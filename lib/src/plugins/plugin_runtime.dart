import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
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

class EnabledMusicPlugin {
  const EnabledMusicPlugin({
    required this.id,
    required this.name,
    required this.path,
    this.isLx = false,
    this.lxSources = const [],
    this.userVariables = const {},
  });

  final String id;
  final String name;
  final String path;
  final bool isLx;
  final List<String> lxSources;

  /// 用户在插件管理中填写的用户变量值，加载插件时注入 env。
  final Map<String, String> userVariables;
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
  });

  final String pluginId;
  final String id;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final String coverUrl;
  final Map<String, dynamic> rawData;
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

/// Bilibili 视频流地址。DASH 视频通常需要 Referer 才能在 Android 播放器中
/// 正常打开，因此地址和请求头一起返回给详情页。
class PluginVideoSource {
  const PluginVideoSource({
    required this.url,
    this.backupUrls = const [],
    this.headers = const {},
    this.mimeType = 'video/mp4',
  });

  final String url;
  final List<String> backupUrls;
  final Map<String, String> headers;
  final String mimeType;
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

Future<List<EnabledMusicPlugin>> loadEnabledMusicPlugins(Ref ref) async {
  const enabledKey = 'mobileEnabledPlugins';
  final dataDir = await ref.read(appDataDirProvider.future);
  final directory = Directory(p.join(dataDir, 'plugins'));
  if (!directory.existsSync()) return const [];
  final prefs = await SharedPreferences.getInstance();
  final enabled = (prefs.getStringList(enabledKey) ?? const []).toSet();
  final savedVariables = readPluginUserVariables(prefs);
  final plugins = <EnabledMusicPlugin>[];
  for (final file in directory.listSync().whereType<File>()) {
    if (p.extension(file.path).toLowerCase() != '.js') continue;
    final id = p.basenameWithoutExtension(file.path);
    if (!enabled.contains(id)) continue;
    final source = await file.readAsString();
    final isLx = _looksLikeLxPlugin(source);
    final metadata = PluginMetadata.parse(source);
    plugins.add(
      EnabledMusicPlugin(
        id: id,
        name: metadata.name ?? id,
        path: file.path,
        isLx: isLx,
        lxSources: isLx ? _detectLxSources(source) : const [],
        userVariables: savedVariables[id] ?? const {},
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
  final lower = source.toLowerCase();
  return lower.contains('lx.event.request') ||
      lower.contains('lx.event.on') ||
      lower.contains('globalthis.lx') ||
      // 压缩/混淆后的落雪插件通常写成 globalThis['lx']，不能只依赖
      // 点号形式，否则会被误判为 MusicFree 插件而无法加载。
      RegExp(r'''globalthis\s*\[\s*['"]lx['"]\s*\]''').hasMatch(lower) ||
      lower.contains('event_names.request') ||
      lower.contains('server_script_config');
}

List<String> _detectLxSources(String source) {
  const supported = ['kw', 'kg', 'tx', 'wy', 'mg'];
  final found = <String>[];
  for (final id in supported) {
    if (RegExp("(?:['\"])?$id(?:['\"])?\\s*[:=]").hasMatch(source) ||
        RegExp("['\"]$id['\"]").hasMatch(source)) {
      found.add(id);
    }
  }
  return found.isEmpty ? supported : found;
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
      () => File(plugin.path).readAsString(),
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
    final bootstrap = await (_runtimeBootstrapTask ??= rootBundle.loadString(
      'assets/plugin_runtime.js',
    ));
    final lxBootstrap = await rootBundle.loadString(
      'assets/lx_plugin_runtime.js',
    );
    final pluginSource = await _loadPluginSource(plugin);
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

  Future<List<PluginSearchSong>> search(
    EnabledMusicPlugin plugin,
    String keyword,
  ) async {
    if (plugin.isLx) return _searchLxPlugin(plugin, keyword);
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
    return list
        .map((raw) => _toSearchSong(plugin.id, _resetMediaItem(plugin, raw)))
        .toList();
  }

  /// 获取歌手详情中的歌曲，沿用桌面端的 getArtistWorks 逻辑。
  /// 插件未实现详情接口时才回退到按歌手名搜索。
  Future<List<PluginSearchSong>> getArtistSongs(
    EnabledMusicPlugin plugin,
    PluginCatalogResult artist,
  ) async {
    if (plugin.isLx) return _searchLxPlugin(plugin, artist.title);
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
      final list = pages;
      if (list.isNotEmpty) {
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
    PluginCatalogResult album,
  ) async {
    if (plugin.isLx) return _searchLxPlugin(plugin, album.title);
    try {
      final response = _runsPluginsInBackground
          ? await _runPluginOperation(plugin, 'getAlbumInfo', {
              'rawData': album.rawData,
              'page': 1,
            })
          : await _callOnCurrentIsolate(plugin, 'getAlbumInfo', [
              album.rawData,
              1,
            ]);
      final list = _extractResultList(response);
      if (list.isNotEmpty) {
        return list
            .map(
              (raw) => _toSearchSong(plugin.id, _resetMediaItem(plugin, raw)),
            )
            .toList();
      }
    } catch (_) {
      // 与桌面端一致：详情接口不可用时回退到普通歌曲搜索。
    }
    final results = await search(plugin, album.title);
    final target = album.title.trim().toLowerCase();
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
    String keyword,
  ) async {
    if (plugin.isLx) {
      final songs = await _searchLxPlugin(plugin, keyword);
      return _aggregateLxCatalog(
        plugin.id,
        songs,
        keyword: keyword,
        artist: true,
      );
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
    String keyword,
  ) async {
    if (plugin.isLx) {
      final songs = await _searchLxPlugin(plugin, keyword);
      return _aggregateLxCatalog(
        plugin.id,
        songs,
        keyword: keyword,
        artist: false,
      );
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
  }

  /// 获取某个热门榜单内的歌曲，用于推荐页混入不依赖个人喜好的
  /// 大众热门内容（类似 BakaMusic 推荐歌单的获取思路）。
  Future<List<PluginSearchSong>> getTopListSongs(
    EnabledMusicPlugin plugin,
    PluginCatalogResult chart, {
    int limit = 40,
  }) async {
    if (plugin.isLx) return const [];
    final songs = await _loadMusicFreePlaylistSongs(
      plugin,
      Map<String, dynamic>.from(chart.rawData),
      kind: 'top',
    );
    return songs
        .take(limit)
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
  ) => <String, dynamic>{...raw, 'platform': plugin.name};

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
    String keyword,
  ) async {
    final sources = plugin.lxSources.isEmpty
        ? const ['kw', 'kg', 'tx', 'wy', 'mg']
        : plugin.lxSources;
    final results = <PluginSearchSong>[];
    final seen = <String>{};
    Object? lastError;
    for (final source in sources) {
      try {
        final rawJson = await lxSearch(
          source: source,
          keyword: keyword,
          limit: 30,
        ).timeout(const Duration(seconds: 20));
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
      } catch (error) {
        lastError = error;
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

    // 与电脑版一致：输入的是歌单名称、ID 或链接，先让 MusicFree 插件搜索，
    // 这样能保留真实歌单名称、封面和插件自己的媒体字段。
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
        lastError = error;
      }
    }

    // 收藏夹/纯 ID 导入兼容路径，B 站、酷狗等插件常只实现此接口。
    try {
      final imported = await _callOnCurrentIsolate(plugin, 'importMusicSheet', [
        input,
      ]);
      final songs = _extractResultList(
        imported,
      ).map((song) => _resetMediaItem(plugin, song)).toList();
      if (songs.isNotEmpty) {
        return {
          'name': '${plugin.name}歌单',
          'coverUrl': _extractCover(songs.first),
          'songs': songs,
        };
      }
    } catch (error) {
      lastError = error;
    }

    // 电脑版的最后一层回退：部分插件不能搜索歌单，但提供排行榜列表。
    try {
      final response = await _callOnCurrentIsolate(plugin, 'getTopLists', []);
      final topLists = _extractTopListItems(response);
      if (topLists.isNotEmpty) {
        final sheet = _bestMatchingPlaylist(topLists, input);
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
    } catch (error) {
      lastError = error;
    }
    throw Exception(
      lastError == null ? '该插件不支持歌单导入' : _friendlyError(lastError.toString()),
    );
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
    final songs = <Map<String, dynamic>>[];
    final seen = <String>{};
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
      if (detail is Map && detail['isEnd'] == true) break;
      // MusicFree 通常每页 30 首；不足一页即视为结束。
      if (pageSongs.length < 30 || added == 0) break;
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

  static Map<String, dynamic> _bestMatchingPlaylist(
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
    final decoded = jsonDecode(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    );
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
      final decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
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
  }) async {
    Future<PluginMediaSource> resolve(String? quality) async {
      if (plugin.isLx) {
        return _resolveLxMediaSource(
          plugin,
          rawData,
          preferredQuality: quality,
        );
      }
      if (_runsPluginsInBackground) {
        final response = await _runPluginOperation(
          plugin,
          'resolveMediaSource',
          {'rawData': rawData, 'preferredQuality': quality},
        );
        final source = _toMediaSource(response);
        if (source == null) throw Exception('插件没有返回可播放地址');
        return source;
      }
      return _resolveMediaSourceOnCurrentIsolate(
        plugin,
        rawData,
        preferredQuality: quality,
      );
    }

    try {
      return await resolve(preferredQuality);
    } catch (error) {
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
    return future.then((qualities) {
      final preferred = preferredQuality?.trim() ?? '';
      // 探测结果可能只包含当前音质能够解析出的子集。始终保留歌曲
      // 元数据中声明的全部音质，避免用户切换音质后重新打开选择器时，
      // 未被本次探测返回的母带/Hi-Res 等选项被覆盖掉。
      final declared = _qualityTokensFromRaw(rawData);
      final merged = <String>{...declared, ...qualities};
      if (preferred.isNotEmpty) merged.add(preferred);
      return merged.isEmpty ? const ['320k'] : merged.toList();
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
  /// 不附加 B 站 Referer 请求头。
  Future<PluginVideoSource> resolveMvSource(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData, {
    String? videoQuality,
  }) async {
    if (plugin.isLx) throw Exception('LX 插件不支持 MV 播放');
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
    if (plugin.isLx) return _getLxLyrics(rawData);
    if (_runsPluginsInBackground) {
      final response = await _runPluginOperation(plugin, 'getLyrics', rawData);
      return response?.toString() ?? '';
    }
    return _getLyricsOnCurrentIsolate(plugin, rawData);
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
          if (lyrics.isNotEmpty) {
            if (_hasWordTiming(lyrics) || !_isNeteaseMusicPlugin(plugin)) {
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
      if (lyrics.isNotEmpty) {
        if (_hasWordTiming(lyrics) || !_isNeteaseMusicPlugin(plugin)) {
          return lyrics;
        }
        bestLyrics = lyrics;
      }
    } catch (_) {
      // getMusicInfo 同样属于可选能力。
    }

    final fallback = await _getPlatformLyricsFallback(plugin, rawData);
    return fallback.isNotEmpty ? fallback : bestLyrics;
  }

  Future<String> _resolveLyricsResponse(dynamic response) async {
    final lyrics = _extractLyrics(response);
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
        final nested = _extractLyrics(decoded);
        if (nested.isNotEmpty) return nested;
      } catch (_) {
        // 纯 LRC 文本不是 JSON，直接返回正文。
      }
      return body.trim();
    } catch (_) {
      return '';
    }
  }

  Future<String> _getPlatformLyricsFallback(
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData,
  ) async {
    if (!_isNeteaseMusicPlugin(plugin)) return '';
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
      return _extractLyrics(decoded);
    } catch (_) {
      return '';
    }
  }

  Future<http.Response> _rawGet(Uri uri, {Map<String, String>? headers}) async {
    final injectedClient = httpClient;
    final canUseInjected =
        injectedClient != null &&
        injectedClient is! _PluginBackgroundHttpClient &&
        injectedClient is! _PluginProxyHttpClient;
    final http.Client client = canUseInjected ? injectedClient : http.Client();
    try {
      return await client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 20));
    } finally {
      if (!canUseInjected) client.close();
    }
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
      lyrics: _extractLyrics(value),
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
    return PluginVideoSource(
      url: url,
      backupUrls: backups,
      headers: headers,
      mimeType: value['mimeType']?.toString().trim().isNotEmpty == true
          ? value['mimeType'].toString().trim()
          : 'video/mp4',
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
    return PluginVideoSource(
      url: direct,
      backupUrls: backups,
      headers: headers,
      mimeType: selected?['mimeType']?.toString().trim().isNotEmpty == true
          ? selected!['mimeType'].toString().trim()
          : 'video/mp4',
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
    return allowed.contains(parsed) ? parsed : 64;
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

  static String _normalizeImageUrl(String value) {
    var normalized = value.trim();
    if (normalized.startsWith('//')) normalized = 'https:$normalized';
    final uri = Uri.tryParse(normalized);
    final host = uri?.host.toLowerCase() ?? '';
    if (normalized.startsWith('http://') &&
        (host == 'music.126.net' || host.endsWith('.music.126.net'))) {
      normalized = 'https://${normalized.substring(7)}';
    }
    return _isHttpUrl(normalized) ? normalized : '';
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
    );
  }

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
        return value > 1000 ? value.floor() : (value * 1000).floor();
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
        return number > 1000 ? number.floor() : (number * 1000).floor();
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
    return 'https://p1.music.126.net/$encrypted/$picId.jpg';
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

  void dispose() {
    _disposeRequested = true;
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
    dynamic data;
    switch (request['operation']) {
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
        };
        break;
      case 'getLyrics':
        if (payload is! Map) throw Exception('歌曲信息格式无效');
        data = await service._getLyricsOnCurrentIsolate(
          plugin,
          Map<String, dynamic>.from(payload),
        );
        break;
      case 'importPlaylist':
        data = await service._importPlaylistOnCurrentIsolate(
          plugin,
          payload?.toString().trim() ?? '',
        );
        break;
      default:
        throw Exception('不支持的插件后台操作：${request['operation']}');
    }
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
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 20));
    final bytes = await response.stream.toBytes();
    final body = utf8.decode(bytes, allowMalformed: true);
    return http.StreamedResponse(
      Stream.value(utf8.encode(encodePluginHttpBody(body))),
      response.statusCode,
      contentLength: null,
      request: request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _client.close();
}

class _PluginProxyHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bodyBytes = await request.finalize().toBytes();
    String responseJson;
    try {
      responseJson = await pluginHttpRequest(
        method: request.method,
        url: request.url.toString(),
        headersJson: jsonEncode(request.headers),
        body: bodyBytes.isEmpty
            ? null
            : utf8.decode(bodyBytes, allowMalformed: true),
        timeout: BigInt.from(20),
        follow: 10,
      );
    } catch (error) {
      // QuickJS XHR expects an HTTP response even when the native request
      // cannot connect. Returning a synthetic 599 response lets the plugin
      // reject the current operation normally instead of creating an
      // unhandled isolate error that replaces the whole app screen.
      final body = jsonEncode({'code': 599, 'message': error.toString()});
      return http.StreamedResponse(
        Stream.value(utf8.encode(encodePluginHttpBody(body))),
        599,
        headers: const {'content-type': 'application/json'},
        request: request,
        reasonPhrase: 'Plugin network request failed',
      );
    }
    final response = jsonDecode(responseJson) as Map<String, dynamic>;
    final responseBody = response['body']?.toString() ?? '';
    final headers = <String, String>{};
    final rawHeaders = response['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers[entry.key.toString()] = entry.value.toString();
      }
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode(encodePluginHttpBody(responseBody))),
      (response['status'] as num?)?.toInt() ?? 500,
      headers: headers,
      request: request,
    );
  }
}

/// QuickJS 0.1.3 会把 XHR 正文插入模板字符串，正文中的反斜杠、换行等
/// 可能在 JSON.parse 前被二次解释。使用纯 ASCII Base64 作为桥接传输格式。
String encodePluginHttpBody(String body) =>
    '__XY_HTTP_BODY_BASE64__${base64Encode(utf8.encode(body))}';
