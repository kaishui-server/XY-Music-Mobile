import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/db_path.dart';
import '../core/settings.dart';
import '../plugins/plugin_runtime.dart';
import '../recent/recent_store.dart';
import '../rust/api.dart';
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

  QueueItem copyWith({String? lyricsRaw, bool? lyricsAttempted}) => QueueItem(
    path: path,
    title: title,
    artist: artist,
    album: album,
    durationMs: durationMs,
    pluginId: pluginId,
    pluginData: pluginData,
    coverUrl: coverUrl,
    lyricsRaw: lyricsRaw ?? this.lyricsRaw,
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
    );
  }
}

/// 应用播放模式与 just_audio 原生循环模式的映射。
/// 顺序和随机由队列逻辑切歌，只有单曲循环交给播放器原生处理。
LoopMode audioLoopModeForPlayMode(int playMode) =>
    normalizePlayMode(playMode) == 1 ? LoopMode.one : LoopMode.off;

class PlayerNotifier extends StateNotifier<PlaybackState> {
  PlayerNotifier(this._ref) : super(const PlaybackState()) {
    VideoPlaybackSession.progressRevision.addListener(_syncVideoPlaybackState);
    _ref.listen<AsyncValue<AppSettings>>(settingsProvider, (previous, next) {
      final allowOtherAudio =
          next.valueOrNull?.playOtherAudioWithoutInterruption ?? false;
      unawaited(_configureAudioSession(allowOtherAudio));
      unawaited(_syncDesktopLyrics());
    });
    _init();
  }

