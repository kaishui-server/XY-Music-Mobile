import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lpinyin/lpinyin.dart';

import '../../src/core/settings.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/library/native_storage_permission.dart';
import '../../src/library/scan_settings_provider.dart';
import '../../src/navigation/sidebar_controller.dart';
import '../../src/player/player_provider.dart';
import '../../src/playlists/playlist_import_actions.dart';
import '../../src/playlists/playlist_picker_sheet.dart';
import '../../src/playlists/playlist_sync.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/plugins/plugin_runtime.dart';
import '../../src/recent/recent_provider.dart';
import '../../src/rust/api.dart';
import '../../src/ui/xy_surface.dart';
import '../../src/widgets/batch_download.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/frosted_search_field.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/source_switch.dart';
import '../../src/widgets/top_notice.dart';
import 'folder_browser_page.dart';

/// 音乐库：收藏 / 歌单 / 本地音乐 / 最近播放 / 播放列表 / 文件夹
/// 的统一分页入口。单一 AppBar，右上角按钮随当前分页切换；
/// 各分页的搜索 / 排序 / 多选状态统一提升到本 State，切页不丢失。
class MusicLibraryPage extends ConsumerStatefulWidget {
  const MusicLibraryPage({super.key});

  @override
  ConsumerState<MusicLibraryPage> createState() => _MusicLibraryPageState();
}

