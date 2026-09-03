import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'app.dart';
import 'src/logging/app_log_store.dart';

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
      // 个别 ROM 的媒体服务初始化失败时仍允许应用进入前台，播放时由播放器自行处理。
      debugPrint('后台音频初始化失败：$error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }
  // 自定义背景必须在第一帧之前加载。否则设置 Provider 完成异步读取前，
  // 页面会短暂使用默认底色，表现为每次恢复或切页时闪一下。
  final startupBackground = await loadXyStartupBackground();
  runApp(
    ProviderScope(child: XyMusicApp(startupBackground: startupBackground)),
  );
}
