import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/favorites/favorites_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/player/player_provider.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/plugins/plugin_runtime.dart';
import '../../src/widgets/batch_action_sheet.dart';
import '../../src/widgets/batch_download.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/source_switch.dart';
import '../../src/widgets/top_notice.dart';

/// 在线歌单页右上角「更多」菜单项（与音乐库-歌单详情页同款）。
enum _OnlinePlaylistMenuAction {
  batchDownload,
  batchSwitchSource,
  batchSaveToPlaylist,
  batchFavorite,
  refresh,
}

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

  // 批量换源进度（右上角「更多」菜单触发）。
  bool _switchingSource = false;
  int _switchingDone = 0;
  int _switchingTotal = 0;

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
        // 歌单名称已由顶部信息卡展示，顶栏不再重复；换源时临时显示进度。
        title: Text(
          isPlaylist
              ? (_switchingSource
                    ? '换源中 $_switchingDone/$_switchingTotal'
                    : '')
              : widget.categoryLabel,
        ),
        // 歌单页复用音乐库-歌单详情页的「更多」菜单。
        actions: isPlaylist
            ? [
                PopupMenuButton<_OnlinePlaylistMenuAction>(
                  tooltip: '更多',
                  icon: const Icon(Icons.more_vert_rounded),
                  onSelected: _onMenuAction,
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: _OnlinePlaylistMenuAction.batchDownload,
                      child: Text('批量下载'),
                    ),
                    PopupMenuItem(
                      value: _OnlinePlaylistMenuAction.batchSwitchSource,
                      child: Text('批量换源'),
                    ),
                    PopupMenuItem(
                      value: _OnlinePlaylistMenuAction.batchSaveToPlaylist,
                      child: Text('批量保存到歌单'),
                    ),
                    PopupMenuItem(
                      value: _OnlinePlaylistMenuAction.batchFavorite,
                      child: Text('批量收藏'),
                    ),
                    PopupMenuItem(
                      value: _OnlinePlaylistMenuAction.refresh,
                      child: Text('刷新'),
                    ),
                  ],
                ),
              ]
            : null,
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
                                const SizedBox(height: 10),
                                FilledButton.tonalIcon(
                                  onPressed: _loading || _songs.isEmpty
                                      ? null
                                      : _showAddToPlaylist,
                                  icon: const Icon(Icons.playlist_add_rounded),
                                  label: const Text('添加到歌单'),
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
                        // 本页自绘迷你播放栏（未注入遮挡高度），浮动按钮组
                        // 需自行避让播放栏。
                        ownMiniPlayerBar: true,
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
      useRootNavigator: true,
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

  /// 右上角「更多」菜单：批量下载 / 批量换源 / 批量保存到歌单 / 批量收藏 /
  /// 刷新（与音乐库-歌单详情页同款）。
  Future<void> _onMenuAction(_OnlinePlaylistMenuAction action) async {
    if (action != _OnlinePlaylistMenuAction.refresh && _songs.isEmpty) {
      XyNotice.show(
        context,
        message: '暂无可操作的歌曲',
        type: XyNoticeType.warning,
        compact: true,
      );
      return;
    }
    switch (action) {
      case _OnlinePlaylistMenuAction.batchDownload:
        await showBatchActionSheet(
          context,
          kind: BatchActionKind.download,
          songs: _songs,
          onDownload: (selected, quality) => runBatchDownload(
            context,
            ref,
            songs: selected,
            qualityOverride: quality,
          ),
        );
      case _OnlinePlaylistMenuAction.batchSwitchSource:
        await showBatchActionSheet(
          context,
          kind: BatchActionKind.switchSource,
          songs: _songs,
          onSwitchSource: (selected, plugin, lxSource) =>
              _switchSourceFor(selected, plugin, lxSource),
        );
      case _OnlinePlaylistMenuAction.batchSaveToPlaylist:
        await showBatchActionSheet(
          context,
          kind: BatchActionKind.saveToPlaylist,
          songs: _songs,
          onSaveToPlaylist: (selected, playlistId) =>
              _saveToPlaylist(selected, playlistId),
        );
      case _OnlinePlaylistMenuAction.batchFavorite:
        await showBatchActionSheet(
          context,
          kind: BatchActionKind.favorite,
          songs: _songs,
          onFavorite: _favoriteSongs,
        );
      case _OnlinePlaylistMenuAction.refresh:
        await _loadSongs();
        if (mounted) {
          XyNotice.show(
            context,
            message: '已刷新',
            type: XyNoticeType.success,
            compact: true,
          );
        }
    }
  }

  /// 批量收藏：把所选歌曲添加到收藏，已在收藏中的自动跳过。
  Future<void> _favoriteSongs(List<Song> selected) async {
    if (selected.isEmpty) return;
    final added = await ref
        .read(favoritesProvider.notifier)
        .addAll(selected.map(FavoriteSongSnapshot.fromSong));
    if (!mounted) return;
    final message = added > 0 ? '已收藏 $added 首歌曲' : '所选歌曲均已在收藏中';
    XyNotice.show(
      context,
      message: message,
      type: added > 0 ? XyNoticeType.success : XyNoticeType.warning,
    );
  }

  /// 批量保存到歌单：把所选歌曲加入目标歌单，已存在的自动跳过。
  Future<void> _saveToPlaylist(List<Song> selected, String playlistId) async {
    if (selected.isEmpty) return;
    final (added, exists) = await ref
        .read(playlistsProvider.notifier)
        .addQueueItems(playlistId, [
          for (final song in selected) song.toQueueItem(),
        ]);
    if (!mounted) return;
    final message = added > 0
        ? '已添加 $added 首到歌单${exists > 0 ? '，$exists 首已存在' : ''}'
        : '所选歌曲均已在歌单中';
    XyNotice.show(
      context,
      message: message,
      type: added > 0 ? XyNoticeType.success : XyNoticeType.warning,
    );
  }

  /// 批量换源：逐首搜索同名歌曲，原位替换本页歌曲（在线歌单不落库，
  /// 直接更新内存列表）。
  Future<void> _switchSourceFor(
    List<Song> selected,
    EnabledMusicPlugin plugin,
    String? lxSource,
  ) async {
    if (selected.isEmpty || _switchingSource) return;
    setState(() {
      _switchingSource = true;
      _switchingDone = 0;
      _switchingTotal = selected.length;
    });
    final replacements = <String, Song>{};
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
          lxSource: lxSource,
        );
        if (candidates.isEmpty) {
          missed.add(song.title);
          continue;
        }
        replacements[song.path] = replacementToSong(plugin, candidates.first);
      } catch (_) {
        missed.add(song.title);
      }
    }
    if (!mounted) return;
    setState(() {
      _switchingSource = false;
      _songs = [for (final song in _songs) replacements[song.path] ?? song];
    });
    if (replacements.isEmpty) {
      XyNotice.show(
        context,
        message: '未找到可用的替换源',
        type: XyNoticeType.warning,
      );
    } else if (missed.isEmpty) {
      XyNotice.show(
        context,
        message: '已换源 ${replacements.length} 首',
        type: XyNoticeType.success,
      );
    } else {
      XyNotice.show(
        context,
        message: '已换源 ${replacements.length} 首，${missed.length} 首未找到',
        type: XyNoticeType.warning,
      );
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
                // 网易等音源 CDN 对 Dart 默认 UA 返回 403，需带浏览器请求头。
                headers: coverImageNetworkHeaders(coverUrl),
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
