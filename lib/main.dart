import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'app.dart';
import 'src/core/custom_font.dart';
import 'src/library/online_cover_overrides.dart';
import 'src/logging/app_log_store.dart';
import 'src/services/cache_auto_clean.dart';

/// 缓存自动清理的生命周期监听：切后台/隐藏时触发一次阈值检查。
/// 顶层持有引用，避免监听器在启动流程结束后被 GC 导致失效。
/// 在 [_bootstrapApp] 中赋值（此时 WidgetsBinding 已初始化）。
AppLifecycleListener? cacheCleanLifecycleListener;

/// 启动阶段各项初始化的等待上限。
///
/// 这些工作原先都是无上限的 `await`：只要其中任何一项（Binder 绑定、大图
/// 解码、日志反序列化）在个别 ROM 上一直不返回，`runApp` 就永远不会执行，
/// 用户看到的就是「开屏卡住」。统一加上限，超时只降级不阻断首帧。
const _logRestoreTimeout = Duration(seconds: 3);
const _startupAssetTimeout = Duration(milliseconds: 2500);
const _audioInitTimeout = Duration(seconds: 5);

Future<void> main() async {
  // runZonedGuarded 兜住 zone 内逃逸的异步异常，交给日志系统落盘
  // （崩溃文件），避免进程被静默杀死而无任何记录。
  runZonedGuarded(() async {
    await _bootstrapApp();
  }, (error, stack) {
    AppLogStore.instance.add(
      'main zone 未捕获异常\n$error\n$stack',
      level: AppLogLevel.error,
    );
    AppLogStore.instance.recordCrash('main zone 异常', error, stack);
  });
}

Future<void> _bootstrapApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 解码图片（封面）缓存上限：框架默认 1000 张 / 100MB，对以小尺寸
  // 封面为主的音乐 App 偏大，长时间浏览歌单后常驻内存明显偏高；
  // 收紧到 512 张 / 64MB 已足够列表回滚复用，降低闲置内存占用。
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 512;
  imageCache.maximumSizeBytes = 64 << 20;
  // 某些使用 AudioServiceActivity 的 Android ROM 不会自动执行
  // file_picker 的 Dart 插件注册，首次调用 FilePicker.platform 时会抛出
  // LateInitializationError: Field '_instance' has not been initialized。
  // 显式注册移动端实现，保证本地插件、头像和反馈附件选择都可用。
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    try {
      FilePickerIO.registerWith();
    } catch (error) {
      debugPrint('文件选择器初始化失败：$error');
    }
  }
  AppLogStore.instance.install();
  // 启动日志恢复：读 SharedPreferences 后要把整串 JSON 反序列化成日志对象
  // （探针通道配额已提到 3000 条），低端机上可能耗时数百毫秒到秒级。
  // 日志属于「有更好、没有也能用」的能力，不能挡在首帧之前，超时先放行，
  // 历史记录由后台任务自行补完（_load 内部不会覆盖运行期新增的条目）。
  await AppLogStore.instance.initialize().timeout(
    _logRestoreTimeout,
    onTimeout: () {
      debugPrint('启动日志恢复超时，跳过等待继续启动');
    },
  );
  // 在线歌曲自定义封面覆盖表：启动即加载，列表/播放页按 revision 刷新。
  unawaited(initOnlineCoverOverrides());
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    try {
      // Android 平板与手机统一使用边到边布局，状态栏由 Flutter 页面背景承载。
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          systemStatusBarContrastEnforced: false,
          systemNavigationBarContrastEnforced: false,
        ),
      );
    } catch (error) {
      debugPrint('系统状态栏初始化失败：$error');
    }
  }
  // 启动卡顿修复：音频服务绑定（Binder IPC，慢 ROM 上可达秒级）、自定义
  // 背景读取解码、自定义字体注册原先串行 await，耗时全部累加在首帧之前。
  // 三者互不依赖，改为并行执行，首帧只需等待最慢的一个完成。
  final audioInit = _initBackgroundAudio().timeout(
    _audioInitTimeout,
    onTimeout: () {
      // 少数 ROM 上媒体服务绑定（Binder IPC）会一直不返回。继续等下去，
      // 用户看到的就是启动画面永久卡死；这里放弃等待直接进前台，播放相关
      // 异常交给播放器自身的错误处理兜底，远好过开不了应用。
      AppLogStore.instance.add(
        '[Startup] 后台音频服务初始化超过 ${_audioInitTimeout.inSeconds}s，'
        '跳过等待继续启动',
        level: AppLogLevel.warning,
      );
    },
  );
  final backgroundFuture = loadXyStartupBackground();
  final fontFuture = restoreCustomFontAtStartup();
  // 自定义背景必须在第一帧之前加载。否则设置 Provider 完成异步读取前，
  // 页面会短暂使用默认底色，表现为每次恢复或切页时闪一下。
  // 但「读文件 + instantiateImageCodec 解码」同样可能长时间不返回，
  // 超时就退回默认底色优先出首帧——少一次背景，好过永远进不去界面。
  final startupBackground = await backgroundFuture.timeout(
    _startupAssetTimeout,
    onTimeout: () => const XyStartupBackground(),
  );
  // 自定义字体同理：必须在第一帧之前注册，避免首屏闪回系统默认字体。
  await fontFuture.timeout(_startupAssetTimeout, onTimeout: () {});
  // PlayerProvider 构造时即创建 just_audio_background 的 AudioPlayer，
  // 其初始化必须先完成；失败已在上层捕获，不会阻断启动。
  await audioInit;

  // 缓存自动清理：启动后检查一次（超过 256MB 自动清理），并注册
  // 生命周期监听（切后台/隐藏时检查）与 30 分钟周期兜底，保证长时间
  // 前台使用也能触发。带节流与并发保护，扫描在后台异步执行不阻塞 UI。
  cacheCleanLifecycleListener = AppLifecycleListener(
    onStateChange: (state) {
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden) {
        unawaited(CacheAutoCleanService.instance.checkAndCleanIfNeeded());
      }
    },
  );
  unawaited(CacheAutoCleanService.instance.checkAndCleanIfNeeded());
  CacheAutoCleanService.instance.startPeriodicCheck();

  runApp(
    ProviderScope(child: XyMusicApp(startupBackground: startupBackground)),
  );
}

