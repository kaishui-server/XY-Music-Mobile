import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../library/library_provider.dart';
import '../player/player_provider.dart';
import '../plugins/lx_playlist_import.dart' show kLxSourceIds, lxSourceLabel;
import '../plugins/plugin_runtime.dart';
import '../favorites/favorites_provider.dart';
import '../playlists/playlists_provider.dart';

/// 换源：把歌曲切换到其他已启用插件的同名音源。
///
/// 参考闲鱼音乐的换源交互：先选择目标音源（插件列表标记类型），
/// 搜索「歌名 歌手」后按 `recognizedSongMatchScore` 打分取最佳匹配；
/// 单曲换源弹出一体化底部面板（搜索框 + 音源 tab + 候选列表，
/// 排版与关联歌词面板一致），批量换源自动取最高分。

/// 插件类型标记：BakaMusic 系 / MusicFree / 洛雪 / animemusic（与歌单
/// 网络导入对话框一致）。
String sourcePluginTag(EnabledMusicPlugin plugin) => plugin.isLx
    ? '洛雪'
    : plugin.isAnimemusic
    ? 'animemusic'
    : (plugin.isBaka || plugin.name.toLowerCase().contains('baka')
          ? 'BakaMusic'
          : 'MusicFree');

/// 选择换源目标插件的底部菜单（批量换源用）。洛雪插件内含多个平台
/// （kw/kg/tx/wy/mg），选中后追加二级菜单选择具体平台（或全部）；
/// 返回 (插件, 洛雪平台短码|null)，取消返回 null。
Future<(EnabledMusicPlugin, String?)?> showSourcePluginPicker(
  BuildContext context,
  List<EnabledMusicPlugin> plugins, {
  String? excludePluginId,
}) async {
  final picked = await _pickPlugin(context, plugins,
      excludePluginId: excludePluginId);
  if (picked == null || !context.mounted) return null;
  if (!picked.isLx) return (picked, null);
  // 洛雪：二次选择子平台；空串表示「全部平台」，取消（null）则放弃。
  final source = await _pickLxSource(context, picked);
  if (source == null) return null;
  return (picked, source.isEmpty ? null : source);
}

Future<EnabledMusicPlugin?> _pickPlugin(
  BuildContext context,
  List<EnabledMusicPlugin> plugins, {
  String? excludePluginId,
}) {
  final candidates = [
    for (final plugin in plugins)
      if (plugin.id != excludePluginId) plugin,
  ];
  return showModalBottomSheet<EnabledMusicPlugin>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                '选择目标音源',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(sheetContext).colorScheme.onSurface,
                ),
              ),
            ),
            if (candidates.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: Text(
                  '没有其他可用的插件，请先在 设置 → 插件 中启用',
                  style: TextStyle(
                    color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              for (final plugin in candidates)
                ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.extension_rounded,
                    size: 22,
                    color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  ),
                  title: Text(
                    plugin.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  trailing: Text(
                    sourcePluginTag(plugin),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(sheetContext).colorScheme.primary,
                    ),
                  ),
                  onTap: () => Navigator.pop(sheetContext, plugin),
                ),
          ],
        ),
      ),
    ),
  );
}

/// 洛雪子平台二级选择：全部平台（返回空串）+ 插件声明的平台列表
/// （未声明时用洛雪默认五平台）；取消返回 null。
Future<String?> _pickLxSource(
  BuildContext context,
  EnabledMusicPlugin plugin,
) {
  final sources = plugin.lxSources.isEmpty ? kLxSourceIds : plugin.lxSources;
  return showModalBottomSheet<String?>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                '${plugin.name} · 选择平台',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(sheetContext).colorScheme.onSurface,
                ),
              ),
            ),
            ListTile(
              dense: true,
              leading: Icon(
                Icons.all_inclusive_rounded,
                size: 22,
                color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
              ),
              title: const Text(
                '全部平台',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text('跨平台搜索，自动取最佳匹配'),
              onTap: () => Navigator.pop(sheetContext, ''),
            ),
            for (final source in sources)
              ListTile(
                dense: true,
                leading: Icon(
                  Icons.album_rounded,
                  size: 22,
                  color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                ),
                title: Text(
                  lxSourceLabel(source),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                onTap: () => Navigator.pop(sheetContext, source),
              ),
          ],
        ),
      ),
    ),
  );
}

/// 在目标插件上搜索替换候选，按匹配度降序返回（仅保留标题匹配的结果）。
/// [lxSource]：洛雪插件限定子平台（kw/kg/tx/wy/mg），null 为全部平台。
Future<List<PluginSearchSong>> searchReplacementCandidates(
  WidgetRef ref,
  EnabledMusicPlugin plugin, {
  required String title,
  required String artist,
  int durationMs = 0,
  String? lxSource,
}) =>
    searchReplacementCandidatesWithKeyword(
      ref,
      plugin,
      keyword: artist.trim().isEmpty
          ? title.trim()
          : '${title.trim()} ${artist.trim()}',
      title: title,
      artist: artist,
      durationMs: durationMs,
      lxSource: lxSource,
    );

