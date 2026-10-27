import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../../pages/player/player_page.dart' show VinylCover;
import '../player/player_provider.dart';
import '../ui/xy_theme.dart';
import '../widgets/cover_image.dart';
import '../widgets/mini_player_bar.dart';
import '../widgets/queue_sheet.dart';

/// 播放栏 → 详情页形变转场（光锥播放器 LightC 同款效果）的起点信息。
///
/// 展开时详情页面板从播放栏矩形连续「生长」到全屏：面板顶边全程跟随
/// 手指、顶部圆角随生长收平、封面从迷你圆角图连续变形到详情页封面、
/// 栏内容早段淡出、页面内容后段（约 t=0.55 起）淡入。
class XyPlayerSheetOrigin {
  const XyPlayerSheetOrigin({
    required this.barRect,
    required this.coverRect,
    required this.pageCoverRect,
    required this.style,
  });

  /// 播放栏在屏幕坐标系中的矩形（形变起点）。
  final Rect barRect;

  /// 播放栏迷你封面在屏幕坐标系中的矩形（封面形变起点）。
  final Rect coverRect;

  /// 详情页封面的预估最终矩形（封面形变终点；页面内容淡入后由
  /// 真实封面接管，估算误差只影响交叉淡化瞬间的对齐精度）。
  final Rect pageCoverRect;

  /// 封面风格：决定封面形变层的终点形态（方图/正圆/全宽/黑胶盘）。
  final PlayerCoverStyle style;
}

/// 最近一次测量的形变起点。播放栏在 push `/player` 前写入；为 null 时
/// （深链直达详情页等）转场退回底部滑入兜底动画。
XyPlayerSheetOrigin? xyPlayerSheetOrigin;

/// `/player` 形变路由是否处于打开状态（install → dispose）：所有
/// [MiniPlayerBar] 实例（壳层/搜索页/在线目录页）据此在转场期间
/// 隐藏本体，避免毛玻璃面板下方透出多实例文字重影。
final ValueNotifier<bool> xySheetRouteActive = ValueNotifier<bool>(false);

/// 详情页封面最终矩形的通用估算：形变封面的终点（buildPlayerSheetOrigin）
/// 与详情页下滑/上滑收起手势的分区判定共用同一来源，保证两者一致。
Rect estimatePageCoverRect(Size screen, double statusBarTop, PlayerCoverStyle style) {
  final w = screen.width;
  if (style == PlayerCoverStyle.immersive) {
    // 沉浸式：封面铺满顶部（_ImmersiveTopCover 全宽方块）。
    return Rect.fromLTWH(0, 0, w, w);
  }
  // 其余风格：内容区居中大封面（约 0.72 屏宽，顶栏下方）。
  final side = w * 0.72;
  return Rect.fromLTWH((w - side) / 2, statusBarTop + 72, side, side);
}

/// 按「栏矩形 + 迷你封面矩形 + 封面风格」构建形变起点。
XyPlayerSheetOrigin buildPlayerSheetOrigin({
  required Rect barRect,
  required Rect coverRect,
  required Size screen,
  required double statusBarTop,
  required PlayerCoverStyle style,
}) {
  return XyPlayerSheetOrigin(
    barRect: barRect,
    coverRect: coverRect,
    pageCoverRect: estimatePageCoverRect(screen, statusBarTop, style),
    style: style,
  );
}

/// 播放详情页形变转场层：把页面（[child]）包进一个从播放栏矩形生长到
/// 全屏的毛玻璃面板中，并叠加封面连续变形层与栏内容复刻层。
///
/// 转场值 t（0→1）：面板矩形 Rect.lerp(barRect, 全屏, t)、圆角 32(1-t)、
/// 页面 Opacity((t-.55)/.45)（经 OverflowBox 底对齐保持全屏布局不重排）、
/// 栏复刻 Opacity(1-t/.25)、封面形变 Rect.lerp(cover→pageCover) 且在
/// t>0.75 淡出让位于真实封面。收起为完全倒序（与展开同一条动画）。
class XyPlayerSheetMorph extends ConsumerWidget {
  const XyPlayerSheetMorph({super.key, required this.animation, this.child});

