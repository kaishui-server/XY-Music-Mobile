import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/settings.dart';
import '../../src/explore/recommendation_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/navigation/sidebar_controller.dart';
import '../../src/player/player_provider.dart';
import '../../src/plugins/plugin_runtime.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/ui/xy_surface.dart';
import '../../src/ui/xy_theme.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/top_notice.dart';

/// 探索页入口。搜索结果仍由独立的搜索页承载，探索页提供个性化推荐
/// 和各插件的热门榜单。
class ExplorePage extends ConsumerStatefulWidget {
  const ExplorePage({super.key});

  @override
  ConsumerState<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends ConsumerState<ExplorePage> {
  // 推荐和热门榜单会同时触发多个插件请求/QuickJS 运行时初始化。
  // 让探索页先完成首帧和页面转场，再挂载这些重内容，避免从首页进入时
  // 主线程短暂阻塞造成“卡一下”。数据 provider 仍会缓存结果，后续进入不会
  // 重复等待这段时间。
  var _showRecommendation = false;
  var _showHotCharts = false;
  Timer? _recommendationTimer;
  Timer? _hotChartsTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 两个毛玻璃模块都包含图片和插件结果，若在同一帧挂载会在页面转场
      // 结束时产生明显掉帧。错峰挂载，数据请求仍由 provider 在后台预热。
      _recommendationTimer = Timer(const Duration(milliseconds: 420), () {
        if (mounted) setState(() => _showRecommendation = true);
      });
      _hotChartsTimer = Timer(const Duration(milliseconds: 820), () {
        if (mounted) setState(() => _showHotCharts = true);
      });
    });
  }

  @override
  void dispose() {
    _recommendationTimer?.cancel();
    _hotChartsTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sidebarOnRight = ref.watch(
      settingsProvider.select(
        (value) => value.valueOrNull?.sidebarPosition == SidebarPosition.right,
      ),
    );
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: sidebarOnRight ? null : const AppSidebarMenuButton(),
        title: const Text('探索'),
        actions: [if (sidebarOnRight) const AppSidebarMenuButton()],
      ),
      body: XyPageBackground(
        child: SafeArea(
          top: false,
          bottom: false,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: _ExploreIntro(
                  height: MediaQuery.sizeOf(context).height * .20,
                ),
              ),
              SliverPersistentHeader(
                pinned: true,
                delegate: _ExploreSearchHeaderDelegate(
                  onTap: () => context.push('/search'),
                ),
              ),
              SliverToBoxAdapter(
                child: _showRecommendation
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                        child: XyPanel(
                          padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
                          blurSigma: 14,
                          color: Theme.of(context).colorScheme.surface
                              .withValues(
                                alpha:
                                    Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? .30
                                    : .42,
                              ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  const Expanded(
                                    child: Text(
                                      '猜你想听',
                                      style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: -.2,
                                      ),
                                    ),
                                  ),
                                  const _RecommendationRefreshButton(),
                                ],
                              ),
                              const SizedBox(height: 8),
                              _RecommendationTabs(
                                onMore: () => context.push(
                                  '/home/explore/recommendations',
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : const _ExploreDeferredSectionPlaceholder(height: 164),
              ),
              SliverToBoxAdapter(
                child: _showHotCharts
                    ? const _ExploreHotChartsSection()
                    : const _ExploreDeferredSectionPlaceholder(height: 180),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExploreHotChartsSection extends ConsumerWidget {
  const _ExploreHotChartsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
      child: XyPanel(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
        blurSigma: 14,
        color: Theme.of(context).colorScheme.surface.withValues(
          alpha: Theme.of(context).brightness == Brightness.dark ? .30 : .42,
        ),
        child: Column(
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '热门榜单',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.2,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '刷新热门榜单',
                  onPressed: () => ref.invalidate(exploreHotChartsProvider),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ref
                .watch(exploreHotChartsProvider)
                .when(
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: 38),
                    child: CircularProgressIndicator(),
                  ),
                  error: (error, _) => _RecommendationMessage(
                    message: '热门榜单暂时不可用',
                    detail: '$error',
                    onRetry: () => ref.invalidate(exploreHotChartsProvider),
                  ),
                  data: (charts) {
                    if (charts.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text('暂无可用的热门榜单'),
                      );
                    }
                    return _ExploreHotChartsTabs(charts: charts);
                  },
                ),
          ],
        ),
      ),
    );
  }
}

