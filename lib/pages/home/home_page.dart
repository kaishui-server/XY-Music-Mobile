import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/home/home_providers.dart';
import '../../src/explore/recommendation_provider.dart';
import '../../src/navigation/sidebar_controller.dart';
import '../../src/player/player_provider.dart';
import '../../src/player/video_playback_session.dart';
import '../../src/recent/recent_provider.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/sync/account_cloud_sync.dart';
import '../../src/core/settings.dart';
import '../../src/ui/xy_surface.dart';
import '../../src/ui/xy_theme.dart';
import '../../src/update/app_update.dart';
import '../../src/widgets/user_avatar_image.dart';

Color _homeGlassPanelColor(BuildContext context) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  return theme.colorScheme.surface.withValues(alpha: dark ? .34 : .48);
}

/// 按电脑端首页顺序组织四个模块，并针对窄屏改为单列纵向布局。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  Timer? _leaderboardRefreshTimer;
  Timer? _listPageWarmupTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 首页首帧后立即后台预加载日/周/总榜，避免用户切换到排行榜时才开始请求。
      preloadHomeLeaderboards(ref);
      // 探索页的推荐和热门榜单也在首页首帧后预热，进入探索页时直接复用
      // Riverpod 缓存，避免重新等待插件初始化和网络请求。
      preloadExploreData(ref);
      // 收藏和最近播放稍后再读取，避免和首页首帧的排行榜/推荐预热争用
      // CPU；用户进入列表页前通常已经完成，页面转场不会再承担查询开销。
      _listPageWarmupTimer = Timer(const Duration(milliseconds: 650), () {
        if (!mounted) return;
        preloadFavoriteSongs(ref);
        preloadRecentSongs(ref);
      });
      _leaderboardRefreshTimer = Timer.periodic(
        const Duration(minutes: 5),
        (_) => _refreshLeaderboards(),
      );
      _bootstrapBackend();
    });
  }

  @override
  void dispose() {
    _leaderboardRefreshTimer?.cancel();
    _listPageWarmupTimer?.cancel();
    super.dispose();
  }

  void _refreshLeaderboards() {
    if (!mounted) return;
    for (final period in LeaderboardPeriod.values) {
      ref.invalidate(homeLeaderboardProvider(period));
    }
    preloadHomeLeaderboards(ref);
  }

  Future<void> _bootstrapBackend() async {
    final backend = ref.read(authProvider.notifier);
    final container = ProviderScope.containerOf(context, listen: false);
    await AccountCloudSync.startAutoUpload(
      backend,
      ref.read(playlistsProvider.notifier),
      container,
      favorites: ref.read(favoritesProvider.notifier),
    );
    try {
      await backend.reportAppOpen();
    } catch (_) {
      // 统计失败不能阻止首页使用。
    }
    BackendAnnouncement? announcement;
    try {
      announcement = await backend.fetchAnnouncement();
    } catch (_) {
      // 公告检查失败不影响启动更新检查。
    }
    if (mounted && announcement != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(
            announcement!.type == 'warning'
                ? Icons.warning_amber_rounded
                : Icons.campaign_outlined,
          ),
          title: Text(announcement.title),
          content: SingleChildScrollView(child: Text(announcement.content)),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        try {
          await backend.confirmAnnouncement(announcement);
        } catch (_) {
          // 下次启动会再次展示，避免把未成功确认的公告误标为已读。
        }
      }
    }
    await _checkForAppUpdate();
  }

  Future<void> _checkForAppUpdate() async {
    try {
      final backend = ref.read(authProvider.notifier);
      final release = await backend.fetchLatestRelease();
      if (!mounted || release == null || release.downloadUrl.trim().isEmpty) {
        return;
      }
      final currentVersion = await backend.currentAppVersion();
      if (compareAppVersions(release.version, currentVersion) <= 0) return;

      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString('xy_music_update_suppressed_version') ==
          release.version) {
        return;
      }
      if (!mounted) return;

      var suppress = false;
      final shouldUpdate = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            icon: const Icon(Icons.system_update_rounded),
            title: Text('发现新版本 ${release.version}'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前版本：$currentVersion'),
                if (release.content.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    '更新内容',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: SingleChildScrollView(child: Text(release.content)),
                  ),
                ],
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: suppress,
                  onChanged: (value) =>
                      setState(() => suppress = value ?? false),
                  title: const Text('此次版本更新不再提示'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('暂不更新'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('立即更新'),
              ),
            ],
          ),
        ),
      );
      if (suppress) {
        await prefs.setString(
          'xy_music_update_suppressed_version',
          release.version,
        );
      }
      if (shouldUpdate == true && mounted) {
        await downloadAndInstallRelease(context, release);
      }
    } catch (_) {
      // 启动更新检查失败不影响进入首页。
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: XyPageBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // 首页 logo 栏固定在滚动内容之外；其他页面不使用此布局。
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: _HomeHeader(),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(hotCommentProvider);
                    ref.invalidate(homeStatisticsProvider);
                    for (final period in LeaderboardPeriod.values) {
                      ref.invalidate(homeLeaderboardProvider(period));
                    }
                    await Future.wait([
                      ref.read(hotCommentProvider.future),
                      ref.read(homeStatisticsProvider.future),
                      ...LeaderboardPeriod.values.map(
                        (period) =>
                            ref.read(homeLeaderboardProvider(period).future),
                      ),
                    ]);
                  },
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
                    children: const [
                      _NowPlayingModule(),
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: 18),
                        child: Center(
                          child: SizedBox(width: 44, child: Divider(height: 1)),
                        ),
                      ),
                      _HotCommentModule(),
                      SizedBox(height: 22),
                      _ListeningStatisticsModule(),
                      SizedBox(height: 22),
                      _LeaderboardModule(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader();

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, child) {
        final right =
            ref.watch(
              settingsProvider.select(
                (value) =>
                    value.valueOrNull?.sidebarPosition == SidebarPosition.right,
              ),
            ) ==
            true;
        final logo = const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'XY Music',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            SizedBox(height: 1),
            Text(
              'XY MUSIC',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 2.2,
                color: Color(0xFF999999),
              ),
            ),
          ],
        );
        return Row(
          mainAxisAlignment: right
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: right
              ? [logo, const SizedBox(width: 4), const AppSidebarMenuButton()]
              : [const AppSidebarMenuButton(), const SizedBox(width: 4), logo],
        );
      },
    );
  }
}

