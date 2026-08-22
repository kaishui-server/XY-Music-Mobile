import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../library/library_provider.dart';
import '../player/player_provider.dart';
import '../rust/api.dart';

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

/// 最近播放记录。监听当前曲目变化，让用户从迷你播放器切歌后回到本页时
/// 能立即看到新记录；排序严格沿用 Rust 统计库返回的播放时间。
final recentSongsProvider = FutureProvider<List<RecentSongEntry>>((ref) async {
  ref.watch(playerProvider.select((state) => state.current?.path));
  final dbPath = await ref.watch(dbPathProvider.future);
  final raw = await statsGetRecentHistory(
    dbPath: dbPath,
    limit: BigInt.from(500),
  );
  final rows = decodeRecentHistoryRows(raw);
  if (rows.isEmpty) return const [];

  final paths = rows
      .map(recentHistorySongPath)
      .where((path) => path.isNotEmpty)
      // 最近播放表主要保存本地曲库路径；插件/网络虚拟路径不在 SQLite songs 表中，
      // 不传入本地查询，避免旧数据触发数据库错误。
      .where(
        (path) =>
            !path.startsWith('plugin://') &&
            !path.startsWith('lx://') &&
            !path.startsWith('http://') &&
            !path.startsWith('https://'),
      )
      .toList();
  if (paths.isEmpty) return const [];
  final songs = await ref.read(libraryProvider.notifier).songsByPaths(paths);
  final byPath = {for (final song in songs) song.path: song};

  return rows
      .map((row) {
        final path = recentHistorySongPath(row);
        final playedAt = recentHistoryPlayedAt(row);
        final song = byPath[path];
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
  await statsClearRecentHistory(dbPath: dbPath);
  ref.invalidate(recentSongsProvider);
}
