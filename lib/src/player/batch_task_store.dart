import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'download_history_store.dart' show DownloadProgressSink;

/// 批量任务类型：批量下载 / 批量换源。
enum BatchTaskKind { download, switchSource }

/// 批量任务整体状态。
enum BatchTaskStatus { running, paused, completed, cancelled }

/// 批量任务中单首歌曲的处理状态。
enum BatchTaskSongStatus { pending, processing, success, skipped, failed }

/// 批量任务中的单首歌曲记录。
class BatchTaskSong {
  const BatchTaskSong({
    required this.title,
    this.artist = '',
    this.album = '',
    required this.status,
    this.detail,
    this.progress = 0,
  });

  final String title;
  final String artist;
  final String album;
  final BatchTaskSongStatus status;

  /// 附加说明：换源目标插件、失败原因或跳过原因。
  final String? detail;

  /// 单曲下载进度 0~1（仅 processing 状态有意义）。
  final double progress;

  BatchTaskSong copyWith({
    BatchTaskSongStatus? status,
    String? detail,
    double? progress,
  }) => BatchTaskSong(
    title: title,
    artist: artist,
    album: album,
    status: status ?? this.status,
    detail: detail ?? this.detail,
    progress: progress ?? this.progress,
  );

  factory BatchTaskSong.fromJson(Map<String, dynamic> json) => BatchTaskSong(
    title: json['title']?.toString() ?? '',
    artist: json['artist']?.toString() ?? '',
    album: json['album']?.toString() ?? '',
    status: switch (json['status']) {
      'success' => BatchTaskSongStatus.success,
      'skipped' => BatchTaskSongStatus.skipped,
      'pending' => BatchTaskSongStatus.pending,
      'processing' => BatchTaskSongStatus.processing,
      _ => BatchTaskSongStatus.failed,
    },
    detail: json['detail']?.toString(),
    progress: (json['progress'] as num?)?.toDouble() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'title': title,
    'artist': artist,
    'album': album,
    'status': status.name,
    'detail': detail,
    'progress': progress,
  };
}

/// 一次批量操作（批量下载 / 批量换源）的记录：一个操作记为一张卡片，
/// 卡片可展开查看本次操作涉及的实际歌曲列表。任务在操作开始时即创建，
/// 执行期间携带整体进度与单曲进度，可暂停 / 继续 / 提前结束。
class BatchTask {
  const BatchTask({
    required this.id,
    required this.kind,
    required this.createdAt,
    required this.songs,
    this.status = BatchTaskStatus.completed,
    this.finishedAt,
  });

  final String id;
  final BatchTaskKind kind;
  final int createdAt;
  final BatchTaskStatus status;
  final int? finishedAt;
  final List<BatchTaskSong> songs;

  bool get isRunning => status == BatchTaskStatus.running;
  bool get isPaused => status == BatchTaskStatus.paused;

  /// 是否仍在执行（运行中或已暂停），用于展示进度条与操作按钮。
  bool get isActive => isRunning || isPaused;

  int get total => songs.length;
  int get successCount =>
      songs.where((s) => s.status == BatchTaskSongStatus.success).length;
  int get failedCount =>
      songs.where((s) => s.status == BatchTaskSongStatus.failed).length;
  int get skippedCount =>
      songs.where((s) => s.status == BatchTaskSongStatus.skipped).length;

  /// 已完成处理的歌曲数（成功 / 失败 / 跳过）。
  int get finishedCount => songs
      .where(
        (s) =>
            s.status == BatchTaskSongStatus.success ||
            s.status == BatchTaskSongStatus.failed ||
            s.status == BatchTaskSongStatus.skipped,
      )
      .length;

  /// 总进度 0~1：已完成的歌曲计 1，处理中的歌曲按单曲进度折算。
  double get progress {
    if (songs.isEmpty) return 0;
    var sum = 0.0;
    for (final song in songs) {
      switch (song.status) {
        case BatchTaskSongStatus.success:
        case BatchTaskSongStatus.failed:
        case BatchTaskSongStatus.skipped:
          sum += 1;
        case BatchTaskSongStatus.processing:
          sum += song.progress.clamp(0.0, 1.0);
        case BatchTaskSongStatus.pending:
          break;
      }
    }
    return (sum / songs.length).clamp(0.0, 1.0);
  }

  BatchTask copyWith({
    BatchTaskStatus? status,
    int? finishedAt,
    List<BatchTaskSong>? songs,
  }) => BatchTask(
    id: id,
    kind: kind,
    createdAt: createdAt,
    status: status ?? this.status,
    finishedAt: finishedAt ?? this.finishedAt,
    songs: songs ?? this.songs,
  );

