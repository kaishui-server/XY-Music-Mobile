import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'app.dart';
import 'src/core/app_error_boundary.dart';
import 'src/logging/app_log_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogStore.instance.install();
  AppErrorController.instance.install();
  await runAppGuarded(() async {
    await AppLogStore.instance.initialize();
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
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      try {
        await JustAudioBackground.init(
          androidNotificationChannelId: 'com.xymusic.mobile.playback',
          androidNotificationChannelName: 'XY Music 音乐播放',
          androidNotificationChannelDescription: '显示正在播放的歌曲和播放控制',
          androidNotificationIcon: 'drawable/ic_stat_xy_music',
          androidNotificationOngoing: true,
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
        // 个别 ROM 的媒体服务初始化失败时仍允许应用进入前台，播放时再展示错误。
        debugPrint('后台音频初始化失败：$error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
    // 自定义背景必须在第一帧之前加载。否则设置 Provider 完成异步读取前，
    // 页面会短暂使用默认底色，表现为每次恢复或切页时闪一下。
    final startupBackground = await loadXyStartupBackground();
    runApp(
      AppErrorBoundary(
        child: ProviderScope(
          child: XyMusicApp(startupBackground: startupBackground),
        ),
      ),
    );
  });
}
