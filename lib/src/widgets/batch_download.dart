import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/settings.dart';
import '../library/library_provider.dart';
import '../player/android_storage.dart';
import '../player/download_history_store.dart';
import '../player/download_lyrics.dart';
import '../plugins/plugin_runtime.dart'
    show declaredQualityTokens, qualityDisplayLabel, qualityTierRank;
import '../player/download_quality.dart';
import '../player/downloaded_song_store.dart';
import '../player/player_provider.dart';
import '../rust/api.dart';
import 'download_options_dialog.dart';
import 'quality_fallback_dialog.dart';
import 'top_notice.dart' show XyNotice, XyNoticeType;

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

/// 批量下载前检测哪些歌曲不支持目标音质。
///
/// 直接读取插件歌曲快照中声明的音质表（MusicFree 的 qualities、洛雪的
/// _types 等），全程同步、不发起任何联网探测——逐首联网探测在大批量下
/// 每首要数秒，19 首就要近一分钟，无法接受。没有音质声明的歌曲无法判定，
/// 按支持处理，真实降级仍由下载后的音质校验兜底。
///
/// 返回 `歌曲路径 -> 该歌曲声明的音质列表（低 → 高）`。
Map<String, List<String>> _detectUnsupportedQuality(
  List<Song> songs, {
  required String quality,
}) {
  final target = quality.trim();
  if (target.isEmpty) return const {};
  final targetLabel = qualityDisplayLabel(target);
  final unsupported = <String, List<String>>{};
  for (final song in songs) {
    if (playbackSourceTypeFor(song.toQueueItem()) ==
        PlaybackSourceType.localFile) {
      continue;
    }
    final declared = declaredQualityTokens(song.pluginData);
    if (declared.isEmpty) continue;
    // 同档位别名（flac/lossless/sq 等）映射到同一显示名称，按名称判定。
    if (declared.any((value) => qualityDisplayLabel(value) == targetLabel)) {
      continue;
    }
    final sorted = [...declared]..sort((a, b) {
      final rank = qualityTierRank(a).compareTo(qualityTierRank(b));
      return rank != 0 ? rank : a.compareTo(b);
    });
    unsupported[song.path] = sorted;
  }
  return unsupported;
}

/// 探测单首歌曲在指定音质下的真实文件大小（字节），供下载弹窗右侧展示。
/// 解析失败或无法确定时返回 null，由弹窗回退到估算值或显示“未知”。
Future<int?> _probeSongDownloadSize(
  WidgetRef ref,
  Song song,
  String quality,
) async {
  try {
    final source = await ref
        .read(playerProvider.notifier)
        .resolveDownloadSourceFor(
          song.toQueueItem(),
          quality,
          includeLyrics: false,
        )
        .timeout(const Duration(seconds: 20));
    return await probeDirectFileSize(source.url, source.headers);
  } catch (_) {
    // 单档位探测失败：保留估算值或显示“未知”，不打断下载弹窗。
  }
  return null;
}