  factory BatchTask.fromJson(Map<String, dynamic> json) => BatchTask(
    id: json['id']?.toString() ?? '',
    kind: json['kind'] == 'switchSource'
        ? BatchTaskKind.switchSource
        : BatchTaskKind.download,
    createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
    status: switch (json['status']) {
      'running' => BatchTaskStatus.running,
      'paused' => BatchTaskStatus.paused,
      'cancelled' => BatchTaskStatus.cancelled,
      _ => BatchTaskStatus.completed,
    },
    finishedAt: (json['finishedAt'] as num?)?.toInt(),
    songs:
        (json['songs'] as List?)
            ?.whereType<Map>()
            .map(
              (value) => BatchTaskSong.fromJson(Map<String, dynamic>.from(value)),
            )
            .toList() ??
        const [],
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'createdAt': createdAt,
    'status': status.name,
    'finishedAt': finishedAt,
    'songs': [for (final song in songs) song.toJson()],
  };
}

/// 批量任务持久化上限：超过后丢弃最旧记录。
const kBatchTaskLimit = 200;

const _batchTaskKey = 'batchTasksV1';
Future<void> _writeQueue = Future<void>.value();

class BatchTaskNotifier extends StateNotifier<List<BatchTask>> {
  BatchTaskNotifier() : super(const []) {
    _load();
  }

  int _counter = 0;

  /// 已取消但记录可能已被删除的任务 id：删除运行中的任务后其 id 不再
  /// 出现在 state 里，后台循环仍可通过这里识别取消，及时停止处理剩余歌曲。
  final Set<String> _cancelledIds = <String>{};

