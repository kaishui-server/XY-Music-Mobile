import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../../src/core/db_path.dart';
import '../../src/core/settings.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/effects/effects_provider.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/lyrics/lyrics_models.dart';
import '../../src/navigation/animated_page_route.dart';
import '../../src/player/player_provider.dart';
import '../../src/player/desktop_lyrics.dart';
import '../../src/player/download_history_store.dart';
import '../../src/player/downloaded_song_store.dart';
import '../../src/player/android_storage.dart';
import '../../src/player/download_lyrics.dart';
import '../../src/player/download_quality.dart';
import '../../src/player/video_playback_session.dart';
import '../../src/playlists/playlists_provider.dart';
import '../../src/playlists/playlist_picker_sheet.dart';
import '../../src/plugins/plugin_runtime.dart';
import '../../src/rust/api.dart';
import '../../src/rust/music/types.dart';
import '../../src/share/share_sheet.dart';
import 'vinyl_tonearm.dart';
import '../../src/widgets/batch_download.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/queue_sheet.dart';
import '../../src/widgets/source_switch.dart';
import '../../src/widgets/top_notice.dart';
import 'comment_sheet.dart';
import '../search/online_catalog_detail_page.dart';

const _pluginLyricsSearchMemoryKey = 'pluginLyricsSearchQueriesV1';

/// 有些插件会把 QRC/KRC 等歌词的密文直接放进播放结果，解码逻辑统一
/// 放在 download_lyrics.dart，单曲下载与批量下载共用。
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
    this.writeMetadata = true,
  });

  final String directory;
  final String quality;
  final bool dontAskAgain;

  /// 下载后向音频文件写入元数据标签（标题/艺术家/专辑/歌词/封面）。
  final bool writeMetadata;
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

/// 音质选项的展示标签（更多菜单与下载选项弹窗共用）。
String _qualityLabel(String quality) => qualityDisplayLabel(quality);

/// 播放页封面样式的展示标签（样式切换按钮提示共用）。
String coverStyleLabel(PlayerCoverStyle style) => switch (style) {
  PlayerCoverStyle.classic => '经典方形',
  PlayerCoverStyle.circle => '圆形旋转',
  PlayerCoverStyle.immersive => '沉浸式',
  PlayerCoverStyle.vinyl => '黑胶唱片',
};

/// 播放页封面样式切换按钮的图标。
IconData coverStyleIcon(PlayerCoverStyle style) => switch (style) {
  PlayerCoverStyle.classic => Icons.crop_square_rounded,
  PlayerCoverStyle.circle => Icons.circle_outlined,
  PlayerCoverStyle.immersive => Icons.blur_on_rounded,
  PlayerCoverStyle.vinyl => Icons.album_rounded,
};

