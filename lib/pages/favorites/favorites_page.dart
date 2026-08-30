import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/favorites/favorites_provider.dart';
import '../../src/core/settings.dart';
import '../../src/library/library_provider.dart';
import '../../src/player/player_provider.dart';
import '../../src/navigation/sidebar_controller.dart';
import '../../src/widgets/song_list_view.dart';

/// 收藏页：展示已收藏的歌曲，点击即播放整个收藏列表。
class FavoritesPage extends ConsumerStatefulWidget {
  const FavoritesPage({super.key});

  @override
  ConsumerState<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends ConsumerState<FavoritesPage> {
  String _query = '';
  _FavoriteSortOrder _sortOrder = _FavoriteSortOrder.newestFirst;
  Future<List<Song>>? _songsFuture;
  int? _songsFutureKey;
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

  Future<void> _clear(BuildContext context) async {
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

  void _toggleSortOrder() {
    final next = _sortOrder == _FavoriteSortOrder.newestFirst
        ? _FavoriteSortOrder.oldestFirst
        : _FavoriteSortOrder.newestFirst;
    setState(() => _sortOrder = next);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          next == _FavoriteSortOrder.newestFirst ? '已按最新收藏排序' : '已按最早收藏排序',
        ),
        duration: const Duration(seconds: 1),
      ),
    );
  }

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
        title: const Text('我的收藏'),
        actions: [
          if (sidebarOnRight) const AppSidebarMenuButton(),
          IconButton(
            tooltip: _sortOrder == _FavoriteSortOrder.newestFirst
                ? '排序：最新收藏在前'
                : '排序：最早收藏在前',
            onPressed: _toggleSortOrder,
            icon: Icon(
              _sortOrder == _FavoriteSortOrder.newestFirst
                  ? Icons.south_rounded
                  : Icons.north_rounded,
            ),
          ),
          IconButton(
            tooltip: '清空收藏',
            onPressed: favPaths.isEmpty ? null : () => _clear(context),
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
                  final orderedPaths =
                      _sortOrder == _FavoriteSortOrder.newestFirst
                      ? favPaths.toList().reversed
                      : favPaths;
                  final songs = <Song>[
                    for (final path in orderedPaths) ?songsByPath[path],
                  ];
                  if (songs.isEmpty) {
                    return const Center(child: Text('收藏的歌曲已不在音乐库中'));
                  }
                  final query = _query.trim().toLowerCase();
                  final filteredSongs = query.isEmpty
                      ? songs
                      : songs
                            .where((song) => _matchesQuery(song, query))
                            .toList();
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                        child: TextField(
                          onChanged: (value) => setState(() => _query = value),
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            hintText: '搜索歌曲、歌手或专辑',
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: '清除搜索',
                                    onPressed: () =>
                                        setState(() => _query = ''),
                                    icon: const Icon(Icons.clear_rounded),
                                  ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
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
                                        .read(libraryProvider.notifier)
                                        .playAll(filteredSongs),
                              icon: const Icon(Icons.play_arrow, size: 20),
                              label: const Text('播放全部'),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
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
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
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

  bool _matchesQuery(Song song, String query) {
    return song.title.toLowerCase().contains(query) ||
        song.artist.toLowerCase().contains(query) ||
        song.album.toLowerCase().contains(query) ||
        song.path.toLowerCase().contains(query);
  }
}

enum _FavoriteSortOrder { newestFirst, oldestFirst }

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
