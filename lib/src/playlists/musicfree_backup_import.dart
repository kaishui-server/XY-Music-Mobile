import 'dart:convert';

import '../library/library_provider.dart';
import '../plugins/plugin_runtime.dart';

class MusicFreeBackupPlaylist {
  const MusicFreeBackupPlaylist({required this.name, required this.songs});

  final String name;
  final List<Song> songs;
}

class MusicFreeBackupImportResult {
  const MusicFreeBackupImportResult({
    required this.playlists,
    required this.totalSongs,
    required this.importedSongs,
    required this.skippedSongs,
    required this.unmatchedPluginSongs,
    required this.missingPluginSources,
  });

  final List<MusicFreeBackupPlaylist> playlists;
  final int totalSongs;
  final int importedSongs;
  final int skippedSongs;

  /// 在线歌曲有来源和 ID，但当前没有已启用的对应插件。
  final int unmatchedPluginSongs;

  /// 去重后的缺失来源名称，例如“酷狗音乐、QQ音乐”。
  final List<String> missingPluginSources;
}

/// 解析 MusicFree 导出的 JSON 备份。
///
/// MusicFree 的备份结构是 `{ version, musicSheets: [...] }`，每个歌单的
/// 歌曲放在 `musicList`。本地歌曲优先保留路径；网络歌曲按 platform/source
/// 匹配当前已安装的 LX 或 MusicFree 插件，保留原始 musicItem 供播放和歌词接口使用。
MusicFreeBackupImportResult parseMusicFreeBackup(
  String content, {
  required List<EnabledMusicPlugin> plugins,
  List<Song> localSongs = const [],
}) {
  final decoded = _decode(content);
  final rawSheets =
      decoded['musicSheets'] ??
      (decoded['data'] is Map ? (decoded['data'] as Map)['musicSheets'] : null);
  if (rawSheets is! List) {
    throw const FormatException('未找到 MusicFree 的 musicSheets 歌单数据');
  }

  final playlists = <MusicFreeBackupPlaylist>[];
  var total = 0;
  var imported = 0;
  var skipped = 0;
  var unmatchedPluginSongs = 0;
  final missingPluginSources = <String>{};
  for (var index = 0; index < rawSheets.length; index++) {
    final sheet = rawSheets[index] is Map
        ? Map<String, dynamic>.from(rawSheets[index] as Map)
        : const <String, dynamic>{};
    final name =
        _text(sheet['title']) ?? _text(sheet['name']) ?? '未命名歌单 ${index + 1}';
    final rawSongs = sheet['musicList'];
    if (rawSongs is! List) continue;
    final songs = <Song>[];
    for (final value in rawSongs) {
      total++;
      if (value is! Map) {
        skipped++;
        continue;
      }
      final raw = Map<String, dynamic>.from(value);
      final song = _toSong(raw, plugins: plugins, localSongs: localSongs);
      if (song == null) {
        skipped++;
        final missingSource = _unmatchedPluginSource(raw, plugins);
        if (missingSource != null) {
          unmatchedPluginSongs++;
          missingPluginSources.add(missingSource);
        }
      } else {
        imported++;
        songs.add(song);
      }
    }
    if (songs.isNotEmpty) {
      playlists.add(MusicFreeBackupPlaylist(name: name, songs: songs));
    }
  }
  if (total == 0) {
    throw const FormatException('备份中没有可导入的歌曲，或没有匹配的插件/本地歌曲');
  }
  return MusicFreeBackupImportResult(
    playlists: playlists,
    totalSongs: total,
    importedSongs: imported,
    skippedSongs: skipped,
    unmatchedPluginSongs: unmatchedPluginSongs,
    missingPluginSources: missingPluginSources.toList(growable: false),
  );
}

String? _unmatchedPluginSource(
  Map<String, dynamic> raw,
  List<EnabledMusicPlugin> plugins,
) {
  if (_localPath(raw).isNotEmpty) return null;
  final platform =
      _text(raw['platform']) ??
      _text(raw['source']) ??
      _text(raw['sourceName']) ??
      _text(raw['source_name']);
  final idValue =
      raw['id'] ??
      raw['musicId'] ??
      raw['songmid'] ??
      raw['songId'] ??
      raw['songid'] ??
      raw['mid'] ??
      raw['hash'];
  final id = idValue?.toString().trim() ?? '';
  if (platform == null || platform.isEmpty || id.isEmpty) return null;
  return _matchPlugin(platform, plugins) == null ? platform : null;
}

Map<String, dynamic> _decode(String content) {
  try {
    final value = jsonDecode(content);
    if (value is Map) return Map<String, dynamic>.from(value);
  } catch (_) {
    // 转换为统一的用户提示。
  }
  throw const FormatException('文件不是有效的 MusicFree JSON 备份');
}

