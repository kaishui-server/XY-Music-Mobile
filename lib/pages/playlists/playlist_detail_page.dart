import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lpinyin/lpinyin.dart';

import '../../src/favorites/favorites_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/plugins/plugin_runtime.dart';
import '../../src/widgets/batch_download.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/frosted_search_field.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/source_switch.dart';
import '../../src/widgets/top_notice.dart' show XyNotice, XyNoticeType;

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
  final Set<String> _selectedPaths = <String>{};
  List<Song> _songs = const <Song>[];
  List<Song> _visibleSongs = const <Song>[];
  bool _selectionMode = false;
  bool _downloading = false;
  bool _switchingSource = false;
  int _switchingDone = 0;
  int _switchingTotal = 0;
  late final TextEditingController _searchController;
  final FocusNode _searchFocus = FocusNode();
  bool _searchMode = false;
  String _query = '';
  SongSort _sort = const SongSort(SongSortKey.custom);

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
      case SongSortKey.artist:
      case SongSortKey.album:
        String sortKey(Song song) => switch (_sort.key) {
          SongSortKey.artist => _pinyinKey(song.artist),
          SongSortKey.album => _pinyinKey(song.album),
          _ => _pinyinKey(song.title),
        };
        final sorted = [...songs]
          ..sort((a, b) {
            var result = sortKey(a).compareTo(sortKey(b));
            if (result == 0) {
              // 艺术家/专辑相同时回落到歌名，保持组内稳定。
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

  void _toggleSelection(Song song) {
    setState(() {
      if (!_selectedPaths.add(song.path)) _selectedPaths.remove(song.path);
    });
  }

  void _toggleAll() {
    final visible = _visibleSongs;
    setState(() {
      if (visible.isNotEmpty &&
          _selectedPaths.length == visible.length &&
          visible.every((song) => _selectedPaths.contains(song.path))) {
        _selectedPaths.clear();
      } else {
        _selectedPaths
          ..clear()
          ..addAll(visible.map((song) => song.path));
      }
    });
  }

  void _closeSelection() {
    setState(() {
      _selectionMode = false;
      _selectedPaths.clear();
    });
  }

  /// 多选批量移出歌单：仅移出歌单，不删除音乐文件与收藏。
  Future<void> _removeSelected() async {
    if (_selectedPaths.isEmpty) return;
    final count = _selectedPaths.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移出歌单'),
        content: Text(
          count == 1
              ? '确定将选中的 1 首歌曲移出歌单吗？\n音乐文件不会被删除。'
              : '确定将选中的 $count 首歌曲移出歌单吗？\n音乐文件不会被删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(playlistsProvider.notifier)
        .removeSongs(widget.playlistId, _selectedPaths.toList());
    if (!mounted) return;
    _closeSelection();
    XyNotice.show(context, message: '已移出 $count 首', type: XyNoticeType.success);
  }

  /// 多选一键收藏：确认后批量添加到收藏，已在收藏中的跳过。
  Future<void> _favoriteSelected() async {
    if (_selectedPaths.isEmpty) return;
    final selected = _songs
        .where((song) => _selectedPaths.contains(song.path))
        .toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加到收藏'),
        content: Text('是否将 ${selected.length} 首歌曲添加到收藏？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final added = await ref
        .read(favoritesProvider.notifier)
        .addAll(selected.map(FavoriteSongSnapshot.fromSong));
    if (!mounted) return;
    _closeSelection();
    final message = added > 0 ? '已收藏 $added 首歌曲' : '所选歌曲均已在收藏中';
    XyNotice.show(context, message: message, type: XyNoticeType.success);
  }

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
        title: _searchMode
            ? FrostedSearchField(
                controller: _searchController,
                focusNode: _searchFocus,
                autofocus: true,
                hintText: '搜索歌单中的歌曲',
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
                // 清除按钮与操作栏「取消」按钮分工：前者清文本，后者退出搜索。
                showClearSuffix: true,
                padding: EdgeInsets.zero,
              )
            : Text(
                _switchingSource
                    ? '换源中 $_switchingDone/$_switchingTotal'
                    : _selectionMode && _selectedPaths.isNotEmpty
                    ? '已选 ${_selectedPaths.length} 首'
                    : playlist.name,
              ),
        actions: [
          if (_searchMode)
            TextButton(onPressed: _exitSearch, child: const Text('取消'))
          else ...[
            // 多选操作集中在底部横排菜单（参考闲鱼音乐），AppBar 只保留
            // 退出多选、排序与搜索。
            if (_selectionMode && !_switchingSource)
              IconButton(
                tooltip: '取消多选',
                onPressed: _closeSelection,
                icon: const Icon(Icons.close_rounded),
              ),
            if (!_selectionMode)
              IconButton(
                tooltip: '多选',
                onPressed: () => setState(() => _selectionMode = true),
                icon: const Icon(Icons.library_add_check_rounded),
              ),
            SongSortMenuButton(
              sort: _sort,
              onSortChanged: (sort) => setState(() => _sort = sort),
            ),
            IconButton(
              tooltip: '搜索',
              onPressed: _enterSearch,
              icon: const Icon(Icons.search_rounded),
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
          return Column(
            children: [
              _PlaylistHeroHeader(
                playlist: playlist,
                songs: songs,
                onPlayAll: songs.isEmpty
                    ? null
                    : () => ref
                          .read(libraryProvider.notifier)
                          .playAll(_applySort(songs, playlist!)),
              ),
              if (songs.isEmpty)
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 110),
                      child: Text(
                        '歌单中暂无可用歌曲',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                )
              else if (visibleSongs.isEmpty)
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 110),
                      child: Text(
                        '未找到匹配的歌曲',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                )
              else
                Expanded(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
                      Expanded(
                        child: SongsListView(
                          songs: visibleSongs,
                          // 悬浮元素遮挡高度已注入 MediaQuery.padding；
                          // 多选时底部横排菜单自带安全区 padding，列表留 12 即可。
                          padding: EdgeInsets.fromLTRB(
                            10,
                            0,
                            10,
                            _selectionMode
                                ? 12
                                : MediaQuery.paddingOf(context).bottom + 12,
                          ),
                          selectionMode: _selectionMode,
                          isSelected: (song) =>
                              _selectedPaths.contains(song.path),
                          onToggleSelection: _toggleSelection,
                          // 搜索过滤时下标与歌单全量不一致，禁止拖拽。
                          onReorder:
                              _sort.key == SongSortKey.custom && query.isEmpty
                              ? _onReorder
                              : null,
                          onPlay: (list, index) => ref
                              .read(libraryProvider.notifier)
                              .playList(list, index),
                        ),
                      ),
                    ],
                  ),
                ),
              // 多选底部横排菜单（参考闲鱼音乐）：全选/收藏/下载/换源/移出。
              // 底部 padding 取注入后的 MediaQuery（系统安全区+自定义底栏
              // 与迷你播放栏的遮挡高度），保证不被悬浮元素盖住。
              if (_selectionMode)
                _SelectionBottomBar(
                  allSelected: visibleSongs.isNotEmpty &&
                      _selectedPaths.length == visibleSongs.length &&
                      visibleSongs.every(
                        (song) => _selectedPaths.contains(song.path),
                      ),
                  hasSelection: _selectedPaths.isNotEmpty,
                  busy: _downloading || _switchingSource,
                  downloading: _downloading,
                  switchingSource: _switchingSource,
                  switchProgress: '$_switchingDone/$_switchingTotal',
                  onToggleAll: _toggleAll,
                  onFavorite: _favoriteSelected,
                  onDownload: _downloadSelected,
                  onSwitchSource: _switchSourceSelected,
                  onRemove: _removeSelected,
                ),
            ],
          );
        },
      ),
    );
  }

  /// 多选批量换源：选择目标插件后逐首搜索同名歌曲，原位替换歌单歌曲。
  Future<void> _switchSourceSelected() async {
    if (_selectedPaths.isEmpty || _switchingSource) return;
    final selected = _songs
        .where((song) => _selectedPaths.contains(song.path))
        .toList();
    if (selected.isEmpty) return;
    final plugins = await ref.read(enabledMusicPluginsProvider.future);
    if (!mounted) return;
    if (plugins.isEmpty) {
      XyNotice.show(
        context,
        message: '请先在 设置 → 插件 中启用插件',
        type: XyNoticeType.warning,
      );
      return;
    }
    final plugin = await showSourcePluginPicker(context, plugins);
    if (plugin == null || !mounted) return;
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
    _closeSelection();
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

  Future<void> _downloadSelected() async {
    if (_downloading || _selectedPaths.isEmpty) return;
    final selected = _songs
        .where((song) => _selectedPaths.contains(song.path))
        .toList();
    setState(() => _downloading = true);
    try {
      await runBatchDownload(context, ref, songs: selected);
      if (mounted) _closeSelection();
    } finally {
      if (mounted) setState(() => _downloading = false);
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
  });

  final MobilePlaylist playlist;
  final List<Song> songs;
  final VoidCallback? onPlayAll;

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
                  '本地歌单 · ${songs.length} 首歌曲',
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

/// 收藏按钮图标：空心心形 + 右下角加号，表达“添加到收藏”。
class _FavoriteAddIcon extends StatelessWidget {
  const _FavoriteAddIcon();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      height: 24,
      child: Stack(
        clipBehavior: Clip.none,
        children: const [
          Align(
            alignment: Alignment.center,
            child: Icon(Icons.favorite_border_rounded, size: 22),
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: Icon(Icons.add_circle_rounded, size: 13),
          ),
        ],
      ),
    );
  }
}

