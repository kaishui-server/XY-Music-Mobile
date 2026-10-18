// 播放链路诊断日志（独立文件：player_provider 与 cloud_proxy 共用，
// 避免 cloud_proxy 反向依赖 provider 造成循环 import）。

import 'package:flutter/foundation.dart';

import '../logging/app_log_store.dart';

/// 播放链路诊断日志：同时写控制台与应用日志库。
///
/// `debugPrint` 不会被 AppLogStore 捕获，用户导出的日志里只有 [PROBE]
/// 心跳；起播各阶段的分段计时（音源解析/setUrl/DNS 预热）必须写入日志
/// 库，导出后才能定位「点歌到出声」的耗时分布。进度事件类高频日志
/// 仍走 debugPrint，避免刷掉日志库容量内的关键计时。
void playbackChainLog(String message) {
  debugPrint(message);
  AppLogStore.instance.add(message);
}