class _ExploreDeferredSectionPlaceholder extends StatelessWidget {
  const _ExploreDeferredSectionPlaceholder({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    // 占位区域保持轻量且透明，避免首帧为了绘制复杂毛玻璃面板再次触发
    // 大量离屏渲染；延迟结束后由真实模块无动画替换，页面滚动位置不会跳动。
    return SizedBox(height: height);
  }
}

class _ExploreHotChartsList extends StatelessWidget {
  const _ExploreHotChartsList({required this.charts});

  final List<RecommendedPlaylist> charts;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final chart in charts)
          _RecommendationPlaylistTile(playlist: chart, showTrailingIcon: true),
      ],
    );
  }
}

class _ExploreHotChartsTabs extends StatelessWidget {
  const _ExploreHotChartsTabs({required this.charts});

  final List<RecommendedPlaylist> charts;

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<RecommendedPlaylist>>{};
    final names = <String, String>{};
    for (final chart in charts) {
      final key = chart.plugin.id;
      groups.putIfAbsent(key, () => []).add(chart);
      names[key] = chart.plugin.name.trim().isEmpty
          ? chart.plugin.id
          : chart.plugin.name;
    }
    final entries = groups.entries.toList(growable: false);
    if (entries.isEmpty) return const SizedBox.shrink();
    final maxItems = entries.fold<int>(
      0,
      (max, entry) => math.max(max, entry.value.length),
    );
    // TabBarView 需要有界高度；每个榜单卡片约 66dp，按当前插件最多的
    // 榜单数量计算高度，单个插件的榜单不会被裁切。
    final contentHeight = math.max(76.0, maxItems * 66.0 + 8.0);
    final scheme = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: entries.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: scheme.primary,
            unselectedLabelColor: scheme.onSurfaceVariant,
            tabs: [for (final entry in entries) Tab(text: names[entry.key])],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: contentHeight,
            child: TabBarView(
              children: [
                for (final entry in entries)
                  // 榜单内容完整展开，不再嵌套纵向滚动容器；上下滑动统一由
                  // 探索页外层 CustomScrollView 处理。
                  _ExploreHotChartsList(charts: entry.value),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ExploreIntro extends StatelessWidget {
  const _ExploreIntro({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height.clamp(150.0, 280.0).toDouble(),
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'XY Music',
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Music is part of my life.',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ExploreRecommendationsPage extends StatefulWidget {
  const ExploreRecommendationsPage({super.key});

  @override
  State<ExploreRecommendationsPage> createState() =>
      _ExploreRecommendationsPageState();
}

class _ExploreRecommendationsPageState extends State<ExploreRecommendationsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _controller;
  var _songCount = 30;
  var _playlistCount = 30;

  @override
  void initState() {
    super.initState();
    _controller = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('猜你想听'),
            bottom: TabBar(
              controller: _controller,
              tabs: const [
                Tab(text: '歌曲'),
                Tab(text: '歌单'),
              ],
            ),
          ),
          body: XyPageBackground(
            child: SafeArea(
              top: false,
              bottom: false,
              child: TabBarView(
                controller: _controller,
                children: [
                  _RecommendationFullSongs(
                    count: _songCount,
                    onMore: () => setState(() => _songCount += 30),
                  ),
                  _RecommendationFullPlaylists(
                    count: _playlistCount,
                    onMore: () => setState(() => _playlistCount += 30),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RecommendationFullSongs extends ConsumerStatefulWidget {
  const _RecommendationFullSongs({required this.count, required this.onMore});

  final int count;
  final VoidCallback onMore;

  @override
  ConsumerState<_RecommendationFullSongs> createState() =>
      _RecommendationFullSongsState();
}

class _RecommendationFullSongsState
    extends ConsumerState<_RecommendationFullSongs> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ref
        .watch(exploreRecommendationsProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => _RecommendationMessage(
            message: '推荐暂时不可用',
            detail: '$error',
            onRetry: () => ref.invalidate(exploreRecommendationsProvider),
          ),
          data: (songs) {
            final shown = songs
                .take(math.min(widget.count, 150))
                .toList(growable: false);
            if (shown.isEmpty) {
              return const _RecommendationMessage(
                message: '暂无推荐歌曲',
                detail: '多播放、收藏几首歌曲后，这里会根据你的偏好生成推荐',
              );
            }
            return Stack(
              children: [
                ListView(
                  controller: _controller,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 110),
                  children: [
                    _RecommendationList(songs: shown),
                    if (shown.length < songs.length && shown.length < 150)
                      _ContinueRecommendationButton(onPressed: widget.onMore),
                  ],
                ),
                ScrollToTopButton(
                  controller: _controller,
                  hasMiniPlayer: ref.watch(
                    playerProvider.select((state) => state.current != null),
                  ),
                ),
              ],
            );
          },
        );
  }
}

class _RecommendationFullPlaylists extends ConsumerStatefulWidget {
  const _RecommendationFullPlaylists({
    required this.count,
    required this.onMore,
  });

  final int count;
  final VoidCallback onMore;

  @override
  ConsumerState<_RecommendationFullPlaylists> createState() =>
      _RecommendationFullPlaylistsState();
}

class _RecommendationFullPlaylistsState
    extends ConsumerState<_RecommendationFullPlaylists> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ref
        .watch(explorePlaylistRecommendationsProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => _RecommendationMessage(
            message: '歌单推荐暂时不可用',
            detail: '$error',
            onRetry: () =>
                ref.invalidate(explorePlaylistRecommendationsProvider),
          ),
          data: (playlists) {
            final shown = playlists
                .take(math.min(widget.count, 150))
                .toList(growable: false);
            if (shown.isEmpty) {
              return const _RecommendationMessage(
                message: '暂无推荐歌单',
                detail: '安装支持歌单搜索的插件后，这里会根据你的偏好生成推荐',
              );
            }
            return Stack(
              children: [
                ListView(
                  controller: _controller,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 110),
                  children: [
                    _RecommendationPlaylistList(playlists: shown),
                    if (shown.length < playlists.length && shown.length < 150)
                      _ContinueRecommendationButton(onPressed: widget.onMore),
                  ],
                ),
                ScrollToTopButton(
                  controller: _controller,
                  hasMiniPlayer: ref.watch(
                    playerProvider.select((state) => state.current != null),
                  ),
                ),
              ],
            );
          },
        );
  }
}

class _ContinueRecommendationButton extends StatelessWidget {
  const _ContinueRecommendationButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.expand_more_rounded),
        label: const Text('继续显示 30 条'),
      ),
    );
  }
}

