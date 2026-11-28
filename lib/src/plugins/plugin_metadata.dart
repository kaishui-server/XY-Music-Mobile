import 'dart:convert';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

/// 插件声明的用户变量（userVariables）。插件在脚本中声明变量键名、
/// 显示名和提示文案，由宿主提供编辑界面并把用户填写的值注入 env。
class PluginUserVariable {
  const PluginUserVariable({required this.key, this.name, this.hint});

  final String key;
  final String? name;
  final String? hint;

  /// 展示名，缺省时回退为键名。
  String get displayName =>
      name?.trim().isNotEmpty == true ? name!.trim() : key;
}

/// 已停用的插件用户变量键（归一化后：全小写、去掉非字母数字字符）。
///
/// 订阅源（mc.vsaa.cn）下发的 Baka 音源插件历史声明过 `SOURCE_API_KEY`
/// 变量（显示名 X-API-KEY）。密钥在安装时已随订阅链接写进脚本自带的
/// 常量（脚本内 `const SOURCE_API_KEY = '...'`），这一栏只是多余地把
/// 密钥再暴露成可编辑输入框。此前仅在弹窗展示层隐藏、已保存的值仍继续
/// 保留并注入，现改为**彻底移除**：解析阶段即剔除，不进元数据、不进
/// 元数据缓存、不写入持久化、也不注入插件运行时环境。
const pluginRetiredUserVariableKeys = {'sourceapikey', 'xapikey'};

String _normalizeUserVariableKey(String rawKey) =>
    rawKey.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// 该变量键是否已被停用（兼容 `SOURCE_API_KEY` / `source_api_key` /
/// `sourceApiKey` / `X-API-KEY` / `x-api-key` 等各种写法）。
///
/// 除了精确匹配，还按**前缀**判定：解析脚本时若键表达式被常量拼接污染
/// （如 `SOURCE_API_KEY3ccnt...`），精确匹配会漏掉，停用变量就会重新
/// 出现在设置页。停用键全部是 API Key 类，前缀命中即可判定为同一条。
bool isPluginRetiredUserVariable(String rawKey) {
  final normalized = _normalizeUserVariableKey(rawKey);
  if (normalized.isEmpty) return false;
  for (final retired in pluginRetiredUserVariableKeys) {
    if (normalized == retired || normalized.startsWith(retired)) return true;
  }
  return false;
}

/// 插件**契约**类型：完全由脚本内容（契约标记/导出结构）判定，不依赖
/// 插件显示名、备注或作者名。
///
/// - [lx]：洛雪 `globalThis.lx` 契约；
/// - [bakaV2]：Baka provider v2 —— `module.exports = {manifest, handlers}`
///   嵌套 handler 表，manifest 声明 `apiVersion: 2` 与 `capabilities`
///   （旧 BakaMusic V1 契约已移除，不再作为独立契约识别）；
/// - [animemusic]：惜梦 animemusic 后端插件；
/// - [musicfree]：标准 MusicFree `module.exports` 契约。
enum PluginContract {
  lx,
  bakaV2,
  animemusic,
  musicfree;

  /// 分栏归属标识（取值与 plugin_runtime.dart 的 `pluginKind*` 常量一致）。
  /// BakaMusic 分栏只承载 v2 契约插件。
  String get kindKey => switch (this) {
    PluginContract.lx => 'lx',
    PluginContract.bakaV2 => 'baka',
    PluginContract.animemusic => 'animemusic',
    PluginContract.musicfree => 'musicfree',
  };

  /// 格式标签（插件管理页展示，与分栏归属同源，避免两处口径不一）。
  String get label => switch (this) {
    PluginContract.lx => 'LX',
    PluginContract.bakaV2 => 'BakaMusic v2',
    PluginContract.animemusic => '惜梦',
    PluginContract.musicfree => 'MusicFree',
  };
}

/// 由三个内容标记还原契约（缓存/跨 isolate 传输后只剩布尔标记时使用）。
///
/// v2 优先：v2 的 manifest 与 MusicFree 不同构，运行时路由必须走专用
/// 适配层，不能被其他标记抢先。
PluginContract pluginContractOf({
  required bool isLx,
  required bool isBakaV2,
  required bool isAnimemusic,
}) {
  if (isLx) return PluginContract.lx;
  if (isBakaV2) return PluginContract.bakaV2;
  if (isAnimemusic) return PluginContract.animemusic;
  return PluginContract.musicfree;
}

class PluginMetadata {
  const PluginMetadata({
    this.id,
    this.name,
    this.version,
    this.author,
    this.remark,
    this.userVariables = const [],
    this.isStarSea = false,
    this.isLx = false,
    this.isBakaV2 = false,
    this.isAnimemusic = false,
    this.apiVersion = 0,
    this.providerId,
    this.platform,
    this.capabilities = const [],
    this.availableMethods = const [],
  });

  final String? id;
  final String? name;
  final String? version;
  final String? author;

  /// 插件备注/描述。不同插件可能使用 description、desc 或 remark。
  final String? remark;

  /// 插件声明的用户变量列表；未声明时为空。
  final List<PluginUserVariable> userVariables;

  /// 是否为星海格式插件：MusicFree 兼容的聚合变体（如惜梦
  /// animemusic 聚合 v4），歌曲带 _src/_source 来源标记，一次搜索
  /// 聚合多平台结果。
  final bool isStarSea;

  /// LX（洛雪）插件：走 globalThis.lx 契约而非 MusicFree
  /// module.exports。规则与 plugin_runtime 的 _looksLikeLxPlugin 一致。
  final bool isLx;

  /// Baka provider **v2** 插件：脚本带 `@baka-provider 2` 标记，或 manifest
  /// 同时声明 `apiVersion: 2` 与 `capabilities`（见 [_detectBakaV2]）。v2 的
  /// manifest 是 `{manifest, handlers}` 嵌套 handler 表，与 MusicFree 的扁平
  /// `module.exports` 不同构，运行时必须走专用适配层。
  final bool isBakaV2;

  /// animemusic 后端插件：直连 animemusic.bzxhkj.com（惜梦 v3/v4、
  /// animemusic/1 新格式等）。分类时 isLx / isBakaV2 优先级更高。
  final bool isAnimemusic;

  /// 插件自述的契约版本（v2 插件为 `manifest.apiVersion`，其余为 0）。
  final int apiVersion;

  /// provider 唯一标识（v2 插件为 `manifest.id`，如 `org.lyramesh.qq.l1`）。
  final String? providerId;

  /// 插件声明的平台标识（v2 为 `manifest.platform`，如 `QQ音乐[H]`）。
  /// **仅作平台标识**使用，不能当作显示名——v2 的显示名以
  /// `manifest.name`（如「QQ音乐[T]」）为准。
  final String? platform;

  /// v2 manifest 声明的能力枚举（`search` / `media.resolve` /
  /// `lyrics.get` / `comments.list` / `collections.members` 等）。
  final List<String> capabilities;

  /// 插件契约（内容判定结果，分类与运行时路由的唯一依据）。
  PluginContract get contract {
    if (isLx) return PluginContract.lx;
    if (isBakaV2) return PluginContract.bakaV2;
    if (isAnimemusic) return PluginContract.animemusic;
    return PluginContract.musicfree;
  }

