import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/plugins/lx_playlist_import.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 用户提供过的两个真实洛雪 v2 全量备份样本；仅在本机附件仍存在时
  /// 参与回归（其他环境自动跳过），结构逻辑由下方 fixture 用例覆盖。
  const files = [
    r'C:\Users\35803\.trae-cn\attachments\a12bde64-4c9a-4c3e-83cb-63d9c920c934_e760aaa5-c896-450c-a30a-60ef75bd98be_playlists.json',
    r'C:\Users\35803\.trae-cn\attachments\e33d1ad2-9ecd-4b66-b9e2-85512ced7cd0_eb65a068-6c48-475b-aaf1-9a08184e608a_playlists1.json',
  ];

  final realFilesExist = files.every((path) => File(path).existsSync());

  test(
    '洛雪 v2 全量备份：解析出固定列表与全部用户歌单',
    () async {
      for (final path in files) {
        final content = await File(path).readAsString();
        final playlists = tryParseLxLocalPlaylists(content);
        expect(playlists, isNotEmpty, reason: '文件解析失败: $path');

        // 固定列表 + 57 个用户歌单。
        expect(playlists, hasLength(greaterThanOrEqualTo(58)));

        final names = playlists.map((item) => item.name).toList();
        expect(names, contains('试听列表'));
        expect(names, contains('我的收藏'));
        expect(names, contains('喜欢听的国语。'));

        final love = playlists.firstWhere(
          (item) => item.name == '我的收藏',
        );
        expect(love.songs, hasLength(greaterThanOrEqualTo(3000)));

        // loveList 首曲（wy）：songmid 从 "wy_3402858225" 剥离前缀，
        // 专辑/封面/音质来自 meta 嵌套。
        final first = love.songs.first;
        expect(first['id'], '3402858225');
        expect(first['title'], '青玉恋');
        expect(first['artist'], '刘宇');
        expect(first['duration'], 252);
        expect(first['album'], '青玉恋');
        expect(
          first['artwork'],
          startsWith('https://p3.music.126.net/'),
        );
        final lx = first['lx'] as Map<String, dynamic>;
        expect(lx['source'], 'wy');
        expect(lx['songmid'], '3402858225');
        expect(lx['songId'], 3402858225);
        expect(lx['interval'], '04:12');
        final types = lx['_types'] as Map<String, dynamic>;
        expect(types, isNotEmpty);
        expect(first['_sourcePath'], 'lx://wy/3402858225');

        // 试听列表首曲（tx）：songmid 从 "tx_001dEI9i3VqAHc" 剥离前缀。
        final audition = playlists.firstWhere(
          (item) => item.name == '试听列表',
        );
        final txSong = audition.songs.first;
        expect(txSong['id'], '001dEI9i3VqAHc');
        expect(txSong['title'], '未完结的爱');
        final txLx = txSong['lx'] as Map<String, dynamic>;
        expect(txLx['source'], 'tx');
        expect(txLx['songmid'], '001dEI9i3VqAHc');
        expect(
          (txSong['artwork'] as String).contains('y.gtimg.cn'),
          isTrue,
        );

        // 用户歌单首曲字段完整。
        final user = playlists.firstWhere(
          (item) => item.name == '喜欢听的国语。',
        );
        expect(user.songs, isNotEmpty);
        final userSong = user.songs.first;
        expect(userSong['title'], isNotEmpty);
        expect(userSong['artist'], isNotEmpty);
        expect(
          (userSong['lx'] as Map)['source'],
          anyOf('kw', 'kg', 'tx', 'wy', 'mg'),
        );
      }
    },
    skip: realFilesExist ? false : '本机无真实备份样本，跳过',
  );

  test('洛雪 v2 单首歌：kw 源 hash 剥离与 v1 结构仍兼容', () {
    // v2 扁平结构（kg：songmid 从 id 前缀剥离）。
    const v2Kg = {
      'id': 'kg_9A2B7C8D9E0F1A2B3C4D5E6F7A8B9C0D',
      'name': '测试歌曲',
      'singer': '测试歌手',
      'source': 'kg',
      'interval': '03:45',
      'meta': {
        'hash': '9A2B7C8D9E0F1A2B3C4D5E6F7A8B9C0D',
        'albumName': '测试专辑',
        'albumId': '12345',
        'picUrl': 'https://example.com/cover.jpg',
        '_qualitys': {
          '128k': {'size': '3.5 MB'},
          '320k': {'size': '8.7 MB'},
        },
      },
    };
    final raw = normalizeLxLocalSong(v2Kg);
    expect(raw, isNotNull);
    expect(raw!['id'], '9A2B7C8D9E0F1A2B3C4D5E6F7A8B9C0D');
    expect(raw['album'], '测试专辑');
    expect(raw['artwork'], 'https://example.com/cover.jpg');
    final lx = raw['lx'] as Map<String, dynamic>;
    expect(lx['hash'], '9A2B7C8D9E0F1A2B3C4D5E6F7A8B9C0D');
    expect((lx['_types'] as Map).containsKey('320k'), isTrue);

    // v1 扁平结构（songmid 在顶层）保持兼容。
    const v1 = {
      'songmid': '001dEI9i3VqAHc',
      'name': '旧版歌曲',
      'singer': '旧版歌手',
      'source': 'tx',
      'interval': '04:12',
    };
    final rawV1 = normalizeLxLocalSong(v1);
    expect(rawV1, isNotNull);
    expect(rawV1!['id'], '001dEI9i3VqAHc');
  });
}
