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

  test('BakaMusic tx 歌曲优先用 songmid 构造 lx 路径', () {
    // BakaMusic 的 QQ 歌同时有数字 songId（id 字段）与字符串 songmid，
    // 洛雪 tx 源必须用 songmid 播放；songId/albummid（小写）保留进 lx。
    final plugin = const EnabledMusicPlugin(
      id: 'lx-linglan',
      name: '聆澜音源(赞助版)[永久]',
      path: '/plugins/lx-linglan.js',
      isLx: true,
      lxSources: ['kw', 'kg', 'tx', 'wy', 'mg'],
    );
    final result = parseMusicFreeBackup(
      jsonEncode({
        'schema': 'bakamusic.music-sheet-backup',
        'version': 3,
        'data': {
          'musicSheets': [
            {
              'id': 'fav',
              'title': '我喜欢',
              'musicList': [
                {
                  'id': 575785845,
                  'songmid': '0006A93H2qAQu2',
                  'title': '恋落花',
                  'singer': '陈语淇',
                  'albumName': '恋落花',
                  'albumid': 66615606,
                  'albummid': '001uSLEI3v9rnZ',
                  'duration': 180,
                  'platform': 'QQ音乐',
                  'qualities': {
                    '128k': {'size': 2887874},
                    '320k': {'size': 7218953},
                  },
                },
              ],
            },
          ],
        },
      }),
      plugins: [plugin],
    );

    final song = result.playlists.single.songs.single;
    expect(song.path, 'lx://tx/0006A93H2qAQu2');
    final lx = song.pluginData!['lx'] as Map<String, dynamic>;
    expect(lx['songmid'], '0006A93H2qAQu2');
    expect(lx['source'], 'tx');
    expect(lx['songId'], 575785845);
    expect(lx['albumId'], 66615606);
    expect(lx['albumMid'], '001uSLEI3v9rnZ');
    expect(lx['interval'], '03:00');
    expect(lx['_interval'], 180000);
    expect((lx['_types'] as Map).containsKey('320k'), isTrue);
  });

  test('酷狗歌曲无 hash 字段时回退 id 并构建音质表', () {
    // mf 原版导出的酷狗歌把 hash 放在 id 字段，lx.hash 需回退 id，
    // interval 格式化为 "MM:SS"、qualities 转成 _types。
    final plugin = const EnabledMusicPlugin(
      id: 'lx',
      name: '落雪音源',
      path: '/plugins/lx.js',
      isLx: true,
      lxSources: ['kg'],
    );
    final result = parseMusicFreeBackup(
      jsonEncode({
        'musicSheets': [
          {
            'title': '我喜欢',
            'musicList': [
              {
                'id': '2D44700BFB234137DEF21A00DC0DC076',
                'title': '五百年沧海桑田',
                'artist': '星火社',
                'album': '五百年沧海桑田',
                'duration': 216,
                'platform': '酷狗音乐(赞助版)[永久]',
                'qualities': {
                  '128k': {'hash': '2D44700BFB234137DEF21A00DC0DC076'},
                  'flac': {'hash': '1C8D85FD26D4E01D44F2912EEF05C4D3'},
                },
              },
            ],
          },
        ],
      }),
      plugins: [plugin],
    );

    final song = result.playlists.single.songs.single;
    expect(song.path, 'lx://kg/2D44700BFB234137DEF21A00DC0DC076');
    final lx = song.pluginData!['lx'] as Map<String, dynamic>;
    expect(lx['hash'], '2D44700BFB234137DEF21A00DC0DC076');
    expect(lx['interval'], '03:36');
    expect(lx['_interval'], 216000);
    expect((lx['_types'] as Map).containsKey('flac'), isTrue);
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
