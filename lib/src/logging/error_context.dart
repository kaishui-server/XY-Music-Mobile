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

  /// 最近一次业务动作（如「换源:lx-music」「批量换源」）。
  ///
  /// route/lastNav 只能回答「崩溃时在哪个页面」，回答不了「正在做什么」：
  /// 换源这类异步链路（选源弹窗 → 同步收藏/歌单 → 替换播放队列）正是
  /// ref-after-dispose 类崩溃的高发区，把动作埋进来后崩溃文件的候选
  /// 范围能进一步收窄到具体的异步回调。
  static String? lastAction;

  /// 最近一次业务动作发生的时刻。
  static DateTime? lastActionAt;

  /// 记录一次业务动作。同步、无 IO，可在任何调用点安全触发。
  static void noteAction(String action) {
    lastAction = action;
    lastActionAt = DateTime.now();
  }

  /// 生成一行可落盘的上下文摘要（同步、无 IO）。
  static String describe() {
    final navAt = lastNavAt;
    final ago = navAt == null
        ? 'n/a'
        : '${DateTime.now().difference(navAt).inMilliseconds}ms 前';
    final actionAt = lastActionAt;
    final actionAgo = actionAt == null
        ? 'n/a'
        : '${DateTime.now().difference(actionAt).inMilliseconds}ms 前';
    String lifecycle;
    try {
      lifecycle = WidgetsBinding.instance.lifecycleState?.name ?? 'unknown';
    } catch (_) {
      lifecycle = 'unknown';
    }
    return '上下文: route=${currentRoute ?? "unknown"} '
        'lifecycle=$lifecycle '
        'lastNav=$lastNavAction(${lastNavRoute ?? "-"}, $ago) '
        'lastAction=${lastAction ?? "-"}($actionAgo)\n';
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
