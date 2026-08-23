import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../favorites/favorites_provider.dart';
import '../library/library_provider.dart';
import '../player/player_provider.dart';
import 'cover_image.dart';
import 'top_notice.dart';

/// 通用歌曲列表：手机端以 56dp 以上触控行展示，点击播放、长按或右侧
/// 更多按钮打开桌面端右键菜单对应的底部操作面板。
class SongsListView extends ConsumerWidget {
  final List<Song> songs;
  final Future<void> Function(List<Song> songs, int index)? onPlay;
  final bool showFavoriteButton;
  final bool selectionMode;
  final bool Function(Song song)? isSelected;
  final ValueChanged<Song>? onToggleSelection;

  /// 列表内边距。全屏页可留出底部安全区，嵌在 shell 内的页面可避让底栏。
  final EdgeInsetsGeometry? padding;
  const SongsListView({
    super.key,
    required this.songs,
    this.onPlay,
    this.padding,
    this.showFavoriteButton = false,
    this.selectionMode = false,
    this.isSelected,
    this.onToggleSelection,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (songs.isEmpty) {
      return const Center(child: Text('暂无歌曲'));
    }
    final favorites = ref.watch(favoritesProvider);
    return ListView.builder(
      padding: padding,
      itemCount: songs.length,
      itemBuilder: (context, i) {
        final s = songs[i];
        final isFavorite = favorites.contains(s.path);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(13),
            child: InkWell(
              onTap: () => selectionMode
                  ? onToggleSelection?.call(s)
                  : onPlay?.call(songs, i),
              onLongPress: selectionMode
                  ? () => onToggleSelection?.call(s)
                  : () => _showSongActions(context, ref, s, i),
              borderRadius: BorderRadius.circular(13),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 7, 4, 7),
                child: Row(
                  children: [
                    if (selectionMode)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Checkbox(
                          value: isSelected?.call(s) ?? false,
                          onChanged: (_) => onToggleSelection?.call(s),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    SongCover(song: s),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  s.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (!showFavoriteButton && isFavorite) ...[
                                const SizedBox(width: 5),
                                const Icon(
                                  Icons.favorite,
                                  size: 14,
                                  color: Color(0xFFEC4141),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _subtitle(s),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _fmt(s.duration),
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant.withValues(alpha: .65),
                      ),
                    ),
                    if (!selectionMode && showFavoriteButton)
                      IconButton(
                        tooltip: isFavorite ? '取消收藏' : '收藏',
                        icon: Icon(
                          isFavorite ? Icons.favorite : Icons.favorite_border,
                          size: 21,
                          color: const Color(0xFFEC4141),
                        ),
                        onPressed: () => _toggleFavorite(context, ref, s),
                      ),
                    if (!selectionMode)
                      IconButton(
                      tooltip: '更多',
                      icon: const Icon(Icons.more_vert, size: 20),
                      onPressed: () => _showSongActions(context, ref, s, i),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _subtitle(Song song) {
    final parts = [
      song.artist,
      song.album,
    ].where((part) => part.trim().isNotEmpty).toList();
    return parts.isEmpty ? '未知艺术家' : parts.join(' · ');
  }

  Future<void> _showSongActions(
    BuildContext context,
    WidgetRef ref,
    Song song,
    int index,
  ) async {
    final isFavorite = ref.read(favoritesProvider).contains(song.path);
    final action = await showModalBottomSheet<_SongAction>(
      context: context,
      // 列表位于 Shell 的分支 Navigator 中，而迷你播放栏叠在分支之上。
      // 使用根 Navigator 让操作面板覆盖整个 Shell，避免被播放栏遮挡。
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Row(
                  children: [
                    SongCover(song: song, size: 52),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _subtitle(song),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              _actionTile(context, _SongAction.play, Icons.play_arrow, '播放'),
              _actionTile(context, _SongAction.playNext, Icons.redo, '下一首播放'),
              _actionTile(
                context,
                _SongAction.addToQueue,
                Icons.playlist_add,
                '添加到播放队列',
              ),
              _actionTile(
                context,
                _SongAction.favorite,
                isFavorite ? Icons.favorite : Icons.favorite_border,
                isFavorite ? '取消收藏' : '收藏',
                color: isFavorite ? const Color(0xFFEC4141) : null,
              ),
              _actionTile(
                context,
                _SongAction.info,
                Icons.info_outline,
                '歌曲信息',
              ),
            ],
          ),
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case _SongAction.play:
        await onPlay?.call(songs, index);
        return;
      case _SongAction.playNext:
        await ref.read(playerProvider.notifier).playNext(song.toQueueItem());
        if (context.mounted) _toast(context, '已添加到下一首');
        return;
      case _SongAction.addToQueue:
        await ref.read(playerProvider.notifier).addToQueue(song.toQueueItem());
        if (context.mounted) _toast(context, '已添加到播放队列');
        return;
      case _SongAction.favorite:
        await _toggleFavorite(context, ref, song);
        return;
      case _SongAction.info:
        if (context.mounted) await _showSongInfo(context, song);
        return;
    }
  }

  Future<void> _toggleFavorite(
    BuildContext context,
    WidgetRef ref,
    Song song,
  ) async {
    final added = await ref
        .read(favoritesProvider.notifier)
        .toggle(song.path, song: FavoriteSongSnapshot.fromSong(song));
    if (context.mounted) _toast(context, added ? '已收藏' : '已取消收藏');
  }

  ListTile _actionTile(
    BuildContext context,
    _SongAction action,
    IconData icon,
    String title, {
    Color? color,
  }) => ListTile(
    minTileHeight: 52,
    leading: Icon(icon, color: color),
    title: Text(title, style: TextStyle(color: color)),
    onTap: () => Navigator.pop(context, action),
  );

  void _toast(BuildContext context, String message) => XyNotice.show(
    context,
    message: message,
    duration: const Duration(seconds: 1),
  );

  Future<void> _showSongInfo(BuildContext context, Song song) =>
      showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '歌曲信息',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                _infoRow(context, '标题', song.title),
                _infoRow(context, '歌手', song.artist),
                _infoRow(context, '专辑', song.album),
                _infoRow(context, '格式', song.format.toUpperCase()),
                _infoRow(context, '时长', _fmt(song.duration)),
                _infoRow(context, '路径', song.path),
              ],
            ),
          ),
        ),
      );

  Widget _infoRow(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 52,
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: Text(value.isEmpty ? '未知' : value)),
      ],
    ),
  );

  String _fmt(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
}

class SongCover extends StatelessWidget {
  const SongCover({super.key, required this.song, this.size = 44});
  final Song song;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CoverImage(
      songPath: song.path,
      imageUrl: song.coverUrl,
      width: size,
      height: size,
      radius: 10,
      icon: Icons.music_note,
    );
  }
}

enum _SongAction { play, playNext, addToQueue, favorite, info }
