import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../favorites/favorites_provider.dart';
import '../library/library_provider.dart';
import '../player/player_provider.dart';
import '../plugins/lx_playlist_import.dart';
import '../plugins/plugin_runtime.dart';
import '../rust/api.dart';
import '../widgets/top_notice.dart';
import 'musicfree_backup_import.dart';
import 'playlists_provider.dart';
import 'playlist_sync.dart';
import 'xy_playlist_file.dart';

enum PlaylistImportMode { network, musicFree, local, xy }

enum DuplicatePlaylistAction { merge, keepBoth }

Future<DuplicatePlaylistAction?> confirmDuplicatePlaylist(
  BuildContext context,
  String name,
) {
  return showDialog<DuplicatePlaylistAction>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: const Text('歌单已存在'),
      content: Text('检测到导入的$name歌单在本地已有此名称的歌单，是否直接合并？'),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(dialogContext, DuplicatePlaylistAction.keepBoth),
          child: const Text('保留两个歌单'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(dialogContext, DuplicatePlaylistAction.merge),
          child: const Text('合并'),
        ),
      ],
    ),
  );
}

/// 歌单「更多」菜单里的重命名（含输入对话框）。
Future<void> renamePlaylistWithDialog(
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

/// 歌单「更多」菜单里的删除（含确认对话框）。
Future<void> deletePlaylistWithDialog(
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

/// 导入歌单入口：弹出来源选择弹窗（网络 / MusicFree / 本地文件 /
/// XY Music 歌单文件），供歌单管理页与音乐库-歌单页共用。
Future<void> showPlaylistImportOptions(
  BuildContext context,
  WidgetRef ref,
) async {
  final mode = await showModalBottomSheet<PlaylistImportMode>(
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
                  Navigator.pop(sheetContext, PlaylistImportMode.network),
            ),
            ListTile(
              leading: const Icon(Icons.extension_rounded),
              title: const Text('从 MusicFree 备份导入'),
              subtitle: const Text('选择 MusicFree 导出的 JSON 备份文件'),
              onTap: () =>
                  Navigator.pop(sheetContext, PlaylistImportMode.musicFree),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_rounded),
              title: const Text('从本地文件导入'),
              subtitle: const Text('支持 M3U / M3U8 / 洛雪 JSON 歌单'),
              onTap: () => Navigator.pop(sheetContext, PlaylistImportMode.local),
            ),
            ListTile(
              leading: const Icon(Icons.library_music_rounded),
              title: const Text('从 XY Music 歌单文件导入'),
              subtitle: const Text('选择 XY Music 导出的 .xyplaylist 文件'),
              onTap: () => Navigator.pop(sheetContext, PlaylistImportMode.xy),
            ),
          ],
        ),
      ),
    ),
  );
  if (!context.mounted) return;
  switch (mode) {
    case PlaylistImportMode.network:
      await _importNetwork(context);
    case PlaylistImportMode.musicFree:
      await _importMusicFreeBackup(context, ref);
    case PlaylistImportMode.local:
      await _importLocal(context, ref);
    case PlaylistImportMode.xy:
      await importXyPlaylistFile(context, ref);
    case null:
      break;
  }
}

