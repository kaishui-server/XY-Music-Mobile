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
/// [level] 可显式指定日志级别，供「非故障但值得记录」的场景使用（如
/// 【N3】流缓存落盘竞态重试）。
void playbackChainLog(String message, {AppLogLevel? level}) {
  // 【N4】同一行只入日志库一次。
  // 2026-11-04 荣耀日志 16:15:09.023 的
  // `[DSP] 在线流纳入接管（延迟3s）: <url>` 同毫秒出现两次且 URL 完全
  // 相同——与 A4 的 `_dspTakeoverLogUrl` 去重无关（全工程只有一处打印
  // 该文案）。真正原因是重复写入：debug 构建下 AppLogStore.install()
  // 接管了 debugPrint（内部会再 add 一次），而这里既调 add 又调
  // debugPrint，同一条消息因此落进日志库两份。
  // 改用 debugPrintSynchronously（只输出到控制台，不经被接管的
  // debugPrint），保证「一份入日志库 + 一份进控制台」。
  AppLogStore.instance.add(message, level: level);
  debugPrintSynchronously(message);
}
