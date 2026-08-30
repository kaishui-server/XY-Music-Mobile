import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../../src/core/db_path.dart';
import '../../src/core/settings.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/player/player_provider.dart';
import '../../src/player/desktop_lyrics.dart';
import '../../src/player/downloaded_song_store.dart';
import '../../src/player/android_storage.dart';
import '../../src/player/video_playback_session.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/plugins/plugin_runtime.dart';
import '../../src/rust/api.dart';
import '../../src/rust/music/types.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/top_notice.dart';

const _pluginLyricsSearchMemoryKey = 'pluginLyricsSearchQueriesV1';

final _lyricsProvider = FutureProvider.autoDispose
    .family<List<_LyricLine>, String>((ref, path) async {
      final dbPath = await ref.watch(dbPathProvider.future);
      final raw = await getSongLyricsPayload(dbPath: dbPath, path: path);
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      return _decodeLyricLines(payload);
    });

final _embeddedLyricsProvider = FutureProvider.autoDispose
    .family<List<_LyricLine>, String>((ref, rawLyrics) async {
      final raw = await parseLyrics(rawLyrics: rawLyrics);
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      return _decodeLyricLines(payload);
    });

List<_LyricLine> _decodeLyricLines(Map<String, dynamic> payload) {
  return (payload['displayLines'] as List? ?? const [])
      .whereType<Map>()
      .map((value) {
        final line = Map<String, dynamic>.from(value);
        return _LyricLine(
          time: (line['time'] as num?)?.toDouble() ?? 0,
          endTime: (line['endTime'] as num?)?.toDouble() ?? 0,
          text: line['text'] as String? ?? '',
          translation: line['translation'] as String? ?? '',
          romaji: line['romaji'] as String? ?? '',
          words: _decodeLyricWords(line['words']),
        );
      })
      .where((line) => line.text.trim().isNotEmpty)
      .toList();
}

/// 有些插件会把 QRC/KRC 等歌词的密文直接放进播放结果。播放页解析器
/// 可以识别其中一部分格式，但如果原样写入下载的 `.lrc` 文件，用户看到的
/// 就会是长串数字和大写字母。仅对明显不像歌词正文的编码串做转换，普通
/// 英文歌词不会被误判。
bool _looksLikeEncodedLyrics(String raw) {
  final text = raw.trim();
  if (text.length < 80 || text.contains('[') || text.contains('<')) {
    return false;
  }
  final compact = text.replaceAll(RegExp(r'\s+'), '');
  if (compact.length < 80 ||
      !RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(compact)) {
    return false;
  }
  final upperOrDigit = RegExp(r'[A-Z0-9]').allMatches(compact).length;
  return upperOrDigit / compact.length >= .82;
}

String _formatLrcTime(double seconds) {
  final milliseconds = (seconds.isFinite && seconds > 0 ? seconds * 1000 : 0)
      .round();
  final minutes = milliseconds ~/ 60000;
  final remainder = milliseconds % 60000;
  final wholeSeconds = remainder ~/ 1000;
  final millis = remainder % 1000;
  return '[${minutes.toString().padLeft(2, '0')}:${wholeSeconds.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}]';
}

/// 将解析器输出的展示行还原为可保存的标准 LRC。这样下载文件中不会保留
/// QRC 等密文，同时翻译行仍会按同一时间戳写入。
String _displayLinesToLrc(dynamic payload) {
  if (payload is! Map) return '';
  final lines = payload['displayLines'];
  if (lines is! List) return '';
  final output = <String>[];
  for (final value in lines.whereType<Map>()) {
    final text = value['text']?.toString().trim() ?? '';
    if (text.isEmpty) continue;
    final time = (value['time'] as num?)?.toDouble();
    if (time == null || !time.isFinite || time < 0) continue;
    final stamp = _formatLrcTime(time);
    output.add('$stamp$text');
    final translation = value['translation']?.toString().trim() ?? '';
    if (translation.isNotEmpty && translation != text) {
      output.add('$stamp$translation');
    }
  }
  return output.join('\n');
}

List<_LyricWord> _decodeLyricWords(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((raw) {
        final word = Map<String, dynamic>.from(raw);
        return _LyricWord(
          text: word['text']?.toString() ?? '',
          start: (word['start'] as num?)?.toDouble() ?? 0,
          end: (word['end'] as num?)?.toDouble() ?? 0,
        );
      })
      .where((word) => word.text.isNotEmpty)
      .toList();
}

class _LyricWord {
  const _LyricWord({
    required this.text,
    required this.start,
    required this.end,
  });

  final String text;
  final double start;
  final double end;
}

class _LyricLine {
  const _LyricLine({
    required this.time,
    required this.endTime,
    required this.text,
    required this.translation,
    required this.romaji,
    this.words = const [],
  });
  final double time;
  final double endTime;
  final String text;
  final String translation;
  final String romaji;
  final List<_LyricWord> words;
}

enum _PlayerMenuAction {
  share,
  download,
  quality,
  playlist,
  linkLyrics,
  lyricsOffset,
  lyricFontSize,
  sleepTimer,
  playbackSpeed,
  toggleDesktopLyrics,
  playVideo,
  playMv,
}

enum _LyricsSourceAction { plugin, local, cancel }

enum _SleepTimerOption {
  off,
  minutes15,
  minutes30,
  minutes45,
  minutes60,
  minutes90,
  custom,
}

class _DownloadOptions {
  const _DownloadOptions({
    required this.directory,
    required this.quality,
    this.dontAskAgain = false,
  });

  final String directory;
  final String quality;
  final bool dontAskAgain;
}

String _formatSleepDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = totalSeconds.remainder(3600) ~/ 60;
  final seconds = totalSeconds.remainder(60);
  final parts = <String>[];
  if (hours > 0) parts.add('$hours 小时');
  if (minutes > 0) parts.add('$minutes 分钟');
  if (seconds > 0 || parts.isEmpty) parts.add('$seconds 秒');
  return parts.join(' ');
}

const _lyricsOffsetsPreferenceKey = 'playerLyricsOffsetsTenthsV1';
// 播放详情页可能被反复打开（B 站视频尤其常见）；同一首歌的无歌词提示
// 只在当前应用运行期间首次进入时显示一次，避免每次返回页面都打扰用户。
final _noLyricsNoticeShownPaths = <String>{};

int clampLyricsOffsetTenths(int value) => value.clamp(-100, 100);

double applyLyricsOffset(double playbackPosition, int offsetTenths) =>
    playbackPosition + clampLyricsOffsetTenths(offsetTenths) / 10;

double playbackPositionForLyric(double lyricTime, int offsetTenths) =>
    math.max(0, lyricTime - clampLyricsOffsetTenths(offsetTenths) / 10);

String lyricsOffsetLabel(int offsetTenths) {
  final normalized = clampLyricsOffsetTenths(offsetTenths);
  if (normalized == 0) return '无偏移';
  final seconds = (normalized.abs() / 10).toStringAsFixed(1);
  return normalized > 0 ? '提前 $seconds 秒' : '延后 $seconds 秒';
}

bool _isBilibiliQueueItem(QueueItem item) {
  final raw = item.pluginData;
  final values = <String>[
    item.path,
    item.pluginId ?? '',
    if (raw != null) ...[
      raw['platform']?.toString() ?? '',
      raw['source']?.toString() ?? '',
      raw['pluginId']?.toString() ?? '',
      raw['bvid']?.toString() ?? '',
      raw['aid']?.toString() ?? '',
      if (raw['rawData'] is Map) ...[
        (raw['rawData'] as Map)['platform']?.toString() ?? '',
        (raw['rawData'] as Map)['bvid']?.toString() ?? '',
        (raw['rawData'] as Map)['aid']?.toString() ?? '',
      ],
    ],
  ];
  return RegExp(
    r'bilibili|哔哩哔哩|哔哩|b站',
    caseSensitive: false,
  ).hasMatch(values.join(' '));
}

