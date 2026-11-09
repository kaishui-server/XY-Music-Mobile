import 'package:flutter/foundation.dart';

/// 播放页 UI 活动信号：播放页是否正在显示进度条 / 逐字歌词。
///
/// 用途：position 流与进度兜底泵按此选择采样档位，避免「无人观看的
/// 进度条」把 UI 线程持续从休眠里拽出来。
/// - 播放页可见：200~250ms 细粒度，进度条平滑、逐字歌词跟手；
/// - 播放页不可见（在首页 / 歌单 / 设置等页面浏览）：600ms 粗档；
/// - App 确定不可见（hidden）：仍按 player_provider 的后台档 2s 走。
///
/// 播放页是独立路由（/player），push 时 acquire、pop 时 release，
/// 因此单个布尔即可覆盖（同一时刻只会存在一个播放页实例）。
class PlayerUiActivity {
  PlayerUiActivity._();

  /// 播放页可见性信号。player_provider 监听后在档位变化时重挂 position 流。
  static final ValueNotifier<bool> visible = ValueNotifier<bool>(false);

  static bool get isVisible => visible.value;

  static void acquire() => visible.value = true;

  static void release() => visible.value = false;
}
