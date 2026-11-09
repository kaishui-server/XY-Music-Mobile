// 歌手头像「只补缺、不覆盖」规则回归测试。
//
// 固定以下行为，避免后续改动导致退化：
// 1. 平台已带头像的歌手不发起补查，补查结果也不会覆盖平台头像；
// 2. 只有缺头像的歌手触发补查：非 LX 走插件歌手搜索，LX 走公开搜索兜底；
// 3. 查询失败/无结果时回退占位，不影响已有头像；
// 4. 解析结果按「插件 + 歌手名」缓存并合并并发请求。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/plugins/artist_avatar_resolver.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';

PluginCatalogResult _artist(String name, {String avatar = ''}) =>
    PluginCatalogResult(
      pluginId: 'p',
      id: name,
      title: name,
      subtitle: '',
      coverUrl: avatar,
      rawData: const {},
    );

void main() {
  group('只补缺：平台已有头像不补查、不覆盖', () {
    test('平台已带头像的歌手不进入补查队列', () {
      final plan = missingArtistAvatarNames([
        (name: 'ILLENIUM', avatar: 'https://img/a.jpg'),
        (name: 'Nevve', avatar: ''),
        (name: 'Nevve', avatar: ''),
        (name: '   ', avatar: ''),
      ]);
      expect(plan, ['Nevve']);
    });

    test('全部歌手都有头像时不产生任何待查项', () {
      expect(
        missingArtistAvatarNames([
          (name: 'A', avatar: 'https://img/a.jpg'),
          (name: 'B', avatar: 'https://img/b.jpg'),
        ]),
        isEmpty,
      );
    });

    test('展示头像始终以平台头像优先，补查结果不覆盖', () {
      expect(
        effectiveArtistAvatar('https://platform/a.jpg', 'https://lookup/b.jpg'),
        'https://platform/a.jpg',
      );
      expect(
        effectiveArtistAvatar('', 'https://lookup/b.jpg'),
        'https://lookup/b.jpg',
      );
      expect(effectiveArtistAvatar('', ''), '');
      expect(effectiveArtistAvatar('  ', null), '');
    });

    test('面板补查只为缺头像的歌手请求，已有头像保持原值', () async {
      final requested = <String>[];
      final resolved = await resolveMissingArtistAvatars(
        [
          (name: 'ILLENIUM', avatar: 'https://platform/ill.jpg'),
          (name: 'Nevve', avatar: ''),
        ],
        (name) async {
          requested.add(name);
          return 'https://lookup/nevve.jpg';
        },
      );
      expect(requested, ['Nevve']);
      expect(resolved.keys, ['Nevve']);
      expect(
        effectiveArtistAvatar('https://platform/ill.jpg', resolved['ILLENIUM']),
        'https://platform/ill.jpg',
      );
      expect(
        effectiveArtistAvatar('', resolved['Nevve']),
        'https://lookup/nevve.jpg',
      );
    });

    test('全部歌手都有头像时不发起任何补查', () async {
      var calls = 0;
      final resolved = await resolveMissingArtistAvatars(
        [
          (name: 'A', avatar: 'https://platform/a.jpg'),
          (name: 'B', avatar: 'https://platform/b.jpg'),
        ],
        (name) async {
          calls++;
          return 'https://lookup/$name.jpg';
        },
      );
      expect(calls, 0);
      expect(resolved, isEmpty);
    });

    test('查询失败或空结果时回退占位，已有头像不受影响', () async {
      final resolved = await resolveMissingArtistAvatars([
        (name: 'ILLENIUM', avatar: 'https://platform/ill.jpg'),
        (name: 'Nevve', avatar: ''),
      ], (name) async => '');
      expect(
        effectiveArtistAvatar('https://platform/ill.jpg', resolved['ILLENIUM']),
        'https://platform/ill.jpg',
      );
      expect(effectiveArtistAvatar('', resolved['Nevve']), '');
    });
  });

  group('补查派发：LX 走公开搜索，其余走插件歌手搜索', () {
    test('非 LX 源走插件歌手搜索，不调用公开兜底', () async {
      var publicCalls = 0;
      var pluginCalls = 0;
      final avatar = await resolveArtistAvatar(
        isLx: false,
        artistName: 'ILLENIUM',
        searchPluginArtists: () async {
          pluginCalls++;
          return [
            _artist('ILLENIUM', avatar: 'https://plugin/ill.jpg'),
            _artist('Nevve', avatar: 'https://plugin/nev.jpg'),
          ];
        },
        resolvePublicAvatar: () async {
          publicCalls++;
          return 'https://public/ill.jpg';
        },
      );
      expect(pluginCalls, 1);
      expect(publicCalls, 0);
      expect(avatar, 'https://plugin/ill.jpg');
    });

    test('LX 源走公开搜索兜底，不调用插件歌手搜索', () async {
      var pluginCalls = 0;
      var publicCalls = 0;
      final avatar = await resolveArtistAvatar(
        isLx: true,
        artistName: 'ILLENIUM',
        searchPluginArtists: () async {
          pluginCalls++;
          return const [];
        },
        resolvePublicAvatar: () async {
          publicCalls++;
          return 'https://public/ill.jpg';
        },
      );
      expect(pluginCalls, 0);
      expect(publicCalls, 1);
      expect(avatar, 'https://public/ill.jpg');
    });

    test('非 LX 源只取同名歌手（忽略大小写/空白/标点）', () async {
      final avatar = await resolveArtistAvatar(
        isLx: false,
        artistName: 'illenium',
        searchPluginArtists: () async => [
          _artist('ILLENIUM', avatar: 'https://plugin/ill.jpg'),
          _artist('Nevve', avatar: 'https://plugin/nev.jpg'),
        ],
        resolvePublicAvatar: () async => 'https://public/never.jpg',
      );
      expect(avatar, 'https://plugin/ill.jpg');
    });

    test('非 LX 源没有同名歌手时不取近似头像', () async {
      final avatar = await resolveArtistAvatar(
        isLx: false,
        artistName: 'ILLENIUM',
        searchPluginArtists: () async => [
          _artist('Nevve', avatar: 'https://plugin/nev.jpg'),
        ],
        resolvePublicAvatar: () async => 'https://public/ill.jpg',
      );
      expect(avatar, '');
    });

    test('多个包含候选时宁可不显示，避免错配', () async {
      final avatar = await resolveArtistAvatar(
        isLx: false,
        artistName: 'Nev',
        searchPluginArtists: () async => [
          _artist('Nevve', avatar: 'https://plugin/a.jpg'),
          _artist('Nevver', avatar: 'https://plugin/b.jpg'),
        ],
        resolvePublicAvatar: () async => 'https://public/nev.jpg',
      );
      expect(avatar, '');
    });

    test('插件歌手搜索异常时静默回退，且不落公开兜底', () async {
      var publicCalls = 0;
      final avatar = await resolveArtistAvatar(
        isLx: false,
        artistName: 'ILLENIUM',
        searchPluginArtists: () async => throw StateError('plugin failed'),
        resolvePublicAvatar: () async {
          publicCalls++;
          return 'https://public/ill.jpg';
        },
      );
      expect(avatar, '');
      expect(publicCalls, 0);
    });

    test('LX 公开搜索异常时静默回退', () async {
      final avatar = await resolveArtistAvatar(
        isLx: true,
        artistName: 'ILLENIUM',
        searchPluginArtists: () async => const [],
        resolvePublicAvatar: () async => throw StateError('public failed'),
      );
      expect(avatar, '');
    });

    test('空歌手名不触发任何请求', () async {
      var pluginCalls = 0;
      var publicCalls = 0;
      final avatar = await resolveArtistAvatar(
        isLx: false,
        artistName: '   ',
        searchPluginArtists: () async {
          pluginCalls++;
          return const [];
        },
        resolvePublicAvatar: () async {
          publicCalls++;
          return 'https://public/x.jpg';
        },
      );
      expect(avatar, '');
      expect(pluginCalls, 0);
      expect(publicCalls, 0);
    });
  });

  group('缓存与并发去重', () {
    test('同插件同歌手的并发请求只打一次', () async {
      final gate = Completer<String>();
      var calls = 0;
      final resolver = ArtistAvatarResolver(
        fetchAvatar: (pluginId, artistName) {
          calls++;
          return gate.future;
        },
      );
      final first = resolver.resolve('p', 'ILLENIUM');
      final second = resolver.resolve('p', 'ILLENIUM');
      expect(calls, 1);
      gate.complete('https://img/ill.jpg');
      expect(await first, 'https://img/ill.jpg');
      expect(await second, 'https://img/ill.jpg');
      expect(calls, 1);
    });

    test('命中缓存后不重复请求，换插件才重新请求', () async {
      var calls = 0;
      final resolver = ArtistAvatarResolver(
        fetchAvatar: (pluginId, artistName) async {
          calls++;
          return 'https://img/$pluginId-$artistName.jpg';
        },
      );
      expect(
        await resolver.resolve('p1', 'ILLENIUM'),
        'https://img/p1-ILLENIUM.jpg',
      );
      expect(
        await resolver.resolve('p1', 'ILLENIUM'),
        'https://img/p1-ILLENIUM.jpg',
      );
      expect(calls, 1);
      expect(
        await resolver.resolve('p2', 'ILLENIUM'),
        'https://img/p2-ILLENIUM.jpg',
      );
      expect(calls, 2);
    });

    test('成功但无结果也会缓存，避免反复查询', () async {
      var calls = 0;
      final resolver = ArtistAvatarResolver(
        fetchAvatar: (pluginId, artistName) async {
          calls++;
          return '';
        },
      );
      expect(await resolver.resolve('p', 'Unknown'), '');
      expect(await resolver.resolve('p', 'Unknown'), '');
      expect(calls, 1);
    });

    test('请求失败不缓存，后续仍可重试', () async {
      var calls = 0;
      final resolver = ArtistAvatarResolver(
        fetchAvatar: (pluginId, artistName) async {
          calls++;
          throw StateError('no key');
        },
      );
      expect(await resolver.resolve('p', 'ILLENIUM'), '');
      expect(calls, 1);
      expect(await resolver.resolve('p', 'ILLENIUM'), '');
      expect(calls, 2);
    });
  });

  test('构造解析器与读取展示头像本身不会发起请求', () {
    var calls = 0;
    ArtistAvatarResolver(
      fetchAvatar: (pluginId, artistName) async {
        calls++;
        return 'https://img/x.jpg';
      },
    );
    final avatar = effectiveArtistAvatar('https://platform/a.jpg', null);
    expect(avatar, 'https://platform/a.jpg');
    expect(calls, 0);
  });
}
