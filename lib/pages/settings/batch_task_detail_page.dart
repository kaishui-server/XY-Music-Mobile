import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/player/batch_task_store.dart';

/// 批量任务详情页：展示某次批量下载 / 批量换源操作涉及的实际歌曲列表，
/// 每首标注处理结果（成功 / 跳过 / 失败）与附加说明。
class BatchTaskDetailPage extends ConsumerWidget {
  const BatchTaskDetailPage({super.key, required this.taskId});

  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(batchTaskProvider);
    final index = tasks.indexWhere((task) => task.id == taskId);
    final task = index < 0 ? null : tasks[index];
    final scheme = Theme.of(context).colorScheme;
    final isDownload = task?.kind == BatchTaskKind.download;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          task == null
              ? '任务详情'
              : '${isDownload ? '批量下载' : '批量换源'} · ${task.total} 首',
        ),
        centerTitle: true,
      ),
      body: task == null
          ? Center(
              child: Text(
                '任务不存在或已删除',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            )
          : ListView.separated(
              padding: EdgeInsets.fromLTRB(
                12,
                12,
                12,
                MediaQuery.paddingOf(context).bottom + 24,
              ),
              itemCount: task.songs.length + 1,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                if (index == 0) return _buildSummary(context, task);
                return _buildSongTile(context, task.songs[index - 1]);
              },
            ),
    );
  }

  Widget _buildSummary(BuildContext context, BatchTask task) {
    final scheme = Theme.of(context).colorScheme;
    final dateTime = DateTime.fromMillisecondsSinceEpoch(task.createdAt);
    String two(int value) => value.toString().padLeft(2, '0');
    final time =
        '${dateTime.year}-${two(dateTime.month)}-${two(dateTime.day)} '
        '${two(dateTime.hour)}:${two(dateTime.minute)}';
    final statusLabel = switch (task.status) {
      BatchTaskStatus.running => '进行中',
      BatchTaskStatus.paused => '已暂停',
      BatchTaskStatus.completed => '已完成',
      BatchTaskStatus.cancelled => '已结束',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$time · $statusLabel · 成功 ${task.successCount} · '
            '失败 ${task.failedCount}'
            '${task.skippedCount > 0 ? ' · 跳过 ${task.skippedCount}' : ''}',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          if (task.isActive) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: task.progress,
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${task.finishedCount}/${task.total}'
                  ' · ${(task.progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSongTile(BuildContext context, BatchTaskSong song) {
    final scheme = Theme.of(context).colorScheme;
    final isFailed = song.status == BatchTaskSongStatus.failed;
    final (IconData icon, Color color) = switch (song.status) {
      BatchTaskSongStatus.success => (
        Icons.check_circle_outline_rounded,
        scheme.primary,
      ),
      BatchTaskSongStatus.skipped => (
        Icons.remove_circle_outline_rounded,
        scheme.onSurfaceVariant,
      ),
      BatchTaskSongStatus.failed => (
        Icons.error_outline_rounded,
        scheme.error,
      ),
      BatchTaskSongStatus.processing => (
        Icons.sync_rounded,
        scheme.primary,
      ),
      BatchTaskSongStatus.pending => (
        Icons.schedule_rounded,
        scheme.onSurfaceVariant,
      ),
    };
    final subtitle = [
      song.artist,
      song.album,
      if (song.status == BatchTaskSongStatus.processing)
        '处理中 ${(song.progress * 100).toStringAsFixed(0)}%'
      else if (song.status == BatchTaskSongStatus.pending)
        '等待处理',
      if (song.detail != null && song.detail!.trim().isNotEmpty) song.detail!,
    ].where((part) => part.trim().isNotEmpty).join(' · ');
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: isFailed ? () => _showErrorDetail(context, song) : null,
        leading: Icon(icon, color: color),
        title: Text(
          song.title.isEmpty ? '未知歌曲' : song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        trailing: isFailed
            ? IconButton(
                tooltip: '查看失败详情',
                visualDensity: VisualDensity.compact,
                onPressed: () => _showErrorDetail(context, song),
                icon: Icon(Icons.info_outline_rounded, size: 20, color: color),
              )
            : null,
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
            if (song.status == BatchTaskSongStatus.processing) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: song.progress > 0 ? song.progress : null,
                minHeight: 3,
                borderRadius: BorderRadius.circular(2),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 失败歌曲的报错详情弹窗：完整展示换源 / 下载失败原因，可选中复制。
  Future<void> _showErrorDetail(BuildContext context, BatchTaskSong song) {
    final detail = song.detail?.trim() ?? '';
    return showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: Text('失败详情：${song.title.isEmpty ? '未知歌曲' : song.title}'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              detail.isEmpty ? '未知错误' : detail,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}