  /// 是否声明了某项 v2 能力（非 v2 插件恒为 false）。
  bool hasCapability(String capability) =>
      isBakaV2 && capabilities.contains(capability);

  /// 静态扫描出的 MusicFree 契约方法名（不执行脚本）。参照 XianYu 的
  /// `_availableMethods`：未适配/精简插件只实现 search + getMediaSource，
  /// 宿主调用其未实现的可选方法会抛错；据此在调用前判断方法是否存在，
  /// 缺失时直接走回退链。压缩/混淆插件扫不出结果时为空集合，调用方
  /// 据此不做门控（保持原来的「尝试调用并靠异常兜底」行为）。
  final List<String> availableMethods;

  static PluginMetadata parse(String script) {
    final constants = _parseStringConstants(script);
    final bindings = _parseBindings(script);
    final header = _parseHeader(script);
    final exported = _parseExportedObject(script, constants, bindings);
    final json = _parseJsonObject(script);
    final constMeta = _parseConstMeta(script);
    final manifest = _parseProviderManifest(script);
    final isBakaV2 = _detectBakaV2(script, manifest);
    final author = _clean(
      manifest['author'] ??
          header['author'] ??
          exported['author'] ??
          json['author'] ??
          constMeta['author'],
    );
    final capabilities = _parseProviderCapabilities(script);
    final methods = _bakaV2Methods(
      isBakaV2: isBakaV2,
      capabilities: capabilities,
      staticMethods: _parseExportedMethods(script),
    );

    return PluginMetadata(
      id: _clean(
        // manifest 只写 providerId 时，插件 ID 也应取它，否则会回退到显示名
        // 归一化，同平台不同变体（qq.l1 / qq.l2）会互相覆盖。
        manifest['id'] ??
            manifest['providerId'] ??
            header['id'] ??
            exported['id'] ??
            json['id'],
      ),
      // v2 的显示名以 manifest.name 为准（「QQ音乐[T]」），platform 只是
      // 平台标识（「QQ音乐[H]」，带音质/接口变体后缀），不能顶替显示名；
      // MusicFree 用 platform 作为插件显示名；LX 常用 @name。
      name: _clean(
        manifest['name'] ??
            header['name'] ??
            exported['platform'] ??
            exported['name'] ??
            json['platform'] ??
            json['name'] ??
            constMeta['name'],
      ),
      version: _clean(
        manifest['version'] ??
            header['version'] ??
            exported['version'] ??
            json['version'] ??
            constMeta['version'],
      ),
      author: author,
      remark: _clean(
        header['description'] ??
            header['desc'] ??
            header['remark'] ??
            exported['description'] ??
            exported['desc'] ??
            exported['remark'] ??
            json['description'] ??
            json['desc'] ??
            json['remark'],
      ),
      userVariables: _parseUserVariables(script, constants),
      isStarSea: _detectStarSea(script),
      isLx: _detectLx(script),
      isBakaV2: isBakaV2,
      isAnimemusic: _detectAnimemusic(script),
      apiVersion: int.tryParse((manifest['apiVersion'] ?? '').trim()) ?? 0,
      providerId: _clean(manifest['providerId'] ?? manifest['id']),
      // platform 只作平台标识（可含音质/接口变体后缀，如「QQ音乐[H]」），
      // 不参与显示名，也不参与分类判定。
      platform: _clean(
        manifest['platform'] ?? exported['platform'] ?? json['platform'],
      ),
      capabilities: capabilities,
      availableMethods: methods,
    );
  }

