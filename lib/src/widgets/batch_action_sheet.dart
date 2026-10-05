import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../library/library_provider.dart';
import '../plugins/lx_playlist_import.dart' show kLxSourceIds, lxSourceLabel;
import '../plugins/plugin_runtime.dart';
import '../playlists/playlists_provider.dart';
import 'song_list_view.dart' show SongCover;

/// 通用批量操作类型：批量下载 / 批量换源 / 批量保存到歌单 / 批量收藏 /
/// 批量取消收藏 / 批量删除（删除仅对本地歌单开放）。
enum BatchActionKind {
  download,
  switchSource,
  saveToPlaylist,
  favorite,
  unfavorite,
  delete,
}

/// 下载音质档位（与设置页“下载音质”、批量下载对话框一致，低 → 高）。
const List<String> kBatchDownloadQualities = [
  '96k',
  '128k',
  '192k',
  '320k',
  'flac',
  'flac24bit',
  'hires',
  'vinyl',
  'dolby',
  'atmos',
  'atmos_plus',
  'master',
];

/// 「新建歌单」在目标歌单下拉框中的哨兵值。
const String _kNewPlaylistValue = '__new_playlist__';

/// 洛雪类插件「全部平台」在子平台下拉框中的哨兵值。
const String _kAllPlatforms = '';

/// 通用批量操作面板：顶部用紧凑下拉框选择（音质 / 换源插件 / 目标歌单，
/// 歌单支持直接新建），中部「已选 xx/xx 首」+ 全选，下面是带勾选框与
/// 封面的歌曲列表，底部是「下载/换源/添加到歌单(xx首)」按钮。
///
/// 三个批量入口共用同一套选择交互，仅顶部的下拉框与底部按钮文案不同。
Future<void> showBatchActionSheet(
  BuildContext context, {
  required BatchActionKind kind,
  required List<Song> songs,
  Future<void> Function(List<Song> selected, String quality)? onDownload,
  Future<void> Function(
    List<Song> selected,
    EnabledMusicPlugin plugin,
    String? lxSource,
  )?
  onSwitchSource,
  Future<void> Function(List<Song> selected, String playlistId)?
  onSaveToPlaylist,
  Future<void> Function(List<Song> selected)? onFavorite,
  Future<void> Function(List<Song> selected)? onUnfavorite,
  Future<void> Function(List<Song> selected)? onDelete,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _BatchActionSheet(
      kind: kind,
      songs: songs,
      onDownload: onDownload,
      onSwitchSource: onSwitchSource,
      onSaveToPlaylist: onSaveToPlaylist,
      onFavorite: onFavorite,
      onUnfavorite: onUnfavorite,
      onDelete: onDelete,
    ),
  );
}

class _BatchActionSheet extends ConsumerStatefulWidget {
  const _BatchActionSheet({
    required this.kind,
    required this.songs,
    this.onDownload,
    this.onSwitchSource,
    this.onSaveToPlaylist,
    this.onFavorite,
    this.onUnfavorite,
    this.onDelete,
  });

  final BatchActionKind kind;
  final List<Song> songs;
  final Future<void> Function(List<Song> selected, String quality)? onDownload;
  final Future<void> Function(
    List<Song> selected,
    EnabledMusicPlugin plugin,
    String? lxSource,
  )?
  onSwitchSource;
  final Future<void> Function(List<Song> selected, String playlistId)?
  onSaveToPlaylist;
  final Future<void> Function(List<Song> selected)? onFavorite;
  final Future<void> Function(List<Song> selected)? onUnfavorite;
  final Future<void> Function(List<Song> selected)? onDelete;

  @override
  ConsumerState<_BatchActionSheet> createState() => _BatchActionSheetState();
}

class _BatchActionSheetState extends ConsumerState<_BatchActionSheet> {
  late final Set<String> _selected;

  // 下载：音质档位。
  late String _quality;
  // 换源：目标插件与洛雪子平台（null 表示全部平台）。
  EnabledMusicPlugin? _plugin;
  String? _lxSource;
  // 保存歌单：目标歌单 id。
  String? _playlistId;

  @override
  void initState() {
    super.initState();
    // 进入批量面板默认全选，用户再按需取消。
    _selected = {for (final song in widget.songs) song.path};
    _quality =
        ref.read(settingsProvider).valueOrNull?.downloadQuality ?? '320k';
  }

