import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Bilibili 歌手搜索将用户结果映射为歌手并支持 data.result', () async {
    final source = r'''
      module.exports = {
        platform: '哔哩哔哩',
        search: async (query, page, type) => ({
          data: {
            result: type === 'artist' ? [{
              mid: 12345,
              uname: query,
              upic: 'https://example.com/avatar.jpg',
              usign: 'B站用户简介',
              videos: 8,
            }] : [],
          },
        }),
      };
    ''';
    final service = PluginRuntimeService(
      httpClient: MockClient((_) async => http.Response('', 200)),
      pluginSources: {'bilibili': source},
    );
    addTearDown(() {
      service.dispose();
      service.httpClient?.close();
    });

    final result = await service.searchArtists(
      const EnabledMusicPlugin(id: 'bilibili', name: '哔哩哔哩', path: ''),
      '测试用户',
    );

    expect(result, hasLength(1));
    expect(result.single.id, '12345');
    expect(result.single.title, '测试用户');
    expect(result.single.subtitle, 'B站用户简介');
    expect(result.single.coverUrl, 'https://example.com/avatar.jpg');
  });

  test('MusicFree 插件可以异步搜索并返回标准歌曲', () async {
    final directory = await Directory.systemTemp.createTemp(
      'xymusic-plugin-runtime-',
    );
    final pluginFile = File(
      '${directory.path}${Platform.pathSeparator}test.js',
    );
    await pluginFile.writeAsString(r'''
      const CryptoJS = require('crypto-js');
      module.exports = {
        platform: 'Runtime Test',
        search: async (query) => ({
          isEnd: true,
          data: [{
            id: CryptoJS.MD5(query).toString(),
            title: query,
            artist: '测试歌手',
            album: '测试专辑',
            duration: 215,
          }],
        }),
        getMediaSource: async (item, quality) => ({
          url: 'https://example.com/' + item.id + '.mp3',
          lyric: '[00:01.00]' + item.title,
          quality,
        }),
      };
    ''');
    final service = PluginRuntimeService();
    addTearDown(() async {
      service.dispose();
      await directory.delete(recursive: true);
    });

    final result = await service.search(
      EnabledMusicPlugin(
        id: 'runtime-test',
        name: 'Runtime Test',
        path: pluginFile.path,
      ),
      'XY Music',
    );

    expect(result, hasLength(1));
    expect(result.single.title, 'XY Music');
    expect(result.single.artist, '测试歌手');
    expect(result.single.durationMs, 215000);

    final source = await service.resolveMediaSource(
      const EnabledMusicPlugin(
        id: 'runtime-test',
        name: 'Runtime Test',
        path: '',
      ),
      result.single.rawData,
    );
    expect(source.url, startsWith('https://example.com/'));
    expect(source.lyrics, '[00:01.00]XY Music');
  });

  test('插件同步计算不会阻塞 Flutter 主 isolate', () async {
    final directory = await Directory.systemTemp.createTemp(
      'xymusic-plugin-isolate-',
    );
    final pluginFile = File(
      '${directory.path}${Platform.pathSeparator}busy-search.js',
    );
    await pluginFile.writeAsString(r'''
      module.exports = {
        platform: 'Busy Search Test',
        search: async (query) => {
          const deadline = Date.now() + 350;
          while (Date.now() < deadline) {}
          return { data: [{ id: 'busy-1', title: query }] };
        },
      };
    ''');
    final service = PluginRuntimeService();
    addTearDown(() async {
      service.dispose();
      await directory.delete(recursive: true);
    });

    var mainIsolateTicks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 20),
      (_) => mainIsolateTicks++,
    );
    final result = await service.search(
      EnabledMusicPlugin(
        id: 'busy-search',
        name: 'Busy Search Test',
        path: pluginFile.path,
      ),
      '动画不能卡住',
    );
    timer.cancel();

    expect(result.single.title, '动画不能卡住');
    expect(
      mainIsolateTicks,
      greaterThanOrEqualTo(3),
      reason: '插件执行期间主 isolate 应继续处理动画帧和定时器',
    );
  });

  test('插件 HTTP 桥不会破坏包含引号和换行的 JSON', () async {
    final directory = await Directory.systemTemp.createTemp(
      'xymusic-plugin-http-runtime-',
    );
    final pluginFile = File(
      '${directory.path}${Platform.pathSeparator}escaped-json.js',
    );
    await pluginFile.writeAsString(r'''
      const axios = require('axios');
      module.exports = {
        platform: 'Escaped JSON Test',
        search: async (query) => {
          const response = await axios.get('https://plugin.test/search', {
            params: { query },
          });
          return { isEnd: true, data: response.data.items };
        },
      };
    ''');
    final responseBody = jsonEncode({
      'items': [
        {'id': 'escaped-1', 'title': '带“引号”与\\反斜杠\n第二行', 'artist': '测试歌手'},
      ],
    });
    final client = MockClient(
      (_) async => http.Response(encodePluginHttpBody(responseBody), 200),
    );
    final service = PluginRuntimeService(httpClient: client);
    addTearDown(() async {
      service.dispose();
      client.close();
      await directory.delete(recursive: true);
    });

    final result = await service.search(
      EnabledMusicPlugin(
        id: 'escaped-json',
        name: 'Escaped JSON Test',
        path: pluginFile.path,
      ),
      'B站',
    );

    expect(result, hasLength(1));
    expect(result.single.title, '带“引号”与\\反斜杠\n第二行');
  });

  test('QQ音乐插件搜索为空时使用 Web 接口返回可播放所需字段', () async {
    final directory = await Directory.systemTemp.createTemp(
      'xymusic-qq-fallback-',
    );
    final pluginFile = File('${directory.path}${Platform.pathSeparator}qq.js');
    await pluginFile.writeAsString(r'''
      module.exports = {
        platform: 'QQ音乐',
        search: async () => ({ isEnd: true, data: [] }),
      };
    ''');
    final client = MockClient((request) async {
      expect(request.url.host, 'c.y.qq.com');
      expect(request.url.queryParameters['w'], '周杰伦');
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            'song': {
              'list': [
                {
                  'songid': 97773,
                  'songmid': '0039MnYb0qxYhV',
                  'songname': '晴天',
                  'albumid': 8220,
                  'albummid': '000MkMni19ClKG',
                  'albumname': '叶惠美',
                  'interval': 269,
                  'size128': 4317292,
                  'size320': 10792943,
                  'sizeflac': 55397039,
                  'singer': [
                    {'id': 4558, 'mid': '0025NhlN2yWrP4', 'name': '周杰伦'},
                  ],
                },
              ],
            },
          },
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final service = PluginRuntimeService(httpClient: client);
    addTearDown(() async {
      service.dispose();
      client.close();
      await directory.delete(recursive: true);
    });

    final result = await service.search(
      EnabledMusicPlugin(id: 'qq-music', name: 'QQ音乐', path: pluginFile.path),
      '周杰伦',
    );

    expect(result, hasLength(1));
    expect(result.single.title, '晴天');
    expect(result.single.artist, '周杰伦');
    expect(result.single.album, '叶惠美');
    expect(result.single.durationMs, 269000);
    expect(result.single.rawData['songmid'], '0039MnYb0qxYhV');
    expect(result.single.rawData['qualities'], contains('320k'));
    expect(
      result.single.coverUrl,
      'https://y.gtimg.cn/music/photo_new/'
      'T002R800x800M000000MkMni19ClKG.jpg',
    );
  });

  test('网易云插件搜索结果缺少 picUrl 时批量补全封面和时长', () async {
    final directory = await Directory.systemTemp.createTemp(
      'xy-music-netease-cover-',
    );
    final pluginFile = File('${directory.path}${Platform.pathSeparator}wy.js');
    await pluginFile.writeAsString(r'''
      module.exports = {
        platform: '网易云音乐',
        search: async () => ({
          isEnd: true,
          data: [{
            id: 509781655,
            title: '想你就写信 (Live)',
            artist: '周杰伦',
            album: '中国新歌声第二季 第13期',
          }],
        }),
      };
    ''');
    final client = MockClient((request) async {
      expect(request.url.host, 'music.163.com');
      expect(request.url.path, '/api/song/detail/');
      expect(request.url.queryParameters['ids'], '[509781655]');
      return http.Response(
        jsonEncode({
          'code': 200,
          'songs': [
            {
              'id': 509781655,
              'duration': 238698,
              'album': {
                'picUrl':
                    'http://p2.music.126.net/cover-key/109951163038292176.jpg',
              },
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final service = PluginRuntimeService(httpClient: client);
    addTearDown(() async {
      service.dispose();
      client.close();
      await directory.delete(recursive: true);
    });

    final result = await service.search(
      EnabledMusicPlugin(id: 'wy', name: '网易云音乐', path: pluginFile.path),
      '周杰伦',
    );

    expect(result, hasLength(1));
    expect(
      result.single.coverUrl,
      'https://p2.music.126.net/cover-key/109951163038292176.jpg?param=800y800',
    );
    expect(result.single.durationMs, 238698);
    expect(result.single.rawData['artwork'], result.single.coverUrl);
  });

  test('网易云插件已有 HTTP 封面时升级为 Android 可加载的 HTTPS 地址', () async {
    final directory = await Directory.systemTemp.createTemp(
      'xy-music-netease-http-cover-',
    );
    final pluginFile = File('${directory.path}${Platform.pathSeparator}wy.js');
    await pluginFile.writeAsString(r'''
      module.exports = {
        platform: '网易云音乐',
        search: async () => ({
          data: [{
            songId: 509781655,
            title: '想你就写信 (Live)',
            artist: '周杰伦',
            duration: 238698,
            artwork: 'http://p2.music.126.net/cover-key/song.jpg',
          }],
        }),
      };
    ''');
    final client = MockClient((_) async {
      fail('已有封面和时长时不应请求歌曲详情接口');
    });
    final service = PluginRuntimeService(httpClient: client);
    addTearDown(() async {
      service.dispose();
      client.close();
      await directory.delete(recursive: true);
    });

    final result = await service.search(
      EnabledMusicPlugin(id: 'wy', name: '网易云音乐', path: pluginFile.path),
      '周杰伦',
    );

    expect(result.single.id, '509781655');
    expect(
      result.single.coverUrl,
      'https://p2.music.126.net/cover-key/song.jpg?param=800y800',
    );
    expect(result.single.rawData['artwork'], result.single.coverUrl);
  });

  test('网易云插件可从嵌套 rawData 的 picId_str 直接生成封面', () async {
    final directory = await Directory.systemTemp.createTemp(
      'xy-music-netease-pic-id-',
    );
    final pluginFile = File('${directory.path}${Platform.pathSeparator}wy.js');
    await pluginFile.writeAsString(r'''
      module.exports = {
        platform: '网易云音乐',
        search: async () => ({
          data: [{
            title: '测试歌曲',
            rawData: {
              id: '509781655',
              al: { picId_str: '109951163038292176' },
            },
          }],
        }),
      };
    ''');
    final client = MockClient((_) async {
      fail('完整 picId_str 应直接生成 CDN 地址，不应请求详情接口');
    });
    final service = PluginRuntimeService(httpClient: client);
    addTearDown(() async {
      service.dispose();
      client.close();
      await directory.delete(recursive: true);
    });

    final result = await service.search(
      EnabledMusicPlugin(id: 'wy', name: '网易云音乐', path: pluginFile.path),
      '测试',
    );

    expect(result.single.id, '509781655');
    expect(
      result.single.coverUrl,
      'https://p1.music.126.net/'
      'yD9vbpuILH-tqNRIaP640g==/109951163038292176.jpg?param=800y800',
    );
    expect(result.single.rawData['artwork'], result.single.coverUrl);
  });

  test('网易云插件可识别 musicInfo/detail 中的封面字段', () async {
    final directory = await Directory.systemTemp.createTemp(
      'xy-music-netease-nested-cover-',
    );
    final pluginFile = File('${directory.path}${Platform.pathSeparator}wy.js');
    await pluginFile.writeAsString(r'''
      module.exports = {
        platform: '网易云音乐',
        search: async () => ({
          data: [{
            id: 509781655,
            title: '测试歌曲',
            duration: 200000,
            musicInfo: {
              detail: {
                album: { blurPicUrl: '//p3.music.126.net/key/song.jpg' },
              },
            },
          }],
        }),
      };
    ''');
    final client = MockClient((_) async {
      fail('已有嵌套封面时不应请求详情接口');
    });
    final service = PluginRuntimeService(httpClient: client);
    addTearDown(() async {
      service.dispose();
      client.close();
      await directory.delete(recursive: true);
    });

    final result = await service.search(
      EnabledMusicPlugin(id: 'wy', name: '网易云音乐', path: pluginFile.path),
      '测试',
    );

    expect(
      result.single.coverUrl,
      'https://p3.music.126.net/key/song.jpg?param=800y800',
    );
  });

  test('网易云旧详情接口没有封面时使用 v3 接口继续补全', () async {
    final directory = await Directory.systemTemp.createTemp(
      'xy-music-netease-v3-cover-',
    );
    final pluginFile = File('${directory.path}${Platform.pathSeparator}wy.js');
    await pluginFile.writeAsString(r'''
      module.exports = {
        platform: '网易云音乐',
        search: async () => ({
          data: [{ id: 509781655, title: '想你就写信', artist: '周杰伦' }],
        }),
      };
    ''');
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      if (request.url.path == '/api/song/detail/') {
        return http.Response(jsonEncode({'songs': []}), 200);
      }
      expect(request.url.path, '/api/v3/song/detail');
      return http.Response(
        jsonEncode({
          'songs': [
            {
              'id': 509781655,
              'dt': 238698,
              'al': {'picUrl': '//p3.music.126.net/cover-key/song.jpg'},
            },
          ],
        }),
        200,
      );
    });
    final service = PluginRuntimeService(httpClient: client);
    addTearDown(() async {
      service.dispose();
      client.close();
      await directory.delete(recursive: true);
    });

    final result = await service.search(
      EnabledMusicPlugin(id: 'wy', name: '网易云音乐', path: pluginFile.path),
      '周杰伦',
    );

    expect(requests, 2);
    expect(
      result.single.coverUrl,
      'https://p3.music.126.net/cover-key/song.jpg?param=800y800',
    );
    expect(result.single.durationMs, 238698);
  });

  test('兼容 getLyrics、getLrc 和歌词行数组返回格式', () async {
    final directory = await Directory.systemTemp.createTemp(
      'xy-music-lyrics-alias-',
    );
    final pluginFile = File(
      '${directory.path}${Platform.pathSeparator}lyrics-alias.js',
    );
    await pluginFile.writeAsString(r'''
      module.exports = {
        platform: '歌词协议兼容测试',
        search: async () => ({ data: [] }),
        getLyrics: async () => ({}),
        getLrc: async () => ({
          data: {
            lrclist: [
              { time: '1.25', lineLyric: '第一句' },
              { time: 62.5, lineLyric: '第二句' },
            ],
          },
        }),
      };
    ''');
    final client = MockClient((_) async => http.Response('', 404));
    final service = PluginRuntimeService(httpClient: client);
    addTearDown(() async {
      service.dispose();
      client.close();
      await directory.delete(recursive: true);
    });

    final lyrics = await service.getLyrics(
      EnabledMusicPlugin(
        id: 'lyrics-alias',
        name: '歌词协议兼容测试',
        path: pluginFile.path,
      ),
      {'id': 'song-1'},
    );

    expect(lyrics, contains('[00:01.25]第一句'));
    expect(lyrics, contains('[01:02.50]第二句'));
  });

  test('插件同时返回普通歌词和逐字歌词时优先保留 YRC', () async {
    final directory = await Directory.systemTemp.createTemp(
      'xy-music-word-lyrics-',
    );
    final pluginFile = File(
      '${directory.path}${Platform.pathSeparator}word.js',
    );
    await pluginFile.writeAsString(r'''
      module.exports = {
        platform: '逐字歌词测试',
        search: async () => ({ data: [] }),
      };
    ''');
    final client = MockClient((_) async {
      fail('内嵌逐字歌词不应发起网络请求');
    });
    final service = PluginRuntimeService(httpClient: client);
    addTearDown(() async {
      service.dispose();
      client.close();
      await directory.delete(recursive: true);
    });
    const yrc = '[1000,900](1000,400,0)逐(1400,500,0)字';

    final lyrics = await service.getLyrics(
      EnabledMusicPlugin(
        id: 'word-lyrics',
        name: '逐字歌词测试',
        path: pluginFile.path,
      ),
      const {
        'rawLrc': '[00:01.00]逐字',
        'yrc': {'lyric': yrc},
      },
    );

    expect(lyrics, yrc);
  });

  test('插件返回歌词 URL 时下载正文', () async {
    final directory = await Directory.systemTemp.createTemp(
      'xy-music-lyrics-url-',
    );
    final pluginFile = File(
      '${directory.path}${Platform.pathSeparator}lyrics-url.js',
    );
    await pluginFile.writeAsString(r'''
      module.exports = {
        platform: '歌词 URL 测试',
        search: async () => ({ data: [] }),
        getLyric: async () => ({
          lyric: 'https://lyrics.test/song.lrc',
        }),
      };
    ''');
    final client = MockClient((request) async {
      expect(request.url.toString(), 'https://lyrics.test/song.lrc');
      return http.Response.bytes(
        utf8.encode('[00:01.00]网络歌词'),
        200,
        headers: {'content-type': 'text/plain; charset=utf-8'},
      );
    });
    final service = PluginRuntimeService(httpClient: client);
    addTearDown(() async {
      service.dispose();
      client.close();
      await directory.delete(recursive: true);
    });

    final lyrics = await service.getLyrics(
      EnabledMusicPlugin(
        id: 'lyrics-url',
        name: '歌词 URL 测试',
        path: pluginFile.path,
      ),
      {'id': 'song-2'},
    );

    expect(lyrics, '[00:01.00]网络歌词');
  });

  test('网易云插件歌词方法失效时使用官方接口兜底', () async {
    final directory = await Directory.systemTemp.createTemp(
      'xy-music-netease-lyrics-',
    );
    final pluginFile = File(
      '${directory.path}${Platform.pathSeparator}wy-lyrics.js',
    );
    await pluginFile.writeAsString(r'''
      module.exports = {
        platform: '网易云音乐',
        search: async () => ({ data: [] }),
        getLyric: async () => ({}),
      };
    ''');
    final client = MockClient((request) async {
      expect(request.url.host, 'music.163.com');
      expect(request.url.path, '/api/song/lyric');
      expect(request.url.queryParameters['id'], '509781655');
      expect(request.url.queryParameters['yv'], '-1');
      return http.Response(
        jsonEncode({
          'code': 200,
          'lrc': {'lyric': '[00:01.00]网易云官方歌词'},
          'yrc': {
            'lyric':
                '[1000,1200](1000,400,0)网(1400,400,0)易'
                '(1800,400,0)云',
          },
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final service = PluginRuntimeService(httpClient: client);
    addTearDown(() async {
      service.dispose();
      client.close();
      await directory.delete(recursive: true);
    });

    final lyrics = await service.getLyrics(
      EnabledMusicPlugin(id: 'wy', name: '网易云音乐', path: pluginFile.path),
      {'id': 509781655},
    );

    expect(lyrics, '[1000,1200](1000,400,0)网(1400,400,0)易(1800,400,0)云');
  });

  // 复现 cwo baka 订阅源 QQ 平台「沧浪歌」无歌词 bug：插件 getLyric
  // 拿到 crypt:1 的十六进制密文后不解密直接透传。修复后宿主应拒绝
  // 密文并走 QQ 平台直连兜底（c.y.qq.com 老接口，按 songmid 查询）。
  test('QQ 音乐插件返回密文时拒绝并走老接口兜底（沧浪歌）', () async {
    final directory = await Directory.systemTemp.createTemp(
      'xy-music-qq-lyrics-',
    );
    final pluginFile = File(
      '${directory.path}${Platform.pathSeparator}qq-lyrics.js',
    );
    await pluginFile.writeAsString(r'''
      module.exports = {
        platform: 'QQ音乐[L1]',
        search: async () => ({ data: [] }),
        getLyric: async () =>
          '8e1f2a3b4c5d6e7f8e1f2a3b4c5d6e7f8e1f2a3b4c5d6e7f8e1f2a3b4c5d6e7f' +
          '8e1f2a3b4c5d6e7f8e1f2a3b4c5d6e7f8e1f2a3b4c5d6e7f8e1f2a3b4c5d6e7f',
      };
    ''');
    // 沧浪歌（songmid=003RbupC0mrIj3）老接口的真实响应。
    const canglangLegacyResponse =
        '{"retcode":0,"code":0,"subcode":0,"lyric":"WzAwOjAxLjcxXeS9nOivje+8mumdnuasogpbMDA6MDIuOTZd5L2c5puy77ya54aZ5pyI5pyI5aKo6L6eL+iRo+WtkOm+mQpbMDA6MDMuOTZd57yW5puy77ya5aKo6L6eL+iRo+WtkOm+mS/pub/ngq/pnJYKWzAwOjA1LjQ3XeWSjOWjsOe8luW9le+8muWwj+mbquS6ui/nhpnmnIjmnIgv57ud5q2MClswMDowNi43Ml3nrJvlrZDlrp7lvZXvvJrlsZXlrofvvIjlvJXllYblnYrvvIkKWzAwOjA3Ljk4XeW8puS5kOWunuW9le+8muWbvemZhemmluW4reeIseS5kOS5kOWbogpbMDA6MDkuMjRd5ZCJ5LuW5a6e5b2V77ya6JGj5a2Q6b6ZClswMDoxMC4yNF3liIbovajmt7fpn7PluIjvvJrmoqjphaMKWzAwOjExLjc0XeavjeW4pu+8muaiqOmFowpbMDA6MTIuNzVd57uf562577ya5aKo6L6eL+mYv+iIn05sZwpbMDA6MTQuMDBd55uR5Yi277ya5q+b5LiN5q2qL+WtkOasogpbMDA6MTUuNTFd5bWV5b2X5LiO5pe25LqG77ya5q2l6IyE5a+G5pepL1pUTiBTdHVkaW8KWzAwOjE2LjUxXemfs+S5kOaOqOW5v++8muWGrOaggC/lvZLkuIAv5pe25a6JClswMDoxNy43N13liLbkvZzlhazlj7jvvJrlrZDlpoLliJ3pn7PkuZDlt6XkvZzlrqQKWzAwOjE5LjAzXea1t+aKpeiuvuiuoe+8muiUk+S6iC/mna3lt57ku5/kur/kvKDlqpLmnInpmZDlhazlj7gKClswMDoyNS41NV3lpJrlsJHmg4Xku4fmganmgKgg5ZCM6LW06Z+25YWJClswMDozMS4zM13lh6DluqbnlJ/mrbvova7lm54g5pyA5piv5peg5bi4ClswMDozNy4xMF3mmK/kuI7pnZ4g5Lu75a6D5aSp5LiL5Y676K6yClswMDo0Mi42M13or7Tku5nlppYg5pyA5pyJ5Yir5peg5aaoCgpbMDA6NDguNDBd5oiR5bCG5rWu55Sf5Y6G5bC9IOeVmeS4gOi6q+S8pApbMDA6NTQuNDJd5Lu75oiR6L2s5LiW6YeN5p2lIOS+neaXp+mavuW/mApbMDA6NTkuOTRd562J5pyI5Y2OIOmTuuWcqOS9oOaIkei6q+S4igpbMDE6MDQuNDZd5Lmf566X5pivIOmZquS9oOS4gOS4lumVvwoKWzAxOjEwLjIzXeiAjOaIkei6q+S4lua1ruayiSDml6DnlY/pqofmtaog5aSp5Zyw5Lu75oiR6ZevClswMToxNS41MF3ljbTlnKjnrYnkvaAg5ouo5byA5Lq65rW35p2l5Yiw5oiR6Lqr5peBClswMToyMS41M13nrYnov4fpm6jpm6rpo47pnJwg5pel5aSN5pelIOaVheS6uuS4jeaVouW/mApbMDE6MjcuMzBd5pyJ5bm45LiO5ZCb55u46YCiIOWIu+WcqOW/g+S4igoKWzAxOjU3LjA4XeaIkeWwhua1rueUn+WOhuWwveeVmeS4gOi6q+S8pApbMDI6MDIuNjFd5Lu75oiR6L2s5LiW6YeN5p2l5L6d5pen6Zq+5b+YClswMjowOC4zOF3nrYnmnIjljY7pk7rlnKjkvaDmiJHouqvkuIoKWzAyOjEzLjE1XeS5n+eul+aYr+mZquS9oOS4gOS4lumVvwoKWzAyOjE4LjkyXeiAjOaIkei6q+S4lua1ruayiSDml6DnlY/pqofmtaog5aSp5Zyw5Lu75oiR6ZevClswMjoyNC4xOV3ljbTlnKjnrYnkvaAg5ouo5byA5Lq65rW35p2l5Yiw5oiR6Lqr5peBClswMjozMC4yMl3nrYnov4fpm6jpm6rpo47pnJwg5pel5aSN5pelIOaVheS6uuS4jeaVouW/mApbMDI6MzUuOTld5pyJ5bm45ZCb55u46YCiIOWIu+WcqOW/g+S4igoKWzAyOjQyLjAyXeWlveWcqOS9oOS7jeaYr+S9oCDmiJHkuqbmmK/miJEg5oCO6aG75LuW5Lq66K6yClswMjo0Ny41N13ml6DkurrkvZzmopcg5pC65omL5Lq66Ze05q2k55Sf5bqU5LiN5p6JClswMjo1My4xMF3lkIzljoblr5LmnaXmmpHlvoAg5bm05aSN5bm0IOa3sea4iuWPiOS9leWmqApbMDI6NTguNjJd57uI5b2S5pyJ5L2g5LiO5oiRIOi4j+egtOayp+a1qgoKWzAzOjA1LjM5XeeJueWIq+m4o+iwou+8mgpbMDM6MDYuNDBd6aOT6aOO5bel5L2c5a6kClswMzowNy42NV3mqLHmoYPmtL7lr7lNQ04KWzAzOjA4LjkxXeadreW3nuS7n+S6v+S8oOWqkuaciemZkOWFrOWPuApbMDM6MDkuOTFd5bm/6KW/6IKG6IKG5aO56Zu26Zu25paH5YyW56eR5oqA5pyJ6ZmQ5YWs5Y+4ClswMzoyMi4wMF0=","trans":""}';
    final client = MockClient((request) async {
      if (request.url.host == 'c.y.qq.com') {
        expect(request.url.path, '/lyric/fcgi-bin/fcg_query_lyric_new.fcg');
        expect(request.url.queryParameters['songmid'], '003RbupC0mrIj3');
        return http.Response(
          canglangLegacyResponse,
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 200);
    });
    final service = PluginRuntimeService(httpClient: client);
    addTearDown(() async {
      service.dispose();
      client.close();
      await directory.delete(recursive: true);
    });

    final lyrics = await service.getLyrics(
      EnabledMusicPlugin(id: 'qq', name: 'QQ音乐[L1]', path: pluginFile.path),
      const {
        'platform': 'QQ音乐[L1]',
        'name': '沧浪歌',
        'id': '374735399',
        'mid': '003RbupC0mrIj3',
      },
    );

    // 密文被拒绝，兜底返回沧浪歌真实歌词（首行与正文）。
    expect(lyrics, contains('[00:01.71]作词：非欢'));
    expect(lyrics, contains('[02:58.62]终归有你与我 踏破沧浪'));
    expect(lyrics, isNot(contains('8e1f2a3b')));
  });

  test('插件歌词为密文且无兜底来源时返回空串而非乱码', () async {
    final directory = await Directory.systemTemp.createTemp(
      'xy-music-encrypted-lyrics-',
    );
    final pluginFile = File(
      '${directory.path}${Platform.pathSeparator}encrypted.js',
    );
    await pluginFile.writeAsString(r'''
      module.exports = {
        platform: '聚合测试',
        search: async () => ({ data: [] }),
        getLyric: async () =>
          'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef' +
          'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
      };
    ''');
    final client = MockClient(
      (_) async => http.Response('{}', 200),
    );
    final service = PluginRuntimeService(httpClient: client);
    addTearDown(() async {
      service.dispose();
      client.close();
      await directory.delete(recursive: true);
    });

    final lyrics = await service.getLyrics(
      EnabledMusicPlugin(id: 'mixed', name: '聚合测试', path: pluginFile.path),
      const {'name': '测试歌曲'},
    );

    expect(lyrics, '');
  });
}
