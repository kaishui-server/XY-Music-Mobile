import 'package:flutter/material.dart';

import 'animated_page_route.dart';

/// 设置项 → 子页面的「卡片展开」转场时长：正向 620ms、反向 460ms，
/// 缓动 FastOutSlowIn（对齐 CurrentMusicX 的 PageContainerTransform：
/// 展开 600ms / 收起 460ms）。
const xySettingsExpandDuration = Duration(milliseconds: 620);
const xySettingsExpandReverseDuration = Duration(milliseconds: 460);

/// 设置项被点击时的源行快照：转场从该行的矩形生长为整页。
@immutable
class SettingsExpandOrigin {
  const SettingsExpandOrigin({
    required this.rect,
    required this.color,
    required this.radius,
  });

  /// 源行在屏幕坐标系中的矩形（转场起点）。
  final Rect rect;

  /// 源行所在卡片的底色：展开首帧用它填充容器，避免从卡片切到页面时闪白。
  final Color color;

  /// 源卡片圆角：随展开进度收平到 0。
  final double radius;
}

/// 源行快照登记表：入口行被点击时写入，设置子页面构建时取走。
///
/// 深链直达、搜索直达或从别处进入设置子页面时快照为空，转场自动回退到
/// 全局页面切换模式，行为与改造前一致。
class SettingsExpandOriginRegistry {
  SettingsExpandOriginRegistry._();

  static SettingsExpandOrigin? _pending;
  static int _pendingAt = 0;

  /// 快照有效期：点击到路由构建之间正常只有几毫秒，超时即视为陈旧数据，
  /// 避免"点了会弹层的行"留下的快照被后续无关导航误用。
  static const int _ttlMs = 1500;

  /// 记录 [context] 对应渲染对象的屏幕矩形作为展开起点。
  static void capture(
    BuildContext context, {
    required Color color,
    double radius = 18,
  }) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final size = renderObject.size;
    if (size.width <= 1 || size.height <= 1) return;
    _pending = SettingsExpandOrigin(
      rect: renderObject.localToGlobal(Offset.zero) & size,
      color: color,
      radius: radius,
    );
    _pendingAt = DateTime.now().millisecondsSinceEpoch;
  }

  /// 取走快照（消费即清空）；不存在或已陈旧时返回 null。
  static SettingsExpandOrigin? take() {
    final origin = _pending;
    _pending = null;
    if (origin == null) return null;
    final age = DateTime.now().millisecondsSinceEpoch - _pendingAt;
    if (age < 0 || age > _ttlMs) return null;
    return origin;
  }
}

/// 设置子页面的「页面展开」转场：源行矩形在 [xySettingsExpandDuration]
/// 内生长为全屏、圆角收平、页面内容在中段淡入，下层页面随进度压暗 14%。
/// 收起为完全倒序。缺少起点快照时回退到全局页面切换模式。
Widget xySettingsExpandTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
  SettingsExpandOrigin? origin,
) {
  if (origin == null) {
    return xyPageTransition(context, animation, secondaryAnimation, child);
  }
  return AnimatedBuilder(
    animation: animation,
    child: RepaintBoundary(child: child),
    builder: (context, child) {
      // 落定后裸返回页面本体：不保留裁剪层与遮罩层，杜绝常驻重绘开销，
      // 也从结构上保证它们不可能遮挡点击。
      if (animation.value >= 1) return child!;
      final t = Curves.fastOutSlowIn.transform(
        animation.value.clamp(0.0, 1.0),
      );
      return LayoutBuilder(
        builder: (context, constraints) {
          final full = Offset.zero & constraints.biggest;
          final rect = Rect.lerp(origin.rect, full, t) ?? full;
          // 页面内容在 t≈0.12 后开始显影，t≈0.62 时完全清晰：前段看着
          // 卡片"长成"容器，后段才是新页面浮现，与参考实现同节奏。
          final contentOpacity = ((t - .12) / .5).clamp(0.0, 1.0);
          return Stack(
            fit: StackFit.expand,
            children: [
              // 源页面仍在底层：随展开进度逐渐压暗。
              IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: .14 * t),
                ),
              ),
              ClipPath(
                clipper: _ExpandingRectClipper(
                  rect: rect,
                  radius: origin.radius * (1 - t),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 容器底色取源卡片色，页面内容淡入前先由它占位。
                    ColoredBox(color: origin.color),
                    Opacity(opacity: contentOpacity, child: child!),
                  ],
                ),
              ),
            ],
          );
        },
      );
    },
  );
}

/// 按插值矩形 + 圆角裁剪展开容器。
class _ExpandingRectClipper extends CustomClipper<Path> {
  const _ExpandingRectClipper({required this.rect, required this.radius});

  final Rect rect;
  final double radius;

  @override
  Path getClip(Size size) {
    final effective = radius.clamp(0.0, rect.shortestSide / 2);
    return Path()
      ..addRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(effective)),
      );
  }

  @override
  bool shouldReclip(_ExpandingRectClipper oldClipper) =>
      oldClipper.rect != rect || oldClipper.radius != radius;
}