  /// 插件 ID 归一化：转小写，把字母数字/中文/下划线/连字符以外的字符
  /// 折叠为 '-'，再剥掉首尾 '-'。保留中文字符——剥离中文会让
  /// 「animemusic聚合」与「animemusic」折叠成同一个 ID，批量安装时
  /// 互相覆盖（提示装了 6 个、列表只剩 3 个）。归一化结果为空时由
  /// 调用方回退到内容哈希。
  static String normalizePluginId(String rawId) {
    return rawId
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_\-\u3400-\u4dbf\u4e00-\u9fff]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
  }

  /// 由脚本内容与安装来源推断插件 ID（安装、更新、备份恢复、去重
  /// 共用同一套规则，避免同一插件在不同入口算出不同 ID）：
  /// metadata.id → metadata.name（MusicFree 的 platform）→ 来源 URL
  /// 文件名，归一化后作为稳定 ID；归一化为空（纯符号名）时回退到
  /// 内容哈希 plugin-xxxxxxxx。订阅插件更新后 name 变化（如加上了
  /// 「(赞助版)[永久]」后缀）会导致 ID 漂移，调用方需迁移旧 ID 引用
  /// （见 plugin_reference_migration.dart）。
  static String resolvePluginId(String script, String origin) =>
      resolvePluginIdFromMetadata(parse(script), origin);

  /// 与 [resolvePluginId] 同规则，但复用已解析好的元数据，避免批量安装时
  /// 对同一段脚本重复执行整套正则解析（脚本可达数百 KB，重复解析是批量
  /// 导入卡顿的主要来源）。
  static String resolvePluginIdFromMetadata(
    PluginMetadata metadata,
    String origin,
  ) {
    // file_picker/下载管理器给的来源路径常带中文，Uri.path 会以百分号
    // 编码返回（QQ音乐 → %E9%9F%B3%E4%B9%90），不解码会让回退 ID 变成
    // qq-e9-9f-b3 这类 UTF-8 字节十六进制串。
    final uri = Uri.tryParse(origin);
    final uriPath = uri == null ? '' : _decodeUriPath(uri.path);
    final rawName =
        metadata.name ??
        p.basenameWithoutExtension(uriPath.isNotEmpty ? uriPath : origin);
    final rawId = metadata.id ?? rawName;
    final normalized = normalizePluginId(rawId);
    return normalized.isNotEmpty
        ? normalized
        : 'plugin-${_fnv1a(rawId).toRadixString(16)}';
  }

  /// 插件版本号比较（按 `.` `-` 分段做数字比较，段缺失按 0）。
  /// 返回正数表示 [left] 更新、0 表示相同、负数表示更旧。
  static int compareVersions(String left, String right) {
    final a = left.split(RegExp(r'[.-]'));
    final b = right.split(RegExp(r'[.-]'));
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final av = i < a.length ? int.tryParse(a[i]) ?? 0 : 0;
      final bv = i < b.length ? int.tryParse(b[i]) ?? 0 : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }

  /// 版本号是否可参与数值比较：首个 `.`/`-` 分段必须是纯数字。
  /// 部分 MusicFree 改造器插件把 version 写成描述性文案（如
  /// 「插件改造器 · 猫头猫 · 迟言」），这类值经 [compareVersions] 会被
  /// 折算成 0.0.0，永远判为比已装插件旧而被静默跳过（安装提示
  /// 「成功 0 个、跳过 1 个」）。不可比较的版本必须排除在版本校验外。
  static bool isComparableVersion(String version) {
    final trimmed = version.trim();
    if (trimmed.isEmpty) return false;
    return int.tryParse(trimmed.split(RegExp(r'[.-]')).first) != null;
  }

  static String _decodeUriPath(String path) {
    if (!path.contains('%')) return path;
    try {
      return Uri.decodeComponent(path);
    } on ArgumentError {
      return path;
    }
  }

  /// FNV-1a 32 位哈希，用于无法归一化的插件名生成回退 ID。
  static int _fnv1a(String input) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(input)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  /// MusicFree/BakaMusic 家族契约识别：脚本导出含 `getMediaSource` 的
  /// 宿主对象（module.exports/export default）。BakaMusic 是 MusicFree
  /// 的衍生契约，两者脚本同构；这类插件即使内嵌 LX 兼容分支（如万象
  /// API 的 `IS_LX = !!(globalThis.lx && globalThis.lx.EVENT_NAMES)`），
  /// 主导出仍是 MusicFree 对象，不能判为洛雪。
  static bool looksLikeMusicFreeContract(String script) {
    final lower = script.toLowerCase();
    final hasExport =
        lower.contains('module.exports') ||
        lower.contains('exports.default') ||
        lower.contains('export default');
    return hasExport && lower.contains('getmediasource');
  }

  /// LX（洛雪）插件静态识别（不执行脚本），与 plugin_runtime 的
  /// _looksLikeLxPlugin 规则保持一致；压缩/混淆后的脚本可能写成
  /// globalThis['lx']，不能只认点号形式。
  ///
  /// 关键：先排除 MusicFree 家族契约。混合契约插件（同时支持
  /// BakaMusic/MusicFree/LX）会在兼容判断里读取 `globalThis.lx`，
  /// 若仅凭字符串命中就判为 LX，会把 MusicFree 插件误分类到洛雪
  /// （搜索页出现平台下拉副行、插件页进错分栏）。
  static bool _detectLx(String script) {
    if (looksLikeMusicFreeContract(script)) return false;
    final lower = script.toLowerCase();
    return lower.contains('lx.event.request') ||
        lower.contains('lx.event.on') ||
        lower.contains('globalthis.lx') ||
        RegExp(r'''globalthis\s*\[\s*['"]lx['"]\s*\]''').hasMatch(lower) ||
        lower.contains('event_names.request') ||
        lower.contains('server_script_config') ||
        // 以下为压缩/混淆变体特征，照搬 XianYu plugin_engine.isLxPluginScript
        // （L93-109）：lx.on(...)/lx.send(...) 调用形式；仅同时出现
        // globalThis 与 EVENT_NAMES（无 globalThis.lx 字面）；以及 \uXXXX
        // 转义形态（\u006c\u0078 = "lx"、\u0053… = "SERVER_SCRIPT_CONFIG"）。
        // 未专门适配过的洛雪插件常被压缩成这些形态，只认字面串会漏判。
        RegExp(r'\blx\s*\.\s*(on|send)\s*\(').hasMatch(lower) ||
        (lower.contains('globalthis') && lower.contains('event_names')) ||
        lower.contains(
          r'\u0053\u0043\u0052\u0049\u0050\u0054\u005f\u004d\u0044\u0035',
        ) ||
        (lower.contains(r'\u006c\u0078') &&
            lower.contains(
              r'\u0067\u006c\u006f\u0062\u0061\u006c\u0054\u0068\u0069\u0073',
            ));
  }

  /// Baka provider **v2** 静态识别（不执行脚本）。
  ///
  /// v2 与 MusicFree 的导出不同构：MusicFree 把方法平铺在
  /// `module.exports` 上，v2 只导出 `{manifest, handlers}`，handler 表按
  /// `'entities.get'` / `'media.resolve'` 之类的点号键嵌套声明。因此不能只看
  /// `module.exports`，判定依据：
  ///
  /// 1. 显式标记 `// @baka-provider 2`（订阅源打包时注入，最可靠）；
  /// 2. 或 manifest 同时声明 `apiVersion: 2` 与 `capabilities`（旧兜底规则
  ///    还要求 `createProvider(` 工厂，但 cwo 订阅的插件把 handler 直接声明
  ///    为 `(request, sdk)` 函数、没有工厂，故去掉该依赖）。
  ///
  /// 判定完全不读取显示名/作者名，避免上游改名或作者变更导致分栏与
  /// 运行时路由漂移。
  static bool _detectBakaV2(String script, Map<String, String> manifest) {
    if (_providerVersionMarker.hasMatch(script)) return true;
    if (!script.toLowerCase().contains('capabilities')) return false;
    final version = (manifest['apiVersion'] ?? '').trim();
    if (version.isNotEmpty) return version == '2';
    return _manifestApiVersion2.hasMatch(script);
  }

  static final RegExp _providerVersionMarker = RegExp(
    r'''@baka-provider\s*[:=]?\s*2\b''',
    caseSensitive: false,
  );

  static final RegExp _manifestApiVersion2 = RegExp(
    r'''["']?apiVersion["']?\s*:\s*2\b''',
  );

  /// 提取 v2 manifest 的标量字段（name/platform/id/version/author）。
  ///
  /// manifest 是脚本顶部的对象字面量（`const manifest = {...}` 或
  /// `module.exports = { manifest: {...} }`），这里只做**静态切片**：先定位
  /// 字面量起点，再按大括号配平截取，最后逐键取字符串值。取不到时返回空
  /// 表，调用方按其他契约的取值链回退，不影响旧插件解析。
  static Map<String, String> _parseProviderManifest(String script) {
    final slice = _manifestObjectSlice(script);
    if (slice == null) return const {};
    final result = <String, String>{};
    for (final key in const [
      'name',
      'platform',
      'id',
      // v2 契约的稳定标识既能写成 `id` 也能写成 `providerId`，两种都要取。
      'providerId',
      'version',
      'author',
      'apiVersion',
    ]) {
      final value = _manifestScalar(slice, key);
      if (value != null && value.isNotEmpty) result[key] = value;
    }
    return result;
  }

  /// 提取 v2 manifest 声明的 `capabilities` 枚举。
  static List<String> _parseProviderCapabilities(String script) {
    final slice = _manifestObjectSlice(script);
    if (slice == null) return const [];
    final match = RegExp(
      r'''["']?capabilities["']?\s*:\s*\[([^\]]*)\]''',
      caseSensitive: false,
    ).firstMatch(slice);
    if (match == null) return const [];
    final body = match.group(1) ?? '';
    final capabilities = <String>[];
    for (final raw in body.split(',')) {
      final value = raw
          .trim()
          .replaceAll(RegExp(r'''^["']|["']$'''), '')
          .trim();
      if (value.isEmpty || capabilities.contains(value)) continue;
      capabilities.add(value);
    }
    return List<String>.unmodifiable(capabilities);
  }

  /// 截取 manifest 对象字面量原文（含大括号），找不到则返回 null。
  static String? _manifestObjectSlice(String script) {
    final patterns = <RegExp>[
      RegExp(r'''\bmanifest\s*[:=]\s*\{'''),
      RegExp(r'''["']manifest["']\s*:\s*\{'''),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(script);
      if (match == null) continue;
      final start = script.indexOf('{', match.start);
      if (start < 0) continue;
      var depth = 0;
      var quote = '';
      for (var i = start; i < script.length; i++) {
        final char = script[i];
        if (quote.isNotEmpty) {
          if (char == r'\') {
            i++;
            continue;
          }
          if (char == quote) quote = '';
          continue;
        }
        if (char == '"' || char == "'" || char == '`') {
          quote = char;
          continue;
        }
        if (char == '{') {
          depth++;
        } else if (char == '}') {
          depth--;
          if (depth == 0) return script.substring(start, i + 1);
        }
      }
    }
    return null;
  }

  /// 在 manifest 切片中读取键的标量值（字符串或数字），失败返回 null。
  ///
  /// 先按**顶层键**取值（嵌套对象/数组整体跳过），取不到再回退到全切片
  /// 正则。两步都必须加键名左边界，否则子串会互相污染——实测上游 manifest
  /// 同时含 `apiVersion` / `appVersion` / `version`，不加边界时：
  /// `version: 2` 会命中 `apiVersion:2`、`version: ">0.1.0-alpha.0"` 会命中
  /// `appVersion`，导致版本号被解析成 `2` / `>0.1.0-alpha.0`，进而让升级
  /// 判定（[compareVersions]）失效。同理 `id` 不能命中 `providerId`。
  static String? _manifestScalar(String slice, String key) {
    final topLevel = _manifestTopLevelValue(slice, key);
    if (topLevel != null) return topLevel;
    final match = RegExp(
      '(?<![\\w\$.])["\']?$key["\']?\\s*:\\s*("[^"]*"|\'[^\']*\'|[^,}\\]\\s]+)',
      caseSensitive: false,
    ).firstMatch(slice);
    if (match == null) return null;
    return _clean(
      match.group(1)?.replaceAll(RegExp(r'''^["']|["']$'''), ''),
    );
  }

  /// 读取 manifest 顶层键 [key] 的标量值；值不是标量（对象/数组）或键
  /// 不存在时返回 null，交由 [_manifestScalar] 的正则回退处理。
  ///
  /// 顶层扫描的意义在于 `name`：manifest 的 `userVariables` 里也带 `name`
  /// 字段（如「用户 ID」），全切片正则一旦顺序变化就会把变量显示名当成
  /// 插件显示名。
  static String? _manifestTopLevelValue(String slice, String key) {
    if (slice.length < 2) return null;
    final String? raw;
    try {
      raw = _topLevelValue(slice.substring(1, slice.length - 1), key);
    } catch (_) {
      return null;
    }
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty ||
        trimmed.startsWith('{') ||
        trimmed.startsWith('[')) {
      return null;
    }
    if (trimmed.startsWith('"') || trimmed.startsWith("'")) {
      final literal = _readStringLiteral(trimmed, 0);
      if (literal == null) return null;
      return _clean(literal.$1);
    }
    return _clean(trimmed);
  }

  /// 歌词接口的方法别名，按宿主尝试顺序排列。LX 系插件（酷狗等）导出的是
  /// 单数 `getLyric`，部分 MusicFree 插件用 `getLrc`/`getSongLyric`/
  /// `getMusicLyric`；静态扫描与运行时门控必须共用这一份清单，只认
  /// `getLyrics` 会把这类插件误判成「无歌词能力」而直接跳过。
  static const List<String> lyricMethodNames = [
    'getLyric',
    'getLyrics',
    'getLrc',
    'getSongLyric',
    'getMusicLyric',
  ];

  /// MusicFree 契约里宿主可能调用的方法名。只有这些方法参与
  /// [availableMethods] 门控，避免把插件内无关的同名标识符误判为契约方法。
  static const Set<String> knownContractMethods = {
    'search',
    'getMediaSource',
    'getMusicInfo',
    'getTopLists',
    'getTopListDetail',
    'getMusicSheetInfo',
    'importMusicSheet',
    'importMusicItem',
    'importPlaylist',
    'getDailyRecommendations',
    'getArtistWorks',
    'getArtistInfo',
    'getAlbumInfo',
    'getMusicComments',
    'getMvSource',
    ...lyricMethodNames,
  };

  /// v2 capability → MusicFree 契约方法名。
  ///
  /// 与 `assets/baka_v2_adapter.js` 的 `FACADE_MAP` 一一对应（适配层按
  /// capability 裁剪并挂载门面方法），两处口径必须一致，否则 Dart 侧门控
  /// 与运行时实际能力会对不上。
  ///
  /// 为什么需要这张表：v2 插件的能力写在 manifest.capabilities 里，键名是
  /// 命名空间形式（`lyrics.get`、`media.resolve`、`comments.list`…）；而
  /// [_parseExportedMethods] 只静态扫描扁平的 MusicFree 方法名（`getLyric`、
  /// `getMediaSource`…），一个都扫不到。若不反查，v2 插件的
  /// [availableMethods] 只剩脚本里顺带出现的名字，门控会把歌词/榜单/评论
  /// 等能力一律判成「不具备」而跳过调用——惜梦 CIT 这批单平台 v2 插件
  /// 全平台取不到歌词即由此引起。
  static final Map<String, List<String>> capabilityMethods = {
    'search': const ['search'],
    'entities.get': const ['getMusicInfo'],
    'collections.get': const ['getMusicSheetInfo'],
    'collections.members': const [
      'getTopListDetail',
      'getMusicSheetInfo',
      'getAlbumInfo',
      'getArtistWorks',
    ],
    'discovery.charts': const ['getTopLists'],
    'discovery.daily': const ['getDailyRecommendations'],
    'media.resolve': const ['getMediaSource'],
    'media.video': const ['getMvSource'],
    'lyrics.get': lyricMethodNames,
    'comments.list': const ['getMusicComments'],
    'links.resolve': const ['importMusicSheet'],
  };

  /// v2 插件的能力方法集：静态扫描结果 ∪ 由 capabilities 反查出的方法名。
  ///
  /// `capabilities` 为空时不门控（返回空集合，语义同 [_parseExportedMethods]
  /// 的「扫不出结果就不拦」）：适配层的 `has()` 在 manifest 未声明能力时
  /// 会挂载全部门面方法，此时任何门控都会比实际能力更窄。
  static List<String> _bakaV2Methods({
    required bool isBakaV2,
    required List<String> capabilities,
    required List<String> staticMethods,
  }) {
    if (!isBakaV2) return staticMethods;
    if (capabilities.isEmpty) return const [];
    final methods = <String>{...staticMethods};
    for (final capability in capabilities) {
      methods.addAll(capabilityMethods[capability] ?? const []);
    }
    return methods.toList();
  }

  /// 静态扫描插件实现了哪些 MusicFree 契约方法（不执行脚本）。
  ///
  /// 参照 XianYu 的 `_availableMethods`（其从加载后的引擎元数据读取）：
  /// 未适配/精简插件可能只实现 search + getMediaSource，宿主调用缺失的
  /// 可选方法会抛错。这里用「方法名以函数形式声明」的宽松匹配逐个探测。
  ///
  /// 刻意宽松（属性/简写方法/箭头函数/赋值式挂载都算命中）：漏判会让
  /// 调用方误跳过插件其实实现了的方法，比多判（退化为原来的尝试调用）
  /// 危险得多，因此宁可多判。
  static List<String> _parseExportedMethods(String script) {
    if (script.isEmpty) return const [];
    final methods = <String>[];
    for (final name in knownContractMethods) {
      final escaped = RegExp.escape(name);
      final body =
          // 简写方法 `search(kw) {` 或箭头 `search: (kw) => `
          r'(?:\([^)]*\)\s*(?:\{|=>)'
          // 属性赋值函数 `search: function` / `search: async (kw) =>` / `search: kw =>`
          r'|:\s*(?:async\s+)?(?:function\b|\(|\w+\s*=>)'
          // 赋值式挂载 `p.search = function` / `= (kw) =>`
          r'|=\s*(?:async\s+)?(?:function\b|\())';
      final pattern = RegExp(
        // 前缀排除 `.`/标识符字符，避免把 `this.search(` 这类调用当成声明。
        '(?:^|[^\\w\\\$.])["\\\']?$escaped["\\\']?\\s*$body',
      );
      if (pattern.hasMatch(script)) methods.add(name);
    }
    return methods;
  }

  /// animemusic（惜梦动画音乐）插件识别：
  /// - 老站点域名 `animemusic.bzxhkj.com`；
  /// - 新插件（如 qishui，API 域名为 `anime.bzxhkj.com`）不再包含老域名，
  ///   但在 META 中声明 `format: "animemusic/1"` 规范，与运行时
  ///   `_looksLikeAnimemusicPlugin` 的判定对齐，避免被误分类到
  ///   MusicFree 插件页。
  /// isLx 与 bakaV2 的分类优先级更高，先于本标记判定。
  static bool _detectAnimemusic(String script) {
    if (script.contains('animemusic.bzxhkj.com')) return true;
    return RegExp(
          r'''["']format["']\s*:\s*["']animemusic/1["']''',
        ).hasMatch(script) ||
        (RegExp(r'''module\.exports\s*=\s*\w+''').hasMatch(script) &&
            script.contains('animemusic/1'));
  }

  /// 星海格式静态识别（不执行脚本）：
  /// - primaryKey 含 "_src"：聚合多平台时不同平台 id 会撞车，星海规范
  ///   要求把来源键纳入主键（如 primaryKey: ["id", "_src"]）；
  /// - 插件读取歌曲的 `._src` / `._source` 来源标记：星海歌曲字段约定，
  ///   MusicFree/LX 规范均无此字段。
  static bool _detectStarSea(String script) {
    if (RegExp(r'''primaryKey\s*:\s*\[[^\]]*_src''').hasMatch(script)) {
      return true;
    }
    return RegExp(r'''\.\s*_src\b|\.\s*_source\b''').hasMatch(script);
  }

  /// 解析插件声明的 userVariables 数组：
  /// userVariables: [{ key: 'token', name: '令牌', hint: '提示' }, ...]
  /// 不执行插件脚本，用括号配对扫描提取数组文本后逐项解析字段。
  static List<PluginUserVariable> _parseUserVariables(
    String script,
    Map<String, String> constants,
  ) {
    final result = <PluginUserVariable>[];
    final seen = <String>{};
    // manifest 的对象字面量可能是 JSON 风格，键带引号（`"userVariables": [`）。
    // 不兼容引号时，酷狗/酷我这批 v2 插件的变量声明会被整体漏掉。
    final arrayPattern = RegExp(r'''["']?userVariables["']?\s*:\s*\[''');
    for (final match in arrayPattern.allMatches(script)) {
      final arrayText = _extractBalanced(script, match.end - 1, '[', ']');
      if (arrayText == null) continue;
      final objectPattern = RegExp(r'\{');
      for (final objectMatch in objectPattern.allMatches(arrayText)) {
        final objectText = _extractBalanced(
          arrayText,
          objectMatch.start,
          '{',
          '}',
        );
        if (objectText == null) continue;
        final key = _resolveExpression(
          _fieldValue(objectText, 'key') ?? '',
          constants,
        );
        if (key == null || key.trim().isEmpty) continue;
        // 已停用的变量（如订阅源的 X-API-KEY）连元数据都不进。
        if (isPluginRetiredUserVariable(key)) continue;
        if (!seen.add(key.trim())) continue;
        result.add(
          PluginUserVariable(
            key: key.trim(),
            name: _resolveExpression(
              _fieldValue(objectText, 'name') ?? '',
              constants,
            ),
            hint: _resolveExpression(
              _fieldValue(objectText, 'hint') ?? '',
              constants,
            ),
          ),
        );
      }
      if (result.isNotEmpty) return result;
    }
    return result;
  }

  /// 提取 [start] 处开括号开始的配对文本（不含首尾括号）。字符串字面量
  /// 中的括号不计入深度。
  static String? _extractBalanced(
    String text,
    int start,
    String open,
    String close,
  ) {
    if (start < 0 || start >= text.length || text[start] != open) return null;
    var depth = 0;
    var inString = false;
    String? quote;
    for (var index = start; index < text.length; index++) {
      final char = text[index];
      if (inString) {
        if (char == r'\') {
          index++;
        } else if (quote != null && char == quote) {
          inString = false;
          quote = null;
        }
        continue;
      }
      if (char == '"' || char == "'") {
        inString = true;
        quote = char;
      } else if (char == open) {
        depth++;
      } else if (char == close) {
        depth--;
        if (depth == 0) return text.substring(start + 1, index);
      }
    }
    return null;
  }

  /// 提取对象文本中的顶层字段值表达式，如 `key: 'token'` 返回 `'token'`。
  static String? _fieldValue(String objectText, String field) {
    final match = RegExp(
      '''(?:^|[,\\{\\r\\n])\\s*["']?$field["']?\\s*:\\s*([^\\r\\n,}]+)''',
      caseSensitive: false,
    ).firstMatch(objectText);
    return match?.group(1)?.trim();
  }

  static Map<String, String> _parseHeader(String script) {
    // 元数据头只会出现在文件开头。限制范围可避免把函数文档里的 @name
    // 误识别为插件名称。
    final scope = script.substring(0, math.min(script.length, 64 * 1024));
    final result = <String, String>{};
    final pattern = RegExp(
      r'^\s*(?://+|/\*+|\*+)?\s*@(id|name|version|author|description|desc|remark)\s+(.+?)\s*(?:\*/)?\s*$',
      caseSensitive: false,
      multiLine: true,
    );
    for (final match in pattern.allMatches(scope)) {
      final key = match.group(1)!.toLowerCase();
      final value = match.group(2)!.trim();
      result.putIfAbsent(key, () => value);
    }
    return result;
  }

  /// animemusic/1 等新格式插件把元信息放在 `const META = { ... }` 单行
  /// JSON 常量里，且 module.exports 导出的是变量而非对象字面量，前面
  /// 的静态解析都取不到名称；这里单独截取该常量做一次 JSON 解析兜底。
  static Map<String, String> _parseConstMeta(String script) {
    final match = RegExp(
      r'const\s+META\s*=\s*(\{[^\n;]+\})\s*;',
    ).firstMatch(script);
    if (match == null) return const {};
    try {
      final value = jsonDecode(match.group(1)!);
      if (value is! Map) return const {};
      return {
        for (final key in const ['id', 'name', 'version', 'author', 'platform'])
          if (value[key] != null && value[key].toString().trim().isNotEmpty)
            key: value[key].toString(),
      };
    } catch (_) {
      return const {};
    }
  }

  static Map<String, String> _parseStringConstants(String script) {
    final result = <String, String>{};
    final scope = script.substring(0, math.min(script.length, 128 * 1024));
    final patterns = [
      RegExp(
        r'''(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*"([^"\r\n]*)"\s*;''',
      ),
      RegExp(r"(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*'([^'\r\n]*)'\s*;"),
      // 数字常量（如服务器注入的 QQ_SOURCE_LEVEL = 1）：部分插件用它从
      // 配置表里选出 platform，成员链求值（见 [_resolveStaticNodeInternal]）
      // 需要把它还原成字符串索引。
      RegExp(
        r'(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(-?\d+(?:\.\d+)?)\s*;',
      ),
    ];
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(scope)) {
        result[match.group(1)!] = match.group(2)!;
      }
    }
    return result;
  }

  static Map<String, String> _parseExportedObject(
    String script,
    Map<String, String> constants,
    Map<String, String> bindings,
  ) {
    final exportPatterns = [
      RegExp(r'module\.exports\s*=\s*\{'),
      RegExp(r'exports\.default\s*=\s*\{'),
      RegExp(r'export\s+default\s*\{'),
    ];
    RegExpMatch? lastMatch;
    for (final pattern in exportPatterns) {
      for (final match in pattern.allMatches(script)) {
        if (lastMatch == null || match.start > lastMatch.start) {
          lastMatch = match;
        }
      }
    }
    if (lastMatch != null) {
      final result = _parseExportFields(
        _extractExportObjectBody(script, lastMatch.end),
        constants,
        bindings,
      );
      if (result.isNotEmpty) return result;
    }
    return _parseVariableExport(script, constants, bindings);
  }

  /// `module.exports = MF_PLUGIN;`（导出的是变量而非对象字面量，
  /// 插件改造器生成的插件常见）：定位该标识符的 const/let/var 对象
  /// 字面量声明，再从声明的对象体中解析元数据字段。
  static Map<String, String> _parseVariableExport(
    String script,
    Map<String, String> constants,
    Map<String, String> bindings,
  ) {
    final variablePatterns = [
      RegExp(r'module\.exports\s*=\s*([A-Za-z_$][\w$]*)\s*;'),
      RegExp(r'exports\.default\s*=\s*([A-Za-z_$][\w$]*)\s*;'),
      RegExp(r'export\s+default\s+([A-Za-z_$][\w$]*)\s*;'),
    ];
    for (final pattern in variablePatterns) {
      for (final match in pattern.allMatches(script)) {
        final identifier = match.group(1)!;
        final declaration = RegExp(
          '(?:const|let|var)\\s+${RegExp.escape(identifier)}\\s*=\\s*\\{',
        ).firstMatch(script);
        if (declaration == null) continue;
        final result = _parseExportFields(
          _extractExportObjectBody(script, declaration.end),
          constants,
          bindings,
        );
        if (result.isNotEmpty) return result;
      }
    }
    return const {};
  }

  /// 提取导出对象字面量的正文（`{` 之后到配对 `}` 之前）：跳过字符串、
  /// 模板字符串与注释中的花括号。不按配对括号截断时，对象之后的代码
  /// （如插件内置的示例歌曲 `id: 'qq_xxx'`）会污染 id/name 字段。
  static String _extractExportObjectBody(String script, int bodyStart) {
    final n = script.length;
    var depth = 1;
    var i = bodyStart;
    while (i < n && depth > 0) {
      final ch = script.codeUnitAt(i);
      if (ch == 0x27 || ch == 0x22 || ch == 0x60) {
        final quote = ch;
        i++;
        while (i < n) {
          final c = script.codeUnitAt(i);
          if (c == 0x5C) {
            i += 2;
            continue;
          }
          if (c == quote) {
            i++;
            break;
          }
          i++;
        }
        continue;
      }
      if (ch == 0x2F &&
          i + 1 < n &&
          (script.codeUnitAt(i + 1) == 0x2F ||
              script.codeUnitAt(i + 1) == 0x2A)) {
        final block = script.codeUnitAt(i + 1) == 0x2A;
        i += 2;
        if (block) {
          while (i + 1 < n &&
              !(script.codeUnitAt(i) == 0x2A &&
                  script.codeUnitAt(i + 1) == 0x2F)) {
            i++;
          }
          i += 2;
        } else {
          while (i < n && script.codeUnitAt(i) != 0x0A) {
            i++;
          }
        }
        continue;
      }
      if (ch == 0x7B) depth++;
      if (ch == 0x7D) depth--;
      i++;
    }
    final end = depth == 0 ? i - 1 : i;
    return script.substring(
      bodyStart,
      math.min(end, math.min(n, bodyStart + 16 * 1024)),
    );
  }

  static Map<String, String> _parseExportFields(
    String scope,
    Map<String, String> constants,
    Map<String, String> bindings,
  ) {
    final result = <String, String>{};
    for (final key in const [
      'id',
      'platform',
      'name',
      'version',
      'author',
      'description',
      'desc',
      'remark',
    ]) {
      final field = RegExp(
        '(?:^|[,\\r\\n])\\s*["\\\']?$key["\\\']?\\s*:\\s*([^\\r\\n,}]+)',
        caseSensitive: false,
        multiLine: true,
      ).firstMatch(_maskNestedScope(scope));
      if (field == null) continue;
      final value = _resolveExpression(field.group(1)!, constants, bindings);
      if (value != null && value.isNotEmpty) result[key] = value;
    }
    return result;
  }

  /// 把导出对象正文中嵌套层级（方法体、数组、内层对象）的内容替换为
  /// 空白，只保留顶层字段供提取：插件方法体内的示例数据（如 debug
  /// 方法的 fakeItem）带 id/name 字段，不屏蔽会污染插件元数据。
  static String _maskNestedScope(String scope) {
    final n = scope.length;
    final buffer = StringBuffer();
    var depth = 0;
    var i = 0;
    while (i < n) {
      final ch = scope.codeUnitAt(i);
      if (ch == 0x27 || ch == 0x22 || ch == 0x60) {
        final quote = ch;
        var j = i + 1;
        while (j < n) {
          final c = scope.codeUnitAt(j);
          if (c == 0x5C) {
            j += 2;
            continue;
          }
          if (c == quote) {
            j++;
            break;
          }
          j++;
        }
        if (depth == 0) {
          buffer.write(scope.substring(i, j));
        } else {
          buffer.write(' ' * (j - i));
        }
        i = j;
        continue;
      }
      if (ch == 0x2F && i + 1 < n) {
        final next = scope.codeUnitAt(i + 1);
        if (next == 0x2F || next == 0x2A) {
          var j = i + 2;
          if (next == 0x2A) {
            while (j + 1 < n &&
                !(scope.codeUnitAt(j) == 0x2A &&
                    scope.codeUnitAt(j + 1) == 0x2F)) {
              j++;
            }
            j += 2;
          } else {
            while (j < n && scope.codeUnitAt(j) != 0x0A) {
              j++;
            }
          }
          buffer.write(' ' * (j - i));
          i = j;
          continue;
        }
      }
      if (ch == 0x7B || ch == 0x5B) {
        depth++;
        buffer.write(' ');
        i++;
        continue;
      }
      if (ch == 0x7D || ch == 0x5D) {
        if (depth > 0) depth--;
        buffer.write(' ');
        i++;
        continue;
      }
      buffer.writeCharCode(depth == 0 ? ch : 0x20);
      i++;
    }
    return buffer.toString();
  }

  static String? _resolveExpression(
    String expression,
    Map<String, String> constants, [
    Map<String, String>? bindings,
  ]) {
    // 优先做成员链静态求值：platform: qqSourceProfile.platform 这类间接
    // 取值只看字面量会得到 null，进而回退成插件 ID（表现为 qq-l1）。
    if (bindings != null) {
      final resolved = _resolveStaticNode(expression, bindings, constants, 0);
      if (resolved != null) return resolved;
    }

    final quoted = RegExp(r'''["']([^"']*)["']''').firstMatch(expression);
    String? result = quoted?.group(1);

    // 表达式本身就是一个完整字符串字面量时直接返回，不能再去拼接同名常量：
    // 订阅源脚本里常写 `const SOURCE_API_KEY = '3ccnt...'`，键却声明成
    // `{ key: "SOURCE_API_KEY" }`；按常量名拼接会把键变成
    // `SOURCE_API_KEY3ccnt...`，导致停用键过滤（[isPluginRetiredUserVariable]）
    // 失配，X-API-KEY 这一栏又会被加到设置页。
    final trimmedExpression = expression.trim();
    if (trimmedExpression.isNotEmpty &&
        (trimmedExpression.startsWith('"') || trimmedExpression.startsWith("'"))) {
      final literal = _readStringLiteral(trimmedExpression, 0);
      if (literal != null && literal.$2 == trimmedExpression.length) {
        return literal.$1;
      }
    }

    // version: VERSION / platform: "网易云音乐" + (IS_PAID ? IS_PAID : "")
    // 均可通过顶层字符串常量静态还原，无需执行不受信任的插件脚本。
    for (final entry in constants.entries) {
      if (!RegExp('\\b${RegExp.escape(entry.key)}\\b').hasMatch(expression)) {
        continue;
      }
      if (result == null || result.isEmpty) {
        result = entry.value;
      } else if (entry.value.isNotEmpty && !result.contains(entry.value)) {
        result += entry.value;
      }
    }
    return result;
  }

  /// 收集顶层 const/let/var 的右值原文（含对象/数组字面量），供
  /// [_resolveStaticNodeInternal] 还原间接取值（如 `A[LEVEL].platform`）。
  ///
  /// 只匹配行首声明，避免把函数体内的局部常量当成插件级配置；脚本前
  /// 128 KB 之外的部分不参与（元数据声明不会出现在那么靠后的位置）。
  static Map<String, String> _parseBindings(String script) {
    final result = <String, String>{};
    final scope = script.substring(0, math.min(script.length, 128 * 1024));
    final pattern = RegExp(
      r'^(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*',
      multiLine: true,
    );
    for (final match in pattern.allMatches(scope)) {
      var i = match.end;
      while (i < scope.length && scope[i].trim().isEmpty) {
        i++;
      }
      if (i >= scope.length) continue;
      String? value;
      if (scope[i] == '{' || scope[i] == '[') {
        final end = _balancedEnd(scope, i);
        if (end != null) value = scope.substring(i, end + 1);
      } else if (scope[i] == '"' || scope[i] == "'") {
        final literal = _readStringLiteral(scope, i);
        if (literal != null) value = scope.substring(i, literal.$2);
      } else {
        var j = i;
        while (j < scope.length &&
            scope[j] != ';' &&
            scope[j] != '\n' &&
            scope[j] != '\r') {
          j++;
        }
        value = scope.substring(i, j).trim();
      }
      if (value != null && value.isNotEmpty) {
        result[match.group(1)!] = value;
      }
    }
    return result;
  }

  /// 成员链静态求值入口：命中字符串字面量时返回其内容，否则返回 null
  /// （交由调用方按原有「字面量 + 字符串常量拼接」规则兜底）。
  static String? _resolveStaticNode(
    String expression,
    Map<String, String> bindings,
    Map<String, String> constants,
    int depth,
  ) {
    return _resolveStaticNodeInternal(
      expression,
      bindings,
      constants,
      depth,
    )?.value;
  }

  /// 有限求值 `IDENT.prop` / `IDENT["prop"]` / `IDENT[CONST]` 及其后续
  /// `.prop`：支持对象/数组字面量常量与别名声明（如
  /// `const qqSourceProfile = qqSourceProfiles[QQ_SOURCE_LEVEL]`）。
  /// 不执行脚本、不做运算，只沿声明与字面量取值，深度受限防环。
  static _StaticNode? _resolveStaticNodeInternal(
    String expression,
    Map<String, String> bindings,
    Map<String, String> constants,
    int depth,
  ) {
    if (depth > 6) return null;
    final trimmed = expression.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return _StaticNode.composite(trimmed);
    }
    if (trimmed.startsWith('"') || trimmed.startsWith("'")) {
      final literal = _readStringLiteral(trimmed, 0);
      if (literal == null || trimmed.substring(literal.$2).trim().isNotEmpty) {
        return null;
      }
      return _StaticNode.literal(literal.$1);
    }

    final baseMatch = RegExp(r'^[A-Za-z_$][\w$]*').firstMatch(trimmed);
    if (baseMatch == null) return null;
    final base = baseMatch.group(0)!;
    var rest = trimmed.substring(base.length);

    _StaticNode? node;
    final raw = bindings[base];
    if (raw != null) {
      node = _resolveStaticNodeInternal(raw, bindings, constants, depth + 1);
    } else {
      final scalar = constants[base];
      if (scalar == null) return null;
      node = _StaticNode.literal(scalar);
    }
    if (node == null) return null;

    while (true) {
      rest = rest.trimLeft();
      if (rest.isEmpty) return node;
      final current = node!;
      // 已解析成字符串后不能再取成员（说明表达式不是纯静态引用）。
      if (current.value != null) return null;
      final step = _matchMemberStep(rest, constants);
      if (step == null) return null;
      final text = current.text!;
      final valueExpression = _topLevelValue(
        text.substring(1, text.length - 1),
        step.$1,
      );
      if (valueExpression == null) return null;
      node = _resolveStaticNodeInternal(
        valueExpression,
        bindings,
        constants,
        depth + 1,
      );
      if (node == null) return null;
      rest = rest.substring(step.$2);
    }
  }

  /// 解析一次成员访问：`.prop` 或 `["prop"]` / `[CONST]` / `[0]`。
  /// 返回（最终键名，访问结束后的偏移）。
  static (String, int)? _matchMemberStep(
    String text,
    Map<String, String> constants,
  ) {
    if (text.startsWith('.')) {
      final match = RegExp(r'^\.\s*([A-Za-z_$][\w$]*)').firstMatch(text);
      return match == null ? null : (match.group(1)!, match.end);
    }
    if (!text.startsWith('[')) return null;
    final close = text.indexOf(']');
    if (close < 0) return null;
    final token = text.substring(1, close).trim();
    String? key;
    if (token.startsWith('"') || token.startsWith("'")) {
      final literal = _readStringLiteral(token, 0);
      if (literal == null || token.substring(literal.$2).trim().isNotEmpty) {
        return null;
      }
      key = literal.$1;
    } else {
      key =
          constants[token] ??
          (RegExp(r'^-?\d+(?:\.\d+)?$').hasMatch(token) ? token : null);
    }
    return key == null ? null : (key, close + 1);
  }

  /// 从对象字面量正文（不含外层括号）中读取顶层键 [key] 的值表达式。
  /// 只扫描顶层，嵌套对象/数组按配对括号整体跳过，避免内部同名字段污染。
  static String? _topLevelValue(String body, String key) {
    final n = body.length;
    var i = 0;
    while (i < n) {
      while (i < n && (body[i] == ',' || body[i].trim().isEmpty)) {
        i++;
      }
      if (i >= n) return null;
      final readKey = _readObjectKey(body, i);
      if (readKey == null) return null;
      i = readKey.$2;
      while (i < n && body[i].trim().isEmpty) {
        i++;
      }
      if (i >= n || body[i] != ':') return null;
      i++;
      final value = _readObjectValue(body, i);
      if (value == null) return null;
      if (readKey.$1 == key) return value.$1;
      i = value.$2;
    }
    return null;
  }

  static (String, int)? _readObjectKey(String text, int start) {
    if (start >= text.length) return null;
    final ch = text[start];
    if (ch == '"' || ch == "'") {
      final literal = _readStringLiteral(text, start);
      return literal == null ? null : (literal.$1, literal.$2);
    }
    var i = start;
    while (i < text.length && _isKeyChar(text.codeUnitAt(i))) {
      i++;
    }
    return i == start ? null : (text.substring(start, i), i);
  }

  /// 读取一个值表达式：对象/数组返回含括号原文，字符串保留引号原文，
  /// 其余读到顶层分隔符为止。
  static (String, int)? _readObjectValue(String text, int start) {
    var i = start;
    while (i < text.length && text[i].trim().isEmpty) {
      i++;
    }
    if (i >= text.length) return null;
    final ch = text[i];
    if (ch == '{' || ch == '[') {
      final end = _balancedEnd(text, i);
      if (end == null) return null;
      return (text.substring(i, end + 1), end + 1);
    }
    if (ch == '"' || ch == "'") {
      final literal = _readStringLiteral(text, i);
      if (literal == null) return null;
      return (text.substring(i, literal.$2), literal.$2);
    }
    var j = i;
    while (j < text.length) {
      final c = text[j];
      if (c == ',' || c == '\n' || c == '\r' || c == '}' || c == ']') break;
      j++;
    }
    return (text.substring(i, j).trim(), j);
  }

  static bool _isKeyChar(int codeUnit) {
    return (codeUnit >= 0x30 && codeUnit <= 0x39) || // 0-9
        (codeUnit >= 0x41 && codeUnit <= 0x5A) || // A-Z
        (codeUnit >= 0x61 && codeUnit <= 0x7A) || // a-z
        codeUnit == 0x5F || // _
        codeUnit == 0x24 || // $
        codeUnit == 0x2D || // -
        codeUnit == 0x2E; // .
  }

  /// 读取一个引号字符串字面量，返回（内容，结束后偏移）。转义仅还原
  /// 字符本身；元数据名称不需要 \uXXXX 展开。
  static (String, int)? _readStringLiteral(String text, int start) {
    if (start >= text.length) return null;
    final quote = text[start];
    if (quote != '"' && quote != "'") return null;
    final buffer = StringBuffer();
    var i = start + 1;
    while (i < text.length) {
      final ch = text[i];
      if (ch == '\\') {
        if (i + 1 >= text.length) return null;
        buffer.write(text[i + 1]);
        i += 2;
        continue;
      }
      if (ch == quote) return (buffer.toString(), i + 1);
      buffer.write(ch);
      i++;
    }
    return null;
  }

  /// 返回 [start] 处 `{`/`[` 对应闭合符的下标；跳过字符串与注释。
  static int? _balancedEnd(String text, int start) {
    if (start >= text.length) return null;
    final open = text[start];
    final close = open == '{' ? '}' : ']';
    var depth = 0;
    var i = start;
    final n = text.length;
    while (i < n) {
      final code = text.codeUnitAt(i);
      if (code == 0x27 || code == 0x22 || code == 0x60) {
        final quote = code;
        i++;
        while (i < n) {
          final c = text.codeUnitAt(i);
          if (c == 0x5C) {
            i += 2;
            continue;
          }
          if (c == quote) {
            i++;
            break;
          }
          i++;
        }
        continue;
      }
      if (code == 0x2F && i + 1 < n) {
        final next = text.codeUnitAt(i + 1);
        if (next == 0x2F || next == 0x2A) {
          i += 2;
          if (next == 0x2A) {
            while (i + 1 < n &&
                !(text.codeUnitAt(i) == 0x2A &&
                    text.codeUnitAt(i + 1) == 0x2F)) {
              i++;
            }
            i += 2;
          } else {
            while (i < n && text.codeUnitAt(i) != 0x0A) {
              i++;
            }
          }
          continue;
        }
      }
      if (text[i] == open) {
        depth++;
      } else if (text[i] == close) {
        depth--;
        if (depth == 0) return i;
      }
      i++;
    }
    return null;
  }

  static Map<String, String> _parseJsonObject(String script) {
    final trimmed = script.trim();
    if (!trimmed.startsWith('{')) return const {};
    try {
      final value = jsonDecode(trimmed);
      if (value is! Map) return const {};
      final map = Map<String, dynamic>.from(value);
      return {
        for (final key in const [
          'id',
          'platform',
          'name',
          'version',
          'author',
          'description',
          'desc',
          'remark',
        ])
          if (map[key] != null) key: map[key].toString(),
      };
    } catch (_) {
      return const {};
    }
  }

  static String? _clean(String? value) {
    final cleaned = value?.replaceFirst(RegExp(r'\s*\*/\s*$'), '').trim();
    return cleaned == null || cleaned.isEmpty ? null : cleaned;
  }
}

