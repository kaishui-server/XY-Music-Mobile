import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_provider.dart';
import '../favorites/favorites_provider.dart';
import '../playlists/playlists_provider.dart';
import 'account_plugin_sync.dart';

/// 移动端账号云同步目前复用服务端的文件同步接口，数据格式与电脑版兼容。
/// 本地歌曲会同步元数据和路径；歌曲文件本身不会上传到服务器。
class AccountCloudSync {
  static const _enabledPrefix = 'account_cloud_sync_enabled_';
  static const _promptedPrefix = 'account_cloud_sync_prompted_';
  static const _frequencyPrefix = 'account_cloud_sync_frequency_';
  static const _lastManualPrefix = 'account_cloud_sync_last_manual_';
  static const _lastUploadHashPrefix = 'account_cloud_sync_last_upload_hash_';
  static const _maxSongsPerChunk = 500;
  static Timer? _autoTimer;
  static bool _autoUploading = false;
  static int _autoStartGeneration = 0;

  /// 最近一次 file_sync_download 拿到的云端歌单索引（id → 歌曲 path
  /// 集合）与收藏 path 集合。sync() 先下载再上传，uploadIfChanged 据此
  /// 校验云端快照是否覆盖本地数据——云端被清空/删除后强制重传。
  static Map<String, Set<String>>? _lastCloudPlaylistSongs;
  static Set<String>? _lastCloudFavoritePaths;

  /// 默认使用 30 分钟，减少后台请求；用户手动选择的频率不会被覆盖。
  static const defaultFrequency = CloudSyncFrequency.thirtyMinutes;

  static String _key(String prefix, String accountId) =>
      '$prefix${accountId.trim()}';

