import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../library/library_provider.dart';
import '../player/player_provider.dart';

class PlaylistSongSnapshot {
  const PlaylistSongSnapshot({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.format,
    this.coverThumbPath,
    this.coverUrl,
    this.pluginId,
    this.pluginData,
    this.lyricsRaw,
  });

  final String path;
  final String title;
  final String artist;
  final String album;
  final int duration;
  final String format;
  final String? coverThumbPath;
  final String? coverUrl;
  final String? pluginId;
  final Map<String, dynamic>? pluginData;
  final String? lyricsRaw;

  factory PlaylistSongSnapshot.fromSong(Song song) => PlaylistSongSnapshot(
    path: song.path,
    title: song.title,
    artist: song.artist,
    album: song.album,
    duration: song.duration,
    format: song.format,
    coverThumbPath: song.coverThumbPath,
    coverUrl: song.coverUrl,
    pluginId: song.pluginId,
    pluginData: song.pluginData,
    lyricsRaw: song.lyricsRaw,
  );

  factory PlaylistSongSnapshot.fromJson(Map<String, dynamic> json) =>
      PlaylistSongSnapshot(
        path: json['path'] as String? ?? '',
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String? ?? '',
        album: json['album'] as String? ?? '',
        duration: (json['duration'] as num?)?.toInt() ?? 0,
        format: json['format'] as String? ?? '网络',
        coverThumbPath: json['coverThumbPath'] as String?,
        coverUrl: json['coverUrl'] as String?,
        pluginId: json['pluginId'] as String?,
        pluginData: json['pluginData'] is Map
            ? Map<String, dynamic>.from(json['pluginData'] as Map)
            : null,
        lyricsRaw: json['lyricsRaw'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'path': path,
    'title': title,
    'artist': artist,
    'album': album,
    'duration': duration,
    'format': format,
    'coverThumbPath': coverThumbPath,
    'coverUrl': coverUrl,
    'pluginId': pluginId,
    'pluginData': pluginData,
    'lyricsRaw': lyricsRaw,
  };

  PlaylistSongSnapshot withCover(String newCoverUrl) => PlaylistSongSnapshot(
    path: path,
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    format: format,
    coverThumbPath: coverThumbPath,
    coverUrl: newCoverUrl,
    pluginId: pluginId,
    pluginData: pluginData,
    lyricsRaw: lyricsRaw,
  );

  Song toSong() => Song(
    path: path,
    title: title,
    artist: artist,
    album: album,
    albumKey: album,
    duration: duration,
    format: format,
    coverThumbPath: coverThumbPath,
    coverUrl: coverUrl,
    pluginId: pluginId,
    pluginData: pluginData,
    lyricsRaw: lyricsRaw,
  );
}

/// 歌单的网络导入来源记录（参考 BakaMusic 的 importSources）：
/// 记录导入时使用的插件与用户输入，供「同步来源」重新拉取歌单快照。
class PlaylistImportSource {
  const PlaylistImportSource({
    required this.kind,
    required this.pluginId,
    required this.input,
    this.lxSource,
    this.importedAt,
  });

  /// 来源类型：'plugin' = 插件运行时导入；'lx' = 洛雪直连导入。
  final String kind;

  /// 导入所用插件 id（洛雪来源为洛雪插件 id）。
  final String pluginId;

  /// 洛雪来源的平台 id（kw/kg/tx/wy/mg），仅 kind == 'lx' 时有意义。
  final String? lxSource;

  /// 用户导入时输入的歌单 ID 或分享链接（同步时原样回传）。
  final String input;

  /// 首次导入时间（ISO 8601，仅展示用）。
  final String? importedAt;

  /// 来源身份键：同插件同输入视为同一来源（重复导入按此去重）。
  String get key => '$kind\u0000$pluginId\u0000${lxSource ?? ''}\u0000$input';

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'pluginId': pluginId,
    'lxSource': lxSource,
    'input': input,
    'importedAt': importedAt,
  };

  factory PlaylistImportSource.fromJson(Map<String, dynamic> json) =>
      PlaylistImportSource(
        kind: json['kind'] as String? ?? 'plugin',
        pluginId: json['pluginId'] as String? ?? '',
        lxSource: json['lxSource'] as String?,
        input: json['input'] as String? ?? '',
        importedAt: json['importedAt'] as String?,
      );
}

