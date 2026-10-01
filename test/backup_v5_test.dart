import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/backup/backup_service.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart'
    show EnabledMusicPlugin;

/// v5 备份格式（仿 MusicFree 结构）的读取转换测试：
/// musicSheets → 收藏/歌单内部偏好结构、plugins → 脚本+订阅来源、
/// exportedSections 的「未勾选不动 / 勾选但为空清空」语义，
/// 以及 v1–v4 旧格式的兼容读取。
void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('xy_backup_v5_test');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  Future<String> writeBackup(Map<String, dynamic> payload) async {
    final file = File('${tmpDir.path}/backup.json');
    await file.writeAsString(jsonEncode(payload));
    return file.path;
  }

  test('v5 全量备份：音乐列表转换回收藏/歌单偏好结构', () async {
    final path = await writeBackup({
      'schema': 'xymusic.backup',
      'version': 5,
      'createdAt': 1788823570424,
      'data': {
        'exportedSections': ['favorites', 'playlists', 'plugins', 'settings'],
        'musicSheets': [
          {
            'id': 'favorite',
            'platform': '本地',
            'title': '我的收藏',
            'coverImg': null,
            'worksNum': 2,
            'customOrder': ['plugin://bili/1', '/music/a.mp3'],
            'musicList': [
              {
                'id': 'BV1xx411',
                'title': '在线歌',
                'artist': '歌手A',
                'album': '专辑A',
                'duration': 180,
                'artwork': 'https://cdn/cover.jpg',
                'platform': 'Bilibili音乐',
                'path': 'plugin://bili/1',
                'pluginId': 'bilibili',
                'format': '网络',
                'qualities': {'128k': 'url'},
                'extra': {'bvid': 'BV1xx411'},
              },
              {
                'id': '',
                'title': '本地歌',
                'artist': '歌手B',
                'album': '',
                'duration': 240,
                'artwork': null,
                'platform': '本地',
                'path': '/music/a.mp3',
                'pluginId': null,
                'format': 'mp3',
                'qualities': null,
                'extra': null,
              },
            ],
          },
          {
            'id': 'sheet-1',
            'title': '我的歌单',
            'coverImg': 'https://cdn/pl.jpg',
            'worksNum': 1,
            'customOrder': ['plugin://kw/9'],
            'musicList': [
              {
                'id': '9',
                'title': '酷我歌',
                'artist': '歌手C',
                'album': '专辑C',
                'duration': 200,
                'artwork': 'https://cdn/kw.jpg',
                'platform': '酷我音乐',
                'path': 'plugin://kw/9',
                'pluginId': 'kw',
                'format': '网络',
                'qualities': {'320k': 'url'},
                'extra': null,
              },
            ],
          },
        ],
        'plugins': [
          {
            'id': 'bilibili',
            'srcUrl': 'https://example.com/bili.js',
            'version': '2.0.8',
            'script': '{"platform":"Bilibili音乐","version":"2.0.8"}',
          },
        ],
        'pluginState': {
          'mobileEnabledPlugins': {'t': 'sl', 'v': ['bilibili']},
        },
        'settings': {
          'themeMode': {'t': 's', 'v': 'dark'},
        },
        'library': {
          'songs': {
            'columns': ['path', 'title'],
            'rows': [
              ['/music/a.mp3', '本地歌'],
            ],
          },
          'play_history': {'columns': [], 'rows': []},
        },
      },
    });

    final data = await const BackupService().readBackup(path);

    // 头部与统计。
    expect(data.exportedAt, contains('2026-'));
    expect(data.sheetCount, 2);
    expect(data.songCount, 3);

    // 收藏：路径顺序 + 快照字段（含 pluginData，不含歌词）。
    final favoritePaths = data.prefs['favoritePaths']!;
    expect(favoritePaths['t'], 'sl');
    expect(favoritePaths['v'], ['plugin://bili/1', '/music/a.mp3']);
    final meta =
        jsonDecode(data.prefs['favoriteSongMetadataV1']!['v'] as String)
            as Map<String, dynamic>;
    expect(meta.length, 2);
    final online = meta['plugin://bili/1'] as Map;
    expect(online['title'], '在线歌');
    expect(online['pluginId'], 'bilibili');
    expect(online['coverUrl'], 'https://cdn/cover.jpg');
    expect(online['pluginData'], {'bvid': 'BV1xx411'});
    expect(online.containsKey('lyricsRaw'), isFalse);
    final local = meta['/music/a.mp3'] as Map;
    expect(local['format'], 'mp3');
    expect(data.prefs['favoriteCustomOrderV1']!['v'],
        ['plugin://bili/1', '/music/a.mp3']);

    // 歌单：songPaths + songSnapshots（歌单快照字段名）。
    final playlists =
        jsonDecode(data.prefs['mobilePlaylistsV1']!['v'] as String) as List;
    expect(playlists.length, 1);
    final playlist = playlists.first as Map;
    expect(playlist['id'], 'sheet-1');
    expect(playlist['name'], '我的歌单');
    expect(playlist['coverUrl'], 'https://cdn/pl.jpg');
    expect(playlist['songPaths'], ['plugin://kw/9']);
    expect(playlist['customOrder'], ['plugin://kw/9']);
    final snapshot =
        (playlist['songSnapshots'] as Map)['plugin://kw/9'] as Map;
    expect(snapshot['songId'], '9');
    expect(snapshot['platform'], '酷我音乐');
    expect(snapshot['qualities'], {'320k': 'url'});

    // 插件：脚本 + 订阅来源表。
    expect(data.plugins, {'bilibili': '{"platform":"Bilibili音乐","version":"2.0.8"}'});
    expect(
      jsonDecode(data.prefs['mobilePluginSourceUrlsV1']!['v'] as String),
      {'bilibili': 'https://example.com/bili.js'},
    );
    expect(data.prefs['mobileEnabledPlugins']!['v'], ['bilibili']);
    expect(data.prefs['themeMode']!['v'], 'dark');

    // 曲库：仅保留元数据缓存表，播放历史被剔除。
    expect(data.library.containsKey('songs'), isTrue);
    expect(data.library.containsKey('play_history'), isFalse);
    expect(data.librarySongCount, 1);
  });

  test('v5 仅勾选收藏：不动本机歌单；收藏为空时清空恢复', () async {
    final path = await writeBackup({
      'schema': 'xymusic.backup',
      'version': 5,
      'createdAt': 1788823570424,
      'data': {
        'exportedSections': ['favorites'],
        'musicSheets': [
          {
            'id': 'favorite',
            'title': '我的收藏',
            'worksNum': 1,
            'musicList': [
              {
                'title': 'x',
                'path': '/music/b.flac',
                'platform': '本地',
                'format': 'flac',
                'duration': 100,
              },
            ],
          },
        ],
      },
    });
    final data = await const BackupService().readBackup(path);
    // 未勾选歌单：不写 mobilePlaylistsV1（不动本机歌单）。
    expect(data.prefs.containsKey('mobilePlaylistsV1'), isFalse);
    expect(data.prefs['favoritePaths']!['v'], ['/music/b.flac']);

    // 空收藏（勾了收藏但没有 favorite 表）→ 清空恢复。
    final emptyPath = await writeBackup({
      'schema': 'xymusic.backup',
      'version': 5,
      'createdAt': 1788823570424,
      'data': {
        'exportedSections': ['favorites'],
        'musicSheets': [],
      },
    });
    final empty = await const BackupService().readBackup(emptyPath);
    expect(empty.prefs['favoritePaths']!['v'], isEmpty);
    expect(empty.prefs['favoriteSongMetadataV1']!['v'], '{}');
    expect(empty.prefs.containsKey('mobilePlaylistsV1'), isFalse);
  });

  test('v5 歌单 id 为空时生成兜底 id；坏条目被跳过', () async {
    final path = await writeBackup({
      'schema': 'xymusic.backup',
      'version': 5,
      'createdAt': 1788823570424,
      'data': {
        'exportedSections': ['playlists'],
        'musicSheets': [
          {
            'id': '',
            'title': '无名歌单',
            'musicList': [
              {'title': 'ok', 'path': '/a.mp3', 'duration': 10},
              'not-a-map',
              {'title': 'no-path', 'duration': 10},
            ],
          },
        ],
      },
    });
    final data = await const BackupService().readBackup(path);
    final playlists =
        jsonDecode(data.prefs['mobilePlaylistsV1']!['v'] as String) as List;
    expect(playlists.length, 1);
    final playlist = playlists.first as Map;
    expect(playlist['id'], startsWith('pl_'));
    expect(playlist['songPaths'], ['/a.mp3']);
    expect((playlist['songSnapshots'] as Map).length, 1);
  });

  test('v5 版本过新时拒绝导入；非 XY 备份报错', () async {
    final tooNew = await writeBackup({
      'schema': 'xymusic.backup',
      'version': 6,
      'createdAt': 0,
      'data': {},
    });
    expect(
      () => const BackupService().readBackup(tooNew),
      throwsA(isA<BackupException>()),
    );
    final foreign = await writeBackup({
      'schema': 'bakamusic.music-sheet-backup',
      'version': 3,
      'createdAt': 0,
      'data': {},
    });
    expect(
      () => const BackupService().readBackup(foreign),
      throwsA(isA<BackupException>()),
    );
  });

  test('v1–v4 旧格式（format 头）仍可读取', () async {
    final path = await writeBackup({
      'format': 'xymusic-backup',
      'version': 4,
      'exportedAt': '2026-09-01T00:00:00',
      'prefs': {
        'mobilePlaylistsV1': {'t': 's', 'v': '[]'},
        'recentSongMetadataV1': {'t': 's', 'v': '{}'},
      },
      'plugins': {'demo': 'console.log(1)'},
      'library': {},
    });
    final data = await const BackupService().readBackup(path);
    expect(data.prefCount, 1); // 最近播放快照被排除。
    expect(data.plugins, {'demo': 'console.log(1)'});
    expect(data.sheetCount, 0);
  });

  test('互转辅助字段：标准平台码与插件歌曲 id 提取', () {
    // 已知平台 → 洛雪风格短码。
    expect(BackupService.canonicalSource('netease'), 'wy');
    expect(BackupService.canonicalSource('wy'), 'wy');
    expect(BackupService.canonicalSource('qq'), 'tx');
    expect(BackupService.canonicalSource('kuwo'), 'kw');
    expect(BackupService.canonicalSource('kw'), 'kw');
    expect(BackupService.canonicalSource('kugou'), 'kg');
    expect(BackupService.canonicalSource('migu'), 'mg');
    expect(BackupService.canonicalSource('bilibili'), 'bilibili');
    // 未知插件去掉「音乐」等后缀，保留可读源名。
    expect(BackupService.canonicalSource('animemusic'), 'anime');
    expect(BackupService.canonicalSource('Bilibili音乐'), 'bilibili');

    // plugin://<pluginId>/<songId> → songId（可含斜杠）。
    expect(BackupService.songIdFromPluginPath('plugin://bili/BV1xx411'),
        'BV1xx411');
    expect(
      BackupService.songIdFromPluginPath('plugin://bili/av170001/part2'),
      'av170001/part2',
    );
    // 非插件路径 / 缺 songId / 缺 pluginId 均返回 null。
    expect(BackupService.songIdFromPluginPath('/storage/a.mp3'), isNull);
    expect(BackupService.songIdFromPluginPath('plugin://bili/'), isNull);
    expect(BackupService.songIdFromPluginPath('plugin:///123'), isNull);
  });

  test('v5 无 path 网络条目：按平台匹配已装插件重建（外部转换产物）', () async {
    final path = await writeBackup({
      'schema': 'xymusic.backup',
      'version': 5,
      'createdAt': 1788823570424,
      'data': {
        'exportedSections': ['favorites'],
        'musicSheets': [
          {
            'id': 'favorite',
            'title': '我的收藏',
            'worksNum': 3,
            'musicList': [
              // MusicFree/BakaMusic 风格：platform + id，无 XY 私有 path。
              {
                'id': '9',
                'title': '酷我歌',
                'artist': '歌手C',
                'album': '专辑C',
                'duration': 200,
                'platform': '酷我音乐',
              },
              // 洛雪风格：source + 复合 id（<source>_<songId>）+ meta。
              {
                'id': 'wy_29097542',
                'title': '网易歌',
                'artist': '歌手D',
                'album': '专辑D',
                'source': 'wy',
                'interval': '03:30',
                'meta': {'songId': '29097542', 'albumId': '29001'},
              },
              // 咪咕平台无专用插件，但洛雪源覆盖 mg → 重建走洛雪。
              {
                'id': '1',
                'title': '无插件歌',
                'artist': 'x',
                'platform': '咪咕音乐',
              },
            ],
          },
        ],
      },
    });

    const plugins = [
      EnabledMusicPlugin(id: 'kw', name: '酷我音乐', path: 'kw.js'),
      EnabledMusicPlugin(
        id: 'lx',
        name: '洛雪音乐',
        path: 'lx.js',
        isLx: true,
        lxSources: ['kw', 'kg', 'tx', 'wy', 'mg'],
      ),
    ];

    final data = await const BackupService().readBackup(
      path,
      enabledPlugins: plugins,
    );

    final favoritePaths = data.prefs['favoritePaths']!['v'] as List;
    expect(favoritePaths.length, 3);
    expect(favoritePaths, contains('plugin://kw/9'));
    expect(favoritePaths, contains('lx://wy/29097542'));
    expect(favoritePaths, contains('lx://mg/1'));

    // 洛雪条目快照：复合 id 拆解、meta 平移到 pluginData.lx。
    final meta =
        jsonDecode(data.prefs['favoriteSongMetadataV1']!['v'] as String)
            as Map<String, dynamic>;
    final lxSnapshot = meta['lx://wy/29097542'] as Map;
    expect(lxSnapshot['title'], '网易歌');
    final pluginData = lxSnapshot['pluginData'] as Map;
    final lx = pluginData['lx'] as Map;
    expect(lx['songmid'], '29097542');
    expect(lx['source'], 'wy');
    expect(lx['albumId'], '29001');
    // mm:ss 时长格式化为洛雪 interval 文本，_interval 存毫秒。
    expect(lx['interval'], '03:30');
    expect(lx['_interval'], 210000);
  });
}
