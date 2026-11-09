import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';

import '../logging/app_log_store.dart';
import '../player/player_ui_activity.dart';

/// 轻量性能探针（久播卡顿根因定位用，定位后整体 git revert 移除）。
///
/// 编译开关：默认 false。采集时改为 true 重新构建 profile 包，定位后
/// 改回 false 即零开销回退。所有打点调用均包裹在
/// `if (kPerformanceProbeEnabled) ...` 中，AOT(profile/release) 编译时
/// 整支 dead code 被 tree-shake，不开启时零开销零侵入。
const bool kPerformanceProbeEnabled = true;

/// 探针报告入口可见性：诊断构建（开关开启）直接可见——真机复测多为
/// release 包，kDebugMode 在 release 下恒为 false，若再叠加 debug 门槛
/// 会导致诊断包里报告界面无法触发；开关关闭时整体仍被 tree-shake。
const bool kPerformanceProbeEntryVisible = kPerformanceProbeEnabled;

/// 探针事件类型（环形缓冲 _type 槽取值）。
enum _ProbeEventType {
  paint, // 词级 painter paint() 耗时分档
  position, // position Listenable 回调间隔
  ticker, // _TimedLyricText Ticker 回调间隔
  animFrame, // 动画帧间隔（sheet / branch / tab 共用槽，靠 source 区分）
}

/// 动画帧来源。
///
/// 三个来源的播放节奏互不相同（sheet 转场 300ms 一次性、底栏分支 280ms
/// 一次性、TabBarView 可被拖拽/惯性驱动更长），若混在一条 gap 序列里
/// 统计，A 结束到 B 开始的空窗会被折成假掉帧、A 与 B 同时运行时又会
/// 互相污染最大间隔。因此按来源各自维护 last 帧时刻与计数，摘要里
/// 分开输出。
enum AnimSource {
  /// XyPlayerSheetRoute 播放页转场（原唯一来源）。
  sheet,

  /// AnimatedBranchContainer 底栏一级分页切换。
  branch,

  /// MusicLibraryPage 音乐库外层/内层 TabBarView 分页切换。
  tab;

  /// 摘要里使用的短名。
  String get tag => switch (this) {
    AnimSource.sheet => 'sheet',
    AnimSource.branch => 'branch',
    AnimSource.tab => 'tab',
  };
}

/// 单例探针：预分配环形缓冲 + 循环写指针，O(1)、零 GC（采集期间不创建
/// 新对象）；仅内存累加计数，禁止实时打印/写盘 IO；报告由 App 内入口
/// 触发一次性渲染/写文档目录。UI isolate 内所有调用顺序执行，天然线程
/// 安全，无需加锁。
class PerformanceProbe {
  PerformanceProbe._();

  static final PerformanceProbe instance = PerformanceProbe._();

  /// 环形缓冲容量：4096 条，写满覆盖最旧事件。
  static const int capacity = 4096;

  // ---- 环形缓冲（预分配，槽位复用，写覆盖不新建） ----
  final List<int> _type = List<int>.filled(capacity, 0);
  final List<int> _value = List<int>.filled(capacity, 0); // 微秒值
  int _head = 0;
  int _written = 0;

  /// 全局时钟：预分配一次，读取不分配对象。
  final Stopwatch _clock = Stopwatch()..start();

  // ---- 词级 painter paint() 耗时分档（<2ms / 2-8ms / >8ms） ----
  int paintCalls = 0;
  int paintLt2ms = 0;
  int paint2to8ms = 0;
  int paintGt8ms = 0;
  int _paintStartUs = 0;

  // ---- position Listenable 触发间隔 ----
  /// 原始回调次数（N 个活跃词状态 × 广播次数）。
  int positionCalls = 0;
  /// 合并同批后的广播批次数——间隔统计的真实分母。
  int positionBatchGaps = 0;
  int positionMaxGapUs = 0;
  int _lastPositionUs = 0;

  // ---- _TimedLyricText Ticker 回调间隔 ----
  int tickerCalls = 0;
  int tickerMaxGapUs = 0;
  int _lastTickerUs = 0;

  // ---- 动画帧间隔与掉帧（按 AnimSource 分槽，摘要分开统计） ----
  /// 各来源帧数 / 最大间隔 / 折算掉帧 / 抖动事件 / 上一帧时刻。
  ///
  /// 用定长 List 而非 Map：探针自身要求零分配，Map 查表还会在每帧回调
  /// 里产生装箱。槽位顺序与 `AnimSource.values` 一一对应。
  final List<int> _animFrames =
      List<int>.filled(AnimSource.values.length, 0);
  final List<int> _animMaxGapUs =
      List<int>.filled(AnimSource.values.length, 0);
  final List<int> _animDropped =
      List<int>.filled(AnimSource.values.length, 0);
  final List<int> _animJank =
      List<int>.filled(AnimSource.values.length, 0);
  final List<int> _lastAnimUs =
      List<int>.filled(AnimSource.values.length, 0);

  /// 全部来源合计（摘要/报告沿用合计口径，保留历史曲线可比性）。
  int get animFrames => _sum(_animFrames);
  int get animMaxGapUs => _maxAll(_animMaxGapUs);
  int get animDroppedFrames => _sum(_animDropped);
  int get animJankEvents => _sum(_animJank);

  static int _sum(List<int> values) {
    var total = 0;
    for (var i = 0; i < values.length; i++) {
      total += values[i];
    }
    return total;
  }

