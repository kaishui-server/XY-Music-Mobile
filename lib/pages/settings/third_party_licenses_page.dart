import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../src/ui/external_link.dart';
import '../../src/widgets/top_notice.dart' show XyNotice, XyNoticeType;

/// 参考项目：名称、参考点、仓库地址。
class _ReferenceProject {
  const _ReferenceProject({
    required this.name,
    required this.note,
    required this.url,
    this.copyOnly = false,
  });

  final String name;
  final String note;
  final String url;

  /// 弦予仅支持点击复制地址，不跳转浏览器。
  final bool copyOnly;
}

const List<_ReferenceProject> _references = [
  _ReferenceProject(
    name: '坤音',
    note: 'UI 参考',
    url: 'https://github.com/ikunshare/kunyin-desktop',
  ),
  _ReferenceProject(
    name: '落雪',
    note: '部分功能实现代码参考',
    url: 'https://github.com/lyswhut/lx-music-desktop',
  ),
  _ReferenceProject(
    name: '弦予',
    note: '软件部分架构参考',
    url: 'https://github.com/TaXiaoQi/XianYu-Music-Mobile',
    copyOnly: true,
  ),
  _ReferenceProject(
    name: 'BakaMusic',
    note: '插件协议与实现参考',
    url: 'https://github.com/Zencok/BakaMusic',
  ),
];

/// 第三方许可页：致谢文案 + 参考项目卡片。除弦予外，卡片点击跳转仓库、
/// 长按复制地址；弦予卡片点击仅复制地址。
class ThirdPartyLicensesPage extends StatelessWidget {
  const ThirdPartyLicensesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('第三方许可')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 40),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(17),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: .3),
              ),
            ),
            child: Text(
              '本项目部分内容参考 坤音（UI）、落雪（部分功能实现代码+仓库地址）、'
              '弦予（软件部分架构+仓库地址）、BakaMusic（仓库地址）等音乐软件，'
              '感谢他们的支持。',
              style: TextStyle(
                fontSize: 14,
                height: 1.7,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 18),
          for (final project in _references) ...[
            _ReferenceCard(project: project),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _ReferenceCard extends StatelessWidget {
  const _ReferenceCard({required this.project});
  final _ReferenceProject project;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: project.url));
    if (context.mounted) {
      XyNotice.show(
        context,
        message: '${project.name} 仓库地址已复制',
        type: XyNoticeType.success,
        compact: true,
      );
    }
  }

  Future<void> _open(BuildContext context) async {
    if (project.copyOnly) {
      await _copy(context);
      return;
    }
    final opened = await openExternalUrl(project.url);
    if (!opened && context.mounted) {
      await _copy(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        borderRadius: BorderRadius.circular(17),
        onTap: () => _open(context),
        onLongPress: () => _copy(context),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: .3),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          project.name,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0x20EC4141),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            project.note,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFFEC4141),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      project.url,
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
              const SizedBox(width: 8),
              Icon(
                project.copyOnly
                    ? Icons.copy_rounded
                    : Icons.open_in_new_rounded,
                size: 18,
                color: const Color(0xFFEC4141),
              ),
            ],
          ),
        ),
      ),
    );
  }
}