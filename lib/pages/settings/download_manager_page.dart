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
import '../../src/widgets/top_notice.dart';

/// 下载管理页：展示最近 500 条下载记录（分页每页 50 条），
/// 支持搜索、查看实时进度/实际音质、重新下载与失败详情。
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

  Future<void> _redownload(DownloadHistoryEntry entry) async {
    if (_redownloading) {
      XyNotice.show(context, message: '已有重新下载任务进行中，请稍候');
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
    setState(() => _redownloading = true);
    final historyNotifier = ref.read(downloadHistoryProvider.notifier);
    final historyId = historyNotifier.restart(entry.id);
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
          if (coverUrl.startsWith('http://') ||
              coverUrl.startsWith('https://'))
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
      historyNotifier.fail(historyId, error.toString());
      if (mounted) {
        XyNotice.show(
          context,
          message: '重新下载失败：$error',
          type: XyNoticeType.error,
        );
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
        title: const Text('下载管理'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(58),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: '搜索歌曲、歌手、专辑',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
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
                if (totalPages > 1)
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
    final isFailed = entry.status == DownloadHistoryStatus.failed;
    final time = entry.finishedAt ?? entry.startedAt;
    final qualityText = entry.actualQuality != null &&
            entry.actualQuality!.toLowerCase() != entry.quality.toLowerCase()
        ? '${_qualityLabel(entry.quality)} → 实际 ${_qualityLabel(entry.actualQuality!)}'
        : _qualityLabel(entry.actualQuality ?? entry.quality);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: isDownloading
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.4),
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
          if (isDownloading) ...[
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
                  entry.totalBytes > 0
                      ? '${(entry.progress * 100).toStringAsFixed(0)}%'
                      : _formatBytes(entry.downloadedBytes),
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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isFailed)
            TextButton(
              onPressed: () => _showErrorDetail(entry),
              child: const Text('查看详情'),
            ),
          if (!isDownloading)
            IconButton(
              tooltip: '重新下载',
              onPressed: _redownloading ? null : () => _redownload(entry),
              icon: const Icon(Icons.download_rounded, size: 21),
            ),
        ],
      ),
    );
  }
}