/// 批量下载选中的歌曲（收藏页与歌单详情页共用）。
///
/// 逐首解析音源并下载，写入下载历史（下载管理页可见进度），
/// 支持暂停信号（用户在下载管理中暂停/删除任务时跳过该首）。
Future<void> runBatchDownload(
  BuildContext context,
  WidgetRef ref, {
  required List<Song> songs,
  String? qualityOverride,
}) async {
  final settings = ref.read(settingsProvider).valueOrNull;
  final initialDirectory = await resolveMusicDownloadDirectory(settings);
  if (!context.mounted) return;
  // 指定音质（通用批量面板已选档位）时跳过选项对话框：直接用已保存的
  // 下载目录与该音质下载，不再重复询问。
  // 单曲下载时弹窗展示各档位文件大小（与播放详情页一致）；批量无意义。
  final singleSong = songs.length == 1 ? songs.first : null;
  final options = qualityOverride != null
      ? DownloadOptions(
          directory: initialDirectory,
          quality: qualityOverride,
          writeMetadata: settings?.downloadWriteMetadata ?? true,
        )
      : settings?.askDownloadDetails ?? true
      ? await showDialog<DownloadOptions>(
          context: context,
          useRootNavigator: true,
          builder: (context) => DownloadOptionsDialog(
            title: singleSong != null ? '下载歌曲' : '批量下载',
            initialDirectory: initialDirectory,
            initialQuality: settings?.downloadQuality ?? '320k',
            qualities: kDownloadQualityOptions,
            initialWriteMetadata: settings?.downloadWriteMetadata ?? true,
            showSizes: singleSong != null,
            estimateSize: singleSong == null
                ? null
                : (quality) {
                    final bytes = estimateLossyDownloadSizeBytes(
                      quality,
                      singleSong.duration * 1000,
                    );
                    return bytes == null
                        ? null
                        : QualitySize(bytes, estimated: true);
                  },
            probeSize: singleSong == null
                ? null
                : (quality) => _probeSongDownloadSize(ref, singleSong, quality),
          ),
        )
      : DownloadOptions(
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
  // 目标音质支持检测：批量下载时部分歌曲可能不支持所选音质，先列出
  // 这些歌曲并让用户选择回退方式（最高 / 最低 / 不下载），再开始下载。
  final qualityByPath = <String, String>{};
  final qualitySkippedPaths = <String>{};
  if (songs.length > 1 && context.mounted) {
    // 检测为纯同步内存计算（读插件快照声明的音质表），瞬时完成，无需提示。
    final unsupported = _detectUnsupportedQuality(
      songs,
      quality: options.quality,
    );
    if (!context.mounted) return;
    if (unsupported.isNotEmpty) {
      final unsupportedSongs = [
        for (final song in songs)
          if (unsupported.containsKey(song.path)) song,
      ];
      final decision = await showQualityFallbackDialog(
        context,
        songs: unsupportedSongs,
        targetQuality: options.quality,
      );
      if (decision == null || !context.mounted) return;
      for (final song in unsupportedSongs) {
        final available = unsupported[song.path]!;
        final include =
            decision.action != QualityFallbackAction.skip &&
            decision.selectedPaths.contains(song.path);
        if (!include) {
          qualitySkippedPaths.add(song.path);
          continue;
        }
        qualityByPath[song.path] =
            decision.action == QualityFallbackAction.lowest
            ? available.first
            : available.last;
      }
    }
  }
  var success = 0;
  var skipped = 0;
  var qualitySkipped = 0;
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
      // 用户选择「不下载」或取消勾选的不支持音质歌曲：直接跳过。
      if (qualitySkippedPaths.contains(song.path)) {
        qualitySkipped++;
        continue;
      }
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
      // 不支持目标音质的歌曲使用用户选定的回退音质（最高 / 最低）。
      final songQuality = qualityByPath[song.path] ?? options.quality;
      final failedBefore = failed;
      final historyId = historyNotifier.begin(
        title: song.title,
        artist: song.artist,
        album: song.album,
        quality: songQuality,
        durationMs: song.duration * 1000,
        sourcePath: song.path,
        pluginId: song.pluginId,
        pluginData: song.pluginData,
        coverUrl: song.coverUrl,
      );
      try {
        final source = await notifier.resolveDownloadSourceFor(
          song.toQueueItem(),
          songQuality,
        );
        final destination = await resolveDownloadFullPath(
          directory: workDirectory,
          title: song.title,
          artist: song.artist,
          album: song.album,
          url: source.url,
          quality: songQuality,
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
          selectedQuality: songQuality,
          durationSec: song.duration,
          songTitle: song.title,
        );
        if (verified.warning != null) downgraded.add(verified.warning!);
        // 列表歌曲的 lyricsRaw 多为空（歌词只在播放时加载），音源解析
        // 返回的歌词兜底；QRC/KRC 密文解码为标准 LRC 再落盘。
        final rawLyrics = song.lyricsRaw?.trim().isNotEmpty == true
            ? song.lyricsRaw!.trim()
            : source.lyrics.trim();
        final lyrics = (settings?.downloadLyrics ?? true)
            ? await normalizeLyricsForDownload(rawLyrics)
            : '';
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
          '${qualitySkipped > 0 ? '，$qualitySkipped 首不支持所选音质未下载' : ''}'
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
