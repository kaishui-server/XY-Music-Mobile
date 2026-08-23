import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../src/core/db_path.dart';
import '../../src/core/settings.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/player/player_provider.dart';
import '../../src/player/downloaded_song_store.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/rust/api.dart';
import '../../src/rust/music/types.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/top_notice.dart';

final _lyricsProvider = FutureProvider.autoDispose
    .family<List<_LyricLine>, String>((ref, path) async {
      final dbPath = await ref.watch(dbPathProvider.future);
      final raw = await getSongLyricsPayload(dbPath: dbPath, path: path);
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      return _decodeLyricLines(payload);
    });

final _embeddedLyricsProvider = FutureProvider.autoDispose
    .family<List<_LyricLine>, String>((ref, rawLyrics) async {
      final raw = await parseLyrics(rawLyrics: rawLyrics);
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      return _decodeLyricLines(payload);
    });

List<_LyricLine> _decodeLyricLines(Map<String, dynamic> payload) {
  return (payload['displayLines'] as List? ?? const [])
      .whereType<Map>()
      .map((value) {
        final line = Map<String, dynamic>.from(value);
        return _LyricLine(
          time: (line['time'] as num?)?.toDouble() ?? 0,
          endTime: (line['endTime'] as num?)?.toDouble() ?? 0,
          text: line['text'] as String? ?? '',
          translation: line['translation'] as String? ?? '',
          romaji: line['romaji'] as String? ?? '',
          words: _decodeLyricWords(line['words']),
        );
      })
      .where((line) => line.text.trim().isNotEmpty)
      .toList();
}

List<_LyricWord> _decodeLyricWords(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((raw) {
        final word = Map<String, dynamic>.from(raw);
        return _LyricWord(
          text: word['text']?.toString() ?? '',
          start: (word['start'] as num?)?.toDouble() ?? 0,
          end: (word['end'] as num?)?.toDouble() ?? 0,
        );
      })
      .where((word) => word.text.isNotEmpty)
      .toList();
}

class _LyricWord {
  const _LyricWord({
    required this.text,
    required this.start,
    required this.end,
  });

  final String text;
  final double start;
  final double end;
}

class _LyricLine {
  const _LyricLine({
    required this.time,
    required this.endTime,
    required this.text,
    required this.translation,
    required this.romaji,
    this.words = const [],
  });
  final double time;
  final double endTime;
  final String text;
  final String translation;
  final String romaji;
  final List<_LyricWord> words;
}

enum _PlayerMenuAction {
  download,
  quality,
  playlist,
  linkLyrics,
  lyricsOffset,
  sleepTimer,
}

enum _LyricsSourceAction { plugin, local }

enum _SleepTimerOption {
  off,
  minutes15,
  minutes30,
  minutes45,
  minutes60,
  minutes90,
  custom,
}

class _DownloadOptions {
  const _DownloadOptions({required this.directory, required this.quality});

  final String directory;
  final String quality;
}

String _formatSleepDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = totalSeconds.remainder(3600) ~/ 60;
  final seconds = totalSeconds.remainder(60);
  final parts = <String>[];
  if (hours > 0) parts.add('$hours 小时');
  if (minutes > 0) parts.add('$minutes 分钟');
  if (seconds > 0 || parts.isEmpty) parts.add('$seconds 秒');
  return parts.join(' ');
}

const _lyricsOffsetsPreferenceKey = 'playerLyricsOffsetsTenthsV1';

int clampLyricsOffsetTenths(int value) => value.clamp(-100, 100);

double applyLyricsOffset(double playbackPosition, int offsetTenths) =>
    playbackPosition + clampLyricsOffsetTenths(offsetTenths) / 10;

double playbackPositionForLyric(double lyricTime, int offsetTenths) =>
    math.max(0, lyricTime - clampLyricsOffsetTenths(offsetTenths) / 10);

String lyricsOffsetLabel(int offsetTenths) {
  final normalized = clampLyricsOffsetTenths(offsetTenths);
  if (normalized == 0) return '无偏移';
  final seconds = (normalized.abs() / 10).toStringAsFixed(1);
  return normalized > 0 ? '提前 $seconds 秒' : '延后 $seconds 秒';
}

