import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_provider.dart';
import '../core/app_refresh.dart';
import '../core/db_path.dart';
import '../library/library_provider.dart';
import '../recent/recent_provider.dart';
import '../recent/recent_store.dart';
import '../rust/api.dart';
import 'listen_stats_uploader.dart';

// 排行榜上报的请求体构造已移到 listen_stats_uploader，这里继续对外暴露，
// 保持既有调用方（含测试）的导入路径不变。
export 'listen_stats_uploader.dart' show buildListenStatsReportPayload;

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

/// 热评接口失败退避：只对「网络 / 超时 / HTTP 非 2xx」这类真故障退避，
/// 避免上游抖动时每次进入首页与 3 分钟轮换都白打请求；退避时长与轮换
/// 周期对齐（3 分钟），到点自动恢复，成功即清除退避。
///
/// 解析失败（上游偶发返回空内容 / 非 JSON）不参与退避，否则一次空包
/// 就会把热评冻结很久。
DateTime? _hotCommentCooldownUntil;
const Duration _hotCommentRetryCooldown = Duration(minutes: 3);

/// 清掉失败退避。供「换一下」「点击重试」与下拉刷新这类**用户主动**
/// 重试入口调用：主动重试必须真正发出请求，否则会被退避直接拦下，
/// 表现为「点了没反应、要等一会儿才自己好」。
void clearHotCommentCooldown() {
  _hotCommentCooldownUntil = null;
}

final hotCommentProvider = FutureProvider.autoDispose<HotComment>((ref) async {
  // 刷新句柄在同步段（首个 await 之前）构造即注册 onDispose：autoDispose
  // provider 若在请求期间被回收，await 之后再调 ref.onDispose 会在已 dispose
  // 的 ProviderElementBase 上抛 Bad state（空闲闪退栈：onDispose → 本闭包）。
  // autoArm: false —— 3 分钟轮换的计时起点必须是「请求成功之后」，取到句柄
  // 后在下方 parseHotComment 成功处才 arm()；句柄内部自行记录回收状态并在
  // dispose 时取消定时器。
  final refresh = registerVisibleRefresh(
    ref,
    const Duration(minutes: 3),
    ref.invalidateSelf,
    autoArm: false,
  );
  final cooldownUntil = _hotCommentCooldownUntil;
  if (cooldownUntil != null && DateTime.now().isBefore(cooldownUntil)) {
    final remainSeconds =
        cooldownUntil.difference(DateTime.now()).inSeconds + 1;
    throw StateError('热评接口暂时不可用，约 $remainSeconds 秒后自动重试');
  }
  try {
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
    _hotCommentCooldownUntil = null;
    // 后台不刷新：到点若 App 在 hidden 则顺延，回前台后的下一个检查点
    // 才真正重拉热评，避免在后台按 3 分钟周期拉接口唤醒网络。
    // 计时起点仍为「热评请求成功之后」，不在请求发起时启动；已回收时
    // arm() 内部直接忽略，不会武装定时器。
    refresh.arm();
    return result;
  } on FormatException catch (error) {
    // 上游偶发返回空内容 / 非 JSON：不退避，等下次轮换或用户重试即可恢复。
    throw StateError('热评内容解析失败（${error.message}）');
  } catch (error) {
    _hotCommentCooldownUntil = DateTime.now().add(_hotCommentRetryCooldown);
    throw StateError('热评接口请求失败（$error）');
  }
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
  // 后台不刷新：首页统计 5 分钟一刷（原 1 分钟，耗电优化），App 不可见时
  // 到点顺延，回前台再重算。每次重算都要串行跑 3 个 stats 接口（Rust 侧
  // 各开一次连接 + 20 条 DDL），1 分钟档在前台上也属于纯浪费。
  // 句柄在同步段构造即注册 onDispose 并立即计时（计时起点就是本次计算开始）。
  registerVisibleRefresh(
    ref,
    const Duration(minutes: 5),
    ref.invalidateSelf,
  );
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
      //
      // 上报本身在 listen_stats_uploader 中做节流/单飞，并直接读本地统计库
      // 的实时值（不再复用 homeStatisticsProvider 的 5 分钟缓存快照）。
      // 播放器在写库后、切后台时也会主动触发上报，这里只是兜底入口。
      if (xymusicId.isNotEmpty && period == LeaderboardPeriod.daily) {
        unawaited(uploadListenStats(ref));
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
