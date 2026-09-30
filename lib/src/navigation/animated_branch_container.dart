import 'package:flutter/material.dart';

import '../core/settings.dart';
import 'animated_page_route.dart';

/// 一级页面分支容器。
///
/// 切换效果跟随设置中的页面切换模式（xyPageTransitionMode），与路由
/// 过渡保持同一风格；所有非活动分支仍保留在树中，因此滚动位置、
/// Tab 状态和各页面 Navigator 都不会丢失。切换方向由路由层按用户
/// 可见的目的地顺序（底栏/侧栏）提供，而非分支下标差。
class AnimatedBranchContainer extends StatefulWidget {
  const AnimatedBranchContainer({
    super.key,
    required this.currentIndex,
    required this.children,
    this.direction,
  });

  final int currentIndex;
  final List<Widget> children;

  /// 分支切换方向：+1 新页从右侧进入，-1 从左侧进入。null 时退回
  /// 分支下标差推断。
  final int? direction;

  @override
  State<AnimatedBranchContainer> createState() =>
      _AnimatedBranchContainerState();
}

class _AnimatedBranchContainerState extends State<AnimatedBranchContainer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  int? _previousIndex;
  int _direction = 1;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 280),
          value: 1,
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed && _previousIndex != null) {
            setState(() => _previousIndex = null);
          }
        });
  }

  @override
  void didUpdateWidget(AnimatedBranchContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex == widget.currentIndex) return;
    _previousIndex = oldWidget.currentIndex;
    _direction =
        widget.direction ??
        (widget.currentIndex > oldWidget.currentIndex ? 1 : -1);
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final movement = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (var index = 0; index < widget.children.length; index++)
            _branchLayer(index, movement),
        ],
      ),
    );
  }

  Widget _branchLayer(int index, Animation<double> movement) {
    final active = index == widget.currentIndex;
    final outgoing = index == _previousIndex;
    final visible = active || outgoing;

    return Offstage(
      offstage: !visible,
      child: IgnorePointer(
        ignoring: !active,
        child: _modeTransition(movement, active, widget.children[index]),
      ),
    );
  }

  /// 按设置中的页面切换模式分发底栏分支过渡。
  Widget _modeTransition(
    Animation<double> movement,
    bool active,
    Widget child,
  ) {
    switch (xyPageTransitionMode) {
      case PageTransitionMode.slide:
        final begin = active ? Offset(_direction.toDouble(), 0) : Offset.zero;
        final end = active ? Offset.zero : Offset(-_direction.toDouble(), 0);
        return SlideTransition(
          position: Tween<Offset>(begin: begin, end: end).animate(movement),
          child: child,
        );
      case PageTransitionMode.stack:
        return _stackTransition(movement, active, child);
      case PageTransitionMode.fade:
        return _fadeTransition(movement, active, child);
    }
  }

  /// 层叠：入场页从切换方向滑入并渐显，离场页反向错开、轻微缩小并渐隐。
  Widget _stackTransition(
    Animation<double> movement,
    bool active,
    Widget child,
  ) {
    if (active) {
      return SlideTransition(
        position:
            Tween<Offset>(
              begin: Offset(_direction.toDouble(), 0),
              end: Offset.zero,
            ).animate(movement),
        child: FadeTransition(opacity: movement, child: child),
      );
    }
    return SlideTransition(
      position:
          Tween<Offset>(
            begin: Offset.zero,
            end: Offset(-_direction * .3, 0),
          ).animate(movement),
      child: ScaleTransition(
        scale: Tween<double>(begin: 1, end: .95).animate(movement),
        child: FadeTransition(opacity: ReverseAnimation(movement), child: child),
      ),
    );
  }

  /// 淡入淡出：两页交叉淡化。
  Widget _fadeTransition(
    Animation<double> movement,
    bool active,
    Widget child,
  ) {
    return FadeTransition(
      opacity: active ? movement : ReverseAnimation(movement),
      child: child,
    );
  }
}
