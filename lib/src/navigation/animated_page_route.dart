import 'dart:async';

import 'package:flutter/material.dart';

import '../core/settings.dart';
import 'player_sheet_morph.dart';

const xyPageTransitionDuration = Duration(milliseconds: 300);
const xyPageReverseTransitionDuration = Duration(milliseconds: 260);

/// 播放详情页转场时长（XianYu 同款 450ms，正反向一致）。
const xyPlayerSheetTransitionDuration = Duration(milliseconds: 450);

/// 播放详情页转场进行中标记：详情页从屏幕底部滑入/收回期间，底下壳层
/// 页面的二级转场（跟随覆盖页动画）必须冻结——「页面从静态背景上滑过」
/// 要求壳层与播放栏完全静止，否则全局切换模式为平移/层叠时壳层会沿
/// 水平轴错向滑动（与竖直滑入混轴）。由 [xyPlayerSheetTransition] 按
/// 转场状态同步置位/复位，[xyPageTransition] 读取。
bool xySecondaryTransitionFrozen = false;

/// 页面切换模式的全局镜像。
///
/// 路由的 transitionsBuilder 无法访问 WidgetRef，由根组件（app.dart）
/// 在设置加载或变化时写入该值；每次新导航都会读取最新模式。
PageTransitionMode xyPageTransitionMode = PageTransitionMode.fade;

/// 当前播放详情页路由引用：路由构造即赋值（早于 install），供播放栏
/// 上滑跟手驱动转场值；路由 dispose 时清除。
XyPlayerSheetRoute<dynamic>? xyPlayerSheetRouteRef;

CurvedAnimation _xyCurve(Animation<double> parent) => CurvedAnimation(
  parent: parent,
  curve: Curves.easeOutCubic,
  reverseCurve: Curves.easeInCubic,
);

/// 页面切换过渡入口：按设置中的切换模式分发。
///
/// 动画落定后（入场完成且未被新页面覆盖）直接裸返回页面本身：
/// 不包裹任何过渡层（Slide/Fade/遮罩），从结构上杜绝装饰层
/// 遮挡点击与滚动的可能。
Widget xyPageTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  return AnimatedBuilder(
    animation: Listenable.merge([animation, secondaryAnimation]),
    child: child,
    builder: (context, child) {
      final settled =
          animation.value >= 1 && secondaryAnimation.value <= 0;
      if (settled) return child!;
      // 播放详情页转场期间冻结本页的二级转场（壳层保持静止）。
      if (xySecondaryTransitionFrozen) return child!;
      // 过渡期间把页面内容圈成独立重绘边界：页面本体（长列表、毛玻璃、
      // 封面模糊、着色器）只需光栅化一次，动画每帧仅更新外层变换与不透明
      // 度，避免整页在 300ms 过渡里逐帧重绘造成切换掉帧。落定后不保留该
      // 边界（走上面的裸返回），不产生常驻图层。
      final page = RepaintBoundary(child: child!);
      switch (xyPageTransitionMode) {
        case PageTransitionMode.slide:
          return _XySlidePageTransition(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            child: page,
          );
        case PageTransitionMode.stack:
          return _XyStackPageTransition(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            child: page,
          );
        case PageTransitionMode.fade:
          return _XyFadePageTransition(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            child: page,
          );
      }
    },
  );
}

