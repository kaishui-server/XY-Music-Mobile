import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/core/rust_init.dart';
import 'src/core/settings.dart';
import 'src/library/library_provider.dart';
import 'src/navigation/routes.dart';
import 'src/ui/xy_theme.dart';
import 'src/ui/xy_surface.dart';

/// 在 Flutter 第一帧之前读取并解码自定义背景。
///
/// 如果等 Riverpod 的异步设置加载完再读取图片，启动和 Android 恢复渲染表面时
/// 会先绘制一帧默认底色。预加载结果直接交给应用根节点，第一帧即可使用。
class XyStartupBackground {
  const XyStartupBackground({this.path = '', this.blur = 18, this.image});

  final String path;
  final double blur;
  final ui.Image? image;
}

Future<XyStartupBackground> loadXyStartupBackground() async {
  try {
    final preferences = await SharedPreferences.getInstance();
    final path = (preferences.getString('customBackgroundPath') ?? '').trim();
    final blur = (preferences.getDouble('customBackgroundBlur') ?? 18)
        .clamp(0, 40)
        .toDouble();
    if (path.isEmpty) return XyStartupBackground(blur: blur);
    final file = File(path);
    if (!await file.exists()) return XyStartupBackground(blur: blur);
    // 只限制解码宽度，不能同时传入固定高度：两者同时指定会把长图
    // 强制解码成正方形，随后在预览和实际背景中表现为横向拉伸。
    // 仅指定宽度时 Flutter 会按原始比例计算高度。
    final codec = await ui.instantiateImageCodec(
      await file.readAsBytes(),
      targetWidth: 1440,
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    return XyStartupBackground(path: path, blur: blur, image: frame.image);
  } catch (_) {
    return const XyStartupBackground();
  }
}

class XyMusicApp extends ConsumerStatefulWidget {
  const XyMusicApp({super.key, this.startupBackground});

  final XyStartupBackground? startupBackground;

  @override
  ConsumerState<XyMusicApp> createState() => _XyMusicAppState();
}

class _XyMusicAppState extends ConsumerState<XyMusicApp> {
  int? _cachedAccent;
  int? _cachedLightDynamicHash;
  int? _cachedDarkDynamicHash;
  ThemeData? _lightTheme;
  ThemeData? _darkTheme;
  String? _precachedBackgroundPath;
  String? _decodedBackgroundPath;
  ui.Image? _decodedBackgroundImage;
  int _backgroundLoadGeneration = 0;

  @override
  void initState() {
    super.initState();
    final startup = widget.startupBackground;
    if (startup?.image != null && startup!.path.isNotEmpty) {
      _precachedBackgroundPath = startup.path;
      _decodedBackgroundPath = startup.path;
      _decodedBackgroundImage = startup.image;
    }
    // 每次进入软件即触发本地音乐后台重扫（LibraryNotifier 构造时执行），
    // 不等用户打开本地音乐页。
    Future.microtask(() => ref.read(libraryProvider.notifier));
  }

  @override
  void dispose() {
    _decodedBackgroundImage?.dispose();
    super.dispose();
  }

  void _ensureThemes(
    int accent, {
    ColorScheme? lightDynamic,
    ColorScheme? darkDynamic,
  }) {
    if (_cachedAccent == accent &&
        _cachedLightDynamicHash == lightDynamic?.hashCode &&
        _cachedDarkDynamicHash == darkDynamic?.hashCode &&
        _lightTheme != null) {
      return;
    }
    _cachedAccent = accent;
    _cachedLightDynamicHash = lightDynamic?.hashCode;
    _cachedDarkDynamicHash = darkDynamic?.hashCode;
    final seed = Color(accent);
    _lightTheme = buildXyTheme(
      brightness: Brightness.light,
      accent: seed,
      dynamicColorScheme: lightDynamic,
    );
    _darkTheme = buildXyTheme(
      brightness: Brightness.dark,
      accent: seed,
      dynamicColorScheme: darkDynamic,
    );
  }

  Widget _systemUiBuilder(BuildContext context, Widget? child) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: xySystemUiOverlayStyle(Theme.of(context).brightness),
      child: child ?? const SizedBox.shrink(),
    );
  }

  void _precacheBackground(String path) {
    if (path.isEmpty) {
      _backgroundLoadGeneration++;
      _precachedBackgroundPath = null;
      _decodedBackgroundPath = null;
      final old = _decodedBackgroundImage;
      _decodedBackgroundImage = null;
      old?.dispose();
      return;
    }
    if (path == _decodedBackgroundPath || path == _precachedBackgroundPath) {
      return;
    }
    final generation = ++_backgroundLoadGeneration;
    _precachedBackgroundPath = path;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _backgroundLoadGeneration) return;
      precacheImage(FileImage(File(path)), context).ignore();
      _decodeBackground(path, generation);
    });
  }

  Future<void> _decodeBackground(String path, int generation) async {
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1440);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted ||
          generation != _backgroundLoadGeneration ||
          _precachedBackgroundPath != path) {
        frame.image.dispose();
        return;
      }
      final old = _decodedBackgroundImage;
      _decodedBackgroundImage = frame.image;
      _decodedBackgroundPath = path;
      old?.dispose();
      setState(() {});
    } catch (_) {
      if (generation == _backgroundLoadGeneration &&
          _precachedBackgroundPath == path) {
        _decodedBackgroundPath = path;
      }
    } finally {}
  }

  @override
  Widget build(BuildContext context) {
    final init = ref.watch(rustInitProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final startup = widget.startupBackground;
    final backgroundPath =
        settings?.customBackgroundPath.trim() ?? startup?.path ?? '';
    final backgroundBlur =
        settings?.customBackgroundBlur ?? startup?.blur ?? 18.0;
    _precacheBackground(backgroundPath);
    final accent = settings?.accentColor ?? 0xFFEC4141;
    final themeMode = switch (settings?.themeMode ??
        ThemeModePreference.system) {
      ThemeModePreference.light => ThemeMode.light,
      ThemeModePreference.dark => ThemeMode.dark,
      ThemeModePreference.system => ThemeMode.system,
    };
    return _RefreshingDynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final dynamicEnabled = settings?.dynamicColor == true;
        _ensureThemes(
          accent,
          lightDynamic: dynamicEnabled ? lightDynamic : null,
          darkDynamic: dynamicEnabled ? darkDynamic : null,
        );
        final theme = _lightTheme!;
        final darkTheme = _darkTheme!;
        Widget appBuilder(BuildContext context, Widget? child) =>
            _systemUiBuilder(
              context,
              BackdropGroup(
                child: XyAppBackground(
                  imagePath: backgroundPath,
                  blur: backgroundBlur,
                  decodedImage: _decodedBackgroundPath == backgroundPath
                      ? _decodedBackgroundImage
                      : null,
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            );

        // 初始化完成后交由 go_router 接管；未完成时展示加载/错误界面。
        if (init.hasValue) {
          return MaterialApp.router(
            title: 'XY Music',
            debugShowCheckedModeBanner: false,
            theme: theme,
            darkTheme: darkTheme,
            themeMode: themeMode,
            routerConfig: appRouter,
            builder: appBuilder,
          );
        }
        return MaterialApp(
          title: 'XY Music',
          debugShowCheckedModeBanner: false,
          theme: theme,
          darkTheme: darkTheme,
          themeMode: themeMode,
          builder: appBuilder,
          home: init.when(
            data: (_) => const _InitLoadingScreen(),
            loading: () => const _InitLoadingScreen(),
            error: (e, _) => _InitErrorScreen(
              error: e,
              onRetry: () => ref.invalidate(rustInitProvider),
            ),
          ),
        );
      },
    );
  }
}

