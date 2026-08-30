import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_provider.dart';
import '../core/db_path.dart';
import '../library/library_provider.dart';
import '../recent/recent_provider.dart';
import '../recent/recent_store.dart';
import '../rust/api.dart';

const _hotCommentApi = 'https://api.fuchenboke.cn/api/wangyi.php';

class HotComment {
  const HotComment({required this.comment, this.songTitle});

  final String comment;
  final String? songTitle;
}

String formatHotCommentForDisplay(String comment) {
  final normalized = comment.trim();
  const pairs = <(String, String)>[
    ('“', '”'),
    ('‘', '’'),
    ('「', '」'),
    ('『', '』'),
    ('"', '"'),
    ("'", "'"),
  ];
  final wrapped = pairs.any(
    (pair) => normalized.startsWith(pair.$1) && normalized.endsWith(pair.$2),
  );
  return wrapped ? normalized : '“$normalized”';
}

HotComment parseHotComment(String raw) {
  final normalized = raw.replaceFirst('\uFEFF', '').trim();
  if (normalized.isEmpty) throw const FormatException('热评内容为空');

  final matches = RegExp(r'《([^《》]+)》').allMatches(normalized).toList();
  if (matches.isEmpty) return HotComment(comment: normalized);
  final last = matches.last;
  final songTitle = last.group(1)?.trim();
  final comment = normalized
      .substring(0, last.start)
      .replaceFirst(RegExp(r'(?:[—–-]{1,2}\s*)?(?:网易云热评)?\s*$'), '')
      .trim();
  return HotComment(
    comment: comment.isEmpty ? normalized : comment,
    songTitle: songTitle?.isEmpty == true ? null : songTitle,
  );
}

