import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/settings.dart';
import 'animated_page_route.dart';

/// 分页（TabBarView / PageView）切换过渡：统一跟随全局「页面切换动画」。
///
/// 实现方式不给分页换控件：分页仍是原生 [TabBarView] / [PageView]
/// （手势、懒构建、页状态保留、滚动语义全部不变），只在每一页外面套一层
/// 「视觉变换」，按 [xyPageTransitionMode] 改变切换时的观感：
///
/// - [PageTransitionMode.slide]（平移）：不套任何装饰，走原生水平滑动，
///   与改造前完全一致，也不产生额外图层；
/// - [PageTransitionMode.fade]（淡入淡出）：抵消分页自身的水平位移，
///   两页原地交叉淡化（不横向滑动）；
/// - [PageTransitionMode.stack]（层叠）：保留三成滑入位移并渐显，
///   离场页被推着同向滑出并轻微缩小。
///
/// 分隔进度取自分页控制器（[TabController.animation] / [PageController]
/// 的浮点页码），因此点标签跳转、横滑拖动、代码 `animateToPage` 都会
/// 走同一套过渡；设置改动后重建即按新取值表现，无需重启。
class XyPagedPage extends StatelessWidget {
  const XyPagedPage({
    super.key,
    required this.index,
    required this.animation,
    required this.pageValue,
    required this.child,
    this.transitionMode,
  });

  /// 本页在分页中的下标。
  final int index;

  /// 局部覆盖全局「页面切换动画」：为空时跟随 [xyPageTransitionMode]。
  /// 个别分页（如播放页封面/歌词）需要独立观感时使用。
  final PageTransitionMode? transitionMode;

  /// 分页进度的通知源；分页控制器尚未挂载时为 null。
  final Listenable? animation;

  /// 读取当前浮点页码（0 .. pageCount-1）；不可用时返回 null。
  final double? Function() pageValue;

  /// 本页内容。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final listenable = animation;
    // 本页生效的切换模式：局部覆盖优先，未指定时跟随全局设置。
    final mode = transitionMode ?? xyPageTransitionMode;
    // 平移模式：原生滑动即目标效果，不加任何装饰层。
    if (mode == PageTransitionMode.slide || listenable == null) {
      return child;
    }
    final width = MediaQuery.sizeOf(context).width;
    // 过渡位移对齐到整数设备像素。
    //
    // [Transform.translate] 的分数像素位移会由合成器对子树纹理做一次
    // 重采样（双线性插值）：淡入/层叠模式下整页文字因此发虚，表现为
    // 「切页时整块内容模糊一两帧再变锐利」，而位置和亮度都不变（因为
    // 位移被淡入抵消、alpha 过渡本身不改亮度）。对齐到物理像素后位移
    // 不再产生重采样，淡入仍由 [Opacity] 单独负责，观感与设置语义不变。
    final dpr = MediaQuery.devicePixelRatioOf(context);
    double snap(double v) => (v * dpr).roundToDouble() / dpr;
    return AnimatedBuilder(
      animation: listenable,
      child: child,
      builder: (context, child) {
        final page = pageValue();
        if (page == null) return child!;
        final delta = page - index;
        final distance = delta.abs();
        // 相邻页静止时正好在视口外（|delta| = 1）：保持原生位置即可，
        // 不能用过渡公式，否则会被拉回视口正中。
        if (distance >= 1) return child!;
        final opacity = (1 - distance).clamp(0.0, 1.0);
        // 非当前页不接收指针：过渡期间相邻页可能被过渡公式拉进视口，
        // 若参与命中测试会盖住并抢走当前页的点击与滚动。
        final ignorePointer = distance > 0.001;
        final Widget transformed = switch (mode) {
          // 完全抵消原生位移：视觉上原地交叉淡化。
          PageTransitionMode.fade => Transform.translate(
            offset: Offset(snap(-delta * width), 0),
            child: Opacity(opacity: opacity, child: child!),
          ),
          // 保留三成位移：入场页滑入渐显，离场页同向滑出并轻微缩小。
          PageTransitionMode.stack => Transform.translate(
            offset: Offset(snap(-delta * width * .7), 0),
            child: Transform.scale(
              scale: 1 - (delta < 0 ? .05 * distance : 0.0),
              child: Opacity(opacity: opacity, child: child!),
            ),
          ),
          PageTransitionMode.slide => child!,
        };
        return ignorePointer
            ? IgnorePointer(ignoring: true, child: transformed)
            : transformed;
      },
    );
  }
}

