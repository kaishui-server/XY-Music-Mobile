import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/settings.dart';
import '../library/library_provider.dart';
import '../player/android_storage.dart';
import '../player/download_history_store.dart';
import '../plugins/plugin_runtime.dart' show qualityDisplayLabel;
import '../player/download_quality.dart';
import '../player/downloaded_song_store.dart';
import '../player/player_provider.dart';
import '../rust/api.dart';
import 'top_notice.dart' show XyNotice, XyNoticeType;

/// 批量下载选项（收藏页与歌单详情页共用）。
class BatchDownloadOptions {
  const BatchDownloadOptions({
    required this.directory,
    required this.quality,
    this.dontAskAgain = false,
    this.writeMetadata = true,
  });
  final String directory;
  final String quality;
  final bool dontAskAgain;

  /// 下载后向音频文件写入元数据标签（标题/艺术家/专辑/歌词/封面）。
  final bool writeMetadata;
}

/// 批量下载选项弹窗：选择下载位置与音质，可勾选“不再弹出”。
class BatchDownloadOptionsDialog extends StatefulWidget {
  const BatchDownloadOptionsDialog({
    super.key,
    required this.initialDirectory,
    required this.initialQuality,
    this.initialWriteMetadata = true,
    this.title = '批量下载',
  });
  final String initialDirectory;
  final String initialQuality;
  final bool initialWriteMetadata;
  final String title;

  @override
  State<BatchDownloadOptionsDialog> createState() =>
      _BatchDownloadOptionsDialogState();
}

class _BatchDownloadOptionsDialogState
    extends State<BatchDownloadOptionsDialog> {
  late final TextEditingController _directoryController;
  late String _directoryValue;
  late String _quality;
  bool _dontAskAgain = false;
  String? _error;
  bool _choosing = false;

  /// 音质档位与设置页“下载音质”一致（低 → 高，共 12 档，最高为超清
  /// 母带）；实际能否下载到该档位取决于插件支持，失败时自动降级。
  static const _qualities = [
    '96k',
    '128k',
    '192k',
    '320k',
    'flac',
    'flac24bit',
    'hires',
    'vinyl',
    'dolby',
    'atmos',
    'atmos_plus',
    'master',
  ];

  @override
  void initState() {
    super.initState();
    _directoryValue = widget.initialDirectory;
    _directoryController = TextEditingController(
      text: AndroidStorage.displayPath(widget.initialDirectory),
    );
    _quality = _normalize(widget.initialQuality);
  }

  @override
  void dispose() {
    _directoryController.dispose();
    super.dispose();
  }

  Future<void> _chooseDirectory() async {
    if (_choosing) return;
    setState(() => _choosing = true);
    try {
      final selected = Platform.isAndroid
          ? await AndroidStorage.pickDirectory()
          : await FilePicker.platform.getDirectoryPath();
      if (!mounted || selected == null) return;
      _directoryValue = selected;
      _directoryController.text = AndroidStorage.displayPath(selected);
      setState(() => _error = null);
    } catch (error) {
      if (mounted) setState(() => _error = '选择文件夹失败：$error');
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  void _submit() {
    final directory = _directoryValue.trim();
    if (directory.isEmpty) {
      setState(() => _error = '请输入或选择可访问的下载文件夹');
      return;
    }
    Navigator.pop(
      context,
      BatchDownloadOptions(
        directory: directory,
        quality: _quality,
        dontAskAgain: _dontAskAgain,
        writeMetadata: widget.initialWriteMetadata,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        height: 276,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '下载位置',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _directoryController,
                      maxLines: 1,
                      style: const TextStyle(fontSize: 13),
                      onChanged: (value) => _directoryValue = value,
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.folder_outlined, size: 19),
                        prefixIconConstraints: BoxConstraints(minWidth: 38),
                        hintText: '/storage/emulated/0/Music',
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 11,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 40,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 11),
                      ),
                      onPressed: _choosing ? null : _chooseDirectory,
                      icon: _choosing
                          ? const SizedBox.square(
                              dimension: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.folder_open_rounded, size: 18),
                      label: Text(
                        _choosing ? '选择中' : '选择',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                '下载音质',
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 5,
                children: [
                  for (final quality in _qualities)
                    ChoiceChip(
                      label: Text(
                        _qualityLabel(quality),
                        style: const TextStyle(fontSize: 12),
                      ),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      selected: _quality == quality,
                      onSelected: (_) => setState(() => _quality = quality),
                    ),
                ],
              ),
              CheckboxListTile(
                value: _dontAskAgain,
                onChanged: (value) =>
                    setState(() => _dontAskAgain = value == true),
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('不再弹出此窗口', style: TextStyle(fontSize: 13)),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('开始下载')),
      ],
    );
  }

  static String _normalize(String value) => switch (value.trim().toLowerCase()) {
    '96k' => '96k',
    '128k' || 'standard' => '128k',
    '192k' => '192k',
    '320k' || 'high' => '320k',
    'flac' || 'lossless' || 'sq' => 'flac',
    'flac24bit' => 'flac24bit',
    'hires' || 'hi-res' => 'hires',
    'vinyl' => 'vinyl',
    'dolby' => 'dolby',
    'atmos' => 'atmos',
    'atmos_plus' => 'atmos_plus',
    'master' => 'master',
    _ => '320k',
  };

  static String _qualityLabel(String quality) =>
      qualityDisplayLabel(quality);
}

