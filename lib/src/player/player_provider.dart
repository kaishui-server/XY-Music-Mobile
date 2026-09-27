import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/db_path.dart';
import '../core/settings.dart';
import '../effects/effects_provider.dart';
import '../favorites/favorites_provider.dart';
import '../plugins/plugin_runtime.dart';
import '../recent/recent_store.dart';
import '../rust/api.dart';
import '../rust/music/types.dart';
import '../widgets/cover_image.dart';
import 'downloaded_song_store.dart';
import 'desktop_lyrics.dart';
import 'lx_lyrics_builder.dart';
import 'video_playback_session.dart';

/// 播放中的单曲信息（小而美：仅保留 UI 需要的最小字段）。
class QueueItem {
  final String path;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final String? pluginId;
  final Map<String, dynamic>? pluginData;
  final String? coverUrl;
  final String? lyricsRaw;
  final bool lyricsAttempted;
  const QueueItem({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    this.durationMs = 0,
    this.pluginId,
    this.pluginData,
    this.coverUrl,
    this.lyricsRaw,
    this.lyricsAttempted = false,
  });

  QueueItem copyWith({
    String? coverUrl,
    String? lyricsRaw,
    bool? lyricsAttempted,
    bool clearLyricsRaw = false,
  }) => QueueItem(
    path: path,
    title: title,
    artist: artist,
    album: album,
    durationMs: durationMs,
    pluginId: pluginId,
    pluginData: pluginData,
    coverUrl: coverUrl ?? this.coverUrl,
    lyricsRaw: clearLyricsRaw ? null : lyricsRaw ?? this.lyricsRaw,
    lyricsAttempted: lyricsAttempted ?? this.lyricsAttempted,
  );
}

class PlaybackRelinkProposal {
  const PlaybackRelinkProposal({
    required this.id,
    required this.queueIndex,
    required this.originalPath,
    required this.originalPluginName,
    required this.replacement,
    required this.replacementSourceName,
    required this.isLocal,
  });

  final int id;
  final int queueIndex;
  final String originalPath;
  final String originalPluginName;
  final QueueItem replacement;
  final String replacementSourceName;
  final bool isLocal;
}

class PlaybackNoticeEvent {
  const PlaybackNoticeEvent(this.id, this.message);

  final int id;
  final String message;
}

final playbackRelinkProposalProvider = StateProvider<PlaybackRelinkProposal?>(
  (ref) => null,
);
final playbackNoticeEventProvider = StateProvider<PlaybackNoticeEvent?>(
  (ref) => null,
);

/// 插件替代音源必须同时满足同名、同作者和近似同长度。不同平台通常会有
/// 1～2 秒的取整差异，因此把“同时长”限定为最多相差 2 秒。
bool isStrictReplacementMatch({
  required String title,
  required String artist,
  required int durationMs,
  required String candidateTitle,
  required String candidateArtist,
  required int candidateDurationMs,
}) {
  if (durationMs <= 0 || candidateDurationMs <= 0) return false;
  return _normalizeReplacementText(title) ==
          _normalizeReplacementText(candidateTitle) &&
      _normalizeReplacementText(artist) ==
          _normalizeReplacementText(candidateArtist) &&
      (durationMs - candidateDurationMs).abs() <= 2000;
}

String _normalizeReplacementText(String value) =>
    _normalizeRecognizedText(value.trim());

class _PluginUnavailableException implements Exception {
  const _PluginUnavailableException(this.pluginId, this.pluginName);

  final String pluginId;
  final String pluginName;

  @override
  String toString() => '歌曲所属插件“$pluginName”已停用或删除';
}

enum PlaybackSourceType { plugin, lx, networkUrl, localFile }

const _recognizedPluginCacheKey = '_recognizedPluginFallback';
const _playbackSourceAssociationsKey = 'playbackSourceAssociationsV1';
const _rememberedLyricsKey = 'rememberedLyricsV1';
const _rememberedLyricsAssociationKey = 'rememberedLyricsAssociationV1';
const _rememberedLyricsOriginalKey = 'rememberedLyricsOriginalV1';

/// 会话歌词格式版本：网络歌词的词级时间转换逻辑变更时递增。
/// 恢复会话时若版本不匹配则丢弃旧版本缓存的网络歌词（lyricsRaw），
/// 重新抓取——否则旧版本转换出的错位逐字时间会被永久复用
/// （如 QQ QRC 绝对时间戳被当相对偏移，只有行时间为 0 的标题行逐字）。
/// 用户手动关联的歌词按路径存在独立的记忆存储中，播放时会重新套用，
/// 不受作废影响；本地文件歌词存的是原文，展示时每次都重新解析。
const _sessionLyricsFormatVersion = 1;

/// 识曲结果只有歌名、歌手等文本信息，回退到插件搜索时必须先做严格匹配，
/// 避免仅因标题里有几个相同字符就播放成另一首歌。
int recognizedSongMatchScore({
  required String title,
  required String artist,
  required String candidateTitle,
  required String candidateArtist,
  int durationMs = 0,
  int candidateDurationMs = 0,
}) {
  final normalizedTitle = _normalizeRecognizedText(title, stripVersion: true);
  final normalizedCandidateTitle = _normalizeRecognizedText(
    candidateTitle,
    stripVersion: true,
  );
  if (normalizedTitle.isEmpty || normalizedCandidateTitle.isEmpty) return -1;

  var score = 0;
  if (normalizedTitle == normalizedCandidateTitle) {
    score += 100;
  } else if (normalizedTitle.length >= 2 &&
      normalizedCandidateTitle.length >= 2 &&
      (normalizedTitle.contains(normalizedCandidateTitle) ||
          normalizedCandidateTitle.contains(normalizedTitle))) {
    score += 70;
  } else {
    return -1;
  }

  final normalizedArtist = _normalizeRecognizedText(artist);
  final normalizedCandidateArtist = _normalizeRecognizedText(candidateArtist);
  if (normalizedArtist.isNotEmpty && normalizedCandidateArtist.isNotEmpty) {
    if (normalizedArtist == normalizedCandidateArtist) {
      score += 40;
    } else if (normalizedArtist.contains(normalizedCandidateArtist) ||
        normalizedCandidateArtist.contains(normalizedArtist)) {
      score += 25;
    }
  }

  if (durationMs > 0 && candidateDurationMs > 0) {
    final difference = (durationMs - candidateDurationMs).abs();
    if (difference <= 5000) {
      score += 20;
    } else if (difference <= 12000) {
      score += 10;
    }
  }
  return score;
}

/// 歌词候选不比较时长，但歌手必须严格一致，避免同名翻唱混入结果。
int pluginLyricsSongMatchScore({
  required String title,
  required String artist,
  required String candidateTitle,
  required String candidateArtist,
}) {
  final normalizedArtist = _normalizeRecognizedText(artist);
  final normalizedCandidateArtist = _normalizeRecognizedText(candidateArtist);
  if (normalizedArtist.isEmpty ||
      normalizedCandidateArtist.isEmpty ||
      normalizedArtist != normalizedCandidateArtist) {
    return -1;
  }
  final normalizedTitle = _normalizeRecognizedText(title, stripVersion: true);
  final normalizedCandidateTitle = _normalizeRecognizedText(
    candidateTitle,
    stripVersion: true,
  );
  if (normalizedTitle.isEmpty || normalizedCandidateTitle.isEmpty) return -1;
  if (normalizedTitle == normalizedCandidateTitle) return 100;
  if (normalizedTitle.length >= 2 &&
      normalizedCandidateTitle.length >= 2 &&
      (normalizedTitle.contains(normalizedCandidateTitle) ||
          normalizedCandidateTitle.contains(normalizedTitle))) {
    return 70;
  }
  return -1;
}

String _normalizeRecognizedText(String value, {bool stripVersion = false}) {
  var normalized = value.toLowerCase();
  if (stripVersion) {
    normalized = normalized.replaceAll(
      RegExp(r'[\(（\[【][^\)）\]】]*[\)）\]】]'),
      '',
    );
  }
  return normalized.replaceAll(
    RegExp(r'[^a-z0-9\u3400-\u9fff]+', unicode: true),
    '',
  );
}

class _RecognizedAudioSource {
  const _RecognizedAudioSource({
    required this.url,
    this.headers = const {},
    this.lyrics = '',
    this.plugin,
    this.pluginData,
  });

  final String url;
  final Map<String, String> headers;
  final String lyrics;
  final EnabledMusicPlugin? plugin;
  final Map<String, dynamic>? pluginData;
}

class PlaybackDownloadSource {
  const PlaybackDownloadSource({required this.url, this.headers = const {}});

  final String url;
  final Map<String, String> headers;
}

class PluginLyricsOption {
  const PluginLyricsOption({
    required this.id,
    required this.pluginId,
    required this.pluginName,
    required this.songTitle,
    required this.songArtist,
    required this.songAlbum,
    required this.durationMs,
    required this.rawData,
    this.lyrics = '',
  });

  final String id;
  final String pluginId;
  final String pluginName;
  final String songTitle;
  final String songArtist;
  final String songAlbum;
  final int durationMs;
  final Map<String, dynamic> rawData;
  final String lyrics;

  PluginLyricsOption copyWith({String? lyrics}) => PluginLyricsOption(
    id: id,
    pluginId: pluginId,
    pluginName: pluginName,
    songTitle: songTitle,
    songArtist: songArtist,
    songAlbum: songAlbum,
    durationMs: durationMs,
    rawData: rawData,
    lyrics: lyrics ?? this.lyrics,
  );
}

/// 当前歌曲手动关联歌词的来源信息，用于在“更多 > 关联歌词”中展示并支持取消关联。
class RememberedLyricsAssociation {
  const RememberedLyricsAssociation({
    required this.source,
    this.pluginName,
    this.title = '',
    this.artist = '',
    this.durationMs = 0,
  });

  final String source;
  final String? pluginName;
  final String title;
  final String artist;
  final int durationMs;

  factory RememberedLyricsAssociation.fromJson(Map<String, dynamic> json) =>
      RememberedLyricsAssociation(
        source: json['source']?.toString() ?? 'local',
        pluginName: json['pluginName']?.toString(),
        title: json['title']?.toString() ?? '',
        artist: json['artist']?.toString() ?? '',
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
    'source': source,
    'pluginName': pluginName,
    'title': title,
    'artist': artist,
    'durationMs': durationMs,
  };
}

class PluginLyricsSearchProgress {
  const PluginLyricsSearchProgress({
    required this.options,
    required this.completedPlugins,
    required this.totalPlugins,
  });

  final List<PluginLyricsOption> options;
  final int completedPlugins;
  final int totalPlugins;
}

String createDefaultPluginLyricsSearchQuery(String title, String artist) =>
    [title.trim(), artist.trim()].where((value) => value.isNotEmpty).join(' ');

List<PluginLyricsOption> buildPluginLyricsSearchOptions(
  EnabledMusicPlugin plugin,
  Iterable<PluginSearchSong> songs,
) {
  final options = <PluginLyricsOption>[];
  final seen = <String>{};
  for (final song in songs.take(30)) {
    final identity = '${plugin.id}:${song.id}';
    if (!seen.add(identity) || song.title.trim().isEmpty) continue;
    options.add(
      PluginLyricsOption(
        id: identity,
        pluginId: plugin.id,
        pluginName: plugin.name,
        songTitle: song.title,
        songArtist: song.artist,
        songAlbum: song.album,
        durationMs: song.durationMs,
        rawData: song.rawData,
      ),
    );
  }
  return options;
}

class _RecognizedSearchCandidate {
  const _RecognizedSearchCandidate({
    required this.plugin,
    required this.song,
    required this.score,
  });

  final EnabledMusicPlugin plugin;
  final PluginSearchSong song;
  final int score;
}

class _RecognizedSearchBatch {
  const _RecognizedSearchBatch(this.plugin, this.songs);

  final EnabledMusicPlugin plugin;
  final List<PluginSearchSong> songs;
}

/// 播放入口和会话恢复必须使用同一套音源分类，不能把 `plugin://` 虚拟路径
/// 交给本地文件播放器。
PlaybackSourceType playbackSourceTypeFor(QueueItem item) {
  if (item.path.startsWith('lx://')) {
    return PlaybackSourceType.lx;
  }
  if (item.pluginId?.trim().isNotEmpty == true) {
    return PlaybackSourceType.plugin;
  }
  if (item.path.startsWith('http://') || item.path.startsWith('https://')) {
    return PlaybackSourceType.networkUrl;
  }
  return PlaybackSourceType.localFile;
}

String normalizeLocalAudioPath(String rawPath, {bool? windows}) {
  var path = rawPath.trim().replaceFirst('\uFEFF', '');
  if (path.length >= 2 &&
      ((path.startsWith('"') && path.endsWith('"')) ||
          (path.startsWith("'") && path.endsWith("'")))) {
    path = path.substring(1, path.length - 1).trim();
  }
  final uri = Uri.tryParse(path);
  if (uri?.scheme.toLowerCase() == 'file') {
    try {
      return uri!.toFilePath(windows: windows ?? Platform.isWindows);
    } catch (_) {}
  }
  if (path.contains('%')) {
    try {
      return Uri.decodeFull(path);
    } catch (_) {}
  }
  return path;
}

const _playbackErrorNotSet = Object();
const _sleepTimerNotSet = Object();
const minimumSleepTimerDuration = Duration(seconds: 30);
const maximumSleepTimerDuration = Duration(hours: 12);

bool isValidSleepTimerDuration(Duration duration) =>
    duration >= minimumSleepTimerDuration &&
    duration <= maximumSleepTimerDuration;

/// 计算定时关闭弹窗应显示的剩余秒数。单独抽出便于使用固定时间测试。
int sleepTimerRemainingSeconds(DateTime? endsAt, {DateTime? now}) {
  if (endsAt == null) return 0;
  return endsAt.difference(now ?? DateTime.now()).inSeconds + 1;
}

class PlaybackState {
  final QueueItem? current;
  final List<QueueItem> queue;
  final int queueIndex;
  final bool isPlaying;
  final double position;
  final double duration;
  final int playMode; // 0 顺序(列表循环) 1 单曲循环 2 随机
  final bool isLoading;
  final String? errorMessage;
  final DateTime? sleepTimerEndsAt;
  final String currentQuality;
  final double playbackSpeed;
  const PlaybackState({
    this.current,
    this.queue = const [],
    this.queueIndex = -1,
    this.isPlaying = false,
    this.position = 0,
    this.duration = 0,
    this.playMode = 0,
    this.isLoading = false,
    this.errorMessage,
    this.sleepTimerEndsAt,
    this.currentQuality = '320k',
    this.playbackSpeed = 1.0,
  });

  PlaybackState copyWith({
    QueueItem? current,
    List<QueueItem>? queue,
    int? queueIndex,
    bool? isPlaying,
    double? position,
    double? duration,
    int? playMode,
    bool? isLoading,
    Object? errorMessage = _playbackErrorNotSet,
    Object? sleepTimerEndsAt = _sleepTimerNotSet,
    String? currentQuality,
    double? playbackSpeed,
  }) {
    return PlaybackState(
      current: current ?? this.current,
      queue: queue ?? this.queue,
      queueIndex: queueIndex ?? this.queueIndex,
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      playMode: playMode ?? this.playMode,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: identical(errorMessage, _playbackErrorNotSet)
          ? this.errorMessage
          : errorMessage as String?,
      sleepTimerEndsAt: identical(sleepTimerEndsAt, _sleepTimerNotSet)
          ? this.sleepTimerEndsAt
          : sleepTimerEndsAt as DateTime?,
      currentQuality: currentQuality ?? this.currentQuality,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
    );
  }
}

/// 应用播放模式与 just_audio 原生循环模式的映射。
/// 顺序和随机由队列逻辑切歌，只有单曲循环交给播放器原生处理。
LoopMode audioLoopModeForPlayMode(int playMode) =>
    normalizePlayMode(playMode) == 1 ? LoopMode.one : LoopMode.off;

/// 媒体会话桥接。
///
/// 本应用采用“每首歌单独 setUrl”的播放模型，just_audio_background 内部
/// 队列永远只有一项，其 hasNext/hasPrevious 恒为 false，因此系统媒体通知
/// （状态栏/锁屏/灵动岛样式的媒体卡片）只显示播放/暂停按钮，MediaSession
/// 也没有声明 skipToNext/skipToPrevious 能力——蓝牙耳机的上一首/下一首
/// 按键因此失效。
///
/// 该桥接包装 just_audio_background 的内部 handler：
/// - 在 playbackState 中补上上一首/下一首控件与对应的 MediaAction，
///   让媒体卡片显示完整的切歌布局，并让系统知道支持切歌；
/// - 注入「收藏」「播放模式」两个自定义按钮（对齐 QQ 音乐等主流播放器
///   的通知栏五键布局：收藏/上一首/播放暂停/下一首/播放模式），图标随
///   收藏状态与播放模式动态切换；
/// - 把 skipToNext/skipToPrevious 及自定义按键转发回 [PlayerNotifier]，
///   由应用自己的播放队列决定切歌行为。
class _MediaSessionBridge extends audio_service.CompositeAudioHandler {
  _MediaSessionBridge(super.inner) : _innerRef = inner;

  /// 被包装的 handler（CompositeAudioHandler 不公开 inner 访问器）。
  final audio_service.AudioHandler _innerRef;

  /// 由播放器注入的切歌回调；为空时回退到被包装 handler 的默认行为。
  Future<void> Function()? onSkipToNext;
  Future<void> Function()? onSkipToPrevious;

  /// 查询当前曲目是否已收藏（用于通知栏收藏按钮的实心/空心图标）。
  bool Function()? favoriteStateResolver;

  /// 查询当前播放模式（0 列表循环 1 单曲循环 2 随机）。
  int Function()? playModeResolver;

  /// 由播放器注入的应用播放队列来源（返回 state.queue 的引用）。
  /// 蓝牙 AVRCP/车机/系统媒体界面按 MediaSession 队列长度判定
  /// 上一首/下一首是否可用；单 URL 播放模型的内部队列恒为 1 首，
  /// 必须把应用队列同步给媒体会话，否则蓝牙耳机/车机的切歌键
  /// 会被判定为不可用而吞掉。
  List<QueueItem>? Function()? queueSource;

  /// 当前曲目在应用队列中的下标（写入 PlaybackState.queueIndex，
  /// 供系统媒体界面对队列高亮定位）。
  int? Function()? queueIndexResolver;

  /// 车机/系统媒体界面点击队列中某首歌时跳转播放（应用侧按
  /// 队列下标点播，替代内部 handler 在单曲源上越界 seek 的默认行为）。
  Future<void> Function(int index)? onSkipToQueueItem;

  /// 通知栏「收藏」按钮：切换当前曲目的收藏状态。
  Future<void> Function()? onToggleFavorite;

  /// 通知栏「播放模式」按钮：循环切换列表循环/单曲循环/随机。
  Future<void> Function()? onCyclePlayMode;

  /// 发布给媒体会话的队列（应用队列转换的 MediaItem 列表）。
  /// 覆写 [queue] 后 SwitchAudioHandler 会把它经平台通道同步到
  /// 原生 mediaSession.setQueue，内部 handler 每次点播重载单曲
  /// 队列的行为不再影响媒体会话侧。
  final BehaviorSubject<List<audio_service.MediaItem>> _bridgeQueue =
      BehaviorSubject<List<audio_service.MediaItem>>.seeded(const []);

  /// 上次同步过的应用队列引用（identical 检测，避免每次状态广播
  /// 都重复整表序列化推送）。
  List<QueueItem>? _lastQueueSourceRef;

  final BehaviorSubject<audio_service.PlaybackState> _patchedPlaybackState =
      BehaviorSubject<audio_service.PlaybackState>();
  StreamSubscription<audio_service.PlaybackState>? _innerSubscription;
  audio_service.PlaybackState? _lastInnerState;
  bool _attached = false;

  /// 订阅被包装 handler 的播放状态并开始发布补丁后的状态。
  /// 必须在替换 SwitchAudioHandler.inner 之前调用一次。
  void attach() {
    if (_attached) return;
    _attached = true;
    _innerSubscription = _innerRef.playbackState.listen(_publish);
  }

  /// 取消订阅（桥接被重建安装时调用，避免旧实例泄漏监听）。
  void detach() {
    _attached = false;
    _innerSubscription?.cancel();
    _innerSubscription = null;
    _bridgeQueue.close();
  }

  /// 收藏/播放模式等自定义按钮状态变化时主动刷新通知（稳定播放中
  /// inner handler 不会再广播新状态，必须由宿主显式触发重发布）。
  void notifyCustomControlsChanged() {
    final last = _lastInnerState;
    if (last != null && !_patchedPlaybackState.isClosed) {
      _publish(last);
    }
  }

  audio_service.MediaControl _favoriteControl() {
    final favorite = favoriteStateResolver?.call() ?? false;
    return audio_service.MediaControl.custom(
      androidIcon: 'drawable/audio_service_favorite${favorite ? '_filled' : ''}',
      label: favorite ? '取消收藏' : '收藏',
      name: 'toggleFavorite',
    );
  }

  audio_service.MediaControl _playModeControl() {
    const icons = [
      'drawable/audio_service_repeat',
      'drawable/audio_service_repeat_one',
      'drawable/audio_service_shuffle',
    ];
    const labels = ['列表循环', '单曲循环', '随机播放'];
    final mode = (playModeResolver?.call() ?? 0).clamp(0, 2);
    return audio_service.MediaControl.custom(
      androidIcon: icons[mode],
      label: labels[mode],
      name: 'cyclePlayMode',
    );
  }

  /// 应用队列同步到媒体会话的条数上限：队列经 Binder 传给
  /// mediaSession.setQueue，事务上限约 1MB，超大歌单（数千首）整表
  /// 推送会触发 TransactionTooLargeException；蓝牙 AVRCP 的
  /// now-playing 列表通常也只展示前几百条，截断到 500 条足够。
  static const int _maxSyncQueueLength = 500;

  /// 应用队列引用变化时把队列转换并推送到媒体会话。内部 handler
  /// 每次点播（customLoad）都会把自身队列重置为单曲，但媒体会话
  /// 读的是覆写后的 [queue]，不受影响；只有应用队列真正变化
  /// （点播新列表/增删歌）才重新整表推送。
  void _syncQueueIfNeeded() {
    final source = queueSource?.call();
    if (identical(source, _lastQueueSourceRef)) return;
    _lastQueueSourceRef = source;
    if (_bridgeQueue.isClosed) return;
    if (source == null || source.isEmpty) {
      _bridgeQueue.add(const []);
      return;
    }
    final items = [
      for (final item
          in source.take(_maxSyncQueueLength))
        _toMediaItem(item),
    ];
    _bridgeQueue.add(items);
  }

  /// 应用队列项转换为媒体会话的 MediaItem：id 用歌曲路径（与应用
  /// 侧点播定位一致），时长/封面可用时附带，供车机/蓝牙界面展示。
  audio_service.MediaItem _toMediaItem(QueueItem item) {
    final artUri = Uri.tryParse(item.coverUrl ?? '');
    return audio_service.MediaItem(
      id: item.path,
      title: item.title,
      artist: item.artist,
      album: item.album,
      duration: item.durationMs > 0
          ? Duration(milliseconds: item.durationMs)
          : null,
      artUri: (artUri != null && artUri.hasScheme) ? artUri : null,
    );
  }

