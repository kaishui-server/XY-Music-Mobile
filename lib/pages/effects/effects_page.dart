import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/effects/effects_provider.dart';
import '../../src/navigation/sidebar_controller.dart';
import '../../src/core/settings.dart';

class EffectsPage extends ConsumerStatefulWidget {
  const EffectsPage({super.key});

  @override
  ConsumerState<EffectsPage> createState() => _EffectsPageState();
}

class _EffectsPageState extends ConsumerState<EffectsPage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final effects = ref.watch(effectsProvider);
    final sidebarOnRight = ref.watch(
      settingsProvider.select(
        (value) => value.valueOrNull?.sidebarPosition == SidebarPosition.right,
      ),
    );
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !sidebarOnRight,
        leading: sidebarOnRight ? null : const AppSidebarMenuButton(),
        title: const Text('音效'),
        actions: [if (sidebarOnRight) const AppSidebarMenuButton()],
      ),
      body: effects.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('音效设置加载失败：$error')),
        data: (settings) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                      value: 0,
                      icon: Icon(Icons.equalizer, size: 18),
                      label: Text('均衡器'),
                    ),
                    ButtonSegment(
                      value: 1,
                      icon: Icon(Icons.auto_awesome, size: 18),
                      label: Text('空间音效'),
                    ),
                  ],
                  selected: {_tab},
                  showSelectedIcon: false,
                  onSelectionChanged: (value) =>
                      setState(() => _tab = value.first),
                ),
              ),
            ),
            Expanded(
              child: _tab == 0
                  ? _EqualizerView(settings: settings)
                  : _SpatialEffectsView(settings: settings),
            ),
          ],
        ),
      ),
    );
  }
}

class _EqualizerView extends ConsumerWidget {
  const _EqualizerView({required this.settings});
  final EffectsSettings settings;

