import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../src/library/library_provider.dart';
import '../../src/core/settings.dart';
import '../../src/library/scan_settings_provider.dart';
import '../../src/navigation/animated_page_route.dart';
import '../../src/navigation/routes.dart';
import '../../src/navigation/sidebar_controller.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/top_notice.dart';
import 'song_list_page.dart';

class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key, this.initialTab});

  final int? initialTab;

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  late int _visibleTab;
  bool _addingFolder = false;
  bool _scanning = false;

  /// 顶栏刷新：重新扫描全部已配置文件夹，同步磁盘上的新增/删除后刷新列表。
  Future<void> _onRefresh() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final count = await ref
          .read(libraryProvider.notifier)
          .scanAllFolders();
      if (!mounted) return;
      XyNotice.show(
        context,
        message: '刷新完成，共 $count 首',
        type: XyNoticeType.success,
        duration: const Duration(seconds: 2),
      );
    } catch (e) {
      if (!mounted) return;
      XyNotice.show(context, message: '刷新失败：$e', type: XyNoticeType.error);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
    _tab.index = widget.initialTab ?? ref.read(libraryTabProvider);
    _visibleTab = _tab.index;
    _tab.addListener(_handleTabChanged);
    // Riverpod 不允许在 initState 中同步修改 Provider。独立侧栏路由需要
    // 更新当前音乐库分区时，延后到首帧完成后再同步。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ref.read(libraryTabProvider) == _tab.index) return;
      ref.read(libraryTabProvider.notifier).state = _tab.index;
    });
    ref.listenManual(libraryTabProvider, (prev, next) {
      if (next != prev && _tab.index != next) {
        _tab.animateTo(next);
      }
    });
  }

  @override
  void dispose() {
    _tab.removeListener(_handleTabChanged);
    _tab.dispose();
    super.dispose();
  }

  void _handleTabChanged() {
    if (_visibleTab == _tab.index) return;
    setState(() => _visibleTab = _tab.index);
    Future<void>.microtask(() {
      if (mounted && ref.read(libraryTabProvider) != _tab.index) {
        ref.read(libraryTabProvider.notifier).state = _tab.index;
      }
    });
  }

  Future<bool> _ensureStoragePermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    if ((await Permission.manageExternalStorage.request()).isGranted) {
      return true;
    }
    if ((await Permission.audio.request()).isGranted) return true;
    return (await Permission.storage.request()).isGranted;
  }

  Future<void> _addFolder() async {
    if (_addingFolder) return;
    setState(() => _addingFolder = true);
    try {
      if (!await _ensureStoragePermission()) {
        throw Exception('未授予存储权限，无法扫描本地文件夹');
      }
      final directory = await FilePicker.platform.getDirectoryPath();
      if (directory == null) return;
      if (directory.startsWith('content://')) {
        throw Exception('请授予“所有文件访问”权限后重新选择文件夹');
      }
      await ref.read(scanFoldersProvider.notifier).addFolder(directory);
      final count = await ref.read(libraryProvider.notifier).scanAllFolders();
      if (!mounted) return;
      XyNotice.show(
        context,
        message: '文件夹已添加，当前共扫描到 $count 首歌曲',
        type: XyNoticeType.success,
      );
    } catch (error) {
      if (!mounted) return;
      XyNotice.show(
        context,
        message: error.toString().replaceFirst('Exception: ', ''),
        type: XyNoticeType.error,
      );
    } finally {
      if (mounted) setState(() => _addingFolder = false);
    }
  }

  Future<void> _searchFolders() async {
    final root = ref.read(libraryProvider).folderRoot;
    final selected = await showSearch<FolderNodeData?>(
      context: context,
      delegate: _FolderSearchDelegate(root),
    );
    if (!mounted || selected == null || selected.songCount <= 0) return;
    await Navigator.push<void>(
      context,
      XyAnimatedPageRoute(
        builder: (_) => SongListPage(
          title: selected.name,
          loader: () =>
              ref.read(libraryProvider.notifier).songsByFolder(selected.path),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);
    final sidebarOnRight = ref.watch(
      settingsProvider.select(
        (value) => value.valueOrNull?.sidebarPosition == SidebarPosition.right,
      ),
    );

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !sidebarOnRight,
        leading: sidebarOnRight ? null : const AppSidebarMenuButton(),
        title: const Text('本地音乐'),
        actions: [
          if (sidebarOnRight) const AppSidebarMenuButton(),
          if (_visibleTab == 3)
            IconButton(
              tooltip: '添加文件夹',
              onPressed: _addingFolder ? null : _addFolder,
              icon: _addingFolder
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.create_new_folder_outlined),
            ),
          if (_visibleTab == 3)
            IconButton(
              tooltip: '搜索文件夹',
              onPressed: _searchFolders,
              icon: const Icon(Icons.search_rounded),
            ),
          IconButton(
            tooltip: '刷新',
            // 刷新需重新扫描文件夹以同步磁盘上的新增/删除，仅 load()
            // 只会重读数据库，无法带出文件夹里的新内容。
            onPressed: _scanning ? null : _onRefresh,
            icon: _scanning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: '歌曲'),
            Tab(text: '歌手'),
            Tab(text: '专辑'),
            Tab(text: '文件夹'),
          ],
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.only(bottom: 90),
        child: lib.loading
            ? const Center(child: CircularProgressIndicator())
            : lib.error != null
            ? _ErrorView(
                message: lib.error!,
                onRetry: () => ref.read(libraryProvider.notifier).load(),
              )
            : TabBarView(
                controller: _tab,
                children: [
                  _AllSongsTab(),
                  _ArtistsTab(),
                  _AlbumsTab(),
                  _FoldersTab(),
                ],
              ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

/// 全部歌曲（支持本地搜索）。
class _AllSongsTab extends ConsumerStatefulWidget {
  @override
  ConsumerState<_AllSongsTab> createState() => _AllSongsTabState();
}

class _AllSongsTabState extends ConsumerState<_AllSongsTab> {
  String _query = '';
  final TextEditingController _controller = TextEditingController();

  /// 音乐库分支的顶层路径。切换到其它页面（侧栏分支、播放页、搜索页）
  /// 再回来时搜索框内容应被清空；分支容器会保留各页面 State，TabBarView
  /// 的销毁机制覆盖不到分支切换，所以在这里监听全局路由变化主动清理。
  static const _libraryPathSegments = {
    'library',
    'local-music',
    'artists',
    'albums',
    'folders',
  };

  void _handleRouteChanged() {
    if (!mounted || _query.isEmpty && _controller.text.isEmpty) return;
    final path = appRouter.routerDelegate.currentConfiguration.uri.path;
    final segment = path.split('/').where((s) => s.isNotEmpty).firstOrNull;
    if (segment != null && _libraryPathSegments.contains(segment)) return;
    _controller.clear();
    setState(() => _query = '');
  }

  @override
  void initState() {
    super.initState();
    appRouter.routerDelegate.addListener(_handleRouteChanged);
  }

  @override
  void dispose() {
    appRouter.routerDelegate.removeListener(_handleRouteChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);
    final songs = _query.isEmpty
        ? lib.songs
        : lib.songs
              .where(
                (s) =>
                    s.title.toLowerCase().contains(_query) ||
                    s.artist.toLowerCase().contains(_query) ||
                    s.album.toLowerCase().contains(_query),
              )
              .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _controller,
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            decoration: InputDecoration(
              hintText: '搜索歌曲、歌手、专辑',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
        ),
        Expanded(
          child: songs.isEmpty
              ? const Center(child: Text('没有匹配的歌曲'))
              : SongsListView(
                  songs: songs,
                  onPlay: (list, i) =>
                      ref.read(libraryProvider.notifier).playList(list, i),
                ),
        ),
      ],
    );
  }
}

/// 歌手目录。
class _ArtistsTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = ref.watch(libraryProvider.select((s) => s.artists));
    if (artists.isEmpty) return const Center(child: Text('暂无歌手'));
    return ListView.separated(
      itemCount: artists.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final a = artists[i];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: Text(
              a.name.isEmpty ? '?' : String.fromCharCode(a.name.runes.first),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${a.count} 首'),
          trailing: Icon(
            Icons.chevron_right,
            color: Theme.of(context).colorScheme.outline,
          ),
          onTap: () => Navigator.push(
            context,
            XyAnimatedPageRoute(
              builder: (_) => SongListPage(
                title: a.name,
                loader: () =>
                    ref.read(libraryProvider.notifier).songsByArtist(a.name),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 专辑目录。
class _AlbumsTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(libraryProvider.select((s) => s.albums));
    if (albums.isEmpty) return const Center(child: Text('暂无专辑'));
    return ListView.separated(
      itemCount: albums.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final a = albums[i];
        return ListTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.album, size: 20),
          ),
          title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${a.artist} · ${a.count} 首',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Icon(
            Icons.chevron_right,
            color: Theme.of(context).colorScheme.outline,
          ),
          onTap: () => Navigator.push(
            context,
            XyAnimatedPageRoute(
              builder: (_) => SongListPage(
                title: a.name,
                loader: () =>
                    ref.read(libraryProvider.notifier).songsByAlbum(a.key),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 文件夹树。
class _FoldersTab extends ConsumerStatefulWidget {
  @override
  ConsumerState<_FoldersTab> createState() => _FoldersTabState();
}

class _FoldersTabState extends ConsumerState<_FoldersTab> {
  final Set<String> _expanded = {};
  final Set<String> _loadingChildren = {};
  final Map<String, List<FolderNodeData>> _loadedChildren = {};

  Future<void> _toggleNode(
    FolderNodeData node,
    List<FolderNodeData> visibleChildren,
  ) async {
    if (_expanded.contains(node.path)) {
      setState(() => _expanded.remove(node.path));
      return;
    }
    if (visibleChildren.isNotEmpty || node.childCount == 0) {
      setState(() => _expanded.add(node.path));
      return;
    }
    if (_loadingChildren.contains(node.path)) return;
    setState(() => _loadingChildren.add(node.path));
    try {
      final children = await ref
          .read(libraryProvider.notifier)
          .folderChildren(node.path);
      if (!mounted) return;
      setState(() {
        _loadedChildren[node.path] = children;
        if (children.isNotEmpty) _expanded.add(node.path);
      });
      if (children.isEmpty && mounted) {
        XyNotice.show(
          context,
          message: '该文件夹中没有可展开的子文件夹',
          duration: const Duration(seconds: 2),
        );
      }
    } catch (error) {
      if (!mounted) return;
      XyNotice.show(
        context,
        message: '读取子文件夹失败：$error',
        type: XyNoticeType.error,
      );
    } finally {
      if (mounted) setState(() => _loadingChildren.remove(node.path));
    }
  }

  void _buildNodes(
    BuildContext context,
    List<FolderNodeData> nodes,
    List<Widget> out, [
    int depth = 0,
  ]) {
    for (final n in nodes) {
      final children = _loadedChildren[n.path] ?? n.children;
      final hasChildren = children.isNotEmpty || n.childCount > 0;
      final isExpanded = _expanded.contains(n.path);
      out.add(
        _FolderTile(
          node: n,
          depth: depth,
          hasChildren: hasChildren,
          isExpanded: isExpanded,
          isLoading: _loadingChildren.contains(n.path),
          onToggle: () => _toggleNode(n, children),
          onOpen: () {
            if (n.songCount > 0) {
              Navigator.push(
                context,
                XyAnimatedPageRoute(
                  builder: (_) => SongListPage(
                    title: n.name,
                    loader: () => ref
                        .read(libraryProvider.notifier)
                        .songsByFolder(n.path),
                  ),
                ),
              );
            }
          },
        ),
      );
      if (isExpanded && children.isNotEmpty) {
        _buildNodes(context, children, out, depth + 1);
      }
    }
  }

  bool _scanning = false;

  Future<void> _onRefresh() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final count = await ref.read(libraryProvider.notifier).scanAllFolders();
      if (!mounted) return;
      setState(() {
        _expanded.clear();
        _loadedChildren.clear();
      });
      XyNotice.show(
        context,
        message: '扫描完成，共 $count 首',
        type: XyNoticeType.success,
        duration: const Duration(seconds: 2),
      );
    } catch (e) {
      if (!mounted) return;
      XyNotice.show(context, message: '扫描失败：$e', type: XyNoticeType.error);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final root = ref.watch(libraryProvider.select((s) => s.folderRoot));
    final tiles = <Widget>[];
    _buildNodes(context, root, tiles);
    // 用 RefreshIndicator 包裹，空态也可下拉；空态用可滚动布局撑满。
    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: root.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.5,
                  child: const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '暂无文件夹\n点击右上角“添加文件夹”选择音乐目录，\n添加后会自动开始扫描',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ],
            )
          : ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: tiles,
            ),
    );
  }
}

class _FolderTile extends StatelessWidget {
  final FolderNodeData node;
  final int depth;
  final bool hasChildren;
  final bool isExpanded;
  final bool isLoading;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  const _FolderTile({
    required this.node,
    required this.depth,
    required this.hasChildren,
    required this.isExpanded,
    required this.isLoading,
    required this.onToggle,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.only(left: 16 + depth * 18, right: 8),
      leading: const Icon(Icons.folder),
      // 标题只显示文件夹名，完整路径放副标题（从右侧省略，保留末级目录）。
      title: Text(
        node.name.isNotEmpty ? node.name : node.path.split('/').last,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        '${node.songCount} 首',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasChildren)
            IconButton(
              icon: isLoading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : AnimatedRotation(
                      turns: isExpanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(Icons.expand_more),
                    ),
              onPressed: isLoading ? null : onToggle,
            ),
          if (node.songCount > 0)
            IconButton(icon: const Icon(Icons.play_arrow), onPressed: onOpen),
        ],
      ),
      onTap: isLoading ? null : (hasChildren ? onToggle : onOpen),
    );
  }
}