Song? _toSong(
  Map<String, dynamic> raw, {
  required List<EnabledMusicPlugin> plugins,
  required List<Song> localSongs,
}) {
  final title =
      _text(raw['title']) ?? _text(raw['name']) ?? _text(raw['songname']);
  if (title == null || title.isEmpty) return null;
  final artist = _artist(raw);
  final album = _album(raw);
  final duration = _durationSeconds(raw);
  final cover = _cover(raw);
  final lyrics =
      _text(raw['rawLrc']) ?? _text(raw['lyrics']) ?? _text(raw['lyric']);

  final localPath = _localPath(raw);
  if (localPath.isNotEmpty) {
    final matched = _matchLocal(localPath, title, artist, localSongs);
    final path = matched?.path ?? localPath;
    return Song(
      path: path,
      title: title,
      artist: artist,
      album: album,
      albumKey: '$album-$artist',
      duration: duration,
      format: '本地',
      coverThumbPath: matched?.coverThumbPath,
      coverUrl: cover.isEmpty ? matched?.coverUrl : cover,
      lyricsRaw: lyrics,
    );
  }

  final platform =
      _text(raw['platform']) ??
      _text(raw['source']) ??
      _text(raw['sourceName']) ??
      _text(raw['source_name']);
  final idValue =
      raw['id'] ??
      raw['musicId'] ??
      raw['songmid'] ??
      raw['songId'] ??
      raw['songid'] ??
      raw['mid'] ??
      raw['hash'];
  final id = idValue?.toString().trim() ?? '';
  if (platform == null || platform.isEmpty || id.isEmpty) return null;
  final plugin = _matchPlugin(platform, plugins);
  if (plugin == null) return null;

  if (plugin.isLx) {
    final source =
        _matchLxSource(platform, plugin) ??
        (plugin.lxSources.isNotEmpty ? plugin.lxSources.first : null);
    if (source == null) return null;
    final lx = <String, dynamic>{
      'songmid': id,
      'source': source,
      'name': title,
      'singer': artist,
      'albumName': album,
      'interval': duration,
      'img': cover,
      'hash': raw['hash'],
      'songId': raw['songId'] ?? raw['songid'],
      'albumId': raw['albumId'] ?? raw['album_id'],
      'albumMid': raw['albumMid'] ?? raw['albummid'],
      'strMediaMid': raw['strMediaMid'] ?? raw['mediaMid'],
    };
    return Song(
      path: 'lx://$source/${Uri.encodeComponent(id)}',
      title: title,
      artist: artist,
      album: album,
      albumKey: '$album-$artist',
      duration: duration,
      format: '网络',
      coverUrl: cover.isEmpty ? null : cover,
      pluginData: {'lx': lx},
      lyricsRaw: lyrics,
    );
  }

  final pluginData = Map<String, dynamic>.from(raw);
  // MusicFree 插件通常使用 id；旧备份可能只保留 musicId/songmid。
  pluginData['id'] ??= idValue;
  pluginData['title'] ??= title;
  pluginData['artist'] ??= artist;
  pluginData['album'] ??= album;
  pluginData['platform'] ??= platform;
  return Song(
    path:
        'plugin://${Uri.encodeComponent(plugin.id)}/${Uri.encodeComponent(id)}',
    title: title,
    artist: artist,
    album: album,
    albumKey: '$album-$artist',
    duration: duration,
    format: '网络',
    coverUrl: cover.isEmpty ? null : cover,
    pluginId: plugin.id,
    pluginData: pluginData,
    lyricsRaw: lyrics,
  );
}

EnabledMusicPlugin? _matchPlugin(
  String platform,
  List<EnabledMusicPlugin> plugins,
) {
  final canonical = _canonical(platform);
  final candidates = <({EnabledMusicPlugin plugin, int score})>[];
  for (final plugin in plugins) {
    final labels = [plugin.name, plugin.id, ...plugin.lxSources];
    var score = 0;
    for (final label in labels) {
      final labelCanonical = _canonical(label);
      if (labelCanonical == canonical) {
        score = plugin.isLx ? 110 : 140;
      } else if (canonical.length >= 2 &&
          labelCanonical.length >= 2 &&
          (labelCanonical.contains(canonical) ||
              canonical.contains(labelCanonical))) {
        // 插件名称可能带“音乐/音源/插件”等后缀，允许一次宽松匹配。
        final relaxed = plugin.isLx ? 80 : 100;
        if (score < relaxed) score = relaxed;
      }
    }
    if (score > 0) candidates.add((plugin: plugin, score: score));
  }
  candidates.sort((a, b) => b.score.compareTo(a.score));
  return candidates.firstOrNull?.plugin;
}

