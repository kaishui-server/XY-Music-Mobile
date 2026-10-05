import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:quickjs_engine/quickjs_engine.dart';
import 'package:quickjs_engine/extensions/xhr.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/db_path.dart';
import '../rust/api.dart';
import '../player/lx_lyrics_builder.dart';
import 'plugin_metadata.dart';
import 'qrc_decrypt.dart';

class EnabledMusicPlugin {
  const EnabledMusicPlugin({
    required this.id,
    required this.name,
    required this.path,
    this.isLx = false,
    this.lxSources = const [],
    this.isBaka = false,
    this.isAnimemusic = false,
    this.animemusicApi = '',
    this.animemusicPlatform = 'wy',
    this.animemusicQualities = const ['128k', '192k', '320k', 'flac'],
    this.userVariables = const {},
    this.sourceUrl = '',
    this.sourceLabel,
    this.availableMethods = const [],
  });

  final String id;
  final String name;
  final String path;
  final bool isLx;
  final List<String> lxSources;

  /// BakaMusic 契约插件（getMvSource 方法 / animeSrc 来源标记），优先级
  /// 低于 LX、高于 animemusic，与插件管理页的分类规则一致。
  final bool isBaka;

  /// animemusic/1 自有格式插件：CommonJS Node 模块，QuickJS 无法直接
  /// 执行（没有 http/https/zlib 内置模块），宿主按其 REST 契约直连。
  final bool isAnimemusic;

  /// 从插件 META 提取的后端接口地址（可被用户变量 api 覆盖）。
  final String animemusicApi;

  /// 后端音源平台（wy/kg/…）。
  final String animemusicPlatform;

  /// META.qualities 声明的音质档位。
  final List<String> animemusicQualities;

  /// 用户在插件管理中填写的用户变量值，加载插件时注入 env。
  final Map<String, String> userVariables;

  /// 插件的订阅来源地址（安装/更新时记录），供音源分类按 URL 前缀
  /// 识别（Baka / 惜梦 / MusicFree）。
  final String sourceUrl;

  /// 多租户订阅源标识（IKUN / 聆澜…）。BakaMusic 的多租户订阅按
  /// `?source=` 对同一插件发放不同授权的脚本，名称相同、内容不同，换源
  /// 列表需要据此区分展示（同名音源各带一个来源标签）。
  final String? sourceLabel;

  /// 静态扫描出的 MusicFree 契约方法名（见 PluginMetadata.availableMethods）。
  /// 空集合表示未识别（压缩/混淆插件），此时不做方法门控。
  final List<String> availableMethods;

  /// 插件是否可能实现了 [method]（参照 XianYu 的 `_availableMethods`）。
  /// 未识别方法集合时一律返回 true，保持「尝试调用并靠异常兜底」；
  /// 识别出集合后，缺失的方法由调用方直接走回退链，省下无谓的跨
  /// isolate 调用与错误日志。仅对 MusicFree 族插件有意义。
  bool mayHaveMethod(String method) =>
      availableMethods.isEmpty || availableMethods.contains(method);
}

class PluginSearchSong {
  const PluginSearchSong({
    required this.pluginId,
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
    required this.coverUrl,
    required this.rawData,
    this.platform = '',
  });

  final String pluginId;
  final String id;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final String coverUrl;
  final Map<String, dynamic> rawData;

  /// 展示用平台名（洛雪/animemusic 等「单插件多平台」源的子平台，
  /// 如「酷我」「B站」）；单平台插件为空（Tab 已显示插件名，不重复）。
  final String platform;
}

/// 插件分类搜索结果（歌手或专辑）。
///
/// MusicFree 插件可以直接返回 artist/album 搜索结果；LX 的分类结果由
/// 落雪搜索接口提供。点击分类结果后，MusicFree 优先调用详情接口获取作品。
class PluginCatalogResult {
  const PluginCatalogResult({
    required this.pluginId,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.coverUrl,
    required this.rawData,
  });

  final String pluginId;
  final String id;
  final String title;
  final String subtitle;
  final String coverUrl;
  final Map<String, dynamic> rawData;
}

class PluginPlaylistImport {
  const PluginPlaylistImport({
    required this.name,
    required this.coverUrl,
    required this.songs,
  });

  final String name;
  final String coverUrl;
  final List<PluginSearchSong> songs;
}

class PluginMediaSource {
  const PluginMediaSource({
    required this.url,
    this.headers = const {},
    this.lyrics = '',
  });
  final String url;
  final Map<String, String> headers;
  final String lyrics;
}

/// 播放源缓存的条目：inFlight 非空表示解析正在进行（并发调用直接
/// 复用同一 Future）；source 非空表示解析完成（TTL 内直接返回）。
class _MediaSourceCacheEntry {
  _MediaSourceCacheEntry(this.cachedAt);
  DateTime cachedAt;
  Future<PluginMediaSource>? inFlight;
  PluginMediaSource? source;
}

/// Bilibili 视频流地址。DASH 视频通常需要 Referer 才能在 Android 播放器中
/// 正常打开，因此地址和请求头一起返回给详情页。
class PluginVideoSource {
  const PluginVideoSource({
    required this.url,
    this.backupUrls = const [],
    this.headers = const {},
    this.mimeType = 'video/mp4',
    this.selectedQuality,
    this.availableQualities = const [],
  });

  final String url;
  final List<String> backupUrls;
  final Map<String, String> headers;
  final String mimeType;

  /// 插件实际选中的画质 key（如 baka 系返回的 "1080p"）。
  /// 请求「最高档」时插件会回落到可用档位，此字段即回落后的真实档位。
  final String? selectedQuality;

  /// 插件返回的可用画质 key 列表（如 ["360p","720p","1080p"]），
  /// 供 MV 播放页的画质选择入口动态展示；插件未提供时为空。
  final List<String> availableQualities;
}

String pluginSongPath(EnabledMusicPlugin plugin, PluginSearchSong song) {
  final explicit = song.rawData['_sourcePath']?.toString().trim() ?? '';
  if (explicit.isNotEmpty) return explicit;
  return 'plugin://${Uri.encodeComponent(plugin.id)}/'
      '${Uri.encodeComponent(song.id)}';
}

List<String> pluginQualityCandidates(String? preferredQuality) => <String>{
  if (preferredQuality?.trim().isNotEmpty == true) preferredQuality!.trim(),
  '320k',
  'high',
  'flac',
  'lossless',
  '128k',
  'standard',
  'super',
}.toList();

/// 音质档位的展示标签（设置页、播放页音质选择器共用）。
/// 档位集合对齐 MusicFree：96k / 128k / 192k / 320k / flac / flac24bit /
/// hires / vinyl / dolby / atmos / atmos_plus / master，另兼容插件侧
/// 仍会返回的 lossless / sq / ape / wav / hi-res / standard / high 等别名。
/// 注意同组别名（如 flac / lossless / sq）必须映射到同一标签，播放页
/// 依赖标签去重；dolby 与 atmos 是两档不同音质，标签必须可区分。
String qualityDisplayLabel(String quality) {
  final lower = quality.trim().toLowerCase();
  // low/super 是 one 系（moro.cn.mt）等插件使用的 MusicFree 语义档：
  // low ≈ 96k 及以下，super 在 high 之上（多对应无损）。
  if (lower == 'low') return '低清 96k';
  if (lower == '96k') return '低清 96k';
  if (lower == '128k' || lower == 'standard') return '标准 128k';
  if (lower == '192k') return '较高 192k';
  if (lower == '320k' || lower == 'high') return '高品质 320k';
  if (lower == 'flac' || lower == 'lossless' || lower == 'sq' || lower == 'super') {
    return '无损 FLAC';
  }
  if (lower == 'flac24bit') return '无损 FLAC Hires';
  if (lower == 'hires' || lower == 'hi-res' || lower.contains('24bit')) {
    return 'Hi-Res 无损';
  }
  if (lower == 'vinyl') return '黑胶转录';
  if (lower == 'atmos_plus') return '全景声 2.0';
  if (lower == 'atmos') return '全景声';
  if (lower == 'dolby') return '杜比全景声';
  if (lower.contains('master')) return '超清母带';
  if (lower == 'ape') return 'APE 无损';
  if (lower == 'wav') return 'WAV 无损';
  return quality;
}

/// 音质档位排序权重（低 → 高），播放页/下载弹窗按此排序展示，
/// 与设置页“在线默认音质”的档位顺序保持一致。未知档位排在最后。
int qualityTierRank(String quality) {
  final lower = quality.trim().toLowerCase();
  const ranks = <String, int>{
    'low': 0,
    '96k': 0,
    '128k': 1,
    'standard': 1,
    '192k': 2,
    '320k': 3,
    'high': 3,
    'flac': 4,
    'lossless': 4,
    'sq': 4,
    'super': 4,
    'ape': 4,
    'wav': 4,
    'flac24bit': 5,
    'hires': 6,
    'hi-res': 6,
    'vinyl': 7,
    'dolby': 8,
    'atmos': 9,
    'atmos_plus': 10,
    'master': 11,
  };
  if (ranks.containsKey(lower)) return ranks[lower]!;
  if (lower.contains('master')) return 11;
  if (lower.contains('24bit')) return 5;
  return 12;
}

const _qualityDiscoveryFallback = [
  '128k',
  '192k',
  '320k',
  'flac',
  'lossless',
  'hires',
  'hi-res',
  'master',
  'sq',
  'ape',
  'wav',
  'dolby',
  'atmos',
];

/// 同步读取插件歌曲快照中声明的音质标识（公开包装）。
/// 供下载弹窗秒开时先填充音质列表，无需等待插件逐档联网探测。
List<String> declaredQualityTokens(dynamic value) =>
    _qualityTokensFromRaw(value);

/// 从插件歌曲快照中提取插件声明的音质标识。不同 MusicFree/LX 插件
/// 使用的字段并不统一，因此这里兼容 qualities、formats、_types 等常见
/// 结构，同时保留插件自己的 token（例如 master、hires、24bit）。
List<String> _qualityTokensFromRaw(dynamic value) {
  final result = <String>{};
  const containerKeys = {
    'qualities',
    'quality',
    'formats',
    'format',
    'availablequalities',
    'qualityoptions',
    'audioqualities',
    'types',
    '_types',
    'lx_types',
  };
  const qualityKeyPattern =
      r'^(?:size|bitrate|quality|format|type)[_\-]?(\d+|flac|lossless|ape|wav|master|hires|hi-res|dolby|atmos).*$';

  void add(dynamic token) {
    final text = token?.toString().trim() ?? '';
    if (text.isEmpty || text.length > 40) return;
    if (RegExp(r'^(?:https?|https?)://', caseSensitive: false).hasMatch(text)) {
      return;
    }
    result.add(text);
  }

  void visit(dynamic node, {bool collect = false}) {
    if (node is List) {
      for (final item in node) {
        visit(item, collect: collect);
      }
      return;
    }
    if (node is! Map) {
      if (collect && (node is String || node is num)) add(node);
      return;
    }
    if (collect) {
      add(
        node['quality'] ??
            node['format'] ??
            node['type'] ??
            node['code'] ??
            node['value'] ??
            node['id'],
      );
    }
    for (final entry in node.entries) {
      final key = entry.key.toString();
      final lower = key.toLowerCase().replaceAll('-', '').replaceAll('_', '');
      final value = entry.value;
      if (containerKeys.contains(lower)) {
        if (value is Map) {
          for (final child in value.entries) {
            add(child.key);
            final childValue = child.value;
            if (childValue is Map) {
              add(
                childValue['quality'] ??
                    childValue['format'] ??
                    childValue['type'] ??
                    childValue['code'] ??
                    childValue['value'] ??
                    childValue['id'],
              );
            } else if (childValue is String &&
                !RegExp(
                  r'^https?://',
                  caseSensitive: false,
                ).hasMatch(childValue)) {
              add(childValue);
            }
          }
        } else {
          visit(value, collect: true);
        }
      }
      final match = RegExp(
        qualityKeyPattern,
        caseSensitive: false,
      ).firstMatch(key);
      if (match != null) {
        final suffix = match.group(1) ?? '';
        add(
          suffix == '128' || suffix == '192' || suffix == '320'
              ? '${suffix}k'
              : suffix,
        );
      }
      if (value is Map || value is List) visit(value, collect: false);
    }
  }

  visit(value);
  return result.toList();
}

