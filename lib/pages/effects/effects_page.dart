// effects_page.dart — 音效页（5531 重写）
//
// 结构：①anime 音效广场（open.anime.bzxhkj.com 实时拉取，官方精选/用户
// 创作，选中后原始 params JSON 直传 Rust 侧官方 animefx.c 引擎）；
// ②十段均衡器（预设 + 自定义预设保留）；③变速变调（保留）。
// 旧版混响/空间音效区块被 anime 音效广场替代（其参数空间已被官方
// schema v1 覆盖：混响/压缩/次谐波/激励/抖晃/旋转/展宽/空气感）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/effects/anime_api.dart';
import '../../src/effects/effects_provider.dart';

class EffectsPage extends ConsumerStatefulWidget {
  const EffectsPage({super.key, this.showBackButton = false});

  final bool showBackButton;

  @override
  ConsumerState<EffectsPage> createState() => _EffectsPageState();
}

class _EffectsPageState extends ConsumerState<EffectsPage> {
  List<AnimeEffect>? _effects;
  bool _loading = true;
  bool _fromCache = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await fetchAnimeEffects(force: force);
      if (!mounted) return;
      setState(() {
        _effects = result.effects;
        _fromCache = result.fromCache;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effects = ref.watch(effectsProvider);
    final fx = effects.valueOrNull ?? const EffectsSettings();

    return Scaffold(
      appBar: AppBar(
        title: const Text('音效'),
        automaticallyImplyLeading: widget.showBackButton,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _buildAnimeSection(theme, fx),
          const SizedBox(height: 20),
          _buildEqualizerSection(theme, fx),
          const SizedBox(height: 20),
          _buildSpeedPitchSection(theme, fx),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 通用小组件

  Widget _sectionHeader(String title, String subtitle, {Widget? trailing}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ],
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.35)),
      ),
      child: child,
    );
  }

  Widget _switchRow(String title, bool value, ValueChanged<bool> onChanged,
      {String? subtitle}) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      title: Text(title, style: theme.textTheme.bodyLarge),
      subtitle: subtitle == null ? null : Text(subtitle, style: theme.textTheme.bodySmall),
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }

  Widget _sliderRow(
    String title,
    double value,
    double min,
    double max,
    int divisions,
    String Function(double) label,
    ValueChanged<double> onChanged,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: theme.textTheme.bodyLarge),
              Text(label(value),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.primary)),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------- ① anime 音效广场

  Widget _buildAnimeSection(ThemeData theme, EffectsSettings fx) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          '音效广场',
          '实时拉取 · 官方精选 / 用户创作 · 由官方 DSP 引擎渲染',
          trailing: IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : () => unawaited(_load(force: true)),
            icon: const Icon(Icons.refresh),
          ),
        ),
        _card(
          child: Column(
            children: [
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              else ...[
                if (_error != null)
                  _buildAnimeError(theme),
                if (_fromCache && _effects != null && _effects!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: Row(
                      children: [
                        Icon(Icons.cloud_off,
                            size: 15, color: theme.colorScheme.outline),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '网络拉取失败，当前展示离线缓存',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.outline),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_effects != null && _effects!.isNotEmpty) ...[
                  _buildAnimeTile(
                    theme,
                    name: '不使用音效',
                    intro: '关闭 anime 音效，恢复原始声音',
                    author: null,
                    official: false,
                    selected: !fx.hasAnimeEffect,
                    onTap: () => unawaited(
                        ref.read(effectsProvider.notifier).clearAnimeEffect()),
                  ),
                  _buildAnimeGroup(theme, '官方精选',
                      _effects!.where((e) => e.official).toList(), fx),
                  _buildAnimeGroup(theme, '用户创作',
                      _effects!.where((e) => !e.official).toList(), fx),
                ] else if (_error == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 28),
                    child: Text('暂无上架音效',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.outline)),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAnimeError(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline,
                  size: 17, color: theme.colorScheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '音效列表拉取失败',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
              TextButton(
                onPressed: () => unawaited(_load(force: true)),
                child: const Text('重试'),
              ),
            ],
          ),
          Text(
            _error ?? '',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }

  Widget _buildAnimeGroup(
      ThemeData theme, String title, List<AnimeEffect> items, EffectsSettings fx) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(title,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
        ),
        ...items.map((e) => _buildAnimeTile(
              theme,
              name: e.name,
              intro: e.intro,
              author: e.author,
              official: e.official,
              selected: fx.animeEffectId == e.id,
              onTap: () => unawaited(
                  ref.read(effectsProvider.notifier).setAnimeEffect(e)),
            )),
      ],
    );
  }

  Widget _buildAnimeTile(
    ThemeData theme, {
    required String name,
    required String intro,
    required String? author,
    required bool official,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final accent = theme.colorScheme.primary;
    return ListTile(
      dense: true,
      onTap: onTap,
      tileColor: selected ? accent.withValues(alpha: 0.08) : null,
      title: Row(
        children: [
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: selected ? FontWeight.bold : null,
                color: selected ? accent : null,
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (official) _buildBadge(theme, '官方', accent),
          if (selected) ...[
            const SizedBox(width: 6),
            Icon(Icons.check_circle, size: 16, color: accent),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (intro.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                intro,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (author != null && author.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '作者：$author',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBadge(ThemeData theme, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10, height: 1.3, color: color)),
    );
  }

  // ----------------------------------------------------------- ② 十段均衡器

  Widget _buildEqualizerSection(ThemeData theme, EffectsSettings fx) {
    final notifier = ref.read(effectsProvider.notifier);
    final customPresets = notifier.customEqPresets;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader('十段均衡器', '31Hz ~ 16kHz · 与 anime 音效叠加生效'),
        _card(
          child: Column(
            children: [
              _switchRow(
                '启用均衡器',
                fx.equalizerEnabled,
                (v) => unawaited(notifier
                    .save(fx.copyWith(equalizerEnabled: v))),
              ),
              _sliderRow(
                '前置增益',
                fx.preamp,
                -12,
                12,
                48,
                (v) => '${v.toStringAsFixed(1)} dB',
                (v) => unawaited(notifier.save(fx.copyWith(preamp: v))),
              ),
              // 内置预设
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in eqPresets)
                      ActionChip(
                        label: Text(p.name),
                        onPressed: () =>
                            unawaited(notifier.applyEqPreset(p.name)),
                      ),
                  ],
                ),
              ),
              // 自定义预设（保留：保存/应用/长按删除）
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Row(
                  children: [
                    Text('自定义预设',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline)),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => _showSaveCustomPresetDialog(theme),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('保存当前'),
                    ),
                  ],
                ),
              ),
              if (customPresets.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final p in customPresets)
                        InputChip(
                          label: Text(p.name),
                          onPressed: () =>
                              unawaited(notifier.applyCustomEqPreset(p.name)),
                          onDeleted: () =>
                              unawaited(notifier.deleteCustomEqPreset(p.name)),
                        ),
                    ],
                  ),
                ),
              _buildEqSliders(theme, fx),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => unawaited(notifier.resetEqualizer()),
                    child: const Text('重置均衡器'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEqSliders(ThemeData theme, EffectsSettings fx) {
    final notifier = ref.read(effectsProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: SizedBox(
        height: 168,
        child: Row(
          children: [
            for (var i = 0; i < 10; i++)
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: RotatedBox(
                        quarterTurns: -1,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2.5,
                            overlayShape: SliderComponentShape.noOverlay,
                            thumbShape:
                                const RoundSliderThumbShape(enabledThumbRadius: 7),
                          ),
                          child: Slider(
                            value: fx.gains[i].clamp(-12, 12),
                            min: -12,
                            max: 12,
                            onChanged: (v) =>
                                unawaited(notifier.setBand(i, v)),
                          ),
                        ),
                      ),
                    ),
                    Text(eqFreqLabels[i],
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontSize: 10)),
                    Text(
                      fx.gains[i] == 0
                          ? '0'
                          : fx.gains[i].toStringAsFixed(1),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontSize: 9, color: theme.colorScheme.outline),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSaveCustomPresetDialog(ThemeData theme) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存为自定义预设'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '预设名称'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await ref.read(effectsProvider.notifier).saveCustomEqPreset(name);
    }
  }

  // ------------------------------------------------------------- ③ 变速变调

  Widget _buildSpeedPitchSection(ThemeData theme, EffectsSettings fx) {
    final notifier = ref.read(effectsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader('变速变调', '独立于音效与均衡器 · 100% 为原速原调'),
        _card(
          child: Column(
            children: [
              _sliderRow(
                '变速',
                fx.playbackRate,
                50,
                200,
                30,
                (v) =>
                    '${(v / 100).toStringAsFixed(2)}x',
                (v) => unawaited(
                    notifier.save(fx.copyWith(playbackRate: v))),
              ),
              _sliderRow(
                '变调',
                fx.pitchShift,
                50,
                200,
                30,
                (v) => v == 100
                    ? '原调'
                    : '${v > 100 ? '+' : ''}${(v - 100).toStringAsFixed(0)}%',
                (v) =>
                    unawaited(notifier.save(fx.copyWith(pitchShift: v))),
              ),
              _switchRow(
                '变速时保持音调',
                fx.preservesPitch,
                (v) => unawaited(
                    notifier.save(fx.copyWith(preservesPitch: v))),
                subtitle: '开启后调整倍速不改变音高',
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ],
    );
  }
}