/// 定时关闭剩余时长的展示标签（随倒计时实时变化）。
String _sleepTimerLabel(DateTime? endsAt) {
  if (endsAt == null) return '未开启';
  final seconds = sleepTimerRemainingSeconds(endsAt);
  return seconds <= 0
      ? '即将停止'
      : '剩余 ${_formatSleepDuration(Duration(seconds: seconds))}';
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

class _PlayerPageState extends ConsumerState<PlayerPage>
    with WidgetsBindingObserver {
  static const _screenAwakeChannel = MethodChannel(
    'com.xymusic.mobile/screen_awake',
  );
  static const _galleryChannel = MethodChannel('com.xymusic.mobile/gallery');

  late final PageController _detailPageController = PageController();
  ProviderSubscription<bool>? _playingSubscription;
  bool _screenAwake = false;
  bool _showLyrics = false;

  /// 横屏沉浸式歌词下临时弹出的播放控制栏（单击弹出，5 秒无操作自动隐藏）。
  bool _landscapeControlsVisible = false;

  /// 竖屏沉浸式歌词页下临时弹出的播放控制栏（点击原播放栏位置弹出，
  /// 5 秒无操作自动隐藏，逻辑与横屏一致）。
  bool _portraitControlsVisible = false;
  Timer? _immersiveBarTimer;

  /// 竖屏沉浸式播放栏的自然高度：布局后测量。播放栏弹出时内容区据此
  /// 收缩让位（恢复沉浸式开启前的排版，播放栏位置不再叠在歌词上）。
  double _portraitImmersiveBarHeight = 0;
  final GlobalKey _portraitImmersiveBarKey = GlobalKey();

  /// 横屏沉浸式播放栏的自然高度（用途同上）。
  double _landscapeImmersiveBarHeight = 0;
  final GlobalKey _landscapeImmersiveBarKey = GlobalKey();
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
  bool _resumeAudioAfterVideo = false;

  /// MV 横屏播放开关：开启后锁定横向屏幕方向，关闭或退出视频时恢复。
  bool _videoLandscape = false;

  /// 当前视频分辨率（B 站/插件解析时的画质档位，如 1080P），顶部副标题
  /// 与画质切换入口使用。MV 默认请求最高档（2160P），插件按可用档位
  /// 回落并返回实际选中画质；B 站视频歌曲初始请求 1080P。
  String _videoQuality = '1080P';

  /// 插件返回的当前 MV 可用画质 key 列表（如 ["360p","720p","1080p"]），
  /// 画质选择入口动态展示；插件未提供时回退到内置档位。
  List<String> _videoAvailableQualities = const [];

  /// 视频画质展示文案：插件回传了实际档位（含回落结果）时显示该档位；
  /// 插件未回传时把「最高档」请求哨兵值显示为「自动」，避免误导。
  String get _displayVideoQuality {
    if (_videoQuality == '2160P' && _videoAvailableQualities.isEmpty) {
      return '自动';
    }
    return _videoQuality.toUpperCase();
  }

  /// 视频静音开关（控制栏音量按钮）。
  bool _videoMuted = false;

  /// 当前视频是否为插件 MV（画质切换时决定走 resolveMvSource 还是
  /// resolveVideoSource，后者需要传 path）。
  bool _videoIsMv = false;
  String? _videoError;
  VoidCallback? _videoControllerListener;
  // 后台久置自动关闭视频的守护已上移到应用级 PlayerNotifier
  //（lib/src/player/player_provider.dart）：本页面退出后视频会话仍存活，
  // 页面级监听随 dispose 失效，无法覆盖“离开详情页后切后台”的场景。
  /// 当前歌曲的 MV 可用性检测结果缓存（与更多菜单的判定一致）：
  /// 插件需声明 getMvSource 扩展且歌曲携带 MV 标识才显示 MV 按钮。
  String? _mvCheckPath;
  bool _mvAvailable = false;

  /// B 站歌曲视频始终可播；插件歌曲按检测结果；本地歌曲不可播。
  bool _mvButtonVisible(QueueItem item) =>
      _isBilibiliQueueItem(item) || (_mvCheckPath == item.path && _mvAvailable);

  /// 换歌时异步检测 MV 可用性并缓存，避免按钮与更多菜单判定不一致。
  /// 检测前先同步重置旧结果：build 中先调用本方法再取按钮可见性，
  /// 上一首的按钮状态可在同一帧内撤下，检测完成后再决定是否显示。
  Future<void> _refreshMvAvailability(QueueItem? item) async {
    if (item == null || _isBilibiliQueueItem(item)) return;
    if (_mvCheckPath == item.path) return;
    _mvCheckPath = item.path;
    _mvAvailable = false;
    final available = await _checkMvAvailable(item);
    if (!mounted || _mvCheckPath != item.path) return;
    if (_mvAvailable != available) {
      _mvAvailable = available;
      setState(() {});
    }
  }

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
    _resumeAudioAfterVideo = VideoPlaybackSession.resumeAudioAfterVideo;
    _videoError = VideoPlaybackSession.error;
    // 详情页销毁重建（如后台久置挂起后再进入）时恢复 MV 上下文：
    // 画质切换走 resolveMvSource 还是 resolveVideoSource 取决于 isMv。
    _videoIsMv = VideoPlaybackSession.isMv;
    _videoQuality = VideoPlaybackSession.quality;
    _videoAvailableQualities = VideoPlaybackSession.availableQualities;
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
    var controllerRemoved = false;
    if (VideoPlaybackSession.controller == null && _videoController != null) {
      final old = _videoController!;
      _unbindVideoController(old);
      _videoController = null;
      controllerRemoved = true;
    }
    // 同步会话状态，覆盖两类外部写入：后台久置挂起（保留 songPath、
    // 写入错误态）与切歌/外部收尾（清空整个会话），页面与会话始终一致。
    var sessionChanged = false;
    if (_videoSongPath != VideoPlaybackSession.songPath) {
      _videoSongPath = VideoPlaybackSession.songPath;
      sessionChanged = true;
    }
    if (_videoLoading != VideoPlaybackSession.loading) {
      _videoLoading = VideoPlaybackSession.loading;
      sessionChanged = true;
    }
    if (_videoError != VideoPlaybackSession.error) {
      _videoError = VideoPlaybackSession.error;
      sessionChanged = true;
    }
    if (_videoIsMv != VideoPlaybackSession.isMv) {
      _videoIsMv = VideoPlaybackSession.isMv;
      sessionChanged = true;
    }
    if (sessionChanged && _videoSongPath == null) {
      _resumeAudioAfterVideo = VideoPlaybackSession.resumeAudioAfterVideo;
    }
    if (mounted && !_videoClosing && (controllerRemoved || sessionChanged)) {
      setState(() {});
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

  /// 播放页封面样式一键切换：经典 → 圆形 → 沉浸式 → 黑胶 循环，
  /// 与外观设置里的下拉选择共用同一份持久化配置。
  void _cycleCoverStyle() {
    final current =
        ref.read(settingsProvider).valueOrNull?.playerCoverStyle ??
        PlayerCoverStyle.classic;
    final next = PlayerCoverStyle
        .values[(current.index + 1) % PlayerCoverStyle.values.length];
    unawaited(ref.read(settingsProvider.notifier).setPlayerCoverStyle(next));
    XyNotice.show(
      context,
      message: '封面样式：${coverStyleLabel(next)}',
      type: XyNoticeType.success,
      compact: true,
      blur: true,
    );
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
      // MV 请求「最高档」哨兵值 2160P：baka 系插件按可用档位自动回落
      // 并在返回值里给出实际画质；B 站视频歌曲请求 1080P（匿名最高档）。
      final initialQuality = isMv ? '2160P' : '1080P';
      _videoQuality = initialQuality;
      _videoAvailableQualities = const [];
      VideoPlaybackSession.quality = initialQuality;
      VideoPlaybackSession.availableQualities = const [];
      _videoMuted = false;
      final controller = await _loadVideoControllerWithFallback(
        plugin: plugin,
        pluginData: pluginData,
        path: item.path,
        isMv: isMv,
        requestedQuality: initialQuality,
      );
      if (!mounted || _videoSongPath != item.path) {
        await controller.dispose();
        return;
      }
      await _attachVideoController(controller, notifier);
    } catch (error) {
      if (!mounted || _videoSongPath != item.path) return;
      // 失败不再退回音频播放页：保留 MV 覆盖层进入错误态，面板上可
      // 重新加载（自动降档搜索低画质）或手动切换画质。
      _enterVideoErrorState(error);
    }
  }

  /// 低于 [failedQuality] 的画质候选，按清晰度从高到低排列。优先取
  /// 插件回传的可用档位；插件未提供时回退内置档位。
  List<String> _lowerVideoQualityCandidates(String failedQuality) {
    final base = _videoAvailableQualities.isNotEmpty
        ? _videoAvailableQualities
        : const ['1080P', '720P', '480P'];
    final failedRank = _videoQualityRank(failedQuality);
    if (failedRank <= 0) return const [];
    final candidates =
        base
            .where(
              (quality) =>
                  _videoQualityRank(quality) > 0 &&
                  _videoQualityRank(quality) < failedRank,
            )
            .toList()
          ..sort(
            (a, b) => _videoQualityRank(b).compareTo(_videoQualityRank(a)),
          );
    return candidates;
  }

  /// 解析播放地址并初始化控制器：主地址失败时逐一尝试备用地址。
  /// 全部失败时抛出最后一个错误。
  Future<VideoPlayerController> _initVideoController(
    PluginVideoSource source,
  ) async {
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
        return candidate;
      } catch (error) {
        lastVideoError = error;
        // 初始化失败的候选地址也要释放，避免连续尝试备用地址时泄漏
        // ExoPlayer/纹理资源。
        try {
          await candidate?.dispose();
        } catch (_) {}
      }
    }
    throw lastVideoError ?? Exception('视频地址无法播放');
  }

  /// 解析指定画质并初始化控制器；起播失败（地址失效/解码失败）时自动
  /// 搜索更低画质档位逐档回落重试（最多 3 档），全部失败抛出最后一次
  /// 错误。成功期间同步 [_videoQuality]、[_videoAvailableQualities] 与
  /// 共享会话的画质记录。
  Future<VideoPlayerController> _loadVideoControllerWithFallback({
    required EnabledMusicPlugin plugin,
    required Map<String, dynamic> pluginData,
    required String path,
    required bool isMv,
    required String requestedQuality,
  }) async {
    final runtime = ref.read(pluginRuntimeProvider);
    final source =
        await (isMv
                ? runtime.resolveMvSource(
                    plugin,
                    pluginData,
                    videoQuality: requestedQuality,
                  )
                : runtime.resolveVideoSource(
                    plugin,
                    pluginData,
                    videoQuality: requestedQuality,
                    path: path,
                  ))
            .timeout(const Duration(seconds: 25));
    if (source.availableQualities.isNotEmpty) {
      _videoAvailableQualities = source.availableQualities;
    }
    // 插件实际选中的画质优先于请求值（回落后的真实档位）。
    final appliedQuality = source.selectedQuality?.trim().isNotEmpty == true
        ? source.selectedQuality!.trim()
        : requestedQuality;
    _videoQuality = appliedQuality;
    Object? lastError;
    VideoPlayerController? controller;
    try {
      controller = await _initVideoController(source);
    } catch (error) {
      lastError = error;
    }
    if (controller != null) {
      VideoPlaybackSession.quality = _videoQuality;
      VideoPlaybackSession.availableQualities = _videoAvailableQualities;
      return controller;
    }
    // 起播失败：自动搜索更低画质逐档回落，给用户抢救出可播的档位。
    for (final quality in _lowerVideoQualityCandidates(
      appliedQuality,
    ).take(3)) {
      try {
        final fallback =
            await (isMv
                    ? runtime.resolveMvSource(
                        plugin,
                        pluginData,
                        videoQuality: quality,
                      )
                    : runtime.resolveVideoSource(
                        plugin,
                        pluginData,
                        videoQuality: quality,
                        path: path,
                      ))
                .timeout(const Duration(seconds: 25));
        if (fallback.availableQualities.isNotEmpty) {
          _videoAvailableQualities = fallback.availableQualities;
        }
        final candidate = await _initVideoController(fallback);
        _videoQuality = fallback.selectedQuality?.trim().isNotEmpty == true
            ? fallback.selectedQuality!.trim()
            : quality;
        VideoPlaybackSession.quality = _videoQuality;
        VideoPlaybackSession.availableQualities = _videoAvailableQualities;
        return candidate;
      } catch (error) {
        lastError = error;
        // 回落失败后恢复原档位，错误面板的手动画质切换以它为基准。
        _videoQuality = appliedQuality;
      }
    }
    throw lastError ?? Exception('视频地址无法播放');
  }

  /// 控制器初始化成功后的收尾：恢复倍速、绑定监听与共享会话、起播并
  /// 接入系统媒体桥接。首次启动与错误面板重新加载共用。
  Future<void> _attachVideoController(
    VideoPlayerController controller,
    PlayerNotifier notifier,
  ) async {
    // MV/视频默认从头播放：不再同步音频播放进度（用户此前反馈
    // 同步进度导致 MV 起始位置随机），仅保留倍速跟随。
    final playbackSpeed = ref.read(playerProvider).playbackSpeed;
    await controller.setPlaybackSpeed(playbackSpeed);
    _bindVideoController(controller);
    _videoController = controller;
    VideoPlaybackSession.controller = controller;
    VideoPlaybackSession.loading = false;
    VideoPlaybackSession.error = null;
    VideoPlaybackSession.changed();
    VideoPlaybackSession.progressChanged();
    if (mounted) {
      setState(() {
        _videoLoading = false;
        _videoError = null;
      });
    }
    await controller.play();
    // video_player 不会自动接入 Android MediaSession。启动静音音频桥接，
    // 让通知栏/锁屏/灵动岛进度与播放暂停按钮同步控制当前视频。
    await notifier.enableVideoMediaBridge();
  }

  /// 视频加载/起播失败：保留 MV 覆盖层进入错误态（不退回音频播放页、
  /// 不恢复音频），错误面板提供重新加载与手动切换画质；关闭视频时
  /// 才按原逻辑恢复音频播放。
  void _enterVideoErrorState(Object error) {
    final errorText = _errorText(error);
    _videoController = null;
    VideoPlaybackSession.controller = null;
    VideoPlaybackSession.loading = false;
    VideoPlaybackSession.error = errorText;
    VideoPlaybackSession.quality = _videoQuality;
    VideoPlaybackSession.availableQualities = _videoAvailableQualities;
    VideoPlaybackSession.changed();
    if (!mounted) return;
    setState(() {
      _videoLoading = false;
      _videoError = errorText;
    });
  }

  /// 错误面板「重新加载」：释放失效控制器（MediaCodec 可能已被系统
  /// 回收）后按当前画质重新解析起播，失败时自动降档搜索低画质。
  Future<void> _reloadVideoPlayback() async {
    final item = ref.read(playerProvider).current;
    if (item == null || _videoSongPath != item.path) return;
    if (_videoLoading || _videoError == null) return;
    final pluginData = item.pluginData;
    if (pluginData == null || pluginData.isEmpty) return;
    EnabledMusicPlugin? plugin;
    try {
      final plugins = await ref.read(enabledMusicPluginsProvider.future);
      plugin = plugins.where((value) => value.id == item.pluginId).firstOrNull;
    } catch (_) {
      plugin = null;
    }
    if (plugin == null) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '歌曲所属插件已停用或删除',
          type: XyNoticeType.error,
        );
      }
      return;
    }
    // 释放已失效的控制器，腾出解码器资源再重新起播。
    final broken = _videoController;
    if (broken != null) {
      _unbindVideoController(broken);
      _videoController = null;
      VideoPlaybackSession.controller = null;
      try {
        await broken.dispose();
      } catch (_) {}
    }
    final quality = _videoQuality;
    setState(() {
      _videoError = null;
      _videoLoading = true;
    });
    VideoPlaybackSession.error = null;
    VideoPlaybackSession.loading = true;
    VideoPlaybackSession.changed();
    try {
      final controller = await _loadVideoControllerWithFallback(
        plugin: plugin,
        pluginData: pluginData,
        path: item.path,
        isMv: _videoIsMv,
        requestedQuality: quality,
      );
      if (!mounted || _videoSongPath != item.path) {
        await controller.dispose();
        return;
      }
      await _attachVideoController(
        controller,
        ref.read(playerProvider.notifier),
      );
    } catch (error) {
      if (!mounted || _videoSongPath != item.path) return;
      _enterVideoErrorState(error);
    }
  }

  /// 控制栏「画质」入口：优先展示插件返回的可用档位，未提供时回退
  /// 到内置档位；按需切换。
  Future<void> _pickVideoQuality() async {
    final qualities = _videoAvailableQualities.isNotEmpty
        ? _videoAvailableQualities
        : const ['1080P', '720P', '480P'];
    bool isSameQuality(String left, String right) =>
        left.toLowerCase() == right.toLowerCase();
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('画质选择'),
              ),
            ),
            for (final quality in qualities)
              ListTile(
                dense: true,
                title: Text(
                  isSameQuality(quality, _videoQuality)
                      ? '${quality.toUpperCase()}（当前）'
                      : quality.toUpperCase(),
                ),
                trailing: isSameQuality(quality, _videoQuality)
                    ? const Icon(Icons.check_rounded, size: 18)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(quality),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || isSameQuality(picked, _videoQuality)) return;
    await _switchVideoQuality(picked);
  }

  /// 切换视频画质：重新解析目标档位的播放地址，无缝替换控制器
  /// （保持播放进度与播放/暂停状态）；解析或起播失败时提示并保留原画质。
  Future<void> _switchVideoQuality(String quality) async {
    final item = ref.read(playerProvider).current;
    if (item == null || _videoSongPath != item.path || _videoLoading) return;
    final pluginData = item.pluginData;
    if (pluginData == null || pluginData.isEmpty) return;
    EnabledMusicPlugin? plugin;
    try {
      final plugins = await ref.read(enabledMusicPluginsProvider.future);
      plugin = plugins.where((value) => value.id == item.pluginId).firstOrNull;
    } catch (_) {
      plugin = null;
    }
    if (plugin == null) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '歌曲所属插件已停用或删除',
          type: XyNoticeType.error,
        );
      }
      return;
    }
    final oldController = _videoController;
    final resumePosition = oldController?.value.position ?? Duration.zero;
    final wasPlaying = oldController?.value.isPlaying ?? true;
    // 从错误面板切换时没有旧控制器，倍速跟随播放器全局设置。
    final previousSpeed =
        oldController?.value.playbackSpeed ??
        ref.read(playerProvider).playbackSpeed;
    setState(() => _videoLoading = true);
    try {
      final runtime = ref.read(pluginRuntimeProvider);
      final source = _videoIsMv
          ? await runtime
                .resolveMvSource(plugin, pluginData, videoQuality: quality)
                .timeout(const Duration(seconds: 25))
          : await runtime
                .resolveVideoSource(
                  plugin,
                  pluginData,
                  videoQuality: quality,
                  path: item.path,
                )
                .timeout(const Duration(seconds: 25));
      if (!mounted || _videoSongPath != item.path) return;
      VideoPlayerController? nextController;
      Object? lastError;
      for (final url in <String>[source.url, ...source.backupUrls]) {
        VideoPlayerController? candidate;
        try {
          candidate = VideoPlayerController.networkUrl(
            Uri.parse(url),
            httpHeaders: source.headers,
            videoPlayerOptions: VideoPlayerOptions(
              allowBackgroundPlayback: true,
              mixWithOthers: true,
            ),
          );
          await candidate.initialize();
          nextController = candidate;
          break;
        } catch (error) {
          lastError = error;
          try {
            await candidate?.dispose();
          } catch (_) {}
        }
      }
      if (nextController == null) {
        throw lastError ?? Exception('该画质暂不可用');
      }
      if (!mounted || _videoSongPath != item.path) {
        await nextController.dispose();
        return;
      }
      // 新控制器承接旧状态：进度、播放状态、倍速、静音，切换无感。
      await nextController.setPlaybackSpeed(previousSpeed);
      if (_videoMuted) {
        await nextController.setVolume(0);
      }
      if (resumePosition > Duration.zero) {
        await nextController.seekTo(resumePosition);
      }
      _bindVideoController(nextController);
      _videoController = nextController;
      VideoPlaybackSession.controller = nextController;
      VideoPlaybackSession.loading = false;
      VideoPlaybackSession.changed();
      VideoPlaybackSession.progressChanged();
      // 实际选中画质优先（插件可能对请求档位回落），并刷新可用档位。
      final appliedQuality = source.selectedQuality?.trim().isNotEmpty == true
          ? source.selectedQuality!.trim()
          : quality;
      if (source.availableQualities.isNotEmpty) {
        _videoAvailableQualities = source.availableQualities;
      }
      setState(() {
        _videoQuality = appliedQuality;
        _videoLoading = false;
        // 从错误面板手动切换画质成功：收起错误面板继续播放。
        _videoError = null;
      });
      VideoPlaybackSession.quality = appliedQuality;
      VideoPlaybackSession.availableQualities = _videoAvailableQualities;
      VideoPlaybackSession.error = null;
      if (wasPlaying) {
        await nextController.play();
      } else {
        await nextController.pause();
      }
      // 旧控制器已解绑，直接释放其原生纹理。
      _unbindVideoController(oldController);
      if (oldController != null &&
          VideoPlaybackSession.controller != oldController) {
        await oldController.dispose();
      }
    } catch (error) {
      if (!mounted || _videoSongPath != item.path) return;
      setState(() => _videoLoading = false);
      XyNotice.show(
        context,
        message: '切换 $quality 失败：${_errorText(error)}',
        type: XyNoticeType.error,
      );
    }
  }

  /// 控制栏「倍速」入口：弹出速度选择（仅作用于当前视频）。
  Future<void> _pickVideoSpeed() async {
    final controller = _videoController;
    if (controller == null) return;
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    final current = controller.value.playbackSpeed;
    final picked = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('倍速选择'),
              ),
            ),
            for (final speed in speeds)
              ListTile(
                dense: true,
                title: Text(
                  speed == 1.0
                      ? '1x（正常）'
                      : '${speed == speed.truncateToDouble() ? speed.truncate() : speed}x',
                ),
                trailing: (speed - current).abs() < 0.01
                    ? const Icon(Icons.check_rounded, size: 18)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(speed),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await controller.setPlaybackSpeed(picked);
  }

  /// 控制栏音量按钮：静音/恢复切换（视频音量归一为 0 或 1）。
  Future<void> _toggleVideoMute() async {
    final controller = _videoController;
    if (controller == null) return;
    setState(() => _videoMuted = !_videoMuted);
    await controller.setVolume(_videoMuted ? 0 : 1);
  }

  /// 控制栏「下载」入口：下载当前画质的视频到音乐下载目录。
  /// 复用歌曲下载链路（下载历史进度 + SAF 目录授权 + staging 中转），
  /// 但不写音频元数据、不进入「已下载歌曲」库。
  Future<void> _downloadCurrentVideo() async {
    final item = ref.read(playerProvider).current;
    if (item == null || _videoSongPath != item.path) return;
    final pluginData = item.pluginData;
    if (pluginData == null || pluginData.isEmpty) {
      XyNotice.show(context, message: '该视频不支持下载', type: XyNoticeType.warning);
      return;
    }
    // 视频下载在历史记录中以「#video」后缀与音频下载区分。
    final videoSourcePath = '${item.path}#video';
    final historyNotifier = ref.read(downloadHistoryProvider.notifier);
    if (historyNotifier.hasActiveDownload(videoSourcePath)) {
      XyNotice.show(context, message: '该 MV 正在下载中，可在“下载管理”查看进度');
      return;
    }
    final settings = ref.read(settingsProvider).valueOrNull;
    final initialDirectory = await resolveMusicDownloadDirectory(settings);
    if (!mounted) return;
    final downloadDirectory = await ensureSafDirectoryAccess(
      context,
      ref,
      initialDirectory,
    );
    if (!mounted) return;
    if (downloadDirectory == null) {
      XyNotice.show(
        context,
        message: '已取消下载：下载目录未授权',
        type: XyNoticeType.warning,
      );
      return;
    }
    EnabledMusicPlugin? plugin;
    try {
      final plugins = await ref.read(enabledMusicPluginsProvider.future);
      plugin = plugins.where((value) => value.id == item.pluginId).firstOrNull;
    } catch (_) {
      plugin = null;
    }
    if (plugin == null) {
      if (mounted) {
        XyNotice.show(
          context,
          message: '歌曲所属插件已停用或删除',
          type: XyNoticeType.error,
        );
      }
      return;
    }
    final videoDuration =
        _videoController?.value.duration ??
        Duration(milliseconds: item.durationMs);
    final historyId = historyNotifier.begin(
      title: '${item.title}（MV）',
      artist: item.artist,
      album: item.album,
      quality: _displayVideoQuality,
      durationMs: videoDuration.inMilliseconds,
      sourcePath: videoSourcePath,
      pluginId: item.pluginId,
      pluginData: item.pluginData,
      coverUrl: item.coverUrl,
    );
    try {
      final runtime = ref.read(pluginRuntimeProvider);
      // 重新解析当前画质拿最新地址：播放中的 URL 可能已接近过期。
      final source = _videoIsMv
          ? await runtime
                .resolveMvSource(
                  plugin,
                  pluginData,
                  videoQuality: _videoQuality,
                )
                .timeout(const Duration(seconds: 25))
          : await runtime
                .resolveVideoSource(
                  plugin,
                  pluginData,
                  videoQuality: _videoQuality,
                  path: item.path,
                )
                .timeout(const Duration(seconds: 25));
      if (ref.read(playerProvider).current?.path != item.path) {
        throw Exception('歌曲已切换，请重新选择下载');
      }
      final usesSafDirectory = AndroidStorage.isTreeUri(downloadDirectory);
      final workDirectory = usesSafDirectory
          ? await resolveDownloadStagingDirectory()
          : downloadDirectory;
      await Directory(workDirectory).create(recursive: true);
      final basename = await buildDownloadBasename(
        title: item.title,
        artist: item.artist,
        album: item.album,
        fileNameStyle: 'artist-title',
      );
      final fileName = '$basename [$_displayVideoQuality].mp4';
      final destination = await resolveDownloadPath(
        directory: workDirectory,
        fileName: fileName,
        overwriteExisting: false,
      );
      final savedPath = await trackDownloadProgress(
        history: historyNotifier,
        entryId: historyId,
        url: source.url,
        headers: source.headers,
        destPath: destination,
        download: () => downloadOnlineSong(
          url: source.url,
          destPath: destination,
          headersJson: jsonEncode(source.headers),
        ),
      );
      var finalPath = savedPath;
      if (usesSafDirectory) {
        finalPath = await AndroidStorage.copyFileToDirectory(
          directoryUri: downloadDirectory,
          sourcePath: savedPath,
          fileName: p.basename(savedPath),
          mimeType: 'video/*',
        );
        try {
          await File(savedPath).delete();
        } catch (_) {}
      }
      historyNotifier.complete(
        historyId,
        savedPath: finalPath,
        actualQuality: _displayVideoQuality,
      );
      if (mounted) {
        XyNotice.show(
          context,
          message: '下载完成：${p.basename(finalPath)}',
          type: XyNoticeType.success,
          duration: const Duration(milliseconds: 2600),
        );
      }
    } catch (error) {
      if (error is DownloadPausedSignal) {
        if (mounted) {
          XyNotice.show(context, message: '已暂停：${item.title}（MV）');
        }
      } else {
        historyNotifier.fail(historyId, _errorText(error));
        if (mounted) {
          XyNotice.show(
            context,
            message: '下载失败：${_errorText(error)}',
            type: XyNoticeType.error,
          );
        }
      }
    }
  }

  Future<void> _closeBilibiliVideo() async {
    if (_videoClosing) return;
    _videoClosing = true;
    _resetVideoOrientation();
    // 在后续释放原生视频纹理期间页面可能被移除；先缓存应用级播放器
    // notifier，避免 await 返回后再次访问已销毁页面的 WidgetRef。
    final notifier = ref.read(playerProvider.notifier);
    final controller = _videoController;
    final sessionOwnsController =
        controller != null && VideoPlaybackSession.controller == controller;
    final shouldResume = _resumeAudioAfterVideo;
    final songPath = _videoSongPath;
    await notifier.disableVideoMediaBridge();
    _videoController = null;
    _videoSongPath = null;
    _videoLoading = false;
    _videoError = null;
    _resumeAudioAfterVideo = false;
    VideoPlaybackSession.songPath = null;
    VideoPlaybackSession.controller = null;
    VideoPlaybackSession.loading = false;
    VideoPlaybackSession.isMv = false;
    VideoPlaybackSession.resumeAudioAfterVideo = false;
    VideoPlaybackSession.error = null;
    VideoPlaybackSession.resetQuality();
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
    if (shouldResume && current?.path == songPath) {
      // 桥接期间静音音频与歌曲共享同一时间线，直接从音频自身位置继续。
      // 不能用视频进度定位音频：MV 视频与音频时长不同，视频时钟越过
      // 音频自然末尾后音频已 completed，此时定位回跳/重播都会出错。
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

  /// 更多菜单：底部弹层（截图样式）。顶部为 5 个圆形快捷按钮
  /// （下载——本地歌曲时为歌词偏移/加到歌单/换源+还原/音质/关联歌词），
  /// 下方为设置列表。开关行与封面样式切换在弹层内直接生效；其余条目
  /// 收起弹层后由本页面拉起对应面板。
  Future<void> _showMoreMenu(QueueItem item) async {
    final notifier = ref.read(playerProvider.notifier);
    final restorable = await notifier.hasSwitchedSource(item.path);
    if (!mounted) return;
    final associated = await notifier.rememberedLyricsAssociation(item.path);
    if (!mounted) return;
    final viewport = MediaQuery.sizeOf(context);
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _PlayerMoreSheet(
        item: item,
        isLandscape: viewport.width > viewport.height,
        restorableSource: restorable,
        hasLyricsAssociation: associated != null,
        onDownload: () => unawaited(_downloadCurrent(item)),
        onAddToPlaylist: () => unawaited(_addToPlaylist(item)),
        onSwitchSource: () => unawaited(_switchSource(item)),
        onRestoreSource: () => unawaited(_restoreSource(item)),
        onPickQuality: () => unawaited(_pickPlaybackQuality()),
        onPickLyricFontSize: () => unawaited(_pickLyricFontSize()),
        onShare: () => unawaited(_showShareSheet(item)),
        onToggleDesktopLyrics: () => unawaited(_toggleDesktopLyrics()),
        onShowEffects: () => unawaited(_showEffectsSheet()),
        onLinkLyrics: () => unawaited(_linkLyrics(item)),
        onUnlinkLyrics: () => unawaited(_unlinkLyrics(item)),
        onShowLyricsOffset: () => unawaited(_showLyricsOffsetSheet(item)),
        onCycleCoverStyle: _cycleCoverStyle,
        onShowComments: () => unawaited(
          showModalBottomSheet<void>(
            context: context,
            useRootNavigator: true,
            isScrollControlled: true,
            builder: (_) => CommentSheet(song: item),
          ),
        ),
        onPickSleepTimer: () => unawaited(_pickSleepTimer()),
        onShowSongInfo: () => unawaited(_showSongInfoSheet(item)),
      ),
    );
  }

  /// 歌曲信息面板：展示平台、歌曲 ID/MID 与作者信息（作者可点进
  /// 作品列表页）。数据取自当前队列项的插件元数据。
  Future<void> _showSongInfoSheet(QueueItem item) async {
    final pluginId = item.pluginId;
    String? platform;
    if (pluginId != null && pluginId.isNotEmpty) {
      final plugins = await ref.read(enabledMusicPluginsProvider.future);
      platform = plugins
          .where((plugin) => plugin.id == pluginId)
          .firstOrNull
          ?.name;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _SongInfoSheet(
        item: item,
        platform: platform ?? '本地音乐',
        onOpenArtist: pluginId == null || pluginId.isEmpty
            ? null
            : (artist) {
                Navigator.of(sheetContext).pop();
                unawaited(_openArtistWorks(item, artist));
              },
      ),
    );
  }

  /// 查看作者发布的歌曲：以歌曲数据里的歌手条目为目录项，复用搜索页
  /// 的歌手详情页加载作品；插件未实现详情接口时由运行时回退按名搜索。
  Future<void> _openArtistWorks(
    QueueItem item,
    _SongArtistInfo artist,
  ) async {
    final pluginId = item.pluginId;
    if (pluginId == null || pluginId.isEmpty) return;
    final plugins = await ref.read(enabledMusicPluginsProvider.future);
    final plugin = plugins
        .where((plugin) => plugin.id == pluginId)
        .firstOrNull;
    if (!mounted) return;
    if (plugin == null) {
      XyNotice.show(
        context,
        message: '歌曲所属插件已停用或删除',
        type: XyNoticeType.warning,
      );
      return;
    }
    final runtime = ref.read(pluginRuntimeProvider);
    // 歌手条目即平台原始歌手对象（name/id/mid 等），可直接作为
    // getArtistWorks 的 rawData；补齐 title/id 保证旧插件取到字段。
    final raw = Map<String, dynamic>.from(artist.raw);
    if (artist.name.isNotEmpty) {
      raw['name'] = artist.name;
      raw.putIfAbsent('title', () => artist.name);
    }
    if (artist.artistId.isNotEmpty) {
      raw.putIfAbsent('id', () => artist.artistId);
    }
    final catalog = PluginCatalogResult(
      pluginId: plugin.id,
      id: artist.artistId.isNotEmpty ? artist.artistId : artist.name,
      title: artist.name,
      subtitle: plugin.name,
      coverUrl: '',
      rawData: raw,
    );
    await Navigator.of(context).push<void>(
      XyAnimatedPageRoute(
        builder: (_) => OnlineCatalogDetailPage(
          title: artist.name,
          subtitle: plugin.name,
          coverUrl: '',
          categoryLabel: '歌手',
          loadSongs: () async {
            final results = await runtime.getArtistSongs(plugin, catalog);
            return [
              for (final song in results)
                if (song.title.trim().isNotEmpty)
                  Song(
                    path: pluginSongPath(plugin, song),
                    title: song.title,
                    artist: song.artist,
                    album: song.album,
                    albumKey: song.album,
                    duration: (song.durationMs / 1000).round(),
                    format: '网络',
                    coverUrl: song.coverUrl,
                    pluginId: plugin.id,
                    pluginData: song.rawData,
                  ),
            ];
          },
        ),
      ),
    );
  }

  /// 歌词偏移子面板：滑杆 + 细调按钮 + 重置，实时生效并保存。
  Future<void> _showLyricsOffsetSheet(QueueItem item) async {
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _LyricsOffsetSheet(
        initialTenths: _lyricsOffsetTenths,
        onApply: (tenths) => unawaited(_applyLyricsOffset(item, tenths)),
      ),
    );
  }

  /// 解除当前歌曲的歌词关联（更多菜单「关联歌词」行的尾部按钮）。
  Future<void> _unlinkLyrics(QueueItem item) async {
    if (ref.read(playerProvider).current?.path != item.path) return;
    await ref.read(playerProvider.notifier).clearCurrentLyricsAssociation();
    if (!mounted) return;
    XyNotice.show(context, message: '已解除歌词关联', type: XyNoticeType.success);
  }

  /// 音效页面：跳转到完整音效设置页（均衡器/变速变调/混响/空间音效/高级音效）。
  Future<void> _showEffectsSheet() async {
    context.push('/effects-page');
  }

  /// 换源：选择目标插件搜索同名歌曲，替换当前播放并保存关联。
  Future<void> _switchSource(QueueItem item) async {
    final plugins = await ref.read(enabledMusicPluginsProvider.future);
    if (!mounted) return;
    if (plugins.isEmpty) {
      XyNotice.show(
        context,
        message: '请先在 设置 → 插件 中启用插件',
        type: XyNoticeType.warning,
      );
      return;
    }
    final picked = await showSourceSwitchSheet(
      context,
      ref,
      title: item.title,
      artist: item.artist,
      durationMs: item.durationMs,
      excludePluginId: item.pluginId,
    );
    if (picked == null || !mounted) return;
    final (plugin, replacement) = picked;
    // 收藏与歌单里的同一首歌同步原位换源，保持列表数据一致。
    await syncReplacementToCollections(
      ref,
      originalPath: item.path,
      plugin: plugin,
      replacement: replacement,
    );
    final applied = await ref
        .read(playerProvider.notifier)
        .switchSource(item.path, replacementToQueueItem(plugin, replacement));
    if (!mounted) return;
    XyNotice.show(
      context,
      message: applied ? '已切换到 ${plugin.name} 音源' : '当前播放队列中已没有这首歌',
      type: applied ? XyNoticeType.success : XyNoticeType.warning,
    );
  }

  /// 还原换源：恢复为换源前的原始音源并立即重播。
  Future<void> _restoreSource(QueueItem item) async {
    final restored = await ref
        .read(playerProvider.notifier)
        .restoreSource(item.path);
    if (!mounted) return;
    XyNotice.show(
      context,
      message: restored ? '已还原为原始音源' : '当前歌曲未换过源，无法还原',
      type: restored ? XyNoticeType.success : XyNoticeType.warning,
    );
  }

  Future<void> _showShareSheet(QueueItem item) async {
    await showSongShareSheet(
      context,
      ref: ref,
      song: item,
      extraActions: [
        Builder(
          builder: (rowContext) => shareMenuRow(
            rowContext,
            leading: const Icon(Icons.image_outlined),
            title: '保存为分享图片',
            onTap: () {
              Navigator.of(rowContext, rootNavigator: true).pop();
              unawaited(_createShareImagePreview(item));
            },
          ),
        ),
      ],
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
    final coverUrl = normalizeCoverImageUrl(item.coverUrl);
    if (coverUrl.startsWith('http://') || coverUrl.startsWith('https://')) {
      // 在线封面：先带浏览器 UA/Referer 直连（网易云等 CDN 对默认 UA 返回 403），
      // 失败后再走 Rust 图片代理兜底（部分运营商网络直连 126.net 也会 403）。
      try {
        final response = await http
            .get(
              Uri.parse(coverUrl),
              headers: coverImageNetworkHeaders(coverUrl),
            )
            .timeout(const Duration(seconds: 8));
        if (response.statusCode >= 200 &&
            response.statusCode < 300 &&
            response.bodyBytes.isNotEmpty) {
          return response.bodyBytes;
        }
      } catch (_) {}
      try {
        final dataUrl = await proxyImage(
          url: coverUrl,
          referer: 'https://music.163.com/',
        );
        final comma = dataUrl.indexOf(',');
        if (comma > 0 && dataUrl.substring(0, comma).contains(';base64')) {
          final decoded = base64Decode(dataUrl.substring(comma + 1));
          if (decoded.isNotEmpty) return decoded;
        }
      } catch (_) {}
    } else if (coverUrl.isNotEmpty && !coverUrl.startsWith('content://')) {
      // 本地路径封面：插件歌曲可能携带 file:// 或绝对路径的缓存封面。
      try {
        var path = coverUrl;
        if (path.startsWith('file://')) path = path.substring('file://'.length);
        final file = File(path);
        if (await file.exists()) return await file.readAsBytes();
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

  /// 歌词字号调整弹窗：双滑杆实时调整（主歌词 + 迷你歌词各自独立），
  /// 下方用示例歌词预览效果，拖动即写入设置。
  /// 设置页“播放详情页歌词-歌词字号”共用同一份数据。
  Future<void> _pickLyricFontSize() async {
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _LyricFontSizeSheet(
        initial: ref.read(settingsProvider).valueOrNull?.lyricFontSize ?? 18.0,
        initialMini:
            ref.read(settingsProvider).valueOrNull?.miniLyricFontSize ?? 14.0,
        onChanged: (value) =>
            ref.read(settingsProvider.notifier).setLyricFontSize(value),
        onMiniChanged: (value) =>
            ref.read(settingsProvider.notifier).setMiniLyricFontSize(value),
      ),
    );
  }

  /// 播放/关闭 MV 或 Bilibili 视频：当前正在播放则关闭，否则按类型启动。
  Future<void> _toggleMvOrVideo(QueueItem item) async {
    if (_videoSongPath == item.path) {
      await _closeBilibiliVideo();
      return;
    }
    final isBili = _isBilibiliQueueItem(item);
    if (!isBili && !await _checkMvAvailable(item)) {
      if (!mounted) return;
      XyNotice.show(context, message: '暂无可播放的 MV', type: XyNoticeType.info);
      return;
    }
    await _startBilibiliVideo(item, isMv: !isBili);
  }

  /// MV 横竖屏切换：横屏时锁定横向并进入沉浸式全屏（隐藏状态栏/导航栏，
  /// 视频铺满整屏）；切回竖屏时恢复系统默认方向与 edgeToEdge 系统栏。
  Future<void> _toggleVideoOrientation() async {
    final next = !_videoLandscape;
    if (!mounted) return;
    setState(() => _videoLandscape = next);
    await SystemChrome.setPreferredOrientations(
      next
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : DeviceOrientation.values,
    );
    await SystemChrome.setEnabledSystemUIMode(
      next ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  /// 视频关闭或页面退出时解除横屏锁定与沉浸模式，恢复系统默认。
  void _resetVideoOrientation() {
    if (!_videoLandscape) return;
    _videoLandscape = false;
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  }

  Future<void> _addToPlaylist(QueueItem item) async {
    final result = await showPlaylistPicker(context, items: [item]);
    if (!mounted || result == null) return;
    final playlist = ref
        .read(playlistsProvider)
        .where((value) => value.id == result.playlistId)
        .firstOrNull;
    final name = playlist?.name;
    XyNotice.show(
      context,
      message: result.existsCount > 0
          ? (name == null ? '该歌曲已在歌单中' : '该歌曲已在歌单“$name”中')
          : (name == null ? '已添加到歌单' : '已添加到歌单“$name”'),
      type: result.existsCount > 0
          ? XyNoticeType.warning
          : XyNoticeType.success,
    );
  }

  /// 歌词偏移实时应用（偏移子面板的滑杆/chip 每次变动都会调用）：
  /// 静默保存并更新页面状态，不弹提示——弹窗内的偏移标签本身就是反馈。
  Future<void> _applyLyricsOffset(QueueItem item, int tenths) async {
    if (ref.read(playerProvider).current?.path != item.path) return;
    try {
      await _saveLyricsOffset(item.path, tenths);
      if (!mounted || ref.read(playerProvider).current?.path != item.path) {
        return;
      }
      setState(() => _lyricsOffsetTenths = clampLyricsOffsetTenths(tenths));
    } catch (_) {
      // 保存失败保持现状：子面板展示的值可能与持久化值短暂不一致，
      // 下次重进弹窗会从页面状态重新读取。
    }
  }

  Future<void> _pickPlaybackQuality() async {
    final item = ref.read(playerProvider).current;
    if (item == null) return;
    // 当前音质取播放器实际状态（正在播放歌曲的档位），无记录时回退
    // 设置的在线默认音质——弹窗勾选回显与播放页徽标保持一致。
    final playbackQuality = ref.read(playerProvider).currentQuality.trim();
    final current = playbackQuality.isNotEmpty
        ? playbackQuality
        : ref.read(settingsProvider).valueOrNull?.onlineDefaultQuality ??
              '320k';
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
  /// 两个“无损 FLAC”或两个“超清母带”。同组别名若包含当前选中的
  /// token，则用选中 token 替换该组保留项，保证勾选状态能正确回显；
  /// 最终顺序由调用方按档位排序。
  List<String> _dedupeQualityByLabel(List<String> qualities, String preferred) {
    final trimmed = preferred.trim();
    final seenLabels = <String>{};
    final result = <String>[];
    for (final value in qualities) {
      final label = _qualityLabel(value);
      if (!seenLabels.add(label)) continue;
      // 同组别名的第一个保留项：若之后发现选中的 token 同组，会替换它。
      result.add(value);
    }
    if (trimmed.isNotEmpty &&
        qualities.contains(trimmed) &&
        !result.contains(trimmed)) {
      final label = _qualityLabel(trimmed);
      final index = result.indexWhere((v) => _qualityLabel(v) == label);
      if (index >= 0) result[index] = trimmed;
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
          .timeout(
            const Duration(seconds: 12),
            onTimeout: () => const <String>[],
          );
      final result = <String>{...discovered, ...fallback};
      final list = result.isEmpty ? const ['320k'] : result.toList();
      // 去重后再按档位（低 → 高）排序：兜底追加的当前音质 token 会落在
      // 列表末尾，且超时/异常路径直接返回未排序列表，统一排一次保证
      // 选择器始终“低清在上、超清母带在最下”。
      return _dedupeQualityByLabel(list, current)..sort((a, b) {
        final rank = qualityTierRank(a).compareTo(qualityTierRank(b));
        return rank != 0 ? rank : a.compareTo(b);
      });
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
    // 网盘歌曲（remote://）没有本地 sidecar 可写，由记忆歌词负责持久化。
    if (playbackSourceTypeFor(item) == PlaybackSourceType.localFile &&
        !item.path.startsWith('remote://')) {
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
      // 网盘歌曲没有本地 sidecar，跳过写盘，仅依靠记忆歌词持久化。
      if (playbackSourceTypeFor(item) == PlaybackSourceType.localFile &&
          !item.path.startsWith('remote://')) {
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
    final raw = item.lyricsRaw?.trim() ?? '';
    if (raw.isEmpty || !needsLyricNormalization(raw)) return raw;

    // 先用 Rust 歌词解析器解码 QRC/KRC 密文、QRC 容器 XML 与非标准词级
    // 时间轴，再把展示行写成标准增强 LRC（`[行]<词起>词…<词束>`），
    // 保证第三方播放器也能显示逐字。
    final decoded = await convertLyricsToEnhancedLrc(raw);
    if (decoded.isNotEmpty) return decoded;

    // 部分插件的搜索结果携带的是损坏的 lyric 字段，但 getLyrics 接口
    // 会返回正常正文；重新请求一次并同样规范化，避免把密文或非标准
    // 时间轴写入文件。
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
          if (retry.isNotEmpty) {
            final retryDecoded = await convertLyricsToEnhancedLrc(retry);
            if (retryDecoded.isNotEmpty) return retryDecoded;
            if (!isUnreadableLyrics(retry)) return retry;
          }
        }
      } catch (_) {
        // 歌词属于下载附加项，重新获取失败不应影响音频下载。
      }
    }
    // 无法可靠解码时宁可不保存歌词，也不要生成用户无法阅读的乱码文件。
    return isUnreadableLyrics(raw) ? '' : raw;
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
    // 同一首歌已有下载中的任务时直接拦截，避免重复下载与重复记录。
    final historyNotifier = ref.read(downloadHistoryProvider.notifier);
    if (historyNotifier.hasActiveDownload(item.path)) {
      XyNotice.show(context, message: '《${item.title}》正在下载中，可在“下载管理”查看进度');
      return;
    }
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
          initialWriteMetadata: settings?.downloadWriteMetadata ?? true,
        ),
      );
    } else {
      options = _DownloadOptions(
        directory: initialDirectory,
        quality: settings?.downloadQuality ?? playback.currentQuality,
        writeMetadata: settings?.downloadWriteMetadata ?? true,
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
    await settingsNotifier.setDownloadWriteMetadata(options.writeMetadata);
    if (options.dontAskAgain) {
      await settingsNotifier.setAskDownloadDetails(false);
    }
    if (!mounted) return;
    // SAF 目录授权校验：重装应用或恢复备份后持久化授权会丢失，直接写入
    // 会被系统以 MANAGE_DOCUMENTS 权限拒绝；失效时引导重新选择目录。
    final downloadDirectory = await ensureSafDirectoryAccess(
      context,
      ref,
      directory,
    );
    if (!mounted) return;
    if (downloadDirectory == null) {
      XyNotice.show(
        context,
        message: '已取消下载：下载目录未授权',
        type: XyNoticeType.warning,
      );
      return;
    }
    final usesSafDirectory = AndroidStorage.isTreeUri(downloadDirectory);
    XyNotice.show(
      context,
      message: '下载已开始 ${item.title}',
      type: XyNoticeType.success,
    );
    // 下载历史记录：进度、实际音质、失败原因均可在“下载管理”页回溯。
    final historyId = historyNotifier.begin(
      title: item.title,
      artist: item.artist,
      album: item.album,
      quality: quality,
      durationMs: item.durationMs,
      sourcePath: item.path,
      pluginId: item.pluginId,
      pluginData: item.pluginData,
      coverUrl: item.coverUrl,
    );
    try {
      final workDirectory = usesSafDirectory
          ? await resolveDownloadStagingDirectory()
          : downloadDirectory;
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
      final savedPath = await trackDownloadProgress(
        history: historyNotifier,
        entryId: historyId,
        url: source.url,
        headers: source.headers,
        destPath: destination,
        download: () => downloadOnlineSong(
          url: source.url,
          destPath: destination,
          headersJson: jsonEncode(source.headers),
        ),
      );
      // 校验真实音质：magic bytes 检测实际格式，纠正扩展名并记录降级。
      final verified = await verifyDownloadedAudioQuality(
        savedPath: savedPath,
        selectedQuality: quality,
        durationSec: (item.durationMs / 1000).round(),
        songTitle: item.title,
      );
      // 正在播放的歌通常已加载歌词；lyricsRaw 为空（如刚启动就下载）
      // 时用音源解析带回的歌词兜底。
      var lyrics = await _lyricsForDownload(item);
      if (lyrics.isEmpty && source.lyrics.trim().isNotEmpty) {
        lyrics = await normalizeLyricsForDownload(source.lyrics);
      }
      final coverUrl = item.coverUrl?.trim() ?? '';
      await finalizeDownloadExtras(
        requestJson: jsonEncode({
          if ((settings?.downloadLyrics ?? true) && lyrics.isNotEmpty)
            'lyricsText': lyrics,
          if ((settings?.downloadLyrics ?? true) && lyrics.isNotEmpty)
            'lyricsPath': p.setExtension(verified.path, '.lrc'),
          if (coverUrl.startsWith('http://') || coverUrl.startsWith('https://'))
            'coverUrl': coverUrl,
          'embedCover': options.writeMetadata,
          if (options.writeMetadata)
            'metadata': {
              'filePath': verified.path,
              'title': item.title,
              'artist': item.artist,
              'album': item.album,
              if (lyrics.isNotEmpty) 'lyrics': lyrics,
            },
        }),
      );
      var finalPath = verified.path;
      if (usesSafDirectory) {
        finalPath = await AndroidStorage.copyFileToDirectory(
          directoryUri: downloadDirectory,
          sourcePath: verified.path,
          fileName: p.basename(verified.path),
          mimeType: 'audio/*',
        );
        final lrcPath = p.setExtension(verified.path, '.lrc');
        if (await File(lrcPath).exists()) {
          await AndroidStorage.copyFileToDirectory(
            directoryUri: downloadDirectory,
            sourcePath: lrcPath,
            fileName: p.basename(lrcPath),
            mimeType: 'text/plain',
          );
        }
        try {
          await File(verified.path).delete();
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
          quality: verified.quality,
          coverUrl: item.coverUrl,
          lyricsRaw: lyrics.isEmpty ? null : lyrics,
        ),
      );
      historyNotifier.complete(
        historyId,
        savedPath: finalPath,
        actualQuality: verified.quality,
      );
      if (mounted) {
        XyNotice.show(
          context,
          message: verified.warning ?? '下载完成：${p.basename(verified.path)}',
          type: verified.warning == null
              ? XyNoticeType.success
              : XyNoticeType.warning,
          duration: verified.warning == null
              ? const Duration(milliseconds: 2600)
              : const Duration(milliseconds: 5000),
        );
      }
    } catch (error) {
      if (error is DownloadPausedSignal) {
        // 用户在下载管理中暂停/删除了任务：状态已标记，不提示失败。
        if (mounted) {
          XyNotice.show(context, message: '已暂停：${item.title}');
        }
      } else {
        historyNotifier.fail(historyId, _errorText(error));
        if (mounted) {
          XyNotice.show(
            context,
            message: '下载失败：${_errorText(error)}',
            type: XyNoticeType.error,
          );
        }
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

  String _errorText(Object error) =>
      error.toString().replaceFirst('Exception: ', '').trim();

  /// 竖屏沉浸式播放栏可见时重置 5 秒隐藏倒计时（封面页 ↔ 歌词页
  /// 翻页时调用）：封面页与歌词页共用同一弹出播放栏，翻页不打断
  /// 播放栏显示（旧版翻页会收起播放栏，切到歌词页后播放栏消失，
  /// 需要再点一次才能唤出）。
  void _keepPortraitImmersiveBar() {
    if (!_portraitControlsVisible) return;
    _immersiveBarTimer?.cancel();
    _immersiveBarTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _portraitControlsVisible) {
        setState(() => _portraitControlsVisible = false);
      }
    });
  }

  /// 布局完成后测量沉浸式播放栏的自然高度（播放栏常驻布局、仅视觉
  /// 隐藏，因此隐藏状态下也可测量）。高度变化时 setState 生效，
  /// 供播放栏弹出时内容区收缩让位（恢复沉浸式开启前的排版）。
  void _measureImmersiveBars() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final portrait = _barHeightOf(_portraitImmersiveBarKey);
      final landscape = _barHeightOf(_landscapeImmersiveBarKey);
      if (portrait == null && landscape == null) return;
      if (portrait == _portraitImmersiveBarHeight &&
          landscape == _landscapeImmersiveBarHeight) {
        return;
      }
      setState(() {
        if (portrait != null) _portraitImmersiveBarHeight = portrait;
        if (landscape != null) _landscapeImmersiveBarHeight = landscape;
      });
    });
  }

  double? _barHeightOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize && box.size.height > 0) {
      return box.size.height;
    }
    return null;
  }

  void _showDetailPage(bool showLyrics) {
    if (_showLyrics != showLyrics) {
      // 竖屏沉浸式翻页时保持弹出播放栏显示，仅重置 5 秒隐藏倒计时。
      _keepPortraitImmersiveBar();
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
          message: '未检测到歌词，可在歌词页关联歌词',
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
    // 横屏锁定跟随详情页生命周期，离开页面即解除。
    _resetVideoOrientation();
    VideoPlaybackSession.revision.removeListener(_syncVideoSession);
    _playingSubscription?.close();
    _playingSubscription = null;
    if (_screenAwake) {
      unawaited(_setScreenAwake(false));
    }
    _unbindVideoController(_videoController);
    _detailPageController.dispose();
    _immersiveBarTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 播放进度每 40–80ms 更新一次；这里只监听歌曲对象，避免进度变化导致
    // 全屏背景、封面和模糊层一起高频重建。
    final current = ref.watch(playerProvider.select((state) => state.current));
    // 播放页封面样式：经典方形 / 圆形旋转 / 沉浸式 / 黑胶唱片（外观设置）。
    final coverStyle =
        ref.watch(
          settingsProvider.select((s) => s.valueOrNull?.playerCoverStyle),
        ) ??
        PlayerCoverStyle.classic;
    _loadLyricsOffsetFor(current);
    // 换歌时检测 MV 可用性（同步前缀先重置旧结果，按钮判定见
    // _mvButtonVisible），检测完成后再通过 setState 刷新按钮显隐。
    unawaited(_refreshMvAvailability(current));
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

    // MV/视频播放时全屏覆盖（参考 MusicFree 短视频横竖屏效果）：整屏纯黑
    // 背景，视频画面居中，播放/进度/横竖屏切换/关闭等控制层全部内置于
    // 视频视图，不再复用详情页头部与底部控制卡。
    final videoActive =
        _videoSongPath != null && _videoSongPath == current?.path;
    if (videoActive) {
      // 顶部标题栏副标题：歌手 · 画质（QQ 音乐 MV 播放页排版）。
      final videoSubtitle = [
        if (current?.artist.isNotEmpty == true) current!.artist,
        _displayVideoQuality,
      ].join(' · ');
      return Scaffold(
        backgroundColor: Colors.black,
        body: _BilibiliVideoView(
          controller: _videoController,
          loading: _videoLoading,
          error: _videoError,
          landscape: _videoLandscape,
          onToggleOrientation: () => unawaited(_toggleVideoOrientation()),
          onClose: () => unawaited(_closeBilibiliVideo()),
          title: current?.title ?? '',
          subtitle: videoSubtitle,
          onPickSpeed: () => unawaited(_pickVideoSpeed()),
          onPickQuality: () => unawaited(_pickVideoQuality()),
          onToggleMute: () => unawaited(_toggleVideoMute()),
          onDownload: () => unawaited(_downloadCurrentVideo()),
          onReload: () => unawaited(_reloadVideoPlayback()),
          onSelectQuality: (quality) {
            if (_videoLoading) return;
            unawaited(_switchVideoQuality(quality));
          },
          qualityChoices: _videoAvailableQualities.isNotEmpty
              ? _videoAvailableQualities
              : const ['1080P', '720P', '480P'],
          currentQuality: _videoQuality,
        ),
      );
    }

    final viewport = MediaQuery.sizeOf(context);
    final isLandscape = viewport.width > viewport.height;

    final detailHeader = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
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
          // 竖屏封面页顶栏不显示歌名/歌手（标题由底部控制卡承载）；
          // 歌词页与横屏（控制卡无标题区）仍保留顶栏标题。
          Expanded(
            child: (isLandscape || _showLyrics)
                ? Column(
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
                    ],
                  )
                : const SizedBox.shrink(),
          ),
          // 收藏按钮仅保留：竖屏底部控制卡内 + 横屏封面右上角（见
          // _BigCover landscape 分支），顶部栏不再放收藏入口。
          // 封面样式切换已移入“更多”菜单；关联歌词由歌词页自带入口提供。
          IconButton(
            tooltip: '更多',
            icon: const Icon(Icons.more_horiz_rounded, color: Colors.white),
            onPressed: current == null ? null : () => _showMoreMenu(current),
          ),
        ],
      ),
    );

    // 竖屏沉浸式歌词：开启后封面页/歌词页铺满内容区，播放栏隐藏、
    // 单击原播放栏位置弹出（上浮动画），5 秒无操作自动隐藏。
    final portraitImmersive =
        ref.watch(
          settingsProvider.select(
            (s) => s.valueOrNull?.portraitImmersiveLyrics,
          ),
        ) ??
        false;
    // 沉浸模式下迷你歌词行数：播放栏隐藏时展示四行（当前 + 后续歌词，
    // 翻译单独占行），播放栏弹出（上浮动画）时自然收为两行，自动隐藏
    // 后恢复四行。展示区预留行数恒为 4，避免封面随行数抖动。
    final immersiveMiniLyrics = portraitImmersive && current != null;
    final miniLyricRows =
        immersiveMiniLyrics && !_portraitControlsVisible ? 4 : 2;
    final miniLyricReserveRows = immersiveMiniLyrics ? 4 : 2;

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
              // 竖屏沉浸式翻页时保持弹出播放栏显示，仅重置 5 秒隐藏
              // 倒计时：封面页与歌词页共用同一播放栏，翻页不应收起。
              _keepPortraitImmersiveBar();
              setState(() => _showLyrics = showLyrics);
            }
          },
          children: [
            if (coverStyle == PlayerCoverStyle.immersive)
              _ImmersiveCoverPage(
                key: ValueKey('cover:${current?.path ?? ''}'),
                item: current,
                offsetTenths: _lyricsOffsetTenths,
                // 竖屏时封面本体铺到屏幕顶端（见 _ImmersiveTopCover），
                // 这里退化为透明手势占位（横屏由左侧封面栏直接绘制）。
                paintCover: false,
                miniLyricRows: miniLyricRows,
                miniLyricReserveRows: miniLyricReserveRows,
                onTap: current == null ? null : _toggleLyrics,
                onLongPress: current == null
                    ? null
                    : () => unawaited(_showMoreMenu(current)),
              )
            else
              _BigCover(
                key: ValueKey('cover:${current?.path ?? ''}'),
                item: current,
                offsetTenths: _lyricsOffsetTenths,
                style: coverStyle,
                miniLyricRows: miniLyricRows,
                miniLyricReserveRows: miniLyricReserveRows,
                onTap: current == null ? null : _toggleLyrics,
                // 长按封面直接弹出“更多”菜单，与右上角更多按钮一致。
                onLongPress: current == null
                    ? null
                    : () => unawaited(_showMoreMenu(current)),
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
                onLinkLyrics: () => unawaited(_linkLyrics(current)),
              ),
          ],
        ),
      ),
    );

    final detailControls = Padding(
      // 仅竖屏使用：控制卡固定在底部，横屏走 buildLandscapeControls。
      // 播放栏整体靠近屏幕边缘（左右/下方内缩自 36px 减至 ~22px）。
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: _GlassControlCard(
        notifier: notifier,
        current: current,
        showMetadata: !_showLyrics,
        onDownload: current == null
            ? null
            : () => unawaited(_downloadCurrent(current)),
        onLyricsOffset: current == null
            ? null
            : () => unawaited(_showLyricsOffsetSheet(current)),
        onLinkLyrics: current == null
            ? null
            : () => unawaited(_linkLyrics(current)),
        onDesktopLyrics: () => unawaited(_toggleDesktopLyrics()),
        onQuality: () => unawaited(_pickPlaybackQuality()),
        onLyricFontSizePage: () => unawaited(_pickLyricFontSize()),
        onPlayMv: current == null || !_mvButtonVisible(current)
            ? null
            : () => unawaited(_toggleMvOrVideo(current)),
      ),
    );
    final detailContent = detailPager;

    // 横屏沉浸式歌词：开启后右半屏只显示歌词，点按弹出播放栏。
    final landscapeImmersive =
        ref.watch(
          settingsProvider.select(
            (s) => s.valueOrNull?.landscapeImmersiveLyrics,
          ),
        ) ??
        false;

    // 竖屏沉浸式：封面页与歌词页统一铺满内容区（封面 + 迷你歌词 /
    // 纯歌词），播放栏隐藏，单击原播放栏位置弹出，5 秒无操作自动
    // 隐藏（与横屏逻辑一致）。portraitImmersive 已在 detailPager
    // 构建前求出（迷你歌词行数需要）。

    // 横屏右栏的播放控制卡：标题/歌手已在顶部展示，仅保留操作按钮行。
    Widget buildLandscapeControls() => Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: _GlassControlCard(
        notifier: notifier,
        current: current,
        showMetadata: false,
        onDownload: current == null
            ? null
            : () => unawaited(_downloadCurrent(current)),
        onLyricsOffset: current == null
            ? null
            : () => unawaited(_showLyricsOffsetSheet(current)),
        onLinkLyrics: current == null
            ? null
            : () => unawaited(_linkLyrics(current)),
        onDesktopLyrics: () => unawaited(_toggleDesktopLyrics()),
        onQuality: () => unawaited(_pickPlaybackQuality()),
        onLyricFontSizePage: () => unawaited(_pickLyricFontSize()),
        onPlayMv: current == null || !_mvButtonVisible(current)
            ? null
            : () => unawaited(_toggleMvOrVideo(current)),
      ),
    );

    // 横屏按钮栏整体缩放（含播放键），适配半屏宽度。
    Widget scaledLandscapeControls() => Transform.scale(
      scale: .84,
      alignment: Alignment.bottomCenter,
      child: buildLandscapeControls(),
    );

    Widget buildLandscapeLyrics() {
      if (current == null) {
        return const Center(
          child: Text('暂无歌词', style: TextStyle(color: Colors.white54)),
        );
      }
      return _LyricsView(
        key: ValueKey('lyrics:${current.path}'),
        item: current,
        offsetTenths: _lyricsOffsetTenths,
        onLinkLyrics: () => unawaited(_linkLyrics(current)),
      );
    }

    // 横屏右半屏：普通模式歌词 + 常驻控制栏；沉浸式仅歌词，单击弹出
    // 播放栏，5 秒无操作自动隐藏。
    Widget buildLandscapeRightPane() {
      final lyrics = buildLandscapeLyrics();
      if (!landscapeImmersive) {
        return Column(
          children: [
            Expanded(child: lyrics),
            scaledLandscapeControls(),
          ],
        );
      }
      // 布局后测量播放栏自然高度（隐藏状态也可测：常驻布局仅视觉隐藏）。
      _measureImmersiveBars();
      // 显示控制栏：设 visible=true + 启动/重启 5 秒隐藏定时器。
      void showBar() {
        _immersiveBarTimer?.cancel();
        setState(() => _landscapeControlsVisible = true);
        _immersiveBarTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) setState(() => _landscapeControlsVisible = false);
        });
      }

      // 隐藏控制栏：取消定时器 + 设 visible=false。
      void hideBar() {
        _immersiveBarTimer?.cancel();
        _immersiveBarTimer = null;
        if (mounted) setState(() => _landscapeControlsVisible = false);
      }

      // 重置倒计时（控制栏内任何交互都触发）。
      void keepBar() {
        if (!_landscapeControlsVisible) return;
        _immersiveBarTimer?.cancel();
        _immersiveBarTimer = Timer(const Duration(seconds: 5), () {
          if (mounted && _landscapeControlsVisible) {
            setState(() => _landscapeControlsVisible = false);
          }
        });
      }

      final barVisible = _landscapeControlsVisible;
      // 播放栏弹出时歌词底部收缩让位（与上浮动画同步），恢复沉浸式
      // 开启前的排版：歌词不再叠在播放栏底下；隐藏时歌词铺满全屏。
      final barHeight = _landscapeImmersiveBarHeight;
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // 播放栏可见时，点歌词空白处立即收起。
              onTap: barVisible ? hideBar : null,
              child: AnimatedPadding(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                padding: EdgeInsets.only(bottom: barVisible ? barHeight : 0),
                child: lyrics,
              ),
            ),
          ),
          if (!barVisible)
            // 播放栏隐藏时叠加透明点按层：任意单击弹出播放栏。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: showBar,
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              key: _landscapeImmersiveBarKey,
              ignoring: !barVisible,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                opacity: barVisible ? 1 : 0,
                // 上浮动画：弹出时整栏自底部上浮滑入并淡入，
                // 隐藏时下滑沉出内容区并淡出。
                child: AnimatedSlide(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  offset: barVisible ? Offset.zero : const Offset(0, 1),
                  // Listener 监听控制栏内任意 PointerDown，重置 5 秒倒计时，
                  // 避免用户正在操作时栏突然消失。
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (_) => keepBar(),
                    // 沉浸式歌词的弹出播放栏不带背景，直接浮在歌词上。
                    child: scaledLandscapeControls(),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    // 竖屏沉浸式内容（封面页与歌词页通用）：内容铺满整个区域
    //（封面 + 迷你歌词 / 纯歌词），播放栏隐藏，单击原播放栏位置
    // 弹出（上浮动画），弹出期间左右翻页（封面页 ↔ 歌词页）播放栏
    // 保持显示，5 秒无操作自动隐藏（与横屏逻辑一致）。
    Widget buildPortraitImmersiveContent() {
      // 布局后测量播放栏自然高度（隐藏状态也可测：常驻布局仅视觉隐藏）。
      _measureImmersiveBars();
      // 显示控制栏：设 visible=true + 启动/重启 5 秒隐藏定时器。
      void showBar() {
        _immersiveBarTimer?.cancel();
        setState(() => _portraitControlsVisible = true);
        _immersiveBarTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) setState(() => _portraitControlsVisible = false);
        });
      }

      final barVisible = _portraitControlsVisible;
      // 播放栏弹出时内容区底部收缩让位（与上浮动画同步），恢复沉浸式
      // 开启前的排版：播放栏位置的歌词隐藏，不再叠在栏底下；隐藏时
      // 歌词翻页区铺满整个内容区（含原播放栏区域）。
      final barHeight = _portraitImmersiveBarHeight;
      return Stack(
        fit: StackFit.expand,
        children: [
          AnimatedPadding(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.only(bottom: barVisible ? barHeight : 0),
            child: detailContent,
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Stack(
              key: _portraitImmersiveBarKey,
              children: [
                // 播放栏隐藏时仍保留布局尺寸，确保与原位置完全
                // 一致；不可见且不响应点击。上浮动画：弹出时整栏
                // 自底部上浮滑入并淡入，隐藏时下滑沉出内容区并淡出。
                IgnorePointer(
                  ignoring: !barVisible,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    opacity: barVisible ? 1 : 0,
                    child: AnimatedSlide(
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      offset: barVisible ? Offset.zero : const Offset(0, 1),
                      // Listener 监听控制栏内任意 PointerDown，重置 5 秒
                      // 倒计时，避免用户正在操作时栏突然消失。
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (_) => _keepPortraitImmersiveBar(),
                        // 沉浸式歌词的弹出播放栏不带背景，直接浮在歌词上。
                        child: detailControls,
                      ),
                    ),
                  ),
                ),
                // 隐藏时原播放栏区域为点按热区：单击弹出播放栏。
                if (!barVisible)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: showBar,
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }

    // 竖屏沉浸式：封面页与歌词页都铺满内容区，播放栏隐藏，
    // 单击原播放栏位置弹出，5 秒无操作自动隐藏。
    final portraitImmersiveActive = portraitImmersive && current != null;

    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // 电脑版详情页同款：封面铺满、重度模糊并叠加暗色氛围层。
            _PlayerDetailBackground(current: current),
            // 沉浸式竖屏：封面顶到屏幕顶端，标题行浮在封面上（否则
            // header 区域露出背景，显得封面“没有覆盖上部”）。
            // 仅封面页显示；歌词页不叠沉浸式封面，露出模糊背景。
            if (coverStyle == PlayerCoverStyle.immersive &&
                !isLandscape &&
                current != null &&
                !_showLyrics)
              Positioned(
                top: 0,
                left: 0,
                child: _ImmersiveTopCover(item: current, side: viewport.width),
              ),
            SafeArea(
              child: isLandscape
                  ? Column(
                      children: [
                        detailHeader,
                        Expanded(
                          // 横屏平分式排版（参考 MusicFree）：左半屏封面正中
                          // 缩放、无迷你歌词；右半屏歌词 + 播放控制。
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: _BigCover(
                                  key: ValueKey(
                                    'coverLandscape:${current?.path ?? ''}',
                                  ),
                                  item: current,
                                  offsetTenths: _lyricsOffsetTenths,
                                  // 沉浸式在横屏分栏下退化为居中方形封面。
                                  style: coverStyle,
                                  landscape: true,
                                  onLongPress: current == null
                                      ? null
                                      : () => unawaited(_showMoreMenu(current)),
                                ),
                              ),
                              Expanded(child: buildLandscapeRightPane()),
                            ],
                          ),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        detailHeader,
                        Expanded(
                          // 竖屏沉浸式：封面页/歌词页铺满内容区，播放栏
                          // 浮在原位置；其余情况保持常驻播放栏布局。
                          child: portraitImmersiveActive
                              ? buildPortraitImmersiveContent()
                              : detailContent,
                        ),
                        if (!portraitImmersiveActive) detailControls,
                      ],
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
    this.initialWriteMetadata = true,
  });

  final String initialDirectory;
  final String initialQuality;
  final List<String> qualities;
  final bool initialWriteMetadata;

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
        writeMetadata: widget.initialWriteMetadata,
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
                CheckboxListTile(
                  value: _dontAskAgain,
                  onChanged: (value) =>
                      setState(() => _dontAskAgain = value == true),
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('不再弹出此窗口', style: TextStyle(fontSize: 13)),
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
        children: [...chips, if (_overflow) _buildToggleChip(expanded: true)],
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
      label: Text(_qualityLabel(quality), style: const TextStyle(fontSize: 12)),
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

/// 播放页更多菜单底部弹层：顶部 5 个圆形快捷按钮（下载——本地歌曲时为
/// 歌词偏移/加到歌单/换源+还原/音质/关联歌词）+ 下方设置列表。开关行与
/// 封面样式切换在弹层内直接生效（watch 设置即时刷新）；其余条目收起弹层
/// 后由宿主页面拉起对应面板。
class _PlayerMoreSheet extends ConsumerStatefulWidget {
  const _PlayerMoreSheet({
    required this.item,
    required this.isLandscape,
    required this.restorableSource,
    required this.hasLyricsAssociation,
    required this.onDownload,
    required this.onAddToPlaylist,
    required this.onSwitchSource,
    required this.onRestoreSource,
    required this.onPickQuality,
    required this.onPickLyricFontSize,
    required this.onShare,
    required this.onToggleDesktopLyrics,
    required this.onShowEffects,
    required this.onLinkLyrics,
    required this.onUnlinkLyrics,
    required this.onShowLyricsOffset,
    required this.onCycleCoverStyle,
    required this.onShowComments,
    required this.onPickSleepTimer,
    required this.onShowSongInfo,
  });

  final QueueItem item;

  /// 打开菜单时的屏幕方向：决定沉浸式歌词开关读写哪个设置。
  final bool isLandscape;

  /// 当前歌曲换过源时展示「还原」小按钮。
  final bool restorableSource;

  /// 当前歌曲存在歌词关联时展示「解除关联」入口。
  final bool hasLyricsAssociation;

  final VoidCallback onDownload;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onSwitchSource;
  final VoidCallback onRestoreSource;
  final VoidCallback onPickQuality;
  final VoidCallback onPickLyricFontSize;
  final VoidCallback onShare;
  final VoidCallback onToggleDesktopLyrics;
  final VoidCallback onShowEffects;
  final VoidCallback onLinkLyrics;
  final VoidCallback onUnlinkLyrics;
  final VoidCallback onShowLyricsOffset;
  final VoidCallback onCycleCoverStyle;
  final VoidCallback onShowComments;
  final VoidCallback onPickSleepTimer;

  /// 打开歌曲信息面板（顶栏信息卡点击）。
  final VoidCallback onShowSongInfo;

  @override
  ConsumerState<_PlayerMoreSheet> createState() => _PlayerMoreSheetState();
}

class _PlayerMoreSheetState extends ConsumerState<_PlayerMoreSheet> {
  /// 解除关联后行内即时移除入口（弹层不收起）。
  late bool _hasLyricsAssociation = widget.hasLyricsAssociation;

  /// 收起弹层后执行宿主动作（子面板由宿主页面拉起）。
  void _popThen(VoidCallback action) {
    Navigator.pop(context);
    action();
  }

  /// 圆形快捷按钮：圆形底 + 图标 + 下方文字标签（可选附加小按钮）。
  Widget _quickButton(
    BuildContext context, {
    IconData? icon,
    Widget? iconOverride,
    required String label,
    required VoidCallback onTap,
    Widget? extra,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: scheme.surfaceContainerHighest,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: 52,
              height: 52,
              child:
                  iconOverride ??
                  Icon(icon!, size: 23, color: scheme.onSurface),
            ),
          ),
        ),
        const SizedBox(height: 7),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        ?extra,
      ],
    );
  }

  /// 换源按钮下方的「还原」小按钮：恢复换源前的原始音源。
  Widget _restorePill(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _popThen(widget.onRestoreSource),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '还原',
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  /// 设置行：图标 + 标题 + 当前值 + 尾部控件（开关/解除关联/箭头）。
  /// 统一最小行高并垂直居中，保证开关行、纯文字行、带小按钮的行
  /// 行高完全一致。
  Widget _settingRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? value,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 11),
            // 标题用 Expanded 占满剩余宽度，保证当前值小字与尾部控件
            // 始终紧贴行右缘，各行右缘完全对齐。
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ),
            if (value?.isNotEmpty == true) ...[
              const SizedBox(width: 8),
              Text(
                value!,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
            ?trailing,
          ],
        ),
      ),
    );
  }

  /// 打开子面板的行：当前值 + 右箭头，收起弹层后由宿主拉起面板。
  Widget _panelRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? value,
    required VoidCallback onOpen,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return _settingRow(
      context,
      icon: icon,
      title: title,
      value: value,
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 20,
        color: scheme.outline,
      ),
      onTap: () => _popThen(onOpen),
    );
  }

  /// 开关行：整行可点，开关自身也响应（Switch 消费自身点击不冒泡）。
  /// Switch 收缩点击区避免撑高行，与其他行保持一致行高。
  Widget _switchRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return _settingRow(
      context,
      icon: icon,
      title: title,
      trailing: SwitchTheme(
        data: SwitchThemeData(
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Switch(value: value, onChanged: onChanged),
      ),
      onTap: () => onChanged(!value),
    );
  }

  /// 关联歌词行的「解除关联」小按钮：解除后行内移除入口，弹层不收起。
  Widget _unlinkButton(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _hasLyricsAssociation = false);
          widget.onUnlinkLyrics();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '解除关联',
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider).valueOrNull;
    final desktopLyricsEnabled = settings?.desktopLyricsEnabled ?? false;
    final immersiveEnabled = widget.isLandscape
        ? (settings?.landscapeImmersiveLyrics ?? false)
        : (settings?.portraitImmersiveLyrics ?? false);
    final coverStyle = settings?.playerCoverStyle ?? PlayerCoverStyle.classic;
    // 音效开/关指示以完整音效系统（均衡器/变速变调/混响/空间/高级）
    // 是否有任一启用为准；旧的 settings.equalizerEnabled 已不再参与。
    final effectsActive = ref.watch(
      effectsProvider.select(
        (value) => value.valueOrNull?.hasActiveEffects ?? false,
      ),
    );
    final lyricFontSize = settings?.lyricFontSize ?? 22.0;
    final sleepTimerEndsAt = ref.watch(
      playerProvider.select((state) => state.sleepTimerEndsAt),
    );
    // 本地歌曲无下载意义，快捷按钮位的「下载」改为「歌词偏移」。
    final isLocal =
        playbackSourceTypeFor(widget.item) == PlaybackSourceType.localFile;

    // 弹层总高不超过屏幕 60%：信息条与 5 个快捷按钮固定可见，
    // 下方设置列表独立滚动。
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .60,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 顶部当前歌曲信息卡：封面缩略图 + 歌名/副标题 + 分享，
              // 整卡可点进入歌曲信息面板（平台/ID/作者）。参考 BakaMusic
              // 弹层排版，卡片化后与下方圆形快捷按钮区拉开层次。
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Material(
                  color: scheme.surfaceContainerHighest.withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _popThen(widget.onShowSongInfo),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 10, 2, 10),
                      child: Row(
                        children: [
                          CoverImage(
                            songPath: widget.item.path,
                            imageUrl: widget.item.coverUrl,
                            width: 48,
                            height: 48,
                            radius: 10,
                            icon: Icons.music_note_rounded,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: scheme.onSurface,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  widget.item.album.trim().isEmpty
                                      ? widget.item.artist
                                      : '${widget.item.artist} · '
                                            '${widget.item.album.trim()}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: '分享',
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              Icons.share_outlined,
                              size: 20,
                              color: scheme.onSurfaceVariant,
                            ),
                            onPressed: () => _popThen(widget.onShare),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Icon(
                              Icons.chevron_right_rounded,
                              size: 20,
                              color: scheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              // 5 个圆形快捷按钮。
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: isLocal
                        ? _quickButton(
                            context,
                            icon: Icons.sync_alt_rounded,
                            label: '歌词偏移',
                            onTap: () => _popThen(widget.onShowLyricsOffset),
                          )
                        : _quickButton(
                            context,
                            icon: Icons.download_rounded,
                            label: '下载',
                            onTap: () => _popThen(widget.onDownload),
                          ),
                  ),
                  Expanded(
                    child: _quickButton(
                      context,
                      icon: Icons.playlist_add_rounded,
                      label: '加到歌单',
                      onTap: () => _popThen(widget.onAddToPlaylist),
                    ),
                  ),
                  Expanded(
                    child: _quickButton(
                      context,
                      icon: Icons.swap_horiz_rounded,
                      label: '换源',
                      onTap: () => _popThen(widget.onSwitchSource),
                      extra: widget.restorableSource
                          ? _restorePill(context)
                          : null,
                    ),
                  ),
                  Expanded(
                    child: _quickButton(
                      context,
                      icon: Icons.high_quality_outlined,
                      label: '音质',
                      onTap: () => _popThen(widget.onPickQuality),
                    ),
                  ),
                  Expanded(
                    child: _quickButton(
                      context,
                      iconOverride: Center(
                        child: Text(
                          '词',
                          style: TextStyle(
                            fontSize: 20,
                            height: 1,
                            fontWeight: FontWeight.w800,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      label: '关联歌词',
                      onTap: () => _popThen(widget.onLinkLyrics),
                      extra: _hasLyricsAssociation
                          ? _unlinkButton(context)
                          : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // 设置列表：超出剩余高度时仅在区域内滚动。
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _switchRow(
                        context,
                        icon: Icons.subtitles_outlined,
                        title: '桌面歌词',
                        value: desktopLyricsEnabled,
                        onChanged: (_) => widget.onToggleDesktopLyrics(),
                      ),
                      _settingRow(
                        context,
                        icon: Icons.format_size_rounded,
                        title: '歌词字号',
                        value: '${lyricFontSize.toInt()}号',
                        trailing: Icon(
                          Icons.chevron_right_rounded,
                          size: 20,
                          color: scheme.outline,
                        ),
                        onTap: () => _popThen(widget.onPickLyricFontSize),
                      ),
                      _switchRow(
                        context,
                        icon: Icons.fullscreen_rounded,
                        title: '沉浸式歌词',
                        value: immersiveEnabled,
                        onChanged: (next) {
                          // 横屏控制右半屏“仅歌词”形态，竖屏控制歌词页播放栏的
                          // 弹出/隐藏（各自的设置互不影响）。
                          widget.isLandscape
                              ? ref
                                    .read(settingsProvider.notifier)
                                    .setLandscapeImmersiveLyrics(next)
                              : ref
                                    .read(settingsProvider.notifier)
                                    .setPortraitImmersiveLyrics(next);
                        },
                      ),
                      _panelRow(
                        context,
                        icon: Icons.equalizer_rounded,
                        title: '音效',
                        value: effectsActive ? '开' : '关',
                        onOpen: widget.onShowEffects,
                      ),
                      _settingRow(
                        context,
                        icon: coverStyleIcon(coverStyle),
                        title: '封面样式',
                        value: coverStyleLabel(coverStyle),
                        onTap: widget.onCycleCoverStyle,
                      ),
                      _panelRow(
                        context,
                        icon: Icons.mode_comment_outlined,
                        title: '查看评论',
                        onOpen: widget.onShowComments,
                      ),
                      _panelRow(
                        context,
                        icon: Icons.timer_outlined,
                        title: '定时关闭',
                        value: _sleepTimerLabel(sleepTimerEndsAt),
                        onOpen: widget.onPickSleepTimer,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 歌曲信息面板的作者条目：平台原始歌手对象 + 提取后的展示字段。
class _SongArtistInfo {
  const _SongArtistInfo({
    required this.name,
    required this.artistId,
    required this.artistMid,
    required this.raw,
    this.avatar = '',
  });

  final String name;
  final String artistId;
  final String artistMid;

  /// 平台头像地址；部分平台（如 QQ/网易歌手条目）不提供，为空时回退占位图标。
  final String avatar;

  /// 平台原始歌手 map（含 name/id/mid 等），作为 getArtistWorks 的
  /// rawData 直传插件。
  final Map<String, dynamic> raw;
}

String _firstTextOf(Map<dynamic, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is num) return value.toString();
  }
  return '';
}

/// 从歌手对象提取头像地址。兼容字符串与 `{url: ...}` / `{urlTemplate: ...}`
/// 形式的嵌套值；顶层找不到时再查 user_info/author_info/user 等嵌套对象
/// （汽水等平台的歌手信息包裹在 user_info 里）。
String _artistAvatarOf(Map<String, dynamic> map) {
  const keys = [
    'avatar',
    'avatarUrl',
    'avatar_url',
    'avatarImgUrlStr',
    'headImg',
    'headPic',
    'headUrl',
    'head_url',
    'singerPic',
    'singerImg',
    'artistPic',
    'artistImg',
    'pic',
    'picUrl',
    'pic_url',
    'img',
    'imgUrl',
    'img_url',
    'img1v1Url',
    'img1v1',
    'image',
    'photo',
    'upic',
    'face',
    'userFace',
    'user_face',
    'cover',
    'coverUrl',
    'cover_url',
  ];
  String readFrom(Map<dynamic, dynamic> source) {
    for (final key in keys) {
      final value = source[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is Map) {
        final nested = value['url'] ?? value['urlTemplate'] ?? value['src'];
        if (nested is String && nested.trim().isNotEmpty) {
          return nested.trim();
        }
      }
    }
    return '';
  }

  final direct = readFrom(map);
  if (direct.isNotEmpty) return direct;
  for (final nestedKey in const ['user_info', 'author_info', 'user', 'artist']) {
    final nested = map[nestedKey];
    if (nested is Map) {
      final found = readFrom(nested);
      if (found.isNotEmpty) return found;
    }
  }
  return '';
}

/// 是否为 QQ 音乐曲目：封面/artwork 指向 y.gtimg.cn（其他平台不会命中）。
bool _isQqSong(QueueItem item) {
  final data = item.pluginData;
  final urls = <String?>[
    item.coverUrl,
    data?['artwork']?.toString(),
    data?['cover']?.toString(),
    data?['coverUrl']?.toString(),
  ];
  return urls.any((url) => (url ?? '').contains('gtimg.cn'));
}

/// QQ 音乐歌手头像约定地址（与桌面端 LxMusicSdk、Rust lx_search 一致）：
/// 歌手条目只带 mid，无头像字段，需按 T001 规则拼接。
String _qqSingerAvatarUrl(String mid) => mid.isEmpty
    ? ''
    : 'https://y.gtimg.cn/music/photo_new/T001R500x500M000$mid.jpg';

/// 从歌曲插件数据提取作者列表：优先归一化后的 singerList（QQ/汽水/
/// 网易等），兼容 artists/singers/singer/ar 等原始字段；都没有时按
/// item.artist 文本按常见分隔符拆分（无 ID，仅展示）。
List<_SongArtistInfo> _songArtistsOf(QueueItem item) {
  final data = item.pluginData;
  List<dynamic> entries = const [];
  if (data != null) {
    final list = data['singerList'] ??
        data['singers'] ??
        data['artists'] ??
        data['artistList'];
    if (list is List) {
      entries = list;
    } else {
      final single = data['singer'] ?? data['ar'] ?? data['author_info'];
      if (single is List) {
        entries = single;
      } else if (single is Map) {
        entries = [single];
      }
    }
  }
  final artists = <_SongArtistInfo>[];
  // QQ 歌手条目无头像字段，按 mid 拼 T001 头像地址兜底。
  final qqSong = _isQqSong(item);
  for (final entry in entries) {
    if (entry is Map) {
      final map = Map<String, dynamic>.from(entry);
      final name = _firstTextOf(map, const [
        'name',
        'title',
        'artist',
        'singer',
        'author',
      ]);
      final id = _firstTextOf(map, const [
        'id',
        'artistId',
        'artist_id',
        'singerId',
      ]);
      final mid = _firstTextOf(map, const [
        'mid',
        'artistMid',
        'artist_mid',
        'singerMid',
      ]);
      if (name.isNotEmpty || id.isNotEmpty) {
        final avatar = _artistAvatarOf(map);
        artists.add(
          _SongArtistInfo(
            name: name,
            artistId: id,
            artistMid: mid,
            avatar: avatar.isNotEmpty
                ? avatar
                : (qqSong ? _qqSingerAvatarUrl(mid) : ''),
            raw: map,
          ),
        );
      }
    } else if (entry is String && entry.trim().isNotEmpty) {
      artists.add(
        _SongArtistInfo(
          name: entry.trim(),
          artistId: '',
          artistMid: '',
          raw: {'name': entry.trim()},
        ),
      );
    }
  }
  if (artists.isEmpty && item.artist.trim().isNotEmpty) {
    for (final name in item.artist.split(RegExp(r'[/、,，&]'))) {
      final trimmed = name.trim();
      if (trimmed.isNotEmpty) {
        artists.add(
          _SongArtistInfo(
            name: trimmed,
            artistId: '',
            artistMid: '',
            raw: {'name': trimmed},
          ),
        );
      }
    }
  }
  return artists;
}

/// 歌曲信息面板：平台 + 歌曲（名称/ID/MID）+ 作者列表（点击作者查看
/// 其发布的歌曲）。ID 类文本用 SelectableText 方便直接长按复制。
class _SongInfoSheet extends StatelessWidget {
  const _SongInfoSheet({
    required this.item,
    required this.platform,
    this.onOpenArtist,
  });

  final QueueItem item;

  /// 所属平台（插件名）；本地歌曲为「本地音乐」。
  final String platform;

  /// 点击作者查看作品；null（本地歌曲/插件缺失）时作者行不可点。
  final void Function(_SongArtistInfo artist)? onOpenArtist;

  Widget _infoRow(BuildContext context, {required String label, String? value}) {
    if (value == null || value.trim().isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 46,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final data = item.pluginData;
    final artists = _songArtistsOf(item);
    final rawTitle = _firstTextOf(data ?? const {}, const [
      'title',
      'name',
      'songname',
      'songName',
    ]);
    final songName = rawTitle.isNotEmpty ? rawTitle : item.title;
    final songId = _firstTextOf(data ?? const {}, const [
      'id',
      'songId',
      'songid',
      'musicId',
    ]);
    final songMid = _firstTextOf(data ?? const {}, const [
      'mid',
      'songmid',
      'songMid',
    ]);
    final rawAlbum = _firstTextOf(data ?? const {}, const [
      'album',
      'albumname',
      'albumName',
      'album_name',
    ]);
    final albumName = rawAlbum.isNotEmpty ? rawAlbum : item.album;
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
              Icon(Icons.info_outline_rounded, color: scheme.primary),
              const SizedBox(width: 12),
              const Text('歌曲信息', style: TextStyle(fontSize: 16)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  platform,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 歌曲卡：名称 / ID / MID / 专辑。
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: .5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                _infoRow(context, label: '名称', value: songName),
                _infoRow(context, label: 'ID', value: songId),
                _infoRow(context, label: 'MID', value: songMid),
                _infoRow(context, label: '专辑', value: albumName),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // 作者卡：每位作者一行，点击查看其发布的歌曲。
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: .5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final artist in artists)
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: onOpenArtist == null
                        ? null
                        : () => onOpenArtist!(artist),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        children: [
                          // 有平台头像时加载真实头像，否则回退到人形占位图标。
                          artist.avatar.isEmpty
                              ? Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: scheme.primary.withValues(alpha: .14),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.person_rounded,
                                    size: 20,
                                    color: scheme.primary,
                                  ),
                                )
                              : CoverImage(
                                  songPath: '',
                                  imageUrl: artist.avatar,
                                  width: 38,
                                  height: 38,
                                  radius: 19,
                                  icon: Icons.person_rounded,
                                  gradient: [
                                    scheme.primary.withValues(alpha: .7),
                                    scheme.primary,
                                  ],
                                ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  artist.name.isEmpty ? '未知作者' : artist.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: scheme.onSurface,
                                  ),
                                ),
                                if (artist.artistId.isNotEmpty)
                                  Text(
                                    'artistId：${artist.artistId}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                if (artist.artistMid.isNotEmpty)
                                  Text(
                                    'artistMid：${artist.artistMid}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (onOpenArtist != null) ...[
                            Text(
                              '作品',
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.primary,
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 18,
                              color: scheme.primary,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                if (artists.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '未知作者',
                      style: TextStyle(color: scheme.onSurfaceVariant),
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

/// 歌词偏移子面板：当前值 + 滑杆 + 细调按钮 + 重置，实时生效并保存。
class _LyricsOffsetSheet extends StatefulWidget {
  const _LyricsOffsetSheet({
    required this.initialTenths,
    required this.onApply,
  });

  final int initialTenths;

  /// 每次变动的实时应用回调（由宿主页面静默保存）。
  final ValueChanged<int> onApply;

  @override
  State<_LyricsOffsetSheet> createState() => _LyricsOffsetSheetState();
}

class _LyricsOffsetSheetState extends State<_LyricsOffsetSheet> {
  late int _offsetTenths = clampLyricsOffsetTenths(widget.initialTenths);

  void _changeOffset(int delta) {
    final next = clampLyricsOffsetTenths(_offsetTenths + delta);
    if (next == _offsetTenths) return;
    setState(() => _offsetTenths = next);
    widget.onApply(next);
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
              Icon(Icons.sync_alt_rounded, color: scheme.primary),
              const SizedBox(width: 12),
              const Text('歌词偏移', style: TextStyle(fontSize: 16)),
              const Spacer(),
              TextButton(
                onPressed: _offsetTenths == 0
                    ? null
                    : () => _changeOffset(-_offsetTenths),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: const Text('重置', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: .5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              lyricsOffsetLabel(_offsetTenths),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
          ),
          Slider(
            value: _offsetTenths.toDouble(),
            min: -100,
            max: 100,
            divisions: 200,
            label: lyricsOffsetLabel(_offsetTenths),
            onChanged: (next) {
              final tenths = next.round();
              if (tenths == _offsetTenths) return;
              setState(() => _offsetTenths = tenths);
              widget.onApply(tenths);
            },
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('延后 10 秒', style: TextStyle(fontSize: 10)),
                Text('同步', style: TextStyle(fontSize: 10)),
                Text('提前 10 秒', style: TextStyle(fontSize: 10)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final (label, delta) in [
                ('-1秒', -10),
                ('-0.5秒', -5),
                ('-0.1秒', -1),
                ('+0.1秒', 1),
                ('+0.5秒', 5),
                ('+1秒', 10),
              ])
                ActionChip(
                  label: Text(label, style: const TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _changeOffset(delta),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '偏移实时保存，仅对当前歌曲生效并记忆。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10, color: scheme.outline),
          ),
        ],
      ),
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

  /// 关联歌词候选排序打分：标题 > 时长（秒级完全一致）> 作者。
  /// 标题归一化完全相等 3 分、互相包含 2 分；时长与当前歌曲秒级完全
  /// 一致 2 分；作者互相包含 1 分。
  int _lyricsOptionScore(PluginLyricsOption option) {
    var score = 0;
    final targetTitle = _normalizeLyricsMatchText(widget.item.title);
    final title = _normalizeLyricsMatchText(option.songTitle);
    if (title.isNotEmpty && targetTitle.isNotEmpty) {
      if (title == targetTitle) {
        score += 3;
      } else if (title.contains(targetTitle) || targetTitle.contains(title)) {
        score += 2;
      }
    }
    final targetSeconds = widget.item.durationMs ~/ 1000;
    final seconds = option.durationMs ~/ 1000;
    if (targetSeconds > 0 && seconds == targetSeconds) score += 2;
    final targetArtist = _normalizeLyricsMatchText(widget.item.artist);
    final artist = _normalizeLyricsMatchText(option.songArtist);
    if (artist.isNotEmpty &&
        targetArtist.isNotEmpty &&
        (artist.contains(targetArtist) || targetArtist.contains(artist))) {
      score += 1;
    }
    return score;
  }

  String _normalizeLyricsMatchText(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

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
            // 匹配优先：标题 > 时长（秒级完全一致）> 作者；同分按
            // 插件名稳定排序（保持各插件结果相对顺序）。
            final score = _lyricsOptionScore(
              b,
            ).compareTo(_lyricsOptionScore(a));
            if (score != 0) return score;
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

class _PlayerDetailBackground extends ConsumerWidget {
  const _PlayerDetailBackground({required this.current});

  final QueueItem? current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final mode =
        settings?.playerDetailBackgroundMode ??
        PlayerDetailBackgroundMode.flowingLight;
    final wallpaperPath = settings?.customBackgroundPath.trim() ?? '';
    final detailImagePath = settings?.playerDetailCustomImagePath.trim() ?? '';
    final wallpaperBlur = settings?.customBackgroundBlur ?? 18.0;

    final backdrop = switch (mode) {
      // 封面模糊背景已移除：统一回退为流光背景。
      PlayerDetailBackgroundMode.coverBlur => _flowingLightBackdrop(current),
      PlayerDetailBackgroundMode.wallpaperBlur =>
        wallpaperPath.isEmpty
            ? _flowingLightBackdrop(current)
            : _wallpaperBackdrop(wallpaperPath, wallpaperBlur, blurred: true),
      PlayerDetailBackgroundMode.flowingLight => _flowingLightBackdrop(current),
      PlayerDetailBackgroundMode.customImage =>
        detailImagePath.isEmpty
            ? _flowingLightBackdrop(current)
            : _wallpaperBackdrop(
                detailImagePath,
                wallpaperBlur,
                blurred: false,
              ),
      // 粒子动效已移除：持久化旧值归一化为流光背景。
      PlayerDetailBackgroundMode.particle => _flowingLightBackdrop(current),
    };

    // 流光模式：底色是不透明封面模糊，亮色封面本身就很亮，再叠加
    // plus 混合的彩色 blob 后极易整屏过曝。保留深色压暗遮罩 + 底部
    // 深色渐变对齐参考应用的暗色氛围，但较 beta10 略微调亮（.30 → .24）。其余
    // 背景模式维持原有可读性遮罩。
    final flowing =
        mode == PlayerDetailBackgroundMode.flowingLight ||
        mode == PlayerDetailBackgroundMode.coverBlur ||
        mode == PlayerDetailBackgroundMode.particle ||
        (mode == PlayerDetailBackgroundMode.wallpaperBlur &&
            wallpaperPath.isEmpty) ||
        (mode == PlayerDetailBackgroundMode.customImage &&
            detailImagePath.isEmpty);

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: backdrop),
          // 流光模式：深色压暗，blob 的 plus 叠加负责提供流动色彩。
          if (flowing)
            ColoredBox(color: Colors.black.withValues(alpha: .24))
          else
            ColoredBox(color: Color(0xFF080A0F).withValues(alpha: .58)),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: flowing
                    ? [Color(0x10000000), Color(0x26000000), Color(0x55000000)]
                    : [Color(0x29000000), Color(0x12000000), Color(0xA6000000)],
                stops: [0, .48, 1],
              ),
            ),
          ),
        ],
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

  Widget _flowingLightBackdrop(QueueItem? item) =>
      _FlowingLightBackground(item: item);
}

/// 流光背景取色未就绪或无封面时的回退色板。
const _kFlowingFallbackColors = <Color>[
  Color(0xFF4C6FFF),
  Color(0xFF48C6EF),
  Color(0xFFEC4141),
];

/// 解析 `hsl(220, 28%, 34%)` 格式的调色板字符串。
Color? _parseHslColor(dynamic value) {
  if (value is! String) return null;
  final match = RegExp(
    r'hsl\(\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)%\s*,\s*(\d+(?:\.\d+)?)%\s*\)',
  ).firstMatch(value);
  if (match == null) return null;
  final hue = double.tryParse(match.group(1)!) ?? 0;
  final saturation = (double.tryParse(match.group(2)!) ?? 0) / 100;
  final lightness = (double.tryParse(match.group(3)!) ?? 0) / 100;
  return HSLColor.fromAHSL(1, hue, saturation, lightness).toColor();
}

class _FlowingLightBackground extends ConsumerStatefulWidget {
  const _FlowingLightBackground({required this.item});

  final QueueItem? item;

  @override
  ConsumerState<_FlowingLightBackground> createState() =>
      _FlowingLightBackgroundState();
}

class _FlowingLightBackgroundState
    extends ConsumerState<_FlowingLightBackground>
    with TickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  );

  /// 封面切换时在旧色板与新色板之间平滑过渡。
  late final AnimationController _colorController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  List<Color> _from = _kFlowingFallbackColors;
  List<Color> _to = _kFlowingFallbackColors;
  int _paletteRequest = 0;

  /// 已解析色板缓存（按取色源），避免同一封面反复解码。
  static final Map<String, List<Color>> _paletteCache = {};

  @override
  void initState() {
    super.initState();
    _resolvePalette();
    // 流光仅随播放运行：暂停时冻结动画，页面静止不再每帧重绘，
    // 降低 GPU 占用与耗电（卡顿优化）。
    if (ref.read(playerProvider.select((s) => s.isPlaying))) {
      _controller.repeat();
    }
    ref.listenManual(playerProvider.select((s) => s.isPlaying), (_, playing) {
      if (playing) {
        if (!_controller.isAnimating) _controller.repeat();
      } else if (_controller.isAnimating) {
        _controller.stop();
      }
    });
  }

  @override
  void didUpdateWidget(covariant _FlowingLightBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item?.path != widget.item?.path ||
        oldWidget.item?.coverUrl != widget.item?.coverUrl) {
      _resolvePalette();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _colorController.dispose();
    super.dispose();
  }

  /// 解析取色源：优先网络封面（网易云 CDN 需经代理转 data URI），
  /// 本地歌曲读取缩略图缓存文件路径；两者皆无时返回 null 走回退色板。
  Future<String?> _coverPaletteSource(QueueItem? item) async {
    if (item == null) return null;
    final coverUrl = normalizeCoverImageUrl(item.coverUrl);
    if (coverUrl.isNotEmpty) {
      if (needsCoverImageProxy(coverUrl)) {
        try {
          final dataUrl = await proxyImage(
            url: coverUrl,
            referer: 'https://music.163.com/',
          );
          if (dataUrl.contains(',')) return dataUrl;
        } catch (_) {
          // 代理失败时退回直连地址。
        }
      }
      return coverUrl;
    }
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final cacheRoot = await ref.read(appDataDirProvider.future);
      final path = await getSongCoverThumbnail(
        dbPath: dbPath,
        cacheRoot: cacheRoot,
        path: item.path,
      );
      return path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }

  Future<void> _resolvePalette() async {
    final request = ++_paletteRequest;
    final item = widget.item;
    final source = await _coverPaletteSource(item);
    if (!mounted || request != _paletteRequest) return;
    if (source == null) {
      _applyPalette(_kFlowingFallbackColors);
      return;
    }
    final cached = _paletteCache[source];
    if (cached != null) {
      _applyPalette(cached);
      return;
    }
    try {
      // colorBoost 适中即可：过高会让色板过亮，叠加 plus 混合的
      // blob 后整屏过曝（beta8 曝光事故）。
      final raw = await extractPalette(
        source: source,
        count: BigInt.from(4),
        colorBoost: 46,
        depth: 30,
      );
      if (!mounted || request != _paletteRequest) return;
      final decoded = jsonDecode(raw);
      final colors = decoded is List
          ? decoded.map(_parseHslColor).whereType<Color>().toList()
          : const <Color>[];
      final palette = colors.length >= 3 ? colors : _kFlowingFallbackColors;
      if (_paletteCache.length >= 24) {
        _paletteCache.remove(_paletteCache.keys.first);
      }
      _paletteCache[source] = palette;
      _applyPalette(palette);
    } catch (_) {
      if (mounted && request == _paletteRequest) {
        _applyPalette(_kFlowingFallbackColors);
      }
    }
  }

  void _applyPalette(List<Color> palette) {
    if (!mounted) return;
    setState(() {
      _from = _currentColors();
      _to = palette;
    });
    _colorController.forward(from: 0);
  }

  List<Color> _currentColors() {
    final t = Curves.easeOutCubic.transform(_colorController.value);
    if (t >= 1 || _to.length != _from.length) {
      return _to.length >= 3 ? _to : _kFlowingFallbackColors;
    }
    return List.generate(_to.length, (index) {
      return Color.lerp(_from[index], _to[index], t) ?? _to[index];
    }, growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    // 封面模糊打底：放大 + 重度模糊，不透明地铺满，色调纯来自
    // 封面本身；提亮/压暗交给外层遮罩控制，避免底色串白过曝。
    // 该子树与动画无关，放在 AnimatedBuilder 外只构建一次，
    // 避免每帧重建比对整棵模糊子树（低端机上可感知的无效开销）。
    Widget blurCover;
    if (item == null) {
      blurCover = const ColoredBox(color: Colors.white);
    } else {
      blurCover = Transform.scale(
        scale: 1.24,
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 32, sigmaY: 32),
          child: CoverImage(
            key: ValueKey('flowing:${item.path}:${item.coverUrl}'),
            songPath: item.path,
            imageUrl: item.coverUrl,
            width: double.infinity,
            height: double.infinity,
            radius: 0,
            cacheWidth: 256,
            icon: Icons.music_note_rounded,
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: blurCover),
        // RepaintBoundary 隔离流光层：blob 每帧重绘只局限在本层，
        // 不会把重绘传播到模糊封面层或外层页面。
        Positioned.fill(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: Listenable.merge([_controller, _colorController]),
              builder: (_, _) {
                // 彩色发光 blob（透明底色 + Plus 混合叠加）。
                return CustomPaint(
                  painter: _FlowingLightPainter(
                    _controller.value,
                    _currentColors(),
                  ),
                  child: const SizedBox.expand(),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _FlowingLightPainter extends CustomPainter {
  const _FlowingLightPainter(this.progress, this.colors);

  final double progress;
  final List<Color> colors;

  Color _blobColor(int index, double alpha) {
    final palette = colors.length >= 3 ? colors : _kFlowingFallbackColors;
    return palette[index % palette.length].withValues(alpha: alpha);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 不再画深色底——底色由外层封面模糊层提供；blob 以极低 alpha 的
    // plus 叠加提供流动色彩即可，alpha 过高会在亮色底上整屏过曝。
    final phase = progress * math.pi * 2;
    final points = [
      (
        Offset(size.width * (.18 + .18 * math.sin(phase)), size.height * .12),
        _blobColor(0, .13),
      ),
      (
        Offset(size.width * (.82 + .16 * math.cos(phase)), size.height * .62),
        _blobColor(1, .10),
      ),
      (
        Offset(
          size.width * (.45 + .2 * math.sin(phase + 1)),
          size.height * .95,
        ),
        _blobColor(2, .07),
      ),
      if (colors.length > 3)
        (
          Offset(
            size.width * (.32 + .22 * math.cos(phase + 2)),
            size.height * (.38 + .18 * math.sin(phase + 3)),
          ),
          _blobColor(3, .05),
        ),
    ];
    // plus 混合让重叠区域亮度叠加，形成流光的通透感。
    for (final (center, color) in points) {
      final radius = math.max(size.width, size.height) * .68;
      final paint = Paint()
        ..shader = ui.Gradient.radial(center, radius, [
          color,
          color.withValues(alpha: 0),
        ])
        ..blendMode = BlendMode.plus;
      canvas.drawRect(Offset.zero & size, paint);
    }
  }

  @override
  bool shouldRepaint(_FlowingLightPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      !listEquals(oldDelegate.colors, colors);
}

class _BilibiliVideoView extends StatefulWidget {
  const _BilibiliVideoView({
    required this.controller,
    required this.loading,
    required this.error,
    this.landscape = false,
    this.onToggleOrientation,
    this.onClose,
    this.title = '',
    this.subtitle = '',
    this.onPickSpeed,
    this.onPickQuality,
    this.onToggleMute,
    this.onDownload,
    this.onReload,
    this.onSelectQuality,
    this.qualityChoices = const [],
    this.currentQuality = '',
  });

  final VideoPlayerController? controller;
  final bool loading;
  final String? error;
  final bool landscape;
  final VoidCallback? onToggleOrientation;
  final VoidCallback? onClose;
  final String title;
  final String subtitle;
  final VoidCallback? onPickSpeed;
  final VoidCallback? onPickQuality;
  final VoidCallback? onToggleMute;
  final VoidCallback? onDownload;
  final VoidCallback? onReload;
  final void Function(String quality)? onSelectQuality;

  /// 错误面板展示的可选画质档位（插件回传或内置档位）。
  final List<String> qualityChoices;

  /// 当前画质档位，错误面板的档位胶囊以此为选中态。
  final String currentQuality;

  @override
  State<_BilibiliVideoView> createState() => _BilibiliVideoViewState();
}

/// MV/视频全屏覆盖播放层（排版参考 QQ 音乐 MV 播放页）：
/// - 整屏纯黑背景，视频画面按原始比例居中
/// - 点击画面切换控制层显隐（播放中 3 秒无操作自动隐藏）
/// - 控制层：顶部标题/副标题（歌手 · 画质），右上角常驻关闭按钮；
///   底部一行式控制栏：进度条 + 播放/音量/时间/倍速/画质/横竖屏切换
class _BilibiliVideoViewState extends State<_BilibiliVideoView> {
  bool _showControls = true;
  bool _dragging = false;
  double _dragValue = 0;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_onVideoChanged);
  }

  /// 播放/暂停等状态变化时刷新中央播放按钮的显隐。
  void _onVideoChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _BilibiliVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onVideoChanged);
      widget.controller?.addListener(_onVideoChanged);
    }
    // 换视频或切换横竖屏时重新展示控制栏并重新计时。
    if (oldWidget.controller != widget.controller ||
        oldWidget.landscape != widget.landscape) {
      _hideTimer?.cancel();
      _showControls = true;
      _scheduleHide();
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onVideoChanged);
    _hideTimer?.cancel();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (widget.controller?.value.isPlaying == true && !_dragging) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
      if (_showControls) {
        _scheduleHide();
      } else {
        _hideTimer?.cancel();
      }
    });
  }

  Future<void> _togglePlay(VideoPlayerController player) async {
    if (player.value.isPlaying) {
      await player.pause();
    } else {
      await player.play();
    }
    if (mounted) setState(() {});
  }

  String _fmtDuration(Duration duration) {
    final seconds = duration.inSeconds.clamp(0, 359999);
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.controller;
    final initialized = player?.value.isInitialized == true;
    return ColoredBox(
      // 全屏覆盖层：除视频画面外全部黑底（参考 MusicFree 短视频效果）。
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 视频画面按原始比例居中，四周留黑。
          if (initialized)
            Center(
              child: AspectRatio(
                aspectRatio: player!.value.aspectRatio > 0
                    ? player.value.aspectRatio
                    : 16 / 9,
                child: VideoPlayer(player),
              ),
            ),
          // 单击切换控制层显隐；双击播放/暂停（QQ 音乐 MV 播放页手势）。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              onDoubleTap: initialized ? () => _togglePlay(player!) : null,
            ),
          ),
          // 暂停时中央展示描边圆环 + 实心三角的大播放按钮。
          if (initialized && !player!.value.isPlaying)
            Center(
              child: GestureDetector(
                onTap: () => _togglePlay(player),
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: .35),
                    border: Border.all(color: Colors.white, width: 2.5),
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 44,
                  ),
                ),
              ),
            ),
          // 播放失败/后台久置挂起：中央错误面板（参考 BakaMusic），提供
          // 重新加载与画质切换。置于关闭按钮之前：面板铺满时右上角的
          // 常驻关闭按钮仍绘制在其上，可直接点按退回音频播放页。
          if (widget.error?.trim().isNotEmpty == true)
            Positioned.fill(
              child: _VideoErrorPanel(
                error: widget.error!,
                choices: widget.qualityChoices,
                currentQuality: widget.currentQuality,
                onReload: widget.onReload,
                onSelectQuality: widget.onSelectQuality,
              ),
            ),
          // 右上角常驻关闭按钮：控制层隐藏时也能退出视频。
          if (widget.onClose != null)
            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                child: IconButton(
                  tooltip: '关闭视频',
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  onPressed: widget.onClose,
                ),
              ),
            ),
          // 顶部标题栏（随控制层显隐）：歌名 + 「歌手 · 画质」。
          // 右侧留出常驻关闭按钮的宽度，标题不会被遮挡。
          if (_showControls &&
              (widget.title.isNotEmpty || widget.subtitle.isNotEmpty))
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: .6),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 56, 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.title.isNotEmpty)
                            Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                height: 1.2,
                              ),
                            ),
                          if (widget.subtitle.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              widget.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // 底部控制栏（QQ 音乐式）：进度条 + 播放/音量/时间/倍速/画质/全屏。
          if (_showControls && initialized)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(top: false, child: _buildControlBar(player!)),
            ),
          if (widget.loading)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
        ],
      ),
    );
  }

  /// 底部控制栏（QQ 音乐式两行布局）：
  /// 第一行全宽进度条；第二行播放/音量 +「当前 / 总时长」+ 倍速/画质/全屏。
  Widget _buildControlBar(VideoPlayerController player) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: player,
      builder: (context, value, _) {
        final durationMs = value.duration.inMilliseconds;
        final positionMs = value.position.inMilliseconds;
        final max = durationMs <= 0 ? 0.0 : durationMs.toDouble();
        final current = _dragging
            ? _dragValue * durationMs
            : positionMs.clamp(0, durationMs <= 0 ? 0 : durationMs).toDouble();
        final muted = value.volume == 0;
        final speedText = _speedLabel(value.playbackSpeed);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.black.withValues(alpha: .55)],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 28, 12, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 第一行：全宽进度条。
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2.5,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                    trackShape: const _VideoProgressTrackShape(),
                  ),
                  child: Slider(
                    value: max <= 0 ? 0 : (current / max).clamp(0.0, 1.0),
                    onChanged: durationMs <= 0
                        ? null
                        : (ratio) {
                            setState(() {
                              _dragging = true;
                              _dragValue = ratio;
                            });
                            _hideTimer?.cancel();
                          },
                    onChangeEnd: durationMs <= 0
                        ? null
                        : (ratio) {
                            _dragging = false;
                            final target = Duration(
                              milliseconds: (ratio * durationMs).round(),
                            );
                            unawaited(player.seekTo(target));
                            _scheduleHide();
                          },
                  ),
                ),
                const SizedBox(height: 2),
                // 第二行：功能按钮（统一 40x40 触摸区 + 22 图标基准对齐）。
                Row(
                  children: [
                    IconButton(
                      tooltip: value.isPlaying ? '暂停' : '播放',
                      iconSize: 26,
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      icon: Icon(
                        value.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                      ),
                      onPressed: () => _togglePlay(player),
                    ),
                    if (widget.onToggleMute != null)
                      IconButton(
                        tooltip: muted ? '取消静音' : '静音',
                        iconSize: 22,
                        padding: const EdgeInsets.all(8),
                        constraints: const BoxConstraints.tightFor(
                          width: 40,
                          height: 40,
                        ),
                        icon: Icon(
                          muted
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          color: Colors.white,
                        ),
                        onPressed: widget.onToggleMute,
                      ),
                    const SizedBox(width: 4),
                    Text(
                      '${_fmtDuration(Duration(milliseconds: current.round()))}'
                      ' / ${_fmtDuration(value.duration)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontFeatures: [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                    const Spacer(),
                    if (widget.onPickSpeed != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: GestureDetector(
                          onTap: widget.onPickSpeed,
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 8,
                              horizontal: 6,
                            ),
                            child: Text(
                              speedText,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontFeatures: [ui.FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (widget.onDownload != null)
                      IconButton(
                        tooltip: '下载视频',
                        iconSize: 22,
                        padding: const EdgeInsets.all(8),
                        constraints: const BoxConstraints.tightFor(
                          width: 40,
                          height: 40,
                        ),
                        icon: const Icon(
                          Icons.file_download_outlined,
                          color: Colors.white,
                        ),
                        onPressed: widget.onDownload,
                      ),
                    if (widget.onPickQuality != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: GestureDetector(
                          onTap: widget.onPickQuality,
                          behavior: HitTestBehavior.opaque,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              vertical: 8,
                              horizontal: 6,
                            ),
                            child: Text(
                              '画质',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (widget.onToggleOrientation != null)
                      IconButton(
                        tooltip: widget.landscape ? '切换竖屏' : '全屏',
                        iconSize: 22,
                        padding: const EdgeInsets.all(8),
                        constraints: const BoxConstraints.tightFor(
                          width: 40,
                          height: 40,
                        ),
                        icon: Icon(
                          widget.landscape
                              ? Icons.fullscreen_exit_rounded
                              : Icons.fullscreen_rounded,
                          color: Colors.white,
                        ),
                        onPressed: widget.onToggleOrientation,
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 倍速显示文案：1.0 → 「1x」、1.25 → 「1.25x」。
  static String _speedLabel(double speed) {
    final v = speed == 0 ? 1.0 : speed;
    final text = v == v.truncateToDouble()
        ? v.truncate().toString()
        : v.toStringAsFixed(2);
    return '$text${'x'}';
  }
}

/// 视频进度条轨道：细圆角轨道，已播段白色、未播段半透明白。
class _VideoProgressTrackShape extends RoundedRectSliderTrackShape {
  const _VideoProgressTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final height = sliderTheme.trackHeight ?? 2.5;
    final radius = Radius.circular(height / 2);
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
    );
    final canvas = context.canvas;
    // 未播放段
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, radius),
      Paint()..color = Colors.white.withValues(alpha: .3),
    );
    // 已播放段
    final played = Rect.fromLTRB(
      trackRect.left,
      trackRect.top,
      thumbCenter.dx,
      trackRect.bottom,
    );
    if (played.width > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(played, radius),
        Paint()..color = Colors.white,
      );
    }
  }
}

class _BigCover extends ConsumerWidget {
  const _BigCover({
    super.key,
    this.item,
    required this.offsetTenths,
    this.style = PlayerCoverStyle.classic,
    this.onTap,
    this.onLongPress,
    this.landscape = false,
    this.miniLyricRows = 2,
    this.miniLyricReserveRows = 2,
  });
  final QueueItem? item;
  final int offsetTenths;
  final PlayerCoverStyle style;
  final VoidCallback? onTap;

  /// 长按封面弹出播放页“更多”菜单（分享/收藏到歌单/关联歌词等）。
  final VoidCallback? onLongPress;

  /// 横屏平分式布局：封面在左半屏正中缩放，不排迷你歌词与桌面反光。
  final bool landscape;

  /// 迷你歌词当前展示行数（沉浸模式播放栏隐藏 4 行、弹出 2 行）。
  final int miniLyricRows;

  /// 迷你歌词展示区预留行数：沉浸模式恒按 4 行预留，播放栏弹出
  /// 收为 2 行时封面不随之抖动。
  final int miniLyricReserveRows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 圆形旋转 / 黑胶需要感知播放状态：播放时旋转、暂停时停在当前角度。
    final playing = ref.watch(playerProvider.select((s) => s.isPlaying));
    // 黑胶唱针开关（设置 → 播放）。
    final showTonearm = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.vinylTonearm ?? true),
    );
    // 竖屏沉浸态（控制卡隐藏、翻页区铺满内容区）：封面组居中会明显
    // 偏下，整体上移一些让视觉重心回到中上部；非沉浸态保持居中。
    final portraitImmersiveActive =
        !landscape &&
        item != null &&
        (ref.watch(
              settingsProvider.select(
                (s) => s.valueOrNull?.portraitImmersiveLyrics,
              ),
            ) ??
            true);
    // 封面下缘迷你歌词展示区高度（按预留行数取），及其占用的总高度
    //（43dp 间距 + 展示区）。
    final lyricArea = _MiniLyrics.heightFor(miniLyricReserveRows);
    final extrasHeight = 43 + lyricArea;
    return LayoutBuilder(
      builder: (context, constraints) {
        final double side;
        final bool showCoverExtras;
        if (landscape) {
          side = math.max(
            1.0,
            math.min(
              420.0,
              math.min(constraints.maxWidth * .8, constraints.maxHeight * .8),
            ),
          );
          showCoverExtras = false;
        } else {
          final normalSide = math.min(
            420.0,
            math.min(
              constraints.maxWidth * .8,
              constraints.maxHeight - extrasHeight,
            ),
          );
          showCoverExtras = normalSide >= 150;
          side = showCoverExtras
              ? normalSide
              : math.max(
                  1.0,
                  math.min(
                    420.0,
                    math.min(constraints.maxWidth * .8, constraints.maxHeight),
                  ),
                );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            Align(
              alignment: Alignment(0, portraitImmersiveActive ? -.4 : 0),
              child: SizedBox(
                width: side,
                height: side + (showCoverExtras ? extrasHeight : 0),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // 方形封面下缘的“桌面反光”，仅经典样式使用。
                    if (showCoverExtras && style == PlayerCoverStyle.classic)
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
                      child: switch (style) {
                        // 圆形旋转封面（参考 MusicFree）：25 秒一圈，
                        // 播放时匀速旋转、暂停时停住，切歌（key 变化）归零。
                        PlayerCoverStyle.circle => _buildCircle(playing, side),
                        // 黑胶唱片（参考 BakaMusic）：盘面 24 秒一圈。
                        PlayerCoverStyle.vinyl => _VinylCover(
                          item: item,
                          playing: playing,
                          size: side,
                          showTonearm: showTonearm,
                          onTap: onTap,
                          onLongPress: onLongPress,
                        ),
                        _ => _buildClassic(side),
                      },
                    ),
                    if (item != null && showCoverExtras)
                      Positioned(
                        top: side + 43,
                        // 与封面同宽（不再向两侧溢出 28dp），歌词不贴屏边。
                        left: 0,
                        right: 0,
                        height: lyricArea,
                        child: AbsorbPointer(
                          child: _MiniLyrics(
                            item: item!,
                            offsetTenths: offsetTenths,
                            maxRows: miniLyricRows,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // 横屏：收藏按钮悬停在封面右上方（唯一的横屏收藏入口），
            // 放在外层全屏 Stack 里定位，不叠在封面图上、也可正常命中点击。
            // 黑胶样式的唱针配重块会伸出盘面上方约 5.4% 边长，按钮需整体
            // 让出唱针区域；矮横屏上方空间不足时退到封面左上侧留白处，
            // 保证任何封面样式（方形/圆形/黑胶）都不与封面或唱针重叠。
            if (item != null && landscape)
              () {
                final coverTop = (constraints.maxHeight - side) / 2;
                final coverLeft = (constraints.maxWidth - side) / 2;
                // 唱针伸出盘面上方的高度（非黑胶样式只需常规间隙）。
                final armClear = style == PlayerCoverStyle.vinyl && showTonearm
                    ? side * .056 + 6
                    : 10.0;
                final aboveTop = coverTop - armClear - 38;
                if (aboveTop >= 8) {
                  return Positioned(
                    top: aboveTop,
                    left: coverLeft + side - 38,
                    child: _LandscapeCoverFavorite(item: item!),
                  );
                }
                return Positioned(
                  top: math.max(8, coverTop - 38),
                  left: math.max(2, coverLeft - 44),
                  child: _LandscapeCoverFavorite(item: item!),
                );
              }(),
          ],
        );
      },
    );
  }

  Widget _buildClassic(double side) {
    return Semantics(
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
            onLongPress: onLongPress,
            child: _cover(side, radius: 24),
          ),
        ),
      ),
    );
  }

  Widget _buildCircle(bool playing, double side) {
    return Semantics(
      button: onTap != null,
      label: onTap == null ? null : '显示歌词',
      child: Container(
        width: side,
        height: side,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Color(0x99000000),
              blurRadius: 44,
              spreadRadius: -8,
              offset: Offset(0, 24),
            ),
          ],
        ),
        child: _SpinningCover(
          playing: playing,
          period: const Duration(seconds: 25),
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              child: _cover(side, radius: side / 2),
            ),
          ),
        ),
      ),
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

