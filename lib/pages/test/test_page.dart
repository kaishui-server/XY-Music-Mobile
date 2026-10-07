import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/home/home_providers.dart';
import '../../src/player/player_provider.dart';
import '../../src/ui/xy_surface.dart';
import '../../src/widgets/cover_image.dart';

/// 卡片宽高比（宽/高，竖长方形）、轮播页内间隙、两侧卡片露出比例，以及
/// 两侧卡片的缩小与淡化幅度。
const double _cardRatio = 0.56;
/// 当前卡片与左右相邻卡片之间的间隙：间隙越小，当前卡片在同一页槽内
/// 越宽、与两侧卡片贴得越近。
const double _cardGap = 3;
const double _peekRatio = 0.075;
const double _sideScale = 0.05;
const double _sideFade = 0.5;
const Duration _switchDuration = Duration(milliseconds: 300);

/// 测试页面：居中一张竖向圆角卡片，开始页与播放页之间淡入淡出切换。
///
/// - 开始页：顶部小字显示今日听歌时长与排行榜名次，其下为细长「正在播放」
///   横条（有正在播放的歌曲时），再下方是左对齐的时段问候大字。点击横条
///   进入播放页。
/// - 播放页：横向轮播当前队列，中间为当前歌曲卡片，左右两侧露出相邻歌曲
///   卡片边缘。卡片最上方是同一条横条，文案为「点击此回到开始」，点击返回
///   开始页。左右滑动直接切换卡片（并切歌），向上滑动切上一首。
class TestPage extends ConsumerStatefulWidget {
  const TestPage({super.key});

  @override
  ConsumerState<TestPage> createState() => _TestPageState();
}

class _TestPageState extends ConsumerState<TestPage> {
  bool _showNowPlaying = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final current = ref.watch(playerProvider.select((state) => state.current));
    // 歌曲被停止后自动退回开始页，避免下次起播时直接跳进播放页。
    ref.listen(playerProvider.select((state) => state.current), (_, next) {
      if (next == null && _showNowPlaying) {
        setState(() => _showNowPlaying = false);
      }
    });
    final item = current;
    final playing = _showNowPlaying && item != null;
    return Scaffold(
      appBar: AppBar(title: const Text('测试页面')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = math.max(constraints.maxWidth - 24, 0.0);
            final availableHeight = math.max(constraints.maxHeight - 24, 0.0);
            // 竖向长方形：按可用空间尽量取满，左右各留一点点让相邻卡片露头。
            final peek = availableWidth * _peekRatio;
            var cardWidth = math.max(availableWidth - peek * 2 - _cardGap, 0.0);
            var cardHeight = cardWidth / _cardRatio;
            if (cardHeight > availableHeight) {
              cardHeight = availableHeight;
              cardWidth = cardHeight * _cardRatio;
            }
            // 每页只比卡片宽出一个间隙，因此两侧只露出相邻卡片的一小条边。
            final fraction = availableWidth <= 0
                ? 1.0
                : math.min((cardWidth + _cardGap) / availableWidth, 1.0);
            return AnimatedSwitcher(
              duration: _switchDuration,
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: playing
                  ? _NowPlayingCarousel(
                      key: const ValueKey('nowPlaying'),
                      cardWidth: cardWidth,
                      cardHeight: cardHeight,
                      viewportFraction: fraction,
                      onBack: () => setState(() => _showNowPlaying = false),
                    )
                  : Center(
                      key: const ValueKey('idle'),
                      child: SizedBox(
                        width: cardWidth,
                        height: cardHeight,
                        child: XyPanel(
                          radius: 26,
                          blurSigma: 20,
                          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                          color: theme.colorScheme.surface.withValues(
                            alpha: dark ? 0.5 : 0.68,
                          ),
                          child: _IdleView(
                            item: item,
                            onOpen: item == null
                                ? null
                                : () =>
                                      setState(() => _showNowPlaying = true),
                          ),
                        ),
                      ),
                    ),
            );
          },
        ),
      ),
    );
  }
}

/// 开始页：顶部听歌/排名小字 + 细长横条 + 左对齐时段问候大字。
class _IdleView extends ConsumerWidget {
  const _IdleView({this.item, this.onOpen});