  static int _maxAll(List<int> values) {
    var best = 0;
    for (var i = 0; i < values.length; i++) {
      if (values[i] > best) best = values[i];
    }
    return best;
  }

  // ---- 活跃对象计数 ----
  int activeTickers = 0;
  int wordStates = 0;
  int positionListeners = 0;

  /// 进度条 Ticker 活跃数（`_ProgressBarState` 自己的 Ticker，与逐字歌词
  /// Ticker 不同源且节奏不同：它每 100ms setState 一次，是播放页最强的
  /// 帧请求源）。此前完全未纳入统计，导致「帧侧零增长」时无法判断到底
  /// 是没有帧驱动源存活，还是驱动源存活却没有产出帧——这两种情况的
  /// 根因完全不同。
  int progressTickers = 0;

  // ---- 帧侧停摆侦测（frame starvation） ----
  /// 帧侧（paint/ticker/anim 三者）零增长、而 position 仍在推进的周期数。
  int frameStallEvents = 0;
  int _logFrameStallAtUs = 0;

  /// 最近一次帧回调时刻（paint / ticker / anim 任一命中）。
  int _lastFrameUs = 0;

  // ---- 帧管线看门狗（帧调度停摆的确诊与自愈） ----
  /// 2s 定时器：不依赖 vsync，帧停摆时它照样能跑，是唯一能在
  /// 「引擎不再回调 beginFrame」时还能执行代码的通路。
  Timer? _frameWatchdog;

  /// 停摆起点（0 = 当前未停摆）。
  int _stallStartUs = 0;

  /// 看门狗向引擎强推帧的次数（每次停摆 2s 一次）。
  int frameWatchdogKicks = 0;

  /// 看门狗发现帧被软件层禁用、强制恢复 resumed 的次数。
  int frameWatchdogResumes = 0;

  /// 看门狗观察到的停摆总次数。
  int frameWatchdogStalls = 0;

  /// 看门狗救回（强推帧后重新出现帧）的次数。
  int frameWatchdogRecovers = 0;

  int _logWatchdogAtUs = 0;

  // 帧侧增量基线（上一周期结束时的累计值）。
  int _basePaintCalls = 0;
  int _baseAnimFrames = 0;

  // ---- 定时快照（每 30s，预分配 64 槽环形） ----
  static const int snapSlots = 64;
  final List<int> _snapTickers = List<int>.filled(snapSlots, -1);
  final List<int> _snapWords = List<int>.filled(snapSlots, -1);
  final List<int> _snapListeners = List<int>.filled(snapSlots, -1);
  final List<int> _snapWatermark = List<int>.filled(snapSlots, -1);
  int _snapHead = 0;
  int _snapCount = 0;
  bool _snapshotScheduled = false;

  // ---- 日志接入（事件级实时 + 30s 单行摘要，写入应用日志库探针通道） ----
  /// 统一前缀：探针日志导出文件（`xy_music_probe_logs_*.txt`）内据此过滤。
  static const String logPrefix = '[PROBE]';

  /// paint 单帧超阈线（与 >8ms 分档口径一致）。
  static const int paintWarnUs = 8000;

  /// Ticker 回调间隔告警线（60fps 约 16ms，>100ms 即肉眼可见卡顿）。
  static const int tickerGapWarnUs = 100000;

  /// position 回调间隔告警线。
  ///
  /// 必须高于 position 流的**最慢前台档**：`_positionStreamPeriods()`
  /// 中「其它页面」档为 600~650ms，且 Ticker 停止推进时 notifier 只靠
  /// drift 累积硬校准（0.5s / 30% 收敛 ≈ 4 个采样 = ~857ms 一跳）。
  /// 旧阈值 500ms 低于这两者，任何非播放页采集都会恒定为超阈，形成
  /// 每 5s 一条的刷屏误报（实测 240 条 POSITION_GAP 挤满探针日志配额）。
  /// 取 1200ms 留出抖动余量，只抓真正的流中断。
  static const int positionGapWarnUs = 1200000;

  /// position 回调的「同批」合并窗口。
  ///
  /// 每个 `_ProgressiveLyricWordState` 各自持有一份 position listener，
  /// 同一次广播会在**同一帧内**被 N 个 listener 依次回调（N = 活跃词数）。
  /// 若把每次回调都当作独立采样，跨批那一次的 gap 恒等于「整批广播
  /// 间隔」而非「回调间隔」，只要 N > 1 就每批必然产出一条超阈误报。
  /// 因此 gap 小于本窗口视为同批，只累加回调数、不参与间隔统计。
  static const int positionBatchMergeUs = 10000;

  /// 暂停/前后台切换的间隔上限：超过即视为「采集暂停」而非「卡顿」。
  ///
  /// 进入后台时 Flutter 停止发 vsync，paint / Ticker / 动画回调全部冻结，
  /// 恢复瞬间一次回调的 gap 就等于整个后台时长（实测 69 分钟）。这类
  /// 间隔既不该计入 maxGap，更不能按 16.7ms 折算成掉帧——否则一次后台
  /// 恢复就会一次性灌入二十多万帧假掉帧（实测 dropped=380643）。
  static const int gapSuspendUs = 1000000;