class _RecommendationPreviewSongs extends ConsumerWidget {
  const _RecommendationPreviewSongs({required this.songs, this.onMore});

  final List<Song> songs;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = songs.take(4).toList(growable: false);
    Future<void> playAt(int index) async {
      final playback = ref
          .read(libraryProvider.notifier)
          .playList(songs, index);
      if (context.mounted) unawaited(context.push<void>('/player'));
      await playback;
    }

    return Column(
      children: [
        for (var index = 0; index < preview.length && index < 3; index++)
          _RecommendationTile(
            song: preview[index],
            onTap: () => unawaited(playAt(index)),
          ),
        if (preview.length > 3)
          _FadedRecommendationItem(
            child: _RecommendationTile(
              song: preview[3],
              onTap: () => unawaited(playAt(3)),
            ),
          ),
        if (onMore != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: onMore, child: const Text('查看更多 >')),
          ),
      ],
    );
  }
}

class _RecommendationPreviewPlaylists extends StatelessWidget {
  const _RecommendationPreviewPlaylists({required this.playlists, this.onMore});

  final List<RecommendedPlaylist> playlists;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final preview = playlists.take(4).toList(growable: false);
    return Column(
      children: [
        for (var index = 0; index < preview.length && index < 3; index++)
          _RecommendationPlaylistTile(playlist: preview[index]),
        if (preview.length > 3)
          _FadedRecommendationItem(
            child: _RecommendationPlaylistTile(playlist: preview[3]),
          ),
        if (onMore != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: onMore, child: const Text('查看更多 >')),
          ),
      ],
    );
  }
}