/// 读取插件管理页记录的插件下载源 URL（id → 安装时的下载地址）。
Map<String, String> _readPluginSourceUrls(
  SharedPreferences prefs,
  String key,
) {
  final raw = prefs.getString(key);
  if (raw == null || raw.isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const {};
    return {
      for (final entry in decoded.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  } catch (_) {
    return const {};
  }
}

/// animemusic 分发端点生成的插件 META.api 与脚本下载地址同主机但指向
/// 默认端口（80），而后端实际运行在订阅源端口上（如 animemusic 的
/// 19844）。对照插件的下载源 URL：同主机、api 未带显式端口、源 URL
/// 带端口时，把 api 端口改写成源端口。
String _rewriteAnimemusicApiPort(String api, String sourceUrl) {
  if (api.isEmpty || sourceUrl.isEmpty) return api;
  final apiUri = Uri.tryParse(api);
  final sourceUri = Uri.tryParse(sourceUrl);
  if (apiUri == null || sourceUri == null) return api;
  if (!apiUri.hasScheme ||
      apiUri.host.isEmpty ||
      apiUri.host != sourceUri.host) {
    return api;
  }
  final apiDefaultPort = !apiUri.hasPort || apiUri.port == 80;
  if (!apiDefaultPort || !sourceUri.hasPort || sourceUri.port == 80) {
    return api;
  }
  return apiUri.replace(port: sourceUri.port).toString();
}

Future<List<EnabledMusicPlugin>> loadEnabledMusicPlugins(Ref ref) async {
  const enabledKey = 'mobileEnabledPlugins';
  const sourceUrlsKey = 'mobilePluginSourceUrlsV1';
  final dataDir = await ref.read(appDataDirProvider.future);
  final directory = Directory(p.join(dataDir, 'plugins'));
  if (!directory.existsSync()) return const [];
  final prefs = await SharedPreferences.getInstance();
  final enabled = (prefs.getStringList(enabledKey) ?? const []).toSet();
  final savedVariables = readPluginUserVariables(prefs);
  final sourceUrls = _readPluginSourceUrls(prefs, sourceUrlsKey);
  final displayNames = readPluginDisplayNames(prefs);
  final sourceLabels = readPluginSourceLabels(prefs);
  final kinds = readPluginKinds(prefs);
  final plugins = <EnabledMusicPlugin>[];
  for (final file in directory.listSync().whereType<File>()) {
    if (p.extension(file.path).toLowerCase() != '.js') continue;
    final id = p.basenameWithoutExtension(file.path);
    if (!enabled.contains(id)) continue;
    final source = await file.readAsString();
    final isLx = _looksLikeLxPlugin(source);
    final isAnimemusic = !isLx && _looksLikeAnimemusicPlugin(source);
    final animemusicMeta =
        isAnimemusic ? _extractAnimemusicMeta(source) : const <String, String>{};
    final metadata = PluginMetadata.parse(source);
    // animemusic 的 module.exports 导出的是变量而非对象字面量，
    // PluginMetadata 取不到名称时回退 META.name。
    var pluginName = metadata.name ?? id;
    final metaName = animemusicMeta['name']?.trim() ?? '';
    if (isAnimemusic && metaName.isNotEmpty) pluginName = metaName;
    // 订阅索引声明的显示名优先：脚本混淆/无元信息时也能显示正确名称。
    final overrideName = displayNames[id]?.trim() ?? '';
    if (overrideName.isNotEmpty) pluginName = overrideName;
    // 分类优先级与插件管理页一致：LX > BakaMusic > animemusic。BakaMusic
    // 只是兼容 MusicFree 协议（官方插件无 animeSrc、内容同构），靠订阅类型
    // 提示与来源 URL 判定；提示是明确意图（导入分栏/订阅结构/手动改类），
    // 优先于 URL，URL 仅在提示缺失时兜底——同 ID 插件被另一族覆盖时来源
    // URL 会从旧插件继承，若 URL 优先会把 MusicFree 插件误标成 BakaMusic。
    var isBaka = !isLx && !isAnimemusic && metadata.isBaka;
    if (!isLx && !isAnimemusic) {
      final kindHint = kinds[id];
      if (kindHint == pluginKindBaka) {
        isBaka = true;
      } else if (kindHint == pluginKindMusicFree ||
          kindHint == pluginKindOther) {
        // 手动归入「其他」的插件按 MusicFree 族处理，不强制 Baka 契约。
        isBaka = false;
      } else if (PluginMetadata.isBakaSourceUrl(sourceUrls[id] ?? '')) {
        isBaka = true;
      }
    }
    plugins.add(
      EnabledMusicPlugin(
        id: id,
        name: pluginName,
        path: file.path,
        isLx: isLx,
        lxSources: isLx ? _detectLxSources(source, name: pluginName) : const [],
        isBaka: isBaka,
        isAnimemusic: isAnimemusic,
        sourceLabel: sourceLabels[id],
        animemusicApi:
            (savedVariables[id]?['api']?.trim().isNotEmpty == true
                ? savedVariables[id]!['api']!.trim()
                : _rewriteAnimemusicApiPort(
                    animemusicMeta['api']?.trim().isNotEmpty == true
                        ? animemusicMeta['api']!.trim()
                        // v2/v3 聚合插件没有 META.api，从脚本 API_URL 提取，
                        // 供歌词/评论直连后端兜底。
                        : _extractAnimemusicFallbackApi(source),
                    sourceUrls[id] ?? '',
                  )),
        animemusicPlatform:
            animemusicMeta['platform']?.trim().isNotEmpty == true
            ? animemusicMeta['platform']!.trim()
            : 'wy',
        animemusicQualities:
            animemusicMeta['qualities']?.trim().isNotEmpty == true
            ? (animemusicMeta['qualities']!
                  .split(',')
                  .map((item) => item.trim())
                  .where((item) => item.isNotEmpty)
                  .toList())
            : const ['128k', '192k', '320k', 'flac'],
        userVariables: savedVariables[id] ?? const {},
        sourceUrl: sourceUrls[id] ?? '',
        availableMethods: metadata.availableMethods,
      ),
    );
  }
  // 插件管理页拖拽保存的顺序即搜索页 Tab 的优先级；未记录顺序的插件
  // （新安装）按名称排序追加在末尾。
  final orderedIds = prefs.getStringList(pluginOrderKey) ?? const [];
  if (orderedIds.isNotEmpty) {
    final byId = {for (final plugin in plugins) plugin.id: plugin};
    final ordered = <EnabledMusicPlugin>[
      for (final id in orderedIds)
        if (byId.containsKey(id)) byId.remove(id)!,
    ];
    ordered.addAll(plugins.where((plugin) => byId.containsKey(plugin.id)));
    return ordered;
  }
  plugins.sort((a, b) => a.name.compareTo(b.name));
  return plugins;
}

/// SharedPreferences 中持久化插件拖拽顺序的键（插件 ID 列表，从上到下）。
const pluginOrderKey = 'mobilePluginOrder';

/// SharedPreferences 中持久化插件用户变量的键：{pluginId: {key: value}}。
const pluginUserVariablesKey = 'mobilePluginUserVariablesV1';

/// SharedPreferences 中持久化插件显示名的键：{pluginId: name}。
/// 订阅索引声明的显示名在安装时写入：脚本被混淆/不含元信息（解析不到
/// 名称）时，重新加载列表仍能显示订阅源给的正确名称，而不是回退成插件 ID。
const pluginDisplayNamesKey = 'mobilePluginDisplayNamesV1';

/// SharedPreferences 中持久化插件订阅来源类型的键：
/// {pluginId: 'baka'|'musicfree'|'lx'|'animemusic'|'other'}。
///
/// BakaMusic 是 MusicFree 的衍生契约，两者脚本同构（都导出
/// module.exports + search/getMediaSource，第三方 MusicFree 通用插件
/// 还可能为兼容 Baka 而附带 getMvSource），**内容层无法可靠区分**。
/// 因此在导入时按订阅源响应结构记录类型，分类时优先于内容静态检测，
/// 使在线导入的 baka / 洛雪 / musicfree 分栏不再出错。
const pluginKindsKey = 'mobilePluginKindsV1';

/// 订阅类型标识（与插件管理页 _PluginKind 的分栏名对齐）。
const pluginKindBaka = 'baka';
const pluginKindMusicFree = 'musicfree';
const pluginKindLx = 'lx';
const pluginKindAnimemusic = 'animemusic';

/// 「其他」分栏：不属于上述任一契约族、或用户手动归位的插件。
/// 仅影响插件管理页的分栏展示，播放仍按脚本内容自动识别契约；
/// 运行时按 MusicFree 族处理，不强制 Baka 契约。
const pluginKindOther = 'other';

/// 读取插件订阅类型覆盖表，只保留合法字符串键值。
Map<String, String> readPluginKinds(SharedPreferences prefs) {
  try {
    final raw = prefs.getString(pluginKindsKey);
    if (raw == null || raw.isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    return {
      for (final entry in decoded.entries)
        if (entry.value is String && (entry.value as String).trim().isNotEmpty)
          entry.key.toString(): (entry.value as String).trim(),
    };
  } catch (_) {
    return {};
  }
}

/// 读取全部插件的显示名覆盖表，只保留合法的字符串键值。
Map<String, String> readPluginDisplayNames(SharedPreferences prefs) {
  try {
    final raw = prefs.getString(pluginDisplayNamesKey);
    if (raw == null || raw.isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    return {
      for (final entry in decoded.entries)
        if (entry.value is String && (entry.value as String).trim().isNotEmpty)
          entry.key.toString(): (entry.value as String).trim(),
    };
  } catch (_) {
    return {};
  }
}

/// SharedPreferences 中持久化插件「来源标签」的键：{pluginId: 'IKUN'|'聆澜'}。
///
/// 多租户订阅源（如 BakaMusic 的 music.cwo.cc.cd）对同一插件按 `?source=`
/// 发放不同授权的脚本：文件名与 platform 都相同（同名「QQ音乐」），内容却
/// 不同。安装时需在插件 ID 上带来源后缀才能并存（见插件管理页），但 ID 只
/// 用于磁盘文件与内部引用、不适合展示，故额外记录来源标签，由音源列表在
/// 名称旁渲染徽标，用户一眼看出这条音源来自 IKUN 还是聆澜。
const pluginSourceLabelsKey = 'mobilePluginSourceLabelsV1';

/// 读取插件来源标签表，只保留合法的字符串键值。
Map<String, String> readPluginSourceLabels(SharedPreferences prefs) {
  try {
    final raw = prefs.getString(pluginSourceLabelsKey);
    if (raw == null || raw.isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    return {
      for (final entry in decoded.entries)
        if (entry.value is String && (entry.value as String).trim().isNotEmpty)
          entry.key.toString(): (entry.value as String).trim(),
    };
  } catch (_) {
    return {};
  }
}

/// 读取全部插件的用户变量，只保留合法的字符串键值。
Map<String, Map<String, String>> readPluginUserVariables(
  SharedPreferences prefs,
) {
  try {
    final raw = prefs.getString(pluginUserVariablesKey);
    if (raw == null) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    return {
      for (final entry in decoded.entries)
        if (entry.value is Map)
          entry.key.toString(): {
            for (final variable in (entry.value as Map).entries)
              if (variable.value is String)
                variable.key.toString(): variable.value as String,
          },
    };
  } catch (_) {
    return {};
  }
}

/// 即使插件已停用，也尽量从仍存在的脚本中读取原显示名；插件文件已删除时
/// 返回 null，由调用方使用歌曲快照或插件 ID 兜底。
Future<String?> loadInstalledMusicPluginName(Ref ref, String pluginId) async {
  final normalizedId = pluginId.trim();
  if (normalizedId.isEmpty) return null;
  try {
    final dataDir = await ref.read(appDataDirProvider.future);
    final file = File(p.join(dataDir, 'plugins', '$normalizedId.js'));
    if (!await file.exists()) return null;
    final metadata = PluginMetadata.parse(await file.readAsString());
    return metadata.name?.trim().isNotEmpty == true
        ? metadata.name!.trim()
        : normalizedId;
  } catch (_) {
    return null;
  }
}

bool _looksLikeLxPlugin(String source) {
  // 先排除 MusicFree/BakaMusic 家族契约：混合契约插件（同时支持
  // BakaMusic/MusicFree/LX）只在兼容判断里读取 globalThis.lx，主导出
  // 仍是 MusicFree 对象，若判为 LX 会用错误的契约驱动插件。
  if (PluginMetadata.looksLikeMusicFreeContract(source)) return false;
  final lower = source.toLowerCase();
  return lower.contains('lx.event.request') ||
      lower.contains('lx.event.on') ||
      lower.contains('globalthis.lx') ||
      // 压缩/混淆后的落雪插件通常写成 globalThis['lx']，不能只依赖
      // 点号形式，否则会被误判为 MusicFree 插件而无法加载。
      RegExp(r'''globalthis\s*\[\s*['"]lx['"]\s*\]''').hasMatch(lower) ||
      lower.contains('event_names.request') ||
      lower.contains('server_script_config') ||
      // 与 PluginMetadata._detectLx 保持一致的混淆变体特征（照搬 XianYu
      // plugin_engine.isLxPluginScript）：lx.on(...)/lx.send(...) 调用形式；
      // 仅同时出现 globalThis 与 EVENT_NAMES；以及 \uXXXX 转义形态。
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

List<String> _detectLxSources(String source, {String? name}) {
  const supported = ['kw', 'kg', 'tx', 'wy', 'mg'];
  // 优先取插件自报的音源：LX 插件通过
  // lx.send(lx.EVENT_NAMES.inited, { sources: { <音源>: {...} } }) 声明它
  // 支持哪些音源。照搬 XianYu 读声明音源的做法（本软件不执行脚本，改为
  // 静态提取）；未适配插件可能只支持五平台中的一部分，声明列表比「脚本
  // 里出现过哪些平台名」更准。宿主内置搜索（Rust lxSearch）只认五平台，
  // 故与五平台取交集，交集为空时退回后面的兜底。
  final declared = _extractLxInitedSources(source)
      .where(supported.contains)
      .toList();
  if (declared.isNotEmpty) return declared;
  final found = <String>[];
  for (final id in supported) {
    if (RegExp("(?:['\"])?$id(?:['\"])?\\s*[:=]").hasMatch(source) ||
        RegExp("['\"]$id['\"]").hasMatch(source)) {
      found.add(id);
    }
  }
  if (found.isNotEmpty) return found;
  // 脚本里完全没有平台 key 时按插件名兜底推断（酷我/酷狗/QQ/网易/咪咕），
  // 对齐 XianYu 的 lxPlatformCodeOf。
  final byName = _lxPlatformCodeByName(name ?? '');
  if (byName != null) return [byName];
  return supported;
}

/// 按插件显示名推断 LX 平台码（XianYu `lxPlatformCodeOf` 的等价实现）。
String? _lxPlatformCodeByName(String name) {
  final lower = name.toLowerCase();
  if (lower.contains('酷我') || lower.contains('kuwo')) return 'kw';
  if (lower.contains('酷狗') || lower.contains('kugou')) return 'kg';
  if (lower.contains('qq') || lower.contains('企鹅')) return 'tx';
  if (lower.contains('网易') || lower.contains('netease')) return 'wy';
  if (lower.contains('咪咕') || lower.contains('migu')) return 'mg';
  return null;
}

/// 从 LX 插件脚本里静态提取 `sources: { ... }` 对象的顶层 key（音源名）。
///
/// 优先取 `inited` 之后的 `sources`（压缩脚本里可能先出现同名对象）；
/// 按花括号配对只收集顶层 key，跳过字符串/注释与嵌套对象。
List<String> _extractLxInitedSources(String source) {
  bool isIdentStart(int c) =>
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      c == 0x5F ||
      c == 0x24;
  bool isIdentPart(int c) => isIdentStart(c) || (c >= 0x30 && c <= 0x39);

  final pattern = RegExp(r"""['"]?sources['"]?\s*:\s*\{""");
  final initedIndex = source.indexOf('inited');
  RegExpMatch? chosen;
  for (final match in pattern.allMatches(source)) {
    if (initedIndex >= 0 && match.start < initedIndex) continue;
    chosen = match;
    break;
  }
  chosen ??= pattern.firstMatch(source);
  if (chosen == null) return const [];

  final n = source.length;
  final keys = <String>[];
  var depth = 0;
  var i = chosen.end; // sources 对象的 '{' 之后
  var expectKey = true;
  while (i < n) {
    final ch = source.codeUnitAt(i);
    if (ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D) {
      i++;
      continue;
    }
    if (ch == 0x27 || ch == 0x22 || ch == 0x60) {
      final quote = ch;
      var j = i + 1;
      while (j < n) {
        final c = source.codeUnitAt(j);
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
      if (depth == 0 && expectKey) {
        var after = j;
        while (after < n && source.codeUnitAt(after) <= 0x20) {
          after++;
        }
        if (after < n && source.codeUnitAt(after) == 0x3A) {
          keys.add(source.substring(i + 1, j - 1));
          i = after + 1;
          expectKey = false;
          continue;
        }
      }
      i = j;
      expectKey = false;
      continue;
    }
    if (ch == 0x2F && i + 1 < n) {
      final next = source.codeUnitAt(i + 1);
      if (next == 0x2F) {
        while (i < n && source.codeUnitAt(i) != 0x0A) {
          i++;
        }
        continue;
      }
      if (next == 0x2A) {
        i += 2;
        while (i + 1 < n &&
            !(source.codeUnitAt(i) == 0x2A && source.codeUnitAt(i + 1) == 0x2F)) {
          i++;
        }
        i += 2;
        continue;
      }
    }
    if (ch == 0x7B || ch == 0x5B) {
      depth++;
      i++;
      expectKey = false;
      continue;
    }
    if (ch == 0x7D || ch == 0x5D) {
      if (ch == 0x7D && depth == 0) break; // sources 对象结束
      depth--;
      i++;
      expectKey = false;
      continue;
    }
    if (depth == 0 && expectKey && isIdentStart(ch)) {
      var j = i;
      while (j < n && isIdentPart(source.codeUnitAt(j))) {
        j++;
      }
      var after = j;
      while (after < n && source.codeUnitAt(after) <= 0x20) {
        after++;
      }
      if (after < n && source.codeUnitAt(after) == 0x3A) {
        keys.add(source.substring(i, j));
        i = after + 1;
        expectKey = false;
        continue;
      }
      i = j;
      expectKey = false;
      continue;
    }
    if (ch == 0x2C && depth == 0) {
      expectKey = true;
      i++;
      continue;
    }
    expectKey = false;
    i++;
  }

  const blocked = {
    'name',
    'type',
    'actions',
    'qualitys',
    'qualities',
    'id',
    'version',
    'description',
    'author',
    'status',
    'message',
    'sources',
  };
  final result = <String>[];
  for (final key in keys) {
    final normalized = key.trim().toLowerCase();
    if (normalized.isEmpty || blocked.contains(normalized)) continue;
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(normalized)) continue;
    if (!result.contains(normalized)) result.add(normalized);
  }
  return result;
}

/// animemusic/1 插件识别：脚本内 META.format 声明自有格式，本体是
/// CommonJS Node 模块（require http/https/zlib），无法在 QuickJS 中执行。
bool _looksLikeAnimemusicPlugin(String source) =>
    RegExp(
      r'''["']format["']\s*:\s*["']animemusic/1["']''',
    ).hasMatch(source) ||
    RegExp(r'''module\.exports\s*=\s*\w+''').hasMatch(source) &&
        source.contains('animemusic/1');

/// 提取 animemusic/1 插件 `const META = { ... }` 中的关键字段。
/// META 由分发端点实时生成、保证是单行合法 JSON，这里按行截取后解码；
/// 解码失败时退回逐字段正则，尽量拿到 api/platform/qualities。
Map<String, String> _extractAnimemusicMeta(String source) {
  final match = RegExp(
    r'const\s+META\s*=\s*(\{[^\n;]+\})\s*;',
  ).firstMatch(source);
  if (match == null) return const {};
  try {
    final decoded = jsonDecode(match.group(1)!) as Map;
    return {
      for (final key in const ['name', 'platform', 'version', 'author', 'api'])
        if (decoded[key] != null && decoded[key].toString().trim().isNotEmpty)
          key: decoded[key].toString(),
      if (decoded['qualities'] is List)
        'qualities': (decoded['qualities'] as List)
            .map((item) => item.toString())
            .join(','),
    };
  } catch (_) {
    return const {};
  }
}

/// 从惜梦聚合插件（v2 洛雪版 / v3 MusicFree 版）脚本中提取后端地址：
/// 两类脚本都以 `const API_URL = ".../index.php"` 声明后端，并调用
/// `/music/url` 路由解析播放地址；本体只实现播放，歌词与评论由宿主
/// 按该地址直连 REST 兜底。
String _extractAnimemusicFallbackApi(String source) {
  if (!source.contains('/music/url')) return '';
  final match = RegExp(
    r'''API_URL\s*=\s*["'](https?://[^"']*?/index\.php(?:\?[^"']*)?)["']''',
  ).firstMatch(source);
  if (match != null) return match.group(1)!.trim();
  // baka 版（animemusic.bzxhkj.com/baka）：无 API_URL 常量，脚本以
  // FALLBACK_BASE（站点根）拼接 `?route=music/url` 调用；站点根实际
  // 只有数据面板，REST 入口在 /v1/index.php（与 v2/v3/v4 的 API_URL
  // 同源）。提取站点根后补全入口路径。
  final base = RegExp(
    r'''(?:FALLBACK_BASE|DEFAULT_BASE)\s*=\s*["'](https?://[^"']+?)["']''',
  ).firstMatch(source);
  final origin = base?.group(1)?.trim().replaceAll(RegExp(r'/+$'), '');
  if (origin == null || origin.isEmpty) return '';
  return '$origin/v1/index.php';
}

final enabledMusicPluginsProvider = FutureProvider<List<EnabledMusicPlugin>>(
  loadEnabledMusicPlugins,
);

final pluginRuntimeProvider = Provider<PluginRuntimeService>((ref) {
  final service = PluginRuntimeService();
  ref.onDispose(service.dispose);
  return service;
});

class PluginRuntimeService {
  /// quickjs_engine 的定时器支持不完整，这里补全浏览器语义：
  /// ① setTimeout 把延时原样透传给 Dart 侧 Timer（按 int 解码），插件
  ///   传浮点延时（如 kw.js 歌单分页的 200 + Math.random() * 100）时
  ///   Dart 侧抛类型错误，Timer 永不创建、await 的 Promise 永远挂起，
  ///   表现为歌单导入 30 秒超时——包裹一层先取整再转发；
  /// ② 引擎完全没有 clearTimeout/setInterval/queueMicrotask，插件
  ///   （如 moro/onemusic 混淆系列）在超时控制里调用 clearTimeout 会
  ///   抛 ReferenceError，且被插件自身 catch 后包装成各种误导性错误
  ///   （“unexpected data at the end”、“搜索服务不可用”等）。
  /// clearTimeout 无法真正取消 Dart 侧 Timer，改为把引擎回调表中对
  /// 应回调替换为空函数，Timer 到期时无害执行；setInterval 用
  /// setTimeout 链式调度实现。setTimeout 的返回值取引擎的全局计数
  /// （每次调用自增，与回调表索引一致），setInterval 的 id 用独立
  /// 大偏移序列避免与 setTimeout 撞号。
  static const String timerCompatibilityShim = '''
    (function (nativeSetTimeout) {
      var intervalBase = 1000000000;
      var intervalSeq = 0;
      var intervals = new Map();
      function nativeTimerIndex() {
        var counter = globalThis.__NATIVE_FLUTTER_JS__setTimeoutCount;
        return typeof counter === 'number' ? counter : -1;
      }
      function clearTimer(id) {
        var idx = Number(id);
        if (!Number.isInteger(idx)) return;
        intervals.delete(idx);
        if (idx >= 0 && idx < intervalBase) {
          var table = globalThis.__NATIVE_FLUTTER_JS__setTimeoutCallbacks;
          if (table) {
            var key = String(idx);
            if (key in table) table[key] = function () {};
          }
        }
      }
      function runInterval(id, fn, delay, args) {
        nativeSetTimeout(function () {
          if (!intervals.has(id)) return;
          try {
            fn.apply(null, args);
          } finally {
            if (intervals.has(id)) runInterval(id, fn, delay, args);
          }
        }, delay);
      }
      globalThis.setTimeout = function (fn, delay) {
        var args = Array.prototype.slice.call(arguments, 2);
        nativeSetTimeout(function () {
          if (typeof fn === 'function') fn.apply(null, args);
        }, Math.round(Number(delay) || 0));
        return nativeTimerIndex();
      };
      globalThis.clearTimeout = clearTimer;
      globalThis.setInterval = function (fn, delay) {
        var args = Array.prototype.slice.call(arguments, 2);
        var id = intervalBase + (++intervalSeq);
        intervals.set(id, true);
        runInterval(
            id, fn, Math.max(1, Math.round(Number(delay) || 1)), args);
        return id;
      };
      globalThis.clearInterval = clearTimer;
      if (typeof globalThis.queueMicrotask !== 'function') {
        globalThis.queueMicrotask = function (fn) {
          Promise.resolve().then(fn);
        };
      }
    })(globalThis.setTimeout);
  ''';

  PluginRuntimeService({
    this.httpClient,
    this.runtimeBootstrap,
    this.runtimeLxBootstrap,
    this.pluginSources = const {},
  });

  final http.BaseClient? httpClient;
  final String? runtimeBootstrap;
  final String? runtimeLxBootstrap;
  final Map<String, String> pluginSources;
  JavascriptRuntime? _runtime;
  // 常驻插件工作 isolate：QuickJS 运行时与已加载插件全程复用，
  // 消除每次操作都要冷启动 JS 引擎并重新 eval 插件源码的开销
  // （该开销是纯 CPU 负载，省电调度下会被放大数秒，表现为部分
  // 机型播放加载特别慢）。
  _PluginWorker? _pluginWorker;
  Future<_PluginWorker>? _pluginWorkerTask;
  Future<void>? _initializing;
  int _activeRuntimeOperations = 0;
  bool _disposeRequested = false;
  Future<String>? _runtimeBootstrapTask;
  final Set<String> _loaded = {};
  final Set<String> _loadedLx = {};
  final Map<String, Future<void>> _loadTasks = {};
  final Map<String, Future<String>> _pluginSourceTasks = {};
  final Map<String, _NeteaseTrackMeta> _neteaseTrackMetaCache = {};
  final Map<String, Future<List<String>>> _qualityDiscoveryCache = {};

  /// 上述两张表都按歌曲/插件维度常驻，长时间在线播放会持续累积；
  /// 加硬上限并按插入顺序淘汰最旧条目，避免常驻内存随播放时长攀升。
  static const int _neteaseTrackMetaCacheLimit = 256;
  static const int _qualityDiscoveryCacheLimit = 64;

  /// 已解析播放源的短时缓存：同一首歌曲短时间内重复播放（切歌回切、
  /// 下一首预取）时直接复用 URL，跳过插件网络解析。音源返回的 CDN
  /// 地址普遍只有几分钟时效，TTL 取保守的 5 分钟，并限制条目数量。
  static const Duration _mediaSourceCacheTtl = Duration(minutes: 5);
  static const int _mediaSourceCacheMaxEntries = 12;
  final Map<String, _MediaSourceCacheEntry> _mediaSourceCache = {};

  /// 已把插件源码同步给常驻 worker 的插件集合：worker 收到源码后会在
  /// 自身缓存（pluginSources），后续请求无需重复携带——每次搜索/切歌
  /// 都跨 isolate 同步拷贝数百 KB 源码字符串，会在低端机（32 位）主
  /// isolate 上造成可感知的卡顿。worker 崩溃重启后集合清空重新同步。
  final Set<String> _pluginSourceSyncedToWorker = {};

  bool get _runsPluginsInBackground =>
      httpClient == null && runtimeBootstrap == null;

  Future<void> _ensureRuntime() => _initializing ??= _initializeRuntime();

  Future<void> _initializeRuntime() async {
    final runtime = getJavascriptRuntime(
      xhr: false,
      extraArgs: const {'stackSize': 4 * 1024 * 1024},
    );
    try {
      xhrSetHttpClient(httpClient ?? _PluginProxyHttpClient());
      runtime.enableXhr();
      final bootstrap =
          runtimeBootstrap ??
          await rootBundle.loadString('assets/plugin_runtime.js');
      final result = runtime.evaluate(
        bootstrap,
        sourceUrl: 'xy_plugin_runtime.js',
      );
      if (result.isError) throw Exception(result.stringResult);
      final wrapTimers = runtime.evaluate(timerCompatibilityShim);
      if (wrapTimers.isError) {
        throw Exception(wrapTimers.stringResult);
      }
      final lxBootstrap =
          runtimeLxBootstrap ??
          await rootBundle.loadString('assets/lx_plugin_runtime.js');
      final lxResult = runtime.evaluate(
        lxBootstrap,
        sourceUrl: 'xy_lx_plugin_runtime.js',
      );
      if (lxResult.isError) throw Exception(lxResult.stringResult);
      _runtime = runtime;
    } catch (_) {
      runtime.dispose();
      _initializing = null;
      rethrow;
    }
  }

  Future<void> _ensurePlugin(EnabledMusicPlugin plugin) {
    if (_loaded.contains(plugin.id)) return Future.value();
    return _loadTasks
        .putIfAbsent(plugin.id, () async {
          await _ensureRuntime();
          final source = await _loadPluginSource(plugin);
          final code =
              '__xyLoadMusicFreePlugin('
              '${jsonEncode(plugin.id)},${jsonEncode(source)},'
              '${jsonEncode(jsonEncode(plugin.userVariables))})';
          final result = _runtime!.evaluate(
            code,
            sourceUrl: p.basename(plugin.path),
          );
          if (result.isError) {
            throw Exception(_friendlyError(result.stringResult));
          }
          final decoded = _decodeResult(result.stringResult);
          if (decoded is! Map) throw Exception('插件初始化返回格式无效');
          _loaded.add(plugin.id);
        })
        .whenComplete(() => _loadTasks.remove(plugin.id));
  }

  Future<String> _loadPluginSource(EnabledMusicPlugin plugin) {
    final bundled = pluginSources[plugin.id];
    if (bundled != null) return Future.value(bundled);
    return _pluginSourceTasks.putIfAbsent(
      plugin.id,
      () async {
        // 插件文件可能在订阅更新/去重合并后被重写或删除，而探索页等
        // 缓存仍持有旧插件对象。文件缺失时给出可操作的提示，而不是
        // 抛出裸 PathNotFoundException。
        final file = File(plugin.path);
        if (!await file.exists()) {
          throw Exception(
            '插件「${plugin.name}」的脚本文件已不存在（可能刚被音源更新'
            '或卸载），请刷新页面或到 设置 → 插件 重新启用后重试',
          );
        }
        return file.readAsString();
      },
    );
  }

  Future<void> _ensureLxPlugin(EnabledMusicPlugin plugin) {
    if (_loadedLx.contains(plugin.id)) return Future.value();
    return _loadTasks
        .putIfAbsent('${plugin.id}:lx', () async {
          await _ensureRuntime();
          final source = await _loadPluginSource(plugin);
          final result = _runtime!.evaluate(
            '__xyLoadLxPlugin(${jsonEncode(plugin.id)},${jsonEncode(source)})',
            sourceUrl: p.basename(plugin.path),
          );
          if (result.isError) {
            throw Exception(_friendlyError(result.stringResult));
          }
          final decoded = _decodeResult(result.stringResult);
          if (decoded is! Map || decoded['ok'] != true) {
            throw Exception('LX 插件初始化返回格式无效');
          }
          _loadedLx.add(plugin.id);
        })
        .whenComplete(() => _loadTasks.remove('${plugin.id}:lx'));
  }

  Future<dynamic> _callLxOnCurrentIsolate(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> request,
  ) async {
    _activeRuntimeOperations++;
    try {
      await _ensureLxPlugin(plugin);
      final expression =
          '__xyCallLxPlugin(${jsonEncode(plugin.id)},'
          '${jsonEncode(request)})';
      final promise = _runtime!.evaluate(expression);
      if (promise.isError) {
        throw Exception(_friendlyError(promise.stringResult));
      }
      final result = await _runtime!.handlePromise(
        promise,
        timeout: const Duration(seconds: 30),
      );
      if (result.isError) {
        throw Exception(_friendlyError(result.stringResult));
      }
      return _decodeResult(result.stringResult);
    } finally {
      _activeRuntimeOperations--;
      if (_activeRuntimeOperations == 0 && _disposeRequested) {
        _disposeNow();
      }
    }
  }

  Future<dynamic> _callOnCurrentIsolate(
    EnabledMusicPlugin plugin,
    String method,
    List<dynamic> args,
  ) async {
    _activeRuntimeOperations++;
    try {
      await _ensurePlugin(plugin);
      final expression =
          '__xyCallMusicFreePlugin('
          '${jsonEncode(plugin.id)},${jsonEncode(method)},${jsonEncode(jsonEncode(args))})';
      final promise = _runtime!.evaluate(expression);
      if (promise.isError) {
        throw Exception(_friendlyError(promise.stringResult));
      }
      final result = await _runtime!.handlePromise(
        promise,
        timeout: const Duration(seconds: 30),
      );
      if (result.isError) {
        throw Exception(_friendlyError(result.stringResult));
      }
      final decoded = _decodeResult(result.stringResult);
      if (decoded is! Map) throw Exception('插件返回格式无效');
      if (decoded['ok'] != true) {
        throw Exception(
          _friendlyError(decoded['error']?.toString() ?? '插件调用失败'),
        );
      }
      return decoded['data'];
    } finally {
      _activeRuntimeOperations--;
      if (_activeRuntimeOperations == 0 && _disposeRequested) {
        _disposeNow();
      }
    }
  }

  Future<dynamic> _runPluginOperation(
    EnabledMusicPlugin plugin,
    String operation,
    dynamic payload,
  ) async {
    final pluginSource = await _loadPluginSource(plugin);
    // 源码只需同步一次：worker 收到请求时会先写入自身缓存再执行操作，
    // 因此 run() 成功返回即可标记已同步；尚未同步时才携带全量源码，
    // 避免每次请求都在主 isolate 上同步拷贝大字符串。
    final sourceAlreadySynced = _pluginSourceSyncedToWorker.contains(
      plugin.id,
    );
    Object? reply;
    try {
      final worker = await _ensurePluginWorker();
      reply = await worker.run(<String, Object?>{
        'operation': operation,
        'pluginId': plugin.id,
        'pluginName': plugin.name,
        'pluginPath': plugin.path,
        'pluginSource': sourceAlreadySynced ? '' : pluginSource,
        'userVariables': jsonEncode(plugin.userVariables),
        'payload': jsonEncode(payload),
      });
      if (!sourceAlreadySynced) {
        _pluginSourceSyncedToWorker.add(plugin.id);
      }
    } on Exception {
      // 常驻工作 isolate 拉起失败或中途崩溃/卡死：回退到一次性
      // 冷启动 isolate，保证插件功能依然可用。
      return _runPluginOperationCold(plugin, operation, payload, pluginSource);
    }
    if (reply is! Map || reply['ok'] != true) {
      throw Exception(
        _friendlyError(
          (reply is Map ? reply['error'] : null)?.toString() ?? '后台插件调用失败',
        ),
      );
    }
    return reply['data'];
  }

  /// 一次性冷启动执行（常驻工作 isolate 不可用时的回退路径）。
  Future<dynamic> _runPluginOperationCold(
    EnabledMusicPlugin plugin,
    String operation,
    dynamic payload,
    String pluginSource,
  ) async {
    final bootstrap = await (_runtimeBootstrapTask ??= rootBundle.loadString(
      'assets/plugin_runtime.js',
    ));
    final lxBootstrap = await rootBundle.loadString(
      'assets/lx_plugin_runtime.js',
    );
    final request = <String, String>{
      'operation': operation,
      'pluginId': plugin.id,
      'pluginName': plugin.name,
      'pluginPath': plugin.path,
      'pluginSource': pluginSource,
      'bootstrap': bootstrap,
      'lxBootstrap': lxBootstrap,
      'userVariables': jsonEncode(plugin.userVariables),
      'payload': jsonEncode(payload),
    };
    final responseText = await Isolate.run(
      () => _executePluginOperationInBackground(request),
      debugName: 'music-plugin-${plugin.id}-$operation',
    );
    final response = jsonDecode(responseText);
    if (response is! Map) throw Exception('后台插件返回格式无效');
    if (response['ok'] != true) {
      throw Exception(
        _friendlyError(response['error']?.toString() ?? '后台插件调用失败'),
      );
    }
    return response['data'];
  }

  /// 惰性拉起常驻插件工作 isolate；已存在时直接复用。
  Future<_PluginWorker> _ensurePluginWorker() {
    final worker = _pluginWorker;
    if (worker != null) return Future.value(worker);
    return _pluginWorkerTask ??= _PluginWorker.spawn().then((spawned) {
      spawned.onDead = () {
        if (_pluginWorker == spawned) {
          _pluginWorker = null;
          _pluginWorkerTask = null;
          // 新 worker 的源码缓存为空，源码同步标记一并清空，
          // 下次调用重新携带全量源码。
          _pluginSourceSyncedToWorker.clear();
        }
      };
      _pluginWorker = spawned;
      return spawned;
    }).catchError((Object error) {
      _pluginWorkerTask = null;
      throw error;
    });
  }

  Future<List<PluginSearchSong>> search(
    EnabledMusicPlugin plugin,
    String keyword, {
    String? lxSource,
  }) async {
    if (plugin.isLx) {
      return _searchLxPlugin(plugin, keyword, onlySource: lxSource);
    }
    if (plugin.isAnimemusic) {
      return _searchAnimemusic(plugin, keyword);
    }
    dynamic response;
    Object? pluginError;
    try {
      response = _runsPluginsInBackground
          ? await _runPluginOperation(plugin, 'search', keyword)
          : await _callOnCurrentIsolate(plugin, 'search', [
              keyword,
              1,
              'music',
            ]);
    } catch (error) {
      if (!_isQqMusicPlugin(plugin)) rethrow;
      pluginError = error;
    }

    var list = _extractResultList(response);
    if (list.isEmpty && _isQqMusicPlugin(plugin)) {
      try {
        list = await _searchQqWebFallback(keyword);
      } catch (fallbackError) {
        if (pluginError != null) {
          throw Exception(
            'QQ音乐搜索失败：${_friendlyError(pluginError.toString())}；'
            '备用接口失败：${_friendlyError(fallbackError.toString())}',
          );
        }
        rethrow;
      }
    }
    if (list.isNotEmpty &&
        (_isNeteaseMusicPlugin(plugin) || list.any(_looksLikeNeteaseTrack))) {
      list = await _backfillNeteaseTrackMeta(list);
    }
    var songs = list
        .map((raw) => _toSearchSong(plugin.id, _resetMediaItem(plugin, raw)))
        .toList();
    // 惜梦系插件搜索空结果兜底：baka 版脚本的 FALLBACK_BASE（站点根）
    // 部署上没有 API 路由，插件自身搜索会静默失败返回空，由宿主直连
    // 后端 music/search 补齐。
    if (songs.isEmpty && plugin.animemusicApi.trim().isNotEmpty) {
      try {
        songs = await _searchAnimemusic(plugin, keyword);
      } catch (_) {
        // 后端不可用时维持空结果。
      }
    }
    // 听书类插件（如 one-酷我听书）声明仅支持 album 类型搜索，music
    // 类型永远为空；回退 album 搜索并把最相关专辑的全部章节展平为
    // 歌曲，让默认「歌曲」Tab 也能直接搜到可点播的章节。
    if (songs.isEmpty) {
      try {
        final albums = await _searchMusicFreeType(plugin, keyword, 'album');
        if (albums.isNotEmpty) {
          final album = _toCatalogResult(
            plugin.id,
            albums.first,
            artist: false,
          );
          final chapters = await getAlbumSongs(plugin, album);
          if (chapters.isNotEmpty) return chapters;
        }
      } catch (_) {
        // album 兜底失败维持空结果。
      }
    }
    return songs;
  }

  /// 获取歌手详情中的歌曲，沿用桌面端的 getArtistWorks 逻辑。
  /// 插件未实现详情接口时才回退到按歌手名搜索。
  Future<List<PluginSearchSong>> getArtistSongs(
    EnabledMusicPlugin plugin,
    PluginCatalogResult artist, {
    String? lxSource,
  }) async {
    if (plugin.isLx) {
      return _searchLxPlugin(plugin, artist.title, onlySource: lxSource);
    }
    if (plugin.isAnimemusic) {
      // animemusic/1 单平台插件：suggest 结果带 animeSrc+id 时直连
      // 后端 music/artist 取热门歌曲（qishui 等平台后端未开放时接口
      // 返回空列表，回退按歌手名搜索）。
      final artistPlatform =
          artist.rawData['animeSrc']?.toString().trim() ?? '';
      final artistId = artist.rawData['id']?.toString().trim() ?? '';
      if (artistPlatform.isNotEmpty && artistId.isNotEmpty) {
        try {
          final songs = await _getAnimemusicArtistSongs(
            plugin,
            artistPlatform,
            artistId,
            name: artist.title,
          );
          if (songs.isNotEmpty) return songs;
        } catch (_) {
          // 后端不可用：回退按歌手名搜索。
        }
      }
      return _searchAnimemusic(plugin, artist.title);
    }
    // 惜梦系歌手热门歌曲：searchArtists 的 suggest 结果带 animeSrc+id，
    // 直连后端 music/artist 取热门歌曲（分页）。
    final artistPlatform = artist.rawData['animeSrc']?.toString().trim() ?? '';
    final artistId = artist.rawData['id']?.toString().trim() ?? '';
    if (artistPlatform.isNotEmpty &&
        artistId.isNotEmpty &&
        plugin.animemusicApi.trim().isNotEmpty) {
      final songs = await _getAnimemusicArtistSongs(
        plugin,
        artistPlatform,
        artistId,
        name: artist.title,
      );
      if (songs.isNotEmpty) return songs;
    }
    if (!plugin.mayHaveMethod('getArtistWorks')) {
      // 未适配/精简插件只实现 search + getMediaSource，调用缺失的详情
      // 方法会直接抛错；照 XianYu 逻辑改为按歌手名搜索回退。
      return search(plugin, artist.title);
    }
    try {
      Future<List<Map<String, dynamic>>> fetchPage(int page) async {
        final response = _runsPluginsInBackground
            ? await _runPluginOperation(plugin, 'getArtistWorks', {
                'rawData': artist.rawData,
                'page': page,
                'type': 'music',
              })
            : await _callOnCurrentIsolate(plugin, 'getArtistWorks', [
                artist.rawData,
                page,
                'music',
              ]);
        return _extractResultList(response);
      }

      // B 站用户作品接口默认每页约 20～30 首，必须继续请求后续页。
      // 不能用“本页少于 20 首”作为结束条件：不同版本插件的 page size
      // 不一致，恰好 20 首时会被误认为只有一页。发现空页或重复页后停止，
      // 避免某些旧插件忽略 page 参数时死循环。
      final pages = <Map<String, dynamic>>[];
      final seenItemKeys = <String>{};
      Object? pageError;
      // B 站 UP 主作品数量可能远超一页；上限只用于防止异常插件忽略
      // page 参数时无限请求，正常情况下会在空页或重复页提前结束。
      final maxPages = _isBilibiliPlugin(plugin) ? 100 : 1;
      for (var page = 1; page <= maxPages; page++) {
        late final List<Map<String, dynamic>> current;
        try {
          current = await fetchPage(page);
        } catch (error) {
          // 某些插件在后续页触发限流/接口错误；保留已经成功取得的
          // 页面，避免整个详情页回退到只返回 20 首的普通搜索结果。
          pageError = error;
          break;
        }
        if (current.isEmpty) break;
        final newItems = current
            .where((item) {
              // B 站部分插件会把 UP 主 mid 放进通用 id 字段，导致同一
              // 页内所有作品被误判为重复；视频 ID 必须优先使用。
              final id =
                  item['bvid'] ??
                  item['aid'] ??
                  item['cid'] ??
                  item['videoId'] ??
                  item['id'] ??
                  item['songId'] ??
                  item['musicId'] ??
                  item['mid'];
              final identity = id?.toString().trim() ?? '';
              final description =
                  '${item['title'] ?? item['name'] ?? ''}|'
                  '${item['artist'] ?? item['author'] ?? ''}|'
                  '${item['duration'] ?? item['length'] ?? ''}';
              // 某些 B 站插件的通用 id 实际是 UP 主 mid；把标题等
              // 描述字段并入去重键，既能保留同一 UP 主的不同作品，
              // 又能识别后续页是否只是重复返回第一页。
              final key = identity.isNotEmpty
                  ? (_isBilibiliPlugin(plugin)
                        ? '$identity|$description'
                        : identity)
                  : description;
              return seenItemKeys.add(key);
            })
            .toList(growable: false);
        if (newItems.isEmpty) break;
        pages.addAll(newItems);
      }
      var list = pages;
      if (list.isNotEmpty) {
        // 歌手作品接口与专辑接口同样可能缺封面（网易 hotSongs 的
        // al.picUrl 缺失时只剩数值 picId），这里与搜索路径保持一致补全。
        if (_isNeteaseMusicPlugin(plugin) || list.any(_looksLikeNeteaseTrack)) {
          list = await _backfillNeteaseTrackMeta(list);
        }
        // 常见的 B 站插件忽略 page 参数，getArtistWorks 只返回第一页
        // （约 30 条）。检测到翻页没有新增内容时，改由宿主直接调用
        // B 站空间投稿接口拉取 UP 主的全部投稿。
        if (_isBilibiliPlugin(plugin) && list.length <= 30) {
          try {
            final direct = await _fetchBilibiliSpaceArcs(artist.rawData);
            if (direct.length > list.length) {
              return direct
                  .map(
                    (raw) =>
                        _toSearchSong(plugin.id, _resetMediaItem(plugin, raw)),
                  )
                  .toList();
            }
          } catch (_) {
            // 直连接口不可用时保留插件返回的第一页结果。
          }
        }
        return list
            .map(
              (raw) => _toSearchSong(plugin.id, _resetMediaItem(plugin, raw)),
            )
            .toList();
      }
      if (pageError != null) throw pageError;
    } catch (_) {
      // 与桌面端一致：详情接口不可用时回退到普通歌曲搜索。
    }
    return search(plugin, artist.title);
  }

  /// 获取专辑详情中的歌曲，沿用桌面端的 getAlbumInfo 逻辑。
  /// 插件未实现详情接口时才回退到按专辑名搜索并过滤。
  Future<List<PluginSearchSong>> getAlbumSongs(
    EnabledMusicPlugin plugin,
    PluginCatalogResult album, {
    String? lxSource,
  }) async {
    if (plugin.isLx) {
      return _searchLxPlugin(plugin, album.title, onlySource: lxSource);
    }
    if (plugin.isAnimemusic) {
      // animemusic/1 单平台插件：suggest 结果带 animeSrc+id 时直连
      // 后端 music/album 取专辑曲目；空结果（qishui 等平台后端未
      // 开放）回退按专辑名搜索。
      final albumPlatform =
          album.rawData['animeSrc']?.toString().trim() ?? '';
      final albumId = album.rawData['id']?.toString().trim() ?? '';
      if (albumPlatform.isNotEmpty && albumId.isNotEmpty) {
        try {
          final songs = await _getAnimemusicAlbumSongs(
            plugin,
            albumPlatform,
            albumId,
          );
          if (songs.isNotEmpty) return songs;
        } catch (_) {
          // 后端不可用：回退按专辑名搜索。
        }
      }
      return _searchAnimemusic(plugin, album.title);
    }
    // 惜梦系专辑歌曲：searchAlbums 的 suggest 结果带 animeSrc+id，
    // 直连后端 music/album 取专辑曲目；kw 上游无歌曲列表，空结果
    // 继续走按专辑名搜索的回退。
    final albumPlatform = album.rawData['animeSrc']?.toString().trim() ?? '';
    final albumId = album.rawData['id']?.toString().trim() ?? '';
    if (albumPlatform.isNotEmpty &&
        albumId.isNotEmpty &&
        plugin.animemusicApi.trim().isNotEmpty) {
      final songs = await _getAnimemusicAlbumSongs(
        plugin,
        albumPlatform,
        albumId,
      );
      if (songs.isNotEmpty) return songs;
    }
    if (!plugin.mayHaveMethod('getAlbumInfo')) {
      // 未实现专辑详情接口时直接按专辑名搜索并过滤（照 XianYu 回退逻辑）。
      return _searchAlbumFallback(plugin, album.title);
    }
    try {
      // 听书类插件（如 one-酷我听书）一次只回一页章节，一本有声书
      // 可达数百集；按 isEnd 循环翻页取全量，id 去重 + 页数上限防死循环。
      final collected = <Map<String, dynamic>>[];
      final seenIds = <String>{};
      for (var page = 1; page <= 20; page++) {
        final response = _runsPluginsInBackground
            ? await _runPluginOperation(plugin, 'getAlbumInfo', {
                'rawData': album.rawData,
                'page': page,
              })
            : await _callOnCurrentIsolate(plugin, 'getAlbumInfo', [
                album.rawData,
                page,
              ]);
        final list = _extractResultList(response);
        if (list.isEmpty) break;
        final before = collected.length;
        for (final raw in list) {
          final id = raw['id']?.toString() ?? '';
          if (id.isNotEmpty && !seenIds.add(id)) continue;
          collected.add(raw);
        }
        if (collected.length == before) break;
        if (response is Map && response['isEnd'] == true) break;
      }
      if (collected.isNotEmpty) {
        // 部分接口（如网易 weapi/v1/album）对 OST 专辑不返回 al.picUrl，
        // 只给超出 JS 安全整数的数值 picId，插件层无法还原封面；统一走
        // song/detail 补全，与搜索路径行为一致。
        var songs = collected;
        if (_isNeteaseMusicPlugin(plugin) || songs.any(_looksLikeNeteaseTrack)) {
          songs = await _backfillNeteaseTrackMeta(songs);
        }
        return songs
            .map(
              (raw) => _toSearchSong(plugin.id, _resetMediaItem(plugin, raw)),
            )
            .toList();
      }
    } catch (_) {
      // 与桌面端一致：详情接口不可用时回退到普通歌曲搜索。
    }
    return _searchAlbumFallback(plugin, album.title);
  }

  /// 专辑详情接口缺失或不可用时，按专辑名搜索并过滤同名专辑曲目。
  Future<List<PluginSearchSong>> _searchAlbumFallback(
    EnabledMusicPlugin plugin,
    String title,
  ) async {
    final results = await search(plugin, title);
    final target = title.trim().toLowerCase();
    return results.where((song) {
      final value = song.album.trim().toLowerCase();
      return value == target ||
          value.contains(target) ||
          target.contains(value);
    }).toList();
  }

  /// 搜索插件歌手。MF 直接调用插件的 artist 类型；LX 仅保留歌手名匹配的结果。
  Future<List<PluginCatalogResult>> searchArtists(
    EnabledMusicPlugin plugin,
    String keyword, {
    String? lxSource,
  }) async {
    if (plugin.isLx) {
      final songs = await _searchLxPlugin(
        plugin,
        keyword,
        onlySource: lxSource,
      );
      return _aggregateLxCatalog(
        plugin.id,
        songs,
        keyword: keyword,
        artist: true,
      );
    }
    // animemusic/1 单平台插件：直连后端 music/suggest 的 singers 分组
    // （v4/baka 等聚合插件同样依赖此兜底）；后端未开放该平台
    // （如 qishui）时接口报错，返回空列表优雅降级。
    if (plugin.isAnimemusic) {
      try {
        return await _searchAnimemusicCatalog(plugin, keyword, artist: true);
      } catch (_) {
        return const [];
      }
    }
    // 惜梦系插件（v2/v3/v4/baka）：声明 supportedSearchType 仅 music，
    // 歌手搜索走后端 music/suggest 的 singers 分组。
    if (plugin.animemusicApi.trim().isNotEmpty) {
      try {
        final artists = await _searchAnimemusicCatalog(
          plugin,
          keyword,
          artist: true,
        );
        if (artists.isNotEmpty) return artists;
      } catch (_) {
        // suggest 不可用时回退插件 artist 类型搜索。
      }
    }
    // Bilibili 的“歌手”实际上是 UP 主。部分插件把用户搜索暴露为
    // user 类型，另一些插件仍使用 artist 类型；优先尝试 user，并且
    // 只接受带有 mid/uid/uname 等用户字段的结果，避免把视频搜索结果
    // 误显示成歌手。
    List<Map<String, dynamic>> list = const [];
    Object? lastError;
    if (_isBilibiliPlugin(plugin)) {
      // B 站歌手分类实际对应用户/UP 主。即便 user 和 artist 类型都
      // 返回了内容，也只能接受明确带用户身份字段的对象；不能把未匹配
      // 的候选内容继续当作 UP 主，否则会把专辑或歌曲标题显示在这里。
      for (final type in const ['user', 'artist']) {
        try {
          final candidate = await _searchMusicFreeType(plugin, keyword, type);
          final users = candidate.where(_looksLikeBilibiliUser).toList();
          if (users.isNotEmpty) {
            list = users;
            break;
          }
        } catch (error) {
          lastError = error;
        }
      }
    } else {
      try {
        list = await _searchMusicFreeType(plugin, keyword, 'artist');
      } catch (error) {
        lastError = error;
      }
    }
    if (list.isEmpty && lastError != null) throw lastError;
    return list
        .map(
          (raw) => _toCatalogResult(
            plugin.id,
            _resetMediaItem(plugin, raw),
            artist: true,
          ),
        )
        .where((item) => item.title.isNotEmpty)
        .toList();
  }

  static bool _looksLikeBilibiliUser(Map<String, dynamic> raw) {
    const fields = [
      'mid',
      'uid',
      'userId',
      'user_id',
      'uname',
      'upic',
      'userName',
      'nickname',
      'username',
      // B 站插件会把 bili_user 结果标准化成 name/id/avatar，
      // 而不是保留接口原始的 uname/mid 字段。
      'id',
      'name',
      'avatar',
      'avatarUrl',
    ];
    final hasIdentity = fields.any((key) {
      final value = raw[key];
      return value != null && value.toString().trim().isNotEmpty;
    });
    if (!hasIdentity) return false;
    // 搜索接口有时会把视频对象混在 user/artist 响应中；这些字段说明
    // 当前对象是歌曲/视频，而不是 UP 主资料。
    const mediaFields = [
      'bvid',
      'aid',
      'songmid',
      'songId',
      'musicId',
      'duration',
      'durationMs',
      'album',
      'albumId',
      'singer',
      'artist',
      'songName',
      'trackName',
    ];
    return !mediaFields.any(
      (key) => raw[key]?.toString().trim().isNotEmpty == true,
    );
  }

  /// 搜索插件专辑。MF 直接调用插件的 album 类型；LX 仅保留专辑名匹配的结果。
  Future<List<PluginCatalogResult>> searchAlbums(
    EnabledMusicPlugin plugin,
    String keyword, {
    String? lxSource,
  }) async {
    if (plugin.isLx) {
      final songs = await _searchLxPlugin(
        plugin,
        keyword,
        onlySource: lxSource,
      );
      return _aggregateLxCatalog(
        plugin.id,
        songs,
        keyword: keyword,
        artist: false,
      );
    }
    // animemusic/1 单平台插件：直连后端 music/suggest 的 albums 分组；
    // 后端未开放该平台（如 qishui）时返回空列表优雅降级。
    if (plugin.isAnimemusic) {
      try {
        return await _searchAnimemusicCatalog(plugin, keyword, artist: false);
      } catch (_) {
        return const [];
      }
    }
    // 惜梦系插件（v2/v3/v4/baka）：专辑搜索走后端 music/suggest 的
    // albums 分组。
    if (plugin.animemusicApi.trim().isNotEmpty) {
      try {
        final albums = await _searchAnimemusicCatalog(
          plugin,
          keyword,
          artist: false,
        );
        if (albums.isNotEmpty) return albums;
      } catch (_) {
        // suggest 不可用时回退插件 album 类型搜索。
      }
    }
    final list = await _searchMusicFreeType(plugin, keyword, 'album');
    return list
        .map(
          (raw) => _toCatalogResult(
            plugin.id,
            _resetMediaItem(plugin, raw),
            artist: false,
          ),
        )
        .where((item) => item.title.isNotEmpty)
        .toList();
  }

  /// 搜索插件歌单/专辑，用于探索页的个性化歌单推荐和搜索页歌单分类。
  /// 不同 MusicFree 插件对歌单类型的命名并不完全一致，优先尝试
  /// sheet，空结果时再回退 playlist；推荐场景可额外回退 album。
  Future<List<PluginCatalogResult>> searchPlaylists(
    EnabledMusicPlugin plugin,
    String keyword, {
    bool includeAlbums = true,
  }) async {
    if (plugin.isLx) return const [];
    if (plugin.isAnimemusic) return const [];
    List<Map<String, dynamic>> list = const [];
    final types = includeAlbums
        ? const ['sheet', 'playlist', 'album']
        : const ['sheet', 'playlist'];
    for (final type in types) {
      try {
        list = await _searchMusicFreeType(plugin, keyword, type);
      } catch (_) {
        continue;
      }
      if (list.isNotEmpty) break;
    }
    return list
        .map(
          (raw) => _toCatalogResult(
            plugin.id,
            _resetMediaItem(plugin, raw),
            artist: false,
          ),
        )
        .where((item) => item.title.isNotEmpty)
        .toList();
  }

  /// 获取插件提供的热门榜单。MusicFree 插件统一通过 getTopLists 暴露榜单，
  /// 结果可能是扁平列表，也可能按分类嵌套在 data 中，因此统一转换为目录项。
  Future<List<PluginCatalogResult>> getTopLists(
    EnabledMusicPlugin plugin,
  ) async {
    if (plugin.isLx) return const [];
    // animemusic/1 单平台插件（如 qishui）：直连后端 music/toplist。
    if (plugin.isAnimemusic) return _getAnimemusicTopLists(plugin);
    if (!plugin.mayHaveMethod('getTopLists')) return const [];
    try {
      final response = _runsPluginsInBackground
          ? await _runPluginOperation(plugin, 'getTopLists', null)
          : await _callOnCurrentIsolate(plugin, 'getTopLists', []);
      return _extractTopListItems(response)
          .map(
            (raw) => _toCatalogResult(
              plugin.id,
              _resetMediaItem(plugin, raw),
              artist: false,
            ),
          )
          .where((item) => item.title.isNotEmpty)
          .toList();
    } catch (_) {
      // 目录接口容错：未实现/报错的插件返回空榜单，不阻断推荐页。
      return const [];
    }
  }

  /// 获取某个热门榜单内的歌曲，用于推荐页混入不依赖个人喜好的
  /// 大众热门内容（类似 BakaMusic 推荐歌单的获取思路）。
  /// [fetchAll] 为 true 时取全榜单曲目（榜单详情页使用，分页拉取到
  /// 后端返回的 total 为止），否则只取前 [limit] 首。
  Future<List<PluginSearchSong>> getTopListSongs(
    EnabledMusicPlugin plugin,
    PluginCatalogResult chart, {
    int limit = 40,
    bool fetchAll = false,
  }) async {
    if (plugin.isLx) return const [];
    // animemusic/1 单平台插件（如 qishui）：直连 music/toplist/detail。
    if (plugin.isAnimemusic) {
      return _getAnimemusicTopListSongs(
        plugin,
        chart,
        limit: limit,
        fetchAll: fetchAll,
      );
    }
    // 未实现榜单详情接口的插件无榜单可拉，直接返回空。
    if (!plugin.mayHaveMethod('getTopListDetail')) return const [];
    final songs = await _loadMusicFreePlaylistSongs(
      plugin,
      Map<String, dynamic>.from(chart.rawData),
      kind: 'top',
    );
    final limited = fetchAll ? songs : songs.take(limit);
    return limited
        .map((raw) => _toSearchSong(plugin.id, _resetMediaItem(plugin, raw)))
        .where((item) => item.title.trim().isNotEmpty)
        .toList();
  }

  Future<List<Map<String, dynamic>>> _searchMusicFreeType(
    EnabledMusicPlugin plugin,
    String keyword,
    String type,
  ) async {
    dynamic response;
    if (_runsPluginsInBackground) {
      response = await _runPluginOperation(plugin, 'search', {
        'keyword': keyword,
        'type': type,
      });
    } else {
      response = await _callOnCurrentIsolate(plugin, 'search', [
        keyword,
        1,
        type,
      ]);
    }
    return _extractResultList(response);
  }

  static PluginCatalogResult _toCatalogResult(
    String pluginId,
    Map<String, dynamic> raw, {
    required bool artist,
  }) {
    String valueText(dynamic value) {
      if (value == null) return '';
      if (value is String) {
        return value.replaceAll(RegExp(r'<[^>]*>'), '').trim();
      }
      if (value is num || value is bool) return value.toString();
      if (value is List) {
        return value.map(valueText).where((item) => item.isNotEmpty).join('/');
      }
      if (value is Map) {
        for (final key in const [
          'name',
          'title',
          'value',
          'artist',
          'singer',
          'author',
          'uname',
          'nickname',
          'username',
        ]) {
          final nested = valueText(value[key]);
          if (nested.isNotEmpty) return nested;
        }
      }
      return '';
    }

    String text(List<String> keys) {
      for (final key in keys) {
        final value = valueText(raw[key]);
        if (value.isNotEmpty) return value;
      }
      return '';
    }

    final title = artist
        ? text(const [
            'name',
            'title',
            'artist',
            'singer',
            'artistName',
            // Bilibili 用户搜索结果字段。
            'uname',
            'nickname',
            'username',
            'userName',
            'author_name',
            'authorName',
            'ownerName',
            'author',
          ])
        : text(const ['title', 'name', 'album', 'albumName', 'album_name']);
    final subtitle = artist
        ? text(const [
            'description',
            'desc',
            'usign',
            'sign',
            'albumCount',
            'songCount',
            'videoCount',
            'videos',
            'fans',
          ])
        : text(const ['artist', 'singer', 'artistName', 'albumArtist']);
    final id = text(
      artist
          ? const [
              'id',
              'artistId',
              'singerId',
              'artist_id',
              // Bilibili 用户主键及常见别名。
              'mid',
              'uid',
              'userId',
              'user_id',
            ]
          : const ['id', 'albumId', 'album_id', 'albumMid', 'album_mid'],
    );
    return PluginCatalogResult(
      pluginId: pluginId,
      id: id.isEmpty ? title : id,
      title: title,
      subtitle: subtitle,
      coverUrl: _extractCover(raw),
      rawData: raw,
    );
  }

  /// MusicFree 桌面端会在每次搜索/详情接口返回后调用 resetMediaItem，
  /// 把插件平台写回原始歌曲对象。部分插件的 getMediaSource 依赖这个
  /// 字段，尤其是 getArtistWorks/getAlbumInfo 返回的歌曲。
  static Map<String, dynamic> _resetMediaItem(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> raw,
  ) {
    final item = <String, dynamic>{...raw, 'platform': plugin.name};
    // 惜梦系插件（animemusicApi 非空）：后端开放 MV 的平台注入 mv
    // 标识让播放页显示 MV 按钮（hasMvIdentifier）；qishui 等平台后端
    // 未开放 MV，不注入以免按钮点击后解析失败。
    if (plugin.animemusicApi.trim().isNotEmpty &&
        item['mv'] == null &&
        item['mvId'] == null &&
        item['mvid'] == null &&
        // platform 被覆盖成插件名前，用原始 raw 判断后端平台。
        _animemusicSupportsMv(raw)) {
      item['mv'] = true;
    }
    return item;
  }

  /// animemusic 后端是否为该歌曲的平台开放 MV（music/mv/search）：
  /// 平台码（_src/_source/animeSrc/platform）需在 MV 画质表
  /// （kg/kw/wy/tx/mg/bilibili）中；qishui 等平台后端未开放 MV。
  static bool _animemusicSupportsMv(Map<String, dynamic> raw) {
    final starSeaSrc =
        raw['_src']?.toString().trim().isNotEmpty == true
            ? raw['_src'].toString().trim()
            : raw['_source']?.toString().trim() ?? '';
    final animeSrc = raw['animeSrc']?.toString().trim() ?? '';
    final rawPlatform = raw['platform']?.toString().trim() ?? '';
    final code = _toAnimemusicPlatformCode(
      starSeaSrc.isNotEmpty
          ? starSeaSrc
          : animeSrc.isNotEmpty
          ? animeSrc
          : rawPlatform,
    );
    return _animemusicMvQuality.containsKey(code);
  }

  static List<PluginCatalogResult> _aggregateLxCatalog(
    String pluginId,
    List<PluginSearchSong> songs, {
    required String keyword,
    required bool artist,
  }) {
    String normalize(String value) => value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(RegExp(r'[·•]'), '');

    final target = normalize(keyword);
    final seen = <String, PluginCatalogResult>{};
    for (final song in songs) {
      final title = (artist ? song.artist : song.album).trim();
      if (title.isEmpty) continue;
      final normalizedTitle = normalize(title);
      if (target.isNotEmpty &&
          !normalizedTitle.contains(target) &&
          !target.contains(normalizedTitle)) {
        continue;
      }
      final subtitle = artist ? song.album : song.artist;
      final key = '${title.toLowerCase()}\u0000${subtitle.toLowerCase()}';
      seen.putIfAbsent(
        key,
        () => PluginCatalogResult(
          pluginId: pluginId,
          id: '${song.id}:$key',
          title: title,
          subtitle: subtitle,
          coverUrl: song.coverUrl,
          rawData: song.rawData,
        ),
      );
    }
    return seen.values.toList();
  }

  Future<List<PluginSearchSong>> _searchLxPlugin(
    EnabledMusicPlugin plugin,
    String keyword, {
    String? onlySource,
  }) async {
    var sources = plugin.lxSources.isEmpty
        ? const ['kw', 'kg', 'tx', 'wy', 'mg']
        : plugin.lxSources;
    if (onlySource != null && onlySource.isNotEmpty) {
      sources = sources.contains(onlySource) ? [onlySource] : const [];
    }
    // 各平台并行请求：串行时总耗时为全部平台网络延迟之和（默认 5 个
    // 平台在弱网/低端机上搜索明显偏慢）。失败平台不影响其余平台，
    // 错误语义与原串行实现一致（全部失败且存在错误时抛出）。
    final responses = await Future.wait(
      sources.map((source) async {
        try {
          final rawJson = await lxSearch(
            source: source,
            keyword: keyword,
            limit: 30,
          ).timeout(const Duration(seconds: 20));
          return (source, rawJson, null as Object?);
        } catch (error) {
          return (source, null, error as Object?);
        }
      }),
    );
    final results = <PluginSearchSong>[];
    final seen = <String>{};
    Object? lastError;
    for (final (source, rawJson, error) in responses) {
      if (rawJson == null) {
        if (error != null) lastError = error;
        continue;
      }
      try {
        final decoded = jsonDecode(rawJson);
        if (decoded is! List) continue;
        for (final value in decoded.whereType<Map>()) {
          final raw = _normalizeLxSearchSong(
            source,
            Map<String, dynamic>.from(value),
          );
          final path = raw['_sourcePath']?.toString() ?? '';
          if (path.isEmpty || !seen.add(path)) continue;
          results.add(_toSearchSong(plugin.id, raw));
        }
      } catch (decodeError) {
        lastError = decodeError;
      }
    }
    if (results.isEmpty && lastError != null) {
      throw Exception('LX 搜索失败：${_friendlyError(lastError.toString())}');
    }
    return results;
  }

  static Map<String, dynamic> _normalizeLxSearchSong(
    String fallbackSource,
    Map<String, dynamic> raw,
  ) {
    final source = (raw['source'] ?? fallbackSource).toString();
    final songmid = (raw['songmid'] ?? raw['song_mid'] ?? raw['id'] ?? '')
        .toString();
    final name = (raw['name'] ?? raw['title'] ?? '').toString();
    final singer = (raw['singer'] ?? raw['artist'] ?? '').toString();
    final album = (raw['album_name'] ?? raw['albumName'] ?? raw['album'] ?? '')
        .toString();
    final rawInterval = raw['interval'] ?? raw['duration'];
    final interval = rawInterval is String
        ? rawInterval
        : rawInterval is num
        ? rawInterval.toString()
        : null;
    final durationMs = _parseDuration(raw);
    final lx = <String, dynamic>{
      'songmid': songmid,
      'source': source,
      'hash': raw['hash'],
      'name': name,
      'singer': singer,
      'albumName': album,
      'albumId': raw['album_id'] ?? raw['albumId'],
      'strMediaMid': raw['str_media_mid'] ?? raw['strMediaMid'],
      'songId': raw['song_id'] ?? raw['songId'],
      'albumMid': raw['album_mid'] ?? raw['albumMid'],
      'copyrightId': raw['copyright_id'] ?? raw['copyrightId'],
      // LyricSongInfo 需要这两个字段来正确识别 LX 返回的歌词和时长。
      'interval': interval,
      '_interval': durationMs > 0 ? durationMs : null,
      '_types': raw['lx_types'] ?? raw['_types'],
    };
    return {
      ...raw,
      'id': songmid,
      'title': name,
      'artist': singer,
      'album': album,
      'duration': raw['interval'] ?? raw['duration'] ?? 0,
      'artwork': raw['img'] ?? raw['artwork'] ?? '',
      'lx': lx,
      '_sourcePath': 'lx://$source/${Uri.encodeComponent(songmid)}',
    };
  }

  /// 按歌单 ID 或分享链接导入插件歌单。
  ///
  /// MusicFree 插件并没有统一的歌单导入实现：部分插件通过
  /// search(sheet) + getMusicSheetInfo 分页读取，另一些只实现
  /// importMusicSheet。这里按桌面端相同的顺序兼容两种协议。
  Future<PluginPlaylistImport> importPlaylist(
    EnabledMusicPlugin plugin,
    String idOrUrl,
  ) async {
    final input = idOrUrl.trim();
    if (input.isEmpty) throw Exception('请输入歌单 ID');
    final response = _runsPluginsInBackground
        ? await _runPluginOperation(plugin, 'importPlaylist', input)
        : await _importPlaylistOnCurrentIsolate(plugin, input);
    if (response is! Map) throw Exception('插件返回的歌单格式无效');
    var songs = _extractResultList(response['songs']);
    if (songs.isNotEmpty &&
        (_isNeteaseMusicPlugin(plugin) || songs.any(_looksLikeNeteaseTrack))) {
      songs = await _backfillNeteaseTrackMeta(songs);
    }
    if (songs.isEmpty) throw Exception('歌单为空，或该插件不支持歌单导入');
    return PluginPlaylistImport(
      name: response['name']?.toString().trim().isNotEmpty == true
          ? response['name'].toString().trim()
          : '${plugin.name}歌单',
      coverUrl: _normalizeImageUrl(response['coverUrl']?.toString() ?? ''),
      songs: songs.map((raw) => _toSearchSong(plugin.id, raw)).toList(),
    );
  }

  Future<Map<String, dynamic>> _importPlaylistOnCurrentIsolate(
    EnabledMusicPlugin plugin,
    String input,
  ) async {
    Object? lastError;
    // 分享文案（如「歌单｜我喜欢的音乐 https://qishui.douyin.com/s/xxx/
    // @汽水音乐」）不以 http 开头，不先抠出里面的链接就会整段文案进
    // 搜索路径，按名称巧合搜回无关歌单（汽水「对不上」的根因）。统一
    // 提取文案中第一条链接再走链接导入；提取不到时保留原文交由插件 /
    // 搜索路径处理。
    var effective = input;
    if (!_isHttpUrl(effective)) {
      final match = RegExp(
        r'''https?://[^\s@，,。、"“”'）)】]+''',
        caseSensitive: false,
      ).firstMatch(effective);
      if (match != null) effective = match.group(0)!;
    }
    final isPlainNumericId = RegExp(r'^\d+$').hasMatch(effective);

    // animemusic/1 单平台插件（如惜梦汽水）：脚本是 CommonJS Node 模块，
    // QuickJS 缺 http/https/zlib 内置模块无法执行，importMusicSheet 与
    // 搜索回退都会失败。宿主直连后端 music/import（分享文案 / 短链 /
    // 纯数字歌单 ID 通吃，后端自行解析），失败时给出明确错误，不再落
    // 入 QuickJS 路径产生误导性的报错。
    if (plugin.isAnimemusic) {
      final imported = await _importAnimemusicPlaylist(plugin, effective);
      if (imported != null) return imported;
      throw Exception('歌单为空，或该插件不支持歌单导入');
    }

    // 链接输入优先走插件原生 importMusicSheet：插件自己解析分享链接里的
    // 歌单 ID（如 QQ 链接 ...?id=2784566436），能拿到真实歌单名、封面和
    // 曲目。不能把整条链接当关键词传给 search——QQ 会返回一批以 URL
    // 片段命名的垃圾歌单，_bestMatchingPlaylist 按 ID 匹配不上时取第一条，
    // 最终导成完全无关的歌单（与前身 XianYu-Music-Mobile 相同的 bug）。
    if (_isHttpUrl(effective)) {
      // 短链（qishui.douyin.com/s/xxx 等）不含数字歌单 ID，而 QuickJS 的
      // XHR 是浏览器语义：重定向被自动跟随、插件读不到 3xx Location
      // （axios 的 maxRedirects:0 在浏览器适配器中被忽略），汽水短链必须
      // 由宿主代为解析重定向后用真实 URL 重试。链接里的纯数字歌单 ID 也
      // 作为兜底候选：酷我 newh5app 等新版链接格式插件正则可能未覆盖，
      // 但纯数字 ID 路径一定支持。
      final candidates = <String>[effective];
      final resolved = await _resolvePlaylistShortLink(effective);
      if (resolved != null && !candidates.contains(resolved)) {
        candidates.add(resolved);
      }
      for (final candidate in List.of(candidates)) {
        final id = _extractPlaylistIdFromUrl(candidate);
        if (id != null && !candidates.contains(id)) candidates.add(id);
      }
      // 汽水链接：插件 importMusicSheet 走 QuickJS XHR，大歌单（300KB+
      // 响应）会触发 xhr.dart 静默吞异常缺陷，回调永不执行、30 秒超
      // 时。宿主直连官方接口导入（参考 XianYu-Music-Desktop），直连
      // 失败再回退插件路径，两个方向都保底。
      if (_isQishuiPlugin(plugin) && _isQishuiLink(effective)) {
        try {
          final direct = await _importQishuiSheetDirect(plugin, effective);
          if (direct != null) return direct;
        } catch (_) {
          // 直连失败（接口变更/网络问题）时回退插件路径
        }
      }
      for (final candidate in candidates) {
        try {
          final imported = await _importViaImportMusicSheet(plugin, candidate);
          if (imported != null) return imported;
        } catch (error) {
          lastError = error;
        }
      }
      // URL 作为搜索关键词永远匹配不到目标歌单（QQ 的教训），链接导入
      // 失败时直接给出明确错误，不再落入搜索回退导入无关歌单。
      // 旧版 BakaMusic 契约插件只提供 importPlaylist 而无
      // importMusicSheet，明确引导更新插件而不是笼统地说「链接不匹配」。
      final message = lastError == null
          ? ''
          : _friendlyError(lastError.toString());
      throw Exception(
        message.contains('importMusicSheet')
            ? '该插件不支持链接导入歌单（可能版本较旧），请到 '
              '设置 → 插件 更新插件后重试，或换用其他音源插件'
            : message.isEmpty
                  ? '无法从该链接导入歌单，请确认链接与所选插件匹配'
                  : message,
      );
    }

    // 纯数字输入（酷狗码、歌单 ID）：先走插件整单导入，搜索回退放后。
    // 数字当关键词搜索返回的是名称巧合的无关歌单，按 ID 精确匹配不上
    // 时不应采用。
    if (isPlainNumericId) {
      // 汽水插件 + 纯 ID：同样优先宿主直连（插件 XHR 大响应挂起）
      if (_isQishuiPlugin(plugin)) {
        try {
          final direct = await _importQishuiSheetDirect(plugin, effective);
          if (direct != null) return direct;
        } catch (_) {
          // 直连失败回退插件路径
        }
      }
      try {
        final imported = await _importViaImportMusicSheet(plugin, effective);
        if (imported != null) return imported;
      } catch (error) {
        lastError = error;
      }
    }

    // 与电脑版一致：输入歌单名称时先让 MusicFree 插件搜索，这样能保留
    // 真实歌单名称、封面和插件自己的媒体字段。
    for (final type in const ['sheet', 'playlist', 'album']) {
      try {
        final searched = await _callOnCurrentIsolate(plugin, 'search', [
          input,
          1,
          type,
        ]);
        final sheets = _extractResultList(searched);
        if (sheets.isEmpty) continue;
        final sheet = _bestMatchingPlaylist(sheets, input);
        if (sheet == null) continue;
        final songs = await _loadMusicFreePlaylistSongs(
          plugin,
          sheet,
          kind: type == 'album' ? 'album' : 'sheet',
        );
        if (songs.isNotEmpty) {
          return {
            'name': _playlistName(sheet, plugin.name),
            'coverUrl': _extractCover(sheet),
            'songs': songs,
          };
        }
      } catch (error) {
        // 搜索回退的失败不应覆盖主路径错误：数字 ID 输入时
        // importMusicSheet 已失败（如 30 秒超时），若被回退路径里插件
        // 的内部错误（如 kw.js searchAlbum 读错字段报 map of
        // undefined）覆盖，用户看到的报错与真正失败原因完全无关。
        lastError ??= error;
      }
    }

    // 收藏夹/纯 ID 导入兼容路径，B 站、酷狗等插件常只实现此接口。
    // 纯数字输入在上面已经尝试过整单导入，不再重复。
    if (!isPlainNumericId) {
      try {
        final imported = await _importViaImportMusicSheet(plugin, input);
        if (imported != null) return imported;
      } catch (error) {
        lastError = error;
      }
    }

    // 电脑版的最后一层回退：部分插件不能搜索歌单，但提供排行榜列表。
    try {
      final response = await _callOnCurrentIsolate(plugin, 'getTopLists', []);
      final topLists = _extractTopListItems(response);
      if (topLists.isNotEmpty) {
        final sheet = _bestMatchingPlaylist(topLists, input);
        if (sheet != null) {
          final songs = await _loadMusicFreePlaylistSongs(
            plugin,
            sheet,
            kind: 'top',
          );
          if (songs.isNotEmpty) {
            return {
              'name': _playlistName(sheet, plugin.name),
              'coverUrl': _extractCover(sheet),
              'songs': songs,
            };
          }
        }
      }
    } catch (error) {
      // 与搜索回退同理：榜单回退的错误不应覆盖主路径错误。
      lastError ??= error;
    }
    throw Exception(
      lastError == null ? '该插件不支持歌单导入' : _friendlyError(lastError.toString()),
    );
  }

  /// 从歌单分享链接中提取纯数字歌单 ID（playlist_detail/123、
  /// playlist/123、pid=123、dissid=123、id=123 等常见格式）。
  static String? _extractPlaylistIdFromUrl(String url) {
    for (final pattern in [
      RegExp(r'playlist[_a-z]*[/=](\d{4,})', caseSensitive: false),
      RegExp(r'[?&]pid=(\d{4,})', caseSensitive: false),
      RegExp(r'[?&]dissid=(\d{4,})', caseSensitive: false),
      RegExp(r'[?&]id=(\d{4,})', caseSensitive: false),
    ]) {
      final match = pattern.firstMatch(url);
      if (match != null) return match.group(1);
    }
    return null;
  }

  /// 解析不含数字歌单 ID 的短链：宿主逐跳读取 3xx Location，直到拿到
  /// 带数字歌单 ID 的真实地址（最多 5 跳）。QuickJS 的 XHR 读不到重
  /// 定向 Location（浏览器语义自动跟随且 axios 的 maxRedirects:0 被
  /// 忽略），插件自身无法解析短链，必须由宿主代劳。
  ///
  /// 字节系短链服务会按客户端 TLS/请求指纹分流：部分客户端拿到 302，
  /// 另一部分直接返回 200 落地页（内嵌歌单数据）。因此采用三通道：
  /// 先走 Rust HTTP 层（follow:0 逐跳 Location），未拿到时再用
  /// dart:io HttpClient 逐跳重试（指纹不同，分流结果可能不同），仍拿
  /// 不到时最后用 Googlebot UA 重试——字节系服务对搜索引擎爬虫稳定
  /// 放行 302；任一通道遇到 200 页面时都会尝试从页面内容直接提取歌单
  /// ID 兜底（与 XianYu-Music-Desktop 的 resolveRedirectId 对齐）。
  Future<String?> _resolvePlaylistShortLink(String url) async {
    if (_extractPlaylistIdFromUrl(url) != null) return null;
    final viaRust = await _resolveShortLinkViaRust(url);
    if (viaRust != null) return viaRust;
    final viaDart = await _resolveShortLinkViaDartHttp(url);
    if (viaDart != null) return viaDart;
    return _resolveShortLinkViaDartHttp(url, userAgent: _googlebotUserAgent);
  }

  /// 从落地页内容中提取歌单 ID（og:url / 内嵌 JSON 等都会带
  /// playlist_id=xxx 之类的串），复用 URL 提取的同一组正则。
  static String? _extractPlaylistIdFromPage(String body) {
    if (body.isEmpty) return null;
    final id = _extractPlaylistIdFromUrl(body);
    if (id != null) return id;
    return RegExp(
      r'playlist_id[=/]([0-9]{6,})',
      caseSensitive: false,
    ).firstMatch(body)?.group(1);
  }

  /// Rust HTTP 层通道：follow:0 逐跳读 Location；200 时从页面提取 ID。
  Future<String?> _resolveShortLinkViaRust(String url) async {
    var current = url;
    for (var hop = 0; hop < 5; hop++) {
      try {
        final responseJson = await pluginHttpRequestBinary(
          method: 'GET',
          url: current,
          headersJson: jsonEncode(const {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
            'Accept': '*/*',
          }),
          timeout: BigInt.from(15),
          follow: 0,
        );
        final response = jsonDecode(responseJson) as Map<String, dynamic>;
        final status = (response['status'] as num?)?.toInt() ?? 0;
        if (status >= 300 && status < 400) {
          final headers = response['headers'];
          if (headers is! Map) return null;
          String? location;
          for (final entry in headers.entries) {
            if (entry.key.toString().toLowerCase() == 'location') {
              location = entry.value?.toString();
              break;
            }
          }
          if (location == null || location.trim().isEmpty) return null;
          final base = Uri.tryParse(current);
          final resolved = base?.resolve(location.trim()).toString();
          if (resolved == null || resolved == current) return null;
          if (_extractPlaylistIdFromUrl(resolved) != null) return resolved;
          current = resolved;
          continue;
        }
        if (status == 200) {
          // 不重定向而直接给落地页（指纹分流）：从页面内容提取 ID。
          final bodyBase64 = response['body_base64']?.toString() ?? '';
          final body = bodyBase64.isEmpty
              ? ''
              : utf8.decode(base64Decode(bodyBase64), allowMalformed: true);
          final id = _extractPlaylistIdFromPage(body);
          if (id != null) return id;
        }
        return null;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// dart:io HttpClient 通道：与 Rust 层指纹不同，作为短链被风控分流
  /// 时的第二通道。逐跳读 Location；200 时从页面内容提取 ID。
  /// [userAgent] 默认模拟安卓 Chrome，可传 Googlebot UA 作为第三通道。
  Future<String?> _resolveShortLinkViaDartHttp(
    String url, {
    String userAgent =
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
  }) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      var current = url;
      for (var hop = 0; hop < 5; hop++) {
        final request = await client.getUrl(Uri.parse(current))
          ..followRedirects = false
          ..maxRedirects = 0;
        request.headers.set(HttpHeaders.userAgentHeader, userAgent);
        request.headers.set(HttpHeaders.acceptHeader, '*/*');
        final response = await request.close();
        final status = response.statusCode;
        if (status >= 300 && status < 400) {
          final location =
              response.headers.value(HttpHeaders.locationHeader);
          if (location == null || location.trim().isEmpty) return null;
          final resolved =
              Uri.parse(current).resolve(location.trim()).toString();
          if (resolved == current) return null;
          if (_extractPlaylistIdFromUrl(resolved) != null) return resolved;
          current = resolved;
          continue;
        }
        if (status == 200) {
          final body = await response
              .transform(const Utf8Decoder(allowMalformed: true))
              .join();
          return _extractPlaylistIdFromPage(body);
        }
        return null;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client?.close();
    }
  }

  /// 用插件的 importMusicSheet 整单导入（分享链接的优先路径、纯 ID 的兼容路径）。
  ///
  /// 插件返回歌单对象（含真实标题/封面/musicList）时按对象取信息；返回
  /// 裸曲目列表时退回用插件名命名。返回 null 表示插件不支持或结果为空，
  /// 调用方继续走搜索路径。QQ 歌单单次整单导入约 999 首封顶（插件固定
  /// song_num=1000），大歌单用官方接口按 song_begin 偏移增量补齐。
  Future<Map<String, dynamic>?> _importViaImportMusicSheet(
    EnabledMusicPlugin plugin,
    String input,
  ) async {
    final imported = await _callOnCurrentIsolate(plugin, 'importMusicSheet', [
      input,
    ]);
    final songs = _extractResultList(imported)
        .map((song) => _resetMediaItem(plugin, song))
        .toList();
    if (songs.isEmpty) return null;
    if (imported is Map) {
      final sheet = Map<String, dynamic>.from(imported);
      if (_isQqMusicPlugin(plugin)) {
        songs.addAll(await _topUpQqDissSongs(plugin, sheet, songs));
      }
      return {
        'name': _playlistName(sheet, plugin.name),
        'coverUrl': _extractCover(sheet),
        'songs': songs,
      };
    }
    return {
      'name': '${plugin.name}歌单',
      'coverUrl': _extractCover(songs.first),
      'songs': songs,
    };
  }

  // ==================== 汽水歌单宿主直连导入 ====================
  // 参考 XianYu-Music-Desktop 的 playlistImportQishui.ts：汽水插件的
  // importMusicSheet 走 QuickJS XHR，大歌单响应（300KB 级）会触发
  // quickjs_engine xhr.dart Dart 侧回调链被静默吞异常的缺陷，Promise
  // 永久挂起直至 30 秒超时。因此汽水链接/ID 由宿主直接调官方接口导
  // 入：PC API（LunaPC UA）cursor 翻页取全，失败时 web 分享页
  // （Googlebot UA）兜底。歌曲字段结构与汽水插件 parseTrackItem 完
  // 全一致，播放与音质解析继续走插件管线（getMediaSource 只依赖
  // id 与 qualities）。

  static const String _googlebotUserAgent =
      'Mozilla/5.0 (compatible; Googlebot/2.1; '
      '+http://www.google.com/bot.html)';

  static const String _qishuiPcApiBase = 'https://api.qishui.com/luna/pc';
  static const String _qishuiWebShareUrl =
      'https://music.douyin.com/qishui/share/playlist';
  static const String _qishuiImageBase = 'https://p3-luna.douyinpic.com/img/';

  static const String _qishuiPcQuery =
      'aid=386088&app_name=luna_pc&region=cn&geo_region=cn&os_region=cn'
      '&sim_region=&device_id=2081836196178571&cdid=&iid=2081836182667'
      '&version_name=3.8.0&version_code=30080000&channel=official'
      '&build_mode=master&network_carrier=&ac=wifi&tz_name=Asia/Shanghai'
      '&resolution=&device_platform=windows&device_type=Windows'
      '&os_version=Windows%2011%20Pro%20for%20Workstations'
      '&fp=2081836196178571';

  static const Map<String, String> _qishuiPcHeaders = {
    'Accept': '*/*',
    'Content-Type': 'application/json; charset=utf-8',
    'Accept-Encoding': 'gzip, deflate',
    'User-Agent': 'LunaPC/3.8.0(467160162)',
    'x-luna-background-type': 'foreground',
    'x-luna-is-background-req': '0',
    'x-luna-is-local-user': '0',
  };

  static const Map<String, String> _qishuiWebShareHeaders = {
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'User-Agent': _googlebotUserAgent,
  };

  /// 汽水原始音质标识 → baka 系音质键（与汽水插件一致）。
  static const Map<String, String> _qishuiQualityToBaka = {
    'medium': '128k',
    'higher': '192k',
    'highest': '320k',
    'lossless': 'flac',
    'hi_res': 'hires',
    'spatial': 'atmos',
  };

  static const Map<String, int> _qishuiQualityFallbackBitrate = {
    'medium': 128000,
    'higher': 192000,
    'highest': 320000,
    'lossless': 1411000,
    'hi_res': 2304000,
    'spatial': 324000,
  };

  /// 是否为汽水系插件（名称含「汽水」/「qishui」）。
  static bool _isQishuiPlugin(EnabledMusicPlugin plugin) {
    final name = plugin.name.toLowerCase();
    return name.contains('汽水') || name.contains('qishui');
  }

  /// 输入是否为汽水链接（qishui / 汽水 / douyin.com 特征）。
  static bool _isQishuiLink(String input) {
    final t = input.toLowerCase();
    return t.contains('qishui') ||
        t.contains('汽水') ||
        t.contains('douyin.com');
  }

  /// 汽水歌单宿主直连导入：解析 ID（短链/分享文案/纯 ID 通吃）→ PC API
  /// 翻页取全 → 格式化为插件同构的曲目列表。返回 null 表示未取到歌单
  /// （ID 不可识别 / 歌单为空 / 接口失败），由调用方回退插件路径。
  Future<Map<String, dynamic>?> _importQishuiSheetDirect(
    EnabledMusicPlugin plugin,
    String input,
  ) async {
    final id = await _extractQishuiPlaylistId(input);
    if (id == null) return null;
    final detail = await _fetchQishuiPlaylistDetail(id);
    if (detail == null) return null;
    final rawTracks = detail['media_resources'];
    if (rawTracks is! List || rawTracks.isEmpty) return null;
    final songs = <Map<String, dynamic>>[];
    for (final raw in rawTracks) {
      if (raw is! Map) continue;
      final item = _formatQishuiTrack(raw);
      if (item != null) songs.add(_resetMediaItem(plugin, item));
    }
    if (songs.isEmpty) return null;
    final sheet = _parseQishuiSheetItem(detail['playlistInfo']);
    final title = sheet?['title']?.toString().trim() ?? '';
    final artwork = sheet?['artwork']?.toString() ?? '';
    return {
      'name': title.isNotEmpty ? title : '${plugin.name}歌单',
      'coverUrl': artwork.isNotEmpty ? artwork : _extractCover(songs.first),
      'songs': songs,
    };
  }

  /// 从输入（纯 ID / 分享链接 / 短链 / 分享文案）提取汽水歌单 ID。
  Future<String?> _extractQishuiPlaylistId(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    if (RegExp(r'^\d+$').hasMatch(trimmed)) return trimmed;
    final direct = _extractPlaylistIdFromUrl(trimmed);
    if (direct != null) return direct;
    // 分享文案中裸露的长数字（歌单 ID 本体）
    final longId = RegExp(r'\d{10,}').firstMatch(trimmed)?.group(0);
    if (longId != null) return longId;
    // 抠出文案中的链接逐条尝试：直接可提取的用 ID，短链交给宿主解析
    final urlMatches = RegExp(
      r'''https?://[^\s@，,。、"“”'）)】]+''',
      caseSensitive: false,
    ).allMatches(trimmed);
    for (final match in urlMatches) {
      final url = match.group(0)!;
      final urlId = _extractPlaylistIdFromUrl(url);
      if (urlId != null) return urlId;
      final lower = url.toLowerCase();
      if (lower.contains('douyin.com/s/') ||
          lower.contains('qishui.douyin.com')) {
        final resolved = await _resolvePlaylistShortLink(url);
        if (resolved != null) {
          final id = _extractPlaylistIdFromUrl(resolved) ??
              (RegExp(r'^\d+$').hasMatch(resolved) ? resolved : null);
          if (id != null) return id;
        }
      }
    }
    return null;
  }

  /// 拉取汽水歌单详情：PC API cursor 翻页取全，失败/为空时 web 分享页
  /// 兜底。返回 {playlistInfo, media_resources}；两条通道都失败返回
  /// null。
  Future<Map<String, dynamic>?> _fetchQishuiPlaylistDetail(String id) async {
    final apiDetail = await _fetchQishuiDetailFromApi(id);
    if (apiDetail != null) return apiDetail;
    return _fetchQishuiDetailFromWeb(id);
  }

  Future<Map<String, dynamic>?> _fetchQishuiDetailFromApi(String id) async {
    final ownsClient = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      var cursor = '';
      Map<String, dynamic>? playlistInfo;
      final resources = <Map<String, dynamic>>[];
      final seenCursors = <String>{};
      for (var page = 0; page < 10000; page++) {
        final response = await client
            .get(
              Uri.parse(
                '$_qishuiPcApiBase/playlist/detail?$_qishuiPcQuery'
                '&playlist_id=$id'
                '&cursor=${Uri.encodeComponent(cursor)}&count=100',
              ),
              headers: _qishuiPcHeaders,
            )
            .timeout(const Duration(seconds: 20));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          return null;
        }
        final decoded = jsonDecode(_decodeResponseBody(response.bodyBytes));
        if (decoded is! Map) return null;
        final mediaResources = decoded['media_resources'];
        if (mediaResources is! List) {
          if (page == 0) return null;
          throw Exception('汽水歌单分页数据异常');
        }
        if (playlistInfo == null && decoded['playlist'] is Map) {
          playlistInfo = Map<String, dynamic>.from(decoded['playlist'] as Map);
        }
        for (final item in mediaResources) {
          if (item is Map) resources.add(Map<String, dynamic>.from(item));
        }
        final hasMore = decoded['has_more'] == true ||
            decoded['has_more'] == 1 ||
            decoded['has_more'] == '1';
        if (!hasMore) {
          return {'playlistInfo': playlistInfo, 'media_resources': resources};
        }
        final next = decoded['next_cursor']?.toString() ?? '';
        if (resources.isEmpty ||
            next.isEmpty ||
            next == cursor ||
            seenCursors.contains(next)) {
          throw Exception('汽水歌单分页游标未推进');
        }
        seenCursors.add(next);
        cursor = next;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      if (ownsClient) client.close();
    }
  }

  /// web 分享页兜底：Googlebot UA 拿分享页 HTML，从内嵌 _ROUTER_DATA
  /// 提取歌单信息与曲目（PC API 被风控时的备用通道）。
  Future<Map<String, dynamic>?> _fetchQishuiDetailFromWeb(String id) async {
    final ownsClient = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      final response = await client
          .get(
            Uri.parse('$_qishuiWebShareUrl?playlist_id=$id'),
            headers: _qishuiWebShareHeaders,
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final html = _decodeResponseBody(response.bodyBytes);
      final routerData = _extractQishuiRouterData(html);
      if (routerData == null) return null;
      final loaderData = routerData['loaderData'];
      final playlistPage = loaderData is Map ? loaderData['playlist_page'] : null;
      if (playlistPage is! Map) return null;
      final info = playlistPage['playlistInfo'];
      // 校验落地页歌单与请求 ID 一致，防止风控页/错误页误判
      if (info is! Map || info['id']?.toString() != id) return null;
      final medias = playlistPage['medias'];
      return {
        'playlistInfo': Map<String, dynamic>.from(info),
        'media_resources': [
          for (final media in (medias is List ? medias : const []))
            if (media is Map) Map<String, dynamic>.from(media),
        ],
      };
    } catch (_) {
      return null;
    } finally {
      if (ownsClient) client.close();
    }
  }

  static Map<String, dynamic>? _extractQishuiRouterData(String html) {
    const assignment = '_ROUTER_DATA = ';
    final start = html.indexOf(assignment);
    if (start == -1) return null;
    final jsonStart = start + assignment.length;
    var jsonEnd = html.indexOf(';\nfunction runWindowFn', jsonStart);
    if (jsonEnd == -1) jsonEnd = html.indexOf(';</script>', jsonStart);
    if (jsonEnd == -1) return null;
    try {
      final decoded = jsonDecode(html.substring(jsonStart, jsonEnd));
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// 汽水 media_resource → 插件 parseTrackItem 同构的媒体条目。
  static Map<String, dynamic>? _formatQishuiTrack(Map raw) {
    final track = _qishuiNormalizeTrack(raw);
    if (track == null) return null;
    final isVideo = _qishuiIsVideoTrack(raw, track);
    final album = track['album'] is Map
        ? Map<String, dynamic>.from(track['album'] as Map)
        : const <String, dynamic>{};
    final videoId = _qishuiFirstText([
      track['video_id'],
      track['ugc_video_id'],
      track['id'],
      track['vid'],
    ]);
    final artwork = _qishuiFirstNonEmpty([
      _qishuiCoverUrl(album['url_cover']),
      _qishuiCoverUrl(track['cover_url']),
      _qishuiFirstUrl(track['image_url']),
      _qishuiFirstUrl(track['share_cover_url']),
      track['coverURL']?.toString() ?? '',
      track['firstFrameURL']?.toString() ?? '',
    ]);
    var artistEntries = [
      for (final artist
          in (track['artists'] is List ? track['artists'] as List : const []))
        if (artist is Map) Map<String, dynamic>.from(artist),
    ];
    if (artistEntries.isEmpty && track['author_info'] is Map) {
      artistEntries = [Map<String, dynamic>.from(track['author_info'] as Map)];
    }
    final singerList = _qishuiSingerList(artistEntries);
    final primary = singerList.isNotEmpty
        ? singerList.first
        : const <String, dynamic>{};
    final labelInfo = track['label_info'] is Map
        ? Map<String, dynamic>.from(track['label_info'] as Map)
        : const <String, dynamic>{};
    final id = track['id']?.toString() ?? '';
    final finalId = id.isNotEmpty ? id : videoId;
    if (finalId.isEmpty) return null;
    final title = _qishuiFirstNonEmpty([
      track['name']?.toString() ?? '',
      track['title']?.toString() ?? '',
      track['videoName']?.toString() ?? '',
      track['desc']?.toString() ?? '',
    ]);
    final artist = _qishuiFirstNonEmpty([
      primary['name']?.toString() ?? '',
      track['artistName']?.toString() ?? '',
      track['author']?.toString() ?? '',
    ]);
    return {
      'id': finalId,
      'title': title,
      'artist': artist,
      'artistId': primary['id']?.toString() ?? '',
      'singerList': singerList,
      'album': album['name']?.toString() ?? '',
      'albumId': album['id']?.toString() ?? '',
      'artwork': artwork,
      'duration': _qishuiDurationSeconds(
        track['duration'] ?? track['duration_ms'],
      ),
      'qualities': _qishuiQualitiesFromBitRates(track['bit_rates']),
      'fee': labelInfo['only_vip_playable'] == true ? 1 : 0,
      if (isVideo) ...{
        'mv': videoId,
        'vid': videoId,
        'is_video': true,
        'videoId': videoId,
      } else
        'vid': _qishuiFirstText([track['vid'], track['video_id']]),
    };
  }

  /// 还原曲目本体：与汽水插件 normalizeTrack 相同的层级解包。
  static Map<String, dynamic>? _qishuiNormalizeTrack(Map raw) {
    final entity = raw['entity'];
    if (entity is Map) {
      final wrapper = entity['track_wrapper'];
      if (wrapper is Map && wrapper['track'] is Map) {
        return Map<String, dynamic>.from(wrapper['track'] as Map);
      }
      for (final key in const ['track', 'video', 'ugc_video']) {
        final inner = entity[key];
        if (inner is Map) return Map<String, dynamic>.from(inner);
      }
    }
    final track = raw['track'];
    if (track is Map) return Map<String, dynamic>.from(track);
    return Map<String, dynamic>.from(raw);
  }

  /// 与汽水插件 isVideoTrack 一致的视频条目判定。
  static bool _qishuiIsVideoTrack(Map raw, Map track) {
    final entity = raw['entity'];
    if (entity is Map &&
        (entity['video'] != null || entity['ugc_video'] != null)) {
      return true;
    }
    if (raw['type'] == 'video' || raw['media_type'] == 'video') return true;
    if (track['video_id'] != null || track['ugc_video_id'] != null) {
      return true;
    }
    if (track['type'] == 'ugc_video' || track['video_type'] == 'ugc_video') {
      return true;
    }
    if (track['media_type'] == 'ugc_video') return true;
    return track['videoName'] != null;
  }

  /// 汽水封面对象（{uri, template_prefix, urls} 或字符串）→ 图片 URL。
  static String _qishuiCoverUrl(dynamic urlCover, [String size = '960:960']) {
    if (urlCover == null) return '';
    if (urlCover is String) return urlCover;
    if (urlCover is! Map) return '';
    final uri = urlCover['uri']?.toString() ?? '';
    final templatePrefix = urlCover['template_prefix']?.toString() ?? '';
    if (uri.isNotEmpty && templatePrefix.isNotEmpty) {
      return '$_qishuiImageBase$uri~$templatePrefix-resize:$size.png';
    }
    final urls = urlCover['urls'];
    if (urls is List && urls.isNotEmpty) {
      final first = urls.first?.toString() ?? '';
      if (first.isNotEmpty) {
        if (uri.isEmpty || first.contains(uri)) return first;
        return '$first$uri';
      }
    }
    return '';
  }

  static String _qishuiFirstUrl(dynamic cover) {
    if (cover is Map) {
      final urls = cover['urls'];
      if (urls is List) {
        for (final url in urls) {
          final s = url?.toString() ?? '';
          if (s.isNotEmpty) return s;
        }
      }
    }
    return '';
  }

  static String _qishuiFirstText(List<dynamic> values) {
    for (final value in values) {
      final s = value?.toString() ?? '';
      if (s.isNotEmpty && s != 'null') return s;
    }
    return '';
  }

  static String _qishuiFirstNonEmpty(List<String> candidates) {
    for (final candidate in candidates) {
      if (candidate.isNotEmpty) return candidate;
    }
    return '';
  }

  /// 与汽水插件 buildSingerList 一致的歌手列表构造。
  static List<Map<String, dynamic>> _qishuiSingerList(
    List<Map<String, dynamic>> artists,
  ) {
    final out = <Map<String, dynamic>>[];
    for (final artist in artists) {
      dynamic info = artist['user_info'];
      if (info is! Map) info = artist['author_info'];
      final userInfo = info is Map ? Map<String, dynamic>.from(info) : artist;
      final id = _qishuiFirstNonEmpty([
        userInfo['id']?.toString() ?? '',
        artist['id']?.toString() ?? '',
      ]);
      final name = _qishuiFirstNonEmpty([
        userInfo['name']?.toString() ?? '',
        userInfo['nickname']?.toString() ?? '',
        artist['name']?.toString() ?? '',
      ]);
      final avatar = _qishuiFirstNonEmpty([
        userInfo['avatar']?.toString() ?? '',
        _qishuiCoverUrl(userInfo['url_avatar'], '100:100'),
        _qishuiCoverUrl(userInfo['medium_avatar_url'], '100:100'),
        _qishuiCoverUrl(userInfo['thumb_avatar_url'], '100:100'),
      ]);
      if (id.isNotEmpty || name.isNotEmpty) {
        out.add({'id': id, 'name': name, 'avatar': avatar});
      }
    }
    return out;
  }

  /// 汽水 bit_rates → 插件同构 qualities（baka 键 →
  /// {size, bitrate, qishuiQuality}），spatial 条目按码率+体积排序映
  /// 射为 atmos / atmos_plus。
  static Map<String, dynamic> _qishuiQualitiesFromBitRates(dynamic bitRates) {
    final qualities = <String, dynamic>{};
    if (bitRates is! List) return qualities;
    final spatialEntries = <Map<String, dynamic>>[];
    for (final entry in bitRates) {
      if (entry is! Map) continue;
      final qishuiQuality = entry['quality']?.toString() ?? '';
      final bitrate = entry['br'] is num
          ? (entry['br'] as num).toInt()
          : _qishuiQualityFallbackBitrate[qishuiQuality] ?? 0;
      if (qishuiQuality == 'spatial') {
        spatialEntries.add({
          'size': entry['size'],
          'bitrate': bitrate,
          'qishuiQuality': qishuiQuality,
        });
        continue;
      }
      final qualityKey = _qishuiQualityToBaka[qishuiQuality];
      if (qualityKey == null || qualities.containsKey(qualityKey)) continue;
      qualities[qualityKey] = {
        'size': entry['size'],
        'bitrate': bitrate,
        'qishuiQuality': qishuiQuality,
      };
    }
    if (spatialEntries.isNotEmpty) {
      num score(Map<String, dynamic> entry) =>
          (entry['bitrate'] as num) * 1000000000 + _qishuiSizeScore(entry['size']);
      spatialEntries.sort((a, b) => score(b).compareTo(score(a)));
      if (spatialEntries.length > 1) {
        qualities['atmos_plus'] = spatialEntries[0];
        qualities['atmos'] = spatialEntries[1];
      } else {
        qualities['atmos'] = spatialEntries[0];
      }
    }
    return qualities;
  }

  static num _qishuiSizeScore(dynamic size) =>
      size is num ? size : (int.tryParse(size?.toString() ?? '') ?? 0);

  static int? _qishuiDurationSeconds(dynamic duration) {
    final n = duration is num ? duration.toInt() : int.tryParse('$duration');
    if (n == null || n <= 0) return null;
    return n > 10000 ? n ~/ 1000 : n;
  }

  /// 汽水 playlist 信息 → 插件 parsePlaylistItem 同构的歌单元数据。
  static Map<String, dynamic>? _parseQishuiSheetItem(dynamic raw) {
    if (raw is! Map) return null;
    final owner = raw['owner'] is Map
        ? Map<String, dynamic>.from(raw['owner'] as Map)
        : const <String, dynamic>{};
    final userArtistInfo = raw['user_artist_info'];
    final userBrief = userArtistInfo is Map && userArtistInfo['user_brief'] is Map
        ? Map<String, dynamic>.from(userArtistInfo['user_brief'] as Map)
        : const <String, dynamic>{};
    final resourceCnt = raw['resource_cnt'];
    final worksNum = _qishuiToInt(raw['count_tracks']) ??
        _qishuiToInt(resourceCnt is Map ? resourceCnt['track_cnt'] : null) ??
        0;
    final labelInfo = raw['label_info'];
    return {
      'id': raw['id']?.toString() ?? '',
      'title': _qishuiFirstNonEmpty([
        raw['title']?.toString() ?? '',
        raw['public_title']?.toString() ?? '',
        raw['name']?.toString() ?? '',
      ]),
      'artist': _qishuiFirstNonEmpty([
        owner['nickname']?.toString() ?? '',
        userBrief['nickname']?.toString() ?? '',
      ]),
      'createUserId': _qishuiFirstNonEmpty([
        owner['id']?.toString() ?? '',
        userBrief['id']?.toString() ?? '',
      ]),
      'description': raw['desc']?.toString() ?? '',
      'artwork': _qishuiCoverUrl(raw['url_cover']),
      'createTime': _qishuiToInt(raw['create_time']) ?? 0,
      'worksNum': worksNum,
      'fee': labelInfo is Map && labelInfo['only_vip_playable'] == true
          ? 1
          : 0,
      '_bakaSourceType': 'playlist',
    };
  }

  static int? _qishuiToInt(dynamic value) {
    if (value is num && value.isFinite) return value.toInt();
    return null;
  }

  /// QQ 歌单超出插件单次整单上限（约 999 首）时，直接调用官方
  /// uniform_get_Dissinfo 接口按 song_begin 偏移补齐剩余曲目。
  /// 补齐的歌曲按 baka 系 QQ 插件 formatMusicItem 的字段结构归一化，
  /// 播放与音质解析继续走插件管线（getMediaSource 只依赖 songmid 与
  /// qualities）。接口失败时静默返回已补齐的部分，不影响导入结果。
  Future<List<Map<String, dynamic>>> _topUpQqDissSongs(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> importedSheet,
    List<Map<String, dynamic>> imported,
  ) async {
    final disstid = importedSheet['id']?.toString().trim() ?? '';
    if (!RegExp(r'^\d+$').hasMatch(disstid)) return const [];
    var total = 0;
    for (final key in const ['worksNum', 'trackCount', 'count', 'total']) {
      final value = importedSheet[key];
      final parsed = value is num
          ? value.toInt()
          : int.tryParse(value?.toString() ?? '');
      if (parsed != null && parsed > total) total = parsed;
    }
    if (total <= imported.length) return const [];
    final seen = <String>{
      for (final song in imported)
        song['songmid']?.toString() ?? song['id']?.toString() ?? '',
    }..remove('');
    final extra = <Map<String, dynamic>>[];
    var begin = imported.length;
    // 安全上限：防止接口异常时无限翻页；正常会因空页/取满提前结束。
    while (begin < total && begin < 10000) {
      final page = await _fetchQqDissSonglist(disstid, begin);
      if (page.isEmpty) break;
      var added = 0;
      for (final raw in page) {
        final item = _normalizeQqDissSong(raw);
        final key = item['songmid']?.toString() ?? '';
        if (key.isEmpty || !seen.add(key)) continue;
        extra.add(_resetMediaItem(plugin, item));
        added++;
      }
      if (added == 0) break;
      begin += page.length;
    }
    return extra;
  }

  /// 拉取 QQ 歌单详情的指定偏移页（uniform_get_Dissinfo）。
  /// song_num 给 2000：接口对单次返回约 999 首封顶，一次取大一些
  /// 可以减少大歌单的请求次数。
  Future<List<Map<String, dynamic>>> _fetchQqDissSonglist(
    String disstid,
    int begin,
  ) async {
    final ownsClient = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      final response = await client
          .post(
            Uri.https('u.y.qq.com', '/cgi-bin/musicu.fcg'),
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                  'AppleWebKit/537.36 (KHTML, like Gecko) '
                  'Chrome/120.0.0.0 Safari/537.36',
              'Referer': 'https://y.qq.com/',
              'Origin': 'https://y.qq.com',
              'Content-Type': 'application/json;charset=UTF-8',
            },
            body: jsonEncode({
              'comm': {'ct': 24, 'cv': 4747474, 'uin': 0},
              'req': {
                'module': 'music.srfDissInfo.aiDissInfo',
                'method': 'uniform_get_Dissinfo',
                'param': {
                  'disstid': int.tryParse(disstid) ?? 0,
                  'userinfo': 1,
                  'tag': 1,
                  'orderlist': 1,
                  'song_begin': begin,
                  'song_num': 2000,
                  'onlysonglist': 0,
                  'enc_host_uin': '',
                },
              },
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const [];
      }
      final decoded = jsonDecode(_decodeResponseBody(response.bodyBytes));
      if (decoded is! Map) return const [];
      final req = decoded['req'];
      final data = req is Map ? req['data'] : null;
      final songlist = data is Map ? data['songlist'] : null;
      if (songlist is! List) return const [];
      return songlist.whereType<Map>().map(Map<String, dynamic>.from).toList();
    } catch (_) {
      return const [];
    } finally {
      if (ownsClient) client.close();
    }
  }

  /// QQ uniform_get_Dissinfo 原始歌曲 → 插件媒体条目结构，
  /// 字段对齐 baka 系 QQ 插件的 formatMusicItem / parseQualities。
  static Map<String, dynamic> _normalizeQqDissSong(Map raw) {
    final album = raw['album'] is Map
        ? Map<String, dynamic>.from(raw['album'] as Map)
        : const <String, dynamic>{};
    final rawSingers = raw['singer'] is List ? raw['singer'] as List : const [];
    final singers = [
      for (final singer in rawSingers.whereType<Map>())
        Map<String, dynamic>.from(singer),
    ];
    final artist = singers
        .map((singer) => singer['name']?.toString() ?? '')
        .where((name) => name.isNotEmpty)
        .join(', ');
    final file = raw['file'] is Map
        ? Map<String, dynamic>.from(raw['file'] as Map)
        : const <String, dynamic>{};
    final qualities = <String, Map<String, int>>{};
    void addQuality(String quality, dynamic size, int bitrate) {
      final bytes = size is num ? size.toInt() : int.tryParse('$size') ?? 0;
      if (bytes > 0) {
        qualities[quality] = {'size': bytes, 'bitrate': bitrate};
      }
    }

    addQuality('128k', file['size_128mp3'], 128000);
    addQuality('320k', file['size_320mp3'], 320000);
    addQuality('flac', file['size_flac'], 1411000);
    addQuality('hires', file['size_hires'], 1536000);
    addQuality('dolby', file['size_dolby'], 1411000);
    final sizeNew = file['size_new'];
    if (sizeNew is List) {
      int sizeAt(int index) =>
          index < sizeNew.length && sizeNew[index] is num
          ? (sizeNew[index] as num).toInt()
          : 0;
      addQuality('master', sizeAt(0), 2304000);
      addQuality('atmos', sizeAt(1), 1411000);
      addQuality('atmos_plus', sizeAt(2), 1411000);
      addQuality('vinyl', sizeAt(4), 2500000);
    }
    final albumMid = album['mid']?.toString() ?? '';
    final albumPmid = album['pmid']?.toString() ?? '';
    final coverMid = albumPmid.isNotEmpty ? albumPmid : albumMid;
    return {
      'id': raw['id'],
      'songmid': raw['mid']?.toString() ?? '',
      'title': raw['title'] ?? raw['name'] ?? '',
      'artist': artist,
      'singerList': singers,
      'artwork': coverMid.isEmpty
          ? ''
          : 'https://y.gtimg.cn/music/photo_new/'
                'T002R800x800M000$coverMid.jpg',
      'album': album['title'] ?? album['name'] ?? '',
      'duration': raw['interval'] ?? 0,
      'albumid': album['id']?.toString() ?? '',
      'albummid': albumMid,
      'qualities': qualities,
    };
  }

  Future<List<Map<String, dynamic>>> _loadMusicFreePlaylistSongs(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> sheet, {
    required String kind,
  }) async {
    final method = switch (kind) {
      'album' => 'getAlbumInfo',
      'top' => 'getTopListDetail',
      _ => 'getMusicSheetInfo',
    };
    // 未实现该详情接口的插件无法拉取曲目：榜单无兜底直接返回空；
    // 歌单/专辑的兜底（按标题搜索）由各自调用方负责。
    if (kind == 'top' && !plugin.mayHaveMethod(method)) return const [];
    var songs = <Map<String, dynamic>>[];
    final seen = <String>{};
    // 分页拉取歌单全部曲目（对齐前身 XianYu-Music-mobile 的导入逻辑）。
    // 只以插件返回的 isEnd / 空页 / 全重复 / 曲目数 / 短页判断结束，
    // 不按固定数量猜页大小——QQ 等插件每页不足 30 首时，按 30 猜测会
    // 提前截断导致歌单导入不完整。
    var maxPageSize = 0;
    var total = 0;
    for (final key in const ['trackCount', 'count', 'total', 'worksNum']) {
      final value = sheet[key];
      if (value is num && value > total) total = value.toInt();
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null && parsed > total) total = parsed;
      }
    }
    for (var page = 1; page <= 50; page++) {
      dynamic detail;
      try {
        detail = await _callOnCurrentIsolate(plugin, method, [sheet, page]);
      } catch (_) {
        if (songs.isNotEmpty) break;
        // 普通歌单详情不可用时，按电脑版逻辑用歌单标题搜索歌曲兜底。
        if (kind == 'sheet' && page == 1) {
          final title = _playlistName(sheet, '').trim();
          if (title.isNotEmpty) {
            final searched = await _callOnCurrentIsolate(plugin, 'search', [
              title,
              1,
              'music',
            ]);
            return _extractResultList(
              searched,
            ).map((song) => _resetMediaItem(plugin, song)).toList();
          }
        }
        rethrow;
      }
      final pageSongs = _extractResultList(detail);
      if (pageSongs.isEmpty) {
        if (songs.isEmpty && kind == 'sheet' && page == 1) {
          final title = _playlistName(sheet, '').trim();
          if (title.isNotEmpty) {
            final searched = await _callOnCurrentIsolate(plugin, 'search', [
              title,
              1,
              'music',
            ]);
            return _extractResultList(
              searched,
            ).map((song) => _resetMediaItem(plugin, song)).toList();
          }
        }
        break;
      }
      var added = 0;
      for (final raw in pageSongs) {
        final song = _resetMediaItem(plugin, raw);
        final key = _songIdentity(song);
        if (seen.add(key)) {
          songs.add(song);
          added++;
        }
      }
      // 全是重复曲目：插件忽略 page 参数每页返回同一批，视为结束。
      if (added == 0) break;
      if (detail is Map && detail['isEnd'] == true) break;
      // 歌单曲目数已知且已取满，视为结束。
      if (total > 0 && songs.length >= total) break;
      if (pageSongs.length > maxPageSize) maxPageSize = pageSongs.length;
      // 短页：比已见过的最大页短，即最后一页（允许插件自定义页大小）。
      if (pageSongs.length < maxPageSize) break;
    }
    // 网易系歌单/专辑/榜单接口对部分 OST 专辑只返回数值 picId（超出
    // JS 安全整数，插件无法生成封面地址），与搜索/导入路径一致补全。
    if (songs.isNotEmpty &&
        (_isNeteaseMusicPlugin(plugin) || songs.any(_looksLikeNeteaseTrack))) {
      songs = await _backfillNeteaseTrackMeta(songs);
    }
    return songs;
  }

  static List<Map<String, dynamic>> _extractTopListItems(dynamic value) {
    final categories = value is List
        ? value.whereType<Map>().map(Map<String, dynamic>.from)
        : _extractResultList(value);
    final result = <Map<String, dynamic>>[];
    for (final category in categories) {
      final nested = category['data'];
      if (nested is List) {
        for (final item in nested.whereType<Map>()) {
          result.add(Map<String, dynamic>.from(item));
        }
      } else if (category['id'] != null || category['title'] != null) {
        result.add(category);
      }
    }
    return result;
  }

  /// 输入携带数字 ID（分享链接、酷狗码、纯数字歌单 ID）时要求搜索结果
  /// 的 ID 精确一致才采用；对不上返回 null 让调用方继续下一层回退——
  /// 把链接/数字码当关键词搜出的歌单与目标歌单无关（酷狗搜索纯数字
  /// 会返回名称巧合的热门歌单，曾被误导入）。纯文本名称输入仍取第一条。
  static Map<String, dynamic>? _bestMatchingPlaylist(
    List<Map<String, dynamic>> sheets,
    String input,
  ) {
    final matches = RegExp(r'\d+').allMatches(input).toList();
    final wanted = matches.isEmpty ? null : matches.last.group(0);
    if (wanted != null) {
      for (final sheet in sheets) {
        for (final key in const ['id', 'playlistId', 'sheetId', 'musicId']) {
          if (sheet[key]?.toString() == wanted) return sheet;
        }
      }
      return null;
    }
    return sheets.first;
  }

  static String _playlistName(Map<String, dynamic> sheet, String pluginName) {
    for (final key in const ['title', 'name', 'playlistName', 'sheetName']) {
      final value = sheet[key]
          ?.toString()
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .trim();
      if (value?.isNotEmpty == true) return value!;
    }
    return pluginName.trim().isEmpty ? '' : '$pluginName歌单';
  }

  static String _songIdentity(Map<String, dynamic> song) {
    for (final key in const [
      'id',
      'songId',
      'musicId',
      'mid',
      'songmid',
      'hash',
    ]) {
      final value = song[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return '$key:$value';
    }
    return jsonEncode(song);
  }

  static bool _isQqMusicPlugin(EnabledMusicPlugin plugin) {
    final name = plugin.name.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final id = plugin.id.toLowerCase();
    return name.contains('qq音乐') ||
        name.contains('qqmusic') ||
        name == 'qq' ||
        id.contains('qq-music') ||
        id.contains('qq_music');
  }

  static bool _isNeteaseMusicPlugin(EnabledMusicPlugin plugin) {
    final name = plugin.name.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final id = plugin.id.toLowerCase();
    return name.contains('网易云') ||
        name.contains('netease') ||
        id == 'wy' ||
        id.contains('netease');
  }

  static bool _isBilibiliPlugin(EnabledMusicPlugin plugin) {
    final value = '${plugin.id} ${plugin.name}'.toLowerCase();
    return value.contains('bilibili') ||
        value.contains('哔哩') ||
        value.contains('b站');
  }

  final Map<String, bool> _mvSupportCache = {};

  /// 判断 MusicFree 插件是否声明了 `getMvSource` 扩展。不执行插件脚本，
  /// 直接扫描插件源码，供菜单展示前快速判断（与用户变量声明扫描同一思路）。
  Future<bool> pluginSupportsMvSource(EnabledMusicPlugin plugin) async {
    if (plugin.isLx) return false;
    // animemusic 插件由宿主直连 REST（music/mv/search、music/mv/url）。
    // animemusic/1 单平台插件按其平台查 MV 画质表：qishui 等后端未
    // 开放 MV 的平台返回 false；v2/v3/v4/baka 多平台聚合保持 true。
    if (plugin.animemusicApi.trim().isNotEmpty) {
      if (!plugin.isAnimemusic) return true;
      return _animemusicMvQuality.containsKey(
        _toAnimemusicPlatformCode(plugin.animemusicPlatform),
      );
    }
    final cached = _mvSupportCache[plugin.id];
    if (cached != null) return cached;
    bool supported = false;
    try {
      final source = await _loadPluginSource(plugin);
      supported = source.contains('getMvSource');
    } catch (_) {
      supported = false;
    }
    _mvSupportCache[plugin.id] = supported;
    return supported;
  }

  /// 参考 BakaMusic 的 canPlayMusicVideo：歌曲需携带 MV 标识字段，
  /// 插件才有机会解析出 MV 播放源。
  static bool hasMvIdentifier(Map<String, dynamic>? rawData) {
    if (rawData == null || rawData.isEmpty) return false;
    const keys = [
      'mv',
      'mvId',
      'mvid',
      'mvHash',
      'mvVid',
      'mvCopyrightId',
      'videoId',
      'is_video',
      'bvid',
    ];

    bool check(Map<dynamic, dynamic> data) => keys.any((key) {
      final value = data[key];
      if (value == null) return false;
      if (value is bool) return value;
      if (value is num) return value != 0;
      final text = value.toString().trim();
      return text.isNotEmpty && text != '0' && text != 'false';
    });

    if (check(rawData)) return true;
    final nested = rawData['rawData'];
    return nested is Map && check(nested);
  }

  static bool _looksLikeNeteaseTrack(Map<String, dynamic> raw) {
    for (final node in _nestedTrackNodes(raw)) {
      for (final key in const ['platform', 'source', 'vendor']) {
        final value = node[key]?.toString().toLowerCase() ?? '';
        if (value.contains('网易') || value.contains('netease')) return true;
      }
      // al/ar/dt 是网易云 v3 歌曲对象的特征字段；picId_str
      // 则是搜索接口最常见的封面标识。
      if (node['al'] is Map ||
          node.containsKey('picId_str') ||
          node.containsKey('pic_str')) {
        return true;
      }
    }
    final cover = _extractCover(raw);
    final host = Uri.tryParse(cover)?.host.toLowerCase() ?? '';
    if (host == 'music.126.net' || host.endsWith('.music.126.net')) return true;
    final url = raw['url']?.toString().toLowerCase() ?? '';
    return url.contains('/wy/') || url.contains('music.163.com');
  }

  static String _extractTrackId(Map<String, dynamic> raw) {
    for (final node in _nestedTrackNodes(raw)) {
      for (final key in const [
        'id',
        'songId',
        'songid',
        'musicId',
        'musicid',
        'songmid',
      ]) {
        final id = node[key]?.toString().trim() ?? '';
        if (RegExp(r'^\d+$').hasMatch(id)) return id;
      }
    }
    return '';
  }

  Future<List<Map<String, dynamic>>> _backfillNeteaseTrackMeta(
    List<Map<String, dynamic>> items,
  ) async {
    final ids = <String>{};
    for (final raw in items) {
      final id = _extractTrackId(raw);
      if (id.isEmpty) continue;
      final cached = _neteaseTrackMetaCache[id];
      final needsCover =
          _extractCover(raw).isEmpty && (cached?.coverUrl.isEmpty ?? true);
      final needsDuration =
          _parseDuration(raw) <= 0 && (cached?.durationMs ?? 0) <= 0;
      if (needsCover || needsDuration) ids.add(id);
    }

    if (ids.isNotEmpty) {
      final ownsClient = httpClient == null;
      final client = httpClient ?? http.Client();
      try {
        final numericIds = ids.map(int.parse).toList();
        final requests = [
          Uri.https('music.163.com', '/api/song/detail/', {
            'ids': jsonEncode(numericIds),
          }),
          Uri.https('music.163.com', '/api/v3/song/detail', {
            'c': jsonEncode([
              for (final id in numericIds) {'id': id},
            ]),
          }),
        ];
        for (final uri in requests) {
          await _fetchNeteaseTrackMeta(client, uri);
          if (ids.every((id) {
            final meta = _neteaseTrackMetaCache[id];
            return meta != null &&
                meta.coverUrl.isNotEmpty &&
                meta.durationMs > 0;
          })) {
            break;
          }
        }
      } catch (_) {
        // 详情接口不可用时仍显示插件原搜索结果，不让补封面阻断搜索。
      } finally {
        if (ownsClient) client.close();
      }
    }

    return items.map((raw) {
      final patched = Map<String, dynamic>.from(raw);
      final existingCover = _extractCover(patched);
      if (existingCover.isNotEmpty) {
        // _extractCover 同时负责把网易云明文地址升级为 HTTPS。写回 artwork
        // 可确保播放队列和持久化会话里也不会继续保存失效的 HTTP 地址。
        patched['artwork'] = existingCover;
      }
      final meta = _neteaseTrackMetaCache[_extractTrackId(raw)];
      if (meta == null) return patched;
      if (existingCover.isEmpty && meta.coverUrl.isNotEmpty) {
        patched['artwork'] = meta.coverUrl;
      }
      if (_parseDuration(patched) <= 0 && meta.durationMs > 0) {
        patched['duration'] = meta.durationMs;
      }
      return patched;
    }).toList();
  }

  /// 播放时为缺少封面的网易系歌曲补拉专辑封面。历史会话/歌单里的
  /// OST 歌曲可能带着空 artwork 持久化（接口当时只返回数值 picId），
  /// 播放时通过 song/detail 现场补全。失败返回空串，不影响播放。
  Future<String> fetchNeteaseTrackCover(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData,
  ) async {
    if (!_isNeteaseMusicPlugin(plugin) && !_looksLikeNeteaseTrack(rawData)) {
      return '';
    }
    if (_extractCover(rawData).isNotEmpty) return '';
    final id = _extractTrackId(rawData);
    if (id.isEmpty || !RegExp(r'^\d+$').hasMatch(id)) return '';
    final cached = _neteaseTrackMetaCache[id];
    if (cached?.coverUrl.isNotEmpty == true) return cached!.coverUrl;
    final patched = await _backfillNeteaseTrackMeta([
      Map<String, dynamic>.from(rawData),
    ]);
    return patched.isEmpty ? '' : _extractCover(patched.first);
  }

  /// 后台 isolate 注入的 HTTP 客户端（_PluginBackgroundHttpClient）为
  /// QuickJS XHR 桥接安全把响应体包装成 `__XY_HTTP_BODY_BASE64__` +
  /// Base64。Dart 侧直连接口复用同一客户端时，解析前必须剥离包装，
  /// 否则 jsonDecode 抛异常被上层 catch 吞掉，网易云元数据补全 / QQ
  /// 搜索直连在后台路径会静默失效。
  static String _decodeResponseBody(List<int> bodyBytes) {
    final body = utf8.decode(bodyBytes, allowMalformed: true);
    const prefix = '__XY_HTTP_BODY_BASE64__';
    if (body.startsWith(prefix)) {
      try {
        return utf8.decode(
          base64Decode(body.substring(prefix.length)),
          allowMalformed: true,
        );
      } catch (_) {
        return body;
      }
    }
    return body;
  }

  Future<void> _fetchNeteaseTrackMeta(http.Client client, Uri uri) async {
    final response = await client
        .get(
          uri,
          headers: const {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
            'Referer': 'https://music.163.com/',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) return;
    final decoded = jsonDecode(_decodeResponseBody(response.bodyBytes));
    final songs = decoded is Map ? decoded['songs'] : null;
    if (songs is! List) return;
    for (final value in songs.whereType<Map>()) {
      final song = Map<String, dynamic>.from(value);
      final id = song['id']?.toString() ?? '';
      final album = song['album'] ?? song['al'];
      final coverUrl = album is Map
          ? _normalizeImageUrl(album['picUrl']?.toString() ?? '')
          : '';
      final duration = song['duration'] ?? song['dt'];
      final previous = _neteaseTrackMetaCache[id];
      _neteaseTrackMetaCache[id] = _NeteaseTrackMeta(
        coverUrl: coverUrl.isNotEmpty ? coverUrl : previous?.coverUrl ?? '',
        durationMs: duration is num && duration > 0
            ? duration.toInt()
            : previous?.durationMs ?? 0,
      );
    }
    while (_neteaseTrackMetaCache.length > _neteaseTrackMetaCacheLimit) {
      _neteaseTrackMetaCache.remove(_neteaseTrackMetaCache.keys.first);
    }
  }

  Future<List<Map<String, dynamic>>> _searchQqWebFallback(
    String keyword,
  ) async {
    final uri = Uri.https('c.y.qq.com', '/soso/fcgi-bin/client_search_cp', {
      'format': 'json',
      'inCharset': 'utf-8',
      'outCharset': 'utf-8',
      'cr': '1',
      'platform': 'h5',
      'catZhida': '0',
      'w': keyword,
      'p': '1',
      'n': '30',
    });
    final ownsClient = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      final response = await client
          .get(
            uri,
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) '
                  'AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1',
              'Referer': 'https://y.qq.com/',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(_decodeResponseBody(response.bodyBytes));
      if (decoded is! Map || decoded['code'] != 0) {
        throw Exception('接口返回状态异常');
      }
      final data = decoded['data'];
      final song = data is Map ? data['song'] : null;
      final rawList = song is Map ? song['list'] : null;
      if (rawList is! List) throw Exception('接口没有返回歌曲列表');
      return rawList
          .whereType<Map>()
          .map(_normalizeQqSearchSong)
          .where((item) => item['songmid'].toString().isNotEmpty)
          .toList();
    } finally {
      if (ownsClient) client.close();
    }
  }

  static Map<String, dynamic> _normalizeQqSearchSong(Map rawValue) {
    final raw = Map<String, dynamic>.from(rawValue);
    final songMid = (raw['songmid'] ?? raw['mid'] ?? raw['media_mid'] ?? '')
        .toString();
    final songId = (raw['songid'] ?? raw['id'] ?? songMid).toString();
    final singers = <Map<String, dynamic>>[];
    final rawSingers = raw['singer'] ?? raw['singers'];
    if (rawSingers is List) {
      for (final singer in rawSingers.whereType<Map>()) {
        singers.add(Map<String, dynamic>.from(singer));
      }
    } else if (rawSingers is Map) {
      singers.add(Map<String, dynamic>.from(rawSingers));
    }
    final artist = singers
        .map((singer) => singer['name']?.toString() ?? '')
        .where((name) => name.isNotEmpty)
        .join(', ');
    final albumMid = (raw['albummid'] ?? raw['album_mid'] ?? '').toString();
    final qualities = <String, Map<String, int>>{};

    void addQuality(String quality, dynamic size, int bitrate) {
      final bytes = size is num ? size.toInt() : int.tryParse('$size') ?? 0;
      if (bytes > 0) {
        qualities[quality] = {'size': bytes, 'bitrate': bitrate};
      }
    }

    addQuality('128k', raw['size128'], 128000);
    addQuality('320k', raw['size320'], 320000);
    addQuality('flac', raw['sizeflac'], 1411000);
    return {
      'id': songId,
      'songmid': songMid,
      'mid': songMid,
      'title': raw['songname'] ?? raw['title'] ?? '',
      'artist': artist,
      'singerList': singers,
      'album': raw['albumname'] ?? '',
      'albumid': raw['albumid']?.toString() ?? '',
      'albummid': albumMid,
      'artwork': albumMid.isEmpty
          ? ''
          : 'https://y.gtimg.cn/music/photo_new/'
                'T002R800x800M000$albumMid.jpg',
      'duration': raw['interval'] ?? 0,
      'qualities': qualities,
    };
  }

  Future<PluginMediaSource> resolveMediaSource(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData, {
    String? preferredQuality,
    bool bypassCache = false,
  }) async {
    final cacheKey = _mediaSourceCacheKey(plugin, rawData, preferredQuality);
    if (!bypassCache) {
      final entry = _mediaSourceCache[cacheKey];
      if (entry != null) {
        if (entry.source != null &&
            DateTime.now().difference(entry.cachedAt) < _mediaSourceCacheTtl) {
          return entry.source!;
        }
        // 解析正在进行：并发调用（预取 + 用户点播）合并为同一请求。
        final inFlight = entry.inFlight;
        if (inFlight != null) return inFlight;
      }
    }
    Future<PluginMediaSource> resolve(String? quality) async {
      if (plugin.isLx) {
        return _resolveLxMediaSource(
          plugin,
          rawData,
          preferredQuality: quality,
        );
      }
      if (plugin.isAnimemusic) {
        return _resolveAnimemusicMediaSource(plugin, rawData, quality);
      }
      if (_runsPluginsInBackground) {
        try {
          final response = await _runPluginOperation(
            plugin,
            'resolveMediaSource',
            {'rawData': rawData, 'preferredQuality': quality},
          );
          final source = _toMediaSource(response);
          if (source == null) throw Exception('插件没有返回可播放地址');
          return source;
        } catch (error) {
          // 惜梦系插件播放兜底：baka 版脚本的 FALLBACK_BASE（站点根）
          // 部署上没有 API 路由，插件解析必然失败，由宿主直连后端
          // music/url 补齐。
          if (plugin.animemusicApi.trim().isNotEmpty) {
            return _resolveAnimemusicMediaSource(plugin, rawData, quality);
          }
          rethrow;
        }
      }
      try {
        return await _resolveMediaSourceOnCurrentIsolate(
          plugin,
          rawData,
          preferredQuality: quality,
        );
      } catch (error) {
        if (plugin.animemusicApi.trim().isNotEmpty) {
          return _resolveAnimemusicMediaSource(plugin, rawData, quality);
        }
        rethrow;
      }
    }

    final future = resolve(preferredQuality);
    final entry = _mediaSourceCache.putIfAbsent(
      cacheKey,
      () => _MediaSourceCacheEntry(DateTime.now()),
    );
    entry.inFlight = future;
    _trimMediaSourceCache(cacheKey);
    try {
      final source = await future;
      entry
        ..source = source
        ..cachedAt = DateTime.now()
        ..inFlight = null;
      return source;
    } catch (error) {
      entry.inFlight = null;
      // 解析失败不留缓存（含 in-flight 占位），下次调用重新走插件。
      if (identical(_mediaSourceCache[cacheKey], entry)) {
        _mediaSourceCache.remove(cacheKey);
      }
      // 音质偏好是跨歌曲保存的，但插件支持的档位是逐首歌曲变化的。
      // 某些插件遇到不支持的 super/母带档位会直接抛错，导致原本可播
      // 的歌曲也被判定为播放失败；失败时用最兼容的 320k 再解析一次。
      final preferred = preferredQuality?.trim() ?? '';
      if (preferred.isEmpty || preferred.toLowerCase() == '320k') rethrow;
      try {
        return await resolve('320k');
      } catch (_) {
        rethrow;
      }
    }
  }

  /// 播放地址 setUrl 失败时使缓存条目失效（地址可能已过 CDN 时效），
  /// 强制下一次解析重新请求插件。
  void invalidateMediaSourceCache(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData, {
    String? quality,
  }) {
    _mediaSourceCache.remove(_mediaSourceCacheKey(plugin, rawData, quality));
  }

  String _mediaSourceCacheKey(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData,
    String? quality,
  ) {
    // 洛雪音源歌曲的歌曲 id 位于 pluginData['lx'] 内层（外层是识曲
    // 快照）；不从内层提取会让同一插件的所有 lx 歌曲共享空 id 键。
    final Map raw = rawData['lx'] is Map
        ? Map<String, dynamic>.from(rawData['lx'] as Map)
        : rawData;
    final songId =
        (raw['id'] ??
                raw['songId'] ??
                raw['songmid'] ??
                raw['mid'] ??
                raw['hash'] ??
                raw['url'] ??
                rawData['url'] ??
                '')
            .toString();
    if (songId.isEmpty) {
      // 兜底：无法提取稳定歌曲 id 时退回整份 rawData 的内容散列，
      // 避免不同歌曲错误共享同一条缓存。
      return '${plugin.id}\u0000${rawData.hashCode}\u0000${quality?.trim() ?? ''}';
    }
    // lx 歌曲的播放解析与平台（kw/kg/tx/wy/mg）绑定，不同平台可能
    // 出现相同歌曲 id，source 也要参与键。
    final source = raw['source']?.toString() ?? '';
    return '${plugin.id}\u0000$source\u0000$songId\u0000${quality?.trim() ?? ''}';
  }

  /// 控制缓存规模：超出上限时按写入时间淘汰最旧条目。
  void _trimMediaSourceCache(String protectedKey) {
    while (_mediaSourceCache.length > _mediaSourceCacheMaxEntries) {
      String? oldestKey;
      DateTime? oldestAt;
      for (final e in _mediaSourceCache.entries) {
        if (e.key == protectedKey) continue;
        if (oldestAt == null || e.value.cachedAt.isBefore(oldestAt)) {
          oldestAt = e.value.cachedAt;
          oldestKey = e.key;
        }
      }
      if (oldestKey == null) break;
      _mediaSourceCache.remove(oldestKey);
    }
  }

  /// 探测当前歌曲和插件实际支持的音质。插件没有统一的音质枚举协议，
  /// 所以先读取歌曲返回的音质元数据，再对没有声明的插件 token 调用一次
  /// getMediaSource；只有返回有效 URL 才会展示给用户。
  Future<List<String>> discoverQualities(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData, {
    String? preferredQuality,
  }) {
    final future = _qualityDiscoveryCache.putIfAbsent(
      _qualityCacheKey(plugin, rawData),
      () => _discoverQualitiesUncached(plugin, rawData),
    );
    while (_qualityDiscoveryCache.length > _qualityDiscoveryCacheLimit) {
      _qualityDiscoveryCache.remove(_qualityDiscoveryCache.keys.first);
    }
    return future.then((qualities) {
      final preferred = preferredQuality?.trim() ?? '';
      // 探测结果可能只包含当前音质能够解析出的子集。始终保留歌曲
      // 元数据中声明的全部音质，避免用户切换音质后重新打开选择器时，
      // 未被本次探测返回的母带/Hi-Res 等选项被覆盖掉。
      final declared = _qualityTokensFromRaw(rawData);
      final merged = <String>{...declared, ...qualities};
      if (preferred.isNotEmpty) merged.add(preferred);
      if (merged.isEmpty) return const ['320k'];
      // 按档位从低到高排序：插件返回的 token 顺序不可控（受 JSON 键序、
      // 探测时序影响），不排序时选择器会出现“母带在无损前面”等乱序。
      return merged.toList()
        ..sort((a, b) {
          final rank = qualityTierRank(a).compareTo(qualityTierRank(b));
          return rank != 0 ? rank : a.compareTo(b);
        });
    });
  }

  /// 在歌曲进入播放流程后预先触发探测，避免打开选择器时再次请求插件。
  void preloadQualities(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData, {
    String? preferredQuality,
  }) {
    unawaited(
      discoverQualities(
        plugin,
        rawData,
        preferredQuality: preferredQuality,
      ).catchError((_) => const <String>[]),
    );
  }

  String _qualityCacheKey(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData,
  ) {
    final id =
        (rawData['id'] ??
                rawData['songId'] ??
                rawData['songmid'] ??
                rawData['mid'] ??
                rawData['hash'] ??
                rawData['url'] ??
                '${rawData['title'] ?? rawData['name']}:${rawData['artist'] ?? rawData['singer']}')
            .toString();
    return '${plugin.id}|$id';
  }

  Future<List<String>> _discoverQualitiesUncached(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData,
  ) async {
    final declared = _qualityTokensFromRaw(rawData);
    if (plugin.isAnimemusic) {
      // REST 后端逐档实测：music/url 返回有效地址才展示给用户。
      final supported = <String>[];
      for (final quality in plugin.animemusicQualities) {
        try {
          final source = await _resolveAnimemusicMediaSource(
            plugin,
            rawData,
            quality,
          ).timeout(const Duration(seconds: 6));
          if (source.url.isNotEmpty) supported.add(quality);
        } catch (_) {
          // 单一音质探测失败不应阻断整个选择器。
        }
      }
      if (supported.isNotEmpty) return supported;
      return plugin.animemusicQualities;
    }
    final candidates = <String>{
      ...declared,
      if (declared.isEmpty) ..._qualityDiscoveryFallback,
    }.toList();
    if (_runsPluginsInBackground && !plugin.isLx) {
      try {
        final response = await _runPluginOperation(
          plugin,
          'discoverQualities',
          {'rawData': rawData, 'qualities': candidates},
        );
        if (response is List) {
          final discovered = response
              .map((value) => value.toString().trim())
              .where((value) => value.isNotEmpty)
              .toList();
          if (discovered.isNotEmpty) {
            // 插件探测通常只报告本次请求成功的音质，不能用它覆盖
            // 歌曲返回的声明列表；两者取并集才能稳定保留所有选项。
            return <String>{...declared, ...discovered}.toList();
          }
        }
      } catch (_) {
        // 后台探测失败时继续走当前 isolate 的兼容路径。
      }
    }
    final supported = <String>[];
    for (final quality in candidates) {
      try {
        final ok = plugin.isLx
            ? await _probeLxQuality(plugin, rawData, quality)
            : await _probeMusicFreeQuality(plugin, rawData, quality);
        if (ok) supported.add(quality);
      } catch (_) {
        // 单一音质探测失败不应阻断整个选择器。
      }
    }
    if (supported.isNotEmpty) return supported;
    // 某些插件只在真正解析时返回地址，保留声明值让用户仍可选择；
    // 没有任何声明时至少保留当前档位，播放逻辑会继续执行兼容回退。
    if (declared.isNotEmpty) return declared;
    return const ['320k'];
  }

  Future<bool> _probeMusicFreeQuality(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData,
    String quality,
  ) async {
    dynamic response;
    if (_runsPluginsInBackground) {
      response = await _runPluginOperation(plugin, 'probeMediaSource', {
        'rawData': rawData,
        'quality': quality,
      }).timeout(const Duration(seconds: 5));
    } else {
      response = await _callOnCurrentIsolate(plugin, 'getMediaSource', [
        rawData,
        quality,
      ]).timeout(const Duration(seconds: 5));
    }
    return _toMediaSource(response) != null;
  }

  Future<bool> _probeLxQuality(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData,
    String quality,
  ) async {
    final value = rawData['lx'];
    if (value is! Map) return false;
    final songInfo = Map<String, dynamic>.from(value);
    try {
      final response = await _callLxOnCurrentIsolate(plugin, {
        'action': 'musicUrl',
        'source': songInfo['source']?.toString() ?? '',
        'info': {'type': quality, 'musicInfo': songInfo},
      }).timeout(const Duration(seconds: 5));
      final url = response?.toString().trim() ?? '';
      if (_isHttpUrl(url)) return true;
    } catch (_) {}
    return false;
  }

  /// 获取 Bilibili 视频流。优先调用电脑版 MusicFree 插件提供的
  /// `getMvSource` 扩展；旧版 B 站插件没有该方法时，按电脑版的备用流程
  /// 通过 BV/AV 号查询 CID，再请求 playurl 接口。
  Future<PluginVideoSource> resolveVideoSource(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData, {
    String? videoQuality,
    String? path,
  }) async {
    if (plugin.isLx) throw Exception('LX 插件不支持视频播放');
    Object? pluginError;
    try {
      final response = _runsPluginsInBackground
          ? await _runPluginOperation(plugin, 'resolveVideoSource', {
              'rawData': rawData,
              'videoQuality': videoQuality ?? '720P',
            })
          : await _callOnCurrentIsolate(plugin, 'getMvSource', [
              _videoPluginItem(plugin, rawData),
              videoQuality ?? '720P',
            ]);
      final source = _toVideoSource(response);
      if (source != null) return source;
    } catch (error) {
      pluginError = error;
    }

    final fallback = await _resolveBilibiliVideoSource(
      rawData,
      path: path,
      videoQuality: videoQuality,
    );
    if (fallback != null) return fallback;
    final suffix = pluginError == null
        ? ''
        : '：${_friendlyError(pluginError.toString())}';
    throw Exception('未能解析当前 Bilibili 视频$suffix');
  }

  Future<PluginVideoSource?> _resolveVideoSourceOnCurrentIsolate(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData, {
    String? videoQuality,
  }) async {
    final response = await _callOnCurrentIsolate(plugin, 'getMvSource', [
      _videoPluginItem(plugin, rawData),
      videoQuality ?? '720P',
    ]);
    return _toVideoSource(response);
  }

  /// 获取非 B 站插件歌曲的 MV 播放源。参考 BakaMusic 的
  /// getMvSource 实现：直接调用 MusicFree 插件的 `getMvSource` 扩展，
  /// 不附加 B 站 Referer 请求头。animemusic/1 插件是 CommonJS Node
  /// 模块，QuickJS 无法执行，宿主按插件契约直连后端 REST。
  Future<PluginVideoSource> resolveMvSource(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData, {
    String? videoQuality,
  }) async {
    if (plugin.isLx) throw Exception('LX 插件不支持 MV 播放');
    if (plugin.animemusicApi.trim().isNotEmpty) {
      return _resolveAnimemusicMvSource(
        plugin,
        rawData,
        videoQuality: videoQuality,
      );
    }
    final response = _runsPluginsInBackground
        ? await _runPluginOperation(plugin, 'resolveMvSource', {
            'rawData': rawData,
            'videoQuality': videoQuality ?? '1080P',
          })
        : await _callOnCurrentIsolate(plugin, 'getMvSource', [
            _videoPluginItem(plugin, rawData),
            videoQuality ?? '1080P',
          ]);
    final source = _toMvSource(response);
    if (source == null) throw Exception('插件没有返回可播放的 MV 地址');
    return source;
  }

  Future<PluginVideoSource?> _resolveMvSourceOnCurrentIsolate(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData, {
    String? videoQuality,
  }) async {
    final response = await _callOnCurrentIsolate(plugin, 'getMvSource', [
      _videoPluginItem(plugin, rawData),
      videoQuality ?? '1080P',
    ]);
    return _toMvSource(response);
  }

  static Map<String, dynamic> _videoPluginItem(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData,
  ) {
    return <String, dynamic>{
      ...rawData,
      'id': rawData['id'] ?? rawData['bvid'] ?? rawData['aid'] ?? '',
      'title': rawData['title'] ?? rawData['name'] ?? '',
      'artist': rawData['artist'] ?? rawData['author'] ?? '',
      'album': rawData['album'] ?? '',
      'duration': rawData['duration'] ?? rawData['durationMs'] ?? 0,
      'platform': plugin.name,
      'pluginId': plugin.id,
      'rawData': rawData,
    };
  }

  Future<PluginMediaSource> _resolveLxMediaSource(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData, {
    String? preferredQuality,
  }) async {
    final value = rawData['lx'];
    if (value is! Map) throw Exception('LX 歌曲缺少音源元数据');
    final songInfo = Map<String, dynamic>.from(value);
    Object? lastError;
    final qualities = pluginQualityCandidates(preferredQuality);
    // 先完整尝试插件自己的接口。自定义 LX 音源通常只支持部分音质，
    // 不能因为第一档音质失败就立刻等待公共接口超时。
    for (final quality in qualities) {
      try {
        final response = await _callLxOnCurrentIsolate(plugin, {
          'action': 'musicUrl',
          'source': songInfo['source']?.toString() ?? '',
          'info': {'type': quality, 'musicInfo': songInfo},
        });
        final pluginUrl = response?.toString().trim() ?? '';
        if (pluginUrl.startsWith('http://') ||
            pluginUrl.startsWith('https://')) {
          return PluginMediaSource(url: _normalizeMediaUrl(pluginUrl));
        }
      } catch (error) {
        lastError = error;
      }
    }
    // Older LX plugins may only expose the public resolver; keep it as a
    // compatibility fallback after the custom handler has been exhausted.
    for (final quality in qualities) {
      try {
        final response = await lxResolveUrl(
          songInfoJson: jsonEncode(songInfo),
          quality: quality,
        ).timeout(const Duration(seconds: 15));
        final decoded = jsonDecode(response);
        final url = decoded is Map
            ? decoded['url']?.toString().trim() ?? ''
            : '';
        if (url.isNotEmpty) {
          return PluginMediaSource(url: _normalizeMediaUrl(url));
        }
      } catch (error) {
        lastError = error;
      }
    }
    throw Exception(lastError ?? 'LX 没有返回可播放地址');
  }

  Future<PluginMediaSource> _resolveMediaSourceOnCurrentIsolate(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData, {
    String? preferredQuality,
  }) async {
    final direct = _extractDirectUrl(rawData);
    Object? lastError;
    for (final quality in pluginQualityCandidates(preferredQuality)) {
      try {
        final response = await _callOnCurrentIsolate(plugin, 'getMediaSource', [
          rawData,
          quality,
        ]);
        final media = _toMediaSource(response);
        if (media != null) return media;
      } catch (error) {
        lastError = error;
        if (error.toString().contains('未提供 getMediaSource')) break;
      }
    }
    if (direct != null) return direct;
    throw Exception(lastError?.toString() ?? '插件没有返回可播放地址');
  }

  Future<String> getLyrics(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData,
  ) async {
    if (plugin.isLx) {
      final lxLyrics = await _getLxLyrics(rawData);
      if (lxLyrics.isNotEmpty) return lxLyrics;
      // v2 类 LX 聚合插件（lx-animemusic）：平台直连歌词失败时按脚本
      // 里的后端地址走 REST 兜底。
      return plugin.animemusicApi.trim().isEmpty
          ? ''
          : _getAnimemusicLyrics(plugin, rawData);
    }
    if (plugin.isAnimemusic) return _getAnimemusicLyrics(plugin, rawData);
    // 未实现歌词接口的插件直接返回空串，由调用方回退平台直连歌词。
    if (!plugin.mayHaveMethod('getLyrics')) return '';
    if (_runsPluginsInBackground) {
      final response = await _runPluginOperation(plugin, 'getLyrics', rawData);
      return response?.toString() ?? '';
    }
    return _getLyricsOnCurrentIsolate(plugin, rawData);
  }

  /// MusicFree 插件评论：getMusicComments(musicItem, page)。
  /// 插件未声明该方法时抛出含方法名的异常，由调用方回退平台直连评论。
  Future<dynamic> getMusicComments(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> musicItem,
    int page,
  ) {
    if (plugin.isAnimemusic) {
      return _getAnimemusicComments(plugin, musicItem, page);
    }
    if (_runsPluginsInBackground) {
      return _runPluginOperation(plugin, 'getMusicComments', {
        'musicItem': musicItem,
        'page': page,
      });
    }
    return _callOnCurrentIsolate(plugin, 'getMusicComments', [
      musicItem,
      page,
    ]);
  }

  /// 惜梦聚合插件（v2 洛雪版 / v3 MusicFree 版）评论兜底：插件本体不
  /// 含评论方法，由宿主直连 animemusic 后端 music/comment；歌曲引用
  /// （平台码 + id）由 _animemusicSongRef 统一解析。
  Future<Map<String, dynamic>> getAnimemusicComments(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> musicItem,
    int page,
  ) => _getAnimemusicComments(plugin, musicItem, page);

  // ==================== animemusic/1 REST 直连 ====================
  // 插件本体是 CommonJS Node 模块，QuickJS 没有其依赖的 http/https/zlib
  // 内置模块；但插件契约只是对后端 REST 的薄封装（{api}/music/search
  // 等，含 PATH_INFO / ?route= 两种路由风格自适应），宿主直接实现等价
  // 调用，插件文件仍保留在磁盘上以便后续更新与配置管理。

  /// 每个插件已确认可用的路由风格：false = PATH_INFO，true = ?route=。
  final Map<String, bool> _animemusicQueryRoute = {};

  /// 每个插件的限流/故障退避截止时间：窗口内所有后端调用直接快速
  /// 失败，不再发网络请求。播放器的换源重试会放大请求频率，把
  /// 限流窗口越撞越长（荣耀 X50i 日志中 33→28→25 秒递减即此现象），
  /// 必须在请求入口熔断。
  final Map<String, DateTime> _animemusicBackoffUntil = {};

  /// 从限流提示中解析「N 秒后再试」的秒数。
  static final RegExp _animemusicRetrySecondsPattern = RegExp(r'(\d+)\s*秒');

  String _animemusicApiBase(EnabledMusicPlugin plugin) => plugin.animemusicApi
      .trim()
      .replaceFirst(RegExp(r'/index\.php(\?.*)?$', caseSensitive: false), '')
      .replaceFirst(RegExp(r'/+$'), '');

  Uri _animemusicUri(
    EnabledMusicPlugin plugin,
    String path,
    Map<String, String> params, {
    required bool queryRoute,
  }) {
    final base = _animemusicApiBase(plugin);
    if (queryRoute) {
      return Uri.parse('$base/index.php').replace(
        queryParameters: {'route': path, ...params},
      );
    }
    return Uri.parse('$base/$path').replace(queryParameters: params);
  }

  /// 调用 animemusic 后端：自动探测并记忆路由风格，404 时换另一种重试。
  Future<Map<String, dynamic>> _callAnimemusicApi(
    EnabledMusicPlugin plugin,
    String path,
    Map<String, String> params,
  ) async {
    if (plugin.animemusicApi.trim().isEmpty) {
      throw Exception('插件缺少后端接口地址');
    }
    // 限流退避：窗口内快速失败，不发请求（换源重试风暴会把窗口
    // 越撞越长，见 _animemusicBackoffUntil 注释）。
    final backoff = _animemusicBackoffUntil[plugin.id];
    if (backoff != null) {
      final remaining = backoff.difference(DateTime.now());
      if (remaining.isNegative) {
        _animemusicBackoffUntil.remove(plugin.id);
      } else {
        throw Exception('音源后端限流中，请 ${remaining.inSeconds + 1} 秒后再试');
      }
    }
    final confirmed = _animemusicQueryRoute[plugin.id];
    final attempts =
        confirmed == null ? [false, true] : [confirmed, !confirmed];
    Object? lastError;
    for (final useQuery in attempts) {
      final uri = _animemusicUri(
        plugin,
        path,
        params,
        queryRoute: useQuery,
      );
      try {
        final response = await _rawGet(uri, headers: const {
          'Accept': 'application/json, text/plain, */*',
          'User-Agent': 'animemusic-plugin/1.0.0',
        });
        if (response.statusCode == 404) {
          // 路由风格不匹配，换另一种再试（与插件 apiCall 一致）。
          lastError = Exception('接口返回 404');
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception('接口返回 HTTP ${response.statusCode}');
        }
        final Object decoded;
        try {
          decoded = jsonDecode(
            utf8.decode(response.bodyBytes, allowMalformed: true),
          );
        } catch (_) {
          // 后端偶发返回 HTML 错误页（网关故障/防护页）。直接 jsonDecode
          // 会抛 FormatException: Unexpected character 且上层无从得知
          // 原因；给明确错误并短暂退避，避免立即重试再撞一次。
          _animemusicSetBackoff(plugin.id, const Duration(seconds: 3));
          throw Exception('音源后端暂时不可用（返回了错误页），请稍后再试');
        }
        if (decoded is! Map) throw Exception('接口返回异常');
        final code = (decoded['code'] as num?)?.toInt() ?? 0;
        if (code == 404) {
          lastError = Exception(decoded['message']?.toString() ?? '接口 404');
          continue;
        }
        if (code != 200) {
          final message = decoded['message']?.toString().trim() ?? '';
          // 「当前时段内调用太多了请33秒后再试」等限流提示：解析秒数
          // 进入退避窗口，本轮与后续调用都不再打后端。
          final match = _animemusicRetrySecondsPattern.firstMatch(message);
          if (match != null) {
            final seconds = int.tryParse(match.group(1) ?? '') ?? 0;
            if (seconds > 0) {
              _animemusicSetBackoff(
                plugin.id,
                Duration(seconds: seconds + 2),
              );
            }
          }
          throw Exception(
            message.isNotEmpty ? message : '接口返回失败（$code）',
          );
        }
        _animemusicQueryRoute[plugin.id] = useQuery;
        return Map<String, dynamic>.from(decoded);
      } catch (error) {
        // 业务错误（限流/参数错/后端 5xx）与路由风格无关，换路由重试
        // 只会成倍放大请求频率，直接抛给上层。
        lastError = error;
        rethrow;
      }
    }
    throw lastError ?? Exception('接口调用失败');
  }

  /// 记录插件后端的退避截止时间。
  void _animemusicSetBackoff(String pluginId, Duration duration) {
    _animemusicBackoffUntil[pluginId] = DateTime.now().add(duration);
  }

  /// 歌词响应中的平台与歌曲 id。搜索结果的 mapSong 已带 platform 字段。
  /// 聚合音源（musicfree-animemusic / lx-animemusic）只负责解析播放地址，
  /// 歌词/评论需要拿原始平台的标识请求后端：
  /// - LX 歌曲（v2）：平台码与 id 在 lx 元数据（酷狗用 hash 播放）；
  /// - MusicFree 聚合（v3）：播放其他插件搜到的歌，rawData.platform 是
  ///   搜索插件名（如「QQ音乐[L1]」），映射回后端平台码；id 与插件的
  ///   getMediaSource 一致（hash ?? songmid ?? id）。
  static (String, String) _animemusicSongRef(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData,
  ) {
    final lxMeta = rawData['lx'];
    if (lxMeta is Map) {
      final source = lxMeta['source']?.toString().trim() ?? '';
      final hash = lxMeta['hash']?.toString().trim() ?? '';
      final songmid = lxMeta['songmid']?.toString().trim() ?? '';
      final lxId = hash.isNotEmpty ? hash : songmid;
      if (source.isNotEmpty && lxId.isNotEmpty) {
        return (source, lxId);
      }
    }
    dynamic idValue =
        rawData['hash'] ??
        rawData['songmid'] ??
        rawData['id'] ??
        rawData['songId'] ??
        rawData['musicId'];
    if (idValue == null && rawData['extra'] is Map) {
      idValue = (rawData['extra'] as Map)['songId'];
    }
    final id = idValue?.toString().trim() ?? '';
    // 来源标记优先级：星海聚合（v4）的 _src/_source、baka 版的
    // animeSrc，值均为后端平台码；缺省回退 platform 字段或插件配置。
    final starSeaSrc =
        rawData['_src']?.toString().trim().isNotEmpty == true
        ? rawData['_src'].toString().trim()
        : rawData['_source']?.toString().trim() ?? '';
    final animeSrc = rawData['animeSrc']?.toString().trim() ?? '';
    final rawPlatform = rawData['platform']?.toString().trim() ?? '';
    final platform = _toAnimemusicPlatformCode(
      starSeaSrc.isNotEmpty
          ? starSeaSrc
          : animeSrc.isNotEmpty
          ? animeSrc
          : rawPlatform.isNotEmpty
          ? rawPlatform
          : plugin.animemusicPlatform,
    );
    return (platform, id);
  }

  /// 平台文本 → animemusic 后端平台码。已是码（kg/kw/wy/tx/mg 等）直接
  /// 返回；中文平台名（含插件名如「QQ音乐[L1]」）映射回标准码。
  static String _toAnimemusicPlatformCode(String text) {
    final value = text.trim();
    if (value.isEmpty) return value;
    if (RegExp(r'^[a-z0-9]+$').hasMatch(value)) return value;
    if (value.contains('网易')) return 'wy';
    if (value.toLowerCase().contains('qq')) return 'tx';
    if (value.contains('酷狗')) return 'kg';
    if (value.contains('酷我')) return 'kw';
    if (value.contains('咪咕')) return 'mg';
    if (value.toLowerCase().contains('bilibili') || value.contains('B站')) {
      return 'bilibili';
    }
    return value;
  }

  Future<List<PluginSearchSong>> _searchAnimemusic(
    EnabledMusicPlugin plugin,
    String keyword, {
    int page = 1,
  }) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return const [];
    final body = await _callAnimemusicApi(plugin, 'music/search', {
      // v4/baka 等聚合插件无 animemusicPlatform 配置（全平台聚合），
      // 兜底搜索默认走 wy。
      'platform': plugin.animemusicPlatform.trim().isNotEmpty
          ? plugin.animemusicPlatform
          : 'wy',
      'keyword': trimmed,
      'page': '$page',
      'limit': '30',
    });
    final data = body['data'];
    if (data is! List) return const [];
    final songs = <PluginSearchSong>[];
    for (final item in data) {
      if (item is! Map) continue;
      final raw = Map<String, dynamic>.from(item);
      // animemusic 后端开放 MV 的平台注入 mv 标识让播放页显示 MV
      // 按钮（hasMvIdentifier）；qishui 等未开放 MV 的平台不注入
      // （_src 已带平台码，按其判断）。
      if (_animemusicSupportsMv(raw)) raw['mv'] = true;
      songs.add(_toSearchSong(plugin.id, raw));
    }
    return songs;
  }

  /// 惜梦系歌手/专辑搜索：music/suggest 的 singers/albums 分组。
  /// v4/baka 等聚合插件声明 supportedSearchType 仅 music，歌手与专辑
  /// 搜索由宿主直连后端 suggest 补齐；条目 rawData 带 animeSrc（平台
  /// 码）+ id，getArtistSongs/getAlbumSongs 据此走详情接口。
  Future<List<PluginCatalogResult>> _searchAnimemusicCatalog(
    EnabledMusicPlugin plugin,
    String keyword, {
    required bool artist,
  }) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return const [];
    final platform = _toAnimemusicPlatformCode(
      plugin.animemusicPlatform.trim().isNotEmpty
          ? plugin.animemusicPlatform
          : 'wy',
    );
    final body = await _callAnimemusicApi(plugin, 'music/suggest', {
      'platform': platform,
      'keyword': trimmed,
    });
    final raw = body[artist ? 'singers' : 'albums'];
    if (raw is! List) return const [];
    final results = <PluginCatalogResult>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final entry = Map<String, dynamic>.from(item);
      final id = entry['id']?.toString().trim() ?? '';
      final title = entry['name']?.toString().trim() ?? '';
      if (id.isEmpty || title.isEmpty) continue;
      results.add(
        PluginCatalogResult(
          pluginId: plugin.id,
          id: id,
          title: title,
          subtitle: artist ? '' : entry['artist']?.toString() ?? '',
          // 后端 artwork 可能是 http://（tx 歌手头像）或 // 开头地址：
          // Android 禁明文 HTTP、渲染层要求完整 URL，统一过规范化。
          coverUrl: _normalizeImageUrl(entry['artwork']?.toString() ?? ''),
          rawData: {
            ...entry,
            'animeSrc': platform,
            'platform': plugin.name,
          },
        ),
      );
    }
    return results;
  }

  /// 惜梦系歌手热门歌曲：music/artist（按歌手 id，分页；tx 需歌名辅助）。
  Future<List<PluginSearchSong>> _getAnimemusicArtistSongs(
    EnabledMusicPlugin plugin,
    String platform,
    String artistId, {
    String? name,
    int page = 1,
  }) async {
    final body = await _callAnimemusicApi(plugin, 'music/artist', {
      'platform': platform,
      'id': artistId,
      'page': '$page',
      'limit': '50',
      if (name?.trim().isNotEmpty == true && platform == 'tx')
        'name': name!.trim(),
    });
    final data = body['list'];
    if (data is! List) return const [];
    return [
      for (final item in data)
        if (item is Map)
          _toSearchSong(
            plugin.id,
            _resetMediaItem(plugin, {
              ...Map<String, dynamic>.from(item),
              'animeSrc': platform,
            }),
          ),
    ];
  }

  /// 惜梦系专辑歌曲：music/album（按专辑 id）。kw 上游无歌曲列表，
  /// 空结果由调用方回退按专辑名搜索。
  Future<List<PluginSearchSong>> _getAnimemusicAlbumSongs(
    EnabledMusicPlugin plugin,
    String platform,
    String albumId, {
    int page = 1,
  }) async {
    final body = await _callAnimemusicApi(plugin, 'music/album', {
      'platform': platform,
      'id': albumId,
      'page': '$page',
      'limit': '50',
    });
    final data = body['list'];
    if (data is! List) return const [];
    return [
      for (final item in data)
        if (item is Map)
          _toSearchSong(
            plugin.id,
            _resetMediaItem(plugin, {
              ...Map<String, dynamic>.from(item),
              'animeSrc': platform,
            }),
          ),
    ];
  }

  /// animemusic 榜单：music/toplist 返回 [{id, name, cover, desc}]，
  /// rawData 记录 animeSrc（平台码）+ id，getTopListSongs 据此直连
  /// music/toplist/detail。
  Future<List<PluginCatalogResult>> _getAnimemusicTopLists(
    EnabledMusicPlugin plugin,
  ) async {
    final platform = _toAnimemusicPlatformCode(
      plugin.animemusicPlatform.trim().isNotEmpty
          ? plugin.animemusicPlatform
          : 'wy',
    );
    final body = await _callAnimemusicApi(plugin, 'music/toplist', {
      'platform': platform,
    });
    final data = body['data'];
    if (data is! List) return const [];
    final results = <PluginCatalogResult>[];
    for (final item in data) {
      if (item is! Map) continue;
      final entry = Map<String, dynamic>.from(item);
      final id = entry['id']?.toString().trim() ?? '';
      final title = entry['name']?.toString().trim() ?? '';
      if (id.isEmpty || title.isEmpty) continue;
      results.add(
        PluginCatalogResult(
          pluginId: plugin.id,
          id: id,
          title: title,
          subtitle: entry['desc']?.toString() ?? '',
          coverUrl: entry['cover']?.toString() ?? '',
          rawData: {...entry, 'animeSrc': platform, 'platform': plugin.name},
        ),
      );
    }
    return results;
  }

  /// animemusic 榜单歌曲：music/toplist/detail（按榜单 id，分页）。
  /// [fetchAll] 为 true 时按 total 分页取全（榜单详情页），每页 100 首，
  /// 与 music/import 相同按 id 去重、防止后端翻页返回重复条目。
  Future<List<PluginSearchSong>> _getAnimemusicTopListSongs(
    EnabledMusicPlugin plugin,
    PluginCatalogResult chart, {
    int limit = 40,
    bool fetchAll = false,
  }) async {
    final platform =
        chart.rawData['animeSrc']?.toString().trim().isNotEmpty == true
        ? chart.rawData['animeSrc'].toString().trim()
        : plugin.animemusicPlatform;
    final chartId = chart.rawData['id']?.toString().trim() ?? '';
    if (chartId.isEmpty) return const [];
    if (!fetchAll) {
      final body = await _callAnimemusicApi(plugin, 'music/toplist/detail', {
        'platform': platform,
        'id': chartId,
        'page': '1',
        'limit': '$limit',
      });
      final data = body['list'];
      if (data is! List) return const [];
      return [
        for (final item in data)
          if (item is Map)
            _toSearchSong(
              plugin.id,
              _resetMediaItem(plugin, {
                ...Map<String, dynamic>.from(item),
                'animeSrc': platform,
              }),
            ),
      ];
    }
    // 榜单详情页：分页拉全（对齐 music/import 的翻页策略）。
    final songs = <Map<String, dynamic>>[];
    final seenIds = <String>{};
    var total = 0;
    const pageSize = 100;
    for (var page = 1; page <= 50; page++) {
      final body = await _callAnimemusicApi(plugin, 'music/toplist/detail', {
        'platform': platform,
        'id': chartId,
        'page': '$page',
        'limit': '$pageSize',
      });
      final list = body['list'];
      if (list is! List) break;
      if (total <= 0) total = (body['total'] as num?)?.toInt() ?? 0;
      var added = 0;
      for (final item in list) {
        if (item is! Map) continue;
        final raw = Map<String, dynamic>.from(item);
        final id = raw['id']?.toString().trim() ?? '';
        if (id.isEmpty || !seenIds.add(id)) continue;
        songs.add({...raw, 'animeSrc': platform});
        added++;
      }
      final hasMore = total > 0
          ? page * pageSize < total
          : list.length >= pageSize;
      if (!hasMore || added == 0) break;
    }
    return [
      for (final raw in songs)
        _toSearchSong(plugin.id, _resetMediaItem(plugin, raw)),
    ];
  }

  /// animemusic/1 单平台插件的歌单导入：直连后端 music/import。分享文案
  /// / 短链 / 纯数字歌单 ID 均由后端自行解析，宿主只负责分页取全曲目与
  /// 条目归一化：该接口的条目不带 _src（music/search 才有），必须注入
  /// animeSrc（平台码）供播放解析（music/url）使用。
  Future<Map<String, dynamic>?> _importAnimemusicPlaylist(
    EnabledMusicPlugin plugin,
    String input,
  ) async {
    final configured = plugin.animemusicPlatform.trim();
    final params = <String, String>{
      'url': input,
      'page': '1',
      'limit': '100',
      // 聚合插件（platform 为空或 all）不传，由后端按链接自动识别平台。
      if (configured.isNotEmpty && configured != 'all') 'platform': configured,
    };
    var platform = _toAnimemusicPlatformCode(configured);
    final songs = <Map<String, dynamic>>[];
    var title = '';
    var cover = '';
    final seenIds = <String>{};
    // 安全上限：防止接口异常时无限翻页；正常会因取满 total 提前结束。
    for (var page = 1; page <= 100; page++) {
      params['page'] = '$page';
      final body = await _callAnimemusicApi(plugin, 'music/import', params);
      final bodyPlatform = body['platform']?.toString().trim() ?? '';
      if (bodyPlatform.isNotEmpty) {
        platform = _toAnimemusicPlatformCode(bodyPlatform);
      }
      if (title.isEmpty) {
        title = body['title']?.toString().trim() ?? '';
        cover = _normalizeImageUrl(body['cover']?.toString() ?? '');
      }
      final list = body['list'];
      if (list is! List) break;
      var added = 0;
      for (final item in list) {
        if (item is! Map) continue;
        final raw = Map<String, dynamic>.from(item);
        final id = raw['id']?.toString().trim() ?? '';
        // 个别后端翻页时返回重复条目，按 id 去重。
        if (id.isEmpty || !seenIds.add(id)) continue;
        songs.add(_resetMediaItem(plugin, {...raw, 'animeSrc': platform}));
        added++;
      }
      final total = (body['total'] as num?)?.toInt() ?? 0;
      final hasMore = total > 0 ? page * 100 < total : list.length >= 100;
      if (!hasMore || added == 0) break;
    }
    if (songs.isEmpty) return null;
    return {
      'name': title.isNotEmpty ? title : '${plugin.name}歌单',
      'coverUrl': cover,
      'songs': songs,
    };
  }

  String _normalizeAnimemusicQuality(String? quality) {
    final value = quality?.trim().toLowerCase() ?? '';
    if (value.isEmpty) return '320k';
    switch (value) {
      case 'hires':
      case 'hi-res':
      case 'master':
      case 'atmos':
      case 'dolby':
      case 'hifi':
      case '24bit':
        return 'flac24bit';
      case 'flac24bit':
      case 'flac':
      case 'lossless':
      case 'sq':
      case 'ape':
      case 'wav':
        return value == 'flac24bit' ? value : 'flac';
      case '128k':
      case '192k':
      case '320k':
        return value;
      default:
        return '320k';
    }
  }

  Future<PluginMediaSource> _resolveAnimemusicMediaSource(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData,
    String? quality,
  ) async {
    final (platform, id) = _animemusicSongRef(plugin, rawData);
    if (id.isEmpty) throw Exception('歌曲缺少 id');
    final body = await _callAnimemusicApi(plugin, 'music/url', {
      'source': platform,
      'musicId': id,
      'quality': _normalizeAnimemusicQuality(quality),
    });
    final url = body['url']?.toString().trim() ?? '';
    if (url.isEmpty) throw Exception('插件没有返回可播放地址');
    return PluginMediaSource(url: _normalizeMediaUrl(url));
  }

  /// animemusic 歌词：优先逐字（lrc-a2，即 Enhanced LRC，直接兼容
  /// Rust 解析器），失败回退逐行；主歌词、翻译、罗马音按与
  /// buildLxLyricsRaw 相同的顺序拼接。
  Future<String> _getAnimemusicLyrics(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData,
  ) async {
    final (platform, id) = _animemusicSongRef(plugin, rawData);
    if (id.isEmpty) return '';
    final params = <String, String>{
      'platform': platform,
      'musicId': id,
      'interval': '200',
      if (rawData['title']?.toString().trim().isNotEmpty == true)
        'name': rawData['title'].toString().trim(),
    };
    String joinLyrics(Map<String, dynamic> body) => [
      body['lyric']?.toString() ?? '',
      body['tlyric']?.toString() ?? '',
      body['rlyric']?.toString() ?? '',
    ]
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .join('\n');

    try {
      final word = await _callAnimemusicApi(
        plugin,
        'music/lyric/word',
        params,
      );
      final joined = joinLyrics(word);
      if (joined.isNotEmpty) return joined;
    } catch (_) {
      // 逐字失败自动回退逐行（与插件 lyricFallback 默认行为一致）。
    }
    final line = await _callAnimemusicApi(plugin, 'music/lyric', params);
    return joinLyrics(line);
  }

  /// animemusic 评论（music/comment）：hot/list 位于响应顶层，hot 仅第
  /// 一页返回（热门），list 为最新评论分页；kg/kw/mg/tx 暂无公开签名
  /// 接口，后端返回空列表不报错。转换为 MusicFree 插件评论格式
  /// （{data: [...], isEnd}）交给 plugin_comments 统一解析。
  Future<Map<String, dynamic>> _getAnimemusicComments(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> musicItem,
    int page,
  ) async {
    final (platform, id) = _animemusicSongRef(plugin, musicItem);
    if (id.isEmpty) return const {'data': <dynamic>[], 'isEnd': true};
    const limit = 20;
    final body = await _callAnimemusicApi(plugin, 'music/comment', {
      'platform': platform,
      'musicId': id,
      'page': '$page',
      'limit': '$limit',
    });
    final list = _animemusicCommentItems(body['list'], 'list-$page');
    final hot = page <= 1
        ? _animemusicCommentItems(body['hot'], 'hot')
        : const <dynamic>[];
    return {
      'data': [...hot, ...list],
      // 请求 20 条实际不足 20 条时视为最后一页。
      'isEnd': list.length < limit,
    };
  }

  /// animemusic 评论条目（user/avatar/content/time/location/likes）映射为
  /// CommentItem.normalize 识别的字段名；time 为「YYYY-MM-DD」日期字符串，
  /// 转换成毫秒时间戳。bilibili 的楼中楼（floors）映射到 replies。
  static List<Map<String, dynamic>> _animemusicCommentItems(
    dynamic raw,
    String idPrefix,
  ) {
    if (raw is! List) return const [];
    final items = <Map<String, dynamic>>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final item = <String, dynamic>{
        'id': '$idPrefix-${items.length}',
        'nickName': entry['user']?.toString() ?? '',
        'avatar': entry['avatar']?.toString(),
        'comment': entry['content']?.toString() ?? '',
        'like': entry['likes'] is num ? (entry['likes'] as num).toInt() : null,
        'createAt': _parseAnimemusicCommentTime(entry['time']),
        'location': entry['location']?.toString(),
      };
      final floors = entry['floors'];
      if (floors is List && floors.isNotEmpty) {
        item['replies'] = _animemusicCommentItems(floors, '$idPrefix-r');
      }
      items.add(item);
    }
    return items;
  }

  static int? _parseAnimemusicCommentTime(dynamic value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final parsed = DateTime.tryParse(text);
    if (parsed != null) return parsed.millisecondsSinceEpoch;
    // 抖音（qishui）等平台的评论时间是美式格式
    // 「M/D/YYYY, h:mm:ss AM/PM」，DateTime.tryParse 无法识别。
    final us = RegExp(
      r'^(\d{1,2})/(\d{1,2})/(\d{4})'
      r'(?:,\s*(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AaPp][Mm]))?$',
    ).firstMatch(text);
    if (us != null) {
      var hour = int.parse(us.group(4) ?? '0');
      final minute = int.parse(us.group(5) ?? '0');
      final second = int.parse(us.group(6) ?? '0');
      final meridiem = (us.group(7) ?? '').toLowerCase();
      if (meridiem == 'pm' && hour < 12) hour += 12;
      if (meridiem == 'am' && hour == 12) hour = 0;
      return DateTime(
        int.parse(us.group(3)!),
        int.parse(us.group(1)!),
        int.parse(us.group(2)!),
        hour,
        minute,
        second,
      ).millisecondsSinceEpoch;
    }
    return int.tryParse(text);
  }

  /// animemusic 各平台 MV 画质映射（与插件 MV_QUALITY 一致）：平台不支持
  /// 的画质映射为空串，后端自选可用画质。
  static const Map<String, Map<String, String>> _animemusicMvQuality = {
    'kg': {},
    'kw': {
      '1080p': 'MP4BD',
      '720p': 'MP4UL',
      '480p': 'MP4HV',
      '360p': 'MV700',
      '240p': 'MP4L',
    },
    'wy': {'1080p': '1080', '720p': '720', '480p': '480', '240p': '240'},
    'tx': {'1080p': '1080', '720p': '720', '480p': '480'},
    'mg': {},
    'bilibili': {
      '1080p': '80',
      '720p': '64',
      '480p': '32',
      '360p': '16',
      '240p': '16',
    },
  };

  /// animemusic MV 解析：按标题（+艺术家）搜索 MV（music/mv/search），
  /// 优先取标题完全一致的一条，再解析直链（music/mv/url）。
  Future<PluginVideoSource> _resolveAnimemusicMvSource(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData, {
    String? videoQuality,
  }) async {
    final platform = plugin.animemusicPlatform;
    final title = rawData['title']?.toString().trim() ?? '';
    final artist = rawData['artist']?.toString().trim() ?? '';
    if (title.isEmpty) throw Exception('缺少歌曲标题，无法搜索 MV');
    final keyword = artist.isEmpty ? title : '$title $artist';
    final body = await _callAnimemusicApi(plugin, 'music/mv/search', {
      'platform': platform,
      'keyword': keyword,
      'page': '1',
      'limit': '10',
    });
    final data = body['data'];
    final candidates = [
      if (data is List)
        for (final item in data)
          if (item is Map) Map<String, dynamic>.from(item),
    ];
    if (candidates.isEmpty) throw Exception('没有找到这首歌的 MV');
    var best = candidates.first;
    for (final candidate in candidates) {
      if (candidate['title']?.toString().trim() == title) {
        best = candidate;
        break;
      }
    }
    final mvId = best['id']?.toString().trim() ?? '';
    if (mvId.isEmpty) throw Exception('MV 结果缺少 id');
    final want = (videoQuality ?? '1080p').trim().toLowerCase();
    final upstream = _animemusicMvQuality[platform]?[want] ?? '';
    final urlBody = await _callAnimemusicApi(plugin, 'music/mv/url', {
      'platform': platform,
      'id': mvId,
      'quality': upstream,
    });
    final url = urlBody['url']?.toString().trim() ?? '';
    if (url.isEmpty) throw Exception('插件没有返回可播放的 MV 地址');
    return PluginVideoSource(url: _normalizeMediaUrl(url));
  }

  Future<String> _getLxLyrics(Map<String, dynamic> rawData) async {
    final value = rawData['lx'];
    if (value is! Map) return '';
    final info = Map<String, dynamic>.from(value);
    final source = info['source']?.toString().trim() ?? '';
    if (source.isEmpty) return '';
    final response = await fetchLyricFromSource(
      source: source,
      songInfoJson: jsonEncode(info),
    ).timeout(const Duration(seconds: 20));
    if (response.trim().isEmpty || response.trim() == 'null') return '';
    final decoded = jsonDecode(response);
    if (decoded is! Map) return '';
    return buildLxLyricsRaw(Map<String, dynamic>.from(decoded));
  }

  /// QQ 音乐逐字歌词直连兜底。部分 QQ 音源插件的 getLyric 内部先请求
  /// musicu.fcg（crypt:1 + qrc:1 拿逐字密文），失败时静默降级到老接口，
  /// 只返回普通 LRC——逐字时间轴就此丢失（插件不报错，宿主无从感知）。
  /// 这里改用 Rust 侧 fetchLyricFromSource('tx')（musicu.fcg qrc:1 +
  /// 3DES 解密 + QRC 解析，与 LX 音源同一条已验证链路）按 songmid 重新
  /// 拉取逐字歌词；失败返回空字符串，由调用方维持插件原结果。
  Future<String> _getTxWordLyricsFallback(Map<String, dynamic> rawData) async {
    final songmid = (rawData['songmid'] ??
            rawData['mid'] ??
            rawData['songMid'])
        ?.toString()
        .trim();
    if (songmid == null || songmid.isEmpty) return '';
    try {
      final response = await fetchLyricFromSource(
        source: 'tx',
        songInfoJson: jsonEncode({
          'songmid': songmid,
          if (rawData['id'] != null) 'songId': rawData['id'],
          'name': rawData['title'] ?? rawData['name'] ?? '',
          'singer': rawData['artist'] ?? rawData['singer'] ?? '',
        }),
      ).timeout(const Duration(seconds: 20));
      final trimmed = response.trim();
      if (trimmed.isEmpty || trimmed == 'null') return '';
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return '';
      final raw = buildLxLyricsRaw(Map<String, dynamic>.from(decoded));
      return _hasWordTiming(raw) ? raw : '';
    } catch (_) {
      return '';
    }
  }

  /// 插件返回的 QQ 歌词无逐字时间轴（普通 LRC）时，尝试直连升级为
  /// QRC 逐字版本；无需升级或失败时返回 null（调用方维持原歌词）。
  /// 以 rawData 含 songmid 判定 QQ 歌曲——酷狗用 hash、酷我用 rid、
  /// 网易用纯数字 id，均不会携带 songmid 字段，不会误触发。
  Future<String?> _upgradeQqLyricsToWordTiming(
    Map<String, dynamic> rawData,
    String lyrics,
  ) async {
    if (_hasWordTiming(lyrics) || _isLikelyEncryptedLyrics(lyrics)) {
      return null;
    }
    final songmid = (rawData['songmid'] ??
            rawData['mid'] ??
            rawData['songMid'])
        ?.toString()
        .trim();
    if (songmid == null || songmid.isEmpty) return null;
    final upgraded = await _getTxWordLyricsFallback(rawData);
    return upgraded.isEmpty ? null : upgraded;
  }

  Future<String> _getLyricsOnCurrentIsolate(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData,
  ) async {
    final embedded = _extractLyrics(rawData);
    // 已内嵌逐字歌词时直接使用；只有普通 LRC 时继续询问插件，插件的
    // getLyric/getLrc 可能会返回更高精度的 YRC/QRC/ESLRC。
    if (_hasWordTiming(embedded)) return embedded;
    var bestLyrics = embedded;

    final songId =
        rawData['id'] ??
        rawData['songId'] ??
        rawData['songmid'] ??
        rawData['mid'];
    pluginLyrics:
    for (final method in const [
      'getLyric',
      'getLyrics',
      'getLrc',
      'getSongLyric',
      'getMusicLyric',
    ]) {
      final arguments = <List<dynamic>>[
        [rawData],
        if (songId != null) [songId],
      ];
      for (final args in arguments) {
        try {
          final response = await _callOnCurrentIsolate(plugin, method, args);
          final lyrics = await _resolveLyricsResponse(response);
          // QQ 音源插件（crypt:1 + qrc:1）返回的是加密的 hex 密文：先在
          // Dart 侧解密（与 Rust qrc_decrypt 同算法），成功返回明文
          // （词级时间轴交给下游解析器，行级 LRC 直接展示）；解密失败
          // 走平台老接口兜底，均不可用时返回空串——绝不把密文透传给
          // 下载/备份链路落盘成乱码。
          if (lyrics.isNotEmpty) {
            if (_isLikelyEncryptedLyrics(lyrics)) {
              final decrypted = decryptQrcLyrics(lyrics);
              if (decrypted != null && decrypted.trim().isNotEmpty) {
                return decrypted;
              }
              final fallback = await _getPlatformLyricsFallback(
                plugin,
                rawData,
              );
              if (fallback.isNotEmpty) return fallback;
              return '';
            }
            if (_hasWordTiming(lyrics) || !_isNeteaseMusicPlugin(plugin)) {
              // QQ 歌曲拿到普通 LRC 时先尝试直连升级为逐字版本（插件
              // 内部 musicu.fcg 失败会静默降级老接口丢失逐字）。
              final upgraded = await _upgradeQqLyricsToWordTiming(
                rawData,
                lyrics,
              );
              if (upgraded != null) return upgraded;
              return lyrics;
            }
            bestLyrics = lyrics;
            break pluginLyrics;
          }
        } catch (_) {
          // 不同 MusicFree 版本的方法名和参数不同，继续尝试下一个协议变体。
        }
      }
    }

    // 有些插件把歌词放在 getMusicInfo 返回值里，并未单独导出歌词方法。
    try {
      final info = await _callOnCurrentIsolate(plugin, 'getMusicInfo', [
        rawData,
      ]);
      final lyrics = await _resolveLyricsResponse(info);
      // 密文处理同上：Dart 侧解密，失败走平台兜底。
      if (lyrics.isNotEmpty) {
        if (_isLikelyEncryptedLyrics(lyrics)) {
          final decrypted = decryptQrcLyrics(lyrics);
          if (decrypted != null && decrypted.trim().isNotEmpty) {
            return decrypted;
          }
          final fallback = await _getPlatformLyricsFallback(plugin, rawData);
          if (fallback.isNotEmpty) return fallback;
          return '';
        }
        if (_hasWordTiming(lyrics) || !_isNeteaseMusicPlugin(plugin)) {
          final upgraded = await _upgradeQqLyricsToWordTiming(
            rawData,
            lyrics,
          );
          if (upgraded != null) return upgraded;
          return lyrics;
        }
        bestLyrics = lyrics;
      }
    } catch (_) {
      // getMusicInfo 同样属于可选能力。
    }

    final fallback = await _getPlatformLyricsFallback(plugin, rawData);
    if (fallback.isNotEmpty) return fallback;
    // v3 类 MusicFree 聚合插件（musicfree-animemusic）只声明
    // getMediaSource，平台兜底也失败时按脚本里的后端地址走 REST 兜底。
    if (plugin.animemusicApi.trim().isNotEmpty) {
      try {
        final aggregated = await _getAnimemusicLyrics(plugin, rawData);
        if (aggregated.isNotEmpty) return aggregated;
      } catch (_) {
        // 后端不可用时维持原有返回。
      }
    }
    // bestLyrics 只保留明文：rawData 内嵌 lyric 字段可能就是密文而插件
    // 方法全部失败，这里最后一道拦截解密，失败宁可返回空串也不把密文
    // 透传给下载/备份链路落盘成乱码。
    if (bestLyrics.isNotEmpty && _isLikelyEncryptedLyrics(bestLyrics)) {
      final decrypted = decryptQrcLyrics(bestLyrics);
      if (decrypted != null && decrypted.trim().isNotEmpty) return decrypted;
      return '';
    }
    return bestLyrics;
  }

  Future<String> _resolveLyricsResponse(dynamic response) async {
    final lyrics = _extractLyricsWithTranslation(response);
    if (lyrics.isNotEmpty) return lyrics;
    final url = _extractLyricsUrl(response);
    if (url.isEmpty) return '';
    try {
      final httpResponse = await _rawGet(Uri.parse(url));
      if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
        return '';
      }
      final body = utf8.decode(httpResponse.bodyBytes, allowMalformed: true);
      try {
        final decoded = jsonDecode(body);
        final nested = _extractLyricsWithTranslation(decoded);
        if (nested.isNotEmpty) return nested;
      } catch (_) {
        // 纯 LRC 文本不是 JSON，直接返回正文。
      }
      return body.trim();
    } catch (_) {
      return '';
    }
  }

  /// 插件歌词全部失效（未声明方法或返回密文/空内容）时的平台直连兜底。
  /// 平台优先按插件名识别；插件是聚合音源（如 musicfree-animemusic、
  /// 只负责解析播放地址）时，改按歌曲 rawData 自带的 platform 字段识别
  /// ——搜索插件写入的平台名（如「QQ音乐[L1]」）会随歌曲数据一起保留；
  /// 星海聚合插件（v4）的歌曲用 _src/_source 标记来源平台码。
  Future<String> _getPlatformLyricsFallback(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData,
  ) async {
    final platformText =
        '${plugin.id} ${plugin.name} ${rawData['platform'] ?? ''} '
        '${rawData['source'] ?? ''} ${rawData['_src'] ?? ''} '
        '${rawData['_source'] ?? ''} ${rawData['animeSrc'] ?? ''}'
        .toLowerCase();
    if (_isNeteaseMusicPlugin(plugin) ||
        RegExp(r'网易|netease|\bwy\b').hasMatch(platformText)) {
      return _getNeteaseLyricsFallback(rawData);
    }
    if (_isQqMusicPlugin(plugin) ||
        RegExp(r'qq音乐|qqmusic|\bqq\b|(^|[^a-z])tx\b').hasMatch(platformText)) {
      return _getQqLyricsFallback(rawData);
    }
    return '';
  }

  Future<String> _getNeteaseLyricsFallback(Map<String, dynamic> rawData) async {
    final id = (rawData['id'] ?? rawData['songId'] ?? rawData['songmid'])
        ?.toString()
        .trim();
    if (id == null || !RegExp(r'^\d+$').hasMatch(id)) return '';
    try {
      final response = await _rawGet(
        Uri.https('music.163.com', '/api/song/lyric', {
          'id': id,
          'lv': '-1',
          'kv': '-1',
          'tv': '-1',
          'yv': '-1',
        }),
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
              'AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36',
          'Referer': 'https://music.163.com/',
        },
      );
      if (response.statusCode < 200 || response.statusCode >= 300) return '';
      final decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
      return _extractLyricsWithTranslation(decoded);
    } catch (_) {
      return '';
    }
  }

  /// QQ 音乐歌词兜底，两级尝试：
  ///
  /// 1. c.y.qq.com 老接口 fcg_query_lyric_new（按 songmid 查询）：
  ///    返回 base64 明文 LRC 与 trans 翻译，实测稳定可用；
  /// 2. musicu.fcg 的 GetPlayLyricInfo 模块（`crypt:0, qrc:0`）：
  ///    可额外拿到 roma 罗马音，但该模块对部分网络环境要求签名
  ///    （code 500003），仅作老接口失败（仅有数字 id 无 songmid、
  ///    或老接口无返回）时的补充。
  ///
  /// 注意 `crypt:1` 会返回十六进制密文——部分 baka 音源插件 bug 的
  /// 根源（插件不解密直接透传导致整屏乱码），本兜底不使用该组合。
  Future<String> _getQqLyricsFallback(Map<String, dynamic> rawData) async {
    final mid = (rawData['mid'] ?? rawData['songmid'] ?? rawData['songMid'])
        ?.toString()
        .trim();
    if (mid != null && mid.isNotEmpty) {
      final legacy = await _getQqLegacyLyrics(mid);
      if (legacy.isNotEmpty) return legacy;
    }
    final id = (rawData['id'] ?? rawData['songId'] ?? rawData['songid'])
        ?.toString()
        .trim();
    final idIsNumeric = id != null && RegExp(r'^\d+$').hasMatch(id);
    if (!idIsNumeric) return '';
    final ownsClient = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      final response = await client
          .post(
            Uri.https('u.y.qq.com', '/cgi-bin/musicu.fcg'),
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                  'AppleWebKit/537.36 (KHTML, like Gecko) '
                  'Chrome/120.0.0.0 Safari/537.36',
              'Referer': 'https://y.qq.com/',
              'Origin': 'https://y.qq.com',
              'Content-Type': 'application/json;charset=UTF-8',
            },
            body: jsonEncode({
              'comm': {'ct': 19, 'cv': 0},
              'req': {
                'module': 'music.musichallSong.PlayLyricInfo.GetPlayLyricInfo',
                'method': 'GetPlayLyricInfo',
                'param': {
                  'crypt': 0,
                  'qrc': 0,
                  'trans': 1,
                  'roma': 1,
                  'song_id': int.parse(id),
                  if (mid != null && mid.isNotEmpty) 'song_mid': mid,
                },
              },
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) return '';
      final decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
      if (decoded is! Map) return '';
      final req = decoded['req'];
      if (req is! Map || (req['code'] is num && (req['code'] as num) != 0)) {
        return '';
      }
      final data = req['data'];
      if (data is! Map) return '';
      final main = _decodeBase64Text(data['lyric']);
      if (main.isEmpty) return '';
      final translation = _decodeBase64Text(data['trans']);
      final romaji = _decodeBase64Text(data['roma']);
      return [
        main,
        if (translation.isNotEmpty) translation,
        if (romaji.isNotEmpty) romaji,
      ].join('\n');
    } catch (_) {
      return '';
    } finally {
      if (ownsClient) client.close();
    }
  }

  /// QQ 歌词老接口：按 songmid 查询，返回 base64 明文 LRC + trans 翻译。
  Future<String> _getQqLegacyLyrics(String songmid) async {
    try {
      final response = await _rawGet(
        Uri.https('c.y.qq.com', '/lyric/fcgi-bin/fcg_query_lyric_new.fcg', {
          'songmid': songmid,
          'g_tk': '5381',
          'loginUin': '0',
          'hostUin': '0',
          'format': 'json',
          'inCharset': 'utf8',
          'outCharset': 'utf-8',
          'notice': '0',
          'platform': 'yqq.json',
          'needNewCode': '0',
        }),
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
              'AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36',
          'Referer': 'https://y.qq.com/',
        },
      );
      if (response.statusCode < 200 || response.statusCode >= 300) return '';
      final decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
      if (decoded is! Map) return '';
      if (decoded['retcode'] is num && (decoded['retcode'] as num) != 0) {
        return '';
      }
      final main = _decodeBase64Text(decoded['lyric']);
      if (main.isEmpty) return '';
      final translation = _decodeBase64Text(decoded['trans']);
      return translation.isEmpty ? main : '$main\n$translation';
    } catch (_) {
      return '';
    }
  }

  /// QQ 歌词接口的字段是 base64 编码文本，解码为 UTF-8 字符串。
  static String _decodeBase64Text(dynamic value) {
    if (value is! String || value.trim().isEmpty) return '';
    try {
      return utf8.decode(base64Decode(value.trim()), allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  Future<http.Response> _rawGet(Uri uri, {Map<String, String>? headers}) async {
    Future<http.Response> once(Uri target) async {
      final injectedClient = httpClient;
      final canUseInjected =
          injectedClient != null &&
          injectedClient is! _PluginBackgroundHttpClient &&
          injectedClient is! _PluginProxyHttpClient;
      final http.Client client =
          canUseInjected ? injectedClient : http.Client();
      try {
        return await client
            .get(target, headers: headers)
            .timeout(const Duration(seconds: 20));
      } finally {
        if (!canUseInjected) client.close();
      }
    }

    http.Response? response;
    Object? error;
    try {
      response = await once(uri);
    } catch (e) {
      error = e;
    }
    // 明文 HTTP 被运营商网络劫持（连接失败/超时/text/html 拦截页）时，
    // 自动改用 HTTPS 重试一次；HTTPS 也失败或仍返回 HTML 时维持原结果。
    if (uri.scheme == 'http') {
      final looksHtml =
          (response?.headers['content-type'] ?? '')
              .toLowerCase()
              .contains('text/html');
      if (error != null || looksHtml) {
        try {
          final retry = await once(uri.replace(scheme: 'https'));
          if (!(retry.headers['content-type'] ?? '')
              .toLowerCase()
              .contains('text/html')) {
            response = retry;
            error = null;
          }
        } catch (_) {
          // HTTPS 不可用，维持原结果。
        }
      }
    }
    if (error != null) {
      throw error;
    }
    if (response == null) {
      throw StateError('网络请求失败');
    }
    return response;
  }

  static PluginMediaSource? _toMediaSource(dynamic value) {
    if (value is String && _isHttpUrl(value)) {
      return PluginMediaSource(url: _normalizeMediaUrl(value));
    }
    if (value is! Map) return null;
    final url = value['url']?.toString().trim() ?? '';
    if (!_isHttpUrl(url)) return null;
    final headers = <String, String>{};
    final rawHeaders = value['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers[entry.key.toString()] = entry.value.toString();
      }
    }
    return PluginMediaSource(
      url: _normalizeMediaUrl(url),
      headers: headers,
      lyrics: _extractLyricsWithTranslation(value),
    );
  }

  static PluginVideoSource? _toVideoSource(dynamic value) {
    if (value is String && _isHttpUrl(value.trim())) {
      return PluginVideoSource(
        url: value.trim(),
        headers: const {
          'Referer': 'https://www.bilibili.com/',
          'Origin': 'https://www.bilibili.com',
        },
      );
    }
    if (value is! Map) return null;
    final url =
        (value['url'] ?? value['baseUrl'] ?? value['base_url'])
            ?.toString()
            .trim() ??
        '';
    if (!_isHttpUrl(url)) return null;
    final headers = <String, String>{};
    final rawHeaders = value['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers[entry.key.toString()] = entry.value.toString();
      }
    }
    headers.putIfAbsent('Referer', () => 'https://www.bilibili.com/');
    headers.putIfAbsent('Origin', () => 'https://www.bilibili.com');
    final backups = <String>[];
    for (final key in const [
      'backupUrls',
      'backup_urls',
      'backupUrl',
      'backup_url',
    ]) {
      final raw = value[key];
      if (raw is Iterable) {
        backups.addAll(
          raw
              .map((item) => item.toString().trim())
              .where((item) => _isHttpUrl(item)),
        );
      } else if (raw is String && _isHttpUrl(raw.trim())) {
        backups.add(raw.trim());
      }
    }
    return PluginVideoSource(
      url: url,
      backupUrls: backups,
      headers: headers,
      mimeType: value['mimeType']?.toString().trim().isNotEmpty == true
          ? value['mimeType'].toString().trim()
          : 'video/mp4',
    );
  }

  /// MV 播放源归一化。与 [_toVideoSource] 的区别：不强制注入 B 站
  /// Referer/Origin，其他插件的 MV 服务器可能校验自己的 Referer。
  static PluginVideoSource? _toMvSource(dynamic value) {
    if (value is String && _isHttpUrl(value.trim())) {
      return PluginVideoSource(url: value.trim());
    }
    if (value is! Map) return null;
    final url =
        (value['url'] ?? value['baseUrl'] ?? value['base_url'])
            ?.toString()
            .trim() ??
        '';
    if (!_isHttpUrl(url)) return null;
    final headers = <String, String>{};
    final rawHeaders = value['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers[entry.key.toString()] = entry.value.toString();
      }
    }
    final userAgent = value['userAgent']?.toString().trim() ?? '';
    if (userAgent.isNotEmpty) {
      headers.putIfAbsent('User-Agent', () => userAgent);
    }
    final backups = <String>[];
    for (final key in const [
      'backupUrls',
      'backup_urls',
      'backupUrl',
      'backup_url',
    ]) {
      final raw = value[key];
      if (raw is Iterable) {
        backups.addAll(
          raw
              .map((item) => item.toString().trim())
              .where((item) => _isHttpUrl(item)),
        );
      } else if (raw is String && _isHttpUrl(raw.trim())) {
        backups.add(raw.trim());
      }
    }
    // 画质信息（baka 系插件）：videoQuality 为实际选中档位，
    // availableVideoQualities 为可用档位列表（兼容 qualities 别名）。
    final selectedQuality =
        value['videoQuality']?.toString().trim() ?? '';
    final availableQualities = <String>[];
    for (final key in const [
      'availableVideoQualities',
      'available_video_qualities',
      'videoQualities',
    ]) {
      final raw = value[key];
      if (raw is Iterable) {
        for (final entry in raw) {
          final qualityKey = entry is Map
              ? (entry['key'] ?? entry['label'] ?? entry['quality'])
                  ?.toString()
                  .trim() ?? ''
              : entry?.toString().trim() ?? '';
          if (qualityKey.isNotEmpty &&
              !availableQualities.contains(qualityKey)) {
            availableQualities.add(qualityKey);
          }
        }
      }
    }
    for (final entry in value['qualities'] ?? const <dynamic>[]) {
      final qualityKey = entry is Map
          ? (entry['key'] ?? entry['label'] ?? entry['quality'])?.toString().trim() ?? ''
          : entry?.toString().trim() ?? '';
      if (qualityKey.isNotEmpty && !availableQualities.contains(qualityKey)) {
        availableQualities.add(qualityKey);
      }
    }
    return PluginVideoSource(
      url: url,
      backupUrls: backups,
      headers: headers,
      mimeType: value['mimeType']?.toString().trim().isNotEmpty == true
          ? value['mimeType'].toString().trim()
          : 'video/mp4',
      selectedQuality: selectedQuality.isEmpty ? null : selectedQuality,
      availableQualities: availableQualities,
    );
  }

  static const _bilibiliSpaceHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    'Referer': 'https://www.bilibili.com/',
    'Origin': 'https://www.bilibili.com',
  };

  /// B 站 wbi 签名混淆表。签名算法：取 imgKey+subKey 按本表取前 32 位
  /// 得 mixinKey，查询参数按 key 排序拼接后追加 mixinKey 取 md5。
  static const _wbiMixinTable = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5,
    49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55,
    40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57,
    62, 11, 36, 20, 34, 44, 52,
  ];

  static String? _cachedWbiMixinKey;
  static DateTime? _cachedWbiMixinKeyAt;

  Future<String?> _bilibiliWbiMixinKey() async {
    // wbi 密钥每天轮换，缓存一小时足够。
    final cachedAt = _cachedWbiMixinKeyAt;
    if (_cachedWbiMixinKey != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < const Duration(hours: 1)) {
      return _cachedWbiMixinKey;
    }
    final response = await _rawGet(
      Uri.https('api.bilibili.com', '/x/web-interface/nav'),
      headers: _bilibiliSpaceHeaders,
    );
    final decoded = jsonDecode(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    );
    if (decoded is! Map || decoded['data'] is! Map) return null;
    final wbi = (decoded['data'] as Map)['wbi_img'];
    if (wbi is! Map) return null;
    String keyFromUrl(dynamic url) =>
        url?.toString().split('/').last.split('.').first ?? '';
    final combined =
        keyFromUrl(wbi['img_url']) + keyFromUrl(wbi['sub_url']);
    if (combined.length < 64) return null;
    final buffer = StringBuffer();
    for (final index in _wbiMixinTable) {
      buffer.write(combined[index]);
      if (buffer.length == 32) break;
    }
    final key = buffer.toString();
    if (key.length != 32) return null;
    _cachedWbiMixinKey = key;
    _cachedWbiMixinKeyAt = DateTime.now();
    return key;
  }

  String _wbiSignedQuery(Map<String, String> params, String mixinKey) {
    final sortedKeys = params.keys.toList()..sort();
    final query = sortedKeys
        .map((key) => '$key=${Uri.encodeComponent(params[key]!)}')
        .join('&');
    final wRid = md5.convert(utf8.encode('$query$mixinKey')).toString();
    return '$query&w_rid=$wRid';
  }

  /// 从 UP 主条目中提取 mid。
  static String _extractBilibiliMid(Map<String, dynamic> raw) {
    bool isMid(String value) => RegExp(r'^\d{2,16}$').hasMatch(value);
    for (final key in const ['mid', 'uid', 'userId']) {
      final value = raw[key]?.toString().trim() ?? '';
      if (isMid(value)) return value;
    }
    for (final node in _nestedTrackNodes(raw)) {
      for (final key in const ['mid', 'uid', 'userId']) {
        final value = node[key]?.toString().trim() ?? '';
        if (isMid(value)) return value;
      }
    }
    // 兜底：某些插件把 mid 放在通用 id 字段。
    for (final node in _nestedTrackNodes(raw)) {
      final value = node['id']?.toString().trim() ?? '';
      if (isMid(value)) return value;
    }
    return '';
  }

  /// 直接调用 B 站空间投稿接口，分页拉取 UP 主的全部投稿视频。
  /// 插件的 getArtistWorks 大多忽略 page 参数只返回第一页，这里在
  /// 翻页检测失效时作为兜底，保证可以看到 UP 主的更多作品。
  Future<List<Map<String, dynamic>>> _fetchBilibiliSpaceArcs(
    Map<String, dynamic> rawData,
  ) async {
    final mid = _extractBilibiliMid(rawData);
    if (mid.isEmpty) return const [];
    final mixinKey = await _bilibiliWbiMixinKey();
    final result = <Map<String, dynamic>>[];
    const ps = 30;
    // 上限 50 页（1500 个投稿）防止异常数据导致无限请求。
    for (var pn = 1; pn <= 50; pn++) {
      final params = <String, String>{
        'mid': mid,
        'pn': '$pn',
        'ps': '$ps',
        'order': 'pubdate',
        'platform': 'web',
        'web_location': '1550101',
        'order_avoided': 'true',
      };
      final query = mixinKey == null
          ? params.entries
                .map((entry) => '${entry.key}=${entry.value}')
                .join('&')
          : _wbiSignedQuery(params, mixinKey);
      final queryMap = <String, String>{};
      for (final pair in query.split('&')) {
        final index = pair.indexOf('=');
        if (index > 0) {
          queryMap[pair.substring(0, index)] = pair.substring(index + 1);
        }
      }
      final response = await _rawGet(
        Uri.https('api.bilibili.com', '/x/space/wbi/arc/search', queryMap),
        headers: _bilibiliSpaceHeaders,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Bilibili 空间接口失败：HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
      if (decoded is! Map) {
        throw Exception('Bilibili 空间接口返回了无效数据');
      }
      final code = decoded['code'];
      if (code is num && code != 0) {
        throw Exception(
          'Bilibili 空间接口失败'
          '${decoded['message'] == null ? '' : '：${decoded['message']}'}',
        );
      }
      final data = decoded['data'];
      final vlist = data is Map && data['list'] is Map
          ? (data['list'] as Map)['vlist']
          : null;
      if (vlist is! List || vlist.isEmpty) break;
      for (final item in vlist) {
        if (item is! Map) continue;
        final bvid = item['bvid']?.toString().trim() ?? '';
        if (bvid.isEmpty) continue;
        result.add({
          'id': bvid,
          'bvid': bvid,
          'title': item['title'],
          'artist': item['author'],
          'author': item['author'],
          'album': 'B站投稿',
          'length': item['length'],
          'duration': item['length'],
          'pic': item['pic'],
          'cover': item['pic'],
        });
      }
      if (vlist.length < ps) break;
    }
    return result;
  }

  Future<PluginVideoSource?> _resolveBilibiliVideoSource(
    Map<String, dynamic> rawData, {
    String? path,
    String? videoQuality,
  }) async {
    final identity = _extractBilibiliIdentity(rawData, path: path);
    if (identity.bvid.isEmpty && identity.aid.isEmpty) return null;
    final identityQuery = identity.bvid.isNotEmpty
        ? {'bvid': identity.bvid}
        : {'aid': identity.aid};
    final headers = const {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      'Referer': 'https://www.bilibili.com/',
      'Origin': 'https://www.bilibili.com',
    };

    var cid = identity.cid;
    if (cid.isEmpty) {
      final view = await _rawGet(
        Uri.https('api.bilibili.com', '/x/web-interface/view', identityQuery),
        headers: headers,
      );
      final data = _parseBilibiliResponse(view, 'Bilibili 视频信息解析');
      cid =
          (data['cid'] ??
                  (data['pages'] is List && data['pages'].isNotEmpty
                      ? data['pages'][0]['cid']
                      : null))
              ?.toString()
              .trim() ??
          '';
    }
    if (cid.isEmpty) throw Exception('Bilibili 视频信息中缺少 CID');

    final qn = _bilibiliQualityId(videoQuality);
    final query = <String, String>{
      ...identityQuery,
      'cid': cid,
      'qn': '$qn',
      'fnval': '16',
      'fourk': '1',
    };
    final play = await _rawGet(
      Uri.https('api.bilibili.com', '/x/player/playurl', query),
      headers: headers,
    );
    final data = _parseBilibiliResponse(play, 'Bilibili 视频流解析');
    final dash = data['dash'];
    final videos = dash is Map && dash['video'] is List
        ? (dash['video'] as List).whereType<Map>().toList()
        : const <Map>[];
    bool hasVideoUrl(Map? candidate) =>
        candidate?['baseUrl'] != null || candidate?['base_url'] != null;
    bool isAvc(Map? candidate) =>
        candidate?['codecs']?.toString().toLowerCase().startsWith('avc1') ==
        true;
    Map? selected;
    final target = qn;
    final sorted = [...videos]
      ..sort((left, right) {
        final codecOrder = (isAvc(right) ? 1 : 0).compareTo(
          isAvc(left) ? 1 : 0,
        );
        if (codecOrder != 0) return codecOrder;
        final leftId = (left['id'] as num?)?.toInt() ?? 0;
        final rightId = (right['id'] as num?)?.toInt() ?? 0;
        return rightId.compareTo(leftId);
      });
    selected = videos.cast<Map?>().firstWhere(
      (candidate) =>
          (candidate?['id'] as num?)?.toInt() == target &&
          hasVideoUrl(candidate),
      orElse: () => null,
    );
    selected ??= sorted.cast<Map?>().firstWhere(
      (candidate) =>
          ((candidate?['id'] as num?)?.toInt() ?? 0) <= target &&
          hasVideoUrl(candidate),
      orElse: () => null,
    );
    selected ??= sorted.isEmpty ? null : sorted.first;
    final direct =
        (selected?['baseUrl'] ??
                selected?['base_url'] ??
                (data['durl'] is List && (data['durl'] as List).isNotEmpty
                    ? (data['durl'] as List).first['url']
                    : null))
            ?.toString()
            .trim() ??
        '';
    if (!_isHttpUrl(direct)) return null;
    final backups = <String>[];
    final backup = selected?['backupUrl'] ?? selected?['backup_url'];
    if (backup is Iterable) {
      backups.addAll(
        backup
            .map((item) => item.toString().trim())
            .where((item) => _isHttpUrl(item)),
      );
    }
    // B 站画质 ID → 档位标签，供实际选中画质与可用档位列表展示。
    String? qualityLabel(Object? rawId) {
      final id = (rawId as num?)?.toInt();
      if (id == null) return null;
      const labels = <int, String>{
        16: '360P',
        32: '480P',
        64: '720P',
        74: '720P',
        80: '1080P',
        112: '1080P',
        116: '1080P',
        120: '4K',
        125: '4K',
        126: '4K',
        127: '4K',
      };
      return labels[id];
    }

    final selectedQuality = qualityLabel(selected?['id']);
    final availableQualities = <String>[];
    final acceptQuality = data['accept_quality'];
    if (acceptQuality is Iterable) {
      for (final rawId in acceptQuality) {
        final label = qualityLabel(rawId);
        if (label != null && !availableQualities.contains(label)) {
          availableQualities.add(label);
        }
      }
    }
    if (selectedQuality != null &&
        !availableQualities.contains(selectedQuality)) {
      availableQualities.insert(0, selectedQuality);
    }
    return PluginVideoSource(
      url: direct,
      backupUrls: backups,
      headers: headers,
      mimeType: selected?['mimeType']?.toString().trim().isNotEmpty == true
          ? selected!['mimeType'].toString().trim()
          : 'video/mp4',
      selectedQuality: selectedQuality,
      availableQualities: availableQualities,
    );
  }

  static Map<String, dynamic> _parseBilibiliResponse(
    http.Response response,
    String label,
  ) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('$label失败：HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    );
    if (decoded is! Map || decoded['data'] is! Map) {
      throw Exception('$label返回了无效数据');
    }
    if (decoded['code'] is num && decoded['code'] != 0) {
      throw Exception(
        '$label失败${decoded['message'] == null ? '' : '：${decoded['message']}'}',
      );
    }
    return Map<String, dynamic>.from(decoded['data'] as Map);
  }

  static int _bilibiliQualityId(String? quality) {
    final text = quality?.trim().toUpperCase() ?? '';
    final match = RegExp(r'\d+').firstMatch(text);
    final parsed = int.tryParse(match?.group(0) ?? '');
    if (parsed == null) return 64;
    const allowed = {6, 16, 32, 64, 74, 80, 112, 116, 120, 125, 126, 127};
    if (allowed.contains(parsed)) return parsed;
    // 高度值归一：2160→4K(120)、1080→80、720→64、480→32、360→16。
    const heightToId = {
      240: 6,
      360: 16,
      480: 32,
      720: 64,
      1080: 80,
      1440: 112,
      2160: 120,
    };
    return heightToId[parsed] ?? 64;
  }

  static ({String bvid, String aid, String cid}) _extractBilibiliIdentity(
    Map<String, dynamic> raw, {
    String? path,
  }) {
    final values = <String>[];
    for (final node in _nestedTrackNodes(raw)) {
      for (final key in const ['bvid', 'bv', 'aid', 'id', 'videoId']) {
        final value = node[key]?.toString().trim() ?? '';
        if (value.isNotEmpty) values.add(value);
      }
    }
    if (path != null && path.trim().isNotEmpty) {
      values.add(Uri.decodeComponent(path.split('/').last));
    }
    final text = values.join(' ');
    final bvid =
        RegExp(
          r'BV[0-9A-Za-z]{10,}',
          caseSensitive: false,
        ).firstMatch(text)?.group(0) ??
        '';
    final aid =
        RegExp(
          r'(?:^|\W)av?(\d+)(?:\W|$)',
          caseSensitive: false,
        ).firstMatch(text)?.group(1) ??
        (bvid.isEmpty
            ? values.firstWhere(
                (value) => RegExp(r'^\d+$').hasMatch(value),
                orElse: () => '',
              )
            : '');
    var cid = '';
    for (final node in _nestedTrackNodes(raw)) {
      final value = node['cid']?.toString().trim() ?? '';
      if (value.isNotEmpty) {
        cid = value;
        break;
      }
    }
    return (bvid: bvid, aid: aid, cid: cid);
  }

  static String _extractLyrics(dynamic value) {
    if (value is String) {
      final text = value.trim();
      if (text.isEmpty || _isHttpUrl(text)) return '';
      if (text.startsWith('{') || text.startsWith('[')) {
        try {
          final nested = _extractLyrics(jsonDecode(text));
          if (nested.isNotEmpty) return nested;
        } catch (_) {
          // 字幕正文也可能以方括号开头，解析失败后仍按 LRC 返回。
        }
      }
      return text;
    }
    if (value is List) return _formatLyricLineList(value);
    if (value is! Map) return '';
    for (final key in const [
      // 逐字格式必须优先于普通 LRC，否则同一响应同时包含 lrc/yrc 时
      // 会提前返回逐行歌词，播放页永远拿不到 words 时间轴。
      'yrc',
      'qrc',
      'eslrc',
      'lxlyric',
      'lyric',
      'rawLrc',
      'rawLyric',
      'lrc',
      'lyrics',
      'originalLyric',
      'originalLyrics',
      'content',
    ]) {
      final lyric = value[key];
      if (lyric is String || lyric is Map || lyric is List) {
        final nested = _extractLyrics(lyric);
        if (nested.isNotEmpty) return nested;
      }
    }
    for (final key in const ['lrclist', 'lyricList', 'lines']) {
      final lines = _formatLyricLineList(value[key]);
      if (lines.isNotEmpty) return lines;
    }
    final data = value['data'];
    return data is Map || data is List ? _extractLyrics(data) : '';
  }

  static bool _hasWordTiming(String lyrics) {
    if (lyrics.isEmpty) return false;
    return RegExp(
          r'^\[\d+,\d+\].*\(-?\d+,-?\d+',
          multiLine: true,
        ).hasMatch(lyrics) ||
        RegExp(
          r'^\[\d+:\d{2}(?:\.\d+)?\].*<[^>]+>',
          multiLine: true,
        ).hasMatch(lyrics) ||
        RegExp(r'<tt[\s>]', caseSensitive: false).hasMatch(lyrics);
  }

  /// 识别「疑似密文」的歌词文本：部分 QQ 音源插件用 crypt:1 请求歌词，
  /// 接口返回的是未解密的十六进制密文（纯 [0-9a-f] 长串、无任何时间
  /// 标签），插件不解密直接透传。这种文本当作歌词会渲染成整屏乱码，
  /// 需要识别出来跳过，改走平台兜底拿真正的 LRC。正常纯文本歌词
  /// 一定含有十六进制之外的字符（汉字/标点/空格换行以外的字母），
  /// 不会被误伤。
  static bool _isLikelyEncryptedLyrics(String lyrics) {
    final text = lyrics.trim();
    if (text.length < 64) return false;
    // 含 LRC 时间标签或逐字格式的一定是正常歌词。
    if (RegExp(r'\[\d{1,3}:\d{1,2}(?:[.:]\d+)?\]').hasMatch(text) ||
        RegExp(r'^\[\d+,\d+\]', multiLine: true).hasMatch(text) ||
        _hasWordTiming(text)) {
      return false;
    }
    return RegExp(r'^[0-9a-fA-F\s]+$').hasMatch(text);
  }

  /// 插件歌词响应还原为「主歌词 + 翻译 + 罗马音」的拼接文本，与
  /// buildLxLyricsRaw 的输出格式一致：Rust 解析器按时间戳与文字脚本
  /// 把翻译/罗马音行合并进 displayLine 的对应字段。此前只取主歌词，
  /// MusicFree 插件（ILyricSource.rawLrc + translation，或 LX 风格的
  /// lyric + tlyric）返回的翻译被整段丢弃，表现为插件歌曲无翻译。
  static String _extractLyricsWithTranslation(dynamic value) {
    final main = _extractLyrics(value);
    if (main.isEmpty || value is! Map) return main;
    // 主歌词是密文（QQ crypt:1）时，翻译/罗马音同样是密文。此前直接丢弃
    // 翻译；现在把密文的翻译/罗马音按行拼接透传，Rust 侧逐行解密后把
    // 翻译行合并进解析管线（对齐桌面端 combined 链路）。明文翻译在密文
    // 主词场景下无法随行拼接（会破坏 hex 检测），仍维持放弃。
    if (_isLikelyEncryptedLyrics(main)) {
      final parts = <String>[main];
      for (final extra in [
        _extractTranslation(value),
        _extractRomaji(value),
      ]) {
        if (_isLikelyEncryptedLyrics(extra)) parts.add(extra);
      }
      return parts.join('\n');
    }
    final translation = _extractTranslation(value);
    final romaji = _extractRomaji(value);
    if (translation.isEmpty && romaji.isEmpty) return main;
    return [main, translation, romaji]
        .where((item) => item.isNotEmpty)
        .join('\n');
  }

  static String _extractTranslation(dynamic value) {
    if (value is! Map) return '';
    for (final key in const [
      'tlyric',
      'tLyric',
      'translation',
      'translatedLyric',
      'transLyric',
    ]) {
      final text = _plainLyricText(value[key]);
      if (text.isNotEmpty) return text;
    }
    final data = value['data'];
    return data is Map ? _extractTranslation(data) : '';
  }

  static String _extractRomaji(dynamic value) {
    if (value is! Map) return '';
    for (final key in const [
      'rlyric',
      'rLyric',
      'roman',
      'romalrc',
      'romanization',
    ]) {
      final text = _plainLyricText(value[key]);
      if (text.isNotEmpty) return text;
    }
    final data = value['data'];
    return data is Map ? _extractRomaji(data) : '';
  }

  /// 歌词字段值可能是纯文本，也可能是网易风格的 `{ lyric: "..." }`
  /// 嵌套结构。
  static String _plainLyricText(dynamic value) {
    if (value is String) return value.trim();
    if (value is Map) {
      for (final key in const ['lyric', 'lrc', 'text', 'content']) {
        final nested = value[key];
        if (nested is String && nested.trim().isNotEmpty) {
          return nested.trim();
        }
      }
    }
    return '';
  }

  static String _extractLyricsUrl(dynamic value) {
    if (value is String) {
      final url = value.trim();
      return _isHttpUrl(url) ? url : '';
    }
    if (value is! Map) return '';
    for (final key in const [
      'lyricUrl',
      'lyric_url',
      'lyricsUrl',
      'lyrics_url',
      'lrcUrl',
      'lrc_url',
    ]) {
      final url = value[key]?.toString().trim() ?? '';
      if (_isHttpUrl(url)) return url;
    }
    for (final key in const ['lyric', 'lyrics', 'lrc', 'rawLrc', 'data']) {
      final nested = value[key];
      if (nested is String && _isHttpUrl(nested.trim())) {
        return nested.trim();
      }
      if (nested is Map) {
        final direct = nested['url']?.toString().trim() ?? '';
        if (_isHttpUrl(direct)) return direct;
        final url = _extractLyricsUrl(nested);
        if (url.isNotEmpty) return url;
      }
    }
    return '';
  }

  static String _formatLyricLineList(dynamic value) {
    if (value is! List) return '';
    final result = <String>[];
    for (final entry in value.whereType<Map>()) {
      final text =
          (entry['lineLyric'] ??
                  entry['text'] ??
                  entry['words'] ??
                  entry['lyric'] ??
                  entry['content'])
              ?.toString()
              .trim();
      if (text == null || text.isEmpty) continue;
      final rawTime =
          entry['time'] ??
          entry['timestamp'] ??
          entry['startTime'] ??
          entry['start'];
      final seconds = rawTime is num
          ? rawTime.toDouble()
          : double.tryParse(rawTime?.toString() ?? '');
      if (seconds == null) continue;
      final normalizedSeconds = seconds > 10000 ? seconds / 1000 : seconds;
      final minutes = normalizedSeconds ~/ 60;
      final wholeSeconds = normalizedSeconds.floor() % 60;
      final centiseconds = ((normalizedSeconds % 1) * 100).floor();
      result.add(
        '[${minutes.toString().padLeft(2, '0')}:'
        '${wholeSeconds.toString().padLeft(2, '0')}.'
        '${centiseconds.toString().padLeft(2, '0')}]$text',
      );
    }
    return result.join('\n');
  }

  static PluginMediaSource? _extractDirectUrl(Map<String, dynamic> raw) {
    for (final key in const ['url', 'playUrl', 'play_url', 'src']) {
      final value = raw[key]?.toString().trim() ?? '';
      if (_isHttpUrl(value)) {
        return PluginMediaSource(url: _normalizeMediaUrl(value));
      }
    }
    final qualities = raw['qualities'];
    if (qualities is Map) {
      for (final value in qualities.values) {
        if (value is Map) {
          final url = value['url']?.toString().trim() ?? '';
          if (_isHttpUrl(url)) {
            return PluginMediaSource(url: _normalizeMediaUrl(url));
          }
        }
      }
    }
    return null;
  }

  static bool _isHttpUrl(String value) =>
      value.startsWith('https://') || value.startsWith('http://');

  /// 部分音源服务仍返回酷我 CDN 的明文地址。Android 新版播放器和部分
  /// ROM 会在播放器层拒绝这类地址，即使应用已允许明文请求，最终表现为
  /// 一直加载。该 CDN 同时提供 HTTPS，优先升级到 HTTPS；其他域名保留
  /// 原地址，避免破坏只支持 HTTP 的插件音源。
  static String _normalizeMediaUrl(String value) {
    final normalized = value.trim();
    final uri = Uri.tryParse(normalized);
    final host = uri?.host.toLowerCase() ?? '';
    if (uri?.scheme.toLowerCase() == 'http' &&
        (host == 'car-bj.kuwo.cn' || host.endsWith('.kuwo.cn'))) {
      return uri!.replace(scheme: 'https').toString();
    }
    return normalized;
  }

  /// 封面地址规范化：Android 禁止加载明文 HTTP 远程图片，而酷狗等音源
  /// 仍返回 http:// 封面（imge.kugou.com 已支持 HTTPS），统一升级到
  /// HTTPS；本机地址保留原协议。写入 rawData 的同时也会随收藏/歌单持久
  /// 化，避免旧数据反复出现失效的明文地址。
  static String _normalizeImageUrl(String value) {
    var normalized = value.trim();
    if (normalized.startsWith('//')) normalized = 'https:$normalized';
    final uri = Uri.tryParse(normalized);
    final host = uri?.host.toLowerCase() ?? '';
    final isLocalHost =
        host == 'localhost' || host == '127.0.0.1' || host == '[::1]';
    if (normalized.startsWith('http://') && !isLocalHost) {
      normalized = 'https://${normalized.substring(7)}';
    }
    if (!_isHttpUrl(normalized)) return '';
    normalized = _stripBilibiliImageTransform(normalized);
    return _withNeteaseCoverScale(normalized);
  }

  /// Bilibili 图床（hdslb.com/biliimg.com）会在 /bfs/ 路径尾部追加
  /// `@320w_180h_1c.avif` 之类的缩放后缀，部分接口的 UP 主头像、视频
  /// 封面默认返回 .avif 缩略图。Flutter 图片解码器不支持 AVIF（部分
  /// Android ROM 也缺），这类地址直接解码失败显示占位图。B站插件本想
  /// 剥离该后缀，但其 `stripBilibiliImageTransform` 依赖 quickjs 环境
  /// 不存在的 `URL` 类而静默失效；宿主统一用字符串操作剥离，让所有
  /// 插件的 B站图片地址还原成原图。
  static String _stripBilibiliImageTransform(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return url;
    final host = uri.host.toLowerCase();
    final isBiliCdn =
        host == 'hdslb.com' ||
        host.endsWith('.hdslb.com') ||
        host == 'biliimg.com' ||
        host.endsWith('.biliimg.com');
    if (!isBiliCdn) return url;
    final path = uri.path;
    if (!path.contains('/bfs/')) return url;
    final atIndex = path.lastIndexOf('@');
    if (atIndex <= 0) return url;
    if (path.substring(atIndex + 1).contains('/')) return url;
    return uri.replace(path: path.substring(0, atIndex)).toString();
  }

  /// 与 cover_image.dart 的 normalizeCoverImageUrl 一致：网易云 CDN 封面
  /// 统一追加官方缩放参数，避免大原图超过 Rust 图片代理 5MB 上限。
  static String _withNeteaseCoverScale(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final host = uri.host.toLowerCase();
    if (host != 'music.126.net' && !host.endsWith('.music.126.net')) {
      return url;
    }
    if (uri.queryParameters.containsKey('param')) return url;
    final merged = <String, String>{...uri.queryParameters, 'param': '800y800'};
    return uri.replace(queryParameters: merged).toString();
  }

  static List<Map<String, dynamic>> _extractResultList(dynamic value) {
    if (value is List) {
      return value.whereType<Map>().map(Map<String, dynamic>.from).toList();
    }
    if (value is! Map) return const [];
    for (final key in const [
      'artistList',
      'artistlist',
      'artists',
      'artistResults',
      'albumList',
      'albumlist',
      'albums',
      'albumResults',
      'artistResult',
      'albumResult',
      // Bilibili 用户搜索接口返回 data.result；部分插件直接暴露
      // userList/users，不能只依赖 MusicFree 的 musicList 字段。
      'result',
      'userList',
      'userlist',
      'users',
      'userResults',
      'userResult',
      'resultList',
      'musicList',
      'musiclist',
      'songList',
      'songlist',
      'song_list',
      'songs',
      'tracks',
      'dataList',
      'list',
      'items',
      'data',
      'resData',
      'sheetList',
      'sheetlist',
      'playlists',
      'playlist',
    ]) {
      final nested = value[key];
      final result = _extractResultList(nested);
      if (result.isNotEmpty) return result;
    }
    return const [];
  }

  static PluginSearchSong _toSearchSong(
    String pluginId,
    Map<String, dynamic> raw,
  ) {
    String valueText(dynamic value) {
      if (value == null) return '';
      if (value is String) {
        return value.replaceAll(RegExp(r'<[^>]*>'), '').trim();
      }
      if (value is num || value is bool) return value.toString();
      if (value is List) {
        return value.map(valueText).where((item) => item.isNotEmpty).join('/');
      }
      if (value is Map) {
        for (final key in const [
          'name',
          'title',
          'value',
          'artist',
          'singer',
          'author',
        ]) {
          final nested = valueText(value[key]);
          if (nested.isNotEmpty) return nested;
        }
      }
      return '';
    }

    String text(List<String> keys) {
      for (final key in keys) {
        final value = valueText(raw[key]);
        if (value.isNotEmpty) return value;
      }
      return '';
    }

    final artist = text(const [
      'artist',
      'singer',
      'author',
      'artists',
      'ar',
      'singerList',
      'artistList',
    ]);
    final album = text(const [
      'albumName',
      'album_name',
      'albumname',
      'albumTitle',
      'album',
      'al',
    ]);
    var id = text(const ['id', 'songId', 'musicId', 'mid']);
    if (id.isEmpty) id = _extractTrackId(raw);
    return PluginSearchSong(
      pluginId: pluginId,
      id: id.isEmpty ? raw.hashCode.toString() : id,
      title: text(const ['title', 'name', 'songname', 'songName']),
      artist: artist,
      album: album,
      durationMs: _parseDuration(raw),
      coverUrl: _extractCover(raw),
      rawData: raw,
      platform: _extractSubPlatform(raw),
    );
  }

  /// 提取「单插件多平台」源的子平台展示名：洛雪（lx.source 短码）与
  /// animemusic 后端（animeSrc/_src/_source 短码）。MusicFree 系的
  /// platform 字段已被 _resetMediaItem 覆盖为插件名（冗余），不提取。
  static String _extractSubPlatform(Map<String, dynamic> raw) {
    final lx = raw['lx'];
    if (lx is Map) {
      final code = lx['source']?.toString().trim() ?? '';
      if (code.isNotEmpty) return _platformCodeLabel(code);
    }
    final code = _toAnimemusicPlatformCode(
      (raw['animeSrc'] ?? raw['_src'] ?? raw['_source'] ?? '').toString(),
    );
    return code.isEmpty ? '' : _platformCodeLabel(code);
  }

  /// 平台短码 → 展示名（与洛雪音源命名一致，含 animemusic 的扩展平台）。
  static String _platformCodeLabel(String code) => switch (code) {
    'wy' => '网易云',
    'tx' => 'QQ音乐',
    'kw' => '酷我',
    'kg' => '酷狗',
    'mg' => '咪咕',
    'bilibili' => 'B站',
    _ => code.toUpperCase(),
  };

  static int _parseDuration(Map<String, dynamic> raw) {
    for (final key in const [
      'duration',
      'interval',
      'dt',
      'time',
      'length',
      'timelength',
      'songTime',
    ]) {
      final value = raw[key];
      if (value is num && value > 0) {
        // 听书章节可达 30+ 分钟（1800 秒），阈值取 10000：秒值
        // （16 分钟内）按秒换算，毫秒值（10 秒以上）保持原样。
        return value > 10000 ? value.floor() : (value * 1000).floor();
      }
      if (value is String && value.contains(':')) {
        final parts = value.split(':').map(int.tryParse).toList();
        if (parts.every((item) => item != null)) {
          var seconds = 0;
          for (final part in parts) {
            seconds = seconds * 60 + part!;
          }
          return seconds * 1000;
        }
      }
      final number = value is String ? double.tryParse(value) : null;
      if (number != null && number > 0) {
        return number > 10000 ? number.floor() : (number * 1000).floor();
      }
    }
    return 0;
  }

  static String _extractCover(Map<String, dynamic> raw) {
    for (final node in _nestedTrackNodes(raw)) {
      final cover = _extractCoverFromNode(node);
      if (cover.isNotEmpty) return cover;
    }
    return '';
  }

  /// 仅供回归测试验证封面提取（picId 兜底生成的 URL 含 param 缩放）。
  @visibleForTesting
  static String extractCoverForTest(Map<String, dynamic> raw) =>
      _extractCover(raw);

  static String _extractCoverFromNode(Map<String, dynamic> node) {
    for (final key in const [
      'artwork',
      'cover',
      'coverImg',
      'coverUrl',
      'cover_url',
      'coverImgUrl',
      'picUrl',
      'picurl',
      'pic',
      'img',
      'imgUrl',
      'imgurl',
      'albumPic',
      'picture',
      'blurPicUrl',
      'avatar',
      'avatarUrl',
      'avatar_url',
      // Bilibili 用户搜索结果常用 upic/face。
      'upic',
      'face',
      'userFace',
      'user_face',
      'headUrl',
      'head_url',
    ]) {
      final value = node[key];
      if (value is String) {
        final normalized = _normalizeImageUrl(value);
        if (normalized.isNotEmpty) return normalized;
      }
    }

    // 网易云 weapi/search 经常只返回 picId_str，由其生成与
    // 电脑端相同的官方 CDN 地址，无需再为每首歌请求详情。
    final picId = _extractReliableNeteasePicId(node);
    if (picId != null) {
      return _neteasePicIdToUrl(picId);
    }
    return '';
  }

  /// 按电脑端的字段范围遍历插件数据。限制三层嵌套并做身份去重，
  /// 避免异常插件返回循环对象时无限递归。
  static List<Map<String, dynamic>> _nestedTrackNodes(
    Map<String, dynamic> root,
  ) {
    const nestedKeys = [
      'rawData',
      'raw',
      'song',
      'data',
      'music',
      'musicInfo',
      'detail',
      'album',
      'al',
    ];
    final result = <Map<String, dynamic>>[];
    final seen = <Map>{};
    var level = <Map>[root];
    for (var depth = 0; depth < 4 && level.isNotEmpty; depth++) {
      final next = <Map>[];
      for (final value in level) {
        if (!seen.add(value)) continue;
        final node = Map<String, dynamic>.from(value);
        result.add(node);
        for (final key in nestedKeys) {
          final child = value[key];
          if (child is Map) next.add(child);
        }
      }
      level = next;
    }
    return result;
  }

  static String? _extractReliableNeteasePicId(Map<String, dynamic> node) {
    for (final key in const ['picId_str', 'pic_str', 'picId', 'pic']) {
      final value = node[key];
      if (value is String) {
        final id = value.trim();
        if (id != '0' && RegExp(r'^\d+$').hasMatch(id)) return id;
      }
      // JS Number 超过 2^53-1 时已经丢失精度，不能用错误的 ID
      // 生成看似正常但实际 404 的封面地址。
      if (value is int && value > 0 && value <= 9007199254740991) {
        return value.toString();
      }
    }
    return null;
  }

  static String _neteasePicIdToUrl(String picId) {
    const magic = '3go8&\$8*3*3h0k(2)2';
    final bytes = <int>[
      for (var index = 0; index < picId.length; index++)
        picId.codeUnitAt(index) ^ magic.codeUnitAt(index % magic.length),
    ];
    final encrypted = base64UrlEncode(md5.convert(bytes).bytes);
    // param 缩放避免大原图超过 Rust 图片代理 5MB 上限（见 cover_image.dart）。
    return 'https://p1.music.126.net/$encrypted/$picId.jpg?param=800y800';
  }

  static dynamic _decodeResult(String input) {
    dynamic value = input;
    for (var i = 0; i < 3 && value is String; i++) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        break;
      }
    }
    return value;
  }

  static String _friendlyError(String message) {
    return message
        .replaceFirst(RegExp(r'^Exception:\s*'), '')
        .replaceAll('TypeError: ', '')
        .trim();
  }

  /// 在给定服务实例上执行一次插件操作：一次性冷启动执行器与常驻
  /// 工作 isolate 共用这段分发逻辑。
  static Future<dynamic> _executePluginOperation(
    PluginRuntimeService service,
    EnabledMusicPlugin plugin,
    String operation,
    dynamic payload,
  ) async {
    dynamic data;
    switch (operation) {
      case 'search':
        {
          final searchPayload = payload is Map
              ? Map<String, dynamic>.from(payload)
              : <String, dynamic>{'keyword': payload?.toString() ?? ''};
          data = await service._callOnCurrentIsolate(plugin, 'search', [
            searchPayload['keyword']?.toString() ?? '',
            1,
            searchPayload['type']?.toString() ?? 'music',
          ]);
          break;
        }
      case 'getArtistWorks':
        {
          if (payload is! Map || payload['rawData'] is! Map) {
            throw Exception('歌手信息格式无效');
          }
          final payloadMap = Map<String, dynamic>.from(payload);
          data = await service._callOnCurrentIsolate(plugin, 'getArtistWorks', [
            Map<String, dynamic>.from(payloadMap['rawData'] as Map),
            (payloadMap['page'] as num?)?.toInt() ?? 1,
            payloadMap['type']?.toString() ?? 'music',
          ]);
          break;
        }
      case 'getAlbumInfo':
        {
          if (payload is! Map || payload['rawData'] is! Map) {
            throw Exception('专辑信息格式无效');
          }
          final payloadMap = Map<String, dynamic>.from(payload);
          data = await service._callOnCurrentIsolate(plugin, 'getAlbumInfo', [
            Map<String, dynamic>.from(payloadMap['rawData'] as Map),
            (payloadMap['page'] as num?)?.toInt() ?? 1,
          ]);
          break;
        }
      case 'getTopLists':
        data = await service._callOnCurrentIsolate(plugin, 'getTopLists', []);
        break;
      case 'resolveMediaSource':
        if (payload is! Map) throw Exception('歌曲信息格式无效');
        final wrappedRawData = payload['rawData'];
        final rawData = wrappedRawData is Map
            ? Map<String, dynamic>.from(wrappedRawData)
            : Map<String, dynamic>.from(payload);
        final preferredQuality = wrappedRawData is Map
            ? payload['preferredQuality']?.toString()
            : null;
        final source = await service._resolveMediaSourceOnCurrentIsolate(
          plugin,
          rawData,
          preferredQuality: preferredQuality,
        );
        data = {
          'url': source.url,
          'headers': source.headers,
          'lyrics': source.lyrics,
        };
        break;
      case 'probeMediaSource':
        if (payload is! Map || payload['rawData'] is! Map) {
          throw Exception('歌曲信息格式无效');
        }
        final payloadMap = Map<String, dynamic>.from(payload);
        final rawData = Map<String, dynamic>.from(payloadMap['rawData'] as Map);
        final quality = payloadMap['quality']?.toString() ?? '';
        final response = await service._callOnCurrentIsolate(
          plugin,
          'getMediaSource',
          [rawData, quality],
        );
        data = PluginRuntimeService._toMediaSource(response) != null;
        break;
      case 'discoverQualities':
        if (payload is! Map || payload['rawData'] is! Map) {
          throw Exception('歌曲信息格式无效');
        }
        final payloadMap = Map<String, dynamic>.from(payload);
        final rawData = Map<String, dynamic>.from(payloadMap['rawData'] as Map);
        final values = payloadMap['qualities'] is List
            ? (payloadMap['qualities'] as List)
                  .map((value) => value.toString())
                  .where((value) => value.trim().isNotEmpty)
                  .toList()
            : const <String>[];
        final supported = <String>[];
        for (final quality in values) {
          try {
            final response = await service
                ._callOnCurrentIsolate(plugin, 'getMediaSource', [
                  rawData,
                  quality,
                ])
                .timeout(const Duration(seconds: 4));
            if (PluginRuntimeService._toMediaSource(response) != null) {
              supported.add(quality);
            }
          } catch (_) {
            // 该档位不可用，继续探测其余档位。
          }
        }
        data = supported;
        break;
      case 'resolveVideoSource':
        if (payload is! Map || payload['rawData'] is! Map) {
          throw Exception('视频歌曲信息格式无效');
        }
        final payloadMap = Map<String, dynamic>.from(payload);
        final rawData = Map<String, dynamic>.from(payloadMap['rawData'] as Map);
        final source = await service._resolveVideoSourceOnCurrentIsolate(
          plugin,
          rawData,
          videoQuality: payloadMap['videoQuality']?.toString(),
        );
        if (source == null) throw Exception('插件没有返回视频地址');
        data = {
          'url': source.url,
          'backupUrls': source.backupUrls,
          'headers': source.headers,
          'mimeType': source.mimeType,
          if (source.selectedQuality != null)
            'videoQuality': source.selectedQuality,
          'availableVideoQualities': source.availableQualities,
        };
        break;
      case 'resolveMvSource':
        if (payload is! Map || payload['rawData'] is! Map) {
          throw Exception('MV 歌曲信息格式无效');
        }
        final payloadMap = Map<String, dynamic>.from(payload);
        final rawData = Map<String, dynamic>.from(payloadMap['rawData'] as Map);
        final source = await service._resolveMvSourceOnCurrentIsolate(
          plugin,
          rawData,
          videoQuality: payloadMap['videoQuality']?.toString(),
        );
        if (source == null) throw Exception('插件没有返回 MV 地址');
        data = {
          'url': source.url,
          'backupUrls': source.backupUrls,
          'headers': source.headers,
          'mimeType': source.mimeType,
          if (source.selectedQuality != null)
            'videoQuality': source.selectedQuality,
          'availableVideoQualities': source.availableQualities,
        };
        break;
      case 'getLyrics':
        if (payload is! Map) throw Exception('歌曲信息格式无效');
        data = await service._getLyricsOnCurrentIsolate(
          plugin,
          Map<String, dynamic>.from(payload),
        );
        break;
      case 'getMusicComments':
        if (payload is! Map || payload['musicItem'] is! Map) {
          throw Exception('歌曲信息格式无效');
        }
        final payloadMap = Map<String, dynamic>.from(payload);
        data = await service._callOnCurrentIsolate(
          plugin,
          'getMusicComments',
          [
            Map<String, dynamic>.from(payloadMap['musicItem'] as Map),
            payloadMap['page'] is num
                ? (payloadMap['page'] as num).toInt()
                : 1,
          ],
        );
        break;
      case 'importPlaylist':
        data = await service._importPlaylistOnCurrentIsolate(
          plugin,
          payload?.toString().trim() ?? '',
        );
        break;
      default:
        throw Exception('不支持的插件后台操作：$operation');
    }
    return data;
  }

  void dispose() {
    _disposeRequested = true;
    _pluginWorker?.kill();
    if (_activeRuntimeOperations > 0) return;
    _disposeNow();
  }

  void _disposeNow() {
    _runtime?.dispose();
    _runtime = null;
    _initializing = null;
    _disposeRequested = false;
    _loaded.clear();
    _loadedLx.clear();
    _pluginSourceTasks.clear();
    _neteaseTrackMetaCache.clear();
    _qualityDiscoveryCache.clear();
  }
}

