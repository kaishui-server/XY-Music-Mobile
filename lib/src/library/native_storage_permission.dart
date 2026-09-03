import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 本地音乐扫描存储权限（Kotlin `StoragePermissionBridge` 的 Dart 封装）。
///
/// 设计参考 MusicFree：权限全部走自写的原生 MethodChannel（Android 原生
/// API 按版本分支），彻底抛弃 permission_handler 插件层——该插件在
/// Android 13 以下对 `Permission.audio` 会返回「假授权」（request 直接
/// granted 但实际未授予）、`manageExternalStorage` 在 Android 11 以下
/// 返回 RESTRICTED，导致 READ_EXTERNAL_STORAGE 从未被真正申请，扫描
/// 时 Rust read_dir 被 EACCES 拒绝，形成「无法读取文件夹」死循环。
///
/// - Android 11+：`Environment.isExternalStorageManager()` 检查，跳转
///   「所有文件访问」设置页，等待应用回到前台后复检；
/// - Android 6-10：运行时弹框申请 READ/WRITE，被拒后跳应用详情页
///   手动引导（MusicFree 同款）；
/// - Android 5 及以下 / 非 Android：安装时已授予，直接放行。
class NativeStoragePermission {
  NativeStoragePermission._();

  static const _channel =
      MethodChannel('com.xymusic.mobile/storage_permission');

  /// Android SDK 版本号（非 Android 返回 0）。
  static int _sdkInt = -1;

  static Future<int> get sdkInt async {
    if (!Platform.isAndroid) return 0;
    if (_sdkInt < 0) {
      _sdkInt = await _channel.invokeMethod<int>('sdkInt') ?? 0;
    }
    return _sdkInt;
  }

  /// 当前是否具备按文件路径读取共享存储的权限。
  static Future<bool> check() async {
    if (!Platform.isAndroid) return true;
    return await _channel.invokeMethod<bool>('check') ?? false;
  }

  /// 确保已授权；未授权时发起申请并等待用户完成操作。
  ///
  /// 跳转系统设置页后应用进入后台，需等用户返回前台（resumed）才能
  /// 重新检测权限状态，超时上限 2 分钟。
  static Future<bool> ensure() async {
    if (!Platform.isAndroid) return true;
    if (await check()) return true;

    // request 返回值：true=弹框后已授予；false=弹框被拒；
    // null=已跳转系统设置页（Android 11+），需等待用户返回。
    final result = await _channel.invokeMethod<bool?>('request');
    if (result == true) return true;
    if (result == null) {
      await _waitForResume();
      return check();
    }
    // 低版本弹框被拒：跳应用详情页让用户手动开启存储权限。
    await _channel.invokeMethod<void>('openAppSettings');
    await _waitForResume();
    return check();
  }

  /// 权限引导文案（按系统版本适配，Android 10 及以下没有
  /// 「所有文件访问」这个设置项，不能误导用户去找）。
  static Future<String> get deniedHint async =>
      (await sdkInt) >= 30
          ? '请在系统设置中授予本应用“所有文件访问”权限'
          : '请在系统设置中授予本应用“存储空间”权限';

  /// 校验目录当前可按文件路径列举（权限不足时 list 会抛异常）。
  static Future<bool> isReadableDirectory(String path) async {
    try {
      // 只需确认能开始列举；空目录同样视为可读。
      await for (final _ in Directory(path).list()) {
        break;
      }
      return true;
    } on Exception {
      return false;
    }
  }

  /// 等待应用回到前台（生命周期 resumed）。
  static Future<void> _waitForResume() async {
    final waiter = _AppResumeWaiter();
    WidgetsBinding.instance.addObserver(waiter);
    try {
      await waiter.resumed.timeout(const Duration(minutes: 2));
    } on Exception {
      // 超时（用户未返回）时忽略，按当前权限状态判断。
    } finally {
      WidgetsBinding.instance.removeObserver(waiter);
    }
  }
}

/// 监听应用回到前台的一次性等待器。
class _AppResumeWaiter with WidgetsBindingObserver {
  final Completer<void> _resumed = Completer<void>();

  Future<void> get resumed => _resumed.future;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_resumed.isCompleted) {
      _resumed.complete();
    }
  }
}