class _RecommendationRefreshButton extends ConsumerStatefulWidget {
  const _RecommendationRefreshButton();

  @override
  ConsumerState<_RecommendationRefreshButton> createState() =>
      _RecommendationRefreshButtonState();
}

class _RecommendationRefreshButtonState
    extends ConsumerState<_RecommendationRefreshButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;
  var _refreshing = false;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    _rotationController.repeat();
    ref.invalidate(exploreRecommendationsProvider);
    ref.invalidate(explorePlaylistRecommendationsProvider);
    try {
      await Future.wait([
        ref.read(exploreRecommendationsProvider.future),
        ref.read(explorePlaylistRecommendationsProvider.future),
      ]);
    } catch (_) {
      // 推荐页会分别显示错误状态；刷新按钮本身不再抛出异常。
    } finally {
      if (mounted) {
        _rotationController.stop();
        _rotationController.value = 0;
        setState(() => _refreshing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: _refreshing ? '正在刷新' : '刷新推荐',
      onPressed: _refreshing ? null : _refresh,
      icon: RotationTransition(
        turns: _rotationController,
        child: const Icon(Icons.refresh_rounded),
      ),
    );
  }
}

class _FadedRecommendationItem extends StatelessWidget {
  const _FadedRecommendationItem({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.white, Colors.white, Colors.transparent],
        stops: [.0, .42, 1],
      ).createShader(bounds),
      child: child,
    );
  }
}

class _RecommendationList extends ConsumerWidget {
  const _RecommendationList({required this.songs});

  final List<Song> songs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        for (var index = 0; index < songs.length; index++)
          _RecommendationTile(
            song: songs[index],
            onTap: () async {
              final playback = ref
                  .read(libraryProvider.notifier)
                  .playList(songs, index);
              if (context.mounted) unawaited(context.push<void>('/player'));
              await playback;
            },
          ),
      ],
    );
  }
}

class _RecommendationTabs extends ConsumerStatefulWidget {
  const _RecommendationTabs({this.onMore});

  final VoidCallback? onMore;

  @override
  ConsumerState<_RecommendationTabs> createState() =>
      _RecommendationTabsState();
}

class _RecommendationTabsState extends ConsumerState<_RecommendationTabs>
    with SingleTickerProviderStateMixin {
  late final TabController _controller;
  var _index = 0;

  @override
  void initState() {
    super.initState();
    _controller = TabController(length: 2, vsync: this)
      ..addListener(() {
        if (_index != _controller.index && !_controller.indexIsChanging) {
          setState(() => _index = _controller.index);
        }
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TabBar(
          controller: _controller,
          onTap: (index) => setState(() => _index = index),
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: theme.colorScheme.primary,
          unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
          tabs: const [
            Tab(text: '歌曲'),
            Tab(text: '歌单'),
          ],
        ),
        const SizedBox(height: 8),
        if (_index == 0)
          _RecommendedSongsContent(onMore: widget.onMore)
        else
          _RecommendedPlaylistsContent(onMore: widget.onMore),
      ],
    );
  }
}

class _RecommendedSongsContent extends ConsumerWidget {
  const _RecommendedSongsContent({this.onMore});

  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(exploreRecommendationsProvider)
        .when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 44),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => _RecommendationMessage(
            message: '推荐暂时不可用',
            detail: '$error',
            onRetry: () => ref.invalidate(exploreRecommendationsProvider),
          ),
          data: (songs) => songs.isEmpty
              ? const _RecommendationMessage(
                  message: '暂无推荐歌曲',
                  detail: '多播放、收藏几首歌曲后，这里会根据你的偏好生成推荐',
                )
              : _RecommendationPreviewSongs(songs: songs, onMore: onMore),
        );
  }
}

