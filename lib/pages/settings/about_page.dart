import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/update/app_update.dart';

final _serverReleaseProvider = FutureProvider.autoDispose<BackendRelease?>((
  ref,
) {
  return ref.read(authProvider.notifier).fetchLatestRelease();
});
final _clientVersionProvider = FutureProvider.autoDispose<String>(
  (ref) => ref.read(authProvider.notifier).currentAppVersion(),
);

class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final release = ref.watch(_serverReleaseProvider);
    final clientVersion = ref.watch(_clientVersionProvider).valueOrNull ?? '0.0.0';
    return Scaffold(
      appBar: AppBar(
        title: const Text('关于'),
        actions: [
          IconButton(
            tooltip: '检查服务器版本',
            onPressed: () => ref.invalidate(_serverReleaseProvider),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 40),
        children: [
          Center(
            child: Column(
              children: [
                Container(
                  width: 92,
                  height: 92,
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .18),
                        blurRadius: 26,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Image.asset('assets/icon/app_icon.png'),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'XY Music',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 5),
                Text(
                  '移动端 $clientVersion',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 9),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x24EC4141),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'Flutter + Rust',
                    style: TextStyle(
                      color: Color(0xFFEC4141),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),
          _AboutCard(
            children: [
              _row(
                context,
                Icons.favorite_outline,
                '为热爱音乐的你打造',
                '本地优先 · 无损播放 · 自由定制',
              ),
              const Divider(height: 1),
              _row(
                context,
                Icons.memory,
                '跨平台音频核心',
                'Rust DSP、QMC2、WebDAV 与音乐库',
              ),
              const Divider(height: 1),
              _row(context, Icons.shield_outlined, '隐私与数据', '音乐库和听歌统计默认保存在本机'),
            ],
          ),
          const SizedBox(height: 14),
          _AboutCard(
            children: [
              release.when(
                loading: () =>
                    _row(context, Icons.cloud_sync_outlined, '服务器服务', '正在检查…'),
                error: (_, _) => _row(
                  context,
                  Icons.cloud_off_outlined,
                  '服务器服务',
                  '连接失败，点击右上角重试',
                ),
                data: (item) {
                  final hasUpdate = item != null &&
                      compareAppVersions(item.version, clientVersion) > 0 &&
                      item.downloadUrl.trim().isNotEmpty;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _row(
                        context,
                        Icons.cloud_done_outlined,
                        '服务器服务',
                        item == null
                            ? '已连接 · 暂无服务端版本公告'
                            : '最新版本 ${item.version}${item.content.isEmpty ? '' : ' · ${item.content}'}',
                      ),
                      if (hasUpdate)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(66, 0, 14, 12),
                          child: FilledButton.icon(
                            onPressed: () => _downloadAndInstall(context, item),
                            icon: const Icon(Icons.system_update_rounded),
                            label: Text('发现新版本（当前 $clientVersion）'),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          _AboutCard(
            children: [
              _row(context, Icons.code, '开源许可', 'GNU AGPL-3.0-only'),
              const Divider(height: 1),
              _row(context, Icons.public, '项目仓库', 'XY Music 开源仓库'),
              const Divider(height: 1),
              _row(
                context,
                Icons.article_outlined,
                '第三方许可',
                'Flutter、Rust 及相关开源组件',
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            '© 2026 XY Music',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant.withValues(alpha: .65),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadAndInstall(
    BuildContext context,
    BackendRelease release,
  ) async {
    await downloadAndInstallRelease(context, release);
  }

  static Widget _row(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
  ) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    child: Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0x20EC4141),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, color: const Color(0xFFEC4141), size: 21),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _AboutCard extends StatelessWidget {
  const _AboutCard({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(17),
      border: Border.all(
        color: Theme.of(
          context,
        ).colorScheme.outlineVariant.withValues(alpha: .3),
      ),
    ),
    child: Column(children: children),
  );
}