  /// 实际刷新率（Hz）。
  ///
  /// 旧口径把帧预算写死 60Hz（16.67ms），在一加 Ace5 竞速版这类 120Hz
  /// 屏上，正常帧间隔本就有 8.33ms；空窗恢复后按 16.67ms 折算，间隔
  /// 越短折算越失真，且 `animGapWarnUs=20ms` 在 120Hz 上等于「掉了
  /// 1.4 帧才记账」，轻度抖动全被漏掉。这里读真实 display 刷新率，
  /// 取不到时回落 60。
  double get refreshRate {
    try {
      final views = ui.PlatformDispatcher.instance.views;
      if (views.isNotEmpty) {
        final rate = views.first.display.refreshRate;
        if (rate.isFinite && rate >= 30) return rate;
      }
    } catch (_) {
      // 部分平台/测试环境取 display 会抛，直接回落默认值。
    }
    return 60;
  }

  /// 单帧预算（微秒）：掉帧折算与告警线的共同基准。
  int get frameBudgetUs {
    final rate = refreshRate;
    return (1000000 / (rate <= 0 ? 60.0 : rate)).round();
  }

  /// 动画帧间隔告警线：1.2 倍单帧预算（60Hz→20ms，120Hz→10ms）。
  int get animGapWarnUs => (frameBudgetUs * 1.2).round();

  /// 帧管线停摆判定线：播放页可见时超过该时长没有任何帧回调即视为
  /// 帧调度停摆（正常前台动画页一帧间隔 ≤16.7ms，静止页也会因进度条
  /// Ticker 每 100ms 产帧；3s 已远超任何正常情况）。
  static const int frameWatchdogStallUs = 3000000;

  /// 看门狗自身轮询周期。用 Timer 而非 vsync：帧管线停摆时 vsync 通路
  /// 已经断了，只能靠事件循环里的定时器做外部观测与复位。
  static const int frameWatchdogPeriodMs = 2000;

  /// 同类事件的最小输出间隔：逐帧超阈只按节流输出代表事件，
  /// 避免把日志库容量刷满（累计次数仍精确计数，摘要里可见）。
  ///
  /// 取 5s 而非 1~2s：AppLogStore 每次 add 都会重置持久化定时器并做全量
  /// jsonEncode 写盘，告警过于密集反而会自己干扰帧率（探针自噪声）。
  static const int eventLogIntervalUs = 5000000;

  // 事件级日志的节流时间戳（0 表示尚未输出过）。
  int _logPaintAtUs = 0;
  int _logTickerAtUs = 0;
  int _logPositionAtUs = 0;
  int _logAnimAtUs = 0;

  // 事件累计次数（摘要与报告共用，长期观察增长）。
  int paintSlowEvents = 0;
  int tickerGapEvents = 0;
  int positionGapEvents = 0;
  int audioStarveEvents = 0;
  int dspTakeoverEvents = 0;

  // 30s 摘要的增量基线（上一周期结束时的累计值）。
  int _basePaintSlow = 0;
  int _baseTickerCalls = 0;
  int _basePositionCalls = 0;
  int _baseAnimDropped = 0;
  int _baseAudioStarve = 0;
  int _summaryCount = 0;

  /// 环形缓冲当前水位（0~capacity）。
  int get watermark => _written < capacity ? _written : capacity;

  /// 运行时长。
  Duration get uptime => _clock.elapsed;

  /// 首帧打点懒启动 30s 定时快照（只创建一次 Timer）。
  void _ensureSnapshotTimer() {
    if (_snapshotScheduled) return;
    _snapshotScheduled = true;
    Timer.periodic(
      const Duration(seconds: 30),
      (_) => _recordSnapshot(),
    );
    _ensureFrameWatchdog();
  }

  /// 帧管线看门狗（单例 Timer，只创建一次）。
  ///
  /// 30s 摘要只能告诉你「这一分钟没帧」，但停摆可能发生在两次摘要之间、
  /// 也可能是丢帧被算进 dropped 而不是零增长；更关键的是**停摆后没有任何
  /// 帧回调能触发侦测代码**，纯靠 vsync 侧打点永远等不到下一帧。因此用
  /// 事件循环里的 Timer 做外部观测：2s 一次，比 30s 摘要快一个数量级，
  /// 定位到停摆起点附近，并且能主动把帧管线踢起来。
  void _ensureFrameWatchdog() {
    if (_frameWatchdog != null) return;
    _frameWatchdog = Timer.periodic(
      const Duration(milliseconds: frameWatchdogPeriodMs),
      (_) => _checkFramePipeline(),
    );
  }

  /// 帧管线当前状态的一句话描述（停摆现场唯一需要的判读依据）。
  ///
  /// 四个字段分别对应三种完全不同的病灶，缺一不可：
  /// - `framesEnabled=false`：SchedulerBinding 被 lifecycle 关掉了帧调度，
  ///   根因在前后台事件（ROM 漏发 resumed / 卡在 inactive），改帧代码无用。
  /// - `scheduled=true`：帧已请求但引擎不回调（vsync/Choreographer 断流），
  ///   属于引擎侧，只能外部强推复位。
  /// - `scheduled=false && transient=0`：根本没人请求帧（Ticker 全被
  ///   mute/stop，或驱动源不在树上），根因在 Ticker 启停逻辑。
  String _pipelineDiag() {
    final binding = SchedulerBinding.instance;
    return 'framesEnabled=${binding.framesEnabled}'
        ' life=${binding.lifecycleState}'
        ' scheduled=${binding.hasScheduledFrame}'
        ' phase=${binding.schedulerPhase.name}'
        ' transient=${binding.transientCallbackCount}';
  }

