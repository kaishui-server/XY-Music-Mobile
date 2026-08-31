import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api.dart' as rust;

/// 下载记录状态。
enum DownloadHistoryStatus { downloading, completed, failed }

/// 单条下载记录：覆盖单曲下载与歌单批量下载两条路径。
class DownloadHistoryEntry {
  const DownloadHistoryEntry({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    this.durationMs = 0,
    required this.startedAt,
    required this.status,
    required this.quality,
    this.sourcePath = '',
    this.pluginId,
    this.pluginDataJson,
    this.coverUrl,
    this.progress = 0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.savedPath,
    this.actualQuality,
    this.error,
    this.finishedAt,
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  /// 歌曲时长（毫秒），重新下载时用于实际码率估算。
  final int durationMs;
  final int startedAt;
  final DownloadHistoryStatus status;
  /// 用户选择的下载音质。
  final String quality;
  /// 重建播放队列项所需的音源路径（插件歌曲为插件虚拟路径）。
  final String sourcePath;
  final String? pluginId;
  /// 插件元数据 JSON，重新下载时还原 pluginData。
  final String? pluginDataJson;
  final String? coverUrl;
  /// 下载进度 0~1（仅 downloading 状态有意义；totalBytes 未知时保持 0）。
  final double progress;
  /// 已下载字节数（downloading 状态时由进度追踪器刷新）。
  final int downloadedBytes;
  /// 总字节数；0 表示服务器未返回长度。
  final int totalBytes;
  final String? savedPath;
  /// 格式校验后的实际音质（下载完成时写入）。
  final String? actualQuality;
  /// 完整失败原因（供“查看详情”展示）。
  final String? error;
  final int? finishedAt;

  DownloadHistoryEntry copyWith({
    DownloadHistoryStatus? status,
    double? progress,
    int? downloadedBytes,
    int? totalBytes,
    String? savedPath,
    String? actualQuality,
    String? error,
    int? finishedAt,
  }) => DownloadHistoryEntry(
    id: id,
    title: title,
    artist: artist,
    album: album,
    durationMs: durationMs,
    startedAt: startedAt,
    status: status ?? this.status,
    quality: quality,
    sourcePath: sourcePath,
    pluginId: pluginId,
    pluginDataJson: pluginDataJson,
    coverUrl: coverUrl,
    progress: progress ?? this.progress,
    downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    savedPath: savedPath ?? this.savedPath,
    actualQuality: actualQuality ?? this.actualQuality,
    error: error ?? this.error,
    finishedAt: finishedAt ?? this.finishedAt,
  );

  factory DownloadHistoryEntry.fromJson(Map<String, dynamic> json) =>
      DownloadHistoryEntry(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        artist: json['artist']?.toString() ?? '',
        album: json['album']?.toString() ?? '',
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        startedAt: (json['startedAt'] as num?)?.toInt() ?? 0,
        status: switch (json['status']) {
          'completed' => DownloadHistoryStatus.completed,
          'failed' => DownloadHistoryStatus.failed,
          _ => DownloadHistoryStatus.downloading,
        },
        quality: json['quality']?.toString() ?? '320k',
        sourcePath: json['sourcePath']?.toString() ?? '',
        pluginId: json['pluginId']?.toString(),
        pluginDataJson: json['pluginDataJson']?.toString(),
        coverUrl: json['coverUrl']?.toString(),
        progress: (json['progress'] as num?)?.toDouble() ?? 0,
        downloadedBytes: (json['downloadedBytes'] as num?)?.toInt() ?? 0,
        totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
        savedPath: json['savedPath']?.toString(),
        actualQuality: json['actualQuality']?.toString(),
        error: json['error']?.toString(),
        finishedAt: (json['finishedAt'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'durationMs': durationMs,
    'startedAt': startedAt,
    'status': status.name,
    'quality': quality,
    'sourcePath': sourcePath,
    'pluginId': pluginId,
    'pluginDataJson': pluginDataJson,
    'coverUrl': coverUrl,
    'progress': progress,
    'downloadedBytes': downloadedBytes,
    'totalBytes': totalBytes,
    'savedPath': savedPath,
    'actualQuality': actualQuality,
    'error': error,
    'finishedAt': finishedAt,
  };
}

/// 历史记录持久化上限：超过后丢弃最旧记录，防止 SharedPreferences 无限膨胀。
const kDownloadHistoryLimit = 500;

const _downloadHistoryKey = 'downloadHistoryV1';
Future<void> _writeQueue = Future<void>.value();

class DownloadHistoryNotifier
    extends StateNotifier<List<DownloadHistoryEntry>> {
  DownloadHistoryNotifier() : super(const []) {
    _load();
  }

  int _counter = 0;

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_downloadHistoryKey);
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final entries = decoded
          .whereType<Map>()
          .map(
            (value) => DownloadHistoryEntry.fromJson(
              Map<String, dynamic>.from(value),
            ),
          )
          .toList();
      // 上次进程被杀时处于 downloading 的记录永远不会完成，启动时标记为失败。
      for (var i = 0; i < entries.length; i++) {
        if (entries[i].status == DownloadHistoryStatus.downloading) {
          entries[i] = entries[i].copyWith(
            status: DownloadHistoryStatus.failed,
            error: '下载被中断（应用退出或进程被终止）',
            finishedAt: entries[i].startedAt,
          );
        }
      }
      state = entries;
    } catch (_) {
      // 历史记录损坏时静默丢弃，不影响下载功能。
    }
  }

  Future<void> _persist() {
    final snapshot = state.take(kDownloadHistoryLimit).toList();
    final operation = _writeQueue.then((_) async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _downloadHistoryKey,
        jsonEncode(snapshot.map((e) => e.toJson()).toList()),
      );
    });
    _writeQueue = operation.catchError((_) {});
    return operation;
  }

  /// 记录一条新的下载，返回其 id 用于后续进度/完成/失败更新。
  String begin({
    required String title,
    required String artist,
    required String album,
    required String quality,
    int durationMs = 0,
    String sourcePath = '',
    String? pluginId,
    Map<String, dynamic>? pluginData,
    String? coverUrl,
  }) {
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
    state = [
      DownloadHistoryEntry(
        id: id,
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        startedAt: DateTime.now().millisecondsSinceEpoch,
        status: DownloadHistoryStatus.downloading,
        quality: quality,
        sourcePath: sourcePath,
        pluginId: pluginId,
        pluginDataJson: pluginData == null || pluginData.isEmpty
            ? null
            : jsonEncode(pluginData),
        coverUrl: coverUrl,
      ),
      ...state,
    ];
    unawaited(_persist());
    return id;
  }

  void updateProgress(
    String id, {
    double? progress,
    int? downloadedBytes,
    int? totalBytes,
  }) {
    final index = state.indexWhere((entry) => entry.id == id);
    if (index < 0 || state[index].status != DownloadHistoryStatus.downloading) {
      return;
    }
    state = [...state]
      ..[index] = state[index].copyWith(
        progress: progress,
        downloadedBytes: downloadedBytes,
        totalBytes: totalBytes,
      );
    // 进度更新非常频繁（约 3Hz），只改内存不落盘；完成/失败时会整体持久化。
  }

  void complete(String id, {String? savedPath, String? actualQuality}) {
    final index = state.indexWhere((entry) => entry.id == id);
    if (index < 0) return;
    state = [...state]
      ..[index] = state[index].copyWith(
        status: DownloadHistoryStatus.completed,
        progress: 1,
        savedPath: savedPath,
        actualQuality: actualQuality,
        error: null,
        finishedAt: DateTime.now().millisecondsSinceEpoch,
      );
    unawaited(_persist());
  }

  void fail(String id, String error) {
    final index = state.indexWhere((entry) => entry.id == id);
    if (index < 0) return;
    state = [...state]
      ..[index] = state[index].copyWith(
        status: DownloadHistoryStatus.failed,
        error: error,
        finishedAt: DateTime.now().millisecondsSinceEpoch,
      );
    unawaited(_persist());
  }

  /// 重新下载：为该条记录新建一条 downloading 记录，保留原失败原因。
  String restart(String id) {
    final index = state.indexWhere((entry) => entry.id == id);
    if (index < 0) {
      return begin(title: '', artist: '', album: '', quality: '320k');
    }
    final entry = state[index];
    return begin(
      title: entry.title,
      artist: entry.artist,
      album: entry.album,
      quality: entry.quality,
      durationMs: entry.durationMs,
      sourcePath: entry.sourcePath,
      pluginId: entry.pluginId,
      pluginData: entry.pluginDataJson == null
          ? null
          : _decodeJson(entry.pluginDataJson!),
      coverUrl: entry.coverUrl,
    );
  }

  Map<String, dynamic>? _decodeJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  void remove(String id) {
    state = state.where((entry) => entry.id != id).toList();
    unawaited(_persist());
  }

  void clear() {
    state = const [];
    unawaited(_persist());
  }
}