/// 横屏封面右上角的收藏按钮：深色半透明圆底保证在亮色封面上也可见。
class _LandscapeCoverFavorite extends ConsumerWidget {
  const _LandscapeCoverFavorite({required this.item});

  final QueueItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFav = ref.watch(favoritesProvider).contains(item.path);
    return IconButton(
      tooltip: isFav ? '取消收藏' : '收藏',
      icon: Icon(
        isFav ? Icons.favorite : Icons.favorite_border,
        // 收藏状态使用固定红色，不随用户自定义主题色变化。
        color: isFav ? const Color(0xFFEC4141) : Colors.white,
        size: 20,
      ),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: .32),
        foregroundColor: Colors.white,
        minimumSize: const Size(38, 38),
        padding: EdgeInsets.zero,
      ),
      onPressed: () => ref
          .read(favoritesProvider.notifier)
          .toggle(item.path, song: FavoriteSongSnapshot.fromQueueItem(item)),
    );
  }
}

/// 匀速旋转容器：播放时转、暂停时停在当前角度；换歌时由父级的
/// ValueKey 触发重建，角度自然归零。手势命中区域不受旋转影响。
class _SpinningCover extends StatefulWidget {
  const _SpinningCover({
    required this.child,
    required this.playing,
    this.period = const Duration(seconds: 25),
  });