  void _toggle(Song song) {
    setState(() {
      if (!_selected.add(song.path)) _selected.remove(song.path);
    });
  }

  bool get _allSelected =>
      widget.songs.isNotEmpty && _selected.length == widget.songs.length;

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

  List<Song> get _selectedSongs => [
    for (final song in widget.songs)
      if (_selected.contains(song.path)) song,
  ];

  String get _title => switch (widget.kind) {
    BatchActionKind.download => '批量下载',
    BatchActionKind.switchSource => '批量换源',
    BatchActionKind.saveToPlaylist => '批量保存到歌单',
    BatchActionKind.favorite => '批量收藏',
    BatchActionKind.unfavorite => '批量取消收藏',
    BatchActionKind.delete => '批量删除',
  };

  String get _actionLabel => switch (widget.kind) {
    BatchActionKind.download => '下载',
    BatchActionKind.switchSource => '换源',
    BatchActionKind.saveToPlaylist => '添加到歌单',
    BatchActionKind.favorite => '收藏',
    BatchActionKind.unfavorite => '取消收藏',
    BatchActionKind.delete => '删除',
  };

  /// 收藏 / 取消收藏 / 删除无需顶部选择项，直接展示歌曲列表。
  bool get _hasSelector =>
      widget.kind != BatchActionKind.favorite &&
      widget.kind != BatchActionKind.unfavorite &&
      widget.kind != BatchActionKind.delete;

  bool get _canSubmit {
    if (_selected.isEmpty) return false;
    return switch (widget.kind) {
      BatchActionKind.download => true,
      BatchActionKind.switchSource => _plugin != null,
      BatchActionKind.saveToPlaylist => _playlistId != null,
      BatchActionKind.favorite => true,
      BatchActionKind.unfavorite => true,
      BatchActionKind.delete => true,
    };
  }

  /// 先关闭面板再执行动作：下载/换源耗时较长，进度提示与结果回到宿主
  /// 页面展示，避免面板一直挂着一个遮罩。
  Future<void> _submit() async {
    if (!_canSubmit) return;
    final selected = _selectedSongs;
    final kind = widget.kind;
    final quality = _quality;
    final plugin = _plugin;
    final lxSource = _lxSource;
    final playlistId = _playlistId;
    Navigator.pop(context);
    switch (kind) {
      case BatchActionKind.download:
        await widget.onDownload?.call(selected, quality);
      case BatchActionKind.switchSource:
        if (plugin != null) {
          await widget.onSwitchSource?.call(selected, plugin, lxSource);
        }
      case BatchActionKind.saveToPlaylist:
        if (playlistId != null) {
          await widget.onSaveToPlaylist?.call(selected, playlistId);
        }
      case BatchActionKind.favorite:
        await widget.onFavorite?.call(selected);
      case BatchActionKind.unfavorite:
        await widget.onUnfavorite?.call(selected);
      case BatchActionKind.delete:
        await widget.onDelete?.call(selected);
    }
  }

