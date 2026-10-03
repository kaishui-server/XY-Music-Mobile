import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/effects/effects_provider.dart';
import '../../src/navigation/sidebar_controller.dart';
import '../../src/core/settings.dart';

class EffectsPage extends ConsumerWidget {
  const EffectsPage({super.key, this.showBackButton = false});

  /// 全屏路由（从播放页进入）时显示返回按钮；侧栏分支路由保持菜单按钮。
  final bool showBackButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final effects = ref.watch(effectsProvider);
    final sidebarOnRight = ref.watch(
      settingsProvider.select(
        (value) => value.valueOrNull?.sidebarPosition == SidebarPosition.right,
      ),
    );
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: showBackButton
            ? const BackButton()
            : (sidebarOnRight ? null : const AppSidebarMenuButton()),
        title: const Text('音效'),
        actions: [
          TextButton.icon(
            onPressed: () => ref.read(effectsProvider.notifier).resetAll(),
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('重置'),
          ),
          if (sidebarOnRight) const AppSidebarMenuButton(),
        ],
      ),
      body: effects.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('音效设置加载失败：$error')),
        data: (settings) {
          final notifier = ref.read(effectsProvider.notifier);
          return ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              MediaQuery.paddingOf(context).bottom + 24,
            ),
            children: [
              _sectionHeader(context, '均衡器'),
              _EqSection(settings: settings, notifier: notifier),
              _sectionHeader(context, '变速变调'),
              _PitchRateSection(settings: settings, notifier: notifier),
              _sectionHeader(context, '混响'),
              _ReverbSection(settings: settings, notifier: notifier),
              _sectionHeader(context, '空间音效'),
              _SpatialSection(settings: settings, notifier: notifier),
              const SizedBox(height: 16),
              Text(
                '均衡器、前级与变速变调实时生效（系统原生音频引擎）；'
                '混响、空间音效由 Rust DSP 引擎处理，'
                '在独占音频输出下播放时生效。',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static Widget _sectionHeader(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

class _EqSection extends StatelessWidget {
  const _EqSection({required this.settings, required this.notifier});
  final EffectsSettings settings;
  final EffectsNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final customPresets = notifier.customEqPresets;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
                    Text('十段均衡器',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    SizedBox(height: 3),
                    Text('针对不同频段精细调整声音',
                        style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              Switch(
                value: settings.equalizerEnabled,
                onChanged: (v) => notifier.save(
                    settings.copyWith(equalizerEnabled: v)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ActionChip(
                  avatar: Icon(Icons.add, size: 18, color: scheme.primary),
                  label: const Text('保存'),
                  onPressed: () => _savePreset(context, notifier),
                ),
              ),
              for (final p in eqPresets)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(p.name),
                    selected: _isPresetActive(settings, p.gains),
                    onSelected: (_) => notifier.applyEqPreset(p.name),
                  ),
                ),
              if (customPresets.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _dividerDot(context),
                ),
                for (final p in customPresets)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onLongPress: () =>
                          _editPreset(context, notifier, p.name),
                      child: ChoiceChip(
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.person_pin, size: 14),
                            const SizedBox(width: 4),
                            Text(p.name),
                          ],
                        ),
                        selected: _isPresetActive(settings, p.gains),
                        onSelected: (_) =>
                            notifier.applyCustomEqPreset(p.name),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 0, 6),
          child: Text(
            customPresets.isEmpty
                ? '长按自定义预设可重命名或删除'
                : '预设 · 点按应用 · 长按编辑',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
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
                    height: 200,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < settings.gains.length; i++)
                          Expanded(
                            child: _EqBand(
                              value: settings.gains[i],
                              freqLabel: eqFreqLabels[i],
                              onCommit: (v) => notifier.setBand(i, v),
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
                          onChanged: (v) => notifier
                              .save(settings.copyWith(preamp: v)),
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

  Widget _dividerDot(BuildContext context) => Center(
        child: Container(
          width: 1,
          height: 20,
          color: Theme.of(context)
              .colorScheme
              .onSurfaceVariant
              .withValues(alpha: 0.3),
        ),
      );

  bool _isPresetActive(EffectsSettings s, List<double> gains) {
    if (s.gains.length != gains.length) return false;
    for (var i = 0; i < s.gains.length; i++) {
      if ((s.gains[i] - gains[i]).abs() > 0.01) return false;
    }
    return true;
  }

  Future<void> _savePreset(
      BuildContext context, EffectsNotifier manager) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存均衡器预设'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('将当前 EQ 增益保存为自定义预设，同名将覆盖',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '预设名称',
                hintText: '例如：我的流行',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      await manager.saveCustomEqPreset(name);
    }
  }

  Future<void> _editPreset(
      BuildContext context, EffectsNotifier manager, String name) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('预设「$name」'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'rename'),
            child: const ListTile(
              leading: Icon(Icons.drive_file_rename_outline),
              title: Text('重命名'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(ctx).colorScheme.error),
              title: Text('删除',
                  style:
                      TextStyle(color: Theme.of(ctx).colorScheme.error)),
            ),
          ),
        ],
      ),
    );
    if (action == 'rename') {
      if (!context.mounted) return;
      final controller = TextEditingController(text: name);
      final newName = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('重命名预设'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '预设名称',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      controller.dispose();
      if (newName != null && newName.isNotEmpty) {
        await manager.renameCustomEqPreset(name, newName);
      }
    } else if (action == 'delete') {
      await manager.deleteCustomEqPreset(name);
    }
  }
}