  final Widget child;
  final bool playing;
  final Duration period;

  @override
  State<_SpinningCover> createState() => _SpinningCoverState();
}

class _SpinningCoverState extends State<_SpinningCover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.period,
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _controller.repeat();
  }

  @override
  void didUpdateWidget(_SpinningCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing == oldWidget.playing) return;
    if (widget.playing) {
      _controller.repeat();
    } else {
      // stop() 保留当前角度，恢复播放时从停住的位置继续转。
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Transform.rotate(
        angle: _controller.value * 2 * math.pi,
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// 沉浸式封面页（参考 MusicFree）：屏宽方形清晰封面铺在内容区顶部，
/// 底部渐隐融入模糊背景，下方保留迷你歌词。点击封面切换歌词页。
class _ImmersiveCoverPage extends StatelessWidget {
  const _ImmersiveCoverPage({
    super.key,
    this.item,
    required this.offsetTenths,
    this.onTap,
    this.onLongPress,
    this.paintCover = true,
    this.miniLyricRows = 2,
    this.miniLyricReserveRows = 2,
  });

  final QueueItem? item;
  final int offsetTenths;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// false 时封面区域退化为透明占位（保留手势与尺寸，迷你歌词位置
  /// 不变）：封面本体由播放页外层 Stack 绘制，铺到屏幕顶端。
  final bool paintCover;

  /// 迷你歌词当前展示行数（沉浸模式播放栏隐藏 4 行、弹出 2 行）。
  final int miniLyricRows;

  /// 迷你歌词展示区预留行数：沉浸模式恒按 4 行预留，播放栏弹出
  /// 收为 2 行时封面不随之抖动。
  final int miniLyricReserveRows;

  @override
  Widget build(BuildContext context) {
    final current = item;
    final lyricArea = _MiniLyrics.heightFor(miniLyricReserveRows);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 封面尽量铺满内容区宽度（MusicFree 的沉浸式封面高=屏宽），
        // 但要给迷你歌词留出空间（展示区 + 12dp 余量）；空间不足
        // 时按高度收缩。
        final side = math.min(
          constraints.maxWidth,
          math.max(80.0, constraints.maxHeight - (lyricArea + 12)),
        );
        return Column(
          children: [
            // 顶部 62% 清晰可见，之下渐隐（MusicFree
            // IMMERSIVE_CLEAR_VISIBLE_RATIO = 0.62）。
            Semantics(
              button: onTap != null,
              label: onTap == null ? null : '显示歌词',
              child: SizedBox(
                width: side,
                height: side,
                child: paintCover
                    ? ShaderMask(
                        blendMode: BlendMode.dstIn,
                        shaderCallback: (bounds) => const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white,
                            Colors.white,
                            Colors.transparent,
                          ],
                          stops: [0, .62, 1],
                        ).createShader(bounds),
                        child: Material(
                          color: Colors.transparent,
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: onTap,
                            onLongPress: onLongPress,
                            child: current == null
                                ? const ColoredBox(
                                    color: Color(0xFF272A31),
                                    child: Center(
                                      child: Icon(
                                        Icons.music_note_rounded,
                                        color: Colors.white54,
                                      ),
                                    ),
                                  )
                                : CoverImage(
                                    key: ValueKey(
                                      'immersive:${current.path}:${current.coverUrl ?? ''}',
                                    ),
                                    songPath: current.path,
                                    imageUrl: current.coverUrl,
                                    width: side,
                                    height: side,
                                    radius: 0,
                                    highQuality: true,
                                    icon: Icons.music_note_rounded,
                                  ),
                          ),
                        ),
                      )
                    : Material(
                        color: Colors.transparent,
                        child: InkWell(onTap: onTap, onLongPress: onLongPress),
                      ),
              ),
            ),
            if (current != null)
              SizedBox(
                height: lyricArea,
                // 左右各留 26dp：歌词不贴屏幕两侧，长句换行更从容。
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 26),
                  child: AbsorbPointer(
                    child: _MiniLyrics(
                      item: current,
                      offsetTenths: offsetTenths,
                      maxRows: miniLyricRows,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 沉浸式封面的全幅顶层：铺满屏宽、顶到屏幕顶端（覆盖状态栏下方
/// 的标题行背后），同样应用 62% 清晰 + 底部渐隐，顶部叠加轻微暗色
/// 渐变保证白色标题文字可读。
class _ImmersiveTopCover extends StatelessWidget {
  const _ImmersiveTopCover({required this.item, required this.side});

  final QueueItem item;
  final double side;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: side,
      height: side,
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, Colors.white, Colors.transparent],
          stops: [0, .62, 1],
        ).createShader(bounds),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CoverImage(
              key: ValueKey('immersiveTop:${item.path}:${item.coverUrl ?? ''}'),
              songPath: item.path,
              imageUrl: item.coverUrl,
              width: side,
              height: side,
              radius: 0,
              highQuality: true,
              icon: Icons.music_note_rounded,
            ),
            // 顶部可读性渐变（标题文字浮在封面上）。
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x59000000), Colors.transparent],
                  stops: [0, .28],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 黑胶唱片封面（参考 BakaMusic）：旋转唱片（盘面纹理 + 61.8% 标签，
/// 对齐网易手机版无中心孔）。
class _VinylCover extends StatelessWidget {
  const _VinylCover({
    this.item,
    required this.playing,
    required this.size,
    this.showTonearm = true,
    this.onTap,
    this.onLongPress,
  });

  final QueueItem? item;
  final bool playing;
  final double size;
  final bool showTonearm;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: onTap == null ? null : '显示歌词',
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // 唱片本体：播放时 24 秒匀速转一圈，暂停时停住。
            _SpinningCover(
              playing: playing,
              period: const Duration(seconds: 24),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Color(0xB2000000),
                      blurRadius: 44,
                      spreadRadius: -10,
                      offset: Offset(0, 22),
                    ),
                  ],
                ),
                child: CustomPaint(
                  size: Size.square(size),
                  painter: _VinylDiscPainter(),
                  child: Center(
                    child: _VinylLabel(item: item, size: size),
                  ),
                ),
              ),
            ),
            // 扇形高光固定在屏幕空间（光源不随唱片旋转），叠加在盘面之上。
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _VinylSheenPainter()),
              ),
            ),
            // 唱针（复刻 BakaMusic 经典款）：播放 -12 度搭在盘缘内侧，
            // 暂停 -20 度悬在盘缘外，720ms 回弹过渡；不拦截点击。
            if (showTonearm)
              Positioned.fill(
                child: IgnorePointer(child: VinylTonearm(playing: playing)),
              ),
            // 手势层盖在最上，避免旋转层干扰点击。
            Positioned.fill(
              child: InkWell(onTap: onTap, onLongPress: onLongPress),
            ),
          ],
        ),
      ),
    );
  }
}

