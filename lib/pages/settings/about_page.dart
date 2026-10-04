import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/ui/external_link.dart';
import '../../src/update/app_update.dart';
import '../../src/widgets/top_notice.dart' show XyNotice, XyNoticeType;
import 'third_party_licenses_page.dart';

/// 项目主仓库地址。
const String kProjectRepoUrl = 'https://github.com/kaishui-server/XY-Music-Mobile';

/// 官方 QQ 交流群号。
const String kQqGroupNumber = '656117919';

/// 创作者 GitHub 主页（展示名与主页地址解耦，展示名以本人习惯称呼为准）。
const String kCreatorKaishuiUrl = 'https://github.com/kaishui-server';
const String kCreatorQingciUrl = 'https://github.com/3580351677';

final _clientVersionProvider = FutureProvider.autoDispose<String>(
  (ref) => ref.read(authProvider.notifier).currentAppVersion(),
);

class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final clientVersion = ref.watch(_clientVersionProvider).valueOrNull ?? '0.0.0';
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 40),
        children: [
          // 顶部品牌区：Logo + 名称 + 版本号。
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
              ],
            ),
          ),
          const SizedBox(height: 26),
          // 左右两个操作按钮：检查更新 / 加入 Q 群。
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  icon: Icons.system_update_rounded,
                  label: '检查更新',
                  onTap: () => _checkForUpdate(context, ref),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ActionButton(
                  icon: Icons.groups_rounded,
                  label: '加入Q群',
                  onTap: () => _copyText(
                    context,
                    kQqGroupNumber,
                    tip: '群号已复制：$kQqGroupNumber',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          // 项目仓库：点击跳转，长按复制。
          _AboutCard(
            children: [
              _LinkRow(
                icon: Icons.code_rounded,
                title: '项目仓库',
                subtitle: 'github.com/kaishui-server/XY-Music-Mobile',
                onTap: () => _openUrl(context, kProjectRepoUrl),
                onLongPress: () => _copyText(
                  context,
                  kProjectRepoUrl,
                  tip: '仓库地址已复制',
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _SectionLabel('创作者'),
          const SizedBox(height: 8),
          _AboutCard(
            children: [
              _LinkRow(
                icon: Icons.person_rounded,
                title: '狐狐不相信人类',
                subtitle: 'github.com/kaishui-server',
                onTap: () => _openUrl(context, kCreatorKaishuiUrl),
              ),
              const Divider(height: 1, indent: 66),
              _LinkRow(
                icon: Icons.person_outline_rounded,
                title: '青辞',
                subtitle: 'github.com/3580351677',
                onTap: () => _openUrl(context, kCreatorQingciUrl),
              ),
            ],
          ),
          const SizedBox(height: 18),
          // 第三方许可：进入独立页面查看参考项目致谢。
          _AboutCard(
            children: [
              _LinkRow(
                icon: Icons.article_outlined,
                title: '第三方许可',
                subtitle: '开源组件与参考项目致谢',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ThirdPartyLicensesPage(),
                  ),
                ),
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

  /// 检查更新：拉取服务端最新版本公告，有新版本时弹出更新说明与下载入口。
  Future<void> _checkForUpdate(BuildContext context, WidgetRef ref) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final release = await ref.read(authProvider.notifier).fetchLatestRelease();
      final clientVersion = await ref
          .read(authProvider.notifier)
          .currentAppVersion();
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      final hasUpdate = release != null &&
          compareAppVersions(release.version, clientVersion) > 0 &&
          release.downloadUrl.trim().isNotEmpty;
      if (hasUpdate) {
        await _showUpdateDialog(context, release);
        return;
      }
      XyNotice.show(
        context,
        message: '已是最新版本（$clientVersion）',
        type: XyNoticeType.success,
      );
    } catch (_) {
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      XyNotice.show(
        context,
        message: '检查更新失败，请稍后重试',
        type: XyNoticeType.warning,
      );
    }
  }

  Future<void> _showUpdateDialog(
    BuildContext context,
    BackendRelease release,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('发现新版本 ${release.version}'),
        content: SingleChildScrollView(
          child: Text(
            release.content.trim().isEmpty ? '暂无更新说明' : release.content.trim(),
            style: const TextStyle(fontSize: 14, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('稍后'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              downloadAndInstallRelease(context, release);
            },
            icon: const Icon(Icons.system_update_rounded),
            label: const Text('下载安装'),
          ),
        ],
      ),
    );
  }

  /// 打开外部链接；系统无法调起浏览器时回退为复制链接。
  Future<void> _openUrl(BuildContext context, String url) async {
    final opened = await openExternalUrl(url);
    if (!opened && context.mounted) {
      await _copyText(context, url, tip: '无法打开浏览器，链接已复制');
    }
  }

  Future<void> _copyText(
    BuildContext context,
    String text, {
    required String tip,
  }) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      XyNotice.show(
        context,
        message: tip,
        type: XyNoticeType.success,
        compact: true,
      );
    }
  }
}

/// 顶部操作按钮：图标 + 文案，等宽排布。
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          height: 54,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: .3),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: const Color(0xFFEC4141)),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 分组小标题。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// 可点击 / 可长按的链接行：左侧圆形图标，中部标题 + 副标题，右侧箭头。
class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onLongPress,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
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
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
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
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: scheme.onSurfaceVariant.withValues(alpha: .7),
            ),
          ],
        ),
      ),
    );
  }
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