import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/custom_font.dart';
import '../core/db_path.dart';
import '../plugins/plugin_metadata.dart';
import '../plugins/plugin_reference_migration.dart';
import '../plugins/plugin_runtime.dart' show EnabledMusicPlugin;
import '../playlists/musicfree_backup_import.dart'
    show musicFreePlatformLabel, rebuildOnlineSongFromGenericEntry;
import '../rust/api.dart' as rust;

/// 备份/恢复失败时抛出的异常，[message] 直接展示给用户。
class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 外观自定义文件条目：[name] 为 appearance 目录内的文件名，
/// [base64] 为文件内容（导入时写回 appearance 目录）。
class BackupAppearanceFile {
  const BackupAppearanceFile({required this.name, required this.base64});

  final String name;
  final String base64;

  Map<String, Object> toJson() => {'name': name, 'base64': base64};
}

/// 备份中的外观自定义文件（v3 起）：全局壁纸、播放详情页背景、
/// 自定义字体。任一项缺失时对应字段为 null。
class BackupAppearance {
  const BackupAppearance({this.background, this.playerDetail, this.font});

  final BackupAppearanceFile? background;
  final BackupAppearanceFile? playerDetail;
  final BackupAppearanceFile? font;

  bool get isEmpty =>
      background == null && playerDetail == null && font == null;

  Map<String, Object> toJson() {
    final map = <String, Object>{};
    final bg = background;
    if (bg != null) map['background'] = bg.toJson();
    final detail = playerDetail;
    if (detail != null) map['playerDetail'] = detail.toJson();
    final customFont = font;
    if (customFont != null) map['font'] = customFont.toJson();
    return map;
  }
}

/// 解析并校验通过的一份备份数据（尚未写入本地）。
class BackupData {
  const BackupData({
    required this.exportedAt,
    required this.prefs,
    required this.plugins,
    this.library = const {},
    this.appearance = const BackupAppearance(),
    this.sheetCount = 0,
    this.songCount = 0,
  });

  /// 导出时间（ISO 8601 字符串，可能为空——仅用于展示）。
  final String exportedAt;

  /// {key: {'t': 's|b|i|d|sl', 'v': ...}}，全部条目均已校验合法。
  /// v5 备份的音乐列表在读取时已转换回内部偏好结构（favoritePaths /
  /// favoriteSongMetadataV1 / mobilePlaylistsV1）。
  final Map<String, Map<String, Object>> prefs;

  /// {插件 id: js 脚本全文}。
  final Map<String, String> plugins;

  /// 曲库表数据（Rust 导出的 {"表名": {columns, rows}} 结构；v1 备份为空）。
  final Map<String, dynamic> library;

  /// 外观自定义文件（v3 起）；v1/v2 备份为空。
  final BackupAppearance appearance;

  /// v5 备份中的歌单/收藏数（含 favorite 收藏表；旧格式为 0）。
  final int sheetCount;

  /// v5 备份中全部歌单/收藏的歌曲总数（旧格式为 0）。
  final int songCount;

  int get prefCount => prefs.length;

  int get pluginCount => plugins.length;

  /// 备份中的本地曲库歌曲数（songs 表行数，仅用于展示）。
  int get librarySongCount {
    final songs = library['songs'];
    if (songs is! Map) return 0;
    final rows = songs['rows'];
    return rows is List ? rows.length : 0;
  }
}

/// 备份导出内容勾选项：仅收藏 / 歌单 / 插件 / 设置四类，
/// 最近播放、听歌统计、下载记录等其余本地数据一律不进备份。
class BackupExportOptions {
  const BackupExportOptions({
    this.favorites = true,
    this.playlists = true,
    this.plugins = true,
    this.settings = true,
  });

  final bool favorites;
  final bool playlists;
  final bool plugins;
  final bool settings;

  bool get isEmpty => !favorites && !playlists && !plugins && !settings;
}

/// 导入完成后的统计。
class BackupImportResult {
  const BackupImportResult({
    required this.prefCount,
    required this.pluginCount,
  });

  final int prefCount;
  final int pluginCount;
}

/// 本地备份：按勾选项把收藏、歌单、插件（含用户变量）与设置导出为
/// 单个 JSON 文件，导入时整体写回。v5 起导出格式仿 MusicFree 备份的
/// 结构风格（schema/version/createdAt + data{musicSheets, plugins,
/// settings}），歌单与收藏以人可读的音乐列表（歌名/歌手/专辑/平台/
/// 音质快照）呈现；导入时转换回内部偏好结构后走既有恢复链路。
/// 设置项 key 无统一前缀且会持续新增，因此「设置」采用全量导出
/// （黑名单排除设备标识与播放类数据），保证未来新增设置自动被备份。
/// 最近播放、听歌统计、下载记录等其余本地数据不进备份（导入旧版
/// 备份时也会忽略）。读取时兼容 v1–v4 旧格式。
class BackupService {
  const BackupService();

  // 插件偏好存储键（与 plugins_page / plugin_runtime 保持一致）：
  // 归一化插件 ID 时需要迁移这些偏好。
  static const _enabledPluginsKey = 'mobileEnabledPlugins';
  static const _sourceUrlsKey = 'mobilePluginSourceUrlsV1';
  static const _pluginOrderKey = 'mobilePluginOrder';
  static const _pluginUserVariablesKey = 'mobilePluginUserVariablesV1';

  /// 「收藏」类偏好键（与 favorites_provider 保持一致）。
  static const _favoriteKeys = <String>{
    'favoritePaths',
    'favoriteSongMetadataV1',
    'favoriteCustomOrderV1',
  };

  /// 「歌单」类偏好键（与 playlists_provider 保持一致）。
  static const _playlistKeys = <String>{'mobilePlaylistsV1'};

  /// 「插件」类偏好键。
  static const _pluginKeys = <String>{
    _enabledPluginsKey,
    _sourceUrlsKey,
    _pluginOrderKey,
    _pluginUserVariablesKey,
  };

  /// v5 备份里随「插件」勾选导出的插件状态键（订阅来源在 plugins
  /// 数组元素的 srcUrl 字段中，不在此列）。
  static const _pluginStateKeys = <String>{
    _enabledPluginsKey,
    _pluginOrderKey,
    _pluginUserVariablesKey,
  };

