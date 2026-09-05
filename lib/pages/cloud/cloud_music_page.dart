import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../src/core/db_path.dart';
import '../../src/library/library_provider.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/top_notice.dart';

/// 云端音乐：搜索 + 源管理一体。
///
/// 直填 Alist/OpenList 服务器地址挂载自建网盘，同步后网盘音频进入
/// 音乐库（remote:// URI），本页就地搜索播放。
/// （TVBox 接口订阅与第三方站点挂载已暂时移除，仅保留自建网盘直连。）
class CloudMusicPage extends ConsumerStatefulWidget {
  const CloudMusicPage({super.key});

  @override
  ConsumerState<CloudMusicPage> createState() => _CloudMusicPageState();
}

class _CloudSource {
  const _CloudSource({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.username,
    required this.rootPath,
    required this.lastSyncAt,
    required this.lastSyncError,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String username;
  final String rootPath;
  final int? lastSyncAt;
  final String? lastSyncError;

  factory _CloudSource.fromJson(Map<String, dynamic> json) => _CloudSource(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    baseUrl: json['baseUrl'] as String? ?? '',
    username: json['username'] as String? ?? '',
    rootPath: json['rootPath'] as String? ?? '/',
    lastSyncAt: (json['lastSyncAt'] as num?)?.toInt(),
    lastSyncError: json['lastSyncError'] as String?,
  );
}

final _cloudSourcesProvider = FutureProvider.autoDispose<List<_CloudSource>>((
  ref,
) async {
  final dbPath = await ref.watch(dbPathProvider.future);
  final raw = await listRemoteSources(dbPath: dbPath);
  return (jsonDecode(raw) as List)
      .map((value) => _CloudSource.fromJson(value as Map<String, dynamic>))
      .toList();
});

final _cloudCacheProvider = FutureProvider.autoDispose<Map<String, dynamic>>((
  ref,
) async {
  final dataDir = await ref.watch(appDataDirProvider.future);
  final raw = await getRemoteCacheUsage(
    cacheRoot: p.join(dataDir, 'remote-cache'),
  );
  return jsonDecode(raw) as Map<String, dynamic>;
});

class _CloudMusicPageState extends ConsumerState<CloudMusicPage> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _syncing = {};
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) =>
      setState(() => _query = value.trim());

  /// 云端歌曲 = 音乐库中 remote:// URI 的歌曲（网盘挂载同步入库）。
  List<Song> get _cloudSongs {
    final songs = ref.read(libraryProvider).songs;
    return songs.where((song) => song.path.startsWith('remote://')).toList();
  }

  List<Song> get _filteredSongs {
    if (_query.isEmpty) return const [];
    final keyword = _query.toLowerCase();
    return _cloudSongs
        .where(
          (song) =>
              song.title.toLowerCase().contains(keyword) ||
              song.artist.toLowerCase().contains(keyword) ||
              song.album.toLowerCase().contains(keyword),
        )
        .toList();
  }

  Future<void> _sync(_CloudSource source) async {
    setState(() => _syncing.add(source.id));
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final dataDir = await ref.read(appDataDirProvider.future);
      final raw = await syncRemoteSource(
        dbPath: dbPath,
        cacheRoot: p.join(dataDir, 'remote-cache'),
        sourceId: source.id,
      );
      final result = jsonDecode(raw) as Map<String, dynamic>;
      await ref.read(libraryProvider.notifier).load();
      ref.invalidate(_cloudSourcesProvider);
      if (mounted) _message('同步完成：${result['parsedSongs'] ?? 0} 首歌曲');
    } catch (error) {
      if (mounted) _message('同步失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _syncing.remove(source.id));
    }
  }

