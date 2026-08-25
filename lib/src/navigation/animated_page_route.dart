import 'package:flutter/material.dart';

const xyPageTransitionDuration = Duration(milliseconds: 280);
const xyPageReverseTransitionDuration = Duration(milliseconds: 240);

/// 前后页面同步水平推移。两个页面的边界始终相接，因此透明页面既能露出
/// 应用级自定义背景，也不会让两页文字在同一位置交叠。
Widget xyHorizontalPageTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  final incoming = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  final outgoing = CurvedAnimation(
    parent: secondaryAnimation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
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
        ).animate(outgoing),
        child: child,
      ),
    ),
  );
}

class XyAnimatedPageRoute<T> extends PageRouteBuilder<T> {
  XyAnimatedPageRoute({required WidgetBuilder builder, super.settings})
    : super(
        transitionDuration: xyPageTransitionDuration,
        reverseTransitionDuration: xyPageReverseTransitionDuration,
        pageBuilder: (context, animation, secondaryAnimation) =>
            builder(context),
        transitionsBuilder: xyHorizontalPageTransition,
      );
}