/// 多选模式的底部横排图标菜单（参考闲鱼音乐）：全选 / 收藏 / 下载 /
/// 换源 / 移出。批量操作进行中时对应按钮显示进度并禁用其余操作。
class _SelectionBottomBar extends StatelessWidget {
  const _SelectionBottomBar({
    required this.allSelected,
    required this.hasSelection,
    required this.busy,
    required this.downloading,
    required this.switchingSource,
    required this.switchProgress,
    required this.onToggleAll,
    required this.onFavorite,
    required this.onDownload,
    required this.onSwitchSource,
    required this.onRemove,
  });

  final bool allSelected;
  final bool hasSelection;
  final bool busy;
  final bool downloading;
  final bool switchingSource;
  final String switchProgress;
  final VoidCallback onToggleAll;
  final VoidCallback onFavorite;
  final VoidCallback onDownload;
  final VoidCallback onSwitchSource;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget item({
      required Widget icon,
      required String label,
      required VoidCallback? onTap,
    }) {
      final enabled = onTap != null;
      return Expanded(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 26,
                  child: Center(
                    child: IconTheme.merge(
                      data: IconThemeData(
                        size: 23,
                        color: enabled
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant.withValues(alpha: .45),
                      ),
                      child: icon,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: enabled
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant.withValues(alpha: .45),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        // Shell 已把自定义底栏+迷你播放栏的遮挡高度注入 MediaQuery.padding，
        // SafeArea 据此把菜单抬到悬浮元素之上。
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
          child: Row(
            children: [
              item(
                icon: Icon(
                  allSelected
                      ? Icons.deselect_rounded
                      : Icons.select_all_rounded,
                ),
                label: allSelected ? '取消全选' : '全选',
                onTap: busy ? null : onToggleAll,
              ),
              item(
                icon: const _FavoriteAddIcon(),
                label: '收藏',
                onTap: busy || !hasSelection ? null : onFavorite,
              ),
              item(
                icon: downloading
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_rounded),
                label: downloading ? '下载中' : '下载',
                onTap: busy || !hasSelection ? null : onDownload,
              ),
              item(
                icon: switchingSource
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.swap_horiz_rounded),
                label: switchingSource ? switchProgress : '换源',
                onTap: busy || !hasSelection ? null : onSwitchSource,
              ),
              item(
                icon: const Icon(Icons.delete_outline_rounded),
                label: '移出',
                onTap: busy || !hasSelection ? null : onRemove,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
