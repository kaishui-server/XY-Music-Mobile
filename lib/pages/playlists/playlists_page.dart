import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/navigation/sidebar_controller.dart';
import '../../src/player/player_provider.dart';
import '../../src/playlists/playlist_import_actions.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/playlists/playlist_sync.dart';
import '../../src/ui/xy_surface.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/song_list_view.dart';

class PlaylistsPage extends ConsumerStatefulWidget {
  const PlaylistsPage({super.key});

  @override
  ConsumerState<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends ConsumerState<PlaylistsPage> {
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};
  final ScrollController _playlistsController = ScrollController();

  @override
  void dispose() {
    _playlistsController.dispose();
    super.dispose();
  }

  void _toggleSelection(String id) {
    setState(() {
      if (!_selectedIds.add(id)) _selectedIds.remove(id);
    });
  }

  void _enterSelection(String id) {
    setState(() {
      _selectionMode = true;
      _selectedIds.add(id);
    });
  }

  void _leaveSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _selectAll(List<MobilePlaylist> playlists) {
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(playlists.map((playlist) => playlist.id));
    });
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '输入歌单名称'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null) await ref.read(playlistsProvider.notifier).create(name);
  }

  Future<void> _deleteSelected(BuildContext context) async {
    final count = _selectedIds.length;
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
    await ref.read(playlistsProvider.notifier).deleteMany(_selectedIds);
    if (!mounted) return;
    _leaveSelection();
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);
    return Scaffold(
      appBar: AppBar(
        leading: const AppSidebarMenuButton(),
        title: Text(_selectionMode ? '已选择 ${_selectedIds.length} 个歌单' : '我的歌单'),
        actions: [
          if (_selectionMode) ...[
            IconButton(
              tooltip: '全选',
              onPressed: () => _selectAll(playlists),
              icon: const Icon(Icons.select_all_rounded),
            ),
            IconButton(
              tooltip: '删除所选歌单',
              onPressed: _selectedIds.isEmpty
                  ? null
                  : () => _deleteSelected(context),
              icon: const Icon(Icons.delete_outline_rounded),
            ),
            IconButton(
              tooltip: '取消多选',
              onPressed: _leaveSelection,
              icon: const Icon(Icons.close_rounded),
            ),
          ] else ...[
            IconButton(
              tooltip: '批量删除歌单',
              onPressed: playlists.isEmpty
                  ? null
                  : () => setState(() => _selectionMode = true),
              icon: const Icon(Icons.checklist_rounded),
            ),
            IconButton(
              tooltip: '导入歌单',
              onPressed: () => showPlaylistImportOptions(context, ref),
              icon: const Icon(Icons.download_rounded),
            ),
            IconButton(
              tooltip: '新建歌单',
              onPressed: () => _create(context, ref),
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ],
      ),
      body: XyPageBackground(
        child: playlists.isEmpty
            ? _EmptyPlaylists(
                onCreate: () => _create(context, ref),
                onImport: () => showPlaylistImportOptions(context, ref),
              )
            : Stack(
                children: [
                  ListView(
                    controller: _playlistsController,
                    // Shell 已把底栏+迷你播放栏的遮挡高度注入
                    // MediaQuery.padding.bottom（含系统安全区），
                    // 直接读取即可避免底部被悬浮元素遮挡。
                    padding: EdgeInsets.fromLTRB(
                      16,
                      8,
                      16,
                      MediaQuery.paddingOf(context).bottom + 12,
                    ),
                    children: [
                      _PlaylistSectionHeader(
                        label: '我的歌单',
                        count: playlists.length,
                        first: true,
                      ),
                      for (final playlist in playlists)
                        _playlistTile(context, playlist),
                    ],
                  ),
                  ScrollToTopButton(
                    controller: _playlistsController,
                    hasMiniPlayer: ref.watch(
                      playerProvider.select((state) => state.current != null),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _playlistTile(BuildContext context, MobilePlaylist playlist) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: XyPanel(
        padding: EdgeInsets.zero,
        child: ListTile(
          minTileHeight: 72,
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_selectionMode)
                Checkbox(
                  value: _selectedIds.contains(playlist.id),
                  onChanged: (_) => _toggleSelection(playlist.id),
                ),
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(
                    alpha: 0.14,
                  ),
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
          trailing: _selectionMode
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PopupMenuButton<String>(
                      tooltip: '更多',
                      onSelected: (action) {
                        switch (action) {
                          case 'sync':
                            syncPlaylistWithNotice(
                              context,
                              ref,
                              playlist,
                            );
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
                  ],
                ),
          onTap: () => _selectionMode
              ? _toggleSelection(playlist.id)
              : context.push('/home/playlists/${playlist.id}'),
          onLongPress: _selectionMode
              ? null
              : () => _enterSelection(playlist.id),
        ),
      ),
    );
  }
}

class _PlaylistSectionHeader extends StatelessWidget {
  const _PlaylistSectionHeader({
    required this.label,
    required this.count,
    required this.first,
  });

  final String label;
  final int count;

  /// 是否为列表首个分区（首个分区不加上间距，避免与 AppBar 拉开过大）。
  final bool first;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: EdgeInsets.fromLTRB(6, first ? 4 : 18, 6, 6),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(fontSize: 12, color: color.withValues(alpha: 0.7)),
          ),
        ],
      ),
    );
  }
}

class _EmptyPlaylists extends StatelessWidget {
  const _EmptyPlaylists({required this.onCreate, required this.onImport});

  final VoidCallback onCreate;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(30, 20, 30, 80),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.queue_music_rounded,
              size: 60,
              color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
            ),
            const SizedBox(height: 16),
            const Text(
              '还没有歌单',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 7),
            Text(
              '创建自己的歌单，或从网络和本地文件导入',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: onImport,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('导入'),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: onCreate,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('新建歌单'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
