import 'package:flutter/material.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
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
                  '移动端 1.0.0 (1)',
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
