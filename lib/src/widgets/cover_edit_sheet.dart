import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../library/song_cover_edit_actions.dart';

/// 打开「编辑封面」底部面板（根 Navigator，覆盖悬浮底栏）。
///
/// 与「歌词设置」面板同构：顶部标题 + 关闭按钮，下方为当前封面预览与
/// 操作列表。播放详情页更多菜单的「编辑封面」入口与在线封面编辑页共用
/// 同一面板，保证四动作（查看大图 / 保存到相册 / 搜索封面 / 从相册选择）
/// 的位置与行为在各处一致。
Future<void> showCoverEditSheet(BuildContext context, SongCoverEditor editor) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => CoverEditSheet(editor: editor),
  );
}

/// 「编辑封面」底部面板：当前封面预览 + 四项封面对作。
///
/// 动作执行前先收起面板，再由根 Navigator 的 context 拉起大图/搜索面板，
/// 避免面板自身的 context 在 pop 后失效。
class CoverEditSheet extends StatefulWidget {
  const CoverEditSheet({super.key, required this.editor});

  /// 封面编辑执行器（歌曲信息 + 四动作共用的落盘逻辑）。
  final SongCoverEditor editor;

  @override
  State<CoverEditSheet> createState() => _CoverEditSheetState();
}

class _CoverEditSheetState extends State<CoverEditSheet> {
  /// 当前生效封面的字节（预览用，只取一次）。
  late final Future<Uint8List?> _previewBytes =
      widget.editor.loadEffectiveBytes();

  /// 收起面板后执行动作：先在面板存活时留存根 Navigator 的 context，
  /// 再 pop 面板，最后用该 context 打开后续界面。
  void _run(Future<void> Function(BuildContext hostContext) action) {
    final hostContext = Navigator.of(context, rootNavigator: true).context;
    Navigator.pop(context);
    unawaited(action(hostContext));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
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
                    '编辑封面',
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
            _previewBlock(context),
            const SizedBox(height: 10),
            _actionRow(
              context,
              icon: Icons.zoom_in_rounded,
              title: '查看大图',
              subtitle: '全屏查看当前封面，支持双指缩放',
              action: widget.editor.viewLarge,
            ),
            _actionRow(
              context,
              icon: Icons.save_alt_rounded,
              title: '保存到相册',
              subtitle: '把当前封面保存到系统相册',
              action: widget.editor.saveToGallery,
            ),
            _actionRow(
              context,
              icon: Icons.image_search_rounded,
              title: '搜索封面',
              subtitle: '按歌名与作者跨插件检索，找不到时兜底 iTunes',
              action: widget.editor.searchCover,
            ),
            _actionRow(
              context,
              icon: Icons.photo_library_outlined,
              title: '从相册选择',
              subtitle: '使用本机图片作为封面',
              action: widget.editor.pickFromGallery,
            ),
            // 已设置自定义封面时才提供还原入口：清除覆盖表，回到来源
            // 插件提供的原封面。
            if (widget.editor.hasOverride)
              _actionRow(
                context,
                icon: Icons.restart_alt_rounded,
                title: '还原默认封面',
                subtitle: '清除自定义封面，回到来源插件提供的原封面',
                action: widget.editor.reset,
              ),
            const SizedBox(height: 6),
            Text(
              '自定义封面仅保存在本机，不会修改音频文件',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: .5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 预览块：当前封面缩略图 + 歌名/作者 + 封面来源标签。
  Widget _previewBlock(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: .45),
        ),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 64,
              height: 64,
              child: FutureBuilder<Uint8List?>(
                future: _previewBytes,
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  if (bytes != null && bytes.isNotEmpty) {
                    return Image.memory(bytes, fit: BoxFit.cover);
                  }
                  return ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.music_note_rounded,
                      size: 26,
                      color: scheme.onSurfaceVariant.withValues(alpha: .6),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.editor.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  widget.editor.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.editor.hasOverride ? '自定义封面' : '原始封面',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 操作行：图标 + 标题/说明 + 右箭头，整行点击后收起面板执行动作。
  Widget _actionRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Future<void> Function(BuildContext hostContext) action,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => _run(action),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 22, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
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
              color: scheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}