class _PitchRateSection extends StatelessWidget {
  const _PitchRateSection({required this.settings, required this.notifier});
  final EffectsSettings settings;
  final EffectsNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Column(
        children: [
          _SliderTile(
            label: '倍速',
            value: settings.playbackRate,
            min: 50,
            max: 200,
            displayBuilder: (v) => '${v.round()}%',
            onChanged: (v) =>
                notifier.save(settings.copyWith(playbackRate: v)),
          ),
          _SliderTile(
            label: '变调',
            value: settings.pitchShift,
            min: 50,
            max: 200,
            displayBuilder: (v) => '${v.round()}%',
            onChanged: (v) =>
                notifier.save(settings.copyWith(pitchShift: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.music_note),
            title: const Text('变速时保持音调'),
            value: settings.preservesPitch,
            onChanged: (v) =>
                notifier.save(settings.copyWith(preservesPitch: v)),
          ),
        ],
      ),
    );
  }
}

class _ReverbSection extends StatelessWidget {
  const _ReverbSection({required this.settings, required this.notifier});
  final EffectsSettings settings;
  final EffectsNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final active =
        settings.reverbKind == 'none' ? null : settings.reverbPreset;
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in [...reverbPresets, ...algoReverbPresets])
                ChoiceChip(
                  label: Text(p.label),
                  selected: active == p.label,
                  onSelected: (_) {
                    if (active == p.label) {
                      notifier.clearReverb();
                    } else {
                      final kind = reverbPresets.contains(p)
                          ? 'convolution'
                          : 'algorithmic';
                      // 预设表用 0..100 表示干/湿声百分比，Rust 侧按 0..1 解释
                      // （滑条同样以 v/100 写回），此处须 /100 归一化，否则
                      // 混响干湿比会失真并被 toRustJson 的 clamp(0,1) 压成满值。
                      notifier.setReverb(kind, p.label,
                          p.dry / 100, p.wet / 100);
                    }
                  },
                ),
            ],
          ),
          if (settings.reverbKind != 'none') ...[
            const SizedBox(height: 8),
            _SliderTile(
              label: '干声',
              value: settings.reverbDry * 100,
              min: 0,
              max: 100,
              displayBuilder: (v) => '${v.round()}%',
              onChanged: (v) => notifier.setReverb(
                  settings.reverbKind,
                  settings.reverbPreset,
                  v / 100,
                  settings.reverbWet),
            ),
            _SliderTile(
              label: '湿声',
              value: settings.reverbWet * 100,
              min: 0,
              max: 100,
              displayBuilder: (v) => '${v.round()}%',
              onChanged: (v) => notifier.setReverb(
                  settings.reverbKind,
                  settings.reverbPreset,
                  settings.reverbDry,
                  v / 100),
            ),
          ],
        ],
      ),
    );
  }
}

