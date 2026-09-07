import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../src/core/db_path.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/top_notice.dart';

/// 云端音乐：网盘连接管理。
///
/// 参考 musicxx 的连接模型：添加 Alist/OpenList 服务器连接（名称/地址/
/// 账号密码/起始目录），点击连接进入网盘文件浏览器，浏览目录并直接
/// 播放音频（remote:// URI 流式播放，长按可缓存离线）。
/// 旧的「挂载同步入库」模式已移除，云端歌曲仅在文件浏览器内播放。
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
  });

  final String id;
  final String name;
  final String baseUrl;
  final String? username;
  final String rootPath;

  factory _CloudSource.fromJson(Map<String, dynamic> json) => _CloudSource(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    baseUrl: json['baseUrl'] as String? ?? '',
    username: json['username'] as String?,
    rootPath: json['rootPath'] as String? ?? '/',
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
  Future<void> _remove(_CloudSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除网盘连接'),
        content: Text(
          '确定移除“${source.name}”吗？网盘上的文件不会被删除，'
          '本地的播放缓存也会保留。',
        ),
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('云端音乐'),
        actions: [
          IconButton(
            tooltip: '连接网盘方法',
            onPressed: _showGuide,
            icon: const Icon(Icons.help_outline),
          ),
          IconButton(
            tooltip: '添加网盘连接',
            onPressed: () => _showAddSheet(),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(_cloudSourcesProvider);
          await ref.read(_cloudSourcesProvider.future);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
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
                        onOpen: () => context.push(
                          '/cloud-music/browse/${source.id}',
                        ),
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
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 添加 / 编辑连接：填写 Alist/OpenList 凭据表单
  // -------------------------------------------------------------------------

  Future<void> _showAddSheet() async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      useRootNavigator: true,
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
      useRootNavigator: true,
      showDragHandle: true,
      builder: (context) => _SourceEditorSheet(source: source),
    );
    if (saved == true) ref.invalidate(_cloudSourcesProvider);
  }

  Future<void> _showGuide() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (context) => const SingleChildScrollView(child: _GuideSheet()),
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
          const Text('还没有网盘连接', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 5),
          Text(
            '填写 Alist / OpenList 服务器地址\n连接后即可浏览并播放网盘音频',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          FilledButton.tonalIcon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加网盘连接'),
          ),
        ],
      ),
    );
  }
}

class _CloudSourceCard extends StatelessWidget {
  const _CloudSourceCard({
    required this.source,
    required this.onOpen,
    required this.onEdit,
    required this.onRemove,
  });
  final _CloudSource source;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(17),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(17),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
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
                IconButton(
                  tooltip: '编辑或移除',
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 20),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
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
                widget.source == null ? '添加网盘连接' : '编辑网盘连接',
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
                  labelText: '起始目录',
                  hintText: '/',
                  helperText: '打开连接时从该目录开始浏览（如 /music）',
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
// 连接指引
// ---------------------------------------------------------------------------

class _GuideSheet extends StatelessWidget {
  const _GuideSheet();

  static const _steps = <(String, String)>[
    (
      '方式一：直连 Alist / OpenList',
      '在电脑、NAS 或服务器上部署 Alist（或 OpenList），在后台「存储」中'
          '添加百度网盘、夸克、阿里云盘、115 等网盘后，直接填服务器地址连接。',
    ),
    (
      '账号与起始目录',
      'Alist 登录账号填入用户名密码；游客可访问的站点可留空。'
      '「起始目录」决定打开连接时进入的网盘目录。',
    ),
    (
      '浏览与播放',
      '保存后点击连接进入网盘文件浏览器，像文件管理器一样浏览目录，'
          '点击音频文件即可流式播放，长按可缓存到本地离线播放。',
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
            '连接网盘听歌',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            '百度、夸克、阿里云盘等网盘不开放直接访问，'
            '通过 Alist / OpenList 桥接即可连接：',
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
