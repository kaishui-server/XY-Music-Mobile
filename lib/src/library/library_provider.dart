import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/db_path.dart';
import '../core/safe_state_notifier.dart';
import '../core/settings.dart';
import '../player/player_provider.dart';
import '../rust/api.dart';
import 'local_scanner.dart';

/// 曲库歌曲（小而美：仅保留播放/展示所需字段）。
class Song {
  final String path;
  final String title;
  final String artist;
  final String album;
  final String albumKey;
  final int duration;
  final String format;
  final String? coverThumbPath;
  final String? coverUrl;
  final String? pluginId;
  final Map<String, dynamic>? pluginData;
  final String? lyricsRaw;

  /// 专辑艺术家标签（与 artist 区分：合辑/致敬专辑两者不同）。
  /// 专辑分组口径要用它，见 [LibraryNotifier._albumKeyOfSong]。
  final String albumArtist;

  /// 拆分后的艺术家名单（对应 song_artists 表的关联来源），歌手分组
  /// 扣减按它匹配，避免多艺术家标签「A/B」整串当一个人。
  final List<String> artistNames;

  /// 文件名（不含目录），用于“按文件名”排序；缺失时回落到 path 的末段。
  final String fileName;

  /// 入库时间 / 文件修改时间（秒或毫秒，仅用于时间排序比较）。
  final int addedAt;
  final int fileModifiedAt;

  const Song({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.albumKey,
    required this.duration,
    required this.format,
    this.coverThumbPath,
    this.coverUrl,
    this.pluginId,
    this.pluginData,
    this.lyricsRaw,
    this.albumArtist = '',
    this.artistNames = const [],
    this.fileName = '',
    this.addedAt = 0,
    this.fileModifiedAt = 0,
  });

  factory Song.fromJson(Map<String, dynamic> j) {
    final path = j['path'] as String? ?? '';
    // Rust LibrarySong 未重命名字段，序列化为 snake_case；兼容 camelCase。
    final rawName = (j['name'] ?? j['fileName']) as String? ?? '';
    return Song(
      path: path,
      title: j['title'] as String? ?? '',
      artist: j['artist'] as String? ?? '',
      album: j['album'] as String? ?? '',
      albumKey: j['album_key'] as String? ?? '',
      albumArtist: (j['album_artist'] ?? j['albumArtist']) as String? ?? '',
      artistNames:
          (j['artist_names'] as List?)?.whereType<String>().toList() ??
          const [],
      duration: (j['duration'] as num?)?.toInt() ?? 0,
      format: j['format'] as String? ?? '',
      coverThumbPath: j['cover_thumb_path'] as String?,
      coverUrl: j['cover_url'] as String?,
      fileName: rawName.isNotEmpty ? rawName : _fileNameFromPath(path),
      addedAt: (j['added_at'] as num?)?.toInt() ?? 0,
      fileModifiedAt: (j['file_modified_at'] as num?)?.toInt() ?? 0,
    );
  }

  static String _fileNameFromPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index < 0 ? normalized : normalized.substring(index + 1);
  }

  QueueItem toQueueItem() => QueueItem(
    path: path,
    title: title,
    artist: artist,
    album: album,
    durationMs: duration * 1000,
    pluginId: pluginId,
    pluginData: pluginData,
    coverUrl: coverUrl,
    lyricsRaw: lyricsRaw,
  );
}

/// 歌手目录项。
class ArtistInfo {
  final int id;
  final String name;
  final int count;
  final String? avatarPath;
  const ArtistInfo({
    required this.id,
    required this.name,
    required this.count,
    this.avatarPath,
  });

  // Rust ArtistCatalogItem 为 snake_case，兼容 camelCase。
  factory ArtistInfo.fromJson(Map<String, dynamic> j) => ArtistInfo(
    id: (j['id'] as num?)?.toInt() ?? 0,
    name: j['name'] as String? ?? '',
    count: (j['count'] as num?)?.toInt() ?? 0,
    avatarPath: (j['avatar_path'] ?? j['avatarPath']) as String?,
  );
}

/// 专辑目录项。
class AlbumInfo {
  final String key;
  final String name;
  final int count;
  final String artist;
  final String firstSongPath;
  const AlbumInfo({
    required this.key,
    required this.name,
    required this.count,
    required this.artist,
    required this.firstSongPath,
  });

