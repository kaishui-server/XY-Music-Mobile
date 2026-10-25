import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../../pages/player/player_page.dart';
import '../core/settings.dart';
import '../lyrics/lyrics_models.dart';
import '../player/player_provider.dart';
import '../player/video_playback_session.dart';
import '../ui/xy_theme.dart';
import 'cover_image.dart';
import 'queue_sheet.dart';

double safeMiniPlayerProgress(double position, double duration) {
  if (!position.isFinite || !duration.isFinite || duration <= 0) return 0;
  return (position / duration).clamp(0.0, 1.0);
}

/// 电脑端 PlayerFooter 的手机化版本。
///
/// 底部播放栏支持「按住从下向上拖动」展开：拖动过程中全屏播放页窗口
/// 从播放栏矩形放大到全屏（播放栏放大式转场），背景色随进度渐变切换、
/// 播放栏文案按钮快速淡出、封面从迷你尺寸放大上浮、详情页文字约半程
/// 渐显；松手超过阈值或快速上滑时吸附展开（补完动画后切入真实播放页
/// 路由），否则回弹收起。
class MiniPlayerBar extends ConsumerStatefulWidget {
  const MiniPlayerBar({super.key});

  @override
  ConsumerState<MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends ConsumerState<MiniPlayerBar>
    with TickerProviderStateMixin {
  /// 迷你封面的定位锚点（拖动预览时封面放大层的起点）。
  final GlobalKey _coverKey = GlobalKey();

  /// 播放栏自身定位锚点：读取播放栏顶部全局 Y，作为预览页初始位置。
  final GlobalKey _barKey = GlobalKey();

  /// 预览页封面占位锚点：读取真实封面最终矩形，放大层目标与之对齐，
  /// 路由页接管时无缝衔接。
  final GlobalKey _coverAnchorKey = GlobalKey();

  /// 预览页（PlayerPage）根锚点：读取封面占位的「页面布局坐标」。
  /// 预览页被窗口放大的 Transform 压缩绘制，localToGlobal 会把该变换
  /// 计入导致终点矩形被压到屏底；以页面根为 ancestor 取局部坐标可
  /// 排除 Transform 影响，页面全屏铺满且进度 1 时布局坐标即屏幕坐标。
  final GlobalKey _pageKey = GlobalKey();

  /// 拖动起始时播放栏顶部的全局 Y（进度 0 时预览页顶部位置）。
  double? _barTopY;

  /// 预览页封面占位的最终矩形（放大层目标，进度 1 时与之重合）。
  Rect? _targetCoverRect;

  /// 拖动预览层（root Overlay）：拖动中/吸附/回弹期间持有，结束后移除。
  OverlayEntry? _entry;

  /// 拖动进度控制器：拖动中直接赋值 value 跟随手指，吸附/回弹走动画。
  AnimationController? _controller;

  /// 拖动起始时的全局 Y 坐标。
  double? _dragStartDy;

  /// 松手后已提交展开/回弹判定：动画期间不再响应新的拖拽/点击。
  bool _committed = false;

  /// 展开补完后延迟移除预览层，给路由转场（在预览层之下进行）留出时间。
  Timer? _swapTimer;

  @override
  void dispose() {
    _swapTimer?.cancel();
    _removeEntry();
    _controller?.dispose();
    super.dispose();
  }

  void _removeEntry() {
    _entry?.remove();
    _entry = null;
  }

  void _resetDrag() {
    _dragStartDy = null;
    _committed = false;
    _barTopY = null;
    _targetCoverRect = null;
    _controller?.dispose();
    _controller = null;
  }

  void _onDragStart(DragStartDetails details) {
    final current = ref.read(playerProvider).current;
    if (current == null) return;
    // 已有预览层（上次动画未收尾）或正在动画时忽略新拖拽。
    if (_entry != null || _controller?.isAnimating == true || _committed) {
      return;
    }
    _dragStartDy = details.globalPosition.dy;
    _committed = false;
    _barTopY = null;
    _targetCoverRect = null;
    // 播放栏顶部全局 Y：进度 0 时窗口初始矩形（播放栏矩形）的顶边。
    final barBox = _barKey.currentContext?.findRenderObject() as RenderBox?;
    if (barBox != null && barBox.attached && barBox.hasSize) {
      final origin = barBox.localToGlobal(Offset.zero);
      _barTopY = origin.dy;
    }
    _controller?.dispose();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: 0,
    );
    _entry = OverlayEntry(
      builder: (ctx) => _buildExpandLayer(ctx),
      maintainState: false,
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
    // 首帧后读取预览页封面占位的全局矩形（页面布局坐标不受 translate
    // 影响，进度 1 时即真实路由页封面位置），作为放大层最终目标。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _entry == null) return;
      final ctx = _coverAnchorKey.currentContext;
      if (ctx == null) return;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) return;
      // 关键：预览页被窗口放大 Transform（translate + scaleY）压缩绘制，
      // 直接 localToGlobal 会把该绘制变换计入，首帧（进度 0）时窗口仅为
      // 播放栏高度，返回的“全局矩形”被压扁并落到屏幕下方（封面跑到屏
      // 底的根因）。以预览页根为 ancestor 只计算页面内布局坐标，页面
      // 全屏铺满且进度 1 时布局坐标即屏幕坐标，终点精确落在详情页封面。
      final pageBox = _pageKey.currentContext?.findRenderObject() as RenderBox?;
      if (pageBox == null || !pageBox.attached || !pageBox.hasSize) return;
      final origin = box.localToGlobal(Offset.zero, ancestor: pageBox);
      _targetCoverRect = Rect.fromLTWH(
        origin.dx,
        origin.dy,
        box.size.width,
        box.size.height,
      );
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final startDy = _dragStartDy;
    if (startDy == null || _entry == null || _committed) return;
    final controller = _controller;
    if (controller == null) return;
    // 向上位移 >0：拖动距离 / 屏幕高度 * 0.85 作为展开进度。
    final dy = startDy - details.globalPosition.dy;
    if (dy <= 0) return;
    final screenH = MediaQuery.sizeOf(context).height;
    final progress = (dy / (screenH * .85)).clamp(0.0, 1.0);
    controller.value = progress;
  }

