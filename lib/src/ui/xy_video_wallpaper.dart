import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// 支持作为动态壁纸的视频扩展名（全小写、带点）。
const Set<String> xyVideoWallpaperExtensions = <String>{
  '.mp4',
  '.m4v',
  '.mov',
  '.webm',
  '.mkv',
  '.avi',
  '.3gp',
  '.ts',
};

/// 判断壁纸路径是否为视频。
///
/// 只看扩展名：壁纸文件由设置页按扩展名白名单落盘（图片走 jpg/png/webp/
/// gif），不会出现「扩展名是图片实际是视频」的形态，因此无需读文件头。
bool xyIsVideoWallpaperPath(String path) {
  final trimmed = path.trim().toLowerCase();
  if (trimmed.isEmpty) return false;
  final dot = trimmed.lastIndexOf('.');
  if (dot < 0) return false;
  return xyVideoWallpaperExtensions.contains(trimmed.substring(dot));
}

/// 全局挂起闸门：视频壁纸让位给「独占播放的视频」（MV/短视频播放页）。
///
/// 自定义动态壁纸是常驻层：应用级背景、抽屉副本、播放详情页背景都引用同一
/// 条租约，MV 播放页又是另一路 ExoPlayer。两路同时解码时，一是在低端机上
/// 直接争抢硬件解码器（MV 默认 2160P，4K 解码实例本就紧张），二是背景纹理
/// 仍在逐帧更新、参与合成，表现就是 MV 画面周期性掉帧/闪烁。
///
/// 这里用引用计数表示「当前有 N 处视频正在独占播放」：计数 > 0 时所有视频
/// 壁纸引用方都会解除租约（释放解码器）并停止渲染纹理，计数归零后重新
/// 挂载恢复播放。
final ValueNotifier<int> _xyVideoWallpaperSuspenders = ValueNotifier<int>(0);

/// 当前是否有视频正在独占播放（此时视频壁纸应完全让位）。
bool get xyVideoWallpaperSuspended => _xyVideoWallpaperSuspenders.value > 0;

/// 单条视频壁纸播放租约。
///
/// 同一个路径在同一时刻只保留一个 [VideoPlayerController]：应用级背景、
/// 抽屉/侧栏复制的背景、设置页预览、播放详情页壁纸背景会同时引用同一
/// 个壁纸文件，各自 new 一个 controller 等于同时开 N 个 ExoPlayer 实例，
/// 在低端机上直接抢解码器并掉帧。多个 widget 复用同一个 Texture，额外
/// 绘制开销近似为零。
class _XyVideoLease {
  _XyVideoLease(this.path);

  final String path;

  /// controller 可能被「失活自愈」整体换掉，用 ValueNotifier 通知所有
  /// 引用方换源，而不是让它们各自持有一个会失效的旧引用。
  final ValueNotifier<VideoPlayerController?> controllerRef =
      ValueNotifier<VideoPlayerController?>(null);

  bool failed = false;
  int refs = 0;
  bool recovering = false;

  /// 尺寸探针：即便 controller 尚未 initialize 完成，也能先拿到视频比例，
  /// 避免首帧用 16:9 兜底造成一次跳变。
  Size? size;

  Future<void>? initializing;

  /// 各引用方的「暂停意图」（key 为挂载中的 State 实例）。
  ///
  /// 以前每个 widget 各自在生命周期回调里 pause/play，共享同一个
  /// controller 时后执行者说了算：只要任何一个处于 paused（例如播放详情页
  /// 转场 lite）的实例最后执行，就会把全局壁纸一起停住，而且没有任何
  /// 人再把它拉起来——这就是「切后台/息屏回来壁纸静止」的直接原因。
  /// 现在由 Host 汇总所有意图后统一决策。
  final Map<Object, bool> holders = <Object, bool>{};

  VideoPlayerController? get controller => controllerRef.value;

  bool get hasActiveHolder => holders.values.any((paused) => !paused);

  /// 初始化进行中标记：失败重试与首次初始化可能撞在一起，加锁避免同时
  /// 建出两个 ExoPlayer（低端机上会互相抢解码器）。
  bool initInFlight = false;

  /// 已尝试的初始化次数（含失败重试），用于限制重试上限。
  int initAttempts = 0;