/// 绑定后台音频服务并配置音频会话。
///
/// 个别 ROM 的媒体服务初始化失败时仍允许应用进入前台，播放时由播放器
/// 自行处理。
Future<void> _initBackgroundAudio() async {
  if (kIsWeb ||
      !(defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS)) {
    return;
  }
  // 必须在创建 AudioPlayer 之前完成：部分机型（实测 OnePlus Android 16）
  // 音频 HAL 不提供系统均衡器，AudioEffect 构造直接抛 RuntimeException，
  // 而 just_audio 只要被注入效果就会在 audio session 建立时构造，异常
  // 发生在主线程无人捕获会导致进程判为崩溃。先探测能力，不支持的机型
  // 干脆不注入对应效果（音效降级，但不再崩溃）。
  await _probeAndroidAudioEffects();
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.xymusic.mobile.playback',
      androidNotificationChannelName: 'XY Music 音乐播放',
      androidNotificationChannelDescription: '显示正在播放的歌曲和播放控制',
      androidNotificationIcon: 'drawable/ic_stat_xy_music',
      androidNotificationOngoing: true,
      // 单击通知不拉起 Activity：改为广播事件转交 Dart，只弹迷你播放器
      // 悬浮窗而不把应用切到前台（配合 audio_service 的定制广播接收器）。
      androidNotificationClickStartsActivity: false,
      androidStopForegroundOnPause: false,
      // MediaSession 会经 Binder 传递封面位图。512x512 的 ARGB 位图
      // 已接近 1MB 事务上限，部分 ROM 会连同整张媒体卡片一起丢弃。
      // 256x256 足够通知栏/锁屏展示，同时保留充足的事务余量。
      artDownscaleWidth: 256,
      artDownscaleHeight: 256,
    );
    final audioSession = await AudioSession.instance;
    await audioSession.configure(const AudioSessionConfiguration.music());
  } catch (error, stackTrace) {
    debugPrint('后台音频初始化失败：$error');
    debugPrintStack(stackTrace: stackTrace);
  }
}

/// 探测设备原生音频效果（均衡器、响度增益）是否可用，并写入
/// just_audio_background 的能力标志。
///
/// 原生侧会试建一次对应 `AudioEffect` 再立即释放；失败（机型音频 HAL
/// 不提供该效果）返回 false。探测本身异常时按“不支持”处理——宁可没有
/// 音效，也不要让进程在首次播放时崩溃。
Future<void> _probeAndroidAudioEffects() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    final supported = await const MethodChannel('com.xymusic.mobile/device_info')
        .invokeMethod<Map<Object?, Object?>>('probeAudioEffects');
    xySetAndroidAudioEffectsSupported(
      equalizer: supported?['equalizer'] == true,
      loudnessEnhancer: supported?['loudnessEnhancer'] == true,
    );
  } catch (error) {
    debugPrint('音频效果能力探测失败，按不支持处理：$error');
    xySetAndroidAudioEffectsSupported(
      equalizer: false,
      loudnessEnhancer: false,
    );
  }
}