/// 黑胶标签区：61.8% 直径的深色圆底 + 92% 封面（对齐网易手机版，
/// 无中心孔）。
class _VinylLabel extends StatelessWidget {
  const _VinylLabel({required this.item, required this.size});

  final QueueItem? item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final label = size * .618;
    final current = item;
    return SizedBox(
      width: label,
      height: label,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 标签圆底（移除深色环，消除封面外圈黑边）。
          DecoratedBox(
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF1A1A1E),
            ),
          ),
          // 封面（92%）叠一层轻微压暗/提饱和，模拟唱片印刷质感。
          SizedBox(
            width: label * .92,
            height: label * .92,
            child: current == null
                ? const Center(
                    child: Icon(
                      Icons.music_note_rounded,
                      color: Colors.white54,
                    ),
                  )
                : ClipOval(
                    child: ColorFiltered(
                      colorFilter: const ColorFilter.matrix([
                        0.9, 0, 0, 0, 0, //
                        0, 0.9, 0, 0, 0, //
                        0, 0, 0.9, 0, 0, //
                        0, 0, 0, 1.08, 0, //
                      ]),
                      child: CoverImage(
                        key: ValueKey(
                          'vinyl:${current.path}:${current.coverUrl ?? ''}',
                        ),
                        songPath: current.path,
                        imageUrl: current.coverUrl,
                        width: label * .92,
                        height: label * .92,
                        radius: label * .46,
                        highQuality: true,
                        icon: Icons.music_note_rounded,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 黑胶盘面：径向渐变底色 + 密集音轨环 + 斜向高光 + 边缘描边。
class _VinylDiscPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final side = size.width;
    final center = Offset(side / 2, side / 2);
    final radius = side / 2;

    // 盘面底色（BakaMusic：中心 #111 → 52% #080808 → 边缘 #171717）。
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFF111111), Color(0xFF080808), Color(0xFF171717)],
          stops: [0, .52, 1],
        ).createShader(Offset.zero & size),
    );

    // 音轨环：从标签外缘到盘沿，每 3.5px 一圈 1px 细环。
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x0DFFFFFF);
    for (var r = radius * .36; r < radius * .99; r += 3.5) {
      canvas.drawCircle(center, r, groove);
    }

    // 高光不画在旋转层：真实黑胶的反光来自固定光源与音轨衍射，
    // 在唱片上呈现为固定的扇形亮区（见 _VinylSheenPainter），随盘面
    // 一起旋转的线性高光会显得“反光跟着唱片转”，不自然。

    // 边缘 1px 白描边（移除内侧压暗环，消除内圈黑边）。
    canvas.drawCircle(
      center,
      radius - .5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x14FFFFFF),
    );
  }

  @override
  bool shouldRepaint(covariant _VinylDiscPainter oldDelegate) => false;
}

