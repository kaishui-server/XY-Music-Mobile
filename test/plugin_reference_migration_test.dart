import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xy_music/src/plugins/plugin_reference_migration.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('空重命名表与自映射不产生任何改写', () async {
    SharedPreferences.setMockInitialValues({
      'mobilePlaylistsV1': jsonEncode([
        {
          'id': 'p1',
          'name': '歌单',
          'songPaths': ['plugin://plugin-188b76fb/abc'],
        },
      ]),
    });
    final prefs = await SharedPreferences.getInstance();
    final before = prefs.getString('mobilePlaylistsV1');
    expect(await migratePluginReferences({}), 0);
    expect(await migratePluginReferences({'a': 'a'}), 0);
    expect(prefs.getString('mobilePlaylistsV1'), before);
  });

  test('歌单内全部旧 ID 引用迁移到新 ID（含中文新 ID 的 URL 编码路径）', () async {
    const oldId = 'plugin-188b76fb';
    const newId = '酷狗音乐-赞助版-永久';
    final oldPath = 'plugin://$oldId/abc123';
    final newPath = 'plugin://${Uri.encodeComponent(newId)}/abc123';
    SharedPreferences.setMockInitialValues({
      'mobilePlaylistsV1': jsonEncode([
        {
          'id': 'p1',
          'name': '我的歌单',
          'songPaths': [oldPath, 'plugin://other-plugin/x'],
          'songSnapshots': {
            oldPath: {
              'path': oldPath,
              'title': '歌',
              'artist': '手',
              'album': '辑',
              'duration': 100,
              'format': '网络',
              'pluginId': oldId,
              'pluginData': {'id': 'abc123'},
            },
          },
          'customOrder': [oldPath],
          'importSources': [
            {'kind': 'plugin', 'pluginId': oldId, 'input': '3730280449'},
          ],
          'songSources': {
            oldPath: ['plugin:$oldId', 'lx:$oldId', 'plugin:other-plugin'],
          },
        },
      ]),
    });
    final changed = await migratePluginReferences({oldId: newId});
    expect(changed, greaterThan(0));
    final prefs = await SharedPreferences.getInstance();
    final playlists =
        (jsonDecode(prefs.getString('mobilePlaylistsV1')!) as List)
            .cast<Map<String, dynamic>>();
    final playlist = playlists.single;
    expect(playlist['songPaths'], [newPath, 'plugin://other-plugin/x']);
    expect(playlist['customOrder'], [newPath]);
    final snapshots = playlist['songSnapshots'] as Map<String, dynamic>;
    expect(snapshots.containsKey(newPath), isTrue);
    expect(snapshots.containsKey(oldPath), isFalse);
    final snapshot = snapshots[newPath] as Map<String, dynamic>;
    expect(snapshot['path'], newPath);
    expect(snapshot['pluginId'], newId);
    expect(snapshot['pluginData'], {'id': 'abc123'});
    final sources = playlist['importSources'] as List;
    expect((sources.single as Map)['pluginId'], newId);
    final songSources = playlist['songSources'] as Map<String, dynamic>;
    expect(songSources.containsKey(newPath), isTrue);
    expect(songSources[newPath], [
      'plugin:$newId',
      'lx:$newId',
      'plugin:other-plugin',
    ]);
  });

  test('收藏路径与快照迁移', () async {
    const oldId = 'plugin-188b76fb';
    const newId = 'kw-new';
    const oldPath = 'plugin://$oldId/song1';
    const newPath = 'plugin://$newId/song1';
    SharedPreferences.setMockInitialValues({
      'favoritePaths': [oldPath, 'plugin://other/song2'],
      'favoriteCustomOrderV1': [oldPath],
      'favoriteSongMetadataV1': jsonEncode({
        oldPath: {
          'path': oldPath,
          'title': 't',
          'artist': 'a',
          'album': 'b',
          'duration': 10,
          'format': '插件',
          'pluginId': oldId,
        },
      }),
    });
    expect(await migratePluginReferences({oldId: newId}), greaterThan(0));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('favoritePaths'), [
      newPath,
      'plugin://other/song2',
    ]);
    expect(prefs.getStringList('favoriteCustomOrderV1'), [newPath]);
    final metadata =
        jsonDecode(prefs.getString('favoriteSongMetadataV1')!) as Map;
    expect(metadata.containsKey(newPath), isTrue);
    expect((metadata[newPath] as Map)['pluginId'], newId);
  });

  test('最近播放快照只迁移 pluginId，path 保持与 SQLite 历史对齐', () async {
    const oldId = 'plugin-188b76fb';
    const newId = 'kg-new';
    const oldPath = 'plugin://$oldId/song9';
    SharedPreferences.setMockInitialValues({
      'recentSongMetadataV1': jsonEncode({
        oldPath: {
          'path': oldPath,
          'title': 't',
          'artist': 'a',
          'album': 'b',
          'durationMs': 1000,
          'playedAt': 1,
          'pluginId': oldId,
        },
      }),
    });
    expect(await migratePluginReferences({oldId: newId}), greaterThan(0));
    final prefs = await SharedPreferences.getInstance();
    final snapshots =
        jsonDecode(prefs.getString('recentSongMetadataV1')!) as Map;
    // path（以及映射键）不能变：SQLite 播放历史按 path 反查快照。
    expect(snapshots.containsKey(oldPath), isTrue);
    final snapshot = snapshots[oldPath] as Map<String, dynamic>;
    expect(snapshot['path'], oldPath);
    expect(snapshot['pluginId'], newId);
  });
}
