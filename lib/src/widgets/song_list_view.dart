import 'dart:async';

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

  /// 开启后列表支持拖拽排序（行首出现手柄）。回调语义与
  /// ReorderableListView.onReorderItem 一致：newIndex 已按移除
  /// oldIndex 项后的目标位置给出，无需手动减一。传 null 表示当前
  /// 场景不允许拖拽（如搜索过滤中）。
  final void Function(int oldIndex, int newIndex)? onReorder;

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
    this.onReorder,
    this.onRemoveAction,
    this.removeActionLabel,
  });

  @override
  ConsumerState<SongsListView> createState() => _SongsListViewState();
}

class _SongsListViewState extends ConsumerState<SongsListView> {
  ScrollController? _internalController;

  /// 定位正在播放歌曲后的短暂高亮行（歌曲路径），超时自动清除。
  String? _highlightPath;
  Timer? _highlightTimer;

  /// 行高按首行实测修正：行内有 48dp 的 IconButton，实际高度可能
  /// 大于估算值（44 + 7×2 + 3×2 = 64）。写死会让定位滚动位置随
  /// 行数累积偏差，越靠下的歌曲偏得越多。
  double _rowExtent = 64;

  /// 首行测量 Key：布局完成后读取真实行高修正 _rowExtent。
  final GlobalKey _firstRowKey = GlobalKey();

