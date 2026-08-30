import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../favorites/favorites_provider.dart';
import '../library/library_provider.dart';
import '../player/player_provider.dart';
import 'cover_image.dart';
import 'top_notice.dart';

/// 通用歌曲列表：手机端以 56dp 以上触控行展示，点击播放、长按或右侧
/// 更多按钮打开桌面端右键菜单对应的底部操作面板。
class SongsListView extends ConsumerStatefulWidget {
  final List<Song> songs;
  final Future<void> Function(List<Song> songs, int index)? onPlay;
  final bool showFavoriteButton;
  final bool selectionMode;
  final bool Function(Song song)? isSelected;
  final ValueChanged<Song>? onToggleSelection;
  final ScrollController? controller;
  final Widget? footer;

  /// 每首歌的“更多”面板里额外注入的操作标题（如最近播放页的
  /// “从最近播放删除”）。回调执行删除，组件负责刷新。
  final Future<void> Function(Song song)? onRemoveAction;

  /// 注入操作显示的菜单标题。
  final String? removeActionLabel;

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
    this.controller,
    this.footer,
    this.onRemoveAction,
    this.removeActionLabel,
  });

  @override
  ConsumerState<SongsListView> createState() => _SongsListViewState();
}

class _SongsListViewState extends ConsumerState<SongsListView> {
  ScrollController? _internalController;

  ScrollController get _controller =>
      widget.controller ?? (_internalController ??= ScrollController());

  @override
  void initState() {
    super.initState();
  }

  @override
  void didUpdateWidget(covariant SongsListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _internalController?.dispose();
      _internalController = null;
    }
  }

  @override
  void dispose() {
    _internalController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.songs.isEmpty) {
      return const Center(child: Text('暂无歌曲'));
    }
    final favorites = ref.watch(favoritesProvider);
    final hasCurrentSong = ref.watch(
      playerProvider.select((state) => state.current != null),
    );
    return Stack(
      children: [
        ListView.builder(
          controller: _controller,
          padding: widget.padding,
          itemCount: widget.songs.length + (widget.footer == null ? 0 : 1),
          itemBuilder: (context, i) {
            if (i == widget.songs.length) return widget.footer!;
            final s = widget.songs[i];
            final isFavorite = favorites.contains(s.path);
            // RepaintBoundary 把每行圈成独立重绘范围：多选勾选或收藏状态
            // 变化时只重绘对应行，避免整个列表跟着重绘造成卡顿。
            return RepaintBoundary(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 2,
                  vertical: 3,
                ),
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(13),
                  child: InkWell(
                    onTap: () => widget.selectionMode
                        ? widget.onToggleSelection?.call(s)
                        : widget.onPlay?.call(widget.songs, i),
                    onLongPress: widget.selectionMode
                        ? () => widget.onToggleSelection?.call(s)
                        : () => _showSongActions(context, ref, s, i),
                    borderRadius: BorderRadius.circular(13),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 7, 4, 7),
                      child: Row(
                        children: [
                          if (widget.selectionMode)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Checkbox(
                                value: widget.isSelected?.call(s) ?? false,
                                onChanged: (_) =>
                                    widget.onToggleSelection?.call(s),
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
                                    if (!widget.showFavoriteButton &&
                                        isFavorite) ...[
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
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant
                                  .withValues(alpha: .65),
                            ),
                          ),
                          if (!widget.selectionMode &&
                              widget.showFavoriteButton)
                            IconButton(
                              tooltip: isFavorite ? '取消收藏' : '收藏',
                              icon: Icon(
                                isFavorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                size: 21,
                                color: const Color(0xFFEC4141),
                              ),
                              onPressed: () =>
                                  _toggleFavorite(context, ref, s),
                            ),
                          if (!widget.selectionMode)
                            IconButton(
                              tooltip: '更多',
                              icon: const Icon(Icons.more_vert, size: 20),
                              onPressed: () =>
                                  _showSongActions(context, ref, s, i),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        ScrollToTopButton(
          controller: _controller,
          hasMiniPlayer: hasCurrentSong,
        ),
      ],
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
              if (widget.onRemoveAction != null)
                _actionTile(
                  context,
                  _SongAction.removeFromRecent,
                  Icons.playlist_remove_outlined,
                  widget.removeActionLabel ?? '移除',
                ),
            ],
          ),
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case _SongAction.play:
        await widget.onPlay?.call(widget.songs, index);
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
      case _SongAction.removeFromRecent:
        await widget.onRemoveAction?.call(song);
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
      // 按 3 倍逻辑像素解码即可覆盖主流高清屏；不限制会把 480px 级别的
      // 网络封面整张解码进纹理，长列表滚动时明显增加内存与解码开销。
      cacheWidth: (size * 3).round(),
      icon: Icons.music_note,
    );
  }
}

/// 长列表统一使用的回到顶部按钮。该组件只能放在 Stack 中，未滚动到
/// 较低位置时不占用空间，避免遮挡列表内容。
class ScrollToTopButton extends StatefulWidget {
  const ScrollToTopButton({
    super.key,
    required this.controller,
    this.hasMiniPlayer = false,
  });

  final ScrollController controller;
  final bool hasMiniPlayer;

  @override
  State<ScrollToTopButton> createState() => _ScrollToTopButtonState();
}

class _ScrollToTopButtonState extends State<ScrollToTopButton> {
  var _visible = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleScroll);
  }

  @override
  void didUpdateWidget(covariant ScrollToTopButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleScroll);
      widget.controller.addListener(_handleScroll);
      _visible = false;
    }
  }

  void _handleScroll() {
    final visible =
        widget.controller.hasClients && widget.controller.offset > 180;
    if (visible != _visible && mounted) setState(() => _visible = visible);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleScroll);
    super.dispose();
  }

  void _scrollToTop() {
    if (!widget.controller.hasClients) return;
    widget.controller.animateTo(
      0,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return Positioned(
      right: 20,
      bottom:
          MediaQuery.paddingOf(context).bottom +
          (widget.hasMiniPlayer ? 104 : 24),
      child: FloatingActionButton.small(
        heroTag: null,
        tooltip: '回到顶部',
        onPressed: _scrollToTop,
        child: const Icon(Icons.keyboard_arrow_up_rounded),
      ),
    );
  }
}

enum _SongAction {
  play,
  playNext,
  addToQueue,
  favorite,
  info,
  removeFromRecent,
}
