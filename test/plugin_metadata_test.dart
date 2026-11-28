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

  test('module.exports 导出变量（改造器插件）时从声明对象解析元数据', () {
    const script = r'''
const IMPORTED_BASE_URL = "https://example.com/api";
async function search(query, page, type) {
  return { isEnd: true, data: [] };
}
const MF_PLUGIN = {
  platform: 'QQ音乐',
  version: '插件改造器 · 1.0',
  author: '橘子出品',
  description: '搜索走 QQ 官方；播放走第三方 API',
  primaryKey: ['id', 'songmid'],
  userVariables: [{ key: 'key', name: 'API Key', hint: '已内置' }],
  search,
  getMediaSource: async () => ({}),
};
module.exports = MF_PLUGIN;

// 对象之后的示例歌曲/文档片段不得污染 id/name 字段
const DEFAULT_SONG = {
  id: 'qq_0039MnYb0qxYhV',
  title: '示例歌曲',
};
''';

    final metadata = PluginMetadata.parse(script);
    expect(metadata.id, isNull);
    expect(metadata.name, 'QQ音乐');
    expect(metadata.version, '插件改造器 · 1.0');
    expect(metadata.author, '橘子出品');
    expect(metadata.userVariables.length, 1);
    expect(metadata.userVariables[0].key, 'key');
    final id = PluginMetadata.resolvePluginId(
      script,
      '/data/user/0/cache/file_picker/QQ音乐(迟言API)(6).js',
    );
    expect(id, 'qq音乐');
  });

  test('描述性 version 不参与版本数值比较（避免安装被静默跳过）', () {
    // 改造器插件常把 version 写成说明文案；compareVersions 会把它折算成
    // 0.0.0，若不排除就会永远判为比已装的数字版本插件旧，安装提示
    // 「成功 0 个、跳过 1 个」。
    const descriptive = '插件改造器 · 猫头猫 · 迟言';
    expect(PluginMetadata.isComparableVersion(descriptive), isFalse);
    expect(PluginMetadata.isComparableVersion(''), isFalse);
    expect(PluginMetadata.isComparableVersion('1.0.0'), isTrue);
    expect(PluginMetadata.isComparableVersion('2-beta3'), isTrue);
    // 说明为何要排除：描述性版本会被折算为 0.0.0，比 1.0.0 旧。
    expect(PluginMetadata.compareVersions(descriptive, '1.0.0') < 0, isTrue);
  });

  test('元数据缺失时文件名回退 ID 解码百分号编码路径', () {
    const script = r'''
async function search(query, page, type) {
  return { isEnd: true, data: [] };
}
module.exports = { search };
''';
    final id = PluginMetadata.resolvePluginId(
      script,
      '/data/user/0/cache/file_picker/QQ音乐(迟言API)(6).js',
    );
    expect(id, 'qq音乐-迟言api-6');
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

  test('订阅源 X-API-KEY 变量被彻底剔除（含各种写法）', () {
    const script = r'''
module.exports = {
  platform: "网易云音乐[T]",
  userVariables: [
    { key: "wy_user_id", name: "网易云连接码", hint: "在 /connect 选择登录" },
    { key: "SOURCE_API_KEY", name: "X-API-KEY", hint: "用于本站取链" },
    { key: "source_api_key", name: "重复写法", hint: "" },
    { key: "sourceApiKey", name: "Source API Key", hint: "驼峰写法" },
    { key: "X-API-KEY", name: "X-API-KEY", hint: "把显示名当键" },
    { key: "SOURCE_API_URL", name: "取链接口（可选）", hint: "留空跟随" },
  ],
  search: async () => ({ data: [] }),
};
''';

    final metadata = PluginMetadata.parse(script);
    expect(
      metadata.userVariables.map((v) => v.key).toList(),
      ['wy_user_id', 'SOURCE_API_URL'],
    );
    expect(
      metadata.userVariables.any(
        (v) => isPluginRetiredUserVariable(v.key),
      ),
      isFalse,
    );
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

  test('插件分类识别：bakaV2/animemusic/lx/musicfree 四类标记', () {
    // BakaMusic v2 契约（V1 已下线）：manifest 声明 apiVersion 2 与 capabilities。
    const bakaV2 = '''
const FALLBACK_BASE = "https://animemusic.bzxhkj.com";
module.exports = {
  manifest: {
    id: "cn.demo.am",
    name: "animemusic v2",
    platform: "animemusic",
    version: "2.0.0",
    author: "demo",
    apiVersion: 2,
    capabilities: ["search", "media.video"],
  },
  handlers: {},
};
function createProvider(sdk) { return { search: () => ({}) }; }
''';
    final bakaV2Meta = PluginMetadata.parse(bakaV2);
    expect(bakaV2Meta.isBakaV2, isTrue);
    expect(bakaV2Meta.isAnimemusic, isTrue); // 域名命中，分类时 v2 优先
    expect(bakaV2Meta.contract, PluginContract.bakaV2);

    // animemusic 后端（v3/v4）：域名命中、无 v2 标记。
    const am = '''
const API_URL = "https://animemusic.bzxhkj.com/v1/index.php";
module.exports = { platform: "musicfree-animemusic" };
''';
    final amMeta = PluginMetadata.parse(am);
    expect(amMeta.isBakaV2, isFalse);
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
    expect(mfMeta.isBakaV2, isFalse);
    expect(mfMeta.isAnimemusic, isFalse);
  });

  test('订阅源域名不再参与分类：MusicFree 契约不被 Baka 订阅源提升', () {
    // BakaMusic V1 下线后，来源 URL 白名单（shiqianjiang.cn / cwo.cc.cd 等）
    // 已从分类链路移除：分栏只由脚本契约决定，URL 不再作为判定依据。
    expect(
      resolvePluginKindKey(contract: PluginContract.musicfree),
      'musicfree',
    );
    expect(
      resolvePluginKindKey(
        contract: PluginContract.musicfree,
        kindHint: 'baka',
      ),
      'musicfree',
    );
  });

  test('platform 经配置表与数字常量间接取值时仍能解析名称', () {
    String script(int level) =>
        '''
const QQ_SOURCE_LEVEL = $level;
const qqSourceProfiles = {
  1: {
    platform: "QQ音乐[L1]",
  },
  2: {
    platform: "QQ音乐[L2]",
  },
};
const qqSourceProfile = qqSourceProfiles[QQ_SOURCE_LEVEL];
module.exports = {
  platform: qqSourceProfile.platform,
  author: "Toskysun",
  version: "1.2.4",
  search: async () => ({ data: [] }),
};
''';

    // 服务器按已鉴权地址注入不同 level：显示名应随配置表取值，
    // 而不是因无法求值回退成 URL 文件名（qq-l1 / qq-l2）。
    expect(PluginMetadata.parse(script(1)).name, 'QQ音乐[L1]');
    expect(PluginMetadata.parse(script(2)).name, 'QQ音乐[L2]');
    expect(PluginMetadata.parse(script(1)).author, 'Toskysun');
    expect(PluginMetadata.parse(script(1)).version, '1.2.4');
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

  test('v2 manifest：显示名取 name，platform 仅作平台标识', () {
    // 与订阅源 qq-l1.js 同构：manifest 内 platform 是「QQ音乐[H]」（音质/接口
    // 变体），name 才是「QQ音乐[T]」。同时含 appVersion，版本号不能被它顶替。
    const script = r'''
const SOURCE_API_KEY = "3ccnt-secret";
module.exports = {
  manifest: {
    platform: "QQ音乐[H]",
    author: "Toskysun",
    hints: {"importMusicSheet": ["复制链接并粘贴即可"]},
    apiVersion: 2,
    id: "org.lyramesh.qq.l1",
    name: "QQ音乐[T]",
    version: "2.0.1",
    appVersion: ">0.1.0-alpha.0",
    capabilities: ["search", "entities.get", "media.resolve"],
    userVariables: [
      {"key": "qq_user_id", "name": "用户 ID", "hint": "在 /connect 扫码"},
      {"key": "SOURCE_API_KEY", "name": "X-API-KEY", "hint": "取链密钥"},
      {"key": "SOURCE_API_URL", "name": "接口地址(可选)", "hint": "留空跟随"}
    ]
  },
  handlers: {},
};
function createProvider(sdk, request = {}) {
  return { search: () => ({}) };
}
''';

    final metadata = PluginMetadata.parse(script);
    expect(metadata.name, 'QQ音乐[T]');
    expect(metadata.platform, 'QQ音乐[H]');
    // 版本号不能被 apiVersion / appVersion 抢占（此前解析成 2 和 >0.1.0-alpha.0）。
    expect(metadata.version, '2.0.1');
    expect(metadata.apiVersion, 2);
    expect(metadata.providerId, 'org.lyramesh.qq.l1');
    expect(metadata.id, 'org.lyramesh.qq.l1');
    expect(metadata.author, 'Toskysun');
    expect(metadata.isBakaV2, isTrue);
    expect(
      metadata.capabilities,
      ['search', 'entities.get', 'media.resolve'],
    );
    // 变量键是纯字面量时不得拼接同名常量（否则键变成 SOURCE_API_KEY3ccnt-secret，
    // 停用过滤失配，X-API-KEY 又会冒出来）。
    expect(
      metadata.userVariables.map((v) => v.key).toList(),
      ['qq_user_id', 'SOURCE_API_URL'],
    );
  });

  test('v2 manifest：JSON 风格键与 userVariables 也能解析', () {
    const script = r'''
const manifest = {
  "platform": "酷狗音乐[T]",
  "author": "Toskysun",
  "appVersion": ">0.1.0-alpha.0",
  "apiVersion": 2,
  "id": "org.lyramesh.kg",
  "name": "酷狗音乐[T]",
  "version": "3.0.1",
  "userVariables": [
    {"key": "kg_user_id", "name": "用户 ID", "hint": "复制连接码"},
    {"key": "SOURCE_API_KEY", "name": "X-API-KEY", "hint": "取链"},
    {"key": "SOURCE_API_URL", "name": "取链接口（可选）", "hint": "留空跟随"}
  ],
  "capabilities": ["search", "media.resolve"]
};
function createProvider(sdk) { return {}; }
''';

    final metadata = PluginMetadata.parse(script);
    // 键带引号时 userVariables 不能再整体漏掉（酷狗/酷我原本解析为空列表）。
    expect(
      metadata.userVariables.map((v) => v.key).toList(),
      ['kg_user_id', 'SOURCE_API_URL'],
    );
    expect(metadata.name, '酷狗音乐[T]');
    expect(metadata.version, '3.0.1');
    expect(metadata.providerId, 'org.lyramesh.kg');
    expect(metadata.apiVersion, 2);
  });

  test('v2 manifest：providerId 写法同样可取稳定标识', () {
    const script = r'''
module.exports = {
  manifest: {
    providerId: "org.lyramesh.joox",
    name: "JOOX",
    platform: "JOOX",
    version: "4.0.1",
    author: "Toskysun",
    apiVersion: 2,
    capabilities: ["search"]
  },
  handlers: {},
};
function createProvider(sdk) { return {}; }
''';

    final metadata = PluginMetadata.parse(script);
    expect(metadata.providerId, 'org.lyramesh.joox');
    expect(metadata.id, 'org.lyramesh.joox');
    expect(metadata.name, 'JOOX');
    expect(metadata.platform, 'JOOX');
  });

  test('停用变量键按前缀判定：常量拼接残留也不复活', () {
    expect(isPluginRetiredUserVariable('SOURCE_API_KEY'), isTrue);
    expect(isPluginRetiredUserVariable('sourceApiKey'), isTrue);
    expect(isPluginRetiredUserVariable('SOURCE_API_KEY3ccnt-secret'), isTrue);
    // 相邻但未被停用的键必须保留。
    expect(isPluginRetiredUserVariable('SOURCE_API_URL'), isFalse);
    expect(isPluginRetiredUserVariable('qq_user_id'), isFalse);
  });

  test('插件契约：kindKey/label 映射与判定优先级', () {
    // kindKey 是分栏/分组共用的分类标识；baka 分栏只承载 v2 契约。
    expect(PluginContract.lx.kindKey, 'lx');
    expect(PluginContract.bakaV2.kindKey, 'baka');
    expect(PluginContract.animemusic.kindKey, 'animemusic');
    expect(PluginContract.musicfree.kindKey, 'musicfree');
    expect(PluginContract.lx.label, 'LX');
    expect(PluginContract.bakaV2.label, 'BakaMusic v2');
    expect(PluginContract.animemusic.label, '惜梦');
    expect(PluginContract.musicfree.label, 'MusicFree');

    // 优先级：lx > bakaV2 > animemusic > musicfree。
    expect(
      pluginContractOf(
        isLx: true,
        isBakaV2: true,
        isAnimemusic: true,
      ),
      PluginContract.lx,
    );
    expect(
      pluginContractOf(
        isLx: false,
        isBakaV2: true,
        isAnimemusic: false,
      ),
      PluginContract.bakaV2,
    );
    expect(
      pluginContractOf(
        isLx: false,
        isBakaV2: false,
        isAnimemusic: true,
      ),
      PluginContract.animemusic,
    );
    expect(
      pluginContractOf(
        isLx: false,
        isBakaV2: false,
        isAnimemusic: false,
      ),
      PluginContract.musicfree,
    );
  });

  test('分类统一入口：契约优先，提示仅保留「其他」覆盖', () {
    // 契约明确的类目不受分栏提示影响（避免粘贴到 BakaMusic 分栏就变 baka）。
    expect(
      resolvePluginKindKey(contract: PluginContract.lx, kindHint: 'baka'),
      'lx',
    );
    expect(
      resolvePluginKindKey(contract: PluginContract.animemusic, kindHint: 'baka'),
      'animemusic',
    );
    // BakaMusic v2 契约不会被 musicfree 提示压回。
    expect(
      resolvePluginKindKey(contract: PluginContract.bakaV2, kindHint: 'musicfree'),
      'baka',
    );
    expect(
      resolvePluginKindKey(contract: PluginContract.bakaV2, kindHint: 'baka'),
      'baka',
    );
    // MusicFree 契约不会因 baka 分栏提示被提升（提示与来源 URL 均不参与分类）。
    expect(
      resolvePluginKindKey(
        contract: PluginContract.musicfree,
        kindHint: 'baka',
      ),
      'musicfree',
    );
    // 用户手动归入「其他」优先级最高。
    expect(
      resolvePluginKindKey(contract: PluginContract.bakaV2, kindHint: 'other'),
      'other',
    );
    expect(
      resolvePluginKindKey(contract: PluginContract.musicfree),
      'musicfree',
    );
  });

  test('分类判定不读插件显示名/作者名', () {
    const script = r'''
module.exports = {
  platform: "baka 音乐聚合",
  author: "baka作者",
  version: "2.0.0",
  search: async () => ({ data: [] }),
  getTopLists: async () => ({ data: [] }),
  getTopListDetail: async () => ({ data: [] }),
};
''';
    final metadata = PluginMetadata.parse(script);
    // 名称/作者含 baka，但脚本内容是普通 MusicFree 契约 → 仍归 MusicFree。
    expect(metadata.isBakaV2, isFalse);
    expect(metadata.contract, PluginContract.musicfree);
    expect(resolvePluginKindKey(contract: metadata.contract), 'musicfree');
  });
}