class _RecommendedPlaylistsContent extends ConsumerWidget {
  const _RecommendedPlaylistsContent({this.onMore});

  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(explorePlaylistRecommendationsProvider)
        .when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 44),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => _RecommendationMessage(
            message: '歌单推荐暂时不可用',
            detail: '$error',
            onRetry: () =>
                ref.invalidate(explorePlaylistRecommendationsProvider),
          ),
          data: (playlists) => playlists.isEmpty
              ? const _RecommendationMessage(
                  message: '暂无推荐歌单',
                  detail: '安装支持歌单搜索的插件后，这里会根据你的偏好生成推荐',
                )
              : _RecommendationPreviewPlaylists(
                  playlists: playlists,
                  onMore: onMore,
                ),
        );
  }
}

class _RecommendationPlaylistList extends StatelessWidget {
  const _RecommendationPlaylistList({required this.playlists});

  final List<RecommendedPlaylist> playlists;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final playlist in playlists)
          _RecommendationPlaylistTile(playlist: playlist),
      ],
    );
  }
}

class _RecommendationPlaylistTile extends StatelessWidget {
  const _RecommendationPlaylistTile({
    required this.playlist,
    this.showTrailingIcon = false,
  });

  final RecommendedPlaylist playlist;
  final bool showTrailingIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final catalog = playlist.result;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: () => Navigator.of(context).push<void>(
            PageRouteBuilder<void>(
              opaque: true,
              transitionDuration: const Duration(milliseconds: 240),
              reverseTransitionDuration: const Duration(milliseconds: 190),
              pageBuilder: (_, _, _) =>
                  _RecommendedPlaylistPage(playlist: playlist),
              transitionsBuilder: (_, animation, secondaryAnimation, child) {
                final eased = CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeInCubic,
                );
                return FadeTransition(
                  opacity: eased,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, .035),
                      end: Offset.zero,
                    ).animate(eased),
                    child: child,
                  ),
                );
              },
            ),
          ),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 7, 8, 7),
            child: Row(
              children: [
                _PlaylistCover(url: catalog.coverUrl),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        catalog.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        [
                          if (catalog.subtitle.trim().isNotEmpty)
                            catalog.subtitle,
                          playlist.plugin.name,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (showTrailingIcon)
                  Icon(
                    Icons.queue_music_rounded,
                    color: theme.colorScheme.primary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecommendedPlaylistPage extends ConsumerStatefulWidget {
  const _RecommendedPlaylistPage({required this.playlist});

  final RecommendedPlaylist playlist;

  @override
  ConsumerState<_RecommendedPlaylistPage> createState() =>
      _RecommendedPlaylistPageState();
}

class _RecommendedPlaylistPageState
    extends ConsumerState<_RecommendedPlaylistPage> {
  late Future<List<Song>> _songsFuture;
  final ScrollController _songsController = ScrollController();

  @override
  void initState() {
    super.initState();
    _songsFuture = _loadSongs();
  }

  Future<List<Song>> _loadSongs() async {
    final catalog = widget.playlist.result;
    final raw = catalog.rawData;
    final input = <String>[
      for (final key in const [
        'id',
        'playlistId',
        'sheetId',
        'albumId',
        'album_id',
        'url',
        'link',
      ])
        if (raw[key]?.toString().trim().isNotEmpty == true)
          raw[key].toString().trim(),
      if (catalog.id.trim().isNotEmpty) catalog.id.trim(),
      catalog.title.trim(),
    ].firstWhere((value) => value.isNotEmpty);
    final imported = await ref
        .read(pluginRuntimeProvider)
        .importPlaylist(widget.playlist.plugin, input);
    return imported.songs
        .where((item) => item.title.trim().isNotEmpty)
        .map(
          (item) => Song(
            path: pluginSongPath(widget.playlist.plugin, item),
            title: item.title,
            artist: item.artist,
            album: item.album,
            albumKey: item.album,
            duration: (item.durationMs / 1000).round(),
            format: '网络',
            coverUrl: item.coverUrl,
            pluginId: widget.playlist.plugin.id,
            pluginData: item.rawData,
            lyricsRaw: _playlistEmbeddedLyrics(item.rawData),
          ),
        )
        .toList(growable: false);
  }

  void _retry() {
    setState(() => _songsFuture = _loadSongs());
  }

  @override
  void dispose() {
    _songsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalog = widget.playlist.result;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          catalog.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: XyPageBackground(
        child: FutureBuilder<List<Song>>(
          future: _songsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return _RecommendationMessage(
                message: '歌单歌曲获取失败',
                detail: '${snapshot.error}',
                onRetry: _retry,
              );
            }
            final songs = snapshot.data ?? const <Song>[];
            if (songs.isEmpty) {
              return const _RecommendationMessage(message: '歌单中暂无歌曲');
            }
            return Stack(
              children: [
                ListView(
                  controller: _songsController,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 110),
                  children: [
                    _RemotePlaylistHeroHeader(
                      playlist: widget.playlist,
                      songs: songs,
                      onPlayAll: () =>
                          ref.read(libraryProvider.notifier).playAll(songs),
                      onAddToPlaylist: () =>
                          _addSongsToLocalPlaylist(context, ref, songs),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 6, bottom: 8),
                      child: Text(
                        '${widget.playlist.plugin.name} · ${songs.length} 首歌曲',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    for (var index = 0; index < songs.length; index++)
                      _RecommendationTile(
                        song: songs[index],
                        onTap: () async {
                          final playback = ref
                              .read(libraryProvider.notifier)
                              .playList(songs, index);
                          if (context.mounted) {
                            unawaited(context.push<void>('/player'));
                          }
                          await playback;
                        },
                      ),
                  ],
                ),
                ScrollToTopButton(
                  controller: _songsController,
                  hasMiniPlayer: ref.watch(
                    playerProvider.select((state) => state.current != null),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RemotePlaylistHeroHeader extends StatelessWidget {
  const _RemotePlaylistHeroHeader({
    required this.playlist,
    required this.songs,
    required this.onPlayAll,
    required this.onAddToPlaylist,
  });

  final RecommendedPlaylist playlist;
  final List<Song> songs;
  final VoidCallback onPlayAll;
  final VoidCallback onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PlaylistCover(url: playlist.result.coverUrl, size: 124),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  playlist.result.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  [
                    playlist.plugin.name,
                    if (playlist.result.subtitle.trim().isNotEmpty)
                      playlist.result.subtitle,
                    '${songs.length} 首歌曲',
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: onPlayAll,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('播放全部'),
                    ),
                    IconButton(
                      onPressed: onAddToPlaylist,
                      tooltip: '添加到歌单',
                      icon: const Icon(Icons.playlist_add_rounded),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _addSongsToLocalPlaylist(
  BuildContext context,
  WidgetRef ref,
  List<Song> songs,
) async {
  final target = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (dialogContext) {
      final playlists = ref.read(playlistsProvider);
      final colors = Theme.of(dialogContext).colorScheme;
      return SizedBox(
        height: MediaQuery.sizeOf(dialogContext).height * .68,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(22, 0, 22, 4),
              child: Text(
                '添加到歌单',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 14),
              child: Text(
                '${songs.length} 首歌曲 · 选择一个目标歌单',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: colors.primaryContainer,
                child: Icon(Icons.add_rounded, color: colors.primary),
              ),
              title: const Text('新建歌单'),
              subtitle: const Text('创建后自动添加这些歌曲'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.pop(dialogContext, '__new__'),
            ),
            const Divider(height: 1),
            Expanded(
              child: playlists.isEmpty
                  ? Center(
                      child: Text(
                        '还没有其他歌单，请先新建一个',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: playlists.length,
                      itemBuilder: (context, index) {
                        final playlist = playlists[index];
                        final firstPath = playlist.songPaths.isEmpty
                            ? playlist.id
                            : playlist.songPaths.first;
                        return ListTile(
                          leading: CoverImage(
                            songPath: firstPath,
                            imageUrl: playlist.effectiveCoverUrl,
                            width: 46,
                            height: 46,
                            radius: 12,
                            icon: Icons.queue_music_rounded,
                          ),
                          title: Text(
                            playlist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text('${playlist.songPaths.length} 首歌曲'),
                          trailing: const Icon(
                            Icons.add_circle_outline_rounded,
                          ),
                          onTap: () =>
                              Navigator.pop(dialogContext, playlist.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    },
  );
  if (!context.mounted || target == null) return;
  final notifier = ref.read(playlistsProvider.notifier);
  if (target == '__new__') {
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('新建歌单'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '输入歌单名称'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text('创建'),
            ),
          ],
        );
      },
    );
    if (!context.mounted || name == null || name.trim().isEmpty) return;
    await notifier.create(name.trim(), songs: songs);
  } else {
    await notifier.mergeImportedSongs(target, songs);
  }
  if (context.mounted) {
    XyNotice.show(context, message: '已添加到歌单', type: XyNoticeType.success);
  }
}

String? _playlistEmbeddedLyrics(Map<String, dynamic> raw) {
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

class _PlaylistCover extends StatelessWidget {
  const _PlaylistCover({required this.url, this.size = 48});

  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(Icons.queue_music_rounded),
    );
    if (url.trim().isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

class _RecommendationTile extends StatelessWidget {
  const _RecommendationTile({required this.song, required this.onTap});

  final Song song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 7, 8, 7),
            child: Row(
              children: [
                SongCover(song: song, size: 48),
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
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        [
                          song.artist,
                          song.album,
                        ].where((value) => value.trim().isNotEmpty).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecommendationMessage extends StatelessWidget {
  const _RecommendationMessage({
    required this.message,
    this.detail,
    this.onRetry,
  });

  final String message;
  final String? detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 38),
      child: Column(
        children: [
          Icon(
            Icons.auto_awesome_rounded,
            size: 36,
            color: color.withValues(alpha: .65),
          ),
          const SizedBox(height: 10),
          Text(message, style: TextStyle(color: color)),
          if (detail != null) ...[
            const SizedBox(height: 5),
            Text(
              detail!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: color.withValues(alpha: .72),
              ),
            ),
          ],
          if (onRetry != null) ...[
            const SizedBox(height: 8),
            TextButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ],
      ),
    );
  }
}

class _ExploreSearchButton extends StatelessWidget {
  const _ExploreSearchButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Semantics(
      button: true,
      label: '搜索网络音乐',
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: .82),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(XyRadii.large),
          side: BorderSide(
            color: dark ? XyColors.darkBorder : XyColors.lightBorder,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: const SizedBox(
            height: 48,
            child: Row(
              children: [
                SizedBox(width: 16),
                Icon(Icons.search_rounded, size: 21),
                SizedBox(width: 11),
                Expanded(child: Text('搜索网络歌曲、歌手、专辑')),
                Padding(
                  padding: EdgeInsets.only(right: 14),
                  child: Icon(Icons.chevron_right_rounded, size: 22),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ExploreSearchHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _ExploreSearchHeaderDelegate({required this.onTap});

  final VoidCallback onTap;

  @override
  double get minExtent => 72;

  @override
  double get maxExtent => 72;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    // 置顶时只保留搜索框自身的半透明背景。外层不能再铺一层色块，
    // 否则在自定义壁纸上会出现一块与其他页面不同的矩形框。
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: _ExploreSearchButton(onTap: onTap),
    );
  }

  @override
  bool shouldRebuild(covariant _ExploreSearchHeaderDelegate oldDelegate) =>
      oldDelegate.onTap != onTap;
}