class _SpatialSection extends StatelessWidget {
  const _SpatialSection({required this.settings, required this.notifier});
  final EffectsSettings settings;
  final EffectsNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final mode = settings.spatialMode;
    return _GlassCard(
      child: Column(
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in const [
                ('none', '关闭'),
                ('surround3d', '3D 环绕'),
                ('d8', '8D 环绕'),
                ('d36', '36D 环绕'),
                ('virtual', '虚拟环绕'),
              ])
                ChoiceChip(
                  label: Text(m.$2),
                  selected: mode == m.$1,
                  onSelected: (_) => notifier.setSpatial(
                      mode == m.$1 ? 'none' : m.$1),
                ),
            ],
          ),
          if (mode == 'surround3d') ...[
            _SliderTile(
              label: '旋转速度',
              value: settings.spatialSpeed,
              min: 2,
              max: 20,
              displayBuilder: (v) =>
                  '${v.toStringAsFixed(1)}s/圈',
              onChanged: (v) => notifier.setSpatial(mode, speed: v),
            ),
            _SliderTile(
              label: '声源距离',
              value: settings.spatialRadius * 10,
              min: 1,
              max: 20,
              displayBuilder: (v) => '${v.round()}',
              onChanged: (v) =>
                  notifier.setSpatial(mode, radius: v / 10),
            ),
          ],
          if (mode == 'd8' || mode == 'd36') ...[
            _SliderTile(
              label: '旋转速度',
              value: settings.spatialSpeed,
              min: 2,
              max: 60,
              displayBuilder: (v) => '${v.round()}s/圈',
              onChanged: (v) => notifier.setSpatial(mode, speed: v),
            ),
            _SliderTile(
              label: '虚拟距离',
              value: settings.spatialRadius * 5,
              min: 1,
              max: 20,
              displayBuilder: (v) => '${v.round()}',
              onChanged: (v) =>
                  notifier.setSpatial(mode, radius: v / 5),
            ),
          ],
          if (mode == 'virtual') ...[
            _SliderTile(
              label: '声场宽度',
              value: settings.virtualSurroundSpread,
              min: 1,
              max: 20,
              displayBuilder: (v) => '${v.round()}',
              onChanged: (v) => notifier.save(
                  settings.copyWith(virtualSurroundSpread: v)),
            ),
          ],
        ],
      ),
    );
  }
}

class _SliderTile extends StatefulWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.displayBuilder,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String Function(double)? displayBuilder;
  final ValueChanged<double> onChanged;

  @override
  State<_SliderTile> createState() => _SliderTileState();
}

class _SliderTileState extends State<_SliderTile> {
  double? _draft;

  @override
  Widget build(BuildContext context) {
    final v = (_draft ?? widget.value).clamp(widget.min, widget.max);
    final text = widget.displayBuilder?.call(v) ?? v.round().toString();
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(widget.label,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis),
        ),
        Expanded(
          child: Slider(
            value: v,
            min: widget.min,
            max: widget.max,
            onChanged: (x) => setState(() => _draft = x),
            onChangeEnd: (x) {
              widget.onChanged(x);
              setState(() => _draft = null);
            },
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            text,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _EqBand extends StatefulWidget {
  const _EqBand({
    required this.value,
    required this.freqLabel,
    required this.onCommit,
  });

  final double value;
  final String freqLabel;
  final ValueChanged<double> onCommit;

  @override
  State<_EqBand> createState() => _EqBandState();
}

class _EqBandState extends State<_EqBand> {
  double? _draft;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = (_draft ?? widget.value).clamp(-12.0, 12.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        children: [
          Text(
            '${v >= 0 ? '+' : ''}${v.round()}',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: Slider(
                value: v,
                min: -12,
                max: 12,
                onChanged: (x) => setState(() => _draft = x),
                onChangeEnd: (x) {
                  widget.onCommit(x);
                  setState(() => _draft = null);
                },
              ),
            ),
          ),
          Text(widget.freqLabel,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
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
          color: Theme.of(context)
              .colorScheme
              .surfaceContainer
              .withValues(alpha: .72),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Theme.of(context)
                .colorScheme
                .outlineVariant
                .withValues(alpha: .35),
          ),
        ),
        child: child,
      );
}