Future<void> _importNetwork(BuildContext context) async {
  final summary = await showDialog<NetworkImportSummary>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (_) => const _NetworkPlaylistImportDialog(),
  );
  if (summary == null || !context.mounted) return;
  final message = StringBuffer('已导入“${summary.name}”，共 ${summary.count} 首');
  if (summary.favoritedCount > 0) {
    message.write('，其中 ${summary.favoritedCount} 首已加入我的收藏');
  }
  XyNotice.show(context, message: message.toString(), type: XyNoticeType.success);
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
        final action = await confirmDuplicatePlaylist(
          context,
          playlist.name,
        );
        if (!context.mounted || action == null) continue;
        if (action == DuplicatePlaylistAction.merge) {
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
    allowedExtensions: const ['m3u', 'm3u8', 'json'],
  );
  final filePath = result?.files.single.path;
  if (filePath == null || !context.mounted) return;
  try {
    // 洛雪歌单导出是 JSON 结构，按扩展名分流处理。
    if (p.extension(filePath).toLowerCase() == '.json') {
      await _importLxLocalFile(context, ref, filePath);
      return;
    }
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

/// 导入洛雪歌单导出的 JSON 文件（单歌单或 my-list 全量备份）。
Future<void> _importLxLocalFile(
  BuildContext context,
  WidgetRef ref,
  String filePath,
) async {
  final content = await File(filePath).readAsString();
  final playlists = tryParseLxLocalPlaylists(content);
  if (playlists.isEmpty) {
    throw Exception('不是有效的洛雪歌单文件');
  }
  final plugins = await ref.read(enabledMusicPluginsProvider.future);
  final lxPlugins = plugins.where((plugin) => plugin.isLx).toList();
  if (lxPlugins.isEmpty) {
    throw Exception('请先启用洛雪插件再导入洛雪歌单');
  }
  var playlistCount = 0;
  var songCount = 0;
  for (final playlist in playlists) {
    final songs = <Song>[];
    for (final raw in playlist.songs) {
      // 歌曲关联到支持其平台的洛雪插件；播放失败时洛雪管线
      // 会自动在其它洛雪插件与公共解析器之间回退。
      final source = raw['lx'] is Map
          ? (raw['lx'] as Map)['source']?.toString() ?? ''
          : '';
      final plugin = lxPlugins
          .where((item) => item.lxSources.contains(source))
          .firstOrNull ?? lxPlugins.first;
      final song = lxRawToPlaylistSong(plugin, raw);
      if (song != null) songs.add(song);
    }
    if (songs.isEmpty) continue;
    final notifier = ref.read(playlistsProvider.notifier);
    final existing = await notifier.findByName(playlist.name);
    if (existing != null) {
      if (!context.mounted) return;
      final action = await confirmDuplicatePlaylist(context, playlist.name);
      if (!context.mounted || action == null) continue;
      if (action == DuplicatePlaylistAction.merge) {
        await notifier.mergeImportedSongs(existing.id, songs);
        playlistCount++;
        songCount += songs.length;
        continue;
      }
    }
    final created = await notifier.create(playlist.name, songs: songs);
    if (created != null) {
      playlistCount++;
      songCount += songs.length;
    }
  }
  if (!context.mounted) return;
  if (playlistCount == 0) throw Exception('歌单中没有可导入的歌曲');
  XyNotice.show(
    context,
    message: '已从洛雪歌单导入 $playlistCount 个歌单、共 $songCount 首',
    type: XyNoticeType.success,
  );
}

/// 导出为 XY Music 歌单文件（.xyplaylist）：在线歌曲带完整快照，
/// 本地歌曲带路径，跨设备导入时快照直接还原、本地路径尽力匹配。
Future<void> exportXyPlaylistFile(
  BuildContext context,
  WidgetRef ref,
  MobilePlaylist playlist,
) async {
  if (playlist.songPaths.isEmpty) {
    XyNotice.show(
      context,
      message: '歌单为空，无法导出',
      type: XyNoticeType.warning,
    );
    return;
  }
  try {
    final content = const JsonEncoder.withIndent('  ').convert(
      buildXyPlaylistFile(playlist),
    );
    final safeName = playlist.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final outputPath = await FilePicker.platform.saveFile(
      fileName: '$safeName.xyplaylist',
      type: FileType.custom,
      allowedExtensions: const ['xyplaylist'],
      bytes: Uint8List.fromList(utf8.encode(content)),
    );
    if (outputPath == null) return;
    if (!context.mounted) return;
    XyNotice.show(
      context,
      message: '已导出“${playlist.name}”（${playlist.songPaths.length} 首）',
      type: XyNoticeType.success,
    );
  } catch (error) {
    if (!context.mounted) return;
    XyNotice.show(
      context,
      message: '歌单导出失败：$error',
      type: XyNoticeType.error,
    );
  }
}

/// 从 XY Music 歌单文件导入：快照歌曲直接还原，本地歌曲先匹配
/// 本机曲库、再尝试按路径解析音频，均失败的歌曲跳过。
Future<void> importXyPlaylistFile(
  BuildContext context,
  WidgetRef ref,
) async {
  final picked = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['xyplaylist', 'json'],
    withData: true,
  );
  final file = picked?.files.singleOrNull;
  if (file == null || !context.mounted) return;
  try {
    final bytes = file.bytes;
    final content = bytes != null && bytes.isNotEmpty
        ? utf8.decode(bytes, allowMalformed: true)
        : file.path == null
        ? ''
        : await File(file.path!).readAsString();
    if (content.trim().isEmpty) throw const FormatException('无法读取歌单文件');
    final data = parseXyPlaylistFile(content);
    final localPaths = [
      for (final path in data.songPaths)
        if (!data.songSnapshots.containsKey(path)) path,
    ];
    final songsByPath = <String, Song>{};
    if (localPaths.isNotEmpty) {
      final librarySongs = await ref
          .read(libraryProvider.notifier)
          .songsByPaths(localPaths);
      for (final song in librarySongs) {
        songsByPath[song.path] = song;
      }
      final missing = localPaths
          .where((path) => !songsByPath.containsKey(path))
          .toList();
      if (missing.isNotEmpty && await _ensureLocalAudioPermission()) {
        try {
          final parsed = jsonDecode(
            await parseAudioFiles(pathsJson: jsonEncode(missing)),
          );
          if (parsed is List) {
            for (final item in parsed.whereType<Map>()) {
              final song = Song.fromJson(Map<String, dynamic>.from(item));
              songsByPath[song.path] = song;
            }
          }
        } catch (_) {
          // 设备上不存在的本地路径直接跳过，不影响快照歌曲导入。
        }
      }
    }
    final songs = [
      for (final path in data.songPaths)
        data.songSnapshots[path]?.toSong() ?? songsByPath[path],
    ].whereType<Song>().toList();
    if (songs.isEmpty) throw const FormatException('歌单文件中没有可导入的歌曲');
    final notifier = ref.read(playlistsProvider.notifier);
    final existing = await notifier.findByName(data.name);
    if (existing != null) {
      if (!context.mounted) return;
      final action = await confirmDuplicatePlaylist(context, data.name);
      if (!context.mounted || action == null) return;
      if (action == DuplicatePlaylistAction.merge) {
        await notifier.mergeImportedSongs(
          existing.id,
          songs,
          coverUrl: data.coverUrl,
        );
        if (!context.mounted) return;
        XyNotice.show(
          context,
          message: '已合并到“${data.name}”，新增 ${songs.length} 首',
          type: XyNoticeType.success,
        );
        return;
      }
    }
    await notifier.create(data.name, songs: songs, coverUrl: data.coverUrl);
    if (!context.mounted) return;
    final skipped = data.songPaths.length - songs.length;
    XyNotice.show(
      context,
      message:
          '已导入“${data.name}”，共 ${songs.length} 首'
          '${skipped > 0 ? '（跳过 $skipped 首本机不存在的本地歌曲）' : ''}',
      type: skipped > 0 ? XyNoticeType.warning : XyNoticeType.success,
    );
  } catch (error) {
    if (!context.mounted) return;
    XyNotice.show(
      context,
      message:
          '歌单导入失败：${error.toString().replaceFirst('Exception: ', '').replaceFirst('FormatException: ', '')}',
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

class NetworkImportSummary {
  const NetworkImportSummary(this.name, this.count, this.favoritedCount);

  final String name;
  final int count;

  /// 同步加入「我的收藏」的歌曲数（未勾选一键收藏时为 0）。
  final int favoritedCount;
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
  // 歌单来源：仅支持已启用的插件（内置直连来源已移除，避免与
  // 同平台插件在下拉里表现为重复项）。洛雪插件按支持的平台拆分。
  String? _selectedSourceId;
  String? _error;
  bool _importing = false;
  // 导入同时把全部歌曲加入「我的收藏」。
  bool _favoriteAll = false;

  @override
  void dispose() {
    _idController.dispose();
    _renameController.dispose();
    super.dispose();
  }

  /// 洛雪平台来源 id：`lx:{pluginId}:{source}`。
  static String _lxSourceId(String pluginId, String source) =>
      'lx:$pluginId:$source';

  /// 当前有效的来源 id：选中项仍有效则用之，否则回退第一个来源。
  /// 默认未手动选择时即第一个来源。
  String? _effectiveSourceId(List<EnabledMusicPlugin> plugins) {
    if (_selectedSourceId != null &&
        _buildSourceIds(plugins).contains(_selectedSourceId)) {
      return _selectedSourceId;
    }
    final ids = _buildSourceIds(plugins);
    return ids.isNotEmpty ? ids.first : null;
  }

  /// 下拉项的来源 id 列表：洛雪插件按平台拆分，其余插件逐项。
  static List<String> _buildSourceIds(List<EnabledMusicPlugin> plugins) => [
    for (final plugin in plugins)
      if (plugin.isLx)
        for (final source in _lxPluginSources(plugin))
          _lxSourceId(plugin.id, source)
      else
        'plugin:${plugin.id}',
  ];

  /// 洛雪插件支持的平台：优先用检测结果，缺省为五个洛雪平台。
  static List<String> _lxPluginSources(EnabledMusicPlugin plugin) =>
      plugin.lxSources.isEmpty ? kLxSourceIds : plugin.lxSources;

  /// 插件类型标记：按订阅源 URL 前缀识别（Baka / 惜梦 / MusicFree），
  /// 详见 plugin_runtime 的 pluginSourceTag。
  static String _pluginTag(EnabledMusicPlugin plugin) =>
      pluginSourceTag(plugin);

  Future<void> _submit(List<EnabledMusicPlugin> plugins) async {
    final input = _idController.text.trim();
    if (input.isEmpty || _importing) return;
    final sourceId = _effectiveSourceId(plugins);
    if (sourceId == null || sourceId.isEmpty) {
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
      // 导入来源记录：供「同步来源」按原插件与输入重新拉取歌单。
      late final PlaylistImportSource source;
      if (sourceId.startsWith('lx:')) {
        // 洛雪插件来源：直连平台公开歌单接口（参考 lx-music-mobile），
        // 不经插件运行时；歌曲携带 lx 元数据走现有洛雪播放管线。
        final parts = sourceId.split(':');
        if (parts.length != 3) throw Exception('无效的洛雪来源');
        final plugin = plugins
            .where((item) => item.isLx && item.id == parts[1])
            .firstOrNull;
        if (plugin == null) throw Exception('所选洛雪插件已停用或删除');
        final result = await importLxPlaylist(source: parts[2], idOrUrl: input);
        importedName = result.name;
        importedCover = result.coverUrl;
        songs = result.songs
            .map((raw) => lxRawToPlaylistSong(plugin, raw))
            .whereType<Song>()
            .toList();
        source = PlaylistImportSource(
          kind: 'lx',
          pluginId: plugin.id,
          lxSource: parts[2],
          input: input,
          importedAt: DateTime.now().toIso8601String(),
        );
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
            .map((item) => pluginSearchSongToPlaylistSong(plugin, item))
            .whereType<Song>()
            .toList();
        source = PlaylistImportSource(
          kind: 'plugin',
          pluginId: plugin.id,
          input: input,
          importedAt: DateTime.now().toIso8601String(),
        );
      }
      if (songs.isEmpty) throw Exception('歌单中没有可导入的歌曲');
      final rename = _renameController.text.trim();
      final name = rename.isEmpty ? importedName : rename;
      final notifier = ref.read(playlistsProvider.notifier);
      // 插件导入需要处理同名歌单合并，与 MusicFree 备份导入保持一致。
      final existing = await notifier.findByName(name);
      if (existing != null) {
        if (!mounted) return;
        final action = await confirmDuplicatePlaylist(context, name);
        if (!mounted) return;
        if (action == null) {
          setState(() => _importing = false);
          return;
        }
        if (action == DuplicatePlaylistAction.merge) {
          await notifier.mergeImportedSongs(
            existing.id,
            songs,
            coverUrl: importedCover,
            sources: [source],
          );
        } else {
          await notifier.create(
            name,
            coverUrl: importedCover.isEmpty
                ? songs.first.coverUrl
                : importedCover,
            songs: songs,
            sources: [source],
          );
        }
      } else {
        await notifier.create(
          name,
          coverUrl: importedCover.isEmpty ? songs.first.coverUrl : importedCover,
          songs: songs,
          sources: [source],
        );
      }
      var favoritedCount = 0;
      if (_favoriteAll) {
        favoritedCount = await ref
            .read(favoritesProvider.notifier)
            .addAll([for (final song in songs) FavoriteSongSnapshot.fromSong(song)]);
      }
      if (!mounted) return;
      Navigator.pop(
        context,
        NetworkImportSummary(
          name,
          songs.length,
          favoritedCount,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Exception: ', '');
        _importing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pluginsValue = ref.watch(enabledMusicPluginsProvider);
    final plugins = pluginsValue.valueOrNull ?? const <EnabledMusicPlugin>[];
    // 插件列表变化（停用/删除）后保证选中项始终有效；默认选第一个。
    final effectiveSelected = _effectiveSourceId(plugins);

    return AlertDialog(
      title: const Text('从网络导入歌单'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (plugins.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    '尚未启用任何插件，请先在 设置 → 插件 中安装并启用音乐插件后再导入网络歌单。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: effectiveSelected,
                  decoration: const InputDecoration(
                    labelText: '选择歌单来源',
                    prefixIcon: Icon(Icons.cloud_rounded),
                  ),
                  items: [
                    // 洛雪插件按支持平台拆分并标记；其余插件按类型标记
                    // （Baka / MusicFree），方便区分同名来源。
                    for (final plugin in plugins)
                      if (plugin.isLx)
                        for (final source in _lxPluginSources(plugin))
                          DropdownMenuItem(
                            value: _lxSourceId(plugin.id, source),
                            child: Text(
                              '${plugin.name} · ${lxSourceLabel(source)}（洛雪）',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          )
                      else
                        DropdownMenuItem(
                          value: 'plugin:${plugin.id}',
                          child: Text(
                            '${plugin.name}（${_pluginTag(plugin)}）',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                  ],
                  onChanged: _importing
                      ? null
                      : (value) => setState(() => _selectedSourceId = value),
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
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _favoriteAll,
                onChanged: _importing
                    ? null
                    : (value) => setState(() => _favoriteAll = value),
                title: const Text('同时收藏全部歌曲'),
                subtitle: const Text('导入后把歌单内歌曲加入「我的收藏」'),
              ),
              Text(
                '来源为已启用的插件，仅可导入公开歌单。',
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
          onPressed: _importing || plugins.isEmpty
              ? null
              : () => _submit(plugins),
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