  final Animation<double> animation;
  final Widget? child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 面板复刻层与封面层需要的播放状态：与迷你播放栏同一套订阅。
    final player = ref.watch(
      playerProvider.select(
        (state) => (
          current: state.current,
          isPlaying: state.isPlaying,
          isLoading: state.isLoading,
          errorMessage: state.errorMessage,
          position: state.position,
          duration: state.duration,
        ),
      ),
    );
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) => _buildMorph(context, ref, player),
    );
  }

  Widget _buildMorph(
    BuildContext context,
    WidgetRef ref,
    ({
      QueueItem? current,
      bool isPlaying,
      bool isLoading,
      String? errorMessage,
      double position,
      double duration,
    })
    player,
  ) {
    final origin = xyPlayerSheetOrigin;
    if (origin == null) return child!;
    // 正向 easeOutCubic / 反向 easeInCubic，与全局页面曲线语义一致；
    // 手势驱动（status 为 completed 时手动改值）沿用正向分支。
    final raw = animation.value;
    final t = animation.status == AnimationStatus.reverse
        ? Curves.easeInCubic.transform(raw)
        : Curves.easeOutCubic.transform(raw);
    // 屏幕尺寸取自 View：overlay 子树的 MediaQuery 可能被 SafeArea 裁剪。
    final view = MediaQueryData.fromView(View.of(context));
    final screen = view.size;
    final full = Rect.fromLTWH(0, 0, screen.width, screen.height);
    final panel = Rect.lerp(origin.barRect, full, t)!;
    final radius = 32 * (1 - t);
    final pageT = ((t - .55) / .45).clamp(0.0, 1.0);
    final barT = (1 - t / .25).clamp(0.0, 1.0);
    final coverT = Curves.easeOut.transform(t);
    final coverRect = Rect.lerp(origin.coverRect, origin.pageCoverRect, coverT)!;
    final coverFade = 1 - ((t - .75) / .25).clamp(0.0, 1.0);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final current = player.current;

    return Stack(
      children: [
        Positioned.fromRect(
          rect: panel,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            clipBehavior: radius > .5 ? Clip.antiAlias : Clip.none,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface.withValues(
                    alpha: dark ? .86 : .92,
                  ),
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(
                    color: dark ? XyColors.darkBorder : XyColors.lightBorder,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: dark ? .3 : .09),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    // 详情页本体：全屏尺寸、底边对齐面板底边，随面板生长
                    // 逐步露出（顶部溢出部分被裁剪），后段整体淡入。
                    Positioned.fill(
                      child: Opacity(
                        opacity: pageT,
                        child: IgnorePointer(
                          ignoring: pageT < 1,
                          child: OverflowBox(
                            alignment: Alignment.bottomLeft,
                            minWidth: screen.width,
                            maxWidth: screen.width,
                            minHeight: screen.height,
                            maxHeight: screen.height,
                            child: SizedBox(
                              width: screen.width,
                              height: screen.height,
                              child: RepaintBoundary(child: child),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 栏内容复刻：面板内的底部还原播放栏内容，早段淡出。
                    if (barT > 0 && current != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: origin.barRect.height,
                        child: Opacity(
                          opacity: barT,
                          child: _buildReplica(context, ref, player, current),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // 封面连续变形层：形态跟随封面风格——经典方形收平到 24 圆角
        // 方图（对齐真实页）、圆形全程保持正圆（半径随矩形宽度过渡）、
        // 沉浸式收平为直角全宽、黑胶直接复用完整黑胶盘（盘面镶中心
        // 封面，避免封面与盘「分家」）；t>0.75 淡出由真实页封面接管。
        if (coverFade > 0 && current != null)
          Positioned.fromRect(
            rect: coverRect,
            child: Opacity(
              opacity: coverFade,
              child: origin.style == PlayerCoverStyle.vinyl
                  ? VinylCover(
                      item: current,
                      playing: player.isPlaying,
                      size: coverRect.width,
                      showTonearm: false,
                    )
                  : CoverImage(
                      songPath: current.path,
                      imageUrl: current.coverUrl,
                      width: coverRect.width,
                      height: coverRect.height,
                      radius: switch (origin.style) {
                        // 起点迷你图 25 = 50/2，随矩形宽度自然成正圆。
                        PlayerCoverStyle.circle => coverRect.width / 2,
                        PlayerCoverStyle.immersive =>
                          ui.lerpDouble(25, 0, coverT)!,
                        _ => ui.lerpDouble(25, 24, coverT)!,
                      },
                      icon: Icons.music_note_rounded,
                    ),
            ),
          ),
      ],
    );
  }

  /// 播放栏内容复刻（与 [MiniPlayerBar] 同构：标题 + 迷你歌词 +
  /// 播放/队列按钮 + 底部进度条），封面区域留空由形变封面层提供。
  Widget _buildReplica(
    BuildContext context,
    WidgetRef ref,
    ({
      QueueItem? current,
      bool isPlaying,
      bool isLoading,
      String? errorMessage,
      double position,
      double duration,
    })
    player,
    QueueItem current,
  ) {
    final isLoading = player.isLoading;
    final isPlaying = player.isPlaying;
    return SizedBox(
      height: double.infinity,
      child: Stack(
        children: [
          Row(
            children: [
              // 迷你封面占位（栏内封面 6 内边距 + 50 尺寸 + 6 间距）。
              const SizedBox(width: 68),
              // 标题/歌词等文字内容在动画过程中直接隐藏（用户要求），
              // 仅以弹性占位保持按钮靠右；收起动画结束、真实播放栏
              // 恢复显示时文字随之出现。
              const Spacer(),
              PlayerButton(
                primary: true,
                icon: isLoading
                    ? Icons.hourglass_top_rounded
                    : isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                label: isLoading ? '加载中' : isPlaying ? '暂停' : '播放',
                onTap: isLoading
                    ? () {}
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
            child: RepaintBoundary(
              child: MiniPlayerProgress(
                position: player.position,
                duration: player.duration,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