  final Ref _ref;
  // 音频中断由本类按设置处理：开启“不中断”时忽略其他应用的音频焦点
  // 中断，避免 just_audio 默认行为直接暂停当前歌曲。
  final AudioPlayer _player = AudioPlayer(handleInterruptions: false);
  final Random _rand = Random();
  StreamSubscription<Duration?>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<dynamic>? _stateSub;
  StreamSubscription<AudioInterruptionEvent>? _audioInterruptionSub;
  StreamSubscription<void>? _becomingNoisySub;
  Timer? _sleepTimer;
  Timer? _sleepTimerTicker;
  bool _manualPause = false;
  bool _wasInterrupted = false;
  bool _handlingTrackEnd = false;
  bool _notificationPermissionChecked = false;
  int _playRequestId = 0;
  String? _lastFailureKey;
  int _relinkProposalId = 0;
  int _noticeId = 0;
  DateTime _lastPosPersist = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastVideoPath;
  bool _videoMediaBridgeActive = false;
  bool _syncingVideoMediaBridge = false;
  bool? _expectedAudioPlayingFromVideo;
  DateTime _lastVideoMediaSeek = DateTime.fromMillisecondsSinceEpoch(0);

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
        unawaited(_player.pause());
      });
    }
    // 逐字歌词需要比默认 200ms 更细的进度采样，否则短字会被直接跳过。
    _posSub = _player
        .createPositionStream(
          steps: 3600,
          minPeriod: const Duration(milliseconds: 40),
          maxPeriod: const Duration(milliseconds: 80),
        )
        .listen((p) {
          // B 站视频播放时，just_audio 只是供系统媒体会话使用的静音时钟。
          // 它与视频解码时钟存在微小偏差，不能再反向更新歌词位置，否则在
          // 句子边界会在上一句和下一句之间反复横跳。
          if (_videoMediaBridgeActive &&
              VideoPlaybackSession.isFor(state.current?.path)) {
            return;
          }
          state = state.copyWith(position: p.inMilliseconds / 1000.0);
          _persistPositionDebounced();
          unawaited(_syncDesktopLyrics());
        });
    _durSub = _player.durationStream.listen((d) {
      if (_videoMediaBridgeActive &&
          VideoPlaybackSession.isFor(state.current?.path)) {
        return;
      }
      state = state.copyWith(
        duration: (d ?? Duration.zero).inMilliseconds / 1000.0,
      );
    });
    _stateSub = _player.playerStateStream.listen((ps) {
      final playing = ps.playing;
      final completed = ps.processingState == ProcessingState.completed;
      if (completed ||
          playing != state.isPlaying ||
          (playing && state.isLoading)) {
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
        } else {
          // 通知栏、锁屏或灵动岛直接控制的是 just_audio。视频播放期间
          // 将该操作反向转发给视频控制器，系统按钮才能真正生效。
          unawaited(_applySystemMediaControlToVideo(playing));
        }
      }
      if (completed && !_manualPause && !_videoMediaBridgeActive) {
        unawaited(_handleTrackEndOnce());
      }
      unawaited(_syncDesktopLyrics());
    });
    await _restoreSession();
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
      noBackground: settings.desktopLyricsNoBackground,
      lyricColor: settings.desktopLyricsLyricColor,
      translationColor: settings.desktopLyricsTranslationColor,
      lyricFontSize: settings.desktopLyricsLyricFontSize,
      translationFontSize: settings.desktopLyricsTranslationFontSize,
      backgroundColor: settings.desktopLyricsBackgroundColor,
      backgroundOpacity: settings.desktopLyricsBackgroundOpacity,
      wordEffectMode: settings.lyricWordEffectMode.index,
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
        unawaited(_syncDesktopLyrics());
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
    unawaited(_syncDesktopLyrics());
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
    await _player.setVolume(0);
    await _player.seek(controller.value.position);
    if (controller.value.isPlaying) {
      _manualPause = false;
      _expectedAudioPlayingFromVideo = true;
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
        if (drift > 600) await _player.seek(value.position);
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
        unawaited(_player.pause());
      }
    } else if (shouldPause && _wasInterrupted) {
      _wasInterrupted = false;
      unawaited(_player.play());
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
          lyricsRaw: meta['lyricsRaw']?.toString(),
          lyricsAttempted:
              meta['lyricsAttempted'] == true || meta['lyricsRaw'] != null,
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

      state = state.copyWith(
        queue: items,
        queueIndex: idx,
        current: items[idx],
        playMode: mode,
        position: pos,
        isPlaying: false,
        isLoading: true,
        errorMessage: null,
        currentQuality: restoredQuality,
      );
      await _ref.read(settingsProvider.notifier).setPlayMode(mode);
      try {
        await _player.setLoopMode(audioLoopModeForPlayMode(mode));
        final plugin = await _prepareAudioSource(
          items[idx],
          queueIndex: idx,
          preferredQualityOverride: restoredQuality,
        );
        await _player.setVolume(_ref.read(volumeProvider));
        await seek(pos);
        // 进程重新启动时只恢复队列、歌曲和进度，不自动恢复“正在播放”。
        // 自动播放会在首页首帧同时启动媒体服务、网络音源和高频 UI 更新，
        // 部分旧设备可能因此被系统终止；用户点击播放后再正常继续。
        _manualPause = true;
        state = state.copyWith(isLoading: false, errorMessage: null);
        if (plugin != null && !(state.current?.lyricsAttempted ?? false)) {
          unawaited(
            _loadPluginLyrics(idx, plugin, state.current ?? items[idx]),
          );
        }
        unawaited(_persistSession());
      } catch (error, stackTrace) {
        debugPrint('播放会话恢复失败：$error');
        debugPrintStack(stackTrace: stackTrace);
        state = state.copyWith(
          isPlaying: false,
          isLoading: false,
          errorMessage: _friendlyPlaybackError(error),
        );
      }
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

  Future<void> _playAt(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    final requestId = ++_playRequestId;
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
    if (previous.current != null && previous.position >= .5) {
      unawaited(_recordPlayback(previous));
    }
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
      final plugin = await _prepareAudioSource(item, queueIndex: index);
      await _player.setVolume(_ref.read(volumeProvider));
      // 最近播放是“开始播放”即记录，与桌面端行为一致。统计写入失败不应
      // 阻断音频播放，因此放到独立异步任务中执行。
      unawaited(_addToRecentHistory(item));
      _manualPause = false;
      unawaited(_startPlayback(requestId, item.path));
      if (requestId != _playRequestId) return;
      // play() 已成功发起。不要 await：它只会在暂停、停止或播放结束后完成。
      state = state.copyWith(isLoading: false, errorMessage: null);
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

  Future<EnabledMusicPlugin?> _prepareAudioSource(
    QueueItem item, {
    required int queueIndex,
    String? preferredQualityOverride,
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
        final source = await _ref
            .read(pluginRuntimeProvider)
            .resolveMediaSource(
              plugin,
              pluginData,
              preferredQuality: preferredQuality,
            );
        await _player.setUrl(
          source.url,
          headers: source.headers,
          tag: mediaItem,
        );
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
                preferredQuality: preferredQuality,
              ),
            ]);
        if (source == null) {
          throw Exception('无法获取识曲结果的播放地址，请确认至少启用了一个可用音乐插件');
        }
        await _player.setUrl(
          source.url,
          headers: source.headers,
          tag: mediaItem,
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
        await _player.setUrl(item.path, tag: mediaItem);
        return null;
      case PlaybackSourceType.localFile:
        await _setLocalAudioSource(item.path, mediaItem);
        return null;
    }
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

  Future<({QueueItem item, String pluginName})?> _findPluginReplacement(
    QueueItem original,
  ) async {
    if (original.title.trim().isEmpty ||
        original.artist.trim().isEmpty ||
        original.durationMs <= 0) {
      return null;
    }
    final plugins = await _ref.read(enabledMusicPluginsProvider.future);
    if (plugins.isEmpty) return null;
    final runtime = _ref.read(pluginRuntimeProvider);
    final batches = await Future.wait(
      plugins.map((plugin) async {
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
    QueueItem replacement,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    final associations = <String, dynamic>{};
    try {
      final raw = preferences.getString(_playbackSourceAssociationsKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map) {
        associations.addAll(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    associations[originalPath] = _queueItemToAssociation(replacement);
    await preferences.setString(
      _playbackSourceAssociationsKey,
      jsonEncode(associations, toEncodable: (value) => value.toString()),
    );
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

  Future<void> _setLocalAudioSource(String rawPath, MediaItem mediaItem) async {
    final trimmed = rawPath.trim();
    if (trimmed.startsWith('content://')) {
      try {
        await _player.setAudioSource(
          AudioSource.uri(Uri.parse(trimmed), tag: mediaItem),
        );
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
      await _player.setFilePath(path, tag: mediaItem);
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
    String? preferredQuality,
  }) async {
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
    var text = item.coverUrl?.trim() ?? '';
    if (text.startsWith('//')) text = 'https:$text';
    var uri = Uri.tryParse(text);
    if (uri != null && uri.scheme == 'http' && _coverHostSupportsHttps(uri)) {
      uri = uri.replace(scheme: 'https');
    }
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

  bool _coverHostSupportsHttps(Uri uri) {
    final host = uri.host.toLowerCase();
    return host == 'music.126.net' ||
        host.endsWith('.music.126.net') ||
        host.endsWith('.qq.com') ||
        host.endsWith('.kugou.com') ||
        host.endsWith('.bilivideo.com') ||
        host.endsWith('.hdslb.com');
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
    final playback = _player.play();
    unawaited(_watchPlayback(playback, requestId, itemPath));
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
    unawaited(_syncDesktopLyrics());
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
  /// 标记为已探测，交给详情页提示用户从右上角关联歌词。
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
    _lastFailureKey = failureKey;
    state = state.copyWith(
      isPlaying: false,
      isLoading: false,
      errorMessage: _friendlyPlaybackError(error),
    );
    final action =
        _ref.read(settingsProvider).valueOrNull?.playbackFailureAction ??
        PlaybackFailureAction.playNext;
    if (action != PlaybackFailureAction.playNext || state.queue.length <= 1) {
      return;
    }
    // 让错误状态完成一次发布，随后再切换，避免按钮短暂卡在加载状态。
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (requestId != _playRequestId || state.queueIndex != queueIndex) return;
    final nextIndex = _pickNextIndex();
    if (nextIndex < 0 || nextIndex == queueIndex) return;
    await _playAt(nextIndex);
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

  Future<void> _recordPlayback(PlaybackState snapshot) async {
    final item = snapshot.current;
    if (item == null) return;
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      await statsRecordPlay(
        dbPath: dbPath,
        payloadJson: jsonEncode({
          'songPath': item.path,
          'listenedMs': (snapshot.position * 1000).round(),
          'durationMs': item.durationMs > 0
              ? item.durationMs
              : (snapshot.duration * 1000).round(),
          'title': item.title,
          'artist': item.artist,
          'album': item.album,
        }),
      );
    } catch (_) {
      // 统计失败不影响播放。
    }
  }

  Future<void> setCurrentLyrics(String lyrics) async {
    final index = state.queueIndex;
    if (lyrics.trim().isEmpty || index < 0 || index >= state.queue.length) {
      return;
    }
    final item = state.queue[index];
    _updateQueueLyrics(index, lyrics);
    await _saveRememberedLyrics(item.path, lyrics);
    await _persistSession();
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

    final requestId = ++_playRequestId;
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
      );
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
                preferredQuality: preferredQuality,
              ),
            ]);
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
        await _player.pause();
      } else {
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

  Future<void> seek(double secs) async {
    await _player.seek(Duration(milliseconds: (secs * 1000).round()));
  }

  Future<void> next() async {
    if (VideoPlaybackSession.controller != null) {
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
        await video.seekTo(Duration.zero);
        await _player.seek(Duration.zero);
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
      await _player.seek(Duration.zero);
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
    VideoPlaybackSession.progressRevision.removeListener(
      _syncVideoPlaybackState,
    );
    _sleepTimer?.cancel();
    _sleepTimerTicker?.cancel();
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
    'updatedAt': updatedAt,
  };
}

/// 音量（与设置联动）。
final volumeProvider = Provider<double>((ref) {
  return ref.watch(settingsProvider.select((s) => s.valueOrNull?.volume)) ??
      1.0;
});

/// 最近播放写入成功后的修订号，让已打开的最近播放页在异步落库完成后刷新。
final recentHistoryRevisionProvider = StateProvider<int>((ref) => 0);

final playerProvider = StateNotifierProvider<PlayerNotifier, PlaybackState>((
  ref,
) {
  return PlayerNotifier(ref);
});
