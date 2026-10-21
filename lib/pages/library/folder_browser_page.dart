import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../src/widgets/top_notice.dart';

/// 自建目录浏览器（设计参考 MusicFree 的 fileSelector 页面）。
///
/// 用于选择本地音乐扫描目录：先在「存储选择」层挑内部存储或 SD 卡
/// （设备挂载了可读外部存储卷时才展示），再逐级浏览目录，确认当前
/// 目录后 pop 返回路径。相比系统 SAF 目录选择器（file_picker）：
/// - 返回的是真实文件系统路径，可直接交给 Rust 侧 WalkDir 扫描；
/// - 列目录与扫描走同一套权限（原生存储权限桥），不会出现
///   「选择器能浏览、扫描却 EACCES」的割裂；
/// - 规避 file_picker 在部分国产 ROM 上的兼容性问题。
///
/// 仅用于 Android；其他平台请在入口处回退 file_picker。
class FolderBrowserPage extends StatefulWidget {
  const FolderBrowserPage({super.key, this.initialFolder});

  /// 初始目录（默认停在存储选择层）。
  final String? initialFolder;

  @override
  State<FolderBrowserPage> createState() => _FolderBrowserPageState();
}

class _FolderBrowserPageState extends State<FolderBrowserPage> {
  /// Android 主存储（内部存储）根目录。
  static const _primaryRoot = '/storage/emulated/0';

  /// 外置 SD 卡挂载目录名形如 /storage/XXXX-XXXX（FUSE 卷 UUID）。
  static final _sdVolumePattern = RegExp(r'^[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}$');

  /// 目录内可见的音频扩展名（小写）。与 Rust 侧 SUPPORTED_LIBRARY_
  /// EXTENSIONS 对齐，另含设置页可选的 wma/ape/opus，宽松展示。
  static const _audioExtensions = {
    'aac', 'aif', 'aiff', 'flac', 'm4a', 'm4b', 'mp3', 'mp4',
    'oga', 'ogg', 'opus', 'wav', 'wma', 'ape',
  };

  /// 可选存储根列表：主存储 + 挂载的 SD 卡卷（无 SD 卡时仅主存储）。
  /// 异步初始化——部分 ROM（华为等）限制第三方 app 直接枚举 /storage
  /// 目录，需原生 getExternalFilesDirs 补充 SD 卡卷。
  List<Directory> _roots = const [];
  bool _rootsReady = false;

  /// 当前浏览目录；null 表示停在顶层「存储选择」层。
  String? _current;
  List<Directory> _entries = const [];
  List<File> _songFiles = const [];
  bool _loading = true;
  String? _error;

  /// 枚举可选存储根（同步部分）：主存储 + /storage 下 XXXX-XXXX 形式
  /// 的外部卷。部分 ROM 限制枚举 /storage，拿不到的卷由原生补充。
  List<Directory> _enumerateRoots() {
    final roots = <Directory>[];
    final primary = Directory(_primaryRoot);
    if (primary.existsSync()) roots.add(primary);
    try {
      for (final entity in Directory('/storage').listSync()) {
        if (entity is! Directory) continue;
        final name = entity.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .last;
        if (!_sdVolumePattern.hasMatch(name)) continue;
        roots.add(entity);
      }
    } catch (_) {
      // /storage 枚举失败不影响主存储可用性。
    }
    return roots;
  }