  static const frequencies = [
    '31',
    '62',
    '125',
    '250',
    '500',
    '1k',
    '2k',
    '4k',
    '8k',
    '16k',
  ];
  static const presets = <String, List<double>>{
    '平直': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    '流行': [-1, 1, 3, 4, 2, -1, -2, 1, 3, 4],
    '摇滚': [5, 3, -1, -3, -1, 2, 5, 6, 6, 5],
    '古典': [4, 3, 2, 1, -1, -1, 0, 2, 3, 4],
    '人声': [-3, -2, 0, 3, 5, 5, 4, 2, 0, -2],
    '低音': [7, 6, 5, 3, 1, 0, -1, -2, -2, -2],
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(effectsProvider.notifier);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
      children: [
        _GlassCard(
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0x24EC4141),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.equalizer, color: Color(0xFFEC4141)),
              ),
              const SizedBox(width: 13),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '十段均衡器',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text('针对不同频段精细调整声音', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              Switch(
                value: settings.equalizerEnabled,
                onChanged: (value) =>
                    notifier.save(settings.copyWith(equalizerEnabled: value)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
          '预设',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 9),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final preset in presets.entries) ...[
                ActionChip(
                  label: Text(preset.key),
                  avatar: const Icon(Icons.tune, size: 16),
                  onPressed: () => notifier.applyPreset(preset.value),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        AnimatedOpacity(
          opacity: settings.equalizerEnabled ? 1 : .42,
          duration: const Duration(milliseconds: 180),
          child: IgnorePointer(
            ignoring: !settings.equalizerEnabled,
            child: _GlassCard(
              padding: const EdgeInsets.fromLTRB(8, 16, 8, 12),
              child: Column(
                children: [
                  SizedBox(
                    height: 250,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (
                          var index = 0;
                          index < settings.gains.length;
                          index++
                        )
                          Expanded(
                            child: Column(
                              children: [
                                Text(
                                  '${settings.gains[index].round()}',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Expanded(
                                  child: RotatedBox(
                                    quarterTurns: 3,
                                    child: Slider(
                                      min: -12,
                                      max: 12,
                                      divisions: 48,
                                      value: settings.gains[index].clamp(
                                        -12,
                                        12,
                                      ),
                                      onChanged: (value) =>
                                          notifier.setBand(index, value),
                                    ),
                                  ),
                                ),
                                Text(
                                  frequencies[index],
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const SizedBox(width: 8),
                      const Text('前级'),
                      Expanded(
                        child: Slider(
                          min: -12,
                          max: 12,
                          divisions: 48,
                          value: settings.preamp.clamp(-12, 12),
                          onChanged: (value) =>
                              notifier.save(settings.copyWith(preamp: value)),
                        ),
                      ),
                      SizedBox(
                        width: 48,
                        child: Text(
                          '${settings.preamp.toStringAsFixed(1)} dB',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      IconButton(
                        tooltip: '重置',
                        onPressed: notifier.resetEqualizer,
                        icon: const Icon(Icons.restart_alt),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SpatialEffectsView extends ConsumerWidget {
  const _SpatialEffectsView({required this.settings});
  final EffectsSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(effectsProvider.notifier);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
      children: [
        Text(
          '快捷音效',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _EffectToggle(
                icon: Icons.surround_sound,
                title: '低音增强',
                subtitle: '强化鼓点与下潜',
                enabled: settings.bassBoost,
                onChanged: (value) =>
                    notifier.save(settings.copyWith(bassBoost: value)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _EffectToggle(
                icon: Icons.open_in_full,
                title: '立体声拓宽',
                subtitle: '扩展左右声场',
                enabled: settings.stereoWiden,
                onChanged: (value) =>
                    notifier.save(settings.copyWith(stereoWiden: value)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _EffectToggle(
          icon: Icons.record_voice_over_outlined,
          title: '人声消除',
          subtitle: '弱化中央声道人声，适合伴唱',
          enabled: settings.vocalRemoval,
          onChanged: (value) =>
              notifier.save(settings.copyWith(vocalRemoval: value)),
        ),
        const SizedBox(height: 18),
        Text(
          '混响空间',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        _GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('环境混响', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in const {
                    '': '关闭',
                    'room': '房间',
                    'hall': '音乐厅',
                    'plate': '板式',
                    'cathedral': '教堂',
                  }.entries)
                    ChoiceChip(
                      selected: settings.reverbPreset == item.key,
                      label: Text(item.value),
                      onSelected: (_) => notifier.save(
                        settings.copyWith(reverbPreset: item.key),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              const Text('环绕模式', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in const {
                    'none': '关闭',
                    'surround3d': '3D',
                    'd8': '8D',
                    'd36': '36D',
                    'virtual': '虚拟 7.1',
                  }.entries)
                    ChoiceChip(
                      selected: settings.spatialMode == item.key,
                      label: Text(item.value),
                      onSelected: (_) => notifier.save(
                        settings.copyWith(spatialMode: item.key),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.bolt, color: Color(0xFFEC4141)),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '音量增强',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text('${settings.audioBoost.toStringAsFixed(1)} dB'),
                ],
              ),
              Slider(
                min: 0,
                max: 12,
                divisions: 24,
                value: settings.audioBoost.clamp(0, 12),
                onChanged: (value) =>
                    notifier.save(settings.copyWith(audioBoost: value)),
              ),
              Text(
                '高增益可能导致削波，请根据耳机与曲目适量调整。',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EffectToggle extends StatelessWidget {
  const _EffectToggle({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onChanged,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => _GlassCard(
    padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
    child: Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: enabled
                ? const Color(0x24EC4141)
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: enabled ? const Color(0xFFEC4141) : null),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 2,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Switch(value: enabled, onChanged: onChanged),
      ],
    ),
  );
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({
    required this.child,
    this.padding = const EdgeInsets.all(14),
  });
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainer.withValues(alpha: .72),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: Theme.of(
          context,
        ).colorScheme.outlineVariant.withValues(alpha: .35),
      ),
    ),
    child: child,
  );
}