  @override
  ValueStream<List<audio_service.MediaItem>> get queue => _bridgeQueue;

  void _publish(audio_service.PlaybackState state) {
    _lastInnerState = state;
    _syncQueueIfNeeded();
    // Android 13+（含澎湃 HyperOS）系统媒体卡片按 PlaybackState 分配
    // 按钮槽位：播放/暂停居中、上一首/下一首按 action bits，两个
    // CustomAction 落在最外侧，最终呈
    // [收藏][上一首][播放暂停][下一首][播放模式] 的五键布局；
    // Android 12 及以下的展开视图按 controls 顺序渲染，紧凑视图取
    // 索引 1/2/3（上一首/播放暂停/下一首）。
    final controls = <audio_service.MediaControl>[
      _favoriteControl(),
      audio_service.MediaControl.skipToPrevious,
      state.playing
          ? audio_service.MediaControl.pause
          : audio_service.MediaControl.play,
      audio_service.MediaControl.skipToNext,
      _playModeControl(),
    ];
    _patchedPlaybackState.add(
      state.copyWith(
        controls: controls,
        systemActions: {
          ...state.systemActions,
          audio_service.MediaAction.skipToPrevious,
          audio_service.MediaAction.skipToNext,
        },
        androidCompactActionIndices: const [1, 2, 3],
        // 应用队列下标（蓝牙/车机界面对 now-playing 队列高亮定位；
        // 单曲播放模型的内部下标恒为 0，直接覆盖）。
        queueIndex: queueIndexResolver?.call(),
      ),
    );
  }

  @override
  ValueStream<audio_service.PlaybackState> get playbackState =>
      _patchedPlaybackState;

  /// 车机方向盘/蓝牙耳机的上一首/下一首按键走系统 KeyEvent → onClick
  /// 路径（区别于通知栏按钮直接调 skipToNext）。默认实现最终在下游的
  /// _PlayerAudioHandler 上就地解析虚方法 skipToNext，因单 URL 播放
  /// 模型 hasNext 恒为 false 而变成 no-op，所以必须在桥接层显式拦截
  /// 并路由到注入的切歌回调。
  @override
  Future<void> click([
    audio_service.MediaButton button = audio_service.MediaButton.media,
  ]) async {
    if (button == audio_service.MediaButton.next) {
      final callback = onSkipToNext;
      if (callback != null) {
        await callback();
        return;
      }
    } else if (button == audio_service.MediaButton.previous) {
      final callback = onSkipToPrevious;
      if (callback != null) {
        await callback();
        return;
      }
    }
    await super.click(button);
  }

  @override
  // ignore: must_call_super
  Future<void> skipToNext() async {
    final callback = onSkipToNext;
    if (callback != null) {
      await callback();
      return;
    }
    await super.skipToNext();
  }

  @override
  // ignore: must_call_super
  Future<void> skipToPrevious() async {
    final callback = onSkipToPrevious;
    if (callback != null) {
      await callback();
      return;
    }
    await super.skipToPrevious();
  }

  /// 车机/系统媒体界面点击 now-playing 队列中的歌曲：路由到应用侧
  /// 按队列下标点播（默认实现会在单曲源上做越界 seek，无效）。
  @override
  // ignore: must_call_super
  Future<void> skipToQueueItem(int index) async {
    final callback = onSkipToQueueItem;
    if (callback != null) {
      await callback(index);
      return;
    }
    await super.skipToQueueItem(index);
  }

  /// 通知栏自定义按钮：custom action 经媒体会话回到这里，拦截后路由到
  /// 注入的回调（收藏/播放模式），其余 custom action 原样转发。
  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    switch (name) {
      case 'toggleFavorite':
        final callback = onToggleFavorite;
        if (callback != null) {
          await callback();
          return;
        }
      case 'cyclePlayMode':
        final callback = onCyclePlayMode;
        if (callback != null) {
          await callback();
          return;
        }
    }
    await super.customAction(name, extras);
  }
}

