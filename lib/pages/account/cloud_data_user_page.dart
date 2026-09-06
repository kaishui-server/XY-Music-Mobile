import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/sync/cloud_data_viewer.dart';

/// 云端用户信息：展示账号在服务器上的注册信息与各云数据的上传时间。
class CloudDataUserPage extends ConsumerStatefulWidget {
  const CloudDataUserPage({super.key});

  @override
  ConsumerState<CloudDataUserPage> createState() => _CloudDataUserPageState();
}

class _CloudDataUserPageState extends ConsumerState<CloudDataUserPage> {
  CloudDataOverview? _overview;
  bool _loading = true;
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(leading: const BackButton(), title: const Text('云端用户')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _buildBody(scheme),
            ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
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
    final overview = _overview!;
    final user = overview.user;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        16, 20, 16, MediaQuery.paddingOf(context).bottom + 104,
      ),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: scheme.primary,
                child: Text(
                  (user?.nickname.isNotEmpty == true ? user!.nickname : '?')
                      .characters
                      .first,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user?.nickname ?? '未找到云端账号',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                    if (user?.xymusicId.isNotEmpty == true)
                      Text(
                        'XY号：${user!.xymusicId}',
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Text('账号信息', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (user == null)
          _infoCard(scheme, [
            _row('状态', '服务器上没有找到这个账号的信息'),
          ])
        else ...[
          _infoCard(scheme, [
            _row('XY号', user.xymusicId),
            _row('昵称', user.nickname),
            _row('邮箱', user.email.isEmpty ? '-' : user.email),
            _row(
              '客户端',
              switch (user.clientType) {
                'mobile' => '移动端',
                'desktop' => '电脑端',
                '' => '-',
                final other => other,
              },
            ),
            _row('注册时间', user.createdAt.isEmpty ? '-' : user.createdAt),
          ]),
        ],
        const SizedBox(height: 20),
        const Text('云数据上传时间', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        _infoCard(scheme, [
          _row(
            '歌单与收藏',
            overview.playlistsUploadedAt.isEmpty ? '从未上传' : overview.playlistsUploadedAt,
          ),
          _row(
            '插件',
            overview.pluginsUploadedAt.isEmpty ? '从未上传' : overview.pluginsUploadedAt,
          ),
          _row(
            '设置',
            overview.settingsUploadedAt.isEmpty ? '从未上传' : overview.settingsUploadedAt,
          ),
        ]),
      ],
    );
  }

  Widget _infoCard(ColorScheme scheme, List<Widget> rows) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(children: rows),
    );
  }

  Widget _row(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(label, style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
