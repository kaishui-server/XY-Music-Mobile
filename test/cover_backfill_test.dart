import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xy_music/src/favorites/favorites_provider.dart';
import 'package:xy_music/src/playlists/playlists_provider.dart';
import 'package:xy_music/src/recent/recent_store.dart';

/// Bug7 回归：播放时现场补拉的封面必须回写收藏/歌单/最近播放快照，
/// 否则导出备份迁移到其他设备后，这些歌曲的封面与手机上实际显示的
/// 不是同一张（另一端只能走 pluginData 兜底或占位图）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const path = 'plugin://wy/100';
  const backfilledCover = 'https://example.com/backfilled.jpg';

  test('最近播放快照：空封面回填，已有封面不覆盖，未知歌曲无操作', () async {
    SharedPreferences.setMockInitialValues({
      'recentSongMetadataV1': jsonEncode({
        path: {
          'path': path,
          'title': '歌',
          'artist': '歌手',
          'album': '专辑',
          'durationMs': 200000,
          'playedAt': 1700000000000,
          'pluginId': 'wy',
          'coverUrl': null,
        },
        'plugin://wy/999': {
          'path': 'plugin://wy/999',
          'title': '已有封面',
          'artist': '歌手',
          'album': '专辑',
          'durationMs': 100000,
          'playedAt': 1700000000000,
          'pluginId': 'wy',
          'coverUrl': 'https://example.com/old.jpg',
        },
      }),
    });

    await backfillRecentSongCover(path, backfilledCover);
    await backfillRecentSongCover('plugin://wy/999', backfilledCover);
    await backfillRecentSongCover('plugin://wy/404', backfilledCover);
    await backfillRecentSongCover(path, '   ');

    final snapshots = await loadRecentSongSnapshots();
    expect(snapshots[path]!.coverUrl, backfilledCover);
    expect(snapshots['plugin://wy/999']!.coverUrl, 'https://example.com/old.jpg');
    expect(snapshots.containsKey('plugin://wy/404'), isFalse);

    final raw = jsonDecode(
      (await SharedPreferences.getInstance()).getString('recentSongMetadataV1')!,
    ) as Map;
    expect(raw[path]['coverUrl'], backfilledCover);
  });

  test('收藏快照：空封面回填且持久化，已有封面不覆盖', () async {
    SharedPreferences.setMockInitialValues({
      'favoritePaths': <String>[path, 'plugin://wy/888'],
      'favoriteSongMetadataV1': jsonEncode({
        path: {
          'path': path,
          'title': '收藏的歌',
          'artist': '歌手',
          'album': '专辑',
          'duration': 200,
          'format': '网络',
          'coverUrl': null,
          'pluginId': 'wy',
        },
        'plugin://wy/888': {
          'path': 'plugin://wy/888',
          'title': '已有封面的收藏',
          'artist': '歌手',
          'album': '专辑',
          'duration': 100,
          'format': '网络',
          'coverUrl': 'https://example.com/old.jpg',
          'pluginId': 'wy',
        },
      }),
    });

    final notifier = FavoritesNotifier();
    await notifier.ready;
    await notifier.backfillCover(path, backfilledCover);
    await notifier.backfillCover('plugin://wy/888', backfilledCover);
    await notifier.backfillCover('plugin://wy/404', backfilledCover);

    expect(notifier.snapshotFor(path)!.coverUrl, backfilledCover);
    expect(
      notifier.snapshotFor('plugin://wy/888')!.coverUrl,
      'https://example.com/old.jpg',
    );
    final raw = jsonDecode(
      (await SharedPreferences.getInstance())
          .getString('favoriteSongMetadataV1')!,
    ) as Map;
    expect(raw[path]['coverUrl'], backfilledCover);
    expect(raw['plugin://wy/888']['coverUrl'], 'https://example.com/old.jpg');
  });

  test('歌单快照：多个歌单包含同一首歌时全部回填', () async {
    SharedPreferences.setMockInitialValues({
      'mobilePlaylistsV1': jsonEncode([
        {
          'id': 'list-1',
          'name': '歌单一',
          'songPaths': [path],
          'createdAt': '2026-09-01T10:00:00.000',
          'songSnapshots': {
            path: {
              'path': path,
              'title': '歌',
              'artist': '歌手',
              'album': '专辑',
              'duration': 200,
              'format': '网络',
              'pluginId': 'wy',
            },
          },
        },
        {
          'id': 'list-2',
          'name': '歌单二（含同一首）',
          'songPaths': [path],
          'createdAt': '2026-09-02T10:00:00.000',
          'songSnapshots': {
            path: {
              'path': path,
              'title': '歌',
              'artist': '歌手',
              'album': '专辑',
              'duration': 200,
              'format': '网络',
              'coverUrl': 'https://example.com/keep.jpg',
              'pluginId': 'wy',
            },
          },
        },
        {
          'id': 'list-3',
          'name': '歌单三（不含该歌）',
          'songPaths': ['plugin://wy/777'],
          'createdAt': '2026-09-03T10:00:00.000',
          'songSnapshots': {
            'plugin://wy/777': {
              'path': 'plugin://wy/777',
              'title': '别的歌',
              'artist': '歌手',
              'album': '专辑',
              'duration': 100,
              'format': '网络',
              'pluginId': 'wy',
            },
          },
        },
      ]),
    });

    final notifier = PlaylistsNotifier();
    await notifier.ready;
    await notifier.backfillSongCover(path, backfilledCover);

    final byId = {for (final item in notifier.items) item.id: item};
    expect(byId['list-1']!.songSnapshots[path]!.coverUrl, backfilledCover);
    // 已有封面保持不变，不覆盖。
    expect(
      byId['list-2']!.songSnapshots[path]!.coverUrl,
      'https://example.com/keep.jpg',
    );
    expect(byId['list-3']!.songSnapshots.containsKey(path), isFalse);

    final raw = jsonDecode(
      (await SharedPreferences.getInstance()).getString('mobilePlaylistsV1')!,
    ) as List;
    final savedList1 = raw.firstWhere((e) => e['id'] == 'list-1');
    expect(savedList1['songSnapshots'][path]['coverUrl'], backfilledCover);
  });
}
