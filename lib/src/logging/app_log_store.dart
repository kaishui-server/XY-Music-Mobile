import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'error_context.dart';

enum AppLogLevel { info, warning, error }

/// 日志通道。业务日志与性能探针日志共用一条时间序，但**各自独立配额、
/// 独立过滤、独立导出**：探针在久播场景可达数百条（30s 摘要 + 事件节流），
/// 若与业务日志挤同一个上限，会把真正的报错/崩溃信息挤出缓冲区。
enum AppLogChannel { general, probe }

class AppLogEntry {
  const AppLogEntry({
    required this.time,
    required this.level,
    required this.message,
    this.channel = AppLogChannel.general,
  });

  final DateTime time;
  final AppLogLevel level;
  final String message;
  final AppLogChannel channel;

  bool get isError => level == AppLogLevel.error;
  bool get isWarning => level == AppLogLevel.warning;
  bool get isProbe => channel == AppLogChannel.probe;

  Map<String, dynamic> toJson() => {
    'time': time.toIso8601String(),
    'level': level.name,
    'channel': channel.name,
    'message': message,
  };

  factory AppLogEntry.fromJson(Map<String, dynamic> json) {
    final message = json['message']?.toString() ?? '';
    final channel = switch (json['channel']?.toString()) {
      'probe' => AppLogChannel.probe,
      'general' => AppLogChannel.general,
      // 旧版本快照没有 channel 字段：探针行统一带 [PROBE] 前缀，据此迁移。
      _ => message.startsWith('[PROBE]')
          ? AppLogChannel.probe
          : AppLogChannel.general,
    };
    return AppLogEntry(
      time: DateTime.tryParse(json['time']?.toString() ?? '') ?? DateTime.now(),
      level: switch (json['level']?.toString()) {
        'error' => AppLogLevel.error,
        'warning' => AppLogLevel.warning,
        _ => AppLogLevel.info,
      },
      message: message,
      channel: channel,
    );
  }
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
  static const _probeMaxEntriesKey = 'appLogProbeMaxEntries';
  static const _warningOnlyKey = 'appLogWarningOnly';

  /// 崩溃文件最多保留数量，与原生 CrashHandler 保持一致。
  static const _maxCrashFiles = 20;

  final List<AppLogEntry> _entries = [];
  Future<void>? _initFuture;
  Timer? _persistTimer;
  bool _installed = false;
  bool _initialized = false;
  /// 卡顿修复：真机上「播放中反复重缓冲」的现场往往在小时级才出现，
  /// 500 条（约十几分钟）一滚动就被覆盖，抓不到复现窗口。默认提到 2000。
  int maxEntries = 2000;

  /// 探针日志独立配额，与 [maxEntries] 互不挤占。
  ///
  /// 30s 一条摘要 + 5s 节流的告警，300 条只能覆盖约 25 分钟，久播卡顿
  /// 恰好就发生在更后面的时间段——实测旧包 240 条 POSITION_GAP 就把
  /// 配额写满，用户真正卡顿时的现场全被覆盖。默认提到 3000。
  int maxProbeEntries = 3000;
  bool warningOnly = false;
  String? _crashDirPath;

  List<AppLogEntry> get entries => List.unmodifiable(_entries);

