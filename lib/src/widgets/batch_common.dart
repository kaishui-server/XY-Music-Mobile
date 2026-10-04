import 'package:flutter/material.dart';

import '../library/library_provider.dart';
import 'song_list_view.dart' show SongCover;

/// 紧凑下拉选择框：单行高度（左侧标签 + 当前值 + 下拉箭头），点击后在
/// 控件下方弹出菜单，选中项带勾选。相比原生 DropdownButton 更省空间，
/// 也不会有沉重的输入框描边。批量操作面板与音质回退弹窗共用。
class CompactDropdownField<T> extends StatelessWidget {
  const CompactDropdownField({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.hint = '请选择',
  });

  final String label;
  final T? value;
  final List<({T value, String label})> options;
  final ValueChanged<T> onChanged;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final matched = options.where((option) => option.value == value).toList();
    final currentLabel = matched.isEmpty ? null : matched.first.label;
    return MenuAnchor(
      style: const MenuStyle(
        maximumSize: WidgetStatePropertyAll<Size?>(Size(300, 340)),
      ),
      menuChildren: [
        for (final option in options)
          MenuItemButton(
            onPressed: () => onChanged(option.value),
            leadingIcon: Icon(
              option.value == value ? Icons.check_rounded : null,
              size: 18,
              color: scheme.primary,
            ),
            child: Text(option.label, style: const TextStyle(fontSize: 13)),
          ),
      ],
      builder: (context, controller, _) => InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () =>
            controller.isOpen ? controller.close() : controller.open(),
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: .55),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  currentLabel ?? hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: currentLabel == null
                        ? scheme.onSurfaceVariant
                        : scheme.onSurface,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_drop_down_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 批量操作 / 音质回退列表的歌曲行：封面 + 标题/艺术家 + 勾选框。
class BatchSongCheckTile extends StatelessWidget {
  const BatchSongCheckTile({
    super.key,
    required this.song,
    required this.checked,
    required this.onChanged,
    this.enabled = true,
  });

  final Song song;
  final bool checked;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final subtitle = [song.artist, song.album]
        .where((part) => part.trim().isNotEmpty)
        .join(' · ');
    return InkWell(
      onTap: enabled ? () => onChanged(!checked) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            SongCover(song: song, size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Checkbox(
              value: checked,
              onChanged: enabled ? (_) => onChanged(!checked) : null,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}