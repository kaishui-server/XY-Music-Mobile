import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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

/// 应用内轻量日志缓存，同时接管 debugPrint 和 Flutter 未处理异常。
/// 日志仅用于用户主动导出诊断，不替代系统日志。
class AppLogStore {
  AppLogStore._();

  static final instance = AppLogStore._();

  static const _entriesKey = 'appLogsV1';
  static const _maxEntriesKey = 'appLogMaxEntries';
  static const _warningOnlyKey = 'appLogWarningOnly';

  final List<AppLogEntry> _entries = [];
  Future<void>? _initFuture;
  Timer? _persistTimer;
  bool _installed = false;
  bool _initialized = false;
  int maxEntries = 500;
  bool warningOnly = false;

  List<AppLogEntry> get entries => List.unmodifiable(_entries);

  Future<void> initialize() => _initFuture ??= _load();

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
      if (previousFlutterError != null) {
        previousFlutterError(details);
      } else {
        FlutterError.dumpErrorToConsole(details);
      }
    };

    final previousPlatformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      add('$error\n$stack', level: AppLogLevel.error);
      return previousPlatformError?.call(error, stack) ?? false;
    };
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
