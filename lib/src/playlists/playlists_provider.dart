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

class MobilePlaylist {
  const MobilePlaylist({
    required this.id,
    required this.name,
    required this.songPaths,
    required this.createdAt,
    this.coverUrl,
    this.songSnapshots = const {},
    this.customOrder,
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
  }) {
    return MobilePlaylist(
      id: id,
      name: name ?? this.name,
      songPaths: songPaths ?? this.songPaths,
      createdAt: createdAt,
      coverUrl: coverUrl ?? this.coverUrl,
      songSnapshots: songSnapshots ?? this.songSnapshots,
      customOrder: customOrder ?? this.customOrder,
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
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final firstSongCover = songs.isEmpty ? null : songs.first.coverUrl;
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

  Future<void> addSongs(String id, Iterable<String> paths) async {
    state = [
      for (final item in state)
        if (item.id == id)
          item.copyWith(songPaths: {...item.songPaths, ...paths}.toList())
        else
          item,
    ];
    await _save();
  }

  /// 将导入歌单的歌曲合并到已有歌单，同时保存网络歌曲的完整快照。
  /// 相同路径只保留一份，已有歌曲的顺序保持不变，新歌曲追加到末尾。
  Future<void> mergeImportedSongs(
    String id,
    Iterable<Song> songs, {
    String? coverUrl,
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
    for (final song in incoming) {
      if (song.path.trim().isEmpty) continue;
      if (!paths.contains(song.path)) paths.add(song.path);
      snapshots[song.path] = PlaylistSongSnapshot.fromSong(song);
    }
    final fallbackCover = incoming
        .map((song) => song.coverUrl?.trim() ?? '')
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    final next = [...state];
    next[index] = current.copyWith(
      songPaths: paths,
      songSnapshots: snapshots,
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
            songPaths: {...playlist.songPaths, item.path}.toList(),
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

  Future<void> removeSong(String id, String path) async {
    state = [
      for (final item in state)
        if (item.id == id)
          item.copyWith(
            songPaths: item.songPaths.where((value) => value != path).toList(),
            songSnapshots: Map.of(item.songSnapshots)..remove(path),
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
}

final playlistsProvider =
    StateNotifierProvider<PlaylistsNotifier, List<MobilePlaylist>>(
      (ref) => PlaylistsNotifier(),
    );
