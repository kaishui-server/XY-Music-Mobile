import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// 「到点刷新」统一句柄：把 onDispose 注册、到期判活与取消收在一处。
///
/// 只能在 provider body 的**同步段**（首个 await 之前）构造：构造时立即
/// `ref.onDispose` 注册，若放到 await 之后，provider 一旦在 await 期间被
/// 回收，注册动作本身就会抛 `Bad state: Cannot call onDispose after a
/// provider was dispose`（真机空闲闪退就出在这里）。
class VisibleRefreshHandle {
  VisibleRefreshHandle(this._ref, this.interval, this.onRefresh) {
    _ref.onDispose(() {
      _disposed = true;
      _cancel?.call();
      _cancel = null;
    });
  }

  final Ref _ref;

  /// 刷新周期（从 [arm] 那一刻开始计时）。
  final Duration interval;

  /// 到点回调（通常是 `ref.invalidateSelf`）。
  final void Function() onRefresh;

  VoidCallback? _cancel;
  bool _disposed = false;
  bool _armed = false;

  /// provider 是否已被回收。
  bool get isDisposed => _disposed;

  /// 武装定时器：仅首次生效，重复调用不会叠加计时，也不会重启周期。
  ///
  /// 供「计时起点必须在某件事成功之后」的场景使用（如热评要先请求成功再
  /// 起算）。已回收时直接忽略。
  void arm() {
    if (_armed || _disposed) return;
    _armed = true;
    _cancel = scheduleRefreshWhenVisible(interval, () {
      // 到期时先判活：已回收则不再触碰 ref，静默结束。
      if (_disposed) return;
      onRefresh();
    });
  }
}

/// 在 provider body 的同步段登记「可见时到点刷新」，返回句柄。
///
/// [autoArm] 为 true（默认）时立即开始计时，适用于刷新周期从 provider 首次
/// 计算开始计算的所有场景；为 false 时先取到句柄，等业务侧成功后再
/// [VisibleRefreshHandle.arm]。
VisibleRefreshHandle registerVisibleRefresh(
  Ref ref,
  Duration interval,
  void Function() onRefresh, {
  bool autoArm = true,
}) {
  final handle = VisibleRefreshHandle(ref, interval, onRefresh);
  if (autoArm) handle.arm();
  return handle;
}