  final QueueItem? item;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final seconds = ref.watch(
      homeStatisticsProvider.select(
        (value) => value.valueOrNull?.dailyListenDuration ?? 0,
      ),
    );
    final rank = ref.watch(
      homeLeaderboardProvider(LeaderboardPeriod.daily).select(
        (value) => value.valueOrNull?.me?.rank ?? 0,
      ),
    );
    final minutes = seconds ~/ 60;
    final rankText = rank > 0 ? '$rank' : '--';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '您今日已听歌 $minutes 分钟，在排行榜中位于第 $rankText 名',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.4,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (item != null) ...[
          const SizedBox(height: 12),
          _NowPlayingStrip(item: item!, trailing: '正在播放', onTap: onOpen),
        ],
        const SizedBox(height: 14),
        Text(
          '${_greetingFor(DateTime.now())}，今天想听点什么？',
          textAlign: TextAlign.left,
          style: TextStyle(
            fontSize: 26,
            height: 1.35,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}

/// 细长横条：左侧极小封面、中间歌名，最右侧为状态/操作文案。
///
/// 开始页显示「正在播放」并点击进入播放页；播放页显示「点击此回到开始」
/// 并点击返回开始页。
class _NowPlayingStrip extends StatelessWidget {
  const _NowPlayingStrip({
    required this.item,
    required this.trailing,
    this.onTap,
  });

  final QueueItem item;
  final String trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              CoverImage(
                songPath: item.path,
                imageUrl: item.coverUrl,
                width: 26,
                height: 26,
                radius: 7,
                icon: Icons.music_note_rounded,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                trailing,
                style: TextStyle(fontSize: 10.5, color: scheme.primary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 播放页：横向轮播队列卡片，中间为当前歌曲，两侧露出相邻卡片边缘。
class _NowPlayingCarousel extends ConsumerStatefulWidget {
  const _NowPlayingCarousel({
    super.key,
    required this.cardWidth,
    required this.cardHeight,
    required this.viewportFraction,
    required this.onBack,
  });

  final double cardWidth;
  final double cardHeight;
  final double viewportFraction;
  final VoidCallback onBack;

  @override
  ConsumerState<_NowPlayingCarousel> createState() =>
      _NowPlayingCarouselState();
}

class _NowPlayingCarouselState extends ConsumerState<_NowPlayingCarousel> {
  late final PageController _controller;

  // 单次竖向手势累计位移，用于「拖得够远」与「甩得够快」两种判定。
  double _vDrag = 0;

  @override
  void initState() {
    super.initState();
    final index = ref.read(playerProvider).queueIndex;
    _controller = PageController(
      initialPage: index < 0 ? 0 : index,
      viewportFraction: widget.viewportFraction,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 当前页的分数位置（滑动中为小数），用于计算两侧卡片的缩放与透明度。
  double get _currentPage {
    if (!_controller.hasClients) return _controller.initialPage.toDouble();
    return _controller.page ?? _controller.initialPage.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final player = ref.watch(
      playerProvider.select(
        (state) => (
          isPlaying: state.isPlaying,
          isLoading: state.isLoading,
          position: state.position,
          duration: state.duration,
          queueIndex: state.queueIndex,
          queue: state.queue,
        ),
      ),
    );
    // 由控制器按钮或自动切歌改变索引时，让轮播跟着滑到对应卡片。
    ref.listen(playerProvider.select((state) => state.queueIndex), (_, next) {
      if (next < 0 || !_controller.hasClients) return;
      if (_controller.page?.round() == next) return;
      unawaited(
        _controller.animateToPage(
          next,
          duration: _switchDuration,
          curve: Curves.easeOut,
        ),
      );
    });
    final hasPrevious = player.queueIndex > 0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) => _vDrag = 0,
      onVerticalDragUpdate: (details) => _vDrag += details.delta.dy,
      onVerticalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        final goPrevious = _vDrag < -36 || velocity < -240;
        _vDrag = 0;
        if (goPrevious && hasPrevious) {
          unawaited(ref.read(playerProvider.notifier).previous());
        }
      },
      child: PageView.builder(
        controller: _controller,
        itemCount: player.queue.length,
        onPageChanged: (index) =>
            unawaited(ref.read(playerProvider.notifier).playIndex(index)),
        itemBuilder: (context, index) {
          if (index >= player.queue.length) return const SizedBox.shrink();
          final item = player.queue[index];
          final isCurrent = index == player.queueIndex;
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              // 距离当前页越远越浅淡、越小；滑动时随位置连续过渡，
              // 因此卡片在滑入过程中会渐渐变明亮并放大到原尺寸。
              final t = (index - _currentPage).abs().clamp(0.0, 1.0);
              return Opacity(
                opacity: 1 - _sideFade * t,
                child: Transform.scale(scale: 1 - _sideScale * t, child: child),
              );
            },
            child: Center(
              child: SizedBox(
                width: widget.cardWidth,
                height: widget.cardHeight,
                child: XyPanel(
                  radius: 26,
                  blurSigma: 20,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  color: theme.colorScheme.surface.withValues(
                    alpha: dark ? 0.5 : 0.68,
                  ),
                  child: _SongCard(
                    item: item,
                    isCurrent: isCurrent,
                    isPlaying: isCurrent && player.isPlaying,
                    isLoading: isCurrent && player.isLoading,
                    position: isCurrent ? player.position : 0,
                    duration: isCurrent ? player.duration : 0,
                    onBack: isCurrent ? widget.onBack : null,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 单张歌曲卡片：顶部横条 + 大封面 + 标题/歌手 + 可拖拽进度条 + 控制器。
///
/// 仅当前歌曲可交互；两侧露出的相邻卡片沿用同一布局，因此滑动过程中卡片
/// 结构不会跳变。
class _SongCard extends ConsumerStatefulWidget {
  const _SongCard({
    required this.item,
    required this.isCurrent,
    required this.isPlaying,
    required this.isLoading,
    required this.position,
    required this.duration,
    this.onBack,
  });

  final QueueItem item;
  final bool isCurrent;
  final bool isPlaying;
  final bool isLoading;
  final double position;
  final double duration;
  final VoidCallback? onBack;

  @override
  ConsumerState<_SongCard> createState() => _SongCardState();
}

class _SongCardState extends ConsumerState<_SongCard> {
  // 拖动中的本地预览位置：拖动期间只跟随手指，松手才真正 seek，避免每个
  // 拖动 tick 都触发一次原生 seek 造成音频卡顿与滑块抖动。
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasDuration = widget.duration.isFinite && widget.duration > 0;
    final duration = hasDuration ? widget.duration : 1.0;
    final position = hasDuration && widget.position.isFinite
        ? widget.position.clamp(0.0, duration)
        : 0.0;
    final sliderValue = _dragValue ?? position;
    final notifier = ref.read(playerProvider.notifier);
    final timeStyle = TextStyle(
      fontSize: 11.5,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _NowPlayingStrip(
          item: widget.item,
          trailing: '点击此回到开始',
          onTap: widget.onBack,
        ),
        const SizedBox(height: 10),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final side = math.min(constraints.maxWidth, constraints.maxHeight);
              return Center(
                child: CoverImage(
                  key: ValueKey('test:${widget.item.path}'),
                  songPath: widget.item.path,
                  imageUrl: widget.item.coverUrl,
                  width: side,
                  height: side,
                  radius: 20,
                  highQuality: true,
                  icon: Icons.music_note_rounded,
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Text(
          widget.item.title,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 5),
        Text(
          widget.item.artist.isEmpty ? '未知歌手' : widget.item.artist,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: theme.colorScheme.primary,
            inactiveTrackColor: theme.colorScheme.onSurface.withValues(
              alpha: 0.14,
            ),
            thumbColor: theme.colorScheme.primary,
            overlayColor: theme.colorScheme.primary.withValues(alpha: 0.16),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
          ),
          child: Slider(
            value: sliderValue,
            max: duration,
            onChanged: hasDuration
                ? (value) => setState(() => _dragValue = value)
                : null,
            onChangeEnd: hasDuration
                ? (value) {
                    setState(() => _dragValue = null);
                    notifier.seek(value);
                  }
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatDuration(sliderValue), style: timeStyle),
              Text(_formatDuration(hasDuration ? duration : 0), style: timeStyle),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _ControlButton(
              icon: Icons.skip_previous_rounded,
              label: '上一首',
              onTap: notifier.previous,
            ),
            const SizedBox(width: 20),
            _ControlButton(
              primary: true,
              icon: widget.isLoading
                  ? Icons.hourglass_top_rounded
                  : widget.isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              label: widget.isLoading
                  ? '加载中'
                  : widget.isPlaying
                  ? '暂停'
                  : '播放',
              onTap: widget.isLoading ? null : notifier.toggle,
            ),
            const SizedBox(width: 20),
            _ControlButton(
              icon: Icons.skip_next_rounded,
              label: '下一首',
              onTap: notifier.next,
            ),
          ],
        ),
      ],
    );
  }
}

/// 播放控制器按钮：主按钮为实心圆形（播放/暂停），其余为纯图标按钮。
class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = primary ? 52.0 : 42.0;
    return Semantics(
      button: true,
      label: label,
      child: InkResponse(
        onTap: onTap,
        radius: size * 0.6,
        child: Container(
          width: size,
          height: size,
          decoration: primary
              ? BoxDecoration(color: scheme.primary, shape: BoxShape.circle)
              : null,
          child: Icon(
            icon,
            size: primary ? 28 : 30,
            color: primary ? scheme.onPrimary : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// 按时段返回问候语：早上 / 上午 / 中午 / 下午 / 晚上 / 午夜。
String _greetingFor(DateTime now) {
  final hour = now.hour;
  if (hour >= 5 && hour < 8) return '早上好';
  if (hour >= 8 && hour < 11) return '上午好';
  if (hour >= 11 && hour < 13) return '中午好';
  if (hour >= 13 && hour < 17) return '下午好';
  if (hour >= 17 && hour < 23) return '晚上好';
  return '午夜好';
}

String _formatDuration(double seconds) {
  if (!seconds.isFinite || seconds < 0) seconds = 0;
  final minutes = seconds ~/ 60;
  final secs = (seconds % 60).floor();
  return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
}