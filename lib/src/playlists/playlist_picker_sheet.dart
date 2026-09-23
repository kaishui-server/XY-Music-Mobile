import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_provider.dart';
import '../widgets/cover_image.dart';
import 'playlists_provider.dart';

/// 添加到歌单的结果：目标歌单、新添加数量与已存在数量。
class PlaylistPickOutcome {
  const PlaylistPickOutcome({
    required this.playlistId,
    required this.addedCount,
    required this.existsCount,
  });

  final String playlistId;
  final int addedCount;
  final int existsCount;
}

/// 弹出“添加到歌单”面板：单曲与多曲（收藏多选等批量场景）共用。
///
/// 选择歌单（或新建歌单）后把全部歌曲加入，返回汇总结果；用户取消
/// 返回 null。已存在于目标歌单的歌曲自动跳过，不重复添加。
Future<PlaylistPickOutcome?> showPlaylistPicker(
  BuildContext context, {
  required List<QueueItem> items,
}) {
  return showModalBottomSheet<PlaylistPickOutcome>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PlaylistPickerSheet(items: items),
  );
}

class _PlaylistPickerSheet extends ConsumerStatefulWidget {
  const _PlaylistPickerSheet({required this.items});

  final List<QueueItem> items;

  @override
  ConsumerState<_PlaylistPickerSheet> createState() =>
      _PlaylistPickerSheetState();
}

class _PlaylistPickerSheetState extends ConsumerState<_PlaylistPickerSheet> {
  bool _busy = false;

  Future<void> _addTo(String playlistId) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final (added, exists) = await ref
          .read(playlistsProvider.notifier)
          .addQueueItems(playlistId, widget.items);
      if (mounted) {
        Navigator.pop(
          context,
          PlaylistPickOutcome(
            playlistId: playlistId,
            addedCount: added,
            existsCount: exists,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createAndAdd() async {
    if (_busy) return;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(hintText: '请输入歌单名称'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('创建并添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || name == null || name.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final playlist = await ref.read(playlistsProvider.notifier).create(name);
      if (playlist == null) return;
      await ref
          .read(playlistsProvider.notifier)
          .addQueueItems(playlist.id, widget.items);
      if (mounted) {
        // 新建歌单中不可能存在重复歌曲，结果恒为全部添加。
        Navigator.pop(
          context,
          PlaylistPickOutcome(
            playlistId: playlist.id,
            addedCount: widget.items.length,
            existsCount: 0,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final items = widget.items;
    final subtitle = items.length == 1
        ? items.first.title
        : '已选 ${items.length} 首歌曲';
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .62,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                '添加到歌单',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: colorScheme.primaryContainer,
                child: Icon(Icons.add_rounded, color: colorScheme.primary),
              ),
              title: const Text('新建歌单'),
              subtitle: Text(
                items.length == 1 ? '创建后自动添加当前歌曲' : '创建后自动添加所选歌曲',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              enabled: !_busy,
              onTap: _createAndAdd,
            ),
            const Divider(height: 1),
            Expanded(
              child: playlists.isEmpty
                  ? Center(
                      child: Text(
                        '还没有歌单，先新建一个吧',
                        style: TextStyle(color: colorScheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 12),
                      itemCount: playlists.length,
                      itemBuilder: (context, index) {
                        final playlist = playlists[index];
                        final firstPath = playlist.songPaths.isEmpty
                            ? playlist.id
                            : playlist.songPaths.first;
                        return ListTile(
                          leading: playlist.songPaths.isEmpty
                              ? CircleAvatar(
                                  backgroundColor:
                                      colorScheme.surfaceContainerHighest,
                                  child: Icon(
                                    Icons.queue_music_rounded,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                )
                              : CoverImage(
                                  songPath: firstPath,
                                  imageUrl: playlist.effectiveCoverUrl,
                                  width: 40,
                                  height: 40,
                                  radius: 20,
                                  icon: Icons.queue_music_rounded,
                                ),
                          title: Text(
                            playlist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text('${playlist.songPaths.length} 首歌曲'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          enabled: !_busy,
                          onTap: () => _addTo(playlist.id),
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