class _FolderSearchDelegate extends SearchDelegate<FolderNodeData?> {
  _FolderSearchDelegate(List<FolderNodeData> root) : _folders = _flatten(root);

  final List<FolderNodeData> _folders;

  static List<FolderNodeData> _flatten(List<FolderNodeData> nodes) {
    final result = <FolderNodeData>[];
    for (final node in nodes) {
      result.add(node);
      result.addAll(_flatten(node.children));
    }
    return result;
  }

  @override
  String get searchFieldLabel => '搜索文件夹名称或路径';

  @override
  List<Widget>? buildActions(BuildContext context) => [
    if (query.isNotEmpty)
      IconButton(
        tooltip: '清空',
        onPressed: () => query = '',
        icon: const Icon(Icons.clear_rounded),
      ),
  ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
    tooltip: '返回',
    onPressed: () => close(context, null),
    icon: const Icon(Icons.arrow_back_rounded),
  );

  @override
  Widget buildResults(BuildContext context) => _buildMatches(context);

  @override
  Widget buildSuggestions(BuildContext context) => _buildMatches(context);

  Widget _buildMatches(BuildContext context) {
    final keyword = query.trim().toLowerCase();
    final matches = keyword.isEmpty
        ? _folders
        : _folders
              .where(
                (folder) =>
                    folder.name.toLowerCase().contains(keyword) ||
                    folder.path.toLowerCase().contains(keyword),
              )
              .toList();
    if (matches.isEmpty) return const Center(child: Text('没有找到匹配的文件夹'));
    return ListView.builder(
      itemCount: matches.length,
      itemBuilder: (context, index) {
        final folder = matches[index];
        return ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(
            folder.name.isEmpty ? _folderName(folder.path) : folder.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${folder.path}\n${folder.songCount} 首',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          enabled: folder.songCount > 0,
          trailing: folder.songCount > 0
              ? const Icon(Icons.chevron_right)
              : null,
          onTap: folder.songCount > 0 ? () => close(context, folder) : null,
        );
      },
    );
  }

  static String _folderName(String path) {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.where((part) => part.isNotEmpty).lastOrNull ?? path;
  }
}