  // Rust AlbumCatalogItem 为 snake_case，兼容 camelCase。
  factory AlbumInfo.fromJson(Map<String, dynamic> j) => AlbumInfo(
    key: j['key'] as String? ?? '',
    name: j['name'] as String? ?? '',
    count: (j['count'] as num?)?.toInt() ?? 0,
    artist: j['artist'] as String? ?? '',
    firstSongPath:
        ((j['first_song_path'] ?? j['firstSongPath']) as String?) ?? '',
  );
}

/// 文件夹树节点。
class FolderNodeData {
  final String name;
  final String path;
  final List<FolderNodeData> children;
  final int childCount;
  final int songCount;
  const FolderNodeData({
    required this.name,
    required this.path,
    required this.children,
    required this.childCount,
    this.songCount = 0,
  });

  // Rust FolderNode 序列化为 snake_case，兼容读取 camelCase 以防上游改动。
  factory FolderNodeData.fromJson(Map<String, dynamic> j) => FolderNodeData(
    name: j['name'] as String? ?? '',
    path: j['path'] as String? ?? '',
    children: (j['children'] as List? ?? [])
        .map((e) => FolderNodeData.fromJson(e as Map<String, dynamic>))
        .toList(),
    childCount: ((j['child_count'] ?? j['childCount']) as num?)?.toInt() ?? 0,
    songCount: ((j['song_count'] ?? j['songCount']) as num?)?.toInt() ?? 0,
  );
}

class LibraryState {
  final List<Song> songs;
  final List<String> folders;
  final List<ArtistInfo> artists;
  final List<AlbumInfo> albums;
  final List<FolderNodeData> folderRoot;
  final bool loading;
  final String? error;
  const LibraryState({
    this.songs = const [],
    this.folders = const [],
    this.artists = const [],
    this.albums = const [],
    this.folderRoot = const [],
    this.loading = true,
    this.error,
  });

  LibraryState copyWith({
    List<Song>? songs,
    List<String>? folders,
    List<ArtistInfo>? artists,
    List<AlbumInfo>? albums,
    List<FolderNodeData>? folderRoot,
    bool? loading,
    String? error,
  }) {
    return LibraryState(
      songs: songs ?? this.songs,
      folders: folders ?? this.folders,
      artists: artists ?? this.artists,
      albums: albums ?? this.albums,
      folderRoot: folderRoot ?? this.folderRoot,
      loading: loading ?? this.loading,
      error: error ?? this.error,
    );
  }
}

class LibraryNotifier extends SafeStateNotifier<LibraryState> {
  LibraryNotifier(this._ref) : super(const LibraryState()) {
    load();
    _rescanOnStartup();
  }

  final Ref _ref;

  /// 扫描编排器（MusicFree 式：令牌取消 + 目录级容错 + 权限预检）。
  final LocalMusicScanner _scanner = LocalMusicScanner();

  /// 每次进入软件后台重扫一次本地文件夹，确保新增/删除/修改的文件
  /// 同步进库；扫描结束后 load() 会自动刷新界面。启动扫描失败不影响
  /// 本地音乐展示，用户可通过刷新按钮手动重试。
  Future<void> _rescanOnStartup() async {
    // notifier 可能在本方法首次 await 前就已被回收，此时不得再继续写 state。
    if (!mounted) return;
    try {
      // 等待设置加载完成，保证扫描格式白名单与用户配置一致。
      await _ref.read(settingsProvider.future);
      // 设置加载期间 notifier 可能已被回收（页面销毁 / provider 重建），
      // 继续向下会触发 state 写入而崩溃。
      if (!mounted) return;
      // 启动扫描必须保留「仅从列表移除」名单：用户手动移除的歌曲在重启
      // 后应当继续隐身，只有用户主动刷新/重扫时才恢复显示。
      await scanAllFolders(revealHidden: false);
    } catch (_) {
      // 静默失败：启动扫描仅用于同步磁盘变更，不向用户报错。
    }
  }

