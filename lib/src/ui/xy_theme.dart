import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 从电脑端提取出的 XY Music 视觉令牌。
abstract final class XyColors {
  static const accent = Color(0xFFEC4141);

  static const darkBackground = Color(0xFF1F1F1F);
  static const darkSurface = Color(0xFF262626);
  static const darkSurfaceRaised = Color(0xFF303030);
  static const darkBorder = Color(0x1FFFFFFF);

  static const lightBackground = Color(0xFFF5F5F5);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightSurfaceRaised = Color(0xFFF0F0F0);
  static const lightBorder = Color(0x14000000);
}

abstract final class XyRadii {
  static const small = 8.0;
  static const medium = 12.0;
  static const large = 18.0;
  static const extraLarge = 24.0;
}

class _XyNoPageTransitionsBuilder extends PageTransitionsBuilder {
  const _XyNoPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

SystemUiOverlayStyle xySystemUiOverlayStyle(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    statusBarBrightness: brightness,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: dark
        ? Brightness.light
        : Brightness.dark,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  );
}

ThemeData buildXyTheme({
  required Brightness brightness,
  required Color accent,
}) {
  final dark = brightness == Brightness.dark;
  final background = dark ? XyColors.darkBackground : XyColors.lightBackground;
  final surface = dark ? XyColors.darkSurface : XyColors.lightSurface;
  final raised = dark
      ? XyColors.darkSurfaceRaised
      : XyColors.lightSurfaceRaised;
  final border = dark ? XyColors.darkBorder : XyColors.lightBorder;
  final onSurface = dark ? Colors.white : const Color(0xFF202020);
  final muted = dark ? const Color(0xFFA9A9A9) : const Color(0xFF686868);

  final scheme =
      ColorScheme.fromSeed(
        seedColor: accent,
        brightness: brightness,
        surface: surface,
      ).copyWith(
        primary: accent,
        onPrimary: Colors.white,
        surface: surface,
        onSurface: onSurface,
        onSurfaceVariant: muted,
        outline: border,
        outlineVariant: border,
        surfaceContainerLowest: background,
        surfaceContainerLow: surface,
        surfaceContainer: surface,
        surfaceContainerHigh: raised,
        surfaceContainerHighest: raised,
      );

  final base = ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    // 由应用级 XyAppBackground 绘制纯色或用户自定义背景，页面 Scaffold
    // 保持透明后才能让背景图贯穿所有移动端页面。
    scaffoldBackgroundColor: Colors.transparent,
    // 页面背景由 Navigator 外侧的常驻背景层负责。禁用整页路由动画，避免
    // 退场页面的默认 Material 底色在 200~300ms 内覆盖自定义背景。
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _XyNoPageTransitionsBuilder(),
        TargetPlatform.iOS: _XyNoPageTransitionsBuilder(),
        TargetPlatform.macOS: _XyNoPageTransitionsBuilder(),
        TargetPlatform.windows: _XyNoPageTransitionsBuilder(),
        TargetPlatform.linux: _XyNoPageTransitionsBuilder(),
        TargetPlatform.fuchsia: _XyNoPageTransitionsBuilder(),
      },
    ),
    useMaterial3: true,
  );

  return base.copyWith(
    splashFactory: InkSparkle.splashFactory,
    dividerColor: border,
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Colors.transparent,
      foregroundColor: onSurface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      systemOverlayStyle: xySystemUiOverlayStyle(brightness),
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        color: onSurface,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
    ),
    textTheme: base.textTheme.copyWith(
      displaySmall: base.textTheme.displaySmall?.copyWith(
        color: onSurface,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.2,
      ),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        color: onSurface,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        color: onSurface,
        fontWeight: FontWeight.w700,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        color: onSurface,
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(color: onSurface),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: raised,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      hintStyle: TextStyle(color: muted, fontSize: 14),
      prefixIconColor: muted,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(XyRadii.medium),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(XyRadii.medium),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(XyRadii.medium),
        borderSide: BorderSide(color: accent, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 44),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(XyRadii.medium),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        foregroundColor: onSurface,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: accent,
      thumbColor: accent,
      overlayColor: accent.withValues(alpha: 0.12),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(XyRadii.large),
        side: BorderSide(color: border),
      ),
    ),
  );
}
