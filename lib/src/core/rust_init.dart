import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logging/app_log_store.dart';
import '../rust/frb_generated.dart' as frb;

/// Rust 桥接初始化的容忍上限。
///
/// 正常机型 dlopen + 初始化在毫秒级完成；但实测出现过首屏一直停在加载页、
/// 没有任何报错的情况——`RustLib.init()` 返回的 Future 迟迟不 resolve，
/// 而原实现里 [rustInitProvider] 只有 `await`、没有任何超时兜底，界面就
/// 永远停在转圈上（即用户反馈的「开屏卡住」）。超过该时长即视为本次启动
/// 异常，交给 UI 显示可重试的错误页，而不是无限等待。
const rustInitTimeout = Duration(seconds: 10);

/// `RustLib.init()` 未在 [rustInitTimeout] 内完成时抛出。
///
/// 「超时」与「失败」语义不同：底层加载可能仍在进行，若随后自行成功，
/// 界面会自动恢复（见 [rustInitProvider]）。
class RustInitTimeoutException implements Exception {
  const RustInitTimeoutException(this.timeout);

  final Duration timeout;

  @override
  String toString() =>
      'Rust 核心初始化超过 ${timeout.inSeconds} 秒仍未完成，'
      '可能是动态库加载或原生桥接被系统阻塞。';
}

/// 全局唯一的 Rust 初始化 Future。
Future<void>? _rustInitFuture;

/// 确保 `RustLib.init()` 全局只执行一次。
///
/// frb 的 `BaseEntrypoint.initImpl` 内部有 `__state != null` 断言，
/// 重复调用会抛 `Should not initialize flutter_rust_bridge twice`。
/// 因此超时后的「重试」必须复用同一个 Future，绝不能重新 init；
/// 只有真正失败（库加载或版本校验抛错，此时 frb 内部 `__state` 仍为
/// null，重新 init 是安全的）才清空缓存，允许下次重来。
Future<void> rustInitOnce() {
  final existing = _rustInitFuture;
  if (existing != null) return existing;
  final future = frb.RustLib.init();
  _rustInitFuture = future;
  // 派生一个只用于清理缓存的 Future：onError 不再 rethrow，
  // 避免在原始 Future 尚未被监听前就产生未捕获异常。
  future.then<void>(
    (_) {},
    onError: (Object error, StackTrace stackTrace) {
      if (identical(_rustInitFuture, future)) _rustInitFuture = null;
    },
  );
  return future;
}

/// 初始化 RustLib 桥接（只初始化一次，带超时保护）。
///
/// 不手动指定 externalLibrary，交由生成的 [defaultExternalLibraryLoaderConfig]
/// 按平台加载正确的库名：Android `libxymusic_core.so`、Windows `xymusic_core.dll`
/// 等。手动传裸名 `xymusic_core` 会导致 Android 下 dlopen 失败。
final rustInitProvider = FutureProvider<void>((ref) async {
  var disposed = false;
  ref.onDispose(() => disposed = true);
  final init = rustInitOnce();
  final stopwatch = Stopwatch()..start();
  try {
    await init.timeout(rustInitTimeout);
    final elapsed = stopwatch.elapsedMilliseconds;
    if (elapsed > 1000) {
      AppLogStore.instance.add(
        '[Startup] Rust 核心初始化耗时 ${elapsed}ms，已超过正常水平',
        level: AppLogLevel.warning,
      );
    }
  } on TimeoutException {
    AppLogStore.instance.add(
      '[Startup] Rust 核心初始化 ${rustInitTimeout.inSeconds}s 未完成，'
      '转入可重试的错误页（底层加载仍在后台继续）',
      level: AppLogLevel.error,
    );
    // 超时不清缓存、不重复 init：dlopen 可能只是慢。底层若随后自行完成，
    // 重新执行本 provider 就能立刻通过，这里主动触发一次让界面自动恢复。
    unawaited(
      init.then<void>(
        (_) {
          if (!disposed) ref.invalidateSelf();
        },
        onError: (Object error, StackTrace stackTrace) {},
      ),
    );
    throw const RustInitTimeoutException(rustInitTimeout);
  }
});
