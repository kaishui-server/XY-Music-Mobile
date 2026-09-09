import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../library/library_provider.dart';
import '../player/player_provider.dart';
import '../plugins/plugin_runtime.dart';

/// 换源：把歌曲切换到其他已启用插件的同名音源。
///
/// 参考闲鱼音乐的换源交互：先选择目标音源（插件列表标记类型），
/// 搜索「歌名 歌手」后按 `recognizedSongMatchScore` 打分取最佳匹配；
/// 单曲换源时弹出候选列表供用户挑选，批量换源自动取最高分。

/// 插件类型标记：Baka 系 / MusicFree / 洛雪（与歌单网络导入对话框一致）。
String sourcePluginTag(EnabledMusicPlugin plugin) =>
    plugin.isLx ? '洛雪' : (plugin.name.toLowerCase().contains('baka') ? 'Baka' : 'MusicFree');

/// 选择换源目标插件的对话框；取消返回 null。
Future<EnabledMusicPlugin?> showSourcePluginPicker(
  BuildContext context,
  List<EnabledMusicPlugin> plugins, {
  String? excludePluginId,
}) {
  final candidates = [
    for (final plugin in plugins)
      if (plugin.id != excludePluginId) plugin,
  ];
  return showDialog<EnabledMusicPlugin>(
    context: context,
    useRootNavigator: true,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('选择目标音源'),
      children: [
        if (candidates.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: Text('没有其他可用的插件，请先在 设置 → 插件 中启用'),
          )
        else
          for (final plugin in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, plugin),
              child: Row(
                children: [
                  Icon(
                    Icons.extension_rounded,
                    size: 20,
                    color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${plugin.name}（${sourcePluginTag(plugin)}）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
      ],
    ),
  );
}

/// 在目标插件上搜索替换候选，按匹配度降序返回（仅保留标题匹配的结果）。
Future<List<PluginSearchSong>> searchReplacementCandidates(
  WidgetRef ref,
  EnabledMusicPlugin plugin, {
  required String title,
  required String artist,
  int durationMs = 0,
}) async {
  final keyword = artist.trim().isEmpty
      ? title.trim()
      : '${title.trim()} ${artist.trim()}';
  final results = await ref
      .read(pluginRuntimeProvider)
      .search(plugin, keyword)
      .timeout(const Duration(seconds: 20), onTimeout: () => const []);
  final scored = <(int, PluginSearchSong)>[];
  for (final song in results) {
    final score = recognizedSongMatchScore(
      title: title,
      artist: artist,
      durationMs: durationMs,
      candidateTitle: song.title,
      candidateArtist: song.artist,
      candidateDurationMs: song.durationMs,
    );
    if (score >= 100) scored.add((score, song));
  }
  scored.sort((a, b) => b.$1.compareTo(a.$1));
  return [for (final entry in scored) entry.$2];
}

/// 搜索结果 → 可播放/可入库的队列项。
QueueItem replacementToQueueItem(
  EnabledMusicPlugin plugin,
  PluginSearchSong song,
) => QueueItem(
  path: pluginSongPath(plugin, song),
  title: song.title,
  artist: song.artist,
  album: song.album,
  durationMs: song.durationMs,
  pluginId: plugin.id,
  pluginData: song.rawData,
  coverUrl: song.coverUrl,
);

/// 搜索结果 → 歌单曲目。
Song replacementToSong(EnabledMusicPlugin plugin, PluginSearchSong song) =>
    Song(
      path: pluginSongPath(plugin, song),
      title: song.title,
      artist: song.artist,
      album: song.album,
      albumKey: song.album,
      duration: (song.durationMs / 1000).round(),
      format: '网络',
      coverUrl: song.coverUrl,
      pluginId: plugin.id,
      pluginData: song.rawData,
    );

/// 单曲换源的候选列表（最多展示前 8 个），取消返回 null。
Future<PluginSearchSong?> showReplacementPicker(
  BuildContext context,
  WidgetRef ref,
  EnabledMusicPlugin plugin, {
  required String title,
  required String artist,
}) {
  return showDialog<PluginSearchSong>(
    context: context,
    useRootNavigator: true,
    builder: (dialogContext) => _ReplacementPickerDialog(
      plugin: plugin,
      title: title,
      artist: artist,
    ),
  );
}

class _ReplacementPickerDialog extends ConsumerStatefulWidget {
  const _ReplacementPickerDialog({
    required this.plugin,
    required this.title,
    required this.artist,
  });

  final EnabledMusicPlugin plugin;
  final String title;
  final String artist;

  @override
  ConsumerState<_ReplacementPickerDialog> createState() =>
      _ReplacementPickerDialogState();
}

class _ReplacementPickerDialogState
    extends ConsumerState<_ReplacementPickerDialog> {
  late Future<List<PluginSearchSong>> _future;

  @override
  void initState() {
    super.initState();
    _future = searchReplacementCandidates(
      ref,
      widget.plugin,
      title: widget.title,
      artist: widget.artist,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('换源：${widget.title}'),
      content: SizedBox(
        width: 400,
        child: FutureBuilder<List<PluginSearchSong>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 160,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return SizedBox(
                height: 120,
                child: Center(
                  child: Text(
                    '搜索失败：${snapshot.error.toString().replaceFirst('Exception: ', '')}',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            final songs = (snapshot.data ?? const <PluginSearchSong>[])
                .take(8)
                .toList();
            if (songs.isEmpty) {
              return const SizedBox(
                height: 120,
                child: Center(child: Text('没有找到匹配的歌曲')),
              );
            }
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final song in songs)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(
                        song.durationMs > 0
                            ? '${(song.durationMs / 1000).round() ~/ 60}:'
                                '${((song.durationMs / 1000).round() % 60).toString().padLeft(2, '0')}'
                            : '',
                      ),
                      onTap: () => Navigator.pop(context, song),
                    ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