/// 正在播放页：现代毛玻璃风格。
/// 封面大圆角浮于详情页背景之上，下方播放栏直接叠加在背景上。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  static const _screenAwakeChannel = MethodChannel(
    'com.xymusic.mobile/screen_awake',
  );
  static const _galleryChannel = MethodChannel('com.xymusic.mobile/gallery');

  late final PageController _detailPageController = PageController();
  ProviderSubscription<bool>? _playingSubscription;
  bool _screenAwake = false;
  bool _showLyrics = false;
  int? _detailPointerId;
  Offset? _detailPointerStart;
  Offset? _detailPointerLast;
  String? _lyricsOffsetSongPath;
  int _lyricsOffsetTenths = 0;
  int _lyricsOffsetLoadRequest = 0;
  String? _lyricsCheckSongPath;
  String? _noLyricsNoticePath;
  VideoPlayerController? _videoController;
  String? _videoSongPath;
  bool _videoLoading = false;
  bool _videoClosing = false;
  bool _videoIsMv = false;
  bool _resumeAudioAfterVideo = false;
  String? _videoError;
  VoidCallback? _videoControllerListener;

  @override
  void initState() {
    super.initState();
    _playingSubscription = ref.listenManual<bool>(
      playerProvider.select((state) => state.isPlaying),
      (_, playing) => unawaited(_setScreenAwake(playing)),
      fireImmediately: true,
    );
    _videoController = VideoPlaybackSession.controller;
    _videoSongPath = VideoPlaybackSession.songPath;
    _videoLoading = VideoPlaybackSession.loading;
    _videoIsMv = VideoPlaybackSession.isMv;
    _resumeAudioAfterVideo = VideoPlaybackSession.resumeAudioAfterVideo;
    _videoError = VideoPlaybackSession.error;
    VideoPlaybackSession.revision.addListener(_syncVideoSession);
    final controller = _videoController;
    if (controller != null) _bindVideoController(controller);
  }

  Future<void> _setScreenAwake(bool enabled) async {
    if (!Platform.isAndroid || _screenAwake == enabled) return;
    _screenAwake = enabled;
    try {
      await _screenAwakeChannel.invokeMethod<bool>('setKeepScreenOn', {
        'enabled': enabled,
      });
    } catch (error) {
      // 防熄屏属于体验增强；平台通道不可用时不能影响播放详情页。
      debugPrint('播放详情页防熄屏设置失败：$error');
    }
  }

  void _syncVideoSession() {
    // 共享会话在释放原生纹理前会先置空控制器；及时解除 listener，避免
    // 释放过程中再次读取 controller.value 导致 native peer 错误。
    if (VideoPlaybackSession.controller == null && _videoController != null) {
      final old = _videoController!;
      _unbindVideoController(old);
      _videoController = null;
      if (mounted && !_videoClosing) setState(() {});
    }
  }

  void _bindVideoController(VideoPlayerController controller) {
    _unbindVideoController(_videoController);
    void listener() {
      if (VideoPlaybackSession.controller == controller) {
        VideoPlaybackSession.progressChanged();
      }
      if (!mounted || _videoController != controller) return;
      if (controller.value.hasError) {
        final error = controller.value.errorDescription;
        VideoPlaybackSession.error = error;
        if (_videoError != error) setState(() => _videoError = error);
      } else if (controller.value.isCompleted &&
          !_videoClosing &&
          !VideoPlaybackSession.restarting) {
        if (normalizePlayMode(ref.read(playerProvider).playMode) == 1) {
          // 播放器状态监听通常会先触发共享会话重播；这里保留兜底，
          // 防止详情页单独收到完成事件时切回音频。
          unawaited(VideoPlaybackSession.restartSingleLoop());
        } else {
          unawaited(_closeBilibiliVideo());
        }
      }
    }

    _videoControllerListener = listener;
    controller.addListener(listener);
  }

  void _unbindVideoController(VideoPlayerController? controller) {
    final listener = _videoControllerListener;
    if (controller != null && listener != null) {
      controller.removeListener(listener);
    }
    _videoControllerListener = null;
  }

  void _toggleLyrics() {
    _showDetailPage(!_showLyrics);
  }

  void _loadLyricsOffsetFor(QueueItem? item) {
    final path = item?.path;
    if (_lyricsOffsetSongPath == path) return;
    _lyricsOffsetSongPath = path;
    _lyricsOffsetTenths = 0;
    final requestId = ++_lyricsOffsetLoadRequest;
    if (path == null || path.isEmpty) return;
    unawaited(() async {
      try {
        final preferences = await SharedPreferences.getInstance();
        final raw = preferences.getString(_lyricsOffsetsPreferenceKey);
        final decoded = raw == null || raw.isEmpty ? null : jsonDecode(raw);
        final stored = decoded is Map ? decoded[path] : null;
        final offset = clampLyricsOffsetTenths((stored as num?)?.toInt() ?? 0);
        if (!mounted ||
            requestId != _lyricsOffsetLoadRequest ||
            _lyricsOffsetSongPath != path) {
          return;
        }
        setState(() => _lyricsOffsetTenths = offset);
      } catch (_) {
        // 单曲偏移读取失败时使用无偏移，不影响歌词显示。
      }
    }());
  }

  Future<void> _saveLyricsOffset(String path, int offsetTenths) async {
    final normalized = clampLyricsOffsetTenths(offsetTenths);
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_lyricsOffsetsPreferenceKey);
    Map<String, dynamic> offsets;
    try {
      final decoded = raw == null || raw.isEmpty ? null : jsonDecode(raw);
      offsets = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } catch (_) {
      offsets = <String, dynamic>{};
    }
    if (normalized == 0) {
      offsets.remove(path);
    } else {
      offsets[path] = normalized;
    }
    await preferences.setString(
      _lyricsOffsetsPreferenceKey,
      jsonEncode(offsets),
    );
  }

  void _startDetailSwipe(PointerDownEvent event) {
    if (_detailPointerId != null) return;
    _detailPointerId = event.pointer;
    _detailPointerStart = event.position;
    _detailPointerLast = event.position;
  }

  void _updateDetailSwipe(PointerMoveEvent event) {
    if (_detailPointerId == event.pointer) {
      _detailPointerLast = event.position;
    }
  }

  void _finishDetailSwipe(PointerEvent event, double viewportWidth) {
    if (_detailPointerId != event.pointer) return;
    final start = _detailPointerStart;
    final end = event is PointerCancelEvent
        ? null
        : (_detailPointerLast ?? event.position);
    _clearDetailSwipe();
    if (start == null || end == null) return;

    final delta = end - start;
    final horizontalDistance = delta.dx.abs();
    final verticalDistance = delta.dy.abs();
    // Keep the gesture easy to trigger on narrow phones.  The previous
    // 84px/24% threshold made short, deliberate swipes get ignored.  A
    // smaller distance still requires a clear horizontal direction so the
    // vertical lyric scrolling gesture does not switch the page by accident.
    final requiredDistance = math.max(
      56.0,
      math.min(96.0, viewportWidth * .18),
    );
    if (horizontalDistance < requiredDistance ||
        horizontalDistance < verticalDistance * 1.3) {
      return;
    }
    if (delta.dx < 0 && !_showLyrics) {
      _showDetailPage(true);
    } else if (delta.dx > 0 && _showLyrics) {
      _showDetailPage(false);
    }
  }

  void _clearDetailSwipe() {
    _detailPointerId = null;
    _detailPointerStart = null;
    _detailPointerLast = null;
  }

  /// 启动视频画面。B 站插件歌曲走 [resolveVideoSource]；其他插件歌曲
  /// 在 [isMv] 为 true 时参考 BakaMusic 调用插件 `getMvSource` 解析 MV，
  /// 其余流程（视频层、进度同步、媒体通知桥接）与 B 站视频完全一致。
  Future<void> _startBilibiliVideo(QueueItem item, {bool isMv = false}) async {
    if (_videoLoading || _videoSongPath == item.path) return;
    if (!isMv && !_isBilibiliQueueItem(item)) {
      XyNotice.show(
        context,
        message: '当前歌曲不是哔哩哔哩插件歌曲',
        type: XyNoticeType.warning,
      );
      return;
    }
    final pluginData = item.pluginData;
    if (pluginData == null || pluginData.isEmpty) {
      XyNotice.show(
        context,
        message: isMv ? '当前歌曲缺少 MV 信息' : '当前歌曲缺少 B 站视频信息',
        type: XyNoticeType.error,
      );
      return;
    }
    List<EnabledMusicPlugin> plugins;
    try {
      plugins = await ref.read(enabledMusicPluginsProvider.future);
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: isMv
              ? '读取歌曲插件失败：${_errorText(error)}'
              : '读取哔哩哔哩插件失败：${_errorText(error)}',
          type: XyNoticeType.error,
        );
      }
      return;
    }
    final plugin = plugins
        .where((value) => value.id == item.pluginId)
        .firstOrNull;
    if (!mounted) return;
    if (plugin == null) {
      XyNotice.show(
        context,
        message: isMv ? '歌曲所属插件已停用或删除' : '哔哩哔哩插件已停用或删除',
        type: XyNoticeType.error,
      );
      return;
    }

    final notifier = ref.read(playerProvider.notifier);
    final resumeAudio = await notifier.pauseForVideo();
    if (!mounted || ref.read(playerProvider).current?.path != item.path) {
      if (resumeAudio) await notifier.resumeAfterVideo();
      return;
    }
    setState(() {
      _videoSongPath = item.path;
      _videoLoading = true;
      _videoClosing = false;
      _videoIsMv = isMv;
      _resumeAudioAfterVideo = resumeAudio;
      _videoError = null;
    });
    VideoPlaybackSession.songPath = item.path;
    VideoPlaybackSession.controller = null;
    VideoPlaybackSession.loading = true;
    VideoPlaybackSession.isMv = isMv;
    VideoPlaybackSession.resumeAudioAfterVideo = resumeAudio;
    VideoPlaybackSession.error = null;
    VideoPlaybackSession.changed();
    try {
      final source = isMv
          ? await ref
                .read(pluginRuntimeProvider)
                .resolveMvSource(plugin, pluginData)
                .timeout(const Duration(seconds: 25))
          : await ref
                .read(pluginRuntimeProvider)
                .resolveVideoSource(
                  plugin,
                  pluginData,
                  videoQuality: '720P',
                  path: item.path,
                )
                .timeout(const Duration(seconds: 25));
      if (!mounted || _videoSongPath != item.path) return;
      VideoPlayerController? controller;
      Object? lastVideoError;
      for (final url in <String>[source.url, ...source.backupUrls]) {
        VideoPlayerController? candidate;
        try {
          candidate = VideoPlayerController.networkUrl(
            Uri.parse(url),
            httpHeaders: source.headers,
            videoPlayerOptions: VideoPlayerOptions(
              // video_player 默认会在锁屏/切后台时暂停自身；视频歌曲需要
              // 和普通歌曲一样保持后台播放。
              allowBackgroundPlayback: true,
              mixWithOthers: true,
            ),
          );
          await candidate.initialize();
          controller = candidate;
          break;
        } catch (error) {
          lastVideoError = error;
          // 初始化失败的候选地址也要释放，避免连续尝试备用地址时泄漏
          // ExoPlayer/纹理资源。
          try {
            await candidate?.dispose();
          } catch (_) {}
        }
      }
      if (controller == null) {
        throw lastVideoError ?? Exception('视频地址无法播放');
      }
      final activeController = controller;
      if (!mounted || _videoSongPath != item.path) {
        await activeController.dispose();
        return;
      }
      final position = ref.read(playerProvider).position;
      final playbackSpeed = ref.read(playerProvider).playbackSpeed;
      await activeController.setPlaybackSpeed(playbackSpeed);
      if (position.isFinite && position > 0) {
        await activeController.seekTo(
          Duration(milliseconds: (position * 1000).round()),
        );
      }
      _bindVideoController(activeController);
      _videoController = activeController;
      VideoPlaybackSession.controller = activeController;
      VideoPlaybackSession.loading = false;
      VideoPlaybackSession.changed();
      VideoPlaybackSession.progressChanged();
      setState(() => _videoLoading = false);
      await activeController.play();
      // video_player 不会自动接入 Android MediaSession。启动静音音频桥接，
      // 让通知栏/锁屏/灵动岛进度与播放暂停按钮同步控制当前视频。
      await notifier.enableVideoMediaBridge();
    } catch (error) {
      if (!mounted || _videoSongPath != item.path) return;
      final errorText = _errorText(error);
      setState(() {
        _videoSongPath = null;
        _videoLoading = false;
        _videoIsMv = false;
        _videoError = errorText;
      });
      VideoPlaybackSession.songPath = null;
      VideoPlaybackSession.controller = null;
      VideoPlaybackSession.loading = false;
      VideoPlaybackSession.isMv = false;
      VideoPlaybackSession.error = errorText;
      VideoPlaybackSession.changed();
      _videoController = null;
      if (_resumeAudioAfterVideo) {
        _resumeAudioAfterVideo = false;
        await notifier.resumeAfterVideo();
      }
      if (mounted) {
        XyNotice.show(
          context,
          message: isMv
              ? 'MV 播放失败：${_errorText(error)}'
              : '视频播放失败：${_errorText(error)}',
          type: XyNoticeType.error,
        );
      }
    }
  }

  Future<void> _closeBilibiliVideo() async {
    if (_videoClosing) return;
    _videoClosing = true;
    // 在后续释放原生视频纹理期间页面可能被移除；先缓存应用级播放器
    // notifier，避免 await 返回后再次访问已销毁页面的 WidgetRef。
    final notifier = ref.read(playerProvider.notifier);
    final controller = _videoController;
    final sessionOwnsController =
        controller != null && VideoPlaybackSession.controller == controller;
    final shouldResume = _resumeAudioAfterVideo;
    final songPath = _videoSongPath;
    // 视频播放期间音频播放器一直停在进入视频前的位置；关闭视频前先
    // 读取视频当前时间，随后把音频播放器定位到同一位置，避免回跳。
    final videoPosition = controller?.value.position;
    await notifier.disableVideoMediaBridge();
    _videoController = null;
    _videoSongPath = null;
    _videoLoading = false;
    _videoError = null;
    _videoIsMv = false;
    _resumeAudioAfterVideo = false;
    VideoPlaybackSession.songPath = null;
    VideoPlaybackSession.controller = null;
    VideoPlaybackSession.loading = false;
    VideoPlaybackSession.isMv = false;
    VideoPlaybackSession.resumeAudioAfterVideo = false;
    VideoPlaybackSession.error = null;
    VideoPlaybackSession.changed();
    VideoPlaybackSession.progressChanged();
    if (mounted) setState(() {});
    // 首页/迷你播放栏切歌时可能已经负责释放控制器，避免二次 dispose。
    _unbindVideoController(controller);
    if (sessionOwnsController) await controller.dispose();
    if (!mounted) {
      _videoClosing = false;
      return;
    }
    final current = ref.read(playerProvider).current;
    if (songPath != null &&
        videoPosition != null &&
        videoPosition.inMilliseconds >= 0 &&
        current?.path == songPath) {
      await notifier.seek(videoPosition.inMilliseconds / 1000.0);
    }
    if (shouldResume && current?.path == songPath) {
      await notifier.resumeAfterVideo();
    }
    _videoClosing = false;
  }

  /// 参考 BakaMusic 的 canPlayMusicVideo：非 B 站插件歌曲需要插件
  /// 声明 `getMvSource` 扩展，且歌曲携带 mv/mvId/videoId 等 MV 标识，
  /// 才在更多菜单中提供“播放MV”。
  Future<bool> _checkMvAvailable(QueueItem item) async {
    final pluginData = item.pluginData;
    if (item.pluginId == null || pluginData == null) return false;
    if (!PluginRuntimeService.hasMvIdentifier(pluginData)) return false;
    try {
      final plugins = await ref.read(enabledMusicPluginsProvider.future);
      final plugin = plugins
          .where((value) => value.id == item.pluginId)
          .firstOrNull;
      if (plugin == null || plugin.isLx) return false;
      return await ref
          .read(pluginRuntimeProvider)
          .pluginSupportsMvSource(plugin);
    } catch (_) {
      return false;
    }
  }

  Future<void> _showMoreMenu(QueueItem item) async {
    final settings = ref.read(settingsProvider).valueOrNull;
    final playbackSpeed = ref.read(playerProvider).playbackSpeed;
    final isLocalSong =
        playbackSourceTypeFor(item) == PlaybackSourceType.localFile;
    final viewport = MediaQuery.sizeOf(context);
    final isLandscape = viewport.width > viewport.height;
    final mvAvailable = !_isBilibiliQueueItem(item) &&
        await _checkMvAvailable(item);
    if (!mounted) return;
    final action = await showModalBottomSheet<_PlayerMenuAction>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      // 仅限制更多菜单的高度，宽度保持系统默认布局；项目较多时由下方
      // SingleChildScrollView 负责纵向滑动浏览。
      constraints: isLandscape
          ? BoxConstraints(
              maxWidth: math.min(560, viewport.width - 32),
              maxHeight: viewport.height * .64,
            )
          : BoxConstraints(maxHeight: viewport.height * .64),
      builder: (sheetContext) => Consumer(
        builder: (context, ref, child) {
          final sleepTimerEndsAt = ref.watch(
            playerProvider.select((state) => state.sleepTimerEndsAt),
          );
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: isLandscape
                  ? viewport.height * .86
                  : viewport.height * .8,
            ),
            child: SingleChildScrollView(
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        child: Row(
                          children: [
                            CoverImage(
                              songPath: item.path,
                              imageUrl: item.coverUrl,
                              width: 54,
                              height: 54,
                              radius: 12,
                              icon: Icons.music_note_rounded,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    item.artist.trim().isEmpty
                                        ? '未知歌手'
                                        : item.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Theme.of(
                                        sheetContext,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: '分享',
                              onPressed: () => Navigator.pop(
                                sheetContext,
                                _PlayerMenuAction.share,
                              ),
                              icon: const Icon(Icons.share_outlined),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      if (!isLocalSong) ...[
                        _moreTile(
                          sheetContext,
                          action: _PlayerMenuAction.download,
                          icon: Icons.download_rounded,
                          title: '下载',
                        ),
                        _moreTile(
                          sheetContext,
                          action: _PlayerMenuAction.quality,
                          icon: Icons.high_quality_rounded,
                          title: '选择音质',
                          value: _qualityLabel(
                            settings?.onlineDefaultQuality ?? '320k',
                          ),
                        ),
                      ],
                      _moreTile(
                        sheetContext,
                        action: _PlayerMenuAction.playlist,
                        icon: Icons.playlist_add_rounded,
                        title: '添加到歌单',
                      ),
                      _moreTile(
                        sheetContext,
                        action: _PlayerMenuAction.linkLyrics,
                        icon: Icons.lyrics_outlined,
                        title: '关联歌词',
                      ),
                      _moreTile(
                        sheetContext,
                        action: _PlayerMenuAction.lyricsOffset,
                        icon: Icons.sync_alt_rounded,
                        title: '歌词偏移',
                        value: lyricsOffsetLabel(_lyricsOffsetTenths),
                      ),
                      _moreTile(
                        sheetContext,
                        action: _PlayerMenuAction.lyricFontSize,
                        icon: Icons.format_size_rounded,
                        title: '歌词字号',
                        value: (settings?.lyricFontSize ?? 18)
                            .toStringAsFixed(0),
                      ),
                      _moreTile(
                        sheetContext,
                        action: _PlayerMenuAction.sleepTimer,
                        icon: Icons.timer_outlined,
                        title: '定时关闭',
                        value: _sleepTimerLabel(sleepTimerEndsAt),
                      ),
                      _moreTile(
                        sheetContext,
                        action: _PlayerMenuAction.playbackSpeed,
                        icon: Icons.speed_rounded,
                        title: '倍速',
                        value: '${_formatPlaybackSpeed(playbackSpeed)}x',
                      ),
                      _moreTile(
                        sheetContext,
                        action: _PlayerMenuAction.toggleDesktopLyrics,
                        icon: settings?.desktopLyricsEnabled == true
                            ? Icons.desktop_access_disabled_outlined
                            : Icons.desktop_windows_outlined,
                        title: settings?.desktopLyricsEnabled == true
                            ? '关闭桌面歌词'
                            : '开启桌面歌词',
                      ),
                      if (_isBilibiliQueueItem(item) || mvAvailable)
                        _moreTile(
                          sheetContext,
                          action: _isBilibiliQueueItem(item)
                              ? _PlayerMenuAction.playVideo
                              : _PlayerMenuAction.playMv,
                          icon: _videoSongPath == item.path
                              ? Icons.stop_circle_outlined
                              : Icons.ondemand_video_outlined,
                          title: _videoSongPath == item.path
                              ? (_videoIsMv ? '关闭MV' : '关闭视频')
                              : (_isBilibiliQueueItem(item)
                                    ? '播放视频'
                                    : '播放MV'),
                          value: _videoLoading ? '解析中' : null,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _PlayerMenuAction.share:
        await _showShareSheet(item);
      case _PlayerMenuAction.download:
        await _downloadCurrent(item);
      case _PlayerMenuAction.quality:
        await _pickPlaybackQuality();
      case _PlayerMenuAction.playlist:
        await _addToPlaylist(item);
      case _PlayerMenuAction.linkLyrics:
        await _linkLyrics(item);
      case _PlayerMenuAction.lyricsOffset:
        await _pickLyricsOffset(item);
      case _PlayerMenuAction.lyricFontSize:
        await _pickLyricFontSize();
      case _PlayerMenuAction.sleepTimer:
        await _pickSleepTimer();
      case _PlayerMenuAction.playbackSpeed:
        await _pickPlaybackSpeed();
      case _PlayerMenuAction.toggleDesktopLyrics:
        await _toggleDesktopLyrics();
      case _PlayerMenuAction.playVideo:
        if (_videoSongPath == item.path) {
          await _closeBilibiliVideo();
        } else {
          await _startBilibiliVideo(item);
        }
      case _PlayerMenuAction.playMv:
        if (_videoSongPath == item.path) {
          await _closeBilibiliVideo();
        } else {
          await _startBilibiliVideo(item, isMv: true);
        }
    }
  }

  Future<void> _showShareSheet(QueueItem item) async {
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              leading: Icon(Icons.share_outlined),
              title: Text('分享歌曲'),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('保存为分享图片'),
              onTap: () {
                Navigator.pop(sheetContext);
                unawaited(_createShareImagePreview(item));
              },
            ),
            ListTile(
              leading: const Icon(Icons.chat_outlined),
              title: const Text('分享链接到QQ'),
              onTap: () => Navigator.pop(sheetContext),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createShareImagePreview(QueueItem item) async {
    try {
      final bytes = await _buildShareImage(item);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('分享图片预览'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 560, maxWidth: 420),
            child: InteractiveViewer(
              minScale: .8,
              maxScale: 3,
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final saved = await _saveShareImage(bytes);
                if (saved && dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
              },
              child: const Text('保存到本地'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '生成分享图片失败：${_errorText(error)}',
          type: XyNoticeType.error,
        );
      }
    }
  }

  Future<bool> _saveShareImage(Uint8List bytes) async {
    try {
      final fileName =
          'xy_music_share_${DateTime.now().millisecondsSinceEpoch}.png';
      bool saved;
      if (Platform.isAndroid) {
        saved =
            await _galleryChannel.invokeMethod<bool>('saveImage', {
              'bytes': bytes,
              'fileName': fileName,
            }) ??
            false;
      } else {
        // 其他桌面平台保留文件保存能力；Android 直接写入系统相册，
        // 不再弹出目录选择器。
        final path = await FilePicker.platform.saveFile(
          dialogTitle: '保存分享图片',
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: const ['png'],
          bytes: bytes,
        );
        saved = path != null && path.isNotEmpty;
      }
      if (!mounted || !saved) return false;
      XyNotice.show(context, message: '分享图片已保存', type: XyNoticeType.success);
      return true;
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '保存分享图片失败：${_errorText(error)}',
          type: XyNoticeType.error,
        );
      }
      return false;
    }
  }

  Future<Uint8List> _buildShareImage(QueueItem item) async {
    const width = 450.0;
    const height = 600.0;
    final accentColor = Theme.of(context).colorScheme.primary;
    final settings = ref.read(settingsProvider).valueOrNull;
    final backgroundBytes = await _shareBackgroundBytes(item, settings);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final bounds = const Rect.fromLTWH(0, 0, width, height);
    if (backgroundBytes != null && backgroundBytes.isNotEmpty) {
      final codec = await ui.instantiateImageCodec(
        backgroundBytes,
        targetWidth: width.toInt(),
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final source = Rect.fromLTWH(
        0,
        0,
        image.width.toDouble(),
        image.height.toDouble(),
      );
      final scale = math.max(width / image.width, height / image.height);
      final destination = Rect.fromCenter(
        center: bounds.center,
        width: image.width * scale,
        height: image.height * scale,
      );
      final paint = Paint()
        ..filterQuality = FilterQuality.high
        ..imageFilter = ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2);
      canvas.drawImageRect(image, source, destination, paint);
      image.dispose();
    } else {
      final gradient = LinearGradient(
        colors: [
          accentColor.withValues(alpha: .9),
          const Color(0xFF171323),
          const Color(0xFF0A0A0F),
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
      canvas.drawRect(bounds, Paint()..shader = gradient.createShader(bounds));
    }
    canvas.drawRect(
      bounds,
      Paint()..color = Colors.black.withValues(alpha: .34),
    );
    final user = ref.read(authProvider).user;
    final userName = user?.nickname.trim() ?? '';
    final greeting = userName.isEmpty
        ? 'XY Music 给你分享了一首歌'
        : '$userName 给你分享了一首歌';
    _paintText(
      canvas,
      greeting,
      const Offset(30, 30),
      maxWidth: width - 60,
      fontSize: 18,
      color: Colors.white.withValues(alpha: .94),
      fontWeight: userName.isEmpty ? FontWeight.w600 : FontWeight.w800,
      maxLines: 3,
    );
    _paintText(
      canvas,
      item.title.trim().isEmpty ? '未知歌曲' : item.title.trim(),
      const Offset(30, 475),
      maxWidth: width - 60,
      fontSize: 38,
      color: Colors.white,
      fontWeight: FontWeight.w800,
      maxLines: 2,
    );
    _paintText(
      canvas,
      item.artist.trim().isEmpty ? '未知歌手' : item.artist.trim(),
      const Offset(32, 545),
      maxWidth: width - 64,
      fontSize: 18,
      color: Colors.white.withValues(alpha: .78),
      fontWeight: FontWeight.w500,
      maxLines: 1,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width.toInt(), height.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (data == null) throw Exception('图片编码失败');
    return data.buffer.asUint8List();
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset offset, {
    required double maxWidth,
    required double fontSize,
    required Color color,
    required FontWeight fontWeight,
    int maxLines = 1,
    TextAlign textAlign = TextAlign.left,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: fontWeight,
          shadows: const [Shadow(color: Colors.black54, blurRadius: 8)],
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: textAlign,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    painter.paint(canvas, offset);
  }

  Future<Uint8List?> _shareBackgroundBytes(
    QueueItem item,
    AppSettings? settings,
  ) async {
    final coverUrl = item.coverUrl?.trim() ?? '';
    if (coverUrl.startsWith('http://') || coverUrl.startsWith('https://')) {
      try {
        final response = await http
            .get(Uri.parse(coverUrl))
            .timeout(const Duration(seconds: 8));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return response.bodyBytes;
        }
      } catch (_) {}
    }
    if (playbackSourceTypeFor(item) == PlaybackSourceType.localFile) {
      try {
        final dbPath = await ref.read(dbPathProvider.future);
        final cacheRoot = await ref.read(appDataDirProvider.future);
        final path = await getSongCover(
          dbPath: dbPath,
          cacheRoot: cacheRoot,
          path: item.path,
        );
        if (path.trim().isNotEmpty && await File(path).exists()) {
          return await File(path).readAsBytes();
        }
      } catch (_) {}
    }
    final wallpaper = settings?.customBackgroundPath.trim() ?? '';
    if (wallpaper.isNotEmpty && await File(wallpaper).exists()) {
      return await File(wallpaper).readAsBytes();
    }
    return null;
  }

  Future<void> _toggleDesktopLyrics() async {
    final currentlyEnabled =
        ref.read(settingsProvider).valueOrNull?.desktopLyricsEnabled ?? false;
    final nextEnabled = !currentlyEnabled;

    if (nextEnabled) {
      if (!Platform.isAndroid) {
        if (mounted) {
          XyNotice.show(
            context,
            message: '当前平台不支持桌面歌词',
            type: XyNoticeType.warning,
          );
        }
        return;
      }
      final started = await DesktopLyricsBridge.setEnabled(true);
      if (!started) {
        if (mounted) {
          XyNotice.show(
            context,
            message: '请授予悬浮窗权限后再开启桌面歌词',
            type: XyNoticeType.warning,
          );
        }
        return;
      }
    } else {
      await DesktopLyricsBridge.setEnabled(false);
    }

    await ref
        .read(settingsProvider.notifier)
        .setDesktopLyricsEnabled(nextEnabled);
    if (!mounted) return;
    XyNotice.show(
      context,
      message: nextEnabled ? '桌面歌词样式请在设置中修改' : '桌面歌词已关闭',
      type: XyNoticeType.success,
    );
  }

  Future<void> _pickPlaybackSpeed() async {
    final current = ref.read(playerProvider).playbackSpeed;
    const speeds = [0.5, 0.8, 1.0, 1.5, 2.0];
    final selected = await showModalBottomSheet<double>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              leading: Icon(Icons.speed_rounded),
              title: Text('播放倍速'),
            ),
            for (final speed in speeds)
              ListTile(
                title: Text('${_formatPlaybackSpeed(speed)}x'),
                trailing: (speed - current).abs() < 0.001
                    ? Icon(
                        Icons.check,
                        color: Theme.of(sheetContext).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, speed),
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await ref.read(playerProvider.notifier).setPlaybackSpeed(selected);
  }

  String _formatPlaybackSpeed(double speed) => speed == speed.roundToDouble()
      ? speed.toStringAsFixed(0)
      : speed.toStringAsFixed(1);

  /// 歌词字号调整弹窗：滑杆实时调整，下方用示例歌词预览效果，
  /// 确认后写入设置。设置页“播放详情页歌词-歌词字号”共用同一份数据。
  Future<void> _pickLyricFontSize() async {
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _LyricFontSizeSheet(
        initial: ref.read(settingsProvider).valueOrNull?.lyricFontSize ?? 18.0,
        onChanged: (value) => ref
            .read(settingsProvider.notifier)
            .setLyricFontSize(value),
      ),
    );
  }

  Future<void> _addToPlaylist(QueueItem item) async {
    final result = await showModalBottomSheet<_PlaylistPickResult>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PlaylistPickerSheet(item: item),
    );
    if (!mounted || result == null) return;
    final playlist = ref
        .read(playlistsProvider)
        .where((value) => value.id == result.playlistId)
        .firstOrNull;
    final name = playlist?.name;
    XyNotice.show(
      context,
      message: switch (result.kind) {
        // 歌曲已在该歌单中，未重复添加。
        _PlaylistPickKind.alreadyExists => name == null
            ? '该歌曲已在歌单中'
            : '该歌曲已在歌单“$name”中',
        _PlaylistPickKind.added => name == null
            ? '已添加到歌单'
            : '已添加到歌单“$name”',
      },
      type: result.kind == _PlaylistPickKind.alreadyExists
          ? XyNoticeType.warning
          : XyNoticeType.success,
    );
  }

  Widget _moreTile(
    BuildContext context, {
    required _PlayerMenuAction action,
    required IconData icon,
    required String title,
    String? value,
  }) {
    return ListTile(
      minTileHeight: 54,
      leading: Icon(icon),
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value?.isNotEmpty == true)
            Text(
              value!,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(width: 4),
          Icon(
            Icons.chevron_right,
            size: 18,
            color: Theme.of(context).colorScheme.outline,
          ),
        ],
      ),
      onTap: () => Navigator.pop(context, action),
    );
  }

  Future<void> _pickPlaybackQuality() async {
    final item = ref.read(playerProvider).current;
    if (item == null) return;
    final current =
        ref.read(settingsProvider).valueOrNull?.onlineDefaultQuality ?? '320k';
    XyNotice.show(context, message: '正在读取插件支持的音质…');
    final qualities = await _discoverQualityOptions(item, preferred: current);
    if (!mounted) return;
    final quality = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final value in qualities)
                ListTile(
                  title: Text(_qualityLabel(value)),
                  trailing: value == current
                      ? Icon(
                          Icons.check_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () => Navigator.pop(context, value),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || quality == null || quality == current) return;
    XyNotice.show(context, message: '正在切换为 ${_qualityLabel(quality)}…');
    await ref.read(playerProvider.notifier).setCurrentQuality(quality);
    if (!mounted) return;
    final error = ref.read(playerProvider).errorMessage;
    XyNotice.show(
      context,
      message: error ?? '已切换为 ${_qualityLabel(quality)}',
      type: error == null ? XyNoticeType.success : XyNoticeType.error,
    );
  }

  /// 按显示名称去重音质选项。插件可能同时返回 flac/lossless/sq 等映射到
  /// 同一档位名称的别名 token（master 系列同理），不去重时选择器会出现
  /// 两个“无损 FLAC”或两个“超清母带”。同组别名保留当前选中的 token，
  /// 保证勾选状态能正确回显；没有选中值时保留第一个。
  List<String> _dedupeQualityByLabel(
    List<String> qualities,
    String preferred,
  ) {
    final trimmed = preferred.trim();
    final ordered = [
      if (trimmed.isNotEmpty && qualities.contains(trimmed)) trimmed,
      ...qualities.where((value) => value != trimmed),
    ];
    final seenLabels = <String>{};
    final result = <String>[];
    for (final value in ordered) {
      if (seenLabels.add(_qualityLabel(value))) result.add(value);
    }
    return result;
  }

  Future<List<String>> _discoverQualityOptions(
    QueueItem item, {
    String? preferred,
  }) async {
    final current = preferred?.trim() ?? '';
    final fallback = <String>{if (current.isNotEmpty) current};
    final raw = item.pluginData;
    final pluginId = item.pluginId?.trim() ?? '';
    if (raw == null || raw.isEmpty || pluginId.isEmpty) {
      return fallback.isEmpty ? const ['320k'] : fallback.toList();
    }
    try {
      final plugins = await ref.read(enabledMusicPluginsProvider.future);
      final plugin = plugins.where((value) => value.id == pluginId).firstOrNull;
      if (plugin == null) {
        return fallback.isEmpty ? const ['320k'] : fallback.toList();
      }
      final discovered = await ref
          .read(pluginRuntimeProvider)
          .discoverQualities(plugin, raw, preferredQuality: current)
          // 逐音质探测可能因插件网络问题长时间无响应，超时后回退到
          // 当前音质，保证下载/切音质弹窗一定能弹出。
          .timeout(const Duration(seconds: 12), onTimeout: () => const <String>[]);
      final result = <String>{...discovered, ...fallback};
      final list = result.isEmpty ? const ['320k'] : result.toList();
      return _dedupeQualityByLabel(list, current);
    } catch (_) {
      return fallback.isEmpty ? const ['320k'] : fallback.toList();
    }
  }

  Future<void> _linkLyrics(QueueItem item) async {
    final associated = await ref
        .read(playerProvider.notifier)
        .rememberedLyricsAssociation(item.path);
    if (!mounted) return;
    final source = await showModalBottomSheet<_LyricsSourceAction>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '关联歌词',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              if (associated != null)
                _AssociatedLyricsCard(
                  association: associated,
                  onCancel: () =>
                      Navigator.pop(context, _LyricsSourceAction.cancel),
                ),
              ListTile(
                leading: const Icon(Icons.extension_outlined),
                title: const Text('从插件获取'),
                subtitle: const Text('搜索所有已启用插件提供的歌词'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(context, _LyricsSourceAction.plugin),
              ),
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: const Text('从本地上传'),
                subtitle: const Text('选择 LRC、YRC、QRC 等歌词文件'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(context, _LyricsSourceAction.local),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || source == null) return;
    if (ref.read(playerProvider).current?.path != item.path) {
      XyNotice.show(
        context,
        message: '歌曲已切换，请重新关联歌词',
        type: XyNoticeType.warning,
      );
      return;
    }
    if (source == _LyricsSourceAction.cancel) {
      await ref.read(playerProvider.notifier).clearCurrentLyricsAssociation();
      if (mounted) {
        XyNotice.show(context, message: '已取消关联歌词', type: XyNoticeType.success);
      }
    } else if (source == _LyricsSourceAction.plugin) {
      await _linkLyricsFromPlugin(item);
    } else {
      await _linkLyricsFromLocal(item);
    }
  }

  Future<void> _pickLyricsOffset(QueueItem item) async {
    final selected = await showDialog<int>(
      context: context,
      useRootNavigator: true,
      builder: (context) =>
          _LyricsOffsetDialog(initialOffsetTenths: _lyricsOffsetTenths),
    );
    if (!mounted || selected == null) return;
    if (ref.read(playerProvider).current?.path != item.path) {
      XyNotice.show(
        context,
        message: '歌曲已切换，请重新设置歌词偏移',
        type: XyNoticeType.warning,
      );
      return;
    }
    try {
      await _saveLyricsOffset(item.path, selected);
      if (!mounted || ref.read(playerProvider).current?.path != item.path) {
        return;
      }
      setState(() => _lyricsOffsetTenths = selected);
      XyNotice.show(
        context,
        message: selected == 0
            ? '已清除当前歌曲的歌词偏移'
            : '当前歌曲歌词将${lyricsOffsetLabel(selected)}',
        type: XyNoticeType.success,
      );
    } catch (error) {
      if (!mounted) return;
      XyNotice.show(
        context,
        message: '保存歌词偏移失败：${_errorText(error)}',
        type: XyNoticeType.error,
      );
    }
  }

  Future<void> _linkLyricsFromPlugin(QueueItem item) async {
    final selected = await showModalBottomSheet<PluginLyricsOption>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _PluginLyricsSearchSheet(item: item),
    );
    if (!mounted || selected == null) return;
    if (ref.read(playerProvider).current?.path != item.path) {
      XyNotice.show(
        context,
        message: '歌曲已切换，请重新选择歌词',
        type: XyNoticeType.warning,
      );
      return;
    }
    // 在线歌词也要像本地上传歌词一样写入本地 sidecar。
    // 这样下次从本地音乐再次播放时，会自动读取上次关联的歌词，
    // 不需要用户重新搜索并选择插件结果。
    if (playbackSourceTypeFor(item) == PlaybackSourceType.localFile) {
      try {
        await saveSongLyrics(
          path: item.path,
          lyrics: selected.lyrics,
          source: LyricsStorageSource.sidecar,
        );
      } catch (error) {
        if (mounted) {
          XyNotice.show(
            context,
            message: '歌词已应用，但记忆保存失败：${_errorText(error)}',
            type: XyNoticeType.warning,
          );
        }
      }
    }
    await ref
        .read(playerProvider.notifier)
        .setCurrentLyrics(
          selected.lyrics,
          association: RememberedLyricsAssociation(
            source: 'plugin',
            pluginName: selected.pluginName,
            title: selected.songTitle,
            artist: selected.songArtist,
            durationMs: selected.durationMs,
          ),
        );
    if (mounted) {
      XyNotice.show(
        context,
        message: '已应用 ${selected.pluginName} 提供的歌词',
        type: XyNoticeType.success,
      );
    }
  }

  Future<void> _linkLyricsFromLocal(QueueItem item) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['lrc', 'yrc', 'qrc', 'lys', 'ttml', 'txt'],
      allowMultiple: false,
    );
    final path = picked?.files.single.path;
    if (!mounted || path == null || path.isEmpty) return;
    try {
      final lyrics = await readLyricsFile(path: path);
      if (lyrics.trim().isEmpty) throw Exception('歌词文件内容为空');
      if (playbackSourceTypeFor(item) == PlaybackSourceType.localFile) {
        await saveSongLyrics(
          path: item.path,
          lyrics: lyrics,
          source: LyricsStorageSource.sidecar,
        );
      }
      if (ref.read(playerProvider).current?.path != item.path) {
        throw Exception('歌曲已切换，请重新关联歌词');
      }
      await ref
          .read(playerProvider.notifier)
          .setCurrentLyrics(
            lyrics,
            association: RememberedLyricsAssociation(
              source: 'local',
              title: item.title,
              artist: item.artist,
              durationMs: item.durationMs,
            ),
          );
      if (mounted) {
        XyNotice.show(context, message: '歌词关联成功', type: XyNoticeType.success);
      }
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '关联歌词失败：${_errorText(error)}',
          type: XyNoticeType.error,
        );
      }
    }
  }

  Future<void> _pickSleepTimer() async {
    final option = await showModalBottomSheet<_SleepTimerOption>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.timer_off_outlined),
                title: const Text('关闭定时'),
                onTap: () => Navigator.pop(context, _SleepTimerOption.off),
              ),
              for (final entry in const [
                (_SleepTimerOption.minutes15, 15),
                (_SleepTimerOption.minutes30, 30),
                (_SleepTimerOption.minutes45, 45),
                (_SleepTimerOption.minutes60, 60),
                (_SleepTimerOption.minutes90, 90),
              ])
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: Text('${entry.$2} 分钟后停止播放'),
                  onTap: () => Navigator.pop(context, entry.$1),
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.tune_rounded),
                title: const Text('自定义'),
                subtitle: const Text('30 秒至 12 小时'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.pop(context, _SleepTimerOption.custom),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || option == null) return;

    Duration? duration;
    if (option == _SleepTimerOption.custom) {
      duration = await showDialog<Duration>(
        context: context,
        useRootNavigator: true,
        builder: (context) => const _CustomSleepTimerDialog(),
      );
      if (!mounted || duration == null) return;
    } else {
      duration = switch (option) {
        _SleepTimerOption.off => null,
        _SleepTimerOption.minutes15 => const Duration(minutes: 15),
        _SleepTimerOption.minutes30 => const Duration(minutes: 30),
        _SleepTimerOption.minutes45 => const Duration(minutes: 45),
        _SleepTimerOption.minutes60 => const Duration(minutes: 60),
        _SleepTimerOption.minutes90 => const Duration(minutes: 90),
        _SleepTimerOption.custom => throw StateError('自定义定时应已单独处理'),
      };
    }
    ref.read(playerProvider.notifier).setSleepTimer(duration);
    XyNotice.show(
      context,
      message: duration == null
          ? '已关闭定时停止'
          : '将在 ${_formatSleepDuration(duration)}后停止播放',
      type: XyNoticeType.success,
    );
  }

  Future<String> _lyricsForDownload(QueueItem item) async {
    var raw = item.lyricsRaw?.trim() ?? '';
    if (raw.isEmpty || !_looksLikeEncodedLyrics(raw)) return raw;

    // 先用 Rust 歌词解析器解码 QRC/KRC 等格式，再把展示行写成标准 LRC。
    try {
      final parsed = jsonDecode(await parseLyrics(rawLyrics: raw));
      final decoded = _displayLinesToLrc(parsed);
      if (decoded.isNotEmpty) return decoded;
    } catch (_) {
      // 密文格式不完整时继续尝试向插件重新取一次歌词。
    }

    // 部分插件的搜索结果携带的是损坏的 lyric 字段，但 getLyrics 接口
    // 会返回正常正文；重新请求一次可避免把密文写入文件。
    final pluginId = item.pluginId?.trim() ?? '';
    final pluginData = item.pluginData;
    if (pluginId.isNotEmpty && pluginData != null) {
      try {
        final plugins = await ref.read(enabledMusicPluginsProvider.future);
        final plugin = plugins
            .where((candidate) => candidate.id == pluginId)
            .firstOrNull;
        if (plugin != null) {
          final retry =
              (await ref
                      .read(pluginRuntimeProvider)
                      .getLyrics(plugin, pluginData))
                  .trim();
          if (retry.isNotEmpty && !_looksLikeEncodedLyrics(retry)) {
            raw = retry;
          }
        }
      } catch (_) {
        // 歌词属于下载附加项，重新获取失败不应影响音频下载。
      }
    }
    // 无法可靠解码时宁可不保存歌词，也不要生成用户无法阅读的乱码文件。
    return _looksLikeEncodedLyrics(raw) ? '' : raw;
  }

  Future<void> _downloadCurrent(QueueItem item) async {
    if (playbackSourceTypeFor(item) == PlaybackSourceType.localFile) {
      XyNotice.show(context, message: '当前歌曲已经是本地文件');
      return;
    }
    // 整个下载流程都可能抛出异常（设置写入、地址解析、文件下载等），
    // 必须整体兜底，否则用户点击下载后没有任何反馈。
    try {
      await _downloadCurrentInner(item);
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '下载失败：${_errorText(error)}',
          type: XyNoticeType.error,
        );
      }
    }
  }

  Future<void> _downloadCurrentInner(QueueItem item) async {
    final settings = ref.read(settingsProvider).valueOrNull;
    final initialDirectory = await resolveMusicDownloadDirectory(settings);
    if (!mounted) return;
    // 先检查是否已下载过；已下载时由用户确认是否重新下载。
    final existing = await _existingDownloadFor(item);
    if (!mounted) return;
    final reDownloading = existing != null;
    if (existing != null) {
      final reDownload = await showDialog<bool>(
        context: context,
        useRootNavigator: true,
        builder: (context) => AlertDialog(
          title: const Text('歌曲已下载过'),
          content: Text(
            '《${existing.title}》已下载过'
            '${existing.quality == null || existing.quality!.isEmpty ? '' : '（${_qualityLabel(existing.quality!)}）'}，'
            '是否重新下载？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('重新下载'),
            ),
          ],
        ),
      );
      if (!mounted || reDownload != true) return;
    }
    final playback = ref.read(playerProvider);
    final shouldAsk = settings?.askDownloadDetails ?? true;
    _DownloadOptions? options;
    if (shouldAsk) {
      XyNotice.show(context, message: '正在读取插件支持的下载音质…');
      final qualities = await _discoverQualityOptions(
        item,
        preferred: playback.currentQuality,
      );
      if (!mounted) return;
      options = await showDialog<_DownloadOptions>(
        context: context,
        useRootNavigator: true,
        builder: (context) => _DownloadOptionsDialog(
          initialDirectory: initialDirectory,
          initialQuality: settings?.downloadQuality ?? playback.currentQuality,
          qualities: qualities,
        ),
      );
    } else {
      options = _DownloadOptions(
        directory: initialDirectory,
        quality: settings?.downloadQuality ?? playback.currentQuality,
      );
    }
    if (!mounted || options == null) return;
    if (ref.read(playerProvider).current?.path != item.path) {
      XyNotice.show(
        context,
        message: '歌曲已切换，请重新选择下载',
        type: XyNoticeType.warning,
      );
      return;
    }
    final quality = options.quality;
    final directory = options.directory.trim();
    final settingsNotifier = ref.read(settingsProvider.notifier);
    await settingsNotifier.setDownloadPath(directory);
    await settingsNotifier.setDownloadQuality(quality);
    if (options.dontAskAgain) {
      await settingsNotifier.setAskDownloadDetails(false);
    }
    if (!mounted) return;
    final usesSafDirectory = AndroidStorage.isTreeUri(directory);
    XyNotice.show(
      context,
      message: '下载已开始 ${item.title}',
      type: XyNoticeType.success,
    );
    try {
      final workDirectory = usesSafDirectory
          ? await resolveDownloadStagingDirectory()
          : directory;
      await Directory(workDirectory).create(recursive: true);
      final source = await ref
          .read(playerProvider.notifier)
          .resolveCurrentDownloadSource(quality)
          // 插件解析可能因网络卡死永久挂起，超时后转成可提示的错误。
          .timeout(const Duration(seconds: 60));
      if (ref.read(playerProvider).current?.path != item.path) {
        throw Exception('歌曲已切换，请重新选择下载');
      }
      final destination = await resolveDownloadFullPath(
        directory: workDirectory,
        title: item.title,
        artist: item.artist,
        album: item.album,
        url: source.url,
        quality: quality,
        keepSourceFilename: false,
        fileNameStyle: 'artist-title',
        // 用户已确认重新下载时直接覆盖旧文件，避免生成 "(1)" 副本。
        overwriteExisting: reDownloading,
      );
      final savedPath = await downloadOnlineSong(
        url: source.url,
        destPath: destination,
        headersJson: jsonEncode(source.headers),
      );
      final lyrics = await _lyricsForDownload(item);
      final coverUrl = item.coverUrl?.trim() ?? '';
      await finalizeDownloadExtras(
        requestJson: jsonEncode({
          if ((settings?.downloadLyrics ?? true) && lyrics.isNotEmpty)
            'lyricsText': lyrics,
          if ((settings?.downloadLyrics ?? true) && lyrics.isNotEmpty)
            'lyricsPath': p.setExtension(savedPath, '.lrc'),
          if (coverUrl.startsWith('http://') || coverUrl.startsWith('https://'))
            'coverUrl': coverUrl,
          'embedCover': true,
          'metadata': {
            'filePath': savedPath,
            'title': item.title,
            'artist': item.artist,
            'album': item.album,
            if (lyrics.isNotEmpty) 'lyrics': lyrics,
          },
        }),
      );
      var finalPath = savedPath;
      if (usesSafDirectory) {
        finalPath = await AndroidStorage.copyFileToDirectory(
          directoryUri: directory,
          sourcePath: savedPath,
          fileName: p.basename(savedPath),
          mimeType: 'audio/*',
        );
        final lrcPath = p.setExtension(savedPath, '.lrc');
        if (await File(lrcPath).exists()) {
          await AndroidStorage.copyFileToDirectory(
            directoryUri: directory,
            sourcePath: lrcPath,
            fileName: p.basename(lrcPath),
            mimeType: 'text/plain',
          );
        }
        try {
          await File(savedPath).delete();
          if (await File(lrcPath).exists()) await File(lrcPath).delete();
        } catch (_) {}
      }
      await rememberDownloadedSongSnapshot(
        DownloadedSongSnapshot(
          path: finalPath,
          title: item.title,
          artist: item.artist,
          album: item.album,
          durationMs: item.durationMs,
          downloadedAt: DateTime.now().millisecondsSinceEpoch,
          sourcePath: item.path,
          quality: quality,
          coverUrl: item.coverUrl,
          lyricsRaw: lyrics.isEmpty ? null : lyrics,
        ),
      );
      if (mounted) {
        XyNotice.show(
          context,
          message: '下载完成：${p.basename(savedPath)}',
          type: XyNoticeType.success,
        );
      }
    } catch (error) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '下载失败：${_errorText(error)}',
          type: XyNoticeType.error,
        );
      }
    }
  }

  Future<DownloadedSongSnapshot?> _existingDownloadFor(QueueItem item) async {
    final snapshots = await loadDownloadedSongSnapshots();
    final title = item.title.trim().toLowerCase();
    final artist = item.artist.trim().toLowerCase();
    snapshots.sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
    for (final snapshot in snapshots) {
      final sourceMatches = snapshot.sourcePath?.trim().isNotEmpty == true
          ? snapshot.sourcePath == item.path
          : snapshot.title.trim().toLowerCase() == title &&
                snapshot.artist.trim().toLowerCase() == artist;
      if (!sourceMatches) continue;
      final path = snapshot.path.trim();
      if (path.toLowerCase().startsWith('content://') ||
          await File(path).exists()) {
        return snapshot;
      }
    }
    return null;
  }

  String _qualityLabel(String quality) {
    final lower = quality.trim().toLowerCase();
    if (lower == '128k' || lower == 'standard') return '标准 128k';
    if (lower == '192k') return '较高 192k';
    if (lower == '320k' || lower == 'high') return '高品质 320k';
    if (lower == 'flac' || lower == 'lossless' || lower == 'sq') {
      return '无损 FLAC';
    }
    if (lower.contains('master')) return '超清母带';
    if (lower == 'hires' || lower == 'hi-res' || lower.contains('24bit')) {
      return 'Hi-Res 高清';
    }
    if (lower == 'ape') return 'APE 无损';
    if (lower == 'wav') return 'WAV 无损';
    if (lower == 'dolby' || lower == 'atmos') return '杜比全景声';
    return quality;
  }

  String _sleepTimerLabel(DateTime? endsAt) {
    if (endsAt == null) return '未开启';
    final seconds = sleepTimerRemainingSeconds(endsAt);
    return seconds <= 0
        ? '即将停止'
        : '剩余 ${_formatSleepDuration(Duration(seconds: seconds))}';
  }

  String _errorText(Object error) =>
      error.toString().replaceFirst('Exception: ', '').trim();

  void _showDetailPage(bool showLyrics) {
    if (_showLyrics != showLyrics) {
      setState(() => _showLyrics = showLyrics);
    }
    final page = showLyrics ? 1 : 0;
    if (_detailPageController.hasClients) {
      _detailPageController.animateToPage(
        page,
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic,
      );
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _detailPageController.hasClients) {
          _detailPageController.jumpToPage(page);
        }
      });
    }
  }

  void _checkLyricsOnEntry(QueueItem? current) {
    if (current == null || current.path.trim().isEmpty) return;
    final path = current.path;
    final notifier = ref.read(playerProvider.notifier);
    if (_lyricsCheckSongPath != path) {
      _lyricsCheckSongPath = path;
      unawaited(notifier.ensureCurrentLyricsChecked());
    }
    if (current.lyricsAttempted &&
        current.lyricsRaw?.trim().isNotEmpty != true &&
        !_noLyricsNoticeShownPaths.contains(path) &&
        _noLyricsNoticePath != path) {
      _noLyricsNoticePath = path;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final latest = ref.read(playerProvider).current;
        if (latest?.path != path ||
            latest?.lyricsRaw?.trim().isNotEmpty == true ||
            latest?.lyricsAttempted != true) {
          return;
        }
        _noLyricsNoticeShownPaths.add(path);
        XyNotice.show(
          context,
          message: '未检测到歌词，可点击右上角关联歌词',
          type: XyNoticeType.success,
          compact: true,
          blur: true,
        );
      });
    }
  }

  @override
  void dispose() {
    // 视频控制器由会话对象持有，退出详情页只销毁页面 UI，不暂停或释放视频。
    // 这样从详情页返回后，视频仍可继续播放；重新进入详情页时会重新绑定。
    VideoPlaybackSession.revision.removeListener(_syncVideoSession);
    _playingSubscription?.close();
    _playingSubscription = null;
    if (_screenAwake) {
      unawaited(_setScreenAwake(false));
    }
    _unbindVideoController(_videoController);
    _detailPageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 播放进度每 40–80ms 更新一次；这里只监听歌曲对象，避免进度变化导致
    // 全屏背景、封面和模糊层一起高频重建。
    final current = ref.watch(playerProvider.select((state) => state.current));
    _loadLyricsOffsetFor(current);
    if (_videoSongPath != null &&
        _videoSongPath != current?.path &&
        !_videoClosing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_videoClosing) unawaited(_closeBilibiliVideo());
      });
    }
    final notifier = ref.read(playerProvider.notifier);
    _checkLyricsOnEntry(current);
    final scheme = Theme.of(context).colorScheme;
    final viewport = MediaQuery.sizeOf(context);
    final isLandscape = viewport.width > viewport.height;

    final detailHeader = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 4,
        vertical: isLandscape ? 0 : 0,
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(
              Icons.keyboard_arrow_down,
              size: 28,
              color: Colors.white,
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  current?.title ?? '正在播放',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if ((current?.artist ?? '').isNotEmpty)
                  Text(
                    current!.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: .58),
                      fontSize: 11,
                    ),
                  ),
                const SizedBox(height: 4),
                if (_videoSongPath != current?.path)
                  _DetailPageIndicator(showLyrics: _showLyrics),
              ],
            ),
          ),
          IconButton(
            tooltip: '更多',
            icon: const Icon(Icons.more_horiz_rounded, color: Colors.white),
            onPressed: current == null ? null : () => _showMoreMenu(current),
          ),
        ],
      ),
    );

    final detailPager = LayoutBuilder(
      builder: (context, constraints) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: current == null ? null : _startDetailSwipe,
        onPointerMove: current == null ? null : _updateDetailSwipe,
        onPointerUp: current == null
            ? null
            : (event) => _finishDetailSwipe(event, constraints.maxWidth),
        onPointerCancel: current == null
            ? null
            : (event) => _finishDetailSwipe(event, constraints.maxWidth),
        child: PageView(
          controller: _detailPageController,
          physics: const NeverScrollableScrollPhysics(),
          onPageChanged: (page) {
            final showLyrics = page == 1;
            if (_showLyrics != showLyrics) {
              setState(() => _showLyrics = showLyrics);
            }
          },
          children: [
            _BigCover(
              key: ValueKey('cover:${current?.path ?? ''}'),
              item: current,
              offsetTenths: _lyricsOffsetTenths,
              onTap: current == null ? null : _toggleLyrics,
            ),
            if (current == null)
              const Center(
                child: Text('暂无歌词', style: TextStyle(color: Colors.white54)),
              )
            else
              _LyricsView(
                key: ValueKey('lyrics:${current.path}'),
                item: current,
                offsetTenths: _lyricsOffsetTenths,
              ),
          ],
        ),
      ),
    );

    final videoActive =
        _videoSongPath != null && _videoSongPath == current?.path;
    final detailControls = Padding(
      padding: EdgeInsets.fromLTRB(
        isLandscape ? 8 : 16,
        0,
        isLandscape ? 8 : 16,
        isLandscape ? 8 : 20,
      ),
      child: _GlassControlCard(
        notifier: notifier,
        current: current,
        showMetadata: !_showLyrics,
        onDownload: current == null
            ? null
            : () => unawaited(_downloadCurrent(current)),
        onAddToPlaylist: current == null
            ? null
            : () => unawaited(_addToPlaylist(current)),
        onLyricsOffset: current == null
            ? null
            : () => unawaited(_pickLyricsOffset(current)),
        onDesktopLyrics: () => unawaited(_toggleDesktopLyrics()),
        videoActive: videoActive,
        videoController: videoActive ? _videoController : null,
      ),
    );
    final detailContent = videoActive
        ? _BilibiliVideoView(
            controller: _videoController,
            loading: _videoLoading,
            error: _videoError,
          )
        : detailPager;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 电脑版详情页同款：封面铺满、重度模糊并叠加暗色氛围层。
          _PlayerDetailBackground(current: current),
          SafeArea(
            child: isLandscape
                ? Column(
                    children: [
                      detailHeader,
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: detailContent),
                            SizedBox(
                              width: math.min(360, viewport.width * .38),
                              child: Center(child: detailControls),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      detailHeader,
                      Expanded(child: detailContent),
                      detailControls,
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 播放详情页中的歌单选择器。创建歌单后会自动将当前歌曲加入新歌单。
enum _PlaylistPickKind { added, alreadyExists }

class _PlaylistPickResult {
  const _PlaylistPickResult(this.playlistId, this.kind);

  final String playlistId;
  final _PlaylistPickKind kind;
}

class _PlaylistPickerSheet extends ConsumerStatefulWidget {
  const _PlaylistPickerSheet({required this.item});

  final QueueItem item;

  @override
  ConsumerState<_PlaylistPickerSheet> createState() =>
      _PlaylistPickerSheetState();
}

class _PlaylistPickerSheetState extends ConsumerState<_PlaylistPickerSheet> {
  bool _busy = false;

  Future<void> _addTo(String playlistId) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final added = await ref
          .read(playlistsProvider.notifier)
          .addQueueItem(playlistId, widget.item);
      if (mounted) {
        Navigator.pop(
          context,
          _PlaylistPickResult(
            playlistId,
            added ? _PlaylistPickKind.added : _PlaylistPickKind.alreadyExists,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createAndAdd() async {
    if (_busy) return;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(hintText: '请输入歌单名称'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('创建并添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || name == null || name.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final playlist = await ref.read(playlistsProvider.notifier).create(name);
      if (playlist == null) return;
      await ref
          .read(playlistsProvider.notifier)
          .addQueueItem(playlist.id, widget.item);
      if (mounted) {
        // 新建歌单中不可能存在重复歌曲，结果恒为“已添加”。
        Navigator.pop(
          context,
          _PlaylistPickResult(playlist.id, _PlaylistPickKind.added),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .62,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                '添加到歌单',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                widget.item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: colorScheme.primaryContainer,
                child: Icon(Icons.add_rounded, color: colorScheme.primary),
              ),
              title: const Text('新建歌单'),
              subtitle: const Text('创建后自动添加当前歌曲'),
              trailing: const Icon(Icons.chevron_right_rounded),
              enabled: !_busy,
              onTap: _createAndAdd,
            ),
            const Divider(height: 1),
            Expanded(
              child: playlists.isEmpty
                  ? Center(
                      child: Text(
                        '还没有歌单，先新建一个吧',
                        style: TextStyle(color: colorScheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 12),
                      itemCount: playlists.length,
                      itemBuilder: (context, index) {
                        final playlist = playlists[index];
                        final firstPath = playlist.songPaths.isEmpty
                            ? playlist.id
                            : playlist.songPaths.first;
                        return ListTile(
                          leading: playlist.songPaths.isEmpty
                              ? CircleAvatar(
                                  backgroundColor:
                                      colorScheme.surfaceContainerHighest,
                                  child: Icon(
                                    Icons.queue_music_rounded,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                )
                              : CoverImage(
                                  songPath: firstPath,
                                  imageUrl: playlist.effectiveCoverUrl,
                                  width: 40,
                                  height: 40,
                                  radius: 20,
                                  icon: Icons.queue_music_rounded,
                                ),
                          title: Text(
                            playlist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text('${playlist.songPaths.length} 首歌曲'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          enabled: !_busy,
                          onTap: () => _addTo(playlist.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DownloadOptionsDialog extends StatefulWidget {
  const _DownloadOptionsDialog({
    required this.initialDirectory,
    required this.initialQuality,
    required this.qualities,
  });

  final String initialDirectory;
  final String initialQuality;
  final List<String> qualities;

  @override
  State<_DownloadOptionsDialog> createState() => _DownloadOptionsDialogState();
}

class _DownloadOptionsDialogState extends State<_DownloadOptionsDialog> {
  late final TextEditingController _directoryController;
  late String _directoryValue;
  late final List<String> _qualities;
  late String _quality;
  bool _dontAskAgain = false;
  bool _choosingDirectory = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _directoryValue = widget.initialDirectory;
    _directoryController = TextEditingController(
      text: AndroidStorage.displayPath(widget.initialDirectory),
    );
    _qualities = widget.qualities.isEmpty
        ? const ['320k']
        : widget.qualities.toSet().toList();
    _quality = _normalizeQuality(widget.initialQuality, _qualities);
  }

  @override
  void dispose() {
    _directoryController.dispose();
    super.dispose();
  }

  Future<void> _chooseDirectory() async {
    if (_choosingDirectory) return;
    setState(() {
      _choosingDirectory = true;
      _error = null;
    });
    try {
      final selected = Platform.isAndroid
          ? await AndroidStorage.pickDirectory()
          : await FilePicker.platform.getDirectoryPath();
      if (!mounted || selected == null) return;
      _directoryValue = selected;
      final displayPath = AndroidStorage.displayPath(selected);
      _directoryController.text = displayPath;
      _directoryController.selection = TextSelection.collapsed(
        offset: displayPath.length,
      );
      setState(() {});
    } catch (error) {
      if (mounted) setState(() => _error = '选择文件夹失败：$error');
    } finally {
      if (mounted) setState(() => _choosingDirectory = false);
    }
  }

  void _submit() {
    final directory = _directoryValue.trim();
    if (directory.isEmpty) {
      setState(() => _error = '请输入或选择下载文件夹');
      return;
    }
    Navigator.pop(
      context,
      _DownloadOptions(
        directory: directory,
        quality: _quality,
        dontAskAgain: _dontAskAgain,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('下载歌曲'),
      content: SizedBox(
        width: 360,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '下载位置',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _directoryController,
                        maxLines: 1,
                        style: const TextStyle(fontSize: 13),
                        onChanged: (value) {
                          _directoryValue = value;
                          if (_error != null) setState(() => _error = null);
                        },
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: '/storage/emulated/0/Music',
                          prefixIcon: Icon(Icons.folder_outlined, size: 19),
                          prefixIconConstraints: BoxConstraints(minWidth: 38),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 11,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 40,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 11),
                        ),
                        onPressed: _choosingDirectory ? null : _chooseDirectory,
                        icon: _choosingDirectory
                            ? const SizedBox.square(
                                dimension: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.folder_open_rounded, size: 18),
                        label: Text(
                          _choosingDirectory ? '选择中' : '选择',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '下载音质',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                _QualitySelector(
                  qualities: _qualities,
                  selected: _quality,
                  onSelected: (quality) => setState(() => _quality = quality),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: _dontAskAgain,
                  onChanged: (value) =>
                      setState(() => _dontAskAgain = value == true),
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    '不再弹出此窗口',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('开始下载')),
      ],
    );
  }

  static String _normalizeQuality(String quality, List<String> available) {
    final value = quality.trim();
    if (available.contains(value)) return value;
    final alias = switch (value.toLowerCase()) {
      'standard' => '128k',
      'lossless' || 'sq' => 'flac',
      'high' => '320k',
      _ => value,
    };
    if (available.contains(alias)) return alias;
    return available.first;
  }

  static String _qualityLabel(String quality) {
    final lower = quality.trim().toLowerCase();
    if (lower == '128k' || lower == 'standard') return '标准 128k';
    if (lower == '192k') return '较高 192k';
    if (lower == '320k' || lower == 'high') return '高品质 320k';
    if (lower == 'flac' || lower == 'lossless' || lower == 'sq') {
      return '无损 FLAC';
    }
    if (lower.contains('master')) return '超清母带';
    if (lower == 'hires' || lower == 'hi-res' || lower.contains('24bit')) {
      return 'Hi-Res 高清';
    }
    if (lower == 'ape') return 'APE 无损';
    if (lower == 'wav') return 'WAV 无损';
    if (lower == 'dolby' || lower == 'atmos') return '杜比全景声';
    return quality;
  }
}

class _QualitySelector extends StatefulWidget {
  const _QualitySelector({
    required this.qualities,
    required this.selected,
    required this.onSelected,
  });

  final List<String> qualities;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  State<_QualitySelector> createState() => _QualitySelectorState();
}

class _QualitySelectorState extends State<_QualitySelector> {
  static const double _spacing = 6;
  static const double _runSpacing = 5;
  static const int _maxRows = 2;

  final GlobalKey _offstageWrapKey = GlobalKey();
  final GlobalKey _expandButtonKey = GlobalKey();
  final List<GlobalKey> _chipKeys = <GlobalKey>[];

  bool _expanded = false;
  bool _overflow = false;
  int _visibleCount = 0;

  @override
  void initState() {
    super.initState();
    _visibleCount = widget.qualities.length;
  }

  List<GlobalKey> get _keys {
    while (_chipKeys.length < widget.qualities.length) {
      _chipKeys.add(GlobalKey());
    }
    return _chipKeys;
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    final chips = <Widget>[
      for (final quality in widget.qualities) _buildChip(quality),
    ];
    final Widget visible;
    if (!_overflow || _expanded) {
      visible = Wrap(
        spacing: _spacing,
        runSpacing: _runSpacing,
        children: [
          ...chips,
          if (_overflow) _buildToggleChip(expanded: true),
        ],
      );
    } else {
      visible = Wrap(
        spacing: _spacing,
        runSpacing: _runSpacing,
        children: [
          ...chips.sublist(0, _visibleCount),
          _buildToggleChip(expanded: false),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        visible,
        Offstage(
          child: Wrap(
            key: _offstageWrapKey,
            spacing: _spacing,
            runSpacing: _runSpacing,
            children: [
              for (var i = 0; i < widget.qualities.length; i++)
                _buildChip(widget.qualities[i], key: _keys[i]),
              _buildToggleChip(expanded: false, key: _expandButtonKey),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildChip(String quality, {Key? key}) {
    return ChoiceChip(
      key: key,
      label: Text(
        _DownloadOptionsDialogState._qualityLabel(quality),
        style: const TextStyle(fontSize: 12),
      ),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 3),
      selected: widget.selected == quality,
      onSelected: (_) => widget.onSelected(quality),
    );
  }

  Widget _buildToggleChip({required bool expanded, Key? key}) {
    return ActionChip(
      key: key,
      avatar: Icon(
        expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
        size: 16,
      ),
      label: Text(
        expanded ? '收起' : '展开更多',
        style: const TextStyle(fontSize: 12),
      ),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 3),
      onPressed: () => setState(() => _expanded = !expanded),
    );
  }

  void _measure() {
    if (!mounted) return;
    final wrapObject = _offstageWrapKey.currentContext?.findRenderObject();
    final buttonContext = _expandButtonKey.currentContext;
    if (wrapObject is! RenderBox || buttonContext == null) return;
    final buttonSize = buttonContext.size;
    if (buttonSize == null) return;
    final available = wrapObject.constraints.maxWidth;
    if (!available.isFinite) return;

    final widths = <double>[];
    for (final key in _keys) {
      final size = key.currentContext?.size;
      if (size == null) return;
      widths.add(size.width);
    }
    final buttonWidth = buttonSize.width;

    final overflow = _rowsFor([...widths, buttonWidth], available) > _maxRows;
    var visibleCount = widget.qualities.length;
    if (overflow) {
      visibleCount = 1;
      for (var i = 0; i < widths.length; i++) {
        final candidate = [...widths.sublist(0, i + 1), buttonWidth];
        if (_rowsFor(candidate, available) <= _maxRows) {
          visibleCount = i + 1;
        } else {
          break;
        }
      }
    }
    if (overflow != _overflow ||
        (!_expanded && visibleCount != _visibleCount)) {
      setState(() {
        _overflow = overflow;
        _visibleCount = visibleCount;
      });
    }
  }

  int _rowsFor(List<double> widths, double available) {
    var rows = 1;
    var used = 0.0;
    for (final width in widths) {
      if (used == 0) {
        used = width;
      } else if (used + _spacing + width <= available + 1) {
        used += _spacing + width;
      } else {
        rows++;
        used = width;
      }
    }
    return rows;
  }
}

class _LyricsOffsetDialog extends StatefulWidget {
  const _LyricsOffsetDialog({required this.initialOffsetTenths});

  final int initialOffsetTenths;

  @override
  State<_LyricsOffsetDialog> createState() => _LyricsOffsetDialogState();
}

class _LyricsOffsetDialogState extends State<_LyricsOffsetDialog> {
  late int _offsetTenths;

  @override
  void initState() {
    super.initState();
    _offsetTenths = clampLyricsOffsetTenths(widget.initialOffsetTenths);
  }

  void _change(int delta) {
    setState(() {
      _offsetTenths = clampLyricsOffsetTenths(_offsetTenths + delta);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('当前歌曲歌词偏移'),
      content: SizedBox(
        width: 330,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                lyricsOffsetLabel(_offsetTenths),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Slider(
              value: _offsetTenths.toDouble(),
              min: -100,
              max: 100,
              divisions: 200,
              label: lyricsOffsetLabel(_offsetTenths),
              onChanged: (value) {
                setState(() => _offsetTenths = value.round());
              },
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('延后 10 秒', style: TextStyle(fontSize: 11)),
                  Text('同步', style: TextStyle(fontSize: 11)),
                  Text('提前 10 秒', style: TextStyle(fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.filledTonal(
                  tooltip: '歌词延后 0.1 秒',
                  onPressed: _offsetTenths <= -100 ? null : () => _change(-1),
                  icon: const Icon(Icons.remove_rounded),
                ),
                const SizedBox(width: 10),
                TextButton(
                  onPressed: _offsetTenths == 0
                      ? null
                      : () => setState(() => _offsetTenths = 0),
                  child: const Text('恢复同步'),
                ),
                const SizedBox(width: 10),
                IconButton.filledTonal(
                  tooltip: '歌词提前 0.1 秒',
                  onPressed: _offsetTenths >= 100 ? null : () => _change(1),
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '每次调整 0.1 秒，仅对当前歌曲生效并记忆。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _offsetTenths),
          child: const Text('应用'),
        ),
      ],
    );
  }
}

class _CustomSleepTimerDialog extends StatefulWidget {
  const _CustomSleepTimerDialog();

  @override
  State<_CustomSleepTimerDialog> createState() =>
      _CustomSleepTimerDialogState();
}

class _CustomSleepTimerDialogState extends State<_CustomSleepTimerDialog> {
  late final TextEditingController _hoursController = TextEditingController(
    text: '0',
  );
  late final TextEditingController _minutesController = TextEditingController(
    text: '0',
  );
  late final TextEditingController _secondsController = TextEditingController(
    text: '30',
  );
  String? _error;

  @override
  void dispose() {
    _hoursController.dispose();
    _minutesController.dispose();
    _secondsController.dispose();
    super.dispose();
  }

  void _submit() {
    final hours = int.tryParse(_hoursController.text) ?? 0;
    final minutes = int.tryParse(_minutesController.text) ?? 0;
    final seconds = int.tryParse(_secondsController.text) ?? 0;
    if (minutes > 59 || seconds > 59) {
      setState(() => _error = '分钟和秒数需填写 0–59');
      return;
    }
    final duration = Duration(hours: hours, minutes: minutes, seconds: seconds);
    if (!isValidSleepTimerDuration(duration)) {
      setState(() => _error = '定时时长必须在 30 秒至 12 小时之间');
      return;
    }
    Navigator.pop(context, duration);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('自定义定时关闭'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('设置停止播放前的等待时间'),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _durationField(
                      controller: _hoursController,
                      label: '小时',
                      nextAction: TextInputAction.next,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _durationField(
                      controller: _minutesController,
                      label: '分钟',
                      nextAction: TextInputAction.next,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _durationField(
                      controller: _secondsController,
                      label: '秒',
                      nextAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: Text(
                  _error ?? '最短 30 秒，最长 12 小时',
                  key: ValueKey(_error),
                  style: TextStyle(
                    fontSize: 12,
                    color: _error == null
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }

  Widget _durationField({
    required TextEditingController controller,
    required String label,
    required TextInputAction nextAction,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      textInputAction: nextAction,
      textAlign: TextAlign.center,
      selectAllOnFocus: true,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(2),
      ],
      decoration: InputDecoration(labelText: label, counterText: ''),
      onChanged: (_) {
        if (_error != null) setState(() => _error = null);
      },
      onSubmitted: onSubmitted,
    );
  }
}

class _AssociatedLyricsCard extends StatelessWidget {
  const _AssociatedLyricsCard({
    required this.association,
    required this.onCancel,
  });

  final RememberedLyricsAssociation association;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final source = association.source == 'plugin'
        ? (association.pluginName?.trim().isNotEmpty == true
              ? '插件：${association.pluginName}'
              : '插件歌词')
        : '本地歌词';
    final title = association.title.trim().isEmpty
        ? '当前歌曲歌词'
        : association.title;
    final artist = association.artist.trim().isEmpty
        ? '未知作者'
        : association.artist;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.link_rounded, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '已关联歌词',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  '$source · $title',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  '$artist · ${_formatAssociatedLyricsDuration(association.durationMs)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          TextButton(onPressed: onCancel, child: const Text('取消关联')),
        ],
      ),
    );
  }
}

String _formatAssociatedLyricsDuration(int durationMs) {
  if (durationMs <= 0) return '--:--';
  final seconds = durationMs ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class _PluginLyricsSearchSheet extends ConsumerStatefulWidget {
  const _PluginLyricsSearchSheet({required this.item});

  final QueueItem item;

  @override
  ConsumerState<_PluginLyricsSearchSheet> createState() =>
      _PluginLyricsSearchSheetState();
}

class _PluginLyricsSearchSheetState
    extends ConsumerState<_PluginLyricsSearchSheet> {
  late final TextEditingController _controller;
  late final String _defaultQuery;
  List<PluginLyricsOption> _options = const [];
  bool _searching = false;
  bool _searched = false;
  bool _queryEdited = false;
  int _completedPlugins = 0;
  int _totalPlugins = 0;
  String? _applyingId;
  String? _error;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _defaultQuery = createDefaultPluginLyricsSearchQuery(
      widget.item.title,
      widget.item.artist,
    );
    _controller = TextEditingController(text: _defaultQuery)
      ..selection = TextSelection.collapsed(offset: _defaultQuery.length);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeSearch());
  }

  @override
  void dispose() {
    _requestId++;
    _controller.dispose();
    super.dispose();
  }

  String get _searchMemoryId {
    final path = widget.item.path.trim();
    if (path.isNotEmpty) return path;
    return '${widget.item.title}\u0000${widget.item.artist}';
  }

  Future<String?> _loadRememberedQuery() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pluginLyricsSearchMemoryKey);
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final value = decoded[_searchMemoryId]?.toString().trim() ?? '';
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  Future<void> _rememberQueryIfEdited(String query) async {
    if (!_queryEdited || query.isEmpty || query == _defaultQuery) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final decoded = jsonDecode(
        prefs.getString(_pluginLyricsSearchMemoryKey) ?? '{}',
      );
      final values = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
      values[_searchMemoryId] = query;
      // 避免极少数设备积累大量歌曲查询记录，保留最近 200 首即可。
      while (values.length > 200) {
        values.remove(values.keys.first);
      }
      await prefs.setString(_pluginLyricsSearchMemoryKey, jsonEncode(values));
    } catch (_) {
      // 搜索本身不应因偏好记忆写入失败而中断。
    }
  }

  Future<void> _initializeSearch() async {
    final remembered = await _loadRememberedQuery();
    if (!mounted) return;
    if (remembered != null && remembered != _controller.text) {
      _controller.value = TextEditingValue(
        text: remembered,
        selection: TextSelection.collapsed(offset: remembered.length),
      );
    }
    await _search();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty || _searching) return;
    await _rememberQueryIfEdited(query);
    final requestId = ++_requestId;
    setState(() {
      _searching = true;
      _searched = true;
      _options = const [];
      _completedPlugins = 0;
      _totalPlugins = 0;
      _error = null;
    });
    try {
      await for (final progress
          in ref
              .read(playerProvider.notifier)
              .findCurrentLyricsFromPluginsProgress(query: query)) {
        if (!mounted || requestId != _requestId) break;
        final merged = <String, PluginLyricsOption>{
          for (final option in _options) option.id: option,
          for (final option in progress.options) option.id: option,
        };
        final options = merged.values.toList()
          ..sort((a, b) {
            final pluginOrder = a.pluginName.compareTo(b.pluginName);
            return pluginOrder != 0 ? pluginOrder : a.id.compareTo(b.id);
          });
        setState(() {
          _options = options;
          _completedPlugins = progress.completedPlugins;
          _totalPlugins = progress.totalPlugins;
        });
      }
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() => _error = _errorMessage(error));
    } finally {
      if (mounted && requestId == _requestId) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _apply(PluginLyricsOption option) async {
    if (_applyingId != null) return;
    setState(() {
      _applyingId = option.id;
      _error = null;
    });
    try {
      final loaded = await ref
          .read(playerProvider.notifier)
          .loadLyricsForOption(option);
      if (!mounted) return;
      if (ref.read(playerProvider).current?.path != widget.item.path) {
        throw Exception('歌曲已切换，请重新选择歌词');
      }
      Navigator.pop(context, loaded);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _applyingId = null;
        _error = _errorMessage(error);
      });
    }
  }

  String _errorMessage(Object error) =>
      error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final availableHeight =
        MediaQuery.sizeOf(context).height - viewInsets.bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: math.min(availableHeight * .82, 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '选择插件歌词',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${widget.item.title} · ${widget.item.artist}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        enabled: !_searching && _applyingId == null,
                        textInputAction: TextInputAction.search,
                        onChanged: (_) {
                          _queryEdited = true;
                          setState(() {});
                        },
                        onSubmitted: (_) => _search(),
                        decoration: const InputDecoration(
                          hintText: '输入歌名、歌手或其他搜索内容',
                          prefixIcon: Icon(Icons.search_rounded),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed:
                          _searching ||
                              _applyingId != null ||
                              _controller.text.trim().isEmpty
                          ? null
                          : _search,
                      child: _searching
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('搜索'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '各插件结果会逐个显示，点击候选歌曲后再获取歌词。',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (_searching && _totalPlugins > 0)
                      Text(
                        '$_completedPlugins/$_totalPlugins 个插件',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      )
                    else if (_options.isNotEmpty)
                      Text(
                        '共 ${_options.length} 个候选',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (_error != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.errorContainer.withValues(alpha: .55),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              Expanded(child: _buildResults(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    if (_options.isNotEmpty) {
      return Column(
        children: [
          if (_searching)
            LinearProgressIndicator(
              minHeight: 2,
              value: _totalPlugins > 0
                  ? _completedPlugins / _totalPlugins
                  : null,
            ),
          Expanded(
            child: _PluginLyricsTabs(
              key: ValueKey(
                _options.map((option) => option.pluginId).toSet().join('|'),
              ),
              options: _options,
              applyingId: _applyingId,
              onSelected: _apply,
            ),
          ),
        ],
      );
    }
    if (_searching) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text(
              _totalPlugins > 0
                  ? '正在搜索插件（$_completedPlugins/$_totalPlugins）…'
                  : '正在启动插件搜索…',
            ),
          ],
        ),
      );
    }
    if (_searched && _error == null) {
      return const Center(child: Text('已启用插件均未返回搜索结果'));
    }
    return const Center(child: Text('输入搜索内容后查看插件结果'));
  }
}

class _PluginLyricsTabs extends StatelessWidget {
  const _PluginLyricsTabs({
    super.key,
    required this.options,
    required this.applyingId,
    required this.onSelected,
  });

  final List<PluginLyricsOption> options;
  final String? applyingId;
  final ValueChanged<PluginLyricsOption> onSelected;

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<PluginLyricsOption>>{};
    final pluginNames = <String, String>{};
    for (final option in options) {
      grouped.putIfAbsent(option.pluginId, () => []).add(option);
      pluginNames[option.pluginId] = option.pluginName;
    }
    final pluginIds = grouped.keys.toList();
    return DefaultTabController(
      length: pluginIds.length,
      child: Column(
        children: [
          Material(
            color: Colors.transparent,
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                for (final id in pluginIds)
                  Tab(text: '${pluginNames[id]} (${grouped[id]!.length})'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                for (final id in pluginIds)
                  _pluginLyricsList(context, grouped[id]!),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pluginLyricsList(
    BuildContext context,
    List<PluginLyricsOption> items,
  ) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, index) {
        final option = items[index];
        final artist = option.songArtist.trim().isEmpty
            ? '未知歌手'
            : option.songArtist;
        final album = option.songAlbum.trim();
        return ListTile(
          minTileHeight: 76,
          leading: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: Text(
              '${index + 1}',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          title: Text(
            option.songTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            album.isEmpty ? artist : '$artist · $album',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: option.id == applyingId
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatLyricsDuration(option.durationMs),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '应用',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
          enabled: applyingId == null,
          onTap: () => onSelected(option),
        );
      },
    );
  }

  static String _formatLyricsDuration(int durationMs) {
    if (durationMs <= 0) return '--:--';
    final seconds = durationMs ~/ 1000;
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return '$minutes:${remainder.toString().padLeft(2, '0')}';
  }
}

class _DetailPageIndicator extends StatelessWidget {
  const _DetailPageIndicator({required this.showLyrics});

  final bool showLyrics;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: showLyrics ? '歌词页，可向右滑动显示封面' : '封面页，可向左滑动显示歌词',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _indicatorPart(active: !showLyrics),
          const SizedBox(width: 4),
          _indicatorPart(active: showLyrics),
        ],
      ),
    );
  }

  Widget _indicatorPart({required bool active}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      width: active ? 16 : 4,
      height: 4,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: active ? .9 : .34),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}

class _PlayerDetailBackground extends ConsumerWidget {
  const _PlayerDetailBackground({required this.current});

  final QueueItem? current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = MediaQuery.sizeOf(context);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final mode =
        settings?.playerDetailBackgroundMode ??
        PlayerDetailBackgroundMode.coverBlur;
    final wallpaperPath = settings?.customBackgroundPath.trim() ?? '';
    final detailImagePath = settings?.playerDetailCustomImagePath.trim() ?? '';
    final wallpaperBlur = settings?.customBackgroundBlur ?? 18.0;

    final backdrop = switch (mode) {
      PlayerDetailBackgroundMode.coverBlur => _coverBackdrop(current, size),
      PlayerDetailBackgroundMode.wallpaperBlur =>
        wallpaperPath.isEmpty
            ? _flowingLightBackdrop()
            : _wallpaperBackdrop(wallpaperPath, wallpaperBlur, blurred: true),
      PlayerDetailBackgroundMode.flowingLight => _flowingLightBackdrop(),
      PlayerDetailBackgroundMode.customImage =>
        detailImagePath.isEmpty
            ? _flowingLightBackdrop()
            : _wallpaperBackdrop(
                detailImagePath,
                wallpaperBlur,
                blurred: false,
              ),
    };

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: backdrop),
          ColoredBox(color: const Color(0xFF080A0F).withValues(alpha: .58)),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x29000000),
                  Color(0x12000000),
                  Color(0xA6000000),
                ],
                stops: [0, .48, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _coverBackdrop(QueueItem? item, Size size) {
    if (item == null) return const ColoredBox(color: Color(0xFF0B0D12));
    // 封面模式保持原有氛围背景样式，不额外施加模糊滤镜。
    return Transform.scale(
      scale: 1.24,
      child: Opacity(
        opacity: .46,
        child: CoverImage(
          key: ValueKey('background:${item.path}'),
          songPath: item.path,
          imageUrl: item.coverUrl,
          width: size.width,
          height: size.height,
          radius: 0,
          cacheWidth: 256,
          icon: Icons.music_note_rounded,
        ),
      ),
    );
  }

  Widget _wallpaperBackdrop(String path, double blur, {required bool blurred}) {
    Widget image = Image.file(
      File(path),
      fit: BoxFit.cover,
      cacheWidth: 1440,
      gaplessPlayback: true,
      filterQuality: FilterQuality.low,
      errorBuilder: (_, _, _) => const SizedBox.expand(),
    );
    if (blurred) {
      image = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: blur.clamp(0, 40),
          sigmaY: blur.clamp(0, 40),
        ),
        child: image,
      );
    }
    return image;
  }

  Widget _flowingLightBackdrop() => const _FlowingLightBackground();
}

class _FlowingLightBackground extends StatefulWidget {
  const _FlowingLightBackground();

  @override
  State<_FlowingLightBackground> createState() =>
      _FlowingLightBackgroundState();
}

class _FlowingLightBackgroundState extends State<_FlowingLightBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (_, _) => CustomPaint(
      painter: _FlowingLightPainter(_controller.value),
      child: const SizedBox.expand(),
    ),
  );
}

class _FlowingLightPainter extends CustomPainter {
  const _FlowingLightPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xFF0B0D12), BlendMode.srcOver);
    final phase = progress * math.pi * 2;
    final points = [
      (
        Offset(size.width * (.18 + .18 * math.sin(phase)), size.height * .12),
        const Color(0x88EC4141),
      ),
      (
        Offset(size.width * (.82 + .16 * math.cos(phase)), size.height * .62),
        const Color(0x664C6FFF),
      ),
      (
        Offset(
          size.width * (.45 + .2 * math.sin(phase + 1)),
          size.height * .95,
        ),
        const Color(0x5548C6EF),
      ),
    ];
    for (final (center, color) in points) {
      final radius = math.max(size.width, size.height) * .78;
      final paint = Paint()
        ..shader = ui.Gradient.radial(center, radius, [
          color,
          color.withValues(alpha: 0),
        ]);
      canvas.drawRect(Offset.zero & size, paint);
    }
  }

  @override
  bool shouldRepaint(_FlowingLightPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _BilibiliVideoView extends StatelessWidget {
  const _BilibiliVideoView({
    required this.controller,
    required this.loading,
    required this.error,
  });

  final VideoPlayerController? controller;
  final bool loading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final player = controller;
    final initialized = player?.value.isInitialized == true;
    return ColoredBox(
      // 保留视频原始比例，黑边区域透明显示详情页背景，避免裁剪视频内容。
      color: Colors.transparent,
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (initialized)
              GestureDetector(
                onTap: () {
                  if (player.value.isPlaying) {
                    player.pause();
                  } else {
                    player.play();
                  }
                },
                child: AspectRatio(
                  aspectRatio: player!.value.aspectRatio > 0
                      ? player.value.aspectRatio
                      : 16 / 9,
                  child: VideoPlayer(player),
                ),
              ),
            if (loading) const CircularProgressIndicator(color: Colors.white),
            if (error?.trim().isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '视频播放失败\n$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, height: 1.5),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BigCover extends StatelessWidget {
  const _BigCover({
    super.key,
    this.item,
    required this.offsetTenths,
    this.onTap,
  });
  final QueueItem? item;
  final int offsetTenths;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final normalSide = math.min(
          390.0,
          math.min(constraints.maxWidth * .72, constraints.maxHeight - 104),
        );
        final showCoverExtras = normalSide >= 150;
        final side = showCoverExtras
            ? normalSide
            : math.max(
                1.0,
                math.min(
                  390.0,
                  math.min(constraints.maxWidth * .72, constraints.maxHeight),
                ),
              );
        return Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: SizedBox(
                width: side,
                height: side + (showCoverExtras ? 104 : 0),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (showCoverExtras)
                      Positioned(
                        top: side - 2,
                        left: 7,
                        right: 7,
                        height: 58,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(22),
                              gradient: const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Color(0x24FFFFFF), Colors.transparent],
                              ),
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      top: 0,
                      left: 0,
                      child: Semantics(
                        button: onTap != null,
                        label: onTap == null ? null : '显示歌词',
                        child: Container(
                          width: side,
                          height: side,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x99000000),
                                blurRadius: 44,
                                spreadRadius: -8,
                                offset: Offset(0, 24),
                              ),
                            ],
                          ),
                          child: Material(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(24),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: onTap,
                              child: _cover(side, radius: 24),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (item != null && showCoverExtras)
                      Positioned(
                        top: side + 43,
                        left: -28,
                        right: -28,
                        height: 56,
                        child: AbsorbPointer(
                          child: _MiniLyrics(
                            item: item!,
                            offsetTenths: offsetTenths,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _cover(double size, {required double radius, int? cacheWidth}) {
    final current = item;
    if (current == null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: const ColoredBox(
          color: Color(0xFF272A31),
          child: Center(
            child: Icon(Icons.music_note_rounded, color: Colors.white54),
          ),
        ),
      );
    }
    return CoverImage(
      key: ValueKey('main:${current.path}:${current.coverUrl ?? ''}'),
      songPath: current.path,
      imageUrl: current.coverUrl,
      width: size,
      height: size,
      radius: radius,
      cacheWidth: cacheWidth,
      highQuality: true,
      icon: Icons.music_note_rounded,
    );
  }
}

class _MiniLyrics extends ConsumerWidget {
  const _MiniLyrics({required this.item, required this.offsetTenths});

  final QueueItem item;
  final int offsetTenths;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = applyLyricsOffset(
      ref.watch(playerProvider.select((state) => state.position)),
      offsetTenths,
    );
    final embedded = item.lyricsRaw?.trim() ?? '';
    if (embedded.isNotEmpty) {
      return _buildAsync(
        ref.watch(_embeddedLyricsProvider(embedded)),
        position,
      );
    }
    if (item.pluginId != null && !item.lyricsAttempted) {
      return _message('正在获取歌词…');
    }
    if (item.pluginId != null) {
      return _message('暂无歌词');
    }
    return _buildAsync(ref.watch(_lyricsProvider(item.path)), position);
  }

  Widget _buildAsync(AsyncValue<List<_LyricLine>> lyrics, double position) {
    return lyrics.when(
      loading: () => _message('正在获取歌词…'),
      error: (_, _) => _message('暂无歌词'),
      data: (lines) {
        if (lines.isEmpty) return _message('暂无歌词');
        var active = lines.lastIndexWhere((line) => line.time <= position);
        if (active < 0) active = 0;
        final current = lines[active];
        final translation = current.translation.trim();
        final secondary = translation.isNotEmpty
            ? translation
            : active + 1 < lines.length
            ? lines[active + 1].text
            : '';
        return _surface(
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, .22),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            child: Column(
              key: ValueKey('${item.path}:${current.time}'),
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  current.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 10)],
                  ),
                ),
                if (secondary.trim().isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    secondary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: .5),
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _message(String text) {
    return _surface(
      Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white.withValues(alpha: .5),
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _surface(Widget child) {
    return Center(child: child);
  }
}

class _LyricsView extends ConsumerStatefulWidget {
  const _LyricsView({
    super.key,
    required this.item,
    required this.offsetTenths,
  });
  final QueueItem item;
  final int offsetTenths;

  @override
  ConsumerState<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<_LyricsView>
    with AutomaticKeepAliveClientMixin<_LyricsView> {
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _lineKeys = {};
  bool _scrollScheduled = false;
  int _coarseScrollTarget = -1;
  int _lastScrollTarget = -1;
  int _pendingScrollTarget = -1;
  bool _userScrolling = false;
  Timer? _resumeAutoScrollTimer;
  List<_LyricLine> _latestLines = const [];

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(_LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.path != widget.item.path) {
      _coarseScrollTarget = -1;
      _lastScrollTarget = -1;
      _pendingScrollTarget = -1;
      _userScrolling = false;
      _resumeAutoScrollTimer?.cancel();
      _lineKeys.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      });
    } else if (oldWidget.offsetTenths != widget.offsetTenths) {
      // 偏移变化（含恢复同步）会移动活动行；重置滚动目标，强制
      // 下一帧重新同步滚动，确保歌词能滚回正确行而不是停留在原处。
      _lastScrollTarget = -1;
    }
  }

  @override
  void dispose() {
    _resumeAutoScrollTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final position = applyLyricsOffset(
      ref.watch(playerProvider.select((state) => state.position)),
      widget.offsetTenths,
    );
    final effectMode =
        ref.watch(settingsProvider).valueOrNull?.lyricWordEffectMode ??
        LyricWordEffectMode.progressive;
    final lyricAlignment =
        ref.watch(settingsProvider).valueOrNull?.lyricDisplayAlignment ??
        LyricDisplayAlignment.left;
    final baseFontSize =
        ref.watch(settingsProvider).valueOrNull?.lyricFontSize ?? 18.0;
    final textAlign = switch (lyricAlignment) {
      LyricDisplayAlignment.left => TextAlign.left,
      LyricDisplayAlignment.center => TextAlign.center,
      LyricDisplayAlignment.right => TextAlign.right,
    };
    final embedded = widget.item.lyricsRaw?.trim() ?? '';
    late final Widget content;
    if (embedded.isNotEmpty) {
      final lyrics = ref.watch(_embeddedLyricsProvider(embedded));
      content = lyrics.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => _lyricsEmpty(context, '歌词解析失败'),
        data: (lines) =>
            _buildLines(lines, position, effectMode, textAlign, baseFontSize),
      );
    } else if (widget.item.pluginId != null && !widget.item.lyricsAttempted) {
      content = _lyricsEmpty(context, '正在获取歌词…');
    } else if (widget.item.pluginId != null) {
      content = _lyricsEmpty(context, '暂无歌词');
    } else {
      final lyrics = ref.watch(_lyricsProvider(widget.item.path));
      content = lyrics.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => _lyricsEmpty(context, '暂无歌词'),
        data: (lines) =>
            _buildLines(lines, position, effectMode, textAlign, baseFontSize),
      );
    }
    return content;
  }

  Widget _buildLines(
    List<_LyricLine> lines,
    double position,
    LyricWordEffectMode effectMode,
    TextAlign textAlign,
    double baseFontSize,
  ) {
    if (lines.isEmpty) {
      return _lyricsEmpty(context, '暂无歌词');
    }
    _latestLines = lines;
    var active = lines.lastIndexWhere((line) => line.time <= position);
    if (active < 0) active = 0;
    _syncScroll(active, lines);
    final size = MediaQuery.sizeOf(context);
    final compactVertical = size.width > size.height;
    final indicatorOnRight = textAlign == TextAlign.right;
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            Positioned.fill(
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.white,
                    Colors.white,
                    Colors.transparent,
                  ],
                  stops: [0, .28, .72, 1],
                ).createShader(rect),
                child: NotificationListener<ScrollNotification>(
                  onNotification: _handleScrollNotification,
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: EdgeInsets.fromLTRB(
                      26,
                      compactVertical ? 28 : 124,
                      26,
                      compactVertical ? 28 : 124,
                    ),
                    itemCount: lines.length,
                    itemBuilder: (context, index) {
                      final line = lines[index];
                      final selected = index == active;
                      return InkWell(
                        key: _lineKeys.putIfAbsent(index, GlobalKey.new),
                        onTap: () => ref
                            .read(playerProvider.notifier)
                            .seek(
                              playbackPositionForLyric(
                                line.time,
                                widget.offsetTenths,
                              ),
                            ),
                        borderRadius: BorderRadius.circular(12),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          padding: EdgeInsets.fromLTRB(
                            selected && !indicatorOnRight ? 14 : 8,
                            10,
                            selected && indicatorOnRight ? 14 : 8,
                            10,
                          ),
                          decoration: BoxDecoration(
                            border: selected
                                ? Border(
                                    // 当前歌词指示线跟随主题色；歌词靠右时
                                    // 指示线同步移动到右侧。
                                    left: indicatorOnRight
                                        ? BorderSide.none
                                        : BorderSide(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                            width: 3,
                                          ),
                                    right: indicatorOnRight
                                        ? BorderSide(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                            width: 3,
                                          )
                                        : BorderSide.none,
                                  )
                                : null,
                          ),
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            opacity: selected ? 1 : .34,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _TimedLyricText(
                                  line: line,
                                  position: position,
                                  selected: selected,
                                  effectMode: effectMode,
                                  textAlign: textAlign,
                                  baseFontSize: baseFontSize,
                                ),
                                if (line.translation.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    line.translation,
                                    textAlign: textAlign,
                                    style: TextStyle(
                                      fontSize: (baseFontSize - 5).clamp(
                                        10.0,
                                        26.0,
                                      ),
                                      color: Colors.white.withValues(
                                        alpha: .68,
                                      ),
                                    ),
                                  ),
                                ],
                                if (line.romaji.isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    line.romaji,
                                    textAlign: textAlign,
                                    style: TextStyle(
                                      fontSize: (baseFontSize - 6).clamp(
                                        9.0,
                                        24.0,
                                      ),
                                      color: Colors.white.withValues(
                                        alpha: .48,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _syncScroll(int active, List<_LyricLine> lines) {
    _pendingScrollTarget = active;
    if (_userScrolling || _lastScrollTarget == active) return;
    if (_scrollScheduled) return;
    _lastScrollTarget = active;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted) return;
      if (!_scrollController.hasClients) {
        // 歌词页未挂载（如用户停留在封面页调偏移）时无法执行滚动；
        // 不能让 _lastScrollTarget 停留在"已同步"状态，否则重新挂载后
        // 永远不会再滚回正确行。
        _lastScrollTarget = -1;
        return;
      }

      final currentOffset = _revealOffset(active);
      if (currentOffset == null) {
        _coarseScrollTo(active, lines);
        return;
      }

      _coarseScrollTarget = -1;
      _animateToOffset(currentOffset);
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _resumeAutoScrollTimer?.cancel();
      _userScrolling = true;
    } else if (notification is ScrollEndNotification && _userScrolling) {
      _resumeAutoScrollTimer?.cancel();
      _resumeAutoScrollTimer = Timer(const Duration(seconds: 3), () {
        if (!mounted) return;
        _userScrolling = false;
        _lastScrollTarget = -1;
        final active = _pendingScrollTarget;
        if (active >= 0 && active < _latestLines.length) {
          _syncScroll(active, _latestLines);
        }
      });
    }
    return false;
  }

  void _animateToOffset(double rawTarget) {
    if (!mounted || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final target = rawTarget.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final distance = (target - position.pixels).abs();
    if (distance < .75) return;
    final milliseconds = (300 + distance * 1.7).round().clamp(340, 620);
    unawaited(
      _scrollController.animateTo(
        target,
        duration: Duration(milliseconds: milliseconds),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  double? _revealOffset(int index) {
    final renderObject = _lineKeys[index]?.currentContext?.findRenderObject();
    if (renderObject == null || !renderObject.attached) return null;
    final viewport = RenderAbstractViewport.of(renderObject);
    return viewport.getOffsetToReveal(renderObject, .42).offset;
  }

  void _coarseScrollTo(int active, List<_LyricLine> lines) {
    if (_coarseScrollTarget == active) return;
    _coarseScrollTarget = active;

    // 大幅拖动进度时目标行可能还没有构建，先按整首歌词比例平滑接近。
    final ratio = lines.length <= 1 ? 0.0 : active / (lines.length - 1);
    final position = _scrollController.position;
    final target = (position.maxScrollExtent * ratio).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    unawaited(
      _scrollController
          .animateTo(
            target,
            duration: const Duration(milliseconds: 360),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (!mounted || _coarseScrollTarget != active) return;
            _coarseScrollTarget = -1;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _userScrolling) return;
              final exactOffset = _revealOffset(active);
              if (exactOffset != null) _animateToOffset(exactOffset);
            });
          }),
    );
  }

  Widget _lyricsEmpty(BuildContext context, String message) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.lyrics_outlined,
          size: 52,
          color: Colors.white.withValues(alpha: .3),
        ),
        const SizedBox(height: 12),
        Text(
          message,
          style: TextStyle(color: Colors.white.withValues(alpha: .5)),
        ),
      ],
    ),
  );
}

/// 歌词字号调整弹窗：滑杆 + 实时预览。拖动即写入设置（实时生效），
/// 播放详情页歌词会立即使用新字号重新渲染。
class _LyricFontSizeSheet extends StatefulWidget {
  const _LyricFontSizeSheet({
    required this.initial,
    required this.onChanged,
  });

  final double initial;
  final ValueChanged<double> onChanged;

  @override
  State<_LyricFontSizeSheet> createState() => _LyricFontSizeSheetState();
}

class _LyricFontSizeSheetState extends State<_LyricFontSizeSheet> {
  late double _value;

  @override
  void initState() {
    super.initState();
    _value = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: 20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.format_size_rounded, color: scheme.primary),
              const SizedBox(width: 12),
              const Text('歌词字号', style: TextStyle(fontSize: 16)),
              const Spacer(),
              Text(
                _value.toStringAsFixed(0),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          Slider(
            value: _value,
            min: 12,
            max: 32,
            divisions: 20,
            label: _value.toStringAsFixed(0),
            onChanged: (value) {
              setState(() => _value = value);
              widget.onChanged(value);
            },
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: .5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '正在播放的歌词行',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: math.min(32, _value + 6),
                    height: 1.3,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '其他歌词行',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: _value,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface.withValues(alpha: .45),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '翻译歌词行',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: (_value - 5).clamp(10.0, 26.0),
                    color: scheme.onSurface.withValues(alpha: .4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TimedLyricText extends StatelessWidget {
  const _TimedLyricText({
    required this.line,
    required this.position,
    required this.selected,
    required this.effectMode,
    required this.textAlign,
    required this.baseFontSize,
  });

  final _LyricLine line;
  final double position;
  final bool selected;
  final LyricWordEffectMode effectMode;
  final TextAlign textAlign;

  /// 设置中的歌词基础字号；选中行在此基础上放大（上限 +6）。
  final double baseFontSize;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(
        end: selected ? math.min(32, baseFontSize + 6) : baseFontSize,
      ),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, fontSize, _) => _buildText(fontSize),
    );
  }

  Widget _buildText(double fontSize) {
    final baseStyle = TextStyle(
      color: Colors.white,
      fontSize: fontSize,
      height: 1.3,
      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
      shadows: selected
          ? const [Shadow(color: Colors.black54, blurRadius: 12)]
          : null,
    );
    if (!selected ||
        line.words.isEmpty ||
        effectMode == LyricWordEffectMode.none) {
      return Text(line.text, textAlign: textAlign, style: baseStyle);
    }

    if (effectMode == LyricWordEffectMode.progressive) {
      return _buildProgressiveText(baseStyle);
    }

    return _buildWordByWordText(baseStyle);
  }

  Widget _buildWordByWordText(TextStyle baseStyle) {
    final dimColor = Colors.white.withValues(alpha: .28);
    return Text.rich(
      TextSpan(
        children: [
          for (final word in line.words)
            TextSpan(
              text: word.text,
              style: baseStyle.copyWith(
                color: Color.lerp(dimColor, Colors.white, _wordProgress(word)),
                shadows: position >= word.start && position < word.end
                    ? const [
                        Shadow(color: Colors.white54, blurRadius: 10),
                        Shadow(color: Colors.black54, blurRadius: 12),
                      ]
                    : baseStyle.shadows,
              ),
            ),
        ],
      ),
      textAlign: textAlign,
      style: baseStyle,
    );
  }

  Widget _buildProgressiveText(TextStyle baseStyle) {
    return Text.rich(
      TextSpan(
        children: [
          for (final word in line.words)
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _ProgressiveLyricWord(
                text: word.text,
                style: baseStyle,
                progress: _wordProgress(word),
              ),
            ),
        ],
      ),
      textAlign: textAlign,
      style: baseStyle,
    );
  }

  double _wordProgress(_LyricWord word) {
    if (position <= word.start) return 0;
    if (position >= word.end || word.end <= word.start) return 1;
    return ((position - word.start) / (word.end - word.start)).clamp(0, 1);
  }
}

class _ProgressiveLyricWord extends StatelessWidget {
  const _ProgressiveLyricWord({
    required this.text,
    required this.style,
    required this.progress,
  });

  final String text;
  final TextStyle style;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final value = progress.clamp(0.0, 1.0);
    // ShaderMask 在进度为 0 时仍会绘制渐变的首个白色采样点，
    // 每个 WidgetSpan 的左边因此出现一条白边。边界状态直接绘制纯色，
    // 只有真正播放到当前词时才使用渐变过渡。
    final dim = Colors.white.withValues(alpha: .28);
    if (value <= 0) {
      return Text(text, style: style.copyWith(color: dim));
    }
    if (value >= 1) {
      return Text(text, style: style.copyWith(color: Colors.white));
    }
    final edgeStart = (value - .08).clamp(0.0, 1.0);
    final edgeEnd = (value + .08).clamp(0.0, 1.0);
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => LinearGradient(
        colors: [Colors.white, Colors.white, dim, dim],
        stops: [0, edgeStart, edgeEnd, 1],
      ).createShader(bounds),
      child: Text(text, style: style.copyWith(color: Colors.white)),
    );
  }
}

/// 毛玻璃控制卡：标题 + 进度 + 播放控制。
class _GlassControlCard extends ConsumerWidget {
  const _GlassControlCard({
    required this.notifier,
    required this.current,
    this.showMetadata = true,
    this.onDownload,
    this.onAddToPlaylist,
    this.onLyricsOffset,
    this.onDesktopLyrics,
    this.videoActive = false,
    this.videoController,
  });
  final PlayerNotifier notifier;
  final QueueItem? current;
  final bool showMetadata;
  final VoidCallback? onDownload;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onLyricsOffset;
  final VoidCallback? onDesktopLyrics;
  final bool videoActive;
  final VideoPlayerController? videoController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final errorMessage = ref.watch(
      playerProvider.select((state) => state.errorMessage),
    );

    // 播放栏直接叠加在详情页背景上，不再使用整块半透明卡片，
    // 让封面背景能够连续延伸到屏幕底部。
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: current == null
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('暂无播放')),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TitleRow(
                  current: current!,
                  showMetadata: showMetadata,
                  onDownload: onDownload,
                  onAddToPlaylist: onAddToPlaylist,
                  onLyricsOffset: onLyricsOffset,
                  onDesktopLyrics: onDesktopLyrics,
                ),
                if (errorMessage != null) ...[
                  const SizedBox(height: 10),
                  _PlaybackError(
                    message: errorMessage,
                    onRetry: notifier.toggle,
                  ),
                ],
                const SizedBox(height: 14),
                _ProgressBar(
                  notifier: notifier,
                  enabled: !videoActive || videoController != null,
                  videoController: videoController,
                ),
                const SizedBox(height: 6),
                _Controls(
                  notifier: notifier,
                  disabled: videoActive,
                  videoController: videoController,
                ),
              ],
            ),
    );
  }
}

class _PlaybackError extends StatelessWidget {
  const _PlaybackError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFEC4141).withValues(alpha: .16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFFEC4141).withValues(alpha: .32),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFFF8A8A), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            child: const Text('重试', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class _TitleRow extends ConsumerWidget {
  const _TitleRow({
    required this.current,
    this.showMetadata = true,
    this.onDownload,
    this.onAddToPlaylist,
    this.onLyricsOffset,
    this.onDesktopLyrics,
  });
  final QueueItem current;
  final bool showMetadata;
  final VoidCallback? onDownload;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onLyricsOffset;
  final VoidCallback? onDesktopLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFav = ref.watch(favoritesProvider).contains(current.path);
    final desktopLyricsEnabled = ref.watch(
      settingsProvider.select(
        (value) => value.valueOrNull?.desktopLyricsEnabled == true,
      ),
    );
    final isLocal =
        playbackSourceTypeFor(current) == PlaybackSourceType.localFile;
    return Row(
      mainAxisAlignment: showMetadata
          ? MainAxisAlignment.start
          : MainAxisAlignment.spaceBetween,
      children: [
        if (showMetadata)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  current.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  current.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: .56),
                  ),
                ),
              ],
            ),
          ),
        if (!showMetadata)
          _quickAction(
            context,
            icon: Icons.download_rounded,
            tooltip: '下载',
            onPressed: isLocal ? null : onDownload,
          ),
        if (!showMetadata)
          _quickAction(
            context,
            icon: Icons.playlist_add_rounded,
            tooltip: '添加到歌单',
            onPressed: onAddToPlaylist,
          ),
        if (!showMetadata)
          _quickAction(
            context,
            icon: Icons.sync_alt_rounded,
            tooltip: '歌词偏移',
            onPressed: onLyricsOffset,
          ),
        if (!showMetadata)
          _quickAction(
            context,
            icon: desktopLyricsEnabled
                ? Icons.desktop_access_disabled_outlined
                : Icons.desktop_windows_outlined,
            tooltip: desktopLyricsEnabled ? '关闭桌面歌词' : '开启桌面歌词',
            onPressed: onDesktopLyrics,
          ),
        if (!showMetadata)
          _quickAction(
            context,
            icon: isFav ? Icons.favorite : Icons.favorite_border,
            tooltip: isFav ? '取消收藏' : '收藏',
            color: isFav ? const Color(0xFFEC4141) : Colors.white70,
            onPressed: () => ref
                .read(favoritesProvider.notifier)
                .toggle(
                  current.path,
                  song: FavoriteSongSnapshot.fromQueueItem(current),
                ),
          ),
        if (showMetadata)
          IconButton(
            icon: Icon(
              isFav ? Icons.favorite : Icons.favorite_border,
              // 收藏状态使用固定红色，不随用户自定义主题色变化。
              color: isFav ? const Color(0xFFEC4141) : Colors.white70,
            ),
            onPressed: () => ref
                .read(favoritesProvider.notifier)
                .toggle(
                  current.path,
                  song: FavoriteSongSnapshot.fromQueueItem(current),
                ),
          ),
      ],
    );
  }

  Widget _quickAction(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, color: color ?? Colors.white70),
      onPressed: onPressed,
      // 与封面界面的收藏按钮保持同一尺寸和内边距，切换页面时图标
      // 中心位置不会发生跳动；所有快捷按钮也因此保持同一水平基线。
      visualDensity: VisualDensity.standard,
      padding: const EdgeInsets.all(8),
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    );
  }
}

class _ProgressBar extends ConsumerWidget {
  const _ProgressBar({
    required this.notifier,
    this.enabled = true,
    this.videoController,
  });
  final PlayerNotifier notifier;
  final bool enabled;
  final VideoPlayerController? videoController;

  String _fmt(double s) {
    if (!s.isFinite || s < 0) s = 0;
    final m = s ~/ 60;
    final sec = (s % 60).floor();
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = videoController;
    if (controller != null) {
      return ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: controller,
        builder: (context, value, child) => _buildProgress(
          context,
          value.position.inMilliseconds / 1000.0,
          value.duration.inMilliseconds / 1000.0,
          onChanged: enabled
              ? (position) => unawaited(
                  controller.seekTo(
                    Duration(milliseconds: (position * 1000).round()),
                  ),
                )
              : null,
        ),
      );
    }

    final progress = ref.watch(
      playerProvider.select(
        (state) => (position: state.position, duration: state.duration),
      ),
    );
    return _buildProgress(
      context,
      progress.position,
      progress.duration,
      onChanged: enabled ? notifier.seek : null,
    );
  }

  Widget _buildProgress(
    BuildContext context,
    double rawPosition,
    double rawDuration, {
    required ValueChanged<double>? onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final dur = rawDuration.isFinite && rawDuration > 0 ? rawDuration : 1.0;
    final position = rawPosition.isFinite ? rawPosition.clamp(0.0, dur) : 0.0;
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            activeTrackColor: scheme.primary,
            inactiveTrackColor: Colors.white.withValues(alpha: .16),
            thumbColor: scheme.primary,
            overlayColor: scheme.primary.withValues(alpha: 0.16),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(value: position, max: dur, onChanged: onChanged),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _fmt(position),
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: .52),
                ),
              ),
              Text(
                _fmt(dur),
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: .52),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Controls extends ConsumerWidget {
  const _Controls({
    required this.notifier,
    this.disabled = false,
    this.videoController,
  });
  final PlayerNotifier notifier;
  final bool disabled;
  final VideoPlayerController? videoController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final player = ref.watch(
      playerProvider.select(
        (state) => (
          isPlaying: state.isPlaying,
          isLoading: state.isLoading,
          playMode: normalizePlayMode(state.playMode),
          hasQueue: state.queue.isNotEmpty,
        ),
      ),
    );
    final video = videoController;
    if (video != null) {
      return ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: video,
        builder: (context, value, child) =>
            _buildControls(context, ref, scheme, (
              isPlaying: value.isPlaying,
              isLoading: false,
              playMode: player.playMode,
              hasQueue: player.hasQueue,
            ), videoController: video),
      );
    }
    return _buildControls(context, ref, scheme, player);
  }

  Widget _buildControls(
    BuildContext context,
    WidgetRef ref,
    ColorScheme scheme,
    ({bool isPlaying, bool isLoading, int playMode, bool hasQueue}) player, {
    VideoPlayerController? videoController,
  }) {
    final icons = [Icons.repeat, Icons.repeat_one, Icons.shuffle];
    final video = videoController;
    // 视频播放时，视频控制器接管播放/进度，但切歌、循环模式和队列仍应可用。
    // 之前把 video != null 整体视为 disabled，导致详情页只有播放按钮能点。
    final controlsDisabled = disabled && video == null;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          iconSize: 21,
          icon: Icon(icons[player.playMode], color: Colors.white70),
          onPressed: controlsDisabled ? null : notifier.cyclePlayMode,
        ),
        IconButton(
          iconSize: 32,
          icon: const Icon(Icons.skip_previous, color: Colors.white),
          onPressed: controlsDisabled ? null : notifier.previous,
        ),
        // 主题色实心播放键
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.primary,
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.4),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: IconButton(
            icon: player.isLoading
                ? const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.6,
                      color: Colors.white,
                    ),
                  )
                : Icon(
                    player.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                  ),
            iconSize: 34,
            onPressed: player.isLoading
                ? null
                : video != null
                ? () {
                    if (video.value.isPlaying) {
                      unawaited(video.pause());
                    } else {
                      unawaited(video.play());
                    }
                  }
                : disabled
                ? null
                : notifier.toggle,
          ),
        ),
        IconButton(
          iconSize: 32,
          icon: const Icon(Icons.skip_next, color: Colors.white),
          onPressed: controlsDisabled ? null : notifier.next,
        ),
        IconButton(
          iconSize: 21,
          icon: const Icon(Icons.queue_music, color: Colors.white70),
          onPressed: controlsDisabled || !player.hasQueue
              ? null
              : () => _showQueue(context, ref),
        ),
      ],
    );
  }

  Future<void> _showQueue(BuildContext context, WidgetRef ref) {
    final player = ref.read(playerProvider);
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .66,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Row(
                  children: [
                    const Text(
                      '播放队列',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${player.queue.length} 首',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: player.queue.length,
                  itemBuilder: (context, index) {
                    final item = player.queue[index];
                    final current = index == player.queueIndex;
                    return ListTile(
                      minTileHeight: 58,
                      leading: current
                          ? const SizedBox(
                              width: 24,
                              child: Icon(
                                Icons.graphic_eq,
                                color: Color(0xFFEC4141),
                              ),
                            )
                          : SizedBox(
                              width: 24,
                              child: Text(
                                '${index + 1}',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                      title: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: current ? const Color(0xFFEC4141) : null,
                          fontWeight: current
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        item.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () async {
                        Navigator.pop(context);
                        await ref
                            .read(playerProvider.notifier)
                            .playIndex(index);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
