import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../src/core/settings.dart';
import '../../src/player/android_storage.dart';
import '../../src/player/batch_task_store.dart';
import '../../src/player/download_history_store.dart';
import '../../src/player/download_quality.dart';
import '../../src/player/downloaded_song_store.dart';
import '../../src/player/player_provider.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/batch_download.dart';
import '../../src/widgets/frosted_search_field.dart';
import '../../src/widgets/top_notice.dart';

/// 任务管理页：分「批量任务」与「单项任务」两个 Tab。
///
/// - 批量任务：记录用户发起的批量下载 / 批量换源操作，一次操作一张卡片，
///   点击进入本次操作涉及的实际歌曲列表。
/// - 单项任务：即原下载管理，展示最近 500 条下载记录（分页每页 50 条），
///   支持搜索、实时进度/实际音质、暂停/继续、重新下载、失败详情、
///   单条与批量删除（可选同时删除本地音乐文件）。
class TaskManagerPage extends ConsumerStatefulWidget {
  const TaskManagerPage({super.key});

  @override
  ConsumerState<TaskManagerPage> createState() => _TaskManagerPageState();
}

/// 分页大小：一次只构建 50 条列表项，避免长列表卡顿。
const _pageSize = 50;

class _TaskManagerPageState extends ConsumerState<TaskManagerPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  int _lastTabIndex = 0;

  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  int _page = 0;
  bool _redownloading = false;

  /// 悬浮头部（搜索框）的测量 Key 与实测高度：搜索框悬浮于列表上方，
  /// 列表内容滚动时从毛玻璃下方穿过被模糊（与列表浮动按钮组同款
  /// 观感），列表顶部让出头部高度。
  final GlobalKey _floatingHeaderKey = GlobalKey();
  double _floatingHeaderExtent = 58;

  /// 多选删除模式：长按列表项进入。
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  /// 已完成记录的文件大小缓存（entry.id → 字节数，0 表示无可用大小）。
  final Map<String, int> _fileSizes = {};

  /// 正在读取文件大小的记录，防止重复 stat。
  final Set<String> _fileSizeInFlight = {};

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _tab.addListener(_handleTabChanged);
  }

  @override
  void dispose() {
    _tab.removeListener(_handleTabChanged);
    _tab.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// 切换 Tab 时重建 AppBar；离开「单项任务」时退出多选。
  void _handleTabChanged() {
    if (!mounted || _tab.index == _lastTabIndex) return;
    _lastTabIndex = _tab.index;
    setState(() {
      if (_tab.index != 1) {
        _selectionMode = false;
        _selectedIds.clear();
      }
    });
  }

  /// 布局完成后用真实高度修正悬浮头部占位，字体缩放等场景自动适配。
  void _measureFloatingHeader() {
    if (!mounted) return;
    final size = _floatingHeaderKey.currentContext?.size;
    if (size == null || size.height <= 0) return;
    if ((size.height - _floatingHeaderExtent).abs() > 0.5) {
      setState(() => _floatingHeaderExtent = size.height);
    }
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

  /// 为已完成记录读取实际文件大小：普通路径直接 stat；
  /// SAF content:// 路径无法直接 stat，回退用下载时记录的 totalBytes
  /// （封面/元数据内嵌前的体积，略有偏差但足够展示）。
  void _ensureFileSize(DownloadHistoryEntry entry) {
    if (entry.status != DownloadHistoryStatus.completed) return;
    if (_fileSizes.containsKey(entry.id) ||
        _fileSizeInFlight.contains(entry.id)) {
      return;
    }
    _fileSizeInFlight.add(entry.id);
    Future<int> resolve() async {
      final path = entry.savedPath?.trim() ?? '';
      if (path.isNotEmpty && !path.toLowerCase().startsWith('content://')) {
        try {
          return await File(path).length();
        } catch (_) {}
      }
      return entry.totalBytes;
    }

    resolve().then((size) {
      if (!mounted) return;
      setState(() => _fileSizes[entry.id] = size);
    }).whenComplete(() => _fileSizeInFlight.remove(entry.id));
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
      var directory = await resolveMusicDownloadDirectory(settings);
      if (!mounted) return;
      // SAF 目录授权校验：重装应用或恢复备份后持久化授权会丢失，直接
      // 写入会被系统以 MANAGE_DOCUMENTS 权限拒绝；失效时引导重新选择。
      directory =
          await ensureSafDirectoryAccess(context, ref, directory) ?? '';
      if (directory.isEmpty) {
        historyNotifier.fail(historyId, '已取消：下载目录未授权');
        if (mounted) {
          XyNotice.show(
            context,
            message: '已取消下载：下载目录未授权',
            type: XyNoticeType.warning,
          );
        }
        return;
      }
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
        sink: historyProgressSink(historyNotifier, historyId),
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

  /// 清空批量任务记录（带确认）。
  Future<void> _confirmClearBatchTasks() async {
    final tasks = ref.read(batchTaskProvider);
    if (tasks.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空批量任务'),
        content: Text('确定清空全部 ${tasks.length} 条批量任务记录吗？'),
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
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ref.read(batchTaskProvider.notifier).clear();
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
    final batchTasks = ref.watch(batchTaskProvider);

    // 布局完成后修正悬浮头部占位高度。
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _measureFloatingHeader(),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectionMode ? '已选择 ${_selectedIds.length} 项' : '任务管理'),
        leading: _selectionMode
            ? IconButton(
                tooltip: '退出多选',
                onPressed: _exitSelection,
                icon: const Icon(Icons.close_rounded),
              )
            : null,
        actions: _buildAppBarActions(entries, batchTasks),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: '批量任务'),
            Tab(text: '单项任务'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _buildBatchTasksTab(theme, batchTasks),
          _buildSingleTasksTab(theme, entries),
        ],
      ),
    );
  }

  List<Widget> _buildAppBarActions(
    List<DownloadHistoryEntry> entries,
    List<BatchTask> batchTasks,
  ) {
    if (_selectionMode) {
      return [
        IconButton(
          tooltip: _selectedIds.length >= entries.length && entries.isNotEmpty
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
      ];
    }
    if (_tab.index == 0) {
      return [
        IconButton(
          tooltip: '清空批量任务',
          onPressed: batchTasks.isEmpty ? null : _confirmClearBatchTasks,
          icon: const Icon(Icons.delete_sweep_outlined),
        ),
      ];
    }
    // 一键清空：等价于全选+批量删除，复用同一确认弹窗
    //（含「同时删除本地音乐文件」选项），不另起删除管线。
    return [
      IconButton(
        tooltip: '清空下载记录',
        onPressed: entries.isEmpty ? null : () => _confirmDelete(List.of(entries)),
        icon: const Icon(Icons.delete_sweep_outlined),
      ),
    ];
  }

  /// 「批量任务」Tab：一次批量操作一张卡片，点击进入实际歌曲列表。
  Widget _buildBatchTasksTab(ThemeData theme, List<BatchTask> tasks) {
    if (tasks.isEmpty) {
      return Center(
        child: Text(
          '暂无批量任务\n使用批量下载或批量换源后会记录在这里',
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        12,
        12,
        12,
        MediaQuery.paddingOf(context).bottom + 24,
      ),
      itemCount: tasks.length,
      itemBuilder: (context, index) => _buildBatchCard(theme, tasks[index]),
    );
  }

  Widget _buildBatchCard(ThemeData theme, BatchTask task) {
    final scheme = theme.colorScheme;
    final isDownload = task.kind == BatchTaskKind.download;
    final notifier = ref.read(batchTaskProvider.notifier);
    final summary = [
      '共 ${task.total} 首',
      if (task.successCount > 0) '成功 ${task.successCount}',
      if (task.failedCount > 0) '失败 ${task.failedCount}',
      if (task.skippedCount > 0) '跳过 ${task.skippedCount}',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(
          '/settings/tasks/batch/${Uri.encodeComponent(task.id)}',
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: scheme.primaryContainer,
                    child: Icon(
                      isDownload
                          ? Icons.download_rounded
                          : Icons.swap_horiz_rounded,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              isDownload ? '批量下载' : '批量换源',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 6),
                            _buildBatchStatusChip(theme, task.status),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_formatTime(task.createdAt)}\n$summary',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '删除记录',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _confirmDeleteBatchTask(task),
                    icon: const Icon(Icons.delete_outline_rounded, size: 21),
                  ),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
              if (task.isActive) ...[
                const SizedBox(height: 10),
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
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () => task.isRunning
                          ? notifier.pause(task.id)
                          : notifier.resume(task.id),
                      icon: Icon(
                        task.isRunning
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 20,
                      ),
                      label: Text(task.isRunning ? '暂停' : '继续'),
                    ),
                    TextButton.icon(
                      onPressed: () => _confirmCancelBatchTask(task),
                      icon: const Icon(Icons.stop_rounded, size: 20),
                      label: const Text('提前结束'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 批量任务状态标签：进行中 / 已暂停 / 已完成 / 已结束。
  Widget _buildBatchStatusChip(ThemeData theme, BatchTaskStatus status) {
    final scheme = theme.colorScheme;
    final (String label, Color color) = switch (status) {
      BatchTaskStatus.running => ('进行中', scheme.primary),
      BatchTaskStatus.paused => ('已暂停', Colors.orange.shade700),
      BatchTaskStatus.completed => ('已完成', scheme.onSurfaceVariant),
      BatchTaskStatus.cancelled => ('已结束', scheme.error),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }

  /// 提前结束批量任务（带确认）：正在处理的歌曲中断，未开始的歌曲不再执行。
  Future<void> _confirmCancelBatchTask(BatchTask task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: const Text('提前结束任务'),
        content: Text(
          '确定提前结束该${task.kind == BatchTaskKind.download ? '批量下载' : '批量换源'}任务吗？\n'
          '正在处理的歌曲会中断，未开始的歌曲不再执行。',
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
            child: const Text('结束'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ref.read(batchTaskProvider.notifier).cancel(task.id);
    }
  }

  /// 删除一条批量任务记录（带确认）。运行中的任务会先被结束，后台循环
  /// 随即停止处理剩余歌曲。
  Future<void> _confirmDeleteBatchTask(BatchTask task) async {
    final isDownload = task.kind == BatchTaskKind.download;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除批量任务'),
        content: Text(
          task.isActive
              ? '该${isDownload ? '批量下载' : '批量换源'}任务正在进行，删除后将立即结束并移除记录。'
              : '确定删除这条${isDownload ? '批量下载' : '批量换源'}记录吗？',
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
    );
    if (confirmed == true) {
      ref.read(batchTaskProvider.notifier).remove(task.id);
    }
  }

  /// 「单项任务」Tab：原下载记录列表（搜索 + 分页 + 多选删除）。
  Widget _buildSingleTasksTab(
    ThemeData theme,
    List<DownloadHistoryEntry> entries,
  ) {
    final totalPages = (entries.length / _pageSize).ceil();
    final safePage = _page.clamp(0, totalPages > 0 ? totalPages - 1 : 0);
    final pageEntries = entries
        .skip(safePage * _pageSize)
        .take(_pageSize)
        .toList();
    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.only(
              top: _selectionMode || entries.isEmpty ? 0 : _floatingHeaderExtent,
            ),
            child: entries.isEmpty
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
                                                (entry) => _selectedIds.contains(
                                                  entry.id,
                                                ),
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
                                      : () => setState(
                                          () => _page = safePage - 1,
                                        ),
                                  icon: const Icon(Icons.chevron_left_rounded),
                                ),
                                Text('${safePage + 1} / $totalPages'),
                                IconButton(
                                  tooltip: '下一页',
                                  onPressed: safePage >= totalPages - 1
                                      ? null
                                      : () => setState(
                                          () => _page = safePage + 1,
                                        ),
                                  icon: const Icon(Icons.chevron_right_rounded),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        if (!_selectionMode)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: KeyedSubtree(
              key: _floatingHeaderKey,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: FrostedSearchField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  showClearSuffix: true,
                  padding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
      ],
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
    // 懒加载已完成记录的实际文件大小（结果写入缓存后重建展示）。
    _ensureFileSize(entry);
    final sizeBytes = entry.status == DownloadHistoryStatus.completed
        ? _fileSizes[entry.id] ?? 0
        : 0;

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
            [
              entry.artist,
              qualityText,
              if (sizeBytes > 0) _formatBytes(sizeBytes),
              _formatTime(time),
            ].join(' · '),
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
                  [
                    if (isPaused) '已暂停',
                    if (entry.totalBytes > 0)
                      '${(entry.progress * 100).toStringAsFixed(0)}%'
                    else
                      _formatBytes(entry.downloadedBytes),
                    // 下载中同时展示已下载/总大小，方便预估体积。
                    if (entry.totalBytes > 0)
                      '${_formatBytes(entry.downloadedBytes)} / ${_formatBytes(entry.totalBytes)}',
                  ].join(' · '),
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