  Future<void> _remove(_CloudSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除云端音乐源'),
        content: Text('确定移除“${source.name}”及其索引吗？网盘上的文件不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final dbPath = await ref.read(dbPathProvider.future);
    await removeRemoteSource(dbPath: dbPath, sourceId: source.id);
    await ref.read(libraryProvider.notifier).load();
    ref.invalidate(_cloudSourcesProvider);
  }

  Future<void> _clearCache() async {
    final dataDir = await ref.read(appDataDirProvider.future);
    await clearRemoteCache(cacheRoot: p.join(dataDir, 'remote-cache'));
    ref.invalidate(_cloudCacheProvider);
    if (mounted) _message('播放缓存已清理');
  }

  void _message(String message, {bool error = false}) => XyNotice.show(
    context,
    message: message,
    type: error ? XyNoticeType.error : XyNoticeType.success,
  );

  @override
  Widget build(BuildContext context) {
    final sources = ref.watch(_cloudSourcesProvider);
    final cache = ref.watch(_cloudCacheProvider).valueOrNull;
    final cacheBytes = (cache?['bytes'] as num?)?.toInt() ?? 0;
    final showResults = _query.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('云端音乐'),
        actions: [
          IconButton(
            tooltip: '挂载网盘方法',
            onPressed: _showMountGuide,
            icon: const Icon(Icons.help_outline),
          ),
          IconButton(
            tooltip: '添加网盘源',
            onPressed: () => _showAddSheet(),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索网盘歌曲（标题 / 歌手 / 专辑）',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: showResults
                ? _buildResults()
                : _buildManagement(sources, cacheBytes, cache),
          ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    final songs = _filteredSongs;
    if (songs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 46,
              color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: .4),
            ),
            const SizedBox(height: 10),
            const Text('没有匹配的网盘歌曲', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              '先在下方添加并同步网盘源',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return SongsListView(
      songs: songs,
      padding: EdgeInsets.only(
        left: 10,
        right: 10,
        bottom: MediaQuery.paddingOf(context).bottom + 148,
      ),
      onPlay: (list, i) =>
          ref.read(libraryProvider.notifier).playList(list, i),
    );
  }

  Widget _buildManagement(
    AsyncValue<List<_CloudSource>> sources,
    int cacheBytes,
    Map<String, dynamic>? cache,
  ) {
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(_cloudSourcesProvider);
        await ref.read(_cloudSourcesProvider.future);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 32),
        children: [
          sources.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(child: Text('加载失败：$error')),
            ),
            data: (items) => items.isEmpty
                ? _CloudEmpty(onAdd: () => _showAddSheet())
                : Column(
                    children: [
                      for (final source in items)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _CloudSourceCard(
                            source: source,
                            syncing: _syncing.contains(source.id),
                            onSync: () => _sync(source),
                            onEdit: () => _showEditSheet(source),
                            onRemove: () => _remove(source),
                          ),
                        ),
                    ],
                  ),
          ),
          _CacheCard(
            bytes: cacheBytes,
            files: (cache?['files'] as num?)?.toInt() ?? 0,
            onClear: cacheBytes > 0 ? _clearCache : null,
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 添加源：直接填写 Alist/OpenList 凭据表单
  // （TVBox 接口订阅与站点解析已暂时移除）
  // -------------------------------------------------------------------------

  Future<void> _showAddSheet() async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => const _SourceEditorSheet(),
    );
    if (added == true) ref.invalidate(_cloudSourcesProvider);
  }

  Future<void> _showEditSheet(_CloudSource source) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => _SourceEditorSheet(source: source),
    );
    if (saved == true) ref.invalidate(_cloudSourcesProvider);
  }

  Future<void> _showMountGuide() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => const SingleChildScrollView(child: _MountGuideSheet()),
    );
  }
}

// ---------------------------------------------------------------------------
// 空态与卡片
// ---------------------------------------------------------------------------

class _CloudEmpty extends StatelessWidget {
  const _CloudEmpty({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          Icon(
            Icons.cloud_outlined,
            size: 52,
            color: scheme.onSurfaceVariant.withValues(alpha: .4),
          ),
          const SizedBox(height: 12),
          const Text('还没有挂载网盘', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 5),
          Text(
            '填写 Alist / OpenList 服务器地址\n挂载后即可搜索播放网盘音频',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          FilledButton.tonalIcon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加网盘源'),
          ),
        ],
      ),
    );
  }
}

class _CloudSourceCard extends StatelessWidget {
  const _CloudSourceCard({
    required this.source,
    required this.syncing,
    required this.onSync,
    required this.onEdit,
    required this.onRemove,
  });
  final _CloudSource source;
  final bool syncing;
  final VoidCallback onSync;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: source.lastSyncError == null
              ? scheme.outlineVariant.withValues(alpha: .3)
              : scheme.error.withValues(alpha: .45),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0x20477BD6),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.cloud_queue, color: Color(0xFF477BD6)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      source.baseUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (value) =>
                    value == 'edit' ? onEdit() : onRemove(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('编辑')),
                  PopupMenuItem(value: 'remove', child: Text('移除')),
                ],
              ),
            ],
          ),
          if (source.lastSyncError != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 16, color: scheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      source.lastSyncError!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: scheme.error),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: syncing ? null : onSync,
              icon: syncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              label: Text(syncing ? '正在同步…' : '立即同步'),
            ),
          ),
        ],
      ),
    );
  }
}

class _CacheCard extends StatelessWidget {
  const _CacheCard({
    required this.bytes,
    required this.files,
    required this.onClear,
  });
  final int bytes;
  final int files;
  final VoidCallback? onClear;