  /// 旧格式（v1–v4）的 format 标识；新版备份改用 [schemaId]。
  static const formatId = 'xymusic-backup';

  /// 新格式（v5 起）的 schema 标识，仿 MusicFree 备份的头部风格。
  static const schemaId = 'xymusic.backup';

  // v2：新增内嵌本地曲库表（songs/library_folders/artists 等），本地收藏与
  // 歌单歌曲依赖这些缓存才能恢复显示。读取时兼容 v1（无曲库字段）。
  // v3：新增外观自定义文件（全局壁纸、播放详情页背景、自定义字体），
  // 导入时写回 appearance 目录并修正设置中的绝对路径。读取时兼容 v1/v2。
  // v4：曲库表导出范围扩展到播放历史与听歌统计（play_history/
  // song_stats 等）。当前版本导出/导入均已收窄为仅曲库元数据缓存表
  //（收藏/歌单恢复显示所需），播放历史与统计表不再迁移；读取仍兼容
  // v1–v4（旧备份中的统计表会被直接忽略）。
  // v5：导出格式整体重写为仿 MusicFree 的结构（schema/version/
  // createdAt + data{musicSheets, plugins, pluginState, settings,
  // appearance, library}），收藏与歌单以人可读的音乐列表呈现；
  // 读取时转换回内部偏好结构，兼容 v1–v4 旧格式。
  static const int version = 5;

  /// 不随备份迁移的键：deviceId 是本机设备标识，不应在新设备复用；
  /// downloadHistoryV1 是本机下载记录，指向的文件不会随备份迁移，
  /// 恢复到新设备只会留下断链记录；recentSongMetadataV1 是最近播放
  /// 网络歌曲快照，与播放历史同属「不迁移」的数据。导出时排除，
  /// 导入时也忽略（v4 之前的旧备份可能包含这些键，跳过即可）。
  static const _excludedKeys = <String>{
    'deviceId',
    'downloadHistoryV1',
    'recentSongMetadataV1',
  };

  /// 随备份迁移的曲库元数据缓存表（Rust 导出结果中仅保留这些）：
  /// 本地收藏与歌单歌曲恢复显示依赖 songs 等缓存。播放历史与统计表
  ///（play_history/recent_plays/song_stats/global_stats/daily_stats 等）
  /// 不迁移。
  static const _libraryCacheTables = <String>{
    'songs',
    'library_folders',
    'artists',
    'song_artists',
    'song_backgrounds',
    'sidebar_folders',
  };

  /// 外观文件大小上限（与设置页选择文件时的限制一致）：
  /// 图片 20MB、字体 100MB，超限的文件不进备份。
  static const int _maxImageBytes = 20 * 1024 * 1024;
  static const int _maxFontBytes = 100 * 1024 * 1024;

  /// 该 prefs 键是否属于 v5 备份的「设置」段：收藏/歌单/插件类键
  /// 各有归属（musicSheets / plugins / pluginState），不重复进设置；
  /// 无法归类的键一律视为「设置」。
  bool _isSettingsKey(String key) =>
      !_excludedKeys.contains(key) &&
      !_favoriteKeys.contains(key) &&
      !_playlistKeys.contains(key) &&
      !_pluginKeys.contains(key);