  /// 上一次自愈重建的时刻：防止「构建失败 → 重建 → 再失败」死循环。
  DateTime? lastRecoverAt;
}

/// 刚被释放、仍在「短暂回收站」里的 controller。
class _RecycledVideo {
  _RecycledVideo(this.controller, this.size, this.timer);

  final VideoPlayerController controller;
  final Size? size;
  final Timer timer;
}

class _XyVideoWallpaperHost with WidgetsBindingObserver {
  _XyVideoWallpaperHost._();

  static final _XyVideoWallpaperHost instance = _XyVideoWallpaperHost._();

  final Map<String, _XyVideoLease> _leases = <String, _XyVideoLease>{};

  /// 单条租约的初始化重试总上限：超过就放弃自愈，由上层底色兜底，
  /// 避免为了一个坏文件无限建解码器把电耗光。
  static const int _maxInitAttempts = 8;

  /// 短暂回收站：release 后 1.2s 内同路径再被引用就复用，见 [acquire]。
  final Map<String, _RecycledVideo> _recycled = <String, _RecycledVideo>{};

  bool _observing = false;
  bool _suspendHooked = false;
  bool _background = false;

  /// 上一次收到的生命周期状态：用于识别「resumed → resumed」的重复回调，
  /// 不能再用 [_background] 当闸门（部分 ROM 息屏只发 inactive）。
  AppLifecycleState? _lastState;

  /// 离开前台的时刻：从第一次收到非 resumed 状态开始计时，直到重新
  /// resumed 才清零。用它判断这次离开是否久到足以让系统回收纹理。
  DateTime? _awaySince;

  static bool _isBackground(AppLifecycleState? state) =>
      state != null &&
      state != AppLifecycleState.resumed &&
      state != AppLifecycleState.inactive;