class _MusicLibraryPageState extends ConsumerState<MusicLibraryPage>
    with TickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 6,
    vsync: this,
  );

  /// 本地音乐分页的子分页控制器：歌曲 / 歌手 / 专辑。
  late final TabController _localTabController = TabController(
    length: 3,
    vsync: this,
  );

  static const _tabs = ['收藏', '歌单', '本地音乐', '文件夹', '最近播放', '播放列表'];

  // ---- 收藏分页状态 ----
  String _favQuery = '';
  final TextEditingController _favSearchController = TextEditingController();
  final FocusNode _favSearchFocus = FocusNode();
  bool _favSearchMode = false;
  SongSort _favSort = const SongSort(SongSortKey.custom);

  /// 自定义排序的拖拽编辑模式：已是自定义排序时再次点击「自定义」
  /// 进入，列表行首显示拖拽手柄；点击「完成」退出，手柄消失。
  bool _favDragEditMode = false;

  Future<List<Song>>? _favSongsFuture;
  int? _favSongsFutureKey;
  List<Song> _favSortedSongs = const <Song>[];

  final Set<String> _favSelectedPaths = <String>{};
  bool _favSelectionMode = false;
  bool _favDeleting = false;
  bool _favDownloading = false;
  // 批量换源进度。
  bool _favSwitchingSource = false;
  int _favSwitchingDone = 0;
  int _favSwitchingTotal = 0;

  /// 播放器状态每秒更新一次。没有这个集合时，build 会反复安排同一批
  /// SharedPreferences 写入，进入收藏页时容易出现连续卡顿。
  final Set<String> _snapshotSyncQueued = <String>{};

  /// 悬浮头部（搜索框 + 歌曲数行）与多选提示行的测量 Key 与实测高度：
  /// 二者悬浮于列表上方，列表内容滚动时从毛玻璃下方穿过被模糊，
  /// 列表顶部让出对应高度，避免第一行歌曲被盖住。
  final GlobalKey _favFloatingHeaderKey = GlobalKey();
  double _favFloatingHeaderExtent = 104;
  final GlobalKey _favSelectionBarKey = GlobalKey();
  double _favSelectionBarExtent = 56;

  // ---- 歌单分页状态 ----
  bool _playlistSelectionMode = false;
  final Set<String> _playlistSelectedIds = <String>{};

  // ---- 本地音乐分页状态 ----
  final Set<String> _localSelectedPaths = <String>{};
  bool _localSelectionMode = false;
  bool _localDeleting = false;

  /// 歌曲子分页的排序：custom 表示曲库原始顺序（扫描序），其余键
  /// 按拼音排序；歌手 / 专辑子分页固定按拼音分组，不参与排序。
  SongSort _localSort = const SongSort(SongSortKey.custom);

  /// 曲库重扫进行中（本地音乐 / 文件夹分页共用的刷新按钮状态）。
  bool _libraryScanning = false;

  /// 添加扫描目录进行中（文件夹分页右上角按钮）。
  bool _addingFolder = false;

  // ---- 最近播放分页状态 ----
  bool _recentSearchMode = false;
  String _recentQuery = '';
  final TextEditingController _recentSearchController = TextEditingController();
  final FocusNode _recentSearchFocus = FocusNode();

  // ---- 文件夹分页状态 ----
  bool _folderSearchMode = false;
  String _folderQuery = '';
  final TextEditingController _folderSearchController = TextEditingController();
  final FocusNode _folderSearchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _tabController.addListener(_onTabChanged);
    _localTabController.addListener(_onTabChanged);
  }

  /// 上一次的分页索引：TabController 的监听在切换动画期间每帧都会触发，
  /// 若每帧都 setState，会让整页（含 6 个分页的构建）在动画期间反复重建，
  /// 这是分页切换卡顿的主因。仅在索引真正变化时刷新一次。
  int _lastTabIndex = 0;
  int _lastLocalTabIndex = 0;

  void _onTabChanged() {
    final changed = _tabController.index != _lastTabIndex ||
        _localTabController.index != _lastLocalTabIndex;
    if (!changed) return;
    _lastTabIndex = _tabController.index;
    _lastLocalTabIndex = _localTabController.index;
    // 切换分页（含本地音乐子分页）时重建 AppBar（右上角按钮跟随变化）。
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _localTabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _localTabController.dispose();
    _favSearchController.dispose();
    _favSearchFocus.dispose();
    _recentSearchController.dispose();
    _recentSearchFocus.dispose();
    _folderSearchController.dispose();
    _folderSearchFocus.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    XyNotice.show(context, message: message, duration: const Duration(seconds: 2));
  }

  String _pinyinKey(String text) =>
      PinyinHelper.getPinyinE(text.trim(), separator: ' ').toLowerCase();

  bool _matchesSongQuery(Song song, String query) {
    return song.title.toLowerCase().contains(query) ||
        song.artist.toLowerCase().contains(query) ||
        song.album.toLowerCase().contains(query);
  }

  // ==========================================================================
  // AppBar：标题与右上角按钮随当前分页切换。
  // ==========================================================================

  String get _appBarTitle {
    switch (_tabController.index) {
      case 0:
        if (_favSelectionMode) {
          if (_favSwitchingSource) return '换源中 $_favSwitchingDone/$_favSwitchingTotal';
          return _favSelectedPaths.isEmpty ? '选择歌曲' : '已选 ${_favSelectedPaths.length} 首';
        }
      case 1:
        if (_playlistSelectionMode) return '已选 ${_playlistSelectedIds.length} 个歌单';
      case 2:
        if (_localSelectionMode) return '已选 ${_localSelectedPaths.length} 首';
    }
    return '音乐库';
  }

  List<Widget> _buildAppBarActions() {
    switch (_tabController.index) {
      case 0:
        // 收藏：搜索 / 多选 / 排序（与歌单详情页同款）。
        if (_favSearchMode) {
          return [
            TextButton(onPressed: _exitFavSearch, child: const Text('取消')),
          ];
        }
        if (_favSelectionMode) {
          return [
            IconButton(
              tooltip: '取消多选',
              onPressed: _favSwitchingSource || _favDownloading || _favDeleting
                  ? null
                  : _favExitSelection,
              icon: const Icon(Icons.close_rounded),
            ),
          ];
        }
        final favEmpty = ref.read(favoritesProvider).isEmpty;
        return [
          IconButton(
            tooltip: '多选',
            onPressed: favEmpty ? null : _enterFavSelection,
            icon: const Icon(Icons.library_add_check_rounded),
          ),
          if (_favDragEditMode)
            // 拖拽编辑模式：点击「完成」收起拖拽手柄。
            TextButton(
              onPressed: () => setState(() => _favDragEditMode = false),
              child: const Text('完成'),
            )
          else
            SongSortMenuButton(
              sort: _favSort,
              onSortChanged: (sort) {
                setState(() {
                  // 已处于自定义排序时再次点击「自定义」：
                  // 进入/退出拖拽编辑模式（手柄随之显隐）。
                  if (sort.key == SongSortKey.custom &&
                      _favSort.key == SongSortKey.custom) {
                    _favDragEditMode = !_favDragEditMode;
                  } else {
                    _favSort = sort;
                    _favDragEditMode = false;
                  }
                });
              },
            ),
          IconButton(
            tooltip: '搜索',
            onPressed: _enterFavSearch,
            icon: const Icon(Icons.search_rounded),
          ),
        ];
      case 1:
        // 歌单：多选（批量清空/删除）+ 导入。
        if (_playlistSelectionMode) {
          return [
            IconButton(
              tooltip: '全选',
              onPressed: () => _selectAllPlaylists(),
              icon: const Icon(Icons.select_all_rounded),
            ),
            IconButton(
              tooltip: '删除所选歌单',
              onPressed: _playlistSelectedIds.isEmpty
                  ? null
                  : () => _deleteSelectedPlaylists(),
              icon: const Icon(Icons.delete_outline_rounded),
            ),
            IconButton(
              tooltip: '取消多选',
              onPressed: _leavePlaylistSelection,
              icon: const Icon(Icons.close_rounded),
            ),
          ];
        }
        return [
          IconButton(
            tooltip: '多选',
            onPressed: ref.read(playlistsProvider).isEmpty
                ? null
                : () => setState(() => _playlistSelectionMode = true),
            icon: const Icon(Icons.checklist_rounded),
          ),
          IconButton(
            tooltip: '导入歌单',
            onPressed: () => showPlaylistImportOptions(context, ref),
            icon: const Icon(Icons.download_rounded),
          ),
        ];
      case 2:
        // 本地音乐：多选（仅歌曲子分页）+ 刷新。
        if (_localSelectionMode) {
          return [
            IconButton(
              tooltip: '取消多选',
              onPressed: _localExitSelection,
              icon: const Icon(Icons.close_rounded),
            ),
          ];
        }
        return [
          // 排序仅对歌曲子分页生效（歌手/专辑子分页固定拼音分组）。
          SongSortMenuButton(
            sort: _localSort,
            onSortChanged: (sort) => setState(() => _localSort = sort),
          ),
          IconButton(
            tooltip: '多选',
            onPressed: _localTabController.index == 0 &&
                    ref.read(libraryProvider).songs.isNotEmpty
                ? _enterLocalSelection
                : null,
            icon: const Icon(Icons.library_add_check_rounded),
          ),
          IconButton(
            tooltip: _libraryScanning ? '扫描中...' : '刷新本地曲库',
            onPressed: _libraryScanning ? null : _refreshLibrary,
            icon: _libraryScanning
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ];
      case 3:
        // 文件夹：扫描目录 + 搜索 + 刷新。
        if (_folderSearchMode) {
          return [
            TextButton(onPressed: _exitFolderSearch, child: const Text('取消')),
          ];
        }
        return [
          IconButton(
            tooltip: _addingFolder ? '添加中...' : '扫描目录',
            onPressed: _addingFolder ? null : _addScanFolder,
            icon: _addingFolder
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.create_new_folder_outlined),
          ),
          IconButton(
            tooltip: '搜索',
            onPressed: _enterFolderSearch,
            icon: const Icon(Icons.search_rounded),
          ),
          IconButton(
            tooltip: _libraryScanning ? '扫描中...' : '刷新',
            onPressed: _libraryScanning ? null : _refreshLibrary,
            icon: _libraryScanning
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ];
      case 4:
        // 最近播放：搜索 + 清空。
        if (_recentSearchMode) {
          return [
            TextButton(onPressed: _exitRecentSearch, child: const Text('取消')),
          ];
        }
        final hasRecent =
            (ref.read(recentSongsProvider).valueOrNull ?? const []).isNotEmpty;
        return [
          IconButton(
            tooltip: '搜索',
            onPressed: _enterRecentSearch,
            icon: const Icon(Icons.search_rounded),
          ),
          IconButton(
            tooltip: '清空最近播放',
            onPressed: hasRecent ? _clearRecent : null,
            icon: const Icon(Icons.delete_sweep_rounded),
          ),
        ];
      default:
        // 播放列表分页暂无附加按钮。
        return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final sidebarOnRight = ref.watch(
      settingsProvider.select(
        (value) => value.valueOrNull?.sidebarPosition == SidebarPosition.right,
      ),
    );
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !sidebarOnRight,
        leading: sidebarOnRight ? null : const AppSidebarMenuButton(),
        title: Text(_appBarTitle),
        actions: [
          ..._buildAppBarActions(),
          if (sidebarOnRight) const AppSidebarMenuButton(),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelStyle: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
          unselectedLabelStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
          tabs: [
            for (final tab in _tabs) Tab(text: tab, height: 54),
          ],
        ),
      ),
      body: XyPageBackground(
        child: TabBarView(
          controller: _tabController,
          children: [
            _buildFavoritesTab(context),
            _buildPlaylistsTab(context),
            _buildLocalTab(context),
            _buildFoldersTab(context),
            _buildRecentTab(context),
            _buildQueueTab(context),
          ],
        ),
      ),
    );
  }

  // ==========================================================================
  // 收藏分页（与歌单详情页同款的多选 / 排序 / 搜索，多选操作集中在
  // 底部横排菜单）。
  // ==========================================================================

  void _enterFavSearch() {
    setState(() => _favSearchMode = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _favSearchFocus.requestFocus();
    });
  }

  void _exitFavSearch() {
    _favSearchFocus.unfocus();
    setState(() {
      _favSearchMode = false;
      _favQuery = '';
      _favSearchController.clear();
    });
  }

  void _enterFavSelection() {
    setState(() {
      _favSelectionMode = true;
      // 多选与拖拽编辑互斥，进入多选时收起拖拽手柄。
      _favDragEditMode = false;
      // 进入多选时清掉搜索过滤，保证全选覆盖整个收藏。
      _favSearchMode = false;
      _favQuery = '';
      _favSearchController.clear();
      _favSearchFocus.unfocus();
    });
  }

  void _favExitSelection() {
    setState(() {
      _favSelectionMode = false;
      _favSelectedPaths.clear();
    });
  }

  void _favToggleSelection(Song song) {
    setState(() {
      if (!_favSelectedPaths.add(song.path)) _favSelectedPaths.remove(song.path);
    });
  }

  void _favToggleAll() {
    final visible = _favSortedSongs;
    setState(() {
      final allSelected = visible.isNotEmpty &&
          _favSelectedPaths.length == visible.length &&
          visible.every((song) => _favSelectedPaths.contains(song.path));
      if (allSelected) {
        _favSelectedPaths.clear();
      } else {
        _favSelectedPaths
          ..clear()
          ..addAll(visible.map((song) => song.path));
      }
    });
  }

  /// 布局完成后用真实高度修正悬浮头部/提示行占位，字体缩放等场景自适应。
  void _measureFavHeaders() {
    if (!mounted) return;
    final size = _favFloatingHeaderKey.currentContext?.size;
    if (size != null &&
        size.height > 0 &&
        (size.height - _favFloatingHeaderExtent).abs() > 0.5) {
      setState(() => _favFloatingHeaderExtent = size.height);
    }
    final selectionSize = _favSelectionBarKey.currentContext?.size;
    if (selectionSize != null &&
        selectionSize.height > 0 &&
        (selectionSize.height - _favSelectionBarExtent).abs() > 0.5) {
      setState(() => _favSelectionBarExtent = selectionSize.height);
    }
  }

  /// 搜索框每输入一个字符都会触发一次 setState。缓存查询 Future，避免
  /// FutureBuilder 收到新 Future 而重复查询、短暂显示加载页。
  Future<List<Song>> _favSongsForPaths(List<String> paths) {
    final key = Object.hashAll(paths);
    if (_favSongsFuture == null || _favSongsFutureKey != key) {
      _favSongsFutureKey = key;
      _favSongsFuture = ref.read(libraryProvider.notifier).songsByPaths(paths);
    }
    return _favSongsFuture!;
  }

  /// 拖拽排序回调：基于当前展示顺序重排并持久化为收藏的自定义顺序。
  /// newIndex 已是移除 oldIndex 项后的目标位置（onReorderItem 语义）。
  Future<void> _favOnReorder(int oldIndex, int newIndex) async {
    final paths = [for (final song in _favSortedSongs) song.path];
    if (oldIndex < 0 || oldIndex >= paths.length) return;
    final path = paths.removeAt(oldIndex);
    paths.insert(newIndex.clamp(0, paths.length), path);
    await ref.read(favoritesProvider.notifier).setCustomOrder(paths);
    // customOrder 存在 notifier 私有字段里，不触发 provider 通知，
    // 需手动刷新以按新顺序重建列表。
    if (mounted) setState(() {});
  }

  /// 按当前排序方式整理收藏歌曲。时间排序基于收藏的添加顺序，
  /// 歌名/艺术家/专辑排序使用拼音避免中文乱序，自定义排序优先使用
  /// 拖拽保存的 customOrder，未记录过的新歌按添加顺序追加在末尾。
  List<Song> _applyFavSort(Map<String, Song> songsByPath, List<String> addedOrder) {
    switch (_favSort.key) {
      case SongSortKey.added:
        final ordered = _favSort.descending
            ? addedOrder.reversed
            : addedOrder;
        return [for (final path in ordered) ?songsByPath[path]];
      case SongSortKey.title:
      case SongSortKey.artist:
      case SongSortKey.album:
        String sortKey(Song song) => switch (_favSort.key) {
          SongSortKey.artist => _pinyinKey(song.artist),
          SongSortKey.album => _pinyinKey(song.album),
          _ => _pinyinKey(song.title),
        };
        final all = [for (final path in addedOrder) ?songsByPath[path]];
        all.sort((a, b) {
          var result = sortKey(a).compareTo(sortKey(b));
          if (result == 0) {
            result = _pinyinKey(a.title).compareTo(_pinyinKey(b.title));
          }
          return _favSort.descending ? -result : result;
        });
        return all;
      case SongSortKey.custom:
        final order = ref.read(favoritesProvider.notifier).customOrder;
        if (order == null || order.isEmpty) {
          return [for (final path in addedOrder) ?songsByPath[path]];
        }
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
        known.sort((a, b) => rank[a.path]!.compareTo(rank[b.path]!));
        return [...known, ...appended];
    }
  }

  /// 多选取消收藏：仅取消收藏，音乐文件不会被删除。
  Future<void> _favDeleteSelected() async {
    if (_favDeleting || _favSelectedPaths.isEmpty) return;
    final count = _favSelectedPaths.length;
    final message = count == 1
        ? '确定取消收藏选中的 1 首歌曲吗？音乐文件不会被删除。'
        : '确定取消收藏选中的 $count 首歌曲吗？音乐文件不会被删除。';
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
            child: const Text('取消收藏'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _favDeleting = true);
    try {
      final removed = await ref
          .read(favoritesProvider.notifier)
          .removeAll(_favSelectedPaths.toList());
      if (!mounted) return;
      _favExitSelection();
      XyNotice.show(
        context,
        message: removed > 0 ? '已取消收藏 $removed 首' : '所选歌曲均不在收藏中',
        type: XyNoticeType.success,
      );
    } finally {
      if (mounted) setState(() => _favDeleting = false);
    }
  }

  /// 多选批量下载：复用歌单页共享的批量下载组件（含音质/目录弹窗）。
  Future<void> _favDownloadSelected() async {
    if (_favDownloading || _favSelectedPaths.isEmpty) return;
    final selected = _favSortedSongs
        .where((song) => _favSelectedPaths.contains(song.path))
        .toList();
    if (selected.isEmpty) return;
    setState(() => _favDownloading = true);
    try {
      await runBatchDownload(context, ref, songs: selected);
      if (mounted) _favExitSelection();
    } finally {
      if (mounted) setState(() => _favDownloading = false);
    }
  }

  /// 多选批量添加到歌单：选中歌曲加入已有歌单或新建歌单。
  Future<void> _favAddSelectedToPlaylist() async {
    if (_favSelectedPaths.isEmpty) return;
    final selected = _favSortedSongs
        .where((song) => _favSelectedPaths.contains(song.path))
        .toList();
    if (selected.isEmpty) return;
    final result = await showPlaylistPicker(
      context,
      items: [for (final song in selected) song.toQueueItem()],
    );
    if (!mounted || result == null) return;
    _favExitSelection();
    final name = ref
        .read(playlistsProvider)
        .where((value) => value.id == result.playlistId)
        .firstOrNull
        ?.name;
    final parts = <String>[
      if (result.addedCount > 0) '已添加 ${result.addedCount} 首到歌单“$name”',
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
  Future<void> _favSwitchSourceSelected() async {
    if (_favSelectedPaths.isEmpty || _favSwitchingSource) return;
    final selected = _favSortedSongs
        .where((song) => _favSelectedPaths.contains(song.path))
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
    final picked = await showSourcePluginPicker(context, plugins);
    if (picked == null || !mounted) return;
    final (plugin, lxSource) = picked;
    setState(() {
      _favSwitchingSource = true;
      _favSwitchingDone = 0;
      _favSwitchingTotal = selected.length;
    });
    var replaced = 0;
    final missed = <String>[];
    for (final song in selected) {
      if (!mounted) return;
      setState(() => _favSwitchingDone++);
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
    setState(() => _favSwitchingSource = false);
    _favExitSelection();
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
                      color: Theme.of(
                        dialogContext,
                      ).colorScheme.onSurfaceVariant,
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

  Widget _buildFavoritesTab(BuildContext context) {
    final favPaths = ref.watch(favoritesProvider);
    if (favPaths.isEmpty) {
      return const _EmptyHint('还没有收藏歌曲\n长按歌曲或点击右侧菜单即可收藏');
    }
    final favorites = ref.read(favoritesProvider.notifier);
    // 播放队列里已收藏的网络歌曲回写快照：跨重启后收藏仍可播放。
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
    return FutureBuilder<List<Song>>(
      key: ValueKey(Object.hashAll(favPaths)),
      future: _favSongsForPaths(localPaths),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _EmptyHint('加载失败：${snap.error}');
        }
        final songsByPath = <String, Song>{
          for (final song in snap.data ?? const <Song>[]) song.path: song,
        };
        for (final path in favPaths) {
          final snapshot =
              favorites.snapshotFor(path) ?? queuedSnapshots[path];
          if (snapshot != null) songsByPath[path] = snapshot.toSong();
        }
        // favPaths（LinkedHashSet）的迭代顺序即收藏添加顺序。
        final addedOrder = favPaths.toList();
        final songs = _applyFavSort(songsByPath, addedOrder);
        if (songs.isEmpty) {
          return const _EmptyHint('收藏的歌曲已不在音乐库中');
        }
        final query = _favQuery.trim().toLowerCase();
        final filteredSongs = query.isEmpty
            ? songs
            : songs
                  .where((song) => _matchesSongQuery(song, query))
                  .toList();
        // 供拖拽回调与多选操作读取当前展示顺序。
        _favSortedSongs = filteredSongs;
        // 布局完成后修正悬浮头部占位高度。
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _measureFavHeaders(),
        );
        final favBusy =
            _favDeleting || _favDownloading || _favSwitchingSource;
        final allFavSelected = filteredSongs.isNotEmpty &&
            _favSelectedPaths.length == filteredSongs.length &&
            filteredSongs.every((s) => _favSelectedPaths.contains(s.path));
        return Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Padding(
                      // 多选时列表顶部让出提示行高度，避免第一行歌曲
                      // 被悬浮的「已选 N 首」提示行盖住。
                      padding: EdgeInsets.only(
                        top: _favSelectionMode
                            ? _favSelectionBarExtent
                            : _favFloatingHeaderExtent,
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
                              padding: EdgeInsets.fromLTRB(
                                10,
                                0,
                                10,
                                _favSelectionMode
                                    ? 12
                                    : MediaQuery.paddingOf(context).bottom + 12,
                              ),
                              selectionMode: _favSelectionMode,
                              isSelected: (song) =>
                                  _favSelectedPaths.contains(song.path),
                              onToggleSelection: _favToggleSelection,
                              // 搜索过滤时下标与全量收藏不一致，禁止拖拽；
                              // 拖拽手柄仅在自定义排序的编辑模式中显示。
                              onReorder:
                                  _favSort.key == SongSortKey.custom &&
                                      _favDragEditMode &&
                                      query.isEmpty
                                  ? _favOnReorder
                                  : null,
                              onPlay: (list, i) => ref
                                  .read(libraryProvider.notifier)
                                  .playList(list, i),
                            ),
                    ),
                  ),
                  // 提示行必须 Positioned 定位：若作为非 Positioned 子项，
                  // 松约束下 Stack 会 shrink-wrap 到提示行高度，
                  // Positioned.fill 的列表随之被钳制，歌曲全部消失。
                  if (_favSelectionMode)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: KeyedSubtree(
                        key: _favSelectionBarKey,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _favSelectedPaths.isEmpty
                                      ? '点击歌曲进行选择'
                                      : '已选 ${_favSelectedPaths.length} 首',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: filteredSongs.isEmpty
                                    ? null
                                    : _favToggleAll,
                                child: Text(allFavSelected ? '取消全选' : '全选'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: KeyedSubtree(
                        key: _favFloatingHeaderKey,
                        child: Column(
                          children: [
                            if (_favSearchMode)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                                child: FrostedSearchField(
                                  controller: _favSearchController,
                                  focusNode: _favSearchFocus,
                                  hintText: '搜索歌曲、歌手或专辑',
                                  onChanged: (value) =>
                                      setState(() => _favQuery = value),
                                  showClearSuffix: true,
                                  padding: EdgeInsets.zero,
                                ),
                              ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                              child: Row(
                                children: [
                                  Text(
                                    query.isEmpty
                                        ? '${filteredSongs.length} 首歌曲'
                                        : '${filteredSongs.length} / ${songs.length} 首歌曲',
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
                                              .read(libraryProvider.notifier)
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
              ),
            ),
            // 多选底部横排菜单（与歌单详情页同款）：
            // 全选 / 加歌单 / 下载 / 换源 / 取消收藏。
            if (_favSelectionMode)
              _SelectionBottomBar(
                actions: [
                  _SelectionAction(
                    icon: Icon(
                      allFavSelected
                          ? Icons.deselect_rounded
                          : Icons.select_all_rounded,
                    ),
                    label: allFavSelected ? '取消全选' : '全选',
                    onTap: favBusy ? null : _favToggleAll,
                  ),
                  _SelectionAction(
                    icon: const Icon(Icons.playlist_add_check_rounded),
                    label: '加歌单',
                    onTap: favBusy || _favSelectedPaths.isEmpty
                        ? null
                        : _favAddSelectedToPlaylist,
                  ),
                  _SelectionAction(
                    icon: _favDownloading
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_rounded),
                    label: _favDownloading ? '下载中' : '下载',
                    onTap: favBusy || _favSelectedPaths.isEmpty
                        ? null
                        : _favDownloadSelected,
                  ),
                  _SelectionAction(
                    icon: _favSwitchingSource
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.swap_horiz_rounded),
                    label: _favSwitchingSource
                        ? '$_favSwitchingDone/$_favSwitchingTotal'
                        : '换源',
                    onTap: favBusy || _favSelectedPaths.isEmpty
                        ? null
                        : _favSwitchSourceSelected,
                  ),
                  _SelectionAction(
                    icon: _favDeleting
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.favorite_border_rounded),
                    label: '取消收藏',
                    onTap: favBusy || _favSelectedPaths.isEmpty
                        ? null
                        : _favDeleteSelected,
                  ),
                ],
              ),
          ],
        );
      },
    );
  }

  // ==========================================================================
  // 歌单分页：歌单卡片列表 + 多选批量删除（清空）。
  // ==========================================================================

  void _togglePlaylistSelection(String id) {
    setState(() {
      if (!_playlistSelectedIds.add(id)) _playlistSelectedIds.remove(id);
    });
  }

  void _enterPlaylistSelection(String id) {
    setState(() {
      _playlistSelectionMode = true;
      _playlistSelectedIds.add(id);
    });
  }

  void _leavePlaylistSelection() {
    setState(() {
      _playlistSelectionMode = false;
      _playlistSelectedIds.clear();
    });
  }

  void _selectAllPlaylists() {
    final playlists = ref.read(playlistsProvider);
    setState(() {
      _playlistSelectedIds
        ..clear()
        ..addAll(playlists.map((playlist) => playlist.id));
    });
  }

  /// 多选批量删除歌单（清空所选）：歌曲文件不会被删除。
  Future<void> _deleteSelectedPlaylists() async {
    final count = _playlistSelectedIds.length;
    if (count == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: const Text('批量删除歌单'),
        content: Text('确定删除选中的 $count 个歌单吗？歌曲文件不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(playlistsProvider.notifier).deleteMany(_playlistSelectedIds);
    if (!mounted) return;
    _leavePlaylistSelection();
  }

  Widget _buildPlaylistsTab(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);
    if (playlists.isEmpty) {
      return const _EmptyHint('还没有歌单\n在探索页或本地音乐中长按歌曲即可创建');
    }
    return Column(
      children: [
        _TabHeaderBar(
          countLabel: '${playlists.length} 个歌单',
          onPlayAll: () => _playAllPlaylists(),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 24),
            itemCount: playlists.length,
            itemBuilder: (context, index) =>
                _buildPlaylistTile(context, playlists[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildPlaylistTile(BuildContext context, MobilePlaylist playlist) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: XyPanel(
        padding: EdgeInsets.zero,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 6,
          ),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_playlistSelectionMode)
                Checkbox(
                  value: _playlistSelectedIds.contains(playlist.id),
                  onChanged: (_) => _togglePlaylistSelection(playlist.id),
                ),
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(13),
                ),
                clipBehavior: Clip.antiAlias,
                child: playlist.songPaths.isNotEmpty
                    ? CoverImage(
                        songPath: playlist.songPaths.first,
                        imageUrl: playlist.effectiveCoverUrl,
                        width: 48,
                        height: 48,
                        radius: 0,
                        icon: Icons.queue_music_rounded,
                      )
                    : Icon(
                        Icons.queue_music_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      ),
              ),
            ],
          ),
          title: Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            playlist.importSources.isEmpty
                ? '${playlist.songPaths.length} 首歌曲'
                : '${playlist.songPaths.length} 首歌曲'
                      ' · ${playlist.importSources.length} 个来源',
          ),
          trailing: _playlistSelectionMode
              ? null
              : PopupMenuButton<String>(
                  tooltip: '更多',
                  onSelected: (action) {
                    switch (action) {
                      case 'sync':
                        syncPlaylistWithNotice(context, ref, playlist);
                      case 'rename':
                        renamePlaylistWithDialog(context, ref, playlist);
                      case 'delete':
                        deletePlaylistWithDialog(context, ref, playlist);
                      case 'export':
                        exportXyPlaylistFile(context, ref, playlist);
                    }
                  },
                  itemBuilder: (context) => [
                    if (playlist.importSources.isNotEmpty)
                      const PopupMenuItem(
                        value: 'sync',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.sync_rounded),
                          title: Text('同步来源'),
                        ),
                      ),
                    const PopupMenuItem(
                      value: 'rename',
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.edit_outlined),
                        title: Text('重命名'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'export',
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.file_upload_outlined),
                        title: Text('导出歌单'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.delete_outline),
                        title: Text('删除歌单'),
                      ),
                    ),
                  ],
                  icon: const Icon(Icons.more_horiz_rounded),
                ),
          onTap: () {
            if (_playlistSelectionMode) {
              _togglePlaylistSelection(playlist.id);
            } else {
              context.push('/home/playlists/${playlist.id}');
            }
          },
          onLongPress: _playlistSelectionMode
              ? null
              : () => _enterPlaylistSelection(playlist.id),
        ),
      ),
    );
  }

  /// 播放全部：合并所有歌单的歌曲（按路径去重，首个歌单优先），
  /// 本地歌曲经曲库解析，网络歌曲走歌单快照。
  Future<void> _playAllPlaylists() async {
    final playlists = ref.read(playlistsProvider);
    final paths = <String>[];
    final snapshots = <String, PlaylistSongSnapshot>{};
    for (final playlist in playlists) {
      for (final path in playlist.songPaths) {
        if (!paths.contains(path)) {
          paths.add(path);
          final snapshot = playlist.songSnapshots[path];
          if (snapshot != null) snapshots[path] = snapshot;
        }
      }
    }
    if (paths.isEmpty) return;
    final localPaths = paths
        .where((path) => !snapshots.containsKey(path))
        .toList();
    final songsByPath = <String, Song>{};
    if (localPaths.isNotEmpty) {
      final songs = await ref
          .read(libraryProvider.notifier)
          .songsByPaths(localPaths);
      for (final song in songs) {
        songsByPath[song.path] = song;
      }
    }
    for (final entry in snapshots.entries) {
      songsByPath[entry.key] = entry.value.toSong();
    }
    final songs = [for (final path in paths) ?songsByPath[path]];
    if (songs.isNotEmpty) {
      await ref.read(libraryProvider.notifier).playAll(songs);
    }
  }

  // ==========================================================================
  // 本地音乐分页：歌曲 / 歌手 / 专辑 三个子分页；多选（歌曲子分页）
  // 与刷新按钮位于 AppBar。
  // ==========================================================================

  void _enterLocalSelection() {
    setState(() {
      _localSelectionMode = true;
      // 多选仅在歌曲子分页可用，切过去保证用户能看到勾选效果。
      _localTabController.animateTo(0);
    });
  }

  void _localExitSelection() {
    setState(() {
      _localSelectionMode = false;
      _localSelectedPaths.clear();
    });
  }

  void _localToggleSelection(Song song) {
    setState(() {
      if (!_localSelectedPaths.add(song.path)) {
        _localSelectedPaths.remove(song.path);
      }
    });
  }

  void _localToggleAll() {
    final songs = ref.read(libraryProvider).songs;
    setState(() {
      final allSelected = songs.isNotEmpty &&
          _localSelectedPaths.length == songs.length &&
          songs.every((song) => _localSelectedPaths.contains(song.path));
      if (allSelected) {
        _localSelectedPaths.clear();
      } else {
        _localSelectedPaths
          ..clear()
          ..addAll(songs.map((song) => song.path));
      }
    });
  }

  /// 多选一键收藏：批量添加到收藏，已在收藏中的跳过。
  Future<void> _localFavoriteSelected() async {
    if (_localSelectedPaths.isEmpty) return;
    final songs = ref.read(libraryProvider).songs;
    final selected = songs
        .where((song) => _localSelectedPaths.contains(song.path))
        .toList();
    if (selected.isEmpty) return;
    final added = await ref
        .read(favoritesProvider.notifier)
        .addAll(selected.map(FavoriteSongSnapshot.fromSong));
    if (!mounted) return;
    _localExitSelection();
    XyNotice.show(
      context,
      message: added > 0 ? '已收藏 $added 首歌曲' : '所选歌曲均已在收藏中',
      type: XyNoticeType.success,
    );
  }

  /// 多选批量删除本地音乐：永久删除设备上的文件，并同步移除收藏与曲库。
  Future<void> _localDeleteSelected() async {
    if (_localDeleting || _localSelectedPaths.isEmpty) return;
    final songs = ref
        .read(libraryProvider)
        .songs
        .where((song) => _localSelectedPaths.contains(song.path))
        .toList();
    if (songs.isEmpty) return;
    final message = songs.length == 1
        ? '确定永久删除《${songs.first.title}》吗？\n该操作会删除设备上的音乐文件，不可恢复。'
        : '确定永久删除选中的 ${songs.length} 首歌曲吗？\n该操作会删除设备上的音乐文件，不可恢复。';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除歌曲'),
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
    if (ok != true || !mounted) return;
    setState(() => _localDeleting = true);
    var failed = 0;
    try {
      for (final song in songs) {
        try {
          await deleteMusicFile(path: song.path);
        } catch (_) {
          failed++;
        }
      }
      // 同步收藏：已删除文件的收藏项一并移除，避免残留失效路径。
      final favorites = ref.read(favoritesProvider);
      for (final song in songs) {
        if (favorites.contains(song.path)) {
          await ref.read(favoritesProvider.notifier).toggle(song.path);
        }
      }
      // 重扫文件夹把删除同步进数据库（增量 diff，只处理变更）。
      await ref.read(libraryProvider.notifier).scanAllFolders();
      if (!mounted) return;
      _localExitSelection();
      XyNotice.show(
        context,
        message: failed > 0
            ? '已删除 ${songs.length - failed} 首，$failed 首删除失败'
            : '已删除 ${songs.length} 首',
        type: failed > 0 ? XyNoticeType.warning : XyNoticeType.success,
      );
    } finally {
      if (mounted) setState(() => _localDeleting = false);
    }
  }

  /// 多选批量添加到歌单。
  Future<void> _localAddSelectedToPlaylist() async {
    if (_localSelectedPaths.isEmpty) return;
    final songs = ref.read(libraryProvider).songs;
    final selected = songs
        .where((song) => _localSelectedPaths.contains(song.path))
        .toList();
    if (selected.isEmpty) return;
    final result = await showPlaylistPicker(
      context,
      items: [for (final song in selected) song.toQueueItem()],
    );
    if (!mounted || result == null) return;
    _localExitSelection();
    final name = ref
        .read(playlistsProvider)
        .where((value) => value.id == result.playlistId)
        .firstOrNull
        ?.name;
    final parts = <String>[
      if (result.addedCount > 0) '已添加 ${result.addedCount} 首到歌单“$name”',
      if (result.existsCount > 0) '${result.existsCount} 首已在歌单中',
    ];
    XyNotice.show(
      context,
      message: parts.isEmpty ? '所选歌曲均已在歌单中' : parts.join('，'),
      type: result.addedCount > 0 ? XyNoticeType.success : XyNoticeType.warning,
    );
  }

  /// 刷新本地曲库：重扫全部扫描目录（本地音乐 / 文件夹分页共用）。
  Future<void> _refreshLibrary() async {
    if (_libraryScanning) return;
    setState(() => _libraryScanning = true);
    try {
      final count = await ref.read(libraryProvider.notifier).scanAllFolders();
      if (!mounted) return;
      XyNotice.show(
        context,
        message: count > 0 ? '已扫描到 $count 首歌曲' : '未扫描到歌曲',
        duration: const Duration(seconds: 2),
      );
    } on Exception catch (e) {
      if (!mounted) return;
      XyNotice.show(
        context,
        message: '扫描失败：${e.toString().replaceFirst('Exception: ', '')}',
        duration: const Duration(seconds: 2),
      );
    } finally {
      if (mounted) setState(() => _libraryScanning = false);
    }
  }

  /// 按指定键给本地歌曲分组（歌手/专辑视图共用），键按拼音排序。
  Map<String, List<Song>> _groupLocalSongs(
    List<Song> songs,
    String Function(Song song) keyOf,
    String unknownLabel,
  ) {
    final groups = <String, List<Song>>{};
    for (final song in songs) {
      final raw = keyOf(song).trim();
      groups.putIfAbsent(raw.isEmpty ? unknownLabel : raw, () => []).add(song);
    }
    return groups;
  }

  Widget _buildLocalTab(BuildContext context) {
    final songs = ref.watch(libraryProvider.select((s) => s.songs));
    if (songs.isEmpty) {
      return const _EmptyHint('本地音乐库为空\n点击右上角「扫描目录」添加本地音乐文件夹');
    }
    return Column(
      children: [
        TabBar(
          controller: _localTabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          unselectedLabelStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
          tabs: const [
            Tab(text: '歌曲', height: 44),
            Tab(text: '歌手', height: 44),
            Tab(text: '专辑', height: 44),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _localTabController,
            children: [
              _buildLocalSongsTab(context, songs),
              _buildLocalGroupsTab(
                context,
                songs,
                keyOf: (song) => song.artist,
                unknownLabel: '未知歌手',
                emptyLabel: '暂无歌手信息',
                icon: Icons.person_rounded,
                unitLabel: '位歌手',
              ),
              _buildLocalGroupsTab(
                context,
                songs,
                keyOf: (song) => song.album,
                unknownLabel: '未知专辑',
                emptyLabel: '暂无专辑信息',
                icon: Icons.album_rounded,
                unitLabel: '张专辑',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLocalSongsTab(BuildContext context, List<Song> songs) {
    // 排序仅作用于歌曲子分页的展示与播放顺序；custom = 曲库扫描序。
    final sortedSongs = _localSort.key == SongSortKey.custom
        ? songs
        : [...songs]..sort((a, b) {
            var result = switch (_localSort.key) {
              SongSortKey.artist => _pinyinKey(
                a.artist,
              ).compareTo(_pinyinKey(b.artist)),
              SongSortKey.album => _pinyinKey(a.album).compareTo(
                _pinyinKey(b.album),
              ),
              _ => _pinyinKey(a.title).compareTo(_pinyinKey(b.title)),
            };
            if (result == 0) {
              result = _pinyinKey(a.title).compareTo(_pinyinKey(b.title));
            }
            return _localSort.descending ? -result : result;
          });
    final allSelected = sortedSongs.isNotEmpty &&
        _localSelectedPaths.length == sortedSongs.length &&
        sortedSongs.every((song) => _localSelectedPaths.contains(song.path));
    return Column(
      children: [
        _TabHeaderBar(
          countLabel: '${sortedSongs.length} 首歌曲',
          onPlayAll: () =>
              ref.read(libraryProvider.notifier).playAll(sortedSongs),
        ),
        Expanded(
          child: SongsListView(
            songs: sortedSongs,
            padding: EdgeInsets.fromLTRB(
              10,
              0,
              10,
              _localSelectionMode
                  ? 12
                  : MediaQuery.paddingOf(context).bottom + 12,
            ),
            selectionMode: _localSelectionMode,
            isSelected: (song) => _localSelectedPaths.contains(song.path),
            onToggleSelection: _localToggleSelection,
            onPlay: (list, i) =>
                ref.read(libraryProvider.notifier).playList(list, i),
          ),
        ),
        // 多选底部横排菜单：全选 / 收藏 / 加歌单。
        if (_localSelectionMode)
          _SelectionBottomBar(
            actions: [
              _SelectionAction(
                icon: Icon(
                  allSelected
                      ? Icons.deselect_rounded
                      : Icons.select_all_rounded,
                ),
                label: allSelected ? '取消全选' : '全选',
                onTap: _localToggleAll,
              ),
              _SelectionAction(
                icon: const _FavoriteAddIcon(),
                label: '收藏',
                onTap: _localSelectedPaths.isEmpty
                    ? null
                    : _localFavoriteSelected,
              ),
              _SelectionAction(
                icon: const Icon(Icons.playlist_add_check_rounded),
                label: '加歌单',
                onTap: _localSelectedPaths.isEmpty
                    ? null
                    : _localAddSelectedToPlaylist,
              ),
              _SelectionAction(
                icon: const Icon(Icons.delete_outline_rounded),
                label: '删除',
                onTap: _localSelectedPaths.isEmpty || _localDeleting
                    ? null
                    : _localDeleteSelected,
              ),
            ],
          ),
      ],
    );
  }

  /// 歌手 / 专辑分组视图：点击分组播放该组全部歌曲（与文件夹分页一致）。
  Widget _buildLocalGroupsTab(
    BuildContext context,
    List<Song> songs, {
    required String Function(Song song) keyOf,
    required String unknownLabel,
    required String emptyLabel,
    required IconData icon,
    required String unitLabel,
  }) {
    final groups = _groupLocalSongs(songs, keyOf, unknownLabel);
    final names = groups.keys.toList()
      ..sort((a, b) => _pinyinKey(a).compareTo(_pinyinKey(b)));
    if (names.isEmpty) {
      return _EmptyHint(emptyLabel);
    }
    return Column(
      children: [
        _TabHeaderBar(
          countLabel: '${names.length} $unitLabel',
          onPlayAll: () => ref.read(libraryProvider.notifier).playAll(songs),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 24),
            itemCount: names.length,
            itemBuilder: (context, index) {
              final name = names[index];
              final groupSongs = groups[name]!;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: XyPanel(
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Icon(icon, color: Theme.of(context).colorScheme.primary),
                    ),
                    title: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text('${groupSongs.length} 首'),
                    trailing: Icon(
                      Icons.play_circle_outline_rounded,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    onTap: () =>
                        ref.read(libraryProvider.notifier).playAll(groupSongs),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ==========================================================================
  // 最近播放分页：搜索 + 清空按钮位于 AppBar。
  // ==========================================================================

  void _enterRecentSearch() {
    setState(() => _recentSearchMode = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _recentSearchFocus.requestFocus();
    });
  }

  void _exitRecentSearch() {
    _recentSearchFocus.unfocus();
    setState(() {
      _recentSearchMode = false;
      _recentQuery = '';
      _recentSearchController.clear();
    });
  }

  Future<void> _clearRecent() async {
    final entries = ref.read(recentSongsProvider).valueOrNull ?? const [];
    if (entries.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空最近播放'),
        content: const Text('确定清空全部最近播放记录吗？'),
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
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await clearRecentSongs(ref);
    if (!mounted) return;
    XyNotice.show(context, message: '已清空最近播放', type: XyNoticeType.success);
  }

  Widget _buildRecentTab(BuildContext context) {
    final recent = ref.watch(recentSongsProvider);
    return recent.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _EmptyHint('加载失败：$error'),
      data: (entries) {
        if (entries.isEmpty) {
          return const _EmptyHint('还没有播放记录');
        }
        final query = _recentQuery.trim().toLowerCase();
        final songs = [
          for (final entry in entries)
            if (query.isEmpty || _matchesSongQuery(entry.song, query))
              entry.song,
        ];
        return Column(
          children: [
            if (_recentSearchMode)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: FrostedSearchField(
                  controller: _recentSearchController,
                  focusNode: _recentSearchFocus,
                  hintText: '搜索最近播放的歌曲',
                  onChanged: (value) => setState(() => _recentQuery = value),
                  showClearSuffix: true,
                ),
              ),
            _TabHeaderBar(
              countLabel: query.isEmpty
                  ? '${songs.length} 首歌曲'
                  : '${songs.length} / ${entries.length} 首歌曲',
              onPlayAll: songs.isEmpty
                  ? null
                  : () => ref.read(libraryProvider.notifier).playAll(songs),
            ),
            Expanded(
              child: songs.isEmpty
                  ? const Center(child: Text('未找到匹配的歌曲'))
                  : SongsListView(
                      songs: songs,
                      showFloatingButtons: false,
                      padding: EdgeInsets.fromLTRB(
                        10,
                        0,
                        10,
                        MediaQuery.paddingOf(context).bottom + 12,
                      ),
                      onPlay: (list, i) => ref
                          .read(libraryProvider.notifier)
                          .playList(list, i),
                      onRemoveAction: (song) => removeRecentSong(ref, song),
                      removeActionLabel: '从最近播放删除',
                    ),
            ),
          ],
        );
      },
    );
  }

  // ==========================================================================
  // 播放列表分页：当前播放队列，点击条目跳转播放。
  // ==========================================================================

  Widget _buildQueueTab(BuildContext context) {
    final queue = ref.watch(playerProvider.select((s) => s.queue));
    final queueIndex = ref.watch(playerProvider.select((s) => s.queueIndex));
    if (queue.isEmpty) {
      return const _EmptyHint('播放队列为空\n播放一首歌后这里会显示队列');
    }
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        _TabHeaderBar(
          countLabel: '${queue.length} 首歌曲',
          onPlayAll: () => ref.read(playerProvider.notifier).playIndex(0),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 24),
            itemCount: queue.length,
            itemBuilder: (context, index) {
              final item = queue[index];
              final current = index == queueIndex;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: XyPanel(
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    leading: CoverImage(
                      songPath: item.path,
                      imageUrl: item.coverUrl,
                      width: 44,
                      height: 44,
                      radius: 12,
                    ),
                    title: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: current ? scheme.primary : null,
                      ),
                    ),
                    subtitle: Text(
                      item.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Icon(
                      current
                          ? Icons.graphic_eq_rounded
                          : Icons.play_arrow_rounded,
                      color: current
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    onTap: () =>
                        ref.read(playerProvider.notifier).playIndex(index),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ==========================================================================
  // 文件夹分页：扫描目录 / 搜索 / 刷新按钮位于 AppBar。
  // ==========================================================================

  void _enterFolderSearch() {
    setState(() => _folderSearchMode = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _folderSearchFocus.requestFocus();
    });
  }

  void _exitFolderSearch() {
    _folderSearchFocus.unfocus();
    setState(() {
      _folderSearchMode = false;
      _folderQuery = '';
      _folderSearchController.clear();
    });
  }

  /// 添加扫描目录：权限 → 目录选择（Android 自建浏览器 / 桌面系统选择器）
  /// → 加入扫描列表并立即扫描（与设置页添加目录同款流程）。
  Future<void> _addScanFolder() async {
    if (_addingFolder) return;
    setState(() => _addingFolder = true);
    try {
      // 权限走原生桥（MusicFree 同款），按系统版本申请真实所需权限。
      if (!await NativeStoragePermission.ensure()) {
        _toast(await NativeStoragePermission.deniedHint);
        return;
      }
      String? dir;
      if (Platform.isAndroid) {
        // 自建目录浏览器：返回真实文件路径且与扫描走同一套权限。
        if (!mounted) return;
        dir = await Navigator.of(context).push<String>(
          MaterialPageRoute(builder: (_) => const FolderBrowserPage()),
        );
      } else {
        dir = await FilePicker.platform.getDirectoryPath();
      }
      if (dir == null || dir.startsWith('content://')) return; // 用户取消
      // 非 Android（SAF 路径）校验可读性；Android 浏览器能列出即已可读。
      if (!Platform.isAndroid &&
          !await NativeStoragePermission.isReadableDirectory(dir)) {
        _toast('无法读取所选文件夹');
        return;
      }
      await ref.read(scanFoldersProvider.notifier).addFolder(dir);
      // 添加即扫描：不扫的话歌曲要等用户手动刷新才出现。
      _toast('已添加扫描目录，开始扫描...');
      try {
        final count = await ref.read(libraryProvider.notifier).scanAllFolders();
        if (!mounted) return;
        if (count == 0) {
          _toast('已添加目录，但未扫描到歌曲，请确认目录内有受支持格式的音频文件');
        } else {
          _toast('已添加目录，共扫描到 $count 首歌曲');
        }
      } on Exception catch (e) {
        if (!mounted) return;
        _toast('扫描失败：${e.toString().replaceFirst('Exception: ', '')}');
      }
    } catch (e) {
      _toast('添加失败：$e');
    } finally {
      if (mounted) setState(() => _addingFolder = false);
    }
  }

  Widget _buildFoldersTab(BuildContext context) {
    final root = ref.watch(libraryProvider.select((s) => s.folderRoot));
    if (root.isEmpty) {
      return const _EmptyHint('暂无文件夹\n点击右上角「扫描目录」添加本地音乐目录');
    }
    final query = _folderQuery.trim().toLowerCase();
    final nodes = query.isEmpty
        ? root
        : root.where((node) {
            final name = node.name.isNotEmpty
                ? node.name
                : node.path.split('/').last;
            return name.toLowerCase().contains(query) ||
                node.path.toLowerCase().contains(query);
          }).toList();
    return Column(
      children: [
        if (_folderSearchMode)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: FrostedSearchField(
              controller: _folderSearchController,
              focusNode: _folderSearchFocus,
              hintText: '搜索文件夹',
              onChanged: (value) => setState(() => _folderQuery = value),
              showClearSuffix: true,
            ),
          ),
        _TabHeaderBar(
          countLabel: query.isEmpty
              ? '${root.length} 个根目录'
              : '${nodes.length} / ${root.length} 个根目录',
          onPlayAll: () => _playFolderSongs(null),
        ),
        Expanded(
          child: nodes.isEmpty
              ? const Center(child: Text('未找到匹配的文件夹'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 24),
                  itemCount: nodes.length,
                  itemBuilder: (context, index) {
                    final node = nodes[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: XyPanel(
                        padding: EdgeInsets.zero,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          leading: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: Icon(
                              Icons.folder_rounded,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                          title: Text(
                            node.name.isNotEmpty
                                ? node.name
                                : node.path.split('/').last,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            '${node.songCount} 首${node.childCount > 0 ? ' · ${node.childCount} 个子文件夹' : ''}',
                          ),
                          trailing: Icon(
                            Icons.play_circle_outline_rounded,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                          onTap: () => _playFolderSongs(node.path),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 播放文件夹内全部歌曲；path 为 null 时播放整个本地曲库。
  Future<void> _playFolderSongs(String? path) async {
    final songs = path == null
        ? ref.read(libraryProvider).songs
        : await ref.read(libraryProvider.notifier).songsByFolder(path);
    if (songs.isEmpty) return;
    await ref.read(libraryProvider.notifier).playAll(songs);
  }
}

/// 各分页顶部的「数量 + 播放全部」行。
class _TabHeaderBar extends StatelessWidget {
  const _TabHeaderBar({required this.countLabel, this.onPlayAll});

  final String countLabel;

  /// null 或列表为空时按钮禁用。
  final VoidCallback? onPlayAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              countLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: onPlayAll,
            icon: const Icon(Icons.play_arrow, size: 20),
            label: const Text('播放全部'),
          ),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.only(bottom: 60),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
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

/// 多选底部横排菜单的单个操作项。
class _SelectionAction {
  const _SelectionAction({
    required this.icon,
    required this.label,
    this.onTap,
  });

  final Widget icon;
  final String label;

  /// null 表示禁用（无选中或操作进行中）。
  final VoidCallback? onTap;
}

/// 多选模式的底部横排图标菜单（与歌单详情页同款）：批量操作进行中时
/// 对应按钮显示进度并禁用其余操作。
class _SelectionBottomBar extends StatelessWidget {
  const _SelectionBottomBar({required this.actions});

  final List<_SelectionAction> actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
              for (final action in actions)
                Expanded(
                  child: InkWell(
                    onTap: action.onTap,
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
                                  color: action.onTap != null
                                      ? scheme.onSurface
                                      : scheme.onSurfaceVariant.withValues(
                                          alpha: .45,
                                        ),
                                ),
                                child: action.icon,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            action.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: action.onTap != null
                                  ? scheme.onSurface
                                  : scheme.onSurfaceVariant.withValues(
                                      alpha: .45,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