/// dynamic_color 默认只在控件首次创建时读取一次系统配色。
/// Android 用户更换系统壁纸后，应用通常只是从后台恢复，并不会重建根
/// Widget，因此原来的主题色会一直停留在旧壁纸。这里在每次回到前台时
/// 重新读取 Material You 调色板，同时保留上一次结果直到新结果返回，避免
/// 刷新期间短暂闪回默认红色主题。
class _RefreshingDynamicColorBuilder extends StatefulWidget {
  const _RefreshingDynamicColorBuilder({required this.builder});

  final Widget Function(ColorScheme? lightDynamic, ColorScheme? darkDynamic)
  builder;

  @override
  State<_RefreshingDynamicColorBuilder> createState() =>
      _RefreshingDynamicColorBuilderState();
}

class _RefreshingDynamicColorBuilderState
    extends State<_RefreshingDynamicColorBuilder>
    with WidgetsBindingObserver {
  ColorScheme? _light;
  ColorScheme? _dark;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    _loading = true;
    try {
      final corePalette = await DynamicColorPlugin.getCorePalette();
      if (!mounted) return;
      if (corePalette != null) {
        setState(() {
          _light = corePalette.toColorScheme();
          _dark = corePalette.toColorScheme(brightness: Brightness.dark);
        });
        return;
      }
      final accent = await DynamicColorPlugin.getAccentColor();
      if (!mounted) return;
      if (accent != null) {
        setState(() {
          _light = ColorScheme.fromSeed(
            seedColor: accent,
            brightness: Brightness.light,
          );
          _dark = ColorScheme.fromSeed(
            seedColor: accent,
            brightness: Brightness.dark,
          );
        });
      }
    } catch (_) {
      // 不支持动态取色的平台保持 null，让外层继续使用固定主题。
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(_light, _dark);
}

class _InitLoadingScreen extends StatelessWidget {
  const _InitLoadingScreen();
  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _InitErrorScreen extends StatelessWidget {
  const _InitErrorScreen({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 16),
              const Text(
                '核心初始化失败',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text('$error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
