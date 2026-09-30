import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xy_music/src/backup/backup_service.dart';
import 'package:xy_music/src/favorites/favorites_provider.dart';
import 'package:xy_music/src/playlists/playlists_provider.dart';

/// Bug7 回归：未下载（网络）歌曲在备份导出 → 恢复的完整链路中，
/// 歌单/收藏快照必须全部存活，恢复后无需重新下载即可显示与播放。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final playlistJson = jsonEncode([
    {
      'id': 'list-1',
      'name': '网络歌单',
      'songPaths': ['plugin://wy/100'],
      'createdAt': '2026-09-01T10:00:00.000',
      'coverUrl': 'https://example.com/cover.jpg',
      'songSnapshots': {
        'plugin://wy/100': {
          'path': 'plugin://wy/100',
          'title': '未下载的歌',
          'artist': '歌手',
          'album': '专辑',
          'duration': 200,
          'format': '网络',
          'coverUrl': 'https://example.com/cover.jpg',
          'pluginId': 'wy',
          'pluginData': {'id': 100},
          'lyricsRaw': '[00:00.00]歌词',
        },
      },
    },
  ]);
  final favoriteMetadataJson = jsonEncode({
    'plugin://wy/200': {
      'path': 'plugin://wy/200',
      'title': '收藏的网络歌',
      'artist': '歌手B',
      'album': '专辑B',
      'duration': 180,
      'format': '网络',
      'pluginId': 'wy',
      'pluginData': {'id': 200},
    },
  });
  final downloadedMetadataJson = jsonEncode({
    '/storage/emulated/0/Download/XY Music/本地歌.mp3': {
      'path': '/storage/emulated/0/Download/XY Music/本地歌.mp3',
      'title': '本地歌',
      'artist': '歌手C',
      'album': '专辑C',
      'durationMs': 210000,
      'downloadedAt': 1700000000000,
      'sourcePath': 'plugin://wy/300',
    },
  });

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            final temp = await Directory.systemTemp.createTemp('xy_backup');
            return temp.path;
          },
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });

  test('备份导出→恢复往返后网络歌曲快照完整存活', () async {
    // 1. 模拟导出设备：SharedPreferences 中已有含快照的歌单/收藏/下载记录。
    SharedPreferences.setMockInitialValues({
      'mobilePlaylistsV1': playlistJson,
      'favoritePaths': <String>['plugin://wy/200'],
      'favoriteSongMetadataV1': favoriteMetadataJson,
      'downloadedSongMetadataV1': downloadedMetadataJson,
    });
    final source = await SharedPreferences.getInstance();
    final prefsDump = <String, Map<String, Object>>{};
    for (final key in source.getKeys()) {
      final value = source.get(key);
      if (value is String) {
        prefsDump[key] = {'t': 's', 'v': value};
      } else if (value is List && value.every((e) => e is String)) {
        prefsDump[key] = {'t': 'sl', 'v': value};
      }
    }
    final backupFile = File(
      p.join(Directory.systemTemp.path, 'xy_backup_test_${DateTime.now().millisecondsSinceEpoch}.json'),
    );
    await backupFile.writeAsString(
      jsonEncode({
        'format': 'xymusic-backup',
        'version': 4,
        'exportedAt': '2026-09-29T00:00:00.000',
        'prefs': prefsDump,
        'plugins': <String, String>{},
        'library': <String, dynamic>{},
      }),
    );

    // 2. 模拟新设备：空 SharedPreferences，从备份文件恢复。
    SharedPreferences.setMockInitialValues({});
    final service = const BackupService();
    final data = await service.readBackup(backupFile.path);
    expect(data.prefCount, 4, reason: '四个含数据的键全部通过校验');
    await service.applyBackup(data);

    // 3. 恢复后的 prefs 中快照数据一字不差。
    final restored = await SharedPreferences.getInstance();
    expect(restored.getString('mobilePlaylistsV1'), playlistJson);
    expect(restored.getString('favoriteSongMetadataV1'), favoriteMetadataJson);
    expect(restored.getString('downloadedSongMetadataV1'), downloadedMetadataJson);
    expect(restored.getStringList('favoritePaths'), ['plugin://wy/200']);

    // 4. provider 重新加载后，未下载歌曲带完整元数据。
    final playlists = PlaylistsNotifier();
    await playlists.ready;
    final playlist = playlists.items.single;
    final song = playlist.songSnapshots['plugin://wy/100']!.toSong();
    expect(song.title, '未下载的歌');
    expect(song.pluginId, 'wy');
    expect(song.pluginData, {'id': 100});
    expect(song.lyricsRaw, '[00:00.00]歌词');

    final favorites = FavoritesNotifier();
    await favorites.ready;
    expect(favorites.paths, contains('plugin://wy/200'));
    final favorite = favorites.snapshotFor('plugin://wy/200')!.toSong();
    expect(favorite.title, '收藏的网络歌');
    expect(favorite.pluginId, 'wy');

    await backupFile.delete();
  });
}
