import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/plugins/plugin_metadata.dart';

/// v2 插件的 manifest 用命名空间键（`lyrics.get`、`media.resolve`…）声明
/// 能力，静态扫描只看扁平的 MusicFree 方法名，扫不到这些键。这些用例锁定
/// 「capabilities 反查回来并进 availableMethods」这一行为，避免歌词门控
/// （`PluginMetadata.lyricMethodNames.any(plugin.mayHaveMethod)`）再次把 v2
/// 插件判成无歌词能力。
/// 与 Plugin.mayHaveMethod 同义：空集合视为未识别，不做门控。
bool may(PluginMetadata metadata, String method) =>
    metadata.availableMethods.isEmpty ||
    metadata.availableMethods.contains(method);

void main() {
  // 结构对齐「惜梦 CIT」单平台包：manifest + 命名空间 handlers，
  // 脚本内不出现任何 MusicFree 扁平方法名。
  const citScript = r'''
const CFG = { plat: 'kg', api: 'https://anime.xisb.cn/v2/index.php', key: 'cit' };

var manifest = {
  apiVersion: 2,
  providerId: 'cn.cit.kg',
  name: 'CIT 酷狗',
  platform: '酷狗音乐',
  version: '2.0.0',
  capabilities: [
    'search',
    'entities.get',
    'collections.get',
    'collections.members',
    'discovery.charts',
    'discovery.hotSearch',
    'discovery.playlists',
    'discovery.searchSuggestions',
    'media.resolve',
    'lyrics.get',
    'comments.list',
    'links.share',
  ],
};

var handlers = {
  search: async function (sdk, request) { return { items: [] }; },
  'entities.get': async function (sdk, request) { return {}; },
  'collections.get': async function (sdk, request) { return {}; },
  'collections.members': async function (sdk, request) { return { items: [] }; },
  'discovery.charts': async function (sdk, request) { return { items: [] }; },
  'media.resolve': async function (sdk, request) { return { url: '' }; },
  'lyrics.get': async function (sdk, request) { return { format: 'lrc', text: '' }; },
  'comments.list': async function (sdk, request) { return { items: [] }; },
};

function createProvider(sdk, request) {
  return { manifest: manifest, handlers: handlers };
}

module.exports = { manifest: manifest, handlers: handlers, createProvider: createProvider };
''';

  test('v2 插件按 capabilities 反查 MusicFree 方法名', () {
    final metadata = PluginMetadata.parse(citScript);

    expect(metadata.isBakaV2, isTrue);
    expect(metadata.capabilities, contains('lyrics.get'));

    // 歌词：这是本次修复的直接目标，门控必须放行。
    final lyricGate = PluginMetadata.lyricMethodNames.any(
      (method) => may(metadata, method),
    );
    expect(lyricGate, isTrue, reason: 'v2 声明 lyrics.get 时不得被歌词门控拦截');
    expect(may(metadata, 'getLyric'), isTrue);

    // 榜单 / 歌单详情 / 评论 / 播放地址 / 搜索
    expect(may(metadata, 'getTopLists'), isTrue);
    expect(may(metadata, 'getTopListDetail'), isTrue);
    expect(may(metadata, 'getAlbumInfo'), isTrue);
    expect(may(metadata, 'getArtistWorks'), isTrue);
    expect(may(metadata, 'getMusicComments'), isTrue);
    expect(may(metadata, 'getMediaSource'), isTrue);
    expect(may(metadata, 'getMusicInfo'), isTrue);
    expect(may(metadata, 'search'), isTrue);

    // 未声明媒体视频能力，不应被放行（否则运行时调用必抛错）
    expect(may(metadata, 'getMvSource'), isFalse);
  });

  test('v2 声明空 capabilities 时不门控（保持尝试调用并靠异常兜底）', () {
    const script = r'''
var manifest = {
  apiVersion: 2,
  providerId: 'cn.demo',
  name: '无能力声明',
  capabilities: [],
};
var handlers = { search: async function () { return { items: [] }; } };
module.exports = { manifest: manifest, handlers: handlers };
''';
    final metadata = PluginMetadata.parse(script);
    expect(metadata.isBakaV2, isTrue);
    expect(metadata.capabilities, isEmpty);
    // 空集合语义 = 不做门控
    expect(metadata.availableMethods, isEmpty);
    expect(may(metadata, 'getLyric'), isTrue);
  });

  test('静态扫描结果与能力反查取并集，不丢原有方法', () {
    const script = r'''
var manifest = {
  apiVersion: 2,
  providerId: 'cn.union',
  name: '并集测试',
  capabilities: ['search', 'lyrics.get'],
};
module.exports = {
  manifest: manifest,
  handlers: {
    search: async function () { return { items: [] }; },
    'lyrics.get': async function () { return { text: '' }; },
  },
  getMvSource: async function () { return {}; },
};
''';
    final metadata = PluginMetadata.parse(script);
    expect(metadata.isBakaV2, isTrue);
    // 静态扫描到的扁平方法
    expect(may(metadata, 'getMvSource'), isTrue);
    // 能力反查出的方法
    expect(may(metadata, 'getLyric'), isTrue);
    expect(may(metadata, 'search'), isTrue);
    // 两边都没声明的不放行
    expect(may(metadata, 'getMusicComments'), isFalse);
  });

  test('非 v2 插件不受影响：仍只认静态扫描结果', () {
    const script = r'''
module.exports = {
  platform: '测试音源',
  version: '1.0',
  search: async () => ({ data: [] }),
  getMediaSource: async () => ({}),
};
''';
    final metadata = PluginMetadata.parse(script);
    expect(metadata.isBakaV2, isFalse);
    expect(metadata.availableMethods, containsAll(['search', 'getMediaSource']));
    expect(may(metadata, 'getLyric'), isFalse);
  });
}
