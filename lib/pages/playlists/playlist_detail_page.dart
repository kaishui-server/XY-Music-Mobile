import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../src/core/settings.dart';
import '../../src/library/library_provider.dart';
import '../../src/player/downloaded_song_store.dart';
import '../../src/player/player_provider.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/top_notice.dart';

class PlaylistDetailPage extends ConsumerStatefulWidget {
  const PlaylistDetailPage({super.key, required this.playlistId});
  final String playlistId;

  @override
  ConsumerState<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends ConsumerState<PlaylistDetailPage> {
  final Set<String> _selectedPaths = <String>{};
  List<Song> _songs = const <Song>[];
  bool _selectionMode = false;
  bool _downloading = false;

  void _toggleSelection(Song song) {
    setState(() {
      if (!_selectedPaths.add(song.path)) _selectedPaths.remove(song.path);
    });
  }

  void _toggleAll() {
    setState(() {
      if (_selectedPaths.length == _songs.length) {
        _selectedPaths.clear();
      } else {
        _selectedPaths
          ..clear()
          ..addAll(_songs.map((song) => song.path));
      }
    });
  }

  void _closeSelection() {
    setState(() {
      _selectionMode = false;
      _selectedPaths.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);
    MobilePlaylist? playlist;
    for (final item in playlists) {
      if (item.id == widget.playlistId) {
        playlist = item;
        break;
      }
    }
    if (playlist == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('歌单')),
        body: Center(
          child: FilledButton(
            onPressed: () => context.go('/home/playlists'),
            child: const Text('返回歌单'),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selectionMode && _selectedPaths.isNotEmpty
              ? '已选 ${_selectedPaths.length} 首'
              : playlist.name,
        ),
        actions: [
          if (_selectionMode)
            IconButton(
              tooltip: '批量下载',
              onPressed: _selectedPaths.isEmpty || _downloading
                  ? null
                  : _downloadSelected,
              icon: _downloading
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded),
            ),
          IconButton(
            tooltip: _selectionMode ? '取消多选' : '多选',
            onPressed: _selectionMode
                ? _closeSelection
                : () => setState(() => _selectionMode = true),
            icon: Icon(
              _selectionMode
                  ? Icons.close_rounded
                  : Icons.library_add_check_rounded,
            ),
          ),
        ],
      ),
      body: FutureBuilder<List<Song>>(
        key: ValueKey(Object.hashAll(playlist.songPaths)),
        future: _loadSongs(ref, playlist),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final songs = snapshot.data ?? const <Song>[];
          _songs = songs;
          if (songs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 110),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.music_off_rounded, size: 52),
                    const SizedBox(height: 12),
                    const Text('歌单中暂无可用歌曲'),
                    const SizedBox(height: 6),
                    Text(
                      '导入文件中的歌曲可能尚未加入本地音乐库',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    Text('${songs.length} 首歌曲'),
                    if (_selectionMode) ...[
                      const SizedBox(width: 10),
                      TextButton(
                        onPressed: _toggleAll,
                        child: Text(
                          _selectedPaths.length == songs.length ? '取消全选' : '全选',
                        ),
                      ),
                    ],
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: () => ref.read(libraryProvider.notifier).playAll(songs),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('播放全部'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SongsListView(
                  songs: songs,
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 90),
                  selectionMode: _selectionMode,
                  isSelected: (song) => _selectedPaths.contains(song.path),
                  onToggleSelection: _toggleSelection,
                  onPlay: (list, index) => ref.read(libraryProvider.notifier).playList(list, index),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _downloadSelected() async {
    if (_downloading || _selectedPaths.isEmpty) return;
    final selected = _songs.where((song) => _selectedPaths.contains(song.path)).toList();
    final settings = ref.read(settingsProvider).valueOrNull;
    final initialDirectory = await resolveMusicDownloadDirectory(settings);
    if (!mounted) return;
    final options = await showDialog<_PlaylistDownloadOptions>(
      context: context,
      useRootNavigator: true,
      builder: (context) => _PlaylistDownloadOptionsDialog(
        initialDirectory: initialDirectory,
        initialQuality: settings?.downloadQuality ?? '320k',
      ),
    );
    if (!mounted || options == null) return;
    setState(() => _downloading = true);
    var success = 0;
    var skipped = 0;
    var failed = 0;
    try {
      await Directory(options.directory).create(recursive: true);
      final notifier = ref.read(playerProvider.notifier);
      for (final song in selected) {
        if (playbackSourceTypeFor(song.toQueueItem()) == PlaybackSourceType.localFile) {
          skipped++;
          continue;
        }
        try {
          final source = await notifier.resolveDownloadSourceFor(song.toQueueItem(), options.quality);
          final destination = await resolveDownloadFullPath(
            directory: options.directory,
            title: song.title,
            artist: song.artist,
            album: song.album,
            url: source.url,
            quality: options.quality,
            keepSourceFilename: false,
            fileNameStyle: 'artist-title',
            overwriteExisting: false,
          );
          final savedPath = await downloadOnlineSong(
            url: source.url,
            destPath: destination,
            headersJson: jsonEncode(source.headers),
          );
          final lyrics = song.lyricsRaw?.trim() ?? '';
          final coverUrl = song.coverUrl?.trim() ?? '';
          await finalizeDownloadExtras(
            requestJson: jsonEncode({
              if ((settings?.downloadLyrics ?? true) && lyrics.isNotEmpty) 'lyricsText': lyrics,
              if ((settings?.downloadLyrics ?? true) && lyrics.isNotEmpty) 'lyricsPath': p.setExtension(savedPath, '.lrc'),
              if (coverUrl.startsWith('http://') || coverUrl.startsWith('https://')) 'coverUrl': coverUrl,
              'embedCover': true,
              'metadata': {
                'filePath': savedPath,
                'title': song.title,
                'artist': song.artist,
                'album': song.album,
                if (lyrics.isNotEmpty) 'lyrics': lyrics,
              },
            }),
          );
          await rememberDownloadedSongSnapshot(DownloadedSongSnapshot(
            path: savedPath,
            title: song.title,
            artist: song.artist,
            album: song.album,
            durationMs: song.duration * 1000,
            downloadedAt: DateTime.now().millisecondsSinceEpoch,
            coverUrl: song.coverUrl,
            lyricsRaw: lyrics.isEmpty ? null : lyrics,
          ));
          success++;
        } catch (_) {
          failed++;
        }
      }
      if (mounted) {
        XyNotice.show(
          context,
          message: '批量下载完成：成功 $success 首${skipped > 0 ? '，本地歌曲跳过 $skipped 首' : ''}${failed > 0 ? '，失败 $failed 首' : ''}',
          type: failed > 0 ? XyNoticeType.warning : XyNoticeType.success,
        );
        _closeSelection();
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<List<Song>> _loadSongs(WidgetRef ref, MobilePlaylist playlist) async {
    final networkPaths = playlist.songSnapshots.keys.toSet();
    final localPaths = playlist.songPaths.where((path) => !networkPaths.contains(path)).toList();
    final localSongs = await ref.read(libraryProvider.notifier).songsByPaths(localPaths);
    final songsByPath = <String, Song>{
      for (final song in localSongs) song.path: song,
      for (final entry in playlist.songSnapshots.entries) entry.key: entry.value.toSong(),
    };
    return [for (final path in playlist.songPaths) if (songsByPath[path] != null) songsByPath[path]!];
  }
}

class _PlaylistDownloadOptions {
  const _PlaylistDownloadOptions({required this.directory, required this.quality});
  final String directory;
  final String quality;
}

class _PlaylistDownloadOptionsDialog extends StatefulWidget {
  const _PlaylistDownloadOptionsDialog({required this.initialDirectory, required this.initialQuality});
  final String initialDirectory;
  final String initialQuality;

  @override
  State<_PlaylistDownloadOptionsDialog> createState() => _PlaylistDownloadOptionsDialogState();
}

class _PlaylistDownloadOptionsDialogState extends State<_PlaylistDownloadOptionsDialog> {
  late final TextEditingController _directoryController;
  late String _quality;
  String? _error;
  bool _choosing = false;
  static const _qualities = ['128k', '192k', '320k', 'flac'];

  @override
  void initState() {
    super.initState();
    _directoryController = TextEditingController(text: widget.initialDirectory);
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
      final selected = await FilePicker.platform.getDirectoryPath();
      if (!mounted || selected == null) return;
      _directoryController.text = selected;
      setState(() => _error = null);
    } catch (error) {
      if (mounted) setState(() => _error = '选择文件夹失败：$error');
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  void _submit() {
    final directory = _directoryController.text.trim();
    if (directory.isEmpty || directory.startsWith('content://')) {
      setState(() => _error = '请输入或选择可访问的下载文件夹');
      return;
    }
    Navigator.pop(context, _PlaylistDownloadOptions(directory: directory, quality: _quality));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('批量下载'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 360,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('下载位置'),
              const SizedBox(height: 8),
              TextField(controller: _directoryController, maxLines: 2, decoration: const InputDecoration(prefixIcon: Icon(Icons.folder_outlined), hintText: '/storage/emulated/0/Music')),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _choosing ? null : _chooseDirectory,
                  icon: _choosing ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.create_new_folder_outlined),
                  label: Text(_choosing ? '正在选择…' : '直接选择文件夹'),
                ),
              ),
              const SizedBox(height: 18),
              const Text('下载音质'),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [for (final quality in _qualities) ChoiceChip(label: Text(_qualityLabel(quality)), selected: _quality == quality, onSelected: (_) => setState(() => _quality = quality))]),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('开始下载')),
      ],
    );
  }

  static String _normalize(String value) => switch (value.trim()) {
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
