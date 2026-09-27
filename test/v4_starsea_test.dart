import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xy_music/src/plugins/plugin_comments.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';

/// 诊断 v4（animemusic 星海聚合 MusicFree 插件）：
/// 搜索 → 歌词 → 评论 全链路，定位「可播放但无歌词无评论」的失败点。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final v4File = File(
    '${Directory.current.path}${Platform.pathSeparator}..'
    '${Platform.pathSeparator}_test${Platform.pathSeparator}lx_v4.js',
  );
  final v4Available = v4File.existsSync();

  test('v4 星海聚合：搜索 / 歌词 / 评论全链路', () async {
    final directory = await Directory.systemTemp.createTemp('xy-v4-');
    final pluginFile = File(
      '${directory.path}${Platform.pathSeparator}v4.js',
    );
    await pluginFile.writeAsString(await v4File.readAsString());
    final plugin = EnabledMusicPlugin(
      id: 'v4',
      name: 'animemusic聚合',
      path: pluginFile.path,
      animemusicApi:
          'https://animemusic.bzxhkj.com/v1/index.php',
    );
    final client = MockClient((request) async {
      final url = request.url.toString();
      // 聚合搜索：每个平台各回一条 wy 歌曲。
      if (url.contains('/music/search')) {
        return http.Response(
          jsonEncode({
            'code': 200,
            'data': [
              {
                '_src': 'wy',
                'id': '3402858225',
                'songId': '3402858225',
                'title': '青玉恋',
                'artist': '刘宇',
                'album': '青玉恋',
                'artwork':
                    'https://p3.music.126.net/ln3--IR0Tt1AN3gBaEqMsA==/109951173520621868.jpg',
                'duration': 252,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      // wy weapi 逐字歌词。
      if (url.contains('interface.music.163.com/weapi/song/lyric')) {
        return http.Response(
          jsonEncode({
            'code': 200,
            'lrc': {'lyric': '[00:01.00]行级歌词'},
            'yrc': {
              'lyric':
                  '[1000,1200](1000,400,0)逐(1400,400,0)字',
            },
            'tlyric': {'lyric': '[00:01.00]translation'},
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      // wy 评论。
      if (url.contains('music.163.com/api/v1/resource/comments')) {
        return http.Response(
          jsonEncode({
            'code': 200,
            'hotComments': [
              {
                'commentId': 1,
                'user': {'nickname': '热评用户', 'avatarUrl': ''},
                'content': '热评内容',
                'likedCount': 10,
                'time': 1700000000000,
              },
            ],
            'comments': [
              {
                'commentId': 2,
                'user': {'nickname': '普通用户', 'avatarUrl': ''},
                'content': '最新评论',
                'likedCount': 1,
                'time': 1700000001000,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('not found', 404);
    });
    final service = PluginRuntimeService(httpClient: client);
    addTearDown(() async {
      service.dispose();
      client.close();
      await directory.delete(recursive: true);
    });

    final songs = await service.search(plugin, '青玉恋');
    // ignore: avoid_print
    print('search results: ${songs.length}');
    expect(songs, isNotEmpty);
    final first = songs.first;
    // ignore: avoid_print
    print('first song raw: ${first.rawData}');

    final lyrics = await service.getLyrics(plugin, first.rawData);
    // ignore: avoid_print
    print('lyrics: ${lyrics.isEmpty ? "(empty)" : lyrics.substring(0, lyrics.length > 80 ? 80 : lyrics.length)}');
    expect(lyrics, isNotEmpty);

    final comments = await fetchSongComments(
      plugin: plugin,
      pluginData: first.rawData,
      runtime: service,
    );
    // ignore: avoid_print
    print('comments: ${comments?.items.length}');
    expect(comments?.items, isNotEmpty);
  }, skip: v4Available ? false : '本机无 v4 脚本样本，跳过');
}