  /// 帧管线看门狗主体：观测 + 分档复位。
  void _checkFramePipeline() {
    final nowUs = _clock.elapsedMicroseconds;
    // 未进过播放页（无帧样本）或播放页不可见：不产帧是正常现象。
    if (!_uiVisible() || _lastFrameUs == 0) {
      _stallStartUs = 0;
      return;
    }
    // App 不在前台：引擎本就停发 vsync，不做任何干预（也避免人为拉起
    // 后台帧唤醒 CPU 增加耗电）。
    if (SchedulerBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      _stallStartUs = 0;
      return;
    }
    final sinceLastFrameUs = nowUs - _lastFrameUs;
    if (sinceLastFrameUs < frameWatchdogStallUs) {
      // 帧已恢复：若上一轮判定为停摆，记一条恢复日志（能量化「卡了多久、
      // 是否被看门狗救回来」，是判断修复是否生效的直接证据）。
      if (_stallStartUs != 0) {
        frameWatchdogRecovers++;
        _emit(
          '$logPrefix WATCHDOG_RECOVER 帧管线恢复'
          ' 本次停摆=${_fmtMs(nowUs - _stallStartUs)}'
          ' 救回=$frameWatchdogRecovers 次 ${_pipelineDiag()}',
          level: AppLogLevel.warning,
        );
        _stallStartUs = 0;
      }
      return;
    }

    // 判定为停摆。
    if (_stallStartUs == 0) {
      _stallStartUs = _lastFrameUs;
      frameWatchdogStalls++;
    }
    final binding = SchedulerBinding.instance;
    final String action;
    if (!binding.framesEnabled) {
      // 病灶一：帧被软件层禁用。强制回到 resumed，让 SchedulerBinding
      // 重新打开帧调度（ROM 漏发 resumed 时这是唯一恢复手段）。
      frameWatchdogResumes++;
      // ignore: invalid_use_of_protected_member
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      action = 'force-resume';
    } else {
      // 病灶二/三：直接向引擎请求 vsync。绕开 SchedulerBinding 的
      // `_hasScheduledFrame` 熔断（该标志一旦卡在 true，所有
      // scheduleFrame 都会变成 no-op，形成永久停摆）。
      frameWatchdogKicks++;
      binding.platformDispatcher.scheduleFrame();
      action = 'kick-frame';
    }
    if (!_throttled(nowUs, _logWatchdogAtUs)) {
      _logWatchdogAtUs = nowUs;
      _emit(
        '$logPrefix WATCHDOG_STALL 帧管线停摆已持续=${_fmtMs(sinceLastFrameUs)}'
        ' 动作=$action（kick=$frameWatchdogKicks resume=$frameWatchdogResumes'
        ' 停摆=$frameWatchdogStalls 次） ${_pipelineDiag()}'
        ' act(tickers=$activeTickers progress=$progressTickers'
        ' words=$wordStates listeners=$positionListeners)',
        level: AppLogLevel.warning,
      );
    }
  }

  void _record(_ProbeEventType type, int valueUs) {
    _type[_head] = type.index;
    _value[_head] = valueUs;
    _head = (_head + 1) % capacity;
    _written++;
  }

  void _recordSnapshot() {
    _snapTickers[_snapHead] = activeTickers;
    _snapWords[_snapHead] = wordStates;
    _snapListeners[_snapHead] = positionListeners;
    _snapWatermark[_snapHead] = watermark;
    _snapHead = (_snapHead + 1) % snapSlots;
    if (_snapCount < snapSlots) _snapCount++;
    _emitSummary();
  }

  // ---- 日志输出（接入项目既有日志体系 AppLogStore） ----

  /// 日志出口：写入应用日志库的**独立探针通道**（设置页「日志 →
  /// 性能探针日志 → 导出」生成的 `xy_music_probe_logs_*.txt`），
  /// debug/profile 下同时写控制台。探针通道有独立配额，不会挤占
  /// 业务日志，也不会混进「导出全部日志 / 导出错误日志」。
  ///
  /// 不使用 `debugPrint`：debug 构建里 `AppLogStore.install()` 已接管
  /// `debugPrint`（内部会再 `add` 一次），直接调用会写出重复条目；
  /// `debugPrintSynchronously` 不在接管范围内，也避免被节流缓冲。
  void _emit(String line, {AppLogLevel level = AppLogLevel.info}) {
    AppLogStore.instance.add(
      line,
      level: level,
      channel: AppLogChannel.probe,
    );
    if (!kReleaseMode || kProfileMode) {
      debugPrintSynchronously(line);
    }
  }

  /// 事件级输出的节流判定：同 2s 内只输出一条代表事件。
  bool _throttled(int nowUs, int lastUs) {
    return lastUs != 0 && nowUs - lastUs < eventLogIntervalUs;
  }