/// 静态求值的中间值：字符串字面量（[value]）或对象/数组字面量原文
/// （[text]）。成员链求值在这两种形态之间推进。
class _StaticNode {
  const _StaticNode.literal(this.value) : text = null;
  const _StaticNode.composite(this.text) : value = null;

  final String? value;
  final String? text;
}

/// 插件分类的**唯一**判定入口。
///
/// 插件管理页的分栏（`_rowFromMeta`）、运行时分组（`musicPluginKindKeyOf`）、
/// 安装/订阅导入/备份导入的格式标签、音源兜底开关的可用源清单，全部走
/// 这一个函数，避免多处各写一份规则导致同一插件在不同链路归类不一致。
///
/// 判定只依赖 [contract]（脚本内容识别出的契约），**不读取插件显示名、
/// 备注或作者名**：上游改名（QQ音乐[L1] → QQ音乐[T]）或换作者都不会改变
/// 归类。
///
/// 返回分类标识 `lx` / `baka` / `animemusic` / `musicfree` / `other`
///（取值与 plugin_runtime.dart 的 `pluginKind*` 常量一致）。这里**不含任何
/// 固定格式优先级**：类别只由插件自身契约决定，展示先后顺序交给用户自定义
/// 排序（`pluginKindOrderKey`）。旧 V1 契约（MusicFree 同构 + yourinfo/
/// baka URL 提示兜底）已随 BakaMusic V1 下线一并移除：`baka` 分栏只承载
/// 内容判定为 v2 的插件，[kindHint] 仅用于保留用户手动归入「其他」的结果。
String resolvePluginKindKey({
  required PluginContract contract,
  String? kindHint,
}) {
  final hint = kindHint?.trim().toLowerCase();
  // 用户手动归入「其他」优先级最高，避免手动整理被内容识别覆盖。
  if (hint == 'other') return 'other';
  return contract.kindKey;
}

