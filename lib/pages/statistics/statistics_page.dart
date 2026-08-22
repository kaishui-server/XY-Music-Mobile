import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/db_path.dart';
import '../../src/library/library_provider.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/cover_image.dart';

class _StatisticsData {
  const _StatisticsData({
    required this.listen,
    required this.library,
    required this.behavior,
    required this.formats,
    required this.quality,
    required this.topSongs,
  });

  final Map<String, dynamic> listen;
  final Map<String, dynamic> library;
  final Map<String, dynamic> behavior;
  final Map<String, dynamic> formats;
  final Map<String, dynamic> quality;
  final List<Song> topSongs;
}

final _statisticsProvider = FutureProvider.autoDispose<_StatisticsData>((
  ref,
) async {
  final refreshTimer = Timer(const Duration(minutes: 1), ref.invalidateSelf);
  ref.onDispose(refreshTimer.cancel);
  final dbPath = await ref.watch(dbPathProvider.future);
  // 这些接口首次打开数据库时会执行 schema 检查和旧版本迁移。串行读取可
  // 避免多个连接同时抢占 SQLite 写锁，尤其是首次进入统计页时。
  Future<Map<String, dynamic>> fetch(Future<String> request) async {
    final decoded = jsonDecode(await request);
    return decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : <String, dynamic>{};
  }

  final listen = await fetch(statsGetListenDurations(dbPath: dbPath));
  final library = await fetch(statsGetLibraryStats(dbPath: dbPath));
  final behavior = await fetch(
    statsGetBehaviorStats(dbPath: dbPath, timeRangeJson: '{"type":"Days30"}'),
  );
  final formats = await fetch(statsGetFormatDistribution(dbPath: dbPath));
  final quality = await fetch(statsGetQualityDistribution(dbPath: dbPath));
  final paths = (behavior['top_songs'] as List? ?? const [])
      .map((row) => row is Map ? row['song_path']?.toString() ?? '' : '')
      .where((path) => path.isNotEmpty)
      .toList();
  final songs = await ref.read(libraryProvider.notifier).songsByPaths(paths);
  final byPath = {for (final song in songs) song.path: song};
  return _StatisticsData(
    listen: listen,
    library: library,
    behavior: behavior,
    formats: formats,
    quality: quality,
    topSongs: paths.map((path) => byPath[path]).whereType<Song>().toList(),
  );
});

class StatisticsPage extends ConsumerWidget {
  const StatisticsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(_statisticsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('听歌统计'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () => ref.invalidate(_statisticsProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: stats.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.query_stats, size: 48),
                const SizedBox(height: 12),
                Text('统计加载失败\n$error', textAlign: TextAlign.center),
                const SizedBox(height: 14),
                FilledButton.tonalIcon(
                  onPressed: () => ref.invalidate(_statisticsProvider),
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
        data: (data) => _StatisticsContent(data: data),
      ),
    );
  }
}

class _StatisticsContent extends StatelessWidget {
  const _StatisticsContent({required this.data});
  final _StatisticsData data;