  /// 30s 单行摘要：累计值 + 本周期增量，便于观察长期增长曲线。
  void _emitSummary() {
    _summaryCount++;
    final up = _clock.elapsed;
    final dPaintSlow = paintSlowEvents - _basePaintSlow;
    final dPaintCalls = paintCalls - _basePaintCalls;
    final dTicker = tickerCalls - _baseTickerCalls;
    final dPosition = positionCalls - _basePositionCalls;
    final dDropped = animDroppedFrames - _baseAnimDropped;
    final dAnimFrames = animFrames - _baseAnimFrames;
    final dStarve = audioStarveEvents - _baseAudioStarve;
    final uiVisible = _uiVisible();
    final line = '$logPrefix 30s#$_summaryCount'
        '/${up.inSeconds}sec(${up.inSeconds ~/ 60}m${up.inSeconds % 60}s)';
    final sb = StringBuffer()
      ..write(line)
      // 播放页可见性是本周期所有指标的前提：不可见时 position 走
      // 600~650ms 粗档、逐字/进度条 Ticker 均不在树上，帧侧零增长是
      // 正常现象。没有这个标记会把「用户在看首页」误判成「画面冻住」。
      ..write(uiVisible ? ' [播放页可见]' : ' [非播放页]')
      ..write(' act(tickers=$activeTickers progress=$progressTickers')
      ..write(' words=$wordStates')
      ..write(' listeners=$positionListeners)')
      ..write(
        ' paint(calls=$paintCalls|+$dPaintCalls|<2ms=$paintLt2ms'
        '|2-8ms=$paint2to8ms|>8ms=$paintGt8ms|slow=$paintSlowEvents(+$dPaintSlow))',
      )
      ..write(' ticker(calls=$tickerCalls->+$dTicker maxGap=${_fmtMs(tickerMaxGapUs)})')
      ..write(
        ' pos(batch=$positionBatchGaps cb=$positionCalls->+$dPosition'
        ' maxGap=${_fmtMs(positionMaxGapUs)})',
      )
      ..write(
        ' anim(frames=$animFrames->+$dAnimFrames'
        ' maxGap=${_fmtMs(animMaxGapUs)}'
        ' dropped=$animDroppedFrames(+$dDropped))',
      )
      // 分源明细：底栏 branch / 音乐库 tab 与播放页 sheet 混在一条序列里
      // 统计会把彼此的间隔串成假掉帧，这里各给一份独立读数。
      ..write(' animSrc(${_animSourceSummary()})')
      // 设备帧预算：所有 anim 阈值与掉帧折算都以它为基准，写进摘要才能
      // 判断「10ms 间隔」在 120Hz 机上到底是正常还是掉帧。
      ..write(
        ' dev(rr=${refreshRate.toStringAsFixed(0)}Hz'
        ' budget=${_fmtMs(frameBudgetUs)})',
      )
      ..write(' audio(starve=$audioStarveEvents(+$dStarve) dsp=$dspTakeoverEvents)')
      ..write(' stall=$frameStallEvents')
      // 帧管线状态：把「有没有发帧请求 / 引擎有没有回帧 / 帧是否被
      // lifecycle 禁掉」直接带进摘要，避免 30s 零增长还要靠猜。
      ..write(' pipe(${_pipelineDiag()})')
      ..write(
        ' wd(kick=$frameWatchdogKicks resume=$frameWatchdogResumes'
        ' stall=$frameWatchdogStalls rec=$frameWatchdogRecovers)',
      )
      ..write(' wm=$watermark/$capacity up=${up.inMinutes}m');
    _emit(sb.toString());
    // 帧侧停摆：播放页可见 + position 仍在推进，但 paint/ticker/anim
    // 三者本周期全部零增长——说明没有任何东西向引擎请求帧（frame
    // starvation），画面处于冻结态。这是「久播后越用越卡」的直接病灶，
    // 单条 warning 不会被 5s 节流吞掉，可精确定位停摆起点。
    if (uiVisible &&
        _summaryCount > 1 &&
        dPaintCalls == 0 &&
        dTicker == 0 &&
        dAnimFrames == 0 &&
        dPosition > 0) {
      frameStallEvents++;
      final nowUs = _clock.elapsedMicroseconds;
      if (!_throttled(nowUs, _logFrameStallAtUs)) {
        _logFrameStallAtUs = nowUs;
        _emit(
          '$logPrefix FRAME_STALL 帧侧零增长但 position 仍在推进'
          '（本 30s: paint+$dPaintCalls ticker+$dTicker anim+$dAnimFrames'
          ' pos+$dPosition）累计=$frameStallEvents 次'
          ' act(tickers=$activeTickers progress=$progressTickers'
          ' words=$wordStates listeners=$positionListeners)'
          ' 距上次帧=${_fmtMs(_sinceLastFrameUs(nowUs))}'
          ' pipe(${_pipelineDiag()})'
          ' wd(kick=$frameWatchdogKicks resume=$frameWatchdogResumes)'
          ' up=${up.inMinutes}m',
          level: AppLogLevel.warning,
        );
      }
    }
    _basePaintSlow = paintSlowEvents;
    _basePaintCalls = paintCalls;
    _baseTickerCalls = tickerCalls;
    _basePositionCalls = positionCalls;
    _baseAnimDropped = animDroppedFrames;
    _baseAnimFrames = animFrames;
    _baseAudioStarve = audioStarveEvents;
  }

  /// 播放页是否正在显示进度条 / 逐字歌词。
  ///
  /// 直接复用 `PlayerUiActivity`——它与 position 流档位用的是同一个信号，
  /// 探针口径因此与业务口径天然一致，不会出现「探针认为在前台、流却按
  /// 后台档跑」的对不上的情况。
  bool _uiVisible() => PlayerUiActivity.isVisible;

  /// 分源动画读数：`sheet=12f/16.7ms/0d`（帧数 / 最大间隔 / 折算掉帧）。
  String _animSourceSummary() {
    final sb = StringBuffer();
    for (var i = 0; i < AnimSource.values.length; i++) {
      if (i > 0) sb.write(' ');
      sb
        ..write(AnimSource.values[i].tag)
        ..write('=')
        ..write(_animFrames[i])
        ..write('f/')
        ..write(_fmtMs(_animMaxGapUs[i]))
        ..write('/')
        ..write(_animDropped[i])
        ..write('d');
    }
    return sb.toString();
  }

