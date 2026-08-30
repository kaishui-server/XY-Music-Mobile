import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

/// 播放详情页临时视频的共享状态。
///
/// 视频控制器不能绑定在详情页 widget 生命周期内，否则离开详情页后
/// 会被销毁。通过这个会话对象让首页和迷你播放栏也能读取视频进度与控制器。
class VideoPlaybackSession {
  static VideoPlayerController? controller;
  static String? songPath;
  static bool loading = false;
  static bool resumeAudioAfterVideo = false;
  static bool restarting = false;
  static String? error;

  /// 当前视频是否来自插件的 MV 解析（非 B 站视频），用于菜单文案区分。
  static bool isMv = false;

  /// 控制器从 null 切换为实例、或视频开始/结束时递增，供外部页面重新绑定。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 视频控制器的进度/播放状态变化通知，供播放器状态和桌面歌词同步。
  static final ValueNotifier<int> progressRevision = ValueNotifier<int>(0);

  static void changed() => revision.value++;

  static void progressChanged() => progressRevision.value++;

  /// 单曲循环时，视频结束后直接从头播放同一个视频。此逻辑放在共享
  /// 会话中，不依赖播放详情页是否仍在前台，离开详情页后也能正常循环。
  static Future<void> restartSingleLoop() async {
    final active = controller;
    if (active == null || restarting) return;
    restarting = true;
    try {
      await active.seekTo(Duration.zero);
      if (controller != active) return;
      await active.play();
      progressChanged();
    } catch (error) {
      debugPrint('B站视频单曲循环重播失败：$error');
    } finally {
      restarting = false;
    }
  }

  /// 从首页或迷你播放栏切歌时结束临时视频，不恢复旧歌曲音频。
  static Future<void> stopForTrackAction() async {
    final active = controller;
    controller = null;
    songPath = null;
    loading = false;
    resumeAudioAfterVideo = false;
    restarting = false;
    error = null;
    isMv = false;
    changed();
    progressChanged();
    await active?.dispose();
  }

  static bool isFor(String? path) =>
      path != null && path.isNotEmpty && songPath == path;
}
