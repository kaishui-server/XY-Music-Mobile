import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_provider.dart';
import '../core/db_path.dart';
import '../rust/api.dart';

/// 云端排行榜听歌时长上报。
///
/// 历史实现把上报挂在 [homeLeaderboardProvider] 的日榜分支里，存在三个
/// 直接导致"排行榜时长不准"的问题：
/// 1. 数据源是 `homeStatisticsProvider` 的缓存快照（5 分钟才重算一次，
///    且读取时只给 3 秒超时）——启动/播放期间读到的常常是很久以前的
///    数值，超时后整次上报还会被丢弃；
/// 2. 只在进入首页构建日榜 provider 时上报，用户长时间在播放页听歌时
///    云端数据完全不动；
/// 3. 服务端回下发 `reset_at` 时会对本地调用 `statsResetLocalStatistics`，
///    而这个接口会清空 global_stats / song_stats / play_history 等**全部**
///    聚合，累计时长真实归零，随后又把 0 上报给服务端，总榜越用越小。
///
/// 现在改为：实时读本地统计库 → 节流上报（播放期间也持续更新）→
/// `reset_at` 只更新本地标记，不再破坏本地累计。
const Duration _kMinUploadGap = Duration(seconds: 60);

/// 记录上一次服务端下发的重置标记，用于判断是否需要重新对齐。
const String kListenStatsResetAtKey = 'listen_stats_last_reset_at';

DateTime? _lastUploadAt;
Future<void>? _inFlight;
bool _queued = false;

/// 只依赖"读 provider"这一能力，便于 Ref / WidgetRef 共用同一套上报逻辑。
typedef ProviderRead = T Function<T>(ProviderListenable<T> provider);

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

/// 上报三周期听歌时长。
///
/// [force] 为 true 时忽略节流窗口（切后台、进首页、用户下拉刷新等关键
/// 时刻必须真正发出请求）。任何异常都被吞掉——上报只是旁路统计，不能
/// 影响播放与榜单展示。
Future<void> uploadListenStats(Ref ref, {bool force = false}) =>
    uploadListenStatsWith(read: ref.read, force: force);

/// Widget 侧入口（首页定时刷新、下拉刷新）。
Future<void> uploadListenStatsFromWidget(WidgetRef ref, {bool force = false}) =>
    uploadListenStatsWith(read: ref.read, force: force);

Future<void> uploadListenStatsWith({
  required ProviderRead read,
  bool force = false,
}) {
  final running = _inFlight;
  if (running != null) {
    if (force) _queued = true;
    return running;
  }
  final last = _lastUploadAt;
  if (!force &&
      last != null &&
      DateTime.now().difference(last) < _kMinUploadGap) {
    return Future<void>.value();
  }
  final future = _upload(read).whenComplete(() {
    _inFlight = null;
    _lastUploadAt = DateTime.now();
    if (_queued) {
      _queued = false;
      // 上一次上报进行中又产生了新时长（强制上报被合并），补发一次。
      unawaited(uploadListenStatsWith(read: read, force: true));
    }
  });
  _inFlight = future;
  return future;
}

Future<void> _upload(ProviderRead read) async {
  try {
    final auth = read(authProvider);
    final xymusicId = auth.user?.xymusicId?.trim() ?? '';
    if (xymusicId.isEmpty) return;
    final notifier = read(authProvider.notifier);
    // 直接读统计库：不复用 homeStatisticsProvider 的缓存，否则上报的
    // 永远是若干分钟前的旧值。
    final dbPath = await read(dbPathProvider.future);
    final raw = await statsGetListenDurations(dbPath: dbPath);
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    final daily = (decoded['daily'] as num?)?.toInt() ?? 0;
    final weekly = (decoded['weekly'] as num?)?.toInt() ?? 0;
    final total = (decoded['total'] as num?)?.toInt() ?? 0;
    final report = await notifier.requestBackendAction(
      'report_listen_stats',
      buildListenStatsReportPayload(
        xymusicId: xymusicId,
        totalDuration: total,
        dailyDuration: daily,
        weeklyDuration: weekly,
      ),
      fetchTimeoutMs: 8000,
    );
    await _syncResetMarker(report);
  } catch (_) {
    // 网络不佳或本地统计库繁忙时静默失败，下一次触发会重试。
  }
}

Future<void> _syncResetMarker(Map<String, dynamic> report) async {
  final resetAt = report['reset_at']?.toString().trim() ?? '';
  if (resetAt.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  final lastResetAt = prefs.getString(kListenStatsResetAtKey) ?? '';
  if (lastResetAt.isNotEmpty && resetAt.compareTo(lastResetAt) <= 0) return;
  // 服务端重置只代表云端记录重新起算。本地统计（尤其 global_stats 里的
  // 累计时长）是唯一可信来源，**不能**再调用 statsResetLocalStatistics
  // 把它一起清空：那会让总榜时长永久归零，排行榜越用越小。
  // 下一次上报会立刻用本地真实累计覆盖云端记录，完成重新对齐。
  await prefs.setString(kListenStatsResetAtKey, resetAt);
}

/// 测试与调试用：清空节流与在飞状态。
void resetListenStatsUploaderForTest() {
  _lastUploadAt = null;
  _inFlight = null;
  _queued = false;
}
