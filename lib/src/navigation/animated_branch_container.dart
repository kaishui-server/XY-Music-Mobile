import 'package:flutter/material.dart';

/// 一级页面分支容器。
///
/// 前一页和下一页同步水平移动，边界始终相接；所有非活动分支仍保留在树中，
/// 因此滚动位置、Tab 状态和各页面 Navigator 都不会丢失。
class AnimatedBranchContainer extends StatefulWidget {
  const AnimatedBranchContainer({
    super.key,
    required this.currentIndex,
    required this.children,
  });

  final int currentIndex;
  final List<Widget> children;

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
    _direction = widget.currentIndex > oldWidget.currentIndex ? 1 : -1;
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
    final begin = active ? Offset(_direction.toDouble(), 0) : Offset.zero;
    final end = active ? Offset.zero : Offset(-_direction.toDouble(), 0);

    return Offstage(
      offstage: !visible,
      child: IgnorePointer(
        ignoring: !active,
        child: SlideTransition(
          position: Tween<Offset>(begin: begin, end: end).animate(movement),
          child: widget.children[index],
        ),
      ),
    );
  }
}
