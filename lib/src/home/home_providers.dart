import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_provider.dart';
import '../core/db_path.dart';
import '../library/library_provider.dart';
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
    required this.playCount,
    this.mostPlayed,
    this.mostPlayedCount = 0,
  });

  final int totalSongs;
  final int libraryDuration;
  final int totalFileSize;
  final int losslessCount;
  final int listenDuration;
  final int playCount;
  final Song? mostPlayed;
  final int mostPlayedCount;

  double get losslessRatio =>
      totalSongs <= 0 ? 0 : losslessCount * 100 / totalSongs;
}

final homeStatisticsProvider = FutureProvider<HomeStatisticsData>((ref) async {
  final songs = ref.watch(libraryProvider.select((state) => state.songs));
  final dbPath = await ref.read(dbPathProvider.future);
  // 首次进入时统计接口可能执行数据库迁移，串行请求避免 SQLite 写锁冲突。
  final libraryRaw = await statsGetLibraryStats(dbPath: dbPath);
  final behaviorRaw = await statsGetBehaviorStats(
    dbPath: dbPath,
    timeRangeJson: '{"type":"All"}',
  );
  final library = Map<String, dynamic>.from(jsonDecode(libraryRaw) as Map);
  final behavior = Map<String, dynamic>.from(jsonDecode(behaviorRaw) as Map);
  final top = behavior['top_songs'] is List
      ? behavior['top_songs'] as List
      : const [];
  final first = top.whereType<Map>().firstOrNull;
  final mostPath = first?['song_path']?.toString() ?? '';
  final mostPlayed = songs.where((song) => song.path == mostPath).firstOrNull;
  return HomeStatisticsData(
    totalSongs: (library['total_songs'] as num?)?.toInt() ?? songs.length,
    libraryDuration: (library['total_duration'] as num?)?.toInt() ?? 0,
    totalFileSize: (library['total_file_size'] as num?)?.toInt() ?? 0,
    losslessCount: (library['lossless_count'] as num?)?.toInt() ?? 0,
    listenDuration: (behavior['total_duration'] as num?)?.toInt() ?? 0,
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

final homeLeaderboardProvider = FutureProvider.autoDispose
    .family<LeaderboardData, LeaderboardPeriod>((ref, period) async {
      final auth = ref.watch(authProvider);
      final stats = await ref.watch(homeStatisticsProvider.future);
      final notifier = ref.read(authProvider.notifier);
      final ciyuanxiId = auth.user?.ciyuanxiId?.trim() ?? '';

      if (ciyuanxiId.isNotEmpty) {
        try {
          await notifier.requestBackendAction('report_listen_stats', {
            'ciyuanxi_id': ciyuanxiId,
            'duration': stats.listenDuration,
            'unique_songs_count': 0,
          }, fetchTimeoutMs: 8000);
        } catch (_) {
          // 上报失败不影响公共排行榜读取。
        }
      }

      final data = await notifier.requestBackendAction('get_leaderboard', {
        if (ciyuanxiId.isNotEmpty) 'ciyuanxi_id': ciyuanxiId,
        'limit': 15,
        'period': period.apiName,
      }, fetchTimeoutMs: 12000);
      return decodeLeaderboardData(data);
    });
