import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 应用级错误状态。用于把无法恢复的 Dart/Flutter 异常展示在页面上，
/// 避免用户只看到闪退或系统无响应。
class AppRuntimeError {
  const AppRuntimeError({
    required this.error,
    this.stackTrace,
    this.source = '应用运行时',
  });

  final Object error;
  final StackTrace? stackTrace;
  final String source;
}

class AppErrorController {
  AppErrorController._();

  static final instance = AppErrorController._();

  final ValueNotifier<AppRuntimeError?> current =
      ValueNotifier<AppRuntimeError?>(null);
  bool _installed = false;

  void install() {
    if (_installed) return;
    _installed = true;

    final previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      previousFlutterError?.call(details);
      if (_isRecoverableNetworkError(details.exception) ||
          _isRecoverableLifecycleError(details.exception) ||
          _isNonFatalFlutterError(details)) {
        // Flutter 会把布局溢出、图片加载失败、异步请求超时等问题都
        // 交给 onError，但这些问题通常只影响当前组件，不能替换整个应用。
        debugPrint('忽略可恢复的局部错误：${details.exception}');
        return;
      }
      report(
        details.exception,
        stackTrace: details.stack,
        source: 'Flutter 界面错误',
      );
    };

    final previousPlatformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      previousPlatformError?.call(error, stack);
      if (_isRecoverableNetworkError(error) ||
          _isRecoverableLifecycleError(error)) {
        debugPrint('忽略可恢复的音频网络错误：$error');
        return true;
      }
      report(error, stackTrace: stack, source: '异步运行时错误');
      // 已经展示错误页，告诉 Flutter 不要再让未处理异常结束应用。
      return true;
    };

    ErrorWidget.builder = (details) => AppFatalErrorScreen(
      error: details.exception,
      stackTrace: details.stack,
      source: '界面构建错误',
    );
  }

  void report(Object error, {StackTrace? stackTrace, String source = '应用运行时'}) {
    current.value = AppRuntimeError(
      error: error,
      stackTrace: stackTrace,
      source: source,
    );
  }

  void clear() => current.value = null;

  /// 临时音源失效或网络超时只影响当前歌曲，不能替换整个应用界面。
  ///
  /// 这里不能按域名白名单判断。插件来源很多，QQ 音乐、酷狗、B 站等
  /// 返回的音源地址都可能变化；只要是底层网络连接失败，就应该交给
  /// 播放器/搜索页处理，而不是把整个应用替换成错误页。
  static bool _isRecoverableNetworkError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('socketexception') ||
        text.contains('socketconnection') ||
        text.contains('clientexception') ||
        text.contains('httpexception') ||
        text.contains('handshakeexception') ||
        text.contains('failed host lookup') ||
        text.contains('connection timed out') ||
        text.contains('connection closed') ||
        text.contains('connection reset') ||
        text.contains('connection refused') ||
        text.contains('network is unreachable') ||
        text.contains('broken pipe') ||
        text.contains('timed out') ||
        text.contains('errno = 110') ||
        text.contains('errno = 111') ||
        text.contains('playerexception') ||
        text.contains('source error') ||
        text.contains('missingpluginexception');
  }

  /// 页面或原生资源销毁时，仍在完成的异步回调可能晚到一帧。它们不应
  /// 替换整个应用页面；对应的播放器/插件服务会在回调结束后自行收尾。
  static bool _isRecoverableLifecycleError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('cannot use "ref" after the widget was disposed') ||
        text.contains("cannot use 'ref' after the widget was disposed") ||
        text.contains('cannot use ref after the widget was disposed') ||
        text.contains('a dart object attempted to access a native peer') ||
        text.contains('native peer has been collected') ||
        text.contains('native resources have already been disposed') ||
        text.contains('native peer is null');
  }

  /// 这些是 Flutter 的诊断性错误，框架可以继续绘制后续页面。
  /// 记录日志即可，不能因此触发全屏保护页。
  static bool _isNonFatalFlutterError(FlutterErrorDetails details) {
    final text = details.exception.toString().toLowerCase();
    return text.contains('renderflex overflowed') ||
        text.contains('renderbox was not laid out') ||
        text.contains('setstate() called after dispose') ||
        text.contains('setstate() or markneedsbuild() called during build') ||
        text.contains('_dependents.isempty') ||
        text.contains('tried to build dirty widget in the wrong build scope') ||
        text.contains('mouse tracker') ||
        text.contains('semantics node') ||
        text.contains('unable to load asset') ||
        text.contains('image provider') ||
        text.contains('failed to load network image');
  }
}

/// 放在应用最外层，接收异步异常并替换为可操作的错误页。
class AppErrorBoundary extends StatelessWidget {
  const AppErrorBoundary({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppRuntimeError?>(
      valueListenable: AppErrorController.instance.current,
      builder: (context, runtimeError, _) {
        if (runtimeError == null) return child;
        return AppFatalErrorScreen(
          error: runtimeError.error,
          stackTrace: runtimeError.stackTrace,
          source: runtimeError.source,
        );
      },
    );
  }
}

class AppFatalErrorScreen extends StatelessWidget {
  const AppFatalErrorScreen({
    required this.error,
    this.stackTrace,
    this.source = '应用运行时',
    super.key,
  });

  final Object error;
  final StackTrace? stackTrace;
  final String source;

  @override
  Widget build(BuildContext context) {
    final message = error.toString().replaceFirst('Exception: ', '').trim();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFFF8F8FA),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      size: 64,
                      color: Color(0xFFD32F2F),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'XY Music 遇到运行错误',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '应用没有直接退出，错误信息如下：',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade700),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 230),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.red.shade100),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          '$source\n$message',
                          style: const TextStyle(
                            fontSize: 13,
                            height: 1.45,
                            color: Color(0xFF5F2120),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    OutlinedButton.icon(
                      onPressed: AppErrorController.instance.clear,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('刷新页面'),
                    ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: () => SystemNavigator.pop(),
                      icon: const Icon(Icons.exit_to_app_rounded),
                      label: const Text('退出应用'),
                    ),
                    if (kDebugMode && stackTrace != null) ...[
                      const SizedBox(height: 16),
                      ExpansionTile(
                        title: const Text('展开堆栈信息'),
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: SelectableText(stackTrace.toString()),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> runAppGuarded(Future<void> Function() body) async {
  await runZonedGuarded<Future<void>>(body, (error, stackTrace) {
    if (AppErrorController._isRecoverableNetworkError(error) ||
        AppErrorController._isRecoverableLifecycleError(error)) {
      debugPrint('忽略可恢复的音频网络错误：$error');
      return;
    }
    AppErrorController.instance.report(
      error,
      stackTrace: stackTrace,
      source: '未处理异步异常',
    );
  });
}
