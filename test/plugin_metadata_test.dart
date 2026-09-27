import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/plugins/plugin_metadata.dart';

void main() {
  test('MusicFree 名称读取最终 module.exports 而不是歌曲字段', () {
    const script = r'''
const VERSION = "7";
const IS_PAID = "(赞助版)[永久]";
function formatSong(item) {
  return { id: "错误ID", name: "错误歌曲名", version: "9108" };
}
module.exports = {
  platform: "网易云音乐" + (IS_PAID ? IS_PAID : ""),
  author: "测试作者",
  version: VERSION,
  search: async () => ({ data: [] }),
};
''';

    final metadata = PluginMetadata.parse(script);
    expect(metadata.id, isNull);
    expect(metadata.name, '网易云音乐(赞助版)[永久]');
    expect(metadata.version, '7');
    expect(metadata.author, '测试作者');
  });

  test('LX 注释头优先作为插件元数据', () {
    const script = r'''
/**
 * @id lx-demo
 * @name 测试 LX 音源
 * @version 1.2.3
 * @author 测试作者
 */
const source = {};
''';

    final metadata = PluginMetadata.parse(script);
    expect(metadata.id, 'lx-demo');
    expect(metadata.name, '测试 LX 音源');
    expect(metadata.version, '1.2.3');
    expect(metadata.author, '测试作者');
  });

  test('解析插件声明的 userVariables', () {
    const script = r'''
const TOKEN_HINT = "用于访问 API 的令牌";
module.exports = {
  platform: "示例音乐",
  userVariables: [
    { key: "token", name: "Access Token", hint: TOKEN_HINT },
    { key: "uid", hint: "用户 ID（可选）" },
  ],
  search: async () => ({ data: [] }),
};
''';

    final metadata = PluginMetadata.parse(script);
    expect(metadata.userVariables.length, 2);
    expect(metadata.userVariables[0].key, 'token');
    expect(metadata.userVariables[0].name, 'Access Token');
    expect(metadata.userVariables[0].hint, '用于访问 API 的令牌');
    expect(metadata.userVariables[0].displayName, 'Access Token');
    expect(metadata.userVariables[1].key, 'uid');
    expect(metadata.userVariables[1].displayName, 'uid');
  });

  test('userVariables 含括号字符串时不破坏解析', () {
    const script = r'''
module.exports = {
  platform: "示例音乐",
  userVariables: [
    { key: "cookie", name: "Cookie [完整]", hint: "形如 a=1; b=[2]" },
  ],
  search: async () => ({ data: [] }),
};
''';

    final metadata = PluginMetadata.parse(script);
    expect(metadata.userVariables.length, 1);
    expect(metadata.userVariables[0].key, 'cookie');
    expect(metadata.userVariables[0].name, 'Cookie [完整]');
  });

  test('未声明 userVariables 时为空列表', () {
    final metadata = PluginMetadata.parse(
      'module.exports = { platform: "x" };',
    );
    expect(metadata.userVariables, isEmpty);
  });

  test('星海格式识别：primaryKey 带 _src 聚合来源标记', () {
    const script = r'''
module.exports = {
  platform: "animemusic聚合",
  primaryKey: ["id", "_src"],
  search: async () => ({ data: [{ id: "1", _src: "wy" }] }),
};
''';
    expect(PluginMetadata.parse(script).isStarSea, isTrue);
  });

  test('星海格式识别：普通 MusicFree 插件不误报', () {
    const script = r'''
module.exports = {
  platform: "示例音乐",
  primaryKey: ["id"],
  search: async () => ({ data: [{ id: "1" }] }),
};
''';
    expect(PluginMetadata.parse(script).isStarSea, isFalse);
  });

  test('插件分类识别：baka/animemusic/lx/musicfree 四类标记', () {
    // BakaMusic 契约：getMvSource 方法与 animeSrc 来源标记。
    const baka = '''
const FALLBACK_BASE = "https://animemusic.bzxhkj.com";
module.exports = {
  platform: "animemusic",
  async getMvSource(musicItem, quality) { return null; },
  async search() { return { data: [{ id: "1", animeSrc: "wy" }] }; },
};
''';
    final bakaMeta = PluginMetadata.parse(baka);
    expect(bakaMeta.isBaka, isTrue);
    expect(bakaMeta.isAnimemusic, isTrue); // 域名命中，分类时 baka 优先

    // animemusic 后端（v3/v4）：域名命中、无 Baka 标记。
    const am = '''
const API_URL = "https://animemusic.bzxhkj.com/v1/index.php";
module.exports = { platform: "musicfree-animemusic" };
''';
    final amMeta = PluginMetadata.parse(am);
    expect(amMeta.isBaka, isFalse);
    expect(amMeta.isAnimemusic, isTrue);

    // LX 契约（v2 洛雪版）：isLx 命中，同样含 animemusic 域名但归 LX。
    const lx = '''
const API_URL = "https://animemusic.bzxhkj.com/v1/index.php";
const { request, on } = globalThis.lx;
''';
    final lxMeta = PluginMetadata.parse(lx);
    expect(lxMeta.isLx, isTrue);
    expect(lxMeta.isAnimemusic, isTrue);

    // 标准 MusicFree：均不命中。
    const mf = '''
module.exports = { platform: "示例音乐" };
''';
    final mfMeta = PluginMetadata.parse(mf);
    expect(mfMeta.isLx, isFalse);
    expect(mfMeta.isBaka, isFalse);
    expect(mfMeta.isAnimemusic, isFalse);
  });

  test('插件 ID 归一化：惜梦 v4 与 baka 不再折叠成同一 ID', () {
    // 回归：剥离中文会让「animemusic聚合」与「animemusic」都归一化成
    // animemusic，批量安装时互相覆盖（提示装了 6 个、列表只剩 3 个）。
    final v4 = PluginMetadata.normalizePluginId('animemusic聚合');
    final baka = PluginMetadata.normalizePluginId('animemusic');
    expect(v4, 'animemusic聚合');
    expect(baka, 'animemusic');
    expect(v4, isNot(baka));
  });

  test('插件 ID 归一化：常规名字与纯中文名', () {
    expect(PluginMetadata.normalizePluginId('lx-animemusic'), 'lx-animemusic');
    expect(PluginMetadata.normalizePluginId('MusicFree-Animemusic'),
        'musicfree-animemusic');
    // 纯中文名保留（此前会被剥空并回退到内容哈希）。
    expect(PluginMetadata.normalizePluginId('示例音乐'), '示例音乐');
    // 空格与全角符号折叠为连字符，首尾剥除。
    expect(PluginMetadata.normalizePluginId(' My Plugin '), 'my-plugin');
    // 全部为非法字符时归一化为空，由调用方回退到内容哈希。
    expect(PluginMetadata.normalizePluginId('（（））'), isEmpty);
  });
}
