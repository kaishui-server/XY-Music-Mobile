import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lpinyin/lpinyin.dart';

import '../../src/favorites/favorites_provider.dart';
import '../../src/core/settings.dart';
import '../../src/library/library_provider.dart';
import '../../src/player/player_provider.dart';
import '../../src/playlists/playlist_picker_sheet.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/navigation/sidebar_controller.dart';
import '../../src/plugins/plugin_runtime.dart';
import '../../src/widgets/batch_download.dart';
import '../../src/widgets/frosted_search_field.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/source_switch.dart';
import '../../src/widgets/top_notice.dart';

/// 收藏页：展示已收藏的歌曲，点击即播放整个收藏列表。
class FavoritesPage extends ConsumerStatefulWidget {
  const FavoritesPage({super.key});

  @override
  ConsumerState<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends ConsumerState<FavoritesPage> {
  String _query = '';
  // 搜索框控制器：供一键清除按钮清空输入。
  final TextEditingController _searchController = TextEditingController();
  SongSort _sort = const SongSort(SongSortKey.custom);

  /// 悬浮头部（搜索框 + 歌曲数行）的测量 Key 与实测高度：头部悬浮于
  /// 列表上方，列表内容滚动时从毛玻璃下方穿过被模糊（与列表浮动
  /// 按钮组同款观感），列表顶部让出头部高度。
  final GlobalKey _floatingHeaderKey = GlobalKey();
  double _floatingHeaderExtent = 104;

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
  Future<List<Song>>? _songsFuture;
  int? _songsFutureKey;
  // 多选删除：勾选的收藏路径集合。
  final Set<String> _selectedPaths = <String>{};
  bool _selectionMode = false;
  bool _deleting = false;
  bool _downloading = false;
  // 批量换源进度（对齐歌单页交互）。
  bool _switchingSource = false;
  int _switchingDone = 0;
  int _switchingTotal = 0;
  // 播放器状态每秒更新一次。没有这个集合时，build 会反复安排同一批
  // SharedPreferences 写入，进入收藏页时容易出现连续卡顿。
  final Set<String> _snapshotSyncQueued = <String>{};

  /// 搜索框每输入一个字符都会触发一次 setState。缓存查询 Future，避免
  /// 因为 FutureBuilder 收到新的 Future 而重新查询歌曲、短暂显示加载页。
  Future<List<Song>> _songsForPaths(List<String> paths) {
    final key = Object.hashAll(paths);
    if (_songsFuture == null || _songsFutureKey != key) {
      _songsFutureKey = key;
      _songsFuture = ref.read(libraryProvider.notifier).songsByPaths(paths);
    }
    return _songsFuture!;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggleSelection(Song song) {
    setState(() {
      if (!_selectedPaths.add(song.path)) _selectedPaths.remove(song.path);
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedPaths.clear();
    });
  }

  /// 多选删除收藏：仅取消收藏，音乐文件不会被删除。
  Future<void> _deleteSelected() async {
    if (_deleting || _selectedPaths.isEmpty) return;
    final message = _selectedPaths.length == 1
        ? '确定取消收藏选中的 1 首歌曲吗？音乐文件不会被删除。'
        : '确定取消收藏选中的 ${_selectedPaths.length} 首歌曲吗？音乐文件不会被删除。';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消收藏'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _deleting = true);
    try {
      final removed = await ref
          .read(favoritesProvider.notifier)
          .removeAll(_selectedPaths.toList());
      if (!mounted) return;
      _exitSelection();
      XyNotice.show(
        context,
        message: removed > 0 ? '已取消收藏 $removed 首' : '所选歌曲均不在收藏中',
        type: XyNoticeType.success,
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  /// 拖拽排序回调：基于当前展示顺序重排并持久化为收藏的自定义顺序。
  /// newIndex 已是移除 oldIndex 项后的目标位置（onReorderItem 语义）。
  Future<void> _onReorder(int oldIndex, int newIndex) async {
    final paths = [for (final song in _sortedSongs) song.path];
    if (oldIndex < 0 || oldIndex >= paths.length) return;
    final path = paths.removeAt(oldIndex);
    paths.insert(newIndex.clamp(0, paths.length), path);
    await ref.read(favoritesProvider.notifier).setCustomOrder(paths);
    // customOrder 存在 notifier 私有字段里，不触发 provider 通知，
    // 需手动刷新以按新顺序重建列表。
    if (mounted) setState(() {});
  }

  /// 多选批量下载：复用歌单页共享的批量下载组件（含音质/目录弹窗）。
  Future<void> _downloadSelected() async {
    if (_downloading || _selectedPaths.isEmpty) return;
    final selected = _sortedSongs
        .where((song) => _selectedPaths.contains(song.path))
        .toList();
    if (selected.isEmpty) return;
    setState(() => _downloading = true);
    try {
      await runBatchDownload(context, ref, songs: selected);
      if (mounted) _exitSelection();
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  /// 多选批量添加到歌单：选中歌曲加入已有歌单或新建歌单。
  Future<void> _addSelectedToPlaylist() async {
    if (_selectedPaths.isEmpty) return;
    final selected = _sortedSongs
        .where((song) => _selectedPaths.contains(song.path))
        .toList();
    if (selected.isEmpty) return;
    final result = await showPlaylistPicker(
      context,
      items: [for (final song in selected) song.toQueueItem()],
    );
    if (!mounted || result == null) return;
    _exitSelection();
    final name = ref
        .read(playlistsProvider)
        .where((value) => value.id == result.playlistId)
        .firstOrNull
        ?.name;
    final parts = <String>[
      if (result.addedCount > 0)
        '已添加 ${result.addedCount} 首到歌单“$name”',
      if (result.existsCount > 0) '${result.existsCount} 首已在歌单中',
    ];
    XyNotice.show(
      context,
      message: parts.isEmpty ? '所选歌曲均已在歌单中' : parts.join('，'),
      type: result.addedCount > 0 ? XyNoticeType.success : XyNoticeType.warning,
    );
  }

  /// 多选批量换源：选择目标插件后逐首搜索同名歌曲，原位替换收藏
  ///（对齐歌单管理的换源交互）。
  Future<void> _switchSourceSelected() async {
    if (_selectedPaths.isEmpty || _switchingSource) return;
    final selected = _sortedSongs
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
            .read(favoritesProvider.notifier)
            .replacePath(
              song.path,
              FavoriteSongSnapshot.fromSong(
                replacementToSong(plugin, candidates.first),
              ),
            );
        replaced++;
      } catch (_) {
        missed.add(song.title);
      }
    }
    if (!mounted) return;
    setState(() => _switchingSource = false);
    _exitSelection();
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

  List<Song> _sortedSongs = const <Song>[];

  @override
  Widget build(BuildContext context) {
    final favPaths = ref.watch(favoritesProvider);
    final favorites = ref.read(favoritesProvider.notifier);
    final playbackQueue = ref.watch(
      playerProvider.select((state) => state.queue),
    );
    final queuedSnapshots = <String, FavoriteSongSnapshot>{
      for (final item in playbackQueue)
        if (favPaths.contains(item.path) &&
            favorites.snapshotFor(item.path) == null &&
            (item.pluginId?.isNotEmpty == true ||
                item.path.startsWith('plugin://') ||
                item.path.startsWith('lx://') ||
                item.path.startsWith('http://') ||
                item.path.startsWith('https://')))
          item.path: FavoriteSongSnapshot.fromQueueItem(item),
    };
    final snapshotsToPersist = queuedSnapshots.entries
        .where((entry) => _snapshotSyncQueued.add(entry.key))
        .map((entry) => entry.value)
        .toList(growable: false);
    if (snapshotsToPersist.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final snapshot in snapshotsToPersist) {
          favorites.rememberSnapshot(snapshot);
        }
      });
    }
    final localPaths = favPaths
        .where(
          (path) =>
              favorites.snapshotFor(path) == null &&
              !queuedSnapshots.containsKey(path),
        )
        .toList();
    final sidebarOnRight = ref.watch(
      settingsProvider.select(
        (value) => value.valueOrNull?.sidebarPosition == SidebarPosition.right,
      ),
    );

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !sidebarOnRight,
        leading: sidebarOnRight ? null : const AppSidebarMenuButton(),
        title: _selectionMode
            ? Text(
                _switchingSource
                    ? '换源中 $_switchingDone/$_switchingTotal'
                    : (_selectedPaths.isEmpty
                          ? '选择要删除的收藏'
                          : '已选 ${_selectedPaths.length} 首'),
              )
            : const Text('我的收藏'),
        actions: [
          if (sidebarOnRight) const AppSidebarMenuButton(),
          if (_selectionMode) ...[
            IconButton(
              tooltip: '添加到歌单',
              onPressed: _switchingSource || _downloading || _deleting ||
                      _selectedPaths.isEmpty
                  ? null
                  : _addSelectedToPlaylist,
              icon: const Icon(Icons.playlist_add_check_rounded),
            ),
            IconButton(
              tooltip: _switchingSource
                  ? '换源中 $_switchingDone/$_switchingTotal'
                  : '批量换源',
              onPressed: _switchingSource || _downloading || _deleting ||
                      _selectedPaths.isEmpty
                  ? null
                  : _switchSourceSelected,
              icon: _switchingSource
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.swap_horiz_rounded),
            ),
            IconButton(
              tooltip: '批量下载',
              onPressed: _downloading || _switchingSource || _deleting ||
                      _selectedPaths.isEmpty
                  ? null
                  : _downloadSelected,
              icon: _downloading
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded),
            ),
            IconButton(
              tooltip: '删除所选收藏',
              onPressed: _deleting || _switchingSource || _downloading ||
                      _selectedPaths.isEmpty
                  ? null
                  : _deleteSelected,
              icon: _deleting
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_outline_rounded),
            ),
            IconButton(
              tooltip: '取消多选',
              onPressed: _switchingSource || _downloading || _deleting
                  ? null
                  : _exitSelection,
              icon: const Icon(Icons.close_rounded),
            ),
          ] else ...[
            IconButton(
              tooltip: '多选删除',
              onPressed: favPaths.isEmpty
                  ? null
                  : () => setState(() {
                        _selectionMode = true;
                        // 多选与拖拽编辑互斥，进入多选时收起拖拽手柄。
                        _dragEditMode = false;
                        // 进入多选时清掉搜索过滤，保证全选覆盖整个收藏。
                        _query = '';
                        _searchController.clear();
                      }),
              icon: const Icon(Icons.library_add_check_rounded),
            ),
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
          ],
        ],
      ),
      body: favPaths.isEmpty
          ? const _FavoritesEmpty()
          : FutureBuilder<List<Song>>(
                // 收藏集合变化时重新查询。
                key: ValueKey(Object.hashAll(favPaths)),
                future: _songsForPaths(localPaths),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return Center(child: Text('加载失败：${snap.error}'));
                  }
                  final songsByPath = <String, Song>{
                    for (final song in snap.data ?? const <Song>[])
                      song.path: song,
                  };
                  for (final path in favPaths) {
                    final snapshot =
                        favorites.snapshotFor(path) ?? queuedSnapshots[path];
                    if (snapshot != null) {
                      songsByPath[path] = snapshot.toSong();
                    }
                  }
                  // favPaths（LinkedHashSet）的迭代顺序即收藏添加顺序。
                  final addedOrder = favPaths.toList();
                  final List<Song> songs;
                  switch (_sort.key) {
                    case SongSortKey.added:
                      final ordered =
                          _sort.descending ? addedOrder.reversed : addedOrder;
                      songs = [for (final path in ordered) ?songsByPath[path]];
                    case SongSortKey.title:
                    case SongSortKey.artist:
                    case SongSortKey.album:
                      String sortKey(Song song) => switch (_sort.key) {
                        SongSortKey.artist => _pinyinKey(song.artist),
                        SongSortKey.album => _pinyinKey(song.album),
                        _ => _pinyinKey(song.title),
                      };
                      final all = [
                        for (final path in addedOrder) ?songsByPath[path],
                      ];
                      all.sort((a, b) {
                        var result = sortKey(a).compareTo(sortKey(b));
                        if (result == 0) {
                          result = _pinyinKey(a.title)
                              .compareTo(_pinyinKey(b.title));
                        }
                        return _sort.descending ? -result : result;
                      });
                      songs = all;
                    case SongSortKey.custom:
                      final order =
                          ref.read(favoritesProvider.notifier).customOrder;
                      if (order == null || order.isEmpty) {
                        songs = [
                          for (final path in addedOrder) ?songsByPath[path],
                        ];
                      } else {
                        final rank = <String, int>{
                          for (var i = 0; i < order.length; i++) order[i]: i,
                        };
                        final known = <Song>[];
                        final appended = <Song>[];
                        for (final path in addedOrder) {
                          final song = songsByPath[path];
                          if (song == null) continue;
                          if (rank.containsKey(path)) {
                            known.add(song);
                          } else {
                            appended.add(song);
                          }
                        }
                        known.sort(
                          (a, b) => rank[a.path]!.compareTo(rank[b.path]!),
                        );
                        songs = [...known, ...appended];
                      }
                  }
                  if (songs.isEmpty) {
                    return const Center(child: Text('收藏的歌曲已不在音乐库中'));
                  }
                  final query = _query.trim().toLowerCase();
                  final filteredSongs = query.isEmpty
                      ? songs
                      : songs
                            .where((song) => _matchesQuery(song, query))
                            .toList();
                  // 供拖拽回调读取当前展示顺序。
                  _sortedSongs = filteredSongs;
                  // 布局完成后修正悬浮头部占位高度。
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _measureFloatingHeader(),
                  );
                  // 搜索框与歌曲数行悬浮于列表上方：列表内容滚动时从
                  // 毛玻璃下方穿过被模糊，与列表浮动按钮组观感一致。
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: Padding(
                          padding: EdgeInsets.only(
                            top: _selectionMode || filteredSongs.isEmpty
                                ? 0
                                : _floatingHeaderExtent,
                          ),
                          child: filteredSongs.isEmpty
                              ? Center(
                                  child: Text(
                                    '没有找到匹配的收藏歌曲',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                )
                              : SongsListView(
                                  songs: filteredSongs,
                                  // 悬浮元素遮挡高度已注入 MediaQuery.padding。
                                  padding: EdgeInsets.fromLTRB(
                                    10,
                                    0,
                                    10,
                                    MediaQuery.paddingOf(context).bottom + 12,
                                  ),
                                  selectionMode: _selectionMode,
                                  isSelected: (song) =>
                                      _selectedPaths.contains(song.path),
                                  onToggleSelection: _toggleSelection,
                                  // 搜索过滤时下标与全量收藏不一致，禁止拖拽；
                                  // 拖拽手柄仅在自定义排序的编辑模式中显示。
                                  onReorder:
                                      _sort.key == SongSortKey.custom &&
                                          _dragEditMode &&
                                          query.isEmpty
                                      ? _onReorder
                                      : null,
                                  onPlay: (list, i) => ref
                                        .read(libraryProvider.notifier)
                                        .playList(list, i),
                                ),
                        ),
                      ),
                      if (_selectionMode)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _selectedPaths.isEmpty
                                      ? '点击歌曲进行选择'
                                      : '已选 ${_selectedPaths.length} 首',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: filteredSongs.isEmpty
                                    ? null
                                    : () => setState(() {
                                          final allSelected =
                                              filteredSongs.isNotEmpty &&
                                                  _selectedPaths.length ==
                                                      filteredSongs.length;
                                          if (allSelected) {
                                            _selectedPaths.clear();
                                          } else {
                                            _selectedPaths
                                              ..clear()
                                              ..addAll(filteredSongs
                                                  .map((s) => s.path));
                                          }
                                        }),
                                child: Text(
                                  filteredSongs.isNotEmpty &&
                                          _selectedPaths.length ==
                                              filteredSongs.length
                                      ? '取消全选'
                                      : '全选',
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: KeyedSubtree(
                            key: _floatingHeaderKey,
                            child: Column(
                              children: [
                                FrostedSearchField(
                                  controller: _searchController,
                                  hintText: '搜索歌曲、歌手或专辑',
                                  onChanged: (value) =>
                                      setState(() => _query = value),
                                  showClearSuffix: true,
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    4,
                                    16,
                                    4,
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    4,
                                    16,
                                    8,
                                  ),
                                  child: Row(
                                    children: [
                                      Text(
                                        '${filteredSongs.length} 首歌曲',
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                      const Spacer(),
                                      FilledButton.tonalIcon(
                                        onPressed: filteredSongs.isEmpty
                                            ? null
                                            : () => ref
                                                  .read(
                                                    libraryProvider.notifier,
                                                  )
                                                  .playAll(filteredSongs),
                                        icon: const Icon(
                                          Icons.play_arrow,
                                          size: 20,
                                        ),
                                        label: const Text('播放全部'),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
    );
  }

  bool _matchesQuery(Song song, String query) {
    return song.title.toLowerCase().contains(query) ||
        song.artist.toLowerCase().contains(query) ||
        song.album.toLowerCase().contains(query) ||
        song.path.toLowerCase().contains(query);
  }

  String _pinyinKey(String title) =>
      PinyinHelper.getPinyinE(title.trim(), separator: ' ').toLowerCase();
}

class _FavoritesEmpty extends StatelessWidget {
  const _FavoritesEmpty();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.only(bottom: 80),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.favorite_border,
            size: 58,
            color: Theme.of(
              context,
            ).colorScheme.onSurfaceVariant.withValues(alpha: .4),
          ),
          const SizedBox(height: 14),
          const Text(
            '还没有收藏歌曲',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            '长按歌曲或点击右侧菜单即可收藏',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}
