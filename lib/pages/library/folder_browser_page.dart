import 'dart:io';

import 'package:flutter/material.dart';

import '../../src/widgets/top_notice.dart';

/// 自建目录浏览器（设计参考 MusicFree 的 fileSelector 页面）。
///
/// 用于选择本地音乐扫描目录：从共享存储根目录（Android 为
/// /storage/emulated/0）开始逐级浏览，确认当前目录后 pop 返回路径。
/// 相比系统 SAF 目录选择器（file_picker）：
/// - 返回的是真实文件系统路径，可直接交给 Rust 侧 WalkDir 扫描；
/// - 列目录与扫描走同一套权限（原生存储权限桥），不会出现
///   「选择器能浏览、扫描却 EACCES」的割裂；
/// - 规避 file_picker 在部分国产 ROM 上的兼容性问题。
///
/// 仅用于 Android；其他平台请在入口处回退 file_picker。
class FolderBrowserPage extends StatefulWidget {
  const FolderBrowserPage({super.key, this.initialFolder});

  /// 初始目录（默认共享存储根目录）。
  final String? initialFolder;

  @override
  State<FolderBrowserPage> createState() => _FolderBrowserPageState();
}

class _FolderBrowserPageState extends State<FolderBrowserPage> {
  /// Android 共享存储根目录。
  static const _androidRoot = '/storage/emulated/0';

  /// 目录内可见的音频扩展名（小写）。与 Rust 侧 SUPPORTED_LIBRARY_
  /// EXTENSIONS 对齐，另含设置页可选的 wma/ape/opus，宽松展示。
  static const _audioExtensions = {
    'aac', 'aif', 'aiff', 'flac', 'm4a', 'm4b', 'mp3', 'mp4',
    'oga', 'ogg', 'opus', 'wav', 'wma', 'ape',
  };

  late String _current;
  List<Directory> _entries = const [];
  List<File> _songFiles = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _current = widget.initialFolder ?? _androidRoot;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dirs = <Directory>[];
      final songs = <File>[];
      await for (final entity in Directory(_current).list()) {
        // 与 MusicFree 一致：读取失败的子项直接跳过，不让单个
        // 异常目录打断浏览。
        if (entity is Directory) {
          final name = entity.uri.pathSegments.isEmpty
              ? entity.path
              : entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (name.startsWith('.')) continue;
          dirs.add(entity);
        } else if (entity is File) {
          final name = entity.uri.pathSegments.isEmpty
              ? entity.path
              : entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (name.startsWith('.')) continue;
          final ext = name.contains('.')
              ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
              : '';
          if (_audioExtensions.contains(ext)) songs.add(entity);
        }
      }
      dirs.sort(
        (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
      );
      songs.sort(
        (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
      );
      if (!mounted) return;
      setState(() {
        _entries = dirs;
        _songFiles = songs;
        _loading = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '无法读取该目录：$e';
      });
    }
  }

  void _enter(Directory dir) {
    _current = dir.path;
    _load();
  }

  bool get _isRoot => _current == _androidRoot;

  void _up() {
    if (_isRoot) return;
    final parent = Directory(_current).parent.path;
    // 不越过共享存储根目录。
    _current = parent.length < _androidRoot.length ? _androidRoot : parent;
    _load();
  }

  String get _displayName {
    if (_isRoot) return '内部存储';
    final segments = Directory(_current)
        .uri
        .pathSegments
        .where((s) => s.isNotEmpty)
        .toList();
    return segments.isEmpty ? _current : segments.last;
  }

  void _confirm() {
    if (!Directory(_current).existsSync()) {
      XyNotice.show(context, message: '目录不存在');
      return;
    }
    Navigator.of(context).pop(_current);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_displayName),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(30),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _current,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.folder_off,
                            size: 48, color: scheme.onSurfaceVariant),
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  children: [
                    if (!_isRoot)
                      ListTile(
                        leading: Icon(Icons.arrow_upward,
                            color: scheme.onSurfaceVariant),
                        title: const Text('返回上一级'),
                        onTap: _up,
                      ),
                    ..._entries.map(
                      (dir) => ListTile(
                        leading: Icon(Icons.folder, color: scheme.primary),
                        title: Text(
                          dir.uri.pathSegments
                              .where((s) => s.isNotEmpty)
                              .last,
                        ),
                        onTap: () => _enter(dir),
                      ),
                    ),
                    // 与 MusicFree fileSelector 一致：目录下直接展示音频
                    // 文件（不可进入），让用户确认该文件夹里确实有歌。
                    ..._songFiles.map(
                      (file) => ListTile(
                        leading: Icon(Icons.music_note,
                            color: scheme.tertiary),
                        title: Text(
                          file.uri.pathSegments
                              .where((s) => s.isNotEmpty)
                              .last,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                        dense: true,
                      ),
                    ),
                  ],
                ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton.icon(
            onPressed: _loading ? null : _confirm,
            icon: const Icon(Icons.check),
            label: Text('选择「$_displayName」'),
          ),
        ),
      ),
    );
  }
}
