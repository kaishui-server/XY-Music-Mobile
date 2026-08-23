import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../library/library_provider.dart';
import '../player/player_provider.dart';
import '../plugins/plugin_runtime.dart';
import '../rust/api.dart';
import 'recent_store.dart';

class RecentSongEntry {
  const RecentSongEntry({required this.song, required this.playedAt});

  final Song song;
  final DateTime playedAt;
}

/// 解析 Rust 返回的最近播放历史。旧版数据可能混用 camelCase，且极少数记录可能被用户数据改写为字符串；
/// 单条坏记录不应让整个“最近播放”页闪退。
List<Map<String, dynamic>> decodeRecentHistoryRows(String rawJson) {
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  } catch (_) {
    return const [];
  }
}

String recentHistorySongPath(Map<String, dynamic> row) {
  final value = row['song_path'] ?? row['songPath'] ?? row['path'];
  return value?.toString().trim() ?? '';
}

int recentHistoryPlayedAt(Map<String, dynamic> row) {
  final value = row['played_at'] ?? row['playedAt'] ?? row['timestamp'];
  if (value is num) return value.toInt();
  final text = value?.toString().trim() ?? '';
  return int.tryParse(text) ??
      DateTime.tryParse(text)?.millisecondsSinceEpoch ??
      0;
}

/// 最近播放记录。等待播放历史真正写入后再刷新，避免当前歌曲已经切换、
/// SQLite 记录尚未落库时提前读取，导致页面一直保留旧结果。
final recentSongsProvider = FutureProvider<List<RecentSongEntry>>((ref) async {
  ref.watch(recentHistoryRevisionProvider);
  final dbPath = await ref.watch(dbPathProvider.future);
  final results = await Future.wait([
    statsGetRecentHistory(dbPath: dbPath, limit: BigInt.from(500)),
    loadRecentSongSnapshots(),
  ]);
  final raw = results[0] as String;
  final snapshots = results[1] as Map<String, RecentSongSnapshot>;
  final rows = decodeRecentHistoryRows(raw);
  if (rows.isEmpty) return const [];

  final paths = <String>{
    for (final row in rows)
      if (recentHistorySongPath(row).isNotEmpty) recentHistorySongPath(row),
  };
  final localPaths = paths
      .where((path) => !_isNetworkRecentPath(path, snapshots[path]))
      .toList(growable: false);
  final songs = localPaths.isEmpty
      ? const <Song>[]
      : await ref.read(libraryProvider.notifier).songsByPaths(localPaths);
  final byPath = {for (final song in songs) song.path: song};

  return rows
      .map((row) {
        final path = recentHistorySongPath(row);
        final playedAt = recentHistoryPlayedAt(row);
        final song = byPath[path] ?? songFromRecentSnapshot(snapshots[path]);
        if (song == null) return null;
        return RecentSongEntry(
          song: song,
          playedAt: DateTime.fromMillisecondsSinceEpoch(
            playedAt.clamp(0, 8640000000000000).toInt(),
          ),
        );
      })
      .whereType<RecentSongEntry>()
      .toList();
});

Future<void> clearRecentSongs(WidgetRef ref) async {
  final dbPath = await ref.read(dbPathProvider.future);
  await Future.wait([
    statsClearRecentHistory(dbPath: dbPath),
    clearRecentSongSnapshots(),
  ]);
  ref.invalidate(recentSongsProvider);
}

bool _isNetworkRecentPath(String path, RecentSongSnapshot? snapshot) =>
    snapshot?.pluginId?.trim().isNotEmpty == true ||
    path.startsWith('plugin://') ||
    path.startsWith('lx://') ||
    path.startsWith('http://') ||
    path.startsWith('https://');

/// 将网络歌曲快照还原为曲库歌曲模型，供统计、首页等非历史页面复用。
Song? songFromRecentSnapshot(RecentSongSnapshot? snapshot) {
  if (snapshot == null) return null;
  final savedCover = snapshot.coverUrl?.trim() ?? '';
  final recoveredCover = snapshot.pluginData == null
      ? ''
      : extractPluginCoverUrl(snapshot.pluginData!);
  return Song(
    path: snapshot.path,
    title: snapshot.title,
    artist: snapshot.artist,
    album: snapshot.album,
    albumKey: snapshot.album,
    duration: (snapshot.durationMs / 1000).round(),
    format: snapshot.pluginId?.trim().isNotEmpty == true ? '插件' : '网络',
    coverUrl: savedCover.isNotEmpty
        ? savedCover
        : (recoveredCover.isEmpty ? null : recoveredCover),
    pluginId: snapshot.pluginId,
    pluginData: snapshot.pluginData,
  );
}
