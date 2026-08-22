import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../src/core/db_path.dart';
import '../../src/library/library_provider.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/top_notice.dart';

class _RemoteSource {
  const _RemoteSource({
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

  factory _RemoteSource.fromJson(Map<String, dynamic> json) => _RemoteSource(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    baseUrl: json['baseUrl'] as String? ?? '',
    username: json['username'] as String? ?? '',
    rootPath: json['rootPath'] as String? ?? '/',
    lastSyncAt: (json['lastSyncAt'] as num?)?.toInt(),
    lastSyncError: json['lastSyncError'] as String?,
  );
}

final _remoteSourcesProvider = FutureProvider.autoDispose<List<_RemoteSource>>((
  ref,
) async {
  final dbPath = await ref.watch(dbPathProvider.future);
  final raw = await listRemoteSources(dbPath: dbPath);
  return (jsonDecode(raw) as List)
      .map((value) => _RemoteSource.fromJson(value as Map<String, dynamic>))
      .toList();
});

final _remoteCacheProvider = FutureProvider.autoDispose<Map<String, dynamic>>((
  ref,
) async {
  final dataDir = await ref.watch(appDataDirProvider.future);
  final raw = await getRemoteCacheUsage(
    cacheRoot: p.join(dataDir, 'remote-cache'),
  );
  return jsonDecode(raw) as Map<String, dynamic>;
});

class RemoteLibraryPage extends ConsumerStatefulWidget {
  const RemoteLibraryPage({super.key});

  @override
  ConsumerState<RemoteLibraryPage> createState() => _RemoteLibraryPageState();
}

class _RemoteLibraryPageState extends ConsumerState<RemoteLibraryPage> {
  final Set<String> _syncing = {};

  Future<void> _sync(_RemoteSource source) async {
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
      ref.invalidate(_remoteSourcesProvider);
      if (mounted) _message('同步完成：${result['parsedSongs'] ?? 0} 首歌曲');
    } catch (error) {
      if (mounted) _message('同步失败：$error');
    } finally {
      if (mounted) setState(() => _syncing.remove(source.id));
    }
  }

  Future<void> _remove(_RemoteSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除远程音乐库'),
        content: Text('确定移除“${source.name}”及其索引吗？服务器上的文件不会被删除。'),
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
    ref.invalidate(_remoteSourcesProvider);
  }

  Future<void> _clearCache() async {
    final dataDir = await ref.read(appDataDirProvider.future);
    await clearRemoteCache(cacheRoot: p.join(dataDir, 'remote-cache'));
    ref.invalidate(_remoteCacheProvider);
    if (mounted) _message('远程缓存已清理');
  }

  void _message(String message) =>
      XyNotice.show(context, message: message, type: XyNoticeType.success);

  @override
  Widget build(BuildContext context) {
    final sources = ref.watch(_remoteSourcesProvider);
    final cache = ref.watch(_remoteCacheProvider).valueOrNull;
    final cacheBytes = (cache?['bytes'] as num?)?.toInt() ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('远程音乐库'),
        actions: [
          IconButton(
            tooltip: '添加 WebDAV',
            onPressed: () => _showEditor(),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(_remoteSourcesProvider);
          await ref.read(_remoteSourcesProvider.future);
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
                child: _InfoCard(
                  icon: Icons.cloud_outlined,
                  title: 'WebDAV 音乐库',
                  subtitle: '连接 NAS 或网盘，索引歌曲后可像本地音乐一样浏览和播放。',
                  action: FilledButton.tonalIcon(
                    onPressed: () => _showEditor(),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('添加'),
                  ),
                ),
              ),
            ),
            sources.when(
              loading: () => const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => SliverFillRemaining(
                child: Center(child: Text('加载失败：$error')),
              ),
              data: (items) => items.isEmpty
                  ? const SliverFillRemaining(
                      hasScrollBody: false,
                      child: _RemoteEmpty(),
                    )
                  : SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      sliver: SliverList.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) => _RemoteSourceCard(
                          source: items[index],
                          syncing: _syncing.contains(items[index].id),
                          onSync: () => _sync(items[index]),
                          onEdit: () => _showEditor(items[index]),
                          onRemove: () => _remove(items[index]),
                        ),
                      ),
                    ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
                child: _InfoCard(
                  icon: Icons.storage_outlined,
                  title: '播放缓存',
                  subtitle:
                      '${_size(cacheBytes)} · ${cache?['files'] ?? 0} 个文件',
                  action: TextButton(
                    onPressed: cacheBytes > 0 ? _clearCache : null,
                    child: const Text('清理'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showEditor([_RemoteSource? source]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => _RemoteEditor(source: source),
    );
    if (saved == true) ref.invalidate(_remoteSourcesProvider);
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }
}

class _RemoteEditor extends ConsumerStatefulWidget {
  const _RemoteEditor({this.source});
  final _RemoteSource? source;

  @override
  ConsumerState<_RemoteEditor> createState() => _RemoteEditorState();
}

class _RemoteEditorState extends ConsumerState<_RemoteEditor> {
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
    _name = TextEditingController(text: widget.source?.name ?? '我的 WebDAV');
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
    'provider': 'webdav',
    'baseUrl': _url.text.trim(),
    'username': _username.text.trim().isEmpty ? null : _username.text.trim(),
    if (_password.text.isNotEmpty) 'password': _password.text,
    'rootPath': _root.text.trim().isEmpty ? '/' : _root.text.trim(),
  };

  Future<void> _test() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await webdavTestConnection(sourceJson: jsonEncode(_payload()));
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
  Widget build(BuildContext context) => Padding(
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
              widget.source == null ? '添加 WebDAV' : '编辑 WebDAV',
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
                hintText: 'https://example.com/dav',
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
                labelText: '用户名（可选）',
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
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                  ),
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

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '此项不能为空' : null;
}

class _RemoteSourceCard extends StatelessWidget {
  const _RemoteSourceCard({
    required this.source,
    required this.syncing,
    required this.onSync,
    required this.onEdit,
    required this.onRemove,
  });
  final _RemoteSource source;
  final bool syncing;
  final VoidCallback onSync;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(17),
      border: Border.all(
        color: source.lastSyncError == null
            ? Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .3)
            : Theme.of(context).colorScheme.error.withValues(alpha: .45),
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
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (value) => value == 'edit' ? onEdit() : onRemove(),
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
                Icon(
                  Icons.error_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    source.lastSyncError!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
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

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.action,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget action;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: const Color(0x20EC4141),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, color: const Color(0xFFEC4141)),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(width: 8),
      action,
    ],
  );
}

class _RemoteEmpty extends StatelessWidget {
  const _RemoteEmpty();
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.cloud_off_outlined,
          size: 52,
          color: Theme.of(
            context,
          ).colorScheme.onSurfaceVariant.withValues(alpha: .4),
        ),
        const SizedBox(height: 12),
        const Text('还没有远程音乐库', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 5),
        Text(
          '点击右上角 + 添加 WebDAV',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}
