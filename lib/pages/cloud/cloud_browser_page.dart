import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../src/core/db_path.dart';
import '../../src/library/library_provider.dart';
import '../../src/player/player_provider.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/top_notice.dart';

/// 网盘文件浏览器：浏览 Alist/OpenList 连接的远端目录，点击音频直接播放。
///
/// 参考 musicxx 的浏览-直连模型：不做挂载同步入库，进入连接后按需拉取
/// 目录列表（`remote://` URI 即时播放，凭据按 URI 中的源 id 从数据库解析），
/// 长按音频文件可缓存到本地离线播放。
class CloudBrowserPage extends ConsumerStatefulWidget {
  const CloudBrowserPage({super.key, required this.sourceId});

  final String sourceId;

  @override
  ConsumerState<CloudBrowserPage> createState() => _CloudBrowserPageState();
}

/// 远端目录条目（Rust `RemoteFileEntry` 的 camelCase JSON）。
class _RemoteEntry {
  const _RemoteEntry({
    required this.remotePath,
    required this.name,
    required this.size,
    required this.isDir,
    this.modifiedAt,
  });

  final String remotePath;
  final String name;
  final int size;
  final bool isDir;
  final String? modifiedAt;

  factory _RemoteEntry.fromJson(Map<String, dynamic> json) => _RemoteEntry(
    remotePath: json['remotePath'] as String? ?? '',
    name: json['name'] as String? ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
    isDir: json['isDir'] as bool? ?? false,
    modifiedAt: json['modifiedAt'] as String?,
  );
}

const _audioExtensions = <String>{
  'mp3', 'flac', 'wav', 'm4a', 'aac', 'ogg', 'opus', 'aiff', 'aif', 'wma', 'ape',
};

bool _isAudioPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return false;
  return _audioExtensions.contains(path.substring(dot + 1).toLowerCase());
}

