import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../library/library_provider.dart';
import '../plugins/lx_playlist_import.dart';
import '../plugins/plugin_runtime.dart';
import '../widgets/top_notice.dart';
import 'playlists_provider.dart';

/// 歌单来源同步失败时抛出的异常，[message] 直接展示给用户。
class PlaylistSyncException implements Exception {
  const PlaylistSyncException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一次来源拉取得到的歌单快照（已按导入顺序排列的歌曲列表）。
class PlaylistSourceSnapshot {
  const PlaylistSourceSnapshot({required this.source, required this.songs});

  final PlaylistImportSource source;
  final List<Song> songs;
}

/// 同步结果统计。
class PlaylistSyncResult {
  const PlaylistSyncResult({
    required this.changed,
    required this.added,
    required this.removed,
    required this.total,
  });

  /// 是否产生了变化（false 表示歌单已是最新，未写入任何数据）。
  final bool changed;
  final int added;
  final int removed;
  final int total;
}

/// 同步计划：差分合并后的新歌单状态（顺序 + 归属 + 快照）与统计。
class PlaylistSyncPlan {
  const PlaylistSyncPlan({
    required this.songPaths,
    required this.songSources,
    required this.songSnapshots,
    required this.customOrder,
    required this.added,
    required this.removed,
    required this.changed,
  });

  final List<String> songPaths;
  final Map<String, List<String>> songSources;
  final Map<String, PlaylistSongSnapshot> songSnapshots;
  final List<String>? customOrder;
  final int added;
  final int removed;
  final bool changed;
}

/// 计算同步计划（纯函数，不读写任何状态）。
///
/// 合并规则（参考 BakaMusic import-sync）：
/// - 全部来源快照按来源顺序展开，同一首歌（path 相同）合并来源键；
/// - 既有歌曲不在任何快照中：手动添加（无来源归属）的保留在末尾，
///   来源歌曲则移除（来源不再包含它）；
/// - 歌曲身份即 path（plugin://插件id/歌曲id 或 lx:// 虚拟路径），
///   天然完成平台 + 歌曲 ID 去重；
/// - 顺序与归属均无变化时 [changed] 为 false（调用方跳过写入，实现
///   「无变化零写入」的万首歌单性能要求）。
PlaylistSyncPlan planPlaylistSync({
  required List<String> currentPaths,
  required Map<String, List<String>> currentSources,
  required Map<String, PlaylistSongSnapshot> currentSnapshots,
  required List<String>? currentCustomOrder,
  required List<PlaylistSourceSnapshot> snapshots,
}) {
  // 快照集合必须完整：部分来源拉取失败时调用方不允许进入本函数。
  final next = <String, List<String>>{};
  for (final snapshot in snapshots) {
    final sourceKey = snapshot.source.key;
    for (final song in snapshot.songs) {
      if (song.path.trim().isEmpty) continue;
      final keys = next[song.path];
      if (keys == null) {
        next[song.path] = [sourceKey];
      } else if (!keys.contains(sourceKey)) {
        keys.add(sourceKey);
      }
    }
  }

  // 既有歌曲：来源歌曲随来源移除，手动歌曲保留（归属置空）。
  final currentPathSet = currentPaths.toSet();
  var removed = 0;
  for (final path in currentPaths) {
    if (next.containsKey(path)) continue;
    if ((currentSources[path] ?? const []).isNotEmpty) {
      removed++;
    } else {
      next[path] = const [];
    }
  }

  final orderedPaths = next.keys.toList();
  var added = 0;
  for (final path in orderedPaths) {
    if (!currentPathSet.contains(path)) added++;
  }

  // 归属表只保留仍在歌单中的来源歌曲（手动歌曲与空键不落表）。
  final nextSources = <String, List<String>>{
    for (final entry in next.entries)
      if (entry.value.isNotEmpty) entry.key: entry.value,
  };

  // 快照：保留既有条目，仅为新增歌曲补充（来源歌曲的元数据刷新
  // 不触发写回，维持最小差分）。
  final orderedPathSet = orderedPaths.toSet();
  final nextSnapshots = Map<String, PlaylistSongSnapshot>.of(currentSnapshots)
    ..removeWhere((path, _) => !orderedPathSet.contains(path));
  for (final snapshot in snapshots) {
    for (final song in snapshot.songs) {
      if (song.path.trim().isEmpty) continue;
      if (!nextSnapshots.containsKey(song.path)) {
        nextSnapshots[song.path] = PlaylistSongSnapshot.fromSong(song);
      }
    }
  }

  // 自定义排序：保留仍存在的歌曲顺序，新增歌曲追加到末尾。
  List<String>? nextCustomOrder;
  if (currentCustomOrder != null) {
    final knownOrder = currentCustomOrder.toSet();
    nextCustomOrder = [
      for (final path in currentCustomOrder)
        if (orderedPathSet.contains(path)) path,
      for (final path in orderedPaths)
        if (!knownOrder.contains(path)) path,
    ];
  }

  final changed =
      !_stringListEquals(orderedPaths, currentPaths) ||
      !_songSourcesEquals(nextSources, currentSources);
  return PlaylistSyncPlan(
    songPaths: orderedPaths,
    songSources: nextSources,
    songSnapshots: nextSnapshots,
    customOrder: nextCustomOrder,
    added: added,
    removed: removed,
    changed: changed,
  );
}

bool _stringListEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _songSourcesEquals(
  Map<String, List<String>> a,
  Map<String, List<String>> b,
) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    final other = b[entry.key];
    if (other == null || !_stringListEquals(entry.value, other)) return false;
  }
  return true;
}