final hotCommentProvider = FutureProvider.autoDispose<HotComment>((ref) async {
  final cacheBuster = DateTime.now().microsecondsSinceEpoch;
  final responseJson = await pluginHttpRequest(
    method: 'GET',
    url: '$_hotCommentApi?_=$cacheBuster',
    headersJson: jsonEncode({'Accept': 'text/plain, */*'}),
    timeout: BigInt.from(12),
    follow: 3,
  );
  final response = jsonDecode(responseJson);
  if (response is! Map) throw const FormatException('热评接口响应无效');
  final status = (response['status'] as num?)?.toInt() ?? 0;
  if (status < 200 || status >= 300) {
    throw Exception('热评接口请求失败（HTTP $status）');
  }
  final result = parseHotComment(response['body']?.toString() ?? '');
  final timer = Timer(const Duration(minutes: 3), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return result;
});

class HomeLyricLine {
  const HomeLyricLine({
    required this.time,
    required this.text,
    required this.translation,
  });

  final double time;
  final String text;
  final String translation;
}

typedef HomeLyricsRequest = ({String path, String lyricsRaw});

final homeLyricsProvider = FutureProvider.autoDispose
    .family<List<HomeLyricLine>, HomeLyricsRequest>((ref, request) async {
      try {
        final raw = request.lyricsRaw.trim().isNotEmpty
            ? await parseLyrics(rawLyrics: request.lyricsRaw)
            : await getSongLyricsPayload(
                dbPath: await ref.read(dbPathProvider.future),
                path: request.path,
              );
        final payload = jsonDecode(raw);
        if (payload is! Map) return const [];
        return (payload['displayLines'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (line) => HomeLyricLine(
                time: (line['time'] as num?)?.toDouble() ?? 0,
                text: line['text']?.toString() ?? '',
                translation: line['translation']?.toString() ?? '',
              ),
            )
            .where((line) => line.text.trim().isNotEmpty)
            .toList();
      } catch (_) {
        return const [];
      }
    });

class HomeStatisticsData {
  const HomeStatisticsData({
    required this.totalSongs,
    required this.libraryDuration,
    required this.totalFileSize,
    required this.losslessCount,
    required this.listenDuration,
    required this.dailyListenDuration,
    required this.weeklyListenDuration,
    required this.playCount,
    this.mostPlayed,
    this.mostPlayedCount = 0,
  });

  final int totalSongs;
  final int libraryDuration;
  final int totalFileSize;
  final int losslessCount;
  final int listenDuration;
  final int dailyListenDuration;
  final int weeklyListenDuration;
  final int playCount;
  final Song? mostPlayed;
  final int mostPlayedCount;

  double get losslessRatio =>
      totalSongs <= 0 ? 0 : losslessCount * 100 / totalSongs;
}

final homeStatisticsProvider = FutureProvider<HomeStatisticsData>((ref) async {
  final refreshTimer = Timer(const Duration(minutes: 1), ref.invalidateSelf);
  ref.onDispose(refreshTimer.cancel);
  final songs = ref.watch(libraryProvider.select((state) => state.songs));
  final dbPath = await ref.read(dbPathProvider.future);
  // 首次进入时统计接口可能执行数据库迁移，串行请求避免 SQLite 写锁冲突。
  final libraryRaw = await statsGetLibraryStats(dbPath: dbPath);
  final behaviorRaw = await statsGetBehaviorStats(
    dbPath: dbPath,
    timeRangeJson: '{"type":"All"}',
  );
  final listenRaw = await statsGetListenDurations(dbPath: dbPath);
  final library = Map<String, dynamic>.from(jsonDecode(libraryRaw) as Map);
  final behavior = Map<String, dynamic>.from(jsonDecode(behaviorRaw) as Map);
  final listen = Map<String, dynamic>.from(jsonDecode(listenRaw) as Map);
  final snapshots = await loadRecentSongSnapshots();
  final top = behavior['top_songs'] is List
      ? behavior['top_songs'] as List
      : const [];
  final first = top.whereType<Map>().firstOrNull;
  final mostPath = first?['song_path']?.toString() ?? '';
  final mostPlayed =
      songs.where((song) => song.path == mostPath).firstOrNull ??
      songFromRecentSnapshot(snapshots[mostPath]);
  return HomeStatisticsData(
    totalSongs: (library['total_songs'] as num?)?.toInt() ?? songs.length,
    libraryDuration: (library['total_duration'] as num?)?.toInt() ?? 0,
    totalFileSize: (library['total_file_size'] as num?)?.toInt() ?? 0,
    losslessCount: (library['lossless_count'] as num?)?.toInt() ?? 0,
    listenDuration:
        (listen['total'] as num?)?.toInt() ??
        (behavior['total_duration'] as num?)?.toInt() ??
        0,
    dailyListenDuration: (listen['daily'] as num?)?.toInt() ?? 0,
    weeklyListenDuration: (listen['weekly'] as num?)?.toInt() ?? 0,
    playCount: (behavior['total_plays'] as num?)?.toInt() ?? 0,
    mostPlayed: mostPlayed,
    mostPlayedCount: (first?['play_count'] as num?)?.toInt() ?? 0,
  );
});

enum LeaderboardPeriod { daily, weekly, total }

extension LeaderboardPeriodLabel on LeaderboardPeriod {
  String get apiName => name;
  String get label => switch (this) {
    LeaderboardPeriod.daily => '日榜',
    LeaderboardPeriod.weekly => '周榜',
    LeaderboardPeriod.total => '总榜',
  };
}

class LeaderboardEntry {
  const LeaderboardEntry({
    required this.rank,
    required this.username,
    required this.nickname,
    required this.duration,
    this.avatar,
    this.isMe = false,
  });

  final int rank;
  final String username;
  final String nickname;
  final int duration;
  final String? avatar;
  final bool isMe;
}

class LeaderboardData {
  const LeaderboardData({
    required this.leaderboard,
    required this.totalUsers,
    this.me,
  });

  final List<LeaderboardEntry> leaderboard;
  final LeaderboardEntry? me;
  final int totalUsers;
}

LeaderboardEntry _decodeLeaderboardEntry(Map raw, {bool forceMe = false}) {
  final username = raw['username']?.toString() ?? '';
  final nickname = raw['nickname']?.toString().trim() ?? '';
  final avatar = raw['avatar']?.toString().trim() ?? '';
  final isMeValue = raw['is_me'];
  return LeaderboardEntry(
    rank: (raw['rank'] as num?)?.toInt() ?? 0,
    username: username,
    nickname: nickname.isEmpty ? username : nickname,
    avatar: avatar.isEmpty ? null : avatar,
    duration: (raw['duration'] as num?)?.toInt() ?? 0,
    isMe: forceMe || isMeValue == true || isMeValue == 1,
  );
}

LeaderboardData decodeLeaderboardData(Map<String, dynamic> data) {
  final rows = (data['leaderboard'] as List? ?? const [])
      .whereType<Map>()
      .map(_decodeLeaderboardEntry)
      .where((entry) => entry.rank > 0)
      .toList();
  final meRaw = data['me'];
  final me = meRaw is Map
      ? _decodeLeaderboardEntry(meRaw, forceMe: true)
      : null;
  return LeaderboardData(
    leaderboard: rows,
    me: me,
    totalUsers: (data['total_users'] as num?)?.toInt() ?? rows.length,
  );
}

// 页面切换或网络短暂抖动时保留上一次成功结果，避免排行榜因为一次超时
// 直接进入错误态；下一次请求成功后会覆盖对应榜单的数据。
final Map<LeaderboardPeriod, LeaderboardData> _leaderboardCache = {};

/// 启动首页时预加载全部榜单。调用方无需等待，结果会写入内存缓存，
/// 后续切换榜单时直接复用；单个榜单失败不会影响其他榜单。
void preloadHomeLeaderboards(WidgetRef ref) {
  for (final period in LeaderboardPeriod.values) {
    final future = ref.read(homeLeaderboardProvider(period).future);
    unawaited(
      future.catchError(
        (_) => const LeaderboardData(leaderboard: [], totalUsers: 0),
      ),
    );
  }
}

// 榜单由首页启动时后台预加载，并在内存中保留到下一次定时刷新；如果使用
// autoDispose，预加载结束后 provider 会立即销毁，切换到周榜/总榜仍会重新
// 请求，造成用户感知到的卡顿。
final homeLeaderboardProvider =
    FutureProvider.family<LeaderboardData, LeaderboardPeriod>((
      ref,
      period,
    ) async {
      final auth = ref.watch(authProvider);
      final notifier = ref.read(authProvider.notifier);
      final xymusicId = auth.user?.xymusicId?.trim() ?? '';

      // 预加载会同时启动日/周/总榜三个 provider。统计上报只需要执行一次，
      // 否则三份 provider 会并发读取本地统计库并重复请求服务端，启动时会
      // 与首页首帧争抢 SQLite/网络资源，造成明显卡顿。
      if (xymusicId.isNotEmpty && period == LeaderboardPeriod.daily) {
        // 听歌统计上报完全作为旁路任务执行，不能阻塞榜单请求；网络较慢
        // 或本地统计库繁忙时，用户仍可立即切换并查看日/周/总榜。
        unawaited(() async {
          try {
            final stats = await ref
                .read(homeStatisticsProvider.future)
                .timeout(const Duration(seconds: 3));
            final report = await notifier.requestBackendAction(
              'report_listen_stats',
              buildListenStatsReportPayload(
                xymusicId: xymusicId,
                totalDuration: stats.listenDuration,
                dailyDuration: stats.dailyListenDuration,
                weeklyDuration: stats.weeklyListenDuration,
              ),
              fetchTimeoutMs: 3000,
            );
            final resetAt = report['reset_at']?.toString().trim() ?? '';
            if (resetAt.isNotEmpty) {
              const resetKey = 'listen_stats_last_reset_at';
              final prefs = await SharedPreferences.getInstance();
              final lastResetAt = prefs.getString(resetKey) ?? '';
              if (lastResetAt.isEmpty || resetAt.compareTo(lastResetAt) > 0) {
                await statsResetLocalStatistics(
                  dbPath: await ref.read(dbPathProvider.future),
                );
                await prefs.setString(resetKey, resetAt);
                ref.invalidate(homeStatisticsProvider);
                await notifier.requestBackendAction(
                  'report_listen_stats',
                  buildListenStatsReportPayload(
                    xymusicId: xymusicId,
                    totalDuration: 0,
                    dailyDuration: 0,
                    weeklyDuration: 0,
                  ),
                  fetchTimeoutMs: 3000,
                );
              }
            }
          } catch (_) {
            // 上报失败不影响公共排行榜读取。
          }
        }());
      }

      try {
        final data = await notifier.requestBackendAction('get_leaderboard', {
          if (xymusicId.isNotEmpty) 'xymusic_id': xymusicId,
          'limit': 15,
          'period': period.apiName,
        }, fetchTimeoutMs: 8000);
        final decoded = decodeLeaderboardData(data);
        _leaderboardCache[period] = decoded;
        return decoded;
      } catch (_) {
        // 网络暂时不可用时展示缓存；没有缓存则展示空榜单，而不是让整个首页
        // 进入“排行榜加载失败”错误态。用户仍可点击刷新再次请求。
        return _leaderboardCache[period] ??
            const LeaderboardData(leaderboard: [], totalUsers: 0);
      }
    });

Map<String, dynamic> buildListenStatsReportPayload({
  required String xymusicId,
  required int totalDuration,
  required int dailyDuration,
  required int weeklyDuration,
}) => {
  'xymusic_id': xymusicId,
  'duration': totalDuration.clamp(0, 0x7FFFFFFFFFFFFFFF),
  'daily_duration': dailyDuration.clamp(0, 0x7FFFFFFFFFFFFFFF),
  // 服务端周榜由每日记录汇总；保留该字段便于服务端日志和后续兼容。
  'weekly_duration': weeklyDuration.clamp(0, 0x7FFFFFFFFFFFFFFF),
  'unique_songs_count': 0,
};