/// 黑胶扇形高光：固定在屏幕空间的两个对称楔形亮区（左上/右下对角）。
/// 细密音轨像衍射光栅一样把光源反射成沿径向的扇形光芒，只出现在
/// 标签外侧的音轨环带上，且不随唱片旋转。
class _VinylSheenPainter extends CustomPainter {
  const _VinylSheenPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.width;
    final center = Offset(side / 2, side / 2);
    final radius = side / 2;
    final labelRadius = side * .618 / 2;

    // 角度渐变（屏幕坐标 0°=右、90°=下）：两峰相差 180°，峰位在 45°
    // （右下）/225°（左上）对角，各宽约 60°，对应左上光源的衍射反射。
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius - labelRadius
      ..blendMode = BlendMode.plus
      ..shader = const SweepGradient(
        colors: [
          Color(0x00FFFFFF),
          Color(0x22FFFFFF),
          Color(0x00FFFFFF),
          Color(0x00FFFFFF),
          Color(0x22FFFFFF),
          Color(0x00FFFFFF),
        ],
        stops: [.04, .125, .21, .54, .625, .71],
      ).createShader(Offset.zero & size);
    canvas.drawCircle(center, (radius + labelRadius) / 2, paint);
  }

  @override
  bool shouldRepaint(covariant _VinylSheenPainter oldDelegate) => false;
}

