// safe_state_notifier.dart — 回收安全的状态容器基类。
//
// 背景：provider 被 ref.invalidate / autoDispose 回收后，在途的异步链路
// （网络请求、磁盘读写、扫描回填、监听回调等）往往仍会跑到末尾并写
// `state`。此时 StateNotifier 内部的 StreamController 已被关闭，release
// 包下写 state 会抛 `Bad state` 一类异常，直接表现为空闲闪退；debug 包
// 下则先在 `_debugIsMounted` 断言处失败。逐处手写 `if (mounted)` 容易漏，
// 因此在基类 setter 上统一收口。
//
// 用法：把 `extends StateNotifier<T>` 换成 `extends SafeStateNotifier<T>`，
// 构造函数仍写 `super(initialState)`，其余成员（含 mixin）保持不变。

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 带存活判定的 StateNotifier 基类。
///
/// 覆写 [state] 的 setter：notifier 已被回收（[mounted] 为 false）时静默
/// 丢弃这次赋值，不再写入内部 `_state`、也不通知监听者，从而避免在已关闭
/// 的 StreamController / 已 dispose 的 element 上继续操作。
///
/// 该保护只作用于「写」这一侧，不改变任何业务取值、持久化写入、返回值或
/// UI 行为；未被回收时与原生 StateNotifier 完全等价。
abstract class SafeStateNotifier<T> extends StateNotifier<T> {
  SafeStateNotifier(super.state);

  @override
  set state(T value) {
    // 已回收：在途异步链路不得再写 state（否则 release 下抛 Bad state 闪退）。
    if (!mounted) return;
    super.state = value;
  }
}
