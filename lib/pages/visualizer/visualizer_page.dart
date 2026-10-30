// visualizer_page.dart — 全屏音乐可视化页（5534 重写）。
//
// 1:1 对齐 sonic-topography 的核心体验：黑底 3D 场景（地形/云海、星云两
// 形态可切换）+ 左侧逐行歌词 + 中央封面幽灵层 + 底部毛玻璃播放条 + 左侧
// 竖排形态/面板图标栏 + 右侧设置抽屉（脉冲触发 / 主题颜色 / 音频检测）。
// 页面锁定横屏；单指拖拽旋转视角（OrbitControls 语义）、双指缩放、
// 点击/长按地形触发 ripple 波纹（按压时长映射强度 0.2~3.0）。
//
// 数据链：Android VisualizerBridge（输出混音 FFT+waveform，~20Hz）→
// VisualizerSource（64 段对数频段 + 帧间平滑 + FFT 失效波形兜底）→
// BeatDetector（低频窗口谱通量节拍检测，移植 beatDetector.ts）→
// CustomPainter（CPU 投影 + ui.Vertices）。
//
// 性能：场景渲染走 Ticker + repaint 通知器，歌词/进度条各自独立 watch，
// 设置变更不触发场景重建。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter;

import 'ghost_cover.dart';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart'
    show
        MethodChannel,
        SystemChrome,
        SystemUiMode,
        SystemUiOverlayStyle,
        DeviceOrientation;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../src/core/db_path.dart';
import '../../src/player/beat_detector.dart';
import '../../src/player/player_provider.dart';
import '../../src/player/visualizer_source.dart';
import '../../src/lyrics/lyrics_models.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/cover_image.dart';
import 'visualizer_engine.dart';
import 'visualizer_scenes.dart';
import 'visualizer_settings.dart';

/// 歌词偏移存取 key（与播放页共用同一份配置）。
const String _lyricsOffsetsKey = 'playerLyricsOffsetsTenthsV1';

enum _DrawerSection { none, theme, groundEq, blocks, pulse, meteor, lyrics, bar, detect }

class VisualizerPage extends ConsumerStatefulWidget {
  const VisualizerPage({super.key});

  @override
  ConsumerState<VisualizerPage> createState() => _VisualizerPageState();
}

