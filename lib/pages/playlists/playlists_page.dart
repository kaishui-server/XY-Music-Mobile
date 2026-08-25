import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../../src/playlists/playlists_provider.dart';
import '../../src/playlists/network_playlist_import.dart';
import '../../src/playlists/musicfree_backup_import.dart';
import '../../src/library/library_provider.dart';
import '../../src/plugins/plugin_runtime.dart';
import '../../src/player/player_provider.dart';
import '../../src/rust/api.dart';
import '../../src/ui/xy_surface.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/top_notice.dart';

enum _DuplicatePlaylistAction { merge, keepBoth }

Future<_DuplicatePlaylistAction?> _confirmDuplicatePlaylist(
  BuildContext context,
  String name,
) {
  return showDialog<_DuplicatePlaylistAction>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: const Text('歌单已存在'),
      content: Text('检测到导入的$name歌单在本地已有此名称的歌单，是否直接合并？'),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, _DuplicatePlaylistAction.keepBoth),
          child: const Text('保留两个歌单'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(dialogContext, _DuplicatePlaylistAction.merge),
          child: const Text('合并'),
        ),
      ],
    ),
  );
}

class PlaylistsPage extends ConsumerStatefulWidget {
  const PlaylistsPage({super.key});

  @override
  ConsumerState<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends ConsumerState<PlaylistsPage> {
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};

  void _toggleSelection(String id) {
    setState(() {
      if (!_selectedIds.add(id)) _selectedIds.remove(id);
    });
  }

  void _enterSelection(String id) {
    setState(() {
      _selectionMode = true;
      _selectedIds.add(id);
    });
  }

