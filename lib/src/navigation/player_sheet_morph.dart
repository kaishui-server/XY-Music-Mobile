import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../library/online_cover_overrides.dart';
import '../../pages/player/player_page.dart'
    show PlayerDetailBackground, SpinningCover, VinylCover;
import '../player/player_provider.dart';
import '../ui/xy_theme.dart';
// 收起阶段整层穿透需要读路由的「已提交收起」状态（见 _buildMorph 末尾）。
// 双向 import（animated_page_route 亦 import 本文件）在 Dart 中是允许的。
import 'animated_page_route.dart';
import '../widgets/cover_image.dart';
import '../widgets/mini_player_bar.dart';
import '../widgets/queue_sheet.dart';

// ---------------------------------------------------------------------------
// 形变转场的时长、曲线与几何公式。
//
// 全部对齐参考项目 CurrentMusicX（feature/player/PlayerSheetTransition.kt）：
// 展开 420ms / 收起 360ms，缓动 cubic-bezier(.2,0,0,1) / (.3,0,.2,1)；
// 面板按「左上角向屏内收 + 宽高涨满」插值，圆角只在最后 6% 收平；
// 浮层与内容透明度分段浮现；封面沿二次曲线飞行（水平先快后慢、
// 垂直与尺寸先慢后快）。路由侧与形变层共用这里的定义，避免两处漂移。
// ---------------------------------------------------------------------------

/// 展开时长（面板长成全屏）。
const Duration xyPlayerSheetOpenDuration = Duration(milliseconds: 420);

/// 收起时长（面板缩回播放栏）。
const Duration xyPlayerSheetCloseDuration = Duration(milliseconds: 360);

/// 展开缓动：起步平、中段快、收尾贴齐（控制点 (0.2,0) / (0,1)）。
const Cubic xyPlayerSheetOpenCurve = Cubic(0.2, 0, 0, 1);

/// 收起缓动：起步略缓、尾段保留一点余速（控制点 (0.3,0) / (0.2,1)）。
const Cubic xyPlayerSheetCloseCurve = Cubic(0.3, 0, 0.2, 1);

/// 面板浮层不透明度：进度前 14% 内线性浮现。
double xySheetSurfaceAlpha(double progress) => (progress / .14).clamp(0.0, 1.0);

/// 面板内容不透明度：16% → 76% 区间淡入（与参考实现同窗口）。
double xySheetContentAlpha(double progress) =>
    ((progress - .16) / .60).clamp(0.0, 1.0);

/// 面板圆角收缩系数：94% 之前保持满圆角，最后 6% 才收平。
double xySheetCornerScale(double progress) =>
    1 - ((progress - .94) / .06).clamp(0.0, 1.0);

/// 面板圆角阶梯量化：8px 一档（32 / 24 / 16 / 8 / 0）。
///
/// 【性能】圆角若是每帧连续插值，`ClipRRect` 的裁剪路径就每帧变化，裁剪层
/// 会把整棵面板子树（含整个详情页）重新栅格化——探针里 raster 超标帧占
/// 62%~86%、worstR 145~287ms 的主因。量化后只有跨档的那几帧才换裁剪路径，
/// 单档差 ≤8px 且只发生在最后 6% 的收平段，肉眼不可辨；低于半档（≤4px）
/// 直接归零并去掉裁剪，尾段彻底不付裁剪成本。
double xySheetQuantizedRadius(double radius) {
  final step = (radius / 8).roundToDouble() * 8;
  if (step <= 4) return 0;
  return step > 32 ? 32 : step;
}

/// 面板矩形：左上角按 (1-p) 向屏内收，宽高按 p 长到目标尺寸。
Rect xySheetPanelRect(Rect origin, Size target, double progress) {
  final p = progress.clamp(0.0, 1.0);
  final left = origin.left * (1 - p);
  final top = origin.top * (1 - p);
  final width = origin.width * (1 - p) + target.width * p;
  final height = origin.height * (1 - p) + target.height * p;
  return Rect.fromLTWH(left, top, width, height);
}

