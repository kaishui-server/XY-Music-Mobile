import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/settings.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/navigation/sidebar_controller.dart';
import '../../src/player/player_provider.dart';
import '../../src/playlists/playlist_import_actions.dart';
import '../../src/playlists/playlist_sync.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/recent/recent_provider.dart';
import '../../src/ui/xy_surface.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/song_list_view.dart';

/// 音乐库：收藏 / 歌单 / 本地音乐 / 最近播放 / 播放列表 / 文件夹
/// 的统一分页入口（原侧边栏多个独立入口合并）。每个分页自带
/// 「播放全部」。
class MusicLibraryPage extends ConsumerStatefulWidget {
  const MusicLibraryPage({super.key});

  @override
  ConsumerState<MusicLibraryPage> createState() => _MusicLibraryPageState();
}

class _MusicLibraryPageState extends ConsumerState<MusicLibraryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 6,
    vsync: this,
  );

  static const _tabs = ['已收藏', '歌单', '本地音乐', '最近播放', '播放列表', '文件夹'];

  @override
  void initState() {
    super.initState();
    _tabController.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    // 切换分页时重建 AppBar（歌单页顶栏需要出现导入按钮）。
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
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
        title: const Text('音乐库'),
        actions: [
          if (_tabController.index == 1)
            IconButton(
              tooltip: '导入歌单',
              onPressed: () => showPlaylistImportOptions(context, ref),
              icon: const Icon(Icons.download_rounded),
            ),
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
            for (final tab in _tabs)
              Tab(text: tab, height: 54),
          ],
        ),
      ),
      body: XyPageBackground(
        child: TabBarView(
          controller: _tabController,
          children: const [
            _FavoritesTab(),
            _PlaylistsTab(),
            _LocalSongsTab(),
            _RecentTab(),
            _QueueTab(),
            _FoldersTab(),
          ],
        ),
      ),
    );
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

/// 已收藏分页：本地歌曲 + 网络快照合并展示（同收藏页口径）。
class _FavoritesTab extends ConsumerStatefulWidget {
  const _FavoritesTab();

  @override
  ConsumerState<_FavoritesTab> createState() => _FavoritesTabState();
}

class _FavoritesTabState extends ConsumerState<_FavoritesTab> {
  Future<List<Song>>? _songsFuture;
  int? _songsFutureKey;

  /// 缓存查询 Future，避免每次 build 都触发 FutureBuilder 重新加载。
  Future<List<Song>> _songsForPaths(List<String> paths) {
    final key = Object.hashAll(paths);
    if (_songsFuture == null || _songsFutureKey != key) {
      _songsFutureKey = key;
      _songsFuture = ref.read(libraryProvider.notifier).songsByPaths(paths);
    }
    return _songsFuture!;
  }