  Future<void> load() async {
    // 入口守卫：notifier 已被回收时不再进入加载流程，避免写 state 崩溃。
    if (!mounted) return;
    state = state.copyWith(loading: true, error: null);
    try {
      // 隐藏名单先于解析加载：songs/分组视图都要按名单过滤。
      await _loadHiddenPaths();
      if (!mounted) return;
      final dbPath = await _ref.read(dbPathProvider.future);
      if (!mounted) return;
      final songsJson = await getLibrarySongsCached(dbPath: dbPath);
      final foldersJson = await getLibraryFolders(dbPath: dbPath);
      final artistsJson = await getLibraryArtistCatalog(dbPath: dbPath);
      final albumsJson = await getLibraryAlbumCatalog(dbPath: dbPath);
      final treeJson = await getLibraryHierarchy(dbPath: dbPath);
      // 五路取数连续无依赖：聚合后统一守一次，回收则不再解析与写 state。
      if (!mounted) return;
      final allSongs = _parseSongs(songsJson);
      // 全量索引用于把隐藏路径还原成歌手/专辑归属，分组视图据此扣减。
      _allSongByPath = {for (final song in allSongs) song.path: song};
      // 数据库原始统计留底：隐藏名单变化时以它为基准重算，避免在已扣减
      // 过的视图上二次扣减。
      _rawArtists = (jsonDecode(artistsJson) as List)
          .map((e) => ArtistInfo.fromJson(e as Map<String, dynamic>))
          .toList();
      _rawAlbums = (jsonDecode(albumsJson) as List)
          .map((e) => AlbumInfo.fromJson(e as Map<String, dynamic>))
          .toList();
      _rawFolderRoot = (jsonDecode(treeJson) as List)
          .map((e) => FolderNodeData.fromJson(e as Map<String, dynamic>))
          .toList();
      state = LibraryState(
        songs: _applyHidden(allSongs),
        // getLibraryFolders 返回 [{path, song_count}, ...]，取出 path。
        folders: (jsonDecode(foldersJson) as List)
            .map((e) => (e as Map<String, dynamic>)['path'] as String? ?? '')
            .where((p) => p.isNotEmpty)
            .toList(),
        artists: _applyHiddenArtists(_rawArtists),
        albums: _applyHiddenAlbums(_rawAlbums),
        folderRoot: _applyHiddenFolders(_rawFolderRoot),
        loading: false,
      );
    } catch (e) {
      // catch 内写 state 前再守一次：异常本身可能正源于已回收的场景。
      if (!mounted) return;
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  List<Song> _parseSongs(String json) => (jsonDecode(json) as List)
      .map((e) => Song.fromJson(e as Map<String, dynamic>))
      .toList();

  /// 已从本地列表移除（文件保留在磁盘）的路径集合。持久化于
  /// SharedPreferences，数据库记录保留，仅本地音乐列表与歌手/专辑
  /// 分组视图不再展示；若之后文件被真正删除，重扫后条目自然消失。
  Set<String> _hiddenPaths = {};

  static const _hiddenPathsKey = 'library.hidden_paths';

  Future<void> _loadHiddenPaths() async {
    final prefs = await SharedPreferences.getInstance();
    _hiddenPaths =
        (prefs.getStringList(_hiddenPathsKey) ?? const []).toSet();
  }

  Future<void> _persistHiddenPaths() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hiddenPathsKey, _hiddenPaths.toList());
  }

  /// 过滤掉已从列表移除的歌曲。
  List<Song> _applyHidden(List<Song> songs) => _hiddenPaths.isEmpty
      ? songs
      : songs.where((song) => !_hiddenPaths.contains(song.path)).toList();

  /// 全量歌曲索引（path → Song），由 [load] 建立。隐藏名单只存路径，
  /// 歌手/专辑扣减需要据此还原被隐藏歌曲的归属。
  Map<String, Song> _allSongByPath = const {};

  /// 数据库返回的原始分组统计。以它为基准按当前隐藏名单重算展示视图，
  /// 保证多次隐藏/一次隐藏结果一致（不在已扣减的视图上二次扣减）。
  List<ArtistInfo> _rawArtists = const [];
  List<AlbumInfo> _rawAlbums = const [];
  List<FolderNodeData> _rawFolderRoot = const [];

  List<Song> _hiddenSongList() {
    if (_hiddenPaths.isEmpty) return const [];
    final list = <Song>[];
    for (final path in _hiddenPaths) {
      final song = _allSongByPath[path];
      if (song != null) list.add(song);
    }
    return list;
  }

