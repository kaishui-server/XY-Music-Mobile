import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lpinyin/lpinyin.dart';
import 'package:path/path.dart' as p;

import '../../src/core/settings.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/player/download_history_store.dart';
import '../../src/player/downloaded_song_store.dart';
import '../../src/player/android_storage.dart';
import '../../src/player/download_quality.dart';
import '../../src/player/player_provider.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/top_notice.dart' show XyNotice, XyNoticeType;

class PlaylistDetailPage extends ConsumerStatefulWidget {
  const PlaylistDetailPage({
    super.key,
    required this.playlistId,
    this.autoFocusSearch = false,
  });
  final String playlistId;
  final bool autoFocusSearch;

  @override
  ConsumerState<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

/// 歌单内歌曲排序方式。
enum _SongSortOrder {
  added('添加顺序'),
  timeDesc('时间从新到旧'),
  titleAsc('歌名 A-Z'),
  titleDesc('歌名 Z-A');

  const _SongSortOrder(this.label);
  final String label;
}

class _PlaylistDetailPageState extends ConsumerState<PlaylistDetailPage> {
  final Set<String> _selectedPaths = <String>{};
  List<Song> _songs = const <Song>[];
  List<Song> _visibleSongs = const <Song>[];
  bool _selectionMode = false;
  bool _downloading = false;
  late final TextEditingController _searchController;
  final FocusNode _searchFocus = FocusNode();
  bool _searchMode = false;
  String _query = '';
  _SongSortOrder _sortOrder = _SongSortOrder.added;

  /// 歌曲列表加载缓存：future 只跟随歌单内容指纹创建一次，
  /// 勾选/搜索等 setState 不会重复触发数据库查询和全屏转圈。
  int _songsCacheKey = 0;
  Future<List<Song>>? _songsFuture;

