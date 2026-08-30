import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 最近播放中的网络歌曲不在本地曲库，必须额外保存再次展示、播放所需的元数据。
class RecentSongSnapshot {
  const RecentSongSnapshot({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
    required this.playedAt,
    this.pluginId,
    this.pluginData,
    this.coverUrl,
  });

  final String path;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final int playedAt;
  final String? pluginId;
  final Map<String, dynamic>? pluginData;
  final String? coverUrl;

  factory RecentSongSnapshot.fromJson(Map<String, dynamic> json) =>
      RecentSongSnapshot(
        path: json['path'] as String? ?? '',
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String? ?? '',
        album: json['album'] as String? ?? '',
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        playedAt: (json['playedAt'] as num?)?.toInt() ?? 0,
        pluginId: json['pluginId'] as String?,
        pluginData: json['pluginData'] is Map
            ? Map<String, dynamic>.from(json['pluginData'] as Map)
            : null,
        coverUrl: json['coverUrl'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'path': path,
    'title': title,
    'artist': artist,
    'album': album,
    'durationMs': durationMs,
    'playedAt': playedAt,
    'pluginId': pluginId,
    'pluginData': pluginData,
    'coverUrl': coverUrl,
  };
}

const _recentSongMetadataKey = 'recentSongMetadataV1';
const _maxRecentSongSnapshots = 300;

// 播放/切歌可能连续触发异步写入；串行化可避免较晚完成的旧快照覆盖新数据。
Future<void> _recentSnapshotWriteQueue = Future<void>.value();

Future<Map<String, RecentSongSnapshot>> loadRecentSongSnapshots() async {
  try {
    await _recentSnapshotWriteQueue;
  } catch (_) {
    // 上一次写入失败不应阻止读取已有快照。
  }
  final prefs = await SharedPreferences.getInstance();
  return _decodeSnapshots(prefs.getString(_recentSongMetadataKey));
}

Future<void> rememberRecentSongSnapshot(RecentSongSnapshot snapshot) {
  final operation = _recentSnapshotWriteQueue.then((_) async {
    final prefs = await SharedPreferences.getInstance();
    final snapshots = _decodeSnapshots(prefs.getString(_recentSongMetadataKey));
    snapshots[snapshot.path] = snapshot;

    if (snapshots.length > _maxRecentSongSnapshots) {
      final oldestFirst = snapshots.values.toList()
        ..sort((a, b) => a.playedAt.compareTo(b.playedAt));
      for (final stale in oldestFirst.take(
        snapshots.length - _maxRecentSongSnapshots,
      )) {
        snapshots.remove(stale.path);
      }
    }

    await prefs.setString(
      _recentSongMetadataKey,
      jsonEncode(
        snapshots.map((path, value) => MapEntry(path, value.toJson())),
        toEncodable: (value) => value.toString(),
      ),
    );
  });
  _recentSnapshotWriteQueue = operation.catchError((_) {});
  return operation;
}

Future<void> clearRecentSongSnapshots() {
  final operation = _recentSnapshotWriteQueue.then((_) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_recentSongMetadataKey);
  });
  _recentSnapshotWriteQueue = operation.catchError((_) {});
  return operation;
}

/// 移除单首歌曲的最近播放快照（用户从最近播放列表删除时调用）。
Future<void> forgetRecentSongSnapshot(String path) {
  final operation = _recentSnapshotWriteQueue.then((_) async {
    final prefs = await SharedPreferences.getInstance();
    final snapshots = _decodeSnapshots(prefs.getString(_recentSongMetadataKey));
    if (snapshots.remove(path) != null) {
      await prefs.setString(
        _recentSongMetadataKey,
        jsonEncode(
          snapshots.map((path, value) => MapEntry(path, value.toJson())),
          toEncodable: (value) => value.toString(),
        ),
      );
    }
  });
  _recentSnapshotWriteQueue = operation.catchError((_) {});
  return operation;
}

Map<String, RecentSongSnapshot> _decodeSnapshots(String? raw) {
  if (raw == null || raw.trim().isEmpty) return {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    final result = <String, RecentSongSnapshot>{};
    for (final entry in decoded.entries) {
      if (entry.value is! Map) continue;
      final snapshot = RecentSongSnapshot.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
      if (snapshot.path.isNotEmpty) result[snapshot.path] = snapshot;
    }
    return result;
  } catch (_) {
    return {};
  }
}
