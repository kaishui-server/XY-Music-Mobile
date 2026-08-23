import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../src/core/db_path.dart';
import '../../src/plugins/plugin_metadata.dart';
import '../../src/plugins/plugin_runtime.dart';
import '../../src/rust/api.dart';
import '../../src/ui/xy_surface.dart';
import '../../src/ui/xy_theme.dart';
import '../../src/widgets/top_notice.dart';

class _PluginInfo {
  const _PluginInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.path,
    required this.enabled,
    this.author,
    this.sourceUrl,
  });

  final String id;
  final String name;
  final String version;
  final String path;
  final bool enabled;
  final String? author;
  final String? sourceUrl;
}

class _InstallSummary {
  const _InstallSummary({
    required this.installed,
    required this.skipped,
    required this.failed,
    required this.names,
    required this.errors,
  });

  final int installed;
  final int skipped;
  final int failed;
  final List<String> names;
  final List<String> errors;

  String get message {
    if (installed == 1 && skipped == 0 && failed == 0) {
      return '已安装并启用 ${names.first}';
    }
    final parts = <String>['成功 $installed 个'];
    if (skipped > 0) parts.add('跳过 $skipped 个');
    if (failed > 0) parts.add('失败 $failed 个');
    return parts.join('，');
  }
}

class _MutableInstallSummary {
  int installed = 0;
  int skipped = 0;
  int failed = 0;
  final names = <String>[];
  final errors = <String>[];

  _InstallSummary freeze() => _InstallSummary(
    installed: installed,
    skipped: skipped,
    failed: failed,
    names: List.unmodifiable(names),
    errors: List.unmodifiable(errors),
  );
}

class _PluginsNotifier extends AsyncNotifier<List<_PluginInfo>> {
  static const _enabledKey = 'mobileEnabledPlugins';
  static const _sourceUrlsKey = 'mobilePluginSourceUrlsV1';
  static const _maxPluginBytes = 5 * 1024 * 1024;
  static const _maxIndexItems = 100;

  @override
  Future<List<_PluginInfo>> build() => _load();

  Future<List<_PluginInfo>> _load() async {
    final dataDir = await ref.read(appDataDirProvider.future);
    final directory = Directory(p.join(dataDir, 'plugins'));
    if (!directory.existsSync()) return const [];
    final prefs = await SharedPreferences.getInstance();
    final enabled = (prefs.getStringList(_enabledKey) ?? const []).toSet();
    final sourceUrls = _readSourceUrls(prefs);
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((file) => p.extension(file.path).toLowerCase() == '.js')
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return files.map((file) {
      final script = file.readAsStringSync();
      final metadata = PluginMetadata.parse(script);
      final id = p.basenameWithoutExtension(file.path);
      return _PluginInfo(
        id: id,
        name: metadata.name ?? id,
        version: metadata.version ?? '未知版本',
        author: metadata.author,
        path: file.path,
        enabled: enabled.contains(id),
        sourceUrl: sourceUrls[id],
      );
    }).toList();
  }

