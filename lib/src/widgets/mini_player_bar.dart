import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../player/player_provider.dart';
import '../player/video_playback_session.dart';
import '../ui/xy_theme.dart';
import 'cover_image.dart';
import 'queue_sheet.dart';

double safeMiniPlayerProgress(double position, double duration) {
  if (!position.isFinite || !duration.isFinite || duration <= 0) return 0;
  return (position / duration).clamp(0.0, 1.0);
}

/// 电脑端 PlayerFooter 的手机化版本。
class MiniPlayerBar extends ConsumerWidget {
  const MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(
      playerProvider.select(
        (state) => (
          current: state.current,
          isPlaying: state.isPlaying,
          isLoading: state.isLoading,
          errorMessage: state.errorMessage,
          // 进度也必须订阅：单曲循环由播放器原生回绕，current 等字段不变，
          // 不订阅 position 的话底栏不会重建，循环重播后进度条停在末尾。
          position: state.position,
          duration: state.duration,
        ),
      ),
    );
    final current = player.current;
    if (current == null) return const SizedBox.shrink();

    // 视频播放时音频播放器会暂停，视频控制器自己提供进度和播放状态。
    // revision 负责在视频控制器创建/销毁时让首页底栏重新绑定。
    return ValueListenableBuilder<int>(
      valueListenable: VideoPlaybackSession.revision,
      builder: (context, _, child) {
        final video = VideoPlaybackSession.isFor(current.path)
            ? VideoPlaybackSession.controller
            : null;
        if (video == null) {
          return _buildBar(context, ref, player, current);
        }
        return ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: video,
          builder: (context, value, child) => _buildBar(
            context,
            ref,
            player,
            current,
            video: video,
            videoValue: value,
          ),
        );
      },
    );
  }

  Widget _buildBar(
    BuildContext context,
    WidgetRef ref,
    ({
      QueueItem? current,
      bool isPlaying,
      bool isLoading,
      String? errorMessage,
      double position,
      double duration,
    }) player,
    QueueItem current, {
    VideoPlayerController? video,
    VideoPlayerValue? videoValue,
  }) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final videoLoading =
        VideoPlaybackSession.isFor(current.path) &&
        VideoPlaybackSession.loading &&
        video == null;
    final isPlaying = videoValue?.isPlaying ?? player.isPlaying;
    final isLoading = videoLoading || (video == null && player.isLoading);
    final position = videoValue == null
        ? player.position
        : videoValue.position.inMilliseconds / 1000.0;
    final duration = videoValue == null
        ? player.duration
        : videoValue.duration.inMilliseconds / 1000.0;

    return GestureDetector(
      onTap: () => context.push('/player'),
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) < -180) context.push('/player');
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(XyRadii.large),
        child: BackdropFilter.grouped(
          // 小型底栏也会在页面滚动时参与合成，降低半径避免低端手机掉帧。
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            height: 64,
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(
                alpha: dark ? .34 : .48,
              ),
              borderRadius: BorderRadius.circular(XyRadii.large),
              border: Border.all(
                color: dark ? XyColors.darkBorder : XyColors.lightBorder,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.3 : 0.09),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Stack(
              children: [
                Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: CoverImage(
                        key: ValueKey('mini:${current.path}'),
                        songPath: current.path,
                        imageUrl: current.coverUrl,
                        width: 50,
                        height: 50,
                        radius: 12,
                        icon: Icons.music_note_rounded,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            current.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            player.errorMessage ??
                                (current.artist.isEmpty
                                    ? '未知歌手'
                                    : current.artist),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: player.errorMessage == null
                                  ? theme.colorScheme.onSurfaceVariant
                                  : theme.colorScheme.error,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _PlayerButton(
                      primary: true,
                      icon: isLoading
                          ? Icons.hourglass_top_rounded
                          : isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      label: isLoading
                          ? '加载中'
                          : isPlaying
                          ? '暂停'
                          : '播放',
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
                    _PlayerButton(
                      icon: Icons.skip_next_rounded,
                      label: '下一首',
                      onTap: () {
                        if (video != null) {
                          unawaited(VideoPlaybackSession.stopForTrackAction());
                        }
                        unawaited(ref.read(playerProvider.notifier).next());
                      },
                    ),
                    _PlayerButton(
                      icon: Icons.queue_music_rounded,
                      label: '播放队列',
                      onTap: () => showQueueSheet(context, ref),
                    ),
                    const SizedBox(width: 3),
                  ],
                ),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: _MiniPlayerProgress(
                    position: position,
                    duration: duration,
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

class _MiniPlayerProgress extends StatelessWidget {
  const _MiniPlayerProgress({required this.position, required this.duration});

  final double position;
  final double duration;

  @override
  Widget build(BuildContext context) {
    final progress = safeMiniPlayerProgress(position, duration);
    return FractionallySizedBox(
      widthFactor: progress,
      child: Container(
        height: 2,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _PlayerButton extends StatelessWidget {
  const _PlayerButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final color = primary
        ? Theme.of(context).colorScheme.primary
        : Colors.transparent;
    return Semantics(
      button: true,
      label: label,
      child: InkResponse(
        onTap: onTap,
        radius: 24,
        child: SizedBox(
          width: 44,
          height: 52,
          child: Center(
            child: Container(
              width: primary ? 34 : 32,
              height: primary ? 34 : 32,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Icon(
                icon,
                size: primary ? 22 : 23,
                color: primary
                    ? Colors.white
                    : Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
