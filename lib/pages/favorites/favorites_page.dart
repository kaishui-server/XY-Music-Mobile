import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/favorites/favorites_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/player/player_provider.dart';
import '../../src/navigation/sidebar_controller.dart';
import '../../src/widgets/song_list_view.dart';

/// 收藏页：展示已收藏的歌曲，点击即播放整个收藏列表。
class FavoritesPage extends ConsumerWidget {
  const FavoritesPage({super.key});

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空收藏'),
        content: const Text('确定取消收藏全部歌曲吗？音乐文件不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(favoritesProvider.notifier).clear();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    if (queuedSnapshots.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final snapshot in queuedSnapshots.values) {
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

    return Scaffold(
      appBar: AppBar(
        leading: const AppSidebarMenuButton(),
        title: const Text('我的收藏'),
        actions: [
          IconButton(
            tooltip: '清空收藏',
            onPressed: favPaths.isEmpty ? null : () => _clear(context, ref),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.only(bottom: 90),
        child: favPaths.isEmpty
            ? const _FavoritesEmpty()
            : FutureBuilder<List<Song>>(
                // 收藏集合变化时重新查询。
                key: ValueKey(Object.hashAll(favPaths)),
                future: ref
                    .read(libraryProvider.notifier)
                    .songsByPaths(localPaths),
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
                  final songs = <Song>[
                    for (final path in favPaths) ?songsByPath[path],
                  ];
                  if (songs.isEmpty) {
                    return const Center(child: Text('收藏的歌曲已不在音乐库中'));
                  }
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: Row(
                          children: [
                            Text(
                              '${songs.length} 首歌曲',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const Spacer(),
                            FilledButton.tonalIcon(
                              onPressed: () => ref
                                  .read(libraryProvider.notifier)
                                  .playAll(songs),
                              icon: const Icon(Icons.play_arrow, size: 20),
                              label: const Text('播放全部'),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: SongsListView(
                          songs: songs,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          onPlay: (list, i) => ref
                              .read(libraryProvider.notifier)
                              .playList(list, i),
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
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
