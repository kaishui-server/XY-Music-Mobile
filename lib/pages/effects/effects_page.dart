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
              _sectionHeader(context, '高级音效'),
              _AdvancedSection(settings: settings, notifier: notifier),
              const SizedBox(height: 16),
              Text(
                '均衡器、前级与变速变调实时生效（系统原生音频引擎）；'
                '混响、空间音效及高级音效由 Rust DSP 引擎处理，'
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
                      notifier.setReverb(kind, p.label,
                          p.dry.toDouble(), p.wet.toDouble());
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

class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection({required this.settings, required this.notifier});
  final EffectsSettings settings;
  final EffectsNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Column(
        children: [
          _switchTile(
            icon: Icons.mic_off,
            title: '消人声',
            value: settings.vocalRemoval,
            onChanged: (v) =>
                notifier.save(settings.copyWith(vocalRemoval: v)),
          ),
          _switchTile(
            icon: Icons.waves,
            title: '颤音',
            value: settings.vibratoEnabled,
            onChanged: (v) =>
                notifier.save(settings.copyWith(vibratoEnabled: v)),
          ),
          if (settings.vibratoEnabled) ...[
            _SliderTile(
              label: '颤音速率',
              value: settings.vibratoRate,
              min: 1,
              max: 20,
              displayBuilder: (v) => '${v.round()} Hz',
              onChanged: (v) =>
                  notifier.save(settings.copyWith(vibratoRate: v)),
            ),
            _SliderTile(
              label: '颤音深度',
              value: settings.vibratoDepth,
              min: 0,
              max: 10,
              displayBuilder: (v) => '${v.round()} ms',
              onChanged: (v) =>
                  notifier.save(settings.copyWith(vibratoDepth: v)),
            ),
          ],
          _switchTile(
            icon: Icons.album,
            title: '抖音效果器',
            value: settings.tremoloEnabled,
            onChanged: (v) =>
                notifier.save(settings.copyWith(tremoloEnabled: v)),
          ),
          if (settings.tremoloEnabled) ...[
            _SliderTile(
              label: '速率',
              value: settings.tremoloRate,
              min: 1,
              max: 20,
              displayBuilder: (v) => '${v.round()} Hz',
              onChanged: (v) =>
                  notifier.save(settings.copyWith(tremoloRate: v)),
            ),
            _SliderTile(
              label: '深度',
              value: settings.tremoloDepth,
              min: 0,
              max: 100,
              displayBuilder: (v) => '${v.round()}%',
              onChanged: (v) =>
                  notifier.save(settings.copyWith(tremoloDepth: v)),
            ),
          ],
          _switchTile(
            icon: Icons.speaker,
            title: 'Bass 重低音增强',
            value: settings.bassBoostEnabled,
            onChanged: (v) =>
                notifier.save(settings.copyWith(bassBoostEnabled: v)),
          ),
          if (settings.bassBoostEnabled) ...[
            _SliderTile(
              label: '增益',
              value: settings.bassBoostGain,
              min: 0,
              max: 15,
              displayBuilder: (v) => '${v.round()} dB',
              onChanged: (v) =>
                  notifier.save(settings.copyWith(bassBoostGain: v)),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.bolt),
              title: const Text('动态低音回弹'),
              value: settings.bassBoostDynamic,
              onChanged: (v) =>
                  notifier.save(settings.copyWith(bassBoostDynamic: v)),
            ),
          ],
          _switchTile(
            icon: Icons.graphic_eq,
            title: '高音增强',
            value: settings.trebleEnabled,
            onChanged: (v) =>
                notifier.save(settings.copyWith(trebleEnabled: v)),
          ),
          if (settings.trebleEnabled) ...[
            _SliderTile(
              label: '增益',
              value: settings.trebleGain,
              min: 0,
              max: 15,
              displayBuilder: (v) => '${v.round()} dB',
              onChanged: (v) =>
                  notifier.save(settings.copyWith(trebleGain: v)),
            ),
          ],
          _switchTile(
            icon: Icons.auto_fix_high,
            title: '失真',
            value: settings.distortionEnabled,
            onChanged: (v) =>
                notifier.save(settings.copyWith(distortionEnabled: v)),
          ),
          if (settings.distortionEnabled) ...[
            _SliderTile(
              label: '失真强度',
              value: settings.distortionAmount,
              min: 1,
              max: 100,
              displayBuilder: (v) => '${v.round()}',
              onChanged: (v) => notifier
                  .save(settings.copyWith(distortionAmount: v)),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.tune),
              title: const Text('软失真'),
              value: settings.distortionType == 'soft',
              onChanged: (v) => notifier.save(settings.copyWith(
                  distortionType: v ? 'soft' : 'hard')),
            ),
          ],
          _switchTile(
            icon: Icons.repeat,
            title: '延迟回声',
            value: settings.delayEnabled,
            onChanged: (v) =>
                notifier.save(settings.copyWith(delayEnabled: v)),
          ),
          if (settings.delayEnabled) ...[
            _SliderTile(
              label: '延迟时间',
              value: settings.delayTime,
              min: 50,
              max: 2000,
              displayBuilder: (v) => '${v.round()} ms',
              onChanged: (v) =>
                  notifier.save(settings.copyWith(delayTime: v)),
            ),
            _SliderTile(
              label: '反馈',
              value: settings.delayFeedback,
              min: 0,
              max: 90,
              displayBuilder: (v) => '${v.round()}%',
              onChanged: (v) =>
                  notifier.save(settings.copyWith(delayFeedback: v)),
            ),
            _SliderTile(
              label: '混合',
              value: settings.delayMix,
              min: 0,
              max: 100,
              displayBuilder: (v) => '${v.round()}%',
              onChanged: (v) =>
                  notifier.save(settings.copyWith(delayMix: v)),
            ),
          ],
          _switchTile(
            icon: Icons.layers,
            title: '镶边',
            value: settings.flangerEnabled,
            onChanged: (v) =>
                notifier.save(settings.copyWith(flangerEnabled: v)),
          ),
          _switchTile(
            icon: Icons.blur_on,
            title: '相位',
            value: settings.phaserEnabled,
            onChanged: (v) =>
                notifier.save(settings.copyWith(phaserEnabled: v)),
          ),
          _switchTile(
            icon: Icons.compress,
            title: '压缩器',
            value: settings.compressorEnabled,
            onChanged: (v) =>
                notifier.save(settings.copyWith(compressorEnabled: v)),
          ),
          _switchTile(
            icon: Icons.volume_off,
            title: '噪声门',
            value: settings.noiseGateEnabled,
            onChanged: (v) =>
                notifier.save(settings.copyWith(noiseGateEnabled: v)),
          ),
          _switchTile(
            icon: Icons.vertical_align_top,
            title: '限制器',
            value: settings.limiterEnabled,
            onChanged: (v) =>
                notifier.save(settings.copyWith(limiterEnabled: v)),
          ),
          _switchTile(
            icon: Icons.highlight,
            title: '谐波激励器',
            value: settings.exciterEnabled,
            onChanged: (v) =>
                notifier.save(settings.copyWith(exciterEnabled: v)),
          ),
          _switchTile(
            icon: Icons.speaker_group,
            title: '次谐波低音增强',
            value: settings.subBassEnabled,
            onChanged: (v) =>
                notifier.save(settings.copyWith(subBassEnabled: v)),
          ),
          _switchTile(
            icon: Icons.graphic_eq,
            title: 'Lo-Fi 低保真',
            value: settings.loFiEnabled,
            onChanged: (v) =>
                notifier.save(settings.copyWith(loFiEnabled: v)),
          ),
          _switchTile(
            icon: Icons.space_bar,
            title: '立体声拓宽',
            value: settings.stereoWidenEnabled,
            onChanged: (v) =>
                notifier.save(settings.copyWith(stereoWidenEnabled: v)),
          ),
          _switchTile(
            icon: Icons.merge,
            title: '单声道合并',
            value: settings.monoMerge,
            onChanged: (v) =>
                notifier.save(settings.copyWith(monoMerge: v)),
          ),
          _switchTile(
            icon: Icons.swap_horiz,
            title: '左右声道交换',
            value: settings.channelSwap,
            onChanged: (v) =>
                notifier.save(settings.copyWith(channelSwap: v)),
          ),
          _switchTile(
            icon: Icons.auto_awesome,
            title: 'V4A 组合音效',
            value: settings.v4aEnabled,
            onChanged: (v) =>
                notifier.save(settings.copyWith(v4aEnabled: v)),
          ),
          const Divider(height: 1),
          Row(
            children: [
              const Icon(Icons.bolt, color: Color(0xFFEC4141)),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('音量增强',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              Text('${settings.audioBoost.toStringAsFixed(1)} dB'),
            ],
          ),
          Slider(
            min: 0,
            max: 12,
            divisions: 24,
            value: settings.audioBoost.clamp(0, 12),
            onChanged: (v) =>
                notifier.save(settings.copyWith(audioBoost: v)),
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
    );
  }

  Widget _switchTile({
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      secondary: Icon(icon),
      title: Text(title),
      value: value,
      onChanged: onChanged,
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