class MobilePlaylist {
  const MobilePlaylist({
    required this.id,
    required this.name,
    required this.songPaths,
    required this.createdAt,
    this.coverUrl,
    this.songSnapshots = const {},
    this.customOrder,
    this.importSources = const [],
    this.songSources = const {},
    this.favorited = false,
  });

  final String id;
  final String name;
  final List<String> songPaths;
  final DateTime createdAt;
  final String? coverUrl;
  final Map<String, PlaylistSongSnapshot> songSnapshots;

  /// 用户手动拖拽后的自定义顺序（完整歌曲路径列表）。null 表示从未
  /// 自定义过，「自定义」排序回退为 songPaths 的原始顺序。
  final List<String>? customOrder;

  /// 歌单的网络导入来源（为空表示非导入歌单或未记录来源）。
  final List<PlaylistImportSource> importSources;

  /// 歌曲归属：path → 来源身份键列表。不在表中的歌曲视为手动添加
  /// （同步时永不移除）；同步时来源不再包含的来源歌曲会被移出歌单。
  final Map<String, List<String>> songSources;

  /// 歌单级收藏标记：收藏歌单在音乐库歌单页单独分区置顶显示，
  /// 与「已收藏」（歌曲级收藏）是两个概念，互不影响。
  final bool favorited;

  /// 歌单没有单独设置封面时，默认使用第一首歌的封面。
  String? get effectiveCoverUrl {
    final explicit = coverUrl?.trim() ?? '';
    if (explicit.isNotEmpty) return explicit;
    if (songPaths.isEmpty) return null;
    return songSnapshots[songPaths.first]?.coverUrl;
  }

  MobilePlaylist copyWith({
    String? name,
    List<String>? songPaths,
    String? coverUrl,
    Map<String, PlaylistSongSnapshot>? songSnapshots,
    List<String>? customOrder,
    List<PlaylistImportSource>? importSources,
    Map<String, List<String>>? songSources,
    bool? favorited,
  }) {
    return MobilePlaylist(
      id: id,
      name: name ?? this.name,
      songPaths: songPaths ?? this.songPaths,
      createdAt: createdAt,
      coverUrl: coverUrl ?? this.coverUrl,
      songSnapshots: songSnapshots ?? this.songSnapshots,
      customOrder: customOrder ?? this.customOrder,
      importSources: importSources ?? this.importSources,
      songSources: songSources ?? this.songSources,
      favorited: favorited ?? this.favorited,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'songPaths': songPaths,
    'createdAt': createdAt.toIso8601String(),
    'coverUrl': coverUrl,
    'songSnapshots': songSnapshots.map(
      (path, snapshot) => MapEntry(path, snapshot.toJson()),
    ),
    if (customOrder != null) 'customOrder': customOrder,
    'importSources': [
      for (final source in importSources) source.toJson(),
    ],
    'songSources': songSources.map((path, keys) => MapEntry(path, keys)),
    if (favorited) 'favorited': true,
  };

  factory MobilePlaylist.fromJson(Map<String, dynamic> json) {
    return MobilePlaylist(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '未命名歌单',
      songPaths: (json['songPaths'] as List? ?? const []).cast<String>(),
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      coverUrl: json['coverUrl'] as String?,
      songSnapshots: json['songSnapshots'] is Map
          ? (json['songSnapshots'] as Map).map((key, value) {
              final snapshot = PlaylistSongSnapshot.fromJson(
                Map<String, dynamic>.from(value as Map),
              );
              return MapEntry(key.toString(), snapshot);
            })
          : const {},
      customOrder: (json['customOrder'] as List?)?.cast<String>(),
      importSources: [
        if (json['importSources'] is List)
          for (final item in json['importSources'] as List)
            if (item is Map)
              PlaylistImportSource.fromJson(
                Map<String, dynamic>.from(item),
              ),
      ],
      songSources: json['songSources'] is Map
          ? (json['songSources'] as Map).map((key, value) {
              final keys = value is List
                  ? value.map((e) => e.toString()).toList()
                  : const <String>[];
              return MapEntry(key.toString(), keys);
            })
          : const {},
      favorited: json['favorited'] == true,
    );
  }
}

class PlaylistsNotifier extends StateNotifier<List<MobilePlaylist>> {
  PlaylistsNotifier() : super(const []) {
    _loaded = _load();
  }