  /// 加载完成前缓存写操作，避免与异步 _load 竞争（同下载历史存储）。
  final List<void Function()> _pendingOps = [];
  bool _loaded = false;

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_batchTaskKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final tasks = decoded
              .whereType<Map>()
              .map(
                (value) => BatchTask.fromJson(Map<String, dynamic>.from(value)),
              )
              .toList();
          // 上次进程被杀时仍在执行的任务不会继续，启动时收尾为已取消，
          // 未处理的歌曲标记为跳过，避免卡片一直停留在“进行中”。
          for (var i = 0; i < tasks.length; i++) {
            final task = tasks[i];
            if (!task.isActive) continue;
            final songs = [
              for (final song in task.songs)
                if (song.status == BatchTaskSongStatus.pending ||
                    song.status == BatchTaskSongStatus.processing)
                  song.copyWith(
                    status: BatchTaskSongStatus.skipped,
                    detail: '任务已中断',
                    progress: 0,
                  )
                else
                  song,
            ];
            tasks[i] = task.copyWith(
              status: BatchTaskStatus.cancelled,
              finishedAt: task.createdAt,
              songs: songs,
            );
          }
          state = tasks;
        }
      }
    } catch (_) {
      // 记录损坏时静默丢弃，不影响批量功能。
    }
    _loaded = true;
    final pending = List<void Function()>.of(_pendingOps);
    _pendingOps.clear();
    for (final op in pending) {
      op();
    }
  }

  void _applyOrQueue(void Function() op) {
    if (_loaded) {
      op();
    } else {
      _pendingOps.add(op);
    }
  }

  Future<void> _persist() {
    final operation = _writeQueue.then((_) async {
      final snapshot = state.take(kBatchTaskLimit).toList();
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _batchTaskKey,
        jsonEncode(snapshot.map((task) => task.toJson()).toList()),
      );
    });
    _writeQueue = operation.catchError((_) {});
    return operation;
  }

  void _trim() {
    if (state.length > kBatchTaskLimit) {
      state = state.take(kBatchTaskLimit).toList();
    }
  }

  BatchTask? _find(String id) {
    for (final task in state) {
      if (task.id == id) return task;
    }
    return null;
  }

  /// 在批量操作开始时创建一条运行中的任务，返回任务 id 用于后续更新。
  /// 歌曲数不足 2 首时视为单项任务，不创建（返回 null）。
  String? create({
    required BatchTaskKind kind,
    required List<BatchTaskSong> songs,
  }) {
    if (songs.length < 2) return null;
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
    final task = BatchTask(
      id: id,
      kind: kind,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      status: BatchTaskStatus.running,
      songs: List.unmodifiable(songs),
    );
    _applyOrQueue(() {
      state = [task, ...state];
      _trim();
      unawaited(_persist());
    });
    return id;
  }

  /// 更新单首歌曲的状态 / 说明 / 进度（状态变更会落盘）。
  void updateSong(
    String taskId,
    int index, {
    BatchTaskSongStatus? status,
    String? detail,
    double? progress,
  }) {
    _applyOrQueue(() {
      final taskIndex = state.indexWhere((task) => task.id == taskId);
      if (taskIndex < 0) return;
      final songs = state[taskIndex].songs;
      if (index < 0 || index >= songs.length) return;
      final updated = [...songs];
      updated[index] = songs[index].copyWith(
        status: status,
        detail: detail,
        progress: progress,
      );
      state = [...state]..[taskIndex] = state[taskIndex].copyWith(
        songs: updated,
      );
      unawaited(_persist());
    });
  }

  /// 高频单曲进度刷新（约 3Hz）：只改内存不落盘，完成/失败时整体持久化。
  void updateSongProgress(String taskId, int index, {double? progress}) {
    if (progress == null) return;
    _applyOrQueue(() {
      final taskIndex = state.indexWhere((task) => task.id == taskId);
      if (taskIndex < 0) return;
      final songs = state[taskIndex].songs;
      if (index < 0 || index >= songs.length) return;
      if (songs[index].status != BatchTaskSongStatus.processing) return;
      final updated = [...songs];
      updated[index] = songs[index].copyWith(progress: progress);
      state = [...state]..[taskIndex] = state[taskIndex].copyWith(
        songs: updated,
      );
    });
  }

  /// 暂停任务：当前歌曲下载完成后挂起，不再开始下一首。
  void pause(String taskId) {
    _applyOrQueue(() {
      final index = state.indexWhere((task) => task.id == taskId);
      if (index < 0 || state[index].status != BatchTaskStatus.running) return;
      state = [...state]..[index] = state[index].copyWith(
        status: BatchTaskStatus.paused,
      );
      unawaited(_persist());
    });
  }

  /// 继续已暂停的任务。
  void resume(String taskId) {
    _applyOrQueue(() {
      final index = state.indexWhere((task) => task.id == taskId);
      if (index < 0 || state[index].status != BatchTaskStatus.paused) return;
      state = [...state]..[index] = state[index].copyWith(
        status: BatchTaskStatus.running,
      );
      unawaited(_persist());
    });
  }

  /// 提前结束任务：正在执行的歌曲被中断，未开始的歌曲不再执行。
  void cancel(String taskId) {
    _applyOrQueue(() {
      final index = state.indexWhere((task) => task.id == taskId);
      if (index < 0 || !state[index].isActive) return;
      _cancelledIds.add(taskId);
      state = [...state]..[index] = state[index].copyWith(
        status: BatchTaskStatus.cancelled,
        finishedAt: DateTime.now().millisecondsSinceEpoch,
      );
      unawaited(_persist());
    });
  }

  /// 任务正常收尾：运行中 / 已暂停 → 已完成（已取消状态保持不变）。
  void finish(String taskId) {
    _applyOrQueue(() {
      _cancelledIds.remove(taskId);
      final index = state.indexWhere((task) => task.id == taskId);
      if (index < 0) return;
      if (state[index].status == BatchTaskStatus.cancelled) return;
      state = [...state]..[index] = state[index].copyWith(
        status: BatchTaskStatus.completed,
        finishedAt: DateTime.now().millisecondsSinceEpoch,
      );
      unawaited(_persist());
    });
  }

  bool isPaused(String taskId) => _find(taskId)?.isPaused ?? false;

  bool isCancelled(String taskId) =>
      _cancelledIds.contains(taskId) ||
      _find(taskId)?.status == BatchTaskStatus.cancelled;

  /// 等待任务从暂停中恢复；返回 false 表示任务已被提前结束，应停止后续处理。
  Future<bool> waitWhilePaused(String taskId) async {
    while (isPaused(taskId) && !isCancelled(taskId)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return !isCancelled(taskId);
  }

  /// 批量下载的进度接收器：把底层轮询的进度写回本任务的指定歌曲。
  DownloadProgressSink progressSink(String taskId, int index) =>
      DownloadProgressSink(
        onProgress: ({progress, downloadedBytes, totalBytes, localPath}) =>
            updateSongProgress(taskId, index, progress: progress),
        isCancelled: () => isCancelled(taskId),
      );

  void remove(String id) {
    _applyOrQueue(() {
      final task = _find(id);
      // 删除运行中的任务时先打上取消标记：记录移除后后台循环仍能据此
      // 及时停止，不会继续处理剩余歌曲。
      if (task != null && task.isActive) _cancelledIds.add(id);
      state = state.where((task) => task.id != id).toList();
      unawaited(_persist());
    });
  }

  void clear() {
    _applyOrQueue(() {
      // 清空同样要让运行中的任务停止后续处理。
      for (final task in state) {
        if (task.isActive) _cancelledIds.add(task.id);
      }
      state = const [];
      unawaited(_persist());
    });
  }
}

final batchTaskProvider =
    StateNotifierProvider<BatchTaskNotifier, List<BatchTask>>(
      (ref) => BatchTaskNotifier(),
    );