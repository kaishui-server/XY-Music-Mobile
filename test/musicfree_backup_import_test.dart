import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/library/library_provider.dart';
import 'package:xy_music/src/playlists/musicfree_backup_import.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';

void main() {
  test('导入 MusicFree 备份中的本地歌单', () {
    final local = const Song(
      path: '/storage/emulated/0/Music/test.mp3',
      title: '测试歌曲',
      artist: '测试歌手',
      album: '专辑',
      albumKey: '专辑-测试歌手',
      duration: 180,
      format: '本地',
    );
    final result = parseMusicFreeBackup(
      jsonEncode({
        'version': 1,
        'musicSheets': [
          {
            'title': '我的歌单',
            'musicList': [
              {
                'name': '测试歌曲',
                'singer': '测试歌手',
                'localPath': '/storage/emulated/0/Music/test.mp3',
                'duration': 180000,
              },
            ],
          },
        ],
      }),
      plugins: const [],
      localSongs: [local],
    );

    expect(result.playlists.single.name, '我的歌单');
    expect(result.importedSongs, 1);
    expect(result.playlists.single.songs.single.path, local.path);
    expect(result.playlists.single.songs.single.format, '本地');
  });

  test('按平台匹配 MusicFree 插件并保留原始歌曲 ID', () {
    final plugin = const EnabledMusicPlugin(
      id: 'netease-mf',
      name: '网易云 MusicFree',
      path: '/plugins/netease-mf.js',
    );
    final result = parseMusicFreeBackup(
      jsonEncode({
        'musicSheets': [
          {
            'name': '在线歌单',
            'musicList': [
              {
                'name': '在线歌曲',
                'singer': '歌手',
                'albumName': '专辑',
                'musicId': 12345,
                'platform': '网易云音乐',
                'duration': 215000,
              },
            ],
          },
        ],
      }),
      plugins: [plugin],
    );

    final song = result.playlists.single.songs.single;
    expect(song.pluginId, plugin.id);
    expect(song.path, 'plugin://netease-mf/12345');
    expect(song.pluginData?['id'], 12345);
    expect(song.duration, 215);
  });

  test('按 LX 来源构造可恢复播放的 lx 歌曲', () {
    final plugin = const EnabledMusicPlugin(
      id: 'lx',
      name: '落雪音源',
      path: '/plugins/lx.js',
      isLx: true,
      lxSources: ['wy'],
    );
    final result = parseMusicFreeBackup(
      jsonEncode({
        'data': {
          'musicSheets': [
            {
              'title': 'LX 歌单',
              'musicList': [
                {'title': '歌曲', 'artist': '歌手', 'id': '9988', 'platform': 'wy'},
              ],
            },
          ],
        },
      }),
      plugins: [plugin],
    );

    final song = result.playlists.single.songs.single;
    expect(song.path, 'lx://wy/9988');
    expect(song.pluginData?['lx']['source'], 'wy');
    expect(song.pluginData?['lx']['songmid'], '9988');
  });

  test('统计没有匹配插件的在线歌曲', () {
    final result = parseMusicFreeBackup(
      jsonEncode({
        'musicSheets': [
          {
            'title': '混合歌单',
            'musicList': [
              {'name': '可导入歌曲', 'singer': '歌手', 'localPath': '/music/song.mp3'},
              {'name': '缺少插件歌曲', 'singer': '歌手', 'id': 2, 'platform': '酷狗音乐'},
            ],
          },
        ],
      }),
      plugins: const [],
    );

    expect(result.importedSongs, 1);
    expect(result.skippedSongs, 1);
    expect(result.unmatchedPluginSongs, 1);
    expect(result.missingPluginSources, ['酷狗音乐']);
  });

  test('全部在线歌曲缺少插件时仍返回导入结果供界面提示', () {
    final result = parseMusicFreeBackup(
      jsonEncode({
        'musicSheets': [
          {
            'title': '缺失插件歌单',
            'musicList': [
              {'name': '歌曲', 'platform': 'QQ音乐', 'id': 1},
            ],
          },
        ],
      }),
      plugins: const [],
    );

    expect(result.importedSongs, 0);
    expect(result.unmatchedPluginSongs, 1);
    expect(result.missingPluginSources, ['QQ音乐']);
  });
}
