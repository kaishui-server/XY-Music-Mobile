import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/sync/cloud_data_viewer.dart';
import '../../src/widgets/top_notice.dart';

/// 查看云数据：展示云端保存的歌单、收藏、插件与账号信息概览，
/// 点击各入口进入对应的只读详情页，支持一键清空云端数据。
class CloudDataPage extends ConsumerStatefulWidget {
  const CloudDataPage({super.key});

  @override
  ConsumerState<CloudDataPage> createState() => _CloudDataPageState();
}

class _CloudDataPageState extends ConsumerState<CloudDataPage> {
  CloudDataOverview? _overview;
  bool _loading = true;
  bool _clearing = false;
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

  Future<void> _clearCloudData() async {
    final overview = _overview;
    if (overview == null || _clearing) return;
    final stats = overview.stats;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空云端数据'),
        content: Text(
          '将删除云端保存的 ${stats.playlistCount} 个歌单（${stats.songTotal} 首歌曲）、'
          '${stats.favoriteCount} 首收藏、${stats.pluginCount} 个插件及设置快照。\n\n'
          '此操作不可恢复，其他设备的云同步数据也会一并丢失，确定继续吗？',
        ),
        actions: [
          TextButton(
            // 默认焦点在取消，防止误触。
            autofocus: true,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('全部清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      final cleared = await CloudDataViewer.clearCloudData(
        ref.read(authProvider.notifier),
      );
      if (!mounted) return;
      XyNotice.show(
        context,
        message: cleared ? '已清空云端数据' : '云端本来就没有数据',
      );
      await _load();
    } catch (error) {
      if (!mounted) return;
      XyNotice.show(
        context,
        message: '清空失败：${error is AuthException ? error.message : '$error'}',
      );
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(leading: const BackButton(), title: const Text('查看云数据')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(
                  left: 16,
                  top: 20,
                  right: 16,
                  // 有播放时避开悬浮迷你播放栏（64 高 + 20 距底 + 余量）。
                  bottom: MediaQuery.paddingOf(context).bottom + 104,
                ),
                children: [
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.cloud_off, color: scheme.error),
                          const SizedBox(width: 12),
                          Expanded(child: Text(_error!)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                  ] else ...[
                    _buildSummaryCard(scheme),
                    const SizedBox(height: 20),
                    _buildEntries(scheme),
                    // 云端完全没有数据时隐藏清空入口。
                    if (_overview?.hasData == true) ...[
                      const SizedBox(height: 28),
                      _buildClearButton(scheme),
                    ],
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildSummaryCard(ColorScheme scheme) {
    final overview = _overview!;
    final stats = overview.stats;
    final lastUpload = overview.playlistsUploadedAt.isNotEmpty
        ? overview.playlistsUploadedAt
        : '从未上传';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_outlined, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  overview.hasData ? '上次上传：$lastUpload' : '云端暂无同步数据',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _statItem(scheme, Icons.queue_music, '${stats.playlistCount}', '歌单'),
              ),
              Expanded(
                child: _statItem(scheme, Icons.music_note, '${stats.songTotal}', '歌曲'),
              ),
              Expanded(
                child: _statItem(scheme, Icons.favorite, '${stats.favoriteCount}', '收藏'),
              ),
              Expanded(
                child: _statItem(scheme, Icons.extension, '${stats.pluginCount}', '插件'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statItem(ColorScheme scheme, IconData icon, String value, String label) {
    return Column(
      children: [
        Icon(icon, size: 20, color: scheme.primary),
        const SizedBox(height: 6),
        Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _buildEntries(ColorScheme scheme) {
    final overview = _overview!;
    final stats = overview.stats;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '云端数据',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        _entryCard(
          scheme,
          icon: Icons.queue_music,
          title: '歌单',
          subtitle: '${stats.playlistCount} 个歌单 · ${stats.songTotal} 首歌曲',
          onTap: () => context.push('/account/cloud-sync/cloud-data/playlists'),
        ),
        const SizedBox(height: 10),
        _entryCard(
          scheme,
          icon: Icons.favorite_border,
          title: '收藏',
          subtitle: '${stats.favoriteCount} 首歌曲',
          onTap: () => context.push('/account/cloud-sync/cloud-data/favorites'),
        ),
        const SizedBox(height: 10),
        _entryCard(
          scheme,
          icon: Icons.extension_outlined,
          title: '插件',
          subtitle: '${stats.pluginCount} 个插件',
          onTap: () => context.push('/account/cloud-sync/cloud-data/plugins'),
        ),
        const SizedBox(height: 10),
        _entryCard(
          scheme,
          icon: Icons.person_outline,
          title: '用户',
          subtitle: overview.user?.nickname ?? '云端账号信息',
          onTap: () => context.push('/account/cloud-sync/cloud-data/user'),
        ),
      ],
    );
  }

  Widget _entryCard(
    ColorScheme scheme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Icon(icon, color: scheme.primary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
      ),
    );
  }

  Widget _buildClearButton(ColorScheme scheme) {
    return OutlinedButton.icon(
      onPressed: _clearing ? null : _clearCloudData,
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.error,
        side: BorderSide(color: scheme.error.withValues(alpha: 0.5)),
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      icon: _clearing
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.delete_forever_outlined),
      label: Text(_clearing ? '清空中…' : '清空云端数据'),
    );
  }
}