/// 形变元素（封面）沿二次曲线飞行：水平位移先快后慢（1-(1-p)²），
/// 垂直位移与尺寸先慢后快（p²），因此飞行物会先向内收、再向上抬。
Rect xySheetFlightRect(Rect start, Rect end, double progress) {
  final p = progress.clamp(0.0, 1.0);
  final horizontal = 1 - (1 - p) * (1 - p);
  final vertical = p * p;
  final width = start.width * (1 - vertical) + end.width * vertical;
  final height = start.height * (1 - vertical) + end.height * vertical;
  final centerX =
      start.center.dx * (1 - horizontal) + end.center.dx * horizontal;
  final centerY = start.center.dy * (1 - vertical) + end.center.dy * vertical;
  return Rect.fromCenter(
    center: Offset(centerX, centerY),
    width: width,
    height: height,
  );
}

/// 曲线反解：跟手阶段按线性映射、松手后按曲线补间，把当前视觉值反解
/// 成曲线坐标作为补间起点，保证「跟手 → 动画」切换瞬间位置连续。
double xySheetCurveInverse(Curve curve, double value) {
  final target = value.clamp(0.0, 1.0);
  if (target <= 0 || target >= 1) return target;
  var low = 0.0;
  var high = 1.0;
  for (var i = 0; i < 24; i++) {
    final mid = (low + high) / 2;
    if (curve.transform(mid) < target) {
      low = mid;
    } else {
      high = mid;
    }
  }
  return (low + high) / 2;
}

/// 播放栏 → 详情页形变转场（光锥播放器 LightC 同款效果）的起点信息。
///
/// 展开时详情页面板从播放栏矩形连续「生长」到全屏：面板顶边全程跟随
/// 手指、顶部圆角随生长收平、封面从迷你圆角图连续变形到详情页封面、
/// 栏内容早段淡出、页面内容后段（约 t=0.5 起）淡入。
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

/// 形变转场是否尚未落定（t < 1）：详情页背景层据此降级为「轻量背景」
/// （不透明兜底色 + 氛围 blob，跳过全屏封面重度模糊）。
///
/// 根源：面板 Rect/圆角每帧都在变（`Positioned.fromRect` + 随半径变化的
/// `ClipRRect`），整棵面板子树每帧重新栅格化，而背景层打底是一次全屏
/// `ImageFilter.blur(sigma 32)`（单份约 7~14ms）。转场期垫层
/// （pageBackdrop）与页面本体各有一份，合计两份全屏模糊每帧重算，低端
/// 机上尾段单帧可达 50~100ms —— 这正是「进歌曲页卡、退出去也卡」的主因。
/// 转场期间改用同色系轻量背景，落定（t=1）后自动恢复完整背景，静止画面
/// 与原先完全一致。
final ValueNotifier<bool> xyPlayerSheetMorphing = ValueNotifier<bool>(false);

/// 详情页真实封面的显现度（0 = 完全不可见，1 = 常态完全显现）。
///
/// 转场语义：封面飞行层全程保持「详情页更多菜单」封面卡的形态（圆角方图，
/// 详情页封面样式（黑胶盘 / 直角沉浸 / 24 圆角方图）只在封面飞到详情页
/// 既定位置、动画落定前的最后一段才渐显——页面因此把这个值乘到自己的
/// 封面层上（[_BigCover] / [_ImmersiveTopCover]），使封面样式不会在
/// 动画进行中提前出现在详情页上。
///
/// 缺省 1（无转场时页面封面常态可见）；[XyPlayerSheetRoute] install 时
/// 置 0、落定或 dispose 时复位 1，形变层按帧写入 1-封面淡出值。
final ValueNotifier<double> xyPlayerPageCoverReveal = ValueNotifier<double>(1);

/// 详情页封面当前的旋转相位（0~1 = 一圈），供形变转场层接续角度。
///
/// 圆形旋转与黑胶盘面在播放中匀速转一圈。展开时飞行层与详情页封面几乎
/// 同一时刻起转（相位都≈0），落定交接天然对齐；收起时详情页封面已经
/// 转了任意角度，飞行层若从 0 起转，封面会在收起的瞬间「跳一下」。
/// 因此详情页封面把自身相位回写到本值（`SpinningCover.phaseSink`），
/// 飞行层挂载时按它起转（`initialPhase`），两边以同一角速度前进，
/// 交接处严丝合缝。
final ValueNotifier<double> xyCoverSpinPhase = ValueNotifier<double>(0);

