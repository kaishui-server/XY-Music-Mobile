import 'package:flutter/material.dart';

import '../../src/sync/cloud_data_viewer.dart';

/// 云数据页通用确认弹窗：红色确认按钮 + 默认焦点在「取消」防误触，
/// 并提示删除只影响云端、自动同步可能重新上传。
Future<bool> showCloudDeleteConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = '删除',
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final scheme = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            const SizedBox(height: 10),
            Text(
              '删除仅影响云端数据，不影响本机；若开启自动同步，本机数据可能在下次同步时重新上传。',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(confirmText),
          ),
        ],
      );
    },
  );
  return confirmed == true;
}

/// 批量管理按钮栏：与插件管理页一致的「批量管理 / 全选 / 删除选中」交互。
/// 放在列表首项，随列表滚动。
class CloudDataBatchBar extends StatelessWidget {
  const CloudDataBatchBar({
    super.key,
    required this.selectionMode,
    required this.selectedCount,
    required this.allSelected,
    required this.busy,
    required this.onToggleMode,
    required this.onToggleAll,
    required this.onDeleteSelected,
  });

  final bool selectionMode;
  final int selectedCount;
  final bool allSelected;
  final bool busy;
  final VoidCallback onToggleMode;
  final VoidCallback onToggleAll;
  final VoidCallback onDeleteSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: busy ? null : onToggleMode,
            icon: Icon(
              selectionMode ? Icons.close_rounded : Icons.checklist_rounded,
            ),
            label: Text(selectionMode ? '退出选择' : '批量管理'),
          ),
          if (selectionMode)
            OutlinedButton.icon(
              onPressed: busy ? null : onToggleAll,
              icon: const Icon(Icons.select_all_rounded),
              label: Text(allSelected ? '取消全选' : '全选'),
            ),
          if (selectionMode)
            FilledButton.icon(
              onPressed: busy || selectedCount == 0 ? null : onDeleteSelected,
              icon: const Icon(Icons.delete_outline_rounded),
              label: Text('删除选中（$selectedCount）'),
            ),
        ],
      ),
    );
  }
}

/// 云端歌曲只读行：序号 + 标题 + 歌手/专辑 + 时长与来源。
/// 支持选择模式（左侧变勾选圈）与单删（右侧垃圾桶）。
class CloudSongTile extends StatelessWidget {
  const CloudSongTile({
    super.key,
    required this.index,
    required this.song,
    this.selectionMode = false,
    this.selected = false,
    this.onTap,
    this.onDelete,
  });

  final int index;
  final CloudSongItem song;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  static String formatDuration(int seconds) {
    if (seconds <= 0) return '';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final duration = formatDuration(song.duration);
    final subtitle = [
      if (song.artist.isNotEmpty) song.artist,
      if (song.album.isNotEmpty) song.album,
    ].join(' - ');
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      leading: selectionMode
          ? Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            )
          : SizedBox(
              width: 28,
              child: Text(
                '$index',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
            ),
      title: Text(
        song.title.isEmpty ? '(未命名)' : song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (song.isOnline && !selectionMode)
            Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '在线',
                style: TextStyle(fontSize: 11, color: scheme.primary),
              ),
            ),
          if (duration.isNotEmpty && !selectionMode)
            Text(
              duration,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          // 旧云端数据可能缺少 path 唯一标识，无法定位删除，不显示删除按钮。
          if (!selectionMode && onDelete != null && song.path.isNotEmpty)
            IconButton(
              onPressed: onDelete,
              icon: Icon(
                Icons.delete_outline_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              tooltip: '删除',
            ),
        ],
      ),
    );
  }
}