/// 按关键词在目标插件上搜索替换候选。默认关键词（歌名 + 歌手）时按
/// `recognizedSongMatchScore` 过滤并排序；自定义关键词时保留插件原始
/// 排序（最多 50 条），方便手动搜索翻唱、Live 等其他版本。
/// [lxSource]：洛雪插件限定子平台（kw/kg/tx/wy/mg），null 为全部平台。
Future<List<PluginSearchSong>> searchReplacementCandidatesWithKeyword(
  WidgetRef ref,
  EnabledMusicPlugin plugin, {
  required String keyword,
  required String title,
  required String artist,
  int durationMs = 0,
  bool scoreFilter = true,
  String? lxSource,
}) async {
  final results = await ref
      .read(pluginRuntimeProvider)
      .search(plugin, keyword, lxSource: lxSource)
      .timeout(const Duration(seconds: 20), onTimeout: () => const []);
  if (!scoreFilter) return results.take(50).toList();
  final scored = <(int, PluginSearchSong)>[];
  for (final song in results) {
    final score = recognizedSongMatchScore(
      title: title,
      artist: artist,
      durationMs: durationMs,
      candidateTitle: song.title,
      candidateArtist: song.artist,
      candidateDurationMs: song.durationMs,
    );
    if (score >= 100) scored.add((score, song));
  }
  scored.sort((a, b) => b.$1.compareTo(a.$1));
  return [for (final entry in scored) entry.$2];
}

/// 搜索结果 → 可播放/可入库的队列项。
QueueItem replacementToQueueItem(
  EnabledMusicPlugin plugin,
  PluginSearchSong song,
) => QueueItem(
  path: pluginSongPath(plugin, song),
  title: song.title,
  artist: song.artist,
  album: song.album,
  durationMs: song.durationMs,
  pluginId: plugin.id,
  pluginData: song.rawData,
  coverUrl: song.coverUrl,
);

/// 搜索结果 → 歌单曲目。
Song replacementToSong(EnabledMusicPlugin plugin, PluginSearchSong song) =>
    Song(
      path: pluginSongPath(plugin, song),
      title: song.title,
      artist: song.artist,
      album: song.album,
      albumKey: song.album,
      duration: (song.durationMs / 1000).round(),
      format: '网络',
      coverUrl: song.coverUrl,
      pluginId: plugin.id,
      pluginData: song.rawData,
    );

/// 换源后同步「我的收藏」与所有包含该歌的歌单：旧音源条目原位替换
/// 为新插件歌曲（保持顺序、快照与来源归属），无需用户再手动把新歌
/// 重新加回列表。同步失败只忽略，不影响播放队列的换源结果。
Future<void> syncReplacementToCollections(
  WidgetRef ref, {
  required String originalPath,
  required EnabledMusicPlugin plugin,
  required PluginSearchSong replacement,
}) async {
  final song = replacementToSong(plugin, replacement);
  try {
    if (ref.read(favoritesProvider).contains(originalPath)) {
      await ref
          .read(favoritesProvider.notifier)
          .replacePath(originalPath, FavoriteSongSnapshot.fromSong(song));
    }
  } catch (_) {}
  try {
    for (final playlist in ref.read(playlistsProvider)) {
      if (playlist.songPaths.contains(originalPath)) {
        await ref
            .read(playlistsProvider.notifier)
            .replaceSong(playlist.id, originalPath, song);
      }
    }
  } catch (_) {}
}

/// 单曲换源的一体化底部面板：顶部搜索框 + 音源 tab + 候选列表，
/// 排版与「选择插件歌词」面板一致。打开即自动搜索，各音源结果独立
/// 分组展示；点选候选返回 (插件, 歌曲)，取消返回 null。
Future<(EnabledMusicPlugin, PluginSearchSong)?> showSourceSwitchSheet(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required String artist,
  int durationMs = 0,
  String? excludePluginId,
}) {
  return showModalBottomSheet<(EnabledMusicPlugin, PluginSearchSong)>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _SourceSwitchSheet(
      title: title,
      artist: artist,
      durationMs: durationMs,
      excludePluginId: excludePluginId,
    ),
  );
}

class _SourceSwitchSheet extends ConsumerStatefulWidget {
  const _SourceSwitchSheet({
    required this.title,
    required this.artist,
    required this.durationMs,
    this.excludePluginId,
  });

  final String title;
  final String artist;
  final int durationMs;
  final String? excludePluginId;

  @override
  ConsumerState<_SourceSwitchSheet> createState() => _SourceSwitchSheetState();
}

