import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/library/library_provider.dart';
import '../../src/player/player_provider.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/top_notice.dart';

/// 网络歌手、专辑、歌单详情页。
///
/// 分类搜索结果本身只包含摘要信息。页面先立即打开，再在页面内加载歌曲，
/// 避免点击后等待插件接口返回造成明显延迟。
class OnlineCatalogDetailPage extends ConsumerStatefulWidget {
  const OnlineCatalogDetailPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.coverUrl,
    required this.categoryLabel,
    required this.loadSongs,
  });

  final String title;
  final String subtitle;
  final String coverUrl;
  final String categoryLabel;
  final Future<List<Song>> Function() loadSongs;

  @override
  ConsumerState<OnlineCatalogDetailPage> createState() =>
      _OnlineCatalogDetailPageState();
}

class _OnlineCatalogDetailPageState
    extends ConsumerState<OnlineCatalogDetailPage> {
  static const _pageSize = 30;

  List<Song> _songs = const [];
  Object? _error;
  bool _loading = true;
  var _visibleSongCount = _pageSize;
  final ScrollController _songsController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadSongs();
  }

  Future<void> _loadSongs() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final songs = await widget.loadSongs();
      if (!mounted) return;
      setState(() {
        _songs = songs;
        _visibleSongCount = _pageSize;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _songsController.dispose();
    super.dispose();
  }

  void _showMoreSongs() {
    if (!mounted || _visibleSongCount >= _songs.length) return;
    setState(() {
      _visibleSongCount = (_visibleSongCount + _pageSize).clamp(
        0,
        _songs.length,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isPlaylist = widget.categoryLabel == '歌单';
    final current = ref.watch(
      playerProvider.select((state) => state.current != null),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(isPlaylist ? widget.title : widget.categoryLabel),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              isPlaylist
                  ? _OnlinePlaylistHero(
                      title: widget.title,
                      subtitle: widget.subtitle,
                      coverUrl: widget.coverUrl,
                      songCount: _songs.length,
                      loading: _loading,
                      onPlayAll: _loading || _songs.isEmpty
                          ? null
                          : () => ref
                                .read(libraryProvider.notifier)
                                .playAll(_songs),
                      onAddToPlaylist: _loading || _songs.isEmpty
                          ? null
                          : _showAddToPlaylist,
                    )
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _CatalogCover(
                            coverUrl: widget.coverUrl,
                            isArtist:
                                widget.categoryLabel == '歌手' ||
                                widget.categoryLabel == 'UP主',
                            isPlaylist: false,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 7),
                                Text(
                                  widget.subtitle.trim().isEmpty
                                      ? '网络${widget.categoryLabel}'
                                      : widget.subtitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  _loading ? '正在加载歌曲…' : '${_songs.length} 首歌曲',
                                  style: TextStyle(
                                    color: scheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
              const Divider(height: 1),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? _LoadError(
                        message: _error.toString().replaceFirst(
                          'Exception: ',
                          '',
                        ),
                        onRetry: _loadSongs,
                      )
                    : _songs.isEmpty
                    ? Center(
                        child: Text(
                          '未找到“${widget.title}”的歌曲',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      )
                    : SongsListView(
                        songs: _songs.take(_visibleSongCount).toList(),
                        controller: _songsController,
                        showFavoriteButton: true,
                        padding: EdgeInsets.only(
                          top: 6,
                          // 底部留出迷你播放栏与浮动按钮组的空间。
                          bottom:
                              MediaQuery.of(context).padding.bottom +
                              (current ? 148 : 16),
                        ),
                        footer: _visibleSongCount < _songs.length
                            ? Padding(
                                padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
                                child: TextButton(
                                  onPressed: _showMoreSongs,
                                  child: const Text('继续显示'),
                                ),
                              )
                            : const SizedBox(height: 8),
                        onPlay: (list, index) => ref
                            .read(libraryProvider.notifier)
                            .playList(list, index),
                      ),
              ),
            ],
          ),
          if (current)
            Positioned(
              left: 12,
              right: 12,
              bottom: MediaQuery.paddingOf(context).bottom + 20,
              child: const MiniPlayerBar(),
            ),
        ],
      ),
    );
  }

  Future<void> _showAddToPlaylist() async {
    if (_songs.isEmpty || !mounted) return;
    final target = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (dialogContext) {
        final playlists = ref.read(playlistsProvider);
        final colors = Theme.of(dialogContext).colorScheme;
        return SizedBox(
          height: MediaQuery.sizeOf(dialogContext).height * .68,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(22, 0, 22, 4),
                child: Text(
                  '添加到歌单',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 14),
                child: Text(
                  '${_songs.length} 首歌曲 · 选择一个目标歌单',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: colors.primaryContainer,
                  child: Icon(Icons.add_rounded, color: colors.primary),
                ),
                title: const Text('新建歌单'),
                subtitle: const Text('创建后自动添加这些歌曲'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.pop(dialogContext, '__new__'),
              ),
              const Divider(height: 1),
              Expanded(
                child: playlists.isEmpty
                    ? Center(
                        child: Text(
                          '还没有其他歌单，请先新建一个',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 16),
                        itemCount: playlists.length,
                        itemBuilder: (context, index) {
                          final playlist = playlists[index];
                          final firstPath = playlist.songPaths.isEmpty
                              ? playlist.id
                              : playlist.songPaths.first;
                          return ListTile(
                            leading: _PlaylistCoverImage(
                              songPath: firstPath,
                              imageUrl: playlist.effectiveCoverUrl,
                            ),
                            title: Text(
                              playlist.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text('${playlist.songPaths.length} 首歌曲'),
                            trailing: const Icon(
                              Icons.add_circle_outline_rounded,
                            ),
                            onTap: () =>
                                Navigator.pop(dialogContext, playlist.id),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || target == null) return;
    final notifier = ref.read(playlistsProvider.notifier);
    if (target == '__new__') {
      final name = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          final controller = TextEditingController();
          return AlertDialog(
            title: const Text('新建歌单'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: '输入歌单名称'),
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
          );
        },
      );
      if (!mounted || name == null || name.trim().isEmpty) return;
      await notifier.create(name.trim(), songs: _songs);
    } else {
      await notifier.mergeImportedSongs(target, _songs);
    }
    if (mounted) {
      XyNotice.show(context, message: '已添加到歌单', type: XyNoticeType.success);
    }
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('加载失败：$message'),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _CatalogCover extends StatelessWidget {
  const _CatalogCover({
    required this.coverUrl,
    required this.isArtist,
    required this.isPlaylist,
    this.size = 92,
  });

  final String coverUrl;
  final bool isArtist;
  final bool isPlaylist;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(isArtist ? size / 2 : 12),
      child: SizedBox(
        width: size,
        height: size,
        child: coverUrl.trim().isEmpty
            ? ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Icon(
                  isArtist
                      ? Icons.person_outline_rounded
                      : isPlaylist
                      ? Icons.queue_music_rounded
                      : Icons.album_outlined,
                  size: 38,
                  color: scheme.onSurfaceVariant,
                ),
              )
            : Image.network(
                coverUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(
                    isArtist
                        ? Icons.person_outline_rounded
                        : isPlaylist
                        ? Icons.queue_music_rounded
                        : Icons.album_outlined,
                    size: 38,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
      ),
    );
  }
}

class _OnlinePlaylistHero extends StatelessWidget {
  const _OnlinePlaylistHero({
    required this.title,
    required this.subtitle,
    required this.coverUrl,
    required this.songCount,
    required this.loading,
    required this.onPlayAll,
    required this.onAddToPlaylist,
  });

  final String title;
  final String subtitle;
  final String coverUrl;
  final int songCount;
  final bool loading;
  final VoidCallback? onPlayAll;
  final VoidCallback? onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CatalogCover(
            coverUrl: coverUrl,
            isArtist: false,
            isPlaylist: true,
            size: 124,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${subtitle.trim().isEmpty ? '网络歌单' : subtitle} · '
                  '${loading ? '正在加载' : '$songCount 首歌曲'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: onPlayAll,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('播放全部'),
                    ),
                    IconButton(
                      tooltip: '添加到歌单',
                      onPressed: onAddToPlaylist,
                      icon: const Icon(Icons.playlist_add_rounded),
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

class _PlaylistCoverImage extends StatelessWidget {
  const _PlaylistCoverImage({required this.songPath, required this.imageUrl});

  final String songPath;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    return CoverImage(
      songPath: songPath,
      imageUrl: imageUrl,
      width: 46,
      height: 46,
      radius: 12,
      icon: Icons.queue_music_rounded,
    );
  }
}
