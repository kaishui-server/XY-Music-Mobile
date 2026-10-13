import 'dart:io';

import 'package:flutter/services.dart';

/// 通知栏&锁屏实时歌词桥接层（任务A：蓝牙歌词补强）。
///
/// 职责边界：
/// - Flutter 只做「歌词/元数据/播放态/进度锚点」的低频推送（复用桌面歌词
///   同一份 LRC 原文与进度源），行滚动推进由原生
///   [NotificationLyricsManager] 按墙钟完成，仅在行变化时更新 RemoteViews，
///   避免通知高频刷新被系统节流/抖动。
/// - 切歌（title/artist/lyrics 内容签名变化）与播放态变化立即推送；
///   播放中进度锚点 ≥500ms 校准一次即可（原生侧自带 200ms 外推）。
/// - 开关语义跟随「蓝牙歌词开关」（settings.bluetoothLyricsEnabled）：
///   开启蓝牙歌词即补强通知栏&锁屏歌词，不新增独立设置项。
class NotificationLyricsBridge {
  NotificationLyricsBridge._();

  static const _channel = MethodChannel('com.xymusic.mobile/notification_lyrics');

  static bool? _lastEnabled;
  static String? _lastContentSignature;
  static bool? _lastIsPlaying;
  static double _lastSentPosition = -1e9;
  static DateTime _lastSendTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// 播放器进度流调用：按需推送歌词/锚点。
  static Future<void> sync({
    required bool enabled,
    required String title,
    required String artist,
    required String lyrics,
    required double position,
    required bool isPlaying,
    required double duration,
  }) async {
    if (!Platform.isAndroid) return;

    final enabledChanged = _lastEnabled != enabled;
    _lastEnabled = enabled;

    final contentSignature = <Object?>[title, artist, lyrics].join('\u0000');
    final contentChanged = contentSignature != _lastContentSignature;
    _lastContentSignature = contentSignature;

    final playingChanged = _lastIsPlaying != isPlaying;
    _lastIsPlaying = isPlaying;

    final posMs = (position * 1000).round();
    final durationMs = (duration * 1000).round();
    final now = DateTime.now();
    final positionDelta = (position - _lastSentPosition).abs();
    final shouldSend =
        enabledChanged ||
        contentChanged ||
        playingChanged ||
        positionDelta > 0.2 ||
        (now.difference(_lastSendTime) >= const Duration(milliseconds: 500) &&
            positionDelta > 0.01);

    if (!shouldSend) return;

    _lastSentPosition = position;
    _lastSendTime = now;
    try {
      if (enabledChanged) {
        await _channel.invokeMethod<bool>(
          'setEnabled',
          <String, dynamic>{'enabled': enabled},
        );
      }
      if (!enabled) return;
      await _channel.invokeMethod<void>('update', <String, dynamic>{
        'title': title,
        'artist': artist,
        'lyrics': lyrics,
        'positionMs': posMs,
        'isPlaying': isPlaying,
        'durationMs': durationMs,
      });
    } on PlatformException {
      // 通知栏歌词是附加能力，失败不影响播放。
    } on MissingPluginException {
      // 非 Android 构建没有对应原生实现。
    }
  }

  /// 播放停止/开关关闭时确保通知被移除（幂等）。
  static Future<void> disable() async {
    if (!Platform.isAndroid) return;
    _lastEnabled = false;
    _lastContentSignature = null;
    _lastIsPlaying = null;
    _lastSentPosition = -1e9;
    _lastSendTime = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await _channel.invokeMethod<bool>(
        'setEnabled',
        <String, dynamic>{'enabled': false},
      );
    } catch (_) {
      // 忽略
    }
  }
}