/// 全局同步请求调度器（参考 BakaMusic sync-fetcher）：
/// - 最多 3 个不同插件并发拉取；
/// - 同一插件串行执行（避免打爆单平台接口）；
/// - 相同「插件 + 输入」的在途请求合并复用（重复请求只发一次）。
class ImportSyncScheduler {
  ImportSyncScheduler._();

  static final ImportSyncScheduler instance = ImportSyncScheduler._();

  static const _maxConcurrent = 3;

  final Set<String> _busyPlugins = {};
  final List<_SyncJob> _queue = [];
  final Map<String, Future<Object?>> _inFlight = {};
  int _active = 0;

  Future<T> run<T>(
    String pluginKey,
    String input,
    Future<T> Function() task,
  ) {
    final requestKey = '$pluginKey\u0000$input';
    final existing = _inFlight[requestKey];
    if (existing != null) {
      return existing.then((value) => value as T);
    }
    final job = _SyncJob(
      pluginKey: pluginKey,
      requestKey: requestKey,
      task: () async => await task(),
    );
    _inFlight[requestKey] = job.completer.future;
    _queue.add(job);
    _pump();
    return job.completer.future.then((value) => value as T);
  }

  void _pump() {
    while (_active < _maxConcurrent) {
      final index = _queue.indexWhere(
        (job) => !_busyPlugins.contains(job.pluginKey),
      );
      if (index < 0) return;
      final job = _queue.removeAt(index);
      _busyPlugins.add(job.pluginKey);
      _active++;
      job.task().then(
        (value) => _complete(job, value, null),
        onError: (Object error, StackTrace stack) =>
            _complete(job, null, (error, stack)),
      );
    }
  }

  void _complete(_SyncJob job, Object? value, (Object, StackTrace)? error) {
    _active--;
    _busyPlugins.remove(job.pluginKey);
    if (identical(_inFlight[job.requestKey], job.completer.future)) {
      _inFlight.remove(job.requestKey);
    }
    if (error != null) {
      job.completer.completeError(error.$1, error.$2);
    } else {
      job.completer.complete(value);
    }
    _pump();
  }
}

class _SyncJob {
  _SyncJob({required this.pluginKey, required this.requestKey, required this.task});

  final String pluginKey;
  final String requestKey;
  final Future<Object?> Function() task;
  final Completer<Object?> completer = Completer<Object?>();
}

/// 插件搜索结果 → 歌单歌曲（网络导入与来源同步共用的转换）。
Song? pluginSearchSongToPlaylistSong(
  EnabledMusicPlugin plugin,
  PluginSearchSong item,
) {
  if (item.title.trim().isEmpty) return null;
  return Song(
    path: pluginSongPath(plugin, item),
    title: item.title,
    artist: item.artist,
    album: item.album,
    albumKey: item.album,
    duration: (item.durationMs / 1000).round(),
    format: '网络',
    coverUrl: item.coverUrl,
    pluginId: plugin.id,
    pluginData: item.rawData,
    lyricsRaw: embeddedLyricsFromRaw(item.rawData),
  );
}