  /// 距最近一次帧回调的时长（从未有过帧时返回 0）。
  int _sinceLastFrameUs(int nowUs) =>
      _lastFrameUs == 0 ? 0 : nowUs - _lastFrameUs;

  // ---- 音频侧最小钩子（由 player_provider 既有事件点调用，仅累加计数） ----

  /// DSP 共享管线接管成功。
  void onDspTakeover() {
    dspTakeoverEvents++;
    _emit('$logPrefix DSP_TAKEOVER 共享管线接管成功（累计 $dspTakeoverEvents 次）');
  }

  /// 缓冲饥饿开始（250ms 轮询首次命中）。
  void onAudioStarveStart() {
    audioStarveEvents++;
    _emit(
      '$logPrefix AUDIO_STARVE 缓冲饥饿开始（累计 $audioStarveEvents 次）',
      level: AppLogLevel.warning,
    );
  }

  /// 缓冲饥饿恢复，[durationMs] 为本次持续时长。
  void onAudioStarveEnd(int durationMs) {
    _emit(
      '$logPrefix AUDIO_STARVE_END 饥饿恢复 持续=${durationMs}ms'
      ' 累计=$audioStarveEvents 次',
      level: AppLogLevel.warning,
    );
  }

  // ---- 打点接口（全部为累加计数，不影响原逻辑） ----

  /// 词级 painter paint() 耗时开始（_SweepWordPainter.paint 首行）。
  void onPaintStart() {
    _ensureSnapshotTimer();
    _paintStartUs = _clock.elapsedMicroseconds;
  }

  /// 词级 painter paint() 耗时结束并分档。
  void onPaintEnd() {
    final us = _clock.elapsedMicroseconds - _paintStartUs;
    paintCalls++;
    _lastFrameUs = _paintStartUs + us;
    if (us < 2000) {
      paintLt2ms++;
    } else if (us <= 8000) {
      paint2to8ms++;
    } else {
      paintGt8ms++;
    }
    _record(_ProbeEventType.paint, us);
    if (us > paintWarnUs) {
      paintSlowEvents++;
      final nowUs = _paintStartUs + us;
      if (!_throttled(nowUs, _logPaintAtUs)) {
        _logPaintAtUs = nowUs;
        _emit(
          '$logPrefix PAINT_SLOW 单帧=${_fmtMs(us)}（超阈'
          ' ${_fmtMs(paintWarnUs)}）累计=$paintSlowEvents 次'
          ' 分档<2/2-8/>8=$paintLt2ms/$paint2to8ms/$paintGt8ms',
          level: AppLogLevel.warning,
        );
      }
    }
  }

  /// position Listenable 回调（_ProgressiveLyricWordState._onPositionChanged）。
  ///
  /// 口径：同一次广播会被 N 个词状态（N = 当前活跃词数）在同一帧内依次
  /// 回调，批内间隔趋近 0、批间间隔才是真实采样节奏。因此按
  /// [positionBatchMergeUs] 合并同批，只有跨批的回调参与间隔统计与告警。
  void onPositionChanged() {
    _ensureSnapshotTimer();
    final now = _clock.elapsedMicroseconds;
    positionCalls++;
    final gap = _lastPositionUs == 0 ? -1 : now - _lastPositionUs;
    _lastPositionUs = now;
    // 首次回调或同批（同一帧内其余 listener）——不参与间隔统计。
    if (gap < 0 || gap < positionBatchMergeUs) return;
    positionBatchGaps++;
    // 超长间隔 = 采集暂停（后台/息屏/暂停恢复），不代表卡顿，不计 maxGap。
    if (gap < gapSuspendUs && gap > positionMaxGapUs) positionMaxGapUs = gap;
    _record(_ProbeEventType.position, gap);
    if (gap > positionGapWarnUs) {
      positionGapEvents++;
      // 仅在播放页可见时输出告警：非播放页 position 走 600~650ms 粗档，
      // 且 Ticker 停止推进时 notifier 只靠 drift 硬校准（~857ms 一跳），
      // 会形成每 5s 一条的恒超阈刷屏——实测 240 条挤满 300 条探针配额，
      // 把用户真正卡顿时的现场全部挤掉。计数仍精确累加，摘要里可见。
      if (_uiVisible() && !_throttled(now, _logPositionAtUs)) {
        _logPositionAtUs = now;
        _emit(
          '$logPrefix POSITION_GAP 间隔=${_fmtMs(gap)}（超阈'
          ' ${_fmtMs(positionGapWarnUs)}）累计=$positionGapEvents 次'
          ' 最大=${_fmtMs(positionMaxGapUs)}',
          level: AppLogLevel.warning,
        );
      }
    }
  }

  /// _TimedLyricText Ticker 回调（_onTick，含早退空转帧）。
  void onTickerTick() {
    _ensureSnapshotTimer();
    final now = _clock.elapsedMicroseconds;
    _lastFrameUs = now;
    if (_lastTickerUs != 0) {
      tickerCalls++;
      final gap = now - _lastTickerUs;
      // 超长间隔 = 无帧（后台/息屏/暂停恢复），不代表 Ticker 卡顿：
      // 不计 maxGap、不记事件，避免后台时长污染（实测 maxGap=63 分钟）。
      if (gap >= gapSuspendUs) {
        _lastTickerUs = now;
        return;
      }
      if (gap > tickerMaxGapUs) tickerMaxGapUs = gap;
      _record(_ProbeEventType.ticker, gap);
      if (gap > tickerGapWarnUs) {
        tickerGapEvents++;
        if (!_throttled(now, _logTickerAtUs)) {
          _logTickerAtUs = now;
          _emit(
            '$logPrefix TICKER_GAP 间隔=${_fmtMs(gap)}（超阈'
            ' ${_fmtMs(tickerGapWarnUs)}）累计=$tickerGapEvents 次'
            ' 最大=${_fmtMs(tickerMaxGapUs)}',
            level: AppLogLevel.warning,
          );
        }
      }
    }
    _lastTickerUs = now;
  }

