import 'package:flutter/material.dart';

/// 封面淡入工具。
///
/// 封面从「占位」切到「真实图片」时如果直接替换，视觉上是一次生硬跳变，
/// 用户的体感是「卡了一下才冒出来」。这里统一用 [ImageFrameBuilder] 在
/// 首帧到达后做一次 220ms 的淡入，让加载过程看起来是顺滑的。
class CoverFadeIn {
  const CoverFadeIn._();

  static const Duration duration = Duration(milliseconds: 220);

  /// [placeholder] 是首帧到达前的垫底画面（切歌场景传入上一曲已渲染的
  /// 封面）。首帧到达后它不会立刻消失，而是留在新图下面一起做交叉
  /// 淡入——否则 220ms 淡入期间下方透出的是页面底色，看起来仍像闪一下
  /// 空白/占位。
  static ImageFrameBuilder frameBuilder({required Widget placeholder}) {
    return (context, child, frame, wasSynchronouslyLoaded) {
      // 同步命中（ImageCache 或已解码好的 FileImage）直接出图，
      // 不要再做淡入，否则滚动列表回滚时会整屏闪。
      if (wasSynchronouslyLoaded) return child;
      if (frame == null) return placeholder;
      return Stack(
        fit: StackFit.expand,
        children: [placeholder, _FadeInOnLoad(child: child)],
      );
    };
  }
}

class _FadeInOnLoad extends StatefulWidget {
  const _FadeInOnLoad({required this.child});

  final Widget child;

  @override
  State<_FadeInOnLoad> createState() => _FadeInOnLoadState();
}

class _FadeInOnLoadState extends State<_FadeInOnLoad>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: CoverFadeIn.duration,
      value: 0,
    );
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _opacity, child: widget.child);
  }
}