/// 判断一个已启用插件是否为哔哩哔哩音源，供搜索页按平台显示“UP主”分类。
bool isBilibiliPluginSource(EnabledMusicPlugin plugin) =>
    PluginRuntimeService._isBilibiliPlugin(plugin);

/// 识别音源类别（歌单导入页、换源面板等处的分类标记）：
/// - BakaMusic：由 [EnabledMusicPlugin.isBaka] 判定，其中已包含契约特征
///   （animeSrc）、订阅类型提示与来源 URL 兜底，此处不再重复按 URL 判定，
///   否则会在「提示为 MusicFree 但来源 URL 仍是旧 Baka 订阅」时与插件
///   管理页分栏不一致。
/// - `animemusic.bzxhkj.com/animemusic*` / `/v2` / `/v3` →「惜梦」
/// - 无来源记录时回退旧规则：名称含 baka →「BakaMusic」；animemusic/1
///   格式 →「惜梦」；其余 →「MusicFree」。
String pluginSourceTag(EnabledMusicPlugin plugin) {
  // 契约特征最准：优先于 URL 前缀（BakaMusic 契约插件可能托管在
  // 任意订阅源上，如 QQ音乐[L1]）。
  if (plugin.isBaka) return 'BakaMusic';
  final url = plugin.sourceUrl.trim().toLowerCase();
  if (url.isNotEmpty &&
      RegExp(
        r'^https?://animemusic\.bzxhkj\.com/(animemusic|v\d+)',
      ).hasMatch(url)) {
    return '惜梦';
  }
  if (plugin.name.toLowerCase().contains('baka')) return 'BakaMusic';
  if (plugin.isAnimemusic) return '惜梦';
  return 'MusicFree';
}