/// 正在播放页：现代毛玻璃风格。
/// 封面大圆角浮于流光背景之上，下方毛玻璃控制卡承载进度与按钮。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  late final PageController _detailPageController = PageController();
  bool _showLyrics = false;
  int? _detailPointerId;
  Offset? _detailPointerStart;
  Offset? _detailPointerLast;
  String? _lyricsOffsetSongPath;
  int _lyricsOffsetTenths = 0;
  int _lyricsOffsetLoadRequest = 0;

  void _toggleLyrics() {
    _showDetailPage(!_showLyrics);
  }

  void _loadLyricsOffsetFor(QueueItem? item) {
    final path = item?.path;
    if (_lyricsOffsetSongPath == path) return;
    _lyricsOffsetSongPath = path;
    _lyricsOffsetTenths = 0;
    final requestId = ++_lyricsOffsetLoadRequest;
    if (path == null || path.isEmpty) return;
    unawaited(() async {
      try {
        final preferences = await SharedPreferences.getInstance();
        final raw = preferences.getString(_lyricsOffsetsPreferenceKey);
        final decoded = raw == null || raw.isEmpty ? null : jsonDecode(raw);
        final stored = decoded is Map ? decoded[path] : null;
        final offset = clampLyricsOffsetTenths((stored as num?)?.toInt() ?? 0);
        if (!mounted ||
            requestId != _lyricsOffsetLoadRequest ||
            _lyricsOffsetSongPath != path) {
          return;
        }
        setState(() => _lyricsOffsetTenths = offset);
      } catch (_) {
        // 单曲偏移读取失败时使用无偏移，不影响歌词显示。
      }
    }());
  }

  Future<void> _saveLyricsOffset(String path, int offsetTenths) async {
    final normalized = clampLyricsOffsetTenths(offsetTenths);
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_lyricsOffsetsPreferenceKey);
    Map<String, dynamic> offsets;
    try {
      final decoded = raw == null || raw.isEmpty ? null : jsonDecode(raw);
      offsets = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } catch (_) {
      offsets = <String, dynamic>{};
    }
    if (normalized == 0) {
      offsets.remove(path);
    } else {
      offsets[path] = normalized;
    }
    await preferences.setString(
      _lyricsOffsetsPreferenceKey,
      jsonEncode(offsets),
    );
  }

  void _startDetailSwipe(PointerDownEvent event) {
    if (_detailPointerId != null) return;
    _detailPointerId = event.pointer;
    _detailPointerStart = event.position;
    _detailPointerLast = event.position;
  }

  void _updateDetailSwipe(PointerMoveEvent event) {
    if (_detailPointerId == event.pointer) {
      _detailPointerLast = event.position;
    }
  }

  void _finishDetailSwipe(PointerEvent event, double viewportWidth) {
    if (_detailPointerId != event.pointer) return;
    final start = _detailPointerStart;
    final end = event is PointerCancelEvent
        ? null
        : (_detailPointerLast ?? event.position);
    _clearDetailSwipe();
    if (start == null || end == null) return;

    final delta = end - start;
    final horizontalDistance = delta.dx.abs();
    final verticalDistance = delta.dy.abs();
    final requiredDistance = math.max(
      84.0,
      math.min(128.0, viewportWidth * .24),
    );
    if (horizontalDistance < requiredDistance ||
        horizontalDistance < verticalDistance * 1.65) {
      return;
    }
    if (delta.dx < 0 && !_showLyrics) {
      _showDetailPage(true);
    } else if (delta.dx > 0 && _showLyrics) {
      _showDetailPage(false);
    }
  }

  void _clearDetailSwipe() {
    _detailPointerId = null;
    _detailPointerStart = null;
    _detailPointerLast = null;
  }

  Future<void> _showMoreMenu(QueueItem item) async {
    final settings = ref.read(settingsProvider).valueOrNull;
    final action = await showModalBottomSheet<_PlayerMenuAction>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => Consumer(
        builder: (context, ref, child) {
          final sleepTimerEndsAt = ref.watch(
            playerProvider.select((state) => state.sleepTimerEndsAt),
          );
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Row(
                      children: [
                        CoverImage(
                          songPath: item.path,
                          imageUrl: item.coverUrl,
                          width: 54,
                          height: 54,
                          radius: 12,
                          icon: Icons.music_note_rounded,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                item.artist.trim().isEmpty
                                    ? '未知歌手'
                                    : item.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Theme.of(
                                    sheetContext,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  _moreTile(
                    sheetContext,
                    action: _PlayerMenuAction.download,
                    icon: Icons.download_rounded,
                    title: '下载',
                  ),
                  _moreTile(
                    sheetContext,
                    action: _PlayerMenuAction.quality,
                    icon: Icons.high_quality_rounded,
                    title: '选择音质',
                    value: _qualityLabel(
                      settings?.onlineDefaultQuality ?? '320k',
                    ),
                  ),
                  _moreTile(
                    sheetContext,
                    action: _PlayerMenuAction.playlist,
                    icon: Icons.playlist_add_rounded,
                    title: '添加到歌单',
                  ),
                  _moreTile(
                    sheetContext,
                    action: _PlayerMenuAction.linkLyrics,
                    icon: Icons.lyrics_outlined,
                    title: '关联歌词',
                  ),
                  _moreTile(
                    sheetContext,
                    action: _PlayerMenuAction.lyricsOffset,
                    icon: Icons.sync_alt_rounded,
                    title: '歌词偏移',
                    value: lyricsOffsetLabel(_lyricsOffsetTenths),
                  ),
                  _moreTile(
                    sheetContext,
                    action: _PlayerMenuAction.sleepTimer,
                    icon: Icons.timer_outlined,
                    title: '定时关闭',
                    value: _sleepTimerLabel(sleepTimerEndsAt),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _PlayerMenuAction.download:
        await _downloadCurrent(item);
      case _PlayerMenuAction.quality:
        await _pickPlaybackQuality();
      case _PlayerMenuAction.playlist:
        await _addToPlaylist(item);
      case _PlayerMenuAction.linkLyrics:
        await _linkLyrics(item);
      case _PlayerMenuAction.lyricsOffset:
        await _pickLyricsOffset(item);
      case _PlayerMenuAction.sleepTimer:
        await _pickSleepTimer();
    }
  }

  Future<void> _addToPlaylist(QueueItem item) async {
    final playlistId = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PlaylistPickerSheet(item: item),
    );
    if (!mounted || playlistId == null) return;
    final playlist = ref
        .read(playlistsProvider)
        .where((value) => value.id == playlistId)
        .firstOrNull;
    XyNotice.show(
      context,
      message: playlist == null ? '已添加到歌单' : '已添加到歌单“${playlist.name}”',
      type: XyNoticeType.success,
    );
  }

  Widget _moreTile(
    BuildContext context, {
    required _PlayerMenuAction action,
    required IconData icon,
    required String title,
    String? value,
  }) {
    return ListTile(
      minTileHeight: 54,
      leading: Icon(icon),
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value?.isNotEmpty == true)
            Text(
              value!,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(width: 4),
          Icon(
            Icons.chevron_right,
            size: 18,
            color: Theme.of(context).colorScheme.outline,
          ),
        ],
      ),
      onTap: () => Navigator.pop(context, action),
    );
  }

  Future<void> _pickPlaybackQuality() async {
    final current =
        ref.read(settingsProvider).valueOrNull?.onlineDefaultQuality ?? '320k';
    final quality = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final value in const ['128k', '192k', '320k', 'flac'])
                ListTile(
                  title: Text(_qualityLabel(value)),
                  trailing: value == current
                      ? Icon(
                          Icons.check_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () => Navigator.pop(context, value),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || quality == null || quality == current) return;
    XyNotice.show(context, message: '正在切换为 ${_qualityLabel(quality)}…');
    await ref.read(playerProvider.notifier).setCurrentQuality(quality);
    if (!mounted) return;
    final error = ref.read(playerProvider).errorMessage;
    XyNotice.show(
      context,
      message: error ?? '已切换为 ${_qualityLabel(quality)}',
      type: error == null ? XyNoticeType.success : XyNoticeType.error,
    );
  }

  Future<void> _linkLyrics(QueueItem item) async {
    final source = await showModalBottomSheet<_LyricsSourceAction>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '关联歌词',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: const Text('从插件获取'),
              subtitle: const Text('搜索所有已启用插件提供的歌词'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pop(context, _LyricsSourceAction.plugin),
            ),
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('从本地上传'),
              subtitle: const Text('选择 LRC、YRC、QRC 等歌词文件'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pop(context, _LyricsSourceAction.local),
            ),
          ],
        ),
      ),
    );
    if (!mounted || source == null) return;
    if (source == _LyricsSourceAction.plugin) {
      await _linkLyricsFromPlugin(item);
    } else {
      await _linkLyricsFromLocal(item);
    }
  }

  Future<void> _pickLyricsOffset(QueueItem item) async {
    final selected = await showDialog<int>(
      context: context,
      useRootNavigator: true,
      builder: (context) =>
          _LyricsOffsetDialog(initialOffsetTenths: _lyricsOffsetTenths),
    );
    if (!mounted || selected == null) return;
    if (ref.read(playerProvider).current?.path != item.path) {
      XyNotice.show(
        context,
        message: '歌曲已切换，请重新设置歌词偏移',
        type: XyNoticeType.warning,
      );
      return;
    }
    try {
      await _saveLyricsOffset(item.path, selected);
      if (!mounted || ref.read(playerProvider).current?.path != item.path) {
        return;
      }
      setState(() => _lyricsOffsetTenths = selected);
      XyNotice.show(
        context,
        message: selected == 0
            ? '已清除当前歌曲的歌词偏移'
            : '当前歌曲歌词将${lyricsOffsetLabel(selected)}',
        type: XyNoticeType.success,
      );
    } catch (error) {
      if (!mounted) return;
      XyNotice.show(
        context,
        message: '保存歌词偏移失败：${_errorText(error)}',
        type: XyNoticeType.error,
      );
    }
  }

  Future<void> _linkLyricsFromPlugin(QueueItem item) async {
    final selected = await showModalBottomSheet<PluginLyricsOption>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _PluginLyricsSearchSheet(item: item),
    );
    if (!mounted || selected == null) return;
    if (ref.read(playerProvider).current?.path != item.path) {
      XyNotice.show(
        context,
        message: '歌曲已切换，请重新选择歌词',
        type: XyNoticeType.warning,
      );
      return;
    }
    // 在线歌词也要像本地上传歌词一样写入本地 sidecar。
    // 这样下次从本地音乐再次播放时，会自动读取上次关联的歌词，
    // 不需要用户重新搜索并选择插件结果。
    if (playbackSourceTypeFor(item) == PlaybackSourceType.localFile) {
      try {
        await saveSongLyrics(
          path: item.path,
          lyrics: selected.lyrics,
          source: LyricsStorageSource.sidecar,
        );
      } catch (error) {
        if (mounted) {
          XyNotice.show(
            context,
            message: '歌词已应用，但记忆保存失败：${_errorText(error)}',
            type: XyNoticeType.warning,
          );
        }
      }
    }
    await ref.read(playerProvider.notifier).setCurrentLyrics(selected.lyrics);
    if (mounted) {
      XyNotice.show(
        context,
        message: '已应用 ${selected.pluginName} 提供的歌词',
        type: XyNoticeType.success,
      );
    }
  }

  Future<void> _linkLyricsFromLocal(QueueItem item) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['lrc', 'yrc', 'qrc', 'lys', 'ttml', 'txt'],
      allowMultiple: false,
    );
    final path = picked?.files.single.path;
    if (!mounted || path == null || path.isEmpty) return;
    try {
      final lyrics = await readLyricsFile(path: path);
      if (lyrics.trim().isEmpty) throw Exception('歌词文件内容为空');
      if (playbackSourceTypeFor(item) == PlaybackSourceType.localFile) {
        await saveSongLyrics(
          path: item.path,
          lyrics: lyrics,
          source: LyricsStorageSource.sidecar,
        );
      }
      if (ref.read(playerProvider).current?.path != item.path) {
        throw Exception('歌曲已切换，请重新关联歌词');
      }
      await ref.read(playerProvider.notifier).setCurrentLyrics(lyrics);
      if (mounted) {
        XyNotice.show(context, message: '歌词关联成功', type: XyNoticeType.success);
      }
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '关联歌词失败：${_errorText(error)}',
          type: XyNoticeType.error,
        );
      }
    }
  }

  Future<void> _pickSleepTimer() async {
    final option = await showModalBottomSheet<_SleepTimerOption>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.timer_off_outlined),
                title: const Text('关闭定时'),
                onTap: () => Navigator.pop(context, _SleepTimerOption.off),
              ),
              for (final entry in const [
                (_SleepTimerOption.minutes15, 15),
                (_SleepTimerOption.minutes30, 30),
                (_SleepTimerOption.minutes45, 45),
                (_SleepTimerOption.minutes60, 60),
                (_SleepTimerOption.minutes90, 90),
              ])
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: Text('${entry.$2} 分钟后停止播放'),
                  onTap: () => Navigator.pop(context, entry.$1),
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.tune_rounded),
                title: const Text('自定义'),
                subtitle: const Text('30 秒至 12 小时'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.pop(context, _SleepTimerOption.custom),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || option == null) return;

    Duration? duration;
    if (option == _SleepTimerOption.custom) {
      duration = await showDialog<Duration>(
        context: context,
        useRootNavigator: true,
        builder: (context) => const _CustomSleepTimerDialog(),
      );
      if (!mounted || duration == null) return;
    } else {
      duration = switch (option) {
        _SleepTimerOption.off => null,
        _SleepTimerOption.minutes15 => const Duration(minutes: 15),
        _SleepTimerOption.minutes30 => const Duration(minutes: 30),
        _SleepTimerOption.minutes45 => const Duration(minutes: 45),
        _SleepTimerOption.minutes60 => const Duration(minutes: 60),
        _SleepTimerOption.minutes90 => const Duration(minutes: 90),
        _SleepTimerOption.custom => throw StateError('自定义定时应已单独处理'),
      };
    }
    ref.read(playerProvider.notifier).setSleepTimer(duration);
    XyNotice.show(
      context,
      message: duration == null
          ? '已关闭定时停止'
          : '将在 ${_formatSleepDuration(duration)}后停止播放',
      type: XyNoticeType.success,
    );
  }

  Future<void> _downloadCurrent(QueueItem item) async {
    if (playbackSourceTypeFor(item) == PlaybackSourceType.localFile) {
      XyNotice.show(context, message: '当前歌曲已经是本地文件');
      return;
    }
    final settings = ref.read(settingsProvider).valueOrNull;
    final initialDirectory = await resolveMusicDownloadDirectory(settings);
    if (!mounted) return;
    final playback = ref.read(playerProvider);
    final options = await showDialog<_DownloadOptions>(
      context: context,
      useRootNavigator: true,
      builder: (context) => _DownloadOptionsDialog(
        initialDirectory: initialDirectory,
        initialQuality: playback.currentQuality,
      ),
    );
    if (!mounted || options == null) return;
    if (ref.read(playerProvider).current?.path != item.path) {
      XyNotice.show(
        context,
        message: '歌曲已切换，请重新选择下载',
        type: XyNoticeType.warning,
      );
      return;
    }
    final quality = options.quality;
    final directory = options.directory.trim();
    XyNotice.show(context, message: '已开始下载 ${item.title}');
    try {
      await Directory(directory).create(recursive: true);
      final source = await ref
          .read(playerProvider.notifier)
          .resolveCurrentDownloadSource(quality);
      if (ref.read(playerProvider).current?.path != item.path) {
        throw Exception('歌曲已切换，请重新选择下载');
      }
      final destination = await resolveDownloadFullPath(
        directory: directory,
        title: item.title,
        artist: item.artist,
        album: item.album,
        url: source.url,
        quality: quality,
        keepSourceFilename: false,
        fileNameStyle: 'artist-title',
        overwriteExisting: false,
      );
      final savedPath = await downloadOnlineSong(
        url: source.url,
        destPath: destination,
        headersJson: jsonEncode(source.headers),
      );
      final lyrics = item.lyricsRaw?.trim() ?? '';
      final coverUrl = item.coverUrl?.trim() ?? '';
      await finalizeDownloadExtras(
        requestJson: jsonEncode({
          if ((settings?.downloadLyrics ?? true) && lyrics.isNotEmpty)
            'lyricsText': lyrics,
          if ((settings?.downloadLyrics ?? true) && lyrics.isNotEmpty)
            'lyricsPath': p.setExtension(savedPath, '.lrc'),
          if (coverUrl.startsWith('http://') || coverUrl.startsWith('https://'))
            'coverUrl': coverUrl,
          'embedCover': true,
          'metadata': {
            'filePath': savedPath,
            'title': item.title,
            'artist': item.artist,
            'album': item.album,
            if (lyrics.isNotEmpty) 'lyrics': lyrics,
          },
        }),
      );
      await rememberDownloadedSongSnapshot(
        DownloadedSongSnapshot(
          path: savedPath,
          title: item.title,
          artist: item.artist,
          album: item.album,
          durationMs: item.durationMs,
          downloadedAt: DateTime.now().millisecondsSinceEpoch,
          coverUrl: item.coverUrl,
          lyricsRaw: lyrics.isEmpty ? null : lyrics,
        ),
      );
      if (mounted) {
        XyNotice.show(
          context,
          message: '下载完成：${p.basename(savedPath)}',
          type: XyNoticeType.success,
        );
      }
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '下载失败：${_errorText(error)}',
          type: XyNoticeType.error,
        );
      }
    }
  }

  String _qualityLabel(String quality) => switch (quality) {
    '128k' => '标准 128k',
    '192k' => '较高 192k',
    '320k' => '高品质 320k',
    'flac' => '无损 FLAC',
    _ => quality,
  };

  String _sleepTimerLabel(DateTime? endsAt) {
    if (endsAt == null) return '未开启';
    final seconds = sleepTimerRemainingSeconds(endsAt);
    return seconds <= 0
        ? '即将停止'
        : '剩余 ${_formatSleepDuration(Duration(seconds: seconds))}';
  }

  String _errorText(Object error) =>
      error.toString().replaceFirst('Exception: ', '').trim();

  void _showDetailPage(bool showLyrics) {
    if (_showLyrics != showLyrics) {
      setState(() => _showLyrics = showLyrics);
    }
    final page = showLyrics ? 1 : 0;
    if (_detailPageController.hasClients) {
      _detailPageController.animateToPage(
        page,
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic,
      );
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _detailPageController.hasClients) {
          _detailPageController.jumpToPage(page);
        }
      });
    }
  }

  @override
  void dispose() {
    _detailPageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 播放进度每 40–80ms 更新一次；这里只监听歌曲对象，避免进度变化导致
    // 全屏背景、封面和模糊层一起高频重建。
    final current = ref.watch(playerProvider.select((state) => state.current));
    _loadLyricsOffsetFor(current);
    final notifier = ref.read(playerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 电脑版详情页同款：封面铺满、重度模糊并叠加暗色氛围层。
          _PlayerDetailBackground(current: current),
          SafeArea(
            child: Column(
              children: [
                // 顶栏
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(
                          Icons.keyboard_arrow_down,
                          size: 28,
                          color: Colors.white,
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              current?.title ?? '正在播放',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if ((current?.artist ?? '').isNotEmpty)
                              Text(
                                current!.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: .58),
                                  fontSize: 11,
                                ),
                              ),
                            const SizedBox(height: 4),
                            _DetailPageIndicator(showLyrics: _showLyrics),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '更多',
                        icon: const Icon(
                          Icons.more_horiz_rounded,
                          color: Colors.white,
                        ),
                        onPressed: current == null
                            ? null
                            : () => _showMoreMenu(current),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: current == null ? null : _startDetailSwipe,
                      onPointerMove: current == null
                          ? null
                          : _updateDetailSwipe,
                      onPointerUp: current == null
                          ? null
                          : (event) =>
                                _finishDetailSwipe(event, constraints.maxWidth),
                      onPointerCancel: current == null
                          ? null
                          : (event) =>
                                _finishDetailSwipe(event, constraints.maxWidth),
                      child: PageView(
                        controller: _detailPageController,
                        physics: const NeverScrollableScrollPhysics(),
                        onPageChanged: (page) {
                          final showLyrics = page == 1;
                          if (_showLyrics != showLyrics) {
                            setState(() => _showLyrics = showLyrics);
                          }
                        },
                        children: [
                          _BigCover(
                            key: ValueKey('cover:${current?.path ?? ''}'),
                            item: current,
                            offsetTenths: _lyricsOffsetTenths,
                            onTap: current == null ? null : _toggleLyrics,
                          ),
                          if (current == null)
                            const Center(
                              child: Text(
                                '暂无歌词',
                                style: TextStyle(color: Colors.white54),
                              ),
                            )
                          else
                            _LyricsView(
                              key: ValueKey('lyrics:${current.path}'),
                              item: current,
                              offsetTenths: _lyricsOffsetTenths,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                // 毛玻璃控制卡
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  child: _GlassControlCard(
                    notifier: notifier,
                    current: current,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 播放详情页中的歌单选择器。创建歌单后会自动将当前歌曲加入新歌单。
class _PlaylistPickerSheet extends ConsumerStatefulWidget {
  const _PlaylistPickerSheet({required this.item});

  final QueueItem item;

  @override
  ConsumerState<_PlaylistPickerSheet> createState() =>
      _PlaylistPickerSheetState();
}

class _PlaylistPickerSheetState
    extends ConsumerState<_PlaylistPickerSheet> {
  bool _busy = false;

  Future<void> _addTo(String playlistId) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(playlistsProvider.notifier)
          .addQueueItem(playlistId, widget.item);
      if (mounted) Navigator.pop(context, playlistId);
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
      final playlist = await ref
          .read(playlistsProvider.notifier)
          .create(name);
      if (playlist == null) return;
      await ref
          .read(playlistsProvider.notifier)
          .addQueueItem(playlist.id, widget.item);
      if (mounted) Navigator.pop(context, playlist.id);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);
    final colorScheme = Theme.of(context).colorScheme;
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
                widget.item.title,
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
              subtitle: const Text('创建后自动添加当前歌曲'),
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
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.queue_music_rounded,
                              color: colorScheme.onSurfaceVariant,
                            ),
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

class _DownloadOptionsDialog extends StatefulWidget {
  const _DownloadOptionsDialog({
    required this.initialDirectory,
    required this.initialQuality,
  });

  final String initialDirectory;
  final String initialQuality;

  @override
  State<_DownloadOptionsDialog> createState() => _DownloadOptionsDialogState();
}

class _DownloadOptionsDialogState extends State<_DownloadOptionsDialog> {
  static const _qualities = ['128k', '192k', '320k', 'flac'];
  late final TextEditingController _directoryController;
  late String _quality;
  bool _choosingDirectory = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _directoryController = TextEditingController(text: widget.initialDirectory);
    _quality = _normalizeQuality(widget.initialQuality);
  }

  @override
  void dispose() {
    _directoryController.dispose();
    super.dispose();
  }

  Future<void> _chooseDirectory() async {
    if (_choosingDirectory) return;
    setState(() {
      _choosingDirectory = true;
      _error = null;
    });
    try {
      final selected = await FilePicker.platform.getDirectoryPath();
      if (!mounted || selected == null) return;
      if (selected.startsWith('content://')) {
        setState(() => _error = '该目录无法直接写入，请选择可访问的文件夹或手动输入路径');
        return;
      }
      _directoryController.text = selected;
      _directoryController.selection = TextSelection.collapsed(
        offset: selected.length,
      );
      setState(() {});
    } catch (error) {
      if (mounted) setState(() => _error = '选择文件夹失败：$error');
    } finally {
      if (mounted) setState(() => _choosingDirectory = false);
    }
  }

  void _submit() {
    final directory = _directoryController.text.trim();
    if (directory.isEmpty) {
      setState(() => _error = '请输入或选择下载文件夹');
      return;
    }
    if (directory.startsWith('content://')) {
      setState(() => _error = '暂不支持将 content URI 作为下载目录');
      return;
    }
    Navigator.pop(
      context,
      _DownloadOptions(directory: directory, quality: _quality),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('下载歌曲'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('下载位置', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(
                controller: _directoryController,
                minLines: 1,
                maxLines: 2,
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                decoration: const InputDecoration(
                  hintText: '/storage/emulated/0/Music',
                  prefixIcon: Icon(Icons.folder_outlined),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _choosingDirectory ? null : _chooseDirectory,
                  icon: _choosingDirectory
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.create_new_folder_outlined),
                  label: Text(_choosingDirectory ? '正在选择…' : '直接选择文件夹'),
                ),
              ),
              const SizedBox(height: 20),
              Text('下载音质', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final quality in _qualities)
                    ChoiceChip(
                      label: Text(_qualityLabel(quality)),
                      selected: _quality == quality,
                      onSelected: (_) => setState(() => _quality = quality),
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(fontSize: 12, color: scheme.error),
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

  static String _normalizeQuality(String quality) => switch (quality.trim()) {
    '128k' || 'standard' => '128k',
    '192k' => '192k',
    'flac' || 'lossless' => 'flac',
    _ => '320k',
  };

  static String _qualityLabel(String quality) => switch (quality) {
    '128k' => '标准 128k',
    '192k' => '较高 192k',
    '320k' => '高品质 320k',
    'flac' => '无损 FLAC',
    _ => quality,
  };
}

class _LyricsOffsetDialog extends StatefulWidget {
  const _LyricsOffsetDialog({required this.initialOffsetTenths});

  final int initialOffsetTenths;

  @override
  State<_LyricsOffsetDialog> createState() => _LyricsOffsetDialogState();
}

class _LyricsOffsetDialogState extends State<_LyricsOffsetDialog> {
  late int _offsetTenths;

  @override
  void initState() {
    super.initState();
    _offsetTenths = clampLyricsOffsetTenths(widget.initialOffsetTenths);
  }

  void _change(int delta) {
    setState(() {
      _offsetTenths = clampLyricsOffsetTenths(_offsetTenths + delta);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('当前歌曲歌词偏移'),
      content: SizedBox(
        width: 330,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                lyricsOffsetLabel(_offsetTenths),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Slider(
              value: _offsetTenths.toDouble(),
              min: -100,
              max: 100,
              divisions: 200,
              label: lyricsOffsetLabel(_offsetTenths),
              onChanged: (value) {
                setState(() => _offsetTenths = value.round());
              },
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('延后 10 秒', style: TextStyle(fontSize: 11)),
                  Text('同步', style: TextStyle(fontSize: 11)),
                  Text('提前 10 秒', style: TextStyle(fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.filledTonal(
                  tooltip: '歌词延后 0.1 秒',
                  onPressed: _offsetTenths <= -100 ? null : () => _change(-1),
                  icon: const Icon(Icons.remove_rounded),
                ),
                const SizedBox(width: 10),
                TextButton(
                  onPressed: _offsetTenths == 0
                      ? null
                      : () => setState(() => _offsetTenths = 0),
                  child: const Text('恢复同步'),
                ),
                const SizedBox(width: 10),
                IconButton.filledTonal(
                  tooltip: '歌词提前 0.1 秒',
                  onPressed: _offsetTenths >= 100 ? null : () => _change(1),
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '每次调整 0.1 秒，仅对当前歌曲生效并记忆。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _offsetTenths),
          child: const Text('应用'),
        ),
      ],
    );
  }
}

class _CustomSleepTimerDialog extends StatefulWidget {
  const _CustomSleepTimerDialog();

  @override
  State<_CustomSleepTimerDialog> createState() =>
      _CustomSleepTimerDialogState();
}

class _CustomSleepTimerDialogState extends State<_CustomSleepTimerDialog> {
  late final TextEditingController _hoursController = TextEditingController(
    text: '0',
  );
  late final TextEditingController _minutesController = TextEditingController(
    text: '0',
  );
  late final TextEditingController _secondsController = TextEditingController(
    text: '30',
  );
  String? _error;

  @override
  void dispose() {
    _hoursController.dispose();
    _minutesController.dispose();
    _secondsController.dispose();
    super.dispose();
  }

  void _submit() {
    final hours = int.tryParse(_hoursController.text) ?? 0;
    final minutes = int.tryParse(_minutesController.text) ?? 0;
    final seconds = int.tryParse(_secondsController.text) ?? 0;
    if (minutes > 59 || seconds > 59) {
      setState(() => _error = '分钟和秒数需填写 0–59');
      return;
    }
    final duration = Duration(hours: hours, minutes: minutes, seconds: seconds);
    if (!isValidSleepTimerDuration(duration)) {
      setState(() => _error = '定时时长必须在 30 秒至 12 小时之间');
      return;
    }
    Navigator.pop(context, duration);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('自定义定时关闭'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('设置停止播放前的等待时间'),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _durationField(
                      controller: _hoursController,
                      label: '小时',
                      nextAction: TextInputAction.next,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _durationField(
                      controller: _minutesController,
                      label: '分钟',
                      nextAction: TextInputAction.next,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _durationField(
                      controller: _secondsController,
                      label: '秒',
                      nextAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: Text(
                  _error ?? '最短 30 秒，最长 12 小时',
                  key: ValueKey(_error),
                  style: TextStyle(
                    fontSize: 12,
                    color: _error == null
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }

  Widget _durationField({
    required TextEditingController controller,
    required String label,
    required TextInputAction nextAction,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      textInputAction: nextAction,
      textAlign: TextAlign.center,
      selectAllOnFocus: true,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(2),
      ],
      decoration: InputDecoration(labelText: label, counterText: ''),
      onChanged: (_) {
        if (_error != null) setState(() => _error = null);
      },
      onSubmitted: onSubmitted,
    );
  }
}

class _PluginLyricsSearchSheet extends ConsumerStatefulWidget {
  const _PluginLyricsSearchSheet({required this.item});

  final QueueItem item;

  @override
  ConsumerState<_PluginLyricsSearchSheet> createState() =>
      _PluginLyricsSearchSheetState();
}

class _PluginLyricsSearchSheetState
    extends ConsumerState<_PluginLyricsSearchSheet> {
  late final TextEditingController _controller;
  List<PluginLyricsOption> _options = const [];
  bool _searching = false;
  bool _searched = false;
  int _completedPlugins = 0;
  int _totalPlugins = 0;
  String? _applyingId;
  String? _error;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    final query = createDefaultPluginLyricsSearchQuery(
      widget.item.title,
      widget.item.artist,
    );
    _controller = TextEditingController(text: query)
      ..selection = TextSelection.collapsed(offset: query.length);
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _requestId++;
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty || _searching) return;
    final requestId = ++_requestId;
    setState(() {
      _searching = true;
      _searched = true;
      _options = const [];
      _completedPlugins = 0;
      _totalPlugins = 0;
      _error = null;
    });
    try {
      await for (final progress
          in ref
              .read(playerProvider.notifier)
              .findCurrentLyricsFromPluginsProgress(query: query)) {
        if (!mounted || requestId != _requestId) break;
        final merged = <String, PluginLyricsOption>{
          for (final option in _options) option.id: option,
          for (final option in progress.options) option.id: option,
        };
        final options = merged.values.toList()
          ..sort((a, b) {
            final pluginOrder = a.pluginName.compareTo(b.pluginName);
            return pluginOrder != 0 ? pluginOrder : a.id.compareTo(b.id);
          });
        setState(() {
          _options = options;
          _completedPlugins = progress.completedPlugins;
          _totalPlugins = progress.totalPlugins;
        });
      }
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() => _error = _errorMessage(error));
    } finally {
      if (mounted && requestId == _requestId) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _apply(PluginLyricsOption option) async {
    if (_applyingId != null) return;
    setState(() {
      _applyingId = option.id;
      _error = null;
    });
    try {
      final loaded = await ref
          .read(playerProvider.notifier)
          .loadLyricsForOption(option);
      if (!mounted) return;
      if (ref.read(playerProvider).current?.path != widget.item.path) {
        throw Exception('歌曲已切换，请重新选择歌词');
      }
      Navigator.pop(context, loaded);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _applyingId = null;
        _error = _errorMessage(error);
      });
    }
  }

  String _errorMessage(Object error) =>
      error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final availableHeight =
        MediaQuery.sizeOf(context).height - viewInsets.bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: math.min(availableHeight * .82, 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '选择插件歌词',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${widget.item.title} · ${widget.item.artist}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        enabled: !_searching && _applyingId == null,
                        textInputAction: TextInputAction.search,
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _search(),
                        decoration: const InputDecoration(
                          hintText: '输入歌名、歌手或其他搜索内容',
                          prefixIcon: Icon(Icons.search_rounded),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed:
                          _searching ||
                              _applyingId != null ||
                              _controller.text.trim().isEmpty
                          ? null
                          : _search,
                      child: _searching
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('搜索'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '各插件结果会逐个显示，点击候选歌曲后再获取歌词。',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (_searching && _totalPlugins > 0)
                      Text(
                        '$_completedPlugins/$_totalPlugins 个插件',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      )
                    else if (_options.isNotEmpty)
                      Text(
                        '共 ${_options.length} 个候选',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (_error != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.errorContainer.withValues(alpha: .55),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              Expanded(child: _buildResults(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    if (_options.isNotEmpty) {
      return Column(
        children: [
          if (_searching)
            LinearProgressIndicator(
              minHeight: 2,
              value: _totalPlugins > 0
                  ? _completedPlugins / _totalPlugins
                  : null,
            ),
          Expanded(
            child: _PluginLyricsTabs(
              key: ValueKey(
                _options.map((option) => option.pluginId).toSet().join('|'),
              ),
              options: _options,
              applyingId: _applyingId,
              onSelected: _apply,
            ),
          ),
        ],
      );
    }
    if (_searching) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text(
              _totalPlugins > 0
                  ? '正在搜索插件（$_completedPlugins/$_totalPlugins）…'
                  : '正在启动插件搜索…',
            ),
          ],
        ),
      );
    }
    if (_searched && _error == null) {
      return const Center(child: Text('已启用插件均未返回搜索结果'));
    }
    return const Center(child: Text('输入搜索内容后查看插件结果'));
  }
}

class _PluginLyricsTabs extends StatelessWidget {
  const _PluginLyricsTabs({
    super.key,
    required this.options,
    required this.applyingId,
    required this.onSelected,
  });

  final List<PluginLyricsOption> options;
  final String? applyingId;
  final ValueChanged<PluginLyricsOption> onSelected;

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<PluginLyricsOption>>{};
    final pluginNames = <String, String>{};
    for (final option in options) {
      grouped.putIfAbsent(option.pluginId, () => []).add(option);
      pluginNames[option.pluginId] = option.pluginName;
    }
    final pluginIds = grouped.keys.toList();
    return DefaultTabController(
      length: pluginIds.length,
      child: Column(
        children: [
          Material(
            color: Colors.transparent,
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                for (final id in pluginIds)
                  Tab(text: '${pluginNames[id]} (${grouped[id]!.length})'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                for (final id in pluginIds)
                  _pluginLyricsList(context, grouped[id]!),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pluginLyricsList(
    BuildContext context,
    List<PluginLyricsOption> items,
  ) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, index) {
        final option = items[index];
        final artist = option.songArtist.trim().isEmpty
            ? '未知歌手'
            : option.songArtist;
        final album = option.songAlbum.trim();
        return ListTile(
          minTileHeight: 76,
          leading: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: Text(
              '${index + 1}',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          title: Text(
            option.songTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            album.isEmpty ? artist : '$artist · $album',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: option.id == applyingId
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatLyricsDuration(option.durationMs),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '应用',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
          enabled: applyingId == null,
          onTap: () => onSelected(option),
        );
      },
    );
  }

  static String _formatLyricsDuration(int durationMs) {
    if (durationMs <= 0) return '--:--';
    final seconds = durationMs ~/ 1000;
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return '$minutes:${remainder.toString().padLeft(2, '0')}';
  }
}

class _DetailPageIndicator extends StatelessWidget {
  const _DetailPageIndicator({required this.showLyrics});

  final bool showLyrics;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: showLyrics ? '歌词页，可向右滑动显示封面' : '封面页，可向左滑动显示歌词',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _indicatorPart(active: !showLyrics),
          const SizedBox(width: 4),
          _indicatorPart(active: showLyrics),
        ],
      ),
    );
  }

  Widget _indicatorPart({required bool active}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      width: active ? 16 : 4,
      height: 4,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: active ? .9 : .34),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}

class _PlayerDetailBackground extends StatelessWidget {
  const _PlayerDetailBackground({required this.current});

  final QueueItem? current;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFF0B0D12)),
          if (current != null)
            Positioned.fill(
              // 低分辨率封面放大后作为氛围背景，不使用动态模糊滤镜。
              // 部分旧 Android GPU 在切换滤镜下的纹理时会发生原生崩溃。
              child: Transform.scale(
                scale: 1.24,
                child: Opacity(
                  opacity: .46,
                  child: CoverImage(
                    key: ValueKey('background:${current!.path}'),
                    songPath: current!.path,
                    imageUrl: current!.coverUrl,
                    width: size.width,
                    height: size.height,
                    radius: 0,
                    cacheWidth: 256,
                    icon: Icons.music_note_rounded,
                  ),
                ),
              ),
            ),
          ColoredBox(color: const Color(0xFF080A0F).withValues(alpha: .58)),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x29000000),
                  Color(0x12000000),
                  Color(0xA6000000),
                ],
                stops: [0, .48, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BigCover extends StatelessWidget {
  const _BigCover({
    super.key,
    this.item,
    required this.offsetTenths,
    this.onTap,
  });
  final QueueItem? item;
  final int offsetTenths;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final normalSide = math.min(
          390.0,
          math.min(constraints.maxWidth * .72, constraints.maxHeight - 104),
        );
        final showCoverExtras = normalSide >= 150;
        final side = showCoverExtras
            ? normalSide
            : math.max(
                1.0,
                math.min(
                  390.0,
                  math.min(constraints.maxWidth * .72, constraints.maxHeight),
                ),
              );
        return Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: SizedBox(
                width: side,
                height: side + (showCoverExtras ? 104 : 0),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (showCoverExtras)
                      Positioned(
                        top: side - 2,
                        left: 7,
                        right: 7,
                        height: 58,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(22),
                              gradient: const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Color(0x24FFFFFF), Colors.transparent],
                              ),
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      top: 0,
                      left: 0,
                      child: Semantics(
                        button: onTap != null,
                        label: onTap == null ? null : '显示歌词',
                        child: Container(
                          width: side,
                          height: side,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x99000000),
                                blurRadius: 44,
                                spreadRadius: -8,
                                offset: Offset(0, 24),
                              ),
                            ],
                          ),
                          child: Material(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(24),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: onTap,
                              child: _cover(side, radius: 24),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (item != null && showCoverExtras)
                      Positioned(
                        top: side + 43,
                        left: -28,
                        right: -28,
                        height: 56,
                        child: AbsorbPointer(
                          child: _MiniLyrics(
                            item: item!,
                            offsetTenths: offsetTenths,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _cover(double size, {required double radius, int? cacheWidth}) {
    final current = item;
    if (current == null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: const ColoredBox(
          color: Color(0xFF272A31),
          child: Center(
            child: Icon(Icons.music_note_rounded, color: Colors.white54),
          ),
        ),
      );
    }
    return CoverImage(
      key: ValueKey('main:${current.path}:${current.coverUrl ?? ''}'),
      songPath: current.path,
      imageUrl: current.coverUrl,
      width: size,
      height: size,
      radius: radius,
      cacheWidth: cacheWidth,
      icon: Icons.music_note_rounded,
    );
  }
}

class _MiniLyrics extends ConsumerWidget {
  const _MiniLyrics({required this.item, required this.offsetTenths});

  final QueueItem item;
  final int offsetTenths;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = applyLyricsOffset(
      ref.watch(playerProvider.select((state) => state.position)),
      offsetTenths,
    );
    final embedded = item.lyricsRaw?.trim() ?? '';
    if (embedded.isNotEmpty) {
      return _buildAsync(
        ref.watch(_embeddedLyricsProvider(embedded)),
        position,
      );
    }
    if (item.pluginId != null && !item.lyricsAttempted) {
      return _message('正在获取歌词…');
    }
    if (item.pluginId != null) {
      return _message('暂无歌词');
    }
    return _buildAsync(ref.watch(_lyricsProvider(item.path)), position);
  }

  Widget _buildAsync(AsyncValue<List<_LyricLine>> lyrics, double position) {
    return lyrics.when(
      loading: () => _message('正在获取歌词…'),
      error: (_, _) => _message('暂无歌词'),
      data: (lines) {
        if (lines.isEmpty) return _message('暂无歌词');
        var active = lines.lastIndexWhere((line) => line.time <= position);
        if (active < 0) active = 0;
        final current = lines[active];
        final translation = current.translation.trim();
        final secondary = translation.isNotEmpty
            ? translation
            : active + 1 < lines.length
            ? lines[active + 1].text
            : '';
        return _surface(
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, .22),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            child: Column(
              key: ValueKey('${item.path}:${current.time}'),
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  current.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 10)],
                  ),
                ),
                if (secondary.trim().isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    secondary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: .5),
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _message(String text) {
    return _surface(
      Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white.withValues(alpha: .5),
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _surface(Widget child) {
    return Center(child: child);
  }
}

class _LyricsView extends ConsumerStatefulWidget {
  const _LyricsView({
    super.key,
    required this.item,
    required this.offsetTenths,
  });
  final QueueItem item;
  final int offsetTenths;

  @override
  ConsumerState<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<_LyricsView>
    with AutomaticKeepAliveClientMixin<_LyricsView> {
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _lineKeys = {};
  bool _scrollScheduled = false;
  int _coarseScrollTarget = -1;
  int _lastScrollTarget = -1;
  int _pendingScrollTarget = -1;
  bool _userScrolling = false;
  Timer? _resumeAutoScrollTimer;
  List<_LyricLine> _latestLines = const [];
  String? _noLyricsNoticePath;

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(_LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.path != widget.item.path) {
      _noLyricsNoticePath = null;
      _coarseScrollTarget = -1;
      _lastScrollTarget = -1;
      _pendingScrollTarget = -1;
      _userScrolling = false;
      _resumeAutoScrollTimer?.cancel();
      _lineKeys.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      });
    }
  }

  @override
  void dispose() {
    _resumeAutoScrollTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final position = applyLyricsOffset(
      ref.watch(playerProvider.select((state) => state.position)),
      widget.offsetTenths,
    );
    final effectMode =
        ref.watch(settingsProvider).valueOrNull?.lyricWordEffectMode ??
        LyricWordEffectMode.progressive;
    final embedded = widget.item.lyricsRaw?.trim() ?? '';
    late final Widget content;
    if (embedded.isNotEmpty) {
      final lyrics = ref.watch(_embeddedLyricsProvider(embedded));
      content = lyrics.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => _lyricsEmpty(context, '歌词解析失败', notifyNoLyrics: true),
        data: (lines) => _buildLines(lines, position, effectMode),
      );
    } else if (widget.item.pluginId != null && !widget.item.lyricsAttempted) {
      content = _lyricsEmpty(context, '正在获取歌词…');
    } else if (widget.item.pluginId != null) {
      content = _lyricsEmpty(context, '暂无歌词', notifyNoLyrics: true);
    } else {
      final lyrics = ref.watch(_lyricsProvider(widget.item.path));
      content = lyrics.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => _lyricsEmpty(context, '暂无歌词', notifyNoLyrics: true),
        data: (lines) => _buildLines(lines, position, effectMode),
      );
    }
    return content;
  }

  Widget _buildLines(
    List<_LyricLine> lines,
    double position,
    LyricWordEffectMode effectMode,
  ) {
    if (lines.isEmpty) {
      return _lyricsEmpty(context, '暂无歌词', notifyNoLyrics: true);
    }
    _latestLines = lines;
    var active = lines.lastIndexWhere((line) => line.time <= position);
    if (active < 0) active = 0;
    _syncScroll(active, lines);
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            Positioned.fill(
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.white,
                    Colors.white,
                    Colors.transparent,
                  ],
                  stops: [0, .28, .72, 1],
                ).createShader(rect),
                child: NotificationListener<ScrollNotification>(
                  onNotification: _handleScrollNotification,
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(26, 124, 26, 124),
                    itemCount: lines.length,
                    itemBuilder: (context, index) {
                      final line = lines[index];
                      final selected = index == active;
                      return InkWell(
                        key: _lineKeys.putIfAbsent(index, GlobalKey.new),
                        onTap: () => ref
                            .read(playerProvider.notifier)
                            .seek(
                              playbackPositionForLyric(
                                line.time,
                                widget.offsetTenths,
                              ),
                            ),
                        borderRadius: BorderRadius.circular(12),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          padding: EdgeInsets.fromLTRB(
                            selected ? 14 : 8,
                            10,
                            8,
                            10,
                          ),
                          decoration: BoxDecoration(
                            border: selected
                                ? const Border(
                                    left: BorderSide(
                                      color: Color(0xFFEC4141),
                                      width: 3,
                                    ),
                                  )
                                : null,
                          ),
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            opacity: selected ? 1 : .34,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _TimedLyricText(
                                  line: line,
                                  position: position,
                                  selected: selected,
                                  effectMode: effectMode,
                                ),
                                if (line.translation.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    line.translation,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.white.withValues(
                                        alpha: .68,
                                      ),
                                    ),
                                  ),
                                ],
                                if (line.romaji.isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    line.romaji,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.white.withValues(
                                        alpha: .48,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _syncScroll(int active, List<_LyricLine> lines) {
    _pendingScrollTarget = active;
    if (_userScrolling || _lastScrollTarget == active) return;
    if (_scrollScheduled) return;
    _lastScrollTarget = active;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted || !_scrollController.hasClients) return;

      final currentOffset = _revealOffset(active);
      if (currentOffset == null) {
        _coarseScrollTo(active, lines);
        return;
      }

      _coarseScrollTarget = -1;
      _animateToOffset(currentOffset);
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _resumeAutoScrollTimer?.cancel();
      _userScrolling = true;
    } else if (notification is ScrollEndNotification && _userScrolling) {
      _resumeAutoScrollTimer?.cancel();
      _resumeAutoScrollTimer = Timer(const Duration(seconds: 3), () {
        if (!mounted) return;
        _userScrolling = false;
        _lastScrollTarget = -1;
        final active = _pendingScrollTarget;
        if (active >= 0 && active < _latestLines.length) {
          _syncScroll(active, _latestLines);
        }
      });
    }
    return false;
  }

  void _animateToOffset(double rawTarget) {
    if (!mounted || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final target = rawTarget.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final distance = (target - position.pixels).abs();
    if (distance < .75) return;
    final milliseconds = (300 + distance * 1.7).round().clamp(340, 620);
    unawaited(
      _scrollController.animateTo(
        target,
        duration: Duration(milliseconds: milliseconds),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  double? _revealOffset(int index) {
    final renderObject = _lineKeys[index]?.currentContext?.findRenderObject();
    if (renderObject == null || !renderObject.attached) return null;
    final viewport = RenderAbstractViewport.of(renderObject);
    return viewport.getOffsetToReveal(renderObject, .42).offset;
  }

  void _coarseScrollTo(int active, List<_LyricLine> lines) {
    if (_coarseScrollTarget == active) return;
    _coarseScrollTarget = active;

    // 大幅拖动进度时目标行可能还没有构建，先按整首歌词比例平滑接近。
    final ratio = lines.length <= 1 ? 0.0 : active / (lines.length - 1);
    final position = _scrollController.position;
    final target = (position.maxScrollExtent * ratio).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    unawaited(
      _scrollController
          .animateTo(
            target,
            duration: const Duration(milliseconds: 360),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (!mounted || _coarseScrollTarget != active) return;
            _coarseScrollTarget = -1;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _userScrolling) return;
              final exactOffset = _revealOffset(active);
              if (exactOffset != null) _animateToOffset(exactOffset);
            });
          }),
    );
  }

  Widget _lyricsEmpty(
    BuildContext context,
    String message, {
    bool notifyNoLyrics = false,
  }) {
    if (notifyNoLyrics) _scheduleNoLyricsNotice();
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.lyrics_outlined,
            size: 52,
            color: Colors.white.withValues(alpha: .3),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: TextStyle(color: Colors.white.withValues(alpha: .5)),
          ),
        ],
      ),
    );
  }

  void _scheduleNoLyricsNotice() {
    final path = widget.item.path;
    if (path.isEmpty || _noLyricsNoticePath == path) return;
    _noLyricsNoticePath = path;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = ref.read(playerProvider).current;
      if (current?.path != path ||
          current?.lyricsRaw?.trim().isNotEmpty == true) {
        return;
      }
      XyNotice.show(
        context,
        message: '未检测到歌词，可点击右上角关联歌词',
        type: XyNoticeType.warning,
      );
    });
  }
}

class _TimedLyricText extends StatelessWidget {
  const _TimedLyricText({
    required this.line,
    required this.position,
    required this.selected,
    required this.effectMode,
  });

  final _LyricLine line;
  final double position;
  final bool selected;
  final LyricWordEffectMode effectMode;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: selected ? 24 : 18),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, fontSize, _) => _buildText(fontSize),
    );
  }

  Widget _buildText(double fontSize) {
    final baseStyle = TextStyle(
      color: Colors.white,
      fontSize: fontSize,
      height: 1.3,
      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
      shadows: selected
          ? const [Shadow(color: Colors.black54, blurRadius: 12)]
          : null,
    );
    if (!selected ||
        line.words.isEmpty ||
        effectMode == LyricWordEffectMode.none) {
      return Text(line.text, style: baseStyle);
    }

    if (effectMode == LyricWordEffectMode.progressive) {
      return _buildProgressiveText(baseStyle);
    }

    return _buildWordByWordText(baseStyle);
  }

  Widget _buildWordByWordText(TextStyle baseStyle) {
    final dimColor = Colors.white.withValues(alpha: .28);
    return Text.rich(
      TextSpan(
        children: [
          for (final word in line.words)
            TextSpan(
              text: word.text,
              style: baseStyle.copyWith(
                color: Color.lerp(dimColor, Colors.white, _wordProgress(word)),
                shadows: position >= word.start && position < word.end
                    ? const [
                        Shadow(color: Colors.white54, blurRadius: 10),
                        Shadow(color: Colors.black54, blurRadius: 12),
                      ]
                    : baseStyle.shadows,
              ),
            ),
        ],
      ),
      style: baseStyle,
    );
  }

  Widget _buildProgressiveText(TextStyle baseStyle) {
    return Text.rich(
      TextSpan(
        children: [
          for (final word in line.words)
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _ProgressiveLyricWord(
                text: word.text,
                style: baseStyle,
                progress: _wordProgress(word),
              ),
            ),
        ],
      ),
      style: baseStyle,
    );
  }

  double _wordProgress(_LyricWord word) {
    if (position <= word.start) return 0;
    if (position >= word.end || word.end <= word.start) return 1;
    return ((position - word.start) / (word.end - word.start)).clamp(0, 1);
  }
}

class _ProgressiveLyricWord extends StatelessWidget {
  const _ProgressiveLyricWord({
    required this.text,
    required this.style,
    required this.progress,
  });

  final String text;
  final TextStyle style;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final value = progress.clamp(0.0, 1.0);
    // ShaderMask 在进度为 0 时仍会绘制渐变的首个白色采样点，
    // 每个 WidgetSpan 的左边因此出现一条白边。边界状态直接绘制纯色，
    // 只有真正播放到当前词时才使用渐变过渡。
    final dim = Colors.white.withValues(alpha: .28);
    if (value <= 0) {
      return Text(text, style: style.copyWith(color: dim));
    }
    if (value >= 1) {
      return Text(text, style: style.copyWith(color: Colors.white));
    }
    final edgeStart = (value - .08).clamp(0.0, 1.0);
    final edgeEnd = (value + .08).clamp(0.0, 1.0);
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => LinearGradient(
        colors: [Colors.white, Colors.white, dim, dim],
        stops: [0, edgeStart, edgeEnd, 1],
      ).createShader(bounds),
      child: Text(text, style: style.copyWith(color: Colors.white)),
    );
  }
}

/// 毛玻璃控制卡：标题 + 进度 + 播放控制。
class _GlassControlCard extends ConsumerWidget {
  const _GlassControlCard({required this.notifier, required this.current});
  final PlayerNotifier notifier;
  final QueueItem? current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final glassColor = Colors.black.withValues(alpha: .24);
    final errorMessage = ref.watch(
      playerProvider.select((state) => state.errorMessage),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      // 背景已经静态模糊，这里用半透明表面即可，避免第二层实时整块采样。
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        decoration: BoxDecoration(
          color: glassColor,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: Colors.white.withValues(alpha: .12)),
        ),
        child: current == null
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('暂无播放')),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _TitleRow(current: current!),
                  if (errorMessage != null) ...[
                    const SizedBox(height: 10),
                    _PlaybackError(
                      message: errorMessage,
                      onRetry: notifier.toggle,
                    ),
                  ],
                  const SizedBox(height: 14),
                  _ProgressBar(notifier: notifier),
                  const SizedBox(height: 6),
                  _Controls(notifier: notifier),
                ],
              ),
      ),
    );
  }
}

