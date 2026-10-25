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
/// 底部播放栏支持「按住从下向上拖动」展开：拖动过程中全屏播放页从底部
/// 跟随手指滑入，左侧封面随进度从迷你尺寸放大为完整封面；松手超过阈值
/// 或快速上滑时吸附展开（补完动画后切入真实播放页路由），否则回弹收起。
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
    // 预览页初始位置锚定播放栏顶部：进度 0 时页面从播放栏位置开始上滑。
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
      final origin = box.localToGlobal(Offset.zero);
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

  /// 拖动预览层：页面从播放栏位置跟随手指上滑 + 封面随进度放大。
  Widget _buildExpandLayer(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    // 全屏播放页预览作为 child 只构建一次，动画帧仅更新外层变换与封面层，
    // 避免拖动过程中整页（毛玻璃/歌词/列表）逐帧重建造成掉帧。
    // 预览页隐藏自带封面（封面由放大层持续提供），并挂封面占位锚点
    // 供读取最终封面矩形，与真实路由页无缝衔接。
    final page = RepaintBoundary(
      child: IgnorePointer(
        child: PlayerPage(coverHidden: true, coverAnchorKey: _coverAnchorKey),
      ),
    );
    return AnimatedBuilder(
      animation: controller,
      child: page,
      builder: (context, child) {
        final progress = controller.value;
        final viewport = MediaQuery.sizeOf(context);
        final screenH = viewport.height;
        // 进度 0 → 页面顶部位于播放栏顶部（从播放栏位置开始上滑）；
        // 进度 1 → 页面顶部到达屏幕顶部。读不到播放栏位置时退回屏外。
        final startY = _barTopY ?? screenH;
        return Stack(
          fit: StackFit.expand,
          children: [
            // 全屏播放页预览：从播放栏位置跟随手指上滑。
            Transform.translate(
              offset: Offset(0, startY * (1 - progress)),
              child: child,
            ),
            // 封面放大层：迷你封面随进度放大上移，持续显示到最终矩形。
            if (progress > .01) _buildCoverLayer(context, progress),
          ],
        );
      },
    );
  }

  Widget _buildCoverLayer(BuildContext context, double progress) {
    final current = ref.read(playerProvider).current;
    if (current == null) return const SizedBox.shrink();
    final startRect = _miniCoverRect();
    if (startRect == null) return const SizedBox.shrink();
    final viewport = MediaQuery.sizeOf(context);
    // 目标矩形优先取预览页封面占位的真实矩形（与路由页封面完全一致，
    // 无缝衔接）；首帧尚未读到（极速拖动）时退回近似估算。
    final targetRect =
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
    final rect = Rect.lerp(startRect, targetRect, eased)!;
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
