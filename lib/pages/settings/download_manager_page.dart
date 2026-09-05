import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../src/core/settings.dart';
import '../../src/player/android_storage.dart';
import '../../src/player/download_history_store.dart';
import '../../src/player/download_quality.dart';
import '../../src/player/downloaded_song_store.dart';
import '../../src/player/player_provider.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/frosted_search_field.dart';
import '../../src/widgets/top_notice.dart';

/// 下载管理页：展示最近 500 条下载记录（分页每页 50 条），
/// 支持搜索、实时进度/实际音质、暂停/继续、重新下载、失败详情、
/// 单条与批量删除（可选同时删除本地音乐文件）。
class DownloadManagerPage extends ConsumerStatefulWidget {
  const DownloadManagerPage({super.key});

  @override
  ConsumerState<DownloadManagerPage> createState() =>
      _DownloadManagerPageState();
}

/// 分页大小：一次只构建 50 条列表项，避免长列表卡顿。
const _pageSize = 50;

class _DownloadManagerPageState extends ConsumerState<DownloadManagerPage> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  int _page = 0;
  bool _redownloading = false;

  /// 多选删除模式：长按列表项进入。
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    setState(() {
      _query = value;
      _page = 0;
    });
  }

  void _enterSelection(String id) {
    setState(() {
      _selectionMode = true;
      _selectedIds.add(id);
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelection(String id) {
    setState(() {
      if (!_selectedIds.add(id)) _selectedIds.remove(id);
    });
  }

  String _formatTime(int millis) {
    final dateTime = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${dateTime.year}-${two(dateTime.month)}-${two(dateTime.day)} '
        '${two(dateTime.hour)}:${two(dateTime.minute)}';
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return value >= 100 || unit == 0
        ? '${value.toStringAsFixed(0)} ${units[unit]}'
        : '${value.toStringAsFixed(1)} ${units[unit]}';
  }

  String _qualityLabel(String quality) {
    final lower = quality.trim().toLowerCase();
    if (lower == '128k' || lower == 'standard') return '标准 128k';
    if (lower == '192k') return '较高 192k';
    if (lower == '320k' || lower == 'high') return '高品质 320k';
    if (lower == 'flac' || lower == 'lossless' || lower == 'sq') {
      return '无损 FLAC';
    }
    return quality;
  }

  Future<void> _showErrorDetail(DownloadHistoryEntry entry) async {
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: Text('下载失败详情：${entry.title}'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              entry.error ?? '未知错误',
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

  /// 重新下载，或继续一条已暂停的记录（复用原记录，不新增）。
  Future<void> _redownload(
    DownloadHistoryEntry entry, {
    bool resume = false,
  }) async {
    if (_redownloading) {
      XyNotice.show(context, message: '已有下载任务进行中，请稍候');
      return;
    }
    if (entry.sourcePath.trim().isEmpty) {
      XyNotice.show(
        context,
        message: '该记录缺少音源信息，无法重新下载',
        type: XyNoticeType.warning,
      );
      return;
    }
    final item = _queueItemFor(entry);
    if (playbackSourceTypeFor(item) == PlaybackSourceType.localFile) {
      XyNotice.show(context, message: '该歌曲已是本地文件，无需重新下载');
      return;
    }
    final historyNotifier = ref.read(downloadHistoryProvider.notifier);
    final String historyId;
    if (resume) {
      if (!historyNotifier.resumeEntry(entry.id)) {
        XyNotice.show(context, message: '任务状态已变化，请刷新后重试');
        return;
      }
      historyId = entry.id;
    } else {
      if (historyNotifier.hasActiveDownload(entry.sourcePath)) {
        XyNotice.show(context, message: '《${entry.title}》正在下载中，请在列表中查看进度');
        return;
      }
      historyId = historyNotifier.restart(entry.id);
    }
    setState(() => _redownloading = true);
    try {
      final settings = ref.read(settingsProvider).valueOrNull;
      final directory = await resolveMusicDownloadDirectory(settings);
      final usesSafDirectory = AndroidStorage.isTreeUri(directory);
      final workDirectory = usesSafDirectory
          ? await resolveDownloadStagingDirectory()
          : directory;
      await Directory(workDirectory).create(recursive: true);
      final source = await ref
          .read(playerProvider.notifier)
          .resolveDownloadSourceFor(item, entry.quality)
          .timeout(const Duration(seconds: 60));
      final destination = await resolveDownloadFullPath(
        directory: workDirectory,
        title: entry.title,
        artist: entry.artist,
        album: entry.album,
        url: source.url,
        quality: entry.quality,
        keepSourceFilename: false,
        fileNameStyle: 'artist-title',
        // 重新下载直接覆盖旧文件，避免生成“(1)”副本。
        overwriteExisting: true,
      );
      final savedPath = await trackDownloadProgress(
        history: historyNotifier,
        entryId: historyId,
        url: source.url,
        headers: source.headers,
        destPath: destination,
        download: () => downloadOnlineSong(
          url: source.url,
          destPath: destination,
          headersJson: jsonEncode(source.headers),
        ),
      );
      final verified = await verifyDownloadedAudioQuality(
        savedPath: savedPath,
        selectedQuality: entry.quality,
        durationSec: (entry.durationMs / 1000).round(),
        songTitle: entry.title,
      );
      final coverUrl = entry.coverUrl?.trim() ?? '';
      await finalizeDownloadExtras(
        requestJson: jsonEncode({
          if (coverUrl.startsWith('http://') || coverUrl.startsWith('https://'))
            'coverUrl': coverUrl,
          'embedCover': true,
          'metadata': {
            'filePath': verified.path,
            'title': entry.title,
            'artist': entry.artist,
            'album': entry.album,
          },
        }),
      );
      var finalPath = verified.path;
      if (usesSafDirectory) {
        finalPath = await AndroidStorage.copyFileToDirectory(
          directoryUri: directory,
          sourcePath: verified.path,
          fileName: p.basename(verified.path),
          mimeType: 'audio/*',
        );
        try {
          await File(verified.path).delete();
        } catch (_) {}
      }
      await rememberDownloadedSongSnapshot(
        DownloadedSongSnapshot(
          path: finalPath,
          title: entry.title,
          artist: entry.artist,
          album: entry.album,
          durationMs: entry.durationMs,
          downloadedAt: DateTime.now().millisecondsSinceEpoch,
          sourcePath: entry.sourcePath,
          quality: verified.quality,
          coverUrl: entry.coverUrl,
        ),
      );
      historyNotifier.complete(
        historyId,
        savedPath: finalPath,
        actualQuality: verified.quality,
      );
      if (mounted) {
        XyNotice.show(
          context,
          message: verified.warning ?? '下载完成：${p.basename(verified.path)}',
          type: verified.warning == null
              ? XyNoticeType.success
              : XyNoticeType.warning,
        );
      }
    } catch (error) {
      if (error is DownloadPausedSignal) {
        // 用户主动暂停：状态已标记，不提示失败。
        if (mounted) {
          XyNotice.show(context, message: '已暂停：${entry.title}');
        }
      } else {
        historyNotifier.fail(historyId, error.toString());
        if (mounted) {
          XyNotice.show(
            context,
            message: '重新下载失败：$error',
            type: XyNoticeType.error,
          );
        }
      }
    } finally {
      if (mounted) setState(() => _redownloading = false);
    }
  }

  QueueItem _queueItemFor(DownloadHistoryEntry entry) {
    Map<String, dynamic>? pluginData;
    final raw = entry.pluginDataJson;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) pluginData = decoded;
      } catch (_) {}
    }
    return QueueItem(
      path: entry.sourcePath,
      title: entry.title,
      artist: entry.artist,
      album: entry.album,
      durationMs: entry.durationMs,
      pluginId: entry.pluginId,
      pluginData: pluginData,
      coverUrl: entry.coverUrl,
    );
  }

  /// 删除一个本地音频文件（支持普通路径与 SAF content:// 文档），
  /// 顺带清理同名 .lrc 歌词文件。
  Future<void> _deleteLocalFile(String? path) async {
    final target = path?.trim() ?? '';
    if (target.isEmpty) return;
    if (target.toLowerCase().startsWith('content://')) {
      try {
        await AndroidStorage.deleteFileInDirectory(target);
      } catch (_) {}
      return;
    }
    try {
      final file = File(target);
      if (await file.exists()) await file.delete();
      final lrc = File(p.setExtension(target, '.lrc'));
      if (await lrc.exists()) await lrc.delete();
    } catch (_) {}
  }

  /// 删除记录（带确认弹窗）：可选择是否同时删除本地音乐文件。
  Future<void> _confirmDelete(List<DownloadHistoryEntry> targets) async {
    if (targets.isEmpty) return;
    var deleteFiles = false;
    final hasCompletedFile = targets.any(
      (entry) =>
          entry.status == DownloadHistoryStatus.completed &&
          (entry.savedPath ?? '').trim().isNotEmpty,
    );
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(
            targets.length == 1 ? '删除下载记录' : '删除 ${targets.length} 条下载记录',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                targets.length == 1
                    ? '确定删除《${targets.first.title.isEmpty ? '未知歌曲' : targets.first.title}》的下载记录吗？'
                    : '确定删除选中的 ${targets.length} 条下载记录吗？',
              ),
              if (hasCompletedFile)
                CheckboxListTile(
                  value: deleteFiles,
                  onChanged: (value) =>
                      setDialogState(() => deleteFiles = value ?? false),
                  title: const Text('同时删除本地音乐文件'),
                  subtitle: const Text('从存储中移除已下载完成的音频文件'),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogContext).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('删除'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    await _deleteEntries(targets, deleteLocalFiles: deleteFiles);
  }

  Future<void> _deleteEntries(
    List<DownloadHistoryEntry> targets, {
    required bool deleteLocalFiles,
  }) async {
    final historyNotifier = ref.read(downloadHistoryProvider.notifier);
    // 下载中的任务先置取消标记再删记录，拦截其后台收尾与完成提示。
    final removed = historyNotifier.removeEntries(
      targets.map((entry) => entry.id).toSet(),
    );
    var removedFiles = 0;
    for (final entry in removed) {
      if (entry.status == DownloadHistoryStatus.completed && deleteLocalFiles) {
        await _deleteLocalFile(entry.savedPath);
        await forgetDownloadedSongSnapshot(entry.savedPath ?? '');
        removedFiles++;
      } else if (entry.status == DownloadHistoryStatus.downloading ||
          entry.status == DownloadHistoryStatus.paused) {
        // 半成品文件无论是否勾选都清理，避免残缺音频混入本地乐库。
        await _deleteLocalFile(entry.localPath);
      }
    }
    if (_selectionMode) _exitSelection();
    if (mounted) {
      XyNotice.show(
        context,
        message: deleteLocalFiles && removedFiles > 0
            ? '已删除 ${removed.length} 条记录和 $removedFiles 个本地文件'
            : '已删除 ${removed.length} 条记录',
        type: XyNoticeType.success,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // watch 触发进度等状态变化时整页重建；列表仅构建当前页 50 条。
    final entries = ref
        .watch(downloadHistoryProvider)
        .where(_matchesQuery)
        .toList();
    final totalPages = (entries.length / _pageSize).ceil();
    final safePage = _page.clamp(0, totalPages > 0 ? totalPages - 1 : 0);
    final pageEntries = entries
        .skip(safePage * _pageSize)
        .take(_pageSize)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(_selectionMode ? '已选择 ${_selectedIds.length} 项' : '下载管理'),
        leading: _selectionMode
            ? IconButton(
                tooltip: '退出多选',
                onPressed: _exitSelection,
                icon: const Icon(Icons.close_rounded),
              )
            : null,
        actions: _selectionMode
            ? [
                IconButton(
                  tooltip:
                      _selectedIds.length >= entries.length &&
                          entries.isNotEmpty
                      ? '取消全选'
                      : '全选',
                  onPressed: entries.isEmpty
                      ? null
                      : () => setState(() {
                          if (_selectedIds.length >= entries.length) {
                            _selectedIds.clear();
                          } else {
                            _selectedIds
                              ..clear()
                              ..addAll(entries.map((e) => e.id));
                          }
                        }),
                  icon: Icon(
                    _selectedIds.length >= entries.length && entries.isNotEmpty
                        ? Icons.deselect_rounded
                        : Icons.select_all_rounded,
                  ),
                ),
              ]
            : null,
        bottom: _selectionMode
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(58),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: FrostedSearchField(
                    controller: _searchController,
                    onChanged: _onSearchChanged,
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
      ),
      body: entries.isEmpty
          ? Center(
              child: Text(
                _query.isEmpty ? '暂无下载记录' : '未找到匹配的下载记录',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: pageEntries.length,
                    itemBuilder: (context, index) =>
                        _buildTile(theme, pageEntries[index]),
                  ),
                ),
                if (_selectionMode)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                      child: Row(
                        children: [
                          Text(
                            '已选 ${_selectedIds.length} 项',
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const Spacer(),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: theme.colorScheme.error,
                            ),
                            onPressed: _selectedIds.isEmpty
                                ? null
                                : () => _confirmDelete(
                                    entries
                                        .where(
                                          (entry) =>
                                              _selectedIds.contains(entry.id),
                                        )
                                        .toList(),
                                  ),
                            icon: const Icon(
                              Icons.delete_sweep_outlined,
                              size: 20,
                            ),
                            label: const Text('批量删除'),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (totalPages > 1)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: '上一页',
                            onPressed: safePage <= 0
                                ? null
                                : () => setState(() => _page = safePage - 1),
                            icon: const Icon(Icons.chevron_left_rounded),
                          ),
                          Text('${safePage + 1} / $totalPages'),
                          IconButton(
                            tooltip: '下一页',
                            onPressed: safePage >= totalPages - 1
                                ? null
                                : () => setState(() => _page = safePage + 1),
                            icon: const Icon(Icons.chevron_right_rounded),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  bool _matchesQuery(DownloadHistoryEntry entry) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return true;
    return entry.title.toLowerCase().contains(query) ||
        entry.artist.toLowerCase().contains(query) ||
        entry.album.toLowerCase().contains(query);
  }

  Widget _buildTile(ThemeData theme, DownloadHistoryEntry entry) {
    final isDownloading = entry.status == DownloadHistoryStatus.downloading;
    final isPaused = entry.status == DownloadHistoryStatus.paused;
    final isFailed = entry.status == DownloadHistoryStatus.failed;
    final time = entry.finishedAt ?? entry.startedAt;
    final qualityText =
        entry.actualQuality != null &&
            entry.actualQuality!.toLowerCase() != entry.quality.toLowerCase()
        ? '${_qualityLabel(entry.quality)} → 实际 ${_qualityLabel(entry.actualQuality!)}'
        : _qualityLabel(entry.actualQuality ?? entry.quality);
    final selected = _selectedIds.contains(entry.id);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      onTap: _selectionMode ? () => _toggleSelection(entry.id) : null,
      onLongPress: _selectionMode ? null : () => _enterSelection(entry.id),
      leading: _selectionMode
          ? Checkbox(
              value: selected,
              onChanged: (_) => _toggleSelection(entry.id),
            )
          : isDownloading
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            )
          : isPaused
          ? Icon(
              Icons.pause_circle_outline_rounded,
              color: Colors.orange.shade700,
            )
          : Icon(
              isFailed
                  ? Icons.error_outline_rounded
                  : Icons.check_circle_outline_rounded,
              color: isFailed
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary,
            ),
      title: Text(
        entry.title.isEmpty ? '未知歌曲' : entry.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            '${entry.artist} · $qualityText · ${_formatTime(time)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (isDownloading || isPaused) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: entry.totalBytes > 0 ? entry.progress : null,
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${isPaused ? '已暂停 ' : ''}${entry.totalBytes > 0 ? '${(entry.progress * 100).toStringAsFixed(0)}%' : _formatBytes(entry.downloadedBytes)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
          if (isFailed && entry.error != null && entry.error!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              entry.error!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.error.withValues(alpha: .85),
              ),
            ),
          ],
        ],
      ),
      trailing: _selectionMode
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isDownloading)
                  IconButton(
                    tooltip: '暂停',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => ref
                        .read(downloadHistoryProvider.notifier)
                        .pause(entry.id),
                    icon: const Icon(Icons.pause_rounded, size: 22),
                  ),
                if (isPaused)
                  IconButton(
                    tooltip: '继续下载',
                    visualDensity: VisualDensity.compact,
                    onPressed: _redownloading
                        ? null
                        : () => _redownload(entry, resume: true),
                    icon: const Icon(Icons.play_arrow_rounded, size: 24),
                  ),
                if (isFailed)
                  IconButton(
                    tooltip: '查看失败详情',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _showErrorDetail(entry),
                    icon: const Icon(Icons.info_outline_rounded, size: 21),
                  ),
                if (!isDownloading)
                  IconButton(
                    tooltip: '重新下载',
                    visualDensity: VisualDensity.compact,
                    onPressed: _redownloading ? null : () => _redownload(entry),
                    icon: const Icon(Icons.download_rounded, size: 21),
                  ),
                IconButton(
                  tooltip: '删除记录',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _confirmDelete([entry]),
                  icon: const Icon(Icons.delete_outline_rounded, size: 21),
                ),
              ],
            ),
    );
  }
}