class _MiniLyrics extends ConsumerWidget {
  const _MiniLyrics({
    required this.item,
    required this.offsetTenths,
    this.maxRows = 2,
  });

  final QueueItem item;
  final int offsetTenths;

  /// 展示的最大行数（按视觉行计，歌词与翻译各占一行）：普通页面 2 行；
  /// 沉浸模式（播放栏隐藏）4 行，播放栏弹出（上浮动画）时回落 2 行，
  /// 自动隐藏后恢复 4 行。因此有翻译时 4 行窗口只放得下当前句 + 下一句。
  final int maxRows;

  /// 翻译跟随歌词展示的字号上限：超过则只显示歌词行，避免展示区
  /// 被小字挤满。
  static const double _singleLineThreshold = 20;

  /// 迷你歌词展示区高度：2 行 78dp、4 行 144dp。父容器按「预留行数」
  /// 取用，保证沉浸模式下播放栏弹出/隐藏时封面不随歌词行数抖动。
  static double heightFor(int rows) => rows >= 4 ? 144 : 78;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = applyLyricsOffset(
      ref.watch(playerProvider.select((state) => state.position)),
      offsetTenths,
    );
    final fontSize = ref.watch(
      settingsProvider.select(
        (value) => value.valueOrNull?.miniLyricFontSize ?? 14.0,
      ),
    );
    final embedded = item.lyricsRaw?.trim() ?? '';
    if (embedded.isNotEmpty) {
      return _buildAsync(
        ref.watch(embeddedLyricsProvider(embedded)),
        position,
        fontSize,
      );
    }
    if (item.pluginId != null && !item.lyricsAttempted) {
      return _message('正在获取歌词…', fontSize);
    }
    if (item.pluginId != null) {
      return _message('暂无歌词', fontSize);
    }
    return _buildAsync(
      ref.watch(songLyricsProvider(item.path)),
      position,
      fontSize,
    );
  }

  Widget _buildAsync(
    AsyncValue<List<LyricLine>> lyrics,
    double position,
    double fontSize,
  ) {
    return lyrics.when(
      loading: () => _message('正在获取歌词…', fontSize),
      error: (_, _) => _message('暂无歌词', fontSize),
      data: (lines) {
        if (lines.isEmpty) return _message('暂无歌词', fontSize);
        var active = lines.lastIndexWhere((line) => line.time <= position);
        if (active < 0) active = 0;
        final rows = _collectRows(lines, active, fontSize);
        if (rows.isEmpty) return _message('暂无歌词', fontSize);
        return _surface(
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            alignment: Alignment.center,
            child: AnimatedSwitcher(
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
              // 当前行推进或行数变化（沉浸模式播放栏弹出/隐藏）时都重建，
              // 由 AnimatedSize 平滑收放行数。
              child: Column(
                key: ValueKey('${item.path}:${lines[active].time}:$maxRows'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const SizedBox(height: 3),
                    _rowText(rows[i], fontSize),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 收集窗口内的歌词行。歌词与翻译各占一行，按「行」而非「句」控制预算：
  /// - 有翻译（字号 ≤ 阈值且当前句带译文）：4 行窗口 = 当前句 + 下一句
  ///   （各含歌词与翻译，共 4 行）；2 行窗口 = 仅当前句（歌词 + 翻译）。
  /// - 无翻译：4 行窗口 = 上一行 + 当前行 + 下两行；2 行窗口 = 当前 + 下一行。
  List<_MiniLyricRow> _collectRows(
    List<LyricLine> lines,
    int active,
    double fontSize,
  ) {
    final showTranslation = fontSize <= _singleLineThreshold;
    final activeHasTranslation =
        showTranslation && lines[active].translation.trim().isNotEmpty;
    // 有翻译时窗口从当前句起算（上一句不占额度），无翻译时保留上一句做上下文。
    final start = activeHasTranslation
        ? active
        : (maxRows >= 4 ? math.max(0, active - 1) : active);
    final rows = <_MiniLyricRow>[];
    var used = 0;
    for (var i = start; i < lines.length; i++) {
      final text = lines[i].text.trim();
      if (text.isEmpty) continue;
      final translation = showTranslation ? lines[i].translation.trim() : '';
      // 歌词恒占 1 行；有译文再加 1 行，超出窗口预算即停止。
      final cost = translation.isEmpty ? 1 : 2;
      if (used + cost > maxRows) break;
      used += cost;
      rows.add(
        _MiniLyricRow(
          text: text,
          isActive: i == active,
          translation: translation,
        ),
      );
    }
    return rows;
  }

  /// 单行渲染：当前行高亮加粗，其余行淡色小字；两者都可在下方跟随
  /// 一行小字翻译（翻译同样占用展示行数）。
  Widget _rowText(_MiniLyricRow row, double fontSize) {
    final isActive = row.isActive;
    final lyric = Text(
      row.text,
      // 当前行换行上限：四行窗口每行单行；两行窗口仅在无翻译且字号
      // 不大时允许软换行（否则「当前行两行 + 翻译 + 下一行」会超出
      // 展示区高度）。
      maxLines:
          isActive &&
              maxRows <= 2 &&
              row.translation.isEmpty &&
              fontSize <= _singleLineThreshold
          ? 2
          : 1,
      softWrap: true,
      overflow: isActive && maxRows <= 2
          ? TextOverflow.clip
          : TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: isActive
          ? TextStyle(
              color: Colors.white,
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              height: 1.3,
              shadows: const [Shadow(color: Colors.black54, blurRadius: 10)],
            )
          : TextStyle(
              color: Colors.white.withValues(alpha: .5),
              fontSize: fontSize * .82,
              height: 1.3,
            ),
    );
    if (row.translation.isEmpty) return lyric;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        lyric,
        const SizedBox(height: 2),
        Text(
          row.translation,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: isActive ? .62 : .4),
            fontSize: fontSize * (isActive ? .78 : .72),
            height: 1.3,
          ),
        ),
      ],
    );
  }

  Widget _message(String text, double fontSize) {
    return _surface(
      Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white.withValues(alpha: .5),
          fontSize: fontSize,
        ),
      ),
    );
  }

  Widget _surface(Widget child) {
    return Center(child: child);
  }
}

/// 迷你歌词单行数据：一行歌词，可携带随行小字翻译（翻译另占一行）。
class _MiniLyricRow {
  const _MiniLyricRow({
    required this.text,
    required this.isActive,
    this.translation = '',
  });

  final String text;
  final bool isActive;
  final String translation;
}

class _LyricsView extends ConsumerStatefulWidget {
  const _LyricsView({
    super.key,
    required this.item,
    required this.offsetTenths,
    this.onLinkLyrics,
  });
  final QueueItem item;
  final int offsetTenths;

  /// 歌词页“暂无歌词”空态下的快捷关联歌词回调。
  final VoidCallback? onLinkLyrics;

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
  List<LyricLine> _latestLines = const [];

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
    final showTranslation =
        ref.watch(settingsProvider).valueOrNull?.showLyricsTranslation ?? true;
    final tapSeek =
        ref.watch(settingsProvider).valueOrNull?.lyricTapSeek ?? true;
    final textAlign = switch (lyricAlignment) {
      LyricDisplayAlignment.left => TextAlign.left,
      LyricDisplayAlignment.center => TextAlign.center,
      LyricDisplayAlignment.right => TextAlign.right,
    };
    final embedded = widget.item.lyricsRaw?.trim() ?? '';
    late final Widget content;
    if (embedded.isNotEmpty) {
      final lyrics = ref.watch(embeddedLyricsProvider(embedded));
      content = lyrics.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => _lyricsEmpty(context, '歌词解析失败'),
        data: (lines) => _buildLines(
          lines,
          position,
          effectMode,
          textAlign,
          baseFontSize,
          showTranslation,
          tapSeek,
        ),
      );
    } else if (widget.item.pluginId != null && !widget.item.lyricsAttempted) {
      content = _lyricsEmpty(context, '正在获取歌词…');
    } else if (widget.item.pluginId != null) {
      content = _lyricsEmpty(
        context,
        '暂无歌词',
        onLinkLyrics: widget.onLinkLyrics,
      );
    } else {
      final lyrics = ref.watch(songLyricsProvider(widget.item.path));
      content = lyrics.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) =>
            _lyricsEmpty(context, '暂无歌词', onLinkLyrics: widget.onLinkLyrics),
        data: (lines) => _buildLines(
          lines,
          position,
          effectMode,
          textAlign,
          baseFontSize,
          showTranslation,
          tapSeek,
        ),
      );
    }
    return content;
  }

  Widget _buildLines(
    List<LyricLine> lines,
    double position,
    LyricWordEffectMode effectMode,
    TextAlign textAlign,
    double baseFontSize,
    bool showTranslation,
    bool tapSeek,
  ) {
    if (lines.isEmpty) {
      return _lyricsEmpty(context, '暂无歌词', onLinkLyrics: widget.onLinkLyrics);
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
                        // 设置关闭“单击歌词调整进度”时禁用点击跳转。
                        onTap: tapSeek
                            ? () => ref
                                  .read(playerProvider.notifier)
                                  .seek(
                                    playbackPositionForLyric(
                                      line.time,
                                      widget.offsetTenths,
                                    ),
                                  )
                            : null,
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
                            opacity: selected ? 1 : .55,
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
                                if (line.translation.isNotEmpty &&
                                    showTranslation) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    line.translation,
                                    textAlign: textAlign,
                                    style: TextStyle(
                                      // 主歌词的一半（约 9sp）在手机上
                                      // 几乎不可见，用户反馈“翻译不见了”，
                                      // 恢复 baseFontSize - 5；字重用
                                      // ExtraBold 强化加粗观感。
                                      fontSize: (baseFontSize - 5).clamp(
                                        10.0,
                                        26.0,
                                      ),
                                      fontWeight: FontWeight.w800,
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

  void _syncScroll(int active, List<LyricLine> lines) {
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

  void _coarseScrollTo(int active, List<LyricLine> lines) {
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

  /// 空态文案；传入 [onLinkLyrics] 时（暂无歌词）不显示 logo，
  /// 改为显示“关联歌词”快捷按钮。
  Widget _lyricsEmpty(
    BuildContext context,
    String message, {
    VoidCallback? onLinkLyrics,
  }) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onLinkLyrics == null) ...[
          Icon(
            Icons.lyrics_outlined,
            size: 52,
            color: Colors.white.withValues(alpha: .3),
          ),
          const SizedBox(height: 12),
        ],
        Text(
          message,
          style: TextStyle(color: Colors.white.withValues(alpha: .5)),
        ),
        if (onLinkLyrics != null) ...[
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: onLinkLyrics,
            icon: const Icon(Icons.lyrics_outlined, size: 20),
            label: const Text('关联歌词'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: .4)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
          ),
        ],
      ],
    ),
  );
}

