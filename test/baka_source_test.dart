import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xy_music/src/plugins/plugin_comments.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';

/// 惜梦 baka 版（BakaMusic 契约，animemusic.bzxhkj.com/baka 分发）全链路：
/// 插件脚本的 FALLBACK_BASE 指向站点根，部署上没有 API 路由（只有 HTML
/// 数据面板），插件自身 search/getMediaSource/getLyric 全部静默失败，
/// 由宿主按 animemusicApi 直连后端 /v1/index.php 兜底：
/// 搜索兜底 → 播放兜底 → 歌词 → 评论 → MV → 歌手搜索 → 歌手热门歌曲
/// → 专辑搜索 → 专辑歌曲。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bakaFile = File(
    '${Directory.current.path}${Platform.pathSeparator}..'
    '${Platform.pathSeparator}_test${Platform.pathSeparator}baka_dispatch.js',
  );
  final bakaAvailable = bakaFile.existsSync();

  test('baka 版：宿主直连兜底全链路', () async {
    final directory = await Directory.systemTemp.createTemp('xy-baka-');
    final pluginFile = File(
      '${directory.path}${Platform.pathSeparator}baka.js',
    );
    await pluginFile.writeAsString(await bakaFile.readAsString());
    final plugin = EnabledMusicPlugin(
      id: 'baka',
      name: 'animemusic',
      path: pluginFile.path,
      // 与 loadEnabledMusicPlugins 提取结果一致：FALLBACK_BASE（站点根）
      // + /v1/index.php。
      animemusicApi: 'https://animemusic.bzxhkj.com/v1/index.php',
      animemusicPlatform: 'wy',
    );

    final jsonHeaders = {'content-type': 'application/json; charset=utf-8'};
    final client = MockClient((request) async {
      final url = request.url.toString();
      // 站点根（插件自身调用，FALLBACK_BASE 兜底）：真实部署只有 HTML
      // 数据面板，code !== 200 → 脚本静默失败。
      if (url.startsWith('https://animemusic.bzxhkj.com/') &&
          !url.contains('/v1/')) {
        return http.Response(
          '<!DOCTYPE html><html><body>animemusic 数据面板</body></html>',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      }
      // 宿主直连后端（PATH_INFO 风格 /v1/music/* 或 query 风格
      // route=music%2F*）。按路由名分流。
      bool isRoute(String name) => url.contains('/v1/music/$name') ||
          url.contains('route=music%2F$name');
      if (isRoute('search')) {
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
          headers: jsonHeaders,
        );
      }
      if (isRoute('url')) {
        return http.Response(
          jsonEncode({
            'code': 200,
            'url': 'https://stream.example.com/3402858225.mp3',
          }),
          200,
          headers: jsonHeaders,
        );
      }
      if (isRoute('lyric/word')) {
        return http.Response(
          jsonEncode({
            'code': 200,
            'lyric': '[1000,1200](1000,400,0)逐(1400,400,0)字',
          }),
          200,
          headers: jsonHeaders,
        );
      }
      if (isRoute('lyric')) {
        return http.Response(
          jsonEncode({'code': 200, 'lyric': '[00:01.00]行级歌词'}),
          200,
          headers: jsonHeaders,
        );
      }
      if (isRoute('comment')) {
        return http.Response(
          jsonEncode({
            'code': 200,
            'hot': [
              {
                'commentId': 1,
                'user': {'nickname': '热评用户', 'avatarUrl': ''},
                'content': '热评内容',
                'likedCount': 10,
                'time': 1700000000000,
              },
            ],
            'list': [
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
          headers: jsonHeaders,
        );
      }
      if (isRoute('suggest')) {
        return http.Response(
          jsonEncode({
            'code': 200,
            'songs': [
              {'id': '5257138', 'title': '屋顶', 'artist': '周杰伦/温岚'},
            ],
            'singers': [
              {
                'id': '6452',
                'name': '周杰伦',
                'artwork':
                    'https://p2.music.126.net/_ECPuM0s0qtWhkpQOSTZUg==/109951169164936940.jpg',
              },
            ],
            'albums': [
              {'id': '21330', 'name': 'J-Top冠军精选', 'artist': '蔡依林'},
            ],
          }),
          200,
          headers: jsonHeaders,
        );
      }
      if (isRoute('artist')) {
        return http.Response(
          jsonEncode({
            'code': 200,
            'name': '周杰伦',
            'avatar': 'https://p2.music.126.net/avatar.jpg',
            'list': [
              {
                'id': '185709',
                'title': '稻香',
                'artist': '周杰伦',
                'album': '魔杰座',
                'duration': 223,
                'artwork': 'https://p2.music.126.net/daoxiang.jpg',
              },
            ],
          }),
          200,
          headers: jsonHeaders,
        );
      }
      if (isRoute('album')) {
        return http.Response(
          jsonEncode({
            'code': 200,
            'list': [
              {
                'id': '185709',
                'title': '稻香',
                'artist': '周杰伦',
                'album': '魔杰座',
                'duration': 223,
                'artwork': 'https://p2.music.126.net/daoxiang.jpg',
              },
            ],
          }),
          200,
          headers: jsonHeaders,
        );
      }
      if (isRoute('mv/search')) {
        return http.Response(
          jsonEncode({
            'code': 200,
            'data': [
              {'id': '54321', 'title': '青玉恋', 'artist': '刘宇'},
            ],
          }),
          200,
          headers: jsonHeaders,
        );
      }
      if (isRoute('mv/url')) {
        return http.Response(
          jsonEncode({
            'code': 200,
            'url': 'https://mv.example.com/54321.mp4',
          }),
          200,
          headers: jsonHeaders,
        );
      }
      // wy 平台直连歌词（_src:'wy' 的歌曲走 _getPlatformLyricsFallback）。
      if (url.contains('interface.music.163.com/weapi/song/lyric')) {
        return http.Response(
          jsonEncode({
            'code': 200,
            'lrc': {'lyric': '[00:01.00]行级歌词'},
            'yrc': {
              'lyric': '[1000,1200](1000,400,0)逐(1400,400,0)字',
            },
            'tlyric': {'lyric': '[00:01.00]translation'},
          }),
          200,
          headers: jsonHeaders,
        );
      }
      // wy 平台直连评论（detectCommentPlatform 识别 _src:'wy'）。
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
          headers: jsonHeaders,
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

    // 1. 搜索：插件自身（站点根 HTML）静默失败返回空 → 宿主 music/search
    //    兜底；歌曲带 _src 来源标记，注入 mv 标识让 MV 按钮显示。
    final songs = await service.search(plugin, '青玉恋');
    // ignore: avoid_print
    print('search results: ${songs.length}');
    expect(songs, isNotEmpty);
    final first = songs.first;
    // ignore: avoid_print
    print('first song raw: ${first.rawData}');
    expect(first.rawData['_src'], 'wy');
    expect(first.rawData['mv'], isNotNull);

    // 2. 歌词：插件 getLyric 失败（null）→ wy 平台直连逐字歌词。
    final lyrics = await service.getLyrics(plugin, first.rawData);
    // ignore: avoid_print
    print(
      'lyrics: ${lyrics.isEmpty ? "(empty)" : lyrics.substring(0, lyrics.length > 80 ? 80 : lyrics.length)}',
    );
    expect(lyrics, isNotEmpty);

    // 3. 评论：插件未声明 getMusicComments → _src:'wy' → wy 平台直连。
    final comments = await fetchSongComments(
      plugin: plugin,
      pluginData: first.rawData,
      runtime: service,
    );
    // ignore: avoid_print
    print('comments: ${comments?.items.length}');
    expect(comments?.items, isNotEmpty);

    // 4. 播放：插件 getMediaSource 失败（null）→ 宿主 music/url 兜底。
    final media = await service.resolveMediaSource(plugin, first.rawData);
    // ignore: avoid_print
    print('media url: ${media.url}');
    expect(media.url, isNotEmpty);

    // 5. MV：animemusicApi 非空 → 宿主 music/mv/search + music/mv/url。
    final mv = await service.resolveMvSource(plugin, first.rawData);
    // ignore: avoid_print
    print('mv url: ${mv.url}');
    expect(mv.url, isNotEmpty);

    // 6. 歌手搜索：宿主 music/suggest singers 分组，条目带 animeSrc+id。
    final artists = await service.searchArtists(plugin, '周杰伦');
    // ignore: avoid_print
    print('artists: ${artists.map((a) => a.title)}');
    expect(artists, isNotEmpty);
    final artist = artists.first;
    expect(artist.rawData['animeSrc'], 'wy');
    expect(artist.rawData['id'], '6452');

    // 7. 歌手热门歌曲：宿主 music/artist。
    final artistSongs = await service.getArtistSongs(plugin, artist);
    // ignore: avoid_print
    print('artist songs: ${artistSongs.map((s) => s.title)}');
    expect(artistSongs, isNotEmpty);

    // 8. 专辑搜索：宿主 music/suggest albums 分组。
    final albums = await service.searchAlbums(plugin, '周杰伦');
    // ignore: avoid_print
    print('albums: ${albums.map((a) => a.title)}');
    expect(albums, isNotEmpty);
    final album = albums.first;
    expect(album.rawData['animeSrc'], 'wy');

    // 9. 专辑歌曲：宿主 music/album。
    final albumSongs = await service.getAlbumSongs(plugin, album);
    // ignore: avoid_print
    print('album songs: ${albumSongs.map((s) => s.title)}');
    expect(albumSongs, isNotEmpty);
  }, skip: bakaAvailable ? false : '本机无 baka 脚本样本，跳过');
}