  /// 仅性能探针通道的条目（按时间序）。
  List<AppLogEntry> get probeEntries => _query(
    channels: const {AppLogChannel.probe},
  );

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
      maxEntries = (preferences.getInt(_maxEntriesKey) ?? 2000)
          .clamp(200, 20000)
          .toInt();
      // 探针配额旧默认是 300（久播 25 分钟即被告警刷屏写满，真卡顿现场
      // 会被挤掉）。读到 <= 300 视为「仍是旧默认/从未调整」，一次性提升
      // 到 3000；用户手动设过更大值的尊重原值。
      final rawProbeMax = preferences.getInt(_probeMaxEntriesKey);
      maxProbeEntries = (rawProbeMax == null || rawProbeMax <= 300
              ? 3000
              : rawProbeMax)
          .clamp(200, 20000)
          .toInt();
      warningOnly = preferences.getBool(_warningOnlyKey) ?? false;
      final raw = preferences.getString(_entriesKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final restored = decoded
              .whereType<Map>()
              .map(
                (value) =>
                    AppLogEntry.fromJson(Map<String, dynamic>.from(value)),
              )
              .toList();
          // 历史条目插到前面而不是清空后覆盖：启动流程对 initialize()
          // 设了超时，恢复动作可能晚于首批运行日志入队（见 main.dart），
          // 整体 clear 会把这几条启动期日志直接吞掉。
          _entries.insertAll(0, restored);
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
    // release 无控制台，debugPrint 内容用户看不到；接管它只会把高频日志
    // 经 JSON + SharedPreferences 落盘，反而拖慢主 isolate。仅调试期接管。
    if (!kReleaseMode) {
      final previousDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        add(message ?? '');
        previousDebugPrint(message, wrapWidth: wrapWidth);
      };
    }

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
        // AOT 堆栈常常只有几帧异步挂起点，光凭它无法定位具体页面；
        // 附上崩溃前最后的导航与生命周期，才能把范围收窄下来。
        '${ErrorContext.describe()}'
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
              '版本: ${info['appVersion']} (构建 ${info['appBuild']})\n';
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

  /// 启动后检测「原生闪退补录」文件（crash-exit-*.txt，由原生侧
  /// ExitInfoRecorder 在上次启动/崩溃后写入），返回本次尚未提示过的
  /// 文件名并把它们标记为已提示。提示文件通过崩溃目录内 marker 文件
  /// 持久化（与崩溃记录同生命周期，清空记录即重置提示状态）。
  Future<List<String>> unseenExitCrashReports() async {
    try {
      final dir = Directory(await _crashDir());
      if (!dir.existsSync()) return const [];
      // 只匹配 crash-exit-<时间戳>.txt，排除 marker（crash-exit-notified）
      // 与路径提示（crash-exit-public-path）等辅助文件。
      final exitCrashName = RegExp(r'^crash-exit-\d{8}-\d{6}\.txt$');
      final names = dir
          .listSync()
          .whereType<File>()
          .map((file) => p.basename(file.path))
          .where(exitCrashName.hasMatch)
          .toList()
        ..sort();
      if (names.isEmpty) return const [];
      final markerFile = File(p.join(dir.path, 'crash-exit-notified.txt'));
      final seen = markerFile.existsSync()
          ? markerFile.readAsStringSync().split('\n').toSet()
          : <String>{};
      final fresh = names.where((name) => !seen.contains(name)).toList();
      if (fresh.isEmpty) return const [];
      await markerFile.writeAsString(names.join('\n'), flush: true);
      return fresh;
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

  void add(
    String message, {
    AppLogLevel? level,
    AppLogChannel channel = AppLogChannel.general,
  }) {
    final text = message.trim();
    if (text.isEmpty) return;
    final resolvedLevel = level ?? _inferLevel(text);
    // 「只记录警告和报错」只约束业务日志：探针数据本身就是 INFO 级的曲线
    // 与摘要，一并过滤会让该开关打开后探针彻底失效。
    if (channel == AppLogChannel.general &&
        warningOnly &&
        resolvedLevel == AppLogLevel.info) {
      return;
    }
    _entries.add(
      AppLogEntry(
        time: DateTime.now(),
        level: resolvedLevel,
        message: text,
        channel: channel,
      ),
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
    _trimChannel(AppLogChannel.general, maxEntries);
    _trimChannel(AppLogChannel.probe, maxProbeEntries);
  }

  /// 按通道各自配额裁剪（从最早的一条开始）。两个通道共用同一条时间序，
  /// 但配额独立——久播时数百条探针不会再把业务日志挤出缓冲区。
  void _trimChannel(AppLogChannel channel, int max) {
    final keep = max.clamp(200, 20000).toInt();
    // 快速路径：总条数不足单通道配额时肯定不超限，避免高频 add 时的全表遍历。
    if (_entries.length <= keep) return;
    var count = 0;
    for (final entry in _entries) {
      if (entry.channel == channel) count++;
    }
    if (count <= keep) return;
    var toRemove = count - keep;
    _entries.removeWhere((entry) {
      if (toRemove <= 0 || entry.channel != channel) return false;
      toRemove--;
      return true;
    });
  }

  Future<void> setMaxEntries(int value) async {
    maxEntries = value.clamp(200, 20000);
    _trim();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_maxEntriesKey, maxEntries);
    await _persistNow();
  }

  Future<void> setMaxProbeEntries(int value) async {
    maxProbeEntries = value.clamp(200, 20000);
    _trim();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_probeMaxEntriesKey, maxProbeEntries);
    await _persistNow();
  }

  Future<void> setWarningOnly(bool value) async {
    warningOnly = value;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_warningOnlyKey, value);
  }