  void _onDragEnd(DragEndDetails details) {
    if (_entry == null || _committed) return;
    _dragStartDy = null;
    final controller = _controller;
    if (controller == null) return;
    final velocity = details.primaryVelocity ?? 0;
    // 阈值判定：快速上滑（沿用旧手势的 -180）或拖过 55% 即吸附展开。
    final expand = velocity < -180 || controller.value >= .55;
    _committed = true;
    unawaited(_settle(expand));
  }

  void _onDragCancel() {
    if (_entry == null || _committed) return;
    _dragStartDy = null;
    _committed = true;
    unawaited(_settle(false));
  }

  /// 松手后的吸附展开 / 回弹收起动画。
  Future<void> _settle(bool expand) async {
    final controller = _controller;
    if (controller == null) return;
    if (expand) {
      await controller.animateTo(
        1.0,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
      if (!mounted) return;
      // 补完到顶后立即 push 真实播放页：路由转场在预览层之下完成，
      // 随后移除预览层，实现「页面已完整呈现」的无缝衔接。
      context.push('/player');
      _swapTimer?.cancel();
      _swapTimer = Timer(const Duration(milliseconds: 400), () {
        if (!mounted) return;
        _removeEntry();
        _resetDrag();
      });
    } else {
      await controller.animateTo(
        0.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      if (!mounted) return;
      _removeEntry();
      _resetDrag();
    }
  }

  /// 迷你封面当前的屏幕位置（放大层起点）。
  Rect? _miniCoverRect() {
    final ctx = _coverKey.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    final origin = box.localToGlobal(Offset.zero);
    return Rect.fromLTWH(origin.dx, origin.dy, box.size.width, box.size.height);
  }

  /// 播放栏当前的屏幕矩形（窗口放大式转场的初始矩形）。
  Rect? _barRect() {
    final ctx = _barKey.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    final origin = box.localToGlobal(Offset.zero);
    return Rect.fromLTWH(origin.dx, origin.dy, box.size.width, box.size.height);
  }

  /// 播放栏克隆层：与真实底栏同款布局（封面/文案/按钮/进度条），
  /// 仅在拖动早期呈现底栏原貌并随进度快速淡出，避免窗口尚未渐显时
  /// 底栏视觉突然消失。内容为静态快照，动画帧只更新外层透明度。
  Widget? _buildBarGhost(BuildContext context) {
    final current = ref.read(playerProvider).current;
    if (current == null) return null;
    final player = ref.read(playerProvider);
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final video = VideoPlaybackSession.isFor(current.path)
        ? VideoPlaybackSession.controller
        : null;
    final isPlaying = video?.value.isPlaying ?? player.isPlaying;
    // 克隆层位于 root Overlay 的 OverlayEntry 中：该上下文没有页面级
    // Material 提供的 DefaultTextStyle，标题 Text（无显式 color）会落入
    // DefaultTextStyle.fallback（空 TextStyle），颜色失去主题继承而产生
    // 与正常播放栏不一致的异常样式。外层补透明 Material，使克隆层文本
    // 与真实底栏同享 bodyMedium/onSurface 等默认样式，保持视觉一致。
    return Material(
      type: MaterialType.transparency,
      child: ClipRRect(
      borderRadius: BorderRadius.circular(32),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(
            alpha: dark ? .34 : .48,
          ),
          borderRadius: BorderRadius.circular(32),
          border: Border.all(
            color: dark ? XyColors.darkBorder : XyColors.lightBorder,
          ),
        ),
        child: Stack(
          children: [
            Row(
              children: [
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: SizedBox(
                    width: 50,
                    height: 50,
                    child: CoverImage(
                      key: ValueKey('ghost:${current.path}'),
                      songPath: current.path,
                      imageUrl: current.coverUrl,
                      width: 50,
                      height: 50,
                      radius: 25,
                      icon: Icons.music_note_rounded,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        current.artist.isEmpty
                            ? current.title
                            : '${current.title} - ${current.artist}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      if (player.errorMessage != null)
                        Text(
                          player.errorMessage!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.error,
                          ),
                        )
                      else
                        RepaintBoundary(child: _MiniBarLyrics(item: current)),
                    ],
                  ),
                ),
                _PlayerButton(
                  primary: true,
                  icon: player.isLoading
                      ? Icons.hourglass_top_rounded
                      : isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  label: player.isLoading
                      ? '加载中'
                      : isPlaying
                      ? '暂停'
                      : '播放',
                  onTap: () {},
                ),
                _PlayerButton(
                  icon: Icons.queue_music_rounded,
                  label: '播放队列',
                  onTap: () {},
                ),
                const SizedBox(width: 3),
              ],
            ),
            Align(
              alignment: Alignment.bottomLeft,
              child: RepaintBoundary(
                child: _MiniPlayerProgress(
                  position: player.position,
                  duration: player.duration,
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  /// 拖动预览层：播放栏放大式转场。
  ///
  /// 进度 0 → 窗口恰为播放栏矩形，背景为播放栏底色、克隆底栏展示原貌
  /// （文案/按钮随进度快速淡出）、封面由独立放大层呈现；进度 1 → 窗口
  /// 放大铺满全屏、背景渐变到详情页底色、详情页文字渐显完毕。全程窗口
  /// 矩形由播放栏矩形 Rect.lerp 放大而来（内容随之纵向拉伸），不再是
  /// 页面从底部滑入。
  Widget _buildExpandLayer(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final viewport = MediaQuery.sizeOf(context);
    // 全屏播放页预览作为 child 只构建一次，动画帧仅更新外层变换、透明度
    // 与封面层，避免拖动过程中整页（毛玻璃/歌词/列表）逐帧重建造成掉帧。
    // 预览页隐藏自带封面（封面由放大层持续提供），并挂封面占位锚点
    // 供读取最终封面矩形，与真实路由页无缝衔接。
    final page = RepaintBoundary(
      key: _pageKey,
      child: IgnorePointer(
        child: PlayerPage(coverHidden: true, coverAnchorKey: _coverAnchorKey),
      ),
    );
    // 播放栏克隆层：拖动早期展示底栏原貌，随进度快速淡出。
    final ghost = _buildBarGhost(context);
    // 播放栏实际矩形：窗口放大的初始矩形（读不到时退回底部条带估算）。
    final barRect =
        _barRect() ??
        Rect.fromLTWH(
          0,
          _barTopY ?? viewport.height - 64,
          viewport.width,
          viewport.height - (_barTopY ?? viewport.height - 64),
        );
    final fullRect = Rect.fromLTWH(0, 0, viewport.width, viewport.height);
    return AnimatedBuilder(
      animation: controller,
      child: page,
      builder: (context, child) {
        final progress = controller.value;
        // ① 背景色渐变：播放栏底色 → 详情页底色，随进度实时过渡。
        final bg = Color.lerp(
          theme.colorScheme.surface.withValues(alpha: dark ? .34 : .48),
          theme.colorScheme.surface,
          progress,
        )!;
        // ② 播放栏文案/按钮快速淡出：拖动早期（~35%）内完成。
        final ghostOpacity = (1 - (progress / .35)).clamp(0.0, 1.0);
        // ⑤ 详情页文字渐显：约一半进度开始，随进度线性显影。
        final pageOpacity = ((progress - .5) / .5).clamp(0.0, 1.0);
        // 封面当前位置：迷你封面起点 → 详情页封面占位终点（与封面放大
        // 层同一 eased 曲线），作为窗口联动的基准，保证窗口与封面同步。
        final startCover =
            _miniCoverRect() ??
            Rect.fromLTWH(
              12,
              _barTopY ?? viewport.height - 64,
              48,
              48,
            );
        final targetCover =
            _targetCoverRect ??
            () {
              final side = math.min(
                420.0,
                math.min(viewport.width * .8, viewport.height - 160),
              );
              return Rect.fromCenter(
                center: Offset(viewport.width / 2, viewport.height * .44),
                width: side,
                height: side,
              );
            }();
        final eased = Curves.easeOutCubic.transform(progress);
        final coverRect = Rect.lerp(startCover, targetCover, eased)!;
        // ④ 窗口矩形（与封面联动）：详情页预览以圆角卡片形式浮现在封面
        // 正上方，底部距封面顶部固定小间距，封面上浮时窗口同步上浮；高度
        // 从播放栏高随进度增长（不超过封面顶上方，避免顶部越出屏外）。
        // 临近进度 1 时窗口平滑铺满全屏（间距自然放开），与真实路由页
        // 无缝衔接。
        const gap = 12.0;
        final cardHeight = math.min(
          64.0 + (viewport.height - 64.0) * eased,
          math.max(0.0, coverRect.top - gap),
        );
        final cardRect = Rect.fromLTWH(
          0,
          coverRect.top - gap - cardHeight,
          viewport.width,
          cardHeight,
        );
        final tailBlend = Curves.easeInOut.transform(
          ((progress - .72) / .28).clamp(0.0, 1.0),
        );
        final winRect = Rect.lerp(cardRect, fullRect, tailBlend)!;
        // 内容纵向缩放：窗口高 / 屏高（宽度方向窗口始终全宽）。
        final scaleY = winRect.height / viewport.height;
        // 窗口圆角：拖动中保持圆角卡片观感，随铺满全屏渐变为 0，
        // 匹配真实路由页直角页面，避免切换跳变。
        final radius = 32.0 * (1 - tailBlend);
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: bg),
            if (ghost != null)
              Positioned.fromRect(
                rect: barRect,
                child: Opacity(opacity: ghostOpacity, child: ghost),
              ),
            // 窗口卡片层：ClipRRect 圆角裁剪，页面内容随窗口矩形纵向拉伸
            // 放大，顶部对齐窗口顶边；文字层由 pageOpacity 控制约半程渐显。
            ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: Opacity(
                opacity: pageOpacity,
                child: Transform(
                  transform:
                      Matrix4.translationValues(0, winRect.top, 0) *
                      Matrix4.diagonal3Values(1.0, scaleY, 1.0),
                  alignment: Alignment.topLeft,
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            ),
            // ③ 封面放大层：从迷你封面位置放大上浮到详情页封面位置。
            if (progress > .01)
              _buildCoverLayer(context, progress, coverRect: coverRect),
          ],
        );
      },
    );
  }

  Widget _buildCoverLayer(
    BuildContext context,
    double progress, {
    required Rect coverRect,
  }) {
    final current = ref.read(playerProvider).current;
    if (current == null) return const SizedBox.shrink();
    // 封面放大层独立于窗口（栈顶层，屏幕坐标系）：矩形由调用方按迷你
    // 封面起点 → 详情页封面占位终点（同一 eased 曲线）插值给出，供窗口
    // 层联动复用，保证两者同步上浮。目标矩形以页面布局坐标读取，不受
    // 窗口缩放绘制变换影响，进度 1 时即真实路由页封面位置。
    final rect = coverRect;
    // 封面样式决定最终圆角：经典方形 24、圆形/黑胶铺满圆、沉浸式直角。
    final style =
        ref.watch(
          settingsProvider.select((s) => s.valueOrNull?.playerCoverStyle),
        ) ??
        PlayerCoverStyle.classic;
    final targetRadius = switch (style) {
      PlayerCoverStyle.circle || PlayerCoverStyle.vinyl => rect.width / 2,
      PlayerCoverStyle.immersive => 0.0,
      _ => 24.0,
    };
    final eased = Curves.easeOutCubic.transform(progress);
    // 持续显示到最终目标矩形：不再中途淡出，真实路由页接管时无缝衔接。
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: CoverImage(
        key: ValueKey('expand:${current.path}'),
        songPath: current.path,
        imageUrl: current.coverUrl,
        width: rect.width,
        height: rect.height,
        radius: 25 + (targetRadius - 25) * eased,
        highQuality: progress > .5,
        icon: Icons.music_note_rounded,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(
      playerProvider.select(
        (state) => (
          current: state.current,
          isPlaying: state.isPlaying,
          isLoading: state.isLoading,
          errorMessage: state.errorMessage,
          // 进度也必须订阅：单曲循环由播放器原生回绕，current 等字段不变，
          // 不订阅 position 的话底栏不会重建，循环重播后进度条停在末尾。
          position: state.position,
          duration: state.duration,
        ),
      ),
    );
    final current = player.current;
    if (current == null) return const SizedBox.shrink();

    // 视频播放时音频播放器会暂停，视频控制器自己提供进度和播放状态。
    // revision 负责在视频控制器创建/销毁时让首页底栏重新绑定。
    return ValueListenableBuilder<int>(
      valueListenable: VideoPlaybackSession.revision,
      builder: (context, _, child) {
        final video = VideoPlaybackSession.isFor(current.path)
            ? VideoPlaybackSession.controller
            : null;
        if (video == null) {
          return _buildBar(context, player, current);
        }
        return ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: video,
          builder: (context, value, child) => _buildBar(
            context,
            player,
            current,
            video: video,
            videoValue: value,
          ),
        );
      },
    );
  }

  Widget _buildBar(
    BuildContext context,
    ({
      QueueItem? current,
      bool isPlaying,
      bool isLoading,
      String? errorMessage,
      double position,
      double duration,
    })
    player,
    QueueItem current, {
    VideoPlayerController? video,
    VideoPlayerValue? videoValue,
  }) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final videoLoading =
        VideoPlaybackSession.isFor(current.path) &&
        VideoPlaybackSession.loading &&
        video == null;
    final isPlaying = videoValue?.isPlaying ?? player.isPlaying;
    final isLoading = videoLoading || (video == null && player.isLoading);
    final position = videoValue == null
        ? player.position
        : videoValue.position.inMilliseconds / 1000.0;
    final duration = videoValue == null
        ? player.duration
        : videoValue.duration.inMilliseconds / 1000.0;

    return GestureDetector(
      onTap: () => context.push('/player'),
      onVerticalDragStart: _onDragStart,
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: _onDragEnd,
      onVerticalDragCancel: _onDragCancel,
      child: ClipRRect(
        key: _barKey,
        // 胶囊形：半径取栏高（64）的一半，左右两端为半圆。
        borderRadius: BorderRadius.circular(32),
        child: BackdropFilter.grouped(
          // 小型底栏也会在页面滚动时参与合成，降低半径避免低端手机掉帧。
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            height: 64,
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(
                alpha: dark ? .34 : .48,
              ),
              borderRadius: BorderRadius.circular(32),
              border: Border.all(
                color: dark ? XyColors.darkBorder : XyColors.lightBorder,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.3 : 0.09),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Stack(
              children: [
                Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: SizedBox(
                        // 定位锚点：拖动预览封面放大层的起点。
                        key: _coverKey,
                        width: 50,
                        height: 50,
                        child: CoverImage(
                          key: ValueKey('mini:${current.path}'),
                          songPath: current.path,
                          imageUrl: current.coverUrl,
                          width: 50,
                          height: 50,
                          radius: 25,
                          icon: Icons.music_note_rounded,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            // 歌手名拼进标题行，保证副行滚动歌词时歌手名仍可见。
                            current.artist.isEmpty
                                ? current.title
                                : '${current.title} - ${current.artist}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          if (player.errorMessage != null)
                            Text(
                              player.errorMessage!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.error,
                              ),
                            )
                          else
                            RepaintBoundary(
                              child: _MiniBarLyrics(item: current),
                            ),
                        ],
                      ),
                    ),
                    _PlayerButton(
                      primary: true,
                      icon: isLoading
                          ? Icons.hourglass_top_rounded
                          : isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      label: isLoading
                          ? '加载中'
                          : isPlaying
                          ? '暂停'
                          : '播放',
                      onTap: isLoading
                          ? () {}
                          : video != null
                          ? () {
                              if (video.value.isPlaying) {
                                unawaited(video.pause());
                              } else {
                                unawaited(video.play());
                              }
                            }
                          : () => ref.read(playerProvider.notifier).toggle(),
                    ),
                    _PlayerButton(
                      icon: Icons.queue_music_rounded,
                      label: '播放队列',
                      onTap: () => showQueueSheet(context, ref),
                    ),
                    const SizedBox(width: 3),
                  ],
                ),
                Align(
                  alignment: Alignment.bottomLeft,
                  // 进度条随 position 流（80~120ms）重绘：RepaintBoundary
                  // 把重绘伤害局限在本层，避免连带玻璃层每 tick 重新采样。
                  child: RepaintBoundary(
                    child: _MiniPlayerProgress(
                      position: position,
                      duration: duration,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniPlayerProgress extends StatelessWidget {
  const _MiniPlayerProgress({required this.position, required this.duration});

  final double position;
  final double duration;

  @override
  Widget build(BuildContext context) {
    final progress = safeMiniPlayerProgress(position, duration);
    return FractionallySizedBox(
      widthFactor: progress,
      child: Container(
        height: 2,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _PlayerButton extends StatelessWidget {
  const _PlayerButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final color = primary
        ? Theme.of(context).colorScheme.primary
        : Colors.transparent;
    return Semantics(
      button: true,
      label: label,
      child: InkResponse(
        onTap: onTap,
        radius: 24,
        child: SizedBox(
          width: 44,
          height: 52,
          child: Center(
            child: Container(
              width: primary ? 34 : 32,
              height: primary ? 34 : 32,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Icon(
                icon,
                size: primary ? 22 : 23,
                color: primary
                    ? Colors.white
                    : Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 底栏迷你歌词：随播放进度滚动显示当前歌词行。
/// 歌手名已并入标题行（歌曲名 - 歌手名）始终显示；本行跟随迷你歌词
/// 字号设置，单行显示、超出省略号截断，无歌词（含插件歌曲未内嵌歌词）
/// 时显示「暂无歌词」占位。
class _MiniBarLyrics extends ConsumerWidget {
  const _MiniBarLyrics({required this.item});

  final QueueItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(
      playerProvider.select((state) => state.position),
    );
    // 跟随迷你歌词字号设置；底栏高度有限（64dp，标题行外仅余约 29dp），
    // 上限收紧到 15 防止撑破布局。
    final fontSize =
        (ref.watch(
                  settingsProvider.select(
                    (s) => s.valueOrNull?.miniLyricFontSize,
                  ),
                ) ??
                11.0)
            .clamp(10.0, 15.0);
    final embedded = item.lyricsRaw?.trim() ?? '';
    final AsyncValue<List<LyricLine>> lyrics;
    if (embedded.isNotEmpty) {
      lyrics = ref.watch(embeddedLyricsProvider(embedded));
    } else if (item.pluginId == null) {
      lyrics = ref.watch(songLyricsProvider(item.path));
    } else {
      lyrics = const AsyncData(<LyricLine>[]);
    }
    const fallback = '暂无歌词';
    var lineTime = -1.0;
    var text = lyrics.when(
      // 加载期间保持空白占位，避免「暂无歌词」与歌词间的占位闪烁。
      loading: () => ' ',
      error: (_, _) => fallback,
      data: (lines) {
        if (lines.isEmpty) return fallback;
        var active = lyricActiveIndex(lines, position);
        lineTime = lines[active].time;
        final line = lines[active].text.trim();
        return line.isEmpty ? fallback : line;
      },
    );
    if (text == fallback) lineTime = -1.0;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      child: Text(
        text,
        key: ValueKey('bar:${item.path}:$lineTime'),
        // 单行显示，超出部分省略号截断，保证底栏高度稳定。
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontSize,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
