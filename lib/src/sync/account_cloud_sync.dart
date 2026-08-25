import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_provider.dart';
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
    ProviderContainer container,
  ) async {
    stopAutoUpload();
    final accountId = auth.currentUser?.ciyuanxiId?.trim() ?? '';
    if (accountId.isEmpty || !await isEnabled(accountId)) return;
    final selected = await frequency(accountId);
    final interval = selected.interval;
    if (interval == null) return;
    _autoTimer = Timer.periodic(interval, (_) async {
      if (_autoUploading || auth.currentUser?.ciyuanxiId?.trim() != accountId) {
        return;
      }
      _autoUploading = true;
      try {
        await uploadIfChanged(auth, playlists);
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
    PlaylistsNotifier playlists,
  ) async {
    final accountId = _accountId(auth);
    await playlists.ready;
    final payload = playlists.items.map(_playlistPayload).toList();
    final result = await _uploadPayload(auth, accountId, payload);
    await _saveUploadHash(accountId, payload);
    return result;
  }

  /// 只有歌单快照发生变化时才上传，避免定时任务重复覆盖同一份云数据。
  /// 返回 null 表示与上次上传完全一致。
  static Future<CloudSyncResult?> uploadIfChanged(
    AuthNotifier auth,
    PlaylistsNotifier playlists,
  ) async {
    final accountId = _accountId(auth);
    await playlists.ready;
    final payload = playlists.items.map(_playlistPayload).toList();
    final hash = _payloadHash(payload);
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_key(_lastUploadHashPrefix, accountId)) == hash) {
      return const CloudSyncResult(noChange: true);
    }
    final result = await _uploadPayload(auth, accountId, payload);
    await prefs.setString(_key(_lastUploadHashPrefix, accountId), hash);
    return result;
  }

  static Future<CloudSyncResult> _uploadPayload(
    AuthNotifier auth,
    String accountId,
    List<Map<String, dynamic>> payload,
  ) async {
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

  static String _payloadHash(List<Map<String, dynamic>> payload) =>
      sha256.convert(utf8.encode(jsonEncode(payload))).toString();

  static Future<void> _saveUploadHash(
    String accountId,
    List<Map<String, dynamic>> payload,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(_lastUploadHashPrefix, accountId),
      _payloadHash(payload),
    );
  }

  static Future<CloudSyncResult> download(
    AuthNotifier auth,
    PlaylistsNotifier playlists,
  ) async {
    final accountId = _accountId(auth);
    await playlists.ready;
    final data = await auth.requestBackendAction('file_sync_download', {
      'user_id': accountId,
    }, fetchTimeoutMs: 60000);
    final raw = data['playlists'];
    if (raw is! List) return const CloudSyncResult();
    var downloadedSongs = 0;
    var downloadedPlaylists = 0;
    for (final value in raw.whereType<Map>()) {
      final id = value['id']?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      final songs = <PlaylistSongSnapshot>[];
      final rawSongs = value['songs'];
      if (rawSongs is List) {
        for (final song in rawSongs.whereType<Map>()) {
          final normalized = _normalizeSong(Map<String, dynamic>.from(song));
          final snapshot = PlaylistSongSnapshot.fromJson(normalized);
          if (snapshot.path.isNotEmpty) songs.add(snapshot);
        }
      }
      await playlists.mergeCloudPlaylist(
        id: id,
        name: value['name']?.toString() ?? '未命名歌单',
        createdAt:
            DateTime.tryParse(value['createdAt']?.toString() ?? '') ??
            DateTime.now(),
        coverUrl:
            value['cloudCoverUrl']?.toString() ?? value['coverUrl']?.toString(),
        songs: songs,
      );
      downloadedPlaylists++;
      downloadedSongs += songs.length;
    }
    return CloudSyncResult(
      downloadedPlaylists: downloadedPlaylists,
      downloadedSongs: downloadedSongs,
    );
  }

  static Future<CloudSyncResult> sync(
    AuthNotifier auth,
    PlaylistsNotifier playlists,
  ) async {
    // 先下载并合并云端数据，再上传合并后的完整快照，避免新设备本地为空
    // 时先上传空歌单而覆盖账号已有数据。
    final downloaded = await download(auth, playlists);
    final uploaded = await uploadIfChanged(auth, playlists);
    if (uploaded == null) {
      return CloudSyncResult(
        noChange: true,
        downloadedPlaylists: downloaded.downloadedPlaylists,
        downloadedSongs: downloaded.downloadedSongs,
      );
    }
    return CloudSyncResult(
      uploadedPlaylists: uploaded.uploadedPlaylists,
      uploadedSongs: uploaded.uploadedSongs,
      downloadedPlaylists: downloaded.downloadedPlaylists,
      downloadedSongs: downloaded.downloadedSongs,
    );
  }

  /// 同步歌单与插件。插件会在上传前先自动安装云端缺失插件，随后再
  /// 上传合并后的本地插件快照，确保新设备不会把云端数据覆盖为空。
  static Future<CloudSyncResult> syncAll(
    AuthNotifier auth,
    PlaylistsNotifier playlists,
    ProviderContainer container,
  ) async {
    final plugins = await AccountPluginSync.sync(auth, container);
    final playlistsResult = await sync(auth, playlists);
    return CloudSyncResult(
      noChange: playlistsResult.noChange && plugins.noChange,
      uploadedPlaylists: playlistsResult.uploadedPlaylists,
      uploadedSongs: playlistsResult.uploadedSongs,
      downloadedPlaylists: playlistsResult.downloadedPlaylists,
      downloadedSongs: playlistsResult.downloadedSongs,
      uploadedPlugins: plugins.uploadedPlugins,
      downloadedPlugins: plugins.downloadedPlugins,
      pluginErrors: plugins.errors,
    );
  }

  static String _accountId(AuthNotifier auth) {
    final id = auth.currentUser?.ciyuanxiId?.trim() ?? '';
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
      'songs': songs,
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
    this.uploadedPlugins = 0,
    this.downloadedPlugins = 0,
    this.pluginErrors = const [],
  });

  final bool noChange;
  final int uploadedPlaylists;
  final int uploadedSongs;
  final int downloadedPlaylists;
  final int downloadedSongs;
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
