import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_provider.dart';
import 'cover_image.dart';

/// 播放队列底部弹窗：打开时自动定位到当前正在播放的歌曲。
/// 供播放页与迷你播放栏共用。每首歌以条式卡片呈现：
/// 左滑删除、右侧把手拖拽排序。
class QueueSheet extends ConsumerStatefulWidget {
  const QueueSheet({super.key, required this.player});

  final PlaybackState player;

  @override
  ConsumerState<QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends ConsumerState<QueueSheet> {
  /// 单行整体高度（卡片 68 + 上下各 4 的间隙），保证滚动定位精确。
  static const double _itemExtent = 76;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // 首帧布局完成后才能拿到 viewport 与 maxScrollExtent，再定位当前歌曲。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final index = widget.player.queueIndex;
      if (index < 0 || index >= widget.player.queue.length) return;
      final viewport = _scrollController.position.viewportDimension;
      // 让当前歌曲尽量落在可视区中间。
      final target = (index * _itemExtent - (viewport - _itemExtent) / 2)
          .clamp(0.0, _scrollController.position.maxScrollExtent);
      if (target > 0) _scrollController.jumpTo(target);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 队列弹窗持有的是打开瞬间的快照，删除/重排后队列已变化；
  /// 以歌曲实例（其次按路径）重新定位最新下标，避免连续左滑时
  /// 用过期下标误删别的歌。
  int _liveIndexOf(QueueItem item) {
    final queue = ref.read(playerProvider).queue;
    final byIdentity = queue.indexOf(item);
    if (byIdentity >= 0) return byIdentity;
    return queue.indexWhere((candidate) => candidate.path == item.path);
  }

  /// 清空播放队列（二次确认）：停止播放并重置队列，其他播放设置保留。
  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空播放队列'),
        content: const Text('确定清空播放队列并停止播放吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    Navigator.pop(context);
    await ref.read(playerProvider.notifier).clearQueue();
  }

  @override
  Widget build(BuildContext context) {
    // 只订阅队列与当前下标：位置、播放状态等高频变化不触发重建，
    // 拖拽过程中不会被打断。
    final queue = ref.watch(playerProvider.select((s) => s.queue));
    final queueIndex = ref.watch(playerProvider.select((s) => s.queueIndex));
    return SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .66,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Row(
                  children: [
                    const Text(
                      '播放队列',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${queue.length} 首',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (queue.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: '清空播放队列',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _confirmClear(),
                        icon: const Icon(Icons.delete_sweep_outlined),
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ReorderableListView.builder(
                  scrollController: _scrollController,
                  // 拖拽只从右侧把手发起（buildDefaultDragHandles 关闭），
                  // 与左滑删除的手势互不冲突。
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: queue.length,
                  // onReorderItem 回传的已是移动后的最终下标。
                  onReorderItem: (oldIndex, newIndex) {
                    ref
                        .read(playerProvider.notifier)
                        .moveQueueItem(oldIndex, newIndex);
                  },
                  proxyDecorator: _dragProxyDecorator,
                  itemBuilder: (context, index) {
                    final item = queue[index];
                    return _QueueRowCard(
                      key: ValueKey('queue-row-${item.path}#$index'),
                      index: index,
                      item: item,
                      current: index == queueIndex,
                      onTap: () async {
                        Navigator.pop(context);
                        await ref
                            .read(playerProvider.notifier)
                            .playIndex(index);
                      },
                      onDismissed: () {
                        final liveIndex = _liveIndexOf(item);
                        if (liveIndex >= 0) {
                          ref
                              .read(playerProvider.notifier)
                              .removeQueueItem(liveIndex);
                        }
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
  }

  /// 拖拽跟随预览：条式卡片带阴影浮起，替代默认的全宽 Material。
  Widget _dragProxyDecorator(
    Widget child,
    int index,
    Animation<double> animation,
  ) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        return Material(
          elevation: 6 * animation.value,
          borderRadius: BorderRadius.circular(12),
          color: Colors.transparent,
          shadowColor: Colors.black54,
          child: child,
        );
      },
      child: child,
    );
  }
}

/// 单首歌的条式卡片：左滑删除（Dismissible）+ 点按切歌 + 右侧拖拽把手。
class _QueueRowCard extends StatelessWidget {
  const _QueueRowCard({
    super.key,
    required this.index,
    required this.item,
    required this.current,
    required this.onTap,
    required this.onDismissed,
  });

  final int index;
  final QueueItem item;
  final bool current;
  final Future<void> Function() onTap;
  final VoidCallback onDismissed;

  static const _accent = Color(0xFFEC4141);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Dismissible(
        key: ValueKey('queue-dismiss-${item.path}#${identityHashCode(item)}'),
        direction: DismissDirection.endToStart,
        background: _dismissBackdrop(scheme),
        secondaryBackground: _dismissBackdrop(scheme),
        onDismissed: (_) => onDismissed(),
        child: Material(
          color: current
              ? _accent.withValues(alpha: .08)
              : scheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: current
                ? BorderSide(color: _accent.withValues(alpha: .35))
                : BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: .5),
                  ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 68,
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  // 与歌曲列表一致的封面图标：本地读内嵌封面、在线用
                  // coverUrl，无封面时显示渐变音符占位。
                  _songCover(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            color: current ? _accent : scheme.onSurface,
                            fontWeight: current
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _subtitle(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  ReorderableDragStartListener(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Icon(
                        Icons.drag_handle,
                        size: 24,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 左滑时右侧露出的红色删除底。
  Widget _dismissBackdrop(ColorScheme scheme) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFE5484D),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 20),
          child: Icon(Icons.delete_outline, color: scheme.onPrimary),
        ),
      ),
    );
  }

  /// 副标题：与歌曲列表一致显示「歌手 · 专辑」，两者皆空时显示未知艺术家。
  String _subtitle() {
    final parts = [item.artist, item.album]
        .where((part) => part.trim().isNotEmpty)
        .toList();
    return parts.isEmpty ? '未知艺术家' : parts.join(' · ');
  }

  /// 歌曲封面图标；正在播放的曲目在右下角叠加红色声波小徽标。
  Widget _songCover() {
    final cover = SizedBox(
      width: 46,
      height: 46,
      child: CoverImage(
        songPath: item.path,
        imageUrl: item.coverUrl,
        width: 46,
        height: 46,
        radius: 10,
        cacheWidth: 46 * 3,
      ),
    );
    if (!current) return cover;
    return SizedBox(
      width: 46,
      height: 46,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          cover,
          Positioned(
            right: -4,
            bottom: -4,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: const BoxDecoration(
                color: _accent,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.graphic_eq,
                size: 10,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 打开播放队列弹窗的便捷方法。
Future<void> showQueueSheet(BuildContext context, WidgetRef ref) {
  final player = ref.read(playerProvider);
  return showModalBottomSheet<void>(
    context: context,
    // 根 Navigator：播放队列弹窗覆盖悬浮底栏/迷你播放栏，避免被遮挡。
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => QueueSheet(player: player),
  );
}
