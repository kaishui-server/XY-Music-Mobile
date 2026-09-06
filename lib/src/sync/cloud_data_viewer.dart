import '../auth/auth_provider.dart';

/// 「查看云数据」的只读数据模型与获取逻辑。
/// 数据来自服务端 cloud_data_overview / cloud_data_playlist_detail 接口，
/// 只包含轻量展示字段（不含插件脚本、pluginData 等大字段）。
class CloudDataViewer {
  /// 概览缓存：主页拉取一次，歌单/收藏/插件/用户子页直接复用。
  static CloudDataOverview? cachedOverview;

  static Future<CloudDataOverview> fetchOverview(AuthNotifier auth) async {
    final accountId = auth.currentUser?.xymusicId?.trim() ?? '';
    if (accountId.isEmpty) throw AuthException('请先登录账号');
    final data = await auth.requestBackendAction('cloud_data_overview', {
      'user_id': accountId,
    }, fetchTimeoutMs: 30000);
    final overview = CloudDataOverview.fromJson(data);
    cachedOverview = overview;
    return overview;
  }

  /// 优先读缓存（无缓存时再请求），供子页面快速展示。
  static Future<CloudDataOverview> overview(AuthNotifier auth) async {
    final cached = cachedOverview;
    if (cached != null) return cached;
    return fetchOverview(auth);
  }

  static Future<CloudPlaylistDetail?> fetchPlaylistDetail(
    AuthNotifier auth,
    String playlistId,
  ) async {
    final accountId = auth.currentUser?.xymusicId?.trim() ?? '';
    if (accountId.isEmpty) throw AuthException('请先登录账号');
    final data = await auth.requestBackendAction(
      'cloud_data_playlist_detail',
      {
        'user_id': accountId,
        'playlist_id': playlistId,
      },
      fetchTimeoutMs: 30000,
    );
    final raw = data['playlist'];
    if (raw is! Map) return null;
    return CloudPlaylistDetail.fromJson(Map<String, dynamic>.from(raw));
  }

  /// 清空云端数据（歌单/收藏/插件/设置快照全部删除，不可恢复）。
  /// 返回 true 表示有数据被清除；云端本来就没有数据时返回 false。
  static Future<bool> clearCloudData(AuthNotifier auth) async {
    final accountId = auth.currentUser?.xymusicId?.trim() ?? '';
    if (accountId.isEmpty) throw AuthException('请先登录账号');
    final data = await auth.requestBackendAction('cloud_data_clear', {
      'user_id': accountId,
    }, fetchTimeoutMs: 30000);
    cachedOverview = null;
    return data['cleared'] == true;
  }

  /// 批量删除云端歌单（传单个 id 即为单删），
  /// 返回实际删除的数量。
  static Future<int> deletePlaylists(
    AuthNotifier auth,
    List<String> playlistIds,
  ) async =>
      _deleteItems(auth, 'cloud_data_delete_playlists', {
        'playlist_ids': playlistIds,
      });

  /// 批量删除云端歌单内的歌曲（按歌单 id + 歌曲唯一 path）。
  static Future<int> deletePlaylistSongs(
    AuthNotifier auth,
    String playlistId,
    List<String> songPaths,
  ) async =>
      _deleteItems(auth, 'cloud_data_delete_playlist_songs', {
        'playlist_id': playlistId,
        'song_paths': songPaths,
      });

  /// 批量删除云端收藏歌曲（按歌曲唯一 path）。
  static Future<int> deleteFavorites(
    AuthNotifier auth,
    List<String> songPaths,
  ) async =>
      _deleteItems(auth, 'cloud_data_delete_favorites', {
        'song_paths': songPaths,
      });

  /// 批量删除云端插件（按插件 id）。
  static Future<int> deletePlugins(
    AuthNotifier auth,
    List<String> pluginIds,
  ) async =>
      _deleteItems(auth, 'cloud_data_delete_plugins', {
        'plugin_ids': pluginIds,
      });

  static Future<int> _deleteItems(
    AuthNotifier auth,
    String action,
    Map<String, dynamic> extra,
  ) async {
    final accountId = auth.currentUser?.xymusicId?.trim() ?? '';
    if (accountId.isEmpty) throw AuthException('请先登录账号');
    final data = await auth.requestBackendAction(action, {
      'user_id': accountId,
      ...extra,
    }, fetchTimeoutMs: 30000);
    // 任一数据被删除后概览缓存即失效。
    if ((data['deleted'] as num?)?.toInt() != 0) {
      cachedOverview = null;
    }
    return (data['deleted'] as num?)?.toInt() ?? 0;
  }
}

class CloudDataOverview {
  const CloudDataOverview({
    required this.hasData,
    required this.playlistsUploadedAt,
    required this.pluginsUploadedAt,
    required this.settingsUploadedAt,
    required this.stats,
    required this.playlists,
    required this.favorites,
    required this.plugins,
    required this.user,
  });

  final bool hasData;
  final String playlistsUploadedAt;
  final String pluginsUploadedAt;
  final String settingsUploadedAt;
  final CloudDataStats stats;
  final List<CloudPlaylistSummary> playlists;
  final List<CloudSongItem> favorites;
  final List<CloudPluginSummary> plugins;
  final CloudUserInfo? user;