  /// 动画帧回调（各动画源的 controller/animation listener）。
  ///
  /// [source] 缺省为 [AnimSource.sheet]，兼容 `onAnimFrame` 直接作为
  /// `VoidCallback` tearoff 传给 `addListener` 的既有调用点。
  void onAnimFrame([AnimSource source = AnimSource.sheet]) {
    final now = _clock.elapsedMicroseconds;
    _lastFrameUs = now;
    final i = source.index;
    final last = _lastAnimUs[i];
    if (last != 0) {
      _animFrames[i]++;
      final gap = now - last;
      // 超长间隔 = 动画被后台/息屏冻结后恢复，不是掉帧：直接丢弃，
      // 否则一次恢复就会按整帧倍数折算灌入二十多万帧假掉帧
      // （实测 dropped=380643，animMaxGap=69 分钟全部来自后台时长）。
      if (gap >= gapSuspendUs) {
        _lastAnimUs[i] = now;
        return;
      }
      if (gap > _animMaxGapUs[i]) _animMaxGapUs[i] = gap;
      // 掉帧：帧间隔超过告警线（1.2 倍真实单帧预算）判定为一次抖动，
      // 间隔越大按整帧倍数累加。基准从写死的 16667us 改为按刷新率
      // 折算，120Hz 屏上不再系统性低估掉帧数。
      if (gap > animGapWarnUs) {
        final budget = frameBudgetUs;
        _animDropped[i] += budget <= 0 ? 0 : (gap - budget) ~/ budget;
        _animJank[i]++;
        _record(_ProbeEventType.animFrame, gap);
        if (!_throttled(now, _logAnimAtUs)) {
          _logAnimAtUs = now;
          _emit(
            '$logPrefix ANIM_JANK[${source.tag}] 帧间隔=${_fmtMs(gap)}'
            '（超阈 ${_fmtMs(animGapWarnUs)}）掉帧累计=$animDroppedFrames 帧'
            ' 抖动事件=$animJankEvents 次',
            level: AppLogLevel.warning,
          );
        }
      }
    }
    _lastAnimUs[i] = now;
  }

  /// 动画开始（controller.forward / animateTo 被触发时调用）。
  ///
  /// 清空该来源的上一帧时刻：两段动画之间可能隔着任意长的空闲期，
  /// 若沿用上一次的 last，首帧 gap 就是整段空闲时长，只能靠
  /// [gapSuspendUs] 兜住 >1s 的情况，1s 以内的空闲仍会被折成假掉帧。
  void onAnimStart(AnimSource source) {
    _lastAnimUs[source.index] = 0;
  }

  /// 动画结束/中断（controller 停稳或 dispose 时调用），同样清空基准。
  void onAnimStop(AnimSource source) {
    _lastAnimUs[source.index] = 0;
  }

  void onTickerStart() {
    _ensureSnapshotTimer();
    activeTickers++;
  }

  void onTickerStop() {
    if (activeTickers > 0) activeTickers--;
  }

  /// 进度条 Ticker（`_ProgressBarState`）启停。
  ///
  /// 与逐字歌词 Ticker 分开计数：前者是播放页最强帧请求源（每 100ms
  /// setState），后者只在活动行且逐字模式生效。FRAME_STALL 出现时，
  /// 靠这两个数就能区分「没有任何帧驱动源」与「驱动源活着但产不出帧」。
  void onProgressTickerStart() {
    _ensureSnapshotTimer();
    progressTickers++;
  }

  void onProgressTickerStop() {
    if (progressTickers > 0) progressTickers--;
  }

  void onWordStateCreated() {
    _ensureSnapshotTimer();
    wordStates++;
  }

  void onWordStateDisposed() {
    if (wordStates > 0) wordStates--;
  }

  void onPositionListenerAdded() {
    _ensureSnapshotTimer();
    positionListeners++;
  }

  void onPositionListenerRemoved() {
    if (positionListeners > 0) positionListeners--;
  }

  // ---- 报告 ----

  String _fmtMs(int us) {
    if (us < 1000) return '$us us';
    return '${(us / 1000).toStringAsFixed(1)} ms';
  }