  /// 初始化存储根列表：先同步枚举 /storage（能直接枚举的 ROM 直接
  /// 拿到全部卷），再经原生 getStorageRoots（getExternalFilesDirs 推导）
  /// 补充遗漏的 SD 卡卷，按去重合并。
  Future<void> _initRoots() async {
    final roots = _enumerateRoots();
    try {
      final raw = await const MethodChannel(
        'com.xymusic.mobile/device_info',
      ).invokeMethod<List<dynamic>>('getStorageRoots');
      for (final path in raw ?? const <dynamic>[]) {
        final p = path.toString();
        if (p.isEmpty ||
            p == _primaryRoot ||
            roots.any((r) => r.path == p)) {
          continue;
        }
        // 卷名必须是 XXXX-XXXX 形式的物理卷（过滤误报的主存储卷根
        // /storage/emulated 等非卷路径）。
        final volumeName = p.split('/').where((s) => s.isNotEmpty).last;
        if (!_sdVolumePattern.hasMatch(volumeName)) continue;
        // 仅收录实际存在的卷目录（未挂载卷原生侧已过滤，这里兜底）。
        if (!Directory(p).existsSync()) continue;
        roots.add(Directory(p));
      }
    } catch (_) {
      // 原生通道失败时保留 /storage 枚举结果，不影响主存储。
    }
    if (!mounted) return;
    setState(() {
      _roots = roots;
      _rootsReady = true;
    });
    // 停在顶层存储选择层时，就绪后刷新一次列表。
    if (_current == null) _load();
  }

  @override
  void initState() {
    super.initState();
    _current = widget.initialFolder;
    _initRoots();
  }

  Future<void> _load() async {
    final current = _current;
    // 存储选择层：无目录内容可列。
    if (current == null) {
      setState(() {
        _entries = const [];
        _songFiles = const [];
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dirs = <Directory>[];
      final songs = <File>[];
      await for (final entity in Directory(current).list()) {
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

  bool get _isRoot =>
      _current != null && _roots.any((r) => r.path == _current);

  void _up() {
    final current = _current;
    if (current == null) return;
    // 已在存储根：返回顶层存储选择层。
    if (_isRoot) {
      setState(() => _current = null);
      _load();
      return;
    }
    final parent = Directory(current).parent.path;
    // 不越过所属存储根目录。
    final root = _roots.firstWhere(
      (r) => current.startsWith(r.path),
      orElse: () => Directory(_primaryRoot),
    );
    _current = parent.length < root.path.length ? root.path : parent;
    _load();
  }

  String get _displayName {
    final current = _current;
    if (current == null) return '选择存储位置';
    if (current == _primaryRoot) return '内部存储';
    if (_isRoot) return 'SD卡';
    final segments = Directory(current)
        .uri
        .pathSegments
        .where((s) => s.isNotEmpty)
        .toList();
    return segments.isEmpty ? current : segments.last;
  }

  void _confirm() {
    final current = _current;
    if (current == null) return;
    if (!Directory(current).existsSync()) {
      XyNotice.show(context, message: '目录不存在');
      return;
    }
    Navigator.of(context).pop(current);
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
                _current ?? '请选择要浏览的存储位置',
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
      body: _current == null
          // 顶层存储选择：主存储 + 挂载的 SD 卡卷（无 SD 卡时仅主存储）。
          // 存储根就绪前（原生通道补充中）显示加载态。
          ? !_rootsReady
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  children: [
                    for (final root in _roots)
                      ListTile(
                        leading: Icon(
                          root.path == _primaryRoot
                              ? Icons.phone_android
                              : Icons.sd_card,
                          color: scheme.primary,
                        ),
                        title: Text(
                          root.path == _primaryRoot ? '内部存储' : 'SD卡',
                        ),
                        subtitle: Text(
                          root.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _enter(root),
                      ),
                  ],
                )
          : _loading
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
      bottomNavigationBar: Padding(
        // Shell 已把悬浮底栏/播放栏高度并入 padding.bottom（含系统安全
        // 区），直接用该值避让，不用 SafeArea 以免双重扣除安全区。
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          MediaQuery.paddingOf(context).bottom + 16,
        ),
        child: FilledButton.icon(
          onPressed: _loading || _current == null ? null : _confirm,
          icon: const Icon(Icons.check),
          label: Text(
            _current == null
                ? '请先选择存储位置'
                : '选择「$_displayName」',
          ),
        ),
      ),
    );
  }
}