  void _ensureObserver() {
    if (!_suspendHooked) {
      _suspendHooked = true;
      _xyVideoWallpaperSuspenders.addListener(_onSuspendChanged);
    }
    if (_observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
    _lastState = WidgetsBinding.instance.lifecycleState;
    _background = _isBackground(_lastState);
  }

  /// 独占播放开始/结束时同步全部租约。
  ///
  /// 开始独占：[applyIntent] 会因挂起而保持暂停（此时引用方通常已经解除
  /// 租约，走不到这里，留作重复挂载时的兜底）。
  /// 结束独占：逐条探测 controller 是否还活着，纹理已被系统回收的先重建，
  /// 再按意图复播——否则「MV 播完退回详情页，动态背景再也不动」。
  void _onSuspendChanged() {
    final suspended = xyVideoWallpaperSuspended;
    for (final lease in _leases.values.toList()) {
      if (!suspended) {
        final controller = lease.controller;
        if (controller == null ||
            !controller.value.isInitialized ||
            controller.value.hasError) {
          recoverIfBroken(lease);
          continue;
        }
      }
      applyIntent(lease);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final prev = _lastState;
    _lastState = state;
    if (state != AppLifecycleState.resumed) _awaySince ??= DateTime.now();
    final background = _isBackground(state);
    if (background) {
      if (_background) return;
      _background = true;
      for (final lease in _leases.values.toList()) {
        final controller = lease.controller;
        if (controller == null) continue;
        if (controller.value.isPlaying) controller.pause().catchError((_) {});
      }
      return;
    }
    // 回到前台：先按意图复播，再延迟探测是否真的在推进。ExoPlayer 在
    // 息屏/后台窗口结束后常常出现「isPlaying 为 true 但 position 不动」
    // 或 SurfaceTexture 已被系统回收（画面消失/全黑）的僵死态。
    //
    // 旧实现用「_background 为 true」当闸门，隐含假设息屏一定会走
    // paused/hidden。但部分 ROM（含澎湃 OS）息屏只发 inactive，闸门
    // 一直为 false，回到 resumed 时整段恢复逻辑被直接跳过——不再 pause
    // 也不再 play，更不会重建失效的纹理，用户看到的就是「息屏后再打开
    // 壁纸不见了/定住不动」。这里改为只在「resumed → resumed」的重复
    // 回调时才跳过，其余情况一律走一次恢复。
    final repeating = prev == AppLifecycleState.resumed &&
        state == AppLifecycleState.resumed;
    _background = false;
    if (repeating) return;
    final awayMs = _awaySince == null
        ? 0
        : DateTime.now().difference(_awaySince!).inMilliseconds;
    _awaySince = null;
    // 真正在后台/息屏停留超过 2s：系统有机会回收 SurfaceTexture，靠
    // play() 复活不了画面，直接整条重建（重新 initialize 会拿到新纹理）。
    final needRebuild = awayMs > 2000;
    for (final lease in _leases.values.toList()) {
      // 回到前台等于一次全新机会：清掉重试计数，之前放弃过的自愈重新可用。
      lease.initAttempts = 0;
      lease.lastRecoverAt = null;
      applyIntent(lease);
      _scheduleRecovery(lease, forceRebuild: needRebuild);
    }
  }

  /// 已就绪（或正在初始化）的租约，引用计数 +1。
  _XyVideoLease acquire(String path) {
    _ensureObserver();
    final existing = _leases[path];
    if (existing != null) {
      existing.refs++;
      return existing;
    }
    // 短暂回收站命中：系统在息屏/配置变更后重建整棵 widget 树时，同一帧
    // 内会先 release 再 acquire。如果这时老老实实 dispose + initialize，
    // 用户看到的就是一段空白，且重建期的解码器争抢正是 initialize 失败
    // （进而壁纸彻底不回来）的高发时机。这里直接复用刚释放的 controller。
    final recyclable = _recycled.remove(path);
    if (recyclable != null) {
      recyclable.timer.cancel();
      final controller = recyclable.controller;
      // 视频独占播放期间不复用：这条 controller 还占着解码器，正好借这次
      // 切换把它彻底交还系统，让位结束后再重建。
      if (!xyVideoWallpaperSuspended &&
          controller.value.isInitialized &&
          !controller.value.hasError) {
        final lease = _XyVideoLease(path)..refs = 1;
        lease.size = recyclable.size;
        _leases[path] = lease;
        lease.controllerRef.value = controller;
        return lease;
      }
      controller.pause().catchError((_) {}).whenComplete(() {
        controller.dispose().catchError((_) {});
      });
    }
    final lease = _XyVideoLease(path)..refs = 1;
    _leases[path] = lease;
    // 让位期间不建解码器：MV 正在用硬件解码，此时 initialize 只会抢不到
    // 并拖慢 MV 首帧。等让位结束由 Host 统一重建（见 _onSuspendChanged）。
    if (xyVideoWallpaperSuspended) return lease;
    lease.initializing = _initialize(lease);
    return lease;
  }

  /// 引用计数 -1，归零即释放 controller 与租约。
  ///
  /// [immediate] 为 true 时跳过「短暂回收站」直接销毁：视频独占播放（MV）
  /// 期间必须真正把解码器还回去，留着 controller 只是不播、codec 照样占着。
  void release(_XyVideoLease lease, {bool immediate = false}) {
    lease.refs--;
    if (lease.refs > 0) return;
    if (_leases[lease.path] == lease) _leases.remove(lease.path);
    final controller = lease.controller;
    lease.controllerRef.value = null;
    if (controller == null) return;
    final size = lease.size;
    controller.pause().catchError((_) {});
    if (immediate) {
      controller.dispose().catchError((_) {});
      return;
    }
    // 先进回收站，1.2s 内同路径再被引用（widget 树重建、页面切换回退）
    // 就直接复用，避免重新 initialize 造成空白与解码器抖动。
    final timer = Timer(const Duration(milliseconds: 1200), () {
      final entry = _recycled.remove(lease.path);
      if (entry == null || !identical(entry.controller, controller)) return;
      // 先停再释放：部分机型 await dispose 期间仍会回调已销毁的纹理。
      controller.dispose().catchError((_) {});
    });
    _recycled[lease.path] = _RecycledVideo(controller, size, timer);
  }

  /// 汇总所有引用方的意图后决定播放态。
  void applyIntent(_XyVideoLease lease) {
    final controller = lease.controller;
    if (controller == null) return;
    if (lease.recovering) return;
    if (_background || xyVideoWallpaperSuspended || !lease.hasActiveHolder) {
      if (controller.value.isPlaying) controller.pause().catchError((_) {});
      return;
    }
    if (!controller.value.isPlaying) controller.play().catchError((_) {});
  }

  /// 由 widget 侧发现 controller 报错/未初始化时调用，触发一次重建。
  void recoverIfBroken(_XyVideoLease lease) {
    // 视频独占播放期间不重建：新建解码器正是要和 MV 抢 codec 的那一刻。
    if (xyVideoWallpaperSuspended) return;
    if (_background || lease.recovering || lease.initInFlight) return;
    if (lease.initAttempts >= _maxInitAttempts) return;
    final now = DateTime.now();
    final last = lease.lastRecoverAt;
    if (last != null && now.difference(last).inMilliseconds < 3000) return;
    lease.lastRecoverAt = now;
    final controller = lease.controller;
    if (controller != null &&
        controller.value.isInitialized &&
        !controller.value.hasError) {
      return;
    }
    unawaited(_rebuild(lease));
  }

  Future<void> _initialize(_XyVideoLease lease) async {
    if (lease.initInFlight) return;
    lease.initInFlight = true;
    VideoPlayerController? controller;
    var failed = false;
    try {
      final file = File(lease.path);
      if (!await file.exists()) {
        lease.failed = true;
        return;
      }
      controller = VideoPlayerController.file(file);
      await controller.setVolume(0);
      await controller.setLooping(true);
      await controller.initialize();
      // initialize 返回后仍校验一次：解封装失败时 initialize 也可能正常
      // 返回但尺寸为 0（仅音频轨/损坏文件），此时按失败回退静态背景。
      final size = controller.value.size;
      if (!controller.value.isInitialized ||
          size.width <= 0 ||
          size.height <= 0) {
        failed = true;
        await controller.dispose();
        return;
      }
      lease.size = size;
      lease.initAttempts = 0;
      lease.failed = false;
      lease.controllerRef.value = controller;
      applyIntent(lease);
    } catch (_) {
      failed = true;
      if (controller != null) {
        controller.dispose().catchError((_) {});
      }
    } finally {
      lease.initInFlight = false;
      if (failed) _scheduleInitRetry(lease);
    }
  }

  /// 初始化失败重试。
  ///
  /// 息屏解锁、系统刚回收过解码器、文件所在存储暂不可用等场景下，
  /// 第一次 initialize 失败并不代表视频真的坏了。旧实现失败后直接置
  /// failed 且再没有任何重试入口（controller 为 null 时 build 只返回空
  /// 占位，也不会触发 [recoverIfBroken]），用户视角就是「息屏后再打开
  /// 动态壁纸彻底不见了，怎么点都不回来」。
  void _scheduleInitRetry(_XyVideoLease lease) {
    if (_leases[lease.path] != lease) return;
    if (lease.initAttempts >= _maxInitAttempts) {
      lease.failed = true;
      return;
    }
    lease.initAttempts++;
    final delay = Duration(milliseconds: 500 * lease.initAttempts);
    Timer(delay, () {
      if (_leases[lease.path] != lease) return;
      // 让位期间不重试：等 Host 在让位结束时统一重建。
      if (xyVideoWallpaperSuspended) return;
      if (lease.controller != null || lease.initInFlight) return;
      lease.failed = false;
      unawaited(_initialize(lease));
    });
  }

  /// 回前台自愈：正常情况下先复播，再探测位置是否真的推进，没推进就
  /// 整条重建；[forceRebuild] 为 true 时跳过探测直接重建（后台/息屏停留
  /// 较久，SurfaceTexture 大概率已被系统回收，画面即使「在推进」也是
  /// 黑的/空的，必须拿一条新纹理）。
  void _scheduleRecovery(
    _XyVideoLease lease, {
    bool forceRebuild = false,
  }) {
    Timer(const Duration(milliseconds: 700), () async {
      if (_leases[lease.path] != lease) return;
      if (_background) return;
      // 让位期间不重建：MV 正在用解码器，重建会直接抢不到。
      if (xyVideoWallpaperSuspended) return;
      if (lease.recovering) return;
      final controller = lease.controller;
      if (forceRebuild || controller == null) {
        await _rebuild(lease);
        return;
      }
      if (!controller.value.isInitialized ||
          controller.value.hasError ||
          controller.value.size.width <= 0) {
        await _rebuild(lease);
        return;
      }
      if (!lease.hasActiveHolder) return;
      final before = controller.value.position;
      await controller.play().catchError((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (_leases[lease.path] != lease || _background) return;
      final current = lease.controller;
      if (current == null) return;
      final advancedMs =
          (current.value.position - before).inMilliseconds.abs();
      if (!current.value.isPlaying || advancedMs < 120) {
        await _rebuild(lease);
      }
    });
  }

  Future<void> _rebuild(_XyVideoLease lease) async {
    if (lease.recovering) return;
    if (_leases[lease.path] != lease) return;
    lease.recovering = true;
    var failed = false;
    final old = lease.controller;
    lease.controllerRef.value = null;
    if (old != null) {
      old.pause().catchError((_) {}).whenComplete(() {
        old.dispose().catchError((_) {});
      });
    }
    try {
      final file = File(lease.path);
      if (!await file.exists()) {
        failed = true;
        return;
      }
      final controller = VideoPlayerController.file(file);
      await controller.setVolume(0);
      await controller.setLooping(true);
      await controller.initialize();
      final size = controller.value.size;
      if (!controller.value.isInitialized ||
          size.width <= 0 ||
          size.height <= 0) {
        await controller.dispose().catchError((_) {});
        failed = true;
        return;
      }
      lease.size = size;
      lease.initAttempts = 0;
      lease.failed = false;
      lease.recovering = false;
      lease.controllerRef.value = controller;
      applyIntent(lease);
    } catch (_) {
      failed = true;
    } finally {
      lease.recovering = false;
      // 重建失败同样走初始化重试：否则 controller 会一直为 null，
      // build 只返回空占位、也不会再触发自愈，壁纸就永久消失了。
      if (failed && lease.controller == null) _scheduleInitRetry(lease);
    }
  }
}

/// 视频壁纸让位作用域：子树挂载期间，所有视频壁纸挂起并释放解码器。
///
/// 用于 MV/短视频播放页——那里本身就是一张全屏黑底 + 一路视频，背景动态
/// 壁纸既不可见、又会和它抢硬件解码器（表现为 MV 画面闪烁掉帧），必须
/// 完全隔开。引用计数支持嵌套/并存多个作用域，最后一个销毁才恢复。
class XyVideoWallpaperSuspendScope extends StatefulWidget {
  const XyVideoWallpaperSuspendScope({super.key, required this.child});

  final Widget child;

  @override
  State<XyVideoWallpaperSuspendScope> createState() =>
      _XyVideoWallpaperSuspendScopeState();
}

class _XyVideoWallpaperSuspendScopeState
    extends State<XyVideoWallpaperSuspendScope> {
  @override
  void initState() {
    super.initState();
    _xyVideoWallpaperSuspenders.value++;
  }

  @override
  void dispose() {
    final next = _xyVideoWallpaperSuspenders.value - 1;
    _xyVideoWallpaperSuspenders.value = next < 0 ? 0 : next;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 视频壁纸过采样倍率。
///
/// 视频纹理的宽/高通常会被硬件解码器按 16 像素对齐，右侧与底部多出来的
/// 填充列在个别机型上会被解成半透明的绿/彩色像素。壁纸铺满屏幕后，
/// 这列填充刚好落在屏幕最右侧，表现为一条紧贴边缘的竖直细窄绿边。
///
/// 另外两条来源会让「细边」更明显：纹理在 Skia 里按浮点尺寸绘制时边缘
/// 带抗锯齿，最外 1 像素天然半透明；[FittedBox] 按容器比例换算后右边缘
/// 可能落在半像素上。两者叠加后，右侧就会透出下层（模糊层/底色），
/// 看上去就是一条「暗色半透明、内容隐约可见」的竖条。
///
/// 取 4%：16 像素对齐最多让纹理比内容宽约 2%（720p 视频 15/720），
/// 每侧裁 2% 刚好覆盖；仅做绘制变换、不改变布局，因此
/// [BoxFit.cover] 与 [BoxFit.fill] 两种显示方式都仍然铺满屏幕宽度。
const double _kVideoWallpaperOverscan = 1.04;

/// 视频壁纸层：无限循环、静音，按 [fit] 铺满（默认等比裁剪）。
///
/// 未就绪或解码失败时返回空占位，由上层底色兜底——壁纸属于纯装饰层，
/// 不允许因为一个损坏的视频把整页刷成黑屏。
class XyVideoWallpaper extends StatefulWidget {
  const XyVideoWallpaper({
    super.key,
    required this.path,
    this.paused = false,
    this.fit = BoxFit.cover,
  });

  final String path;

  /// 暂停播放（保留最后一帧）：转场/形变期间用它降负载。
  final bool paused;

  /// 铺放方式：居中裁剪（[BoxFit.cover]）或完全铺满（[BoxFit.fill]）。
  final BoxFit fit;

  @override
  State<XyVideoWallpaper> createState() => _XyVideoWallpaperState();
}

class _XyVideoWallpaperState extends State<XyVideoWallpaper> {
  _XyVideoLease? _lease;

  /// 当前是否处于「视频独占播放」让位态（MV/短视频正在播放）。
  bool _suspended = false;

  @override
  void initState() {
    super.initState();
    _suspended = xyVideoWallpaperSuspended;
    _xyVideoWallpaperSuspenders.addListener(_onSuspendChanged);
    // 让位期间不挂载：连解码器都不建，MV 独占硬件解码。
    if (!_suspended) _attach();
  }

  @override
  void didUpdateWidget(XyVideoWallpaper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _detach();
      if (!_suspended) _attach();
      return;
    }
    if (oldWidget.paused != widget.paused) {
      final lease = _lease;
      if (lease != null) {
        lease.holders[this] = widget.paused;
        _XyVideoWallpaperHost.instance.applyIntent(lease);
      }
    }
  }

  @override
  void dispose() {
    _xyVideoWallpaperSuspenders.removeListener(_onSuspendChanged);
    _detach();
    super.dispose();
  }

  /// 让位开始：解除租约并立即销毁解码器（不进回收站）。
  /// 让位结束：重新挂载，纹理会被重新创建。
  void _onSuspendChanged() {
    final suspended = xyVideoWallpaperSuspended;
    if (suspended == _suspended) return;
    _suspended = suspended;
    if (suspended) {
      _detach();
    } else {
      _attach();
    }
    if (mounted) setState(() {});
  }

  void _attach() {
    if (!xyIsVideoWallpaperPath(widget.path)) return;
    final lease = _XyVideoWallpaperHost.instance.acquire(widget.path);
    _lease = lease;
    // 生命周期不再由每个 widget 各自监听（多个 observer 互相覆盖状态），
    // 统一由 Host 汇总处理；这里只登记本引用方的暂停意图。
    lease.holders[this] = widget.paused;
    _XyVideoWallpaperHost.instance.applyIntent(lease);
  }

  void _detach() {
    final lease = _lease;
    _lease = null;
    if (lease == null) return;
    lease.holders.remove(this);
    _XyVideoWallpaperHost.instance.applyIntent(lease);
    // 让位期间立即销毁：pause 之后的 controller 仍占着硬件解码器，
    // 不真正释放的话 MV 依旧要跟它抢。
    _XyVideoWallpaperHost.instance.release(
      lease,
      immediate: xyVideoWallpaperSuspended,
    );
  }

  @override
  Widget build(BuildContext context) {
    final lease = _lease;
    if (lease == null) return const SizedBox.expand();
    return ValueListenableBuilder<VideoPlayerController?>(
      valueListenable: lease.controllerRef,
      builder: (context, controller, _) {
        final size = lease.size;
        if (controller == null || size == null) {
          // 初始化彻底失败（息屏解锁瞬间解码器被占、存储短暂不可用等）
          // 时也补一次自愈；初始化进行中会被 recoverIfBroken 里的
          // initInFlight 拦掉，不会重复建 controller。
          if (lease.failed) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _XyVideoWallpaperHost.instance.recoverIfBroken(lease);
            });
          }
          return const SizedBox.expand();
        }
        final value = controller.value;
        if (!value.isInitialized || value.hasError) {
          // 报错（典型是息屏/后台窗口结束后 surface 解绑）时主动重建，
          // 否则 ExoPlayer 会一直往一个已失效的 surface 上画，表现为
          // 「壁纸静止不动」甚至「壁纸消失」。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _XyVideoWallpaperHost.instance.recoverIfBroken(lease);
          });
          return const SizedBox.expand();
        }
        return IgnorePointer(
          child: ClipRect(
            child: Transform.scale(
              scale: _kVideoWallpaperOverscan,
              child: SizedBox.expand(
                child: FittedBox(
                  fit: widget.fit,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: size.width,
                    height: size.height,
                    child: VideoPlayer(controller),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