class _NeteaseTrackMeta {
  const _NeteaseTrackMeta({required this.coverUrl, required this.durationMs});

  final String coverUrl;
  final int durationMs;
}

/// 供封面渲染、数据迁移和单元测试复用的插件封面归一化入口。
String extractPluginCoverUrl(Map<String, dynamic> raw) =>
    PluginRuntimeService._extractCover(raw);

/// 由可靠的网易云 picId 生成官方 CDN 封面地址。
String neteasePicIdToCoverUrl(String picId) =>
    PluginRuntimeService._neteasePicIdToUrl(picId);

Map<String, String> _decodeUserVariables(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const {};
    return {
      for (final entry in decoded.entries)
        if (entry.value is String)
          entry.key.toString(): entry.value as String,
    };
  } catch (_) {
    return const {};
  }
}

Future<String> _executePluginOperationInBackground(
  Map<String, String> request,
) async {
  final client = _PluginBackgroundHttpClient();
  final service = PluginRuntimeService(
    httpClient: client,
    runtimeBootstrap: request['bootstrap'],
    runtimeLxBootstrap: request['lxBootstrap'],
    pluginSources: {request['pluginId'] ?? '': request['pluginSource'] ?? ''},
  );
  try {
    final plugin = EnabledMusicPlugin(
      id: request['pluginId'] ?? '',
      name: request['pluginName'] ?? '',
      path: request['pluginPath'] ?? '',
      userVariables: _decodeUserVariables(request['userVariables']),
    );
    final payload = jsonDecode(request['payload'] ?? 'null');
    final data = await PluginRuntimeService._executePluginOperation(
      service,
      plugin,
      request['operation'] ?? '',
      payload,
    );
    return jsonEncode({'ok': true, 'data': data});
  } catch (error, stackTrace) {
    return jsonEncode({
      'ok': false,
      'error': error.toString(),
      'stack': stackTrace.toString(),
    });
  } finally {
    service.dispose();
    client.close();
  }
}