String _titleFromName(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// 文件名「标题 - 歌手」拆分（与 Rust scanner 同语义：取最后一个分隔符）。
(String, String) _splitTitleArtist(String name) {
  final stem = _titleFromName(name);
  for (final separator in [' - ', '-', ' – ', '–', ' — ', '—']) {
    final index = stem.lastIndexOf(separator);
    if (index <= 0 || index + separator.length >= stem.length) continue;
    final title = stem.substring(0, index).trim();
    final artist = stem.substring(index + separator.length).trim();
    if (title.isNotEmpty && artist.isNotEmpty) return (title, artist);
  }
  return (stem, '');
}

String _albumFromPath(String remotePath) {
  final segments = remotePath
      .split('/')
      .where((segment) => segment.trim().isNotEmpty)
      .toList();
  return segments.length >= 2 ? segments[segments.length - 2] : '未知专辑';
}

String _formatSize(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(value / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
}

class _CloudBrowserPageState extends ConsumerState<CloudBrowserPage> {
  /// 目录导航栈：根为起始目录（相对源 root_path 的 '/'）。
  final List<String> _pathStack = ['/'];
  List<_RemoteEntry> _entries = const [];
  bool _loading = true;
  String? _error;
  String _sourceName = '';

  String get _path => _pathStack.last;
  bool get _atRoot => _pathStack.length <= 1;

  @override
  void initState() {
    super.initState();
    _loadSourceName();
    _load();
  }

  Future<void> _loadSourceName() async {
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final raw = await listRemoteSources(dbPath: dbPath);
      final sources = (jsonDecode(raw) as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      final match = sources
          .where((source) => source['id'] == widget.sourceId)
          .firstOrNull;
      if (mounted && match != null) {
        setState(() => _sourceName = match['name']?.toString() ?? '');
      }
    } catch (_) {
      // 名称仅用于展示，加载失败不影响浏览。
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final raw = await remoteBrowseDirectory(
        dbPath: dbPath,
        sourceId: widget.sourceId,
        path: _path,
      );
      final entries = (jsonDecode(raw) as List)
          .map((value) => _RemoteEntry.fromJson(value as Map<String, dynamic>))
          .where((entry) => entry.isDir || _isAudioPath(entry.remotePath))
          .toList();
      // 目录在前、文件在后，各自按名称排序，浏览顺序稳定。
      entries.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  void _openDir(_RemoteEntry entry) {
    setState(() => _pathStack.add(entry.remotePath));
    _load();
  }

  void _goUp() {
    if (_atRoot) return;
    setState(() => _pathStack.removeLast());
    _load();
  }

  /// remote:// URI：源 id + 相对 root_path 的远程路径（与 Rust
  /// `RemoteFileEntry::remote_uri` 同构）。
  String _remoteUri(_RemoteEntry entry) => 'remote://${widget.sourceId}'
      '${entry.remotePath.startsWith('/') ? '' : '/'}${entry.remotePath}';

  Song _songFromEntry(_RemoteEntry entry) {
    final (title, artist) = _splitTitleArtist(entry.name);
    final album = _albumFromPath(entry.remotePath);
    final dot = entry.name.lastIndexOf('.');
    final format = dot > 0 ? entry.name.substring(dot + 1).toLowerCase() : '';
    return Song(
      path: _remoteUri(entry),
      title: title,
      artist: artist,
      album: album,
      albumKey: '${album.toLowerCase()}::${artist.toLowerCase()}',
      duration: 0,
      format: format,
    );
  }

  List<_RemoteEntry> get _audioEntries =>
      _entries.where((entry) => !entry.isDir).toList();

  void _playAt(int index) {
    final songs = _audioEntries.map(_songFromEntry).toList();
    if (songs.isEmpty) return;
    ref.read(libraryProvider.notifier).playList(songs, index);
  }

  Future<void> _cacheEntry(_RemoteEntry entry) async {
    final uri = _remoteUri(entry);
    final dbPath = await ref.read(dbPathProvider.future);
    final dataDir = await ref.read(appDataDirProvider.future);
    if (mounted) {
      XyNotice.show(context, message: '开始缓存「${entry.name}」…');
    }
    try {
      await precacheRemoteSong(
        dbPath: dbPath,
        cacheRoot: p.join(dataDir, 'remote-cache'),
        remoteUri: uri,
      );
      if (mounted) {
        XyNotice.show(
          context,
          message: '「${entry.name}」缓存完成，可离线播放',
          type: XyNoticeType.success,
        );
      }
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '缓存失败：$error',
          type: XyNoticeType.error,
        );
      }
    }
  }

  void _showEntryMenu(_RemoteEntry entry, int index) {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${_formatSize(entry.size)}${entry.modifiedAt != null ? ' · ${entry.modifiedAt}' : ''}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: const Text('播放'),
              onTap: () {
                Navigator.pop(context);
                _playAt(index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_for_offline_outlined),
              title: const Text('缓存到本地'),
              subtitle: const Text('下载后可离线播放'),
              onTap: () {
                Navigator.pop(context);
                unawaited(_cacheEntry(entry));
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dirName = _atRoot
        ? (_sourceName.isEmpty ? '网盘' : _sourceName)
        : (_path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? _path);

    return PopScope(
      canPop: _atRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goUp();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(dirName, overflow: TextOverflow.ellipsis),
              if (!_atRoot)
                Text(
                  _path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: '返回上级目录',
              onPressed: _atRoot ? null : _goUp,
              icon: const Icon(Icons.arrow_upward_rounded),
            ),
            IconButton(
              tooltip: '刷新',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: _buildBody(scheme),
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 44,
                color: scheme.onSurfaceVariant.withValues(alpha: .4),
              ),
              const SizedBox(height: 12),
              Text(
                '目录加载失败',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              FilledButton.tonalIcon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_open_rounded,
              size: 46,
              color: scheme.onSurfaceVariant.withValues(alpha: .4),
            ),
            const SizedBox(height: 10),
            const Text('空目录', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              '该目录下没有文件夹或音频文件',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    final audioIndexBase =
        _entries.where((entry) => entry.isDir).length;
    return ListView.builder(
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: 4,
        bottom: MediaQuery.paddingOf(context).bottom + 108,
      ),
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        if (entry.isDir) {
          return ListTile(
            leading: Icon(
              Icons.folder_rounded,
              color: scheme.primary.withValues(alpha: .85),
            ),
            title: Text(
              entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _openDir(entry),
          );
        }
        final audioIndex = index - audioIndexBase;
        final (title, artist) = _splitTitleArtist(entry.name);
        final current = ref.watch(
          playerProvider.select(
            (state) => state.current?.path == _remoteUri(entry),
          ),
        );
        return ListTile(
          leading: Icon(
            current
                ? Icons.graphic_eq_rounded
                : Icons.music_note_rounded,
            color: current
                ? scheme.primary
                : scheme.onSurfaceVariant.withValues(alpha: .7),
          ),
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: current ? FontWeight.w700 : FontWeight.w500,
              color: current ? scheme.primary : null,
            ),
          ),
          subtitle: Text(
            [
              if (artist.isNotEmpty) artist,
              _formatSize(entry.size),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          trailing: current
              ? Icon(Icons.volume_up_rounded, color: scheme.primary)
              : null,
          onTap: () => _playAt(audioIndex),
          onLongPress: () => _showEntryMenu(entry, audioIndex),
        );
      },
    );
  }
}
