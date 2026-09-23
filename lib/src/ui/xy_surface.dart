import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'xy_theme.dart';

class XyPageBackground extends StatelessWidget {
  const XyPageBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        gradient: dark
            ? const RadialGradient(
                center: Alignment(1.15, -1.0),
                radius: 1.05,
                colors: [Color(0x2EEC4141), Color(0x001F1F1F)],
                stops: [0, 0.7],
              )
            : const RadialGradient(
                center: Alignment(1.1, -1.0),
                radius: 1.05,
                colors: [Color(0x16EC4141), Color(0x00F5F5F5)],
                stops: [0, 0.7],
              ),
      ),
      child: child,
    );
  }
}

/// Shares the app-level decoded wallpaper with descendants such as the drawer.
/// Keeping a single decoded frame avoids a white placeholder flash each time a
/// new XyAppBackground instance (for example, the sidebar) is opened.
class XyBackgroundScope extends InheritedWidget {
  const XyBackgroundScope({
    super.key,
    required this.path,
    required this.image,
    required super.child,
  });

  final String path;
  final ui.Image? image;

  static XyBackgroundScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<XyBackgroundScope>();

  @override
  bool updateShouldNotify(XyBackgroundScope oldWidget) =>
      path != oldWidget.path || !identical(image, oldWidget.image);
}

/// 应用级背景。用户选择的图片只保存在本机应用目录，不会上传到服务器。
class XyAppBackground extends StatefulWidget {
  const XyAppBackground({
    super.key,
    required this.child,
    this.imagePath = '',
    this.blur = 18,
    this.decodedImage,
  });

  final Widget child;
  final String imagePath;
  final double blur;
  final ui.Image? decodedImage;

  @override
  State<XyAppBackground> createState() => _XyAppBackgroundState();
}

class _XyAppBackgroundState extends State<XyAppBackground> {
  Widget? _backgroundLayer;
  String? _layerPath;
  double? _layerBlur;
  ui.Image? _layerImage;
  Brightness? _layerBrightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureBackgroundLayer();
  }

  @override
  void didUpdateWidget(XyAppBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureBackgroundLayer();
  }

  void _ensureBackgroundLayer() {
    final brightness = Theme.of(context).brightness;
    final path = widget.imagePath.trim();
    final blur = widget.blur.clamp(0, 40).toDouble();
    final inherited = XyBackgroundScope.maybeOf(context);
    final decodedImage =
        widget.decodedImage ??
        (inherited?.path.trim() == path ? inherited?.image : null);
    if (_backgroundLayer != null &&
        _layerPath == path &&
        _layerBlur == blur &&
        identical(_layerImage, decodedImage) &&
        _layerBrightness == brightness) {
      return;
    }
    _layerPath = path;
    _layerBlur = blur;
    _layerImage = decodedImage;
    _layerBrightness = brightness;
    _backgroundLayer = _buildBackgroundLayer(
      path: path,
      blur: blur,
      decodedImage: decodedImage,
      brightness: brightness,
    );
  }

  Widget _buildBackgroundLayer({
    required String path,
    required double blur,
    required ui.Image? decodedImage,
    required Brightness brightness,
  }) {
    final dark = brightness == Brightness.dark;
    final hasImage = path.isNotEmpty;

    Widget image() {
      if (decodedImage != null) {
        return RawImage(
          image: decodedImage,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.low,
        );
      }
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        cacheWidth: 1440,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
        errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
      );
    }

    // 整个背景是独立的重绘边界，并且这个 Widget 实例只会在背景设置真的
    // 变化时重建。路由入场、退场和页面滚动只重绘前景，不再让手机 GPU
    // 重新合成模糊图片，避免先出现默认底色再闪出背景图。
    return RepaintBoundary(
      child: ColoredBox(
        color: dark ? XyColors.darkBackground : XyColors.lightBackground,
        child: hasImage
            ? Stack(
                fit: StackFit.expand,
                children: [
                  image(),
                  ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(
                      sigmaX: blur,
                      sigmaY: blur,
                    ),
                    child: image(),
                  ),
                  ColoredBox(
                    color: (dark ? Colors.black : Colors.white).withValues(
                      alpha: dark ? .38 : .28,
                    ),
                  ),
                ],
              )
            : const SizedBox.expand(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _ensureBackgroundLayer();
    return Stack(
      fit: StackFit.expand,
      children: [
        _backgroundLayer!,
        XyBackgroundScope(
          path: widget.imagePath.trim(),
          image: _layerImage,
          child: widget.child,
        ),
      ],
    );
  }
}

class XyPanel extends StatelessWidget {
  const XyPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = XyRadii.large,
    this.color,
    this.blurSigma = 0,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;

  /// 对面板后方内容进行模糊。配合半透明 [color] 使用可实现玻璃效果。
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final panel = DecoratedBox(
      decoration: BoxDecoration(
        color:
            color ??
            theme.colorScheme.surface.withValues(alpha: dark ? 0.9 : 0.94),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: dark ? XyColors.darkBorder : XyColors.lightBorder,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.18 : 0.05),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(padding: padding, child: child),
    );
    if (blurSigma <= 0) return panel;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter.grouped(
        filter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: panel,
      ),
    );
  }
}

/// 玻璃容器：BackdropFilter 高斯模糊 + 半透明底色。
///
/// 常驻玻璃效果，不做滚动降级（切换会造成闪屏）。使用时确保外层
/// 有局部裁剪（ClipRRect/ClipOval），否则滤镜区域会外溢。
class XyBackdropGlass extends StatelessWidget {
  const XyBackdropGlass({
    super.key,
    required this.child,
    required this.glassColor,
    this.sigma = 16,
    this.borderRadius,
  });

  /// 玻璃底色（较低不透明度，配合模糊透出后方内容）。
  final Color glassColor;

  /// 高斯模糊半径。
  final double sigma;

  /// 圆角裁剪；外层已裁剪时传 null 避免重复 ClipRRect。
  final BorderRadius? borderRadius;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    Widget content = ColoredBox(color: glassColor, child: child);
    if (sigma > 0) {
      // .grouped 构造挂到 app 根部的 BackdropGroup（app.dart）共享
      // 背景图层：普通 BackdropFilter 只能采样“同图层中绘制在自己
      // 之前”的内容，而 XyAppBackground 为性能被 RepaintBoundary
      // 隔离在独立图层，普通构造永远读不到背景（玻璃模糊全部失效）。
      // grouped 从共享图层采样，多个玻璃元素也只重采样一次。
      content = BackdropFilter.grouped(
        filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: content,
      );
    }
    final radius = borderRadius;
    if (radius != null) {
      content = ClipRRect(borderRadius: radius, child: content);
    }
    return content;
  }
}