class _VisualizerPageState extends ConsumerState<VisualizerPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// 状态栏原生兜底通道：Android 15 强制 edge-to-edge 后 SystemChrome 的
  /// immersiveSticky 在部分机型（荣耀等）失效，API 30+ 用原生
  /// WindowInsetsController 硬隐藏状态栏。
  static const _systemUiChannel = MethodChannel('com.xymusic.mobile/system_ui');

  Ticker? _ticker;
  Duration _lastElapsed = Duration.zero;
  double _time = 0; // 真实秒（按压时长/冷却计时）
  double _shaderTime = 0; // 场景时间（真实时间流，对齐参考 uTime=clock）
  double _blockPulse = 0; // 悬浮方块脉冲（kick 包络的指数平滑）

  // 节拍链路状态（脉冲/流星两套独立检测器）。
  BeatDetectorState _kickBeat = createBeatDetectorState();
  BeatDetectorState _meteorBeat = createBeatDetectorState();
  bool _kickOnset = false;
  double _kickEnv = 0;
  bool _meteorOnset = false;
  double _meteorEnv = 0;
  double _lastKickAt = -999;
  double _lastMeteorAt = -999;
  final List<VisMeteor> _meteors = <VisMeteor>[];
  List<double> _displayBands = List.filled(kVisBandCount, 0);
  // 数据源状态。
  bool _sourceReady = false;
  bool _sourceFailed = false;
  bool _noAudioHint = false; // 已启动但无音频输出提示

  // 3D 相机 + ripple 缓冲（手势直接操作）。
  final OrbitCamera _cam = OrbitCamera();
  final VisRippleBuffer _ripples = VisRippleBuffer();

  // 手势状态。
  double? _pressAt; // 按下时刻（真实秒）
  Offset? _pressPos;
  Offset _lastFocal = Offset.zero;
  double _lastScale = 1.0;
  bool _inScale = false;

  // 封面幽灵层（预处理后的低饱和提亮+遮罩图）。
  GhostTextures? _coverImage;
  String? _coverKey;
  String? _coverSourcePath; // 原始封面文件路径（播放栏缩略图用）

  // UI 状态。
  _DrawerSection _drawer = _DrawerSection.none;
  final ValueNotifier<int> _frameTick = ValueNotifier<int>(0);
  /// 活帧：painter 持有它的引用，_onTick 每帧原地更新 time/kickEnvelope/
  /// rms/blockPulse 等字段，使暂停/无音频（无 rebuild）时画面时间流仍推进
  /// （否则 painter 停留在 build 时快照，脉冲冻结不回落）。
  VisFrame? _liveFrame;
  int _lyricsOffsetTenths = 0;
  String? _offsetLoadedFor;

  // 底部播放栏自动隐藏：开启后 3 秒无触摸淡出。可见时任意触摸刷新计时；
  // 隐藏后只有单击播放栏区域唤起（_revealBar），点场景/其它区域不唤起。
  // Listener 在 build 的 Stack 外层监听，不消费事件。
  Timer? _barHideTimer;
  bool _barVisible = true;

  void _touchActivity() {
    // 隐藏期间触摸不算活动：唤起只认播放栏区域的单击。
    if (!_barVisible) return;
    _barHideTimer?.cancel();
    _barHideTimer = null;
    if (ref.read(visualizerSettingsProvider).autoHideBar) {
      _barHideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && _barVisible) setState(() => _barVisible = false);
      });
    }
  }

  /// 单击播放栏区域唤起：显示并立即启动 3 秒隐藏计时。
  void _revealBar() {
    setState(() => _barVisible = true);
    _touchActivity();
  }

  /// 沉浸式隐藏状态栏：SystemChrome 兜底旧机型，API 30+ 原生硬隐藏。
  /// 路由过渡/前台恢复后 insets 状态可能被重置，帧后与 resume 各调一次。
  Future<void> _hideStatusBar() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await _systemUiChannel.invokeMethod<bool>('setStatusBarHidden', {
      'hidden': true,
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_hideStatusBar());
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 可视化仅限横屏：进入锁横屏，退出恢复。
    SystemChrome.setPreferredOrientations(
        const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    // 沉浸式：隐藏状态栏（从屏幕边缘下滑可临时呼出，sticky 自动回收）。
    unawaited(_hideStatusBar());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_hideStatusBar());
    });
    _ticker = createTicker(_onTick)..start();
    unawaited(_bootSource());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.dispose();
    _frameTick.dispose();
    _barHideTimer?.cancel();
    _coverImage?.dispose();
    _coverImage = null;
    unawaited(VisualizerSource.instance.stop());
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    // 恢复全局边到边布局（与应用其余页面一致，状态栏回归）。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    unawaited(
      _systemUiChannel.invokeMethod<bool>('setStatusBarHidden', {
        'hidden': false,
      }),
    );
    super.dispose();
  }

  Future<void> _bootSource() async {
    final ok = await VisualizerSource.instance.start();
    if (!mounted) return;
    setState(() {
      _sourceReady = ok;
      _sourceFailed = !ok;
    });
  }

  Future<void> _retrySource() async {
    setState(() => _sourceFailed = false);
    await _bootSource();
  }

  void _onTick(Duration elapsed) {
    final dt = _lastElapsed == Duration.zero
        ? 1 / 60
        : (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    _time += dt;

    final settings = ref.read(visualizerSettingsProvider);
    final src = VisualizerSource.instance;

    _shaderTime += dt;

    // 「运动速度」= 频谱响应速率（对齐 sonic-topography
    // responseRate = lerp(2.2, 60, motionSpeed/100)，统一指数趋近）。
    final motionRate = 2.2 + (60 - 2.2) * settings.motionSpeed / 100;

    if (_sourceReady) {
      final gain = (settings.detectLevel / 100).clamp(0.0, 2.0);
      final smoothed = src.stepSmoothed(dt, ratePerSecond: motionRate);
      for (int i = 0; i < kVisBandCount; i++) {
        _displayBands[i] = math.min(1.0, smoothed[i] * gain);
      }
    } else {
      // 无频谱数据（权限被拒/启动失败）时用怠速呼吸动画保持画面生命感。
      for (int i = 0; i < kVisBandCount; i++) {
        final w = i / kVisBandCount;
        _displayBands[i] = 0.08 +
            0.10 * (0.5 + 0.5 * math.sin(_time * 1.1 + w * 9)) *
                (1 - w * 0.7);
      }
    }

    // 悬浮方块脉冲：kick 包络按「速度」设置的速率做指数趋近平滑
    // （对齐 MapScene：pulseSpeed = lerp(3, 36, speed/100)）。
    final blockRate = 3.0 + (36.0 - 3.0) * settings.blockSpeed / 100;
    _blockPulse += (_kickEnv - _blockPulse) * (1 - math.exp(-blockRate * dt));

    // —— 触发器检测（脉冲 + 流星各一套，Advanced 用自定义频段窗口）——
    _kickOnset = false;
    _meteorOnset = false;
    _kickEnv = 0;
    _meteorEnv = 0;
    if (settings.kickEnabled && _sourceReady) {
      final out = _stepTrigger(
        state: _kickBeat,
        settings: settings,
        delta: dt,
        mode: settings.kickMode,
        sensitivity: settings.kickSensitivity,
        autoTrack: settings.kickAutoTrack,
      );
      _kickBeat = out.$1;
      _kickOnset = out.$2;
      _kickEnv = out.$3;
    }
    if (settings.meteorEnabled && _sourceReady) {
      final out = _stepTrigger(
        state: _meteorBeat,
        settings: settings,
        delta: dt,
        mode: settings.meteorMode,
        sensitivity: settings.meteorSensitivity,
        autoTrack: true,
      );
      _meteorBeat = out.$1;
      _meteorOnset = out.$2;
      _meteorEnv = out.$3;
    }

    // —— 脉冲触发 → ripple（随机落点，强度×脉冲强度，冷却帧限流）——
    if (_kickOnset && _time - _lastKickAt >= settings.kickCooldownFrames / 60.0) {
      _lastKickAt = _time;
      final rnd = math.Random();
      final ang = rnd.nextDouble() * math.pi * 2;
      if (settings.form == VisualizerForm.terrain) {
        final rad = math.sqrt(rnd.nextDouble()) * 20.0;
        final strength =
            math.min(_kickEnv * 2.0 * settings.kickStrength * 5.0, 3.0);
        _ripples.add(math.cos(ang) * rad, math.sin(ang) * rad, strength,
            white: false, time: _shaderTime);
      } else {
        // 星云：ripple 落点用归一化偏移（-1..1）。
        _ripples.add(math.cos(ang), math.sin(ang),
            math.min(_kickEnv * 1.6 * settings.kickStrength * 5.0, 2.2),
            white: false, time: _shaderTime);
      }
    }

    // —— 流星触发 → 生成飞行光点（冷却帧限流）——
    if (_meteorOnset &&
        _time - _lastMeteorAt >= settings.meteorCooldownFrames / 60.0) {
      _lastMeteorAt = _time;
      final rnd = math.Random();
      final strength =
          math.min(_meteorEnv * settings.meteorStrength * 2.2, 1.5);
      if (settings.form == VisualizerForm.terrain) {
        final ang = rnd.nextDouble() * math.pi * 2;
        final spd = 26 + rnd.nextDouble() * 14;
        _meteors.add(VisMeteor(
          x: math.cos(ang) * 95,
          y: 22 + rnd.nextDouble() * 18,
          z: math.sin(ang) * 95,
          vx: -math.cos(ang) * spd,
          vy: -(8 + rnd.nextDouble() * 8),
          vz: -math.sin(ang) * spd,
          t0: _shaderTime,
          strength: strength,
        ));
      } else {
        // 星云：归一化坐标（-1..1），vy 为屏幕高度比例。
        final ang = rnd.nextDouble() * math.pi * 2;
        final spd = 0.35 + rnd.nextDouble() * 0.3;
        _meteors.add(VisMeteor(
          x: math.cos(ang) * 0.9,
          y: 0.45 + rnd.nextDouble() * 0.35,
          z: math.sin(ang) * 0.5,
          vx: -math.cos(ang) * spd,
          vy: -(0.22 + rnd.nextDouble() * 0.16),
          vz: -math.sin(ang) * spd * 0.4,
          t0: _shaderTime,
          strength: strength,
        ));
      }
    }
    // 清理过期流星。
    if (_meteors.isNotEmpty) {
      _meteors.removeWhere((m) => _shaderTime - m.t0 > 3.4);
    }

    // —— 数据活跃度提示 ——
    final active = _sourceReady && VisualizerSource.instance.hasData;
    if (active && _noAudioHint) {
      _noAudioHint = false;
    } else if (!active && _sourceReady && !_noAudioHint) {
      _noAudioHint = true;
    }

    // 活帧字段原地更新：painter 持有 _liveFrame 引用、repaint 每帧触发
    // paint()，因此这里刷新时间流即可让地形/星云动画持续推进——不再依赖
    // build 重建 painter（暂停/无音频时无 rebuild，旧实现会冻结）。
    final live = _liveFrame ??= _frame(settings);
    live.time = _shaderTime;
    live.kickEnvelope = settings.kickEnabled ? _kickEnv : 0;
    live.rms = VisualizerSource.instance.rms;
    live.blockPulse = _blockPulse;

    _frameTick.value++;
  }

  /// 触发器推进一步：返回 (新状态, 是否 onset, 包络)。
  /// Auto Beat 用低频四窗口；Advanced 用 bandStart..bandEnd 自定义窗口；
  /// 灵敏度 0..1 → 检测器 0..100；「自动追踪」关闭时禁用窗口自动挑选
  /// （固定 Classic 窗口，等效降低自适应）。
  (BeatDetectorState, bool, double) _stepTrigger({
    required BeatDetectorState state,
    required VisualizerSettings settings,
    required double delta,
    required TriggerMode mode,
    required double sensitivity,
    required bool autoTrack,
  }) {
    List<double> windowBands;
    if (mode == TriggerMode.advanced) {
      final start = settings.bandStart.clamp(0, kVisBandCount - 2);
      final end = settings.bandEnd.clamp(start + 1, kVisBandCount - 1);
      windowBands = _displayBands.sublist(start, math.min(end + 1, start + 8));
    } else {
      windowBands = _displayBands.sublist(0, 8);
    }
    var out = stepBeatDetector(
      state: state,
      windowBands: windowBands,
      deltaSeconds: delta,
      sensitivity: sensitivity * 100,
    );
    var st = out.state;
    if (!autoTrack) {
      // 固定窗口：重置窗口评分避免自动切换（简化实现）。
      st = BeatDetectorState(
        activeWindowIndex: st.activeWindowIndex,
        windowScores: List.filled(st.windowScores.length, 0),
        previousWindowLevels: st.previousWindowLevels,
        fluxHistory: st.fluxHistory,
        fluxHistoryIndex: st.fluxHistoryIndex,
        smoothedFlux: st.smoothedFlux,
        previousSmoothedFlux: st.previousSmoothedFlux,
        cooldownRemaining: st.cooldownRemaining,
        kickEnvelopeState: st.kickEnvelopeState,
      );
    }
    return (st, out.kickOnset, out.kickEnvelope);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(visualizerSettingsProvider);
    final player = ref.watch(playerProvider);
    final current = player.current;
    // 关闭自动隐藏时立即唤起播放栏（build 内直接改标志，本次渲染即生效）。
    if (!settings.autoHideBar && !_barVisible) _barVisible = true;

    // 歌曲切换时重载歌词偏移 + 封面幽灵层。
    final songPath = current?.path ?? '';
    if (songPath.isNotEmpty && _offsetLoadedFor != songPath) {
      _offsetLoadedFor = songPath;
      unawaited(_loadLyricsOffset(songPath));
    }
    final coverKey = '$songPath\u0000${current?.coverUrl ?? ''}';
    if (_coverKey != coverKey) {
      _coverKey = coverKey;
      unawaited(_loadCover(current));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        // Listener 只监听不消费：可见时任意触摸（拖动/单击/设置面板操作）
        // 都刷新 3 秒隐藏计时；隐藏期间触摸不唤起（唤起只认播放栏区域
        // 单击，见 _revealBar）。
        child: Listener(
          onPointerDown: (_) => _touchActivity(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 场景层（Ticker 驱动，不随 riverpod 重建）+ 轨道相机手势。
              RepaintBoundary(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: _onScaleStart,
                  onScaleUpdate: _onScaleUpdate,
                  onTapDown: (d) {
                    _pressAt = _time;
                    _pressPos = d.localPosition;
                  },
                  onTapUp: _onTapRelease,
                  onTapCancel: () {
                    _pressAt = null;
                    _pressPos = null;
                  },
                  child: Builder(builder: (context) {
                    // 活帧：settings/form 或封面纹理变化时重建，否则复用
                    // _onTick 每帧原地更新的同一实例——暂停/无音频无 rebuild
                    // 时动画时间流仍由 repaint 驱动持续推进（脉冲正常回落）。
                    if (_liveFrame == null ||
                        _liveFrame!.settings != settings ||
                        _liveFrame!.coverImage != _coverImage) {
                      _liveFrame = _frame(settings);
                    }
                    final visFrame = _liveFrame!;
                    return CustomPaint(
                      painter: settings.form == VisualizerForm.terrain
                          ? TerrainScenePainter(
                              visFrame,
                              repaint: _frameTick, // Ticker 每帧驱动重绘
                            )
                          : NebulaScenePainter(
                              visFrame,
                              repaint: _frameTick,
                            ),
                      isComplex: true,
                      willChange: true,
                    );
                  }),
                ),
              ),
              // 歌词覆盖层（设置驱动：模式/字号/颜色/字体）。
              // 5547：左右手势分区废除——歌词层不参与任何手势
              // （IgnorePointer），全屏手势统一控制脉冲方块地形图
              // （拖动=轨道视角旋转，单击/长按=涟漪波纹）。
              Positioned(
                left: 16,
                top: 0,
                bottom: 140,
                width: MediaQuery.of(context).size.width * 0.40,
                child: IgnorePointer(
                  child: _LyricsOverlay(
                    offsetTenths: _lyricsOffsetTenths,
                    settings: settings,
                  ),
                ),
              ),
              // 底部毛玻璃播放条（对齐图一：左封面+歌名+歌手 / 中进度条 /
              // 右控制按钮；支持 3 秒无操作自动隐藏，隐藏后单击本区域
              // 唤起——GestureDetector 常驻占位命中，可见时把单击让给
              // 播放栏内部按钮）。
              Positioned(
                left: 16,
                right: 16,
                bottom: 18,
                child: AnimatedOpacity(
                  opacity: _barVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // 可见时不拦截（onTap=null，命中落到内部按钮）；
                    // 隐藏时 IgnorePointer 让单击落到这里唤起。
                    onTap: _barVisible ? null : _revealBar,
                    child: IgnorePointer(
                      ignoring: !_barVisible,
                      child: _GlassPlayBar(
                        songPath: songPath,
                        title: current?.title ?? '未在播放',
                        artist: current?.artist ?? '',
                        coverPath: _coverSourcePath,
                        onOpenSettings: () => setState(() {
                          _drawer = _drawer == _DrawerSection.none
                              ? _DrawerSection.theme
                              : _DrawerSection.none;
                        }),
                      ),
                    ),
                  ),
                ),
              ),
              // 右侧设置抽屉。
              _SettingsDrawer(
                section: _drawer,
                onClose: () => setState(() => _drawer = _DrawerSection.none),
                onFormChanged: (f) {
                  // 切换形态时清空 ripple（两形态坐标系不同）。
                  _ripples.clear();
                  ref
                      .read(visualizerSettingsProvider.notifier)
                      .update((s) => s.copyWith(form: f));
                },
                onSectionChanged: (s) => setState(() => _drawer = s),
              ),
              // 数据源失败/无音频输出提示（居左下，短暂显示）。
              if (_sourceFailed)
                Positioned(
                  left: 16,
                  bottom: 150,
                  child: _SourceFailHint(
                    text: '频谱采集不可用（需要麦克风权限）',
                    onRetry: _retrySource,
                  ),
                )
              else if (_noAudioHint)
                Positioned(
                  left: 16,
                  bottom: 150,
                  child: _SourceFailHint(
                    text: '未检测到音频输出，请播放音乐后重试',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // —— 轨道相机手势（OrbitControls 语义）——

  void _onScaleStart(ScaleStartDetails d) {
    _inScale = true;
    _lastFocal = d.localFocalPoint;
    _lastScale = 1.0;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final size = context.size;
    if (size == null || !_inScale) return;
    final delta = d.localFocalPoint - _lastFocal;
    _lastFocal = d.localFocalPoint;
    // 单指：纯旋转；双指：旋转+缩放（对齐 OrbitControls TOUCH.DOLLY_ROTATE）。
    _cam.orbit(delta.dx, delta.dy, size.width, size.height);
    if (d.pointerCount >= 2 && (d.scale - _lastScale).abs() > 0.0001) {
      _cam.dolly(_lastScale / d.scale);
      _lastScale = d.scale;
    }
  }

  void _onTapRelease(TapUpDetails d) {
    final pressAt = _pressAt;
    _pressAt = null;
    if (pressAt == null) return;
    final settings = ref.read(visualizerSettingsProvider);
    // 按压时长映射强度：快速单击 0.9，长按渐强至 3.0（0.3 时波纹环几乎
    // 看不见——用户反馈「单击波纹弱」）；再乘「脉冲强度」（默认 0.5 → ×2.5）。
    final hold = (_time - pressAt).clamp(0.0, 3.0);
    final base = hold < 0.25 ? 0.9 : math.min(0.8 + hold * 0.73, 3.0);
    final strength = base * settings.kickStrength * 5.0;
    final pos = _pressPos ?? d.localPosition;
    _pressPos = null;
    if (settings.form == VisualizerForm.terrain) {
      final gp = _cam.screenToGround(pos, context.size?.width ?? 1,
          context.size?.height ?? 1);
      if (gp == null) return;
      final dist = math.sqrt(gp.dx * gp.dx + gp.dy * gp.dy);
      if (dist > 84) return; // 地形范围外
      _ripples.add(gp.dx, gp.dy, math.min(strength, 3.0),
          white: false, time: _shaderTime);
    } else {
      // 星云：落点归一化到 -1..1。
      final size = context.size;
      if (size == null) return;
      final nx = (pos.dx / size.width - 0.5) * 2;
      final ny = (pos.dy / size.height - 0.5) * 2;
      _ripples.add(nx.clamp(-1.0, 1.0), ny.clamp(-1.0, 1.0),
          math.min(strength, 2.2), white: false, time: _shaderTime);
    }
  }

  VisFrame _frame(VisualizerSettings s) {
    return VisFrame(
      bands: _displayBands,
      kickEnvelope: s.kickEnabled ? _kickEnv : 0,
      rms: VisualizerSource.instance.rms,
      time: _shaderTime,
      blockPulse: _blockPulse,
      settings: s,
      camera: _cam,
      ripples: _ripples,
      coverImage: _coverImage,
      meteors: _meteors,
    );
  }

  /// 封面幽灵层加载：在线封面走代理落盘缓存，本地歌走 ID3 提取；
  /// 双尺寸解码（解码器直出、零离屏）：内层 512px 清晰纹理承载中心
  /// 轮廓，外层 64px 纹理 GPU 放大即强柔焦承载雾环；暗化/去饱和/径向
  /// 与垂直渐隐全部由顶点色承载（ghost_cover.ghostVertexColor）。
  Future<void> _loadCover(QueueItem? item) async {
    try {
      final songPath = item?.path ?? '';
      if (songPath.isEmpty) {
        if (mounted) {
          setState(() {
            _coverImage = null;
            _coverSourcePath = null;
          });
        }
        return;
      }
      final coverUrl = normalizeCoverImageUrl(item?.coverUrl);
      String? coverPath;
      final cacheRoot = await ref.read(appDataDirProvider.future);
      if (coverUrl.isEmpty) {
        final dbPath = await ref.read(dbPathProvider.future);
        coverPath = await getSongCover(
          dbPath: dbPath,
          cacheRoot: cacheRoot,
          path: songPath,
        );
      } else {
        final file =
            File('$cacheRoot/vis_cover_${coverUrl.hashCode}.img');
        if (!await file.exists() || await file.length() == 0) {
          final dataUrl = await proxyImage(
            url: coverUrl,
            referer: 'https://music.163.com/',
          );
          final comma = dataUrl.indexOf(',');
          if (comma > 0 && dataUrl.substring(0, comma).contains(';base64')) {
            await file.writeAsBytes(
              base64Decode(dataUrl.substring(comma + 1)),
              flush: true,
            );
          }
        }
        if (await file.exists() && await file.length() > 0) {
          coverPath = file.path;
        }
      }
      if (coverPath == null || !File(coverPath).existsSync()) {
        if (mounted) {
          setState(() {
            _coverImage = null;
            _coverSourcePath = null;
          });
        }
        return;
      }
      final bytes = await File(coverPath).readAsBytes();
      // 双尺寸解码：instantiateImageCodec 直出（5542/5545 实锤离屏烘焙
      // 管线在 Impeller 真机不可靠，解码器直出才是跨端一致的产物）。
      final sharpCodec =
          await ui.instantiateImageCodec(bytes, targetWidth: 512);
      final sharp = (await sharpCodec.getNextFrame()).image;
      ui.Image? blur;
      try {
        final blurCodec =
            await ui.instantiateImageCodec(bytes, targetWidth: 64);
        blur = (await blurCodec.getNextFrame()).image;
      } catch (_) {
        // 64px 解码失败时降级：雾环复用清晰纹理（仅柔焦程度不同）。
      }
      final textures = buildGhostTextures(
        sharpSrc: sharp,
        blurSrc: blur ?? sharp,
      );
      if (!mounted) {
        sharp.dispose();
        blur?.dispose();
        return;
      }
      setState(() {
        _coverImage?.dispose();
        _coverImage = textures;
        _coverSourcePath = coverPath;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _coverImage = null;
          _coverSourcePath = null;
        });
      }
    }
  }

  Future<void> _loadLyricsOffset(String path) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_lyricsOffsetsKey);
      if (raw == null || raw.isEmpty) return;
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final v = map[path];
      if (v is num && mounted) {
        setState(() => _lyricsOffsetTenths = v.toInt());
      }
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// 歌词覆盖层：逐行列表，全部由「歌词设置」驱动：
// 模式（经典/弹跳/3D空间）、显示开关、活跃/非活跃字号、每行最大字数、
// 字体颜色、卡拉OK颜色跟随主题、Serif/Sans、空间偏移。
// ---------------------------------------------------------------------------

class _LyricsOverlay extends ConsumerStatefulWidget {
  final int offsetTenths;
  final VisualizerSettings settings;
  const _LyricsOverlay({
    required this.offsetTenths,
    required this.settings,
  });

  @override
  ConsumerState<_LyricsOverlay> createState() => _LyricsOverlayState();
}

class _LyricsOverlayState extends ConsumerState<_LyricsOverlay> {
  final ScrollController _scroll = ScrollController();
  int _lastActive = -1;

  // 行距系数（5581 从 2.6 收紧到 2.0，对齐参考图的紧凑排版）。
  double _rowExtent(VisualizerSettings s) =>
      math.max(s.lyricsActiveSize, s.lyricsInactiveSize) * 2.0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<LyricLine> _lyricsFor(WidgetRef ref, QueueItem? item) {
    if (item == null) return const <LyricLine>[];
    final embedded = item.lyricsRaw?.trim() ?? '';
    if (embedded.isNotEmpty) {
      final l = ref.watch(embeddedLyricsProvider(embedded)).valueOrNull;
      if (l != null && l.isNotEmpty) return l;
    }
    return ref.watch(songLyricsProvider(item.path)).valueOrNull ??
        const <LyricLine>[];
  }

  int _activeIndex(List<LyricLine> lines, double pos) {
    final target = pos + widget.offsetTenths / 10.0;
    int idx = -1;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].time <= target) idx = i;
    }
    return idx;
  }

  /// 每行最大字数截断。
  String _clip(String text, double maxChars) {
    final n = maxChars.round();
    if (n <= 0 || text.length <= n) return text;
    return text.substring(0, n) + '…';
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    if (!s.lyricsShow) return const SizedBox.shrink();
    final current = ref.watch(
        playerProvider.select((s) => s.current));
    final position = ref.watch(
        playerProvider.select((s) => s.position));
    final lines = _lyricsFor(ref, current);
    if (lines.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '暂无歌词',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.3),
            fontSize: 13,
            fontFamily: s.lyricsSerif ? 'Georgia' : null,
          ),
        ),
      );
    }
    final active = _activeIndex(lines, position);
    if (active != _lastActive) {
      _lastActive = active;
      if (active >= 0 && _scroll.hasClients) {
        final h = _scroll.position.viewportDimension;
        final extent = _rowExtent(s);
        final target = (active * extent - h * 0.32).clamp(
          0.0,
          _scroll.position.maxScrollExtent,
        );
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
    }

    // 颜色：开启「卡拉OK颜色跟随主题」时用主题强调色，否则用自选字体色。
    final activeColor = s.lyricsFollowTheme
        ? Color(s.theme.accent)
        : Color(s.lyricsColor);
    final fontFamily = s.lyricsSerif ? 'Georgia' : null;
    final extent = _rowExtent(s);
    final leftPad = s.lyricsOffsetX.clamp(-120.0, 240.0);

    return ListView.builder(
      controller: _scroll,
      itemExtent: extent,
      padding: EdgeInsets.symmetric(vertical: extent * 3),
      itemCount: lines.length,
      itemBuilder: (context, i) {
        final isActive = i == active;
        Widget row = Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              SizedBox(
                width: 14,
                child: isActive
                    ? Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: activeColor,
                          shape: BoxShape.circle,
                        ),
                      )
                    : null,
              ),
              Expanded(
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 220),
                  style: TextStyle(
                    color: isActive
                        ? activeColor
                        : Colors.white.withValues(alpha: 0.32),
                    fontSize: isActive
                        ? s.lyricsActiveSize
                        : s.lyricsInactiveSize,
                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                    height: 1.2,
                    fontFamily: fontFamily,
                  ),
                  child: Text(
                    _clip(lines[i].text, s.lyricsMaxChars),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        );
        // 模式：弹跳（活跃行弹性缩放入场）。
        if (isActive && s.lyricsMode == LyricsMode.bounce) {
          row = TweenAnimationBuilder<double>(
            tween: Tween(begin: 1.18, end: 1.0),
            duration: const Duration(milliseconds: 420),
            curve: Curves.elasticOut,
            builder: (context, v, child) => Transform.scale(
                scale: v, alignment: Alignment.centerLeft, child: child),
            child: row,
          );
        }
        // 模式：3D空间（按行距做透视偏移，活跃行前凸）。
        if (s.lyricsMode == LyricsMode.space3d) {
          final depth = (i - active).abs();
          final tilt = isActive ? -0.10 : (0.06 * math.min(depth, 6));
          row = Transform(
            alignment: Alignment.centerLeft,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0018)
              ..rotateY(tilt)
              ..translate(math.min(depth, 6) * 6.0, 0.0, isActive ? 24.0 : 0.0),
            child: row,
          );
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(
            ref.read(playerProvider.notifier).seek(lines[i].time),
          ),
          child: Padding(
            padding: EdgeInsets.only(left: leftPad),
            child: row,
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 底部毛玻璃播放条：封面缩略图 + 进度 + 循环/上一首/播放暂停/下一首/
// 播放队列/设置（对齐参考图布局）。
// ---------------------------------------------------------------------------

class _GlassPlayBar extends ConsumerStatefulWidget {
  final String songPath;
  final String title;
  final String artist;
  final String? coverPath; // 原始封面文件路径（缩略图）
  final VoidCallback onOpenSettings;
  const _GlassPlayBar({
    required this.songPath,
    required this.title,
    required this.artist,
    required this.coverPath,
    required this.onOpenSettings,
  });

  @override
  ConsumerState<_GlassPlayBar> createState() => _GlassPlayBarState();
}

class _GlassPlayBarState extends ConsumerState<_GlassPlayBar> {
  double? _dragValue;

  String _fmt(double secs) {
    if (!secs.isFinite || secs < 0) secs = 0;
    final m = secs ~/ 60;
    final s = (secs % 60).toInt();
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// 播放队列面板：列表 + 当前行高亮，点击切歌。
  void _showQueue() {
    final player = ref.read(playerProvider);
    final queue = player.queue;
    final currentIdx = player.queueIndex;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xEE101418),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 10),
          itemCount: queue.length,
          itemBuilder: (ctx, i) {
            final song = queue[i];
            final active = i == currentIdx;
            return ListTile(
              dense: true,
              leading: Text(
                '${i + 1}',
                style: TextStyle(
                  color: active ? Colors.white : Colors.white54,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              title: Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active ? Colors.white : Colors.white.withValues(alpha: 0.78),
                  fontSize: 14,
                  fontWeight: active ? FontWeight.bold : FontWeight.w400,
                ),
              ),
              subtitle: song.artist.isEmpty
                  ? null
                  : Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 11,
                      ),
                    ),
              trailing: active
                  ? Icon(Icons.graphic_eq_rounded,
                      size: 16, color: Colors.white.withValues(alpha: 0.8))
                  : null,
              onTap: () {
                Navigator.of(ctx).pop();
                unawaited(
                    ref.read(playerProvider.notifier).playIndex(i));
              },
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying =
        ref.watch(playerProvider.select((s) => s.isPlaying));
    final position =
        ref.watch(playerProvider.select((s) => s.position));
    final duration =
        ref.watch(playerProvider.select((s) => s.duration));
    final playMode =
        ref.watch(playerProvider.select((s) => s.playMode));
    final queueLen = ref
        .watch(playerProvider.select((s) => s.queue.length));
    final notifier = ref.read(playerProvider.notifier);
    const loopIcons = [
      Icons.repeat_rounded,
      Icons.repeat_one_rounded,
      Icons.shuffle_rounded,
    ];
    final cover = widget.coverPath;

    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.10),
            ),
          ),
          // 对齐图一的单行大圆角胶囊：左侧封面+歌名+歌手，中间进度条
          // （两端时间），右侧模式/上一曲/大圆播放/下一曲/队列/设置。
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 左：封面缩略图 + 歌名/歌手。
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: cover != null && File(cover).existsSync()
                    ? Image.file(
                        File(cover),
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      )
                    : Container(
                        width: 44,
                        height: 44,
                        color: Colors.white.withValues(alpha: 0.08),
                        child: const Icon(Icons.music_note_rounded,
                            size: 20, color: Colors.white38),
                      ),
              ),
              const SizedBox(width: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 190),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                        height: 1.15,
                      ),
                    ),
                    if (widget.artist.trim().isNotEmpty)
                      Text(
                        widget.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 11,
                          height: 1.2,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // 中：进度条（两端时间标注）。
              Expanded(
                child: Row(
                  children: [
                    Text(_fmt(position),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 11,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        )),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2.5,
                          overlayShape: SliderComponentShape.noOverlay,
                          thumbShape:
                              const RoundSliderThumbShape(enabledThumbRadius: 5),
                          activeTrackColor: Colors.white.withValues(alpha: 0.85),
                          inactiveTrackColor:
                              Colors.white.withValues(alpha: 0.16),
                          thumbColor: Colors.white,
                        ),
                        child: Slider(
                          value: _dragValue ??
                              position.clamp(0.0, duration > 0 ? duration : 1),
                          max: duration > 0 ? duration : 1,
                          onChanged: duration > 0
                              ? (v) => setState(() => _dragValue = v)
                              : null,
                          onChangeEnd: (v) {
                            _dragValue = null;
                            unawaited(
                                ref.read(playerProvider.notifier).seek(v));
                          },
                        ),
                      ),
                    ),
                    Text(_fmt(duration),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 11,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        )),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // 右：控制按钮组（模式/上一曲/播放/下一曲/队列/设置）。
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '播放顺序',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => unawaited(notifier.cyclePlayMode()),
                    icon: Icon(
                      loopIcons[playMode.clamp(0, 2)],
                      size: 21,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    tooltip: '上一首',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => unawaited(notifier.previous()),
                    icon: const Icon(Icons.skip_previous_rounded,
                        color: Colors.white, size: 26),
                  ),
                  const SizedBox(width: 2),
                  // 大圆播放钮：白底黑图标（对齐图一）。
                  Material(
                    color: Colors.white,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => unawaited(notifier.toggle()),
                      child: SizedBox(
                        width: 46,
                        height: 46,
                        child: Icon(
                          isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: Colors.black,
                          size: 27,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    tooltip: '下一首',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => unawaited(notifier.next()),
                    icon: const Icon(Icons.skip_next_rounded,
                        color: Colors.white, size: 26),
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    tooltip: '播放队列',
                    visualDensity: VisualDensity.compact,
                    onPressed: queueLen > 0 ? _showQueue : null,
                    icon: Icon(
                      Icons.queue_music_rounded,
                      size: 22,
                      color: Colors.white.withValues(
                          alpha: queueLen > 0 ? 0.85 : 0.3),
                    ),
                  ),
                  IconButton(
                    tooltip: '可视化设置',
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.onOpenSettings,
                    icon: Icon(
                      Icons.tune_rounded,
                      size: 21,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 右侧设置抽屉：七节面板（主题配色 / 地形均衡器 / 悬浮方块 / 脉冲触发 /
// 流星触发 / 歌词设置 / 音频检测），对齐 sonic-topography 设置面板。
// ---------------------------------------------------------------------------

class _SettingsDrawer extends ConsumerWidget {
  final _DrawerSection section;
  final VoidCallback onClose;
  final ValueChanged<VisualizerForm> onFormChanged;
  final ValueChanged<_DrawerSection> onSectionChanged;

  const _SettingsDrawer({
    required this.section,
    required this.onClose,
    required this.onFormChanged,
    required this.onSectionChanged,
  });

  static const _sectionLabels = [
    '主题配色', '地形均衡器', '悬浮方块', '脉冲触发', '流星触发', '歌词设置', '播放栏', '音频检测',
  ];
  static const _sectionOrder = [
    _DrawerSection.theme,
    _DrawerSection.groundEq,
    _DrawerSection.blocks,
    _DrawerSection.pulse,
    _DrawerSection.meteor,
    _DrawerSection.lyrics,
    _DrawerSection.bar,
    _DrawerSection.detect,
  ];
  // 图标栏（对齐参考图：垂直图标列，选中项圆角描边高亮）。
  static const _sectionIcons = [
    Icons.palette_outlined, // 主题配色
    Icons.equalizer_rounded, // 地形均衡器
    Icons.view_in_ar_rounded, // 悬浮方块
    Icons.monitor_heart_outlined, // 脉冲触发
    Icons.auto_awesome_outlined, // 流星触发
    Icons.music_note_outlined, // 歌词设置
    Icons.slideshow_rounded, // 播放栏
    Icons.graphic_eq_rounded, // 音频检测
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = section != _DrawerSection.none;
    final settings = ref.watch(visualizerSettingsProvider);
    final notifier = ref.read(visualizerSettingsProvider.notifier);

    Widget hint(String text) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            text,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 12,
            ),
          ),
        );

    // 触发器（脉冲/流星共用布局）。
    List<Widget> triggerSection({
      required bool enabled,
      required ValueChanged<bool> onEnabled,
      required TriggerMode mode,
      required ValueChanged<TriggerMode> onMode,
      bool? autoTrack,
      ValueChanged<bool>? onAutoTrack,
      required double sensitivity,
      required ValueChanged<double> onSensitivity,
      required double cooldown,
      required ValueChanged<double> onCooldown,
      required double strength,
      required ValueChanged<double> onStrength,
    }) {
      return [
        _switchTile('启用', enabled, onEnabled),
        const SizedBox(height: 8),
        _segmentTabs(
          labels: const ['Auto Beat', 'Advanced'],
          activeIndex: mode == TriggerMode.autoBeat ? 0 : 1,
          onChanged: (i) =>
              onMode(i == 0 ? TriggerMode.autoBeat : TriggerMode.advanced),
        ),
        if (autoTrack != null && mode == TriggerMode.autoBeat)
          _switchTile('自动追踪', autoTrack, onAutoTrack!),
        _sliderRow('灵敏度', sensitivity, 0, 1, onSensitivity,
            label: sensitivity.toStringAsFixed(1)),
        _sliderRow('冷却帧', cooldown, 0, 300, onCooldown,
            label: cooldown.round().toString()),
        _sliderRow('脉冲强度', strength, 0, 1, onStrength,
            label: strength.toStringAsFixed(1)),
        if (mode == TriggerMode.advanced) ...[
          const SizedBox(height: 8),
          Text(
            '触发频段（Advanced）',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 12,
            ),
          ),
          _sliderRow(
            '下限',
            settings.bandStart.toDouble(),
            0,
            27,
            (v) => notifier.update((s) {
              final start = v.toInt();
              final end = math.max(start + 1, s.bandEnd);
              return s.copyWith(bandStart: start, bandEnd: end);
            }),
            label: settings.bandStart.toString(),
          ),
          _sliderRow(
            '上限',
            settings.bandEnd.toDouble(),
            1,
            28,
            (v) => notifier.update((s) {
              final end = math.max(v.toInt(), s.bandStart + 1);
              return s.copyWith(bandEnd: end);
            }),
            label: settings.bandEnd.toString(),
          ),
        ],
      ];
    }

    return Positioned(
      top: 0,
      bottom: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          offset: visible ? Offset.zero : const Offset(1.2, 0),
          child: FadeTransition(
            opacity: AlwaysStoppedAnimation(visible ? 1 : 0),
            child: ClipRRect(
              borderRadius:
                  const BorderRadius.horizontal(left: Radius.circular(24)),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: Container(
                  width: 332,
                  color: Colors.black.withValues(alpha: 0.62),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 左缘图标栏（选中项圆角描边高亮，对齐参考图）。
                      Container(
                        width: 56,
                        color: Colors.black.withValues(alpha: 0.35),
                        child: SafeArea(
                          top: false,
                          child: Column(
                            children: [
                              const SizedBox(height: 10),
                              for (int i = 0; i < _sectionOrder.length; i++)
                                _railIcon(
                                  i,
                                  selected: section == _sectionOrder[i],
                                  onTap: () =>
                                      onSectionChanged(_sectionOrder[i]),
                                ),
                            ],
                          ),
                        ),
                      ),
                      // 右侧内容面板。
                      Expanded(
                        child: SafeArea(
                          top: false,
                          child: ListView(
                            padding:
                                const EdgeInsets.fromLTRB(16, 14, 16, 24),
                            children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                section == _DrawerSection.none
                                    ? '可视化设置'
                                    : _sectionLabels[
                                        _sectionOrder.indexOf(section)],
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: onClose,
                              icon: Icon(Icons.close_rounded,
                                  size: 20,
                                  color: Colors.white.withValues(alpha: 0.6)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        // 形态切换（地形 / 星云）。
                        _segmentTabs(
                          labels: const ['地形 / 云海', '星云'],
                          activeIndex: settings.form == VisualizerForm.terrain
                              ? 0
                              : 1,
                          onChanged: (i) => onFormChanged(i == 0
                              ? VisualizerForm.terrain
                              : VisualizerForm.nebula),
                        ),
                        const SizedBox(height: 12),
                        // —— 主题配色 ——
                        if (section == _DrawerSection.theme) ...[
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              for (int i = 0; i < kVisThemes.length; i++)
                                _namedSwatch(
                                  kVisThemes[i],
                                  selected: settings.themeIndex == i,
                                  onTap: () => notifier.update(
                                      (s) => s.copyWith(themeIndex: i)),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: () => notifier.update((s) =>
                                const VisualizerSettings().copyWith(
                                    form: s.form)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white70,
                              side: BorderSide(
                                  color:
                                      Colors.white.withValues(alpha: 0.25)),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.restart_alt_rounded,
                                size: 18),
                            label: const Text('恢复全部默认设置',
                                style: TextStyle(fontSize: 13)),
                          ),
                          _switchTile(
                            '显示封面',
                            settings.showCover,
                            (v) => notifier
                                .update((s) => s.copyWith(showCover: v)),
                          ),
                        ]
                        // —— 地形均衡器 ——
                        else if (section == _DrawerSection.groundEq) ...[
                          const SizedBox(height: 4),
                          for (int i = 0; i < kEqBandNames.length; i++)
                            _eqRow(
                              settings,
                              i,
                              onChanged: (band) => notifier.update((s) {
                                final eq = List<VisEqBand>.of(s.groundEq);
                                eq[i] = band;
                                return s.copyWith(groundEq: eq);
                              }),
                            ),
                          _sliderRow(
                            '运动速度',
                            settings.motionSpeed,
                            0,
                            100,
                            (v) => notifier
                                .update((s) => s.copyWith(motionSpeed: v)),
                            label: settings.motionSpeed.round().toString(),
                          ),
                          _sliderRow(
                            '振幅',
                            settings.amplitude,
                            0,
                            100,
                            (v) => notifier
                                .update((s) => s.copyWith(amplitude: v)),
                            label: settings.amplitude.round().toString(),
                          ),
                          _sliderRow(
                            '地形密度',
                            settings.terrainDensity.toDouble(),
                            0,
                            100,
                            (v) => notifier.update(
                                (s) => s.copyWith(terrainDensity: v.round())),
                            label: '${settings.terrainDensity}',
                          ),
                        ]
                        // —— 悬浮方块 ——
                        else if (section == _DrawerSection.blocks) ...[
                          _switchTile(
                            '启用',
                            settings.blocksEnabled,
                            (v) => notifier
                                .update((s) => s.copyWith(blocksEnabled: v)),
                          ),
                          _sliderRow(
                            '强度',
                            settings.blockIntensity,
                            0,
                            100,
                            (v) => notifier
                                .update((s) => s.copyWith(blockIntensity: v)),
                            label: settings.blockIntensity.round().toString(),
                          ),
                          _sliderRow(
                            '最小尺寸',
                            settings.blockMinSize,
                            0,
                            100,
                            (v) => notifier.update((s) => s.copyWith(
                                blockMinSize: v,
                                blockMaxSize: math.max(v, s.blockMaxSize))),
                            label: settings.blockMinSize.round().toString(),
                          ),
                          _sliderRow(
                            '最大尺寸',
                            settings.blockMaxSize,
                            0,
                            100,
                            (v) => notifier.update((s) => s.copyWith(
                                blockMaxSize: v,
                                blockMinSize: math.min(v, s.blockMinSize))),
                            label: settings.blockMaxSize.round().toString(),
                          ),
                          _sliderRow(
                            '速度',
                            settings.blockSpeed,
                            0,
                            100,
                            (v) => notifier
                                .update((s) => s.copyWith(blockSpeed: v)),
                            label: settings.blockSpeed.round().toString(),
                          ),
                        ]
                        // —— 脉冲触发 ——
                        else if (section == _DrawerSection.pulse) ...[
                          ...triggerSection(
                            enabled: settings.kickEnabled,
                            onEnabled: (v) => notifier
                                .update((s) => s.copyWith(kickEnabled: v)),
                            mode: settings.kickMode,
                            onMode: (m) =>
                                notifier.update((s) => s.copyWith(kickMode: m)),
                            autoTrack: settings.kickAutoTrack,
                            onAutoTrack: (v) => notifier
                                .update((s) => s.copyWith(kickAutoTrack: v)),
                            sensitivity: settings.kickSensitivity,
                            onSensitivity: (v) => notifier
                                .update((s) => s.copyWith(kickSensitivity: v)),
                            cooldown: settings.kickCooldownFrames,
                            onCooldown: (v) => notifier.update(
                                (s) => s.copyWith(kickCooldownFrames: v)),
                            strength: settings.kickStrength,
                            onStrength: (v) => notifier
                                .update((s) => s.copyWith(kickStrength: v)),
                          ),
                        ]
                        // —— 流星触发 ——
                        else if (section == _DrawerSection.meteor) ...[
                          ...triggerSection(
                            enabled: settings.meteorEnabled,
                            onEnabled: (v) => notifier
                                .update((s) => s.copyWith(meteorEnabled: v)),
                            mode: settings.meteorMode,
                            onMode: (m) => notifier
                                .update((s) => s.copyWith(meteorMode: m)),
                            sensitivity: settings.meteorSensitivity,
                            onSensitivity: (v) => notifier.update(
                                (s) => s.copyWith(meteorSensitivity: v)),
                            cooldown: settings.meteorCooldownFrames,
                            onCooldown: (v) => notifier.update(
                                (s) => s.copyWith(meteorCooldownFrames: v)),
                            strength: settings.meteorStrength,
                            onStrength: (v) => notifier
                                .update((s) => s.copyWith(meteorStrength: v)),
                          ),
                        ]
                        // —— 歌词设置 ——
                        else if (section == _DrawerSection.lyrics) ...[
                          const SizedBox(height: 8),
                          _segmentTabs(
                            labels: const ['经典', '弹跳', '3D空间'],
                            activeIndex: settings.lyricsMode.index,
                            onChanged: (i) => notifier.update((s) =>
                                s.copyWith(
                                    lyricsMode: LyricsMode.values[i])),
                          ),
                          _switchTile(
                            '显示歌词',
                            settings.lyricsShow,
                            (v) => notifier
                                .update((s) => s.copyWith(lyricsShow: v)),
                          ),
                          _sliderRow(
                            '活跃字号',
                            settings.lyricsActiveSize,
                            5,
                            40,
                            (v) => notifier.update(
                                (s) => s.copyWith(lyricsActiveSize: v)),
                            label:
                                settings.lyricsActiveSize.round().toString(),
                          ),
                          _sliderRow(
                            '非活跃字号',
                            settings.lyricsInactiveSize,
                            3,
                            30,
                            (v) => notifier.update(
                                (s) => s.copyWith(lyricsInactiveSize: v)),
                            label:
                                settings.lyricsInactiveSize.round().toString(),
                          ),
                          _sliderRow(
                            '每行最大字数',
                            settings.lyricsMaxChars.toDouble(),
                            4,
                            100,
                            (v) => notifier.update(
                                (s) =>
                                    s.copyWith(lyricsMaxChars: v.round().toDouble())),
                            label: '${settings.lyricsMaxChars.round()}',
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '字体颜色',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.55),
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              _colorSwatch(
                                0xFFFFFFFF,
                                selected: settings.lyricsColor == 0xFFFFFFFF,
                                onTap: () => notifier.update(
                                    (s) => s.copyWith(lyricsColor: 0xFFFFFFFF)),
                              ),
                              const SizedBox(width: 8),
                              for (final t in kVisThemes) ...[
                                _colorSwatch(
                                  t.main,
                                  selected: settings.lyricsColor == t.main,
                                  onTap: () => notifier.update(
                                      (s) => s.copyWith(lyricsColor: t.main)),
                                ),
                                const SizedBox(width: 8),
                              ],
                            ],
                          ),
                          _switchTile(
                            '卡拉OK颜色跟随主题',
                            settings.lyricsFollowTheme,
                            (v) => notifier.update(
                                (s) => s.copyWith(lyricsFollowTheme: v)),
                          ),
                          _segmentTabs(
                            labels: const ['Serif', 'Sans'],
                            activeIndex: settings.lyricsSerif ? 0 : 1,
                            onChanged: (i) => notifier
                                .update((s) => s.copyWith(lyricsSerif: i == 0)),
                          ),
                          _sliderRow(
                            '空间偏移',
                            settings.lyricsOffsetX,
                            -100,
                            100,
                            (v) => notifier
                                .update((s) => s.copyWith(lyricsOffsetX: v)),
                            label: settings.lyricsOffsetX.round().toString(),
                          ),
                        ]
                        // —— 播放栏 ——
                        else if (section == _DrawerSection.bar) ...[
                          _switchTile(
                            '自动隐藏播放栏',
                            settings.autoHideBar,
                            (v) => notifier
                                .update((s) => s.copyWith(autoHideBar: v)),
                          ),
                          hint('开启后 3 秒内无任何触摸自动隐藏，单击屏幕即可唤起。'),
                        ]
                        // —— 音频检测 ——
                        else if (section == _DrawerSection.detect) ...[
                          _sliderRow(
                            '节拍检测灵敏度',
                            settings.detectLevel,
                            0,
                            100,
                            (v) => notifier
                                .update((s) => s.copyWith(detectLevel: v)),
                            label: settings.detectLevel.round().toString(),
                          ),
                          hint('调整频谱采集的输入增益，过高可能削波失真。'),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
        ),
    );
  }

  // —— 小部件 ——

  /// 图标栏单元（对齐参考图：圆角方框描边高亮）。
  Widget _railIcon(int i,
      {required bool selected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 56,
        height: 50,
        alignment: Alignment.center,
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: selected
                ? Colors.white.withValues(alpha: 0.10)
                : Colors.transparent,
            border: Border.all(
              width: 1.4,
              color: selected
                  ? Colors.white.withValues(alpha: 0.85)
                  : Colors.transparent,
            ),
          ),
          child: Icon(
            _sectionIcons[i],
            size: 20,
            color: selected
                ? Colors.white
                : Colors.white.withValues(alpha: 0.45),
          ),
        ),
      ),
    );
  }

  Widget _namedSwatch(VisTheme t,
      {required bool selected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(t.main), Color(t.dim)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? Colors.white : Colors.white24,
                width: selected ? 2.5 : 1,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t.name,
            style: TextStyle(
              color: selected
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.55),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _colorSwatch(int argb,
      {required bool selected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: Color(argb),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.white : Colors.white24,
            width: selected ? 2.5 : 1,
          ),
        ),
      ),
    );
  }

  /// 地形均衡器单频段行：频段名 + On/Off 开关 + 0..100 滑杆。
  Widget _eqRow(
    VisualizerSettings settings,
    int index, {
    required ValueChanged<VisEqBand> onChanged,
  }) {
    final band = settings.groundEq[index];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 44,
                child: Text(kEqBandNames[index],
                    style: TextStyle(
                      color: band.on
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.4),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    )),
              ),
              SizedBox(
                width: 40,
                height: 26,
                child: Transform.scale(
                  scale: 0.72,
                  child: Switch(
                    value: band.on,
                    onChanged: (v) => onChanged(band.copyWith(on: v)),
                    activeThumbColor: Colors.white,
                    activeTrackColor: Colors.white24,
                    inactiveThumbColor: Colors.white30,
                    inactiveTrackColor: Colors.white12,
                  ),
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 2.5,
                    overlayShape: SliderComponentShape.noOverlay,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 5),
                    activeTrackColor: Colors.white.withValues(alpha: 0.85),
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.14),
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: band.value.clamp(0, 100),
                    min: 0,
                    max: 100,
                    onChanged: band.on ? (v) => onChanged(band.copyWith(value: v)) : null,
                  ),
                ),
              ),
              SizedBox(
                width: 30,
                child: Text(
                  band.value.round().toString(),
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _switchTile(String title, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(title,
          style: const TextStyle(color: Colors.white, fontSize: 14)),
      value: value,
      onChanged: onChanged,
      activeThumbColor: Colors.white,
    );
  }

  Widget _segmentTabs({
    required List<String> labels,
    required int activeIndex,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      children: [
        for (int i = 0; i < labels.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(i),
              child: Container(
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: i == activeIndex
                      ? Colors.white.withValues(alpha: 0.16)
                      : Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: i == activeIndex
                        ? Colors.white.withValues(alpha: 0.4)
                        : Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                child: Text(
                  labels[i],
                  style: TextStyle(
                    color: i == activeIndex
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.5),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _sliderRow(
    String title,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    required String label,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13.5)),
              Text(label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  )),
            ],
          ),
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 2.5,
              overlayShape: SliderComponentShape.noOverlay,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              activeTrackColor: Colors.white.withValues(alpha: 0.85),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.14),
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 数据源失败提示。
// ---------------------------------------------------------------------------

class _SourceFailHint extends StatelessWidget {
  final String text;
  final VoidCallback? onRetry;
  const _SourceFailHint({required this.text, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.info_outline_rounded,
              size: 16, color: Colors.white70),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 10),
            GestureDetector(
              onTap: onRetry,
              child: const Text('重试',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ],
      ),
    );
  }
}