  static Map<String, String> _readSourceUrls(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_sourceUrlsKey);
      if (raw == null) return {};
      return (jsonDecode(raw) as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, value.toString()),
      );
    } catch (_) {
      return {};
    }
  }

  static String _pluginId(String script, String origin) {
    final metadata = PluginMetadata.parse(script);
    final rawName =
        metadata.name ??
        p.basenameWithoutExtension(Uri.tryParse(origin)?.path ?? origin);
    final rawId = metadata.id ?? rawName;
    final normalized = rawId
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return normalized.isNotEmpty
        ? normalized
        : 'plugin-${_fnv1a(rawId).toRadixString(16)}';
  }

  static int _fnv1a(String input) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(input)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  static int _compareVersion(String left, String right) {
    final a = left.split(RegExp(r'[.-]'));
    final b = right.split(RegExp(r'[.-]'));
    final length = a.length > b.length ? a.length : b.length;
    for (var index = 0; index < length; index++) {
      final av = index < a.length ? int.tryParse(a[index]) ?? 0 : 0;
      final bv = index < b.length ? int.tryParse(b[index]) ?? 0 : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }

  static void _validateScript(String script) {
    final trimmed = script.trim();
    if (trimmed.isEmpty) throw Exception('插件内容为空');
    if (utf8.encode(script).length > _maxPluginBytes) {
      throw Exception('插件超过 5 MB 安全限制');
    }
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('<!doctype html') || lower.startsWith('<html')) {
      throw Exception('链接返回了网页，不是插件脚本');
    }
    final looksLikePlugin =
        lower.contains('@name') ||
        lower.contains('module.exports') ||
        lower.contains('export default') ||
        lower.contains('platform') ||
        lower.contains('musicfree') ||
        lower.contains('lx.');
    if (!looksLikePlugin) throw Exception('无法识别受支持的插件格式');
  }

  Future<String> _downloadText(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw Exception('请输入有效的 HTTP 或 HTTPS 地址');
    }
    final responseJson = await pluginHttpRequest(
      method: 'GET',
      url: uri.toString(),
      headersJson: const JsonEncoder().convert({'Accept': '*/*'}),
      timeout: BigInt.from(20),
      follow: 10,
    );
    final response = jsonDecode(responseJson) as Map<String, dynamic>;
    final status = (response['status'] as num?)?.toInt() ?? 0;
    if (status < 200 || status >= 300) throw Exception('下载失败：HTTP $status');
    final body = response['body'] as String? ?? '';
    if (body.isEmpty) throw Exception('服务器返回了空内容');
    return body;
  }

  Future<bool> _persistScript(
    String script,
    String origin,
    _MutableInstallSummary summary, {
    String? displayName,
    String? displayVersion,
  }) async {
    _validateScript(script);
    final metadata = PluginMetadata.parse(script);
    final id = _pluginId(script, origin);
    final name = displayName?.trim().isNotEmpty == true
        ? displayName!.trim()
        : (metadata.name ?? id);
    final version = displayVersion?.trim().isNotEmpty == true
        ? displayVersion!.trim()
        : (metadata.version ?? '0');
    final existing = state.valueOrNull
        ?.where((item) => item.id == id || item.name == name)
        .firstOrNull;
    if (existing != null && _compareVersion(version, existing.version) <= 0) {
      summary.skipped++;
      return false;
    }

    final dataDir = await ref.read(appDataDirProvider.future);
    await savePluginScript(dataDir: dataDir, id: id, script: script);
    final prefs = await SharedPreferences.getInstance();
    final enabled = (prefs.getStringList(_enabledKey) ?? const []).toSet()
      ..add(id);
    await prefs.setStringList(_enabledKey, enabled.toList());
    if (origin.startsWith('http://') || origin.startsWith('https://')) {
      final sources = _readSourceUrls(prefs)..[id] = origin;
      await prefs.setString(_sourceUrlsKey, jsonEncode(sources));
    }
    summary.installed++;
    summary.names.add(name);
    return true;
  }

  Future<_InstallSummary> installFromUrl(String url) async {
    final summary = _MutableInstallSummary();
    final content = await _downloadText(url);
    final trimmed = content.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        final dynamic rawItems = decoded is List
            ? decoded
            : decoded is Map<String, dynamic>
            ? (decoded['plugins'] ?? decoded['plugin'])
            : null;
        if (rawItems is List && rawItems.isNotEmpty) {
          final base = Uri.parse(url);
          for (final raw in rawItems.take(_maxIndexItems)) {
            if (raw is! Map) continue;
            final item = Map<String, dynamic>.from(raw);
            final rawUrl = item['url']?.toString().trim() ?? '';
            if (rawUrl.isEmpty) continue;
            final pluginUrl = base.resolve(rawUrl).toString();
            try {
              final script = await _downloadText(pluginUrl);
              await _persistScript(
                script,
                pluginUrl,
                summary,
                displayName: item['name']?.toString(),
                displayVersion: item['version']?.toString(),
              );
            } catch (error) {
              summary.failed++;
              summary.errors.add('${item['name'] ?? pluginUrl}：$error');
            }
          }
          state = AsyncData(await _load());
          ref.invalidate(enabledMusicPluginsProvider);
          return summary.freeze();
        }
      } catch (_) {
        // 不是插件索引时，继续按单个脚本处理并给出准确的格式错误。
      }
    }

    try {
      await _persistScript(content, url, summary);
    } catch (error) {
      summary.failed++;
      summary.errors.add(error.toString());
    }
    state = AsyncData(await _load());
    ref.invalidate(enabledMusicPluginsProvider);
    return summary.freeze();
  }

  Future<_InstallSummary> importPlugin() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['js'],
    );
    final path = result?.files.single.path;
    if (path == null) {
      return const _InstallSummary(
        installed: 0,
        skipped: 0,
        failed: 0,
        names: [],
        errors: [],
      );
    }
    final summary = _MutableInstallSummary();
    try {
      final script = await readPluginFile(path: path);
      await _persistScript(script, path, summary);
    } catch (error) {
      summary.failed++;
      summary.errors.add(error.toString());
    }
    state = AsyncData(await _load());
    ref.invalidate(enabledMusicPluginsProvider);
    return summary.freeze();
  }

  Future<void> toggle(_PluginInfo plugin, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = (prefs.getStringList(_enabledKey) ?? const []).toSet();
    value ? enabled.add(plugin.id) : enabled.remove(plugin.id);
    await prefs.setStringList(_enabledKey, enabled.toList());
    state = AsyncData(await _load());
    ref.invalidate(enabledMusicPluginsProvider);
  }

  Future<_InstallSummary> updatePlugin(_PluginInfo plugin) async {
    final url = plugin.sourceUrl;
    if (url == null || url.isEmpty) throw Exception('本地导入的插件没有在线更新地址');
    return installFromUrl(url);
  }

  Future<void> remove(_PluginInfo plugin) async {
    await removeMany([plugin]);
  }

  Future<void> removeMany(Iterable<_PluginInfo> plugins) async {
    final targets = plugins.toList(growable: false);
    if (targets.isEmpty) return;
    for (final plugin in targets) {
      try {
        final file = File(plugin.path);
        if (file.existsSync()) await file.delete();
      } catch (_) {
        // 继续删除其它插件，最后以刷新后的实际列表为准。
      }
    }
    final prefs = await SharedPreferences.getInstance();
    final ids = targets.map((plugin) => plugin.id).toSet();
    final enabled = (prefs.getStringList(_enabledKey) ?? const []).toSet()
      ..removeAll(ids);
    await prefs.setStringList(_enabledKey, enabled.toList());
    final sources = _readSourceUrls(prefs);
    for (final id in ids) {
      sources.remove(id);
    }
    await prefs.setString(_sourceUrlsKey, jsonEncode(sources));
    state = AsyncData(await _load());
    ref.invalidate(enabledMusicPluginsProvider);
  }

  Future<void> removeAll() async {
    await removeMany(state.valueOrNull ?? const []);
  }
}

