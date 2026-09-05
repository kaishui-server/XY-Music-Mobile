import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api.dart' as rust;

/// 下载记录状态。
enum DownloadHistoryStatus { downloading, paused, completed, failed }

/// 用户主动暂停/取消下载时由进度跟踪器抛出的信号。
/// 调用方捕获后应静默处理（不提示“下载失败”），记录状态已由
/// 暂停操作标记为 paused。
class DownloadPausedSignal implements Exception {
  const DownloadPausedSignal();
}

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
    /// 下载中的本地目标路径（含 SAF 中转目录），删除任务时用于清理
    /// 半成品文件；完成后与 savedPath 不同（SAF 场景最终文件在树里）。
    this.localPath,
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
  final String? localPath;
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
    String? localPath,
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
    localPath: localPath ?? this.localPath,
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
          'paused' => DownloadHistoryStatus.paused,
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
        localPath: json['localPath']?.toString(),
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
    'localPath': localPath,
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

  /// 加载完成前缓存写操作。此前构造函数里的异步 _load() 会与
  /// begin() 竞争：加载完成时整体替换 state，把刚插入的下载记录
  /// 从内存中冲掉（complete/fail 全部 no-op），表现为“下载中列表
  /// 不显示、重启后显示被中断”。所有状态变更先入队，待加载完成
  /// 后按序应用，彻底消除该竞争。
  final List<void Function()> _pendingOps = [];
  bool _loaded = false;

  /// 已请求取消/暂停的任务 id：进度追踪器轮询到标记后中断收尾。
  final Set<String> _cancelRequests = {};

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_downloadHistoryKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final entries = decoded
              .whereType<Map>()
              .map(
                (value) => DownloadHistoryEntry.fromJson(
                  Map<String, dynamic>.from(value),
                ),
              )
              .toList();
          // 上次进程被杀时处于 downloading 的记录永远不会完成，启动时
          // 标记为失败；paused 状态保留（用户可手动继续重新下载）。
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
        }
      }
    } catch (_) {
      // 历史记录损坏时静默丢弃，不影响下载功能。
    }
    _loaded = true;
    final pending = List<void Function()>.of(_pendingOps);
    _pendingOps.clear();
    for (final op in pending) {
      op();
    }
  }

  /// 加载完成前缓存操作，完成后立即执行。
  void _applyOrQueue(void Function() op) {
    if (_loaded) {
      op();
    } else {
      _pendingOps.add(op);
    }
  }

  Future<void> _persist() {
    final operation = _writeQueue.then((_) async {
      // 写入时再取快照：包含此前所有已应用操作，且不会在加载完成前
      // 用不完整的内存状态覆盖磁盘上的历史记录。
      final snapshot = state.take(kDownloadHistoryLimit).toList();
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _downloadHistoryKey,
        jsonEncode(snapshot.map((e) => e.toJson()).toList()),
      );
    });
    _writeQueue = operation.catchError((_) {});
    return operation;
  }

  /// 同一音源是否已有下载中的任务（用于发起下载前去重提示）。
  bool hasActiveDownload(String sourcePath) {
    final path = sourcePath.trim();
    if (path.isEmpty || !_loaded) return false;
    return state.any(
      (entry) =>
          entry.sourcePath == path &&
          entry.status == DownloadHistoryStatus.downloading,
    );
  }

  /// 记录一条新的下载，返回其 id 用于后续进度/完成/失败更新。
  ///
  /// 去重：同一音源已有下载中的任务时不重复插入记录（返回的新 id
  /// 不会进入列表，后续进度更新自动 no-op），调用方应在发起下载前
  /// 用 [hasActiveDownload] 拦截并提示用户。
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
    final source = sourcePath.trim();
    final entry = DownloadHistoryEntry(
      id: id,
      title: title,
      artist: artist,
      album: album,
      durationMs: durationMs,
      startedAt: DateTime.now().millisecondsSinceEpoch,
      status: DownloadHistoryStatus.downloading,
      quality: quality,
      sourcePath: source,
      pluginId: pluginId,
      pluginDataJson: pluginData == null || pluginData.isEmpty
          ? null
          : jsonEncode(pluginData),
      coverUrl: coverUrl,
    );
    _applyOrQueue(() {
      final duplicate = source.isNotEmpty &&
          state.any(
            (e) =>
                e.sourcePath == source &&
                e.status == DownloadHistoryStatus.downloading,
          );
      if (duplicate) return;
      state = [entry, ...state];
      unawaited(_persist());
    });
    return id;
  }

  void updateProgress(
    String id, {
    double? progress,
    int? downloadedBytes,
    int? totalBytes,
    String? localPath,
  }) {
    _applyOrQueue(() {
      final index = state.indexWhere((entry) => entry.id == id);
      if (index < 0 || state[index].status != DownloadHistoryStatus.downloading) {
        return;
      }
      state = [...state]
        ..[index] = state[index].copyWith(
          progress: progress,
          downloadedBytes: downloadedBytes,
          totalBytes: totalBytes,
          localPath: localPath,
        );
      // 进度更新非常频繁（约 3Hz），只改内存不落盘；完成/失败时会整体持久化。
    });
  }

  void complete(String id, {String? savedPath, String? actualQuality}) {
    _applyOrQueue(() {
      _cancelRequests.remove(id);
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
    });
  }

  void fail(String id, String error) {
    _applyOrQueue(() {
      _cancelRequests.remove(id);
      final index = state.indexWhere((entry) => entry.id == id);
      if (index < 0) return;
      // 用户主动暂停触发的中断不是失败，保持 paused 状态。
      if (state[index].status == DownloadHistoryStatus.paused) return;
      state = [...state]
        ..[index] = state[index].copyWith(
          status: DownloadHistoryStatus.failed,
          error: error,
          finishedAt: DateTime.now().millisecondsSinceEpoch,
        );
      unawaited(_persist());
    });
  }

  /// 暂停一个下载中的任务：标记 paused 并请求取消进度跟踪。底层
  /// HTTP 流无法真正中止，但收尾（入库/完成通知）会被拦截。
  void pause(String id) {
    _applyOrQueue(() {
      final index = state.indexWhere((entry) => entry.id == id);
      if (index < 0 || state[index].status != DownloadHistoryStatus.downloading) {
        return;
      }
      _cancelRequests.add(id);
      state = [...state]
        ..[index] = state[index].copyWith(
          status: DownloadHistoryStatus.paused,
          error: null,
          finishedAt: DateTime.now().millisecondsSinceEpoch,
        );
      unawaited(_persist());
    });
  }

  /// 继续一个已暂停的任务：状态回到 downloading 并清除取消标记，
  /// 由下载管理页用同一 id 重新发起下载（复用同一条记录）。
  bool resumeEntry(String id) {
    if (!_loaded) return false;
    final index = state.indexWhere((entry) => entry.id == id);
    if (index < 0 || state[index].status != DownloadHistoryStatus.paused) {
      return false;
    }
    _cancelRequests.remove(id);
    state = [...state]
      ..[index] = state[index].copyWith(
        status: DownloadHistoryStatus.downloading,
        progress: 0,
        downloadedBytes: 0,
        error: null,
        finishedAt: null,
      );
    unawaited(_persist());
    return true;
  }

  bool isCancelRequested(String id) => _cancelRequests.contains(id);

  /// 重新下载：为该条记录新建一条 downloading 记录，保留原失败原因。
  String restart(String id) {
    final index = _loaded ? state.indexWhere((entry) => entry.id == id) : -1;
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

  /// 删除单条记录。下载中的任务同时置取消标记，拦截其收尾。
  void remove(String id) {
    _applyOrQueue(() {
      _cancelRequests.add(id);
      state = state.where((entry) => entry.id != id).toList();
      unawaited(_persist());
    });
  }

  /// 批量删除记录。返回被删除的记录，供调用方按需清理本地文件。
  List<DownloadHistoryEntry> removeEntries(Set<String> ids) {
    final removed = <DownloadHistoryEntry>[];
    _applyOrQueue(() {
      if (ids.isEmpty) return;
      removed.addAll(state.where((entry) => ids.contains(entry.id)));
      _cancelRequests.addAll(ids);
      state = state.where((entry) => !ids.contains(entry.id)).toList();
      unawaited(_persist());
    });
    return removed;
  }

  void clear() {
    _applyOrQueue(() {
      _cancelRequests.addAll(state.map((entry) => entry.id));
      state = const [];
      unawaited(_persist());
    });
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
///
/// 支持暂停：轮询到取消标记时抛出 [DownloadPausedSignal]，调用方的
/// 下载收尾（校验/入库/完成提示）被跳过；底层 HTTP 流无法中止，会
/// 在后台静默写完（结果被丢弃）。
Future<String> trackDownloadProgress({
  required DownloadHistoryNotifier history,
  required String entryId,
  required String url,
  required Map<String, String> headers,
  required String destPath,
  required Future<String> Function() download,
}) async {
  // 记录本地目标路径：删除任务时可据此清理半成品文件。
  history.updateProgress(entryId, localPath: destPath);
  if (history.isCancelRequested(entryId)) {
    throw const DownloadPausedSignal();
  }

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
  if (history.isCancelRequested(entryId)) {
    throw const DownloadPausedSignal();
  }

  final task = download();
  final paused = Completer<void>();
  Timer? poller;
  try {
    poller = Timer.periodic(const Duration(milliseconds: 320), (_) {
      if (history.isCancelRequested(entryId)) {
        if (!paused.isCompleted) paused.complete();
        return;
      }
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
    final result = await Future.any([
      task,
      paused.future.then((_) => throw const DownloadPausedSignal()),
    ]);
    // 下载已结束但暂停请求恰好插在最后一次轮询之后：同样视为暂停。
    if (history.isCancelRequested(entryId)) {
      throw const DownloadPausedSignal();
    }
    return result;
  } finally {
    poller?.cancel();
  }
}
