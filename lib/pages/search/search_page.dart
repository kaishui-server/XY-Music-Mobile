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
import 'online_catalog_detail_page.dart';

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
    this.catalog = const [],
    this.loading = false,
    this.searched = false,
    this.error,
  });

  final List<Song> songs;
  final List<PluginCatalogResult> catalog;
  final bool loading;
  final bool searched;
  final String? error;
}

enum _SearchCategory { songs, artists, albums }

class _SearchPageState extends ConsumerState<SearchPage>
    with SingleTickerProviderStateMixin {
  static const _historyKey = 'network_search_history_v1';
  static const _historyLimit = 50;

  late final TextEditingController _controller = TextEditingController(
    text: widget.initialQuery,
  );
  final Map<String, _PluginSearchState> _states = {};
  late final TabController _categoryController;
  int _selectedPluginIndex = 0;
  _SearchCategory _selectedCategory = _SearchCategory.songs;
  List<String> _history = const [];
  late final Future<void> _historyReady;
  Timer? _debounce;
  int _queryToken = 0;

  @override
  void initState() {
    super.initState();
    _categoryController = TabController(
      length: _SearchCategory.values.length,
      vsync: this,
    );
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
    _categoryController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() {});
    _debounce?.cancel();
    final keyword = value.trim();
    if (keyword.isEmpty) {
      _queryToken++;
      setState(() {
        _states.clear();
        _selectedCategory = _SearchCategory.songs;
        _categoryController.index = 0;
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _search(keyword),
    );
  }

  String _stateKey(String pluginId, _SearchCategory category) =>
      '$pluginId:${category.name}';

  _PluginSearchState _stateFor(
    EnabledMusicPlugin plugin,
    _SearchCategory category,
  ) => _states[_stateKey(plugin.id, category)] ?? const _PluginSearchState();

  Future<void> _search(String input) async {
    final keyword = input.trim();
    if (keyword.isEmpty) return;
    _recordHistory(keyword);
    final token = ++_queryToken;
    final plugins = await ref.read(enabledMusicPluginsProvider.future);
    if (!mounted || token != _queryToken) return;
    setState(() {
      for (final plugin in plugins) {
        _states[_stateKey(plugin.id, _SearchCategory.songs)] =
            const _PluginSearchState(loading: true, searched: true);
        _states[_stateKey(plugin.id, _SearchCategory.artists)] =
            const _PluginSearchState();
        _states[_stateKey(plugin.id, _SearchCategory.albums)] =
            const _PluginSearchState();
      }
    });
    if (_selectedCategory != _SearchCategory.songs) {
      for (var pluginIndex = 0; pluginIndex < plugins.length; pluginIndex++) {
        _ensureCategorySearch(
          plugins,
          pluginIndex: pluginIndex,
          category: _selectedCategory,
        );
      }
    }
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
          .map((item) => _songFromPlugin(plugin, item))
          .toList();
      if (!mounted || token != _queryToken) return;
      setState(() {
        _states[_stateKey(plugin.id, _SearchCategory.songs)] =
            _PluginSearchState(songs: songs, searched: true);
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
        _states[_stateKey(
          plugin.id,
          _SearchCategory.songs,
        )] = _PluginSearchState(
          searched: true,
          error: error.toString().replaceFirst('Exception: ', ''),
        );
      });
    }
  }

  Song _songFromPlugin(EnabledMusicPlugin plugin, PluginSearchSong item) {
    return Song(
      path: pluginSongPath(plugin, item),
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
    );
  }

  Future<void> _openCatalogResult(
    EnabledMusicPlugin plugin,
    _SearchCategory category,
    PluginCatalogResult item,
  ) async {
    final keyword = item.title.trim();
    if (keyword.isEmpty) return;
    // 与电脑版一致：先进入详情页，再在详情页内调用插件详情接口，
    // 避免点击后等待网络请求完成才发生页面跳转。
    final runtime = ref.read(pluginRuntimeProvider);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => OnlineCatalogDetailPage(
          title: keyword,
          subtitle: item.subtitle,
          coverUrl: item.coverUrl,
          categoryLabel: _categoryLabel(category),
          loadSongs: () async {
            final results = category == _SearchCategory.artists
                ? await runtime.getArtistSongs(plugin, item)
                : await runtime.getAlbumSongs(plugin, item);
            return results
                .where((song) => song.title.trim().isNotEmpty)
                .map((song) => _songFromPlugin(plugin, song))
                .toList();
          },
        ),
      ),
    );
  }

  Future<void> _searchPluginCategory(
    EnabledMusicPlugin plugin,
    _SearchCategory category,
    String keyword,
    int token,
  ) async {
    final key = _stateKey(plugin.id, category);
    setState(() {
      _states[key] = const _PluginSearchState(loading: true, searched: true);
    });
    try {
      final runtime = ref.read(pluginRuntimeProvider);
      final catalog = category == _SearchCategory.artists
          ? await runtime.searchArtists(plugin, keyword)
          : await runtime.searchAlbums(plugin, keyword);
      if (!mounted || token != _queryToken) return;
      setState(() {
        _states[key] = _PluginSearchState(catalog: catalog, searched: true);
      });
    } catch (error) {
      if (!mounted || token != _queryToken) return;
      setState(() {
        _states[key] = _PluginSearchState(
          searched: true,
          error: error.toString().replaceFirst('Exception: ', ''),
        );
      });
    }
  }

  void _ensureCategorySearch(
    List<EnabledMusicPlugin> plugins, {
    int? pluginIndex,
    _SearchCategory? category,
  }) {
    final index = pluginIndex ?? _selectedPluginIndex;
    final selected = category ?? _selectedCategory;
    if (index < 0 ||
        index >= plugins.length ||
        selected == _SearchCategory.songs) {
      return;
    }
    final plugin = plugins[index];
    final state = _stateFor(plugin, selected);
    if (state.loading || state.searched || _controller.text.trim().isEmpty) {
      return;
    }
    final token = _queryToken;
    unawaited(
      _searchPluginCategory(plugin, selected, _controller.text.trim(), token),
    );
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
    setState(() {
      _states.clear();
      _selectedCategory = _SearchCategory.songs;
      _categoryController.index = 0;
    });
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
          const SizedBox(height: 4),
          // 使用竖直列表展示历史，避免关键词被挤成块状标签。
          for (var index = 0; index < _history.length; index++) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              minTileHeight: 46,
              leading: Icon(
                Icons.history_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              title: Text(
                _history[index],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: '删除 ${_history[index]}',
                icon: const Icon(Icons.close_rounded, size: 19),
                onPressed: () => _removeHistory(_history[index]),
              ),
              onTap: () => _searchFromHistory(_history[index]),
            ),
          ],
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

  Widget _tabBody(
    EnabledMusicPlugin plugin, {
    required bool showMiniPlayer,
    required _SearchCategory category,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final state = _stateFor(plugin, category);
    if (!state.searched) {
      return Center(
        child: Text(
          category == _SearchCategory.songs
              ? '输入关键词，从 ${plugin.name} 搜索网络音乐'
              : '点击上方“${_categoryLabel(category)}”开始搜索 ${plugin.name} 分类结果',
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
    if (category == _SearchCategory.songs && state.songs.isEmpty ||
        category != _SearchCategory.songs && state.catalog.isEmpty) {
      return const _MessageState(
        icon: Icons.search_off_rounded,
        title: '没有搜索到结果',
        message: '可以换一个关键词再试，或切换其他插件',
      );
    }
    if (category != _SearchCategory.songs) {
      return _CatalogListView(
        items: state.catalog,
        category: category,
        showMiniPlayer: showMiniPlayer,
        onTap: (item) => _openCatalogResult(plugin, category, item),
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

  String _categoryLabel(_SearchCategory category) {
    switch (category) {
      case _SearchCategory.songs:
        return '歌曲';
      case _SearchCategory.artists:
        return '歌手';
      case _SearchCategory.albums:
        return '专辑';
    }
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
    // 失效插件的替代音源搜索由全局播放器统一展示顶部提示，避免这里再用
    // “播放失败”覆盖更准确的“无法找到代替音源”说明。
    if (error != null && !error.contains('无法找到代替音源')) {
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
              : PreferredSize(
                  preferredSize: const Size.fromHeight(92),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TabBar(
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        onTap: (index) {
                          _selectedPluginIndex = index;
                          _ensureCategorySearch(plugins, pluginIndex: index);
                        },
                        tabs: [
                          for (final plugin in plugins) Tab(text: plugin.name),
                        ],
                      ),
                      TabBar(
                        controller: _categoryController,
                        onTap: (index) {
                          final category = _SearchCategory.values[index];
                          setState(() {
                            _selectedCategory = category;
                          });
                          // 分类搜索结果按插件分别展示，切换分类时预取所有插件，
                          // 这样用户左右切换一级插件 Tab 不会看到未加载的空页。
                          for (
                            var pluginIndex = 0;
                            pluginIndex < plugins.length;
                            pluginIndex++
                          ) {
                            _ensureCategorySearch(
                              plugins,
                              pluginIndex: pluginIndex,
                              category: category,
                            );
                          }
                        },
                        tabs: const [
                          Tab(text: '歌曲'),
                          Tab(text: '歌手'),
                          Tab(text: '专辑'),
                        ],
                      ),
                    ],
                  ),
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
                      message: '请先在插件管理中安装并启用 MF 或 LX 插件',
                    );
                  }
                  if (showingHistory) {
                    return _historyBody(showMiniPlayer: showMiniPlayer);
                  }
                  return TabBarView(
                    children: [
                      for (final plugin in loadedPlugins)
                        _tabBody(
                          plugin,
                          category: _selectedCategory,
                          showMiniPlayer: showMiniPlayer,
                        ),
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

class _CatalogListView extends StatelessWidget {
  const _CatalogListView({
    required this.items,
    required this.category,
    required this.showMiniPlayer,
    required this.onTap,
  });

  final List<PluginCatalogResult> items;
  final _SearchCategory category;
  final bool showMiniPlayer;
  final ValueChanged<PluginCatalogResult> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom =
        MediaQuery.of(context).padding.bottom + (showMiniPlayer ? 104 : 16);
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottom),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final item = items[index];
        final isArtist = category == _SearchCategory.artists;
        final cover = item.coverUrl.trim();
        final placeholder = Icon(
          isArtist ? Icons.person_outline_rounded : Icons.album_outlined,
          color: scheme.onSurfaceVariant,
          size: 26,
        );
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 4,
          ),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(isArtist ? 28 : 8),
            child: SizedBox(
              width: 52,
              height: 52,
              child: cover.isEmpty
                  ? ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: Center(child: placeholder),
                    )
                  : Image.network(
                      cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: Center(child: placeholder),
                      ),
                    ),
            ),
          ),
          title: Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: item.subtitle.trim().isEmpty
              ? Text(isArtist ? '歌手' : '专辑')
              : Text(
                  item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => onTap(item),
        );
      },
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