  /// 按勾选项导出本地数据为 v5 备份（仿 MusicFree 结构），弹系统
  /// 保存对话框由用户选择保存位置。返回保存路径；用户取消时返回
  /// null。勾选了某类数据时对应 data 字段必定出现（哪怕为空），
  /// 导入端据此区分「未勾选（不动本机数据）」与「勾选但为空（清空
  /// 恢复）」。
  Future<String?> exportBackup({
    BackupExportOptions options = const BackupExportOptions(),
  }) async {
    final prefs = await SharedPreferences.getInstance();
    // 曲库元数据缓存表仅服务收藏/歌单恢复；音乐列表里本地歌的
    // 标题/歌手等元数据也从 songs 表补全。
    final library = options.favorites || options.playlists
        ? await _exportLibrary()
        : const <String, dynamic>{};
    final songsIndex = _buildSongsIndex(library);

    final data = <String, Object>{};
    // 勾选项清单：导入端据此区分「未勾选（不动本机数据）」与
    // 「勾选但为空（清空恢复）」——空收藏/零歌单在 musicSheets 里
    // 没有对应表，只能靠这个标记识别。
    data['exportedSections'] = <String>[
      if (options.favorites) 'favorites',
      if (options.playlists) 'playlists',
      if (options.plugins) 'plugins',
      if (options.settings) 'settings',
    ];
    if (options.favorites || options.playlists) {
      final sheets = <Map<String, Object?>>[];
      if (options.favorites) {
        sheets.add(_buildFavoriteSheet(prefs, songsIndex));
      }
      if (options.playlists) {
        sheets.addAll(_buildPlaylistSheets(prefs, songsIndex));
      }
      data['musicSheets'] = sheets;
      if (library.isNotEmpty) data['library'] = library;
    }
    if (options.plugins) {
      data['plugins'] = await _buildPluginEntries(prefs);
      final pluginState = <String, Map<String, Object>>{};
      for (final key in _pluginStateKeys) {
        final entry = _encodeValue(prefs.get(key));
        if (entry != null) pluginState[key] = entry;
      }
      data['pluginState'] = pluginState;
    }
    if (options.settings) {
      final settings = <String, Map<String, Object>>{};
      for (final key in prefs.getKeys()) {
        if (!_isSettingsKey(key)) continue;
        final entry = _encodeValue(prefs.get(key));
        if (entry != null) settings[key] = entry;
      }
      data['settings'] = settings;
      // 外观自定义文件（壁纸/字体）归入「设置」类。
      final appearance = await _exportAppearance(prefs);
      if (!appearance.isEmpty) data['appearance'] = appearance.toJson();
    }

    final payload = <String, Object>{
      'schema': schemaId,
      'version': version,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'data': data,
    };
    final text = const JsonEncoder.withIndent('  ').convert(payload);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final fileName =
        'xy_music_backup_${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.json';
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出备份',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['json'],
      bytes: utf8.encode(text),
    );
    return (path == null || path.isEmpty) ? null : path;
  }

  /// 把曲库 songs 表（columns + rows）转成 {path: 行 Map} 索引，
  /// 供音乐列表给本地歌曲补全标题/歌手/专辑/时长/格式。结构不符
  /// 或没有 path 列时返回空表（本地歌退化为仅带路径）。
  Map<String, Map<String, Object>> _buildSongsIndex(
    Map<String, dynamic> library,
  ) {
    final songs = library['songs'];
    if (songs is! Map) return const {};
    final columns = songs['columns'];
    final rows = songs['rows'];
    if (columns is! List || rows is! List) return const {};
    final colIndex = <String, int>{};
    for (var i = 0; i < columns.length; i++) {
      colIndex[columns[i].toString()] = i;
    }
    final pathIdx = colIndex['path'];
    if (pathIdx == null) return const {};
    final index = <String, Map<String, Object>>{};
    for (final row in rows) {
      if (row is! List || pathIdx >= row.length) continue;
      final path = row[pathIdx];
      if (path is! String || path.isEmpty) continue;
      index[path] = {
        for (final entry in colIndex.entries)
          if (entry.value < row.length) entry.key: row[entry.value],
      };
    }
    return index;
  }

  /// 收藏表（id 固定为 favorite，与 MusicFree 的「我喜欢」一致）。
  Map<String, Object?> _buildFavoriteSheet(
    SharedPreferences prefs,
    Map<String, Map<String, Object>> songsIndex,
  ) {
    final paths = prefs.getStringList('favoritePaths') ?? const <String>[];
    final meta = _decodeJsonMap(prefs.getString('favoriteSongMetadataV1'));
    final musicList = <Map<String, Object?>>[];
    for (final path in paths) {
      final entry = _sheetEntry(
        path: path,
        favorite: meta[path],
        song: songsIndex[path],
      );
      if (entry != null) musicList.add(entry);
    }
    return {
      'id': 'favorite',
      'platform': '本地',
      'title': '我的收藏',
      'coverImg': null,
      'worksNum': musicList.length,
      'customOrder': prefs.getStringList('favoriteCustomOrderV1'),
      'musicList': musicList,
    };
  }

  /// 各歌单曲（每张歌单一个 musicSheet，字段名对齐 MobilePlaylist）。
  List<Map<String, Object?>> _buildPlaylistSheets(
    SharedPreferences prefs,
    Map<String, Map<String, Object>> songsIndex,
  ) {
    final raw = prefs.getString('mobilePlaylistsV1');
    if (raw == null || raw.isEmpty) return const [];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];
    final sheets = <Map<String, Object?>>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final songPaths =
          (item['songPaths'] as List?)?.whereType<String>().toList() ??
          const <String>[];
      final snapshots = item['songSnapshots'] is Map
          ? item['songSnapshots'] as Map
          : const {};
      final musicList = <Map<String, Object?>>[];
      for (final path in songPaths) {
        final entry = _sheetEntry(
          path: path,
          playlistSnapshot: snapshots[path],
          song: songsIndex[path],
        );
        if (entry != null) musicList.add(entry);
      }
      sheets.add({
        'id': item['id']?.toString() ?? '',
        'platform': '本地',
        'title': item['name']?.toString() ?? '未命名歌单',
        'coverImg': item['coverUrl'],
        'worksNum': musicList.length,
        'customOrder': item['customOrder'],
        'musicList': musicList,
      });
    }
    return sheets;
  }

  /// 单首歌曲的音乐条目：MusicFree 风格的展示字段（id/title/artist/
  /// album/duration/artwork/platform）+ 互转辅助字段（source/qualityList，
  /// 供外部格式转换工具直接识别，不参与 XY 自身恢复链路）+ XY 恢复
  /// 必需的字段（path/pluginId/format/qualities/extra）。优先用在线
  /// 歌曲快照（字段最全），其次曲库行（本地歌），标题兜底为文件名。
  Map<String, Object?>? _sheetEntry({
    required String path,
    Map? favorite,
    Map? playlistSnapshot,
    Map? song,
  }) {
    if (path.isEmpty) return null;
    final snap = playlistSnapshot;
    final title =
        _str(snap?['title'] ?? favorite?['title'] ?? song?['title']) ??
        _fallbackTitle(path);
    final pluginId = _str(snap?['pluginId'] ?? favorite?['pluginId']);
    final format =
        _str(favorite?['format'] ?? song?['format']) ??
        (pluginId != null ? '网络' : '');
    final extra = snap?['extra'] ?? favorite?['pluginData'];
    final extraMap = extra is Map ? extra : null;
    final lxMap = extraMap?['lx'];
    final lxSourceCode = lxMap is Map ? _str(lxMap['source']) : null;
    // 平台内歌曲 id：歌单快照自带 songId；收藏快照没有，从 path
    // （plugin://<pluginId>/<songId>）提取——没有它转换工具无法在
    // 目标格式里定位在线歌曲。
    final songId =
        _str(snap?['songId']) ??
        (pluginId != null ? songIdFromPluginPath(path) : null);
    // 音质表：歌单快照自带；收藏快照没有，从插件原始数据（extra）
    // 的 qualities 挖掘（MusicFree 系插件的原始返回都带）。
    final qualities = snap?['qualities'] is Map
        ? snap!['qualities'] as Map
        : (extraMap?['qualities'] is Map ? extraMap!['qualities'] as Map : null);
    final sourceCode = pluginId != null ? canonicalSource(pluginId) : 'local';
    // 展示平台名（MusicFree/BakaMusic 转换后靠它匹配音源拉歌词与
    // 播放地址）：MusicFree 系用插件原始值（extra.platform），洛雪
    // 与未知源按标准平台码映射中文名。
    final extraPlatform = _str(extraMap?['platform']);
    final platform = extraPlatform != null && extraPlatform.isNotEmpty
        ? extraPlatform
        : musicFreePlatformLabel(lxSourceCode ?? sourceCode);
    return {
      'id': songId ?? '',
      // 标准平台码（对齐洛雪命名：wy/tx/kw/kg/mg/bilibili，本地 local，
      // 未知源保留归一化插件名）——转换工具查表即知平台归属。
      'source': sourceCode,
      'title': title,
      'artist': _str(snap?['artist'] ?? favorite?['artist'] ?? song?['artist']) ?? '',
      'album': _str(snap?['album'] ?? favorite?['album'] ?? song?['album']) ?? '',
      // 专辑 id（洛雪 meta 与 MusicFree albumId 字段需要）。
      'albumId': _str(
        extraMap?['albumId'] ??
            extraMap?['album_id'] ??
            (lxMap is Map ? lxMap['albumId'] : null),
      ),
      'duration':
          _int(snap?['duration'] ?? favorite?['duration'] ?? song?['duration']) ?? 0,
      'artwork': _str(snap?['coverUrl'] ?? favorite?['coverUrl']),
      'platform': platform,
      // 可用音质标签（URL 会过期，互转只需要知道有哪些音质）。
      'qualityList': [
        for (final key in qualities?.keys ?? const [])
          key.toString(),
      ],
      // XY 特有：恢复链路的核心字段。
      'path': path,
      'pluginId': pluginId,
      'format': format,
      'qualities': qualities,
      'extra': extra is Map ? extra : null,
    };
  }

  /// 任意平台标识（插件 id/中文名/英文平台名）→ 标准平台码。
  /// 与洛雪的源代码命名对齐（wy/tx/kw/kg/mg/bilibili），未知源返回
  /// 去掉「音乐/音源/插件」等后缀的归一化名（保留自定义源可读性）。
  /// 与 musicfree_backup_import 的 _canonical 同款规则；公开静态供
  /// 备份互转逻辑与测试直接使用。
  static String canonicalSource(String value) {
    final normalized = value.toLowerCase().replaceAll(
      RegExp(r'[\s_.\-—/\\()[\]（）【】·]+'),
      '',
    );
    if (normalized.contains('netease') || normalized.contains('网易')) {
      return 'wy';
    }
    if (normalized.contains('qq') || normalized.contains('腾讯')) return 'tx';
    if (normalized.contains('kuwo') || normalized.contains('酷我')) return 'kw';
    if (normalized.contains('kugou') || normalized.contains('酷狗')) return 'kg';
    if (normalized.contains('migu') || normalized.contains('咪咕')) return 'mg';
    if (normalized.contains('bilibili') || normalized.contains('哔哩')) {
      return 'bilibili';
    }
    final fallback = normalized.replaceAll(
      RegExp(r'(音乐|music|音源|source|插件|plugin)$'),
      '',
    );
    return fallback.isEmpty ? normalized : fallback;
  }

  /// 从插件歌曲路径（`plugin://<pluginId>/<songId>`）提取平台歌曲 id；
  /// 歌曲 id 本身可含斜杠（B 站 BV 号等），因此取第一个斜杠之后的
  /// 全部内容。非插件路径返回 null。
  static String? songIdFromPluginPath(String path) {
    if (!path.startsWith('plugin://')) return null;
    final rest = path.substring('plugin://'.length);
    final slash = rest.indexOf('/');
    if (slash <= 0 || slash >= rest.length - 1) return null;
    return rest.substring(slash + 1);
  }

  /// 插件数组：每个元素含订阅来源地址（srcUrl，仿 MusicFree）、从
  /// 脚本头尽力解析的版本号，以及脚本全文（本地导入的插件没有
  /// srcUrl，靠 script 才能离线恢复）。
  Future<List<Map<String, Object?>>> _buildPluginEntries(
    SharedPreferences prefs,
  ) async {
    final sources = await _readPluginSources();
    final sourceUrls = _decodeJsonMap(prefs.getString(_sourceUrlsKey));
    return [
      for (final entry in sources.entries)
        {
          'id': entry.key,
          'srcUrl': sourceUrls[entry.key]?.toString() ?? '',
          'version': _parseScriptVersion(entry.value) ?? '',
          'script': entry.value,
        },
    ];
  }

  /// 从插件脚本头部尽力解析版本号（"version": "x.y.z" 或 @version
  /// 注释）；解析不到返回 null（仅用于备份展示，不影响恢复）。
  /// 引号用 \x22/\x27 表示，避免 raw string 与内嵌引号冲突。
  String? _parseScriptVersion(String script) {
    final head = script.length > 2048 ? script.substring(0, 2048) : script;
    final match = RegExp(
      r'[\x22\x27]version[\x22\x27]\s*[:=]\s*[\x22\x27]([^\x22\x27]+)[\x22\x27]',
    ).firstMatch(head);
    if (match != null) return match.group(1);
    final comment = RegExp(r'@version\s+([0-9A-Za-z.\-]+)').firstMatch(head);
    return comment?.group(1);
  }

  /// 解析 prefs 里存成 JSON 字符串的 Map（收藏快照/订阅来源表等）；
  /// 损坏时返回空表。
  Map<String, Map> _decodeJsonMap(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          entry.key.toString(): entry.value is Map ? entry.value as Map : const {},
      };
    } catch (_) {
      return const {};
    }
  }

  String? _str(Object? value) => value is String && value.isNotEmpty
      ? value
      : null;

  int? _int(Object? value) => value is num ? value.toInt() : null;

  /// 本地歌无任何元数据时的标题兜底：取文件名（去掉扩展名）。
  String _fallbackTitle(String path) {
    final name = p.basename(path);
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 读取并校验备份文件（不写入任何数据）。
  /// 文件损坏、格式或版本不识别时抛 [BackupException]。
  ///
  /// [enabledPlugins]：当前已启用插件列表——v5 备份里无 XY 私有 path
  /// 的网络条目（外部格式转换工具产出）按平台匹配插件重建，缺插件时
  /// 跳过。
  Future<BackupData> readBackup(
    String filePath, {
    List<EnabledMusicPlugin> enabledPlugins = const [],
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw const BackupException('备份文件不存在');
    }
    final Object decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FormatException {
      throw const BackupException('文件损坏或不是有效的备份文件');
    } on FileSystemException {
      throw const BackupException('备份文件读取失败');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const BackupException('文件损坏或不是有效的备份文件');
    }
    // v5 起（仿 MusicFree 结构）按 schema 识别；v1–v4 旧格式按 format。
    if (decoded['schema'] == schemaId) {
      return _readV5Backup(decoded, enabledPlugins);
    }
    if (decoded['format'] != formatId) {
      throw const BackupException('这不是 XY Music 的备份文件');
    }
    final fileVersion = decoded['version'];
    if (fileVersion is! int || fileVersion < 1) {
      throw const BackupException('备份文件版本无法识别');
    }
    if (fileVersion > version) {
      throw const BackupException('备份来自更新版本的应用，请先升级后再导入');
    }

    // prefs：整体校验通过后才返回，调用方确认后才写入。
    final rawPrefs = decoded['prefs'];
    if (rawPrefs is! Map) {
      throw const BackupException('备份文件缺少设置数据');
    }
    final prefs = <String, Map<String, Object>>{};
    for (final entry in rawPrefs.entries) {
      final key = entry.key.toString();
      // 旧版本备份里可能带有下载记录等不该迁移的键，导入时直接忽略。
      if (_excludedKeys.contains(key)) continue;
      final value = entry.value;
      if (value is! Map) continue;
      final t = value['t'];
      final v = value['v'];
      if (t is! String) continue;
      if (!_valueMatchesType(v, t)) continue;
      prefs[key] = {'t': t, 'v': v as Object};
    }

    // plugins：插件 id 必须是安全文件名，防止路径穿越。
    final rawPlugins = decoded['plugins'];
    final plugins = <String, String>{};
    if (rawPlugins is Map) {
      for (final entry in rawPlugins.entries) {
        final id = entry.key.toString();
        final source = entry.value;
        if (source is! String || source.isEmpty) continue;
        if (!_isSafePluginId(id)) continue;
        plugins[id] = source;
      }
    }

    // library：v2 起内嵌的曲库表数据（v1 备份没有该字段，跳过曲库恢复）。
    // 仅接受元数据缓存表；旧版备份里的播放历史/统计表直接忽略。
    final library = <String, dynamic>{};
    final rawLibrary = decoded['library'];
    if (rawLibrary is Map) {
      for (final entry in rawLibrary.entries) {
        if (entry.value is Map &&
            _libraryCacheTables.contains(entry.key.toString())) {
          library[entry.key.toString()] = entry.value;
        }
      }
    }

    // appearance：v3 起内嵌的外观自定义文件（v1/v2 备份没有该字段）。
    // 文件名不安全、base64 损坏或超限的条目在解析时直接跳过。
    final rawAppearance = decoded['appearance'];
    var appearance = const BackupAppearance();
    if (rawAppearance is Map) {
      appearance = BackupAppearance(
        background: _decodeAppearanceEntry(
          rawAppearance['background'],
          maxBytes: _maxImageBytes,
        ),
        playerDetail: _decodeAppearanceEntry(
          rawAppearance['playerDetail'],
          maxBytes: _maxImageBytes,
        ),
        font: _decodeAppearanceEntry(
          rawAppearance['font'],
          maxBytes: _maxFontBytes,
        ),
      );
    }
    return BackupData(
      exportedAt: decoded['exportedAt']?.toString() ?? '',
      prefs: prefs,
      plugins: plugins,
      library: library,
      appearance: appearance,
    );
  }

  /// v5 备份的歌单 id 兜底序号（空 id 生成临时 id 用）。
  /// static：BackupService 是 const 构造，实例字段必须 final。
  static int _playlistSeq = 0;

  /// 读取 v5 备份（仿 MusicFree 结构）：把 data 里的音乐列表、插件
  /// 数组、设置段落转换回内部偏好结构（favoritePaths /
  /// favoriteSongMetadataV1 / mobilePlaylistsV1 / {t, v} 条目），
  /// 之后复用 applyBackup 的既有恢复链路（曲库表、插件 ID 归一化、
  /// 外观写回）。exportedSections 记录导出时的勾选项：未勾选的
  /// 部分不动本机数据，勾选但为空则清空恢复。
  BackupData _readV5Backup(
    Map<String, dynamic> decoded,
    List<EnabledMusicPlugin> enabledPlugins,
  ) {
    final fileVersion = decoded['version'];
    if (fileVersion is! int || fileVersion < 5) {
      throw const BackupException('备份文件版本无法识别');
    }
    if (fileVersion > version) {
      throw const BackupException('备份来自更新版本的应用，请先升级后再导入');
    }
    final data = decoded['data'];
    if (data is! Map) {
      throw const BackupException('备份文件缺少数据');
    }
    final sections =
        (data['exportedSections'] as List?)?.whereType<String>().toSet() ??
        const <String>{};

    final prefs = <String, Map<String, Object>>{};
    // settings + pluginState → 偏好条目（{t, v} 编码与 v1–v4 一致）。
    for (final section in const ['settings', 'pluginState']) {
      final raw = data[section];
      if (raw is! Map) continue;
      for (final entry in raw.entries) {
        final key = entry.key.toString();
        if (_excludedKeys.contains(key)) continue;
        final value = entry.value;
        if (value is! Map) continue;
        final t = value['t'];
        final v = value['v'];
        if (t is! String) continue;
        if (!_valueMatchesType(v, t)) continue;
        prefs[key] = {'t': t, 'v': v as Object};
      }
    }

    // musicSheets → 收藏/歌单内部偏好结构。
    var sheetCount = 0;
    var songCount = 0;
    var favoriteRestored = false;
    final playlists = <Map<String, Object?>>[];
    final rawSheets = data['musicSheets'];
    if (rawSheets is List) {
      for (final raw in rawSheets) {
        if (raw is! Map) continue;
        sheetCount++;
        final musicList =
            raw['musicList'] is List ? raw['musicList'] as List : const [];
        songCount += musicList.length;
        if (raw['id'] == 'favorite') {
          final paths = <String>[];
          final meta = <String, Object>{};
          for (final item in musicList) {
            if (item is! Map) continue;
            final resolved = _resolveEntry(item, enabledPlugins);
            if (resolved == null) continue;
            final path = resolved['path'] as String;
            paths.add(path);
            meta[path] = _favoriteSnapshotFromEntry(resolved);
          }
          prefs['favoritePaths'] = {'t': 'sl', 'v': paths};
          prefs['favoriteSongMetadataV1'] = {'t': 's', 'v': jsonEncode(meta)};
          final order =
              (raw['customOrder'] as List?)?.whereType<String>().toList();
          if (order != null) {
            prefs['favoriteCustomOrderV1'] = {'t': 'sl', 'v': order};
          }
          favoriteRestored = true;
        } else {
          playlists.add(_playlistFromSheet(raw, enabledPlugins));
        }
      }
    }
    if (sections.contains('favorites') && !favoriteRestored) {
      // 勾选了收藏但备份里没有收藏表（空收藏）：清空恢复。
      prefs['favoritePaths'] = {
        't': 'sl',
        'v': const <String>[],
      };
      prefs['favoriteSongMetadataV1'] = {'t': 's', 'v': '{}'};
    }
    if (sections.contains('playlists')) {
      prefs['mobilePlaylistsV1'] = {'t': 's', 'v': jsonEncode(playlists)};
    }

    // plugins → {id: script} + 订阅来源表（srcUrl 仿 MusicFree）。
    final plugins = <String, String>{};
    final sourceUrls = <String, String>{};
    final rawPlugins = data['plugins'];
    if (rawPlugins is List) {
      for (final raw in rawPlugins) {
        if (raw is! Map) continue;
        final id = raw['id']?.toString() ?? '';
        final script = raw['script'];
        if (id.isEmpty || script is! String || script.isEmpty) continue;
        if (!_isSafePluginId(id)) continue;
        plugins[id] = script;
        final srcUrl = raw['srcUrl'];
        if (srcUrl is String && srcUrl.isNotEmpty) {
          sourceUrls[id] = srcUrl;
        }
      }
      if (sourceUrls.isNotEmpty) {
        prefs[_sourceUrlsKey] = {'t': 's', 'v': jsonEncode(sourceUrls)};
      }
    }

    return BackupData(
      exportedAt: _createdAtToIso(decoded['createdAt']),
      prefs: prefs,
      plugins: plugins,
      library: _decodeLibrarySection(data),
      appearance: _decodeAppearanceSection(data),
      sheetCount: sheetCount,
      songCount: songCount,
    );
  }

  /// v5 音乐条目 → 带有效 path 的条目：外部格式转换工具产出的网络
  /// 条目没有 XY 私有 path/pluginId，按平台匹配已安装插件重建（复用
  /// MusicFree 备份导入的关联链路）；无法关联（缺插件/字段不全）
  /// 返回 null。
  Map? _resolveEntry(Map item, List<EnabledMusicPlugin> plugins) {
    final path = item['path'];
    if (path is String && path.isNotEmpty) return item;
    if (plugins.isEmpty) return null;
    final song = rebuildOnlineSongFromGenericEntry(
      Map<String, dynamic>.from(item),
      plugins,
    );
    if (song == null) return null;
    return {
      ...item,
      'path': song.path,
      'pluginId': song.pluginId,
      'extra': song.pluginData,
    };
  }

  /// 音乐条目 → 收藏快照（FavoriteSongSnapshot 的 JSON 结构）。
  /// 歌词不随备份迁移（体积大，恢复后播放时自动重新获取）。
  Map<String, Object?> _favoriteSnapshotFromEntry(Map item) => {
    'path': item['path'],
    'title': item['title'] ?? '',
    'artist': item['artist'] ?? '',
    'album': item['album'] ?? '',
    'duration': _int(item['duration']) ?? 0,
    'format': _str(item['format']) ?? '网络',
    'coverUrl': item['artwork'],
    'pluginId': item['pluginId'],
    'pluginData': item['extra'] is Map ? item['extra'] : null,
  };

  /// musicSheet → 歌单（MobilePlaylist 的 JSON 结构）。id 为空时
  /// 生成临时 id（歌单操作全部以 id 为键，空 id 会断链）。
  Map<String, Object?> _playlistFromSheet(
    Map raw,
    List<EnabledMusicPlugin> plugins,
  ) {
    final musicList =
        raw['musicList'] is List ? raw['musicList'] as List : const [];
    final songPaths = <String>[];
    final snapshots = <String, Object>{};
    for (final item in musicList) {
      if (item is! Map) continue;
      final resolved = _resolveEntry(item, plugins);
      if (resolved == null) continue;
      final path = resolved['path'] as String;
      songPaths.add(path);
      snapshots[path] = {
        'title': resolved['title'] ?? '',
        'artist': resolved['artist'] ?? '',
        'album': resolved['album'] ?? '',
        'coverUrl': resolved['artwork'],
        'duration': _int(resolved['duration']) ?? 0,
        'songId': resolved['id'] ?? '',
        'qualities': resolved['qualities'],
        'pluginId': resolved['pluginId'],
        'platform': resolved['platform'],
        'extra': resolved['extra'],
      };
    }
    final id = raw['id']?.toString() ?? '';
    return {
      'id': id.isNotEmpty
          ? id
          : 'pl_${DateTime.now().millisecondsSinceEpoch}_${_playlistSeq++}',
      'name': raw['title']?.toString() ?? '导入的歌单',
      'coverUrl': raw['coverImg'],
      'songPaths': songPaths,
      'songSnapshots': snapshots,
      if (raw['customOrder'] is List)
        'customOrder': (raw['customOrder'] as List).whereType<String>().toList(),
    };
  }

  /// v5 备份的 createdAt（毫秒时间戳）→ ISO 8601 展示字符串。
  String _createdAtToIso(Object? createdAt) => createdAt is int
      ? DateTime.fromMillisecondsSinceEpoch(createdAt).toIso8601String()
      : '';

  /// v5 data.library：仅接受曲库元数据缓存表（与 v1–v4 一致）。
  Map<String, dynamic> _decodeLibrarySection(Map data) {
    final library = <String, dynamic>{};
    final rawLibrary = data['library'];
    if (rawLibrary is Map) {
      for (final entry in rawLibrary.entries) {
        if (entry.value is Map &&
            _libraryCacheTables.contains(entry.key.toString())) {
          library[entry.key.toString()] = entry.value;
        }
      }
    }
    return library;
  }

  /// v5 data.appearance：解析规则与 v3+ 一致。
  BackupAppearance _decodeAppearanceSection(Map data) {
    final rawAppearance = data['appearance'];
    if (rawAppearance is! Map) return const BackupAppearance();
    return BackupAppearance(
      background: _decodeAppearanceEntry(
        rawAppearance['background'],
        maxBytes: _maxImageBytes,
      ),
      playerDetail: _decodeAppearanceEntry(
        rawAppearance['playerDetail'],
        maxBytes: _maxImageBytes,
      ),
      font: _decodeAppearanceEntry(
        rawAppearance['font'],
        maxBytes: _maxFontBytes,
      ),
    );
  }

  /// 把校验通过的备份写入本地：先整体恢复曲库表（SQLite 事务，失败即中止），
  /// 再逐条写回 SharedPreferences，最后把插件脚本写入 plugins 目录（同名
  /// 覆盖——恢复语义）。调用前应已通过 [readBackup] 校验并经用户确认。
  Future<BackupImportResult> applyBackup(BackupData data) async {
    final dbPath = p.join(await resolveAppDataDir(), 'library.db');
    if (data.library.isNotEmpty) {
      try {
        await rust.importLibraryTables(
          dbPath: dbPath,
          payload: jsonEncode(data.library),
        );
      } catch (e) {
        throw BackupException('曲库恢复失败：$e');
      }
    }
    final prefs = await SharedPreferences.getInstance();
    for (final entry in data.prefs.entries) {
      final t = entry.value['t']!;
      final v = entry.value['v']!;
      switch (t) {
        case 's':
          await prefs.setString(entry.key, v as String);
        case 'b':
          await prefs.setBool(entry.key, v as bool);
        case 'i':
          await prefs.setInt(entry.key, v is int ? v : (v as num).toInt());
        case 'd':
          await prefs.setDouble(
            entry.key,
            v is double ? v : (v as num).toDouble(),
          );
        case 'sl':
          await prefs.setStringList(entry.key, (v as List).cast<String>());
      }
    }
    final pluginCount = data.plugins.length;
    if (data.plugins.isNotEmpty) {
      final dir = Directory(p.join(await resolveAppDataDir(), 'plugins'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      for (final entry in data.plugins.entries) {
        await File(
          p.join(dir.path, '${entry.key}.js'),
        ).writeAsString(entry.value);
      }
      // 备份里的插件文件名沿用导出设备的 ID，脚本内容重新计算的 ID
      // 可能已经漂移（旧版本安装时回退了哈希 ID、订阅插件 name 加了
      // 赞助后缀等）。导入后立即归一化到内容 ID，并把启用状态、订阅
      // 来源与歌单/收藏等歌曲数据引用一并迁移——否则下次更新合并时
      // 旧 ID 文件被删，备份恢复的歌单会全部断链（搜不到插件）。
      await _canonicalizePluginIds(dir);
    }

    // 外观自定义文件（v3 起）：写回 appearance 目录，并把 prefs 里的
    // 图片路径改写为本机路径（备份里的路径指向导出设备，在本机无效）。
    if (!data.appearance.isEmpty) {
      final dir = Directory(p.join(await resolveAppDataDir(), 'appearance'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final imageEntries = <String, BackupAppearanceFile?>{
        'customBackgroundPath': data.appearance.background,
        'playerDetailCustomImagePath': data.appearance.playerDetail,
      };
      for (final entry in imageEntries.entries) {
        final file = entry.value;
        if (file == null) continue;
        try {
          final target = p.join(dir.path, file.name);
          await File(target).writeAsBytes(base64Decode(file.base64));
          await prefs.setString(entry.key, target);
        } on FormatException {
          // 读取时已校验过 base64，正常不会到这里；防御性跳过。
        } on FileSystemException {
          // 单个文件写回失败时跳过，不影响其余数据恢复。
        }
      }
      final font = data.appearance.font;
      if (font != null) {
        try {
          // 字体固定写 custom_font.ttf（与 customFontFilePath 一致），
          // fontFamily 设置已随 prefs 恢复，无需改写路径。
          await File(
            await customFontFilePath(),
          ).writeAsBytes(base64Decode(font.base64));
        } on FileSystemException {
          // 写回失败时字体回退系统默认，不影响其余数据。
        }
      }
    }
    return BackupImportResult(
      prefCount: data.prefCount,
      pluginCount: pluginCount,
    );
  }

  /// 把 plugins 目录内文件名 ID 与脚本内容 ID 不一致的插件归一化：
  /// - 内容 ID 的主文件已存在：本文件视为变体，删除（内容与偏好以
  ///   主文件为准）；
  /// - 不存在：文件改名为内容 ID。
  /// 两种情况都把启用状态、订阅来源、用户变量、拖拽顺序等偏好从旧
  /// ID 迁移到新 ID，并调用 [migratePluginReferences] 迁移歌单、收藏
  /// 与最近播放里的旧 ID 引用，保证备份恢复的歌单不断链。
  Future<void> _canonicalizePluginIds(Directory dir) async {
    if (!dir.existsSync()) return;
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((file) => p.extension(file.path).toLowerCase() == '.js')
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    final renames = <String, String>{};
    for (final file in files) {
      final fileId = p.basenameWithoutExtension(file.path);
      String script;
      try {
        script = file.readAsStringSync();
      } catch (_) {
        continue;
      }
      final contentId = PluginMetadata.resolvePluginId(script, file.path);
      if (contentId == fileId) continue;
      final target = File(p.join(dir.path, '$contentId.js'));
      try {
        if (target.existsSync()) {
          // 同内容 ID 的主文件已在（本机已装新版）：变体直接删除。
          await file.delete();
        } else {
          await file.rename(target.path);
        }
      } catch (_) {
        // 删除/改名失败时保留原文件，偏好与引用不迁移，下次再试。
        continue;
      }
      renames[fileId] = contentId;
    }
    if (renames.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final enabled = (prefs.getStringList(_enabledPluginsKey) ?? const [])
        .toSet();
    var enabledChanged = false;
    for (final entry in renames.entries) {
      if (enabled.remove(entry.key)) {
        enabled.add(entry.value);
        enabledChanged = true;
      }
    }
    if (enabledChanged) {
      await prefs.setStringList(_enabledPluginsKey, enabled.toList());
    }

    final sourcesRaw = prefs.getString(_sourceUrlsKey);
    if (sourcesRaw != null) {
      try {
        final sources = (jsonDecode(sourcesRaw) as Map).map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        );
        var sourcesChanged = false;
        for (final entry in renames.entries) {
          final value = sources.remove(entry.key);
          if (value != null) {
            sources.putIfAbsent(entry.value, () => value);
            sourcesChanged = true;
          }
        }
        if (sourcesChanged) {
          await prefs.setString(_sourceUrlsKey, jsonEncode(sources));
        }
      } catch (_) {
        // 来源表损坏时跳过，不影响其余迁移。
      }
    }

    final order = prefs.getStringList(_pluginOrderKey);
    if (order != null && order.any(renames.containsKey)) {
      await prefs.setStringList(_pluginOrderKey, [
        for (final id in order) renames[id] ?? id,
      ]);
    }

    final variablesRaw = prefs.getString(_pluginUserVariablesKey);
    if (variablesRaw != null) {
      try {
        final variables = (jsonDecode(variablesRaw) as Map).map(
          (key, value) =>
              MapEntry(key.toString(), Map<String, String>.from(value as Map)),
        );
        var variablesChanged = false;
        for (final entry in renames.entries) {
          final value = variables.remove(entry.key);
          if (value != null) {
            variables.putIfAbsent(entry.value, () => value);
            variablesChanged = true;
          }
        }
        if (variablesChanged) {
          await prefs.setString(_pluginUserVariablesKey, jsonEncode(variables));
        }
      } catch (_) {
        // 变量表损坏时跳过，不影响其余迁移。
      }
    }

    await migratePluginReferences(renames);
  }

  /// 按运行时类型把 SharedPreferences 的值编码成 {t, v} 条目；
  /// 不认识的类型返回 null（跳过，不进备份）。
  Map<String, Object>? _encodeValue(Object? value) {
    if (value is String) return {'t': 's', 'v': value};
    if (value is bool) return {'t': 'b', 'v': value};
    if (value is int) return {'t': 'i', 'v': value};
    if (value is double) return {'t': 'd', 'v': value};
    if (value is List && value.every((e) => e is String)) {
      return {'t': 'sl', 'v': value};
    }
    return null;
  }

  /// 校验解码后的值与类型标记匹配。
  bool _valueMatchesType(Object? v, String t) {
    switch (t) {
      case 's':
        return v is String;
      case 'b':
        return v is bool;
      case 'i':
        return v is int;
      case 'd':
        return v is num;
      case 'sl':
        return v is List && v.every((e) => e is String);
      default:
        return false;
    }
  }

  /// 插件 id 只允许字母/数字/下划线/连字符，杜绝目录分隔符与 ".."
  /// 穿越。
  bool _isSafePluginId(String id) => RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(id);

  /// 外观文件名只允许字母/数字/下划线/连字符/点，且不能以点开头或
  /// 包含 ".."，杜绝路径分隔符与目录穿越。
  bool _isSafeAppearanceFileName(String name) =>
      RegExp(r'^[A-Za-z0-9_\-][A-Za-z0-9_\-.]*$').hasMatch(name) &&
      !name.contains('..');

  /// 导出外观自定义文件：全局壁纸、播放详情页背景与自定义字体。
  /// 文件缺失、不可读或超限时跳过对应条目，不影响其余数据导出。
  Future<BackupAppearance> _exportAppearance(SharedPreferences prefs) async {
    final background = await _encodeAppearanceFile(
      prefs.getString('customBackgroundPath'),
      maxBytes: _maxImageBytes,
    );
    final playerDetail = await _encodeAppearanceFile(
      prefs.getString('playerDetailCustomImagePath'),
      maxBytes: _maxImageBytes,
    );
    // 字体没有路径设置项：family 非空即视为启用，文件固定在
    // appearance/custom_font.ttf。
    final font = (prefs.getString('fontFamily') ?? '').trim().isEmpty
        ? null
        : await _encodeAppearanceFile(
            await customFontFilePath(),
            maxBytes: _maxFontBytes,
          );
    return BackupAppearance(
      background: background,
      playerDetail: playerDetail,
      font: font,
    );
  }

  /// 读取单个外观文件并编码为 base64 条目；路径为空、文件不存在、
  /// 读取失败或超过 [maxBytes] 时返回 null。
  Future<BackupAppearanceFile?> _encodeAppearanceFile(
    String? path, {
    required int maxBytes,
  }) async {
    if (path == null || path.isEmpty) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.length > maxBytes) return null;
      return BackupAppearanceFile(
        name: p.basename(path),
        base64: base64Encode(bytes),
      );
    } on FileSystemException {
      return null;
    }
  }

  /// 解析并校验备份里的单个外观文件条目：文件名必须安全（防路径
  /// 穿越）、base64 可解码且不超过 [maxBytes]，否则返回 null 跳过。
  BackupAppearanceFile? _decodeAppearanceEntry(
    Object? raw, {
    required int maxBytes,
  }) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final base64Text = raw['base64'];
    if (name is! String || base64Text is! String || base64Text.isEmpty) {
      return null;
    }
    if (!_isSafeAppearanceFileName(name)) return null;
    try {
      final bytes = base64Decode(base64Text);
      if (bytes.isEmpty || bytes.length > maxBytes) return null;
    } on FormatException {
      return null;
    }
    return BackupAppearanceFile(name: name, base64: base64Text);
  }

  /// 读取 plugins 目录下全部插件脚本（文件名即插件 id）。
  Future<Map<String, String>> _readPluginSources() async {
    final dir = Directory(p.join(await resolveAppDataDir(), 'plugins'));
    if (!dir.existsSync()) return const {};
    final sources = <String, String>{};
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      if (p.extension(entity.path).toLowerCase() != '.js') continue;
      try {
        sources[p.basenameWithoutExtension(entity.path)] = await entity
            .readAsString();
      } on FileSystemException {
        // 单个脚本读取失败时跳过，不影响其余数据导出。
      }
    }
    return sources;
  }

  /// 从 Rust 导出曲库用户数据表，仅保留元数据缓存表
  /// （songs/library_folders/artists 等）。本地收藏与歌单歌曲依赖这些
  /// 缓存元数据才能在恢复后正常显示；导出失败时抛 [BackupException]
  /// （曲库缺失会让本地歌曲恢复不完整，不应静默跳过）。
  Future<Map<String, dynamic>> _exportLibrary() async {
    final dbPath = p.join(await resolveAppDataDir(), 'library.db');
    try {
      final payload = await rust.exportLibraryTables(dbPath: dbPath);
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        return {
          for (final entry in decoded.entries)
            if (_libraryCacheTables.contains(entry.key)) entry.key: entry.value,
        };
      }
      throw const FormatException('unexpected payload');
    } on FormatException {
      throw const BackupException('曲库数据导出失败');
    } catch (e) {
      throw BackupException('曲库数据导出失败：$e');
    }
  }
}