/// 常驻插件工作 isolate：QuickJS 运行时与各插件只加载一次，之后
/// 所有操作复用热运行时。此前每次播放/搜索都要在全新 isolate 里
/// 冷启动 JS 引擎并重新 eval 插件源码，纯 CPU 负载在省电调度下
/// 会被显著拖慢（表现为部分机型播放加载特别慢，录屏等高性能
/// 状态下又恢复正常）。
class _PluginWorker {
  _PluginWorker._(this._isolate, this._sendPort, this._responses);

  final Isolate _isolate;
  final SendPort _sendPort;
  final ReceivePort _responses;
  final Map<int, Completer<Object?>> _pending = {};
  int _nextRequestId = 0;

  /// isolate 意外退出或被终止时通知服务清空引用，下次调用重新拉起。
  void Function()? onDead;

  /// 单请求兜底超时：防止插件 JS 死循环或异常把常驻 isolate 永久
  /// 挂死，超时后终止 isolate，下一次调用时自动重启。
  static const _requestTimeout = Duration(seconds: 120);

  static Future<_PluginWorker> spawn() async {
    final bootstrap = await rootBundle.loadString(
      'assets/plugin_runtime.js',
    );
    final lxBootstrap = await rootBundle.loadString(
      'assets/lx_plugin_runtime.js',
    );
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(
      _pluginWorkerEntry,
      <String, Object?>{
        'bootstrap': bootstrap,
        'lxBootstrap': lxBootstrap,
        'ready': ready.sendPort,
      },
      debugName: 'music-plugin-worker',
    );
    final sendPort = await ready.first as SendPort;
    final responses = ReceivePort();
    final worker = _PluginWorker._(isolate, sendPort, responses);
    responses.listen(
      worker._handleMessage,
      onDone: worker._handleWorkerGone,
    );
    return worker;
  }

