import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../library/library_provider.dart';
import '../player/player_provider.dart';
import '../plugins/plugin_runtime.dart';

/// 网络歌曲不在本地 SQLite 曲库中，收藏时必须一并保存展示与重新播放所需信息。
class FavoriteSongSnapshot {
  const FavoriteSongSnapshot({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.format,
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
  final String? coverUrl;
  final String? pluginId;
  final Map<String, dynamic>? pluginData;
  final String? lyricsRaw;

  factory FavoriteSongSnapshot.fromSong(Song song) => FavoriteSongSnapshot(
    path: song.path,
    title: song.title,
    artist: song.artist,
    album: song.album,
    duration: song.duration,
    format: song.format,
    coverUrl: song.coverUrl,
    pluginId: song.pluginId,
    pluginData: song.pluginData,
    lyricsRaw: song.lyricsRaw,
  );

  factory FavoriteSongSnapshot.fromQueueItem(QueueItem item) =>
      FavoriteSongSnapshot(
        path: item.path,
        title: item.title,
        artist: item.artist,
        album: item.album,
        duration: (item.durationMs / 1000).round(),
        format: item.pluginId == null ? '网络' : '插件',
        coverUrl: item.coverUrl,
        pluginId: item.pluginId,
        pluginData: item.pluginData,
        lyricsRaw: item.lyricsRaw,
      );

  factory FavoriteSongSnapshot.fromJson(Map<String, dynamic> json) =>
      FavoriteSongSnapshot(
        path: json['path'] as String? ?? '',
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String? ?? '',
        album: json['album'] as String? ?? '',
        duration: (json['duration'] as num?)?.toInt() ?? 0,
        format: json['format'] as String? ?? '网络',
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
    'coverUrl': coverUrl,
    'pluginId': pluginId,
    'pluginData': pluginData,
    'lyricsRaw': lyricsRaw,
  };

  Song toSong() {
    final savedCover = coverUrl?.trim() ?? '';
    final recoveredCover = pluginData == null
        ? ''
        : extractPluginCoverUrl(pluginData!);
    return Song(
      path: path,
      title: title,
      artist: artist,
      album: album,
      albumKey: album,
      duration: duration,
      format: format,
      coverUrl: savedCover.isNotEmpty
          ? savedCover
          : (recoveredCover.isEmpty ? null : recoveredCover),
      pluginId: pluginId,
      pluginData: pluginData,
      lyricsRaw: lyricsRaw,
    );
  }
}

/// 收藏歌曲路径集合。
///
/// 本地歌曲仍按路径交给 Rust 查询；网络歌曲额外在 SharedPreferences 中保存快照，
/// 避免把 `plugin://` 虚拟路径误当成本地曲库路径后丢失。
class FavoritesNotifier extends StateNotifier<Set<String>> {
  FavoritesNotifier() : super(const {}) {
    _loaded = _load();
  }

  static const _key = 'favoritePaths';
  static const _songMetadataKey = 'favoriteSongMetadataV1';
  static const _customOrderKey = 'favoriteCustomOrderV1';

  late final Future<void> _loaded;
  final Map<String, FavoriteSongSnapshot> _songSnapshots = {};

  /// 用户手动拖拽后的自定义顺序；null 表示从未自定义过。
  List<String>? _customOrder;

  Future<void> get ready => _loaded;

  /// 当前收藏路径的只读快照，供账号云同步读取。
  Set<String> get paths => Set.unmodifiable(state);

  /// 「自定义」排序顺序（拖拽排序后的完整路径顺序）。
  List<String>? get customOrder =>
      _customOrder == null ? null : List.unmodifiable(_customOrder!);

  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  Future<void> _load() async {
    final prefs = await _prefs();
    final paths = (prefs.getStringList(_key) ?? const <String>[]).toSet();
    final order = prefs.getStringList(_customOrderKey);
    if (order != null && order.isNotEmpty) _customOrder = order;
    final rawMetadata = prefs.getString(_songMetadataKey);
    if (rawMetadata != null && rawMetadata.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawMetadata);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (entry.value is! Map) continue;
            final snapshot = FavoriteSongSnapshot.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            );
            if (snapshot.path.isNotEmpty && paths.contains(snapshot.path)) {
              _songSnapshots[snapshot.path] = snapshot;
            }
          }
        }
      } catch (_) {
        // 旧版本或损坏的元数据不应影响本地收藏路径加载。
      }
    }
    state = paths;
  }

  bool isFavorite(String path) => state.contains(path);

  FavoriteSongSnapshot? snapshotFor(String path) => _songSnapshots[path];

  /// 为旧版本只保存了路径的网络收藏补齐歌曲快照，不改变收藏状态。
  Future<void> rememberSnapshot(FavoriteSongSnapshot song) async {
    await _loaded;
    if (!state.contains(song.path) ||
        !_needsSnapshot(song.path, song.pluginId) ||
        _songSnapshots.containsKey(song.path)) {
      return;
    }
    _songSnapshots[song.path] = song;
    await _persist();
  }

  /// 切换收藏状态，返回切换后的结果（true 表示已收藏）。
  Future<bool> toggle(String path, {FavoriteSongSnapshot? song}) async {
    await _loaded;
    final next = state.toSet();
    final added = !next.remove(path);
    if (added) {
      next.add(path);
      if (song != null && _needsSnapshot(path, song.pluginId)) {
        _songSnapshots[path] = song;
      }
    } else {
      _songSnapshots.remove(path);
      _customOrder = _customOrder?.where((value) => value != path).toList();
    }
    state = next;
    await _persist();
    return added;
  }

  /// 批量取消收藏（多选删除）。返回实际移除的数量。
  Future<int> removeAll(Iterable<String> paths) async {
    await _loaded;
    final next = state.toSet();
    var removed = 0;
    for (final path in paths) {
      if (next.remove(path)) {
        removed++;
        _songSnapshots.remove(path);
      }
    }
    if (removed == 0) return 0;
    _customOrder = _customOrder?.where(next.contains).toList();
    state = next;
    await _persist();
    return removed;
  }

  /// 保存「自定义」排序结果（拖拽排序后的完整路径顺序）。
  Future<void> setCustomOrder(List<String> order) async {
    await _loaded;
    // 只保留仍在收藏中的路径，保持与收藏集合一致。
    _customOrder = order.where(state.contains).toList();
    await _persist();
  }

  /// 批量添加收藏（多选一键收藏）。已在收藏中的跳过，返回实际新增数量。
  Future<int> addAll(Iterable<FavoriteSongSnapshot> songs) async {
    await _loaded;
    final next = state.toSet();
    var added = 0;
    for (final song in songs) {
      if (next.contains(song.path)) continue;
      next.add(song.path);
      added++;
      if (_needsSnapshot(song.path, song.pluginId)) {
        _songSnapshots[song.path] = song;
      }
    }
    if (added == 0) return 0;
    state = next;
    await _persist();
    return added;
  }

  bool _needsSnapshot(String path, String? pluginId) =>
      pluginId?.trim().isNotEmpty == true ||
      path.startsWith('plugin://') ||
      path.startsWith('lx://') ||
      path.startsWith('http://') ||
      path.startsWith('https://');

  Future<void> _persist() async {
    final prefs = await _prefs();
    await prefs.setStringList(_key, state.toList());
    if (_customOrder == null || _customOrder!.isEmpty) {
      await prefs.remove(_customOrderKey);
    } else {
      await prefs.setStringList(_customOrderKey, _customOrder!);
    }
    if (_songSnapshots.isEmpty) {
      await prefs.remove(_songMetadataKey);
    } else {
      await prefs.setString(
        _songMetadataKey,
        jsonEncode(
          _songSnapshots.map(
            (path, snapshot) => MapEntry(path, snapshot.toJson()),
          ),
          toEncodable: (value) => value.toString(),
        ),
      );
    }
  }

  Future<void> clear() async {
    await _loaded;
    state = const {};
    _songSnapshots.clear();
    _customOrder = null;
    final prefs = await _prefs();
    await prefs.remove(_key);
    await prefs.remove(_songMetadataKey);
    await prefs.remove(_customOrderKey);
  }

  /// 合并云端收藏。收藏在云端是独立数据，不会创建或写入“我喜欢”歌单。
  Future<int> mergeCloudFavorites(
    Iterable<FavoriteSongSnapshot> incoming,
  ) async {
    await _loaded;
    final next = state.toSet();
    var added = 0;
    var changed = false;
    for (final song in incoming) {
      final path = song.path.trim();
      if (path.isEmpty) continue;
      if (next.add(path)) {
        added++;
        changed = true;
      }
      if (_songSnapshots[path] != song) changed = true;
      _songSnapshots[path] = song;
    }
    if (changed) {
      state = next;
      await _persist();
    }
    return added;
  }
}

final favoritesProvider = StateNotifierProvider<FavoritesNotifier, Set<String>>(
  (ref) {
    return FavoritesNotifier();
  },
);

/// 主页首帧后预热本地收藏歌曲查询。网络收藏使用已保存的快照，不需要
/// 访问曲库；本地收藏则提前完成一次批量查询，避免进入收藏页时和转场同帧
/// 触发数据库读取。
void preloadFavoriteSongs(WidgetRef ref) {
  unawaited(
    () async {
      final notifier = ref.read(favoritesProvider.notifier);
      await notifier.ready;
      final localPaths = notifier.paths
          .where((path) => notifier.snapshotFor(path) == null)
          .toList(growable: false);
      if (localPaths.isEmpty) return;
      await ref.read(libraryProvider.notifier).songsByPaths(localPaths);
    }().catchError((_) {}),
  );
}
