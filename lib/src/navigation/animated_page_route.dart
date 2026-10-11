import 'package:flutter/material.dart';

import '../core/settings.dart';

const xyPageTransitionDuration = Duration(milliseconds: 300);
const xyPageReverseTransitionDuration = Duration(milliseconds: 260);

/// 页面切换模式的全局镜像。
///
/// 路由的 transitionsBuilder 无法访问 WidgetRef，由根组件（app.dart）
/// 在设置加载或变化时写入该值；每次新导航都会读取最新模式。
PageTransitionMode xyPageTransitionMode = PageTransitionMode.fade;

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

/// 播放详情页专属转场：全屏覆盖页从底部向上滑入、关闭时向下收回底部，
/// 与全局页面切换模式设置无关（底部弹出语义与迷你播放条「上滑打开」
/// 手势一致）。落定后裸返回页面本体，性能策略与 [xyPageTransition] 相同。
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
      final settled =
          animation.value >= 1 && secondaryAnimation.value <= 0;
      if (settled) return child!;
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(_xyCurve(animation)),
        child: RepaintBoundary(child: child!),
      );
    },
  );
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
