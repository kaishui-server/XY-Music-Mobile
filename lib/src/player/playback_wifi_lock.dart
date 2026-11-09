import 'package:flutter/services.dart';

/// 播放期 Wi-Fi 高性能锁联动（耗电优化）。
///
/// 背景：原生侧（`MainActivity.acquirePlaybackWifiLock`）原本在 `onCreate`
/// 里无条件持有 `WIFI_MODE_FULL_HIGH_PERF`，唯一释放点是 `onDestroy`——
/// 等于只要 App 进程活着，Wi-Fi 就被禁止进入省电模式，熄屏、暂停、闲置
/// 全都在持续耗电。
///
/// 现在改为由播放态驱动：起播 acquire，暂停/停止后由原生侧延迟 3s 释放
/// （延迟是为了避免切歌、短暂缓冲造成的 acquire/release 抖动）。Dart 侧
/// 做一层去重，避免 `playerStateStream` 高频回调反复跨通道调用。
class PlaybackWifiLock {
  PlaybackWifiLock._();

  static const MethodChannel _channel =
      MethodChannel('com.xymusic.mobile/playback_wifi');

  /// 上一次同步给原生的状态（null = 尚未同步过）。
  static bool? _lastSynced;

  /// 把当前播放态同步给原生侧。异常一律吞掉：持锁失败只影响 Wi-Fi
  /// 调度策略，不影响播放本身。
  static Future<void> sync(bool playing) async {
    if (_lastSynced == playing) return;
    _lastSynced = playing;
    try {
      await _channel.invokeMethod<void>('setPlaying', playing);
    } catch (_) {
      // 原生通道未就绪（如测试环境）时静默忽略。
      _lastSynced = null;
    }
  }
}