final _pluginsProvider =
    AsyncNotifierProvider<_PluginsNotifier, List<_PluginInfo>>(
      _PluginsNotifier.new,
    );

class PluginsPage extends ConsumerStatefulWidget {
  const PluginsPage({super.key});

  @override
  ConsumerState<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends ConsumerState<PluginsPage> {
  final TextEditingController _installUrlController = TextEditingController();
  String _query = '';
  bool _busy = false;
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};

  @override
  void dispose() {
    _installUrlController.dispose();
    super.dispose();
  }

  void _showResult(_InstallSummary result) {
    if (!mounted ||
        (result.installed == 0 && result.skipped == 0 && result.failed == 0)) {
      return;
    }
    final details = result.errors.isEmpty
        ? ''
        : '\n${result.errors.take(2).join('\n')}';
    XyNotice.show(
      context,
      message: '${result.message}$details',
      type: result.errors.isEmpty ? XyNoticeType.success : XyNoticeType.warning,
    );
  }

  Future<void> _importLocal() async {
    setState(() => _busy = true);
    try {
      _showResult(await ref.read(_pluginsProvider.notifier).importPlugin());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _installFromUrl() async {
    final controller = _installUrlController..clear();
    final url = await showDialog<String>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          sheetContext,
                        ).colorScheme.primary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Icon(
                        Icons.language_rounded,
                        color: Theme.of(sheetContext).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 11),
                    const Expanded(
                      child: Text(
                        '从网络安装插件',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '支持单个 JS 插件直链，以及包含 plugins 数组的 JSON 插件索引。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '插件地址',
                    hintText: 'https://example.com/plugin.js',
                    prefixIcon: Icon(Icons.link_rounded),
                  ),
                  onSubmitted: (value) => Navigator.pop(sheetContext, value),
                ),
                const SizedBox(height: 12),
                const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 17,
                      color: Color(0xFFEC9A29),
                    ),
                    SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '插件拥有网络访问能力，请只安装你信任的来源。',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF9A6A29),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: () =>
                            Navigator.pop(sheetContext, controller.text.trim()),
                        icon: const Icon(Icons.download_rounded),
                        label: const Text('下载并安装'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (url == null || url.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(_pluginsProvider.notifier)
          .installFromUrl(url);
      _showResult(result);
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '安装失败：$error',
          type: XyNoticeType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _update(_PluginInfo plugin) async {
    setState(() => _busy = true);
    try {
      _showResult(
        await ref.read(_pluginsProvider.notifier).updatePlugin(plugin),
      );
    } catch (error) {
      if (mounted) {
        XyNotice.show(context, message: '$error', type: XyNoticeType.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(_PluginInfo plugin) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除插件'),
        content: Text('确定删除“${plugin.name}”吗？'),
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
      await ref.read(_pluginsProvider.notifier).remove(plugin);
    }
  }

  Future<void> _removeSelected(List<_PluginInfo> items) async {
    final selected = items
        .where((plugin) => _selectedIds.contains(plugin.id))
        .toList();
    if (selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('批量删除插件'),
        content: Text('确定删除选中的 ${selected.length} 个插件吗？'),
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
    setState(() => _busy = true);
    try {
      await ref.read(_pluginsProvider.notifier).removeMany(selected);
      if (mounted) {
        setState(() {
          _selectedIds.clear();
          _selectionMode = false;
        });
        XyNotice.show(context, message: '已删除 ${selected.length} 个插件');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeAll(List<_PluginInfo> items) async {
    if (items.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除全部插件'),
        content: Text('确定删除全部 ${items.length} 个插件吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('全部删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(_pluginsProvider.notifier).removeAll();
      if (mounted) {
        setState(() {
          _selectedIds.clear();
          _selectionMode = false;
        });
        XyNotice.show(context, message: '已删除全部插件');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plugins = ref.watch(_pluginsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('插件管理')),
      body: XyPageBackground(
        child: plugins.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('插件加载失败：$error')),
          data: (items) {
            _selectedIds.removeWhere(
              (id) => !items.any((plugin) => plugin.id == id),
            );
            final query = _query.trim().toLowerCase();
            final filtered = query.isEmpty
                ? items
                : items.where((item) {
                    return item.name.toLowerCase().contains(query) ||
                        item.id.toLowerCase().contains(query) ||
                        (item.author?.toLowerCase().contains(query) ?? false);
                  }).toList();
            return Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    const _SecurityNotice(),
                    const SizedBox(height: 14),
                    _InstallPanel(
                      busy: _busy,
                      onOnline: _installFromUrl,
                      onLocal: _importLocal,
                    ),
                    const SizedBox(height: 22),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '已安装插件',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        Text(
                          '${items.length} 个',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    if (items.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                    _selectionMode = !_selectionMode;
                                    if (!_selectionMode) _selectedIds.clear();
                                  }),
                            icon: Icon(
                              _selectionMode
                                  ? Icons.close_rounded
                                  : Icons.checklist_rounded,
                            ),
                            label: Text(_selectionMode ? '退出选择' : '批量管理'),
                          ),
                          if (_selectionMode)
                            OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => setState(() {
                                      final visibleIds = filtered
                                          .map((plugin) => plugin.id)
                                          .toSet();
                                      if (visibleIds.every(
                                        _selectedIds.contains,
                                      )) {
                                        _selectedIds.removeAll(visibleIds);
                                      } else {
                                        _selectedIds.addAll(visibleIds);
                                      }
                                    }),
                              icon: const Icon(Icons.select_all_rounded),
                              label: const Text('全选当前结果'),
                            ),
                          if (_selectionMode)
                            FilledButton.icon(
                              onPressed: _busy || _selectedIds.isEmpty
                                  ? null
                                  : () => _removeSelected(items),
                              icon: const Icon(Icons.delete_outline_rounded),
                              label: Text('删除选中（${_selectedIds.length}）'),
                            ),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : () => _removeAll(items),
                            icon: const Icon(Icons.delete_sweep_outlined),
                            label: const Text('删除全部'),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    TextField(
                      onChanged: (value) => setState(() => _query = value),
                      decoration: const InputDecoration(
                        hintText: '搜索插件名称、作者或 ID',
                        prefixIcon: Icon(Icons.search_rounded),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (items.isEmpty)
                      _EmptyPlugins(
                        onOnline: _installFromUrl,
                        onLocal: _importLocal,
                      )
                    else if (filtered.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 50),
                        child: Center(child: Text('没有匹配的插件')),
                      )
                    else
                      for (final plugin in filtered) ...[
                        _PluginCard(
                          plugin: plugin,
                          busy: _busy,
                          selectable: _selectionMode,
                          selected: _selectedIds.contains(plugin.id),
                          onSelect: (value) => setState(() {
                            value
                                ? _selectedIds.add(plugin.id)
                                : _selectedIds.remove(plugin.id);
                          }),
                          onToggle: (value) => ref
                              .read(_pluginsProvider.notifier)
                              .toggle(plugin, value),
                          onUpdate: plugin.sourceUrl == null
                              ? null
                              : () => _update(plugin),
                          onRemove: () => _remove(plugin),
                        ),
                        const SizedBox(height: 10),
                      ],
                  ],
                ),
                if (_busy)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: LinearProgressIndicator(
                      minHeight: 2,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SecurityNotice extends StatelessWidget {
  const _SecurityNotice();

  @override
  Widget build(BuildContext context) {
    return XyPanel(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.security_rounded,
            size: 21,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '插件脚本可访问网络并参与在线音乐解析。关闭插件会保留文件，但不会将其列为启用来源。',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InstallPanel extends StatelessWidget {
  const _InstallPanel({
    required this.busy,
    required this.onOnline,
    required this.onLocal,
  });

  final bool busy;
  final VoidCallback onOnline;
  final VoidCallback onLocal;

  @override
  Widget build(BuildContext context) {
    return XyPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '安装插件',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 5),
          Text(
            '与电脑端一致，支持网络直链、JSON 插件索引和本地文件。',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy ? null : onOnline,
                  icon: const Icon(Icons.language_rounded),
                  label: const Text('在线安装'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : onLocal,
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('本地导入'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyPlugins extends StatelessWidget {
  const _EmptyPlugins({required this.onOnline, required this.onLocal});

  final VoidCallback onOnline;
  final VoidCallback onLocal;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(
            Icons.extension_off_outlined,
            size: 54,
            color: Theme.of(
              context,
            ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          const Text('还没有安装插件', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            '从网络地址或本地文件安装兼容插件',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TextButton(onPressed: onOnline, child: const Text('输入插件地址')),
        ],
      ),
    );
  }
}

class _PluginCard extends StatelessWidget {
  const _PluginCard({
    required this.plugin,
    required this.busy,
    required this.selectable,
    required this.selected,
    required this.onSelect,
    required this.onToggle,
    required this.onUpdate,
    required this.onRemove,
  });

  final _PluginInfo plugin;
  final bool busy;
  final bool selectable;
  final bool selected;
  final ValueChanged<bool> onSelect;
  final ValueChanged<bool> onToggle;
  final VoidCallback? onUpdate;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 12, 7, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(XyRadii.large),
        border: Border.all(
          color: dark ? XyColors.darkBorder : XyColors.lightBorder,
        ),
      ),
      child: Row(
        children: [
          if (selectable)
            Checkbox(
              value: selected,
              onChanged: busy ? null : (value) => onSelect(value ?? false),
            ),
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              Icons.extension_rounded,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plugin.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    'v${plugin.version}',
                    if (plugin.author?.isNotEmpty == true) plugin.author!,
                    plugin.sourceUrl == null ? '本地' : '在线',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: plugin.enabled, onChanged: busy ? null : onToggle),
          PopupMenuButton<String>(
            enabled: !busy,
            onSelected: (value) {
              if (value == 'update') onUpdate?.call();
              if (value == 'remove') onRemove();
            },
            itemBuilder: (context) => [
              if (onUpdate != null)
                const PopupMenuItem(value: 'update', child: Text('检查并安装更新')),
              const PopupMenuItem(value: 'remove', child: Text('卸载插件')),
            ],
          ),
        ],
      ),
    );
  }
}
