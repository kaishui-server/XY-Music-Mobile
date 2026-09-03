import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/library/library_provider.dart';
import '../../src/recent/recent_provider.dart';
import '../../src/core/settings.dart';
import '../../src/navigation/sidebar_controller.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/top_notice.dart' show XyNotice, XyNoticeType;

class RecentPage extends ConsumerStatefulWidget {
  const RecentPage({super.key});

  @override
  ConsumerState<RecentPage> createState() => _RecentPageState();
}

class _RecentPageState extends ConsumerState<RecentPage> {
  int _segment = 0;
  bool _searching = false;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空最近播放'),
        content: const Text('这会移除全部最近播放记录，但不会删除音乐文件。'),
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
    if (confirmed == true) await clearRecentSongs(ref);
  }

  @override
  Widget build(BuildContext context) {
    final recent = ref.watch(recentSongsProvider);
    final sidebarOnRight = ref.watch(
      settingsProvider.select(
        (value) => value.valueOrNull?.sidebarPosition == SidebarPosition.right,
      ),
    );
    final keyword = _query.toLowerCase();
    final entries = recent.valueOrNull ?? const <RecentSongEntry>[];
    final filteredEntries = keyword.isEmpty
        ? entries
        : entries
              .where(
                (entry) =>
                    entry.song.title.toLowerCase().contains(keyword) ||
                    entry.song.artist.toLowerCase().contains(keyword) ||
                    entry.song.album.toLowerCase().contains(keyword),
              )
              .toList();
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !sidebarOnRight,
        leading: sidebarOnRight ? null : const AppSidebarMenuButton(),
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: '搜索最近播放',
                  border: InputBorder.none,
                ),
                onChanged: (value) => setState(() => _query = value.trim()),
              )
            : const Text('最近播放'),
        actions: [
          if (sidebarOnRight) const AppSidebarMenuButton(),
          IconButton(
            tooltip: _searching ? '取消' : '搜索',
            onPressed: () {
              setState(() {
                _searching = !_searching;
                if (!_searching) {
                  _query = '';
                  _searchController.clear();
                }
              });
            },
            icon: Icon(
              _searching ? Icons.close_rounded : Icons.search_rounded,
            ),
          ),
          IconButton(
            tooltip: '清空记录',
            onPressed: recent.valueOrNull?.isNotEmpty == true ? _clear : null,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                      value: 0,
                      icon: Icon(Icons.music_note, size: 18),
                      label: Text('歌曲'),
                    ),
                    ButtonSegment(
                      value: 1,
                      icon: Icon(Icons.album_outlined, size: 18),
                      label: Text('专辑'),
                    ),
                  ],
                  selected: {_segment},
                  onSelectionChanged: (value) =>
                      setState(() => _segment = value.first),
                  showSelectedIcon: false,
                ),
              ),
            ),
          Expanded(
            child: recent.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _RecentError(
                error: '$error',
                onRetry: () => ref.invalidate(recentSongsProvider),
              ),
              data: (allEntries) => allEntries.isEmpty
                  ? const _RecentEmpty()
                  : _searching && filteredEntries.isEmpty
                  ? const _RecentSearchEmpty()
                  : _segment == 0
                  ? _RecentSongs(entries: filteredEntries)
                  : _RecentAlbums(entries: filteredEntries),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentSongs extends ConsumerWidget {
  const _RecentSongs({required this.entries});

  final List<RecentSongEntry> entries;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songs = entries.map((entry) => entry.song).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(
                '${songs.length} 首',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              FilledButton.tonalIcon(
                onPressed: () =>
                    ref.read(libraryProvider.notifier).playAll(songs),
                icon: const Icon(Icons.play_arrow, size: 20),
                label: const Text('播放全部'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: SongsListView(
            songs: songs,
            // 底部留出迷你播放栏与浮动按钮组的空间。
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 148),
            onPlay: (list, index) =>
                ref.read(libraryProvider.notifier).playList(list, index),
            removeActionLabel: '从最近播放删除',
            onRemoveAction: (song) async {
              await removeRecentSong(ref, song);
              if (context.mounted) {
                XyNotice.show(
                  context,
                  message: '已从最近播放删除',
                  type: XyNoticeType.success,
                  duration: const Duration(seconds: 1),
                );
              }
            },
          ),
        ),
      ],
    );
  }
}

class _RecentAlbums extends ConsumerWidget {
  const _RecentAlbums({required this.entries});

  final List<RecentSongEntry> entries;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = <String, List<Song>>{};
    for (final entry in entries) {
      final key = entry.song.albumKey.isNotEmpty
          ? entry.song.albumKey
          : '${entry.song.album}\u0000${entry.song.artist}';
      groups.putIfAbsent(key, () => []).add(entry.song);
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 90),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 18,
        crossAxisSpacing: 14,
        childAspectRatio: .78,
      ),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final songs = groups.values.elementAt(index);
        final first = songs.first;
        return InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => ref.read(libraryProvider.notifier).playAll(songs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CoverImage(
                      songPath: first.path,
                      imageUrl: first.coverUrl,
                      radius: 16,
                      icon: Icons.album,
                    ),
                    Positioned(
                      right: 10,
                      bottom: 10,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          color: Color(0xFFEC4141),
                          shape: BoxShape.circle,
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(9),
                          child: Icon(
                            Icons.play_arrow,
                            color: Colors.white,
                            size: 21,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                first.album.isEmpty ? '未知专辑' : first.album,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                '${first.artist} · ${songs.length} 首',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RecentEmpty extends StatelessWidget {
  const _RecentEmpty();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.only(bottom: 100),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.history_rounded,
            size: 58,
            color: Theme.of(
              context,
            ).colorScheme.onSurfaceVariant.withValues(alpha: .4),
          ),
          const SizedBox(height: 14),
          const Text(
            '还没有播放记录',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            '播放一首歌曲后会出现在这里',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

class _RecentSearchEmpty extends StatelessWidget {
  const _RecentSearchEmpty();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.only(bottom: 100),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 52,
            color: Theme.of(
              context,
            ).colorScheme.onSurfaceVariant.withValues(alpha: .4),
          ),
          const SizedBox(height: 12),
          const Text(
            '没有匹配的播放记录',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    ),
  );
}

class _RecentError extends StatelessWidget {
  const _RecentError({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 42),
          const SizedBox(height: 12),
          Text('加载最近播放失败\n$error', textAlign: TextAlign.center),
          const SizedBox(height: 14),
          FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    ),
  );
}