  static Future<bool> isEnabled(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key(_enabledPrefix, accountId)) ?? false;
  }

  static Future<void> setEnabled(String accountId, bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key(_enabledPrefix, accountId), enabled);
  }

  static Future<bool> hasPrompted(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key(_promptedPrefix, accountId)) ?? false;
  }

  static Future<void> markPrompted(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key(_promptedPrefix, accountId), true);
  }

  static Future<CloudSyncFrequency> frequency(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key(_frequencyPrefix, accountId));
    return CloudSyncFrequency.values.firstWhere(
      (item) => item.name == value,
      orElse: () => defaultFrequency,
    );
  }

  static Future<void> setFrequency(
    String accountId,
    CloudSyncFrequency value,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(_frequencyPrefix, accountId), value.name);
  }

  static Future<DateTime?> lastManualSyncAt(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(_key(_lastManualPrefix, accountId));
    return value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);
  }

  static Future<void> markManualSync(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _key(_lastManualPrefix, accountId),
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 在应用运行期间按账号设置周期性上传。选择“手动上传”时停止定时器。
  static Future<void> startAutoUpload(
    AuthNotifier auth,
    PlaylistsNotifier playlists,
    ProviderContainer container, {
    FavoritesNotifier? favorites,
  }) async {
    stopAutoUpload();
    // 启动时登录凭证是异步从磁盘恢复的；不等 ready 就读 currentUser
    // 会拿到空账号并直接放弃，导致定时器从未启动（也就永远不会定时上传）。
    final generation = ++_autoStartGeneration;
    try {
      await auth.ready.timeout(const Duration(seconds: 10));
    } catch (_) {
      // init 卡死（如 Rust 调用挂起）时超时放弃，本次不启动定时器。
      return;
    }
    if (generation != _autoStartGeneration) return; // 已有更新的启动请求
    final accountId = auth.currentUser?.xymusicId?.trim() ?? '';
    if (accountId.isEmpty || !await isEnabled(accountId)) return;
    final selected = await frequency(accountId);
    final interval = selected.interval;
    if (interval == null) return;
    _autoTimer = Timer.periodic(interval, (_) async {
      if (_autoUploading || auth.currentUser?.xymusicId?.trim() != accountId) {
        return;
      }
      _autoUploading = true;
      try {
        // 自动同步按周期发送完整歌单快照，而不是依赖本地哈希跳过。
        // 这样即使上次上传只保存了歌单元数据、服务器端歌曲数据不完整，
        // 下一次自动同步也会把当前歌单中的全部歌曲补齐到云端。
        await upload(auth, playlists, favorites: favorites);
        await AccountPluginSync.uploadIfChanged(auth, container);
      } catch (_) {
        // 自动同步失败不打断播放或页面操作，下次周期继续重试。
      } finally {
        _autoUploading = false;
      }
    });
  }

  static void stopAutoUpload() {
    _autoTimer?.cancel();
    _autoTimer = null;
    _autoUploading = false;
  }

  static Future<CloudSyncResult> upload(
    AuthNotifier auth,
    PlaylistsNotifier playlists, {
    FavoritesNotifier? favorites,
  }) async {
    final accountId = _accountId(auth);
    await playlists.ready;
    await favorites?.ready;
    final payload = playlists.items.map(_playlistPayload).toList();
    final favoritePayload = favorites == null
        ? const <Map<String, dynamic>>[]
        : _favoritePayload(favorites);
    final result = await _uploadPayload(
      auth,
      accountId,
      payload,
      favorites: favoritePayload,
    );
    await _saveUploadHash(accountId, payload, favoritePayload);
    return result;
  }

  /// 只有歌单快照发生变化时才上传，避免定时任务重复覆盖同一份云数据。
  ///
  /// 云端数据被清空/部分删除而本地哈希仍命中时，会强制重传一次重建
  /// 云端快照（与插件同步 v3 的保护一致），否则「查看云数据」会一直
  /// 显示 0、其它设备也永远拉不到歌单。
  static Future<CloudSyncResult> uploadIfChanged(
    AuthNotifier auth,
    PlaylistsNotifier playlists, {
    FavoritesNotifier? favorites,
  }) async {
    final accountId = _accountId(auth);
    await playlists.ready;
    await favorites?.ready;
    final payload = playlists.items.map(_playlistPayload).toList();
    final favoritePayload = favorites == null
        ? const <Map<String, dynamic>>[]
        : _favoritePayload(favorites);
    final hash = _payloadHash(payload, favoritePayload);
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_key(_lastUploadHashPrefix, accountId)) == hash) {
      if (payload.isEmpty && favoritePayload.isEmpty) {
        return const CloudSyncResult(noChange: true);
      }
      // 未先下载（无云端快照可比对）或云端已覆盖全部本地数据时跳过；
      // 云端数据被清空/回滚后，仅凭本地哈希会让上传永久跳过，
      // 因此云端缺失本地已有数据时强制重传。
      final cloudSongs = _lastCloudPlaylistSongs;
      final cloudFavorites = _lastCloudFavoritePaths;
      if (cloudSongs == null ||
          cloudFavorites == null ||
          _cloudCovers(cloudSongs, cloudFavorites, payload, favoritePayload)) {
        return const CloudSyncResult(noChange: true);
      }
    }
    final result = await _uploadPayload(
      auth,
      accountId,
      payload,
      favorites: favoritePayload,
    );
    await prefs.setString(_key(_lastUploadHashPrefix, accountId), hash);
    return result;
  }

  /// 云端快照是否已包含全部本地歌单与收藏（歌单按 id + 歌曲 path、
  /// 收藏按 path 比对）。
  static bool _cloudCovers(
    Map<String, Set<String>> cloudPlaylistSongs,
    Set<String> cloudFavoritePaths,
    List<Map<String, dynamic>> payload,
    List<Map<String, dynamic>> favoritePayload,
  ) {
    for (final playlist in payload) {
      final cloudSongs = cloudPlaylistSongs['${playlist['id']}'];
      if (cloudSongs == null) return false;
      for (final song in playlist['songs'] as List) {
        if (song is! Map) continue;
        final path = song['path']?.toString() ?? '';
        if (path.isNotEmpty && !cloudSongs.contains(path)) return false;
      }
    }
    for (final favorite in favoritePayload) {
      final path = favorite['path']?.toString() ?? '';
      if (path.isNotEmpty && !cloudFavoritePaths.contains(path)) return false;
    }
    return true;
  }

  static Future<CloudSyncResult> _uploadPayload(
    AuthNotifier auth,
    String accountId,
    List<Map<String, dynamic>> payload, {
    required List<Map<String, dynamic>> favorites,
  }) async {
    await auth.requestBackendAction('file_sync_upload_start', {
      'user_id': accountId,
    }, fetchTimeoutMs: 30000);

    final chunks = <List<Map<String, dynamic>>>[];
    var current = <Map<String, dynamic>>[];
    var songCount = 0;
    for (final item in payload) {
      final songs = (item['songs'] as List).length;
      if (current.isNotEmpty && songCount + songs > _maxSongsPerChunk) {
        chunks.add(current);
        current = <Map<String, dynamic>>[];
        songCount = 0;
      }
      current.add(item);
      songCount += songs;
    }
    if (current.isNotEmpty || chunks.isEmpty) chunks.add(current);

    for (var index = 0; index < chunks.length; index++) {
      await auth.requestBackendAction('file_sync_upload_chunk', {
        'user_id': accountId,
        'chunk_index': index,
        'total_chunks': chunks.length,
        'chunk_data': chunks[index],
      }, fetchTimeoutMs: 60000);
    }
    final data = await auth.requestBackendAction('file_sync_upload_finish', {
      'user_id': accountId,
      'favorites': favorites,
    }, fetchTimeoutMs: 60000);
    return CloudSyncResult(
      uploadedPlaylists:
          (data['playlist_count'] as num?)?.toInt() ?? payload.length,
      uploadedSongs:
          (data['song_total'] as num?)?.toInt() ??
          payload.fold<int>(
            0,
            (sum, item) => sum + (item['songs'] as List).length,
          ),
    );
  }

  static String _payloadHash(
    List<Map<String, dynamic>> payload,
    List<Map<String, dynamic>> favorites,
  ) => sha256
      .convert(
        utf8.encode(jsonEncode({'playlists': payload, 'favorites': favorites})),
      )
      .toString();

  static Future<void> _saveUploadHash(
    String accountId,
    List<Map<String, dynamic>> payload,
    List<Map<String, dynamic>> favorites,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(_lastUploadHashPrefix, accountId),
      _payloadHash(payload, favorites),
    );
  }

  static Future<CloudSyncResult> download(
    AuthNotifier auth,
    PlaylistsNotifier playlists, {
    FavoritesNotifier? favorites,
  }) async {
    final accountId = _accountId(auth);
    await playlists.ready;
    final data = await auth.requestBackendAction('file_sync_download', {
      'user_id': accountId,
    }, fetchTimeoutMs: 60000);
    final raw = data['playlists'];
    // 记录云端歌单索引（id → 歌曲 path 集合），供 uploadIfChanged 校验
    // 云端快照覆盖情况；云端歌单被清空/删除时据此强制重传。
    final cloudPlaylistSongs = <String, Set<String>>{};
    if (raw is List) {
      for (final value in raw.whereType<Map>()) {
        final cloudId = value['id']?.toString().trim() ?? '';
        if (cloudId.isEmpty) continue;
        final cloudSongPaths = <String>{};
        final cloudRawSongs = value['songs'];
        if (cloudRawSongs is List) {
          for (final song in cloudRawSongs.whereType<Map>()) {
            final path = song['path']?.toString() ?? '';
            if (path.isNotEmpty) cloudSongPaths.add(path);
          }
        }
        cloudPlaylistSongs[cloudId] = cloudSongPaths;
      }
    }
    _lastCloudPlaylistSongs = cloudPlaylistSongs;
    var downloadedSongs = 0;
    var downloadedPlaylists = 0;
    final legacyFavorites = <FavoriteSongSnapshot>[];
    if (raw is List) {
      for (final value in raw.whereType<Map>()) {
        final id = value['id']?.toString().trim() ?? '';
        if (id.isEmpty) continue;
        final songs = <PlaylistSongSnapshot>[];
        final rawSongs = value['songs'];
        final playlistName = value['name']?.toString().trim() ?? '';
        final isLegacyFavorites =
            favorites != null &&
            (value['isFavorite'] == true ||
                playlistName == '我喜欢的音乐' ||
                playlistName == '我喜欢');
        if (rawSongs is List) {
          for (final song in rawSongs.whereType<Map>()) {
            final normalized = _normalizeSong(Map<String, dynamic>.from(song));
            if (isLegacyFavorites) {
              final snapshot = FavoriteSongSnapshot.fromJson(normalized);
              if (snapshot.path.isNotEmpty) legacyFavorites.add(snapshot);
            } else {
              final snapshot = PlaylistSongSnapshot.fromJson(normalized);
              if (snapshot.path.isNotEmpty) songs.add(snapshot);
            }
          }
        }
        if (isLegacyFavorites) continue;
        // 云端记录的导入来源（旧版云端快照没有该字段，解析为空即可）。
        final importedSources = <PlaylistImportSource>[];
        final rawSources = value['importSources'];
        if (rawSources is List) {
          for (final item in rawSources.whereType<Map>()) {
            final source = PlaylistImportSource.fromJson(
              Map<String, dynamic>.from(item),
            );
            if (source.input.isEmpty && source.pluginId.isEmpty) continue;
            importedSources.add(source);
          }
        }
        await playlists.mergeCloudPlaylist(
          id: id,
          name: value['name']?.toString() ?? '未命名歌单',
          createdAt:
              DateTime.tryParse(value['createdAt']?.toString() ?? '') ??
              DateTime.now(),
          coverUrl:
              value['cloudCoverUrl']?.toString() ??
              value['coverUrl']?.toString(),
          songs: songs,
          sources: importedSources,
        );
        downloadedPlaylists++;
        downloadedSongs += songs.length;
      }
    }
    var downloadedFavorites = 0;
    final rawFavorites = data['favorites'];
    // 记录云端收藏 path 集合（与歌单索引同理，供覆盖校验）。
    final cloudFavoritePaths = <String>{};
    final favoriteSongs = <FavoriteSongSnapshot>[];
    if (rawFavorites is List) {
      for (final value in rawFavorites) {
        if (value is Map) {
          final path = value['path']?.toString() ?? '';
          if (path.isNotEmpty) cloudFavoritePaths.add(path);
          if (favorites == null) continue;
          final normalized = _normalizeSong(Map<String, dynamic>.from(value));
          final snapshot = FavoriteSongSnapshot.fromJson(normalized);
          if (snapshot.path.isNotEmpty) favoriteSongs.add(snapshot);
        } else if (value is String && value.trim().isNotEmpty) {
          cloudFavoritePaths.add(value.trim());
          if (favorites == null) continue;
          favoriteSongs.add(
            FavoriteSongSnapshot(
              path: value.trim(),
              title: value.trim().split(RegExp(r'[\\/]')).last,
              artist: '',
              album: '',
              duration: 0,
              format: '本地',
            ),
          );
        }
      }
    }
    _lastCloudFavoritePaths = cloudFavoritePaths;
    if (favorites != null) {
      downloadedFavorites = await favorites.mergeCloudFavorites([
        ...legacyFavorites,
        ...favoriteSongs,
      ]);
    }
    return CloudSyncResult(
      downloadedPlaylists: downloadedPlaylists,
      downloadedSongs: downloadedSongs,
      downloadedFavorites: downloadedFavorites,
    );
  }

  static Future<CloudSyncResult> sync(
    AuthNotifier auth,
    PlaylistsNotifier playlists, {
    FavoritesNotifier? favorites,
  }) async {
    // 先下载并合并云端数据，再上传合并后的完整快照，避免新设备本地为空
    // 时先上传空歌单而覆盖账号已有数据。
    final downloaded = await download(auth, playlists, favorites: favorites);
    final uploaded = await uploadIfChanged(
      auth,
      playlists,
      favorites: favorites,
    );
    if (uploaded.noChange) {
      return CloudSyncResult(
        noChange: true,
        downloadedPlaylists: downloaded.downloadedPlaylists,
        downloadedSongs: downloaded.downloadedSongs,
        downloadedFavorites: downloaded.downloadedFavorites,
      );
    }
    return CloudSyncResult(
      uploadedPlaylists: uploaded.uploadedPlaylists,
      uploadedSongs: uploaded.uploadedSongs,
      downloadedPlaylists: downloaded.downloadedPlaylists,
      downloadedSongs: downloaded.downloadedSongs,
      downloadedFavorites: downloaded.downloadedFavorites,
    );
  }

  /// 同步歌单与插件。插件会在上传前先自动安装云端缺失插件，随后再
  /// 上传合并后的本地插件快照，确保新设备不会把云端数据覆盖为空。
  static Future<CloudSyncResult> syncAll(
    AuthNotifier auth,
    PlaylistsNotifier playlists,
    ProviderContainer container, {
    FavoritesNotifier? favorites,
  }) async {
    final plugins = await AccountPluginSync.sync(auth, container);
    final playlistsResult = await sync(auth, playlists, favorites: favorites);
    return CloudSyncResult(
      noChange: playlistsResult.noChange && plugins.noChange,
      uploadedPlaylists: playlistsResult.uploadedPlaylists,
      uploadedSongs: playlistsResult.uploadedSongs,
      downloadedPlaylists: playlistsResult.downloadedPlaylists,
      downloadedSongs: playlistsResult.downloadedSongs,
      downloadedFavorites: playlistsResult.downloadedFavorites,
      uploadedPlugins: plugins.uploadedPlugins,
      downloadedPlugins: plugins.downloadedPlugins,
      pluginErrors: plugins.errors,
    );
  }

  static String _accountId(AuthNotifier auth) {
    final id = auth.currentUser?.xymusicId?.trim() ?? '';
    if (id.isEmpty) throw AuthException('请先登录账号');
    return id;
  }

  static Map<String, dynamic> _playlistPayload(MobilePlaylist playlist) {
    final songs = [
      for (final path in playlist.songPaths)
        _songPayload(path, playlist.songSnapshots[path]),
    ];
    return {
      'id': playlist.id,
      'name': playlist.name,
      'type': 'mixed',
      'createdAt': playlist.createdAt.toIso8601String(),
      'cloudCoverUrl': playlist.effectiveCoverUrl,
      'isFavorite': false,
      // 导入来源随歌单一起上云：否则云端快照缺少 importSources，重装/
      // 重登后恢复的歌单会丢失「同步来源」按钮，只能重新导入。
      'importSources': [
        for (final source in playlist.importSources) source.toJson(),
      ],
      'songs': songs,
    };
  }

  static List<Map<String, dynamic>> _favoritePayload(
    FavoritesNotifier favorites,
  ) => [
    for (final path in favorites.paths)
      _favoriteSongPayload(path, favorites.snapshotFor(path)),
  ];

  static Map<String, dynamic> _favoriteSongPayload(
    String path,
    FavoriteSongSnapshot? snapshot,
  ) {
    if (snapshot != null) {
      return {
        ...snapshot.toJson(),
        'name': snapshot.title,
        'source_type': snapshot.pluginId?.isNotEmpty == true
            ? 'plugin'
            : 'local',
        'syncType': snapshot.pluginId?.isNotEmpty == true ? 'online' : 'local',
      };
    }
    final fileName = path.split(RegExp(r'[\\/]')).last;
    final title = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
    return {
      'path': path,
      'name': title,
      'title': title,
      'artist': '',
      'album': '',
      'duration': 0,
      'format': '本地',
      'source_type': 'local',
      'syncType': 'local',
    };
  }

  static Map<String, dynamic> _songPayload(
    String path,
    PlaylistSongSnapshot? snapshot,
  ) {
    if (snapshot != null) {
      return {
        ...snapshot.toJson(),
        'name': snapshot.title,
        'source_type': snapshot.pluginId?.isNotEmpty == true
            ? 'plugin'
            : 'local',
        'syncType': snapshot.pluginId?.isNotEmpty == true ? 'online' : 'local',
      };
    }
    final fileName = path.split(RegExp(r'[\\/]')).last;
    final title = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
    return {
      'path': path,
      'name': title,
      'title': title,
      'artist': '',
      'album': '',
      'duration': 0,
      'format': '本地',
      'source_type': 'local',
      'syncType': 'local',
    };
  }

  static Map<String, dynamic> _normalizeSong(Map<String, dynamic> raw) {
    final durationMs = raw['durationMs'];
    final durationSeconds = durationMs is num
        ? (durationMs / 1000).round()
        : (raw['duration'] as num?)?.toInt() ?? 0;
    return {
      ...raw,
      'path': raw['path']?.toString() ?? '',
      'title': raw['title']?.toString() ?? raw['name']?.toString() ?? '',
      'artist': raw['artist']?.toString() ?? '',
      'album': raw['album']?.toString() ?? '',
      'duration': durationSeconds,
      'format': raw['format']?.toString() ?? '网络',
      // 电脑版同步文件使用 snake_case；移动端快照使用 camelCase，
      // 下载时统一成移动端 PlaylistSongSnapshot 能识别的字段。
      'coverThumbPath': raw['coverThumbPath'] ?? raw['cover_thumb_path'],
      'coverUrl': raw['coverUrl'] ?? raw['cover_url'],
      'pluginId': raw['pluginId'] ?? raw['plugin_id'],
      'pluginData': raw['pluginData'] ?? raw['rawData'] ?? raw['raw_data'],
      'lyricsRaw': raw['lyricsRaw'] ?? raw['lyrics_raw'],
    };
  }
}