String? _matchLxSource(String platform, EnabledMusicPlugin plugin) {
  final canonical = _canonical(platform);
  for (final source in plugin.lxSources) {
    if (_canonical(source) == canonical) return source;
  }
  return null;
}

String _canonical(String value) {
  final normalized = value.toLowerCase().replaceAll(
    RegExp(r'[\s_.\-—/\\()[\]（）【】·]+'),
    '',
  );
  if (normalized.contains('netease') || normalized.contains('网易')) return 'wy';
  if (normalized.contains('qq') || normalized.contains('腾讯')) return 'tx';
  if (normalized.contains('kuwo') || normalized.contains('酷我')) return 'kw';
  if (normalized.contains('kugou') || normalized.contains('酷狗')) return 'kg';
  if (normalized.contains('migu') || normalized.contains('咪咕')) return 'mg';
  if (normalized.contains('bilibili') || normalized.contains('哔哩')) {
    return 'bilibili';
  }
  return normalized.replaceAll(RegExp(r'(音乐|music|音源|source|插件|plugin)$'), '');
}

Song? _matchLocal(
  String path,
  String title,
  String artist,
  List<Song> localSongs,
) {
  if (localSongs.isEmpty) return null;
  final normalizedPath = _normalizePath(path);
  for (final song in localSongs) {
    if (_normalizePath(song.path) == normalizedPath) return song;
  }
  final fileName = _fileStem(path);
  for (final song in localSongs) {
    if (fileName.isNotEmpty && _fileStem(song.path) == fileName) return song;
  }
  final titleKey = _normalizeText(title);
  final artistKey = _normalizeText(artist);
  final matches = localSongs
      .where(
        (song) =>
            _normalizeText(song.title) == titleKey &&
            (_normalizeText(song.artist) == artistKey || artistKey.isEmpty),
      )
      .toList();
  return matches.length == 1 ? matches.first : null;
}

String _normalizePath(String value) =>
    value.trim().replaceAll('\\', '/').toLowerCase();

String _fileStem(String value) {
  final name = value.replaceAll('\\', '/').split('/').last;
  return _normalizeText(name.replaceFirst(RegExp(r'\.[^.]+$'), ''));
}

String _normalizeText(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[（(].*?[）)]'), '')
    .replaceAll(RegExp(r'\s+'), '')
    .trim();

String _artist(Map<String, dynamic> raw) {
  final value =
      raw['artist'] ?? raw['singer'] ?? raw['author'] ?? raw['singerList'];
  if (value is Map) return _text(value['name']) ?? '未知歌手';
  if (value is List) {
    return value
        .map((item) => item is Map ? item['name'] : item)
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .join('/');
  }
  return _text(value) ?? '未知歌手';
}

String _album(Map<String, dynamic> raw) {
  final value =
      raw['album'] ?? raw['albumName'] ?? raw['album_name'] ?? raw['al'];
  if (value is Map) return _text(value['name']) ?? '未知专辑';
  return _text(value) ?? '未知专辑';
}

String _cover(Map<String, dynamic> raw) {
  final value = raw['artwork'] ?? raw['coverUrl'] ?? raw['cover'] ?? raw['img'];
  if (value is Map) {
    return _text(value['url']) ?? _text(value['src']) ?? '';
  }
  return _text(value) ?? '';
}

int _durationSeconds(Map<String, dynamic> raw) {
  final value = raw['duration'] ?? raw['interval'] ?? raw['dt'] ?? raw['time'];
  if (value is String && value.contains(':')) {
    final parts = value.split(':').map(int.tryParse).toList();
    if (parts.every((part) => part != null)) {
      return parts.fold(0, (total, part) => total * 60 + (part ?? 0));
    }
  }
  final number = value is num ? value.toDouble() : double.tryParse('$value');
  if (number == null || number <= 0) return 0;
  return (number > 1000 ? number / 1000 : number).round();
}

String _localPath(Map<String, dynamic> raw) {
  final candidates = <dynamic>[raw['localPath'], raw['local_path'], raw['url']];
  final qualities = raw['qualities'];
  if (qualities is Map) {
    candidates.addAll(
      qualities.values.map((value) => value is Map ? value['url'] : null),
    );
  }
  for (final value in candidates) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) continue;
    if (text.startsWith('file:')) {
      final uri = Uri.tryParse(text);
      if (uri != null) {
        try {
          return uri.toFilePath(windows: false);
        } catch (_) {}
      }
    }
    if (text.startsWith('content://')) return text;
    final uri = Uri.tryParse(text);
    if (uri?.scheme.isNotEmpty == true) continue;
    return text;
  }
  return '';
}

String? _text(dynamic value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}
