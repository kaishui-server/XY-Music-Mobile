import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_provider.dart';

/// 播放队列底部弹窗：打开时自动定位到当前正在播放的歌曲。
/// 供播放页与迷你播放栏共用。
class QueueSheet extends ConsumerStatefulWidget {
  const QueueSheet({super.key, required this.player});

  final PlaybackState player;

  @override
  ConsumerState<QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends ConsumerState<QueueSheet> {
  /// 队列项固定高度（两行 ListTile 的标准高度），保证滚动定位精确。
  static const double _itemExtent = 72;
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

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
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
                      '${player.queue.length} 首',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  itemExtent: _itemExtent,
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: player.queue.length,
                  itemBuilder: (context, index) {
                    final item = player.queue[index];
                    final current = index == player.queueIndex;
                    return ListTile(
                      minTileHeight: 58,
                      leading: current
                          ? const SizedBox(
                              width: 24,
                              child: Icon(
                                Icons.graphic_eq,
                                color: Color(0xFFEC4141),
                              ),
                            )
                          : SizedBox(
                              width: 24,
                              child: Text(
                                '${index + 1}',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                      title: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: current ? const Color(0xFFEC4141) : null,
                          fontWeight: current
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        item.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () async {
                        Navigator.pop(context);
                        await ref
                            .read(playerProvider.notifier)
                            .playIndex(index);
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
}

/// 打开播放队列弹窗的便捷方法。
Future<void> showQueueSheet(BuildContext context, WidgetRef ref) {
  final player = ref.read(playerProvider);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => QueueSheet(player: player),
  );
}