/// 洛雪直连歌单的 raw 歌曲 → 歌单歌曲（关联洛雪插件与 lx 元数据）。
Song? lxRawToPlaylistSong(
  EnabledMusicPlugin plugin,
  Map<String, dynamic> raw,
) {
  final title = raw['title']?.toString().trim() ?? '';
  final path = raw['_sourcePath']?.toString() ?? '';
  if (title.isEmpty || path.isEmpty) return null;
  final duration = raw['duration'];
  return Song(
    path: path,
    title: title,
    artist: raw['artist']?.toString() ?? '',
    album: raw['album']?.toString() ?? '',
    albumKey: raw['album']?.toString() ?? '',
    duration: duration is num ? duration.toInt() : 0,
    format: '网络',
    coverUrl: raw['artwork']?.toString(),
    pluginId: plugin.id,
    pluginData: raw,
    lyricsRaw: embeddedLyricsFromRaw(raw),
  );
}

/// 从插件 raw 数据里提取内嵌歌词（网络导入与洛雪本地导入共用）。
String? embeddedLyricsFromRaw(Map<String, dynamic> raw) {
  for (final key in const [
    'yrc',
    'qrc',
    'eslrc',
    'lxlyric',
    'lyric',
    'lyrics',
    'lrc',
  ]) {
    final value = raw[key];
    if (value is String && value.trim().isNotEmpty) return value;
    if (value is Map) {
      for (final nested in const ['lyric', 'lyrics', 'lrc', 'content']) {
        final text = value[nested];
        if (text is String && text.trim().isNotEmpty) return text;
      }
    }
  }
  return null;
}

/// 正在同步的歌单 id（单歌单互斥，防止重复触发互相覆盖）。
final _syncingPlaylistIds = <String>{};

/// 执行一次歌单来源同步（UI 调用入口）。
///
/// 流程（参考 BakaMusic service.syncImportedSheet）：
/// 1. 先解析全部来源的插件，再开始任何网络请求；
/// 2. 经全局调度器并发拉取全部来源快照，任一失败立即中止
///    （先全量拉取后持久化，失败时现有歌曲保持不变）；
/// 3. 提交前复核插件列表（拉取期间插件被停用/删除则放弃提交）；
/// 4. 差分合并：无变化跳过写入，有变化一次性写回。
Future<PlaylistSyncResult> syncPlaylist(
  WidgetRef ref,
  MobilePlaylist playlist,
) async {
  final notifier = ref.read(playlistsProvider.notifier);
  await notifier.ready;
  // 重新读取最新歌单状态（页面传入的可能已过期）。
  final current = notifier.items
      .where((item) => item.id == playlist.id)
      .firstOrNull;
  if (current == null) {
    throw const PlaylistSyncException('歌单不存在或已被删除');
  }
  if (!_syncingPlaylistIds.add(current.id)) {
    throw const PlaylistSyncException('该歌单正在同步，请稍后再试');
  }
  try {
    final sources = current.importSources;
    if (sources.isEmpty) {
      throw const PlaylistSyncException('此歌单缺少导入来源，请重新导入');
    }

    // 先解析全部来源的插件（缺失即中止，不做任何网络请求）。
    // AsyncValue 对象本身保留用于提交前的失效复核。
    final pluginsValue = ref.read(enabledMusicPluginsProvider);
    final plugins = await ref.read(enabledMusicPluginsProvider.future);
    final resolved = <String, EnabledMusicPlugin>{};
    for (final source in sources) {
      final plugin = plugins
          .where((item) => item.id == source.pluginId)
          .firstOrNull;
      if (plugin == null) {
        throw const PlaylistSyncException(
          '导入插件未启用或已移除，请恢复原插件后重试',
        );
      }
      resolved[source.key] = plugin;
    }

    // 并发拉取全部来源快照：任何来源失败则整体中止（不写任何数据）。
    final runtime = ref.read(pluginRuntimeProvider);
    final fetched = <String, List<Song>>{};
    final failures = <String>[];
    await Future.wait([
      for (final source in sources)
        _fetchSourceSongs(runtime, resolved[source.key]!, source).then(
          (songs) {
            fetched[source.key] = songs;
          },
          onError: (Object error) {
            failures.add(
              '${_sourceLabel(source, resolved[source.key]!)}：'
              '${error.toString().replaceFirst('Exception: ', '')}',
            );
          },
        ),
    ]);
    if (failures.isNotEmpty) {
      throw PlaylistSyncException(
        '同步失败：${failures.first}（现有歌曲保持不变）',
      );
    }

    // 提交前复核插件列表：拉取期间插件变化则放弃提交。
    if (!identical(pluginsValue, ref.read(enabledMusicPluginsProvider))) {
      throw const PlaylistSyncException('插件状态已变化，本次同步已取消');
    }

    final plan = planPlaylistSync(
      currentPaths: current.songPaths,
      currentSources: current.songSources,
      currentSnapshots: current.songSnapshots,
      currentCustomOrder: current.customOrder,
      snapshots: [
        for (final source in sources)
          PlaylistSourceSnapshot(
            source: source,
            songs: fetched[source.key] ?? const [],
          ),
      ],
    );
    if (!plan.changed) {
      return PlaylistSyncResult(
        changed: false,
        added: 0,
        removed: 0,
        total: current.songPaths.length,
      );
    }
    await notifier.applySync(
      current.id,
      songPaths: plan.songPaths,
      songSources: plan.songSources,
      songSnapshots: plan.songSnapshots,
      customOrder: plan.customOrder,
    );
    return PlaylistSyncResult(
      changed: true,
      added: plan.added,
      removed: plan.removed,
      total: plan.songPaths.length,
    );
  } finally {
    _syncingPlaylistIds.remove(current.id);
  }
}