  factory CloudDataOverview.fromJson(Map<String, dynamic> j) {
    final statsRaw = j['stats'];
    final playlistsRaw = j['playlists'];
    final favoritesRaw = j['favorites'];
    final pluginsRaw = j['plugins'];
    final userRaw = j['user'];
    return CloudDataOverview(
      hasData: j['has_data'] == true,
      playlistsUploadedAt: j['playlists_uploaded_at']?.toString() ?? '',
      pluginsUploadedAt: j['plugins_uploaded_at']?.toString() ?? '',
      settingsUploadedAt: j['settings_uploaded_at']?.toString() ?? '',
      stats: CloudDataStats.fromJson(
        statsRaw is Map ? Map<String, dynamic>.from(statsRaw) : const {},
      ),
      playlists: playlistsRaw is List
          ? [
              for (final item in playlistsRaw.whereType<Map>())
                CloudPlaylistSummary.fromJson(Map<String, dynamic>.from(item)),
            ]
          : const [],
      favorites: favoritesRaw is List
          ? [
              for (final item in favoritesRaw.whereType<Map>())
                CloudSongItem.fromJson(Map<String, dynamic>.from(item)),
            ]
          : const [],
      plugins: pluginsRaw is List
          ? [
              for (final item in pluginsRaw.whereType<Map>())
                CloudPluginSummary.fromJson(Map<String, dynamic>.from(item)),
            ]
          : const [],
      user: userRaw is Map
          ? CloudUserInfo.fromJson(Map<String, dynamic>.from(userRaw))
          : null,
    );
  }
}

class CloudDataStats {
  const CloudDataStats({
    this.playlistCount = 0,
    this.songTotal = 0,
    this.favoriteCount = 0,
    this.pluginCount = 0,
  });

  final int playlistCount;
  final int songTotal;
  final int favoriteCount;
  final int pluginCount;

  factory CloudDataStats.fromJson(Map<String, dynamic> j) => CloudDataStats(
        playlistCount: (j['playlist_count'] as num?)?.toInt() ?? 0,
        songTotal: (j['song_total'] as num?)?.toInt() ?? 0,
        favoriteCount: (j['favorite_count'] as num?)?.toInt() ?? 0,
        pluginCount: (j['plugin_count'] as num?)?.toInt() ?? 0,
      );
}

class CloudPlaylistSummary {
  const CloudPlaylistSummary({
    required this.id,
    required this.name,
    required this.songCount,
    required this.createdAt,
    required this.coverUrl,
  });

  final String id;
  final String name;
  final int songCount;
  final String createdAt;
  final String coverUrl;

  factory CloudPlaylistSummary.fromJson(Map<String, dynamic> j) =>
      CloudPlaylistSummary(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '未命名歌单',
        songCount: (j['song_count'] as num?)?.toInt() ?? 0,
        createdAt: j['created_at']?.toString() ?? '',
        coverUrl: j['cover_url']?.toString() ?? '',
      );
}

class CloudPlaylistDetail {
  const CloudPlaylistDetail({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.coverUrl,
    required this.songs,
  });

  final String id;
  final String name;
  final String createdAt;
  final String coverUrl;
  final List<CloudSongItem> songs;

  factory CloudPlaylistDetail.fromJson(Map<String, dynamic> j) =>
      CloudPlaylistDetail(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '未命名歌单',
        createdAt: j['created_at']?.toString() ?? '',
        coverUrl: j['cover_url']?.toString() ?? '',
        songs: j['songs'] is List
            ? [
                for (final item in (j['songs'] as List).whereType<Map>())
                  CloudSongItem.fromJson(Map<String, dynamic>.from(item)),
              ]
            : const [],
      );
}

class CloudSongItem {
  const CloudSongItem({
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.format,
    required this.sourceType,
    required this.path,
  });

  final String title;
  final String artist;
  final String album;
  final int duration;
  final String format;
  final String sourceType;

  /// 云端歌曲唯一标识（删除时按它匹配）；个别旧数据可能为空。
  final String path;

  /// online = 插件音源，local = 本地文件。
  bool get isOnline => sourceType == 'online' || sourceType == 'plugin';

  factory CloudSongItem.fromJson(Map<String, dynamic> j) => CloudSongItem(
        title: j['title']?.toString() ?? '',
        artist: j['artist']?.toString() ?? '',
        album: j['album']?.toString() ?? '',
        duration: (j['duration'] as num?)?.toInt() ?? 0,
        format: j['format']?.toString() ?? '',
        sourceType: j['source_type']?.toString() ?? '',
        path: j['path']?.toString() ?? '',
      );
}

class CloudPluginSummary {
  const CloudPluginSummary({
    required this.id,
    required this.name,
    required this.format,
    required this.version,
    required this.author,
    required this.enabled,
    required this.sourceUrl,
  });

  final String id;
  final String name;
  final String format;
  final String version;
  final String author;
  final bool enabled;
  final String sourceUrl;

  /// lx = LX 音源脚本，musicfree = MusicFree 插件。
  bool get isLx => format == 'lx';

  factory CloudPluginSummary.fromJson(Map<String, dynamic> j) =>
      CloudPluginSummary(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '未知插件',
        format: j['format']?.toString() ?? '',
        version: j['version']?.toString() ?? '',
        author: j['author']?.toString() ?? '',
        enabled: j['enabled'] == true,
        sourceUrl: j['source_url']?.toString() ?? '',
      );
}

class CloudUserInfo {
  const CloudUserInfo({
    required this.userId,
    required this.nickname,
    required this.xymusicId,
    required this.email,
    required this.clientType,
    required this.createdAt,
  });

  final String userId;
  final String nickname;
  final String xymusicId;
  final String email;
  final String clientType;
  final String createdAt;

  factory CloudUserInfo.fromJson(Map<String, dynamic> j) => CloudUserInfo(
        userId: j['user_id']?.toString() ?? '',
        nickname: j['nickname']?.toString() ?? '',
        xymusicId: j['xymusic_id']?.toString() ?? '',
        email: j['email']?.toString() ?? '',
        clientType: j['client_type']?.toString() ?? '',
        createdAt: j['created_at']?.toString() ?? '',
      );
}
