import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lpinyin/lpinyin.dart';

import '../../src/favorites/favorites_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/playlists/playlist_sync.dart' show syncPlaylistWithNotice;
import '../../src/plugins/plugin_runtime.dart';
import '../../src/widgets/batch_action_sheet.dart';
import '../../src/widgets/batch_download.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/frosted_search_field.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/source_switch.dart';
import '../../src/widgets/top_notice.dart' show XyNotice, XyNoticeType;

/// 歌单页右上角「更多」菜单项。
enum _PlaylistMenuAction {
  batchDownload,
  batchSwitchSource,
  batchSaveToPlaylist,
  batchFavorite,
  batchDelete,
  refresh,
}

class PlaylistDetailPage extends ConsumerStatefulWidget {
  const PlaylistDetailPage({
    super.key,
    required this.playlistId,
    this.autoFocusSearch = false,
  });
  final String playlistId;
  final bool autoFocusSearch;

  @override
  ConsumerState<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends ConsumerState<PlaylistDetailPage> {
  List<Song> _songs = const <Song>[];
  List<Song> _visibleSongs = const <Song>[];
  bool _switchingSource = false;
  int _switchingDone = 0;
  int _switchingTotal = 0;
  late final TextEditingController _searchController;
  final FocusNode _searchFocus = FocusNode();
  bool _searchMode = false;
  String _query = '';
  SongSort _sort = const SongSort(SongSortKey.custom);

  /// 悬浮头部（搜索框 + 歌单信息卡 + 歌曲数行）的测量 Key 与实测高度：
  /// 头部悬浮于列表上方，列表内容滚动时从毛玻璃下方穿过被模糊（与
  /// 列表浮动按钮组同款观感），列表顶部让出头部高度。
  final GlobalKey _floatingHeaderKey = GlobalKey();
  double _floatingHeaderExtent = 190;

  /// 布局完成后用真实高度修正悬浮头部占位，字体缩放等场景自动适配。
  void _measureFloatingHeader() {
    if (!mounted) return;
    final size = _floatingHeaderKey.currentContext?.size;
    if (size == null || size.height <= 0) return;
    if ((size.height - _floatingHeaderExtent).abs() > 0.5) {
      setState(() => _floatingHeaderExtent = size.height);
    }
  }

  /// 自定义排序的拖拽编辑模式：已是自定义排序时再次点击“自定义”
  /// 进入，列表行首显示拖拽手柄；点击“完成”退出，手柄消失。
  bool _dragEditMode = false;

  /// 歌曲列表加载缓存：future 只跟随歌单内容指纹创建一次，
  /// 勾选/搜索等 setState 不会重复触发数据库查询和全屏转圈。
  int _songsCacheKey = 0;
  Future<List<Song>>? _songsFuture;

  Future<List<Song>> _songsFor(MobilePlaylist playlist) {
    final key = Object.hashAll(playlist.songPaths);
    if (_songsFuture == null || key != _songsCacheKey) {
      _songsCacheKey = key;
      _songsFuture = _loadSongs(ref, playlist);
    }
    return _songsFuture!;
  }

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    if (widget.autoFocusSearch) {
      _searchMode = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _enterSearch() {
    setState(() => _searchMode = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _exitSearch() {
    _searchFocus.unfocus();
    setState(() {
      _searchMode = false;
      _query = '';
      _searchController.clear();
    });
  }

  /// 按当前排序方式整理歌曲列表。时间排序基于歌单的添加顺序
  /// （songPaths 本身按添加先后存储），歌名/艺术家/专辑排序使用拼音
  /// 避免中文乱序，自定义排序优先使用拖拽保存的 customOrder，未记录过
  /// 的新歌按添加顺序追加在末尾。
  List<Song> _applySort(List<Song> songs, MobilePlaylist playlist) {
    switch (_sort.key) {
      case SongSortKey.added:
        return _sort.descending ? songs.reversed.toList() : songs;
      case SongSortKey.title:
      case SongSortKey.fileName:
      case SongSortKey.path:
      case SongSortKey.artist:
      case SongSortKey.album:
      case SongSortKey.modified:
        final sorted = [...songs]
          ..sort((a, b) {
            var result = compareSongsBySortKey(_sort.key, a, b, _pinyinKey);
            if (result == 0) {
              // 主键相同时回落到歌名，保持组内稳定。
              result = _pinyinKey(a.title).compareTo(_pinyinKey(b.title));
            }
            return _sort.descending ? -result : result;
          });
        return sorted;
      case SongSortKey.custom:
        final order = playlist.customOrder;
        if (order == null || order.isEmpty) return songs;
        final rank = <String, int>{
          for (var i = 0; i < order.length; i++) order[i]: i,
        };
        final known = <Song>[];
        final appended = <Song>[];
        for (final song in songs) {
          if (rank.containsKey(song.path)) {
            known.add(song);
          } else {
            appended.add(song);
          }
        }
        known.sort((a, b) => rank[a.path]!.compareTo(rank[b.path]!));
        return [...known, ...appended];
    }
  }

  /// 拖拽排序回调：基于当前展示顺序重排并持久化为歌单的自定义顺序。
  /// newIndex 已是移除 oldIndex 项后的目标位置（onReorderItem 语义）。
  void _onReorder(int oldIndex, int newIndex) {
    final paths = [for (final song in _visibleSongs) song.path];
    if (oldIndex < 0 || oldIndex >= paths.length) return;
    final path = paths.removeAt(oldIndex);
    paths.insert(newIndex.clamp(0, paths.length), path);
    ref
        .read(playlistsProvider.notifier)
        .setCustomOrder(widget.playlistId, paths);
  }

  String _pinyinKey(String title) =>
      PinyinHelper.getPinyinE(title.trim(), separator: ' ').toLowerCase();

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);
    MobilePlaylist? playlist;
    for (final item in playlists) {
      if (item.id == widget.playlistId) {
        playlist = item;
        break;
      }
    }
    if (playlist == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('歌单')),
        body: Center(
          child: FilledButton(
            onPressed: () => context.go('/home/playlists'),
            child: const Text('返回歌单'),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        // 歌单名称已由信息卡（悬浮头部）展示，顶栏不再重复大标题。
        title: Text(
          _switchingSource ? '换源中 $_switchingDone/$_switchingTotal' : '',
        ),
        actions: [
          if (_searchMode)
            TextButton(onPressed: _exitSearch, child: const Text('取消'))
          else ...[
            if (_dragEditMode)
              // 拖拽编辑模式：点击“完成”收起拖拽手柄。
              TextButton(
                onPressed: () => setState(() => _dragEditMode = false),
                child: const Text('完成'),
              )
            else
              SongSortMenuButton(
                sort: _sort,
                onSortChanged: (sort) {
                  setState(() {
                    // 已处于自定义排序时再次点击“自定义”：
                    // 进入/退出拖拽编辑模式（手柄随之显隐）。
                    if (sort.key == SongSortKey.custom &&
                        _sort.key == SongSortKey.custom) {
                      _dragEditMode = !_dragEditMode;
                    } else {
                      _sort = sort;
                      _dragEditMode = false;
                    }
                  });
                },
              ),
            IconButton(
              tooltip: '搜索',
              onPressed: _enterSearch,
              icon: const Icon(Icons.search_rounded),
            ),
            // 右上角更多：批量下载 / 批量换源 / 批量保存到歌单 / 批量收藏 /
            // 批量删除（仅本地歌单）/ 刷新，点击后在按钮旁弹出小菜单。
            PopupMenuButton<_PlaylistMenuAction>(
              tooltip: '更多',
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: _onMenuAction,
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: _PlaylistMenuAction.batchDownload,
                  child: Text('批量下载'),
                ),
                const PopupMenuItem(
                  value: _PlaylistMenuAction.batchSwitchSource,
                  child: Text('批量换源'),
                ),
                const PopupMenuItem(
                  value: _PlaylistMenuAction.batchSaveToPlaylist,
                  child: Text('批量保存到歌单'),
                ),
                const PopupMenuItem(
                  value: _PlaylistMenuAction.batchFavorite,
                  child: Text('批量收藏'),
                ),
                // 仅本地歌单（无导入来源）提供批量删除。
                if (playlist!.importSources.isEmpty)
                  const PopupMenuItem(
                    value: _PlaylistMenuAction.batchDelete,
                    child: Text('批量删除'),
                  ),
                const PopupMenuItem(
                  value: _PlaylistMenuAction.refresh,
                  child: Text('刷新'),
                ),
              ],
            ),
          ],
        ],
      ),
      body: FutureBuilder<List<Song>>(
        key: ValueKey(_songsCacheKey),
        future: _songsFor(playlist),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final songs = snapshot.data ?? const <Song>[];
          _songs = songs;
          final query = _query;
          final visibleSongs = _applySort(
            query.isEmpty
                ? songs
                : songs
                      .where(
                        (song) =>
                            song.title.toLowerCase().contains(query) ||
                            song.artist.toLowerCase().contains(query) ||
                            song.album.toLowerCase().contains(query),
                      )
                      .toList(),
            playlist!,
          );
          _visibleSongs = visibleSongs;
          // 布局完成后修正悬浮头部占位高度。
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _measureFloatingHeader(),
          );
          // 搜索框（搜索时）+ 歌单信息卡 + 歌曲数行悬浮于列表上方：列表
          // 内容滚动时从毛玻璃下方穿过被模糊，与列表浮动按钮组观感一致。
          return Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Padding(
                        padding: EdgeInsets.only(
                          top: songs.isEmpty || visibleSongs.isEmpty
                              ? 0
                              : _floatingHeaderExtent,
                        ),
                        child: songs.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 110),
                                  child: Text(
                                    '歌单中暂无可用歌曲',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              )
                            : visibleSongs.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 110),
                                  child: Text(
                                    '未找到匹配的歌曲',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              )
                            : SongsListView(
                                songs: visibleSongs,
                                // 悬浮元素遮挡高度已注入 MediaQuery.padding，
                                // 列表底部留出安全区与遮挡高度。
                                padding: EdgeInsets.fromLTRB(
                                  10,
                                  0,
                                  10,
                                  MediaQuery.paddingOf(context).bottom + 12,
                                ),
                                // 搜索过滤时下标与歌单全量不一致，禁止拖拽；
                                // 拖拽手柄仅在自定义排序的编辑模式中显示。
                                onReorder:
                                    _sort.key == SongSortKey.custom &&
                                        _dragEditMode &&
                                        query.isEmpty
                                    ? _onReorder
                                    : null,
                                onPlay: (list, index) => ref
                                    .read(libraryProvider.notifier)
                                    .playList(list, index),
                                // 更多菜单中的单曲移出（仅移出歌单，不删文件）。
                                onRemoveAction: (song) async {
                                  await ref
                                      .read(playlistsProvider.notifier)
                                      .removeSongs(widget.playlistId, [
                                        song.path,
                                      ]);
                                  if (context.mounted) {
                                    XyNotice.show(
                                      context,
                                      message: '已移出歌单',
                                      type: XyNoticeType.success,
                                    );
                                  }
                                },
                                removeActionLabel: '移出歌单',
                              ),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: KeyedSubtree(
                        key: _floatingHeaderKey,
                        child: Column(
                          children: [
                            if (_searchMode)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                                child: FrostedSearchField(
                                  controller: _searchController,
                                  focusNode: _searchFocus,
                                  autofocus: true,
                                  hintText: '搜索歌单中的歌曲',
                                  onChanged: (value) => setState(
                                    () => _query = value.trim().toLowerCase(),
                                  ),
                                  // 清除按钮与操作栏「取消」按钮分工：前者清
                                  // 文本，后者退出搜索。
                                  showClearSuffix: true,
                                  padding: EdgeInsets.zero,
                                ),
                              ),
                            _PlaylistHeroHeader(
                              playlist: playlist,
                              songs: songs,
                              onPlayAll: songs.isEmpty
                                  ? null
                                  : () => ref
                                        .read(libraryProvider.notifier)
                                        .playAll(_applySort(songs, playlist!)),
                              onSyncSource: playlist.importSources.isEmpty
                                  ? null
                                  : () => syncPlaylistWithNotice(
                                      context,
                                      ref,
                                      playlist!,
                                    ),
                            ),
                            if (songs.isNotEmpty && visibleSongs.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  8,
                                ),
                                child: Row(
                                  children: [
                                    Text(
                                      query.isEmpty
                                          ? '${songs.length} 首歌曲'
                                          : '${visibleSongs.length} / ${songs.length} 首歌曲',
                                    ),
                                    const Spacer(),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 右上角更多菜单：批量下载 / 批量换源 / 批量保存到歌单 / 批量收藏 /
  /// 批量删除（仅本地歌单）/ 刷新。
  Future<void> _onMenuAction(_PlaylistMenuAction action) async {
    switch (action) {
      case _PlaylistMenuAction.batchDownload:
        await showBatchActionSheet(
          context,
          kind: BatchActionKind.download,
          songs: _songs,
          onDownload: (selected, quality) => runBatchDownload(
            context,
            ref,
            songs: selected,
            qualityOverride: quality,
          ),
        );
      case _PlaylistMenuAction.batchSwitchSource:
        await showBatchActionSheet(
          context,
          kind: BatchActionKind.switchSource,
          songs: _songs,
          onSwitchSource: (selected, plugin, lxSource) =>
              _switchSourceFor(selected, plugin, lxSource),
        );
      case _PlaylistMenuAction.batchSaveToPlaylist:
        await showBatchActionSheet(
          context,
          kind: BatchActionKind.saveToPlaylist,
          songs: _songs,
          onSaveToPlaylist: (selected, playlistId) =>
              _saveToPlaylist(selected, playlistId),
        );
      case _PlaylistMenuAction.batchFavorite:
        await showBatchActionSheet(
          context,
          kind: BatchActionKind.favorite,
          songs: _songs,
          onFavorite: _favoriteSongs,
        );
      case _PlaylistMenuAction.batchDelete:
        await showBatchActionSheet(
          context,
          kind: BatchActionKind.delete,
          songs: _songs,
          onDelete: (selected) => _deleteSongsFromPlaylist(selected),
        );
      case _PlaylistMenuAction.refresh:
        _refreshSongs();
    }
  }

  /// 批量收藏：把所选歌曲添加到收藏，已在收藏中的自动跳过。
  Future<void> _favoriteSongs(List<Song> selected) async {
    if (selected.isEmpty) return;
    final added = await ref
        .read(favoritesProvider.notifier)
        .addAll(selected.map(FavoriteSongSnapshot.fromSong));
    if (!mounted) return;
    final message = added > 0 ? '已收藏 $added 首歌曲' : '所选歌曲均已在收藏中';
    XyNotice.show(
      context,
      message: message,
      type: added > 0 ? XyNoticeType.success : XyNoticeType.warning,
    );
  }

  /// 批量删除：把所选歌曲移出本地歌单（仅移出歌单，不删除音乐文件与收藏）。
  Future<void> _deleteSongsFromPlaylist(List<Song> selected) async {
    if (selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('批量删除'),
        content: Text(
          '确定将选中的 ${selected.length} 首歌曲移出歌单吗？\n音乐文件不会被删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(playlistsProvider.notifier)
        .removeSongs(widget.playlistId, [
          for (final song in selected) song.path,
        ]);
    if (!mounted) return;
    XyNotice.show(
      context,
      message: '已移出 ${selected.length} 首',
      type: XyNoticeType.success,
    );
  }

  /// 刷新歌单：丢弃歌曲加载缓存并重新读取（文件变动后可见最新内容）。
  void _refreshSongs() {
    setState(() => _songsFuture = null);
    XyNotice.show(
      context,
      message: '已刷新',
      type: XyNoticeType.success,
      compact: true,
    );
  }

  /// 批量保存到歌单：把所选歌曲加入目标歌单，已存在的自动跳过。
  Future<void> _saveToPlaylist(List<Song> selected, String playlistId) async {
    if (selected.isEmpty) return;
    final (added, exists) = await ref
        .read(playlistsProvider.notifier)
        .addQueueItems(playlistId, [
          for (final song in selected) song.toQueueItem(),
        ]);
    if (!mounted) return;
    final message = added > 0
        ? '已添加 $added 首到歌单${exists > 0 ? '，$exists 首已存在' : ''}'
        : '所选歌曲均已在歌单中';
    XyNotice.show(
      context,
      message: message,
      type: added > 0 ? XyNoticeType.success : XyNoticeType.warning,
    );
  }

  /// 批量换源（通用面板与多选菜单共用）：逐首搜索同名歌曲，原位替换歌单
  /// 歌曲，保持顺序与来源归属。
  Future<void> _switchSourceFor(
    List<Song> selected,
    EnabledMusicPlugin plugin,
    String? lxSource,
  ) async {
    if (selected.isEmpty || _switchingSource) return;
    setState(() {
      _switchingSource = true;
      _switchingDone = 0;
      _switchingTotal = selected.length;
    });
    var replaced = 0;
    final missed = <String>[];
    for (final song in selected) {
      if (!mounted) return;
      setState(() => _switchingDone++);
      try {
        final candidates = await searchReplacementCandidates(
          ref,
          plugin,
          title: song.title,
          artist: song.artist,
          durationMs: song.duration * 1000,
          lxSource: lxSource,
        );
        if (candidates.isEmpty) {
          missed.add(song.title);
          continue;
        }
        await ref
            .read(playlistsProvider.notifier)
            .replaceSong(
              widget.playlistId,
              song.path,
              replacementToSong(plugin, candidates.first),
            );
        replaced++;
      } catch (_) {
        missed.add(song.title);
      }
    }
    if (!mounted) return;
    setState(() => _switchingSource = false);
    if (missed.isEmpty) {
      XyNotice.show(
        context,
        message: '换源完成：$replaced 首已切换到 ${plugin.name}',
        type: XyNoticeType.success,
      );
    } else {
      await showDialog<void>(
        context: context,
        useRootNavigator: true,
        builder: (dialogContext) => AlertDialog(
          title: const Text('换源完成'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('成功换源 $replaced 首，${missed.length} 首未找到匹配结果：'),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  child: Text(
                    missed.take(50).join('\n') +
                        (missed.length > 50 ? '\n…' : ''),
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    }
  }

  Future<List<Song>> _loadSongs(WidgetRef ref, MobilePlaylist playlist) async {
    final networkPaths = playlist.songSnapshots.keys.toSet();
    final localPaths = playlist.songPaths
        .where((path) => !networkPaths.contains(path))
        .toList();
    final localSongs = await ref
        .read(libraryProvider.notifier)
        .songsByPaths(localPaths);
    final songsByPath = <String, Song>{
      for (final song in localSongs) song.path: song,
      for (final entry in playlist.songSnapshots.entries)
        entry.key: entry.value.toSong(),
    };
    return [
      for (final path in playlist.songPaths)
        if (songsByPath[path] != null) songsByPath[path]!,
    ];
  }
}

class _PlaylistHeroHeader extends StatelessWidget {
  const _PlaylistHeroHeader({
    required this.playlist,
    required this.songs,
    required this.onPlayAll,
    this.onSyncSource,
  });

  final MobilePlaylist playlist;
  final List<Song> songs;
  final VoidCallback? onPlayAll;

  /// 存在导入来源时的「同步来源」回调（拉取来源最新内容）。
  final VoidCallback? onSyncSource;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coverPath = playlist.songPaths.isEmpty
        ? 'playlist://${playlist.id}'
        : playlist.songPaths.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CoverImage(
            songPath: coverPath,
            imageUrl: playlist.effectiveCoverUrl,
            width: 124,
            height: 124,
            radius: 18,
            highQuality: true,
            icon: Icons.queue_music_rounded,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  playlist.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  playlist.importSources.isEmpty
                      ? '本地歌单 · ${songs.length} 首歌曲'
                      : '本地歌单 · ${songs.length} 首歌曲'
                        ' · ${playlist.importSources.length} 个来源',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: onPlayAll,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('播放全部'),
                    ),
                    if (onSyncSource != null)
                      OutlinedButton.icon(
                        onPressed: onSyncSource,
                        icon: const Icon(Icons.sync_rounded),
                        label: const Text('同步来源'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


