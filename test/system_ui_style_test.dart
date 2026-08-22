import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/ui/xy_theme.dart';

void main() {
  test('浅色和深色主题始终使用透明系统状态栏', () {
    final light = xySystemUiOverlayStyle(Brightness.light);
    final dark = xySystemUiOverlayStyle(Brightness.dark);

    expect(light.statusBarColor, Colors.transparent);
    expect(dark.statusBarColor, Colors.transparent);
    expect(light.systemStatusBarContrastEnforced, isFalse);
    expect(dark.systemStatusBarContrastEnforced, isFalse);
    expect(light.statusBarIconBrightness, Brightness.dark);
    expect(dark.statusBarIconBrightness, Brightness.light);
  });

  test('AppBar 使用与主题明暗一致的透明状态栏样式', () {
    final lightTheme = buildXyTheme(
      brightness: Brightness.light,
      accent: XyColors.accent,
    );
    final darkTheme = buildXyTheme(
      brightness: Brightness.dark,
      accent: XyColors.accent,
    );

    expect(
      lightTheme.appBarTheme.systemOverlayStyle?.statusBarColor,
      Colors.transparent,
    );
    expect(
      lightTheme.appBarTheme.systemOverlayStyle?.statusBarIconBrightness,
      Brightness.dark,
    );
    expect(
      darkTheme.appBarTheme.systemOverlayStyle?.statusBarColor,
      Colors.transparent,
    );
    expect(
      darkTheme.appBarTheme.systemOverlayStyle?.statusBarIconBrightness,
      Brightness.light,
    );
  });
}