/// 平移：前后两页同步水平推移，边界始终相接。
/// 入场页左缘带过渡阴影、被覆盖页轻微压暗，落定后均不可见，
/// 避免透明页面在动画中产生“叠加”观感。
class _XySlidePageTransition extends StatelessWidget {
  const _XySlidePageTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final incoming = _xyCurve(animation);
    final covered = _xyCurve(secondaryAnimation);
    return ClipRect(
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(incoming),
        child: SlideTransition(
          position: Tween<Offset>(
            begin: Offset.zero,
            end: const Offset(-1, 0),
          ).animate(covered),
          child: Stack(
            fit: StackFit.expand,
            children: [
              child,
              // 入场页左缘阴影：动画进行中可见，落定后淡出。
              // IgnorePointer 确保装饰层永不参与命中测试，
              // 否则透明度为 0 时仍会吞掉整页点击。
              FadeTransition(
                opacity: ReverseAnimation(incoming),
                child: const IgnorePointer(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: 24,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [Colors.black45, Colors.transparent],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 被覆盖页压暗：跟随覆盖进度加深，最多 24%。
              // ColoredBox 对命中测试始终不透明，必须用 IgnorePointer
              // 隔离，否则动画落定后整页按钮都点不动。
              FadeTransition(
                opacity: covered.drive(
                  Tween<double>(begin: 0, end: .24),
                ),
                child: const IgnorePointer(
                  child: ColoredBox(color: Colors.black),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 层叠：入场页从右侧滑入并淡入，被覆盖页向左错开、轻微缩小并渐隐，
/// 两页在动画中前后交叠，落定后下层页完全隐藏。
class _XyStackPageTransition extends StatelessWidget {
  const _XyStackPageTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final incoming = _xyCurve(animation);
    final covered = _xyCurve(secondaryAnimation);
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(incoming),
      child: FadeTransition(
        opacity: incoming,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: Offset.zero,
            end: const Offset(-.3, 0),
          ).animate(covered),
          child: ScaleTransition(
            scale: Tween<double>(begin: 1, end: .95).animate(covered),
            child: FadeTransition(
              opacity: ReverseAnimation(covered),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 淡入淡出：入场页渐显，被覆盖页渐隐，两页交叉淡化，
/// 落定后下层页完全消失。
class _XyFadePageTransition extends StatelessWidget {
  const _XyFadePageTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final incoming = _xyCurve(animation);
    final covered = _xyCurve(secondaryAnimation);
    return FadeTransition(
      opacity: incoming,
      child: FadeTransition(
        opacity: ReverseAnimation(covered),
        child: child,
      ),
    );
  }
}

/// 播放详情页专属转场（光锥播放器 LightC 同款形变）：详情页面板从
/// 播放栏矩形连续生长到全屏（顶边全程跟手、圆角收平、封面连续变形、
/// 栏内容与页面内容交叉淡化），收起为完全倒序，与全局页面切换模式
/// 设置无关（底部弹出语义与迷你播放条「上滑打开」手势一致）。
///
/// 缺少形变起点（[xyPlayerSheetOrigin] 为 null，深链直达详情页等）
/// 时退回底部滑入兜底动画（[_playerSheetFallbackTransition]）。
/// 转场进行中置位 [xySecondaryTransitionFrozen] 冻结壳层二级转场，
/// 落定后复位；落定后裸返回页面本体，性能策略与 [xyPageTransition]
/// 相同。
Widget xyPlayerSheetTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  return AnimatedBuilder(
    animation: Listenable.merge([animation, secondaryAnimation]),
    child: child,
    builder: (context, child) {
      // 冻结标记与转场状态同步：前向/反向进行中冻结壳层，落定（含被
      // 上层页覆盖）后解除，不影响其它页面的正常转场。
      xySecondaryTransitionFrozen =
          animation.status == AnimationStatus.forward ||
          animation.status == AnimationStatus.reverse;
      // 落定（含被上层页覆盖）裸返回：t=1 时形变各层退化为页面本身。
      if (animation.value >= 1) return child!;
      if (xyPlayerSheetOrigin == null) {
        return _playerSheetFallbackTransition(animation, child);
      }
      return XyPlayerSheetMorph(animation: animation, child: child);
    },
  );
}

/// 兜底转场：全屏覆盖页从底部向上滑入/收回（5574 行为）。
Widget _playerSheetFallbackTransition(Animation<double> animation, Widget? child) {
  final curved = _xyCurve(animation);
  final t = curved.value;
  final raw = animation.value;
  final fadeT = animation.status == AnimationStatus.reverse
      ? const Interval(0, 0.45, curve: Curves.easeIn).transform(raw)
      : const Interval(0, 0.45, curve: Curves.easeOut).transform(raw);
  // 顶部圆角随进度长出再收平（中段峰值 24），静止时归零。
  final radius = 96.0 * t * (1 - t);
  return SlideTransition(
    position: Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(curved),
    child: ClipRRect(
      borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
      clipBehavior: radius > 0.5 ? Clip.antiAlias : Clip.none,
      child: Opacity(opacity: fadeT, child: RepaintBoundary(child: child!)),
    ),
  );
}

/// 播放详情页路由：暴露动画控制器的手势驱动接口，供播放栏上滑与详情
/// 页下滑实时驱动转场（子类内访问 @protected controller 是 Dart 允许的
/// 用法，对外只暴露下列公开成员）。
class XyPlayerSheetRoute<T> extends PageRouteBuilder<T> {
  XyPlayerSheetRoute({required super.settings, required WidgetBuilder builder})
    : super(
        transitionDuration: xyPlayerSheetTransitionDuration,
        reverseTransitionDuration: xyPlayerSheetTransitionDuration,
        // 不透明关闭：形变面板为毛玻璃半透明，需要持续采样其下的壳层
        // 页面（转场中与落定后都是）；落定后详情页自身不透明盖满全屏。
        opaque: false,
        pageBuilder: (context, animation, secondaryAnimation) =>
            builder(context),
        transitionsBuilder: xyPlayerSheetTransition,
      ) {
    xyPlayerSheetRouteRef = this;
    // 转场期间隐藏所有 MiniPlayerBar 实例本体（morph 层复刻提供
    // 面板视觉），收起动画结束（dispose）后恢复。
    xySheetRouteActive.value = true;
  }

  /// 手势写入的目标转场值：控制器未就绪（尚未 install）时暂存，
  /// install 后应用，保证 push 当帧不丢跟手进度。
  double? _dragTarget;

  /// 拖动实时驱动：详情页下滑收起为 1 → 0，播放栏上滑展开为 0 → 1。
  set dragValue(double value) {
    _dragTarget = value.clamp(0.0, 1.0);
    final controller = this.controller;
    if (controller == null) return;
    if (controller.isAnimating) controller.stop();
    controller.value = _dragTarget!;
  }

  /// 松手回弹到全屏：时长按剩余距离等比缩短，避免短距回弹拖沓。
  void springBack() {
    final controller = this.controller;
    if (controller == null) return;
    if (controller.isAnimating) controller.stop();
    final remaining = (1.0 - controller.value).clamp(0.0, 1.0);
    if (remaining <= 0) return;
    unawaited(
      controller.animateTo(
        1.0,
        duration: Duration(
          milliseconds:
              (xyPlayerSheetTransitionDuration.inMilliseconds * remaining)
                  .round(),
        ),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  /// 松手收回：面板缩回播放栏矩形，动画完成后移除路由（此时转场值
  /// 已为 0，路由离场无视觉跳变）。
  void collapseAndPop() {
    final controller = this.controller;
    if (controller == null) {
      _popSelf();
      return;
    }
    if (controller.isAnimating) controller.stop();
    final remaining = controller.value.clamp(0.0, 1.0);
    if (remaining <= 0) {
      _popSelf();
      return;
    }
    unawaited(
      controller
          .animateTo(
            0.0,
            duration: Duration(
              milliseconds:
                  (xyPlayerSheetTransitionDuration.inMilliseconds * remaining)
                      .round(),
            ),
            curve: Curves.easeInCubic,
          )
          .whenComplete(_popSelf),
    );
  }

  void _popSelf() {
    final navigator = this.navigator;
    if (navigator == null || !isActive || !navigator.canPop()) return;
    navigator.pop();
  }

  @override
  void install() {
    super.install();
    // install 创建控制器后立即应用暂存的拖动值，didPush 从该值续播。
    final controller = this.controller;
    final value = _dragTarget;
    if (controller != null && value != null && value > 0) {
      controller.value = value;
    }
  }

  @override
  void dispose() {
    if (identical(xyPlayerSheetRouteRef, this)) {
      xyPlayerSheetRouteRef = null;
    }
    xySheetRouteActive.value = false;
    // 兜底复位冻结标记：正常路径由转场落定复位，这里覆盖转场被异常
    // 中断（路由被外部直接移除等）的情况，避免壳层二级转场被永久冻结。
    xySecondaryTransitionFrozen = false;
    super.dispose();
  }
}

class XyAnimatedPageRoute<T> extends PageRouteBuilder<T> {
  XyAnimatedPageRoute({required WidgetBuilder builder, super.settings})
    : super(
        transitionDuration: xyPageTransitionDuration,
        reverseTransitionDuration: xyPageReverseTransitionDuration,
        pageBuilder: (context, animation, secondaryAnimation) =>
            builder(context),
        transitionsBuilder: xyPageTransition,
      );
}
