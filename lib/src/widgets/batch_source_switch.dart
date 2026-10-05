import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../library/library_provider.dart';
import '../player/batch_task_store.dart';
import '../plugins/plugin_runtime.dart';
import 'source_switch.dart';
import 'top_notice.dart' show XyNotice, XyNoticeType;

/// 后台批量换源：在宿主页面之外持续执行，用户可继续听歌或切换到其他页面。
///
/// 歌曲数 ≥ 2 时创建一条批量任务（任务管理页可见进度、可暂停 / 提前结束），
/// 逐首在目标插件搜索同名歌曲并回调 [replace] 原位替换；每首成功 / 失败
/// 不再逐条弹窗，仅在开始与全部完成时提示。宿主页面被销毁后任务仍会继续，
/// 结果落在批量任务记录里。
Future<void> runBatchSwitchSource(
  BuildContext context,
  WidgetRef ref, {
  required List<Song> songs,
  required EnabledMusicPlugin plugin,
  String? lxSource,
  required Future<void> Function(Song original, Song replacement) replace,
  void Function(int done, int total)? onProgress,
  VoidCallback? onFinished,
}) async {
  if (songs.isEmpty) return;
  // 依赖在启动时一次性捕获：循环内不再触碰 WidgetRef / BuildContext，
  // 页面销毁后仍能继续执行（插件运行时与各 Provider 均为应用级生命周期）。
  final batchNotifier = ref.read(batchTaskProvider.notifier);
  final runtime = ref.read(pluginRuntimeProvider);
  final batchTaskId = songs.length >= 2
      ? batchNotifier.create(
          kind: BatchTaskKind.switchSource,
          songs: [
            for (final song in songs)
              BatchTaskSong(
                title: song.title,
                artist: song.artist,
                album: song.album,
                status: BatchTaskSongStatus.pending,
              ),
          ],
        )
      : null;
  if (context.mounted) {
    XyNotice.show(
      context,
      message: '开始换源 ${songs.length} 首…',
      compact: true,
    );
  }
  var replaced = 0;
  var failed = 0;
  var index = 0;
  // 在 finish 清除取消标记前捕获，供收尾提示区分「提前结束 / 完成」。
  var cancelled = false;
  try {
    while (index < songs.length) {
      if (batchTaskId != null) {
        // 提前结束：不再开始后续歌曲。
        if (!await batchNotifier.waitWhilePaused(batchTaskId)) break;
        batchNotifier.updateSong(
          batchTaskId,
          index,
          status: BatchTaskSongStatus.processing,
        );
      }
      final song = songs[index];
      try {
        final candidates = await searchReplacementCandidatesWithRuntime(
          runtime,
          plugin,
          title: song.title,
          artist: song.artist,
          durationMs: song.duration * 1000,
          lxSource: lxSource,
        );
        if (candidates.isEmpty) {
          failed++;
          if (batchTaskId != null) {
            batchNotifier.updateSong(
              batchTaskId,
              index,
              status: BatchTaskSongStatus.failed,
              detail: '未找到匹配结果',
            );
          }
        } else {
          await replace(song, replacementToSong(plugin, candidates.first));
          replaced++;
          if (batchTaskId != null) {
            batchNotifier.updateSong(
              batchTaskId,
              index,
              status: BatchTaskSongStatus.success,
              detail: '已切换到 ${plugin.name}',
            );
          }
        }
      } catch (error) {
        failed++;
        if (batchTaskId != null) {
          batchNotifier.updateSong(
            batchTaskId,
            index,
            status: BatchTaskSongStatus.failed,
            detail: error.toString(),
          );
        }
      }
      index++;
      onProgress?.call(index, songs.length);
    }
  } finally {
    // 收尾：未处理的歌曲标记为跳过，任务置为已完成 / 已取消。
    if (batchTaskId != null) {
      cancelled = batchNotifier.isCancelled(batchTaskId);
      for (var rest = index; rest < songs.length; rest++) {
        batchNotifier.updateSong(
          batchTaskId,
          rest,
          status: BatchTaskSongStatus.skipped,
          detail: cancelled ? '已取消' : '未完成',
        );
      }
      batchNotifier.finish(batchTaskId);
    }
    onFinished?.call();
  }
  if (!context.mounted) return;
  XyNotice.show(
    context,
    message:
        '${cancelled ? '批量换源已提前结束' : '换源完成'}：成功 $replaced 首'
        '${failed > 0 ? '，失败 $failed 首' : ''}',
    type: failed > 0 ? XyNoticeType.warning : XyNoticeType.success,
  );
}