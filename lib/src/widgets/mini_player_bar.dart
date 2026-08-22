import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../player/player_provider.dart';
import '../ui/xy_theme.dart';
import 'cover_image.dart';

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
        ),
      ),
    );
    final current = player.current;
    if (current == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => context.push('/player'),
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) < -180) context.push('/player');
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(XyRadii.large),
        // 不使用实时 BackdropFilter；播放器进度高频更新时，旧设备的 GPU
        // 可能持续重采样整块底栏并发生原生崩溃。
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(
              alpha: dark ? 0.98 : 0.99,
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
                    icon: player.isLoading
                        ? Icons.hourglass_top_rounded
                        : player.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    label: player.isLoading
                        ? '加载中'
                        : player.isPlaying
                        ? '暂停'
                        : '播放',
                    onTap: () => ref.read(playerProvider.notifier).toggle(),
                  ),
                  _PlayerButton(
                    icon: Icons.skip_next_rounded,
                    label: '下一首',
                    onTap: () => ref.read(playerProvider.notifier).next(),
                  ),
                  const SizedBox(width: 3),
                ],
              ),
              const Align(
                alignment: Alignment.bottomLeft,
                child: _MiniPlayerProgress(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniPlayerProgress extends ConsumerWidget {
  const _MiniPlayerProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timing = ref.watch(
      playerProvider.select(
        (state) => (position: state.position, duration: state.duration),
      ),
    );
    final progress = safeMiniPlayerProgress(timing.position, timing.duration);
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
