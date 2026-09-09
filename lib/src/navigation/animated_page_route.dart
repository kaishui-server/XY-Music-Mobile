import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/settings.dart';

const xyPageTransitionDuration = Duration(milliseconds: 300);
const xyPageReverseTransitionDuration = Duration(milliseconds: 260);

/// 页面切换模式的全局镜像。
///
/// 路由的 transitionsBuilder 无法访问 WidgetRef，由根组件（app.dart）
/// 在设置加载或变化时写入该值；每次新导航都会读取最新模式。
PageTransitionMode xyPageTransitionMode = PageTransitionMode.slide;

CurvedAnimation _xyCurve(Animation<double> parent) => CurvedAnimation(
  parent: parent,
  curve: Curves.easeOutCubic,
  reverseCurve: Curves.easeInCubic,
);

/// 页面切换过渡入口：按设置中的切换模式分发。
Widget xyPageTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  switch (xyPageTransitionMode) {
    case PageTransitionMode.slide:
      return _XySlidePageTransition(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: child,
      );
    case PageTransitionMode.stack:
      return _XyStackPageTransition(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: child,
      );
    case PageTransitionMode.cube:
      return _XyCubePageTransition(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: child,
      );
  }
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
              FadeTransition(
                opacity: ReverseAnimation(incoming),
                child: const Align(
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
              // 被覆盖页压暗：跟随覆盖进度加深，最多 24%。
              FadeTransition(
                opacity: covered.drive(
                  Tween<double>(begin: 0, end: .24),
                ),
                child: const ColoredBox(color: Colors.black),
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

/// 方块：两页绕相邻边缘做带透视的 3D 旋转，像立方体翻面。
/// 入场页绕右边缘从竖直转平（朝向观察者），被覆盖页绕左边缘折入屏幕。
class _XyCubePageTransition extends StatelessWidget {
  const _XyCubePageTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  static const double _perspective = .0016;

  @override
  Widget build(BuildContext context) {
    final incoming = _xyCurve(animation);
    final covered = _xyCurve(secondaryAnimation);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return ClipRect(
          child: AnimatedBuilder(
            animation: Listenable.merge([incoming, covered]),
            child: child,
            builder: (context, child) {
              final enterAngle = (1 - incoming.value) * math.pi / 2;
              final coverAngle = covered.value * math.pi / 2;
              final matrix = Matrix4.identity();
              if (covered.value > 0) {
                // 被覆盖页绕左边缘折入屏幕（右缘远去）。
                matrix.multiply(
                  Matrix4.identity()
                    ..setEntry(3, 2, _perspective)
                    ..rotateY(-coverAngle),
                );
              }
              if (incoming.value < 1) {
                // 入场页绕右边缘从屏幕后方转平。
                matrix.multiply(
                  Matrix4.identity()
                    ..setEntry(3, 2, _perspective)
                    ..translateByDouble(width.toDouble(), 0, 0, 1)
                    ..rotateY(enterAngle)
                    ..translateByDouble(-width.toDouble(), 0, 0, 1),
                );
              }
              return Transform(transform: matrix, child: child);
            },
          ),
        );
      },
    );
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
