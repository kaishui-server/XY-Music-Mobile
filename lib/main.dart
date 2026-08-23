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
        );
        final audioSession = await AudioSession.instance;
        await audioSession.configure(const AudioSessionConfiguration.music());
      } catch (error, stackTrace) {
        // 个别 ROM 的媒体服务初始化失败时仍允许应用进入前台，播放时再展示错误。
        debugPrint('后台音频初始化失败：$error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
    runApp(AppErrorBoundary(child: const ProviderScope(child: XyMusicApp())));
  });
}