  static const _storageKey = 'mobilePlaylistsV1';
  late final Future<void> _loaded;

  Future<void> get ready => _loaded;

  /// 当前歌单的只读快照，供云同步服务读取。
  List<MobilePlaylist> get items => List.unmodifiable(state);

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final values = jsonDecode(raw) as List<dynamic>;
      state = values
          .map((item) => MobilePlaylist.fromJson(item as Map<String, dynamic>))
          .where((item) => item.id.isNotEmpty)
          .toList();
    } catch (_) {
      state = const [];
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode(state.map((item) => item.toJson()).toList()),
    );
  }

  /// 补拉封面回写：歌单内歌曲快照存在且封面为空时填入补拉结果。
  /// 一首歌可能同时存在于多个歌单，全部回填。不回写的话，歌单列表
  /// 与备份迁移到其他设备后的封面都会和播放页实际显示的不一致。
  Future<void> backfillSongCover(String path, String coverUrl) async {
    await _loaded;
    final trimmed = coverUrl.trim();
    if (trimmed.isEmpty) return;
    var changed = false;
    final next = <MobilePlaylist>[];
    for (final playlist in state) {
      final snapshot = playlist.songSnapshots[path];
      if (snapshot == null || snapshot.coverUrl?.trim().isNotEmpty == true) {
        next.add(playlist);
        continue;
      }
      changed = true;
      next.add(
        playlist.copyWith(
          songSnapshots: {
            ...playlist.songSnapshots,
            path: snapshot.withCover(trimmed),
          },
        ),
      );
    }
    if (!changed) return;
    state = next;
    await _save();
  }

  /// 查找与导入歌单同名的本地歌单。名称比较忽略首尾空白，但保留用户
  /// 输入的大小写和正文，避免导入时意外覆盖其他歌单。
  Future<MobilePlaylist?> findByName(String name) async {
    await _loaded;
    final normalized = name.trim();
    if (normalized.isEmpty) return null;
    for (final item in state) {
      if (item.name.trim() == normalized) return item;
    }
    return null;
  }

  Future<MobilePlaylist?> create(
    String name, {
    List<String> paths = const [],
    String? coverUrl,
    List<Song> songs = const [],
    List<PlaylistImportSource> sources = const [],
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final firstSongCover = songs.isEmpty ? null : songs.first.coverUrl;
    final sourceKeys = [for (final source in sources) source.key];
    final item = MobilePlaylist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: trimmed,
      songPaths: {...paths, ...songs.map((song) => song.path)}.toList(),
      createdAt: DateTime.now(),
      coverUrl: coverUrl?.trim().isNotEmpty == true
          ? coverUrl!.trim()
          : firstSongCover,
      songSnapshots: {
        for (final song in songs)
          song.path: PlaylistSongSnapshot.fromSong(song),
      },
      importSources: sources,
      // 导入歌曲全部归属到传入来源；本地路径（paths）不记录归属，
      // 视为手动添加，同步时不会被移除。
      songSources: {
        if (sourceKeys.isNotEmpty)
          for (final song in songs) song.path: List.of(sourceKeys),
      },
    );
    state = [...state, item];
    await _save();
    return item;
  }

  Future<void> rename(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    state = [
      for (final item in state)
        if (item.id == id) item.copyWith(name: trimmed) else item,
    ];
    await _save();
  }

  /// 切换歌单收藏状态（歌单级收藏，与歌曲级「已收藏」互不影响），
  /// 返回切换后的结果（true 表示已收藏）。
  Future<bool> toggleFavorite(String id) async {
    await _loaded;
    final index = state.indexWhere((item) => item.id == id);
    if (index < 0) return false;
    final next = [...state];
    final favorited = !next[index].favorited;
    next[index] = next[index].copyWith(favorited: favorited);
    state = next;
    await _save();
    return favorited;
  }

  /// 设置歌单收藏状态（确定语义，不用 toggle：外部以明确目标值调用）。
  Future<void> setFavorite(String id, bool value) async {
    await _loaded;
    final index = state.indexWhere((item) => item.id == id);
    if (index < 0 || state[index].favorited == value) return;
    final next = [...state];
    next[index] = next[index].copyWith(favorited: value);
    state = next;
    await _save();
  }

  /// 合并一份从账号云同步下载的歌单，保留本机已有歌曲并补齐云端快照。
  Future<void> mergeCloudPlaylist({
    required String id,
    required String name,
    required DateTime createdAt,
    required Iterable<PlaylistSongSnapshot> songs,
    String? coverUrl,
  }) async {
    await _loaded;
    final incoming = songs.toList();
    final index = state.indexWhere((item) => item.id == id);
    if (index < 0) {
      state = [
        ...state,
        MobilePlaylist(
          id: id,
          name: name.trim().isEmpty ? '未命名歌单' : name.trim(),
          songPaths: incoming.map((song) => song.path).toSet().toList(),
          createdAt: createdAt,
          coverUrl: coverUrl?.trim().isEmpty == true ? null : coverUrl?.trim(),
          songSnapshots: {for (final song in incoming) song.path: song},
        ),
      ];
    } else {
      final current = state[index];
      final paths = <String>[...current.songPaths];
      final snapshots = Map<String, PlaylistSongSnapshot>.of(
        current.songSnapshots,
      );
      for (final song in incoming) {
        if (!paths.contains(song.path)) paths.add(song.path);
        snapshots[song.path] = song;
      }
      final next = current.copyWith(
        name: name.trim().isEmpty ? current.name : name.trim(),
        songPaths: paths,
        coverUrl: current.coverUrl ?? coverUrl,
        songSnapshots: snapshots,
      );
      final nextState = [...state];
      nextState[index] = next;
      state = nextState;
    }
    await _save();
  }

  Future<void> delete(String id) async {
    state = state.where((item) => item.id != id).toList();
    await _save();
  }

  Future<void> deleteMany(Iterable<String> ids) async {
    final selected = ids.toSet();
    if (selected.isEmpty) return;
    state = state.where((item) => !selected.contains(item.id)).toList();
    await _save();
  }

  /// 把 [incoming] 中尚未存在于 [existing] 的新路径按传入顺序插入列表顶部。
  /// 已存在的路径保持原位置不变，返回原列表表示没有任何新增。
  List<String> _prependNewPaths(
    List<String> existing,
    Iterable<String> incoming,
  ) {
    final known = existing.toSet();
    final fresh = <String>[];
    for (final path in incoming) {
      if (path.trim().isEmpty) continue;
      if (known.add(path)) fresh.add(path);
    }
    if (fresh.isEmpty) return existing;
    return [...fresh, ...existing];
  }

  /// 添加歌曲到歌单。新歌曲默认插入列表顶部，已在歌单中的保持原位置；
  /// 用户拖拽过排序时同步把新歌前置到自定义顺序，保证置顶可见。
  Future<void> addSongs(String id, Iterable<String> paths) async {
    state = [
      for (final item in state)
        if (item.id == id)
          item.copyWith(
            songPaths: _prependNewPaths(item.songPaths, paths),
            customOrder: item.customOrder == null
                ? null
                : _prependNewPaths(item.customOrder!, paths),
          )
        else
          item,
    ];
    await _save();
  }

  /// 将导入歌单的歌曲合并到已有歌单，同时保存网络歌曲的完整快照。
  /// 相同路径只保留一份，已有歌曲的顺序保持不变，新歌曲追加到末尾。
  /// 传入 [sources] 时记录导入来源（同来源重复导入按 key 去重），并
  /// 为本次导入的歌曲累加来源归属（原手动添加的歌曲转为来源歌曲）。
  Future<void> mergeImportedSongs(
    String id,
    Iterable<Song> songs, {
    String? coverUrl,
    List<PlaylistImportSource> sources = const [],
  }) async {
    await _loaded;
    final incoming = songs.toList(growable: false);
    if (incoming.isEmpty) return;
    final index = state.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final current = state[index];
    final paths = <String>[...current.songPaths];
    final snapshots = Map<String, PlaylistSongSnapshot>.of(
      current.songSnapshots,
    );
    final importSources = [...current.importSources];
    for (final source in sources) {
      if (!importSources.any((item) => item.key == source.key)) {
        importSources.add(source);
      }
    }
    final sourceKeys = [for (final source in sources) source.key];
    final songSources = Map<String, List<String>>.of(current.songSources);
    for (final song in incoming) {
      if (song.path.trim().isEmpty) continue;
      if (!paths.contains(song.path)) paths.add(song.path);
      snapshots[song.path] = PlaylistSongSnapshot.fromSong(song);
      final existing = songSources[song.path];
      if (existing == null) {
        if (sourceKeys.isNotEmpty) {
          songSources[song.path] = List.of(sourceKeys);
        }
      } else {
        for (final key in sourceKeys) {
          if (!existing.contains(key)) existing.add(key);
        }
      }
    }
    final fallbackCover = incoming
        .map((song) => song.coverUrl?.trim() ?? '')
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    final next = [...state];
    next[index] = current.copyWith(
      songPaths: paths,
      songSnapshots: snapshots,
      importSources: importSources,
      songSources: songSources,
      coverUrl:
          current.coverUrl ??
          (coverUrl?.trim().isNotEmpty == true
              ? coverUrl!.trim()
              : fallbackCover.isEmpty
              ? null
              : fallbackCover),
    );
    state = next;
    await _save();
  }

  /// 将当前播放队列中的歌曲加入歌单，同时保存网络歌曲所需的完整快照。
  /// 仅保存 path 会导致网络歌曲重新打开歌单时丢失插件信息，因此这里保留
  /// 插件、封面和歌词等元数据，确保歌单中的网络歌曲可以继续播放。
  /// 新歌曲默认插入列表顶部（含用户拖拽过的自定义顺序）。
  ///
  /// 返回 true 表示新添加；false 表示歌曲已在该歌单中（未重复添加）。
  Future<bool> addQueueItem(String id, QueueItem item) async {
    final existing = state.where((playlist) => playlist.id == id).firstOrNull;
    if (existing != null && existing.songPaths.contains(item.path)) {
      return false;
    }
    final snapshot = PlaylistSongSnapshot(
      path: item.path,
      title: item.title,
      artist: item.artist,
      album: item.album,
      duration: (item.durationMs / 1000).round(),
      format: item.pluginId == null ? '本地' : '网络',
      coverUrl: item.coverUrl,
      pluginId: item.pluginId,
      pluginData: item.pluginData,
      lyricsRaw: item.lyricsRaw,
    );
    state = [
      for (final playlist in state)
        if (playlist.id == id)
          playlist.copyWith(
            songPaths: _prependNewPaths(playlist.songPaths, [item.path]),
            customOrder: playlist.customOrder == null
                ? null
                : _prependNewPaths(playlist.customOrder!, [item.path]),
            coverUrl:
                (playlist.coverUrl?.trim().isNotEmpty ?? false) ||
                    playlist.songPaths.isNotEmpty
                ? playlist.coverUrl
                : item.coverUrl,
            songSnapshots: Map.of(playlist.songSnapshots)
              ..[item.path] = snapshot,
          )
        else
          playlist,
    ];
    await _save();
    return true;
  }

  /// 批量将歌曲加入歌单（收藏多选等场景）：合并为一次状态更新与一次
  /// 持久化写入。已存在的歌曲自动跳过，返回 (新添加数量, 已存在数量)。
  Future<(int, int)> addQueueItems(String id, List<QueueItem> items) async {
    final existingPlaylist = state.where((playlist) => playlist.id == id).firstOrNull;
    if (existingPlaylist == null) return (0, 0);
    final existingPaths = existingPlaylist.songPaths.toSet();
    final fresh = <QueueItem>[
      for (final item in items)
        if (!existingPaths.contains(item.path)) item,
    ];
    if (fresh.isEmpty) return (0, items.length);
    final newPaths = [for (final item in fresh) item.path];
    state = [
      for (final playlist in state)
        if (playlist.id == id)
          playlist.copyWith(
            songPaths: _prependNewPaths(playlist.songPaths, newPaths),
            customOrder: playlist.customOrder == null
                ? null
                : _prependNewPaths(playlist.customOrder!, newPaths),
            coverUrl:
                (playlist.coverUrl?.trim().isNotEmpty ?? false) ||
                    playlist.songPaths.isNotEmpty
                ? playlist.coverUrl
                : fresh.first.coverUrl,
            songSnapshots: Map.of(playlist.songSnapshots)
              ..addAll({
                for (final item in fresh)
                  item.path: PlaylistSongSnapshot(
                    path: item.path,
                    title: item.title,
                    artist: item.artist,
                    album: item.album,
                    duration: (item.durationMs / 1000).round(),
                    format: item.pluginId == null ? '本地' : '网络',
                    coverUrl: item.coverUrl,
                    pluginId: item.pluginId,
                    pluginData: item.pluginData,
                    lyricsRaw: item.lyricsRaw,
                  ),
              }),
          )
        else
          playlist,
    ];
    await _save();
    return (fresh.length, items.length - fresh.length);
  }

  Future<void> removeSong(String id, String path) async {
    state = [
      for (final item in state)
        if (item.id == id)
          item.copyWith(
            songPaths: item.songPaths.where((value) => value != path).toList(),
            songSnapshots: Map.of(item.songSnapshots)..remove(path),
            // 同步清除归属：来源歌单下次同步仍包含这首歌时会重新加回
            //（与 BakaMusic 的「显式本地删除可被来源恢复」语义一致）。
            songSources: Map.of(item.songSources)..remove(path),
            customOrder: item.customOrder
                ?.where((value) => value != path)
                .toList(),
          )
        else
          item,
    ];
    await _save();
  }

  /// 批量移除歌曲（多选删除）。仅移出歌单，不删除音乐文件；一次持久化，
  /// 避免逐首 removeSong 反复写盘。
  Future<void> removeSongs(String id, List<String> paths) async {
    if (paths.isEmpty) return;
    final removing = paths.toSet();
    state = [
      for (final item in state)
        if (item.id == id)
          item.copyWith(
            songPaths:
                item.songPaths.where((value) => !removing.contains(value)).toList(),
            songSnapshots: Map.of(item.songSnapshots)
              ..removeWhere((value, _) => removing.contains(value)),
            songSources: Map.of(item.songSources)
              ..removeWhere((value, _) => removing.contains(value)),
            customOrder: item.customOrder
                ?.where((value) => !removing.contains(value))
                .toList(),
          )
        else
          item,
    ];
    await _save();
  }

  /// 保存「自定义」排序结果（拖拽排序后的完整路径顺序）。
  Future<void> setCustomOrder(String id, List<String> order) async {
    state = [
      for (final item in state)
        if (item.id == id) item.copyWith(customOrder: order) else item,
    ];
    await _save();
  }

  /// 换源：把歌单中 [oldPath] 的歌曲原位替换为 [newSong]（来自其他插件）。
  /// 歌单顺序与自定义排序保持不变，网络歌曲快照同步更新；原歌曲的
  /// 来源归属转移到新路径（换源后下次同步以来源为准恢复原曲）。
  Future<void> replaceSong(String id, String oldPath, Song newSong) async {
    state = [
      for (final item in state)
        if (item.id == id)
          item.copyWith(
            songPaths: [
              for (final path in item.songPaths)
                if (path == oldPath) newSong.path else path,
            ],
            songSnapshots: Map.of(item.songSnapshots)
              ..remove(oldPath)
              ..[newSong.path] = PlaylistSongSnapshot.fromSong(newSong),
            songSources: _transferSongSource(
              item.songSources,
              oldPath,
              newSong.path,
            ),
            customOrder: item.customOrder
                ?.map((path) => path == oldPath ? newSong.path : path)
                .toList(),
          )
        else
          item,
    ];
    await _save();
  }

  /// 迁移歌曲归属：旧路径的来源键转移到新路径；无归属（手动添加）
  /// 时新路径同样不记录归属。
  static Map<String, List<String>> _transferSongSource(
    Map<String, List<String>> sources,
    String oldPath,
    String newPath,
  ) {
    final keys = sources[oldPath];
    if (keys == null || keys.isEmpty) return sources;
    return Map.of(sources)..remove(oldPath)..[newPath] = List.of(keys);
  }

  /// 应用「同步来源」的计算结果：一次性写回歌曲顺序、归属、快照与
  /// 自定义排序（差分合并的最终提交点）。调用前应已确认结果有变化。
  Future<void> applySync(
    String id, {
    required List<String> songPaths,
    required Map<String, List<String>> songSources,
    required Map<String, PlaylistSongSnapshot> songSnapshots,
    List<String>? customOrder,
  }) async {
    await _loaded;
    final index = state.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final current = state[index];
    final next = [...state];
    next[index] = current.copyWith(
      songPaths: songPaths,
      songSources: songSources,
      songSnapshots: songSnapshots,
      customOrder: customOrder,
    );
    state = next;
    await _save();
  }
}

final playlistsProvider =
    StateNotifierProvider<PlaylistsNotifier, List<MobilePlaylist>>(
      (ref) => PlaylistsNotifier(),
    );
