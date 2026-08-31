import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/core/settings.dart';
import '../../src/library/library_provider.dart';
import '../../src/navigation/animated_page_route.dart';
import '../../src/navigation/sidebar_controller.dart';
import '../../src/player/player_provider.dart';
import '../../src/plugins/plugin_runtime.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/top_notice.dart';
import 'online_catalog_detail_page.dart';

bool isCurrentSearchSong(QueueItem? current, Song song) =>
    current?.path == song.path;

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({
    super.key,
    this.initialQuery = '',
    this.showSidebarButton = false,
    this.embeddedInShell = false,
    this.exploreMode = false,
  });

  final String initialQuery;
  final bool showSidebarButton;
  final bool embeddedInShell;
  final bool exploreMode;

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

enum _SearchCategory { songs, artists, albums, playlists }

/// 搜索来源 Tab 的展示模型，与电脑版 Search.vue 的 SourceItem 对应。
///
/// MusicFree 插件一个插件一个 Tab；LX 插件内含多个平台音源
/// （kw/kg/tx/wy/mg），多平台时按平台拆成独立 Tab，搜索请求只查
/// 对应平台，避免所有平台结果混在一个插件名下。
class _SearchSourceTab {
  const _SearchSourceTab({
    required this.plugin,
    required this.name,
    required this.key,
    this.lxSource,
  });

  final EnabledMusicPlugin plugin;

  /// Tab 标题：多平台 LX 显示平台名，其余显示插件名。
  final String name;

  /// 状态存储键：插件 id 或“插件id__平台id”，保证各 Tab 状态独立。
  final String key;

  /// LX 插件拆分后的具体平台标识，非 LX 插件为 null。
  final String? lxSource;
}

/// LX 平台显示名，与电脑版 lxMusicSdk 的 LX_SOURCE_NAMES 一致。
const _lxSourceNames = <String, String>{
  'kw': '小蜗音乐',
  'kg': '小枸音乐',
  'tx': '小秋音乐',
  'wy': '小芸音乐',
  'mg': '小蜜音乐',
};