  /// 统一分隔符并去掉末尾分隔符，便于跨平台比较。
  static String _normPath(String path) {
    var value = path.replaceAll('\\', '/');
    while (value.length > 1 && value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// 歌曲是否位于 [folderPath] 之内（本目录直属或任意层子目录）。
  /// 与 Rust 侧 count_songs_recursive 的 `path = dir OR path LIKE dir/%`
  /// 口径保持一致，否则文件夹计数会与实际列表条数对不上。
  static bool _pathUnder(String songPath, String folderPath) {
    final folder = _normPath(folderPath);
    if (folder.isEmpty) return false;
    final song = _normPath(songPath);
    return song == folder || song.startsWith('$folder/');
  }

  /// 与 Rust 侧 UNKNOWN_ARTIST 保持一致。
  static const _unknownArtist = '未知歌手';

  /// 歌曲归属的艺术家名单，口径对齐 song_artists 表的来源 artist_names
  /// （为空时回落 artist 标签，再空则归入未知歌手）。
  static List<String> _artistNamesOf(Song song) {
    final names = <String>[];
    for (final name in song.artistNames) {
      final trimmed = name.trim();
      if (trimmed.isNotEmpty) names.add(trimmed);
    }
    if (names.isNotEmpty) return names;
    final fallback = song.artist.trim();
    return [fallback.isEmpty ? _unknownArtist : fallback];
  }

  /// 歌手视图扣减：被隐藏歌曲所属歌手的计数减去隐藏数，归零则不再展示。
  List<ArtistInfo> _applyHiddenArtists(List<ArtistInfo> artists) {
    final hiddenSongs = _hiddenSongList();
    if (hiddenSongs.isEmpty) return artists;
    final hiddenByArtist = <String, int>{};
    for (final song in hiddenSongs) {
      for (final name in _artistNamesOf(song)) {
        final key = name.toLowerCase();
        hiddenByArtist[key] = (hiddenByArtist[key] ?? 0) + 1;
      }
    }
    final result = <ArtistInfo>[];
    for (final artist in artists) {
      final hidden = hiddenByArtist[artist.name.trim().toLowerCase()] ?? 0;
      final count = artist.count - hidden;
      if (count <= 0) continue;
      result.add(
        ArtistInfo(
          id: artist.id,
          name: artist.name,
          count: count,
          avatarPath: artist.avatarPath,
        ),
      );
    }
    return result;
  }

  /// 复刻 Rust 侧专辑分组键：album_key 非空时用它，否则
  /// `album::album_artist`（缺 album_artist 时回落 artist），整串小写。
  /// 与 get_library_album_catalog / get_library_song_paths_by_album 同口径。
  static String _albumKeyOfSong(Song song) {
    final rawKey = song.albumKey.trim();
    if (rawKey.isNotEmpty) return rawKey.toLowerCase();
    final album = song.album.trim();
    final albumName = album.isEmpty ? 'Unknown' : album;
    var albumArtistName = song.albumArtist.trim();
    if (albumArtistName.isEmpty) {
      final artist = song.artist.trim();
      albumArtistName = artist.isEmpty ? 'Unknown' : artist;
    }
    return '$albumName::$albumArtistName'.toLowerCase();
  }

  /// 专辑视图扣减：计数减去隐藏数、归零则整条不展示；首曲被隐藏时改用
  /// 该专辑仍在展示的歌曲，避免封面/入口指向一首已隐身的歌。
  List<AlbumInfo> _applyHiddenAlbums(List<AlbumInfo> albums) {
    final hiddenSongs = _hiddenSongList();
    if (hiddenSongs.isEmpty) return albums;

    final hiddenByKey = <String, int>{};
    for (final song in hiddenSongs) {
      final key = _albumKeyOfSong(song);
      hiddenByKey[key] = (hiddenByKey[key] ?? 0) + 1;
    }
    // 每张专辑挑一首仍可见的歌作为首曲，一次遍历建好映射。
    final firstVisibleByKey = <String, String>{};
    for (final song in _allSongByPath.values) {
      if (_hiddenPaths.contains(song.path)) continue;
      firstVisibleByKey.putIfAbsent(_albumKeyOfSong(song), () => song.path);
    }

    final result = <AlbumInfo>[];
    for (final album in albums) {
      final key = album.key.trim().toLowerCase();
      final count = album.count - (hiddenByKey[key] ?? 0);
      if (count <= 0) continue;
      result.add(
        AlbumInfo(
          key: album.key,
          name: album.name,
          count: count,
          artist: album.artist,
          firstSongPath:
              firstVisibleByKey[key] ??
              (_hiddenPaths.contains(album.firstSongPath)
                  ? ''
                  : album.firstSongPath),
        ),
      );
    }
    return result;
  }

  /// 文件夹视图扣减：每个节点的 song_count 是「含子目录」的递归统计，
  /// 因此按同样的目录前缀口径统计隐藏数后相减，父节点会自动包含子目录中
  /// 被隐藏的歌。
  List<FolderNodeData> _applyHiddenFolders(List<FolderNodeData> nodes) {
    if (_hiddenPaths.isEmpty) return nodes;
    return [for (final node in nodes) _applyHiddenFolder(node)];
  }

  FolderNodeData _applyHiddenFolder(FolderNodeData node) {
    var hiddenUnder = 0;
    for (final path in _hiddenPaths) {
      // 已不在库中的隐藏路径不参与扣减（文件被删并重扫后条目自然消失）。
      if (_allSongByPath.isNotEmpty && !_allSongByPath.containsKey(path)) {
        continue;
      }
      if (_pathUnder(path, node.path)) hiddenUnder++;
    }
    return FolderNodeData(
      name: node.name,
      path: node.path,
      children: [
        for (final child in node.children) _applyHiddenFolder(child),
      ],
      childCount: node.childCount,
      songCount: hiddenUnder >= node.songCount ? 0 : node.songCount - hiddenUnder,
    );
  }

  /// 以数据库原始统计为基准重算歌手/专辑/文件夹视图。
  void _refreshGroupedViews() {
    state = state.copyWith(
      artists: _applyHiddenArtists(_rawArtists),
      albums: _applyHiddenAlbums(_rawAlbums),
      folderRoot: _applyHiddenFolders(_rawFolderRoot),
    );
  }

  /// 从本地列表移除歌曲（文件保留在磁盘，不删数据库记录）。播放队列
  /// 中已加入的不受影响；收藏保留（文件仍在，可正常播放）。
  ///
  /// 四个展示视图必须同步过滤：只改 songs 会让歌手页、专辑页、文件夹树
  /// 仍显示这些歌和对应计数（表现为「移除了但还在」）。
  Future<void> hideSongs(List<String> paths) async {
    if (paths.isEmpty) return;
    _hiddenPaths.addAll(paths);
    await _persistHiddenPaths();
    state = state.copyWith(songs: _applyHidden(state.songs));
    _refreshGroupedViews();
  }

  Future<List<FolderNodeData>> folderChildren(String path) async {
    final dbPath = await _ref.read(dbPathProvider.future);
    final childrenJson = await getFolderChildren(
      dbPath: dbPath,
      folderPath: path,
    );
    final children = (jsonDecode(childrenJson) as List)
        .map((e) => FolderNodeData.fromJson(e as Map<String, dynamic>))
        .toList();
    // 懒加载的子目录同样要按隐藏名单扣减，否则展开后的计数与列表不符。
    return _applyHiddenFolders(children);
  }

  /// 格式大类 → 实际扩展名白名单（与 Rust is_ext_allowed 对应）。
  /// wma/ape/opus 与 MusicFree 的本地音乐支持格式对齐。
  static const _formatExtensions = <String, List<String>>{
    'flac': ['flac'],
    'mp3': ['mp3'],
    'wav': ['wav'],
    'aac': ['aac'],
    'm4a': ['m4a', 'm4b', 'mp4'],
    'ogg': ['ogg', 'oga', 'opus'],
    'aiff': ['aif', 'aiff'],
    'wma': ['wma'],
    'ape': ['ape'],
  };

  /// 扫描全部已配置目录，按选定格式白名单入库，返回扫描到的歌曲总数。
  ///
  /// [revealHidden] 控制是否在扫描结束后清空「仅从列表移除」的隐藏名单：
  /// - 用户手动刷新/重扫（默认 true）：清空名单，磁盘上仍在的歌曲恢复显示；
  /// - 启动时自动扫描（false）：保留名单，用户移除过的歌曲重启后不复活。
  ///
  /// 启动后台扫描与用户手动刷新可能并发触发，这里用共享 Future 去重，
  /// 并发调用只会等待同一次扫描完成，避免重复扫盘。若在途的是启动扫描
  /// 而本次是手动扫描，则等它在途任务结束后再补一次手动扫描，避免复用到
  /// 「保留名单」的错误语义。
  Future<int> scanAllFolders({bool revealHidden = true}) {
    final inFlight = _scanInFlight;
    if (inFlight != null) {
      if (!revealHidden) return inFlight;
      return inFlight.then((_) => scanAllFolders());
    }
    return _scanInFlight = _doScanAllFolders(revealHidden: revealHidden)
        .whenComplete(() {
          _scanInFlight = null;
        });
  }

  Future<int>? _scanInFlight;

  Future<int> _doScanAllFolders({required bool revealHidden}) async {
    // 设置读取必须在同步段完成：provider 若在 await 期间被回收，之后再
    // 触碰 _ref 会抛 Bad state（回收后 element 不再可用）。
    final settings = _ref.read(settingsProvider).valueOrNull;
    final dbPath = await _ref.read(dbPathProvider.future);
    final selectedFormats = settings?.scanFormats ?? kSupportedScanFormats;
    final minDuration = settings?.libraryMinDurationSeconds ?? 0;

    // 展开为扩展名白名单。
    final allowed = <String>[
      for (final f in selectedFormats) ...(_formatExtensions[f] ?? [f]),
    ];

    final foldersJson = await getLibraryFolders(dbPath: dbPath);
    final folders = (jsonDecode(foldersJson) as List)
        .map((e) => (e as Map<String, dynamic>)['path'] as String? ?? '')
        .where((p) => p.isNotEmpty)
        .toList();

    // 编排（权限预检 + 令牌取消 + 单目录容错）由 LocalMusicScanner
    // 完成，设计参考 MusicFree 的 localMusicSheet.ts。
    final summary = await _scanner.scanAll(
      dbPath: dbPath,
      folders: folders,
      allowedFormats: allowed,
      minimumDurationSeconds: minDuration > 0 ? minDuration : null,
    );
    // 手动重扫视为重新开始：清空「仅从列表移除」的隐藏名单——文件仍在
    // 磁盘的歌曲会被重新扫出并恢复显示，否则名单会永久吞掉这些条目
    // （表现为目录里明明有歌、扫描完成但列表不显示）。启动扫描不清空，
    // 否则用户移除的歌曲每次重启都会复活。
    if (revealHidden && _hiddenPaths.isNotEmpty) {
      _hiddenPaths = {};
      await _persistHiddenPaths();
    }
    await load();
    // 一首都没扫到且有错误时，抛出以便 UI 展示真实原因。
    if (summary.foundSongs == 0 && summary.errors.isNotEmpty) {
      throw Exception('扫描失败：${summary.errors.first}');
    }
    return summary.foundSongs;
  }

  /// 按歌手取歌曲列表。
  Future<List<Song>> songsByArtist(String name) async {
    final dbPath = await _ref.read(dbPathProvider.future);
    final pathsJson = await getLibrarySongPathsByArtist(
      dbPath: dbPath,
      artistName: name,
    );
    final paths = (jsonDecode(pathsJson) as List).cast<String>();
    final songsJson = await getLibrarySongsByPaths(
      dbPath: dbPath,
      paths: paths,
    );
    return _applyHidden(_parseSongs(songsJson));
  }

  /// 按专辑 key 取歌曲列表。
  Future<List<Song>> songsByAlbum(String key) async {
    final dbPath = await _ref.read(dbPathProvider.future);
    final pathsJson = await getLibrarySongPathsByAlbum(
      dbPath: dbPath,
      albumKey: key,
    );
    final paths = (jsonDecode(pathsJson) as List).cast<String>();
    final songsJson = await getLibrarySongsByPaths(
      dbPath: dbPath,
      paths: paths,
    );
    return _applyHidden(_parseSongs(songsJson));
  }

  /// 按文件夹取歌曲列表。
  ///
  /// 与歌手/专辑视图保持一致：同样走 [_applyHidden] 过滤，否则点进文件夹
  /// 仍能看到已移除的歌。
  Future<List<Song>> songsByFolder(String path) async {
    final dbPath = await _ref.read(dbPathProvider.future);
    final pathsJson = await getLibrarySongPathsForFolderView(
      dbPath: dbPath,
      folderPath: path,
      query: null,
      sortMode: 'title',
    );
    final paths = (jsonDecode(pathsJson) as List).cast<String>();
    final songsJson = await getLibrarySongsByPaths(
      dbPath: dbPath,
      paths: paths,
    );
    return _applyHidden(_parseSongs(songsJson));
  }

  /// 按路径批量取歌曲（用于收藏等自定义路径集合）。
  ///
  /// 已从库中移除的路径不会返回，因此结果可能少于传入路径数。
  Future<List<Song>> songsByPaths(List<String> paths) async {
    if (paths.isEmpty) return const [];
    // 曲库启动时已经把歌曲目录加载到内存。优先从内存返回，避免收藏页和
    // 最近播放页再次跨 Rust/SQLite 查询；只有不在当前目录缓存中的路径才
    // 继续走数据库查询（例如刚扫描完成、尚未刷新目录的歌曲）。
    final byPath = {for (final song in state.songs) song.path: song};
    final cached = <Song>[];
    final missing = <String>[];
    for (final path in paths) {
      final song = byPath[path];
      if (song != null) {
        cached.add(song);
      } else {
        missing.add(path);
      }
    }
    if (missing.isEmpty) return cached;
    final dbPath = await _ref.read(dbPathProvider.future);
    final songsJson = await getLibrarySongsByPaths(
      dbPath: dbPath,
      paths: missing,
    );
    return [...cached, ..._parseSongs(songsJson)];
  }

  /// 播放全部歌曲（或从指定索引开始）。
  Future<void> playFrom(int index) async {
    final songs = state.songs;
    if (songs.isEmpty) return;
    await _playList(songs, index);
  }

  /// 播放当前列表全部歌曲。随机模式下会先将整组歌曲洗牌，
  /// 因此不会固定从列表第一首开始。
  Future<void> playAll(List<Song> songs) async {
    if (songs.isEmpty) return;
    await _playList(songs, 0, randomizeStart: true);
  }

  /// 播放任意歌曲列表（点击单曲走这里）。
  ///
  /// 受“播放歌曲时”设置影响：默认把整个列表加入播放队列；选择
  /// “仅将此歌曲加入播放队列”时只把用户点播过的歌曲加入播放列表，
  /// 未点播过的歌曲不混入队列。已点播过的歌曲会保留在列表里，重复
  /// 点击同一首直接切歌、不重复入队。
  Future<void> playList(List<Song> songs, int index) async {
    if (songs.isEmpty) return;
    final mode = _ref
        .read(settingsProvider)
        .valueOrNull
        ?.playSongQueueMode;
    if (mode == PlaySongQueueMode.singleSong) {
      final i = index.clamp(0, songs.length - 1).toInt();
      final clicked = songs[i];
      final notifier = _ref.read(playerProvider.notifier);
      final queue = _ref.read(playerProvider).queue;
      final existing = queue.indexWhere((q) => q.path == clicked.path);
      if (existing >= 0) {
        // 这首歌之前点播过，仍在播放列表中：直接切到该曲，避免重复入队。
        await notifier.playIndex(existing);
        return;
      }
      if (queue.isEmpty) {
        // 尚未播放任何歌曲：以点中的这首为唯一队列项。
        await _playList([clicked], 0);
        return;
      }
      // 已有点播历史：把点中的歌曲追加到队列末尾并立即播放，
      // 保留之前点播过的歌曲，未点播的歌曲不进入列表。
      await notifier.addToQueue(clicked.toQueueItem());
      await notifier.playIndex(queue.length);
      return;
    }
    await _playList(songs, index);
  }

  Future<void> _playList(
    List<Song> songs,
    int index, {
    bool randomizeStart = false,
  }) async {
    final items = songs.map((s) => s.toQueueItem()).toList();
    await _ref
        .read(playerProvider.notifier)
        .playQueue(items, startIndex: index, randomizeStart: randomizeStart);
  }
}

final libraryProvider = StateNotifierProvider<LibraryNotifier, LibraryState>(
  (ref) => LibraryNotifier(ref),
);

/// 音乐库页当前 Tab（0 全部 / 1 歌手 / 2 专辑 / 3 文件夹），供主页网格跳转。
final libraryTabProvider = StateProvider<int>((ref) => 0);
