import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/core/rust_init.dart';
import 'src/deeplink/deep_link_handler.dart';
import 'src/core/settings.dart';
import 'src/navigation/animated_page_route.dart';
import 'src/library/library_provider.dart';
import 'src/plugins/plugin_runtime.dart';
import 'src/player/mini_player_overlay.dart';
import 'src/player/player_provider.dart';
import 'src/navigation/routes.dart';
import 'src/ui/xy_theme.dart';
import 'src/ui/xy_surface.dart';
import 'src/widgets/top_notice.dart';
import 'src/widgets/welcome_overlay.dart';

/// 应用固定中文 locale：系统组件（长按菜单等）与应用文案保持一致。
const _zhLocale = Locale('zh', 'CN');

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

class _XyMusicAppState extends ConsumerState<XyMusicApp>
    with WidgetsBindingObserver {
  int? _cachedAccent;
  String? _cachedFontFamily;
  int? _cachedLightDynamicHash;
  int? _cachedDarkDynamicHash;
  ThemeData? _lightTheme;
  ThemeData? _darkTheme;
  String? _precachedBackgroundPath;
  String? _decodedBackgroundPath;
  ui.Image? _decodedBackgroundImage;
  int _backgroundLoadGeneration = 0;

  /// 视口“全高”记录，仅在视口变大（键盘收起 / 首次布局）时刷新。
  /// 部分系统（Android 15+ 上 adjustResize 与 edge-to-edge 并存）既压缩了
  /// 原生视图高度、又上报了 IME insets：页面 Scaffold 再按 insets 避让一次
  /// 等于双重避让，表单被推出屏幕，键盘上方空出一块与键盘等大的区域
  /// （浅色背景下表现为“白色遮挡”）。检测到视口高度明显缩水即说明原生侧
  /// 已经 resize，将上报给子树的 insets 归零，避免双重计算。
  Size? _viewportWithoutKeyboard;
  Timer? _pluginRuntimeWarmupTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final startup = widget.startupBackground;
    if (startup?.image != null && startup!.path.isNotEmpty) {
      _precachedBackgroundPath = startup.path;
      _decodedBackgroundPath = startup.path;
      _decodedBackgroundImage = startup.image;
    }
    // 每次进入软件即触发本地音乐后台重扫（LibraryNotifier 构造时执行），
    // 不等用户打开本地音乐页。
    Future.microtask(() => ref.read(libraryProvider.notifier));
    // 预热插件 QuickJS 运行时（约 800KB 引导 JS）：放在启动 5 秒后的
    // 空闲期，避免冷启动开销叠加在用户第一次点歌的音源解析路径上。
    _pluginRuntimeWarmupTimer = Timer(
      const Duration(seconds: 5),
      () => unawaited(
        ref.read(pluginRuntimeProvider).warmupRuntime(),
      ),
    );
    // 分享深链（xymusic://song?...）：注册原生回调 + 取回冷启动深链。
    Future.microtask(() => XyDeepLink.init(ref, appRouter));
    // 迷你播放器悬浮窗桥：接收原生按钮/进度条操作与通知栏单击回调。
    MiniPlayerOverlayBridge.init(ref);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pluginRuntimeWarmupTimer?.cancel();
    _decodedBackgroundImage?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退到后台时清空解码图片缓存：封面解码纹理是后台常驻内存的大头。
    // 正在显示的图片由各自的 ImageStream 句柄继续持有，不受清空影响；
    // 回前台后列表滚动到不可见再恢复的条目按需重新解码（本地封面有
    // 磁盘缓存，网络封面走 HTTP 缓存）。
    if (state == AppLifecycleState.hidden) {
      PaintingBinding.instance.imageCache.clear();
    }
  }

  @override
  void didHaveMemoryPressure() {
    // 系统内存吃紧（低端机/后台进程回收前）时主动释放解码图片缓存。
    PaintingBinding.instance.imageCache.clear();
  }

  void _ensureThemes(
    int accent, {
    ColorScheme? lightDynamic,
    ColorScheme? darkDynamic,
    String fontFamily = '',
  }) {
    if (_cachedAccent == accent &&
        _cachedFontFamily == fontFamily &&
        _cachedLightDynamicHash == lightDynamic?.hashCode &&
        _cachedDarkDynamicHash == darkDynamic?.hashCode &&
        _lightTheme != null) {
      return;
    }
    _cachedAccent = accent;
    _cachedFontFamily = fontFamily;
    _cachedLightDynamicHash = lightDynamic?.hashCode;
    _cachedDarkDynamicHash = darkDynamic?.hashCode;
    final seed = Color(accent);
    // 空字符串表示系统默认字体。
    final family = fontFamily.isEmpty ? null : fontFamily;
    _lightTheme = buildXyTheme(
      brightness: Brightness.light,
      accent: seed,
      dynamicColorScheme: lightDynamic,
      fontFamily: family,
    );
    _darkTheme = buildXyTheme(
      brightness: Brightness.dark,
      accent: seed,
      dynamicColorScheme: darkDynamic,
      fontFamily: family,
    );
  }

  Widget _systemUiBuilder(BuildContext context, Widget? child) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: xySystemUiOverlayStyle(Theme.of(context).brightness),
      child: child ?? const SizedBox.shrink(),
    );
  }

  /// 把“音量键调节应用内音量”开关推送给原生层（MainActivity 持有，
  /// dispatchKeyEvent 里同步判断是否拦截音量键）。设置加载完成与
  /// 用户切换时都会触发；失败静默（原生层保持默认不拦截）。
  void _syncVolumeKeyCapture(bool enabled) {
    if (!Platform.isAndroid) return;
    MethodChannel('com.xymusic.mobile/volume_keys')
        .invokeMethod('setCaptureEnabled', {'enabled': enabled})
        .catchError((_) => null);
  }

  void _precacheBackground(String path) {
    if (path.isEmpty) {
      _backgroundLoadGeneration++;
      _precachedBackgroundPath = null;
      _decodedBackgroundPath = null;
      final old = _decodedBackgroundImage;
      _decodedBackgroundImage = null;
      _disposeBackgroundImage(old);
      return;
    }
    if (path == _decodedBackgroundPath || path == _precachedBackgroundPath) {
      return;
    }
    final generation = ++_backgroundLoadGeneration;
    _precachedBackgroundPath = path;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _backgroundLoadGeneration) return;
      // 不要在此处对原图做全分辨率 precacheImage：一张高像素照片
      // （例如 48MP）会分配近 200MB 解码纹理，低端机设置壁纸瞬间
      // 直接 OOM 原生崩溃（表现为"设置后闪退"）。显示链路全部按
      // 1440 宽解码（_decodeBackground 与 XyAppBackground 均已限制）。
      _decodeBackground(path, generation);
    });
  }

  /// 释放旧背景图。光栅缓存可能仍引用上一帧的纹理，立即 dispose
  /// 存在 use-after-free 风险，延迟到下一帧结束后再释放。
  void _disposeBackgroundImage(ui.Image? image) {
    if (image == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
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
      _disposeBackgroundImage(old);
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
    // 音量键拦截开关同步到原生层（含设置加载完成后的首次同步）。
    ref.listen<bool>(
      settingsProvider.select(
        (s) => s.valueOrNull?.volumeKeyControlsAppVolume ?? true,
      ),
      (_, enabled) => _syncVolumeKeyCapture(enabled),
    );
    // 音量键调节应用内音量的 OSD 反馈：音量键被拦截时系统音量面板
    // 不会出现，由根节点提示当前应用音量。
    ref.listen<double?>(volumeKeyOscProvider, (_, next) {
      if (next == null || !mounted) return;
      XyNotice.show(
        this.context,
        message: '应用音量 ${(next * 100).round()}%',
        compact: true,
        duration: const Duration(milliseconds: 1100),
      );
    });
    // 迷你播放器悬浮窗：开关变化立即同步（含授予权限后的首次显示），
    // 播放状态变化按节流增量同步（换歌/进度/播放态/队列）。
    ref.listen<bool>(
      settingsProvider.select(
        (s) => s.valueOrNull?.miniPlayerOverlayEnabled ?? false,
      ),
      (_, _) => MiniPlayerOverlayBridge.requestSync(immediate: true),
    );
    ref.listen<PlaybackState>(
      playerProvider,
      (_, _) => MiniPlayerOverlayBridge.requestSync(),
    );
    // 同步页面切换模式到路由层（transitionsBuilder 无法访问 ref）。
    xyPageTransitionMode =
        settings?.pageTransitionMode ?? PageTransitionMode.fade;
    final startup = widget.startupBackground;
    final backgroundPath =
        settings?.customBackgroundPath.trim() ?? startup?.path ?? '';
    final backgroundBlur =
        settings?.customBackgroundBlur ?? startup?.blur ?? 18.0;
    final backgroundFade = settings?.customBackgroundFade ?? 0.0;
    _precacheBackground(backgroundPath);
    final accent = settings?.accentColor ?? 0xFFEC4141;
    final fontFamily = settings?.fontFamily ?? '';
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
          fontFamily: fontFamily,
        );
        final theme = _lightTheme!;
        final darkTheme = _darkTheme!;
        Widget appBuilder(BuildContext context, Widget? child) {
          final mediaQuery = MediaQuery.of(context);
          final rawInsets = mediaQuery.viewInsets.bottom;
          // 只在视口“变大”（键盘收起 / 首次布局）时刷新全高记录。
          // adjustResize 下原生压缩 FlutterView 可能先于 IME insets 上报：
          // 那一帧 size 已缩水而 insets 仍为 0，若此刻记录会把缩水高度
          // 当成全高，后续归零判断永远不成立，双重避让（键盘上方露出
          // 与键盘等大的浅色 Scaffold 背景）复现。
          final recorded = _viewportWithoutKeyboard;
          if (recorded == null ||
              (mediaQuery.size.width == recorded.width &&
                  mediaQuery.size.height > recorded.height)) {
            _viewportWithoutKeyboard = mediaQuery.size;
          }
          final viewport = _viewportWithoutKeyboard;
          // 宽度需一致才比较高度，避免横竖屏切换时误判为“已 resize”。
          final keyboardResolved = viewport != null &&
                  mediaQuery.size.width == viewport.width &&
                  mediaQuery.size.height < viewport.height - 50
              ? 0.0
              : rawInsets;
          return _systemUiBuilder(
            context,
            BackdropGroup(
              child: XyAppBackground(
                imagePath: backgroundPath,
                blur: backgroundBlur,
                fade: backgroundFade,
                decodedImage: _decodedBackgroundPath == backgroundPath
                    ? _decodedBackgroundImage
                    : null,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: child == null
                          ? const SizedBox.shrink()
                          : MediaQuery(
                              data: mediaQuery.copyWith(
                                viewInsets: EdgeInsets.only(
                                  bottom: keyboardResolved,
                                ),
                              ),
                              child: child,
                            ),
                    ),
                    // 首次启动欢迎/初始化向导：全屏叠加在侧边栏、底栏
                    // 与全部页面之上；完成（或稍后设置）写入标记后消失。
                    if (ref.watch(
                      settingsProvider.select(
                        (s) => s.valueOrNull?.welcomeSetupCompleted == false,
                      ),
                    ))
                      const Positioned.fill(child: WelcomeOverlay()),
                  ],
                ),
              ),
            ),
          );
        }

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
            // 应用内文案全部为中文，固定中文 locale 让系统组件（长按
            // 文本菜单、日期选择器等）也显示中文。
            locale: _zhLocale,
            supportedLocales: const [_zhLocale],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
          );
        }
        return MaterialApp(
          title: 'XY Music',
          debugShowCheckedModeBanner: false,
          theme: theme,
          darkTheme: darkTheme,
          themeMode: themeMode,
          builder: appBuilder,
          locale: _zhLocale,
          supportedLocales: const [_zhLocale],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
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
