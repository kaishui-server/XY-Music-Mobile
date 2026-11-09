import 'package:flutter/material.dart';

/// 崩溃现场上下文：最近一次导航动作、被操作的页面、App 生命周期。
///
/// 由来：[`Bad state: Cannot use "ref" after the widget was disposed.`] 在
/// release AOT 下只会留下 3 帧 `<asynchronous suspension>`，没有源码行号，
/// 单看堆栈无法回答"哪一页、什么时机把已销毁 widget 的 ref 又读了一次"。
/// 崩溃文件里补上这三项，候选范围就能从整个 UI 层收窄到少数几个异步回调。
class ErrorContext {
  ErrorContext._();

  /// 当前可见路由（最近一次 push/replace/remove 后按栈顶推算）。
  static String? currentRoute;

  /// 最近一次导航动作：push / pop / replace / remove。
  static String lastNavAction = 'none';

  /// 最近一次导航动作涉及的页面（pop 时即被弹出的那一页）。
  static String? lastNavRoute;

  /// 最近一次导航动作发生的时刻。
  static DateTime? lastNavAt;

  /// 生成一行可落盘的上下文摘要（同步、无 IO）。
  static String describe() {
    final navAt = lastNavAt;
    final ago = navAt == null
        ? 'n/a'
        : '${DateTime.now().difference(navAt).inMilliseconds}ms 前';
    String lifecycle;
    try {
      lifecycle = WidgetsBinding.instance.lifecycleState?.name ?? 'unknown';
    } catch (_) {
      lifecycle = 'unknown';
    }
    return '上下文: route=${currentRoute ?? "unknown"} '
        'lifecycle=$lifecycle '
        'lastNav=$lastNavAction(${lastNavRoute ?? "-"}, $ago)\n';
  }
}

/// 把导航事件写进 [ErrorContext]，挂在 `appRouter` 的 observers 上。
class ErrorContextObserver extends NavigatorObserver {
  static String _name(Route<dynamic>? route) =>
      route?.settings.name ?? route?.runtimeType.toString() ?? '-';

  void _note(String action, Route<dynamic>? route, Route<dynamic>? shown) {
    ErrorContext.lastNavAction = action;
    ErrorContext.lastNavRoute = _name(route);
    ErrorContext.lastNavAt = DateTime.now();
    if (shown != null) ErrorContext.currentRoute = _name(shown);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _note('push', route, route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _note('pop', route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _note('replace', newRoute, newRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _note('remove', route, previousRoute);
  }
}