class CloudSyncResult {
  const CloudSyncResult({
    this.noChange = false,
    this.uploadedPlaylists = 0,
    this.uploadedSongs = 0,
    this.downloadedPlaylists = 0,
    this.downloadedSongs = 0,
    this.downloadedFavorites = 0,
    this.uploadedPlugins = 0,
    this.downloadedPlugins = 0,
    this.pluginErrors = const [],
  });

  final bool noChange;
  final int uploadedPlaylists;
  final int uploadedSongs;
  final int downloadedPlaylists;
  final int downloadedSongs;
  final int downloadedFavorites;
  final int uploadedPlugins;
  final int downloadedPlugins;
  final List<String> pluginErrors;
}

enum CloudSyncFrequency {
  fiveMinutes('每 5 分钟自动上传', Duration(minutes: 5)),
  fifteenMinutes('每 15 分钟自动上传', Duration(minutes: 15)),
  thirtyMinutes('每 30 分钟自动上传', Duration(minutes: 30)),
  oneHour('每 1 小时自动上传', Duration(hours: 1)),
  sixHours('每 6 小时自动上传', Duration(hours: 6)),
  twelveHours('每 12 小时自动上传', Duration(hours: 12)),
  oneDay('每天自动上传', Duration(days: 1)),
  manual('手动上传', null);

  const CloudSyncFrequency(this.label, this.interval);

  final String label;
  final Duration? interval;
}
