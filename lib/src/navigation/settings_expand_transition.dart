import 'package:flutter/material.dart';

/// 设置项 → 子页面的「卡片展开」转场时长：正向 620ms、反向 460ms，
/// 缓动 FastOutSlowIn（对齐 CurrentMusicX 的 PageContainerTransform：
/// 展开 600ms / 收起 460ms）。
const xySettingsExpandDuration = Duration(milliseconds: 620);
const xySettingsExpandReverseDuration = Duration(milliseconds: 460);

/// 设置项被点击时的源行快照：转场从该行的矩形生长为整页。
@immutable
class SettingsExpandOrigin {
  const SettingsExpandOrigin({required this.rect, required this.radius});

  /// 源行在屏幕坐标系中的矩形（转场起点）。
  final Rect rect;

  /// 源行圆角：随展开进度收平到 0。
  final double radius;
}

/// 源行快照登记表：入口行被点击时写入，设置子页面构建时取走。
///
/// 深链直达、搜索直达或从别处进入设置子页面时快照为空，路由层
/// （routes.dart 的 `_settingsExpandPage`）据此回退到全局页面切换动画。
class SettingsExpandOriginRegistry {
  SettingsExpandOriginRegistry._();

  static SettingsExpandOrigin? _pending;
  static int _pendingAt = 0;

  /// 快照有效期：点击到路由构建之间正常只有几毫秒，超时即视为陈旧数据，
  /// 避免"点了会弹层的行"留下的快照被后续无关导航误用。
  static const int _ttlMs = 1500;

  /// 记录 [context] 对应渲染对象的屏幕矩形作为展开起点。
  static void capture(BuildContext context, {double radius = 18}) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final size = renderObject.size;
    if (size.width <= 1 || size.height <= 1) return;
    _pending = SettingsExpandOrigin(
      rect: renderObject.localToGlobal(Offset.zero) & size,
      radius: radius,
    );
    _pendingAt = DateTime.now().millisecondsSinceEpoch;
  }

  /// 取走快照（消费即清空）；不存在或已陈旧时返回 null。
  ///
  /// 有效快照同时写入 [_active]：根页的挖洞裁剪（见
  /// [xySettingsRootCoverTransition]）需要与详情页同一个矩形，而 take()
  /// 只会被详情页调用一次，根页只能事后读取。陈旧 / 缺失时同步清空，
  /// 避免上一次展开的矩形被无关导航误用。
  static SettingsExpandOrigin? take() {
    final origin = _pending;
    _pending = null;
    if (origin == null) {
      _active = null;
      return null;
    }
    final age = DateTime.now().millisecondsSinceEpoch - _pendingAt;
    if (age < 0 || age > _ttlMs) {
      _active = null;
      return null;
    }
    _active = origin;
    return origin;
  }

  /// 当前生效的展开起点：由 [take] 写入，根页挖洞裁剪读取，
  /// 覆盖转场从正数归零（详情页完全收尾）时清空。
  static SettingsExpandOrigin? get active => _active;
  static SettingsExpandOrigin? _active;

  /// 根页上一帧上报的覆盖进度（见 [updateCoverProgress]）。
  static double _lastCoverProgress = 0;

  /// 根页每帧上报覆盖它的详情页转场进度；进度**从正数归零**（转场完全
  /// 收尾）时清空生效起点。
  ///
  /// 不能见 0 就清：详情页刚 push 的首帧 secondaryAnimation 同样是 0，
  /// 无脑清会把 [take] 刚写入的起点抹掉——展开期表现为「碰巧」没事
  /// （origin 为 null 走旧的显隐口径），收起阶段根页就拿不到矩形、退回
  /// 整页绘制，文字透过透明的详情页叠在一起（文字重叠复现的根因）。
  static void updateCoverProgress(double value) {
    if (value <= 0) {
      if (_lastCoverProgress > 0) {
        _active = null;
      }
      _lastCoverProgress = 0;
      return;
    }
    _lastCoverProgress = value;
  }
}