  void _leaveSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _selectAll(List<MobilePlaylist> playlists) {
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(playlists.map((playlist) => playlist.id));
    });
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '输入歌单名称'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null) await ref.read(playlistsProvider.notifier).create(name);
  }

  Future<void> _showImportOptions(BuildContext context, WidgetRef ref) async {
    final mode = await showModalBottomSheet<_PlaylistImportMode>(
      context: context,
      // 迷你播放栏位于 Shell 的顶层 Stack；使用根 Navigator 让弹窗覆盖它。
      useRootNavigator: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.cloud_download_rounded),
                title: const Text('从网络导入'),
                subtitle: const Text('网易云、QQ音乐、酷我、酷狗'),
                onTap: () =>
                    Navigator.pop(sheetContext, _PlaylistImportMode.network),
              ),
              ListTile(
                leading: const Icon(Icons.extension_rounded),
                title: const Text('从 MusicFree 备份导入'),
                subtitle: const Text('选择 MusicFree 导出的 JSON 备份文件'),
                onTap: () =>
                    Navigator.pop(sheetContext, _PlaylistImportMode.musicFree),
              ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file_rounded),
                title: const Text('从本地文件导入'),
                subtitle: const Text('支持 M3U / M3U8 歌单'),
                onTap: () =>
                    Navigator.pop(sheetContext, _PlaylistImportMode.local),
              ),
            ],
          ),
        ),
      ),
    );
    if (!context.mounted) return;
    switch (mode) {
      case _PlaylistImportMode.network:
        await _importNetwork(context);
        break;
      case _PlaylistImportMode.musicFree:
        await _importMusicFreeBackup(context, ref);
        break;
      case _PlaylistImportMode.local:
        await _importLocal(context, ref);
        break;
      case null:
        break;
    }
  }

  Future<void> _importNetwork(BuildContext context) async {
    final summary = await showDialog<_NetworkImportSummary>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => const _NetworkPlaylistImportDialog(),
    );
    if (summary == null || !context.mounted) return;
    XyNotice.show(
      context,
      message: '已导入“${summary.name}”，共 ${summary.count} 首',
      type: XyNoticeType.success,
    );
  }

  Future<void> _importMusicFreeBackup(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty || !context.mounted) return;
    try {
      final file = picked.files.single;
      final bytes = file.bytes;
      final content = bytes != null && bytes.isNotEmpty
          ? utf8.decode(bytes, allowMalformed: true)
          : file.path == null
          ? ''
          : await File(file.path!).readAsString();
      if (content.trim().isEmpty) throw const FormatException('无法读取备份文件');
      final plugins = await ref.read(enabledMusicPluginsProvider.future);
      final result = parseMusicFreeBackup(
        content,
        plugins: plugins,
        localSongs: ref.read(libraryProvider).songs,
      );
      var playlistCount = 0;
      for (final playlist in result.playlists) {
        final notifier = ref.read(playlistsProvider.notifier);
        final existing = await notifier.findByName(playlist.name);
        if (existing != null) {
          if (!context.mounted) return;
          final action = await _confirmDuplicatePlaylist(
            context,
            playlist.name,
          );
          if (!context.mounted || action == null) continue;
          if (action == _DuplicatePlaylistAction.merge) {
            await notifier.mergeImportedSongs(existing.id, playlist.songs);
            playlistCount++;
            continue;
          }
        }
        final created = await notifier.create(
          playlist.name,
          songs: playlist.songs,
        );
        if (created != null) playlistCount++;
      }
      if (!context.mounted) return;
      if (result.unmatchedPluginSongs > 0) {
        await showDialog<void>(
          context: context,
          useRootNavigator: true,
          builder: (dialogContext) => AlertDialog(
            title: const Text('导入完成'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '成功导入${result.importedSongs}首歌曲，'
                  '${result.unmatchedPluginSongs}首歌曲因无匹配插件无法关联，'
                  '请您安装完整对应插件后重试',
                ),
                if (result.missingPluginSources.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    '缺失插件：${result.missingPluginSources.join('、')}',
                    style: TextStyle(
                      color: Theme.of(dialogContext).colorScheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('确定'),
              ),
            ],
          ),
        );
      } else {
        final skipped = result.skippedSongs > 0
            ? '，跳过 ${result.skippedSongs} 首数据不完整的歌曲'
            : '';
        XyNotice.show(
          context,
          message:
              '已从 MusicFree 备份导入 $playlistCount 个歌单、${result.importedSongs} 首歌曲$skipped',
          type: result.skippedSongs > 0
              ? XyNoticeType.warning
              : XyNoticeType.success,
        );
      }
    } catch (error) {
      if (!context.mounted) return;
      XyNotice.show(
        context,
        message:
            'MusicFree 备份导入失败：${error.toString().replaceFirst('Exception: ', '')}',
        type: XyNoticeType.error,
      );
    }
  }

  Future<void> _importLocal(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['m3u', 'm3u8'],
    );
    final filePath = result?.files.single.path;
    if (filePath == null || !context.mounted) return;
    try {
      if (!await _ensureLocalAudioPermission()) {
        throw Exception('未授予本地音乐访问权限，无法读取歌单中的歌曲');
      }
      final file = File(filePath);
      final base = file.parent.path;
      final lines = await file.readAsLines();
      final paths = lines
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('#'))
          .map((line) => _resolveM3uPath(line, base))
          .where((path) => path.isNotEmpty)
          .toSet()
          .toList();
      if (paths.isEmpty) throw Exception('歌单文件中没有本地音频路径');
      final parsed = jsonDecode(
        await parseAudioFiles(pathsJson: jsonEncode(paths)),
      );
      final songs = parsed is List
          ? parsed
                .whereType<Map>()
                .map((item) => Song.fromJson(Map<String, dynamic>.from(item)))
                .toList()
          : const <Song>[];
      if (songs.isEmpty) {
        throw Exception('歌单中的音频文件不存在、没有访问权限或格式不受支持');
      }
      final name = p.basenameWithoutExtension(filePath);
      await ref.read(playlistsProvider.notifier).create(name, songs: songs);
      if (!context.mounted) return;
      XyNotice.show(
        context,
        message: '已导入“$name”，共 ${songs.length} 首',
        type: XyNoticeType.success,
      );
    } catch (error) {
      if (!context.mounted) return;
      XyNotice.show(
        context,
        message: '歌单导入失败：$error',
        type: XyNoticeType.error,
      );
    }
  }

  Future<bool> _ensureLocalAudioPermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.audio.isGranted ||
        await Permission.storage.isGranted ||
        await Permission.manageExternalStorage.isGranted) {
      return true;
    }
    if ((await Permission.audio.request()).isGranted) return true;
    if ((await Permission.storage.request()).isGranted) return true;
    return (await Permission.manageExternalStorage.request()).isGranted;
  }

  String _resolveM3uPath(String rawLine, String basePath) {
    final path = normalizeLocalAudioPath(rawLine);
    if (path.startsWith('content://')) return path;
    return p.isAbsolute(path)
        ? p.normalize(path)
        : p.normalize(p.join(basePath, path));
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    MobilePlaylist playlist,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除歌单'),
        content: Text('确定删除“${playlist.name}”吗？歌曲文件不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(playlistsProvider.notifier).delete(playlist.id);
    }
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    MobilePlaylist playlist,
  ) async {
    final controller = TextEditingController(text: playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '输入歌单名称'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == playlist.name.trim()) return;
    await ref.read(playlistsProvider.notifier).rename(playlist.id, trimmed);
  }

  Future<void> _deleteSelected(BuildContext context) async {
    final count = _selectedIds.length;
    if (count == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: const Text('批量删除歌单'),
        content: Text('确定删除选中的 $count 个歌单吗？歌曲文件不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(playlistsProvider.notifier).deleteMany(_selectedIds);
    if (!mounted) return;
    _leaveSelection();
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectionMode ? '已选择 ${_selectedIds.length} 个歌单' : '我的歌单'),
        actions: [
          if (_selectionMode) ...[
            IconButton(
              tooltip: '全选',
              onPressed: () => _selectAll(playlists),
              icon: const Icon(Icons.select_all_rounded),
            ),
            IconButton(
              tooltip: '删除所选歌单',
              onPressed: _selectedIds.isEmpty
                  ? null
                  : () => _deleteSelected(context),
              icon: const Icon(Icons.delete_outline_rounded),
            ),
            IconButton(
              tooltip: '取消多选',
              onPressed: _leaveSelection,
              icon: const Icon(Icons.close_rounded),
            ),
          ] else ...[
            IconButton(
              tooltip: '批量删除歌单',
              onPressed: playlists.isEmpty
                  ? null
                  : () => setState(() => _selectionMode = true),
              icon: const Icon(Icons.checklist_rounded),
            ),
            IconButton(
              tooltip: '导入歌单',
              onPressed: () => _showImportOptions(context, ref),
              icon: const Icon(Icons.download_rounded),
            ),
            IconButton(
              tooltip: '新建歌单',
              onPressed: () => _create(context, ref),
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ],
      ),
      body: XyPageBackground(
        child: playlists.isEmpty
            ? _EmptyPlaylists(
                onCreate: () => _create(context, ref),
                onImport: () => _showImportOptions(context, ref),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 98),
                itemCount: playlists.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final playlist = playlists[index];
                  return XyPanel(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      minTileHeight: 72,
                      leading: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_selectionMode)
                            Checkbox(
                              value: _selectedIds.contains(playlist.id),
                              onChanged: (_) => _toggleSelection(playlist.id),
                            ),
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: playlist.songPaths.isNotEmpty
                                ? CoverImage(
                                    songPath: playlist.songPaths.first,
                                    imageUrl: playlist.effectiveCoverUrl,
                                    width: 48,
                                    height: 48,
                                    radius: 0,
                                    icon: Icons.queue_music_rounded,
                                  )
                                : Icon(
                                    Icons.queue_music_rounded,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                          ),
                        ],
                      ),
                      title: Text(
                        playlist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text('${playlist.songPaths.length} 首歌曲'),
                      trailing: _selectionMode
                          ? null
                          : PopupMenuButton<String>(
                              tooltip: '更多',
                              onSelected: (action) {
                                switch (action) {
                                  case 'rename':
                                    _rename(context, ref, playlist);
                                  case 'delete':
                                    _delete(context, ref, playlist);
                                }
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                  value: 'rename',
                                  child: ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(Icons.edit_outlined),
                                    title: Text('重命名'),
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(Icons.delete_outline),
                                    title: Text('删除歌单'),
                                  ),
                                ),
                              ],
                              icon: const Icon(Icons.more_horiz_rounded),
                            ),
                      onTap: () => _selectionMode
                          ? _toggleSelection(playlist.id)
                          : context.push('/home/playlists/${playlist.id}'),
                      onLongPress: _selectionMode
                          ? null
                          : () => _enterSelection(playlist.id),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _EmptyPlaylists extends StatelessWidget {
  const _EmptyPlaylists({required this.onCreate, required this.onImport});

  final VoidCallback onCreate;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(30, 20, 30, 80),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.queue_music_rounded,
              size: 60,
              color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
            ),
            const SizedBox(height: 16),
            const Text(
              '还没有歌单',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 7),
            Text(
              '创建自己的歌单，或从网络和本地文件导入',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: onImport,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('导入'),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: onCreate,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('新建歌单'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _PlaylistImportMode { network, musicFree, local }

class _NetworkImportSummary {
  const _NetworkImportSummary(this.name, this.count);

  final String name;
  final int count;
}

class _NetworkPlaylistImportDialog extends ConsumerStatefulWidget {
  const _NetworkPlaylistImportDialog();

  @override
  ConsumerState<_NetworkPlaylistImportDialog> createState() =>
      _NetworkPlaylistImportDialogState();
}

class _NetworkPlaylistImportDialogState
    extends ConsumerState<_NetworkPlaylistImportDialog> {
  final _idController = TextEditingController();
  final _renameController = TextEditingController();
  String _selectedSourceId = 'builtin:wy';
  String? _error;
  bool _importing = false;

  @override
  void dispose() {
    _idController.dispose();
    _renameController.dispose();
    super.dispose();
  }

  Future<void> _submit(List<EnabledMusicPlugin> plugins) async {
    final input = _idController.text.trim();
    if (input.isEmpty || _importing) return;
    final sourceId = _selectedSourceId;
    if (sourceId.isEmpty) {
      setState(() => _error = '请选择歌单来源');
      return;
    }
    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      late final String importedName;
      late final String importedCover;
      late final List<Song> songs;
      if (sourceId.startsWith('builtin:')) {
        final service = NetworkPlaylistImportService();
        try {
          final result = await service.importPlaylist(
            sourceId.substring('builtin:'.length),
            input,
          );
          importedName = result.name;
          importedCover = result.coverUrl;
          songs = result.songs;
        } finally {
          service.dispose();
        }
      } else {
        final pluginId = sourceId.substring('plugin:'.length);
        final plugin = plugins.firstWhere(
          (item) => item.id == pluginId,
          orElse: () => throw Exception('所选插件已停用或删除'),
        );
        final result = await ref
            .read(pluginRuntimeProvider)
            .importPlaylist(plugin, input);
        importedName = result.name;
        importedCover = result.coverUrl;
        songs = result.songs
            .where((item) => item.title.trim().isNotEmpty)
            .map(
              (item) => Song(
                path: pluginSongPath(plugin, item),
                title: item.title,
                artist: item.artist,
                album: item.album,
                albumKey: item.album,
                duration: (item.durationMs / 1000).round(),
                format: '网络',
                coverUrl: item.coverUrl,
                pluginId: plugin.id,
                pluginData: item.rawData,
                lyricsRaw: _embeddedLyrics(item.rawData),
              ),
            )
            .toList();
      }
      if (songs.isEmpty) throw Exception('歌单中没有可导入的歌曲');
      final rename = _renameController.text.trim();
      final name = rename.isEmpty ? importedName : rename;
      final notifier = ref.read(playlistsProvider.notifier);
      // 内置网络接口沿用原有导入行为；插件歌单需要额外处理同名合并，
      // 与 MusicFree 备份导入保持一致。
      final existing = sourceId.startsWith('plugin:')
          ? await notifier.findByName(name)
          : null;
      if (existing != null) {
        if (!mounted) return;
        final action = await _confirmDuplicatePlaylist(context, name);
        if (!mounted) return;
        if (action == null) {
          setState(() => _importing = false);
          return;
        }
        if (action == _DuplicatePlaylistAction.merge) {
          await notifier.mergeImportedSongs(
            existing.id,
            songs,
            coverUrl: importedCover,
          );
        } else {
          await notifier.create(
            name,
            coverUrl: importedCover.isEmpty
                ? songs.first.coverUrl
                : importedCover,
            songs: songs,
          );
        }
      } else {
        await notifier.create(
          name,
          coverUrl: importedCover.isEmpty
              ? songs.first.coverUrl
              : importedCover,
          songs: songs,
        );
      }
      if (!mounted) return;
      Navigator.pop(context, _NetworkImportSummary(name, songs.length));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Exception: ', '');
        _importing = false;
      });
    }
  }

  static String? _embeddedLyrics(Map<String, dynamic> raw) {
    for (final key in const [
      'yrc',
      'qrc',
      'eslrc',
      'lxlyric',
      'lyric',
      'lyrics',
      'lrc',
    ]) {
      final value = raw[key];
      if (value is String && value.trim().isNotEmpty) return value;
      if (value is Map) {
        for (final nested in const ['lyric', 'lyrics', 'lrc', 'content']) {
          final text = value[nested];
          if (text is String && text.trim().isNotEmpty) return text;
        }
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final pluginsValue = ref.watch(enabledMusicPluginsProvider);
    final plugins = pluginsValue.valueOrNull ?? const <EnabledMusicPlugin>[];
    return AlertDialog(
      title: const Text('从网络导入歌单'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _selectedSourceId,
                decoration: const InputDecoration(
                  labelText: '选择歌单来源',
                  prefixIcon: Icon(Icons.cloud_rounded),
                ),
                items: [
                  for (final source in builtinPlaylistSources)
                    DropdownMenuItem(
                      value: 'builtin:${source.id}',
                      child: Text(source.name),
                    ),
                  for (final plugin in plugins)
                    DropdownMenuItem(
                      value: 'plugin:${plugin.id}',
                      child: Text(
                        plugin.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _importing
                    ? null
                    : (value) => setState(
                        () => _selectedSourceId = value ?? 'builtin:wy',
                      ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _idController,
                autofocus: true,
                enabled: !_importing,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: '歌单 ID',
                  hintText: '输入歌单 ID，也支持粘贴分享链接',
                  prefixIcon: Icon(Icons.tag_rounded),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _renameController,
                enabled: !_importing,
                maxLength: 40,
                decoration: const InputDecoration(
                  labelText: '歌单重命名（可选）',
                  hintText: '留空则使用网络歌单名称',
                  prefixIcon: Icon(Icons.edit_rounded),
                ),
              ),
              Text(
                '内置支持网易云、QQ音乐、酷我、酷狗，仅可导入公开歌单。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
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
          onPressed: _importing ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _importing ? null : () => _submit(plugins),
          child: _importing
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('导入歌单'),
        ),
      ],
    );
  }
}