  /// 清空本地日志并同步删除持久化快照。
  /// [channel] 为空时清空全部通道；指定通道时只清该通道，其余保留。
  Future<void> clear({AppLogChannel? channel}) async {
    _persistTimer?.cancel();
    _persistTimer = null;
    if (channel == null) {
      _entries.clear();
    } else {
      _entries.removeWhere((entry) => entry.channel == channel);
    }
    try {
      final preferences = await SharedPreferences.getInstance();
      if (_entries.isEmpty) {
        await preferences.remove(_entriesKey);
      } else {
        await _persistNow();
      }
    } catch (_) {
      // 本地存储失败不应阻止页面立即显示为空；下次写入时会重新创建。
    }
  }

  /// 查询业务日志（默认**不含**性能探针通道）。
  ///
  /// 探针日志高频且体积大，若混入全量/错误导出会淹没真正的报错信息；
  /// 需要探针数据时显式传 `channels: {AppLogChannel.probe}`。
  List<AppLogEntry> query({
    Duration? since,
    bool errorsOnly = false,
    Set<AppLogChannel> channels = const {AppLogChannel.general},
  }) => _query(since: since, errorsOnly: errorsOnly, channels: channels);

  /// [channels] 为空时不做通道过滤（内部使用，如清空/统计）。
  List<AppLogEntry> _query({
    Duration? since,
    bool errorsOnly = false,
    Set<AppLogChannel>? channels,
  }) {
    final threshold = since == null ? null : DateTime.now().subtract(since);
    return _entries
        .where((entry) {
          if (channels != null && !channels.contains(entry.channel)) {
            return false;
          }
          final withinTime =
              threshold == null || !entry.time.isBefore(threshold);
          final levelMatches = !errorsOnly || entry.isError;
          return withinTime && levelMatches;
        })
        .toList(growable: false);
  }

  /// 批量落盘调度（内存卡顿修复降频）：错误日志 500ms 内尽快落盘
  /// （进程随时可能被杀）；普通日志批量降频——前台 2s 合并一次、
  /// 后台 30s 一次，避免播放过程中高频 add 反复触发全量
  /// jsonEncode + SharedPreferences 写盘（长期播放时的持续磁盘唤醒
  /// 与主 isolate 负担）。时间线以最后一次 add 为基准重新计时，
  /// 空闲时不会空转写盘。
  void _schedulePersist() {
    if (!_initialized) return;
    _persistTimer?.cancel();
    final hasError = _entries.isNotEmpty && _entries.last.isError;
    AppLifecycleState? lifecycle;
    try {
      lifecycle = WidgetsBinding.instance.lifecycleState;
    } catch (_) {
      // Binding 尚未初始化（main 早期安装日志时）：按前台批量处理。
    }
    final inBackground =
        lifecycle != null && lifecycle != AppLifecycleState.resumed;
    final delay = hasError
        ? const Duration(milliseconds: 500)
        : (inBackground
              ? const Duration(seconds: 30)
              : const Duration(seconds: 2));
    _persistTimer = Timer(delay, () {
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