/// 帧末提交的待写显现度（build 阶段直接写会同步通知监听者并触发
/// markNeedsBuild 异常，与 [_syncPlayerSheetMorphing] 同一处理）。
double? _pendingPageCoverReveal;

/// 写入详情页封面显现度：值未变时不产生任何通知；变化推迟到帧末提交。
void syncPlayerPageCoverReveal(double reveal) {
  final next = reveal.clamp(0.0, 1.0);
  if (xyPlayerPageCoverReveal.value == next) return;
  if (_pendingPageCoverReveal == next) return;
  _pendingPageCoverReveal = next;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_pendingPageCoverReveal != next) return;
    _pendingPageCoverReveal = null;
    if (xyPlayerPageCoverReveal.value != next) {
      xyPlayerPageCoverReveal.value = next;
    }
  });
}

/// 详情页封面最终矩形的通用估算：形变封面的终点（buildPlayerSheetOrigin）
/// 与详情页下滑/上滑收起手势的分区判定共用同一来源，保证两者一致。
Rect estimatePageCoverRect(
  Size screen,
  double statusBarTop,
  PlayerCoverStyle style,
) {
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

/// 飞行封面的目标形态：与详情页 [_BigCover] 当前封面样式逐像素同源。
///
/// 详情页各风格的封面圆角（player_page.dart `_buildClassic` / `_buildCircle`
/// / `_ImmersiveTopCover`）：
/// - classic：边长 = pageCoverRect.width 时固定 24 圆角——飞行层按
///   24/详情页边长 的比例折算，任意飞行尺寸下形态比例一致，落定交接
///   时飞行图与真实封面严丝合缝；
/// - circle：正圆（边长一半）；
/// - vinyl：黑胶盘面为正圆（整盘由 [VinylCover] 绘制）；
/// - immersive：直角铺满（详情页为全宽方块）。
double xySheetCoverRadius(
  PlayerCoverStyle style,
  double side,
  Rect pageCoverRect,
) {
  switch (style) {
    case PlayerCoverStyle.classic:
      final ref = pageCoverRect.width > 1 ? pageCoverRect.width : side;
      return side * (24 / ref);
    case PlayerCoverStyle.circle:
    case PlayerCoverStyle.vinyl:
      return side / 2;
    case PlayerCoverStyle.immersive:
      return 0;
  }
}

/// 飞行封面由「播放栏迷你圆图」收敛到详情页封面形态的进度（0→1）。
///
/// 起点 coverRect 是播放栏那颗正圆迷你封面（50 尺寸 / 圆角 25）：若第一帧
/// 就直接切成详情页的方图或黑胶盘，起手会有一帧明显跳变。这里在转场最
/// 初 10% 内做形态收敛——起点与播放栏完全重合，之后全程保持详情页封面
/// 样式（用户要求「动画过程中封面与详情页封面样式一致」）。
double xySheetCoverShapeProgress(double t) => (t / .10).clamp(0.0, 1.0);

/// 播放详情页形变转场层：把页面（[child]）包进一个从播放栏矩形生长到
/// 全屏的毛玻璃面板中，并叠加封面连续变形层与栏内容复刻层。
///
/// 转场值 t（0→1）：面板矩形 Rect.lerp(barRect, 全屏, t)、圆角 32(1-t)、
/// 页面 Opacity((t-.5)/.4)（经 OverflowBox 底对齐保持全屏布局不重排）、
/// 栏复刻 Opacity(1-t/.25)、封面形变 Rect.lerp(cover→pageCover) 且在
/// t>0.75 淡出让位于真实封面。收起为完全倒序（与展开同一条动画）。
class XyPlayerSheetMorph extends ConsumerWidget {
  const XyPlayerSheetMorph({super.key, required this.animation, this.child});

  final Animation<double> animation;
  final Widget? child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 面板复刻层与封面层需要的播放状态：与迷你播放栏同一套订阅。
    // 刻意不订阅 position/duration：播放中进度是细档流（约 16ms 一次，
    // 120Hz 下等于每帧），若并入这里，转场期间 morph 每帧都要因进度变化
    // 重建整棵树（面板 + 整个详情页 + 封面形变层），而真正需要进度的
    // 只有栏复刻里的那条迷你进度条——已下沉到 _ReplicaProgress 单独订阅。
    final player = ref.watch(
      playerProvider.select(
        (state) => (
          current: state.current,
          isPlaying: state.isPlaying,
          isLoading: state.isLoading,
          errorMessage: state.errorMessage,
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
    ({QueueItem? current, bool isPlaying, bool isLoading, String? errorMessage})
    player,
  ) {
    final origin = xyPlayerSheetOrigin;
    if (origin == null) return child!;
    // 手势跟手驱动：线性值直接映射面板位置（严格跟手）；松手后的
    // 补间动画仍按方向套曲线（正向 easeOutCubic / 反向 easeInCubic，
    // 与全局页面曲线语义一致）。
    final raw = animation.value.clamp(0.0, 1.0);
    // 缓动与参考实现一致：展开 cubic-bezier(.2,0,0,1)、收起
    // cubic-bezier(.3,0,.2,1)。跟手期间仍走线性（严格跟手）。
    final t = xyPlayerSheetGestureDriving
        ? raw
        : animation.status == AnimationStatus.reverse
        ? xyPlayerSheetCloseCurve.transform(raw)
        : xyPlayerSheetOpenCurve.transform(raw);
    // 屏幕尺寸取自 View：overlay 子树的 MediaQuery 可能被 SafeArea 裁剪。
    final view = MediaQueryData.fromView(View.of(context));
    final screen = view.size;
    // 面板矩形按参考实现的逐轴插值：左上角向屏内收、宽高涨到全屏。
    final panel = xySheetPanelRect(origin.barRect, screen, t);
    // 圆角只在最后 6% 收平（中段保留浮起圆角），不再全程线性衰减。
    final radius = 32 * xySheetCornerScale(t);
    // 【性能】圆角阶梯量化（32/24/16/8/0）：原先每帧连续插值，裁剪路径
    // 每帧都变，整棵面板子树（含详情页全屏内容）被迫每帧重栅格化。
    // 量化后只有跨档帧才换路径；≤4px 归零去裁剪，尾段不再付裁剪成本。
    final panelRadius = xySheetQuantizedRadius(radius);
    // 分段不透明度（参考实现同窗口）：面板浮层前 14% 浮现，页面正文
    // 16%→76% 淡入（旧版是 50%→90%，转场前半程几乎看不到内容）。
    final surfaceAlpha = xySheetSurfaceAlpha(t);
    final pageT = xySheetContentAlpha(t);
    // 栏复刻与面板浮层同源：面板刚浮现时它在，14% 之后随浮层一起退场。
    final barT = (1 - t / .14).clamp(0.0, 1.0);
    // 封面沿二次曲线飞行：水平先快后慢、垂直与尺寸先慢后快。
    final coverRect = xySheetFlightRect(
      origin.coverRect,
      origin.pageCoverRect,
      t,
    );
    // 封面飞行层全程保持「详情页更多菜单」封面卡的形态（圆角方图），
    // 不随 style 变形：详情页封面样式（黑胶盘 / 直角沉浸 / 24 圆角方图）
    // 只在飞到详情页既定位置、动画落定前的一段才由真实页封面显现。
    // coverFade 是飞行层自身的淡出窗口（92% 之后到落定）。
    final coverFade = 1 - ((t - .92) / .08).clamp(0.0, 1.0);
    // 详情页真实封面（含黑胶唱臂、方形反光、沉浸式直角铺满等样式装饰）
    // 的显现度：飞行全程为 0——页面封面区留白，封面视觉完全由飞行圆角图
    // 提供；飞到位后渐显，且比飞行层淡出早一步收官（90%→98% 走完，
    // 落定帧已是 1）。早收官是必要的：显现度经帧末提交、页面看到的是上
    // 一帧的值，若与飞行层同时到 t=1 才满，落定那一帧飞行层已消失而页
    // 面封面还差最后一点，会闪一帧偏淡。
    syncPlayerPageCoverReveal(((t - .90) / .08).clamp(0.0, 1.0));
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final current = player.current;
    // 背景连续性（两种主题都要）：面板底色是 scheme.surface（浅色主题下
    // 即纯白）@.86/.92，而详情页真实背景恒为「封面模糊 + 深色压暗」的
    // 暗色调，页面正文又要到 t≈0.5 才淡入——中间整段是一块近白/近黑面板，
    // 展开与收起都会在面板底色↔页面暗背景之间来回扫，这正是用户看到的
    // 「闪白」（浅色主题是纯白面板扫暗底，深色主题是面板底色与封面氛围色
    // 不一致，在部分机型上同样明显）。
    // 这里在面板内垫一层与详情页完全同源的背景（同一组件、同样底部对齐、
    // 同样按全屏尺寸溢出裁切），在转场前段由透明交叉淡入：起始帧仍是播放
    // 栏的毛玻璃观感，随后直接过渡到页面真实背景（不再出现比两端都亮的
    // 白色中间态）；页面正文 t≥0.16 开始淡入时，其背景与本层逐像素一致，
    // 交叠期间背景完全不变。垫层淡入窗口比正文略早（t=0.58 即满），
    // 保证正文显形时底下已经是不透明的同源背景，不会透出面板白底。
    final backdropT = ((t - .02) / .56).clamp(0.0, 1.0);
    // 页面完全不透明后不再构建垫层：详情页自身背景是重度的封面模糊
    // （ImageFiltered sigma 32），Stack 不会对被子节点完全遮挡的层做剔除，
    // 转场结束后仍保留垫层等于整场播放期间都多画一遍全屏模糊。页面正文
    // 淡入窗口改为参考实现的 (t-.16)/.6（t=0.76 即完全盖住）：
    // 在展开曲线 cubic-bezier(.2,0,0,1) 下 t=0.76 落在动画约 47% 处——垫层
    // 提前移除让转场后段（视觉近静止、最昂贵的一段）从「壳层快照+垫层+
    // 页面」3 层全屏混合降到 2 层，视觉无差别（两背景逐像素一致）。t=1 时
    // 页面正文（Opacity 1，直接透传）与其背景已逐像素覆盖垫层，此时
    // 移除垫层既不改变任何一帧的画面，也把转场结束后的额外开销降为 0；
    // 收起动画 t<1 时垫层按原值重新出现，全程背景仍连续。
    final showPageBackdrop = current != null && pageT < 1;

    // 面板内容体：面板色装饰 + 详情页本体 + 栏内容复刻。
    // 【性能】详情页页面体：内容窗口改成固定整屏尺寸、只用 Transform 平移
    // 定位（见下方面板层），窗口尺寸恒为屏幕尺寸，因此不再需要 OverflowBox
    // 做「按全屏撑开 + 底边对齐面板」的兜底；页面体直接填满窗口，宽度与
    // 高度全程不变，转场期间不做任何重排。
    final pageBody = RepaintBoundary(child: child);
    // 与详情页同源的背景垫层，从透明交叉淡入到完全不透明。
    // 底下的 ColoredBox 与详情页 Scaffold 兜底色取同一个值，保证封面模糊层
    // 淡入/未就绪时两处透出的都是同一个不透明底色，而不是面板的纯白。
    // lite: true —— 转场期间用轻量背景（不透明兜底色 + 氛围 blob），
    // 跳过全屏封面重度模糊（sigma 32，单份 7~14ms）：面板 Rect/圆角每帧
    // 变化会让本层每帧重新栅格化，与页面本体那份模糊叠加后尾段单帧可达
    // 50~100ms。落定后垫层移除（showPageBackdrop 转 false），页面切回完整
    // 背景，视觉无损失。
    final pageBackdrop = showPageBackdrop
        ? Positioned.fill(
            child: Opacity(
              opacity: backdropT,
              child: ColoredBox(
                // 窗口已是整屏尺寸，垫层直接铺满窗口即可（原先靠 OverflowBox
                // 按全屏撑开，窗口固定后不再需要）。
                color: playerBackdropBaseColor(scheme),
                child: PlayerDetailBackground(current: current, lite: true),
              ),
            ),
          )
        : null;
    // 面板投影：blur 24 的阴影每帧随面板 Rect 重算，后段面板已接近全屏
    // （阴影大半落在屏幕外）时纯属浪费。转场后段直接去掉，前段保留浮起感。
    final panelShadows = t < .35
        ? [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? .3 : .09),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ]
        : const <BoxShadow>[];
    // 面板底色让位：垫层完全不透明后（backdropT>=1）或页面正文已完全
    // 淡入（pageT>=1）时，86/92% 半透明的 surface 底色被逐像素盖住、
    // 毫无可见贡献，却让合成器每帧多混合一层全屏半透明（5632 探针实测
    // raster 是转场卡顿主因，全屏 blend 是大头）。此时置透明，合成器
    // 可直接剔除该层。仅在有垫层/页面兜底（current != null）时让位，
    // 无曲目时页面体没有不透明背景，底色仍需承担面板外观。
    final panelBaseCovered = current != null && (backdropT >= 1 || pageT >= 1);
    // 【性能】面板底色/描边/投影独立成一层：面板 Rect 每帧在变，把它和
    // 整页内容拆开以后，尺寸变化只让这层小圆角矩形重画，不再牵动里面
    // 整个详情页（原先装饰包着内容，装饰尺寸每帧变会顺带重录整棵子树）。
    final panelSurface = DecoratedBox(
      decoration: BoxDecoration(
        // 浮层底色按 XY 的分段不透明度（前 14% 浮现）：起点帧是透明的，
        // 面板从播放栏位置「长出」而不是先闪一块半透明底。
        color: panelBaseCovered
            ? scheme.surface.withValues(alpha: 0)
            : scheme.surface.withValues(
                alpha: (dark ? .86 : .92) * surfaceAlpha,
              ),
        borderRadius: BorderRadius.circular(panelRadius),
        border: Border.all(
          color: dark ? XyColors.darkBorder : XyColors.lightBorder,
        ),
        boxShadow: panelShadows,
      ),
    );
    // 面板内容体（不含底色装饰）：详情页本体 + 栏内容复刻。
    final panelContent = Stack(
      fit: StackFit.expand,
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
            // 窗口是整屏宽、面板随生长变宽（≥ 播放栏宽度），右边界要按
            // 面板实际宽度收，才能与真实播放栏的按钮位置逐像素对齐。
            right: screen.width - panel.width,
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
    );

    // 【性能】面板层：内容尺寸恒定 + 便宜裁剪。
    // 旧实现用 Positioned.fromRect 直接把内容套进面板矩形，面板 Rect 每帧
    // 变化就等于让整棵子树（全屏背景、整页歌词）每帧换约束重新布局、重录
    // 图层，图层缓存无从复用。现在内容恒为整屏尺寸（约束不变 → 布局与
    // 位图缓存全程复用），面板的生长只体现为两点：OverflowBox 的对齐偏移
    // （左下角贴齐面板左下角）与裁剪框尺寸。裁剪坚持用 ClipRRect 而不是
    // ClipPath——路径裁剪在多数 GPU 上要额外一层整屏 mask，圆角矩形是
    // 原生 clip，代价低得多。
    // 裁剪必须始终生效（即使圆角已量化到 0）：面板在最后 6% 仍未长满
    // 整屏，内容窗口比面板大一圈，去掉裁剪会露出面板外的页面内容。
    // 注意：这里刻意不再挂 BackdropFilter。
    // 1) 面板色本来就 86%~92% 不透明，模糊只剩 8%~14% 的可见收益，却要付
    //    一次全屏 saveLayer + 大半径采样；
    // 2) 形变路由是 opaque:false，BackdropFilter 采样的是跨路由/跨
    //    RepaintBoundary 的背景层，属于「取不到就是未定义内容」的路径
    //    （本工程其余毛玻璃都改用 BackdropFilter.grouped）；在部分 GPU/
    //    驱动（如用户反馈的荣耀机型）上可能读到未初始化的白色底，表现为
    //    深色主题下也闪白；
    // 3) 旧的 sigma 衰减分支会在 t≈0.95 切换 widget 类型，导致整块
    //    panelContent（含整个详情页）被重建，中途重新挂载页面。
    // 去掉后转场层级结构全程恒定，背景由上面的 pageBackdrop 负责。
    final panelWindow = Positioned.fromRect(
      rect: panel,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(panelRadius),
        clipBehavior: Clip.antiAlias,
        // OverflowBox 把「固定整屏约束」强加给内容：面板多宽多高都不影响
        // 内容的布局尺寸，也就不触发重布局；左下角对齐＝全屏内容底边、
        // 左边贴齐面板，随面板生长逐段露出。
        child: OverflowBox(
          alignment: Alignment.bottomLeft,
          minWidth: screen.width,
          maxWidth: screen.width,
          minHeight: screen.height,
          maxHeight: screen.height,
          child: panelContent,
        ),
      ),
    );

    // 【收起阶段整层穿透】只有「手势跟手中」或「展开补间进行中」才允许
    // 形变层接收指针；其余状态（收起补间、已提交收起、静止）整层不吃
    // 指针，点击直接落到壳层上，不再被残留的复刻层吞掉。
    // 注意 collapseAndPop() 的收起补间是通过 controller.animateTo(0) 跑的，
    // controller 的 direction 为 forward，`animation.status` 在收起期间同样
    // 是 forward——只看 status 会把收起误判成展开，所以必须叠加路由的
    // isCollapsing（收起已提交）这一条。
    final ignoring =
        !(xyPlayerSheetGestureDriving ||
            animation.status == AnimationStatus.forward) ||
        (xyPlayerSheetRouteRef?.isCollapsing ?? false);

    return IgnorePointer(
      ignoring: ignoring,
      child: Stack(
        children: [
          // 面板底色/描边/投影：位置与尺寸仍按面板 Rect 精确绘制（绘制顺序
          // 在内容之下），但它是一块没有子节点的装饰层，重画成本可忽略。
          Positioned.fromRect(rect: panel, child: panelSurface),
          // 面板内容：内容尺寸恒定，只裁不重排。
          panelWindow,
          // 封面飞行层：形态与详情页当前封面样式完全一致（用户要求）——
          // 经典方形是 24 圆角方图、圆形旋转是正圆、沉浸式是直角铺满、
          // 黑胶是整块黑胶盘面（[VinylCover]，与详情页同一个组件），
          // 只随飞行边长等比缩放。转场最初 10% 内由播放栏那颗迷你圆图
          // 收敛到该形态（见 [xySheetCoverShapeProgress]），起点不跳帧。
          // 按内切正方形居中绘制：coverRect 中间帧宽高不等（迷你封面到
          // 沉浸式 w×w 时逐轴速率不同），取 min 边长保证形态不失真。
          if (coverFade > 0 && current != null) ...[
            () {
              final side = math.min(coverRect.width, coverRect.height);
              // 【性能】飞行封面改为「固定渲染尺寸 + 外层 Transform 缩放」：
              // 旧实现把每帧变化的 side / radius 直接喂给 CoverImage 与
              // VinylCover，封面图、黑胶盘面（渐变 + 约 36 圈音轨 +
              // ColorFiltered）每帧重布局、重绘、重栅格化——探针里封面飞到
              // 接近详情页尺寸之后的 raster 尖峰正是这一段。现在统一以详情页
              // 封面边长为渲染基准，飞行尺寸只由外层 Transform.scale 表达：
              // 子层尺寸与圆角全程恒定，位图可复用，缩放交给合成器。
              final pageSide = math.min(
                origin.pageCoverRect.width,
                origin.pageCoverRect.height,
              );
              final baseSide = pageSide > 1 ? pageSide : side;
              final scale = baseSide > 0 ? side / baseSide : 1.0;
              final shape = xySheetCoverShapeProgress(t);
              final targetRadius = xySheetCoverRadius(
                origin.style,
                baseSide,
                origin.pageCoverRect,
              );
              // 圆角只在转场最初 10%（形态收敛段）由迷你正圆收敛到目标形态，
              // 之后恒等于详情页封面的精确圆角——中段完全不变化，落定交接
              // 时逐像素对齐；收敛段再量化到 4px 一档，最多换几次裁剪路径。
              final radius = shape >= 1
                  ? targetRadius
                  : ((baseSide / 2 + (targetRadius - baseSide / 2) * shape) / 4)
                            .roundToDouble() *
                        4;
              final art = CoverImage(
                songPath: current.path,
                imageUrl: resolveOnlineCoverUrl(current.coverUrl, current.path),
                width: baseSide,
                height: baseSide,
                radius: radius,
                icon: Icons.music_note_rounded,
              );
              // 【旋转】封面形态与详情页一致，旋转状态也必须一致：圆形旋转
              // 与黑胶盘面在播放中转、暂停时停住，转场期间不能冻结——形变
              // 动画 400ms 内虽然只转约 6°，但「盘面在转」的节奏一旦中断，
              // 落定交接给详情页封面时会出现一次明显顿挫。因此两类旋转形态
              // 直接接播放态，并用与详情页相同的组件与周期（圆形 25 秒一圈、
              // 黑胶 24 秒一圈）。起转相位取详情页封面的实时相位
              // [xyCoverSpinPhase]：收起时飞行层是新建的 State，若从 0 度
              // 起转，封面会在动画第一帧跳一下角度；按相位接续后两侧以同一
              // 角速度前进，交接处严丝合缝。
              final spinPhase = xyCoverSpinPhase.value;
              final Widget flying;
              switch (origin.style) {
                case PlayerCoverStyle.circle:
                  flying = SpinningCover(
                    playing: player.isPlaying,
                    period: const Duration(seconds: 25),
                    initialPhase: spinPhase,
                    child: art,
                  );
                case PlayerCoverStyle.vinyl:
                  // 盘面盖在圆图之上（shape 控制显现），唱针不画
                  // （showTonearm: false）：转场中飞行尺寸靠外层缩放表达，
                  // 唱针臂会随缩放抖动并伸出封面边界。
                  // 盘面按基准尺寸渲染（尺寸恒定），转场期间不再每帧重建盘面。
                  flying = Stack(
                    fit: StackFit.expand,
                    children: [
                      art,
                      Opacity(
                        opacity: shape,
                        child: VinylCover(
                          item: current,
                          playing: player.isPlaying,
                          size: baseSide,
                          showTonearm: false,
                          initialPhase: spinPhase,
                        ),
                      ),
                    ],
                  );
                case PlayerCoverStyle.classic:
                case PlayerCoverStyle.immersive:
                  flying = art;
              }
              // 基准尺寸的方框居中放在 coverRect 中心，实际视觉尺寸由
              // Transform.scale（绕中心缩放）给到 side——盒子位置只随中心点
              // 平移，不再随边长改变布局。
              return Positioned(
                left: coverRect.left + (coverRect.width - baseSide) / 2,
                top: coverRect.top + (coverRect.height - baseSide) / 2,
                width: baseSide,
                height: baseSide,
                child: Opacity(
                  opacity: coverFade,
                  child: IgnorePointer(
                    child: Transform.scale(
                      scale: scale,
                      // 图层缓存：暂停态盘面不转时位图可直接复用，缩放只改
                      // 合成变换；播放态旋转重绘也被隔离在这一层内。
                      child: RepaintBoundary(child: flying),
                    ),
                  ),
                ),
              );
            }(),
          ],
        ],
      ),
    );
  }

  /// 播放栏内容复刻（与 [MiniPlayerBar] 同构：标题 + 迷你歌词 +
  /// 播放/队列按钮 + 底部进度条），封面区域留空由形变封面层提供。
  Widget _buildReplica(
    BuildContext context,
    WidgetRef ref,
    ({QueueItem? current, bool isPlaying, bool isLoading, String? errorMessage})
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
                label: isLoading
                    ? '加载中'
                    : isPlaying
                    ? '暂停'
                    : '播放',
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
              // 进度单独订阅：只让这条进度条随进度流重建，不牵动整棵
              // 形变树（见 build 里的订阅说明）。
              child: _ReplicaProgress(),
            ),
          ),
        ],
      ),
    );
  }
}

/// 形变面板内的迷你进度条：进度流的唯一订阅点。
///
/// 播放中 position/duration 是细档更新（约 16ms 一次，120Hz 屏上等于每帧），
/// 放在 [XyPlayerSheetMorph] 主体里订阅会让整棵形变树（面板装饰 + 整个
/// 详情页 + 封面形变层）每帧重建一次，转场期间叠加成明显卡顿。这里单独
/// 订阅，重建范围只有这条进度条本身。
class _ReplicaProgress extends ConsumerWidget {
  const _ReplicaProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(
      playerProvider.select(
        (state) => (position: state.position, duration: state.duration),
      ),
    );
    return MiniPlayerProgress(
      position: progress.position,
      duration: progress.duration,
    );
  }
}