  ScrollController get _controller =>
      widget.controller ?? (_internalController ??= ScrollController());

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
    _highlightTimer?.cancel();
    _internalController?.dispose();
    super.dispose();
  }

  /// 定位到正在播放的歌曲：滚动到对应行并短暂高亮。定位按钮的
  /// 显隐由 _FloatingListButtons 根据滚动位置自动维护（接近即隐藏）。
  void _locatePlaying() {
    final path = ref.read(playerProvider).current?.path;
    final index =
        path == null ? -1 : widget.songs.indexWhere((s) => s.path == path);
    if (index < 0) {
      XyNotice.show(
        context,
        message: '正在播放的歌曲不在此列表中',
        duration: const Duration(seconds: 2),
      );
      return;
    }
    if (!_controller.hasClients) return;
    final target = (index * _rowExtent)
        .clamp(0.0, _controller.position.maxScrollExtent)
        .toDouble();
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
    setState(() => _highlightPath = path);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _highlightPath = null);
    });
  }

  /// 布局完成后用首行真实高度修正行高估算值，保证定位滚动准确。
  void _measureFirstRow() {
    if (!mounted) return;
    final size = _firstRowKey.currentContext?.size;
    if (size == null || size.height <= 0) return;
    if ((size.height - _rowExtent).abs() > 0.5) {
      setState(() => _rowExtent = size.height);
    }
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
    final playingPath = ref.watch(
      playerProvider.select((state) => state.current?.path),
    );
    // 播放歌曲在列表中时给出目标行位置，定位按钮据此判断远近。
    int playingIndex = -1;
    if (playingPath != null) {
      playingIndex = widget.songs.indexWhere((s) => s.path == playingPath);
    }
    final playingTarget = playingIndex < 0 ? null : playingIndex * _rowExtent;
    // 布局完成后测量首行真实高度，修正定位滚动的行高估算。
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureFirstRow());
    // 列表类型只取决于 onReorder：多选/普通模式共用同一棵滚动视图，
    // 避免进入多选时因切换 ListView/ReorderableListView 丢失滚动位置。
    final reorderable = widget.onReorder != null;
    return Stack(
      children: [
        if (reorderable)
          ReorderableListView.builder(
            scrollController: _controller,
            padding: widget.padding as EdgeInsets?,
            itemCount: widget.songs.length + (widget.footer == null ? 0 : 1),
            onReorderItem: widget.onReorder!,
            itemBuilder: (context, i) => _buildRow(
              context,
              i,
              favorites: favorites,
              dragIndex:
                  i < widget.songs.length && !widget.selectionMode ? i : -1,
            ),
          )
        else
          ListView.builder(
            controller: _controller,
            padding: widget.padding,
            itemCount: widget.songs.length + (widget.footer == null ? 0 : 1),
            itemBuilder: (context, i) => _buildRow(
              context,
              i,
              favorites: favorites,
              dragIndex: -1,
            ),
          ),
        _FloatingListButtons(
          controller: _controller,
          hasMiniPlayer: hasCurrentSong,
          playingTarget: playingTarget,
          onLocatePlaying: _locatePlaying,
        ),
      ],
    );
  }

  /// 构建第 i 行（i == songs.length 时为 footer）。dragIndex >= 0 时
  /// 行首显示拖拽手柄；footer 行传 -1 不显示手柄。
  Widget _buildRow(
    BuildContext context,
    int i, {
    required Set<String> favorites,
    required int dragIndex,
  }) {
    if (i == widget.songs.length) {
      return KeyedSubtree(key: const ValueKey('songs-footer'), child: widget.footer!);
    }
    final s = widget.songs[i];
    final isFavorite = favorites.contains(s.path);
    final highlighted = _highlightPath == s.path;
    // RepaintBoundary 把每行圈成独立重绘范围：多选勾选或收藏状态
    // 变化时只重绘对应行，避免整个列表跟着重绘造成卡顿。
    return RepaintBoundary(
      key: ValueKey(s.path),
      child: Padding(
        // 首行挂测量 Key，布局后读取真实行高。
        key: i == 0 ? _firstRowKey : null,
        padding: const EdgeInsets.symmetric(
          horizontal: 2,
          vertical: 3,
        ),
        child: Material(
          color: highlighted
              ? Theme.of(context).colorScheme.primary.withValues(alpha: .16)
              : Colors.transparent,
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
                    )
                  else if (dragIndex >= 0)
                    // 与插件管理列表一致的拖拽手柄：只有手柄区域可发起排序。
                    ReorderableDragStartListener(
                      index: dragIndex,
                      child: SizedBox(
                        width: 34,
                        height: 44,
                        child: Icon(
                          Icons.drag_indicator_rounded,
                          size: 22,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant,
                        ),
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

/// 歌曲列表右下角的浮动按钮组：回到顶部 / 回到底部 / 定位正在播放。
/// 紧贴迷你播放栏上沿；已到顶（或到底）时对应按钮自动隐藏，滚动
/// 位置离正在播放歌曲较远时定位按钮显示，接近（约半屏内）时隐藏。
class _FloatingListButtons extends StatefulWidget {
  const _FloatingListButtons({
    required this.controller,
    required this.hasMiniPlayer,
    required this.playingTarget,
    required this.onLocatePlaying,
  });

  final ScrollController controller;

  /// 正在播放歌曲不在列表中（或未播放）时定位按钮整体隐藏。
  final bool hasMiniPlayer;

  /// 正在播放歌曲行的目标滚动偏移（index × 行高）。
  final double? playingTarget;
  final VoidCallback onLocatePlaying;

  @override
  State<_FloatingListButtons> createState() => _FloatingListButtonsState();
}

class _FloatingListButtonsState extends State<_FloatingListButtons> {
  bool _canTop = false;
  bool _canBottom = false;
  bool _showLocate = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleScroll);
    // 首帧布局完成后才有 maxScrollExtent / viewport，才能判断状态。
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleScroll());
  }

  @override
  void didUpdateWidget(covariant _FloatingListButtons oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleScroll);
      widget.controller.addListener(_handleScroll);
      _canTop = false;
      _canBottom = false;
      _showLocate = false;
    }
    // 切歌或列表重排后重算远近。
    if (oldWidget.playingTarget != widget.playingTarget) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _handleScroll());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleScroll);
    super.dispose();
  }

  void _handleScroll() {
    if (!mounted || !widget.controller.hasClients) return;
    final position = widget.controller.position;
    final canTop = position.pixels > 24;
    final canBottom = position.maxScrollExtent - position.pixels > 24;
    final target = widget.playingTarget;
    final bool showLocate;
    if (target == null) {
      showLocate = false;
    } else {
      final clamped = target.clamp(0.0, position.maxScrollExtent);
      // 距目标不超过半屏视为“已在播放歌曲附近”。
      showLocate =
          (position.pixels - clamped).abs() > position.viewportDimension * .5;
    }
    if (canTop != _canTop ||
        canBottom != _canBottom ||
        showLocate != _showLocate) {
      setState(() {
        _canTop = canTop;
        _canBottom = canBottom;
        _showLocate = showLocate;
      });
    }
  }

  void _scrollTo(double offset) {
    if (!widget.controller.hasClients) return;
    widget.controller.animateTo(
      offset.clamp(0.0, widget.controller.position.maxScrollExtent),
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_canTop && !_canBottom && !_showLocate) {
      return const SizedBox.shrink();
    }
    return Positioned(
      right: 12,
      // 迷你播放栏位于 safeBottom+20、高 64，上沿即 safeBottom+84；
      // 按钮组留 8px 间距贴在其上侧。
      bottom:
          MediaQuery.paddingOf(context).bottom +
          (widget.hasMiniPlayer ? 92 : 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_canTop)
            FloatingActionButton.small(
              heroTag: null,
              tooltip: '回到顶部',
              onPressed: () => _scrollTo(0),
              child: const Icon(Icons.keyboard_arrow_up_rounded),
            ),
          if (_canBottom)
            FloatingActionButton.small(
              heroTag: null,
              tooltip: '回到底部',
              onPressed: () =>
                  _scrollTo(widget.controller.position.maxScrollExtent),
              child: const Icon(Icons.keyboard_arrow_down_rounded),
            ),
          if (_showLocate)
            FloatingActionButton.small(
              heroTag: null,
              tooltip: '定位正在播放',
              onPressed: widget.onLocatePlaying,
              child: const Icon(Icons.my_location_rounded, size: 18),
            ),
        ],
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

/// 歌曲列表排序键。custom = 自定义顺序（手动拖拽），为默认排序。
enum SongSortKey {
  custom('自定义'),
  added('按添加时间'),
  title('按歌曲名');

  const SongSortKey(this.label);
  final String label;
}

/// 排序状态：排序键 + 正倒序（仅 added/title 有效，custom 无方向）。
class SongSort {
  const SongSort(this.key, {this.descending = false});

  final SongSortKey key;
  final bool descending;

  /// 单击菜单项时的切换规则：点击已选中的键切换正倒序；首次选择某键
  /// 时使用该键的默认方向（添加时间默认倒序/最新在前，歌名默认正序）。
  SongSort toggle(SongSortKey tapped) {
    if (tapped == key) {
      return SongSort(tapped, descending: !descending);
    }
    return SongSort(tapped, descending: tapped == SongSortKey.added);
  }
}

/// 管理菜单中的附加操作（如收藏页的“清空收藏”）。
class SongMenuAction {
  const SongMenuAction({
    required this.id,
    required this.label,
    this.icon,
    this.isDestructive = false,
  });

  final String id;
  final String label;
  final IconData? icon;
  final bool isDestructive;
}

/// 歌曲列表右上角“排序”菜单：歌曲排序（简化为三个键，单击同类项
/// 切换正倒序）+ 可选的附加管理操作。
class SongSortMenuButton extends StatelessWidget {
  const SongSortMenuButton({
    super.key,
    required this.sort,
    required this.onSortChanged,
    this.actions = const <SongMenuAction>[],
    this.onAction,
  });

  final SongSort sort;
  final ValueChanged<SongSort> onSortChanged;
  final List<SongMenuAction> actions;
  final ValueChanged<SongMenuAction>? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: '歌曲排序',
      icon: const Icon(Icons.sort_rounded),
      position: PopupMenuPosition.under,
      onSelected: (value) {
        if (value.startsWith('sort:')) {
          final key = SongSortKey.values.firstWhere(
            (k) => k.name == value.substring(5),
          );
          onSortChanged(sort.toggle(key));
        } else {
          for (final action in actions) {
            if (action.id == value) onAction?.call(action);
          }
        }
      },
      itemBuilder: (context) => [
        for (final key in SongSortKey.values)
          PopupMenuItem(
            value: 'sort:${key.name}',
            height: 48,
            child: Row(
              children: [
                Icon(
                  key == sort.key
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  size: 20,
                  color: key == sort.key ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Text(key.label),
                if (key == sort.key && key != SongSortKey.custom) ...[
                  const SizedBox(width: 6),
                  Text(
                    sort.descending ? '倒序' : '正序',
                    style: TextStyle(fontSize: 12, color: scheme.primary),
                  ),
                ],
              ],
            ),
          ),
        if (actions.isNotEmpty) const PopupMenuDivider(),
        for (final action in actions)
          PopupMenuItem(
            value: action.id,
            height: 48,
            child: Row(
              children: [
                if (action.icon != null) ...[
                  Icon(
                    action.icon,
                    size: 20,
                    color: action.isDestructive ? scheme.error : null,
                  ),
                  const SizedBox(width: 10),
                ],
                Text(
                  action.label,
                  style: TextStyle(
                    color: action.isDestructive ? scheme.error : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