  Future<List<Song>> _songsFor(MobilePlaylist playlist) {
    final key = Object.hashAll(playlist.songPaths);
    if (_songsFuture == null || key != _songsCacheKey) {
      _songsCacheKey = key;
      _songsFuture = _loadSongs(ref, playlist);
    }
    return _songsFuture!;
  }

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    if (widget.autoFocusSearch) {
      _searchMode = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _enterSearch() {
    setState(() => _searchMode = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _exitSearch() {
    _searchFocus.unfocus();
    setState(() {
      _searchMode = false;
      _query = '';
      _searchController.clear();
    });
  }

  /// 按当前排序方式整理歌曲列表。时间排序基于歌单的添加顺序
  /// （songPaths 本身按添加先后存储），歌名排序使用拼音避免中文乱序。
  List<Song> _applySort(List<Song> songs) {
    switch (_sortOrder) {
      case _SongSortOrder.added:
        return songs;
      case _SongSortOrder.timeDesc:
        return songs.reversed.toList();
      case _SongSortOrder.titleAsc:
      case _SongSortOrder.titleDesc:
        final descending = _sortOrder == _SongSortOrder.titleDesc;
        final sorted = [...songs]..sort((a, b) {
            final result = _pinyinKey(a.title).compareTo(_pinyinKey(b.title));
            return descending ? -result : result;
          });
        return sorted;
    }
  }

  String _pinyinKey(String title) =>
      PinyinHelper.getPinyinE(title.trim(), separator: ' ').toLowerCase();

  Future<void> _showSortSheet() async {
    final order = await showModalBottomSheet<_SongSortOrder>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '歌曲排序',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            for (final value in _SongSortOrder.values)
              ListTile(
                title: Text(value.label),
                leading: Icon(
                  value == _sortOrder
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                ),
                onTap: () => Navigator.pop(context, value),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (order == null || order == _sortOrder) return;
    setState(() => _sortOrder = order);
  }

  void _toggleSelection(Song song) {
    setState(() {
      if (!_selectedPaths.add(song.path)) _selectedPaths.remove(song.path);
    });
  }

  void _toggleAll() {
    final visible = _visibleSongs;
    setState(() {
      if (visible.isNotEmpty &&
          _selectedPaths.length == visible.length &&
          visible.every((song) => _selectedPaths.contains(song.path))) {
        _selectedPaths.clear();
      } else {
        _selectedPaths
          ..clear()
          ..addAll(visible.map((song) => song.path));
      }
    });
  }

  void _closeSelection() {
    setState(() {
      _selectionMode = false;
      _selectedPaths.clear();
    });
  }

  /// 多选一键收藏：确认后批量添加到收藏，已在收藏中的跳过。
  Future<void> _favoriteSelected() async {
    if (_selectedPaths.isEmpty) return;
    final selected = _songs
        .where((song) => _selectedPaths.contains(song.path))
        .toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加到收藏'),
        content: Text('是否将 ${selected.length} 首歌曲添加到收藏？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final added = await ref
        .read(favoritesProvider.notifier)
        .addAll(selected.map(FavoriteSongSnapshot.fromSong));
    if (!mounted) return;
    _closeSelection();
    final message = added > 0 ? '已收藏 $added 首歌曲' : '所选歌曲均已在收藏中';
    XyNotice.show(context, message: message, type: XyNoticeType.success);
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
        title: _searchMode
            ? TextField(
                controller: _searchController,
                focusNode: _searchFocus,
                autofocus: true,
                maxLines: 1,
                textInputAction: TextInputAction.search,
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜索歌单中的歌曲',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: _exitSearch,
                        ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                ),
              )
            : Text(
                _selectionMode && _selectedPaths.isNotEmpty
                    ? '已选 ${_selectedPaths.length} 首'
                    : playlist.name,
              ),
        actions: [
          if (_searchMode)
            TextButton(
              onPressed: _exitSearch,
              child: const Text('取消'),
            )
          else ...[
            if (_selectionMode)
              IconButton(
                tooltip: '添加到收藏',
                onPressed: _selectedPaths.isEmpty
                    ? null
                    : _favoriteSelected,
                icon: const _FavoriteAddIcon(),
              ),
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
            IconButton(
              tooltip: '排序',
              onPressed: _showSortSheet,
              icon: Icon(
                Icons.sort_rounded,
                color: _sortOrder == _SongSortOrder.added
                    ? null
                    : Theme.of(context).colorScheme.primary,
              ),
            ),
            IconButton(
              tooltip: '搜索',
              onPressed: _enterSearch,
              icon: const Icon(Icons.search_rounded),
            ),
          ],
        ],
      ),
      body: FutureBuilder<List<Song>>(
        key: ValueKey(_songsCacheKey),
        future: _songsFor(playlist),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final songs = snapshot.data ?? const <Song>[];
          _songs = songs;
          final query = _query;
          final visibleSongs = _applySort(query.isEmpty
              ? songs
              : songs
                    .where(
                      (song) =>
                          song.title.toLowerCase().contains(query) ||
                          song.artist.toLowerCase().contains(query) ||
                          song.album.toLowerCase().contains(query),
                    )
                    .toList());
          _visibleSongs = visibleSongs;
          return Column(
            children: [
              _PlaylistHeroHeader(
                playlist: playlist!,
                songs: songs,
                onPlayAll: songs.isEmpty
                    ? null
                    : () =>
                        ref.read(libraryProvider.notifier).playAll(_applySort(songs)),
              ),
              if (songs.isEmpty)
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 110),
                      child: Text(
                        '歌单中暂无可用歌曲',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                )
              else if (visibleSongs.isEmpty)
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 110),
                      child: Text(
                        '未找到匹配的歌曲',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                )
              else
                Expanded(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Row(
                          children: [
                            Text(
                              query.isEmpty
                                  ? '${songs.length} 首歌曲'
                                  : '${visibleSongs.length} / ${songs.length} 首歌曲',
                            ),
                            if (_selectionMode) ...[
                              const SizedBox(width: 10),
                              TextButton(
                                onPressed: _toggleAll,
                                child: Text(
                                  _selectedPaths.length == visibleSongs.length
                                      ? '取消全选'
                                      : '全选',
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Expanded(
                        child: SongsListView(
                          songs: visibleSongs,
                          padding: const EdgeInsets.fromLTRB(10, 0, 10, 90),
                          selectionMode: _selectionMode,
                          isSelected: (song) =>
                              _selectedPaths.contains(song.path),
                          onToggleSelection: _toggleSelection,
                          onPlay: (list, index) => ref
                              .read(libraryProvider.notifier)
                              .playList(list, index),
                        ),
                      ),
                    ],
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
    final selected = _songs
        .where((song) => _selectedPaths.contains(song.path))
        .toList();
    final settings = ref.read(settingsProvider).valueOrNull;
    final initialDirectory = await resolveMusicDownloadDirectory(settings);
    if (!mounted) return;
    final options = settings?.askDownloadDetails ?? true
        ? await showDialog<_PlaylistDownloadOptions>(
            context: context,
            useRootNavigator: true,
            builder: (context) => _PlaylistDownloadOptionsDialog(
              initialDirectory: initialDirectory,
              initialQuality: settings?.downloadQuality ?? '320k',
            ),
          )
        : _PlaylistDownloadOptions(
            directory: initialDirectory,
            quality: settings?.downloadQuality ?? '320k',
          );
    if (!mounted || options == null) return;
    final settingsNotifier = ref.read(settingsProvider.notifier);
    await settingsNotifier.setDownloadPath(options.directory.trim());
    await settingsNotifier.setDownloadQuality(options.quality);
    if (options.dontAskAgain) {
      await settingsNotifier.setAskDownloadDetails(false);
    }
    if (!mounted) return;
    setState(() => _downloading = true);
    var success = 0;
    var skipped = 0;
    var failed = 0;
    var completed = 0;
    final total = selected.length;
    final downgraded = <String>[];
    final failureReasons = <String>[];
    try {
      final usesSafDirectory = AndroidStorage.isTreeUri(options.directory);
      final workDirectory = usesSafDirectory
          ? await resolveDownloadStagingDirectory()
          : options.directory;
      await Directory(workDirectory).create(recursive: true);
      final notifier = ref.read(playerProvider.notifier);
      final historyNotifier = ref.read(downloadHistoryProvider.notifier);
      for (final song in selected) {
        if (playbackSourceTypeFor(song.toQueueItem()) ==
            PlaybackSourceType.localFile) {
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
              'embedCover': true,
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
              directoryUri: options.directory,
              sourcePath: verified.path,
              fileName: p.basename(verified.path),
              mimeType: 'audio/*',
            );
            final lrcPath = p.setExtension(verified.path, '.lrc');
            if (await File(lrcPath).exists()) {
              await AndroidStorage.copyFileToDirectory(
                directoryUri: options.directory,
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
          failed++;
          failureReasons.add('${song.title}：$error');
          historyNotifier.fail(historyId, error.toString());
        }
        completed++;
        if (mounted) {
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
      if (mounted) {
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
        _closeSelection();
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<List<Song>> _loadSongs(WidgetRef ref, MobilePlaylist playlist) async {
    final networkPaths = playlist.songSnapshots.keys.toSet();
    final localPaths = playlist.songPaths
        .where((path) => !networkPaths.contains(path))
        .toList();
    final localSongs = await ref
        .read(libraryProvider.notifier)
        .songsByPaths(localPaths);
    final songsByPath = <String, Song>{
      for (final song in localSongs) song.path: song,
      for (final entry in playlist.songSnapshots.entries)
        entry.key: entry.value.toSong(),
    };
    return [
      for (final path in playlist.songPaths)
        if (songsByPath[path] != null) songsByPath[path]!,
    ];
  }
}

class _PlaylistHeroHeader extends StatelessWidget {
  const _PlaylistHeroHeader({
    required this.playlist,
    required this.songs,
    required this.onPlayAll,
  });

  final MobilePlaylist playlist;
  final List<Song> songs;
  final VoidCallback? onPlayAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coverPath = playlist.songPaths.isEmpty
        ? 'playlist://${playlist.id}'
        : playlist.songPaths.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CoverImage(
            songPath: coverPath,
            imageUrl: playlist.effectiveCoverUrl,
            width: 124,
            height: 124,
            radius: 18,
            highQuality: true,
            icon: Icons.queue_music_rounded,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  playlist.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '本地歌单 · ${songs.length} 首歌曲',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: onPlayAll,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('播放全部'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 收藏按钮图标：空心心形 + 右下角加号，表达“添加到收藏”。
class _FavoriteAddIcon extends StatelessWidget {
  const _FavoriteAddIcon();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      height: 24,
      child: Stack(
        clipBehavior: Clip.none,
        children: const [
          Align(
            alignment: Alignment.center,
            child: Icon(Icons.favorite_border_rounded, size: 22),
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: Icon(Icons.add_circle_rounded, size: 13),
          ),
        ],
      ),
    );
  }
}

class _PlaylistDownloadOptions {
  const _PlaylistDownloadOptions({
    required this.directory,
    required this.quality,
    this.dontAskAgain = false,
  });
  final String directory;
  final String quality;
  final bool dontAskAgain;
}

class _PlaylistDownloadOptionsDialog extends StatefulWidget {
  const _PlaylistDownloadOptionsDialog({
    required this.initialDirectory,
    required this.initialQuality,
  });
  final String initialDirectory;
  final String initialQuality;

  @override
  State<_PlaylistDownloadOptionsDialog> createState() =>
      _PlaylistDownloadOptionsDialogState();
}

class _PlaylistDownloadOptionsDialogState
    extends State<_PlaylistDownloadOptionsDialog> {
  late final TextEditingController _directoryController;
  late String _directoryValue;
  late String _quality;
  bool _dontAskAgain = false;
  String? _error;
  bool _choosing = false;
  static const _qualities = ['128k', '192k', '320k', 'flac'];

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
      _PlaylistDownloadOptions(
        directory: directory,
        quality: _quality,
        dontAskAgain: _dontAskAgain,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('批量下载'),
      content: SizedBox(
        width: 360,
        height: 220,
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
              const SizedBox(height: 8),
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
