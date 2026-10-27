import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../core/settings.dart';
import '../lyrics/lyrics_models.dart';
import '../navigation/animated_page_route.dart';
import '../navigation/player_sheet_morph.dart';
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
/// 展开播放详情页为光锥播放器（LightC）式形变转场：详情页面板从本栏
/// 矩形连续「生长」到全屏。单击直接 push（面板自动生长）；上滑则先
/// push，随后由本栏手势实时驱动路由转场值（面板顶边跟随手指），松手
/// 按进度/速度决定展开或收回。详情页内的下滑手势与顶栏箭头收起走同
/// 一条动画的倒序，四个入口共用同一效果。
class MiniPlayerBar extends ConsumerStatefulWidget {
  const MiniPlayerBar({super.key});

  @override
  ConsumerState<MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends ConsumerState<MiniPlayerBar> {
  /// 展开转场进行中防抖：push 的 Future 在详情页 pop 时完成，期间播放
  /// 栏已被路由盖住，但转场早期路由尚未盖住播放栏时仍可能收到二次点击，
  /// 避免叠出两个播放页路由。
  bool _opening = false;

  /// 上滑手势已 push 详情页（进入跟手驱动阶段）。
  bool _dragPushed = false;

  /// 上滑手势起始 Y。
  double? _dragStartDy;

  /// 迷你封面锚点：push 前测量封面矩形，供形变转场做封面连续变形。
  final GlobalKey _coverKey = GlobalKey();

  /// 测量并写入形变起点（栏矩形 / 迷你封面矩形 / 页面封面预估矩形）。
  void _prepareOrigin() {
    final barBox = context.findRenderObject();
    if (barBox is! RenderBox || !barBox.attached || !barBox.hasSize) return;
    final barRect = barBox.localToGlobal(Offset.zero) & barBox.size;
    // 封面矩形兜底：按栏内布局推算（6 内边距 + 50 尺寸 + 垂直居中）。
    var coverRect = Rect.fromLTWH(
      barRect.left + 6,
      barRect.top + (barRect.height - 50) / 2,
      50,
      50,
    );
    final coverBox = _coverKey.currentContext?.findRenderObject();
    if (coverBox is RenderBox && coverBox.attached && coverBox.hasSize) {
      coverRect = coverBox.localToGlobal(Offset.zero) & coverBox.size;
    }
    final view = MediaQueryData.fromView(View.of(context));
    final style =
        ref.read(settingsProvider).valueOrNull?.playerCoverStyle ??
        PlayerCoverStyle.classic;
    xyPlayerSheetOrigin = buildPlayerSheetOrigin(
      barRect: barRect,
      coverRect: coverRect,
      screen: view.size,
      statusBarTop: view.padding.top,
      style: style,
    );
  }

  /// 打开播放详情页：与详情页下滑/箭头收起共用 `/player` 路由形变
  /// 转场。转场期间忽略重复入口。
  void _openPlayer() {
    if (_opening || !mounted) return;
    if (ref.read(playerProvider).current == null) return;
    setState(() => _opening = true);
    _prepareOrigin();
    unawaited(
      context.push('/player').whenComplete(() {
        // 收起动画结束（路由 pop 完成）后才恢复显示播放栏本体。
        if (mounted) setState(() => _opening = false);
      }),
    );
  }

  void _onDragStart(DragStartDetails details) {
    _dragStartDy = details.globalPosition.dy;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final startDy = _dragStartDy;
    if (startDy == null) return;
    final dy = startDy - details.globalPosition.dy; // 上滑为正
    if (dy <= 14) return;
    if (!_dragPushed) {
      _dragPushed = true;
      _openPlayer(); // 内部先测量并写入 xyPlayerSheetOrigin。
    }
    // 面板顶边跟随手指：进度 = 上滑距离 / 栏顶边到屏幕顶的距离。
    final route = xyPlayerSheetRouteRef;
    if (route == null) return;
    final top = math.max(xyPlayerSheetOrigin?.barRect.top ?? 1, 1);
    route.dragValue = (dy / top).clamp(0.0, 1.0);
  }

  void _onDragEnd(DragEndDetails details) {
    final startDy = _dragStartDy;
    _dragStartDy = null;
    final pushed = _dragPushed;
    _dragPushed = false;
    final dy = startDy == null ? 0.0 : startDy - details.globalPosition.dy;
    final velocity = details.primaryVelocity ?? 0;
    final route = xyPlayerSheetRouteRef;
    if (pushed && route != null) {
      // 跟手驱动中松手：快甩或过半展开，否则缩回播放栏并关闭。
      final top = math.max(xyPlayerSheetOrigin?.barRect.top ?? 1, 1);
      final progress = (dy / top).clamp(0.0, 1.0);
      if (velocity < -180 || progress > 0.45) {
        route.springBack();
      } else {
        route.collapseAndPop();
      }
      return;
    }
    // 未进入跟手阶段：快速上滑或拖过一栏高度都触发展开（同一 push）。
    if (velocity < -180 || dy > 64) _openPlayer();
  }

  void _onDragCancel() {
    _dragStartDy = null;
    final pushed = _dragPushed;
    _dragPushed = false;
    if (pushed) xyPlayerSheetRouteRef?.collapseAndPop();
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

    // 形变转场进行中隐藏播放栏本体：毛玻璃面板下方不再透出真实栏
    // 文字重影（过渡视觉由 morph 层的面板复刻与封面形变提供），收起
    // 动画结束（路由 pop 完成）后恢复。Opacity(0) 保留布局占位，
    // 壳层不因栏隐藏/恢复而跳动。
    // 激活态由全局 xySheetRouteActive 驱动——壳层/搜索页/在线目录页
    // 共 3 个 MiniPlayerBar 实例同步隐藏，与触发转场的实例无关；
    // _opening 兜底覆盖 push 首帧（路由尚未 install）的间隙。
    return ValueListenableBuilder<bool>(
      valueListenable: xySheetRouteActive,
      builder: (context, routeActive, _) {
        final hidden = _opening || routeActive;
        return IgnorePointer(
          ignoring: hidden,
          child: Opacity(
            opacity: hidden ? 0 : 1,
            child: GestureDetector(
      // 单击 push /player（面板自动生长）；上滑先 push 再由本手势实时
      // 驱动形变转场（面板顶边跟随手指）。
      onTap: _openPlayer,
      onVerticalDragStart: _onDragStart,
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: _onDragEnd,
      onVerticalDragCancel: _onDragCancel,
      child: ClipRRect(
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
                              child: MiniBarLyrics(item: current),
                            ),
                        ],
                      ),
                    ),
                    PlayerButton(
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
                    PlayerButton(
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
                    child: MiniPlayerProgress(
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
            ),
          ),
        );
      },
    );
  }
}

/// 迷你播放进度条：也供详情页形变转场的栏内容复刻层复用。
class MiniPlayerProgress extends StatelessWidget {
  const MiniPlayerProgress({super.key, required this.position, required this.duration});

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

/// 播放栏圆形操作按钮：也供详情页形变转场的栏内容复刻层复用。
class PlayerButton extends StatelessWidget {
  const PlayerButton({
    super.key,
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
/// 时显示「暂无歌词」占位。也供详情页形变转场的栏内容复刻层复用。
class MiniBarLyrics extends ConsumerWidget {
  const MiniBarLyrics({super.key, required this.item});

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