/// 歌词字号调整弹窗：双滑杆（主歌词 + 迷你歌词）+ 实时预览。拖动即写入
/// 设置（实时生效），播放详情页歌词会立即使用新字号重新渲染；两类字号
/// 彼此独立。
class _LyricFontSizeSheet extends StatefulWidget {
  const _LyricFontSizeSheet({
    required this.initial,
    required this.initialMini,
    required this.onChanged,
    required this.onMiniChanged,
  });

  final double initial;
  final double initialMini;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onMiniChanged;

  @override
  State<_LyricFontSizeSheet> createState() => _LyricFontSizeSheetState();
}

class _LyricFontSizeSheetState extends State<_LyricFontSizeSheet> {
  late double _value;
  late double _miniValue;

  @override
  void initState() {
    super.initState();
    _value = widget.initial;
    _miniValue = widget.initialMini;
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
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.subtitles_outlined, color: scheme.primary),
              const SizedBox(width: 12),
              const Text('迷你歌词字号', style: TextStyle(fontSize: 16)),
              const Spacer(),
              Text(
                _miniValue.toStringAsFixed(0),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          Slider(
            value: _miniValue,
            min: 10,
            max: 24,
            divisions: 14,
            label: _miniValue.toStringAsFixed(0),
            onChanged: (value) {
              setState(() => _miniValue = value);
              widget.onMiniChanged(value);
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
          const SizedBox(height: 8),
          // 迷你歌词预览：与封面下方的迷你歌词展示区等高，
          // 直观展示迷你歌词字号的效果。
          Container(
            height: 78,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: .5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '迷你歌词主行',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: _miniValue,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                if (_miniValue <= 20) ...[
                  const SizedBox(height: 3),
                  Text(
                    '迷你歌词副行',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: _miniValue * .82,
                      color: scheme.onSurface.withValues(alpha: .5),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '迷你歌词超过 20 只显示单行；两类字号独立保存，重启后保留',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurface.withValues(alpha: .5),
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

  final LyricLine line;
  final double position;
  final bool selected;
  final LyricWordEffectMode effectMode;
  final TextAlign textAlign;

  /// 设置中的歌词基础字号：所有行统一字号，不再对当前行放大。
  final double baseFontSize;

  @override
  Widget build(BuildContext context) {
    // 当前播放行不再叠加阴影，逐字/逐词高亮也不再发光，保持纯色渲染。
    final baseStyle = TextStyle(
      color: Colors.white,
      fontSize: baseFontSize,
      height: 1.3,
      fontWeight: FontWeight.w600,
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
    // 与未播放行（白字 + 整行 55% 透明度）保持同一灰度，避免当前行
    // 未播区呈现更深的灰。
    final dimColor = Colors.white.withValues(alpha: .55);
    return Text.rich(
      TextSpan(
        children: [
          for (final word in line.words)
            TextSpan(
              text: word.text,
              style: baseStyle.copyWith(
                color: Color.lerp(dimColor, Colors.white, _wordProgress(word)),
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

  double _wordProgress(LyricWord word) {
    if (position <= word.start) return 0;
    if (position >= word.end || word.end <= word.start) return 1;
    return ((position - word.start) / (word.end - word.start)).clamp(0, 1);
  }
}

class _ProgressiveLyricWord extends StatefulWidget {
  const _ProgressiveLyricWord({
    required this.text,
    required this.style,
    required this.progress,
  });

  final String text;
  final TextStyle style;
  final double progress;

  @override
  State<_ProgressiveLyricWord> createState() => _ProgressiveLyricWordState();
}

class _ProgressiveLyricWordState extends State<_ProgressiveLyricWord> {
  /// 已排版的白色字形画笔。文本/样式/缩放未变时跨帧复用以消除逐帧
  /// TextPainter.layout（字形排版是逐字扫光的主要开销）。
  TextPainter? _painter;
  TextStyle? _resolved;
  String? _layoutText;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensurePainter();
  }

  @override
  void didUpdateWidget(_ProgressiveLyricWord oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _ensurePainter();
    }
  }

  /// 合并 DefaultTextStyle 与主题缩放后按需重排；输入不变则直接复用。
  void _ensurePainter() {
    final resolved = DefaultTextStyle.of(context).style.merge(widget.style);
    final scaler = MediaQuery.textScalerOf(context);
    if (_painter != null &&
        _layoutText == widget.text &&
        _resolved == resolved) {
      return;
    }
    _painter?.dispose();
    _layoutText = widget.text;
    _resolved = resolved;
    _painter = TextPainter(
      text: TextSpan(
        text: widget.text,
        style: resolved.copyWith(color: Colors.white),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
  }

  @override
  void dispose() {
    _painter?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.progress.clamp(0.0, 1.0);
    // 前景画笔方案：child（暗色整词）走普通 Text 渲染路径，与未扫光
    // 的词完全一致；白色字形由 TextPainter 按相同 style 绘制并水平裁剪。
    // 不引入 saveLayer/混合模式，WidgetSpan 内字形底部（下降部）不会
    // 再被图层擦除裁掉。进度采样 80ms 一次，硬边裁剪在视觉上足够平滑。
    // 暗色与未播放行（55% 透明度）灰度一致。
    //
    // WidgetSpan 内的 Text 会与 DefaultTextStyle 合并（字体族等来自
    // 主题）；画笔必须用同一份合并后的样式布局，否则 child 与画笔
    // 用两套字体渲染出大小不一的重影。
    final resolved = _resolved ?? widget.style;
    final dim = Colors.white.withValues(alpha: .55);
    if (value <= 0) {
      return Text(widget.text, style: resolved.copyWith(color: dim));
    }
    if (value >= 1) {
      return Text(widget.text, style: resolved.copyWith(color: Colors.white));
    }
    return CustomPaint(
      foregroundPainter: _SweepWordPainter(
        painter: _painter,
        progress: value,
      ),
      child: Text(widget.text, style: resolved.copyWith(color: dim)),
    );
  }
}

/// 逐字扫光前景画笔：在暗色整词之上，按进度水平裁剪绘制白色字形。
///
/// 画笔只负责裁剪绘制，字形由 [_ProgressiveLyricWordState] 预排版并复用，
/// 因此每次 paint 不再触发 TextPainter.layout；画笔本身不持有/释放
/// TextPainter（原生 Paragraph 由 State 在其 dispose 时统一释放）。
class _SweepWordPainter extends CustomPainter {
  _SweepWordPainter({required this.painter, required this.progress});

  final TextPainter? painter;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final tp = painter;
    if (tp == null || progress <= 0) return;
    final clipWidth = tp.width * progress.clamp(0.0, 1.0);
    if (clipWidth <= 0) return;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, clipWidth, size.height));
    tp.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SweepWordPainter old) =>
      old.progress != progress || old.painter != painter;
}

/// 毛玻璃控制卡：标题 + 进度 + 播放控制。
class _GlassControlCard extends ConsumerWidget {
  const _GlassControlCard({
    required this.notifier,
    required this.current,
    this.showMetadata = true,
    this.onDownload,
    this.onLinkLyrics,
    this.onDesktopLyrics,
    this.onQuality,
    this.onLyricFontSizePage,
    this.onPlayMv,
    this.onLyricsOffset,
  });
  final PlayerNotifier notifier;
  final QueueItem? current;
  final bool showMetadata;
  final VoidCallback? onDownload;
  final VoidCallback? onLinkLyrics;
  final VoidCallback? onDesktopLyrics;
  final VoidCallback? onQuality;
  final VoidCallback? onLyricFontSizePage;
  final VoidCallback? onPlayMv;
  final VoidCallback? onLyricsOffset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final errorMessage = ref.watch(
      playerProvider.select((state) => state.errorMessage),
    );

    // 播放栏直接叠加在详情页背景上，不再使用整块半透明卡片，
    // 让封面背景能够连续延伸到屏幕底部。
    // 播放栏整体放大：标题/时间字号、进度条与控制按钮同步加大，
    // 内边距收窄配合外层让播放栏更贴近屏幕边缘。
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
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
                  onLinkLyrics: onLinkLyrics,
                  onDesktopLyrics: onDesktopLyrics,
                  onQuality: onQuality,
                  onLyricFontSizePage: onLyricFontSizePage,
                  onPlayMv: onPlayMv,
                  onLyricsOffset: onLyricsOffset,
                ),
                if (errorMessage != null) ...[
                  const SizedBox(height: 10),
                  _PlaybackError(
                    message: errorMessage,
                    onRetry: notifier.toggle,
                    onSwitchSource: current == null
                        ? null
                        : () => _switchCurrentSource(context, ref, current!),
                  ),
                ],
                const SizedBox(height: 16),
                _ProgressBar(notifier: notifier),
                const SizedBox(height: 8),
                _Controls(notifier: notifier),
              ],
            ),
    );
  }

  /// 报错框「换源」：选目标插件 → 挑候选歌曲 → 原位替换队列并立即重播。
  Future<void> _switchCurrentSource(
    BuildContext context,
    WidgetRef ref,
    QueueItem item,
  ) async {
    final plugins = await ref.read(enabledMusicPluginsProvider.future);
    if (!context.mounted) return;
    if (plugins.isEmpty) {
      XyNotice.show(
        context,
        message: '请先在 设置 → 插件 中启用插件',
        type: XyNoticeType.warning,
      );
      return;
    }
    final picked = await showSourceSwitchSheet(
      context,
      ref,
      title: item.title,
      artist: item.artist,
      durationMs: item.durationMs,
      excludePluginId: item.pluginId,
    );
    if (picked == null || !context.mounted) return;
    final (plugin, song) = picked;
    // 收藏与歌单里的同一首歌同步原位换源，保持列表数据一致。
    await syncReplacementToCollections(
      ref,
      originalPath: item.path,
      plugin: plugin,
      replacement: song,
    );
    final replaced = await ref
        .read(playerProvider.notifier)
        .switchSource(item.path, replacementToQueueItem(plugin, song));
    if (!context.mounted) return;
    if (replaced) {
      XyNotice.show(
        context,
        message: '已切换到 ${plugin.name} 音源',
        type: XyNoticeType.success,
      );
    } else {
      XyNotice.show(
        context,
        message: '原歌曲已不在播放队列中',
        type: XyNoticeType.warning,
      );
    }
  }
}

class _PlaybackError extends StatelessWidget {
  const _PlaybackError({
    required this.message,
    required this.onRetry,
    this.onSwitchSource,
  });
  final String message;
  final VoidCallback onRetry;
  final VoidCallback? onSwitchSource;

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
          if (onSwitchSource != null)
            TextButton(
              onPressed: onSwitchSource,
              child: const Text('换源', style: TextStyle(color: Colors.white)),
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
    this.onLinkLyrics,
    this.onDesktopLyrics,
    this.onQuality,
    this.onLyricFontSizePage,
    this.onPlayMv,
    this.onLyricsOffset,
  });
  final QueueItem current;
  final bool showMetadata;
  final VoidCallback? onDownload;
  final VoidCallback? onLinkLyrics;
  final VoidCallback? onDesktopLyrics;
  final VoidCallback? onQuality;
  final VoidCallback? onLyricFontSizePage;
  final VoidCallback? onPlayMv;

  /// 本地歌曲时快捷按钮位的「歌词偏移」入口。
  final VoidCallback? onLyricsOffset;

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
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    // Flexible 让歌手名较短时 MV 按钮紧贴在歌手名右侧，
                    // 而不是被推到行末（收藏按钮下方）。
                    Flexible(
                      child: Text(
                        current.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white.withValues(alpha: .56),
                        ),
                      ),
                    ),
                    if (onPlayMv != null)
                      IconButton(
                        tooltip: '播放 MV',
                        icon: const Icon(
                          Icons.ondemand_video_outlined,
                          size: 18,
                          color: Colors.white70,
                        ),
                        padding: const EdgeInsets.only(left: 6),
                        constraints: const BoxConstraints.tightFor(
                          width: 30,
                          height: 24,
                        ),
                        onPressed: onPlayMv,
                      ),
                  ],
                ),
              ],
            ),
          ),
        // 封面页：标题区右侧仅保留收藏按钮。
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
        // 歌词页快捷按钮：音质（当前歌曲实际音质缩写）→ 下载（本地歌曲
        // 无下载意义，改为歌词偏移）→ 关联歌词 → 字号调整 → 桌面歌词。
        if (!showMetadata)
          _qualityBadgeAction(
            context,
            ref,
            tooltip: '音质调节',
            onPressed: isLocal ? null : onQuality,
          ),
        if (!showMetadata)
          isLocal
              ? _quickAction(
                  context,
                  icon: Icons.sync_alt_rounded,
                  tooltip: '歌词偏移',
                  onPressed: onLyricsOffset,
                )
              : _quickAction(
                  context,
                  icon: Icons.download_rounded,
                  tooltip: '下载',
                  onPressed: onDownload,
                ),
        if (!showMetadata)
          _charAction(
            context,
            text: '词',
            tooltip: '关联歌词',
            onPressed: onLinkLyrics,
          ),
        if (!showMetadata)
          _quickAction(
            context,
            icon: Icons.format_size_rounded,
            tooltip: '字号调整',
            onPressed: onLyricFontSizePage,
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
      ],
    );
  }

  /// 音质按钮：显示正在播放歌曲的实际音质缩写（参考桌面端），颜色与
  /// 同排其他快捷按钮保持统一；无音质信息（本地/未知）时回退 HQ。
  Widget _qualityBadgeAction(
    BuildContext context,
    WidgetRef ref, {
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    final quality = ref
        .watch(playerProvider.select((state) => state.currentQuality))
        .trim();
    final label = qualityShortLabel(quality);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.standard,
      padding: const EdgeInsets.all(8),
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      icon: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w800,
          letterSpacing: .5,
          color: Colors.white70,
        ),
      ),
    );
  }

  Widget _quickAction(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    double size = 26,
  }) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: size, color: Colors.white70),
      onPressed: onPressed,
      // 与封面界面的收藏按钮保持同一尺寸和内边距，切换页面时图标
      // 中心位置不会发生跳动；所有快捷按钮也因此保持同一水平基线。
      visualDensity: VisualDensity.standard,
      padding: const EdgeInsets.all(8),
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    );
  }

  /// 汉字图标按钮：用单个中文字（如“词”）代替图标字形，视觉大小
  /// 按字号对齐同排的 [Icon] 快捷按钮。
  Widget _charAction(
    BuildContext context, {
    required String text,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      icon: Text(
        text,
        style: const TextStyle(
          fontSize: 22,
          height: 1,
          fontWeight: FontWeight.w800,
          color: Colors.white70,
        ),
      ),
      onPressed: onPressed,
      visualDensity: VisualDensity.standard,
      padding: const EdgeInsets.all(8),
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    );
  }
}

class _ProgressBar extends ConsumerStatefulWidget {
  const _ProgressBar({required this.notifier});
  final PlayerNotifier notifier;

  @override
  ConsumerState<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends ConsumerState<_ProgressBar> {
  // 拖动中的本地预览位置：拖动期间滑块只跟随手指，暂时隔离进度流
  // 的更新；松手（onChangeEnd）才真正 seek。旧实现把 onChanged 直接
  // 接到原生 seek，每个拖动 tick 都执行一次 seek，既造成音频卡顿，
  // 又让滑块在手指位置与流式位置之间来回打架（表现为拖拽失误）。
  double? _dragValue;

  String _fmt(double s) {
    if (!s.isFinite || s < 0) s = 0;
    final m = s ~/ 60;
    final sec = (s % 60).floor();
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final progress = ref.watch(
      playerProvider.select(
        (state) => (position: state.position, duration: state.duration),
      ),
    );
    return _buildProgress(
      context,
      _dragValue ?? progress.position,
      progress.duration,
      onChanged: (value) => setState(() => _dragValue = value),
      onChangeEnd: (value) {
        setState(() => _dragValue = null);
        widget.notifier.seek(value);
      },
    );
  }

  Widget _buildProgress(
    BuildContext context,
    double rawPosition,
    double rawDuration, {
    required ValueChanged<double>? onChanged,
    ValueChanged<double>? onChangeEnd,
  }) {
    final scheme = Theme.of(context).colorScheme;
    // 时长未知（恢复会话/插件歌曲元数据缺时长）时进度归零：若仍按
    // max=1.0 钳制，恢复的 position 会让滑块先停在尾端，时长事件到达
    // 后再跳回真实进度。
    final hasDuration = rawDuration.isFinite && rawDuration > 0;
    final dur = hasDuration ? rawDuration : 1.0;
    final position = hasDuration && rawPosition.isFinite
        ? rawPosition.clamp(0.0, dur)
        : 0.0;
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: scheme.primary,
            inactiveTrackColor: Colors.white.withValues(alpha: .16),
            thumbColor: scheme.primary,
            overlayColor: scheme.primary.withValues(alpha: 0.16),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
          ),
          child: Slider(
            value: position,
            max: dur,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _fmt(position),
                style: TextStyle(
                  fontSize: 12.5,
                  color: Colors.white.withValues(alpha: .52),
                ),
              ),
              Text(
                _fmt(dur),
                style: TextStyle(
                  fontSize: 12.5,
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
  const _Controls({required this.notifier});
  final PlayerNotifier notifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    return _buildControls(context, ref, player);
  }

  Widget _buildControls(
    BuildContext context,
    WidgetRef ref,
    ({bool isPlaying, bool isLoading, int playMode, bool hasQueue}) player,
  ) {
    final icons = [Icons.repeat, Icons.repeat_one, Icons.shuffle];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          iconSize: 30,
          icon: Icon(icons[player.playMode], color: Colors.white70),
          onPressed: notifier.cyclePlayMode,
        ),
        IconButton(
          iconSize: 36,
          icon: const Icon(Icons.skip_previous, color: Colors.white),
          onPressed: notifier.previous,
        ),
        // 播放键：去掉主题色圆形底与投影，只保留图标本身。
        IconButton(
          iconSize: 54,
          icon: player.isLoading
              ? const SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.8,
                    color: Colors.white,
                  ),
                )
              : Icon(
                  player.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                  shadows: const [
                    Shadow(color: Colors.black54, blurRadius: 12),
                  ],
                ),
          onPressed: player.isLoading ? null : notifier.toggle,
        ),
        IconButton(
          iconSize: 36,
          icon: const Icon(Icons.skip_next, color: Colors.white),
          onPressed: notifier.next,
        ),
        IconButton(
          iconSize: 30,
          icon: const Icon(Icons.queue_music, color: Colors.white70),
          onPressed: !player.hasQueue ? null : () => _showQueue(context, ref),
        ),
      ],
    );
  }

  Future<void> _showQueue(BuildContext context, WidgetRef ref) {
    return showQueueSheet(context, ref);
  }
}

/// 视频画质档位数值（'1080P' → 1080、'720p' → 720），无法解析返回 0。
/// 供起播失败的自动降档与错误面板的档位排序共用。
int _videoQualityRank(String label) {
  final match = RegExp(r'(\d{3,4})').firstMatch(label);
  return match == null ? 0 : int.parse(match.group(1)!);
}

/// MV/视频错误面板（参考 BakaMusic 的播放失败页）：中央描边圆环警示
/// 图标 + 标题/说明 +「重新加载」按钮 + 画质档位胶囊快捷切换。用于
/// 起播失败（自动降档也失败）与后台久置挂起两种场景。
class _VideoErrorPanel extends StatelessWidget {
  const _VideoErrorPanel({
    required this.error,
    required this.choices,
    required this.currentQuality,
    this.onReload,
    this.onSelectQuality,
  });

  final String error;
  final List<String> choices;
  final String currentQuality;
  final VoidCallback? onReload;
  final void Function(String quality)? onSelectQuality;

  @override
  Widget build(BuildContext context) {
    // 档位按清晰度从高到低排序、去重。
    final ranked = <String>[];
    for (final quality in choices) {
      if (!ranked.any(
        (existing) => existing.toLowerCase() == quality.toLowerCase(),
      )) {
        ranked.add(quality);
      }
    }
    ranked.sort((a, b) => _videoQualityRank(b).compareTo(_videoQualityRank(a)));
    return ColoredBox(
      color: Colors.black.withValues(alpha: .82),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: .35),
                  border: Border.all(color: Colors.white, width: 2.5),
                ),
                child: const Icon(
                  Icons.error_outline_rounded,
                  color: Colors.white,
                  size: 42,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'MV 播放失败',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '请重新加载，或选择其他清晰度',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 28),
              OutlinedButton.icon(
                onPressed: onReload,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white, width: 1.2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 10,
                  ),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text(
                  '重新加载',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              if (ranked.length > 1 && onSelectQuality != null) ...[
                const SizedBox(height: 28),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final quality in ranked)
                      _buildQualityChip(quality, onSelectQuality!),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              Text(
                error,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQualityChip(
    String quality,
    void Function(String quality) onSelect,
  ) {
    final selected = quality.toLowerCase() == currentQuality.toLowerCase();
    return GestureDetector(
      onTap: selected ? null : () => onSelect(quality),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: selected ? Colors.white : Colors.white38,
            width: 1,
          ),
        ),
        child: Text(
          quality.toUpperCase(),
          style: TextStyle(
            color: selected ? Colors.black : Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