  /// 生成报告文本（App 内直接渲染 / 查看时写文档目录一次）。
  String buildReport() {
    final now = _clock.elapsed;
    final sb = StringBuffer();
    sb.writeln('XY-Music 性能探针报告');
    sb.writeln('日志前缀: $logPrefix（同数据已写入应用日志库的独立探针通道，'
        '设置页「日志 → 性能探针日志」可单独导出）');
    sb.writeln('运行时长: $now.inMinutes 分 ${now.inSeconds % 60} 秒');
    sb.writeln('环形缓冲水位: $watermark / $capacity（写满覆盖最旧）');
    sb.writeln('---');
    sb.writeln('[词级 painter paint()]');
    sb.writeln('  调用: $paintCalls 次');
    sb.writeln(
      '  分档: <2ms $paintLt2ms | 2-8ms $paint2to8ms | >8ms $paintGt8ms',
    );
    sb.writeln(
      '  平均: '
      '${paintCalls == 0 ? 0 : _fmtMs(_probeAvgPaintUs())} / 帧',
    );
    sb.writeln('  超阈(>8ms)事件: $paintSlowEvents 次');
    sb.writeln('---');
    sb.writeln('[position Listenable 回调]');
    sb.writeln('  原始回调: $positionCalls 次（活跃词状态数 × 广播次数）');
    sb.writeln('  广播批次: $positionBatchGaps 次（已合并同批 listener）');
    sb.writeln(
      '  最大间隔: ${_fmtMs(positionMaxGapUs)}'
      '（>${_fmtMs(gapSuspendUs)} 视为采集暂停，不计入）',
    );
    sb.writeln('  超阈(>${_fmtMs(positionGapWarnUs)})事件: $positionGapEvents 次');
    sb.writeln('---');
    sb.writeln('[_TimedLyricText Ticker]');
    sb.writeln('  回调: $tickerCalls 次（含早退空转帧）');
    sb.writeln(
      '  最大间隔: ${_fmtMs(tickerMaxGapUs)}'
      '（>${_fmtMs(gapSuspendUs)} 视为采集暂停，不计入）',
    );
    sb.writeln('  超阈(>${_fmtMs(tickerGapWarnUs)})事件: $tickerGapEvents 次');
    sb.writeln('---');
    sb.writeln('[动画帧（按来源分开统计）]');
    sb.writeln(
      '  设备: ${refreshRate.toStringAsFixed(0)}Hz'
      '（单帧预算 ${_fmtMs(frameBudgetUs)}，告警线 ${_fmtMs(animGapWarnUs)}）',
    );
    sb.writeln('  合计帧数: $animFrames');
    for (var i = 0; i < AnimSource.values.length; i++) {
      final src = AnimSource.values[i];
      final gap = _animMaxGapUs[i];
      sb.writeln(
        '  [${src.tag}] 帧数 ${_animFrames[i]}'
        '；最大间隔 ${gap == 0 ? '—' : _fmtMs(gap)}'
        '；掉帧 ${_animDropped[i]} 帧'
        '（抖动 ${_animJank[i]} 次）',
      );
    }
    sb.writeln(
      '  说明: 最大间隔 >${_fmtMs(gapSuspendUs)} 视为采集暂停不计入；'
      '掉帧按真实刷新率折算，仅统计 <${_fmtMs(gapSuspendUs)} 的真实掉帧',
    );
    sb.writeln(
      '  来源: sheet=XyPlayerSheetRoute 播放页转场 / '
      'branch=AnimatedBranchContainer 底栏一级分页 / '
      'tab=MusicLibraryPage TabBarView 分页',
    );
    sb.writeln('---');
    sb.writeln('[音频侧 DSP 管线]');
    sb.writeln('  共享管线接管: $dspTakeoverEvents 次');
    sb.writeln('  缓冲饥饿: $audioStarveEvents 次');
    sb.writeln('---');
    sb.writeln('[帧侧停摆 frame starvation]');
    sb.writeln('  停摆周期: $frameStallEvents 个 30s 周期');
    sb.writeln(
      '  判定: 播放页可见 + position 本周期仍有推进，而 paint/ticker/anim'
      ' 三者全部零增长（= 没有任何东西向引擎请求帧）',
    );
    sb.writeln(
      '  出现即说明画面处于冻结态，是最直接的卡顿病灶；'
      '日志中搜 FRAME_STALL 可定位停摆起点',
    );
    sb.writeln('---');
    sb.writeln('[当前活跃对象]');
    sb.writeln('  逐字歌词 Ticker: $activeTickers');
    sb.writeln('  进度条 Ticker: $progressTickers');
    sb.writeln('  逐字词状态对象: $wordStates');
    sb.writeln('  position Listener: $positionListeners');
    sb.writeln('---');
    sb.writeln('[30s 定时快照（tickers/words/listeners/水位）]');
    if (_snapCount == 0) {
      sb.writeln('  （尚无快照，采集持续 30s 后出现）');
    } else {
      for (var i = 0; i < _snapCount; i++) {
        final idx = (_snapHead - _snapCount + i + snapSlots) % snapSlots;
        final sec = (i + 1) * 30;
        sb.writeln(
          '  +${sec}s: '
          '${_snapTickers[idx]}/${_snapWords[idx]}/'
          '${_snapListeners[idx]}/${_snapWatermark[idx]}',
        );
      }
    }
    return sb.toString();
  }

  int _probeAvgPaintUs() {
    if (paintCalls == 0) return 0;
    // 环形缓冲中的 paint 事件求和求均值（近 4096 条，跨帧混合）。
    var sum = 0;
    var n = 0;
    var idx = (_head - 1 + capacity) % capacity;
    for (var i = 0; i < capacity && i < _written; i++) {
      if (_type[idx] == _ProbeEventType.paint.index) {
        sum += _value[idx];
        n++;
      }
      idx = (idx - 1 + capacity) % capacity;
    }
    return n == 0 ? 0 : sum ~/ n;
  }

  /// 报告原文写入应用文档目录（仅查看时写一次，不实时 IO）。
  Future<String> dumpReportToFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final now = DateTime.now();
    final name = 'probe_report_'
        '${now.year}${_two(now.month)}${_two(now.day)}_'
        '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}.txt';
    final file = File('${dir.path}/$name');
    await file.writeAsString(buildReport());
    return file.path;
  }

  static String _two(int v) => v < 10 ? '0$v' : '$v';
}