/// 跟随「页面切换动画」设置的分页标签视图：与 [TabBarView] 参数一致。
///
/// 未显式传 [controller] 时沿用上层的 [DefaultTabController]。
class XyTabBarView extends StatelessWidget {
  const XyTabBarView({
    super.key,
    this.controller,
    this.physics,
    this.dragStartBehavior = DragStartBehavior.start,
    this.viewportFraction = 1.0,
    this.clipBehavior = Clip.hardEdge,
    required this.children,
  });

  final TabController? controller;
  final ScrollPhysics? physics;
  final DragStartBehavior dragStartBehavior;
  final double viewportFraction;
  final Clip clipBehavior;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tab = controller ?? DefaultTabController.of(context);
    final progress = tab.animation;
    return TabBarView(
      controller: tab,
      physics: physics,
      dragStartBehavior: dragStartBehavior,
      viewportFraction: viewportFraction,
      clipBehavior: clipBehavior,
      children: [
        for (var index = 0; index < children.length; index++)
          XyPagedPage(
            index: index,
            animation: progress,
            pageValue: () => progress?.value,
            child: children[index],
          ),
      ],
    );
  }
}

/// 跟随「页面切换动画」设置的 [PageView]：参数与固定数量的分页写法一致。
///
/// 只覆盖整页分页场景（封面/歌词、详情分页等）；`PageView.builder`
/// 的无限分页仍用原生控件。
class XyPageView extends StatelessWidget {
  const XyPageView({
    super.key,
    this.controller,
    this.physics,
    this.onPageChanged,
    this.scrollDirection = Axis.horizontal,
    this.allowImplicitScrolling = false,
    this.pageSnapping = true,
    this.padEnds = true,
    this.clipBehavior = Clip.hardEdge,
    this.transitionMode,
    required this.children,
  });

  final PageController? controller;
  final ScrollPhysics? physics;
  final ValueChanged<int>? onPageChanged;
  final Axis scrollDirection;
  final bool allowImplicitScrolling;
  final bool pageSnapping;
  final bool padEnds;
  final Clip clipBehavior;

  /// 局部覆盖全局「页面切换动画」：为空时跟随 [xyPageTransitionMode]。
  final PageTransitionMode? transitionMode;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final pager = controller;
    return PageView(
      controller: pager,
      physics: physics,
      onPageChanged: onPageChanged,
      scrollDirection: scrollDirection,
      allowImplicitScrolling: allowImplicitScrolling,
      pageSnapping: pageSnapping,
      padEnds: padEnds,
      clipBehavior: clipBehavior,
      children: [
        for (var index = 0; index < children.length; index++)
          XyPagedPage(
            index: index,
            animation: pager,
            transitionMode: transitionMode,
            pageValue: () {
              if (pager == null || !pager.hasClients) return null;
              try {
                return pager.page;
              } catch (_) {
                // 元素树换挂的过渡帧（如播放页沉浸式开关实时换布局）里，
                // 旧 PageView 要到帧末 finalize 才释放 ScrollPosition，而
                // 新 PageView 已经挂载——控制器短暂挂着两个 position，此时
                // 读 page（positions.single）会抛 StateError。release 下该
                // 异常会把整个翻页区渲染成灰屏（ErrorWidget），且若没有
                // 后续重建就永久灰屏（实测 2026-11）。过渡期返回 null 直接
                // 走原生位置，帧末旧挂载释放后自动恢复正常读值。
                return null;
              }
            },
            child: children[index],
          ),
      ],
    );
  }
}
