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
import '../../src/library/library_provider.dart';
import '../../src/plugins/plugin_runtime.dart';
import '../../src/player/player_provider.dart';
import '../../src/rust/api.dart';
import '../../src/ui/xy_surface.dart';
import '../../src/widgets/top_notice.dart';

class PlaylistsPage extends ConsumerWidget {
  const PlaylistsPage({super.key});

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
                subtitle: const Text('选择插件并输入歌单 ID'),
                onTap: () =>
                    Navigator.pop(sheetContext, _PlaylistImportMode.network),
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的歌单'),
        actions: [
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
                      leading: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: playlist.coverUrl?.isNotEmpty == true
                            ? Image.network(
                                playlist.coverUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Icon(
                                  Icons.queue_music_rounded,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              )
                            : Icon(
                                Icons.queue_music_rounded,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                      ),
                      title: Text(
                        playlist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text('${playlist.songPaths.length} 首歌曲'),
                      trailing: IconButton(
                        tooltip: '删除歌单',
                        onPressed: () => _delete(context, ref, playlist),
                        icon: const Icon(Icons.more_horiz_rounded),
                      ),
                      onTap: () =>
                          context.push('/home/playlists/${playlist.id}'),
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

enum _PlaylistImportMode { network, local }

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
    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      late final String importedName;
      late final String importedCover;
      late final List<Song> songs;
      if (_selectedSourceId.startsWith('builtin:')) {
        final service = NetworkPlaylistImportService();
        try {
          final result = await service.importPlaylist(
            _selectedSourceId.substring('builtin:'.length),
            input,
          );
          importedName = result.name;
          importedCover = result.coverUrl;
          songs = result.songs;
        } finally {
          service.dispose();
        }
      } else {
        final pluginId = _selectedSourceId.substring('plugin:'.length);
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
                path:
                    'plugin://${Uri.encodeComponent(plugin.id)}/'
                    '${Uri.encodeComponent(item.id)}',
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
      await ref
          .read(playlistsProvider.notifier)
          .create(
            name,
            coverUrl: importedCover.isEmpty
                ? songs.first.coverUrl
                : importedCover,
            songs: songs,
          );
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
                decoration: const InputDecoration(
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
