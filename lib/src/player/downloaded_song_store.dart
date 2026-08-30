import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/settings.dart';

class DownloadedSongSnapshot {
  const DownloadedSongSnapshot({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
    required this.downloadedAt,
    this.sourcePath,
    this.quality,
    this.coverUrl,
    this.lyricsRaw,
  });

  final String path;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final int downloadedAt;
  final String? sourcePath;
  final String? quality;
  final String? coverUrl;
  final String? lyricsRaw;

  factory DownloadedSongSnapshot.fromJson(Map<String, dynamic> json) =>
      DownloadedSongSnapshot(
        path: json['path']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        artist: json['artist']?.toString() ?? '',
        album: json['album']?.toString() ?? '',
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        downloadedAt: (json['downloadedAt'] as num?)?.toInt() ?? 0,
        sourcePath: json['sourcePath']?.toString(),
        quality: json['quality']?.toString(),
        coverUrl: json['coverUrl']?.toString(),
        lyricsRaw: json['lyricsRaw']?.toString(),
      );

  Map<String, dynamic> toJson() => {
    'path': path,
    'title': title,
    'artist': artist,
    'album': album,
    'durationMs': durationMs,
    'downloadedAt': downloadedAt,
    'sourcePath': sourcePath,
    'quality': quality,
    'coverUrl': coverUrl,
    'lyricsRaw': lyricsRaw,
  };
}

const _downloadedSongsKey = 'downloadedSongMetadataV1';
Future<void> _downloadedSongsWriteQueue = Future<void>.value();

Future<List<DownloadedSongSnapshot>> loadDownloadedSongSnapshots() async {
  try {
    await _downloadedSongsWriteQueue;
  } catch (_) {}
  final preferences = await SharedPreferences.getInstance();
  final raw = preferences.getString(_downloadedSongsKey);
  // 返回可修改的空列表：调用方会对结果 sort，const [] 会抛
  // "Cannot modify an unmodifiable list"。
  if (raw == null || raw.trim().isEmpty) return <DownloadedSongSnapshot>[];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return <DownloadedSongSnapshot>[];
    return decoded.values
        .whereType<Map>()
        .map(
          (value) =>
              DownloadedSongSnapshot.fromJson(Map<String, dynamic>.from(value)),
        )
        .where((snapshot) => snapshot.path.isNotEmpty)
        .toList();
  } catch (_) {
    return <DownloadedSongSnapshot>[];
  }
}

Future<void> rememberDownloadedSongSnapshot(DownloadedSongSnapshot snapshot) {
  final operation = _downloadedSongsWriteQueue.then((_) async {
    final preferences = await SharedPreferences.getInstance();
    final current = <String, dynamic>{};
    try {
      final raw = preferences.getString(_downloadedSongsKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map) current.addAll(Map<String, dynamic>.from(decoded));
    } catch (_) {}
    current[snapshot.path] = snapshot.toJson();
    await preferences.setString(_downloadedSongsKey, jsonEncode(current));
  });
  _downloadedSongsWriteQueue = operation.catchError((_) {});
  return operation;
}

Future<String> resolveMusicDownloadDirectory(AppSettings? settings) async {
  final configured = settings?.downloadPath.trim() ?? '';
  if (configured.isNotEmpty) return configured;
  Directory? base;
  try {
    base = await getDownloadsDirectory();
  } catch (_) {}
  try {
    base ??= await getExternalStorageDirectory();
  } catch (_) {}
  base ??= await getApplicationDocumentsDirectory();
  return p.join(base.path, 'XY Music');
}

/// Writable staging directory used before copying a download to an Android
/// SAF tree URI selected by the user.
Future<String> resolveDownloadStagingDirectory() async {
  final base = await getApplicationSupportDirectory();
  final directory = Directory(p.join(base.path, 'download_staging'));
  await directory.create(recursive: true);
  return directory.path;
}