/// 确保 SAF 下载目录仍可写：授权失效（重装应用/恢复备份/系统回收后
/// 持久化授权丢失）时引导用户重新选择目录，并同步更新下载路径设置。
///
/// 返回可用于本次下载的目录（授权正常时原样返回 [directory]，重新选择
/// 后返回新目录）；用户取消或选择失败时返回 null，调用方应中止下载。
Future<String?> ensureSafDirectoryAccess(
  BuildContext context,
  WidgetRef ref,
  String directory,
) async {
  if (!AndroidStorage.isTreeUri(directory)) return directory;
  if (await AndroidStorage.hasDirectoryGrant(directory)) return directory;
  if (!context.mounted) return null;
  final ok = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (dialogContext) => AlertDialog(
      title: const Text('下载目录授权失效'),
      content: const Text(
        '当前下载目录（SAF 文件夹）的访问授权已丢失，通常发生在重装应用或'
        '恢复备份之后。\n\n请重新选择下载目录，选择同一文件夹即可保留原目录。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('重新选择'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return null;
  final picked = await AndroidStorage.pickDirectory();
  final trimmed = picked?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  await ref.read(settingsProvider.notifier).setDownloadPath(trimmed);
  return trimmed;
}

/// 批量下载选中的歌曲（收藏页与歌单详情页共用）。
///
/// 逐首解析音源并下载，写入下载历史（下载管理页可见进度），
/// 支持暂停信号（用户在下载管理中暂停/删除任务时跳过该首）。
Future<void> runBatchDownload(
  BuildContext context,
  WidgetRef ref, {
  required List<Song> songs,
}) async {
  final settings = ref.read(settingsProvider).valueOrNull;
  final initialDirectory = await resolveMusicDownloadDirectory(settings);
  if (!context.mounted) return;
  final options = settings?.askDownloadDetails ?? true
      ? await showDialog<BatchDownloadOptions>(
          context: context,
          useRootNavigator: true,
          builder: (context) => BatchDownloadOptionsDialog(
            initialDirectory: initialDirectory,
            initialQuality: settings?.downloadQuality ?? '320k',
            initialWriteMetadata: settings?.downloadWriteMetadata ?? true,
          ),
        )
      : BatchDownloadOptions(
          directory: initialDirectory,
          quality: settings?.downloadQuality ?? '320k',
          writeMetadata: settings?.downloadWriteMetadata ?? true,
        );
  if (!context.mounted || options == null) return;
  final settingsNotifier = ref.read(settingsProvider.notifier);
  await settingsNotifier.setDownloadPath(options.directory.trim());
  await settingsNotifier.setDownloadQuality(options.quality);
  await settingsNotifier.setDownloadWriteMetadata(options.writeMetadata);
  if (options.dontAskAgain) {
    await settingsNotifier.setAskDownloadDetails(false);
  }
  if (!context.mounted) return;
  // SAF 目录授权校验：重装应用或恢复备份后持久化授权会丢失，直接写入
  // 会被系统以 MANAGE_DOCUMENTS 权限拒绝；失效时引导重新选择目录。
  final downloadDirectory = await ensureSafDirectoryAccess(
    context,
    ref,
    options.directory.trim(),
  );
  if (downloadDirectory == null) {
    if (context.mounted) {
      XyNotice.show(
        context,
        message: '已取消下载：下载目录未授权',
        type: XyNoticeType.warning,
      );
    }
    return;
  }
  var success = 0;
  var skipped = 0;
  var failed = 0;
  var completed = 0;
  final total = songs.length;
  final downgraded = <String>[];
  final failureReasons = <String>[];
  try {
    final usesSafDirectory = AndroidStorage.isTreeUri(downloadDirectory);
    final workDirectory = usesSafDirectory
        ? await resolveDownloadStagingDirectory()
        : downloadDirectory;
    await Directory(workDirectory).create(recursive: true);
    final notifier = ref.read(playerProvider.notifier);
    final historyNotifier = ref.read(downloadHistoryProvider.notifier);
    for (final song in songs) {
      if (playbackSourceTypeFor(song.toQueueItem()) ==
          PlaybackSourceType.localFile) {
        skipped++;
        continue;
      }
      // 已有同歌曲下载中的任务时跳过，避免重复记录。
      if (historyNotifier.hasActiveDownload(song.path)) {
        skipped++;
        continue;
      }
      final failedBefore = failed;
      final historyId = historyNotifier.begin(
        title: song.title,
        artist: song.artist,
        album: song.album,
        quality: options.quality,
        durationMs: song.duration * 1000,
        sourcePath: song.path,
        pluginId: song.pluginId,
        pluginData: song.pluginData,
        coverUrl: song.coverUrl,
      );
      try {
        final source = await notifier.resolveDownloadSourceFor(
          song.toQueueItem(),
          options.quality,
        );
        final destination = await resolveDownloadFullPath(
          directory: workDirectory,
          title: song.title,
          artist: song.artist,
          album: song.album,
          url: source.url,
          quality: options.quality,
          keepSourceFilename: false,
          fileNameStyle: 'artist-title',
          overwriteExisting: false,
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
        // 校验真实音质：magic bytes 检测实际格式，纠正扩展名并记录降级。
        final verified = await verifyDownloadedAudioQuality(
          savedPath: savedPath,
          selectedQuality: options.quality,
          durationSec: song.duration,
          songTitle: song.title,
        );
        if (verified.warning != null) downgraded.add(verified.warning!);
        final lyrics = song.lyricsRaw?.trim() ?? '';
        final coverUrl = song.coverUrl?.trim() ?? '';
        await finalizeDownloadExtras(
          requestJson: jsonEncode({
            if ((settings?.downloadLyrics ?? true) && lyrics.isNotEmpty)
              'lyricsText': lyrics,
            if ((settings?.downloadLyrics ?? true) && lyrics.isNotEmpty)
              'lyricsPath': p.setExtension(verified.path, '.lrc'),
            if (coverUrl.startsWith('http://') ||
                coverUrl.startsWith('https://'))
              'coverUrl': coverUrl,
            'embedCover': options.writeMetadata,
            if (options.writeMetadata)
              'metadata': {
                'filePath': verified.path,
                'title': song.title,
                'artist': song.artist,
                'album': song.album,
                if (lyrics.isNotEmpty) 'lyrics': lyrics,
              },
          }),
        );
        var finalPath = verified.path;
        if (usesSafDirectory) {
          finalPath = await AndroidStorage.copyFileToDirectory(
            directoryUri: downloadDirectory,
            sourcePath: verified.path,
            fileName: p.basename(verified.path),
            mimeType: 'audio/*',
          );
          final lrcPath = p.setExtension(verified.path, '.lrc');
          if (await File(lrcPath).exists()) {
            await AndroidStorage.copyFileToDirectory(
              directoryUri: downloadDirectory,
              sourcePath: lrcPath,
              fileName: p.basename(lrcPath),
              mimeType: 'text/plain',
            );
          }
          try {
            await File(verified.path).delete();
            if (await File(lrcPath).exists()) await File(lrcPath).delete();
          } catch (_) {}
        }
        await rememberDownloadedSongSnapshot(
          DownloadedSongSnapshot(
            path: finalPath,
            title: song.title,
            artist: song.artist,
            album: song.album,
            durationMs: song.duration * 1000,
            downloadedAt: DateTime.now().millisecondsSinceEpoch,
            sourcePath: song.path,
            quality: verified.quality,
            coverUrl: song.coverUrl,
            lyricsRaw: lyrics.isEmpty ? null : lyrics,
          ),
        );
        historyNotifier.complete(
          historyId,
          savedPath: finalPath,
          actualQuality: verified.quality,
        );
        success++;
      } catch (error) {
        if (error is DownloadPausedSignal) {
          // 用户在下载管理中暂停/删除了该任务：计入跳过，不提示失败。
          skipped++;
        } else {
          failed++;
          failureReasons.add('${song.title}：$error');
          historyNotifier.fail(historyId, error.toString());
        }
      }
      completed++;
      if (context.mounted) {
        final reason = failed > failedBefore
            ? '：${failureReasons.last.split('：').skip(1).join('：')}'
            : '';
        XyNotice.show(
          context,
          message: '${failed > failedBefore ? '歌曲《${song.title}》下载失败$reason' : '歌曲《${song.title}》下载完成'}（$completed/$total）',
          type: failed > failedBefore
              ? XyNoticeType.error
              : XyNoticeType.success,
          compact: true,
        );
      }
    }
    if (context.mounted) {
      final summary =
          '批量下载完成：成功 $success 首'
          '${skipped > 0 ? '，本地歌曲跳过 $skipped 首' : ''}'
          '${failed > 0 ? '，失败 $failed 首' : ''}'
          '${downgraded.isNotEmpty ? '，${downgraded.length} 首低于所选音质' : ''}';
      final details = <String>[
        if (failureReasons.isNotEmpty) '失败原因：${failureReasons.join('；')}',
        if (downgraded.isNotEmpty) downgraded.first,
      ].join('\n');
      XyNotice.show(
        context,
        message: details.isEmpty ? summary : '$summary\n$details',
        type: failed > 0 || downgraded.isNotEmpty
            ? XyNoticeType.warning
            : XyNoticeType.success,
        duration: details.isEmpty
            ? const Duration(milliseconds: 2600)
            : const Duration(milliseconds: 6000),
      );
    }
  } finally {
    // 调用方负责自身的 downloading 状态复位；这里不再额外提示。
  }
}
