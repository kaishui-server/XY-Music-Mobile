import 'package:flutter/material.dart';

/// 赞助页：展示赞助提示文案与微信 / 支付宝收款码。
class SponsorPage extends StatelessWidget {
  const SponsorPage({super.key});

  /// 赞助提示文案。
  static const String kSponsorTip =
      '赞助均为无偿赞助，本软件承诺永不添加需要额外付费的功能与权益，'
      '赞助>10元可获得qq群自定义称号，感谢您对开发者的支持！';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('赞助')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 40),
        children: [
          // 顶部提示文案。
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: .3),
              ),
            ),
            child: Text(
              kSponsorTip,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 24),
          _QrCodeCard(
            title: '微信收款码',
            asset: 'assets/weixin_qrcode.jpg',
          ),
          const SizedBox(height: 20),
          _QrCodeCard(
            title: '支付宝收款码',
            asset: 'assets/zfb_qrcode.jpg',
          ),
        ],
      ),
    );
  }
}

/// 收款码卡片：居中展示收款码图片 + 底部标签。
class _QrCodeCard extends StatelessWidget {
  const _QrCodeCard({required this.title, required this.asset});

  final String title;
  final String asset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: .3),
        ),
      ),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 1,
              child: Image.asset(
                asset,
                fit: BoxFit.contain,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