  String _size(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    if (value < 1024 * 1024 * 1024) {
      return '${(value / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(value / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(17),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: const Color(0x20EC4141),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.storage_outlined, color: Color(0xFFEC4141)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '播放缓存',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  '${_size(bytes)} · $files 个文件',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onClear,
            child: const Text('清理'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 凭据表单：新增 / 编辑
// ---------------------------------------------------------------------------

class _SourceEditorSheet extends ConsumerStatefulWidget {
  const _SourceEditorSheet({this.source});

  final _CloudSource? source;

  @override
  ConsumerState<_SourceEditorSheet> createState() => _SourceEditorSheetState();
}

class _SourceEditorSheetState extends ConsumerState<_SourceEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _root;
  bool _obscure = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.source?.name ?? '我的网盘');
    _url = TextEditingController(text: widget.source?.baseUrl ?? '');
    _username = TextEditingController(text: widget.source?.username ?? '');
    _password = TextEditingController();
    _root = TextEditingController(text: widget.source?.rootPath ?? '/');
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _root.dispose();
    super.dispose();
  }

  Map<String, dynamic> _payload() => {
    if (widget.source != null) 'id': widget.source!.id,
    'name': _name.text.trim(),
    'provider': 'alist',
    'baseUrl': _url.text.trim(),
    'username': _username.text.trim().isEmpty ? null : _username.text.trim(),
    if (_password.text.isNotEmpty) 'password': _password.text,
    'rootPath': _root.text.trim().isEmpty ? '/' : _root.text.trim(),
  };

  Future<void> _test() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await alistTestConnection(sourceJson: jsonEncode(_payload()));
      if (mounted) {
        XyNotice.show(context, message: '连接成功', type: XyNoticeType.success);
      }
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '连接失败：$error',
          type: XyNoticeType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      await saveRemoteSource(
        dbPath: dbPath,
        sourceJson: jsonEncode(_payload()),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '保存失败：$error',
          type: XyNoticeType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.source == null ? '挂载网盘' : '编辑网盘源',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 18),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '名称',
                  prefixIcon: Icon(Icons.label_outline),
                  border: OutlineInputBorder(),
                ),
                validator: _required,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  helperText: 'Alist / OpenList 服务器根地址（如 http://192.168.1.10:5244）',
                  helperMaxLines: 2,
                  prefixIcon: Icon(Icons.link),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return '请输入服务器地址';
                  final uri = Uri.tryParse(value.trim());
                  return uri == null || !uri.hasScheme
                      ? '请输入完整的 http(s) 地址'
                      : null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _username,
                decoration: const InputDecoration(
                  labelText: '用户名（可选，游客访问留空）',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: widget.source == null ? '密码（可选）' : '密码（留空则保持不变）',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  ),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _root,
                decoration: const InputDecoration(
                  labelText: '音乐根目录',
                  hintText: '/',
                  helperText: '只索引该目录下的音频（如 /music）',
                  prefixIcon: Icon(Icons.folder_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _test,
                      icon: const Icon(Icons.wifi_tethering),
                      label: const Text('测试连接'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _save,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                      label: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '此项不能为空' : null;
}

// ---------------------------------------------------------------------------
// 挂载指引
// ---------------------------------------------------------------------------

class _MountGuideSheet extends StatelessWidget {
  const _MountGuideSheet();

  static const _steps = <(String, String)>[
    (
      '方式一：直连 Alist / OpenList',
      '在电脑、NAS 或服务器上部署 Alist（或 OpenList），在后台「存储」中'
          '添加百度网盘、夸克、阿里云盘、115 等网盘后，直接填服务器地址挂载。',
    ),
    (
      '账号与根目录',
      'Alist 登录账号填入用户名密码；游客可访问的站点可留空。'
          '「音乐根目录」限定只索引该目录下的音频文件。',
    ),
    (
      '同步与播放',
      '保存后点击「立即同步」建立索引，之后可像本地音乐一样搜索、'
          '浏览和播放网盘歌曲，播放过的文件自动进入本地缓存。',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '挂载网盘听歌',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            '百度、夸克、阿里云盘等网盘不开放直接访问，'
            '通过 Alist / OpenList 桥接即可挂载：',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < _steps.length; i++) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _steps[i].$1,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _steps[i].$2,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (i < _steps.length - 1) const SizedBox(height: 14),
          ],
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '提示：自建 Alist 需保持常开（推荐部署在 NAS、服务器或小主机上）；'
              '手机需与服务器处于同一网络或服务器具备公网访问。\n'
              '参考项目：github.com/alist-org/alist · github.com/OpenListTeam/OpenList',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
