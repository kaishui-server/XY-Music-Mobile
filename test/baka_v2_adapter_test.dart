import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// v2 适配层的静态契约测试：保证 assets 产物、入口签名、能力映射表与
/// Dart 侧调用约定保持一致（真机 QuickJS 链路无法在单测内执行）。
void main() {
  final adapter = File('assets/baka_v2_adapter.js');

  test('适配脚本存在且已声明进 pubspec assets', () {
    expect(adapter.existsSync(), isTrue);
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec.contains('assets/baka_v2_adapter.js'), isTrue);
  });

  test('暴露 __xyLoadV2Plugin(id, source, userVariablesJson) 入口', () {
    final source = adapter.readAsStringSync();
    expect(
      RegExp(
        r'globalThis\.__xyLoadV2Plugin\s*=\s*function\s*\(\s*id\s*,\s*source\s*,\s*userVariablesJson\s*\)',
      ).hasMatch(source),
      isTrue,
    );
  });

  test('注册阶段复用 __xyLoadMusicFreePlugin 通道', () {
    final source = adapter.readAsStringSync();
    expect(source.contains('__xyLoadMusicFreePlugin'), isTrue);
    // 门面必须带 search，否则会被 MusicFree 运行时判定为非插件而加载失败。
    expect(source.contains('facade.search = function'), isTrue);
  });

  test('覆盖引擎分发的全部调用方法', () {
    final source = adapter.readAsStringSync();
    const methods = [
      'search',
      'getMediaSource',
      'getMusicInfo',
      'getArtistWorks',
      'getAlbumInfo',
      'getTopLists',
      'getTopListDetail',
      'getDailyRecommendations',
      'getMusicComments',
      'getLyrics',
    ];
    for (final method in methods) {
      expect(
        source.contains("'$method'"),
        isTrue,
        reason: '适配层缺少 $method 的分发映射',
      );
    }
  });

  test('能力分组覆盖 search/entities/media/collections/lyrics/comments', () {
    final source = adapter.readAsStringSync();
    // v2 能力名是命名空间点分写法（entities.get / media.resolve …），
    // 断言必须用完整能力名，用旧的分组前缀找不到带引号的字面量。
    for (final group in const [
      "'search'",
      "'entities.get'",
      "'media.resolve'",
      "'collections.members'",
      "'lyrics.get'",
      "'comments.list'",
    ]) {
      expect(source.contains(group), isTrue, reason: '缺少能力分组 $group');
    }
    // 能力为空时不裁剪（部分订阅源不带 capabilities 字段）。
    expect(source.contains('!state.capabilities.length ||'), isTrue);
  });
}
