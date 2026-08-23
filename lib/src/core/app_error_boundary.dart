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
      report(
        details.exception,
        stackTrace: details.stack,
        source: 'Flutter 界面错误',
      );
    };

    final previousPlatformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      previousPlatformError?.call(error, stack);
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
    AppErrorController.instance.report(
      error,
      stackTrace: stackTrace,
      source: '未处理异步异常',
    );
  });
}