class _PlaybackError extends StatelessWidget {
  const _PlaybackError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFEC4141).withValues(alpha: .16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFFEC4141).withValues(alpha: .32),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFFF8A8A), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            child: const Text('重试', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class _TitleRow extends ConsumerWidget {
  const _TitleRow({required this.current});
  final QueueItem current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isFav = ref.watch(favoritesProvider).contains(current.path);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                current.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                current.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: .56),
                ),
              ),
            ],
          ),
        ),
        IconButton(
          icon: Icon(
            isFav ? Icons.favorite : Icons.favorite_border,
            color: isFav ? scheme.primary : Colors.white70,
          ),
          onPressed: () => ref
              .read(favoritesProvider.notifier)
              .toggle(
                current.path,
                song: FavoriteSongSnapshot.fromQueueItem(current),
              ),
        ),
      ],
    );
  }
}

class _ProgressBar extends ConsumerWidget {
  const _ProgressBar({required this.notifier});
  final PlayerNotifier notifier;

  String _fmt(double s) {
    if (!s.isFinite || s < 0) s = 0;
    final m = s ~/ 60;
    final sec = (s % 60).floor();
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final progress = ref.watch(
      playerProvider.select(
        (state) => (position: state.position, duration: state.duration),
      ),
    );
    final dur = progress.duration.isFinite && progress.duration > 0
        ? progress.duration
        : 1.0;
    final position = progress.position.isFinite
        ? progress.position.clamp(0.0, dur)
        : 0.0;
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            activeTrackColor: scheme.primary,
            inactiveTrackColor: Colors.white.withValues(alpha: .16),
            thumbColor: scheme.primary,
            overlayColor: scheme.primary.withValues(alpha: 0.16),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: position,
            max: dur,
            onChanged: (v) => notifier.seek(v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _fmt(position),
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: .52),
                ),
              ),
              Text(
                _fmt(dur),
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: .52),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Controls extends ConsumerWidget {
  const _Controls({required this.notifier});
  final PlayerNotifier notifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final player = ref.watch(
      playerProvider.select(
        (state) => (
          isPlaying: state.isPlaying,
          isLoading: state.isLoading,
          playMode: normalizePlayMode(state.playMode),
          hasQueue: state.queue.isNotEmpty,
        ),
      ),
    );
    final icons = [Icons.repeat, Icons.repeat_one, Icons.shuffle];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          iconSize: 21,
          icon: Icon(icons[player.playMode], color: Colors.white70),
          onPressed: notifier.cyclePlayMode,
        ),
        IconButton(
          iconSize: 32,
          icon: const Icon(Icons.skip_previous, color: Colors.white),
          onPressed: notifier.previous,
        ),
        // 主题色实心播放键
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.primary,
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.4),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: IconButton(
            icon: player.isLoading
                ? const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.6,
                      color: Colors.white,
                    ),
                  )
                : Icon(
                    player.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                  ),
            iconSize: 34,
            onPressed: player.isLoading ? null : notifier.toggle,
          ),
        ),
        IconButton(
          iconSize: 32,
          icon: const Icon(Icons.skip_next, color: Colors.white),
          onPressed: notifier.next,
        ),
        IconButton(
          iconSize: 21,
          icon: const Icon(Icons.queue_music, color: Colors.white70),
          onPressed: !player.hasQueue ? null : () => _showQueue(context, ref),
        ),
      ],
    );
  }

  Future<void> _showQueue(BuildContext context, WidgetRef ref) {
    final player = ref.read(playerProvider);
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .66,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Row(
                  children: [
                    const Text(
                      '播放队列',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${player.queue.length} 首',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: player.queue.length,
                  itemBuilder: (context, index) {
                    final item = player.queue[index];
                    final current = index == player.queueIndex;
                    return ListTile(
                      minTileHeight: 58,
                      leading: current
                          ? const SizedBox(
                              width: 24,
                              child: Icon(
                                Icons.graphic_eq,
                                color: Color(0xFFEC4141),
                              ),
                            )
                          : SizedBox(
                              width: 24,
                              child: Text(
                                '${index + 1}',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                      title: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: current ? const Color(0xFFEC4141) : null,
                          fontWeight: current
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        item.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () async {
                        Navigator.pop(context);
                        await ref
                            .read(playerProvider.notifier)
                            .playIndex(index);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
