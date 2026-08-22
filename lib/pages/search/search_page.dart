import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/player/player_provider.dart';
import '../../src/plugins/plugin_runtime.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/top_notice.dart';

bool isCurrentSearchSong(QueueItem? current, Song song) =>
    current?.path == song.path;

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.initialQuery = ''});

  final String initialQuery;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _PluginSearchState {
  const _PluginSearchState({
    this.songs = const [],
    this.loading = false,
    this.searched = false,
    this.error,
  });

  final List<Song> songs;
  final bool loading;
  final bool searched;
  final String? error;
}

class _SearchPageState extends ConsumerState<SearchPage> {
  static const _historyKey = 'network_search_history_v1';
  static const _historyLimit = 20;

  late final TextEditingController _controller = TextEditingController(
    text: widget.initialQuery,
  );
  final Map<String, _PluginSearchState> _states = {};
  List<String> _history = const [];
  late final Future<void> _historyReady;
  Timer? _debounce;
  int _queryToken = 0;

  @override
  void initState() {
    super.initState();
    _historyReady = _loadHistory();
    if (widget.initialQuery.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search(widget.initialQuery);
      });
    }
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final loaded = _normalizeHistory(
      prefs.getStringList(_historyKey) ?? const [],
    );
    if (!mounted) return;
    setState(() => _history = loaded);
  }

  List<String> _normalizeHistory(Iterable<String> values) {
    final seen = <String>{};
    final normalized = <String>[];
    for (final value in values) {
      final keyword = value.trim();
      if (keyword.isEmpty || !seen.add(keyword.toLowerCase())) continue;
      normalized.add(keyword);
      if (normalized.length == _historyLimit) break;
    }
    return normalized;
  }

  void _recordHistory(String keyword) {
    unawaited(_recordHistoryWhenReady(keyword));
  }

  Future<void> _recordHistoryWhenReady(String keyword) async {
    await _historyReady;
    if (!mounted) return;
    final next = _normalizeHistory([keyword, ..._history]);
    if (next.length == _history.length &&
        next.indexed.every((entry) => entry.$2 == _history[entry.$1])) {
      return;
    }
    setState(() => _history = next);
    await _saveHistory(next);
  }

  Future<void> _saveHistory(List<String> history) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_historyKey, history);
  }

  void _removeHistory(String keyword) {
    final next = _history.where((item) => item != keyword).toList();
    setState(() => _history = next);
    unawaited(_saveHistory(next));
  }

  void _clearHistory() {
    setState(() => _history = const []);
    unawaited(_saveHistory(const []));
  }

  void _searchFromHistory(String keyword) {
    _debounce?.cancel();
    _controller.value = TextEditingValue(
      text: keyword,
      selection: TextSelection.collapsed(offset: keyword.length),
    );
    setState(() {});
    FocusScope.of(context).unfocus();
    unawaited(_search(keyword));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() {});
    _debounce?.cancel();
    final keyword = value.trim();
    if (keyword.isEmpty) {
      _queryToken++;
      setState(_states.clear);
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _search(keyword),
    );
  }

  Future<void> _search(String input) async {
    final keyword = input.trim();
    if (keyword.isEmpty) return;
    _recordHistory(keyword);
    final token = ++_queryToken;
    final plugins = await ref.read(enabledMusicPluginsProvider.future);
    if (!mounted || token != _queryToken) return;
    setState(() {
      for (final plugin in plugins) {
        _states[plugin.id] = const _PluginSearchState(
          loading: true,
          searched: true,
        );
      }
    });
    await Future.wait(
      plugins.map((plugin) => _searchPlugin(plugin, keyword, token)),
    );
  }

  Future<void> _searchPlugin(
    EnabledMusicPlugin plugin,
    String keyword,
    int token,
  ) async {
    try {
      final result = await ref
          .read(pluginRuntimeProvider)
          .search(plugin, keyword);
      final songs = result
          .where((item) => item.title.trim().isNotEmpty)
          .map(
            (item) => Song(
              path:
                  'plugin://${Uri.encodeComponent(plugin.id)}/'
                  '${Uri.encodeComponent(item.id)}',
              title: item.title,
              artist: item.artist,
              album: item.album,
              albumKey: item.album,
              duration: (item.durationMs / 1000).round(),
              format: '网络',
              coverUrl: item.coverUrl,
              pluginId: plugin.id,
              pluginData: item.rawData,
              lyricsRaw: _embeddedLyrics(item.rawData),
            ),
          )
          .toList();
      if (!mounted || token != _queryToken) return;
      setState(() {
        _states[plugin.id] = _PluginSearchState(songs: songs, searched: true);
      });
      unawaited(
        ref
            .read(authProvider.notifier)
            .reportSearch(
              keyword: keyword,
              source: plugin.id,
              resultCount: songs.length,
            )
            .catchError((_) {}),
      );
    } catch (error) {
      if (!mounted || token != _queryToken) return;
      setState(() {
        _states[plugin.id] = _PluginSearchState(
          searched: true,
          error: error.toString().replaceFirst('Exception: ', ''),
        );
      });
    }
  }

  String? _embeddedLyrics(Map<String, dynamic> raw) {
    for (final key in const [
      'yrc',
      'qrc',
      'eslrc',
      'lxlyric',
      'lyric',
      'rawLrc',
      'lrc',
      'lyrics',
    ]) {
      final value = raw[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  void _clear() {
    _controller.clear();
    _debounce?.cancel();
    _queryToken++;
    setState(_states.clear);
  }

  Widget _historyBody({required bool showMiniPlayer}) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        20,
        22,
        20,
        MediaQuery.of(context).padding.bottom + (showMiniPlayer ? 104 : 24),
      ),
      children: [
        if (_history.isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  '搜索历史',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _clearHistory,
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                label: const Text('清空'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              for (final keyword in _history)
                InputChip(
                  avatar: const Icon(Icons.history_rounded, size: 18),
                  label: Text(keyword),
                  onPressed: () => _searchFromHistory(keyword),
                  onDeleted: () => _removeHistory(keyword),
                  deleteIcon: const Icon(Icons.close_rounded, size: 17),
                  deleteButtonTooltipMessage: '删除 $keyword',
                ),
            ],
          ),
          const SizedBox(height: 34),
        ],
        Icon(
          Icons.manage_search_rounded,
          size: 48,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
        const SizedBox(height: 12),
        Text(
          _history.isEmpty ? '搜索网络音乐' : '继续搜索',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 7),
        Text(
          '输入歌曲、歌手或专辑名称，结果将按插件分类展示',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _tabBody(EnabledMusicPlugin plugin, {required bool showMiniPlayer}) {
    final scheme = Theme.of(context).colorScheme;
    final state = _states[plugin.id] ?? const _PluginSearchState();
    if (!state.searched) {
      return Center(
        child: Text(
          '输入关键词，从 ${plugin.name} 搜索网络音乐',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null) {
      return _MessageState(
        icon: Icons.cloud_off_outlined,
        title: '${plugin.name} 搜索失败',
        message: state.error!,
        actionLabel: '重试',
        onAction: () => _search(_controller.text),
      );
    }
    if (state.songs.isEmpty) {
      return const _MessageState(
        icon: Icons.search_off_rounded,
        title: '没有搜索到歌曲',
        message: '可以换一个关键词再试',
      );
    }
    return SongsListView(
      songs: state.songs,
      showFavoriteButton: true,
      padding: EdgeInsets.only(
        top: 6,
        bottom:
            MediaQuery.of(context).padding.bottom + (showMiniPlayer ? 104 : 12),
      ),
      onPlay: _playNetworkSongs,
    );
  }

  Future<void> _playNetworkSongs(List<Song> songs, int index) async {
    final selected = songs[index];
    if (isCurrentSearchSong(ref.read(playerProvider).current, selected)) {
      if (mounted) unawaited(context.push<void>('/player'));
      return;
    }
    // playList 会先同步写入当前歌曲和播放队列，再异步解析插件音源。
    // 因此这里立即打开详情页，让用户直接看到加载、歌词或失败状态。
    final playback = ref.read(libraryProvider.notifier).playList(songs, index);
    if (mounted) unawaited(context.push<void>('/player'));
    await playback;
    if (!mounted) return;
    final error = ref.read(playerProvider).errorMessage;
    if (error != null) {
      XyNotice.show(
        context,
        message: '播放失败：$error',
        type: XyNoticeType.error,
        duration: const Duration(seconds: 5),
        actionLabel: '重试',
        onAction: () => ref.read(playerProvider.notifier).toggle(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pluginsValue = ref.watch(enabledMusicPluginsProvider);
    final plugins = pluginsValue.valueOrNull ?? const <EnabledMusicPlugin>[];
    final showingHistory = _controller.text.trim().isEmpty;
    final showMiniPlayer = ref.watch(
      playerProvider.select((state) => state.current != null),
    );
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return DefaultTabController(
      length: plugins.isEmpty ? 1 : plugins.length,
      child: Scaffold(
        appBar: AppBar(
          title: TextField(
            controller: _controller,
            autofocus: widget.initialQuery.isEmpty,
            textInputAction: TextInputAction.search,
            onChanged: _onChanged,
            onSubmitted: _search,
            decoration: InputDecoration(
              hintText: '搜索网络歌曲、歌手、专辑',
              border: InputBorder.none,
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除',
                      onPressed: _clear,
                      icon: const Icon(Icons.clear, size: 20),
                    ),
            ),
          ),
          bottom: plugins.isEmpty || showingHistory
              ? null
              : TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [for (final plugin in plugins) Tab(text: plugin.name)],
                ),
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: pluginsValue.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => _MessageState(
                  icon: Icons.error_outline,
                  title: '插件列表加载失败',
                  message: error.toString(),
                  actionLabel: '重试',
                  onAction: () => ref.invalidate(enabledMusicPluginsProvider),
                ),
                data: (loadedPlugins) {
                  if (loadedPlugins.isEmpty) {
                    return const _MessageState(
                      icon: Icons.extension_off_outlined,
                      title: '没有可搜索的插件',
                      message: '请先在插件管理中安装并启用 MusicFree 插件',
                    );
                  }
                  if (showingHistory) {
                    return _historyBody(showMiniPlayer: showMiniPlayer);
                  }
                  return TabBarView(
                    children: [
                      for (final plugin in loadedPlugins)
                        _tabBody(plugin, showMiniPlayer: showMiniPlayer),
                    ],
                  );
                },
              ),
            ),
            if (showMiniPlayer)
              Positioned(
                left: 12,
                right: 12,
                bottom: safeBottom + 20,
                child: const MiniPlayerBar(),
              ),
          ],
        ),
      ),
    );
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 7),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