class _NowPlayingModule extends ConsumerWidget {
  const _NowPlayingModule();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentPath = ref.watch(
      playerProvider.select((state) => state.current?.path),
    );
    return ValueListenableBuilder<int>(
      valueListenable: VideoPlaybackSession.revision,
      builder: (context, _, child) {
        final video = VideoPlaybackSession.isFor(currentPath)
            ? VideoPlaybackSession.controller
            : null;
        if (video == null) return _buildContent(context, ref);
        return ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: video,
          builder: (context, value, child) =>
              _buildContent(context, ref, video: video, videoValue: value),
        );
      },
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref, {
    VideoPlayerController? video,
    VideoPlayerValue? videoValue,
  }) {
    // 只订阅当前歌曲和进度字段，避免队列元数据/错误状态变化时重建首页大模块。
    final player = ref.watch(
      playerProvider.select(
        (state) => (
          current: state.current,
          isPlaying: state.isPlaying,
          position: state.position,
          duration: state.duration,
          isLoading: state.isLoading,
        ),
      ),
    );
    final song = player.current;
    final theme = Theme.of(context);
    final position = videoValue == null
        ? player.position
        : videoValue.position.inMilliseconds / 1000.0;
    final duration = videoValue == null
        ? player.duration
        : videoValue.duration.inMilliseconds / 1000.0;
    final isPlaying = videoValue?.isPlaying ?? player.isPlaying;
    final isLoading =
        video == null && player.isLoading ||
        video == null && VideoPlaybackSession.loading;
    final progress = duration <= 0
        ? 0.0
        : (position / duration).clamp(0.0, 1.0);
    final source = song == null
        ? '等待播放'
        : song.pluginId != null
        ? '插件音乐'
        : song.path.startsWith('http')
        ? '在线音乐'
        : '本地音乐';
    final lyric = song == null
        ? null
        : ref.watch(
            homeLyricsProvider((
              path: song.path,
              lyricsRaw: song.lyricsRaw ?? '',
            )),
          );
    final activeLyric = lyric?.whenOrNull(
      data: (lines) => _activeLyric(lines, position),
    );

    return GestureDetector(
      onTap: () =>
          song == null ? context.go('/library') : context.push('/player'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _ModuleEyebrow('正在播放'),
            const SizedBox(height: 18),
            Text(
              song?.title ?? '暂无正在播放的歌曲',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 31,
                height: 1.08,
                letterSpacing: -1.1,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 10),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: song == null
                        ? '从音乐库选择一首歌曲'
                        : song.artist.isEmpty
                        ? '未知歌手'
                        : song.artist,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(text: '  ·  $source'),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            _HomeProgressBar(
              value: progress,
              enabled: song != null && duration > 0,
              onSeek: (value) {
                if (video != null) {
                  unawaited(
                    video.seekTo(
                      Duration(milliseconds: (value * duration * 1000).round()),
                    ),
                  );
                } else {
                  unawaited(
                    ref.read(playerProvider.notifier).seek(value * duration),
                  );
                }
              },
            ),
            const SizedBox(height: 7),
            Row(
              children: [
                Text(
                  '${_formatClock(position)} / ${_formatClock(duration)}',
                  style: TextStyle(
                    fontSize: 11,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                _RoundControl(
                  primary: true,
                  enabled: song != null,
                  label: isPlaying ? '暂停' : '播放',
                  icon: isLoading
                      ? Icons.hourglass_top_rounded
                      : isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  onTap: isLoading
                      ? () {}
                      : video != null
                      ? () {
                          if (video.value.isPlaying) {
                            unawaited(video.pause());
                          } else {
                            unawaited(video.play());
                          }
                        }
                      : () => ref.read(playerProvider.notifier).toggle(),
                ),
                const SizedBox(width: 9),
                _RoundControl(
                  enabled: song != null,
                  label: '下一首',
                  icon: Icons.skip_next_rounded,
                  onTap: () {
                    if (video != null) {
                      unawaited(VideoPlaybackSession.stopForTrackAction());
                    }
                    unawaited(ref.read(playerProvider.notifier).next());
                  },
                ),
              ],
            ),
            const SizedBox(height: 17),
            Container(height: 1, color: theme.dividerColor),
            const SizedBox(height: 14),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              // AnimatedSwitcher 默认使用居中 Stack 布局。上一句歌词如果是
              // 两行，旧组件的宽度会把新歌词先放到中间，再在布局稳定后跳回左侧。
              // 让所有歌词占满同一块区域，并始终从左上角开始布局，切换时只做淡入淡出。
              layoutBuilder: (currentChild, previousChildren) => SizedBox(
                width: double.infinity,
                child: Stack(
                  alignment: Alignment.topLeft,
                  fit: StackFit.passthrough,
                  children: <Widget>[
                    ...previousChildren,
                    currentChild ?? const SizedBox.shrink(),
                  ],
                ),
              ),
              child: Column(
                key: ValueKey(activeLyric?.text ?? song?.path ?? 'empty'),
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    song == null
                        ? '音乐会在这里开始'
                        : activeLyric?.text ??
                              (song.lyricsAttempted ? '暂无同步歌词' : '正在获取歌词…'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.45,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.82,
                      ),
                    ),
                  ),
                  if (activeLyric?.translation.isNotEmpty == true) ...[
                    const SizedBox(height: 3),
                    Text(
                      activeLyric!.translation,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  HomeLyricLine? _activeLyric(List<HomeLyricLine> lines, double position) {
    HomeLyricLine? active;
    for (final line in lines) {
      if (line.time > position) break;
      active = line;
    }
    return active ?? lines.firstOrNull;
  }
}

class _HomeProgressBar extends StatelessWidget {
  const _HomeProgressBar({
    required this.value,
    required this.enabled,
    required this.onSeek,
  });

  final double value;
  final bool enabled;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        void seek(double dx) {
          if (!enabled || constraints.maxWidth <= 0) return;
          onSeek((dx / constraints.maxWidth).clamp(0.0, 1.0));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => seek(details.localPosition.dx),
          onHorizontalDragUpdate: (details) => seek(details.localPosition.dx),
          child: SizedBox(
            height: 18,
            child: Align(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Stack(
                  children: [
                    Container(
                      height: 6,
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.12,
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: value,
                      child: Container(
                        height: 6,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RoundControl extends StatelessWidget {
  const _RoundControl({
    required this.enabled,
    required this.label,
    required this.icon,
    required this.onTap,
    this.primary = false,
  });

  final bool enabled;
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Material(
          color: primary
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurface.withValues(alpha: 0.08),
          shape: const CircleBorder(),
          child: InkWell(
            onTap: enabled ? onTap : null,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                icon,
                size: 23,
                color: primary ? Colors.white : theme.colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HotCommentModule extends ConsumerWidget {
  const _HotCommentModule();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final comment = ref.watch(hotCommentProvider);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: _ModuleEyebrow('热评推荐')),
              TextButton.icon(
                onPressed: comment.isLoading
                    ? null
                    : () => ref.invalidate(hotCommentProvider),
                icon: AnimatedRotation(
                  turns: comment.isLoading ? 1 : 0,
                  duration: const Duration(milliseconds: 500),
                  child: const Icon(Icons.refresh_rounded, size: 16),
                ),
                label: const Text('换一下'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          comment.when(
            loading: () => const _ModuleLoading(height: 88),
            error: (_, _) => _InlineError(
              message: '热评加载失败',
              onRetry: () => ref.invalidate(hotCommentProvider),
            ),
            data: (item) => InkWell(
              onTap: item.songTitle == null
                  ? null
                  : () => context.push(
                      '/search?q=${Uri.encodeQueryComponent(item.songTitle!)}',
                    ),
              borderRadius: BorderRadius.circular(XyRadii.medium),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatHotCommentForDisplay(item.comment),
                      style: const TextStyle(
                        fontSize: 18,
                        height: 1.55,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (item.songTitle != null) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '《${item.songTitle}》',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.search_rounded,
                            size: 17,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '搜索歌曲',
                            style: TextStyle(
                              color: theme.colorScheme.primary,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ListeningStatisticsModule extends ConsumerWidget {
  const _ListeningStatisticsModule();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statistics = ref.watch(homeStatisticsProvider);
    return Column(
      children: [
        _ModuleHeading(
          title: '听歌统计',
          subtitle: '本地音乐与聆听数据',
          action: '查看详细',
          onAction: () => context.push('/settings/statistics'),
        ),
        const SizedBox(height: 10),
        statistics.when(
          loading: () => XyPanel(
            color: _homeGlassPanelColor(context),
            // 低端手机上大半径 BackdropFilter 会在滚动时反复重采样整块背景。
            // 10px 仍保留玻璃质感，但显著降低合成开销。
            blurSigma: 10,
            child: const _ModuleLoading(height: 190),
          ),
          error: (_, _) => XyPanel(
            color: _homeGlassPanelColor(context),
            blurSigma: 10,
            child: _InlineError(
              message: '听歌统计加载失败',
              onRetry: () => ref.invalidate(homeStatisticsProvider),
            ),
          ),
          data: (data) => _StatisticsPanel(data: data),
        ),
      ],
    );
  }
}

class _StatisticsPanel extends StatelessWidget {
  const _StatisticsPanel({required this.data});

  final HomeStatisticsData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return XyPanel(
      color: _homeGlassPanelColor(context),
      blurSigma: 10,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      radius: XyRadii.extraLarge,
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '总歌曲',
                      style: TextStyle(
                        fontSize: 12,
                        letterSpacing: 1.2,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${data.totalSongs}',
                      style: const TextStyle(
                        fontSize: 40,
                        height: 1,
                        letterSpacing: -1.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: _CompactMetric(
                        label: '总听歌时长',
                        value: _formatLongDuration(data.listenDuration),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: _CompactMetric(
                        label: '播放次数',
                        value: '${data.playCount} 次',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Divider(height: 1, color: theme.dividerColor),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 2.25,
            children: [
              _StatMetricTile(
                label: '曲库总时长',
                value: _formatLongDuration(data.libraryDuration),
              ),
              _StatMetricTile(
                label: '音乐库大小',
                value: _formatFileSize(data.totalFileSize),
              ),
              _StatMetricTile(
                label: '无损占比',
                value: '${data.losslessRatio.toStringAsFixed(1)}%',
              ),
              _StatMetricTile(
                label: '最常听',
                value: data.mostPlayed?.title ?? '暂无记录',
                detail: data.mostPlayed == null
                    ? null
                    : '${data.mostPlayedCount} 次',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CompactMetric extends StatelessWidget {
  const _CompactMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 3),
        Align(
          alignment: Alignment.centerRight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ],
    );
  }
}

class _StatMetricTile extends StatelessWidget {
  const _StatMetricTile({
    required this.label,
    required this.value,
    this.detail,
  });

  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          if (detail != null)
            Text(
              detail!,
              style: TextStyle(
                fontSize: 9,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _LeaderboardModule extends ConsumerStatefulWidget {
  const _LeaderboardModule();

  @override
  ConsumerState<_LeaderboardModule> createState() => _LeaderboardModuleState();
}

class _LeaderboardModuleState extends ConsumerState<_LeaderboardModule> {
  // 首页首次进入默认展示当天的排行榜，用户仍可手动切换周榜和总榜。
  LeaderboardPeriod _period = LeaderboardPeriod.daily;

  @override
  Widget build(BuildContext context) {
    final ranking = ref.watch(homeLeaderboardProvider(_period));
    final auth = ref.watch(authProvider);
    return Column(
      children: [
        _ModuleHeading(
          title: '听歌排行榜',
          subtitle: '${_period.label} · 云端排行',
          action: '刷新',
          onAction: () => ref.invalidate(homeLeaderboardProvider(_period)),
        ),
        const SizedBox(height: 10),
        XyPanel(
          color: _homeGlassPanelColor(context),
          blurSigma: 10,
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
          radius: XyRadii.extraLarge,
          child: Column(
            children: [
              _PeriodTabs(
                selected: _period,
                // 请求进行中也允许切换榜单；每个周期使用独立的 provider，
                // 不应被当前周期的加载状态锁死。
                enabled: true,
                onChanged: (period) => setState(() => _period = period),
              ),
              const SizedBox(height: 10),
              ranking.when(
                loading: () => const _ModuleLoading(height: 240),
                error: (_, _) => _InlineError(
                  message: '排行榜加载失败',
                  onRetry: () =>
                      ref.invalidate(homeLeaderboardProvider(_period)),
                ),
                data: (data) => _LeaderboardList(data: data),
              ),
              if (!auth.isLoggedIn && !ranking.isLoading) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => context.push('/account'),
                  icon: const Icon(Icons.person_outline_rounded, size: 17),
                  label: const Text('登录后显示你的个人排名'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _PeriodTabs extends StatelessWidget {
  const _PeriodTabs({
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final LeaderboardPeriod selected;
  final bool enabled;
  final ValueChanged<LeaderboardPeriod> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: .42),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          for (final period in LeaderboardPeriod.values)
            Expanded(
              child: InkWell(
                onTap: enabled ? () => onChanged(period) : null,
                borderRadius: BorderRadius.circular(10),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected == period
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    period.label,
                    style: TextStyle(
                      color: selected == period
                          ? Colors.white
                          : theme.colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LeaderboardList extends StatelessWidget {
  const _LeaderboardList({required this.data});

  final LeaderboardData data;

  @override
  Widget build(BuildContext context) {
    if (data.leaderboard.isEmpty) {
      return const SizedBox(height: 100, child: Center(child: Text('暂无排行榜数据')));
    }
    final top = data.leaderboard.take(15).toList();
    final me = data.me;
    final meIncluded = me == null || top.any((entry) => entry.rank == me.rank);
    return Column(
      children: [
        for (var i = 0; i < top.length; i++) ...[
          _LeaderboardRow(entry: top[i]),
          if (i < top.length - 1) const SizedBox(height: 3),
        ],
        if (!meIncluded) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 5),
            child: Text('···', style: TextStyle(color: Colors.grey)),
          ),
          _LeaderboardRow(entry: me),
        ],
        const SizedBox(height: 8),
        Text(
          '共 ${data.totalUsers} 位用户参与排行',
          style: TextStyle(
            fontSize: 10,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _LeaderboardRow extends StatelessWidget {
  const _LeaderboardRow({required this.entry});

  final LeaderboardEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: entry.isMe
            ? theme.colorScheme.primary.withValues(alpha: 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(13),
        border: entry.isMe
            ? Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.24),
              )
            : null,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            child: Text(
              '${entry.rank}',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _rankColor(entry.rank, theme),
                fontSize: entry.rank <= 3 ? 17 : 12,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _LeaderboardAvatar(entry: entry),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.nickname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (entry.isMe) ...[
                      const SizedBox(width: 5),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: const Text(
                          '你',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 8,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '@${entry.username.isEmpty ? entry.nickname : entry.username}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatLongDuration(entry.duration),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }

  Color _rankColor(int rank, ThemeData theme) => switch (rank) {
    1 => const Color(0xFFE2A719),
    2 => const Color(0xFF8D99A6),
    3 => const Color(0xFFB87845),
    _ => theme.colorScheme.onSurfaceVariant,
  };
}

class _LeaderboardAvatar extends StatelessWidget {
  const _LeaderboardAvatar({required this.entry});

  final LeaderboardEntry entry;

  @override
  Widget build(BuildContext context) {
    final fallback = _avatarFallback(context);
    return ClipOval(
      child: SizedBox.square(
        dimension: 38,
        child: entry.avatar == null
            ? fallback
            : UserAvatarImage(
                source: entry.avatar!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }

  Widget _avatarFallback(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.14),
    child: Center(
      child: Text(
        entry.nickname.isEmpty ? '?' : entry.nickname.characters.first,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w900,
        ),
      ),
    ),
  );
}

class _ModuleEyebrow extends StatelessWidget {
  const _ModuleEyebrow(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 14,
      height: 1.15,
      fontWeight: FontWeight.w900,
      letterSpacing: 1.6,
    ),
  );
}

class _ModuleHeading extends StatelessWidget {
  const _ModuleHeading({
    required this.title,
    required this.subtitle,
    this.action,
    this.onAction,
  });

  final String title;
  final String subtitle;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (action != null)
          TextButton(onPressed: onAction, child: Text(action!)),
      ],
    );
  }
}

class _ModuleLoading extends StatelessWidget {
  const _ModuleLoading({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: const Center(
      child: SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 92,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message),
          const SizedBox(height: 4),
          TextButton(onPressed: onRetry, child: const Text('点击重试')),
        ],
      ),
    ),
  );
}

String _formatClock(double seconds) {
  if (!seconds.isFinite || seconds <= 0) return '0:00';
  final total = seconds.round();
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}

String _formatLongDuration(int seconds) {
  if (seconds <= 0) return '0 分钟';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (hours > 0 && minutes > 0) return '$hours 小时 $minutes 分';
  if (hours > 0) return '$hours 小时';
  return '${minutes.clamp(1, 59)} 分钟';
}

String _formatFileSize(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