String _sourceLabel(PlaylistImportSource source, EnabledMusicPlugin plugin) {
  if (source.kind == 'lx' && (source.lxSource ?? '').isNotEmpty) {
    return '${plugin.name} · ${lxSourceLabel(source.lxSource!)}';
  }
  return plugin.name;
}

Future<List<Song>> _fetchSourceSongs(
  PluginRuntimeService runtime,
  EnabledMusicPlugin plugin,
  PlaylistImportSource source,
) async {
  if (source.kind == 'lx') {
    final lxSource = (source.lxSource ?? '').trim();
    if (!kLxSourceIds.contains(lxSource)) {
      throw const PlaylistSyncException('来源的洛雪音源无效，请重新导入');
    }
    final result = await ImportSyncScheduler.instance.run(
      'lx:${plugin.id}',
      source.input,
      () => importLxPlaylist(source: lxSource, idOrUrl: source.input),
    );
    return [
      for (final raw in result.songs) lxRawToPlaylistSong(plugin, raw),
    ].whereType<Song>().toList();
  }
  final result = await ImportSyncScheduler.instance.run(
    'plugin:${plugin.id}',
    source.input,
    () => runtime.importPlaylist(plugin, source.input),
  );
  return [
    for (final item in result.songs) pluginSearchSongToPlaylistSong(plugin, item),
  ].whereType<Song>().toList();
}

/// 从 UI 触发一次歌单来源同步：进度与结果通过顶部提示条展示。
Future<void> syncPlaylistWithNotice(
  BuildContext context,
  WidgetRef ref,
  MobilePlaylist playlist,
) async {
  XyNotice.show(
    context,
    message: '正在同步“${playlist.name}”的最新内容…',
    type: XyNoticeType.info,
    duration: const Duration(seconds: 60),
  );
  try {
    final result = await syncPlaylist(ref, playlist);
    if (!context.mounted) return;
    if (!result.changed) {
      XyNotice.show(
        context,
        message: '歌单已是最新，共 ${result.total} 首',
        type: XyNoticeType.success,
      );
      return;
    }
    final removedInfo = result.removed > 0 ? '，移除 ${result.removed} 首' : '';
    XyNotice.show(
      context,
      message: '同步完成：新增 ${result.added} 首$removedInfo，'
          '共 ${result.total} 首',
      type: XyNoticeType.success,
    );
  } on PlaylistSyncException catch (error) {
    if (!context.mounted) return;
    XyNotice.show(context, message: error.message, type: XyNoticeType.error);
  } catch (error) {
    if (!context.mounted) return;
    XyNotice.show(
      context,
      message: '同步失败：${error.toString().replaceFirst('Exception: ', '')}',
      type: XyNoticeType.error,
    );
  }
}