  int _number(Map<String, dynamic> map, String key) =>
      (map[key] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final recentActivity =
        (data.behavior['recent_activity'] as List? ?? const [])
            .map((value) => (value as num).toDouble())
            .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFEC4141), Color(0xFFB92F54)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.headphones, color: Colors.white),
                  SizedBox(width: 8),
                  Text(
                    '我的听歌时光',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _HeroMetric(
                      value: _duration(_number(data.listen, 'daily')),
                      label: '今日',
                    ),
                  ),
                  Expanded(
                    child: _HeroMetric(
                      value: _duration(_number(data.listen, 'weekly')),
                      label: '近 7 天',
                    ),
                  ),
                  Expanded(
                    child: _HeroMetric(
                      value: _duration(_number(data.listen, 'total')),
                      label: '累计',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const _SectionTitle('近 7 天趋势'),
        const SizedBox(height: 10),
        _StatCard(
          child: SizedBox(
            height: 126,
            child: _ActivityBars(values: recentActivity),
          ),
        ),
        const SizedBox(height: 18),
        const _SectionTitle('我的音乐库'),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.85,
          children: [
            _MetricCard(
              icon: Icons.music_note,
              value: '${_number(data.library, 'total_songs')}',
              label: '歌曲',
            ),
            _MetricCard(
              icon: Icons.person_outline,
              value: '${_number(data.library, 'artist_count')}',
              label: '歌手',
            ),
            _MetricCard(
              icon: Icons.album_outlined,
              value: '${_number(data.library, 'album_count')}',
              label: '专辑',
            ),
            _MetricCard(
              icon: Icons.hd_outlined,
              value: '${_number(data.library, 'lossless_count')}',
              label: '无损歌曲',
            ),
          ],
        ),
        if (data.topSongs.isNotEmpty) ...[
          const SizedBox(height: 18),
          const _SectionTitle('近 30 天常听'),
          const SizedBox(height: 10),
          _StatCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                for (var i = 0; i < data.topSongs.length; i++)
                  ListTile(
                    leading: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        CoverImage(
                          songPath: data.topSongs[i].path,
                          width: 44,
                          height: 44,
                          radius: 10,
                        ),
                        Positioned(
                          left: -6,
                          top: -6,
                          child: CircleAvatar(
                            radius: 10,
                            backgroundColor: const Color(0xFFEC4141),
                            child: Text(
                              '${i + 1}',
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    title: Text(
                      data.topSongs[i].title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      data.topSongs[i].artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 18),
        const _SectionTitle('音质构成'),
        const SizedBox(height: 10),
        _StatCard(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _QualityChip(
                label: 'Hi-Res',
                count: _number(data.quality, 'hires'),
                color: const Color(0xFFE0A21A),
              ),
              _QualityChip(
                label: '无损',
                count: _number(data.quality, 'super_quality'),
                color: const Color(0xFF4C9C6A),
              ),
              _QualityChip(
                label: '高品质',
                count: _number(data.quality, 'high_quality'),
                color: const Color(0xFF477BD6),
              ),
              _QualityChip(
                label: '其他',
                count: _number(data.quality, 'other'),
                color: Colors.grey,
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _duration(int seconds) {
    if (seconds < 60) return seconds == 0 ? '0 分' : '<1 分';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    return hours > 0 ? '${hours}h ${minutes}m' : '$minutes 分';
  }
}

class _HeroMetric extends StatelessWidget {
  const _HeroMetric({required this.value, required this.label});
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 19,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 3),
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
    ],
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Text(
    title,
    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
  );
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.child,
    this.padding = const EdgeInsets.all(14),
  });
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(17),
      border: Border.all(
        color: Theme.of(
          context,
        ).colorScheme.outlineVariant.withValues(alpha: .3),
      ),
    ),
    child: child,
  );
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.value,
    required this.label,
  });
  final IconData icon;
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) => _StatCard(
    child: Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: const Color(0x24EC4141),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: const Color(0xFFEC4141)),
        ),
        const SizedBox(width: 12),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _ActivityBars extends StatelessWidget {
  const _ActivityBars({required this.values});
  final List<double> values;
  @override
  Widget build(BuildContext context) {
    final normalized = values.length == 7 ? values : List.filled(7, 0.0);
    final max = normalized.fold<double>(
      1,
      (current, value) => value > current ? value : current,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: (normalized[i] / max).clamp(.06, 1),
                        child: Container(
                          decoration: BoxDecoration(
                            color: i == 6
                                ? const Color(0xFFEC4141)
                                : const Color(0x66EC4141),
                            borderRadius: BorderRadius.circular(7),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    i == 6 ? '今天' : '${6 - i}天前',
                    style: const TextStyle(fontSize: 9),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _QualityChip extends StatelessWidget {
  const _QualityChip({
    required this.label,
    required this.count,
    required this.color,
  });
  final String label;
  final int count;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .13),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      '$label  $count',
      style: TextStyle(color: color, fontWeight: FontWeight.w700),
    ),
  );
}