class PlayerNotifier extends StateNotifier<PlaybackState>
    with WidgetsBindingObserver {
  PlayerNotifier(this._ref) : super(const PlaybackState()) {
    WidgetsBinding.instance.addObserver(this);
    _statsFlushTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (state.current != null && state.isPlaying) {
        _flushCurrentPlaybackStats();
      }
    });
    VideoPlaybackSession.progressRevision.addListener(_syncVideoPlaybackState);
    _ref.listen<AsyncValue<AppSettings>>(settingsProvider, (previous, next) {
      final allowOtherAudio =
          next.valueOrNull?.playOtherAudioWithoutInterruption ?? false;
      unawaited(_configureAudioSession(allowOtherAudio));
      // 开关桌面歌词时会直接启动原生浮窗（此时显示“暂无歌词”），
      // 之前发送过隐藏消息的标记已失效，必须重置后重新判定显隐，
      // 否则“软件内不显示桌面歌词”时浮窗会一直停留在“暂无歌词”。
      _desktopLyricsHiddenSent = false;
      _requestDesktopLyricsSync(immediate: true);
    });
    // 音效（均衡器/前级/音量增强/变速变调）：音效页的全部修改都写入
    // effectsProvider，这里桥接到真实播放引擎——普通输出走系统原生
    // 均衡器 + 响度增益（Android）；变速变调走 just_audio 的
    // setSpeed/setPitch（跨平台）；独占输出由 EffectsNotifier 自行下发
    // Rust DSP。此前均衡器误监听 AppSettings 的旧字段（音效页从不写它），
    // 导致普通输出下全部音效无效果。
    _ref.listen<AsyncValue<EffectsSettings>>(effectsProvider, (previous, next) {
      final fx = next.valueOrNull;
      if (fx == null) return;
      final last = previous?.valueOrNull;
      // last 为 null（首次加载）时视为全量变化。
      var eqChanged = last == null ||
          fx.equalizerEnabled != last.equalizerEnabled ||
          fx.preamp != last.preamp ||
          fx.audioBoost != last.audioBoost;
      if (!eqChanged) {
        final a = fx.gains, b = last.gains;
        eqChanged = a.length != b.length;
        for (var i = 0; !eqChanged && i < a.length && i < b.length; i++) {
          eqChanged = (a[i] - b[i]).abs() > 0.01;
        }
      }
      if (eqChanged) {
        unawaited(_applyEffectsEqualizer(fx));
      }
      final speedChanged = last == null ||
          fx.playbackRate != last.playbackRate ||
          fx.pitchShift != last.pitchShift ||
          fx.preservesPitch != last.preservesPitch;
      if (speedChanged) {
        unawaited(_applyEffectsSpeedPitch());
      }
    });
    // 收藏在播放页/歌曲列表/通知栏任何一处切换时，刷新通知栏收藏
    // 按钮的实心/空心图标（通知栏按钮见 _MediaSessionBridge）。
    _ref.listen<Set<String>>(favoritesProvider, (previous, next) {
      if (!setEquals(previous, next)) _refreshNotificationCustomControls();
    });
    _init();
    _installCarMediaButtonChannel();
    _installVolumeKeyChannel();
    // just_audio_background 的内部 handler 要等首个 AudioPlayer 完成平台
    // 初始化才会挂到 SwitchAudioHandler 上，延迟安装 + 播放时兜底重试。
    // 用可取消的 Timer 而非 Future.delayed：dispose 时取消，避免测试
    // 环境结束时残留 pending timer。
    _bridgeInstallTimer = Timer(const Duration(seconds: 1), () {
      _installMediaSessionBridge();
    });
  }

  _MediaSessionBridge? _mediaSessionBridge;

  /// 延迟安装媒体会话桥接的一次性定时器（构造时启动，dispose 取消）。
  Timer? _bridgeInstallTimer;

  /// 安装媒体会话桥接（见 [_MediaSessionBridge]），让通知栏/锁屏/灵动岛
  /// 显示上一首/下一首按钮，并把蓝牙耳机的切歌按键转发到本播放器。
  /// 幂等：初始化未完成时静默返回，每次点播时兜底重试（播放器重建可能
  /// 把 inner 换回裸 handler，需要重新安装）。
  void _installMediaSessionBridge() {
    if (kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      // 本地补丁包暴露的内部 SwitchAudioHandler（upstream 0.0.1-beta.17
      // 将其藏在私有变量中，宿主无法干预媒体会话）。
      final handler = xySwitchAudioHandler;
      final current = handler.inner;
      if (identical(current, _mediaSessionBridge)) {
        return;
      }
      // 只有 just_audio_background 的内部 handler 就位后才安装，避免把
      // 桥接套在初始空 handler 上，随后又被平台初始化覆盖。
      if (current.runtimeType.toString() != '_PlayerAudioHandler') return;
      _mediaSessionBridge?.detach();
      final bridge = _MediaSessionBridge(current)
        ..onSkipToNext = next
        ..onSkipToPrevious = previous
        ..queueSource = () {
          return state.queue;
        }
        ..queueIndexResolver = () {
          return state.queueIndex >= 0 ? state.queueIndex : null;
        }
        ..onSkipToQueueItem = playIndex
        ..favoriteStateResolver = () {
          final path = state.current?.path;
          return path != null && _ref.read(favoritesProvider).contains(path);
        }
        ..playModeResolver = () {
          return normalizePlayMode(state.playMode);
        }
        ..onToggleFavorite = _toggleFavoriteFromNotification
        ..onCyclePlayMode = _cyclePlayModeFromNotification;
      bridge.attach();
      handler.inner = bridge;
      _mediaSessionBridge = bridge;
    } catch (_) {
      // 媒体服务初始化失败时保持未安装，播放时重试。
    }
  }

  /// 通知栏「收藏」按钮：切换当前曲目的收藏状态，并刷新通知图标。
  Future<void> _toggleFavoriteFromNotification() async {
    final item = state.current;
    if (item == null) return;
    await _ref
        .read(favoritesProvider.notifier)
        .toggle(item.path, song: FavoriteSongSnapshot.fromQueueItem(item));
  }

  /// 通知栏「播放模式」按钮：循环切换播放模式（列表循环→单曲循环→
  /// 随机），通知栏按钮图标随新模式刷新。
  Future<void> _cyclePlayModeFromNotification() => cyclePlayMode();

  /// 收藏状态与播放模式变化时刷新通知栏自定义按钮的图标。稳定播放中
  /// inner handler 不会再广播状态，收藏从播放页/列表切换后必须显式触发
  /// 重发布，否则通知栏心形图标会滞后。
  void _refreshNotificationCustomControls() {
    _mediaSessionBridge?.notifyCustomControlsChanged();
  }

  /// 上一次车机/方向盘按键的触发时间（节流用）。
  DateTime? _lastCarMediaButtonAt;

  /// 车机/方向盘媒体按键兜底通道（见 MainActivity.dispatchKeyEvent）：
  /// 部分车机 ROM 不把媒体键交给 MediaSession，而是直接注入前台
  /// Activity。原生层拦截后经此通道转发到 Flutter，路由到播放控制。
  /// 标准 Android 上活跃媒体会话优先消费这些按键（走上面的桥接），
  /// 不会走到这里，因此不会重复触发。
  void _installCarMediaButtonChannel() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    const channel = MethodChannel('com.xymusic.mobile/media_buttons');
    channel.setMethodCallHandler((call) async {
      if (call.method != 'onMediaButton') return;
      final action = call.arguments as String?;
      if (action == null) return;
      final now = DateTime.now();
      final last = _lastCarMediaButtonAt;
      // 200ms 节流：避免按键在 Activity 与媒体会话两条链路上重复触发，
      // 或车机按键连发导致连续切歌。
      if (last != null &&
          now.difference(last) < const Duration(milliseconds: 200)) {
        return;
      }
      _lastCarMediaButtonAt = now;
      switch (action) {
        case 'next':
          await next();
          break;
        case 'previous':
          await previous();
          break;
        case 'playPause':
          await toggle();
          break;
        case 'play':
          if (!state.isPlaying) await toggle();
          break;
        case 'pause':
        case 'stop':
          if (state.isPlaying) await toggle();
          break;
        case 'fastForward':
          await seek(state.position + 10);
          break;
        case 'rewind':
          await seek(max(0, state.position - 10));
          break;
      }
    });
  }

  /// 上一次音量键事件的触发时间（长按连发节流用）。
  DateTime? _lastVolumeKeyAt;

  /// 音量键应用内音量通道（见 MainActivity.dispatchKeyEvent）：设置
  /// “音量键调节应用内音量”开启时，原生层把前台的音量键转发到这里，
  /// 只调本应用播放音量（0–1），不动系统媒体音量。长按音量键会连发
  /// ACTION_DOWN，节流避免音量跳变过快。
  void _installVolumeKeyChannel() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    const channel = MethodChannel('com.xymusic.mobile/volume_keys');
    channel.setMethodCallHandler((call) async {
      if (call.method != 'onVolumeKey') return;
      final direction = call.arguments as String?;
      if (direction != 'up' && direction != 'down') return;
      final now = DateTime.now();
      final last = _lastVolumeKeyAt;
      if (last != null &&
          now.difference(last) < const Duration(milliseconds: 120)) {
        return;
      }
      _lastVolumeKeyAt = now;
      final current = _ref.read(volumeProvider);
      final target =
          (direction == 'up' ? current + .05 : current - .05).clamp(0.0, 1.0);
      if ((target - current).abs() < .001) return;
      await setAppVolume(target);
      // 供应用根节点显示“应用音量 xx%”的 OSD 反馈。
      _ref.read(volumeKeyOscProvider.notifier).state = target;
    });
  }

  /// 设置应用内音量（音量键通道使用）：写设置并立即应用到播放器。
  /// MV 视频桥接期间播放器音量为 0（画面自带伴音），此时只保存设置，
  /// 桥接结束恢复音量时会应用新值。
  Future<void> setAppVolume(double v) async {
    final clamped = v.clamp(0.0, 1.0);
    await _ref.read(settingsProvider.notifier).setVolume(clamped);
    if (!_videoMediaBridgeActive) {
      await _player.setVolume(clamped);
    }
  }

  final Ref _ref;

  /// 把音效页的均衡器/前级/音量增强应用到播放引擎。
  ///
  /// 普通输出（扬声器/蓝牙）走系统原生音效：10 段均衡器增益按对数频率
  /// 轴插值映射到设备实际频段（常见 5 段），前级（preamp）与音量增强
  /// （audioBoost）合并为整体 dB 增益走原生响度增益器。均衡器未随
  /// audio session 创建（首次 load 前）时门面自动缓存，load 后重放。
  Future<void> _applyEffectsEqualizer(EffectsSettings fx) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await xyAndroidEqualizer.applyMapped(
        enabled: fx.equalizerEnabled,
        gains: fx.gains,
        centerFrequencies: eqCenterFrequencies,
      );
      final boost = fx.preamp + fx.audioBoost;
      // 前级随均衡器开关，音量增强独立有效（不要求均衡器开启）。
      final loudness = fx.equalizerEnabled
          ? boost
          : fx.audioBoost;
      await xyLoudnessEnhancer.apply(
        enabled: loudness.abs() > 0.01,
        targetGain: loudness,
      );
    } catch (error) {
      debugPrint('音效均衡器应用失败：$error');
    }
  }

  /// 音效页变速变调与播放页倍速的合成速度：播放页倍速为档位式
  /// （0.5/0.8/1.0/1.5/2.0），音效页变速为连续百分比，两者相乘。
  double _combinedEffectsSpeed() {
    final fx = _ref.read(effectsProvider).valueOrNull;
    final rate = fx?.playbackRate ?? 100;
    return (state.playbackSpeed * rate / 100).clamp(0.25, 4.0);
  }

  /// 合成变调：音效页变调百分比；「保持音调」关闭时变速会连带变调
  /// （与 ExoPlayer 的 PlaybackParameters 语义一致）。
  double _combinedEffectsPitch() {
    final fx = _ref.read(effectsProvider).valueOrNull;
    var pitch = (fx?.pitchShift ?? 100) / 100;
    if (fx?.preservesPitch == false) {
      pitch *= _combinedEffectsSpeed();
    }
    return pitch.clamp(0.5, 2.0);
  }

  /// 应用合成速度/变调到音频播放器（视频走自身倍速状态，不叠加变调）。
  Future<void> _applyEffectsSpeedPitch() async {
    try {
      await _player.setSpeed(_combinedEffectsSpeed());
      await _player.setPitch(_combinedEffectsPitch());
    } catch (error) {
      // 部分平台（如 Windows）不支持 setPitch：速度仍生效，变调忽略。
      debugPrint('音效变速变调应用失败：$error');
    }
  }

  // 音频中断由本类按设置处理：开启“不中断”时忽略其他应用的音频焦点
  // 中断，避免 just_audio 默认行为直接暂停当前歌曲。
  // 均衡器音效经 xyAndroidEqualizer 门面驱动真实平台播放器上的原生
  // 均衡器（fork 注入）；不能挂入本播放器管线：经 just_audio_background
  // 代理的激活发生在首次 load 前，Java 侧均衡器尚未随 audio session
  // 创建，空指针会中断 setPlatform 使播放卡死。
  late final AudioPlayer _player = AudioPlayer(handleInterruptions: false);
  final Random _rand = Random();
  StreamSubscription<Duration?>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<dynamic>? _stateSub;
  StreamSubscription<AudioInterruptionEvent>? _audioInterruptionSub;
  StreamSubscription<void>? _becomingNoisySub;
  Timer? _sleepTimer;
  Timer? _sleepTimerTicker;
  Timer? _statsFlushTimer;
  Timer? _desktopLyricsSyncTimer;
  bool _manualPause = false;
  bool _wasInterrupted = false;
  bool _handlingTrackEnd = false;
  bool _notificationPermissionChecked = false;
  int _playRequestId = 0;
  // 标识当前 just_audio 音频源属于哪一次切歌请求。切歌时网络音源解析和
  // 系统媒体权限请求都可能异步完成，过期请求不能再调用 play()，否则会
  // 出现界面已经显示新歌但实际仍播放旧歌（或下一首）的错位。
  int? _preparedSourceRequestId;
  // just_audio 的 setUrl/setFilePath 必须按顺序执行，避免两个并发切歌请求
  // 在原生层交错完成，最后把旧音源覆盖到新歌曲上。
  Future<void> _sourceOperation = Future<void>.value();
  String? _lastFailureKey;
  // 连续播放失败计数：起播成功（音源就绪）时清零。换源重试风暴会
  // 把后端限流窗口越撞越长，连续失败达到阈值后停止自动切下一首，
  // 停止扩散并明确报错（见 _handlePlaybackFailure）。
  int _consecutivePlaybackFailures = 0;
  static const int _maxConsecutivePlaybackFailures = 3;
  // 播放失败策略计数（按当前失败歌曲归组，切歌后自动重置）：
  // 优先重试当前歌的次数、自动换源次数与已尝试过的音源（防止在
  // 两个坏源之间来回切换形成死循环）。起播成功时整体清零。
  String _failureStrategyPath = '';
  int _playbackRetryAttempts = 0;
  int _playbackSwitchAttempts = 0;
  final Set<String> _switchAttemptedPluginIds = {};
  // “降低音质”步骤已尝试过的档位（防止同一档反复重解析死循环）。
  final Set<String> _qualityDropAttemptedTiers = {};
  int _relinkProposalId = 0;
  int _noticeId = 0;
  DateTime _lastPosPersist = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastVideoPath;
  bool _videoMediaBridgeActive = false;
  bool _syncingVideoMediaBridge = false;

  /// MV 播放前歌曲自身的进度/时长（见 [enableVideoMediaBridge]）。
  /// 桥接期间静音音频被 seek 到视频时间线，关闭视频时用这里记录的值
  /// 把歌曲进度恢复到开启 MV 之前，MV 的播放进度不污染歌曲进度。
  Duration? _songPositionBeforeVideo;
  String? _songPositionBeforeVideoPath;
  int? _songDurationBeforeVideoMs;
  bool _desktopLyricsSyncInFlight = false;
  bool _desktopLyricsSyncPending = false;
  bool _desktopLyricsHiddenSent = false;
  DateTime _lastDesktopLyricsSync = DateTime.fromMillisecondsSinceEpoch(0);
  bool? _expectedAudioPlayingFromVideo;
  DateTime _lastVideoMediaSeek = DateTime.fromMillisecondsSinceEpoch(0);
  // 脏回跳过滤的解卡状态：连续被过滤事件的上一值与计数。
  int _staleStreakPrevMs = -1;
  int _staleStreakCount = 0;
  // 听歌统计按会话增量刷写，避免定时刷写把累计 position 重复计算。
  String? _statsSessionPath;
  int _statsRecordedPositionMs = 0;
  bool _statsPlayEventRecorded = false;
  Future<void> _statsWriteChain = Future<void>.value();
  // 统计墙钟（单调时钟，不受系统时间跳变影响）：估算“自上次刷写以来
  // 最多可能真实听了多久”。脏回跳/错误时长元数据（如在线源返回数小时
  // 的 durationMs）会让单次结算产生数小时的 listenedMs，用墙钟上限
  // 把每次结算钳制在物理可能的范围内。
  final Stopwatch _statsWallClock = Stopwatch()..start();
  int _statsLastFlushElapsedMs = 0;

  Future<void> _init() async {
    final allowOtherAudio =
        _ref
            .read(settingsProvider)
            .valueOrNull
            ?.playOtherAudioWithoutInterruption ??
        false;
    await _configureAudioSession(allowOtherAudio);
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      final session = await AudioSession.instance;
      _audioInterruptionSub = session.interruptionEventStream.listen(
        _handleAudioInterruption,
      );
      _becomingNoisySub = session.becomingNoisyEventStream.listen((_) {
        _manualPause = true;
        _flushCurrentPlaybackStats();
        unawaited(_player.pause());
      });
    }
    _attachPlayerStreams();
    await _restoreSession();
  }

  /// position 采样周期随前后台自适应：
  /// - 前台逐字歌词需要比默认 200ms 更细的进度采样，但 40ms 会让全局播放
  ///   状态在手机上以 25fps 重建，首页、底栏和歌词页会同时承受不必要的
  ///   开销；80~120ms 足够逐词/渐进效果使用，也能明显降低主 isolate 负担。
  /// - 退到后台后界面不再刷新，高频广播只会持续唤醒渲染引擎（后台 CPU
  ///   高占用的主因）。降频到 1s 已足够进度持久化/睡眠定时器使用。
  /// - 桌面歌词开启时仍需较平滑的进度驱动原生歌词窗，折中 250ms。
  ({Duration min, Duration max}) _positionStreamPeriods() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final inForeground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (inForeground) {
      return (
        min: const Duration(milliseconds: 80),
        max: const Duration(milliseconds: 120),
      );
    }
    final desktopLyrics =
        _ref.read(settingsProvider).valueOrNull?.desktopLyricsEnabled == true;
    if (desktopLyrics) {
      return (
        min: const Duration(milliseconds: 250),
        max: const Duration(milliseconds: 300),
      );
    }
    return (
      min: const Duration(seconds: 1),
      max: const Duration(milliseconds: 1100),
    );
  }

  /// 单独挂接 position 流：前后台切换时仅重挂这一条订阅（见
  /// [_handleAppLifecycleChanged]），duration/playerState 订阅不受影响。
  void _attachPositionStream() {
    final periods = _positionStreamPeriods();
    _posSub = _player
        .createPositionStream(
          steps: 3600,
          minPeriod: periods.min,
          maxPeriod: periods.max,
        )
        .listen((p) {
          // B 站视频播放时，just_audio 只是供系统媒体会话使用的静音时钟。
          // 它与视频解码时钟存在微小偏差，不能再反向更新歌词位置，否则在
          // 句子边界会在上一句和下一句之间反复横跳。
          if (_videoMediaBridgeActive &&
              VideoPlaybackSession.isFor(state.current?.path)) {
            return;
          }
          final positionMs = p.inMilliseconds;
          // 大幅回跳过滤（纯过滤，不做 seek 修复——旧方案的修复 seek 会
          // 重写原生基准引发新问题，已移除）：
          // - 单曲循环的自然回绕（上次可信进度已逼近末尾、新进度回到
          //   开头）必须放行，否则歌曲会在开头几秒无限循环；
          // - 其余远离当前进度的回跳（熄屏/系统控件暂停恢复时原生可能
          //   上报滞后或被重置为 0 的基准事件）视为脏数据：忽略并记
          //   日志，等待原生以正确基准重新上报。参考的 XianYu 架构下
          //   原生基准不会被播放器重建/媒体会话交接污染，故无需此层；
          //   本应用存在重建与桥接路径，需要这层最小防护。
          // 以 state.position（本回调是播放期唯一写者）为参照基准。
          final lastMs = (state.position * 1000).round();
          final durationMs = state.duration * 1000;
          final isNaturalWrap = state.isPlaying &&
              positionMs < 5000 &&
              durationMs > 10000 &&
              lastMs >= durationMs - 5000;
          if (positionMs + 3000 < lastMs && !isNaturalWrap) {
            // 解卡判定（beta15 实测：恢复播放后先有一条滞后的前进事件
            // 污染基准，随后真实进度流全部被当作回跳过滤，界面卡死）：
            // 被滤事件若持续严格递增，说明原生确实在从更低基准实时前进，
            // 连续 8 次（约 0.7s）后重新接受并重同步基准；杂乱脏数据
            // （如 0 风暴）不满足递增，继续过滤。
            if (_staleStreakPrevMs >= 0 && positionMs > _staleStreakPrevMs) {
              _staleStreakCount++;
            } else {
              _staleStreakPrevMs = positionMs;
              _staleStreakCount = 1;
            }
            if (_staleStreakCount >= 8) {
              debugPrint(
                '[播放链路] 连续递增的被滤事件判定为真实进度流，'
                '重同步基准 ${lastMs}ms → ${positionMs}ms',
              );
              _staleStreakPrevMs = -1;
              _staleStreakCount = 0;
            } else {
              debugPrint(
                '[播放链路] 忽略脏回跳进度事件 ${positionMs}ms'
                '（最近可信 ${lastMs}ms，播放态 ${state.isPlaying}）',
              );
              return;
            }
          } else {
            _staleStreakPrevMs = -1;
            _staleStreakCount = 0;
          }
          state = state.copyWith(position: positionMs / 1000.0);
          _persistPositionDebounced();
          _requestDesktopLyricsSync();
        });
  }

  /// 挂接 just_audio 的 position / duration / playerState 订阅。
  /// 重建 AudioPlayer 实例（起播卡死自愈）后必须重新挂接。
  void _attachPlayerStreams() {
    _attachPositionStream();
    _durSub = _player.durationStream.listen((d) {
      if (_videoMediaBridgeActive &&
          VideoPlaybackSession.isFor(state.current?.path)) {
        return;
      }
      final dur = (d ?? Duration.zero).inMilliseconds / 1000.0;
      // 参考 XianYu-Music-Mobile：恢复/重挂期间原生可能上报 null 或 0
      // 时长。已经拿到正时长时忽略 0，防止进度条 max 被冲掉、
      // position 被按 max=1.0 错误钳制。
      if (dur <= 0 && state.duration > 0) return;
      state = state.copyWith(duration: dur);
    });
    _stateSub = _player.playerStateStream.listen((ps) {
      final playing = ps.playing;
      final completed = ps.processingState == ProcessingState.completed;
      if (completed ||
          playing != state.isPlaying ||
          (playing && state.isLoading)) {
        if (playing) {
          // 恢复播放时重新起算统计墙钟窗口：暂停期间不产生新的收听
          // 时长，若不重置，长时间暂停后的首次结算上限会包含暂停
          // 时长，脏回跳产生的错误尾部就能穿透钳制。
          _statsLastFlushElapsedMs = _statsWallClock.elapsedMilliseconds;
        }
        state = state.copyWith(
          isPlaying: completed ? false : playing,
          // just_audio 的 play() 要等暂停或播放结束才完成。播放器已经进入
          // playing 时必须立刻结束加载态，否则详情页按钮会一直转圈。
          isLoading: playing ? false : state.isLoading,
        );
      }
      // just_audio 播放到末尾时可能仍保持 playing=true，必须明确监听
      // ProcessingState.completed，不能只等待 playing 变为 false。
      if (_videoMediaBridgeActive) {
        if (completed) {
          unawaited(_recoverVideoMediaBridge());
        } else if (_expectedAudioPlayingFromVideo == playing) {
          // 这是视频状态同步产生的音频事件，不要再反向操作视频。
          _expectedAudioPlayingFromVideo = null;
        } else if (!playing && _expectedAudioPlayingFromVideo == true) {
          // 桥接起播序列：音频尚未真正播放前，seek/buffering 会发出
          // playing=false 事件。它不是系统媒体的暂停命令，若在此反向
          // 暂停视频，MV 会在起播瞬间被误暂停。忽略并等待起播事件。
        } else {
          // 通知栏、锁屏或灵动岛直接控制的是 just_audio。视频播放期间
          // 将该操作反向转发给视频控制器，系统按钮才能真正生效。
          unawaited(_applySystemMediaControlToVideo(playing));
        }
      }
      if (completed && !_manualPause && !_videoMediaBridgeActive) {
        unawaited(_handleTrackEndOnce());
      }
      _requestDesktopLyricsSync(immediate: true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 后台播放仍会继续计时，但在进入后台/非激活状态时先保存一次，
    // 避免系统回收进程后丢失最后一段播放时长。
    if (state != AppLifecycleState.resumed) {
      _flushCurrentPlaybackStats();
    }
    // 前后台切换时重挂 position 流，按当前生命周期选择采样周期
    // （后台降频，降低后台 CPU 占用）；尚未挂接时忽略。
    if (_posSub != null) {
      _posSub?.cancel();
      _posSub = null;
      _attachPositionStream();
    }
    _guardVideoSessionOnLifecycle(state);
  }

  /// 后台久置挂起视频（应用级守护）。挂在 PlayerNotifier 而非播放
  /// 详情页上：详情页退出后视频会话仍存活，页面级监听随 dispose 失效，
  /// 覆盖不了“离开详情页后切后台久置”的场景。ExoPlayer 的 MediaCodec
  /// 表面在后台久置后会被系统回收，恢复渲染时抛 MediaCodecVideoRenderer
  /// error。不再直接关闭视频退回音频播放页，而是保留 MV 会话进入
  /// 错误态：用户回到软件仍停在 MV 界面，可重新加载或手动切换画质。
  DateTime? _videoBackgroundedAt;
  static const _videoBackgroundCloseThreshold = Duration(seconds: 90);

  void _guardVideoSessionOnLifecycle(AppLifecycleState state) {
    final hasVideo = VideoPlaybackSession.controller != null ||
        VideoPlaybackSession.songPath != null;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        if (hasVideo) _videoBackgroundedAt = DateTime.now();
      case AppLifecycleState.resumed:
        final backgroundedAt = _videoBackgroundedAt;
        _videoBackgroundedAt = null;
        if (backgroundedAt == null || !hasVideo) break;
        if (DateTime.now().difference(backgroundedAt) <
            _videoBackgroundCloseThreshold) {
          break;
        }
        unawaited(_suspendVideoAfterBackgroundIdle());
      default:
        break;
    }
  }

  Future<void> _suspendVideoAfterBackgroundIdle() async {
    final suspended = await VideoPlaybackSession.suspendForBackgroundIdle();
    if (!suspended) return;
    // 视频控制器已释放，静音桥接不再有意义：暂停音频并恢复用户音量、
    // 歌曲进度，但保持歌曲暂停——重新加载成功后会重新接入桥接。
    await disableVideoMediaBridge();
  }

  Future<void> _syncDesktopLyrics() async {
    final settings = _ref.read(settingsProvider).valueOrNull;
    final item = state.current;
    final isAppForeground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (settings == null ||
        !settings.desktopLyricsEnabled ||
        item == null ||
        (settings.desktopLyricsHideInApp && isAppForeground)) {
      await DesktopLyricsBridge.sync(
        enabled: false,
        title: '',
        artist: '',
        lyrics: '',
        position: 0,
        isPlaying: false,
        noBackground: true,
        lyricColor: 0xFFFFFFFF,
        translationColor: 0xFFE1E1E6,
        lyricFontSize: 24,
        translationFontSize: 13,
        backgroundColor: 0xFF18181C,
        backgroundOpacity: .85,
        wordEffectMode: LyricWordEffectMode.none.index,
        locked: false,
      );
      return;
    }
    await DesktopLyricsBridge.sync(
      enabled: true,
      title: item.title,
      artist: item.artist,
      lyrics: item.lyricsRaw ?? '',
      position: state.position,
      isPlaying: state.isPlaying,
      noBackground: settings.desktopLyricsNoBackground,
      lyricColor: settings.desktopLyricsLyricColor,
      translationColor: settings.desktopLyricsTranslationColor,
      lyricFontSize: settings.desktopLyricsLyricFontSize,
      translationFontSize: settings.desktopLyricsTranslationFontSize,
      backgroundColor: settings.desktopLyricsBackgroundColor,
      backgroundOpacity: settings.desktopLyricsBackgroundOpacity,
      wordEffectMode: settings.desktopLyricsShowWordEffect
          ? settings.lyricWordEffectMode.index
          : LyricWordEffectMode.none.index,
      locked: settings.desktopLyricsLocked,
    );
  }

  /// B站视频播放时 just_audio 处于暂停状态，普通进度流不会再更新。
  /// 将视频控制器的状态镜像到播放状态，桌面歌词即可继续按视频进度刷新。
  void _syncVideoPlaybackState() {
    final controller = VideoPlaybackSession.controller;
    final path = VideoPlaybackSession.songPath;
    if (controller == null || path == null || path.isEmpty) {
      if (_videoMediaBridgeActive) {
        unawaited(disableVideoMediaBridge());
      }
      if (_lastVideoPath != null && state.current?.path == _lastVideoPath) {
        _lastVideoPath = null;
        state = state.copyWith(isPlaying: false, isLoading: false);
        _requestDesktopLyricsSync(immediate: true);
      }
      return;
    }
    if (state.current?.path != path) return;
    _lastVideoPath = path;
    final value = controller.value;
    if (value.isCompleted && normalizePlayMode(state.playMode) == 1) {
      // 视频不是 just_audio 的音频源，不能依赖 AudioPlayer 的 LoopMode.one。
      // 单曲循环时直接重播共享的视频控制器，避免结束后退回音频播放。
      unawaited(VideoPlaybackSession.restartSingleLoop());
    }
    final duration = value.duration.inMilliseconds > 0
        ? value.duration.inMilliseconds / 1000.0
        : state.duration;
    state = state.copyWith(
      position: value.position.inMilliseconds / 1000.0,
      duration: duration,
      isPlaying: value.isPlaying,
      isLoading: false,
    );
    _persistPositionDebounced();
    if (_videoMediaBridgeActive) {
      unawaited(_mirrorVideoStateToSystemMedia());
    }
    _requestDesktopLyricsSync();
  }

  /// 桌面歌词是附加能力，不能随着每次播放进度更新都跨 MethodChannel。
  /// 关闭桌面歌词时只发送一次隐藏消息；开启时最多每 100ms 同步一次，
  /// 并且不会让旧的异步同步任务和新的任务同时堆积。
  void _requestDesktopLyricsSync({bool immediate = false}) {
    final settings = _ref.read(settingsProvider).valueOrNull;
    final shouldShow =
        settings?.desktopLyricsEnabled == true &&
        !(settings?.desktopLyricsHideInApp == true &&
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed);
    if (!shouldShow) {
      _desktopLyricsSyncPending = false;
      _desktopLyricsSyncTimer?.cancel();
      _desktopLyricsSyncTimer = null;
      if (!_desktopLyricsHiddenSent) {
        _desktopLyricsHiddenSent = true;
        if (!_desktopLyricsSyncInFlight) {
          _desktopLyricsSyncInFlight = true;
          unawaited(
            _syncDesktopLyrics().whenComplete(
              () => _desktopLyricsSyncInFlight = false,
            ),
          );
        }
      }
      return;
    }

    _desktopLyricsHiddenSent = false;
    _desktopLyricsSyncPending = true;
    if (immediate) {
      _desktopLyricsSyncTimer?.cancel();
      _desktopLyricsSyncTimer = null;
      if (!_desktopLyricsSyncInFlight) _startDesktopLyricsSync();
      return;
    }
    if (_desktopLyricsSyncInFlight || _desktopLyricsSyncTimer != null) return;
    final elapsed = DateTime.now().difference(_lastDesktopLyricsSync);
    final delay = elapsed >= const Duration(milliseconds: 100)
        ? Duration.zero
        : const Duration(milliseconds: 100) - elapsed;
    _desktopLyricsSyncTimer = Timer(delay, () {
      _desktopLyricsSyncTimer = null;
      if (!_desktopLyricsSyncInFlight) _startDesktopLyricsSync();
    });
  }

  void _startDesktopLyricsSync() {
    if (_desktopLyricsSyncInFlight || !_desktopLyricsSyncPending) return;
    _desktopLyricsSyncPending = false;
    _desktopLyricsSyncInFlight = true;
    _lastDesktopLyricsSync = DateTime.now();
    unawaited(
      _syncDesktopLyrics().whenComplete(() {
        _desktopLyricsSyncInFlight = false;
        if (_desktopLyricsSyncPending) _requestDesktopLyricsSync();
      }),
    );
  }

  /// 用已经加载的音频源作为 Android 系统媒体会话的“静音时钟”。
  ///
  /// video_player 自己没有接入 audio_service，直接暂停音频后系统媒体卡片
  /// 会停在旧进度，系统播放按钮也只能控制音频。视频播放期间让音频静音并
  /// 与视频保持同一进度，即可复用稳定的系统媒体会话，同时避免双重声音。
  Future<void> enableVideoMediaBridge() async {
    final controller = VideoPlaybackSession.controller;
    final path = VideoPlaybackSession.songPath;
    if (controller == null || path == null || state.current?.path != path) {
      return;
    }
    _videoMediaBridgeActive = true;
    _lastVideoMediaSeek = DateTime.fromMillisecondsSinceEpoch(0);
    // 歌曲进度与 MV 进度分离：桥接会把静音音频 seek 到视频时间线驱动
    // 系统媒体会话，这里先记下歌曲自身的进度/时长（此时音频仍是
    // pauseForVideo 暂停时的位置），关闭视频时恢复，MV 的播放进度
    // 不会影响歌曲播放进度。
    _songPositionBeforeVideo = _player.position;
    _songPositionBeforeVideoPath = path;
    _songDurationBeforeVideoMs = _player.duration?.inMilliseconds;
    // 必须在进入 await 前登记预期播放态：setVolume/seek 期间视频进度
    // 监听会触发镜像同步并提前起播音频，若此刻才写标记，起播序列中
    // 的 seek 事件（playing=false）会与标记不匹配而被当作暂停命令。
    final videoPlaying = controller.value.isPlaying;
    if (videoPlaying) {
      _manualPause = false;
      _expectedAudioPlayingFromVideo = true;
    }
    await _player.setVolume(0);
    await _player.seek(controller.value.position);
    if (videoPlaying) {
      unawaited(_startPlayback(_playRequestId, path));
    } else {
      _manualPause = true;
      _expectedAudioPlayingFromVideo = false;
      await _player.pause();
    }
  }

  /// 结束视频媒体桥接并恢复用户音量。关闭视频、切歌和视频初始化失败均可
  /// 重复调用，因此这里保持幂等。
  Future<void> disableVideoMediaBridge() async {
    final wasActive = _videoMediaBridgeActive;
    _videoMediaBridgeActive = false;
    _syncingVideoMediaBridge = false;
    _expectedAudioPlayingFromVideo = null;
    if (wasActive && _player.playing) {
      _manualPause = true;
      await _player.pause();
    }
    await _player.setVolume(_ref.read(volumeProvider));
    await _restoreSongProgressAfterVideo();
  }

  /// 关闭 MV/视频后把歌曲进度恢复到开启前（见 [enableVideoMediaBridge]）。
  /// MV 关闭即终止播放：视频进度条不再残留，播放页回到歌曲自身进度。
  /// 切歌等场景下当前歌曲已变化时跳过恢复（新歌曲自行加载），仅清空记录。
  Future<void> _restoreSongProgressAfterVideo() async {
    final savedPath = _songPositionBeforeVideoPath;
    final savedPosition = _songPositionBeforeVideo;
    final savedDurationMs = _songDurationBeforeVideoMs;
    _songPositionBeforeVideoPath = null;
    _songPositionBeforeVideo = null;
    _songDurationBeforeVideoMs = null;
    if (savedPath == null || savedPosition == null) return;
    if (state.current?.path != savedPath) return;
    try {
      await _player.seek(savedPosition);
      // seek 期间可能已经切歌（异步关闭视频的路径），恢复前再校验一次，
      // 避免旧歌曲的进度覆盖新歌曲的状态。
      if (state.current?.path != savedPath) return;
      var restored = state.copyWith(
        position: savedPosition.inMilliseconds / 1000.0,
      );
      if (savedDurationMs != null && savedDurationMs > 0) {
        restored = restored.copyWith(duration: savedDurationMs / 1000.0);
      }
      state = restored;
      if (_statsSessionPath == state.current?.path) {
        _statsRecordedPositionMs = savedPosition.inMilliseconds;
      }
      _persistPositionDebounced();
      _requestDesktopLyricsSync(immediate: true);
    } catch (error) {
      debugPrint('关闭视频后恢复歌曲进度失败：$error');
    }
  }

  Future<void> _mirrorVideoStateToSystemMedia() async {
    if (!_videoMediaBridgeActive || _syncingVideoMediaBridge) return;
    final controller = VideoPlaybackSession.controller;
    final path = VideoPlaybackSession.songPath;
    if (controller == null || path == null || state.current?.path != path) {
      return;
    }
    _syncingVideoMediaBridge = true;
    try {
      final value = controller.value;
      final shouldPlay = value.isPlaying && !value.isCompleted;
      if (shouldPlay != _player.playing) {
        _expectedAudioPlayingFromVideo = shouldPlay;
        _manualPause = !shouldPlay;
        if (shouldPlay) {
          unawaited(_startPlayback(_playRequestId, path));
        } else {
          await _player.pause();
        }
      }

      // 视频和音频来自同一条 B 站内容，但两套解码时钟仍可能产生小幅漂移。
      // 每秒最多校准一次；小于 600ms 不 seek，避免造成系统进度条抖动。
      final now = DateTime.now();
      if (now.difference(_lastVideoMediaSeek) >= const Duration(seconds: 1)) {
        _lastVideoMediaSeek = now;
        final drift = (_player.position - value.position).inMilliseconds.abs();
        if (drift > 600) {
          final audioDurationMs = _player.duration?.inMilliseconds ?? 0;
          // MV 视频与音频是两路不同时长的内容，漂移校准不得把静音音频
          // 拖过其自然末尾：音频一旦提前 completed，关闭视频后 play()
          // 会把整曲从头重播。
          if (audioDurationMs <= 0 ||
              value.position.inMilliseconds < audioDurationMs - 250) {
            await _player.seek(value.position);
          }
        }
      }
    } finally {
      _syncingVideoMediaBridge = false;
    }
  }

  Future<void> _applySystemMediaControlToVideo(bool shouldPlay) async {
    if (!_videoMediaBridgeActive) return;
    final controller = VideoPlaybackSession.controller;
    if (controller == null ||
        VideoPlaybackSession.songPath != state.current?.path ||
        controller.value.isPlaying == shouldPlay) {
      return;
    }
    try {
      if (shouldPlay) {
        await controller.play();
      } else {
        await controller.pause();
      }
      VideoPlaybackSession.progressChanged();
    } catch (error) {
      debugPrint('系统媒体按钮控制 B 站视频失败：$error');
    }
  }

  Future<void> _recoverVideoMediaBridge() async {
    if (!_videoMediaBridgeActive) return;
    final controller = VideoPlaybackSession.controller;
    final path = VideoPlaybackSession.songPath;
    if (controller == null || path == null || state.current?.path != path) {
      return;
    }
    if (controller.value.isCompleted) return;
    // MV 视频常比音频长。视频进度越过音频末尾后不再 seek+play：
    // just_audio 在 completed 状态下 play() 会把静音音频从头重播，
    // 与每秒一次的进度校准 seek 相互触发，形成无声的重播循环。
    final audioDurationMs = _player.duration?.inMilliseconds ?? 0;
    final videoMs = controller.value.position.inMilliseconds;
    if (audioDurationMs > 0 && videoMs >= audioDurationMs - 250) {
      return;
    }
    try {
      await _player.seek(controller.value.position);
      if (controller.value.isPlaying) {
        _expectedAudioPlayingFromVideo = true;
        unawaited(_startPlayback(_playRequestId, path));
      }
    } catch (error) {
      debugPrint('B 站视频系统媒体进度恢复失败：$error');
    }
  }

  /// 配置系统音频焦点。开启后使用“可降低音量”的焦点类型，并在 iOS
  /// 使用 mixWithOthers，使其他音乐播放时本应用不会被自动暂停。
  Future<void> _configureAudioSession(bool allowOtherAudio) async {
    if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(
        AudioSessionConfiguration.music().copyWith(
          androidAudioFocusGainType: allowOtherAudio
              ? AndroidAudioFocusGainType.gainTransientMayDuck
              : AndroidAudioFocusGainType.gain,
          androidWillPauseWhenDucked: allowOtherAudio ? false : null,
          avAudioSessionCategoryOptions: allowOtherAudio
              ? AVAudioSessionCategoryOptions.mixWithOthers
              : AVAudioSessionCategoryOptions.none,
        ),
      );
    } catch (error) {
      debugPrint('音频焦点配置失败：$error');
    }
  }

  void _handleAudioInterruption(AudioInterruptionEvent event) {
    final allowOtherAudio =
        _ref
            .read(settingsProvider)
            .valueOrNull
            ?.playOtherAudioWithoutInterruption ??
        false;
    if (allowOtherAudio) return;
    final shouldPause =
        event.type == AudioInterruptionType.pause ||
        event.type == AudioInterruptionType.unknown;
    if (event.begin) {
      if (shouldPause && _player.playing) {
        _wasInterrupted = true;
        _flushCurrentPlaybackStats();
        unawaited(_player.pause());
      }
    } else if (shouldPause && _wasInterrupted) {
      _wasInterrupted = false;
      // 与手动恢复播放一致走 _startPlayback：中断期间（通话/熄屏）
      // 原生同样可能上报错误基准，恢复前先按暂停锚点校正。
      final path = state.current?.path;
      if (path != null && _preparedSourceRequestId == _playRequestId) {
        _manualPause = false;
        unawaited(_startPlayback(_playRequestId, path));
      } else {
        unawaited(_player.play());
      }
    }
  }

  /// 启动时从 SQLite 恢复上次播放会话。
  Future<void> _restoreSession() async {
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final jsonStr = await loadPlaybackSession(dbPath: dbPath);
      final j = jsonDecode(jsonStr) as Map<String, dynamic>;
      final paths = (j['playQueuePaths'] as List? ?? const []).cast<String>();
      if (paths.isEmpty) return;
      final queueMeta = j['queueSongMeta'] is Map
          ? Map<String, dynamic>.from(j['queueSongMeta'] as Map)
          : const <String, dynamic>{};
      // 旧会话没有版本号（默认 0）：网络歌词的词级时间转换逻辑已变更，
      // 旧缓存的逐字时间整体错位（表现为只有标题行逐字），必须作废重抓。
      final savedLyricsVersion =
          (j['lyricsFormatVersion'] as num?)?.toInt() ?? 0;
      final keepSessionLyrics = savedLyricsVersion >= _sessionLyricsFormatVersion;
      final items = paths.map((p) {
        final raw = queueMeta[p];
        final meta = raw is Map
            ? Map<String, dynamic>.from(raw)
            : const <String, dynamic>{};
        final pluginData = meta['pluginData'] is Map
            ? Map<String, dynamic>.from(meta['pluginData'] as Map)
            : null;
        final savedCover = meta['coverUrl']?.toString().trim() ?? '';
        final recoveredCover = pluginData == null
            ? ''
            : extractPluginCoverUrl(pluginData);
        final savedLyricsRaw = meta['lyricsRaw']?.toString();
        return QueueItem(
          path: p,
          title: meta['title']?.toString() ?? _titleFromPath(p),
          artist: meta['artist']?.toString() ?? '',
          album: meta['album']?.toString() ?? '',
          durationMs: (meta['durationMs'] as num?)?.toInt() ?? 0,
          pluginId: meta['pluginId']?.toString(),
          pluginData: pluginData,
          // 旧版会话可能已把网易云封面保存为空值，
          // 启动恢复时直接从完整的插件快照重建。
          coverUrl: savedCover.isNotEmpty
              ? savedCover
              : (recoveredCover.isEmpty ? null : recoveredCover),
          lyricsRaw: keepSessionLyrics ? savedLyricsRaw : null,
          // 作废旧歌词时 lyricsAttempted 必须一并复位，否则播放链和
          // ensureCurrentLyricsChecked 都会因“已探测”跳过重新抓取。
          lyricsAttempted: keepSessionLyrics &&
              (meta['lyricsAttempted'] == true || savedLyricsRaw != null),
        );
      }).toList();
      final currentPath = j['currentSongPath'] as String?;
      final startIndex = currentPath == null ? 0 : paths.indexOf(currentPath);
      final idx = startIndex < 0 ? 0 : startIndex;
      final mode = normalizePlayMode((j['playMode'] as num?)?.toInt() ?? 0);
      final pos = (j['currentPositionSecs'] as num?)?.toDouble() ?? 0;
      final restoredQuality =
          j['sessionQualityOverride']?.toString().trim().isNotEmpty == true
          ? j['sessionQualityOverride'].toString().trim()
          : (_ref.read(settingsProvider).valueOrNull?.onlineDefaultQuality ??
                '320k');

      // 快速恢复队列与歌曲信息，不设 isLoading：插件音源解析可能需要
      // 数秒甚至超时，阻塞在 loading 态会让用户以为起播卡死。
      state = state.copyWith(
        queue: items,
        queueIndex: idx,
        current: items[idx],
        playMode: mode,
        position: pos,
        // 进度条 max 立即用队列元数据时长占位：不设的话进入播放页时
        // 恢复的 position 会被按 max=1.0 钳到尾端，起播后才跳回真实
        // 进度（表现为进度条先满格再回跳）。真实时长仍由引擎事件更正。
        duration: items[idx].durationMs / 1000.0,
        isPlaying: false,
        isLoading: false,
        errorMessage: null,
        currentQuality: restoredQuality,
      );
      _beginStatsSession(items[idx], initialPositionMs: (pos * 1000).round());
      await _ref.read(settingsProvider.notifier).setPlayMode(mode);
      // 后台异步预加载音源：成功则用户点播放即可直接起播；失败也不
      // 污染 UI 状态，toggle() 检测到音源未就绪会自动重走切歌链。
      unawaited(() async {
        try {
          await _player.setLoopMode(audioLoopModeForPlayMode(mode));
          final plugin = await _prepareAudioSource(
            items[idx],
            queueIndex: idx,
            preferredQualityOverride: restoredQuality,
          );
          if (idx != state.queueIndex) return; // 期间已切歌，放弃
          _preparedSourceRequestId = _playRequestId;
          await _player.setVolume(_ref.read(volumeProvider));
          await seek(pos);
          // 进程重新启动时只恢复队列、歌曲和进度，不自动恢复“正在播放”。
          // 自动播放会在首页首帧同时启动媒体服务、网络音源和高频 UI 更新，
          // 部分旧设备可能因此被系统终止；用户点击播放后再正常继续。
          _manualPause = true;
          if (plugin != null && !(state.current?.lyricsAttempted ?? false)) {
            unawaited(
              _loadPluginLyrics(idx, plugin, state.current ?? items[idx]),
            );
          }
          unawaited(_persistSession());
        } catch (error, stackTrace) {
          debugPrint('播放会话预加载失败：$error');
          debugPrintStack(stackTrace: stackTrace);
          // 预加载失败不设置 errorMessage / isLoading：
          // 静默等待用户点击播放时由 toggle() 触发重试。
        }
      }());
    } catch (_) {
      // 无有效会话，忽略。
    }
  }

  String _titleFromPath(String p) {
    final name = p.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 防抖持久化进度（每 5 秒一次），供重启恢复。
  void _persistPositionDebounced() {
    if (state.current == null) return;
    final now = DateTime.now();
    if (now.difference(_lastPosPersist).inSeconds < 5) return;
    _lastPosPersist = now;
    Future(() async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        await updatePlaybackPosition(
          dbPath: dbPath,
          positionSecs: state.position,
          isPlaying: state.isPlaying,
        );
      } catch (_) {}
    });
  }

  /// 播放一组歌曲（替换队列）。随机模式下使用一次洗牌，保证一轮内
  /// 每首歌只出现一次，而不是每次切歌都重新抽签。
  ///
  /// [randomizeStart] 用于“播放全部”：随机模式下整组歌曲洗牌后从
  /// 洗牌后的第一首开始。普通点击单曲时保留用户点中的歌曲为第一首，
  /// 再将剩余歌曲洗牌。
  Future<void> playQueue(
    List<QueueItem> items, {
    int startIndex = 0,
    bool randomizeStart = false,
  }) async {
    if (items.isEmpty) return;
    var queue = List<QueueItem>.of(items);
    var effectiveStartIndex = startIndex.clamp(0, queue.length - 1).toInt();
    if (normalizePlayMode(state.playMode) == 2) {
      if (randomizeStart) {
        _shuffleInPlace(queue);
        effectiveStartIndex = 0;
      } else {
        final selected = queue.removeAt(effectiveStartIndex);
        _shuffleInPlace(queue);
        queue.insert(0, selected);
        effectiveStartIndex = 0;
      }
    }
    state = state.copyWith(queue: queue);
    await _playAt(effectiveStartIndex);
  }

  void _shuffleInPlace<T>(List<T> values) {
    for (var i = values.length - 1; i > 0; i--) {
      final j = _rand.nextInt(i + 1);
      if (i == j) continue;
      final item = values[i];
      values[i] = values[j];
      values[j] = item;
    }
  }

  /// 将歌曲插到当前曲目之后，不打断正在播放的歌曲。
  Future<void> playNext(QueueItem item) async {
    final queue = [...state.queue];
    final insertAt = state.queueIndex < 0 ? queue.length : state.queueIndex + 1;
    queue.insert(insertAt.clamp(0, queue.length).toInt(), item);
    state = state.copyWith(queue: queue);
    await _persistSession();
  }

  /// 将歌曲追加到播放队列末尾。
  Future<void> addToQueue(QueueItem item) async {
    final queue = [...state.queue, item];
    state = state.copyWith(queue: queue);
    await _persistSession();
  }

  /// 清空播放队列并停止播放。播放模式、倍速、音质、睡眠定时等
  /// 设置项保留，仅重置队列与播放状态。
  Future<void> clearQueue() async {
    if (state.queue.isEmpty && state.current == null) return;
    // 结束临时视频会话，避免视频伴音残留。
    if (VideoPlaybackSession.controller != null) {
      await VideoPlaybackSession.stopForTrackAction();
      await disableVideoMediaBridge();
    }
    _flushPlaybackStats(state);
    // stop() 会发出 playing=false，先抑制自动下一首。
    _manualPause = true;
    ++_playRequestId;
    _preparedSourceRequestId = null;
    try {
      await _player.stop();
    } catch (_) {}
    state = PlaybackState(
      playMode: state.playMode,
      playbackSpeed: state.playbackSpeed,
      currentQuality: state.currentQuality,
      sleepTimerEndsAt: state.sleepTimerEndsAt,
    );
    await _persistSession();
    unawaited(_syncDesktopLyrics());
  }

  Future<void> _playAt(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    _installMediaSessionBridge();
    // 重新点播歌曲（包括正在以视频形式播放的 B 站歌曲）时，先结束
    // 临时视频会话并退出媒体桥接。否则视频画面自带的伴音会与新启动
    // 的音频流同时播放，出现两路重复的声音。
    if (VideoPlaybackSession.controller != null) {
      await VideoPlaybackSession.stopForTrackAction();
      await disableVideoMediaBridge();
    }
    final requestId = ++_playRequestId;
    _preparedSourceRequestId = null;
    var item = state.queue[index];
    final associated = await _loadAssociatedReplacement(item.path);
    if (requestId != _playRequestId) return;
    if (associated != null) {
      final queue = [...state.queue];
      queue[index] = associated;
      item = associated;
      state = state.copyWith(queue: queue);
    }
    // 关联歌词同时适用于插件歌曲、普通网络歌曲和本地歌曲。
    // 以稳定的歌曲路径（插件 ID + 歌曲 ID）作为键，覆盖搜索结果自带的默认歌词。
    final rememberedLyrics = await _loadRememberedLyrics(item.path);
    if (rememberedLyrics != null && rememberedLyrics.trim().isNotEmpty) {
      item = item.copyWith(lyricsRaw: rememberedLyrics, lyricsAttempted: true);
      final queue = [...state.queue];
      queue[index] = item;
      state = state.copyWith(queue: queue);
    }
    final previous = state;
    _flushPlaybackStats(previous);
    _beginStatsSession(item);
    // stop() 会发出 playing=false；切换音源期间先抑制自动下一首，真正
    // 开始新歌曲前再复位，否则手动点开的歌曲播放结束后永远不会循环。
    _manualPause = true;
    final playbackQuality =
        _ref.read(settingsProvider).valueOrNull?.onlineDefaultQuality ?? '320k';
    state = state.copyWith(
      queueIndex: index,
      current: item,
      isPlaying: false,
      position: 0,
      duration: item.durationMs / 1000.0,
      isLoading: true,
      errorMessage: null,
      currentQuality: playbackQuality,
    );
    try {
      await _player.stop();
      final plugin = await _prepareAudioSource(
        item,
        queueIndex: index,
        requestId: requestId,
      );
      if (requestId != _playRequestId) return;
      _preparedSourceRequestId = requestId;
      _consecutivePlaybackFailures = 0;
      _resetFailureStrategyCounters();
      await _player.setVolume(_ref.read(volumeProvider));
      // 换源后重放合成速度/变调（ExoPlayer 重建 PlaybackParameters 会
      // 复位为 1.0）与均衡器（fork 门面在 load 后自行重放）。
      await _player.setSpeed(_combinedEffectsSpeed());
      try {
        await _player.setPitch(_combinedEffectsPitch());
      } catch (_) {
        // 平台不支持变调：忽略，速度仍生效。
      }
      // 最近播放是“开始播放”即记录，与桌面端行为一致。统计写入失败不应
      // 阻断音频播放，因此放到独立异步任务中执行。
      unawaited(_addToRecentHistory(item));
      _manualPause = false;
      unawaited(_startPlayback(requestId, item.path));
      if (requestId != _playRequestId) return;
      // play() 已成功发起。不要 await：它只会在暂停、停止或播放结束后完成。
      state = state.copyWith(isLoading: false, errorMessage: null);
      // 空闲预解析下一首的播放地址，切歌时直接命中运行时缓存。
      unawaited(_prefetchNextSource());
      if (plugin != null && !(state.current?.lyricsAttempted ?? false)) {
        unawaited(_loadPluginLyrics(index, plugin, item));
      } else if (plugin == null &&
          playbackSourceTypeFor(item) == PlaybackSourceType.localFile &&
          !(state.current?.lyricsAttempted ?? false)) {
        // 本地歌曲没有嵌入歌词时也要完成一次探测，避免详情页一直显示
        // “正在获取歌词”，并让界面可以明确提示用户手动关联歌词。
        unawaited(_loadLocalLyrics(index, item.path));
      }
    } catch (error, stackTrace) {
      if (requestId != _playRequestId) return;
      debugPrint('歌曲播放失败：$error');
      debugPrintStack(stackTrace: stackTrace);
      if (error is _PluginUnavailableException) {
        await _handleUnavailablePlugin(
          item,
          index,
          error,
          requestId: requestId,
        );
        return;
      }
      await _handlePlaybackFailure(
        error,
        requestId: requestId,
        queueIndex: index,
      );
    }
    unawaited(_persistSession());
  }

  /// 起播成功后预解析队列中下一首歌曲的播放地址（写入运行时短时
  /// 缓存）。插件 getMusicUrl 网络解析是切歌加载的大头，HyperOS 等
  /// 系统的省电策略可能拖慢网络线程；播放期间的空闲预取让切歌时
  /// 直接命中缓存，仅需 setUrl 连接 CDN。
  Future<void> _prefetchNextSource() async {
    final queue = state.queue;
    final nextIndex = state.queueIndex + 1;
    if (nextIndex < 0 || nextIndex >= queue.length) return;
    final item = queue[nextIndex];
    final type = playbackSourceTypeFor(item);
    if (type != PlaybackSourceType.plugin && type != PlaybackSourceType.lx) {
      return;
    }
    final pluginData = item.pluginData;
    final pluginId = item.pluginId?.trim() ?? '';
    if (pluginData == null || pluginData.isEmpty || pluginId.isEmpty) return;
    try {
      final plugins = await _ref.read(enabledMusicPluginsProvider.future);
      final plugin = plugins
          .where((candidate) => candidate.id == pluginId)
          .firstOrNull;
      if (plugin == null) return;
      final preferredQuality =
          _ref.read(settingsProvider).valueOrNull?.onlineDefaultQuality ??
          '320k';
      await _ref
          .read(pluginRuntimeProvider)
          .resolveMediaSource(
            plugin,
            pluginData,
            preferredQuality: preferredQuality,
          );
    } catch (_) {
      // 预取失败静默：切歌时会按原路径重新解析。
    }
  }

  Future<EnabledMusicPlugin?> _prepareAudioSource(
    QueueItem item, {
    required int queueIndex,
    String? preferredQualityOverride,
    int? requestId,
  }) async {
    final mediaItem = await _systemMediaItem(item);
    final preferredQuality = preferredQualityOverride?.trim().isNotEmpty == true
        ? preferredQualityOverride!.trim()
        : (_ref.read(settingsProvider).valueOrNull?.onlineDefaultQuality ??
              '320k');
    switch (playbackSourceTypeFor(item)) {
      case PlaybackSourceType.plugin:
        final pluginData = item.pluginData;
        if (pluginData == null || pluginData.isEmpty) {
          throw Exception('网络歌曲缺少插件元数据，无法重新获取播放地址');
        }
        final plugins = await _ref.read(enabledMusicPluginsProvider.future);
        final plugin = plugins
            .where((candidate) => candidate.id == item.pluginId)
            .firstOrNull;
        if (plugin == null) {
          final pluginId = item.pluginId?.trim() ?? '';
          final installedName = await loadInstalledMusicPluginName(
            _ref,
            pluginId,
          );
          throw _PluginUnavailableException(
            pluginId,
            installedName ?? _pluginNameFromSnapshot(item) ?? pluginId,
          );
        }
        final runtime = _ref.read(pluginRuntimeProvider);
        // 各阶段计时日志：真机上排查“加载慢”时通过 logcat 观察是插件
        // 解析（getMusicUrl 网络请求）慢还是 setUrl（CDN 连接）慢。
        final resolveStopwatch = Stopwatch()..start();
        late PluginMediaSource source;
        try {
          source = await runtime.resolveMediaSource(
            plugin,
            pluginData,
            preferredQuality: preferredQuality,
          );
        } catch (error) {
          // 默认音质是跨歌曲保存的，当前歌曲可能并不支持上首歌使用的
          // super/母带档位。若插件明确返回“不支持音质”，自动降到 320k
          // 重试，并更新默认值，避免后续歌曲继续重复失败。
          final lower = error.toString().toLowerCase();
          final unsupportedQuality =
              lower.contains('不支持') && lower.contains('音质');
          if (!unsupportedQuality || preferredQuality.toLowerCase() == '320k') {
            rethrow;
          }
          source = await runtime.resolveMediaSource(
            plugin,
            pluginData,
            preferredQuality: '320k',
          );
          await _ref
              .read(settingsProvider.notifier)
              .setOnlineDefaultQuality('320k');
        }
        debugPrint(
          '[播放链路] ${item.path} 音源解析 ${resolveStopwatch.elapsedMilliseconds}ms',
        );
        final setUrlStopwatch = Stopwatch()..start();
        Future<void> submitUrl(PluginMediaSource resolved) => _setPlayerUrl(
          resolved.url,
          // just_audio treats even an empty map as an instruction to route
          // the request through its local Dart proxy.  LX plugins (including
          // 长青) normally return no headers; that proxy performs the TLS
          // request with Dart's HttpClient and some Android networks abort
          // the connection, resulting in a generic `(0) Source error`.
          // Leave headers null when none are required so ExoPlayer opens the
          // URL natively.  Keep the proxy for plugins that really need
          // custom headers (for example Bilibili DASH streams).
          headers: resolved.headers.isEmpty ? null : resolved.headers,
          tag: mediaItem,
          requestId: requestId,
        );
        try {
          await submitUrl(source);
        } catch (error) {
          if (requestId != null && requestId != _playRequestId) rethrow;
          // 短时缓存（预取/切歌回切）的地址可能已过 CDN 时效：失效缓存
          // 并绕过缓存强制重新解析一次，避免把地址过期误判为不可播。
          runtime.invalidateMediaSourceCache(
            plugin,
            pluginData,
            quality: preferredQuality,
          );
          source = await runtime.resolveMediaSource(
            plugin,
            pluginData,
            preferredQuality: preferredQuality,
            bypassCache: true,
          );
          await submitUrl(source);
        }
        debugPrint(
          '[播放链路] ${item.path} setUrl ${setUrlStopwatch.elapsedMilliseconds}ms',
        );
        // 歌曲开始准备播放后立即后台探测当前插件支持的音质，结果由运行时
        // 缓存；播放和下载菜单重复打开时直接读取缓存，不再现场等待网络。
        _ref
            .read(pluginRuntimeProvider)
            .preloadQualities(
              plugin,
              pluginData,
              preferredQuality: preferredQuality,
            );
        // 历史队列里的网易系 OST 歌曲可能持久化了空封面（当时接口只返回
        // 数值 picId），播放时现场补拉专辑封面，避免播放页一直无封面。
        if (item.coverUrl?.trim().isNotEmpty != true) {
          unawaited(_backfillPluginCover(queueIndex, item, plugin, pluginData));
        }
        // 已存在用户记忆的歌词时，不要被插件返回的默认歌词覆盖。
        if (source.lyrics.isNotEmpty &&
            state.queue[queueIndex].lyricsRaw?.trim().isEmpty != false) {
          _updateQueueLyrics(queueIndex, source.lyrics);
        }
        return plugin;
      case PlaybackSourceType.lx:
        final rawLx = item.pluginData?['lx'];
        if (rawLx is! Map) {
          throw Exception('识曲结果缺少播放元数据');
        }
        final plugins = await _ref.read(enabledMusicPluginsProvider.future);
        // 洛雪插件自有歌曲只走洛雪命名空间（见 _resolveOwnedLxSource）。
        final resolveStopwatch = Stopwatch()..start();
        var owned = await _resolveOwnedLxSource(
          item,
          Map<String, dynamic>.from(rawLx),
          plugins,
          preferredQuality: preferredQuality,
        );
        debugPrint(
          '[播放链路] ${item.path} lx 音源解析 ${resolveStopwatch.elapsedMilliseconds}ms',
        );
        if (owned != null) {
          final setUrlStopwatch = Stopwatch()..start();
          Future<void> submitOwnedUrl(_RecognizedAudioSource resolved) =>
              _setPlayerUrl(
                resolved.url,
                headers: resolved.headers.isEmpty ? null : resolved.headers,
                tag: mediaItem,
                requestId: requestId,
              );
          try {
            await submitOwnedUrl(owned);
          } catch (error) {
            if (requestId != null && requestId != _playRequestId) rethrow;
            // 短时缓存的地址可能已过 CDN 时效：绕过缓存重新解析一次。
            final fresh = await _resolveOwnedLxSource(
              item,
              Map<String, dynamic>.from(rawLx),
              plugins,
              preferredQuality: preferredQuality,
              bypassCache: true,
            );
            if (fresh == null) rethrow;
            owned = fresh;
            await submitOwnedUrl(owned);
          }
          debugPrint(
            '[播放链路] ${item.path} setUrl ${setUrlStopwatch.elapsedMilliseconds}ms',
          );
          if (!(state.current?.lyricsAttempted ?? false)) {
            unawaited(
              _loadLxLyrics(
                queueIndex,
                item.path,
                Map<String, dynamic>.from(rawLx),
              ),
            );
          }
          if (owned.lyrics.trim().isNotEmpty &&
              state.queue[queueIndex].lyricsRaw?.trim().isEmpty != false) {
            _updateQueueLyrics(queueIndex, owned.lyrics);
          }
          final lxPlugin = owned.plugin;
          if (lxPlugin != null) {
            _ref
                .read(pluginRuntimeProvider)
                .preloadQualities(
                  lxPlugin,
                  item.pluginData ?? const <String, dynamic>{},
                  preferredQuality: preferredQuality,
                );
          }
          return null;
        }
        // 识曲等没有对应洛雪插件的歌曲保持原有回退链：缓存、全插件
        // 标题搜索与洛雪公共解析并行竞速。
        final cached = await _resolveCachedRecognizedPlugin(
          item,
          plugins,
          preferredQuality: preferredQuality,
        );
        final source =
            cached ??
            await _firstRecognizedSource([
              _resolveRecognizedWithPlugins(
                item,
                plugins,
                preferredQuality: preferredQuality,
              ),
              _resolveRecognizedWithLx(
                Map<String, dynamic>.from(rawLx),
                plugins: plugins,
                preferredQuality: preferredQuality,
              ),
            ]).timeout(const Duration(seconds: 30), onTimeout: () => null);
        if (source == null) {
          throw Exception('无法获取识曲结果的播放地址，请确认至少启用了一个可用音乐插件');
        }
        await _setPlayerUrl(
          source.url,
          headers: source.headers.isEmpty ? null : source.headers,
          tag: mediaItem,
          requestId: requestId,
        );
        if (!(state.current?.lyricsAttempted ?? false)) {
          unawaited(
            _loadLxLyrics(
              queueIndex,
              item.path,
              Map<String, dynamic>.from(rawLx),
            ),
          );
        }
        if (source.plugin != null && source.pluginData != null) {
          _cacheRecognizedPluginSource(
            queueIndex,
            source.plugin!,
            source.pluginData!,
          );
          if (source.lyrics.trim().isNotEmpty &&
              state.queue[queueIndex].lyricsRaw?.trim().isEmpty != false) {
            _updateQueueLyrics(queueIndex, source.lyrics);
          } else if (!(state.current?.lyricsAttempted ?? false)) {
            unawaited(
              _loadRecognizedPluginLyrics(
                queueIndex,
                item.path,
                source.plugin!,
                source.pluginData!,
              ),
            );
          }
        }
        return null;
      case PlaybackSourceType.networkUrl:
        await _setPlayerUrl(item.path, tag: mediaItem, requestId: requestId);
        return null;
      case PlaybackSourceType.localFile:
        await _setLocalAudioSource(item.path, mediaItem, requestId: requestId);
        return null;
    }
  }

  /// 将原生音频源设置操作串行化，并在真正提交前检查请求是否仍然有效。
  /// 这样快速点击上一首/下一首时，旧请求即使晚于新请求完成解析，也不会
  /// 把旧音源重新写回播放器。
  Future<T> _enqueueSourceOperation<T>(Future<T> Function() operation) {
    final result = _sourceOperation.then((_) => operation());
    _sourceOperation = result.then<void>(
      (_) {},
      onError: (error, stackTrace) {},
    );
    return result;
  }

  /// 播放地址 Java 层 DNS 预热：解析结果写入系统 netd 缓存（与
  /// ExoPlayer 共享同一缓存）。实测部分厂商 ROM 上 CDN 域名冷解析
  /// 可达数秒（如 tx 音源 isure 节点 setUrl 8 秒），预热后 setUrl 的
  /// 连接阶段直接命中缓存。回传的耗时与地址同时写入日志，用于诊断
  /// 慢连接根因（DNS 慢 / 连接慢 / 代理慢）。
  Future<void> _warmUpPlaybackDns(String url) async {
    if (!Platform.isAndroid) return;
    final uri = Uri.tryParse(url);
    final host = uri?.host ?? '';
    if (uri == null || !uri.hasScheme || host.isEmpty) return;
    try {
      final result = await const MethodChannel(
        'com.xymusic.mobile/dns_lookup',
      ).invokeMethod<Map<dynamic, dynamic>>('lookup', {
        'host': host,
      }).timeout(const Duration(seconds: 4));
      debugPrint(
        '[播放链路] DNS预热 $host ${result?['elapsedMs']}ms '
        '${result?['error'] ?? result?['addresses']}',
      );
    } catch (_) {
      // 预热失败（超时/无服务）不阻塞播放链路。
    }
  }

  Future<void> _setPlayerUrl(
    String url, {
    Map<String, String>? headers,
    Object? tag,
    int? requestId,
  }) async {
    await _enqueueSourceOperation(() async {
      if (requestId != null && requestId != _playRequestId) return;
      if (url.startsWith('http')) {
        // 预解析域名填充系统 DNS 缓存；headers 走向也记入日志，
        // 下份日志可据此区分「本地代理慢」与「DNS/网络慢」。
        await _warmUpPlaybackDns(url);
        if (requestId != null && requestId != _playRequestId) return;
        final host = Uri.tryParse(url)?.host ?? '';
        debugPrint(
          '[播放链路] setUrl 开始 $host '
          '(${headers == null ? '直连' : '本地代理 ${headers.length} 头'})',
        );
      }
      // setUrl 加超时保护：部分机型上 ExoPlayer 加载特定 URL 可能卡死
      // （既不抛错也不完成），导致 isLoading 永久为 true。超过 15 秒
      // 主动放弃并抛出超时，交由上层错误处理链路统一兜底。
      try {
        await _player
            .setUrl(url, headers: headers, tag: tag)
            .timeout(const Duration(seconds: 15));
      } on TimeoutException {
        debugPrint('[播放链路] setUrl 超时 15s，主动中断并上报错误');
        rethrow;
      }
    });
  }

  String? _pluginNameFromSnapshot(QueueItem item) {
    final data = item.pluginData;
    if (data == null) return null;
    for (final key in const [
      'pluginName',
      'platform',
      'sourceName',
      'source',
    ]) {
      final value = data[key]?.toString().trim() ?? '';
      if (value.isNotEmpty && value.length <= 80) return value;
    }
    return null;
  }

  Future<void> _handleUnavailablePlugin(
    QueueItem item,
    int queueIndex,
    _PluginUnavailableException error, {
    required int requestId,
  }) async {
    final localReplacement = await _findLocalReplacement(item);
    if (requestId != _playRequestId) return;
    if (localReplacement != null) {
      _publishRelinkProposal(
        queueIndex: queueIndex,
        original: item,
        originalPluginName: error.pluginName,
        replacement: localReplacement,
        replacementSourceName: '本地音乐',
        isLocal: true,
      );
      return;
    }

    final pluginReplacement = await _findPluginReplacement(item);
    if (requestId != _playRequestId) return;
    if (pluginReplacement != null) {
      _publishRelinkProposal(
        queueIndex: queueIndex,
        original: item,
        originalPluginName: error.pluginName,
        replacement: pluginReplacement.item,
        replacementSourceName: pluginReplacement.pluginName,
        isLocal: false,
      );
      return;
    }

    final message = '该歌曲所属“${error.pluginName}”插件无法使用，无法找到代替音源';
    state = state.copyWith(
      isPlaying: false,
      isLoading: false,
      errorMessage: message,
    );
    _publishNotice(message);
    unawaited(_persistSession());
  }

  void _publishRelinkProposal({
    required int queueIndex,
    required QueueItem original,
    required String originalPluginName,
    required QueueItem replacement,
    required String replacementSourceName,
    required bool isLocal,
  }) {
    state = state.copyWith(
      isPlaying: false,
      isLoading: false,
      errorMessage: null,
    );
    _ref
        .read(playbackRelinkProposalProvider.notifier)
        .state = PlaybackRelinkProposal(
      id: ++_relinkProposalId,
      queueIndex: queueIndex,
      originalPath: original.path,
      originalPluginName: originalPluginName,
      replacement: replacement,
      replacementSourceName: replacementSourceName,
      isLocal: isLocal,
    );
  }

  void _publishNotice(String message) {
    _ref.read(playbackNoticeEventProvider.notifier).state = PlaybackNoticeEvent(
      ++_noticeId,
      message,
    );
  }

  Future<void> acceptRelinkProposal(PlaybackRelinkProposal proposal) async {
    final pending = _ref.read(playbackRelinkProposalProvider);
    if (pending?.id != proposal.id) return;
    _ref.read(playbackRelinkProposalProvider.notifier).state = null;
    final index = proposal.queueIndex;
    if (index < 0 || index >= state.queue.length) return;
    final currentAtIndex = state.queue[index];
    if (currentAtIndex.path != proposal.originalPath) return;

    await _saveAssociatedReplacement(
      proposal.originalPath,
      proposal.replacement,
      original: currentAtIndex,
    );
    final queue = [...state.queue];
    queue[index] = proposal.replacement;
    state = state.copyWith(
      queue: queue,
      current: index == state.queueIndex ? proposal.replacement : state.current,
      duration: index == state.queueIndex
          ? proposal.replacement.durationMs / 1000.0
          : state.duration,
      errorMessage: null,
    );
    unawaited(_persistSession());
    await _playAt(index);
  }

  /// 手动换源：把队列中 path 为 [originalPath] 的歌曲替换为 [replacement]
  /// （其他插件的搜索结果），持久保存关联并立即重新播放。返回是否找到
  /// 对应队列项。
  Future<bool> switchSource(
    String originalPath,
    QueueItem replacement,
  ) async {
    final index = state.queue.indexWhere((item) => item.path == originalPath);
    if (index < 0) return false;
    await _saveAssociatedReplacement(
      originalPath,
      replacement,
      original: state.queue[index],
    );
    final queue = [...state.queue];
    queue[index] = replacement;
    state = state.copyWith(
      queue: queue,
      current: index == state.queueIndex ? replacement : state.current,
      duration: index == state.queueIndex
          ? replacement.durationMs / 1000.0
          : state.duration,
      errorMessage: null,
    );
    unawaited(_persistSession());
    if (index == state.queueIndex) {
      await _playAt(index);
    }
    return true;
  }

  /// 无网络/在线音源失败时直接切换到本地替代并续播，不弹提案询问：
  /// 替换会像手动接受提案一样持久保存关联，下次播放同一首自动用本地。
  Future<void> _autoRelinkToLocal({
    required int queueIndex,
    required QueueItem original,
    required QueueItem replacement,
  }) async {
    if (queueIndex < 0 || queueIndex >= state.queue.length) return;
    if (state.queue[queueIndex].path != original.path) return;

    await _saveAssociatedReplacement(
      original.path,
      replacement,
      original: original,
    );
    final queue = [...state.queue];
    queue[queueIndex] = replacement;
    state = state.copyWith(
      queue: queue,
      current: queueIndex == state.queueIndex
          ? replacement
          : state.current,
      duration: queueIndex == state.queueIndex
          ? replacement.durationMs / 1000.0
          : state.duration,
      errorMessage: null,
    );
    unawaited(_persistSession());
    _publishNotice('在线音源不可用，已自动切换为本地文件播放');
    await _playAt(queueIndex);
  }

  void dismissRelinkProposal(PlaybackRelinkProposal proposal) {
    final pending = _ref.read(playbackRelinkProposalProvider);
    if (pending?.id != proposal.id) return;
    _ref.read(playbackRelinkProposalProvider.notifier).state = null;
    state = state.copyWith(
      isPlaying: false,
      isLoading: false,
      errorMessage: '歌曲所属插件“${proposal.originalPluginName}”无法使用',
    );
  }

  Future<QueueItem?> _findLocalReplacement(QueueItem original) async {
    final candidates = <({QueueItem item, bool downloaded})>[];
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final raw = await searchLibrarySongs(
        dbPath: dbPath,
        query: original.title.trim(),
        limit: BigInt.from(80),
      );
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final value in decoded.whereType<Map>()) {
          final item = _queueItemFromLibraryJson(
            Map<String, dynamic>.from(value),
          );
          if (item == null ||
              !_sameReplacementTitle(original.title, item.title)) {
            continue;
          }
          if (await _localItemExists(item)) {
            candidates.add((item: item, downloaded: false));
          }
        }
      }
    } catch (_) {
      // 本地库不可用时仍继续检查下载记录和下载目录。
    }

    try {
      final snapshots = await loadDownloadedSongSnapshots();
      for (final snapshot in snapshots) {
        if (!_sameReplacementTitle(original.title, snapshot.title) ||
            !await File(normalizeLocalAudioPath(snapshot.path)).exists()) {
          continue;
        }
        candidates.add((
          item: QueueItem(
            path: snapshot.path,
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            durationMs: snapshot.durationMs,
            coverUrl: snapshot.coverUrl,
            lyricsRaw: snapshot.lyricsRaw,
            lyricsAttempted: snapshot.lyricsRaw?.trim().isNotEmpty == true,
          ),
          downloaded: true,
        ));
      }
    } catch (_) {}

    if (candidates.isEmpty) {
      final legacy = await _findLegacyDownloadedReplacement(original);
      if (legacy != null) candidates.add((item: legacy, downloaded: true));
    }
    if (candidates.isEmpty) return null;

    candidates.sort(
      (left, right) =>
          _localReplacementScore(
            original,
            right.item,
            downloaded: right.downloaded,
          ).compareTo(
            _localReplacementScore(
              original,
              left.item,
              downloaded: left.downloaded,
            ),
          ),
    );
    var selected = candidates.first.item;
    if (selected.lyricsRaw?.trim().isNotEmpty != true) {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        final lyrics = await getSongLyrics(dbPath: dbPath, path: selected.path);
        if (lyrics.trim().isNotEmpty) {
          selected = selected.copyWith(
            lyricsRaw: lyrics,
            lyricsAttempted: true,
          );
        }
      } catch (_) {}
    }
    return selected;
  }

  /// 深链分享播放等场景的公开入口：按标题/歌手/时长在启用的插件中
  /// 搜索可用音源并解析出可播放的 QueueItem（复用重连的匹配逻辑）。
  Future<({QueueItem item, String pluginName})?> findOnlineReplacement(
    QueueItem original,
  ) =>
      _findPluginReplacement(original);

  Future<({QueueItem item, String pluginName})?> _findPluginReplacement(
    QueueItem original, {
    Set<String> excludePluginIds = const {},
  }) async {
    if (original.title.trim().isEmpty ||
        original.artist.trim().isEmpty ||
        original.durationMs <= 0) {
      return null;
    }
    final plugins = await _ref.read(enabledMusicPluginsProvider.future);
    final candidates = [
      for (final plugin in plugins)
        if (!excludePluginIds.contains(plugin.id)) plugin,
    ];
    if (candidates.isEmpty) return null;
    final runtime = _ref.read(pluginRuntimeProvider);
    final batches = await Future.wait(
      candidates.map((plugin) async {
        try {
          final songs = await runtime
              .search(plugin, original.title.trim())
              .timeout(const Duration(seconds: 15));
          return _RecognizedSearchBatch(plugin, songs);
        } catch (_) {
          return _RecognizedSearchBatch(plugin, const []);
        }
      }),
    );
    final matches = <({EnabledMusicPlugin plugin, PluginSearchSong song})>[];
    for (final batch in batches) {
      for (final song in batch.songs) {
        if (isStrictReplacementMatch(
          title: original.title,
          artist: original.artist,
          durationMs: original.durationMs,
          candidateTitle: song.title,
          candidateArtist: song.artist,
          candidateDurationMs: song.durationMs,
        )) {
          matches.add((plugin: batch.plugin, song: song));
        }
      }
    }
    matches.sort((left, right) {
      final duration = (original.durationMs - left.song.durationMs)
          .abs()
          .compareTo((original.durationMs - right.song.durationMs).abs());
      return duration != 0
          ? duration
          : left.plugin.name.compareTo(right.plugin.name);
    });
    final quality =
        _ref.read(settingsProvider).valueOrNull?.onlineDefaultQuality ?? '320k';
    for (final match in matches.take(10)) {
      try {
        final media = await runtime
            .resolveMediaSource(
              match.plugin,
              match.song.rawData,
              preferredQuality: quality,
            )
            .timeout(const Duration(seconds: 20));
        if (media.url.trim().isEmpty) continue;
        final cover = match.song.coverUrl.trim().isNotEmpty
            ? match.song.coverUrl.trim()
            : extractPluginCoverUrl(match.song.rawData);
        return (
          item: QueueItem(
            path:
                'plugin://${Uri.encodeComponent(match.plugin.id)}/'
                '${Uri.encodeComponent(match.song.id)}',
            title: match.song.title,
            artist: match.song.artist,
            album: match.song.album,
            durationMs: match.song.durationMs,
            pluginId: match.plugin.id,
            pluginData: match.song.rawData,
            coverUrl: cover.isEmpty ? null : cover,
            lyricsRaw: media.lyrics.trim().isEmpty ? null : media.lyrics,
            lyricsAttempted: media.lyrics.trim().isNotEmpty,
          ),
          pluginName: match.plugin.name,
        );
      } catch (_) {
        // 搜索命中但无法解析播放地址时继续尝试其它插件。
      }
    }
    return null;
  }

  bool _sameReplacementTitle(String left, String right) =>
      _normalizeReplacementText(left).isNotEmpty &&
      _normalizeReplacementText(left) == _normalizeReplacementText(right);

  int _localReplacementScore(
    QueueItem original,
    QueueItem candidate, {
    required bool downloaded,
  }) {
    var score = downloaded ? 400 : 300;
    if (_normalizeReplacementText(original.artist) ==
        _normalizeReplacementText(candidate.artist)) {
      score += 100;
    }
    if (original.durationMs > 0 && candidate.durationMs > 0) {
      final difference = (original.durationMs - candidate.durationMs).abs();
      if (difference <= 2000) {
        score += 80;
      } else if (difference <= 5000) {
        score += 40;
      }
    }
    return score;
  }

  QueueItem? _queueItemFromLibraryJson(Map<String, dynamic> json) {
    final path = json['path']?.toString().trim() ?? '';
    if (path.isEmpty) return null;
    final cover = json['cover_url']?.toString().trim().isNotEmpty == true
        ? json['cover_url'].toString().trim()
        : json['cover_thumb_path']?.toString().trim() ?? '';
    return QueueItem(
      path: path,
      title: json['title']?.toString() ?? _titleFromPath(path),
      artist: json['artist']?.toString() ?? '',
      album: json['album']?.toString() ?? '',
      durationMs: ((json['duration'] as num?)?.toInt() ?? 0) * 1000,
      coverUrl: cover.isEmpty ? null : cover,
    );
  }

  Future<bool> _localItemExists(QueueItem item) async {
    if (item.path.startsWith('content://')) return true;
    return File(normalizeLocalAudioPath(item.path)).exists();
  }

  Future<QueueItem?> _findLegacyDownloadedReplacement(
    QueueItem original,
  ) async {
    try {
      final settings = _ref.read(settingsProvider).valueOrNull;
      final directoryPath = await resolveMusicDownloadDirectory(settings);
      final directory = Directory(directoryPath);
      if (!await directory.exists()) return null;
      final normalizedTitle = _normalizeReplacementText(original.title);
      final paths = <String>[];
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File || paths.length >= 30) continue;
        final extension = p.extension(entity.path).toLowerCase();
        if (!const {
          '.flac',
          '.mp3',
          '.wav',
          '.aac',
          '.m4a',
          '.ogg',
          '.opus',
          '.aiff',
        }.contains(extension)) {
          continue;
        }
        if (_normalizeReplacementText(
          p.basenameWithoutExtension(entity.path),
        ).contains(normalizedTitle)) {
          paths.add(entity.path);
        }
      }
      if (paths.isEmpty) return null;
      final parsed = jsonDecode(
        await parseAudioFiles(pathsJson: jsonEncode(paths)),
      );
      if (parsed is! List) return null;
      final candidates = parsed
          .whereType<Map>()
          .map(
            (value) =>
                _queueItemFromLibraryJson(Map<String, dynamic>.from(value)),
          )
          .whereType<QueueItem>()
          .where((item) => _sameReplacementTitle(original.title, item.title))
          .toList();
      if (candidates.isEmpty) return null;
      candidates.sort(
        (a, b) => _localReplacementScore(
          original,
          b,
          downloaded: true,
        ).compareTo(_localReplacementScore(original, a, downloaded: true)),
      );
      return candidates.first;
    } catch (_) {
      return null;
    }
  }

  Future<QueueItem?> _loadAssociatedReplacement(String originalPath) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_playbackSourceAssociationsKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded[originalPath] is! Map) return null;
      return _queueItemFromAssociation(
        Map<String, dynamic>.from(decoded[originalPath] as Map),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveAssociatedReplacement(
    String originalPath,
    QueueItem replacement, {
    QueueItem? original,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final associations = <String, dynamic>{};
    try {
      final raw = preferences.getString(_playbackSourceAssociationsKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map) {
        associations.addAll(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    final entry = _queueItemToAssociation(replacement);
    // 记录换源前的原始音源，供「还原」功能恢复。
    if (original != null) {
      entry['original'] = _queueItemToAssociation(original);
    }
    associations[originalPath] = entry;
    await preferences.setString(
      _playbackSourceAssociationsKey,
      jsonEncode(associations, toEncodable: (value) => value.toString()),
    );
  }

  /// 在持久化关联中查找替代音源 path 为 [replacementPath] 的记录，
  /// 返回（原始音源 path, 关联条目）。
  Future<(String, Map<String, dynamic>)?> _findReplacementEntry(
    String replacementPath,
  ) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_playbackSourceAssociationsKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is Map && value['path']?.toString() == replacementPath) {
          return (entry.key.toString(), Map<String, dynamic>.from(value));
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _removeAssociatedReplacement(String originalPath) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_playbackSourceAssociationsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded[originalPath] == null) return;
      final associations = Map<String, dynamic>.from(decoded);
      associations.remove(originalPath);
      await preferences.setString(
        _playbackSourceAssociationsKey,
        jsonEncode(associations, toEncodable: (value) => value.toString()),
      );
    } catch (_) {}
  }

  /// 当前歌曲是否为换源后的替代音源且保存了可还原的原始音源，
  /// 用于决定播放页更多菜单是否展示「还原」入口。
  Future<bool> hasSwitchedSource(String currentPath) async {
    final matched = await _findReplacementEntry(currentPath);
    return matched?.$2['original'] is Map;
  }

  /// 还原换源：把队列中 path 为 [currentPath]（换源后的替代音源）的歌曲
  /// 恢复为换源前的原始音源，并删除持久化关联（之后按原音源播放不再
  /// 自动换回替代音源）。返回是否成功还原。
  Future<bool> restoreSource(String currentPath) async {
    final matched = await _findReplacementEntry(currentPath);
    if (matched == null) return false;
    final (originalPath, entry) = matched;
    final originalJson = entry['original'];
    if (originalJson is! Map) return false;
    final original = _queueItemFromAssociation(
      Map<String, dynamic>.from(originalJson),
    );
    if (original == null) return false;
    await _removeAssociatedReplacement(originalPath);
    final index = state.queue.indexWhere((item) => item.path == currentPath);
    if (index >= 0) {
      final queue = [...state.queue];
      queue[index] = original;
      state = state.copyWith(
        queue: queue,
        current: index == state.queueIndex ? original : state.current,
        duration: index == state.queueIndex
            ? original.durationMs / 1000.0
            : state.duration,
      );
      unawaited(_persistSession());
      if (index == state.queueIndex) {
        await _playAt(index);
      }
    }
    return true;
  }

  Future<String?> _loadRememberedLyrics(String path) async {
    final key = path.trim();
    if (key.isEmpty) return null;
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_rememberedLyricsKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final lyrics = decoded[key]?.toString().trim() ?? '';
      return lyrics.isEmpty ? null : lyrics;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveRememberedLyrics(String path, String lyrics) async {
    final key = path.trim();
    final value = lyrics.trim();
    if (key.isEmpty || value.isEmpty || value.length > 300 * 1024) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      final remembered = <String, dynamic>{};
      final raw = preferences.getString(_rememberedLyricsKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map) {
        remembered.addAll(Map<String, dynamic>.from(decoded));
      }
      remembered[key] = value;
      // 歌词文本可能较大，限制数量避免长期使用后占满偏好设置。
      while (remembered.length > 100) {
        remembered.remove(remembered.keys.first);
      }
      await preferences.setString(_rememberedLyricsKey, jsonEncode(remembered));
    } catch (_) {}
  }

  Future<void> _saveRememberedLyricsAssociation(
    String path,
    RememberedLyricsAssociation association,
    String originalLyrics,
  ) async {
    final key = path.trim();
    if (key.isEmpty) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      final associations = <String, dynamic>{};
      final originals = <String, dynamic>{};
      final rawAssociations = preferences.getString(
        _rememberedLyricsAssociationKey,
      );
      final rawOriginals = preferences.getString(_rememberedLyricsOriginalKey);
      final decodedAssociations = rawAssociations == null
          ? null
          : jsonDecode(rawAssociations);
      final decodedOriginals = rawOriginals == null
          ? null
          : jsonDecode(rawOriginals);
      if (decodedAssociations is Map) {
        associations.addAll(Map<String, dynamic>.from(decodedAssociations));
      }
      if (decodedOriginals is Map) {
        originals.addAll(Map<String, dynamic>.from(decodedOriginals));
      }
      associations[key] = association.toJson();
      // 重新选择歌词时保留第一次关联前的默认歌词，取消关联才能真正恢复默认内容。
      originals.putIfAbsent(key, () => originalLyrics);
      while (associations.length > 100) {
        final oldest = associations.keys.first;
        associations.remove(oldest);
        originals.remove(oldest);
      }
      await Future.wait([
        preferences.setString(
          _rememberedLyricsAssociationKey,
          jsonEncode(associations),
        ),
        preferences.setString(
          _rememberedLyricsOriginalKey,
          jsonEncode(originals),
        ),
      ]);
    } catch (_) {}
  }

  Future<RememberedLyricsAssociation?> rememberedLyricsAssociation(
    String path,
  ) async {
    final key = path.trim();
    if (key.isEmpty) return null;
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_rememberedLyricsAssociationKey);
      final decoded = raw == null || raw.isEmpty ? null : jsonDecode(raw);
      final value = decoded is Map ? decoded[key] : null;
      if (value is! Map) return null;
      return RememberedLyricsAssociation.fromJson(
        Map<String, dynamic>.from(value),
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> _removeRememberedLyricsAssociation(String path) async {
    final key = path.trim();
    if (key.isEmpty) return null;
    try {
      final preferences = await SharedPreferences.getInstance();
      final rawOriginals = preferences.getString(_rememberedLyricsOriginalKey);
      final decodedOriginals = rawOriginals == null || rawOriginals.isEmpty
          ? null
          : jsonDecode(rawOriginals);
      final originals = decodedOriginals is Map
          ? Map<String, dynamic>.from(decodedOriginals)
          : <String, dynamic>{};
      final original = originals.remove(key)?.toString();
      final rawAssociations = preferences.getString(
        _rememberedLyricsAssociationKey,
      );
      final decodedAssociations =
          rawAssociations == null || rawAssociations.isEmpty
          ? null
          : jsonDecode(rawAssociations);
      final associations = decodedAssociations is Map
          ? Map<String, dynamic>.from(decodedAssociations)
          : <String, dynamic>{};
      associations.remove(key);
      final rawLyrics = preferences.getString(_rememberedLyricsKey);
      final decodedLyrics = rawLyrics == null || rawLyrics.isEmpty
          ? null
          : jsonDecode(rawLyrics);
      final lyrics = decodedLyrics is Map
          ? Map<String, dynamic>.from(decodedLyrics)
          : <String, dynamic>{};
      lyrics.remove(key);
      await Future.wait([
        associations.isEmpty
            ? preferences.remove(_rememberedLyricsAssociationKey)
            : preferences.setString(
                _rememberedLyricsAssociationKey,
                jsonEncode(associations),
              ),
        originals.isEmpty
            ? preferences.remove(_rememberedLyricsOriginalKey)
            : preferences.setString(
                _rememberedLyricsOriginalKey,
                jsonEncode(originals),
              ),
        lyrics.isEmpty
            ? preferences.remove(_rememberedLyricsKey)
            : preferences.setString(_rememberedLyricsKey, jsonEncode(lyrics)),
      ]);
      return original;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _queueItemToAssociation(QueueItem item) => {
    'path': item.path,
    'title': item.title,
    'artist': item.artist,
    'album': item.album,
    'durationMs': item.durationMs,
    'pluginId': item.pluginId,
    'pluginData': item.pluginData,
    'coverUrl': item.coverUrl,
    'lyricsRaw': item.lyricsRaw,
    'lyricsAttempted': item.lyricsAttempted,
  };

  QueueItem? _queueItemFromAssociation(Map<String, dynamic> json) {
    final path = json['path']?.toString() ?? '';
    if (path.isEmpty) return null;
    return QueueItem(
      path: path,
      title: json['title']?.toString() ?? _titleFromPath(path),
      artist: json['artist']?.toString() ?? '',
      album: json['album']?.toString() ?? '',
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      pluginId: json['pluginId']?.toString(),
      pluginData: json['pluginData'] is Map
          ? Map<String, dynamic>.from(json['pluginData'] as Map)
          : null,
      coverUrl: json['coverUrl']?.toString(),
      lyricsRaw: json['lyricsRaw']?.toString(),
      lyricsAttempted: json['lyricsAttempted'] == true,
    );
  }

  Future<void> _setLocalAudioSource(
    String rawPath,
    MediaItem mediaItem, {
    int? requestId,
  }) async {
    final trimmed = rawPath.trim();
    // 网盘挂载歌曲（remote:// URI）：先解析播放来源，命中缓存播本地
    // 缓存文件，未缓存则流式播放 Alist/OpenList 直链。
    if (trimmed.startsWith('remote://')) {
      await _setRemoteAudioSource(trimmed, mediaItem, requestId: requestId);
      return;
    }
    if (trimmed.startsWith('content://')) {
      try {
        await _enqueueSourceOperation(() async {
          if (requestId != null && requestId != _playRequestId) return;
          await _player.setAudioSource(
            AudioSource.uri(Uri.parse(trimmed), tag: mediaItem),
          );
        });
        return;
      } catch (_) {
        throw const _LocalPlaybackException('本地歌曲无法播放，请重新选择文件或重新授予文件访问权限');
      }
    }

    final path = normalizeLocalAudioPath(trimmed);
    var exists = await File(path).exists();
    if (!exists && !kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await _requestAndroidAudioPermission();
      exists = await File(path).exists();
    }
    if (!exists) {
      throw const _LocalPlaybackException('本地歌曲文件不存在或没有访问权限，请重新扫描歌曲');
    }
    try {
      await _enqueueSourceOperation(() async {
        if (requestId != null && requestId != _playRequestId) return;
        await _player.setFilePath(path, tag: mediaItem);
      });
    } catch (_) {
      throw const _LocalPlaybackException('本地歌曲无法播放，请确认文件未损坏且格式受支持');
    }
  }

  Future<void> _requestAndroidAudioPermission() async {
    if (await Permission.audio.isGranted ||
        await Permission.storage.isGranted ||
        await Permission.manageExternalStorage.isGranted) {
      return;
    }
    if ((await Permission.audio.request()).isGranted) return;
    if ((await Permission.storage.request()).isGranted) return;
    await Permission.manageExternalStorage.request();
  }

  /// 远程挂载歌曲的播放解析：已缓存返回本地路径直接播；未缓存则解析
  /// Alist/OpenList 直链并附带防盗链 headers 流式播放。
  Future<void> _setRemoteAudioSource(
    String remoteUri,
    MediaItem mediaItem, {
    int? requestId,
  }) async {
    String planJson;
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      planJson = await remotePlaybackSource(
        dbPath: dbPath,
        remoteUri: remoteUri,
      );
    } catch (error) {
      throw _LocalPlaybackException('网盘歌曲解析失败：$error');
    }
    final plan = jsonDecode(planJson) as Map<String, dynamic>;
    final kind = plan['kind'] as String? ?? '';
    if (kind == 'cached') {
      final cachedPath = plan['path'] as String? ?? '';
      try {
        await _enqueueSourceOperation(() async {
          if (requestId != null && requestId != _playRequestId) return;
          await _player.setFilePath(cachedPath, tag: mediaItem);
        });
      } catch (_) {
        throw const _LocalPlaybackException('网盘缓存文件无法播放，请清理缓存后重试');
      }
      return;
    }

    final url = plan['url'] as String? ?? '';
    if (url.isEmpty) {
      throw const _LocalPlaybackException('网盘歌曲缺少播放地址');
    }
    // Alist/OpenList 播放计划：优先使用服务端返回的防盗链 headers
    // （raw_url 直链的 UA/Referer/Cookie 等），叠加 Basic 认证兜底。
    final headers = <String, String>{
      if (plan['headers'] case final Map<String, dynamic> extraHeaders)
        for (final entry in extraHeaders.entries)
          if (entry.value != null) entry.key: entry.value.toString(),
      if (plan['userAgent'] case final String userAgent?
          when userAgent.isNotEmpty)
        'User-Agent': userAgent,
      if (plan['referer'] case final String referer? when referer.isNotEmpty)
        'Referer': referer,
    };
    final username = plan['username'] as String?;
    final password = plan['password'] as String?;
    if (username != null &&
        username.isNotEmpty &&
        !headers.containsKey('Authorization')) {
      final token = base64Encode(utf8.encode('$username:${password ?? ''}'));
      headers['Authorization'] = 'Basic $token';
    }
    try {
      await _setPlayerUrl(
        url,
        headers: headers.isEmpty ? null : headers,
        tag: mediaItem,
        requestId: requestId,
      );
    } catch (_) {
      throw const _LocalPlaybackException('网盘歌曲无法播放，请检查网络或账号密码');
    }
  }

  /// 洛雪插件自有歌曲的解析（对齐 BakaMusic 的命名空间隔离：洛雪音源
  /// 与 MusicFree 插件是两个独立命名空间，互不接管对方的歌曲）。
  ///
  /// 歌曲携带的 pluginId 对应一个已启用的洛雪插件时，由该插件自己解析
  /// 播放地址；失败也只在洛雪命名空间内回退（其它洛雪插件与公共解析
  /// 器），不再按标题搜索 MusicFree 插件，避免洛雪歌单的歌曲被聆澜等
  /// 聚合插件的 QQ 音源接管。
  ///
  /// 返回 null 表示该歌曲不属于任何已启用的洛雪插件（识曲等场景），
  /// 调用方应继续走通用回退链。
  Future<_RecognizedAudioSource?> _resolveOwnedLxSource(
    QueueItem item,
    Map<String, dynamic> rawLx,
    List<EnabledMusicPlugin> plugins, {
    String? preferredQuality,
    bool bypassCache = false,
  }) async {
    final lxPluginId = item.pluginId?.trim() ?? '';
    if (lxPluginId.isEmpty) return null;
    final lxPlugin = plugins
        .where((candidate) => candidate.id == lxPluginId && candidate.isLx)
        .firstOrNull;
    if (lxPlugin == null) return null;
    Object? lxError;
    try {
      final media = await _ref
          .read(pluginRuntimeProvider)
          .resolveMediaSource(
            lxPlugin,
            item.pluginData ?? const <String, dynamic>{},
            preferredQuality: preferredQuality,
            bypassCache: bypassCache,
          )
          .timeout(const Duration(seconds: 30));
      if (media.url.trim().isNotEmpty) {
        return _RecognizedAudioSource(
          url: media.url,
          headers: media.headers,
          lyrics: media.lyrics,
          plugin: lxPlugin,
        );
      }
    } catch (error) {
      lxError = error;
    }
    final fallback = await _resolveRecognizedWithLx(
      Map<String, dynamic>.from(rawLx),
      plugins: plugins
          .where((candidate) => candidate.id != lxPlugin.id)
          .toList(),
      preferredQuality: preferredQuality,
    ).timeout(const Duration(seconds: 30), onTimeout: () => null);
    if (fallback != null && fallback.url.trim().isNotEmpty) return fallback;
    final reason = lxError == null
        ? '洛雪音源解析失败，请检查洛雪插件是否可用'
        : '洛雪音源解析失败：'
              '${lxError.toString().replaceFirst('Exception: ', '')}';
    throw Exception(reason);
  }

  Future<_RecognizedAudioSource?> _resolveCachedRecognizedPlugin(
    QueueItem item,
    List<EnabledMusicPlugin> plugins, {
    String? preferredQuality,
  }) async {
    final rawCache = item.pluginData?[_recognizedPluginCacheKey];
    if (rawCache is! Map) return null;
    final cache = Map<String, dynamic>.from(rawCache);
    final pluginId = cache['pluginId']?.toString() ?? '';
    final rawData = cache['rawData'];
    if (pluginId.isEmpty || rawData is! Map) return null;
    final plugin = plugins
        .where((candidate) => candidate.id == pluginId)
        .firstOrNull;
    if (plugin == null) return null;
    try {
      final data = Map<String, dynamic>.from(rawData);
      final media = await _ref
          .read(pluginRuntimeProvider)
          .resolveMediaSource(plugin, data, preferredQuality: preferredQuality)
          .timeout(const Duration(seconds: 20));
      return _RecognizedAudioSource(
        url: media.url,
        headers: media.headers,
        lyrics: media.lyrics,
        plugin: plugin,
        pluginData: data,
      );
    } catch (_) {
      // 插件更新或歌曲地址规则变化时，继续重新搜索，不让旧缓存阻断播放。
      return null;
    }
  }

  Future<_RecognizedAudioSource?> _resolveRecognizedWithPlugins(
    QueueItem item,
    List<EnabledMusicPlugin> plugins, {
    String? preferredQuality,
  }) async {
    if (plugins.isEmpty || item.title.trim().isEmpty) return null;
    final runtime = _ref.read(pluginRuntimeProvider);
    final batches = await Future.wait(
      plugins.map((plugin) async {
        try {
          final songs = await runtime
              .search(plugin, item.title.trim())
              .timeout(const Duration(seconds: 18));
          return _RecognizedSearchBatch(plugin, songs);
        } catch (_) {
          return _RecognizedSearchBatch(plugin, const []);
        }
      }),
    );
    final candidates = <_RecognizedSearchCandidate>[];
    for (final batch in batches) {
      for (final song in batch.songs) {
        final score = recognizedSongMatchScore(
          title: item.title,
          artist: item.artist,
          candidateTitle: song.title,
          candidateArtist: song.artist,
          durationMs: item.durationMs,
          candidateDurationMs: song.durationMs,
        );
        if (score >= 90) {
          candidates.add(
            _RecognizedSearchCandidate(
              plugin: batch.plugin,
              song: song,
              score: score,
            ),
          );
        }
      }
    }
    candidates.sort((a, b) => b.score.compareTo(a.score));
    for (final candidate in candidates.take(8)) {
      try {
        final media = await runtime
            .resolveMediaSource(
              candidate.plugin,
              candidate.song.rawData,
              preferredQuality: preferredQuality,
            )
            .timeout(const Duration(seconds: 20));
        if (media.url.trim().isEmpty) continue;
        return _RecognizedAudioSource(
          url: media.url,
          headers: media.headers,
          lyrics: media.lyrics,
          plugin: candidate.plugin,
          pluginData: candidate.song.rawData,
        );
      } catch (_) {
        // 搜索命中不代表当前插件一定能解析该音质，继续尝试下一个候选。
      }
    }
    return null;
  }

  Future<_RecognizedAudioSource?> _resolveRecognizedWithLx(
    Map<String, dynamic> songInfo, {
    List<EnabledMusicPlugin> plugins = const [],
    String? preferredQuality,
  }) async {
    // LX 歌曲可能来自导入/听歌识曲，路径中没有原始插件 ID。优先让已
    // 安装的 LX 插件自己解析播放地址（例如自定义 API 音源），再回退
    // 到公共 Rust 地址解析器。
    final source = songInfo['source']?.toString().trim() ?? '';
    final runtime = _ref.read(pluginRuntimeProvider);
    for (final plugin in plugins.where((item) => item.isLx)) {
      if (source.isNotEmpty &&
          plugin.lxSources.isNotEmpty &&
          !plugin.lxSources.contains(source)) {
        continue;
      }
      try {
        final media = await runtime
            .resolveMediaSource(plugin, {
              'lx': songInfo,
            }, preferredQuality: preferredQuality)
            .timeout(const Duration(seconds: 20));
        if (media.url.trim().isNotEmpty) {
          return _RecognizedAudioSource(
            url: media.url,
            headers: media.headers,
            lyrics: media.lyrics,
            plugin: plugin,
            pluginData: {'lx': songInfo},
          );
        }
      } catch (_) {
        // 当前 LX 插件不支持该来源时继续尝试其它插件/公共接口。
      }
    }
    final types = songInfo['_types'] is Map
        ? Map<String, dynamic>.from(songInfo['_types'] as Map)
        : const <String, dynamic>{};
    final qualities = <String>{
      if (preferredQuality?.trim().isNotEmpty == true) preferredQuality!.trim(),
      if (types.containsKey('flac')) 'flac',
      if (types.containsKey('320k')) '320k',
      '128k',
    };
    for (final quality in qualities) {
      try {
        final raw = await lxResolveUrl(
          songInfoJson: jsonEncode(songInfo),
          quality: quality,
        ).timeout(const Duration(seconds: 12));
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final url = decoded['url']?.toString().trim() ?? '';
          if (url.isNotEmpty) return _RecognizedAudioSource(url: url);
        }
      } catch (_) {
        // 当前音质或公共代理不可用时继续降级。
      }
    }
    return null;
  }

  Future<_RecognizedAudioSource?> _firstRecognizedSource(
    List<Future<_RecognizedAudioSource?>> operations,
  ) {
    if (operations.isEmpty) return Future.value();
    final completer = Completer<_RecognizedAudioSource?>();
    var remaining = operations.length;
    for (final operation in operations) {
      operation.then(
        (source) {
          if (source != null && !completer.isCompleted) {
            completer.complete(source);
          }
          remaining--;
          if (remaining == 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        },
        onError: (_) {
          remaining--;
          if (remaining == 0 && !completer.isCompleted) {
            completer.complete(null);
          }
        },
      );
    }
    return completer.future;
  }

  void _cacheRecognizedPluginSource(
    int index,
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData,
  ) {
    if (index < 0 || index >= state.queue.length) return;
    final old = state.queue[index];
    final queue = [...state.queue];
    queue[index] = QueueItem(
      path: old.path,
      title: old.title,
      artist: old.artist,
      album: old.album,
      durationMs: old.durationMs,
      pluginId: old.pluginId,
      pluginData: {
        ...?old.pluginData,
        _recognizedPluginCacheKey: {'pluginId': plugin.id, 'rawData': rawData},
      },
      coverUrl: old.coverUrl,
      lyricsRaw: old.lyricsRaw,
      lyricsAttempted: old.lyricsAttempted,
    );
    state = state.copyWith(
      queue: queue,
      current: index == state.queueIndex ? queue[index] : state.current,
    );
    unawaited(_persistSession());
  }

  Future<void> _loadRecognizedPluginLyrics(
    int index,
    String path,
    EnabledMusicPlugin plugin,
    Map<String, dynamic> rawData,
  ) async {
    try {
      final lyrics = await _ref
          .read(pluginRuntimeProvider)
          .getLyrics(plugin, rawData)
          .timeout(const Duration(seconds: 20));
      if (index < 0 ||
          index >= state.queue.length ||
          state.queue[index].path != path) {
        return;
      }
      if (lyrics.trim().isNotEmpty) {
        _updateQueueLyrics(index, lyrics);
      } else {
        _markLyricsAttempted(index);
      }
      unawaited(_persistSession());
    } catch (_) {
      if (index >= 0 &&
          index < state.queue.length &&
          state.queue[index].path == path) {
        _markLyricsAttempted(index);
        unawaited(_persistSession());
      }
    }
  }

  Future<MediaItem> _systemMediaItem(QueueItem item) async {
    final artwork = await _systemArtwork(item);
    return MediaItem(
      id: item.path,
      title: item.title.trim().isEmpty ? _titleFromPath(item.path) : item.title,
      artist: item.artist.trim().isEmpty ? '未知歌手' : item.artist,
      album: item.album.trim().isEmpty ? null : item.album,
      duration: item.durationMs > 0
          ? Duration(milliseconds: item.durationMs)
          : null,
      artUri: artwork.uri,
      artHeaders: artwork.headers,
      displayTitle: item.title,
      displaySubtitle: item.artist,
      playable: true,
    );
  }

  Future<({Uri? uri, Map<String, String>? headers})> _systemArtwork(
    QueueItem item,
  ) async {
    // 复用 normalizeCoverImageUrl：HTTPS 升级 + 网易云 CDN param 缩放
    // （大原图会让系统媒体会话封面加载失败）。
    final text = normalizeCoverImageUrl(item.coverUrl);
    var uri = Uri.tryParse(text);
    if (uri != null && const {'http', 'https'}.contains(uri.scheme)) {
      return (uri: uri, headers: _systemArtworkHeaders(uri));
    }
    if (uri != null && const {'file', 'content'}.contains(uri.scheme)) {
      return (uri: uri, headers: null);
    }
    // 部分本地歌曲把封面缩略图保存为普通绝对路径，没有 file:// 前缀。
    if (text.isNotEmpty && File(text).existsSync()) {
      return (uri: Uri.file(text), headers: null);
    }
    if (playbackSourceTypeFor(item) != PlaybackSourceType.localFile) {
      return (uri: null, headers: null);
    }
    // 本地歌曲通常只有音频路径，Flutter 页面会临时提取内嵌封面；系统
    // 媒体服务无法读取 Flutter 图片对象，因此生成缩略图并传 file URI。
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final cacheRoot = await _ref.read(appDataDirProvider.future);
      final thumbnail = await getSongCoverThumbnail(
        dbPath: dbPath,
        cacheRoot: cacheRoot,
        path: normalizeLocalAudioPath(item.path),
      );
      if (thumbnail.trim().isNotEmpty && File(thumbnail).existsSync()) {
        return (uri: Uri.file(thumbnail), headers: null);
      }
    } catch (error) {
      debugPrint('系统媒体封面提取失败：$error');
    }
    return (uri: null, headers: null);
  }

  Map<String, String>? _systemArtworkHeaders(Uri uri) {
    final host = uri.host.toLowerCase();
    const userAgent =
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
    if (host == 'music.126.net' || host.endsWith('.music.126.net')) {
      return const {
        'User-Agent': userAgent,
        'Referer': 'https://music.163.com/',
      };
    }
    if (host.endsWith('.hdslb.com') || host.endsWith('.bilivideo.com')) {
      return const {
        'User-Agent': userAgent,
        'Referer': 'https://www.bilibili.com/',
      };
    }
    if (host.endsWith('.qq.com')) {
      return const {'User-Agent': userAgent, 'Referer': 'https://y.qq.com/'};
    }
    if (host.endsWith('.kugou.com')) {
      return const {
        'User-Agent': userAgent,
        'Referer': 'https://www.kugou.com/',
      };
    }
    return const {'User-Agent': userAgent};
  }

  Future<void> _startPlayback(int requestId, String itemPath) async {
    // Android 13+ 要求先获得通知权限，媒体服务才能把 MediaStyle 通知写入
    // 状态栏、锁屏和系统媒体中心。之前这里与 play() 并发执行，权限弹窗
    // 尚未完成时音频服务已经启动，部分系统会直接丢弃首个媒体通知。
    await _ensureMediaNotificationPermission();
    // 权限请求期间用户可能已经切换了歌曲；同时确认播放器音源仍是本次
    // 请求准备的音源，避免过期的 play() 把实际音频推进到错误的歌曲。
    if (requestId != _playRequestId ||
        state.current?.path != itemPath ||
        _preparedSourceRequestId != requestId) {
      return;
    }
    // 参考 XianYu-Music-Mobile：恢复播放就是纯粹的 play()。此前这里的
    // “先 seek 回锚点重写原生基准 + 起播后漂移校验再 seek”会在部分系统
    // （如 ColorOS 系统控件暂停→熄屏→恢复）上触发原生基准重置，反而
    // 造成 UI 进度从 0 开始走。原生 positionStream 会持续上报真实进度。
    final expectedMs = (state.position * 1000).round();
    // 起播进入加载态：play() 发起到引擎真正出声（playing 事件）之间，
    // 迷你播放栏/播放页按钮显示“加载中”而非滞留播放图标；出声后由
    // playerStateStream 监听统一清除。兜底：引擎极端挂死不上报 playing
    // 时 3 秒后强制结束，避免按钮永久停在“加载中”且不可点。
    state = state.copyWith(isLoading: true);
    _clearLoadingWhenStalled(
      requestId: requestId,
      itemPath: itemPath,
    );
    final playback = _player.play();
    unawaited(_watchPlayback(playback, requestId, itemPath));
    // 诊断日志：恢复播放完成后核对预期与实际进度。若出现“音频在正确
    // 位置但界面从 0 开始”的复现，此日志可直接区分是原生基准被重置
    // （实际≈0）还是事件流被污染（实际正常但事件脏）。
    unawaited(
      playback.then(
        (_) => debugPrint(
          '[播放链路] 恢复播放完成：预期 $expectedMs ms，'
          '实际 ${_player.position.inMilliseconds} ms',
        ),
      ),
    );
  }

  /// 起播加载态兜底：3 秒内 playing 事件仍未到来（引擎挂死等极端情况）
  /// 时强制结束 loading，避免按钮永久停在“加载中”且不可点。出声正常
  /// 时 playing 事件已先行清除，此处不做任何事。
  void _clearLoadingWhenStalled({
    required int requestId,
    required String itemPath,
  }) {
    Timer(const Duration(seconds: 3), () {
      if (requestId != _playRequestId || state.current?.path != itemPath) {
        return;
      }
      if (state.isLoading) {
        state = state.copyWith(isLoading: false);
      }
    });
  }

  Future<void> _ensureMediaNotificationPermission() async {
    if (_notificationPermissionChecked ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _notificationPermissionChecked = true;
    try {
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
    } catch (_) {
      // 媒体会话在多数 Android 版本不依赖通知权限；请求失败不能阻断播放。
    }
  }

  Future<void> _watchPlayback(
    Future<void> playback,
    int requestId,
    String itemPath,
  ) async {
    try {
      await playback;
    } catch (error, stackTrace) {
      // 停止旧歌曲后，它遗留的播放 Future 可能稍后才报错，不能覆盖新歌曲。
      if (requestId != _playRequestId || state.current?.path != itemPath) {
        return;
      }
      debugPrint('歌曲播放失败：$error');
      debugPrintStack(stackTrace: stackTrace);
      await _handlePlaybackFailure(
        error,
        requestId: requestId,
        queueIndex: state.queueIndex,
      );
    }
  }

  void _updateQueueLyrics(int index, String lyrics) {
    if (lyrics.trim().isEmpty || index < 0 || index >= state.queue.length) {
      return;
    }
    final queue = [...state.queue];
    queue[index] = queue[index].copyWith(
      lyricsRaw: lyrics,
      lyricsAttempted: true,
    );
    state = state.copyWith(
      queue: queue,
      current: index == state.queueIndex ? queue[index] : state.current,
    );
    // 视频播放期间 just_audio 没有进度流，歌词补全后要主动刷新桌面歌词。
    _requestDesktopLyricsSync(immediate: true);
  }

  /// 播放时为空封面的网易系插件歌曲补拉专辑封面（fire-and-forget）。
  Future<void> _backfillPluginCover(
    int index,
    QueueItem item,
    EnabledMusicPlugin plugin,
    Map<String, dynamic> pluginData,
  ) async {
    try {
      final cover = await _ref
          .read(pluginRuntimeProvider)
          .fetchNeteaseTrackCover(plugin, pluginData)
          .timeout(const Duration(seconds: 15));
      if (cover.trim().isEmpty) return;
      if (index < 0 || index >= state.queue.length) return;
      final current = state.queue[index];
      if (current.path != item.path ||
          current.coverUrl?.trim().isNotEmpty == true) {
        return;
      }
      final queue = [...state.queue];
      queue[index] = current.copyWith(coverUrl: cover);
      state = state.copyWith(
        queue: queue,
        current: index == state.queueIndex ? queue[index] : state.current,
      );
      unawaited(_persistSession());
    } catch (_) {
      // 封面补全失败不影响播放。
    }
  }

  Future<void> _loadPluginLyrics(
    int index,
    EnabledMusicPlugin plugin,
    QueueItem item,
  ) async {
    if (item.pluginData == null) return;
    try {
      final lyrics = await _ref
          .read(pluginRuntimeProvider)
          .getLyrics(plugin, item.pluginData!);
      if (index >= 0 &&
          index < state.queue.length &&
          state.queue[index].path == item.path) {
        if (lyrics.trim().isNotEmpty) {
          _updateQueueLyrics(index, lyrics);
        } else {
          _markLyricsAttempted(index);
        }
        unawaited(_persistSession());
      }
    } catch (_) {
      if (index >= 0 &&
          index < state.queue.length &&
          state.queue[index].path == item.path) {
        _markLyricsAttempted(index);
        unawaited(_persistSession());
      }
    }
  }

  Future<void> _loadLxLyrics(
    int index,
    String path,
    Map<String, dynamic> songInfo,
  ) async {
    try {
      final source = songInfo['source']?.toString().trim() ?? '';
      if (source.isEmpty) {
        _markLyricsAttemptedForPath(index, path);
        return;
      }
      final response = await fetchLyricFromSource(
        source: source,
        songInfoJson: jsonEncode(songInfo),
      ).timeout(const Duration(seconds: 20));
      if (response.trim().isEmpty || response.trim() == 'null') {
        _markLyricsAttemptedForPath(index, path);
        return;
      }
      final decoded = jsonDecode(response);
      if (decoded is! Map) {
        _markLyricsAttemptedForPath(index, path);
        return;
      }
      final lyrics = buildLxLyricsRaw(Map<String, dynamic>.from(decoded));
      if (lyrics.isEmpty) {
        _markLyricsAttemptedForPath(index, path);
        return;
      }
      if (index >= 0 &&
          index < state.queue.length &&
          state.queue[index].path == path) {
        _updateQueueLyrics(index, lyrics);
        unawaited(_persistSession());
      }
    } catch (_) {
      // LX 歌词属于附加能力，失败时不影响已经开始的音频播放。
      _markLyricsAttemptedForPath(index, path);
    }
  }

  Future<void> _loadLocalLyrics(int index, String path) async {
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final lyrics = await getSongLyrics(dbPath: dbPath, path: path);
      if (index < 0 ||
          index >= state.queue.length ||
          state.queue[index].path != path) {
        return;
      }
      if (lyrics.trim().isNotEmpty) {
        _updateQueueLyrics(index, lyrics);
      } else {
        _markLyricsAttempted(index);
      }
      unawaited(_persistSession());
    } catch (_) {
      _markLyricsAttemptedForPath(index, path);
    }
  }

  /// 进入播放详情页时主动完成一次歌词探测，不依赖歌词页是否已经滑到。
  /// 网络歌曲、LX 音源和本地歌曲分别走各自的歌词来源；没有歌词时也会
  /// 标记为已探测，交给详情页提示用户在歌词页关联歌词。
  Future<void> ensureCurrentLyricsChecked() async {
    final index = state.queueIndex;
    final item = state.current;
    if (item == null ||
        index < 0 ||
        item.lyricsRaw?.trim().isNotEmpty == true) {
      return;
    }
    if (item.lyricsAttempted) return;

    switch (playbackSourceTypeFor(item)) {
      case PlaybackSourceType.localFile:
        await _loadLocalLyrics(index, item.path);
      case PlaybackSourceType.plugin:
        final pluginData = item.pluginData;
        if (pluginData == null || pluginData.isEmpty) {
          _markLyricsAttemptedForPath(index, item.path);
          return;
        }
        final plugins = await _ref.read(enabledMusicPluginsProvider.future);
        final plugin = plugins
            .where((candidate) => candidate.id == item.pluginId)
            .firstOrNull;
        if (plugin == null) {
          _markLyricsAttemptedForPath(index, item.path);
          return;
        }
        await _loadPluginLyrics(index, plugin, item);
      case PlaybackSourceType.lx:
        final raw = item.pluginData?['lx'];
        if (raw is Map) {
          await _loadLxLyrics(index, item.path, Map<String, dynamic>.from(raw));
        } else {
          _markLyricsAttemptedForPath(index, item.path);
        }
      case PlaybackSourceType.networkUrl:
        _markLyricsAttemptedForPath(index, item.path);
    }
  }

  void _markLyricsAttemptedForPath(int index, String path) {
    if (index < 0 ||
        index >= state.queue.length ||
        state.queue[index].path != path) {
      return;
    }
    _markLyricsAttempted(index);
    unawaited(_persistSession());
  }

  void _markLyricsAttempted(int index) {
    if (index < 0 || index >= state.queue.length) return;
    final queue = [...state.queue];
    queue[index] = queue[index].copyWith(lyricsAttempted: true);
    state = state.copyWith(
      queue: queue,
      current: index == state.queueIndex ? queue[index] : state.current,
    );
  }

  String _friendlyPlaybackError(Object error) {
    if (error is _LocalPlaybackException) return error.message;
    var message = error.toString().replaceFirst('Exception: ', '').trim();
    if (message.contains('Source error') ||
        message.contains('PlayerException')) {
      message = '音频地址无法播放或已经失效';
    }
    return message.isEmpty ? '歌曲播放失败，请重试' : message;
  }

  bool _isUnsupportedQualityError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('不支持') &&
        (message.contains('音质') || message.contains('quality'));
  }

  /// 根据“播放失败后”设置决定是停在当前歌曲还是自动尝试下一首。
  /// 队列只有一首歌时不自动重试，避免同一首失败歌曲无限循环。
  Future<void> _handlePlaybackFailure(
    Object error, {
    required int requestId,
    required int queueIndex,
  }) async {
    if (requestId != _playRequestId ||
        queueIndex < 0 ||
        queueIndex >= state.queue.length) {
      return;
    }
    // errorStream 与 play() Future 可能同时报告同一个错误，避免重复切歌。
    final failureKey = '$requestId:$queueIndex';
    if (_lastFailureKey == failureKey) return;

    // 有些插件会先返回一个看似有效的 URL，真正开始播放时才返回
    // “不支持 super 音质”。这类错误无法在解析阶段发现，先把跨歌曲
    // 保存的偏好降到 320k 并重试当前歌曲，避免误跳到下一首。
    final currentQuality = state.currentQuality.trim();
    if (_isUnsupportedQualityError(error) &&
        currentQuality.isNotEmpty &&
        currentQuality.toLowerCase() != '320k') {
      _lastFailureKey = failureKey;
      await _ref
          .read(settingsProvider.notifier)
          .setOnlineDefaultQuality('320k');
      if (requestId != _playRequestId || state.queueIndex != queueIndex) {
        return;
      }
      await _playAt(queueIndex);
      return;
    }
    _lastFailureKey = failureKey;
    _consecutivePlaybackFailures += 1;
    // 无网络或在线音源获取失败：优先在本地（下载目录、本地曲库）找
    // 同名歌曲替代，找到则直接自动切换播放并弹通知提示（不再弹“本地
    // 替代”提案询问），找不到才按播放失败设置停止或跳下一首。
    QueueItem? failedItem;
    if (queueIndex < state.queue.length) {
      failedItem = state.queue[queueIndex];
      final localReplacement = await _findLocalReplacement(failedItem);
      if (requestId != _playRequestId) return;
      if (localReplacement != null) {
        await _autoRelinkToLocal(
          queueIndex: queueIndex,
          original: failedItem,
          replacement: localReplacement,
        );
        return;
      }
    }
    final settings = _ref.read(settingsProvider).valueOrNull;
    final retryLimit = settings?.playbackRetryCount ?? 1;
    final switchLimit = settings?.playbackSwitchSourceCount ?? 2;
    final priority = settings?.playbackFailurePriority ??
        kDefaultPlaybackFailurePriority;
    state = state.copyWith(
      isPlaying: false,
      isLoading: false,
      errorMessage: _friendlyPlaybackError(error),
    );
    // 优先重试：网络抖动导致的偶发失败，直接重试当前歌（原音源）。
    if (failedItem != null && _failureStrategyPath != failedItem.path) {
      _failureStrategyPath = failedItem.path;
      _playbackRetryAttempts = 0;
      _playbackSwitchAttempts = 0;
      _switchAttemptedPluginIds.clear();
      _qualityDropAttemptedTiers.clear();
    }
    if (retryLimit > 0 && _playbackRetryAttempts < retryLimit) {
      _playbackRetryAttempts += 1;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (requestId != _playRequestId || state.queueIndex != queueIndex) {
        return;
      }
      await _playAt(queueIndex);
      return;
    }
    // 策略优先级：降低音质 → 换源播放 → 跳下一首 → 暂停播放（可排序）。
    for (final step in priority) {
      switch (step) {
        case PlaybackFailureStep.lowerQuality:
          if (failedItem == null ||
              playbackSourceTypeFor(failedItem) != PlaybackSourceType.plugin) {
            break;
          }
          final nextTier = _nextLowerQualityTier();
          if (nextTier == null) break;
          _qualityDropAttemptedTiers.add(nextTier);
          if (requestId != _playRequestId || state.queueIndex != queueIndex) {
            return;
          }
          _publishNotice(
            '当前音质播放失败，自动降到「${qualityDisplayLabel(nextTier)}」重试',
          );
          // 改默认音质后重播当前歌；再失败会回到本策略链逐档下降
          //（已试档位会被 _qualityDropAttemptedTiers 跳过）。
          await _ref
              .read(settingsProvider.notifier)
              .setOnlineDefaultQuality(nextTier);
          if (requestId != _playRequestId || state.queueIndex != queueIndex) {
            return;
          }
          await _playAt(queueIndex);
          return;
        case PlaybackFailureStep.switchSource:
          if (failedItem == null ||
              switchLimit <= 0 ||
              _playbackSwitchAttempts >= switchLimit) {
            break;
          }
          _playbackSwitchAttempts += 1;
          final currentPluginId = failedItem.pluginId;
          if (currentPluginId != null && currentPluginId.isNotEmpty) {
            _switchAttemptedPluginIds.add(currentPluginId);
          }
          try {
            final replacement = await _findPluginReplacement(
              failedItem,
              excludePluginIds: _switchAttemptedPluginIds,
            );
            if (replacement == null) break;
            if (requestId != _playRequestId ||
                queueIndex < 0 ||
                queueIndex >= state.queue.length ||
                state.queue[queueIndex].path != failedItem.path) {
              return;
            }
            _publishNotice('音源不可用，已自动换源到「${replacement.pluginName}」');
            await switchSource(failedItem.path, replacement.item);
            return;
          } catch (_) {
            // 换源失败继续尝试下一档策略。
          }
        case PlaybackFailureStep.playNext:
          if (state.queue.length <= 1) break;
          // 连败熔断：连续多首失败（后端限流/断网/音源整体故障）时继续
          // 自动切下一首只会把请求风暴扩散到整张队列，停止自动切换，
          // 保留最后一首的错误提示等用户手动处理。
          if (_consecutivePlaybackFailures >= _maxConsecutivePlaybackFailures) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 80));
          if (requestId != _playRequestId || state.queueIndex != queueIndex) {
            return;
          }
          final nextIndex = _pickNextIndex();
          if (nextIndex < 0 || nextIndex == queueIndex) break;
          await _playAt(nextIndex);
          return;
        case PlaybackFailureStep.pause:
          return;
      }
    }
  }

  /// 起播成功后清空播放失败策略计数（重试/换源/已试音源/降音质档位）。
  void _resetFailureStrategyCounters() {
    _failureStrategyPath = '';
    _playbackRetryAttempts = 0;
    _playbackSwitchAttempts = 0;
    _switchAttemptedPluginIds.clear();
    _qualityDropAttemptedTiers.clear();
  }

  /// “降低音质”步骤：从当前档位往下（qualityTierRank）找第一个尚未
  /// 尝试过的更低标准档；已到最低档或全部试过返回 null（本步骤放弃，
  /// 落到策略列表的下一档）。
  String? _nextLowerQualityTier() {
    const tiersByRankDesc = <String>[
      'master',
      'atmos_plus',
      'atmos',
      'dolby',
      'vinyl',
      'hires',
      'flac24bit',
      'flac',
      '320k',
      '192k',
      '128k',
      '96k',
    ];
    final currentQuality = state.currentQuality.trim();
    var currentRank = qualityTierRank(
      currentQuality.isEmpty ? '320k' : currentQuality,
    );
    for (final tier in tiersByRankDesc) {
      if (qualityTierRank(tier) >= currentRank) continue;
      if (_qualityDropAttemptedTiers.contains(tier)) continue;
      return tier;
    }
    return null;
  }

  Future<void> _addToRecentHistory(QueueItem item) async {
    try {
      await rememberRecentSongSnapshot(
        RecentSongSnapshot(
          path: item.path,
          title: item.title,
          artist: item.artist,
          album: item.album,
          durationMs: item.durationMs,
          playedAt: DateTime.now().millisecondsSinceEpoch,
          pluginId: item.pluginId,
          pluginData: item.pluginData,
          coverUrl: item.coverUrl,
        ),
      );
    } catch (_) {
      // 快照写入失败时，本地歌曲仍可依靠曲库记录显示。
    }

    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      await statsAddToHistory(dbPath: dbPath, songPath: item.path);
      _ref.read(recentHistoryRevisionProvider.notifier).state++;
    } catch (_) {
      // 播放历史属于附加能力，数据库异常时保持播放器可用。
    }
  }

  void _beginStatsSession(QueueItem item, {int initialPositionMs = 0}) {
    _statsSessionPath = item.path;
    // Dart 的 int 和 SQLite 的 INTEGER 都是 64 位（在 Android/iOS 上不会
    // 因播放超过 2^31 毫秒而溢出）。旧代码把恢复位置硬限制在 2^31 ms，
    // 恰好约 35.8 分钟，长时间播放/恢复时会造成排行榜时长停止累计。
    _statsRecordedPositionMs = initialPositionMs < 0 ? 0 : initialPositionMs;
    _statsPlayEventRecorded = false;
    // 新会话重新起算墙钟窗口。
    _statsLastFlushElapsedMs = _statsWallClock.elapsedMilliseconds;
  }

  int _statsPositionMs(PlaybackState snapshot) {
    var positionMs = (snapshot.position * 1000).round();
    // 只有播放器音源已明确属于当前切歌请求时才读取原生进度。切歌/换音质
    // 的异步过程中，just_audio 可能暂时仍返回上一首的 position，直接取
    // max 会把旧歌曲的大段进度误记到新歌曲，进而放大排行榜时长。
    if (snapshot.current?.path == state.current?.path &&
        _preparedSourceRequestId == _playRequestId) {
      final playerPositionMs = _player.position.inMilliseconds;
      final statePositionMs = (snapshot.position * 1000).round();
      // positionStream 最多只会滞后约一个采样周期；差距过大通常意味着
      // 原生播放器仍在切源或刚刚切换，宁可等待下一次刷写也不采用它。
      if (playerPositionMs >= statePositionMs &&
          playerPositionMs - statePositionMs <= 2000) {
        positionMs = max(positionMs, playerPositionMs);
      }
    }
    final video = VideoPlaybackSession.controller;
    if (video != null && VideoPlaybackSession.isFor(snapshot.current?.path)) {
      positionMs = max(positionMs, video.value.position.inMilliseconds);
    }
    final item = snapshot.current;
    final durationMs = item != null && item.durationMs > 0
        ? item.durationMs
        : (snapshot.duration * 1000).round();
    if (durationMs > 0) positionMs = min(positionMs, durationMs);
    return max(0, positionMs);
  }

  void _enqueueStatsChunk(
    QueueItem item,
    PlaybackState snapshot,
    int listenedMs,
    bool countAsPlay,
  ) {
    if (listenedMs <= 0) return;
    final payload = jsonEncode({
      'songPath': item.path,
      'listenedMs': listenedMs,
      'durationMs': item.durationMs > 0
          ? item.durationMs
          : (snapshot.duration * 1000).round(),
      'title': item.title,
      'artist': item.artist,
      'album': item.album,
      'countAsPlay': countAsPlay,
    });
    _statsWriteChain = _statsWriteChain.then((_) async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        await statsRecordPlay(dbPath: dbPath, payloadJson: payload);
      } catch (_) {
        // 统计失败不影响播放；下一次刷写继续尝试记录新增时长。
      }
    });
  }

  /// 将当前会话相对上次刷写的新增时长写入统计。
  void _flushPlaybackStats(PlaybackState snapshot) {
    final item = snapshot.current;
    if (item == null) return;
    // 先结算墙钟窗口：无论本次走哪个分支（含早退），下一次结算的
    // 上限都从现在重新起算。上限按最高 3 倍速 + 15s 容差估算——
    // 定时刷写周期为 15s，正常增量远小于上限，不会被误伤。
    final nowElapsedMs = _statsWallClock.elapsedMilliseconds;
    final wallCapMs = (nowElapsedMs - _statsLastFlushElapsedMs) * 3 + 15000;
    _statsLastFlushElapsedMs = nowElapsedMs;
    // 已暂停且没有正在播放的原生音频时，不会产生新的听歌时长。过滤这类
    // 调用可避免暂停期间残留的 position 被重复结算。
    if (!snapshot.isPlaying && !_player.playing) return;
    if (_statsSessionPath != item.path) {
      _beginStatsSession(item);
    }
    final positionMs = _statsPositionMs(snapshot);
    if (positionMs < 500) return;

    // just_audio 的单曲循环可能在原生层直接把 position 从末尾跳回 0，
    // 不一定经过 ProcessingState.completed。先补齐上一轮的尾部，再开启
    // 新一轮会话，避免循环播放时后续时长全部被当成负增量丢弃。
    if (positionMs + 1000 < _statsRecordedPositionMs) {
      final durationMs = item.durationMs > 0
          ? item.durationMs
          : (snapshot.duration * 1000).round();
      // 尾部时长同样受墙钟钳制：时长元数据错误（在线源可能返回数小时）
      // 或脏回跳（熄屏恢复进度归零）时，避免一次结算记出数小时。
      final tailMs = min(
        max(0, durationMs - _statsRecordedPositionMs),
        wallCapMs,
      );
      if (tailMs > 0) {
        _enqueueStatsChunk(item, snapshot, tailMs, !_statsPlayEventRecorded);
      }
      _statsRecordedPositionMs = positionMs;
      _statsPlayEventRecorded = false;
      return;
    }

    final deltaMs = min(positionMs - _statsRecordedPositionMs, wallCapMs);
    if (deltaMs <= 0) return;

    _statsRecordedPositionMs = positionMs;
    final countAsPlay = !_statsPlayEventRecorded;
    _statsPlayEventRecorded = true;
    _enqueueStatsChunk(item, snapshot, deltaMs, countAsPlay);
  }

  void _flushCurrentPlaybackStats() {
    _flushPlaybackStats(state);
  }

  Future<void> setCurrentLyrics(
    String lyrics, {
    RememberedLyricsAssociation? association,
  }) async {
    final index = state.queueIndex;
    if (lyrics.trim().isEmpty || index < 0 || index >= state.queue.length) {
      return;
    }
    final item = state.queue[index];
    _updateQueueLyrics(index, lyrics);
    await _saveRememberedLyrics(item.path, lyrics);
    if (association != null) {
      await _saveRememberedLyricsAssociation(
        item.path,
        association,
        item.lyricsRaw ?? '',
      );
    }
    await _persistSession();
  }

  /// 取消当前歌曲的手动关联歌词，恢复关联前保存的默认歌词，并重新探测歌词。
  Future<void> clearCurrentLyricsAssociation() async {
    final item = state.current;
    if (item == null) return;
    final original = await _removeRememberedLyricsAssociation(item.path);
    final index = state.queueIndex;
    if (index < 0 || index >= state.queue.length) return;
    final restoredLyrics = original?.trim() ?? '';
    final queue = [...state.queue];
    queue[index] = item.copyWith(
      lyricsRaw: restoredLyrics.isEmpty ? null : restoredLyrics,
      clearLyricsRaw: restoredLyrics.isEmpty,
      lyricsAttempted: restoredLyrics.isNotEmpty,
    );
    state = state.copyWith(queue: queue, current: queue[index]);
    if (playbackSourceTypeFor(item) == PlaybackSourceType.localFile &&
        !item.path.startsWith('content://') &&
        !item.path.startsWith('remote://')) {
      try {
        final sidecarPath = p.setExtension(item.path, '.lrc');
        if (restoredLyrics.isEmpty) {
          final sidecar = File(sidecarPath);
          if (await sidecar.exists()) await sidecar.delete();
        } else {
          await saveSongLyrics(
            path: item.path,
            lyrics: restoredLyrics,
            source: LyricsStorageSource.sidecar,
          );
        }
      } catch (_) {
        // 恢复歌词文件失败时仍保留内存中的默认歌词，不能影响播放。
      }
    }
    await _persistSession();
    if (restoredLyrics.isEmpty) {
      await ensureCurrentLyricsChecked();
    }
  }

  Future<void> setCurrentQuality(String quality) async {
    final normalized = quality.trim();
    if (normalized.isEmpty) return;
    await _ref
        .read(settingsProvider.notifier)
        .setOnlineDefaultQuality(normalized);
    final item = state.current;
    final index = state.queueIndex;
    if (item == null ||
        index < 0 ||
        playbackSourceTypeFor(item) == PlaybackSourceType.localFile) {
      return;
    }

    // 视频播放期间切换音质时，先结束临时视频会话并退出媒体桥接。
    // 否则视频画面自带的伴音会与新解析的音频流（且已恢复音量）同时
    // 播放，出现两路声音。
    if (VideoPlaybackSession.controller != null) {
      await VideoPlaybackSession.stopForTrackAction();
      await disableVideoMediaBridge();
    }

    final requestId = ++_playRequestId;
    _preparedSourceRequestId = null;
    final position = state.position;
    final wasPlaying = state.isPlaying;
    _manualPause = true;
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      await _player.stop();
      await _prepareAudioSource(
        item,
        queueIndex: index,
        preferredQualityOverride: normalized,
        requestId: requestId,
      );
      if (requestId != _playRequestId) return;
      _preparedSourceRequestId = requestId;
      _consecutivePlaybackFailures = 0;
      _resetFailureStrategyCounters();
      await _player.setVolume(_ref.read(volumeProvider));
      await seek(position);
      _manualPause = !wasPlaying;
      if (wasPlaying) _startPlayback(requestId, item.path);
      if (requestId == _playRequestId) {
        state = state.copyWith(
          isLoading: false,
          errorMessage: null,
          currentQuality: normalized,
        );
      }
    } catch (error, stackTrace) {
      if (requestId != _playRequestId) return;
      debugPrint('切换播放音质失败：$error');
      debugPrintStack(stackTrace: stackTrace);
      state = state.copyWith(
        isPlaying: false,
        isLoading: false,
        errorMessage: _friendlyPlaybackError(error),
      );
    }
    unawaited(_persistSession());
  }

  Future<PlaybackDownloadSource> resolveCurrentDownloadSource(
    String quality,
  ) async {
    final item = state.current;
    if (item == null) throw Exception('当前没有正在播放的歌曲');
    return resolveDownloadSourceFor(item, quality);
  }

  /// Resolve a downloadable source without changing the current playback item.
  /// This is used by playlist batch downloads so downloading does not interrupt playback.
  Future<PlaybackDownloadSource> resolveDownloadSourceFor(
    QueueItem item,
    String quality,
  ) async {
    final preferredQuality = quality.trim().isEmpty ? '320k' : quality.trim();
    switch (playbackSourceTypeFor(item)) {
      case PlaybackSourceType.plugin:
        final data = item.pluginData;
        if (data == null || data.isEmpty) throw Exception('歌曲缺少插件元数据');
        final plugins = await _ref.read(enabledMusicPluginsProvider.future);
        final plugin = plugins
            .where((candidate) => candidate.id == item.pluginId)
            .firstOrNull;
        if (plugin == null) throw Exception('歌曲所属插件已停用或删除');
        final source = await _ref
            .read(pluginRuntimeProvider)
            .resolveMediaSource(
              plugin,
              data,
              preferredQuality: preferredQuality,
            );
        return PlaybackDownloadSource(url: source.url, headers: source.headers);
      case PlaybackSourceType.lx:
        final rawLx = item.pluginData?['lx'];
        if (rawLx is! Map) throw Exception('识曲结果缺少播放元数据');
        final plugins = await _ref.read(enabledMusicPluginsProvider.future);
        // 洛雪插件自有歌曲只走洛雪命名空间，下载不并入 MusicFree 插件。
        final owned = await _resolveOwnedLxSource(
          item,
          Map<String, dynamic>.from(rawLx),
          plugins,
          preferredQuality: preferredQuality,
        );
        if (owned != null) {
          return PlaybackDownloadSource(
            url: owned.url,
            headers: owned.headers,
          );
        }
        final cached = await _resolveCachedRecognizedPlugin(
          item,
          plugins,
          preferredQuality: preferredQuality,
        );
        final source =
            cached ??
            await _firstRecognizedSource([
              _resolveRecognizedWithPlugins(
                item,
                plugins,
                preferredQuality: preferredQuality,
              ),
              _resolveRecognizedWithLx(
                Map<String, dynamic>.from(rawLx),
                plugins: plugins,
                preferredQuality: preferredQuality,
              ),
            ]).timeout(const Duration(seconds: 30), onTimeout: () => null);
        if (source == null) throw Exception('无法获取歌曲下载地址');
        return PlaybackDownloadSource(url: source.url, headers: source.headers);
      case PlaybackSourceType.networkUrl:
        return PlaybackDownloadSource(url: item.path);
      case PlaybackSourceType.localFile:
        throw Exception('本地歌曲无需重复下载');
    }
  }

  Future<List<PluginLyricsOption>> findCurrentLyricsFromPlugins({
    String? query,
  }) async {
    final options = <PluginLyricsOption>[];
    await for (final progress in findCurrentLyricsFromPluginsProgress(
      query: query,
    )) {
      options.addAll(progress.options);
    }
    options.sort((a, b) => a.pluginName.compareTo(b.pluginName));
    return options;
  }

  Stream<PluginLyricsSearchProgress> findCurrentLyricsFromPluginsProgress({
    String? query,
  }) {
    late final StreamController<PluginLyricsSearchProgress> controller;
    var cancelled = false;
    controller = StreamController<PluginLyricsSearchProgress>(
      onCancel: () => cancelled = true,
    );

    Future<void> search() async {
      try {
        final item = state.current;
        if (item == null) return;
        final keyword =
            (query ??
                    createDefaultPluginLyricsSearchQuery(
                      item.title,
                      item.artist,
                    ))
                .trim();
        if (keyword.isEmpty) return;
        final plugins = await _ref.read(enabledMusicPluginsProvider.future);
        if (plugins.isEmpty) return;
        final runtime = _ref.read(pluginRuntimeProvider);
        var completed = 0;
        if (!cancelled && !controller.isClosed) {
          controller.add(
            PluginLyricsSearchProgress(
              options: const [],
              completedPlugins: 0,
              totalPlugins: plugins.length,
            ),
          );
        }

        Future<void> resolvePlugin(EnabledMusicPlugin plugin) async {
          List<PluginSearchSong> songs;
          try {
            songs = await runtime
                .search(plugin, keyword)
                .timeout(const Duration(seconds: 8));
          } catch (_) {
            songs = const [];
          }
          completed++;
          if (cancelled || controller.isClosed) return;
          controller.add(
            PluginLyricsSearchProgress(
              options: buildPluginLyricsSearchOptions(plugin, songs),
              completedPlugins: completed,
              totalPlugins: plugins.length,
            ),
          );
        }

        await Future.wait(plugins.map(resolvePlugin));
      } catch (error, stackTrace) {
        if (!cancelled && !controller.isClosed) {
          controller.addError(error, stackTrace);
        }
      } finally {
        if (!cancelled && !controller.isClosed) await controller.close();
      }
    }

    controller.onListen = () => unawaited(search());
    return controller.stream;
  }

  Future<PluginLyricsOption> loadLyricsForOption(
    PluginLyricsOption option,
  ) async {
    if (option.lyrics.trim().isNotEmpty) return option;
    final plugins = await _ref.read(enabledMusicPluginsProvider.future);
    final plugin = plugins
        .where((candidate) => candidate.id == option.pluginId)
        .firstOrNull;
    if (plugin == null) throw Exception('歌词插件已停用或删除');
    final lyrics = await _ref
        .read(pluginRuntimeProvider)
        .getLyrics(plugin, option.rawData)
        .timeout(const Duration(seconds: 20));
    if (lyrics.trim().isEmpty) throw Exception('该搜索结果没有返回歌词');
    return option.copyWith(lyrics: lyrics);
  }

  void setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerTicker?.cancel();
    _sleepTimerTicker = null;
    if (duration == null || duration <= Duration.zero) {
      state = state.copyWith(sleepTimerEndsAt: null);
      return;
    }
    if (!isValidSleepTimerDuration(duration)) {
      throw ArgumentError.value(duration, 'duration', '定时时长必须在 30 秒至 12 小时之间');
    }
    final endsAt = DateTime.now().add(duration);
    state = state.copyWith(sleepTimerEndsAt: endsAt);
    // 定时关闭菜单会直接展示剩余时长。每秒推送一次状态，
    // 让弹窗右侧文字与实际倒计时同步，而不必关闭后重新打开。
    _sleepTimerTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (state.sleepTimerEndsAt != endsAt) return;
      if (DateTime.now().isBefore(endsAt)) {
        state = state.copyWith(sleepTimerEndsAt: endsAt);
      }
    });
    _sleepTimer = Timer(duration, () {
      _sleepTimer = null;
      _sleepTimerTicker?.cancel();
      _sleepTimerTicker = null;
      state = state.copyWith(sleepTimerEndsAt: null);
      _manualPause = true;
      _flushCurrentPlaybackStats();
      unawaited(_player.pause());
    });
  }

  Future<void> toggle() async {
    if (state.current == null) return;
    final video = VideoPlaybackSession.isFor(state.current?.path)
        ? VideoPlaybackSession.controller
        : null;
    if (video != null) {
      if (video.value.isPlaying) {
        await video.pause();
      } else {
        await video.play();
      }
      VideoPlaybackSession.progressChanged();
      return;
    }
    if (state.errorMessage != null && state.queueIndex >= 0) {
      await _playAt(state.queueIndex);
      return;
    }
    try {
      if (state.isPlaying) {
        _manualPause = true;
        _flushCurrentPlaybackStats();
        await _player.pause();
      } else {
        // 音源未就绪（恢复会话失败、上首播放失败等）时不能直接
        // _startPlayback：_preparedSourceRequestId 校验不通过会静默返回，
        // 用户看到「点播放没反应」，形同卡死。此时重新走完整切歌链。
        if (_preparedSourceRequestId != _playRequestId) {
          await _playAt(state.queueIndex);
          return;
        }
        _manualPause = false;
        _startPlayback(_playRequestId, state.current!.path);
      }
    } catch (error) {
      state = state.copyWith(
        isPlaying: false,
        isLoading: false,
        errorMessage: _friendlyPlaybackError(error),
      );
    }
  }

  /// 播放详情页临时播放视频时暂停音频，但保留当前音源和进度，
  /// 关闭视频后可以无缝恢复原歌曲。
  Future<bool> pauseForVideo() async {
    final wasPlaying = _player.playing || state.isPlaying;
    _manualPause = true;
    _flushCurrentPlaybackStats();
    if (_player.playing) await _player.pause();
    return wasPlaying;
  }

  Future<void> resumeAfterVideo() async {
    final current = state.current;
    if (current == null || state.errorMessage != null) return;
    await _player.setVolume(_ref.read(volumeProvider));
    _manualPause = false;
    unawaited(_startPlayback(_playRequestId, current.path));
  }

  /// 设置当前播放速度。音频和 B 站视频共用同一速度状态，切换视频或
  /// 关闭视频后仍保持用户刚刚选择的倍速。实际音频速度还要乘上音效页
  /// 的连续变速系数（见 [_combinedEffectsSpeed]），档位值只作为 UI 真源。
  Future<void> setPlaybackSpeed(double speed) async {
    const supported = <double>[0.5, 0.8, 1.0, 1.5, 2.0];
    final normalized = supported.reduce(
      (a, b) => (a - speed).abs() <= (b - speed).abs() ? a : b,
    );
    state = state.copyWith(playbackSpeed: normalized);
    try {
      await _player.setSpeed(_combinedEffectsSpeed());
      final video = VideoPlaybackSession.isFor(state.current?.path)
          ? VideoPlaybackSession.controller
          : null;
      if (video != null) await video.setPlaybackSpeed(normalized);
    } catch (error) {
      debugPrint('设置播放倍速失败：$error');
    }
  }

  Future<void> seek(double secs) async {
    final targetMs = max(0, (secs * 1000).round());
    _flushCurrentPlaybackStats();
    await _player.seek(Duration(milliseconds: targetMs));
    if (_statsSessionPath == state.current?.path) {
      _statsRecordedPositionMs = targetMs;
    }
  }

  Future<void> next() async {
    if (VideoPlaybackSession.controller != null) {
      _flushCurrentPlaybackStats();
      await VideoPlaybackSession.stopForTrackAction();
      await disableVideoMediaBridge();
    }
    final i = _pickNextIndex();
    if (i >= 0) await _playAt(i);
  }

  Future<void> playIndex(int index) => _playAt(index);

  Future<void> previous() async {
    final video = VideoPlaybackSession.isFor(state.current?.path)
        ? VideoPlaybackSession.controller
        : null;
    if (video != null) {
      final videoPosition = video.value.position.inMilliseconds / 1000.0;
      if (max(state.position, videoPosition) > 3) {
        _flushCurrentPlaybackStats();
        await video.seekTo(Duration.zero);
        await _player.seek(Duration.zero);
        if (_statsSessionPath == state.current?.path) {
          _statsRecordedPositionMs = 0;
        }
        state = state.copyWith(position: 0);
        VideoPlaybackSession.progressChanged();
        return;
      }
      await VideoPlaybackSession.stopForTrackAction();
      await disableVideoMediaBridge();
    }
    // 常见播放器行为：当前歌曲已经播放超过几秒时，第一次点“上一首”
    // 先回到本曲开头；只有再次点击才切换到队列上一首。不要只依赖
    // positionStream 的状态值，它在切歌、后台播放或快速点击时可能滞后。
    final playerPosition = _player.position.inMilliseconds / 1000.0;
    final position = max(state.position, playerPosition);
    if (position > 3) {
      await seek(0);
      // 立即同步状态，避免用户快速再次点击时仍被旧进度判定为重播。
      state = state.copyWith(position: 0);
      return;
    }
    final n = state.queue.length;
    if (n == 0) return;
    final i = state.queueIndex <= 0 ? n - 1 : state.queueIndex - 1;
    await _playAt(i);
  }

  Future<void> cyclePlayMode() async {
    final next = (normalizePlayMode(state.playMode) + 1) % 3;
    if (next == 2 && state.queue.length > 1) {
      final current = state.current;
      final queue = List<QueueItem>.of(state.queue);
      final currentIndex = current == null
          ? -1
          : queue.indexWhere((item) => item.path == current.path);
      if (currentIndex >= 0) {
        final selected = queue.removeAt(currentIndex);
        _shuffleInPlace(queue);
        queue.insert(0, selected);
      } else {
        _shuffleInPlace(queue);
      }
      state = state.copyWith(
        playMode: next,
        queue: queue,
        queueIndex: current == null ? state.queueIndex : 0,
      );
    } else {
      state = state.copyWith(playMode: next);
    }
    await _player.setLoopMode(audioLoopModeForPlayMode(next));
    await _ref.read(settingsProvider.notifier).setPlayMode(next);
    unawaited(_persistSession());
    // 通知栏「播放模式」按钮图标随新模式刷新（列表循环/单曲循环/随机）。
    _refreshNotificationCustomControls();
  }

  Future<void> _handleTrackEndOnce() async {
    if (_handlingTrackEnd) return;
    _handlingTrackEnd = true;
    try {
      await _onTrackEnd();
    } finally {
      _handlingTrackEnd = false;
    }
  }

  Future<void> _onTrackEnd() async {
    if (normalizePlayMode(state.playMode) == 1) {
      // 单曲循环：重播当前曲。
      await seek(0);
      _statsPlayEventRecorded = false;
      final current = state.current;
      if (current != null) {
        _manualPause = false;
        _startPlayback(_playRequestId, current.path);
      }
      return;
    }
    final next = _pickNextIndex();
    if (next < 0) {
      await _player.pause();
      if (state.current != null) await seek(0);
      return;
    }
    await _playAt(next);
  }

  int _pickNextIndex() {
    final n = state.queue.length;
    if (n == 0) return -1;
    if (state.queueIndex < 0) return 0;
    return (state.queueIndex + 1) % n; // 顺序：列表循环环绕
  }

  Future<void> _persistSession() async {
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final settings = _ref.read(settingsProvider).valueOrNull;
      if (state.current == null) return;
      final sessionJson = jsonEncode(
        buildPlaybackSessionPayload(
          state: state,
          volume: settings?.volume ?? 1.0,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await savePlaybackSession(dbPath: dbPath, sessionJson: sessionJson);
    } catch (_) {
      // 会话保存失败不能中断或结束正在播放的歌曲。
    }
  }

  @override
  void dispose() {
    _flushCurrentPlaybackStats();
    WidgetsBinding.instance.removeObserver(this);
    _bridgeInstallTimer?.cancel();
    VideoPlaybackSession.progressRevision.removeListener(
      _syncVideoPlaybackState,
    );
    _sleepTimer?.cancel();
    _sleepTimerTicker?.cancel();
    _statsFlushTimer?.cancel();
    _desktopLyricsSyncTimer?.cancel();
    _audioInterruptionSub?.cancel();
    _becomingNoisySub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}

class _LocalPlaybackException implements Exception {
  const _LocalPlaybackException(this.message);

  final String message;

  @override
  String toString() => message;
}

Map<String, dynamic> buildPlaybackSessionPayload({
  required PlaybackState state,
  required double volume,
  required int updatedAt,
}) {
  final item = state.current;
  final queueMeta = <String, dynamic>{
    for (final queueItem in state.queue)
      if (playbackSourceTypeFor(queueItem) != PlaybackSourceType.localFile)
        queueItem.path: {
          'title': queueItem.title,
          'artist': queueItem.artist,
          'album': queueItem.album,
          'durationMs': queueItem.durationMs,
          'pluginId': queueItem.pluginId,
          'pluginData': queueItem.pluginData,
          'coverUrl': queueItem.coverUrl,
          'lyricsRaw': queueItem.lyricsRaw,
          'lyricsAttempted': queueItem.lyricsAttempted,
        },
  };
  return {
    'currentSongPath': item?.path,
    'playQueuePaths': state.queue.map((q) => q.path).toList(),
    'sourceSongPaths': const <String>[],
    'playMode': normalizePlayMode(state.playMode),
    'volume': volume,
    'currentPositionSecs': state.position,
    'isPlaying': state.isPlaying,
    'sessionQualityOverride': state.currentQuality,
    'queueSongMeta': queueMeta,
    // 记录写入时的歌词转换版本，恢复时版本不一致则作废旧歌词缓存。
    'lyricsFormatVersion': _sessionLyricsFormatVersion,
    'updatedAt': updatedAt,
  };
}

/// 音量（与设置联动）。
final volumeProvider = Provider<double>((ref) {
  return ref.watch(settingsProvider.select((s) => s.valueOrNull?.volume)) ??
      1.0;
});

/// 音量键调节应用内音量后的最新值（仅音量键通道写入）。应用根节点
/// 监听它显示“应用音量 xx%”的 OSD 反馈——音量键被拦截时系统音量
/// 面板不会出现，需要自己提示当前音量。
final volumeKeyOscProvider = StateProvider<double?>((ref) => null);

/// 最近播放写入成功后的修订号，让已打开的最近播放页在异步落库完成后刷新。
final recentHistoryRevisionProvider = StateProvider<int>((ref) => 0);

final playerProvider = StateNotifierProvider<PlayerNotifier, PlaybackState>((
  ref,
) {
  return PlayerNotifier(ref);
});