/// 设置子页面的「页面展开」转场：源行矩形在 [xySettingsExpandDuration] 内
/// 生长为全屏、圆角收平，收起为完全倒序。
///
/// 过渡内容就是**详情页本体**（设置项 + 背景）——不做内容淡入淡出窗口，
/// 页面直接参与矩形的生长 / 收缩。卡片形态只存在于贴近设置条目的首尾：
/// 刚要展开时是一个带源行圆角的小矩形视口（卡片观感），随着进度推进矩形
/// 迅速放大为整页；收起对称，末段缩回源行大小。
///
/// 矩形之外什么都不画（下层根页按同一矩形做互补挖洞裁剪，见
/// [xySettingsRootCoverTransition]），两层拼起来就是完整的 container
/// transform：根页被矩形覆盖的部分让位给详情页，矩形缩到哪根页就露出
/// 到哪。壳层浮层（自定义底栏、迷你播放条）绘制在导航器之上，不归本
/// 转场管，始终保持显示。
///
/// 缺少起点快照时不会走到这里：路由层（routes.dart 的 `_settingsExpandPage`）
/// 会直接回退到全局「页面切换动画」。
Widget xySettingsExpandTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
  SettingsExpandOrigin? origin,
) {
  return AnimatedBuilder(
    animation: animation,
    child: RepaintBoundary(child: child),
    builder: (context, child) {
      final page = child!;
      // 落定后裸返回页面本体：不再保留裁剪层，既省掉常驻重绘，也从结构上
      // 保证不会遮挡点击。
      if (animation.value >= 1) return page;
      final t = Curves.fastOutSlowIn.transform(animation.value.clamp(0.0, 1.0));
      return LayoutBuilder(
        builder: (context, constraints) {
          final full = Offset.zero & constraints.biggest;
          // 无快照时的兜底起点（防御性分支，正常不会命中）：屏幕中上部
          // 一块卡片尺寸矩形，避免退化成"从 0 面积生长"的怪异观感。
          final startRect =
              origin?.rect ??
              Rect.fromCenter(
                center: Offset(full.width / 2, full.height * .42),
                width: full.width - 32,
                height: 56,
              );
          final rect = Rect.lerp(startRect, full, t) ?? full;
          // 圆角只用源行圆角，随展开进度收平到整页。
          final radius = (origin?.radius ?? 18) * (1 - t);
          // 详情页本体随矩形裁剪：矩形之内是页面（设置项 + 背景），
          // 矩形之外什么都不画，留给根页露出。
          return ClipPath(
            clipper: _ExpandingRectClipper(rect: rect, radius: radius),
            child: page,
          );
        },
      );
    },
  );
}

/// 设置根页被展开详情页覆盖时的二级转场：按同一矩形做**挖洞互补裁剪**——
/// 矩形之外绘制根页（作为卡片缩回的落点，矩形缩到哪就露出到哪），矩形之内
/// 留给详情页（本页在该区域不绘制，避免两层设置项文字叠加）。
///
/// 收尾处理：覆盖进度从正数归零（详情页转场完全收尾）时清空生效起点；
/// 被普通页面覆盖（无展开起点）时维持旧的显隐口径（展开中隐藏、收起露出）。
Widget xySettingsRootCoverTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  return AnimatedBuilder(
    animation: secondaryAnimation,
    child: child,
    builder: (context, child) {
      final secondary = secondaryAnimation;
      // 每帧上报覆盖进度：进度从正数归零（详情页转场完全收尾）时清空
      // 生效起点（见 [SettingsExpandOriginRegistry.updateCoverProgress]
      // 的注释——首帧不能清，否则收起阶段拿不到矩形）。
      SettingsExpandOriginRegistry.updateCoverProgress(secondary.value);
      if (secondary.value <= 0) {
        return child!;
      }
      final origin = SettingsExpandOriginRegistry.active;
      // 非展开覆盖（普通页面盖在设置根页上）：布尔阶跃显隐——0 值时 Opacity
      // 直接跳过绘制，不产生每帧 saveLayer 的合成开销。
      if (origin == null) {
        final hidden =
            secondary.status == AnimationStatus.forward ||
            secondary.value >= 1;
        return Opacity(opacity: hidden ? 0.0 : 1.0, child: child);
      }
      final t = Curves.fastOutSlowIn.transform(secondary.value.clamp(0.0, 1.0));
      return LayoutBuilder(
        builder: (context, constraints) {
          final full = Offset.zero & constraints.biggest;
          final rect = Rect.lerp(origin.rect, full, t) ?? full;
          final radius = origin.radius * (1 - t);
          // 已完全覆盖（矩形=全屏）时挖洞为空，本页自然不绘制，无需特判。
          return ClipPath(
            clipper: _HoleRoundedRectClipper(rect: rect, radius: radius),
            child: child,
          );
        },
      );
    },
  );
}

/// 按插值矩形 + 圆角裁剪展开容器（矩形**之内**）。
class _ExpandingRectClipper extends CustomClipper<Path> {
  const _ExpandingRectClipper({required this.rect, required this.radius});

  final Rect rect;
  final double radius;

  @override
  Path getClip(Size size) {
    // 圆角收平到 0 之后用直边矩形裁剪，省掉圆角路径的栅格化开销。
    if (radius <= .5) return Path()..addRect(rect);
    final effective = radius.clamp(0.0, rect.shortestSide / 2);
    return Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(effective)));
  }

  @override
  bool shouldReclip(_ExpandingRectClipper oldClipper) =>
      oldClipper.rect != rect || oldClipper.radius != radius;
}

/// 全屏挖去圆角矩形（矩形**之外**）：根页互补裁剪用。
class _HoleRoundedRectClipper extends CustomClipper<Path> {
  const _HoleRoundedRectClipper({required this.rect, required this.radius});

  final Rect rect;
  final double radius;

  @override
  Path getClip(Size size) {
    final outer = Path()..addRect(Offset.zero & size);
    final effective = radius.clamp(0.0, rect.shortestSide / 2);
    final hole = radius <= .5
        ? (Path()..addRect(rect))
        : (Path()
          ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(effective))));
    return Path.combine(PathOperation.difference, outer, hole);
  }

  @override
  bool shouldReclip(_HoleRoundedRectClipper oldClipper) =>
      oldClipper.rect != rect || oldClipper.radius != radius;
}