class _SourceSwitchSheetState extends ConsumerState<_SourceSwitchSheet> {
  late final TextEditingController _controller;
  late final String _defaultQuery;
  List<EnabledMusicPlugin> _plugins = const [];
  final Map<String, List<PluginSearchSong>> _results = {};
  final Set<String> _completed = {};
  bool _loadingPlugins = true;
  bool _searching = false;
  bool _searched = false;
  // 搜索防污染：新一轮搜索开始时递增，旧请求的结果直接丢弃。
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _defaultQuery = widget.artist.trim().isEmpty
        ? widget.title.trim()
        : '${widget.title.trim()} ${widget.artist.trim()}';
    _controller = TextEditingController(text: _defaultQuery)
      ..selection = TextSelection.collapsed(offset: _defaultQuery.length);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  @override
  void dispose() {
    _requestId++;
    _controller.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final plugins = await ref.read(enabledMusicPluginsProvider.future);
      if (!mounted) return;
      setState(() {
        _plugins = [
          for (final plugin in plugins)
            if (plugin.id != widget.excludePluginId) plugin,
        ];
        _loadingPlugins = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingPlugins = false);
    }
    await _search();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty || _searching) return;
    final requestId = ++_requestId;
    setState(() {
      _searching = true;
      _searched = true;
      _results.clear();
      _completed.clear();
    });
    final plugins = _plugins;
    if (plugins.isEmpty) {
      if (mounted) setState(() => _searching = false);
      return;
    }
    // 各音源并行搜索，逐个完成后立即展示，无需等全部结束。
    await Future.wait([
      for (final plugin in plugins) _searchPlugin(requestId, plugin, query),
    ]);
    if (mounted && requestId == _requestId) {
      setState(() => _searching = false);
    }
  }

  Future<void> _searchPlugin(
    int requestId,
    EnabledMusicPlugin plugin,
    String query,
  ) async {
    List<PluginSearchSong> songs = const [];
    try {
      songs = await searchReplacementCandidatesWithKeyword(
        ref,
        plugin,
        keyword: query,
        title: widget.title,
        artist: widget.artist,
        durationMs: widget.durationMs,
        // 自定义关键词时不按原曲信息过滤，保留插件原始排序。
        scoreFilter: query == _defaultQuery,
      );
    } catch (_) {
      songs = const [];
    }
    if (!mounted || requestId != _requestId) return;
    setState(() {
      _results[plugin.id] = songs;
      _completed.add(plugin.id);
    });
  }

  String _formatDuration(int durationMs) {
    if (durationMs <= 0) return '';
    final seconds = durationMs ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final availableHeight =
        MediaQuery.sizeOf(context).height - viewInsets.bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: math.min(availableHeight * .82, 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '歌曲换源',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${widget.title} · ${widget.artist}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        enabled: !_searching,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _search(),
                        decoration: const InputDecoration(
                          hintText: '输入歌名、歌手或其他搜索内容',
                          prefixIcon: Icon(Icons.search_rounded),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed:
                          _searching || _controller.text.trim().isEmpty
                          ? null
                          : _search,
                      child: _searching
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('搜索'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '各音源结果独立展示，点击候选歌曲即可换源。',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (_searching && _plugins.isNotEmpty)
                      Text(
                        '${_completed.length}/${_plugins.length} 个音源',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      )
                    else if (_searched && _plugins.isNotEmpty)
                      Text(
                        '共 ${_results.values.fold<int>(0, (sum, list) => sum + list.length)} 个候选',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _buildResults(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    if (_loadingPlugins) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_plugins.isEmpty) {
      return const Center(child: Text('没有其他可用的插件，请先在 设置 → 插件 中启用'));
    }
    return Column(
      children: [
        if (_searching)
          LinearProgressIndicator(
            minHeight: 2,
            value: _completed.length / _plugins.length,
          ),
        Expanded(
          child: DefaultTabController(
            length: _plugins.length,
            child: Column(
              children: [
                Material(
                  color: Colors.transparent,
                  child: TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [
                      for (final plugin in _plugins)
                        Tab(
                          text: _completed.contains(plugin.id)
                              ? '${plugin.name} (${_results[plugin.id]!.length})'
                              : plugin.name,
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      for (final plugin in _plugins) _pluginList(context, plugin),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _pluginList(BuildContext context, EnabledMusicPlugin plugin) {
    if (!_completed.contains(plugin.id)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text('正在搜索 ${plugin.name}…'),
          ],
        ),
      );
    }
    final songs = _results[plugin.id] ?? const <PluginSearchSong>[];
    if (songs.isEmpty) {
      return const Center(child: Text('该音源没有匹配的歌曲'));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: songs.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
      itemBuilder: (context, index) {
        final song = songs[index];
        final artist = song.artist.trim().isEmpty ? '未知歌手' : song.artist;
        final album = song.album.trim();
        final duration = _formatDuration(song.durationMs);
        return ListTile(
          minTileHeight: 64,
          title: Text(
            song.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            album.isEmpty ? artist : '$artist · $album',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 洛雪/animemusic 等「单插件多平台」源显示子平台标签，
              // 区分同一首歌的不同平台候选。
              if (song.platform.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    song.platform,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(
                        context,
                      ).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                duration.isEmpty ? '--:--' : duration,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          onTap: () => Navigator.pop(context, (plugin, song)),
        );
      },
    );
  }
}
