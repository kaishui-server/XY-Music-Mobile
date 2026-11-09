import 'dart:async';

import 'package:flutter/widgets.dart';

/// App 是否处于「确定不可见」：切走全屏 App / 锁屏 / onStop。
///
/// 与 player_provider 的 position 降频判据保持一致：只看 hidden。
/// paused（其他应用悬浮窗抢焦点、但本 App 界面仍可见）不算后台，
/// 否则这类场景会被误判成后台而挂起刷新。
bool get isAppHiddenNow =>
    WidgetsBinding.instance.lifecycleState == AppLifecycleState.hidden;

/// 到期刷新：到点时若 App 在后台则顺延（每分钟复查一次），回到前台后的
/// 下一个检查点才真正刷新。
///
/// 用于榜单 / 推荐 / 统计这类「到点 invalidate 自己重拉接口」的定时器：
/// 后台没人看的时候按周期拉接口只会白白唤醒网络与 CPU。
///
/// 返回值是取消函数，调用方应 `ref.onDispose(cancel)`。
VoidCallback scheduleRefreshWhenVisible(
  Duration interval,
  void Function() onRefresh,
) {
  Timer? timer;

  void arm(Duration delay) {
    timer?.cancel();
    timer = Timer(delay, () {
      if (isAppHiddenNow) {
        // 后台不刷新：改为每分钟复查，直到回到前台。
        arm(const Duration(minutes: 1));
        return;
      }
      onRefresh();
    });
  }

  arm(interval);
  return () {
    timer?.cancel();
    timer = null;
  };
}
