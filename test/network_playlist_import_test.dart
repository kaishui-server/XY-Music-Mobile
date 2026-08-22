import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xy_music/src/playlists/network_playlist_import.dart';

void main() {
  test('网易云歌单 ID 可导入为可播放的 LX 歌曲快照', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'music.163.com');
      expect(request.url.queryParameters['id'], '3778678');
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'code': 200,
            'playlist': {
              'name': '热歌榜',
              'coverImgUrl': 'http://music.126.net/cover.jpg',
              'trackIds': [
                {'id': 123},
              ],
              'tracks': [
                {
                  'id': 123,
                  'name': '测试歌曲',
                  'dt': 215000,
                  'ar': [
                    {'name': '测试歌手'},
                  ],
                  'al': {
                    'id': 456,
                    'name': '测试专辑',
                    'picUrl': 'http://music.126.net/song.jpg',
                  },
                },
              ],
            },
          }),
        ),
        200,
      );
    });
    final service = NetworkPlaylistImportService(client: client);

    final result = await service.importPlaylist('wy', '3778678');

    expect(result.name, '热歌榜');
    expect(result.coverUrl, 'https://music.126.net/cover.jpg');
    expect(result.songs.single.path, 'lx://wy/123');
    expect(result.songs.single.duration, 215);
    expect(result.songs.single.pluginId, isNull);
    expect(result.songs.single.pluginData?['lx']['source'], 'wy');
    expect(result.songs.single.pluginData?['lx']['songmid'], '123');
  });

  test('QQ音乐歌单分享链接可提取 ID 并保存解析播放所需字段', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'c.y.qq.com');
      expect(request.url.queryParameters['disstid'], '7011264340');
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'code': 0,
            'cdlist': [
              {
                'dissname': '电子歌单',
                'logo': 'https://example.com/list.jpg',
                'songlist': [
                  {
                    'id': 100,
                    'mid': 'song-mid',
                    'title': '测试 QQ 歌曲',
                    'interval': 180,
                    'singer': [
                      {'name': 'QQ歌手'},
                    ],
                    'album': {'id': 200, 'mid': 'album-mid', 'name': 'QQ专辑'},
                    'file': {'media_mid': 'media-mid'},
                  },
                ],
              },
            ],
          }),
        ),
        200,
      );
    });
    final service = NetworkPlaylistImportService(client: client);

    final result = await service.importPlaylist(
      'wy',
      'https://y.qq.com/n/ryqq/playlist/7011264340',
    );

    final song = result.songs.single;
    expect(result.name, '电子歌单');
    expect(song.path, 'lx://tx/song-mid');
    expect(song.coverUrl, contains('album-mid'));
    expect(song.pluginData?['lx']['strMediaMid'], 'media-mid');
    expect(song.pluginData?['lx']['albumMid'], 'album-mid');
  });
}
