import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../library/online_cover_overrides.dart';
import '../../pages/player/player_page.dart'
    show PlayerDetailBackground, VinylCover;
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

/// 形变是否处于手势跟手驱动中：由 [XyPlayerSheetRoute.dragValue] 置位、
/// 松手转场（springBack/collapseAndPop）复位。跟手期间 morph 层直接
/// 使用线性转场值（不再叠加 easeOutCubic），否则手指拖 20% 面板已生长
/// 49%（easeOutCubic 前段斜率约 3 倍），观感严重超前于手指、拖回时
/// 又反向迟滞——这是此前展开/收起「不丝滑」的主因。
bool xyPlayerSheetGestureDriving = false;

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
    // 手势跟手驱动：线性值直接映射面板位置（严格跟手）；松手后的
    // 补间动画仍按方向套曲线（正向 easeOutCubic / 反向 easeInCubic，
    // 与全局页面曲线语义一致）。
    final raw = animation.value;
    final t = xyPlayerSheetGestureDriving
        ? raw.clamp(0.0, 1.0)
        : animation.status == AnimationStatus.reverse
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
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final current = player.current;
    // 背景连续性（两种主题都要）：面板底色是 scheme.surface（浅色主题下
    // 即纯白）@.86/.92，而详情页真实背景恒为「封面模糊 + 深色压暗」的
    // 暗色调，页面正文又要到 t≈0.55 才淡入——中间整段是一块近白/近黑面板，
    // 展开与收起都会在面板底色↔页面暗背景之间来回扫，这正是用户看到的
    // 「闪白」（浅色主题是纯白面板扫暗底，深色主题是面板底色与封面氛围色
    // 不一致，在部分机型上同样明显）。
    // 这里在面板内垫一层与详情页完全同源的背景（同一组件、同样底部对齐、
    // 同样按全屏尺寸溢出裁切），在转场前段由透明交叉淡入：起始帧仍是播放
    // 栏的毛玻璃观感，随后直接过渡到页面真实背景（不再出现比两端都亮的
    // 白色中间态）；页面正文 t≥0.55 淡入时，其背景与本层逐像素一致，
    // 交叠期间背景完全不变。
    final backdropT = ((t - .02) / .5).clamp(0.0, 1.0);
    // 页面完全不透明后不再构建垫层：详情页自身背景是重度的封面模糊
    // （ImageFiltered sigma 32），Stack 不会对被子节点完全遮挡的层做剔除，
    // 转场结束后仍保留垫层等于整场播放期间都多画一遍全屏模糊。t=1 时
    // 页面正文（Opacity 1，直接透传）与其背景已逐像素覆盖垫层，此时
    // 移除垫层既不改变任何一帧的画面，也把转场结束后的额外开销降为 0；
    // 收起动画 t<1 时垫层按原值重新出现，全程背景仍连续。
    final showPageBackdrop = current != null && pageT < 1;

    // 面板内容体：面板色装饰 + 详情页本体 + 栏内容复刻。
    // 详情页页面体（全屏尺寸、底边对齐面板底边，随面板生长逐步露出）。
    final pageBody = OverflowBox(
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
    );
    // 与详情页同源的背景垫层，从透明交叉淡入到完全不透明。
    // 底下的 ColoredBox 与详情页 Scaffold 兜底色取同一个值，保证封面模糊层
    // 淡入/未就绪时两处透出的都是同一个不透明底色，而不是面板的纯白。
    final pageBackdrop = showPageBackdrop
        ? Positioned.fill(
            child: Opacity(
              opacity: backdropT,
              child: ColoredBox(
                color: playerBackdropBaseColor(scheme),
                child: OverflowBox(
                  alignment: Alignment.bottomLeft,
                  minWidth: screen.width,
                  maxWidth: screen.width,
                  minHeight: screen.height,
                  maxHeight: screen.height,
                  child: SizedBox(
                    width: screen.width,
                    height: screen.height,
                    child: PlayerDetailBackground(current: current),
                  ),
                ),
              ),
            ),
          )
        : null;
    final panelContent = DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: dark ? .86 : .92),
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
          // 页面背景垫层（两种主题）：在页面正文之前先接管背景色，
          // 消除「面板底色 → 页面暗背景」之间的闪白中间态。
          ?pageBackdrop,
          // 详情页本体：后段整体淡入。pageT<=0 时不构建页面子树
          // （省整页布局，此前 Opacity(0) 仍会跑全屏 OverflowBox 布局）。
          // 这里始终用 Opacity 包住页面体（不按 pageT>=1 切裸放），
          // 避免中途切换 widget 类型导致整页 element 被重建：重建会触发
          // PlayerPage.dispose/initState（沉浸式状态栏一收一放、曲目状态
          // 重载），在部分机型上表现为动画中途闪白/抖动。alpha=255 时
          // RenderOpacity 本身就会直接透传，无额外 saveLayer。
          if (pageT > 0)
            Positioned.fill(
              child: Opacity(
                opacity: pageT,
                child: IgnorePointer(ignoring: true, child: pageBody),
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
                child: RepaintBoundary(
                  child: _buildReplica(context, ref, player, current),
                ),
              ),
            ),
        ],
      ),
    );

    return Stack(
      children: [
        Positioned.fromRect(
          rect: panel,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            clipBehavior: radius > .5 ? Clip.antiAlias : Clip.none,
            // 注意：这里刻意不再挂 BackdropFilter。
            // 1) 面板色本来就 86%~92% 不透明，模糊只剩 8%~14% 的可见收益，
            //    却要付一次全屏 saveLayer + 大半径采样；
            // 2) 形变路由是 opaque:false，BackdropFilter 采样的是跨路由/跨
            //    RepaintBoundary 的背景层，属于「取不到就是未定义内容」的
            //    路径（本工程其余毛玻璃都改用 BackdropFilter.grouped）；
            //    在部分 GPU/驱动（如用户反馈的荣耀机型）上可能读到未初始化
            //    的白色底，表现为深色主题下也闪白；
            // 3) 旧的 sigma 衰减分支会在 t≈0.95 切换 widget 类型，导致整块
            //    panelContent（含整个详情页）被重建，中途重新挂载页面。
            // 去掉后转场层级结构全程恒定，背景由上面的 pageBackdrop 负责。
            child: panelContent,
          ),
        ),
        // 封面连续变形层：形态跟随封面风格——经典方形收平到 24 圆角
        // 方图（对齐真实页）、圆形全程保持正圆（半径随矩形宽度过渡）、
        // 沉浸式收平为直角全宽、黑胶直接复用完整黑胶盘（盘面镶中心
        // 封面，避免封面与盘「分家」）；t>0.75 淡出由真实页封面接管。
        // 黑胶/圆图必须按内切正方形绘制：VinylCover 内部画布与唱臂坐标
        // 按正方形盘面设计，若 coverRect 中间帧宽高不等（50×50 迷你封面
        // lerp 到沉浸式 w×w 时速率不同），tight 约束会把盘面拉成椭圆、
        // 唱臂比例失调（用户实测黑胶变形）。此处统一取 min 边长居中。
        if (coverFade > 0 && current != null) ...[
          // 黑胶/圆图必须按内切正方形绘制：VinylCover 内部画布与唱臂坐标
          // 按正方形盘面设计，若 coverRect 中间帧宽高不等（50×50 迷你封面
          // lerp 到沉浸式 w×w 时速率不同），tight 约束会把盘面拉成椭圆、
          // 唱臂比例失调（用户实测黑胶变形）。此处统一取 min 边长居中。
          Positioned(
            left: coverRect.left + (coverRect.width - math.min(coverRect.width, coverRect.height)) / 2,
            top: coverRect.top + (coverRect.height - math.min(coverRect.width, coverRect.height)) / 2,
            width: math.min(coverRect.width, coverRect.height),
            height: math.min(coverRect.width, coverRect.height),
            child: Opacity(
              opacity: coverFade,
              child: Builder(
                builder: (context) {
                  final side = math.min(coverRect.width, coverRect.height);
                  return origin.style == PlayerCoverStyle.vinyl
                      ? VinylCover(
                          item: current,
                          playing: player.isPlaying,
                          size: side,
                          showTonearm: false,
                        )
                      : CoverImage(
                          songPath: current.path,
                          imageUrl: resolveOnlineCoverUrl(
                            current.coverUrl,
                            current.path,
                          ),
                          width: side,
                          height: side,
                          radius: switch (origin.style) {
                            // 起点迷你图 25 = 50/2，随矩形宽度自然成正圆。
                            PlayerCoverStyle.circle => side / 2,
                            PlayerCoverStyle.immersive =>
                              ui.lerpDouble(25, 0, coverT)!,
                            _ => ui.lerpDouble(25, 24, coverT)!,
                          },
                          icon: Icons.music_note_rounded,
                        );
                },
              ),
            ),
          ),
        ],
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