  @override
  Widget build(BuildContext context) {
    final favPaths = ref.watch(favoritesProvider);
    if (favPaths.isEmpty) {
      return const _EmptyHint('还没有收藏歌曲\n长按歌曲或点击右侧菜单即可收藏');
    }
    final favorites = ref.read(favoritesProvider.notifier);
    final localPaths = favPaths
        .where((path) => favorites.snapshotFor(path) == null)
        .toList();
    return FutureBuilder<List<Song>>(
      key: ValueKey(Object.hashAll(favPaths)),
      future: _songsForPaths(localPaths),
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
          final snapshot = favorites.snapshotFor(path);
          if (snapshot != null) songsByPath[path] = snapshot.toSong();
        }
        // favPaths（LinkedHashSet）的迭代顺序即收藏添加顺序。
        final songs = [for (final path in favPaths) ?songsByPath[path]];
        if (songs.isEmpty) {
          return const _EmptyHint('收藏的歌曲已不在音乐库中');
        }
        return Column(
          children: [
            _TabHeaderBar(
              countLabel: '${songs.length} 首歌曲',
              onPlayAll: () => ref
                  .read(libraryProvider.notifier)
                  .playAll(songs),
            ),
            Expanded(
              child: SongsListView(
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
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 歌单分页：歌单卡片列表，点击进入歌单详情。
class _PlaylistsTab extends ConsumerWidget {
  const _PlaylistsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);
    if (playlists.isEmpty) {
      return const _EmptyHint('还没有歌单\n在探索页或本地音乐中长按歌曲即可创建');
    }
    return Column(
      children: [
        _TabHeaderBar(
          countLabel: '${playlists.length} 个歌单',
          onPlayAll: () => _playAllPlaylists(ref),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 24),
            itemCount: playlists.length,
            itemBuilder: (context, index) {
              final playlist = playlists[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: XyPanel(
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    leading: Container(
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
                    trailing: PopupMenuButton<String>(
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
                    onTap: () =>
                        context.push('/home/playlists/${playlist.id}'),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 播放全部：合并所有歌单的歌曲（按路径去重，首个歌单优先），
  /// 本地歌曲经曲库解析，网络歌曲走歌单快照。
  Future<void> _playAllPlaylists(WidgetRef ref) async {
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
}

/// 本地音乐分页：全部本地歌曲。
class _LocalSongsTab extends ConsumerWidget {
  const _LocalSongsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = ref.watch(libraryProvider.select((s) => s.songs));
    if (songs.isEmpty) {
      return const _EmptyHint('本地音乐库为空\n在设置中添加扫描文件夹后自动导入');
    }
    return Column(
      children: [
        _TabHeaderBar(
          countLabel: '${songs.length} 首歌曲',
          onPlayAll: () => ref.read(libraryProvider.notifier).playAll(songs),
        ),
        Expanded(
          child: SongsListView(
            songs: songs,
            showFloatingButtons: false,
            padding: EdgeInsets.fromLTRB(
              10,
              0,
              10,
              MediaQuery.paddingOf(context).bottom + 12,
            ),
            onPlay: (list, i) =>
                ref.read(libraryProvider.notifier).playList(list, i),
          ),
        ),
      ],
    );
  }
}

/// 最近播放分页。
class _RecentTab extends ConsumerWidget {
  const _RecentTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentSongsProvider);
    return recent.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _EmptyHint('加载失败：$error'),
      data: (entries) {
        if (entries.isEmpty) {
          return const _EmptyHint('还没有播放记录');
        }
        final songs = [for (final entry in entries) entry.song];
        return Column(
          children: [
            _TabHeaderBar(
              countLabel: '${songs.length} 首歌曲',
              onPlayAll: () =>
                  ref.read(libraryProvider.notifier).playAll(songs),
            ),
            Expanded(
              child: SongsListView(
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
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 播放列表分页：当前播放队列，点击条目跳转播放。
class _QueueTab extends ConsumerWidget {
  const _QueueTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          onPlayAll: () =>
              ref.read(playerProvider.notifier).playIndex(0),
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
}

/// 文件夹分页：扫描目录树，点击文件夹播放该目录下全部歌曲。
class _FoldersTab extends ConsumerWidget {
  const _FoldersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final root = ref.watch(libraryProvider.select((s) => s.folderRoot));
    if (root.isEmpty) {
      return const _EmptyHint('暂无文件夹\n在 设置 → 本地音乐 中添加扫描目录');
    }
    return Column(
      children: [
        _TabHeaderBar(
          countLabel: '${root.length} 个根目录',
          onPlayAll: () => _playFolderSongs(ref, null),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 24),
            itemCount: root.length,
            itemBuilder: (context, index) {
              final node = root[index];
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
                    onTap: () => _playFolderSongs(ref, node.path),
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
  Future<void> _playFolderSongs(WidgetRef ref, String? path) async {
    final songs = path == null
        ? ref.read(libraryProvider).songs
        : await ref.read(libraryProvider.notifier).songsByFolder(path);
    if (songs.isEmpty) return;
    await ref.read(libraryProvider.notifier).playAll(songs);
  }
}
