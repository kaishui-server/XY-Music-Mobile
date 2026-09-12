import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/sync/cloud_data_viewer.dart';
import '../../src/widgets/top_notice.dart';
import 'cloud_data_widgets.dart';

/// 云端插件列表：只读展示云同步保存的插件，点击查看插件详情，
/// 支持单个删除与批量删除（仅操作云端数据）。
class CloudDataPluginsPage extends ConsumerStatefulWidget {
  const CloudDataPluginsPage({super.key});

  @override
  ConsumerState<CloudDataPluginsPage> createState() =>
      _CloudDataPluginsPageState();
}

class _CloudDataPluginsPageState extends ConsumerState<CloudDataPluginsPage> {
  CloudDataOverview? _overview;
  bool _loading = true;
  bool _deleting = false;
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final overview = await CloudDataViewer.fetchOverview(
        ref.read(authProvider.notifier),
      );
      if (!mounted) return;
      setState(() {
        _overview = overview;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is AuthException ? error.message : '$error';
      });
    }
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  Future<void> _delete(List<String> ids, String confirmMessage) async {
    if (_deleting || ids.isEmpty) return;
    final confirmed = await showCloudDeleteConfirm(
      context,
      title: '删除云端插件',
      message: confirmMessage,
    );
    if (!confirmed || !mounted) return;
    setState(() => _deleting = true);
    try {
      final deleted = await CloudDataViewer.deletePlugins(
        ref.read(authProvider.notifier),
        ids,
      );
      if (!mounted) return;
      XyNotice.show(context, message: '已删除 $deleted 个云端插件');
      _exitSelection();
      await _load();
    } catch (error) {
      if (!mounted) return;
      XyNotice.show(
        context,
        message: '删除失败：${error is AuthException ? error.message : '$error'}',
      );
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _deleteOne(CloudPluginSummary plugin) => _delete(
        [plugin.id],
        '确定删除云端插件「${plugin.name}」吗？其他设备将不再自动安装该插件。',
      );

  Future<void> _deleteSelected() {
    final overview = _overview;
    if (overview == null) return Future.value();
    final names = overview.plugins
        .where((p) => _selectedIds.contains(p.id))
        .map((p) => '「${p.name}」')
        .join('、');
    return _delete(
      _selectedIds.toList(),
      '确定删除选中的 ${_selectedIds.length} 个云端插件（$names）吗？其他设备将不再自动安装这些插件。',
    );
  }

  void _showPluginDetail(CloudPluginSummary plugin) {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      // 根 Navigator：详情面板覆盖悬浮底栏，避免底部内容被底栏遮挡。
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.extension, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      plugin.name,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _detailRow('插件 ID', plugin.id.isEmpty ? '-' : plugin.id),
              _detailRow(
                '类型',
                plugin.isLx ? 'LX 音源' : 'MusicFree 插件',
              ),
              _detailRow('版本', plugin.version.isEmpty ? '-' : plugin.version),
              _detailRow('作者', plugin.author.isEmpty ? '-' : plugin.author),
              _detailRow('同步状态', plugin.enabled ? '已启用' : '已禁用'),
              if (plugin.sourceUrl.isNotEmpty)
                _detailRow('来源地址', plugin.sourceUrl),
              const SizedBox(height: 12),
              Text(
                '插件脚本会在此账号其它设备登录时自动安装。',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              // 弹窗内的单删入口（与列表行垃圾桶等价）。
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _deleting ? null : () => _deleteOne(plugin),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: scheme.error,
                    side: BorderSide(color: scheme.error.withValues(alpha: 0.5)),
                  ),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('删除该云端插件'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(leading: const BackButton(), title: const Text('云端插件')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _buildList(scheme),
            ),
    );
  }

  Widget _buildList(ColorScheme scheme) {
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_error!, style: TextStyle(color: scheme.error)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      );
    }
    final plugins = _overview?.plugins ?? const [];
    if (plugins.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(32),
        children: [
          Center(
            child: Column(
              children: [
                Icon(Icons.extension_off, size: 56, color: scheme.onSurfaceVariant),
                const SizedBox(height: 12),
                Text('云端还没有插件', style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        12, 8, 12, MediaQuery.paddingOf(context).bottom + 104,
      ),
      // 首项是批量管理按钮栏。
      itemCount: plugins.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return CloudDataBatchBar(
            selectionMode: _selectionMode,
            selectedCount: _selectedIds.length,
            allSelected: _selectedIds.length >= plugins.length,
            busy: _deleting,
            onToggleMode: () => setState(() {
              _selectionMode = !_selectionMode;
              if (!_selectionMode) _selectedIds.clear();
            }),
            onToggleAll: () => setState(() {
              if (_selectedIds.length >= plugins.length) {
                _selectedIds.clear();
              } else {
                _selectedIds
                  ..clear()
                  ..addAll(plugins.map((p) => p.id));
              }
            }),
            onDeleteSelected: _deleteSelected,
          );
        }
        final plugin = plugins[index - 1];
        final selected = _selectedIds.contains(plugin.id);
        final subtitle = [
          if (plugin.version.isNotEmpty) 'v${plugin.version}',
          if (plugin.author.isNotEmpty) plugin.author,
          plugin.isLx ? 'LX 音源' : 'MusicFree',
        ].join(' · ');
        return ListTile(
          onTap: _deleting
              ? null
              : _selectionMode
                  ? () => setState(() {
                        if (selected) {
                          _selectedIds.remove(plugin.id);
                        } else {
                          _selectedIds.add(plugin.id);
                        }
                      })
                  : () => _showPluginDetail(plugin),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          leading: _selectionMode
              ? Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                )
              : CircleAvatar(
                  backgroundColor: plugin.enabled
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.extension,
                    color: plugin.enabled ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
          title: Text(
            plugin.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: _selectionMode
              ? null
              : IconButton(
                  onPressed: _deleting ? null : () => _deleteOne(plugin),
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                  tooltip: '删除',
                ),
        );
      },
    );
  }
}