  void _handleMessage(Object? message) {
    if (message is! Map) return;
    final id = message['requestId'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    completer.complete(message);
  }

  void _handleWorkerGone() {
    final pending = List<Completer<Object?>>.of(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      completer.completeError(Exception('插件运行时已退出'));
    }
    onDead?.call();
  }

  /// 提交一次操作并等待回复。回复始终以 Map 返回（含 ok 字段），
  /// 只有 isolate 基础设施故障（崩溃/超时）才会让 Future 出错。
  Future<Object?> run(Map<String, Object?> request) {
    final id = ++_nextRequestId;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _sendPort.send({
      ...request,
      'requestId': id,
      'replyTo': _responses.sendPort,
    });
    return completer.future.timeout(_requestTimeout, onTimeout: () {
      kill();
      throw Exception('插件后台调用超时');
    });
  }

  void kill() {
    _handleWorkerGone();
    _responses.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

/// 常驻工作 isolate 入口：创建一个持久化的插件服务实例（QuickJS
/// 运行时与已加载插件全程存活），循环处理主 isolate 的操作请求。
void _pluginWorkerEntry(Map<String, Object?> init) {
  final service = PluginRuntimeService(
    httpClient: _PluginBackgroundHttpClient(),
    runtimeBootstrap: init['bootstrap'] as String?,
    runtimeLxBootstrap: init['lxBootstrap'] as String?,
    pluginSources: <String, String>{},
  );
  final requests = ReceivePort();
  (init['ready'] as SendPort).send(requests.sendPort);
  requests.listen((message) {
    if (message is! Map) return;
    final replyTo = message['replyTo'];
    if (replyTo is! SendPort) return;
    final requestId = message['requestId'];
    _runPluginWorkerRequest(service, message).then(
      (data) =>
          replyTo.send({'requestId': requestId, 'ok': true, 'data': data}),
      onError: (Object error) => replyTo.send({
        'requestId': requestId,
        'ok': false,
        'error': error.toString(),
      }),
    );
  });
}

Future<dynamic> _runPluginWorkerRequest(
  PluginRuntimeService service,
  Map<Object?, Object?> message,
) async {
  final pluginId = message['pluginId']?.toString() ?? '';
  final pluginSource = message['pluginSource'];
  if (pluginSource is String && pluginSource.isNotEmpty) {
    // 主 isolate 解析好的插件源码（含内置插件覆盖），注入后由
    // 服务按插件 id 缓存，后续请求直接复用。
    service.pluginSources[pluginId] = pluginSource;
  }
  final plugin = EnabledMusicPlugin(
    id: pluginId,
    name: message['pluginName']?.toString() ?? '',
    path: message['pluginPath']?.toString() ?? '',
    userVariables: _decodeUserVariables(message['userVariables']?.toString()),
  );
  final payload = jsonDecode(message['payload']?.toString() ?? 'null');
  return PluginRuntimeService._executePluginOperation(
    service,
    plugin,
    message['operation']?.toString() ?? '',
    payload,
  );
}

/// 后台 isolate 不能复用主 isolate 中已经初始化的 Rust 桥，因此直接使用
/// Dart IO HTTP 客户端。插件响应仍通过 Base64 送进 QuickJS，避免正文中的
/// 反斜杠、反引号和换行被 XHR 扩展二次解释。
class _PluginBackgroundHttpClient extends http.BaseClient {
  _PluginBackgroundHttpClient() : _client = http.Client();

  static const _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Safari/537.36';

  final http.Client _client;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.headers.putIfAbsent('user-agent', () => _desktopUserAgent);
    // 该客户端由常驻 worker isolate 长期持有，默认复用 keep-alive 连接。
    // 手机在 Wi-Fi/蜂窝间切换或 CDN 静默断开空闲连接后，复用旧 socket 会
    // 在 TLS 层解密失败（BAD_DECRYPT / DECRYPTION_FAILED_OR_BAD_RECORD_MAC）
    // 或被直接重置，表现为「无法连接音源服务器」。插件请求均为用户触发的
    // 低频请求，禁用连接复用带来的握手开销可忽略，却能根除陈旧连接问题。
    request.persistentConnection = false;
    http.StreamedResponse? response;
    Object? error;
    try {
      response = await _client
          .send(request)
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      error = e;
    }
    // 明文 HTTP 被运营商网络劫持（连接失败/超时/text/html 拦截页）时，
    // 自动改用 HTTPS 重试一次；HTTPS 也失败则维持原结果。
    if (request.url.scheme == 'http') {
      final looksHtml = response != null &&
          (response.headers['content-type'] ?? '')
              .toLowerCase()
              .contains('text/html');
      if (error != null || looksHtml) {
        final httpsRequest = http.Request(
          request.method,
          request.url.replace(scheme: 'https'),
        )..headers.addAll(request.headers);
        if (request is http.Request && request.bodyBytes.isNotEmpty) {
          httpsRequest.bodyBytes = request.bodyBytes;
        }
        try {
          final retry = await _client
              .send(httpsRequest)
              .timeout(const Duration(seconds: 20));
          if (!(retry.headers['content-type'] ?? '')
              .toLowerCase()
              .contains('text/html')) {
            response = retry;
            error = null;
          }
        } catch (_) {
          // HTTPS 不可用，维持原结果。
        }
      }
    }
    if (error != null || response == null) {
      return _syntheticPluginNetworkFailure(
        request,
        '网络请求失败：无法连接音源服务器（网络受限或服务器不可达）',
      );
    }
    // 直接按原始字节 Base64 包装，避免 utf8 解码破坏二进制响应
    // （酷我 newlyric 等接口返回二进制歌词，插件以 arraybuffer 消费）。
    List<int> bytes;
    try {
      bytes = await response.stream.toBytes();
    } catch (_) {
      return _syntheticPluginNetworkFailure(
        request,
        '网络请求失败：响应传输中断（网络受限或服务器不可达）',
      );
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode(encodePluginHttpBodyBytes(bytes))),
      response.statusCode,
      contentLength: null,
      request: request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  /// 网络失败不能向 QuickJS XHR 桥接抛出：桥接（quickjs_engine 的
  /// xhr.dart）Dart 回调链没有异常保护，抛出会让 JS 侧 Promise 永久
  /// 挂起，用户侧表现为播放长时间转圈后失败。与 _PluginProxyHttpClient
  /// 一致返回合成 599 JSON，让插件立即以明确错误 reject。
  static http.StreamedResponse _syntheticPluginNetworkFailure(
    http.BaseRequest request,
    String message,
  ) {
    final body = jsonEncode({'code': 599, 'message': message});
    return http.StreamedResponse(
      Stream.value(utf8.encode(encodePluginHttpBody(body))),
      599,
      headers: const {'content-type': 'application/json'},
      request: request,
      reasonPhrase: 'Plugin network request failed',
    );
  }

  @override
  void close() => _client.close();
}

class _PluginProxyHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bodyBytes = await request.finalize().toBytes();
    final url = request.url.toString();
    final bodyText = bodyBytes.isEmpty
        ? null
        : utf8.decode(bodyBytes, allowMalformed: true);
    Map<String, dynamic>? response = await _pluginBinaryRequest(
      method: request.method,
      url: url,
      headersJson: jsonEncode(request.headers),
      body: bodyText,
    );
    // 部分运营商网络会劫持明文 HTTP：连接直接失败、超时，或返回
    // text/html 拦截页（荣耀等设备实测）。此时自动改用 HTTPS 重试一次；
    // HTTPS 也失败或同样返回 HTML 时维持原结果，不影响仅支持 HTTP 的音源。
    if (url.startsWith('http://')) {
      final intercepted =
          response == null || _pluginResponseIsHtmlPage(response);
      if (intercepted) {
        final retry = await _pluginBinaryRequest(
          method: request.method,
          url: 'https://${url.substring('http://'.length)}',
          headersJson: jsonEncode(request.headers),
          body: bodyText,
        );
        if (retry != null && !_pluginResponseIsHtmlPage(retry)) {
          response = retry;
        }
      }
    }
    if (response == null) {
      // QuickJS XHR expects an HTTP response even when the native request
      // cannot connect. Returning a synthetic 599 response lets the plugin
      // reject the current operation normally instead of creating an
      // unhandled isolate error that replaces the whole app screen.
      final body = jsonEncode({
        'code': 599,
        'message': '网络请求失败：无法连接音源服务器（明文 HTTP 被网络拦截或服务器不可达）',
      });
      return http.StreamedResponse(
        Stream.value(utf8.encode(encodePluginHttpBody(body))),
        599,
        headers: const {'content-type': 'application/json'},
        request: request,
        reasonPhrase: 'Plugin network request failed',
      );
    }
    final bodyBase64 = response['body_base64']?.toString() ?? '';
    final headers = <String, String>{};
    final rawHeaders = response['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers[entry.key.toString()] = entry.value.toString();
      }
    }
    return http.StreamedResponse(
      Stream.value(
        utf8.encode('__XY_HTTP_BODY_BASE64__$bodyBase64'),
      ),
      (response['status'] as num?)?.toInt() ?? 500,
      headers: headers,
      request: request,
    );
  }

