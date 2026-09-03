import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLogLevel { info, warning, error }

class AppLogEntry {
  const AppLogEntry({
    required this.time,
    required this.level,
    required this.message,
  });

  final DateTime time;
  final AppLogLevel level;
  final String message;

  bool get isError => level == AppLogLevel.error;
  bool get isWarning => level == AppLogLevel.warning;

  Map<String, dynamic> toJson() => {
    'time': time.toIso8601String(),
    'level': level.name,
    'message': message,
  };

  factory AppLogEntry.fromJson(Map<String, dynamic> json) => AppLogEntry(
    time: DateTime.tryParse(json['time']?.toString() ?? '') ?? DateTime.now(),
    level: switch (json['level']?.toString()) {
      'error' => AppLogLevel.error,
      'warning' => AppLogLevel.warning,
      _ => AppLogLevel.info,
    },
    message: json['message']?.toString() ?? '',
  );
}

/// 一份崩溃记录文件（含原生崩溃与 Dart 致命异常）。
class CrashReport {
  CrashReport({required this.file});

  final File file;

  String get name => p.basename(file.path);

  DateTime get time => file.lastModifiedSync();

  int get size => file.statSync().size;
}

/// 应用内轻量日志缓存，同时接管 debugPrint 和 Flutter 未处理异常。
/// 日志仅用于用户主动导出诊断，不替代系统日志。
///
/// 参考 legado（开源阅读）的日志设计：致命异常（Flutter 框架异常、
/// 平台未捕获异常、Dart isolate 崩溃、原生未捕获异常）除了进入内存
/// 缓存外，还会**立即同步写入**应用私有目录 crash/ 下的独立文件——
/// 进程随后被系统杀死也不会丢失记录；原生层崩溃由 Kotlin 侧
/// CrashHandler 写入同一目录。
class AppLogStore {
  AppLogStore._();

  static final instance = AppLogStore._();

  static const _entriesKey = 'appLogsV1';
  static const _maxEntriesKey = 'appLogMaxEntries';
  static const _warningOnlyKey = 'appLogWarningOnly';

  /// 崩溃文件最多保留数量，与原生 CrashHandler 保持一致。
  static const _maxCrashFiles = 20;

  final List<AppLogEntry> _entries = [];
  Future<void>? _initFuture;
  Timer? _persistTimer;
  bool _installed = false;
  bool _initialized = false;
  int maxEntries = 500;
  bool warningOnly = false;
  String? _crashDirPath;

  List<AppLogEntry> get entries => List.unmodifiable(_entries);

  Future<void> initialize() => _initFuture ??= _load();