  /// 新建歌单并选中，供“批量保存到歌单”下拉框直接创建。
  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(hintText: '请输入歌单名称'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || name == null || name.trim().isEmpty) return;
    final playlist = await ref.read(playlistsProvider.notifier).create(name);
    if (!mounted || playlist == null) return;
    setState(() => _playlistId = playlist.id);
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final viewInsets = MediaQuery.viewInsetsOf(context);
    return AnimatedPadding(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: (height - viewInsets.bottom) * .82,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  _title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              // 下拉菜单是浮层，限高只约束关闭态的控件高度。
              if (_hasSelector) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(child: _buildSelector(context)),
                ),
                const Divider(height: 16),
              ],
              _buildSelectAllRow(context),
              const Divider(height: 1),
              Expanded(child: _buildSongList(context)),
              const Divider(height: 1),
              _buildSubmitBar(context),
            ],
          ),
        ),
      ),
    );
  }

  /// 顶部下拉框：按批量类型展示音质 / 换源插件 / 目标歌单。
  Widget _buildSelector(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
      child: switch (widget.kind) {
        BatchActionKind.download => _DropdownField<String>(
          label: '下载音质',
          value: _quality,
          options: [
            for (final quality in kBatchDownloadQualities)
              (value: quality, label: qualityDisplayLabel(quality)),
          ],
          onChanged: (value) => setState(() => _quality = value),
        ),
        BatchActionKind.switchSource => _buildPluginSelector(context),
        BatchActionKind.saveToPlaylist => _buildPlaylistSelector(context),
        BatchActionKind.favorite ||
        BatchActionKind.unfavorite ||
        BatchActionKind.delete =>
          const SizedBox.shrink(),
      },
    );
  }

  Widget _buildPluginSelector(BuildContext context) {
    final pluginsAsync = ref.watch(enabledMusicPluginsProvider);
    return pluginsAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => const Text('插件加载失败'),
      data: (plugins) {
        if (plugins.isEmpty) {
          return const Text('没有可用插件，请先在 设置 → 插件 中启用');
        }
        final plugin = _plugin;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DropdownField<String>(
              label: '换源插件',
              value: plugin?.id,
              hint: '请选择插件',
              options: [
                for (final item in plugins) (value: item.id, label: item.name),
              ],
              onChanged: (value) => setState(() {
                _plugin = plugins.firstWhere((item) => item.id == value);
                _lxSource = null;
              }),
            ),
            // 洛雪类插件内含多平台，追加一个子平台下拉框（默认全部平台）。
            if (plugin != null && plugin.isLx) ...[
              const SizedBox(height: 8),
              _DropdownField<String>(
                label: '${plugin.name} · 平台',
                value: _lxSource ?? _kAllPlatforms,
                options: [
                  (value: _kAllPlatforms, label: '全部平台'),
                  for (final source in (plugin.lxSources.isEmpty
                      ? kLxSourceIds
                      : plugin.lxSources))
                    (value: source, label: lxSourceLabel(source)),
                ],
                onChanged: (value) =>
                    setState(() => _lxSource = value.isEmpty ? null : value),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildPlaylistSelector(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);
    return _DropdownField<String>(
      label: '保存到歌单',
      value: _playlistId,
      hint: '请选择歌单',
      options: [
        (value: _kNewPlaylistValue, label: '＋ 新建歌单…'),
        for (final playlist in playlists)
          (value: playlist.id, label: playlist.name),
      ],
      onChanged: (value) {
        if (value == _kNewPlaylistValue) {
          // 选择“新建歌单”只弹创建框，创建成功后自动选中新歌单。
          _createPlaylist();
        } else {
          setState(() => _playlistId = value);
        }
      },
    );
  }

  Widget _buildSelectAllRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
      child: Row(
        children: [
          Text(
            '已选 ${_selected.length}/${widget.songs.length} 首',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          const Text('全选', style: TextStyle(fontSize: 13)),
          Checkbox(
            value: _allSelected,
            onChanged: (_) => _toggleAll(),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildSongList(BuildContext context) {
    if (widget.songs.isEmpty) {
      return const Center(child: Text('暂无可操作的歌曲'));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: widget.songs.length,
      itemBuilder: (context, index) {
        final song = widget.songs[index];
        final checked = _selected.contains(song.path);
        final subtitle = [song.artist, song.album]
            .where((part) => part.trim().isNotEmpty)
            .join(' · ');
        return InkWell(
          onTap: () => _toggle(song),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(
              children: [
                // 面板内始终加载封面（含网络封面），保证列表可见封面图。
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
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Checkbox(
                  value: checked,
                  onChanged: (_) => _toggle(song),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSubmitBar(BuildContext context) {
    final count = _selected.length;
    final isDestructive =
        widget.kind == BatchActionKind.delete ||
        widget.kind == BatchActionKind.unfavorite;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: SizedBox(
        height: 46,
        child: FilledButton(
          onPressed: _canSubmit ? _submit : null,
          style: isDestructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                )
              : null,
          child: Text('$_actionLabel($count 首)'),
        ),
      ),
    );
  }
}

/// 紧凑下拉选择框：单行高度（左侧标签 + 当前值 + 下拉箭头），点击后在
/// 控件下方弹出菜单，选中项带勾选。相比原生 DropdownButton 更省空间，
/// 也不会有沉重的输入框描边。
class _DropdownField<T> extends StatelessWidget {
  const _DropdownField({
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