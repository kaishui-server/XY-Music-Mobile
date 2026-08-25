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
  });

  final String id;
  final String name;
  final String path;
  final bool isLx;
  final List<String> lxSources;
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

Future<List<EnabledMusicPlugin>> loadEnabledMusicPlugins(Ref ref) async {
  const enabledKey = 'mobileEnabledPlugins';
  final dataDir = await ref.read(appDataDirProvider.future);
  final directory = Directory(p.join(dataDir, 'plugins'));
  if (!directory.existsSync()) return const [];
  final prefs = await SharedPreferences.getInstance();
  final enabled = (prefs.getStringList(enabledKey) ?? const []).toSet();
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
      ),
    );
  }
  plugins.sort((a, b) => a.name.compareTo(b.name));
  return plugins;
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
    this.pluginSources = const {},
  });

  final http.BaseClient? httpClient;
  final String? runtimeBootstrap;
  final Map<String, String> pluginSources;
  JavascriptRuntime? _runtime;
  Future<void>? _initializing;
  int _activeRuntimeOperations = 0;
  bool _disposeRequested = false;
  Future<String>? _runtimeBootstrapTask;
  final Set<String> _loaded = {};
  final Map<String, Future<void>> _loadTasks = {};
  final Map<String, Future<String>> _pluginSourceTasks = {};
  final Map<String, _NeteaseTrackMeta> _neteaseTrackMetaCache = {};

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
              '${jsonEncode(plugin.id)},${jsonEncode(source)},"{}")';
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
    final pluginSource = await _loadPluginSource(plugin);
    final request = <String, String>{
      'operation': operation,
      'pluginId': plugin.id,
      'pluginName': plugin.name,
      'pluginPath': plugin.path,
      'pluginSource': pluginSource,
      'bootstrap': bootstrap,
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
      final response = _runsPluginsInBackground
          ? await _runPluginOperation(plugin, 'getArtistWorks', {
              'rawData': artist.rawData,
              'page': 1,
              'type': 'music',
            })
          : await _callOnCurrentIsolate(plugin, 'getArtistWorks', [
              artist.rawData,
              1,
              'music',
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
    // Bilibili 的“歌手”实际上是 UP 主。不同版本的 B 站插件有的沿用
    // MusicFree 的 artist 类型，有的则使用 user 类型；先走桌面端的
    // artist 流程，返回空时再兼容 user，避免把 B 站用户误当成歌曲歌手。
    List<Map<String, dynamic>> list;
    Object? artistError;
    try {
      list = await _searchMusicFreeType(plugin, keyword, 'artist');
    } catch (error) {
      artistError = error;
      list = const [];
    }
    if (list.isEmpty && _isBilibiliPlugin(plugin)) {
      try {
        list = await _searchMusicFreeType(plugin, keyword, 'user');
      } catch (error) {
        if (artistError != null) rethrow;
      }
    }
    if (list.isEmpty && artistError != null) {
      throw artistError;
    }
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
    if (plugin.isLx) {
      return _resolveLxMediaSource(rawData, preferredQuality: preferredQuality);
    }
    if (_runsPluginsInBackground) {
      final response = await _runPluginOperation(plugin, 'resolveMediaSource', {
        'rawData': rawData,
        'preferredQuality': preferredQuality,
      });
      final source = _toMediaSource(response);
      if (source == null) throw Exception('插件没有返回可播放地址');
      return source;
    }
    return _resolveMediaSourceOnCurrentIsolate(
      plugin,
      rawData,
      preferredQuality: preferredQuality,
    );
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
    Map<String, dynamic> rawData, {
    String? preferredQuality,
  }) async {
    final value = rawData['lx'];
    if (value is! Map) throw Exception('LX 歌曲缺少音源元数据');
    final songInfo = Map<String, dynamic>.from(value);
    Object? lastError;
    for (final quality in pluginQualityCandidates(preferredQuality)) {
      try {
        final response = await lxResolveUrl(
          songInfoJson: jsonEncode(songInfo),
          quality: quality,
        ).timeout(const Duration(seconds: 15));
        final decoded = jsonDecode(response);
        final url = decoded is Map
            ? decoded['url']?.toString().trim() ?? ''
            : '';
        if (url.isNotEmpty) return PluginMediaSource(url: url);
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
      return PluginMediaSource(url: value);
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
      url: url,
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
      if (_isHttpUrl(value)) return PluginMediaSource(url: value);
    }
    final qualities = raw['qualities'];
    if (qualities is Map) {
      for (final value in qualities.values) {
        if (value is Map) {
          final url = value['url']?.toString().trim() ?? '';
          if (_isHttpUrl(url)) return PluginMediaSource(url: url);
        }
      }
    }
    return null;
  }

  static bool _isHttpUrl(String value) =>
      value.startsWith('https://') || value.startsWith('http://');

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
    _pluginSourceTasks.clear();
    _neteaseTrackMetaCache.clear();
  }
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

Future<String> _executePluginOperationInBackground(
  Map<String, String> request,
) async {
  final client = _PluginBackgroundHttpClient();
  final service = PluginRuntimeService(
    httpClient: client,
    runtimeBootstrap: request['bootstrap'],
    pluginSources: {request['pluginId'] ?? '': request['pluginSource'] ?? ''},
  );
  try {
    final plugin = EnabledMusicPlugin(
      id: request['pluginId'] ?? '',
      name: request['pluginName'] ?? '',
      path: request['pluginPath'] ?? '',
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
    final responseJson = await pluginHttpRequest(
      method: request.method,
      url: request.url.toString(),
      headersJson: jsonEncode(request.headers),
      body: bodyBytes.isEmpty
          ? null
          : utf8.decode(bodyBytes, allowMalformed: true),
      timeout: BigInt.from(20),
      follow: 10,
    );
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
