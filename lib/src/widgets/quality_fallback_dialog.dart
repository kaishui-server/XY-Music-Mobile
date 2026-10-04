import 'package:flutter/material.dart';

import '../library/library_provider.dart';
import '../plugins/plugin_runtime.dart' show qualityDisplayLabel;
import 'batch_common.dart';

/// 不支持目标音质的歌曲的处理方式。
enum QualityFallbackAction {
  /// 下载其最高可用音质。
  highest,

  /// 下载其最低可用音质。
  lowest,

  /// 不下载这些歌曲。
  skip,
}

/// 音质回退弹窗的确认结果。
class QualityFallbackDecision {
  const QualityFallbackDecision({
    required this.action,
    required this.selectedPaths,
  });

  /// 用户选择的处理方式。
  final QualityFallbackAction action;

  /// 勾选（纳入下载）的歌曲路径集合；未勾选的歌曲不下载。
  final Set<String> selectedPaths;
}

/// 批量下载前弹出「部分歌曲不支持所选音质」提示：
/// 顶部下拉框选择这些歌曲的处理方式（最高 / 最低 / 不下载），下面是
/// 与批量操作面板一致的勾选框歌曲列表，取消勾选即不下载该歌曲。
///
/// 返回 null 表示用户取消整批下载。
Future<QualityFallbackDecision?> showQualityFallbackDialog(
  BuildContext context, {
  required List<Song> songs,
  required String targetQuality,
}) {
  return showDialog<QualityFallbackDecision>(
    context: context,
    useRootNavigator: true,
    builder: (_) =>
        _QualityFallbackDialog(songs: songs, targetQuality: targetQuality),
  );
}

class _QualityFallbackDialog extends StatefulWidget {
  const _QualityFallbackDialog({
    required this.songs,
    required this.targetQuality,
  });

  final List<Song> songs;
  final String targetQuality;

  @override
  State<_QualityFallbackDialog> createState() => _QualityFallbackDialogState();
}

class _QualityFallbackDialogState extends State<_QualityFallbackDialog> {
  late final Set<String> _selected;
  QualityFallbackAction _action = QualityFallbackAction.highest;

  @override
  void initState() {
    super.initState();
    // 默认全部纳入下载，用户按需取消勾选。
    _selected = {for (final song in widget.songs) song.path};
  }

  bool get _skipping => _action == QualityFallbackAction.skip;

  bool get _allSelected =>
      widget.songs.isNotEmpty && _selected.length == widget.songs.length;

  void _toggle(Song song) {
    setState(() {
      if (!_selected.add(song.path)) _selected.remove(song.path);
    });
  }

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(widget.songs.map((song) => song.path));
      }
    });
  }

  void _submit() {
    Navigator.pop(
      context,
      QualityFallbackDecision(action: _action, selectedPaths: {..._selected}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 弹窗高度自适应：小屏（<600dp）下压缩列表高度，避免整体溢出。
    final contentHeight = (MediaQuery.sizeOf(context).height * 0.46).clamp(
      240.0,
      400.0,
    );
    return AlertDialog(
      title: const Text('部分歌曲不支持所选音质'),
      content: SizedBox(
        width: 380,
        height: contentHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '以下 ${widget.songs.length} 首歌曲无法下载'
              '${qualityDisplayLabel(widget.targetQuality)}，请选择处理方式：',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            CompactDropdownField<QualityFallbackAction>(
              label: '不支持此音质的歌曲',
              value: _action,
              options: const [
                (
                  value: QualityFallbackAction.highest,
                  label: '下载其最高音质',
                ),
                (value: QualityFallbackAction.lowest, label: '下载其最低音质'),
                (value: QualityFallbackAction.skip, label: '不下载这些歌曲'),
              ],
              onChanged: (value) => setState(() => _action = value),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  _skipping
                      ? '以下歌曲将不会被下载'
                      : '已选 ${_selected.length}/${widget.songs.length} 首',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (!_skipping) ...[
                  const Text('全选', style: TextStyle(fontSize: 13)),
                  Checkbox(
                    value: _allSelected,
                    onChanged: (_) => _toggleAll(),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: widget.songs.length,
                itemBuilder: (context, index) {
                  final song = widget.songs[index];
                  return BatchSongCheckTile(
                    song: song,
                    checked: !_skipping && _selected.contains(song.path),
                    enabled: !_skipping,
                    onChanged: (_) => _toggle(song),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(_skipping ? '继续' : '继续下载'),
        ),
      ],
    );
  }
}