/// 把已启用插件列表转换成搜索 Tab 列表（仿电脑版 refreshPluginSourceList）。
List<_SearchSourceTab> _buildSearchSourceTabs(
  List<EnabledMusicPlugin> plugins,
) {
  final tabs = <_SearchSourceTab>[];
  for (final plugin in plugins) {
    if (!plugin.isLx) {
      tabs.add(
        _SearchSourceTab(plugin: plugin, name: plugin.name, key: plugin.id),
      );
      continue;
    }
    final sources = plugin.lxSources.isEmpty
        ? const ['kw', 'kg', 'tx', 'wy', 'mg']
        : plugin.lxSources
              .where(_lxSourceNames.containsKey)
              .toList(growable: false);
    if (sources.isEmpty) {
      tabs.add(
        _SearchSourceTab(plugin: plugin, name: plugin.name, key: plugin.id),
      );
      continue;
    }
    if (sources.length == 1) {
      tabs.add(
        _SearchSourceTab(
          plugin: plugin,
          name: plugin.name,
          key: plugin.id,
          lxSource: sources.first,
        ),
      );
      continue;
    }
    for (final source in sources) {
      tabs.add(
        _SearchSourceTab(
          plugin: plugin,
          name: _lxSourceNames[source]!,
          key: '${plugin.id}__$source',
          lxSource: source,
        ),
      );
    }
  }
  return tabs;
}

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
  final ScrollController _historyController = ScrollController();
  final FocusNode _searchFocusNode = FocusNode();
  int _inputRevision = 0;
  int _searchedRevision = -1;
  int _queryToken = 0;
  DateTime _lastInputAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _submitConfirmTimer;

  @override
  void initState() {
    super.initState();
    _categoryController = TabController(
      length: _SearchCategory.values.length,
      vsync: this,
    );
    _searchFocusNode.addListener(_onSearchFocusChanged);
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
    _submitConfirmTimer?.cancel();
    _searchFocusNode
      ..removeListener(_onSearchFocusChanged)
      ..dispose();
    _categoryController.dispose();
    _controller.dispose();
    _historyController.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _lastInputAt = DateTime.now();
    // 部分输入法的“搜索”动作先于字符提交到达：确认期内文本又发生了
    // 变化，说明该动作是随本次字符误发的，取消挂起的提交。
    _submitConfirmTimer?.cancel();
    _submitConfirmTimer = null;
    _inputRevision++;
    setState(() {});
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
  }

  /// 键盘“搜索”动作的提交处理（带误报甄别）。
  ///
  /// 部分中文输入法（搜狗等）在候选字上屏时会随字符误发一次“搜索”
  /// 动作，且动作与字符提交的先后顺序不定：
  /// 1. 动作在字符提交**之后**到达——距最近一次输入不足 100ms，直接忽略；
  /// 2. 动作在字符提交**之前**到达——先挂起 200ms 确认定时器，若期间
  ///    文本发生变化（字符随后到达）则取消，视为误报。
  /// 只有确认期内文本始终未变的动作才视为用户真实按下搜索键，此时才
  /// 收起键盘并执行搜索。
  void _onSubmitted(String value) {
    if (DateTime.now().difference(_lastInputAt) <
        const Duration(milliseconds: 100)) {
      return;
    }
    _submitConfirmTimer?.cancel();
    _submitConfirmTimer = Timer(const Duration(milliseconds: 200), () {
      _submitConfirmTimer = null;
      if (!mounted) return;
      final keyword = _controller.text.trim();
      if (keyword.isEmpty) return;
      _searchFocusNode.unfocus();
      unawaited(_search(keyword));
    });
  }

  void _onSearchFocusChanged() {
    if (_searchFocusNode.hasFocus) return;
    final keyword = _controller.text.trim();
    if (keyword.isNotEmpty && _searchedRevision != _inputRevision) {
      unawaited(_search(keyword));
    }
  }

  String _stateKey(String tabKey, _SearchCategory category) =>
      '$tabKey:${category.name}';

  _PluginSearchState _stateForTab(
    _SearchSourceTab tab,
    _SearchCategory category,
  ) => _states[_stateKey(tab.key, category)] ?? const _PluginSearchState();

  Future<void> _search(String input) async {
    final keyword = input.trim();
    if (keyword.isEmpty) return;
    _searchedRevision = _inputRevision;
    _recordHistory(keyword);
    final token = ++_queryToken;
    final plugins = await ref.read(enabledMusicPluginsProvider.future);
    if (!mounted || token != _queryToken) return;
    final tabs = _buildSearchSourceTabs(plugins);
    setState(() {
      for (final tab in tabs) {
        _states[_stateKey(tab.key, _SearchCategory.songs)] =
            const _PluginSearchState(loading: true, searched: true);
        _states[_stateKey(tab.key, _SearchCategory.artists)] =
            const _PluginSearchState();
        _states[_stateKey(tab.key, _SearchCategory.albums)] =
            const _PluginSearchState();
        _states[_stateKey(tab.key, _SearchCategory.playlists)] =
            const _PluginSearchState();
      }
    });
    if (_selectedCategory != _SearchCategory.songs) {
      for (var tabIndex = 0; tabIndex < tabs.length; tabIndex++) {
        _ensureCategorySearch(
          tabs,
          pluginIndex: tabIndex,
          category: _selectedCategory,
        );
      }
    }
    await Future.wait(
      tabs.map((tab) => _searchTabSource(tab, keyword, token)),
    );
  }

  Future<void> _searchTabSource(
    _SearchSourceTab tab,
    String keyword,
    int token,
  ) async {
    try {
      final result = await ref
          .read(pluginRuntimeProvider)
          .search(tab.plugin, keyword, lxSource: tab.lxSource);
      final songs = result
          .where((item) => item.title.trim().isNotEmpty)
          .map((item) => _songFromPlugin(tab.plugin, item))
          .toList();
      if (!mounted || token != _queryToken) return;
      setState(() {
        _states[_stateKey(tab.key, _SearchCategory.songs)] =
            _PluginSearchState(songs: songs, searched: true);
      });
      unawaited(
        ref
            .read(authProvider.notifier)
            .reportSearch(
              keyword: keyword,
              source: tab.plugin.id,
              resultCount: songs.length,
            )
            .catchError((_) {}),
      );
    } catch (error) {
      if (!mounted || token != _queryToken) return;
      setState(() {
        _states[_stateKey(
          tab.key,
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
    _SearchSourceTab tab,
    _SearchCategory category,
    PluginCatalogResult item,
  ) async {
    final plugin = tab.plugin;
    final keyword = item.title.trim();
    if (keyword.isEmpty) return;
    // 与电脑版一致：先进入详情页，再在详情页内调用插件详情接口，
    // 避免点击后等待网络请求完成才发生页面跳转。
    final runtime = ref.read(pluginRuntimeProvider);
    await Navigator.of(context).push<void>(
      XyAnimatedPageRoute(
        builder: (_) => OnlineCatalogDetailPage(
          title: keyword,
          subtitle: item.subtitle,
          coverUrl: item.coverUrl,
          categoryLabel: _categoryLabelForPlugin(category, plugin),
          loadSongs: () async {
            final results = switch (category) {
              _SearchCategory.artists => await runtime.getArtistSongs(
                plugin,
                item,
                lxSource: tab.lxSource,
              ),
              _SearchCategory.albums => await runtime.getAlbumSongs(
                plugin,
                item,
                lxSource: tab.lxSource,
              ),
              _SearchCategory.playlists => await _loadPlaylistSongs(
                runtime,
                plugin,
                item,
              ),
              _SearchCategory.songs => const <PluginSearchSong>[],
            };
            return results
                .where((song) => song.title.trim().isNotEmpty)
                .map((song) => _songFromPlugin(plugin, song))
                .toList();
          },
        ),
      ),
    );
  }

  Future<List<PluginSearchSong>> _loadPlaylistSongs(
    PluginRuntimeService runtime,
    EnabledMusicPlugin plugin,
    PluginCatalogResult item,
  ) async {
    final raw = item.rawData;
    final input = <String>[
      for (final key in const [
        'id',
        'playlistId',
        'playlist_id',
        'sheetId',
        'sheet_id',
        'albumId',
        'album_id',
        'url',
        'link',
      ])
        if (raw[key]?.toString().trim().isNotEmpty == true)
          raw[key].toString().trim(),
      if (item.id.trim().isNotEmpty) item.id.trim(),
      item.title.trim(),
    ].firstWhere((value) => value.isNotEmpty);
    final imported = await runtime.importPlaylist(plugin, input);
    return imported.songs;
  }

  Future<void> _searchPluginCategory(
    _SearchSourceTab tab,
    _SearchCategory category,
    String keyword,
    int token,
  ) async {
    final plugin = tab.plugin;
    final key = _stateKey(tab.key, category);
    setState(() {
      _states[key] = const _PluginSearchState(loading: true, searched: true);
    });
    try {
      final runtime = ref.read(pluginRuntimeProvider);
      final catalog = switch (category) {
        _SearchCategory.artists => await runtime.searchArtists(
          plugin,
          keyword,
          lxSource: tab.lxSource,
        ),
        _SearchCategory.albums => await runtime.searchAlbums(
          plugin,
          keyword,
          lxSource: tab.lxSource,
        ),
        _SearchCategory.playlists => await runtime.searchPlaylists(
          plugin,
          keyword,
          includeAlbums: false,
        ),
        _SearchCategory.songs => const <PluginCatalogResult>[],
      };
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
    List<_SearchSourceTab> tabs, {
    int? pluginIndex,
    _SearchCategory? category,
  }) {
    final index = pluginIndex ?? _selectedPluginIndex;
    final selected = category ?? _selectedCategory;
    if (index < 0 || index >= tabs.length || selected == _SearchCategory.songs) {
      return;
    }
    final tab = tabs[index];
    final state = _stateForTab(tab, selected);
    if (state.loading || state.searched || _controller.text.trim().isEmpty) {
      return;
    }
    final token = _queryToken;
    unawaited(
      _searchPluginCategory(tab, selected, _controller.text.trim(), token),
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
    _queryToken++;
    setState(() {
      _states.clear();
      _selectedCategory = _SearchCategory.songs;
      _categoryController.index = 0;
    });
  }

  Widget _historyBody({required bool showMiniPlayer}) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        ListView(
          controller: _historyController,
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
              '输入歌曲、歌手、专辑或歌单名称，结果将按插件分类展示',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            if (widget.exploreMode) ...[
              const SizedBox(height: 34),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '推荐',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 72),
            ],
          ],
        ),
        ScrollToTopButton(
          controller: _historyController,
          hasMiniPlayer: showMiniPlayer,
        ),
      ],
    );
  }

  Widget _tabBody(
    _SearchSourceTab tab, {
    required bool showMiniPlayer,
    required _SearchCategory category,
  }) {
    final plugin = tab.plugin;
    final scheme = Theme.of(context).colorScheme;
    final state = _stateForTab(tab, category);
    if (!state.searched) {
      return Center(
        child: Text(
          category == _SearchCategory.songs
              ? '输入关键词，从 ${tab.name} 搜索网络音乐'
              : '点击上方“${_categoryLabelForPlugin(category, plugin)}”开始搜索 ${tab.name} 分类结果',
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
        title: '${tab.name} 搜索失败',
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
        categoryLabel: _categoryLabelForPlugin(category, plugin),
        showMiniPlayer: showMiniPlayer,
        onTap: (item) => _openCatalogResult(tab, category, item),
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

  String _categoryLabelForPlugin(
    _SearchCategory category,
    EnabledMusicPlugin? plugin,
  ) {
    switch (category) {
      case _SearchCategory.songs:
        return '歌曲';
      case _SearchCategory.artists:
        return plugin != null && isBilibiliPluginSource(plugin) ? 'UP主' : '歌手';
      case _SearchCategory.albums:
        return '专辑';
      case _SearchCategory.playlists:
        return '歌单';
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
    // 插件列表先按 LX 平台拆分成搜索 Tab：多平台 LX 插件每个平台
    // 一个 Tab，其余插件一个插件一个 Tab（仿电脑版行为）。
    final tabs = _buildSearchSourceTabs(plugins);
    final showingHistory = _controller.text.trim().isEmpty;
    final showMiniPlayer =
        ref.watch(playerProvider.select((state) => state.current != null)) &&
        !widget.embeddedInShell;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final sidebarOnRight = ref.watch(
      settingsProvider.select(
        (value) => value.valueOrNull?.sidebarPosition == SidebarPosition.right,
      ),
    );
    return DefaultTabController(
      length: tabs.isEmpty ? 1 : tabs.length,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading:
              !widget.showSidebarButton && !widget.embeddedInShell,
          leading: widget.showSidebarButton && !sidebarOnRight
              ? const AppSidebarMenuButton()
              : null,
          title: TextField(
            controller: _controller,
            focusNode: _searchFocusNode,
            autofocus: widget.initialQuery.isEmpty,
            textInputAction: TextInputAction.search,
            onChanged: _onChanged,
            // 空实现：覆盖框架默认的“收到键盘动作即失焦收起键盘”行为，
            // 由 _onSubmitted 自行决定何时收起键盘。
            onEditingComplete: () {},
            onSubmitted: _onSubmitted,
            decoration: InputDecoration(
              hintText: '搜索网络歌曲、歌手、专辑、歌单',
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
          actions: [
            if (widget.showSidebarButton && sidebarOnRight)
              const AppSidebarMenuButton(),
          ],
          // TabBar 始终挂载（只要插件列表非空），不随输入文本有无变化。
          // 否则输入第一个字符时 AppBar 底部从无到有挂载（高度突增 92px），
          // 输入法组词期间发生布局重排会导致键盘被强制收起，输入被打断。
          // body 仍按是否有文本在历史页/结果页之间切换。
          bottom: tabs.isEmpty
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
                          setState(() => _selectedPluginIndex = index);
                          _ensureCategorySearch(tabs, pluginIndex: index);
                        },
                        tabs: [
                          for (final tab in tabs) Tab(text: tab.name),
                        ],
                      ),
                      TabBar(
                        controller: _categoryController,
                        onTap: (index) {
                          final category = _SearchCategory.values[index];
                          setState(() {
                            _selectedCategory = category;
                          });
                          // 分类搜索结果按来源 Tab 分别展示，切换分类时预取
                          // 所有 Tab，这样用户左右切换一级 Tab 不会看到
                          // 未加载的空页。
                          for (
                            var tabIndex = 0; tabIndex < tabs.length; tabIndex++
                          ) {
                            _ensureCategorySearch(
                              tabs,
                              pluginIndex: tabIndex,
                              category: category,
                            );
                          }
                        },
                        tabs: [
                          const Tab(text: '歌曲'),
                          Tab(
                            text:
                                tabs.isNotEmpty &&
                                    _selectedPluginIndex >= 0 &&
                                    _selectedPluginIndex < tabs.length &&
                                    isBilibiliPluginSource(
                                      tabs[_selectedPluginIndex].plugin,
                                    )
                                ? 'UP主'
                                : '歌手',
                          ),
                          const Tab(text: '专辑'),
                          const Tab(text: '歌单'),
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
                      for (final tab in tabs)
                        _tabBody(
                          tab,
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

class _CatalogListView extends StatefulWidget {
  const _CatalogListView({
    required this.items,
    required this.category,
    required this.categoryLabel,
    required this.showMiniPlayer,
    required this.onTap,
  });

  final List<PluginCatalogResult> items;
  final _SearchCategory category;
  final String categoryLabel;
  final bool showMiniPlayer;
  final ValueChanged<PluginCatalogResult> onTap;

  @override
  State<_CatalogListView> createState() => _CatalogListViewState();
}

class _CatalogListViewState extends State<_CatalogListView> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom =
        MediaQuery.of(context).padding.bottom +
        (widget.showMiniPlayer ? 104 : 16);
    final isArtist = widget.category == _SearchCategory.artists;
    final isPlaylist = widget.category == _SearchCategory.playlists;
    return Stack(
      children: [
        ListView.separated(
          controller: _controller,
          padding: EdgeInsets.fromLTRB(16, 8, 16, bottom),
          itemCount: widget.items.length,
          separatorBuilder: (_, _) => const SizedBox(height: 4),
          itemBuilder: (context, index) {
            final item = widget.items[index];
            final cover = item.coverUrl.trim();
            final placeholder = Icon(
              isArtist
                  ? Icons.person_outline_rounded
                  : isPlaylist
                  ? Icons.queue_music_rounded
                  : Icons.album_outlined,
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
                  ? Text(widget.categoryLabel)
                  : Text(
                      item.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => widget.onTap(item),
            );
          },
        ),
        ScrollToTopButton(
          controller: _controller,
          hasMiniPlayer: widget.showMiniPlayer,
        ),
      ],
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
