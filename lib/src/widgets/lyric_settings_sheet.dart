import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'color_picker_body.dart';

/// 打开播放详情页「歌词设置」底部面板（根 Navigator，覆盖悬浮底栏）。
///
/// 播放详情页更多菜单与设置页「播放详情页歌词」共用同一面板/同一份数据。
Future<void> showLyricSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const LyricSettingsSheet(),
  );
}

/// 歌词设置底部面板：歌词颜色（未播/已播）、字号（主/迷你）、翻译与
/// 罗马音开关、逐字动效、对齐方式集中一处，所有调整即时写入设置。
///
/// - 颜色取色体复用桌面歌词「歌词样式」的 [ColorPickerBody]；十六进制
///   输入会弹软键盘，面板用 viewInsets 底部避让（键盘弹出时整体上移，
///   输入框不被遮挡）。
/// - 「重置颜色」把未播/已播两色恢复为默认白系样式（未播=白 55%）。
class LyricSettingsSheet extends ConsumerStatefulWidget {
  const LyricSettingsSheet({super.key});

  @override
  ConsumerState<LyricSettingsSheet> createState() =>
      _LyricSettingsSheetState();
}

class _LyricSettingsSheetState extends ConsumerState<LyricSettingsSheet> {
  /// 当前取色目标：0=未播歌词 1=已播歌词。
  int _target = 0;
  static const _targets = ['未播歌词', '已播歌词'];

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    if (settings == null) {
      return const SizedBox(height: 120);
    }
    final notifier = ref.read(settingsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final playedColor = Color(settings.playerLyricPlayedColor);
    final unplayedColor = Color(settings.playerLyricUnplayedColor);
    final currentColor = _target == 0 ? unplayedColor : playedColor;
    final fontSize = settings.lyricFontSize;
    return Padding(
      // 底部避让 = 系统安全区 + 软键盘高度：十六进制输入弹出键盘时面板
      // 整体上移，输入框始终可见。
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '歌词设置',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
              // 实时预览：暗色底上按当前颜色 + 字号渲染示例（贴近播放页
              // 歌词页的真实观感）。
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF202028),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '已播放歌词示例',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: playedColor,
                        fontSize: fontSize,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        // 发光效果预览：与逐字渲染同一参数（已播色 65% 辉光）。
                        shadows: settings.lyricGlowEnabled
                            ? [
                                Shadow(
                                  color: playedColor.withValues(alpha: .65),
                                  blurRadius: 8,
                                ),
                              ]
                            : null,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '未播放歌词示例 · 翻译行',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: unplayedColor,
                        fontSize: fontSize,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _sliderRow(
                context,
                icon: Icons.format_size_rounded,
                title: '歌词字号',
                value: fontSize,
                min: 12,
                max: 32,
                divisions: 20,
                onChanged: (value) => notifier.setLyricFontSize(value),
              ),
              _sliderRow(
                context,
                icon: Icons.subtitles_outlined,
                title: '迷你歌词字号',
                value: settings.miniLyricFontSize,
                min: 10,
                max: 24,
                divisions: 14,
                onChanged: (value) => notifier.setMiniLyricFontSize(value),
              ),
              const SizedBox(height: 8),
              _alignmentRow(context, settings.lyricDisplayAlignment),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: Icon(Icons.translate_rounded, color: scheme.primary),
                title: const Text('显示翻译'),
                value: settings.showLyricsTranslation,
                onChanged: (value) => notifier.setShowLyricsTranslation(value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: Icon(
                  Icons.abc_rounded,
                  color: scheme.primary,
                ),
                title: const Text('显示罗马音'),
                value: settings.showLyricsRomaji,
                onChanged: (value) => notifier.setShowLyricsRomaji(value),
              ),
              const SizedBox(height: 6),
              _segmentRow(
                title: '逐字动效',
                labels: const {0: '逐词', 1: '渐进', 2: '关闭'},
                selected: settings.lyricWordEffectMode.index,
                onSelectionChanged: (selection) => notifier
                    .setLyricWordEffectMode(
                      LyricWordEffectMode.values[selection.first],
                    ),
              ),
              const SizedBox(height: 10),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: Icon(
                  Icons.auto_awesome_rounded,
                  color: scheme.primary,
                ),
                title: const Text('歌词光效'),
                subtitle: const Text('逐字歌词按逐字进度发光；无逐字时间戳时激活行整行发光'),
                value: settings.lyricGlowEnabled,
                onChanged: (value) => notifier.setLyricGlowEnabled(value),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.palette_outlined,
                    color: scheme.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    '歌词颜色',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      notifier.setPlayerLyricPlayedColor(
                        kDefaultPlayerLyricPlayedColor,
                      );
                      notifier.setPlayerLyricUnplayedColor(
                        kDefaultPlayerLyricUnplayedColor,
                      );
                    },
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    label: const Text('重置颜色'),
                  ),
                ],
              ),
              SegmentedButton<int>(
                segments: [
                  for (var i = 0; i < _targets.length; i++)
                    ButtonSegment(value: i, label: Text(_targets[i])),
                ],
                selected: {_target},
                showSelectedIcon: false,
                onSelectionChanged: (selection) =>
                    setState(() => _target = selection.first),
              ),
              const SizedBox(height: 14),
              ColorPickerBody(
                // initial 变化时内部 didUpdateWidget 自动重置。
                initial: currentColor.toARGB32(),
                onChanged: (value) => _target == 0
                    ? notifier.setPlayerLyricUnplayedColor(value)
                    : notifier.setPlayerLyricPlayedColor(value),
              ),
              const SizedBox(height: 4),
              Text(
                '颜色、字号与显示开关实时生效并自动保存',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: .5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 对齐方式：占据整行的三段图标选择条（参考设计稿）。
  ///
  /// 与标题行分开布局——标题在上，整行宽度均分给「靠左/居中/靠右」三段；
  /// 段内只显示图标、不显示文字，选中段填充主题色浅底并把图标提亮，未选段
  /// 透明底、图标次级；段与段之间用 1px 细线分隔，整条不加圆角外框，与设计
  /// 稿保持一致。
  Widget _alignmentRow(
    BuildContext context,
    LyricDisplayAlignment selected,
  ) {
    final scheme = Theme.of(context).colorScheme;
    const items = <(LyricDisplayAlignment, IconData, String)>[
      (LyricDisplayAlignment.left, Icons.format_align_left_rounded, '靠左'),
      (LyricDisplayAlignment.center, Icons.format_align_center_rounded, '居中'),
      (LyricDisplayAlignment.right, Icons.format_align_right_rounded, '靠右'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.format_align_left_rounded,
              color: scheme.primary,
              size: 20,
            ),
            const SizedBox(width: 12),
            const Text('对齐方式', style: TextStyle(fontSize: 15)),
          ],
        ),
        const SizedBox(height: 8),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: .6),
            ),
          ),
          child: SizedBox(
            height: 48,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0)
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: scheme.outlineVariant.withValues(alpha: .6),
                    ),
                  Expanded(
                    child: _alignmentSegment(
                      context,
                      icon: items[i].$2,
                      label: items[i].$3,
                      selected: selected == items[i].$1,
                      onTap: () => ref
                          .read(settingsProvider.notifier)
                          .setLyricDisplayAlignment(items[i].$1),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 对齐方式单段：选中浅色主题底 + 主题前景，未选透明底 + 次级前景。
  ///
  /// 段内只保留图标、不显示文字，图标语义（靠左/居中/靠右）通过
  /// [Semantics] 与 [Tooltip] 提供，保证无障碍朗读与长按提示。
  Widget _alignmentSegment(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: .55);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: InkWell(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            color: selected
                ? scheme.primary.withValues(alpha: .16)
                : Colors.transparent,
            alignment: Alignment.center,
            child: Icon(icon, size: 20, color: foreground),
          ),
        ),
      ),
    );
  }

  Widget _sliderRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Row(
          children: [
            Icon(icon, color: scheme.primary, size: 20),
            const SizedBox(width: 12),
            Text(title, style: const TextStyle(fontSize: 15)),
            const Spacer(),
            Text(
              value.toStringAsFixed(0),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: value.toStringAsFixed(0),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _segmentRow({
    required String title,
    required Map<int, String> labels,
    required int selected,
    required ValueChanged<Set<int>> onSelectionChanged,
  }) {
    return Row(
      children: [
        Text(title, style: const TextStyle(fontSize: 15)),
        const Spacer(),
        SegmentedButton<int>(
          segments: [
            for (final entry in labels.entries)
              ButtonSegment(value: entry.key, label: Text(entry.value)),
          ],
          selected: {selected},
          showSelectedIcon: false,
          onSelectionChanged: onSelectionChanged,
          style: const ButtonStyle(
            visualDensity: VisualDensity(horizontal: -3, vertical: -2),
          ),
        ),
      ],
    );
  }
}