  /// 崩溃记录目录。Android 优先询问原生（与 CrashHandler 写入同一目录，
  /// 位于内部存储，无需任何存储权限）；其他平台用应用支持目录。
  Future<String> _crashDir() async {
    final cached = _crashDirPath;
    if (cached != null) return cached;
    String path;
    if (!kIsWeb && Platform.isAndroid) {
      try {
        path = await const MethodChannel(
          'com.xymusic.mobile/device_info',
        ).invokeMethod<String>('getCrashDir') ?? '';
      } catch (_) {
        path = '';
      }
    } else {
      path = '';
    }
    if (path.isEmpty) {
      try {
        // 非Android或通道不可用时的兜底：应用支持目录同样无需权限。
        final support = await getApplicationSupportDirectory();
        path = p.join(support.path, 'xy_music', 'crash');
      } catch (_) {
        path = p.join(Directory.systemTemp.path, 'xy_music_crash');
      }
    }
    _crashDirPath = path;
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) dir.createSync(recursive: true);
    } catch (_) {
      // 目录创建失败时仍返回路径，写入崩溃文件时会再次尝试。
    }
    return path;
  }

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      maxEntries = (preferences.getInt(_maxEntriesKey) ?? 500)
          .clamp(50, 5000)
          .toInt();
      warningOnly = preferences.getBool(_warningOnlyKey) ?? false;
      final raw = preferences.getString(_entriesKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _entries
            ..clear()
            ..addAll(
              decoded.whereType<Map>().map(
                (value) =>
                    AppLogEntry.fromJson(Map<String, dynamic>.from(value)),
              ),
            );
          _trim();
        }
      }
    } catch (_) {
      // 日志初始化失败不能影响应用启动。
    } finally {
      _initialized = true;
    }
  }

  /// 在 main 中尽早调用，捕获启动阶段的 debugPrint。
  void install() {
    if (_installed) return;
    _installed = true;
    final previousDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      add(message ?? '');
      previousDebugPrint(message, wrapWidth: wrapWidth);
    };

    final previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      add(
        '${details.exception}\n${details.stack ?? ''}'.trim(),
        level: AppLogLevel.error,
      );
      // 框架渲染异常通常是局部的（errorBuilder 已兜底），只进日志缓存；
      // 真正致命的异常由 PlatformDispatcher/isolate 监听写入崩溃文件。
      if (previousFlutterError != null) {
        previousFlutterError(details);
      } else {
        FlutterError.dumpErrorToConsole(details);
      }
    };

    final previousPlatformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      add('$error\n$stack', level: AppLogLevel.error);
      // 平台分发层面的未捕获异常（async/await 逃逸、引擎回调崩溃）
      // 属于致命异常：立即写入崩溃文件，进程被杀也不丢。
      unawaited(recordCrash('Dart 平台异常', error, stack));
      return previousPlatformError?.call(error, stack) ?? false;
    };

    // 非 UI isolate 的未处理异常同样写入崩溃文件。
    Isolate.current.addErrorListener(
      RawReceivePort((dynamic pair) {
        final list = pair as List;
        unawaited(
          recordCrash(
            'Dart isolate 异常',
            list.isNotEmpty ? list[0] : '未知错误',
            list.length > 1 && list[1] is StackTrace
                ? list[1] as StackTrace
                : null,
          ),
        );
      }).sendPort,
    );
  }

  /// 把致命异常写入独立崩溃文件（同步 flush，进程随时可被杀死）。
  /// 同时作为一条 error 日志进入内存缓存。
  Future<void> recordCrash(
    String kind,
    Object error,
    StackTrace? stack,
  ) async {
    add('$kind\n$error\n${stack ?? ''}', level: AppLogLevel.error);
    try {
      final dir = await _crashDir();
      final now = DateTime.now();
      final stamp =
          '${now.year}${_two(now.month)}${_two(now.day)}-'
          '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
      final file = File(
        p.join(dir, 'crash-dart-$stamp-${now.millisecondsSinceEpoch % 1000}.txt'),
      );
      final header = await _deviceHeader();
      await file.writeAsString(
        '===== XY Music $kind =====\n'
        '时间: ${now.toIso8601String()}\n'
        '$header'
        '============================\n'
        '$error\n'
        '${stack ?? ''}\n',
        flush: true,
      );
      await _trimCrashFiles(dir);
    } catch (_) {
      // 崩溃记录失败不能反向拖垮应用。
    }
  }

  Future<String> _deviceHeader() async {
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final info = await const MethodChannel(
          'com.xymusic.mobile/device_info',
        ).invokeMapMethod<String, dynamic>('getDeviceInfo');
        if (info != null) {
          return '设备: ${info['manufacturer']} ${info['model']} '
              '(Android ${info['osVersion']}, API ${info['sdkInt']})\n'
              '版本: ${info['appVersion']}\n';
        }
      }
    } catch (_) {}
    return '';
  }

  String _two(int value) => value.toString().padLeft(2, '0');

  Future<void> _trimCrashFiles(String dirPath) async {
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return;
      final files = dir
          .listSync()
          .whereType<File>()
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final file in files.skip(_maxCrashFiles)) {
        try {
          await file.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 全部崩溃记录（原生 + Dart），新文件在前。
  Future<List<CrashReport>> crashReports() async {
    try {
      final dir = Directory(await _crashDir());
      if (!dir.existsSync()) return const [];
      final reports = dir
          .listSync()
          .whereType<File>()
          .where((file) => p.basename(file.path).startsWith('crash-'))
          .map((file) => CrashReport(file: file))
          .toList();
      reports.sort((a, b) => b.time.compareTo(a.time));
      return reports;
    } catch (_) {
      return const [];
    }
  }

  Future<String> readCrashReport(CrashReport report) async {
    try {
      return await report.file.readAsString();
    } catch (_) {
      return '';
    }
  }

  Future<void> deleteCrashReport(CrashReport report) async {
    try {
      await report.file.delete();
    } catch (_) {}
  }

  /// 清空全部崩溃记录文件。
  Future<void> clearCrashReports() async {
    try {
      final dir = Directory(await _crashDir());
      if (!dir.existsSync()) return;
      for (final entity in dir.listSync()) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 汇总导出全部崩溃记录（用于反馈页附件）。
  Future<String> exportCrashReports() async {
    final reports = await crashReports();
    final buffer = StringBuffer()
      ..writeln('XY Music 崩溃记录')
      ..writeln('导出时间：${DateTime.now().toIso8601String()}')
      ..writeln('崩溃文件数：${reports.length}')
      ..writeln(List.filled(72, '=').join());
    for (final report in reports) {
      buffer
        ..writeln()
        ..writeln('【${report.name}】')
        ..writeln(await readCrashReport(report))
        ..writeln(List.filled(72, '-').join());
    }
    return buffer.toString();
  }

  void add(String message, {AppLogLevel? level}) {
    final text = message.trim();
    if (text.isEmpty) return;
    final resolvedLevel = level ?? _inferLevel(text);
    if (warningOnly && resolvedLevel == AppLogLevel.info) return;
    _entries.add(
      AppLogEntry(time: DateTime.now(), level: resolvedLevel, message: text),
    );
    _trim();
    _schedulePersist();
  }

  AppLogLevel _inferLevel(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('error') ||
        lower.contains('exception') ||
        lower.contains('failed') ||
        message.contains('错误') ||
        message.contains('失败') ||
        message.contains('报错')) {
      return AppLogLevel.error;
    }
    if (lower.contains('warn') ||
        message.contains('警告') ||
        message.contains('注意')) {
      return AppLogLevel.warning;
    }
    return AppLogLevel.info;
  }

  void _trim() {
    final keep = maxEntries.clamp(50, 5000).toInt();
    if (_entries.length > keep) {
      _entries.removeRange(0, _entries.length - keep);
    }
  }

  Future<void> setMaxEntries(int value) async {
    maxEntries = value.clamp(50, 5000);
    _trim();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_maxEntriesKey, maxEntries);
    await _persistNow();
  }

  Future<void> setWarningOnly(bool value) async {
    warningOnly = value;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_warningOnlyKey, value);
  }

  /// 清空本地日志并同步删除持久化快照。
  Future<void> clear() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    _entries.clear();
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(_entriesKey);
    } catch (_) {
      // 本地存储失败不应阻止页面立即显示为空；下次写入时会重新创建。
    }
  }

  List<AppLogEntry> query({Duration? since, bool errorsOnly = false}) {
    final threshold = since == null ? null : DateTime.now().subtract(since);
    return _entries
        .where((entry) {
          final withinTime =
              threshold == null || !entry.time.isBefore(threshold);
          final levelMatches = !errorsOnly || entry.isError;
          return withinTime && levelMatches;
        })
        .toList(growable: false);
  }

  void _schedulePersist() {
    if (!_initialized) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_persistNow());
    });
  }

  Future<void> _persistNow() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _entriesKey,
        jsonEncode(_entries.map((entry) => entry.toJson()).toList()),
      );
    } catch (_) {}
  }
}