  /// 调用 Rust 二进制 HTTP 接口；失败（连接错误/超时）返回 null 而非抛错，
  /// 便于上层先尝试 HTTPS 回退再决定最终结果。
  Future<Map<String, dynamic>?> _pluginBinaryRequest({
    required String method,
    required String url,
    required String headersJson,
    String? body,
  }) async {
    try {
      final responseJson = await pluginHttpRequestBinary(
        method: method,
        url: url,
        headersJson: headersJson,
        body: body,
        timeout: BigInt.from(20),
        follow: 10,
      );
      return jsonDecode(responseJson) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// 判断插件 HTTP 响应是否为 text/html 页面（运营商拦截页特征）。
  static bool _pluginResponseIsHtmlPage(Map<String, dynamic> response) {
    final rawHeaders = response['headers'];
    if (rawHeaders is! Map) return false;
    for (final key in rawHeaders.keys) {
      if (key.toString().toLowerCase() == 'content-type') {
        return rawHeaders[key]
            ?.toString()
            .toLowerCase()
            .contains('text/html') ==
            true;
      }
    }
    return false;
  }
}

/// QuickJS 0.1.3 会把 XHR 正文插入模板字符串，正文中的反斜杠、换行等
/// 可能在 JSON.parse 前被二次解释。使用纯 ASCII Base64 作为桥接传输格式。
String encodePluginHttpBody(String body) =>
    '__XY_HTTP_BODY_BASE64__${base64Encode(utf8.encode(body))}';

/// 按原始字节 Base64 包装（二进制安全），供插件以 arraybuffer 消费
/// 二进制响应（酷我 newlyric 等接口）。
String encodePluginHttpBodyBytes(List<int> bytes) =>
    '__XY_HTTP_BODY_BASE64__${base64Encode(bytes)}';
