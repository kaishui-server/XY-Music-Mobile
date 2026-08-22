import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import 'src/core/rust_init.dart';
import 'src/core/settings.dart';
import 'src/navigation/routes.dart';
import 'src/ui/xy_theme.dart';

class XyMusicApp extends ConsumerStatefulWidget {
  const XyMusicApp({super.key});

  @override
  ConsumerState<XyMusicApp> createState() => _XyMusicAppState();
}

class _XyMusicAppState extends ConsumerState<XyMusicApp> {
  int? _cachedAccent;
  ThemeData? _lightTheme;
  ThemeData? _darkTheme;

  void _ensureThemes(int accent) {
    if (_cachedAccent == accent && _lightTheme != null) return;
    _cachedAccent = accent;
    final seed = Color(accent);
    _lightTheme = buildXyTheme(brightness: Brightness.light, accent: seed);
    _darkTheme = buildXyTheme(brightness: Brightness.dark, accent: seed);
  }

  Widget _systemUiBuilder(BuildContext context, Widget? child) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: xySystemUiOverlayStyle(Theme.of(context).brightness),
      child: child ?? const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final init = ref.watch(rustInitProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final accent = settings?.accentColor ?? 0xFFEC4141;
    final themeMode = switch (settings?.themeMode ??
        ThemeModePreference.system) {
      ThemeModePreference.light => ThemeMode.light,
      ThemeModePreference.dark => ThemeMode.dark,
      ThemeModePreference.system => ThemeMode.system,
    };
    _ensureThemes(accent);
    final theme = _lightTheme!;
    final darkTheme = _darkTheme!;

    // 初始化完成后交由 go_router 接管；未完成时展示加载/错误界面。
    if (init.hasValue) {
      return MaterialApp.router(
        title: 'XY Music',
        debugShowCheckedModeBanner: false,
        theme: theme,
        darkTheme: darkTheme,
        themeMode: themeMode,
        routerConfig: appRouter,
        builder: _systemUiBuilder,
      );
    }
    return MaterialApp(
      title: 'XY Music',
      debugShowCheckedModeBanner: false,
      theme: theme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      builder: _systemUiBuilder,
      home: init.when(
        data: (_) => const _InitLoadingScreen(),
        loading: () => const _InitLoadingScreen(),
        error: (e, _) => _InitErrorScreen(
          error: e,
          onRetry: () => ref.invalidate(rustInitProvider),
        ),
      ),
    );
  }
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
