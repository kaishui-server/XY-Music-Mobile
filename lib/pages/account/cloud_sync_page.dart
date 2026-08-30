import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/sync/account_cloud_sync.dart';
import '../../src/widgets/top_notice.dart';

/// 账号云同步设置：自动上传频率与手动同步入口。
class CloudSyncPage extends ConsumerStatefulWidget {
  const CloudSyncPage({super.key});

  @override
  ConsumerState<CloudSyncPage> createState() => _CloudSyncPageState();
}

class _CloudSyncPageState extends ConsumerState<CloudSyncPage> {
  CloudSyncFrequency _frequency = AccountCloudSync.defaultFrequency;
  bool _loading = true;
  bool _syncing = false;
  int _cooldown = 0;
  Timer? _cooldownTimer;

  String get _accountId => ref.read(authProvider).user?.xymusicId?.trim() ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final id = _accountId;
    if (id.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final container = ProviderScope.containerOf(context, listen: false);
    final selected = await AccountCloudSync.frequency(id);
    final last = await AccountCloudSync.lastManualSyncAt(id);
    if (!mounted) return;
    setState(() {
      _frequency = selected;
      _loading = false;
      _cooldown = _remainingCooldown(last);
    });
    await AccountCloudSync.startAutoUpload(
      ref.read(authProvider.notifier),
      ref.read(playlistsProvider.notifier),
      container,
      favorites: ref.read(favoritesProvider.notifier),
    );
    _startCooldownTicker();
  }

  int _remainingCooldown(DateTime? last) {
    if (last == null) return 0;
    final elapsed = DateTime.now().difference(last).inSeconds;
    return (30 - elapsed).clamp(0, 30);
  }

  void _startCooldownTicker() {
    _cooldownTimer?.cancel();
    if (_cooldown <= 0) return;
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final next = (_cooldown - 1).clamp(0, 30);
      setState(() => _cooldown = next);
      if (next == 0) _cooldownTimer?.cancel();
    });
  }

  Future<void> _changeFrequency(CloudSyncFrequency value) async {
    final id = _accountId;
    if (id.isEmpty) return;
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() => _frequency = value);
    await AccountCloudSync.setFrequency(id, value);
    await AccountCloudSync.startAutoUpload(
      ref.read(authProvider.notifier),
      ref.read(playlistsProvider.notifier),
      container,
      favorites: ref.read(favoritesProvider.notifier),
    );
    if (mounted) _notice('已更新同步频率：${value.label}');
  }

  Future<void> _manualSync() async {
    final id = _accountId;
    if (id.isEmpty || _syncing || _cooldown > 0) return;
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() {
      _syncing = true;
      _cooldown = 30;
    });
    _startCooldownTicker();
    await AccountCloudSync.markManualSync(id);
    try {
      final result = await AccountCloudSync.syncAll(
        ref.read(authProvider.notifier),
        ref.read(playlistsProvider.notifier),
        container,
        favorites: ref.read(favoritesProvider.notifier),
      );
      if (mounted) {
        final suffix = result.pluginErrors.isEmpty
            ? ''
            : '；插件失败 ${result.pluginErrors.length} 个，请稍后重试';
        _notice(
          result.noChange
              ? '同步完成：歌单和插件没有变化，未重复上传$suffix'
              : '同步完成：插件下载 ${result.downloadedPlugins} 个、上传 ${result.uploadedPlugins} 个；歌单上传 ${result.uploadedPlaylists} 个、下载 ${result.downloadedPlaylists} 个$suffix',
        );
      }
    } catch (error) {
      if (mounted) {
        _notice(
          error is AuthException ? '同步失败：${error.message}' : '同步失败：$error',
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  void _notice(String message) {
    XyNotice.show(
      context,
      message: message,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(leading: const BackButton(), title: const Text('账号云同步')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.cloud_sync_outlined, color: scheme.primary),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          '云同步会保存歌单、歌曲元数据和已安装插件。插件脚本会在其它设备登录后自动安装，不会上传本地音频文件。自动上传只会在应用运行且账号保持登录时执行。',
                          style: TextStyle(height: 1.45),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  '更新云数据频率',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  '默认每 30 分钟上传一次，也可以选择最快每 5 分钟、每天上传或完全手动上传。',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<CloudSyncFrequency>(
                  initialValue: _frequency,
                  decoration: const InputDecoration(
                    labelText: '自动上传频率',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final item in CloudSyncFrequency.values)
                      DropdownMenuItem(value: item, child: Text(item.label)),
                  ],
                  onChanged: (value) {
                    if (value != null) _changeFrequency(value);
                  },
                ),
                const SizedBox(height: 28),
                const Text(
                  '手动同步',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  '手动同步完成后 30 秒内不能再次点击，避免重复请求。',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _syncing || _cooldown > 0 ? null : _manualSync,
                  icon: _syncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync),
                  label: Text(
                    _syncing
                        ? '同步中…'
                        : (_cooldown > 0 ? '请等待 $_cooldown 秒' : '立即手动同步'),
                  ),
                ),
              ],
            ),
    );
  }
}