final downloadHistoryProvider =
    StateNotifierProvider<DownloadHistoryNotifier, List<DownloadHistoryEntry>>(
      (ref) => DownloadHistoryNotifier(),
    );

/// 包装一次下载任务并轮询目标文件大小，更新下载历史中的实时进度。
///
/// Rust 下载接口不返回进度流，这里先通过 HEAD 请求取 Content-Length，
/// 再以约 3Hz 轮询目标文件字节数估算进度；HEAD 失败或服务器不返回
/// 长度时仅展示已下载字节数，不展示百分比。
Future<String> trackDownloadProgress({
  required DownloadHistoryNotifier history,
  required String entryId,
  required String url,
  required Map<String, String> headers,
  required String destPath,
  required Future<String> Function() download,
}) async {
  var totalBytes = 0;
  try {
    final head = await rust
        .pluginHttpRequest(
          method: 'HEAD',
          url: url,
          headersJson: jsonEncode(headers),
          timeout: BigInt.from(8),
        )
        .timeout(const Duration(seconds: 8));
    final decoded = jsonDecode(head);
    if (decoded is Map) {
      final responseHeaders = decoded['headers'];
      if (responseHeaders is Map) {
        final length = responseHeaders['content-length']?.toString();
        final parsed = length == null ? 0 : int.tryParse(length) ?? 0;
        if (parsed > 0) totalBytes = parsed;
      }
    }
  } catch (_) {
    // HEAD 失败不影响下载本身，进度退化为只显示字节数。
  }

  Timer? poller;
  try {
    poller = Timer.periodic(const Duration(milliseconds: 320), (_) {
      File(destPath).length().then((size) {
        history.updateProgress(
          entryId,
          downloadedBytes: size,
          totalBytes: totalBytes,
          progress: totalBytes > 0
              ? (size / totalBytes).clamp(0.0, 1.0)
              : null,
        );
      }).catchError((_) {});
    });
    return await download();
  } finally {
    poller?.cancel();
  }
}
