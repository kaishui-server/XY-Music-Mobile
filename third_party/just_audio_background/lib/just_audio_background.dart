import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:rxdart/rxdart.dart';
import 'package:synchronized/synchronized.dart';

export 'package:audio_service/audio_service.dart' show MediaItem;

late SwitchAudioHandler _audioHandler;
late JustAudioPlatform _platform;

/// XY Music 本地补丁：暴露内部 SwitchAudioHandler，宿主应用可用它在
/// just_audio_background 初始化完成后替换/包装 inner handler，例如为
/// “单 URL 播放”模型补上媒体通知的上一首/下一首控件。
/// 未初始化（JustAudioBackground.init 尚未调用）时抛出 LateInitializationError。
SwitchAudioHandler get xySwitchAudioHandler => _audioHandler;

/// XY Music 本地补丁：跨代理链的均衡器门面。
///
/// 真实平台播放器在 [_initPlayer] 时被注入原生 AndroidEqualizer（默认
/// 停用），本门面在其首次 load（audio session attach、原生均衡器创建）
/// 之后按需读写。未就绪时缓存开关与增益，load 完成后自动重放；audio
/// session 变化重建均衡器也会触发重放。宿主应用直接读写本门面，外层
/// just_audio 播放器不再挂任何音频效果。
final XyAndroidEqualizer xyAndroidEqualizer = XyAndroidEqualizer();

/// XY Music 本地补丁：响度增益（LoudnessEnhancer）门面。
///
/// 与 [xyAndroidEqualizer] 同机制：真实平台播放器在 [_initPlayer] 时被
/// 注入原生 AndroidLoudnessEnhancer（默认停用），供宿主实现均衡器前级
/// （preamp）、音量增强等整体 dB 增益。未就绪时缓存，load 后重放。
final XyAndroidLoudnessEnhancer xyLoudnessEnhancer =
    XyAndroidLoudnessEnhancer();

/// XY Music 本地补丁：设备原生音频效果可用性。
///
/// 宿主应在初始化音频之前探测并写入结果（见 [xySetAndroidAudioEffectsSupported]）。
/// 部分机型（实测 OnePlus Android 16）的音频 HAL 不提供系统均衡器实现，
/// `android.media.audiofx.AudioEffect` 构造时抛 RuntimeException
/// （"Cannot initialize effect engine for type: 0bed4300-... Error: -3"）。
/// just_audio 只要被注入 AndroidEqualizer/AndroidLoudnessEnhancer，就会在
/// audio session 建立时构造对应效果；该异常发生在主线程且无人捕获，会直接
/// 把整个进程判为崩溃退出。因此不可用时干脆不注入，音效在该机型上降级。
bool xyAndroidEqualizerSupported = true;
bool xyAndroidLoudnessEnhancerSupported = true;

/// 写入原生音频效果能力探测结果（宿主在音频初始化前调用一次）。
void xySetAndroidAudioEffectsSupported({
  required bool equalizer,
  required bool loudnessEnhancer,
}) {
  xyAndroidEqualizerSupported = equalizer;
  xyAndroidLoudnessEnhancerSupported = loudnessEnhancer;
}

/// 均衡器单个频段的可读信息。
class XyEqualizerBandInfo {
  const XyEqualizerBandInfo({
    required this.index,
    required this.centerFrequency,
    required this.gain,
  });

  /// 频段下标（从 0 开始）。
  final int index;

  /// 中心频率（Hz）。
  final double centerFrequency;

  /// 当前增益（dB）。
  final double gain;
}

/// 均衡器整体的可读信息。
class XyEqualizerInfo {
  const XyEqualizerInfo({
    required this.minDecibels,
    required this.maxDecibels,
    required this.bands,
  });

  final double minDecibels;
  final double maxDecibels;
  final List<XyEqualizerBandInfo> bands;
}

class XyAndroidEqualizer {
  AudioPlayerPlatform? _platform;

  /// 是否已完成过至少一次 load（原生均衡器已随 audio session 创建）。
  bool _sourceLoaded = false;

  /// 缓存的开关状态与各频段增益（dB），load 后重放。
  bool _enabled = false;
  final Map<int, double> _bandGains = {};

  /// 最近一次 [applyMapped] 的入参缓存：load 后重放时按（可能更新的）
  /// 原生频段重新插值映射。
  List<double>? _mappedSourceGains;
  List<double>? _mappedSourceFreqs;

  /// 原生均衡器真实频段的中心频率缓存（Hz，按下标对应）。
  /// 首次成功读取后缓存，播放器重建（_bind）时清空。
  List<double>? _nativeBandFreqs;

  void _bind(AudioPlayerPlatform platform) {
    _platform = platform;
    _sourceLoaded = false;
    _nativeBandFreqs = null;
  }

  Future<void> _onSourceLoaded() async {
    _sourceLoaded = true;
    await _refreshNativeBands();
    await _reapply();
  }

  /// 读取原生均衡器真实频段参数并缓存中心频率。失败（均衡器尚未就绪
  /// 或平台不支持）时保持缓存为空，重放退化为按下标直写。
  Future<void> _refreshNativeBands() async {
    final platform = _platform;
    if (platform == null || !_sourceLoaded) return;
    if (_nativeBandFreqs != null) return;
    try {
      final response = await platform
          .androidEqualizerGetParameters(AndroidEqualizerGetParametersRequest());
      final freqs = [
        for (final band in response.parameters.bands) band.centerFrequency,
      ];
      if (freqs.isNotEmpty) _nativeBandFreqs = freqs;
    } catch (_) {
      // 原生均衡器暂不可用：保持缓存为空，下次 load 后重试。
    }
  }

  /// 把缓存的开关与增益写入真实平台播放器上的原生均衡器。
  /// 均衡器尚未创建（切换音源瞬间）时静默失败，下次 load 后重放。
  Future<void> _reapply() async {
    final platform = _platform;
    if (platform == null || !_sourceLoaded) return;
    try {
      await platform.audioEffectSetEnabled(AudioEffectSetEnabledRequest(
        type: 'AndroidEqualizer',
        enabled: _enabled,
      ));
      for (final entry in _bandGains.entries) {
        await platform.androidEqualizerBandSetGain(
          AndroidEqualizerBandSetGainRequest(
            bandIndex: entry.key,
            gain: entry.value,
          ),
        );
      }
    } catch (_) {
      // 原生均衡器暂不可用：保留缓存，待下次 load 完成后重放。
    }
  }

  /// 读取均衡器参数（频段列表、dB 范围、各频段当前增益）。
  /// 播放器尚未 load 或均衡器尚未就绪时返回 null，宿主可稍后重试。
  Future<XyEqualizerInfo?> readInfo() async {
    final platform = _platform;
    if (platform == null || !_sourceLoaded) return null;
    try {
      final response = await platform
          .androidEqualizerGetParameters(AndroidEqualizerGetParametersRequest());
      final message = response.parameters;
      return XyEqualizerInfo(
        minDecibels: message.minDecibels,
        maxDecibels: message.maxDecibels,
        bands: [
          for (final band in message.bands)
            XyEqualizerBandInfo(
              index: band.index,
              centerFrequency: band.centerFrequency,
              gain: band.gain,
            ),
        ],
      );
    } catch (_) {
      return null;
    }
  }

  /// 设置均衡器开关（未就绪时缓存，load 后生效）。
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    await _reapply();
  }

  /// 设置单个频段增益（dB，未就绪时缓存，load 后生效）。
  Future<void> setBandGain(int index, double gain) async {
    _bandGains[index] = gain;
    await _reapply();
  }

  /// 整份应用：开关 + 按下标排列的各频段增益（多余的忽略，缺失的补 0）。
  Future<void> apply({
    required bool enabled,
    required List<double> gains,
  }) async {
    _enabled = enabled;
    _bandGains
      ..clear()
      ..addAll({
        for (var i = 0; i < gains.length; i++) i: gains[i],
      });
    await _reapply();
  }

  /// 按频段中心频率映射应用：宿主的均衡器 UI 通常是固定频段（如 10 段
  /// 31Hz~16kHz），而原生均衡器频段数由设备决定（常见 5 段）。这里把
  /// 宿主各频段增益在对数频率轴上插值到原生频段，避免下标错位导致
  /// 「低频滑杆改的是中频」甚至越界失败。
  ///
  /// 未就绪时缓存入参，load 后自动重放（重放时会重新读取原生频段）。
  Future<void> applyMapped({
    required bool enabled,
    required List<double> gains,
    required List<double> centerFrequencies,
  }) async {
    _enabled = enabled;
    _mappedSourceGains = List<double>.of(gains);
    _mappedSourceFreqs = List<double>.of(centerFrequencies);
    await _refreshNativeBands();
    await _remapAndReapply();
  }

  Future<void> _remapAndReapply() async {
    final gains = _mappedSourceGains;
    final freqs = _mappedSourceFreqs;
    if (gains == null || freqs == null) return;
    final nativeFreqs = _nativeBandFreqs;
    _bandGains.clear();
    if (nativeFreqs == null || nativeFreqs.isEmpty) {
      // 原生频段未知（均衡器未就绪）：按下标直写，与旧行为兼容。
      _bandGains.addAll({
        for (var i = 0; i < gains.length; i++) i: gains[i],
      });
    } else {
      for (var i = 0; i < nativeFreqs.length; i++) {
        _bandGains[i] = _interpolateGain(freqs, gains, nativeFreqs[i]);
      }
    }
    await _reapply();
  }

  /// 对数频率轴插值：目标频率在 [freqs] 相邻两点之间线性插值，
  /// 超出范围时取端点值。
  static double _interpolateGain(
    List<double> freqs,
    List<double> gains,
    double target,
  ) {
    if (freqs.isEmpty) return 0;
    if (target <= freqs.first) return gains.first;
    if (target >= freqs.last) return gains.last;
    final logTarget = log(target);
    for (var i = 1; i < freqs.length; i++) {
      if (target <= freqs[i]) {
        final span = log(freqs[i]) - log(freqs[i - 1]);
        if (span <= 0) return gains[i];
        final t = (logTarget - log(freqs[i - 1])) / span;
        return gains[i - 1] + (gains[i] - gains[i - 1]) * t;
      }
    }
    return gains.last;
  }
}

/// 响度增益门面：整体 dB 增益（如均衡器前级、音量增强），挂载在真实
/// 平台播放器的原生 AndroidLoudnessEnhancer 上。生命周期与
/// [XyAndroidEqualizer] 一致（bind/load 重放）。
class XyAndroidLoudnessEnhancer {
  AudioPlayerPlatform? _platform;
  bool _sourceLoaded = false;
  bool _enabled = false;
  double _targetGain = 0;

  void _bind(AudioPlayerPlatform platform) {
    _platform = platform;
    _sourceLoaded = false;
  }

  Future<void> _onSourceLoaded() async {
    _sourceLoaded = true;
    await _reapply();
  }

  Future<void> _reapply() async {
    final platform = _platform;
    if (platform == null || !_sourceLoaded) return;
    try {
      await platform.audioEffectSetEnabled(AudioEffectSetEnabledRequest(
        type: 'AndroidLoudnessEnhancer',
        enabled: _enabled,
      ));
      await platform.androidLoudnessEnhancerSetTargetGain(
        AndroidLoudnessEnhancerSetTargetGainRequest(targetGain: _targetGain),
      );
    } catch (_) {
      // 原生响度增益暂不可用：保留缓存，待下次 load 完成后重放。
    }
  }

  /// 应用整体增益（dB）。未就绪时缓存，load 后自动重放。
  Future<void> apply({required bool enabled, required double targetGain}) async {
    _enabled = enabled;
    _targetGain = targetGain;
    await _reapply();
  }
}

/// Provides the [init] method to initialise just_audio for background playback.
class JustAudioBackground {
  /// Initialise just_audio for background playback. This should be called from
  /// your app's `main` method. e.g.:
  ///
  /// ```dart
  /// Future<void> main() async {
  ///   await JustAudioBackground.init(
  ///     androidNotificationChannelId: 'com.ryanheise.bg_demo.channel.audio',
  ///     androidNotificationChannelName: 'Audio playback',
  ///     androidNotificationOngoing: true,
  ///   );
  ///   runApp(MyApp());
  /// }
  /// ```
  ///
  /// Each parameter controls a behaviour in audio_service. Consult
  /// audio_service's `AudioServiceConfig` API documentation for more
  /// information.
  static Future<void> init({
    bool androidResumeOnClick = true,
    String? androidNotificationChannelId,
    String androidNotificationChannelName = 'Notifications',
    String? androidNotificationChannelDescription,
    Color? notificationColor,
    String androidNotificationIcon = 'mipmap/ic_launcher',
    bool androidShowNotificationBadge = false,
    bool androidNotificationClickStartsActivity = true,
    bool androidNotificationOngoing = false,
    bool androidStopForegroundOnPause = true,
    int? artDownscaleWidth,
    int? artDownscaleHeight,
    Duration fastForwardInterval = const Duration(seconds: 10),
    Duration rewindInterval = const Duration(seconds: 10),
    bool preloadArtwork = false,
    Map<String, dynamic>? androidBrowsableRootExtras,
  }) async {
    WidgetsFlutterBinding.ensureInitialized();
    await _JustAudioBackgroundPlugin.setup(
      androidResumeOnClick: androidResumeOnClick,
      androidNotificationChannelId: androidNotificationChannelId,
      androidNotificationChannelName: androidNotificationChannelName,
      androidNotificationChannelDescription:
          androidNotificationChannelDescription,
      notificationColor: notificationColor,
      androidNotificationIcon: androidNotificationIcon,
      androidShowNotificationBadge: androidShowNotificationBadge,
      androidNotificationClickStartsActivity:
          androidNotificationClickStartsActivity,
      androidNotificationOngoing: androidNotificationOngoing,
      androidStopForegroundOnPause: androidStopForegroundOnPause,
      artDownscaleWidth: artDownscaleWidth,
      artDownscaleHeight: artDownscaleHeight,
      fastForwardInterval: fastForwardInterval,
      rewindInterval: rewindInterval,
      preloadArtwork: preloadArtwork,
      androidBrowsableRootExtras: androidBrowsableRootExtras,
    );
  }
}

class _JustAudioBackgroundPlugin extends JustAudioPlatform {
  static Future<void> setup({
    bool androidResumeOnClick = true,
    String? androidNotificationChannelId,
    String androidNotificationChannelName = 'Notifications',
    String? androidNotificationChannelDescription,
    Color? notificationColor,
    String androidNotificationIcon = 'mipmap/ic_launcher',
    bool androidShowNotificationBadge = false,
    bool androidNotificationClickStartsActivity = true,
    bool androidNotificationOngoing = false,
    bool androidStopForegroundOnPause = true,
    int? artDownscaleWidth,
    int? artDownscaleHeight,
    Duration fastForwardInterval = const Duration(seconds: 10),
    Duration rewindInterval = const Duration(seconds: 10),
    bool preloadArtwork = false,
    Map<String, dynamic>? androidBrowsableRootExtras,
  }) async {
    _platform = JustAudioPlatform.instance;
    JustAudioPlatform.instance = _JustAudioBackgroundPlugin();
    _audioHandler = await AudioService.init(
      builder: () => SwitchAudioHandler(BaseAudioHandler()),
      config: AudioServiceConfig(
        androidResumeOnClick: androidResumeOnClick,
        androidNotificationChannelId: androidNotificationChannelId,
        androidNotificationChannelName: androidNotificationChannelName,
        androidNotificationChannelDescription:
            androidNotificationChannelDescription,
        notificationColor: notificationColor,
        androidNotificationIcon: androidNotificationIcon,
        androidShowNotificationBadge: androidShowNotificationBadge,
        androidNotificationClickStartsActivity:
            androidNotificationClickStartsActivity,
        androidNotificationOngoing: androidNotificationOngoing,
        androidStopForegroundOnPause: androidStopForegroundOnPause,
        artDownscaleWidth: artDownscaleWidth,
        artDownscaleHeight: artDownscaleHeight,
        fastForwardInterval: fastForwardInterval,
        rewindInterval: rewindInterval,
        preloadArtwork: preloadArtwork,
        androidBrowsableRootExtras: androidBrowsableRootExtras,
      ),
    );
  }

  _JustAudioPlayer? _player;
  String? _playerId;

  _JustAudioBackgroundPlugin();

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    if (_playerId != null) {
      throw PlatformException(
        code: "error",
        message: "just_audio_background supports only a single player instance",
      );
    }
    _playerId = request.id;
    _player ??= _JustAudioPlayer(initRequest: request);
    return _player!;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    if (request.id == _playerId) {
      _playerId = null;
      final player = _player;
      _player = null;
      await player?.release();
    }
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
      DisposeAllPlayersRequest request) async {
    final player = _player;
    _player = null;
    await player?.release();
    return DisposeAllPlayersResponse();
  }
}

final _PlayerAudioHandler _playerAudioHandler = _PlayerAudioHandler();

class _JustAudioPlayer extends AudioPlayerPlatform {
  final InitRequest initRequest;
  final eventController =
      StreamController<PlaybackEventMessage>.broadcast(sync: true);
  final playerDataController =
      StreamController<PlayerDataMessage>.broadcast(sync: true);

  _JustAudioPlayer({required this.initRequest}) : super(initRequest.id) {
    eventController.onCancel = _playerAudioHandler.cancelStreamSubscriptions;
    _playerAudioHandler._initPlayer(initRequest);
    // XY Music 本地补丁：重建播放器实例时保留宿主已安装的媒体会话
    // 桥接（_MediaSessionBridge 套在 _playerAudioHandler 外层）。若此时
    // 无条件把 inner 换回裸 handler，通知栏切歌/收藏/播放模式按钮会
    // 静默失效，直到宿主下次点播兜底重装。仅当 inner 仍是初始占位
    // BaseAudioHandler 或裸 _PlayerAudioHandler 时才执行常规挂载。
    final currentInner = _audioHandler.inner;
    if (identical(currentInner, _playerAudioHandler) ||
        currentInner.runtimeType == BaseAudioHandler) {
      _audioHandler.inner = _playerAudioHandler;
    }
    _audioHandler.customEvent
        .whereType<PlaybackEventMessage>()
        .listen(eventController.add);
    _audioHandler.customEvent
        .whereType<_PlayingEvent>()
        .map((event) => event.playing)
        .distinct()
        .listen((playing) {
      playerDataController.add(PlayerDataMessage(playing: playing));
    });
  }

  PlaybackState get playbackState => _audioHandler.playbackState.nvalue!;

  Future<void> release() async {
    await _audioHandler.stop();
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      playerDataController.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) =>
      _playerAudioHandler.customLoad(request);

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    await _audioHandler.play();
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    await _audioHandler.pause();
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) =>
      _playerAudioHandler.customSetVolume(request);

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    await _playerAudioHandler.setSpeed(request.speed);
    return SetSpeedResponse();
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async {
    await _playerAudioHandler.customSetPitch(request);
    return SetPitchResponse();
  }

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
      SetSkipSilenceRequest request) async {
    await _playerAudioHandler.customSetSkipSilence(request);
    return SetSkipSilenceResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    await _audioHandler
        .setRepeatMode(AudioServiceRepeatMode.values[request.loopMode.index]);
    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
      SetShuffleModeRequest request) async {
    await _audioHandler.setShuffleMode(
        AudioServiceShuffleMode.values[request.shuffleMode.index]);
    return SetShuffleModeResponse();
  }

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
          SetShuffleOrderRequest request) =>
      _playerAudioHandler.customSetShuffleOrder(request);

  @override
  Future<SetWebCrossOriginResponse> setWebCrossOrigin(
      SetWebCrossOriginRequest request) async {
    _playerAudioHandler.customSetWebCrossOrigin(request);
    return SetWebCrossOriginResponse();
  }

  @override
  Future<SetWebSinkIdResponse> setWebSinkId(SetWebSinkIdRequest request) {
    _playerAudioHandler.customSetWebSinkId(request);
    throw SetWebSinkIdResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) =>
      _playerAudioHandler.customPlayerSeek(request);

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
          ConcatenatingInsertAllRequest request) =>
      _playerAudioHandler.customConcatenatingInsertAll(request);

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
          ConcatenatingRemoveRangeRequest request) =>
      _playerAudioHandler.customConcatenatingRemoveRange(request);

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
          ConcatenatingMoveRequest request) =>
      _playerAudioHandler.customConcatenatingMove(request);

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
          SetAndroidAudioAttributesRequest request) =>
      _playerAudioHandler.customSetAndroidAudioAttributes(request);

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
              SetAutomaticallyWaitsToMinimizeStallingRequest request) =>
          _playerAudioHandler
              .customSetAutomaticallyWaitsToMinimizeStalling(request);

  @override
  Future<AndroidEqualizerBandSetGainResponse> androidEqualizerBandSetGain(
          AndroidEqualizerBandSetGainRequest request) =>
      _playerAudioHandler.customAndroidEqualizerBandSetGain(request);

  @override
  Future<AndroidEqualizerGetParametersResponse> androidEqualizerGetParameters(
          AndroidEqualizerGetParametersRequest request) =>
      _playerAudioHandler.customAndroidEqualizerGetParameters(request);

  @override
  Future<AndroidLoudnessEnhancerSetTargetGainResponse>
      androidLoudnessEnhancerSetTargetGain(
              AndroidLoudnessEnhancerSetTargetGainRequest request) =>
          _playerAudioHandler
              .customAndroidLoudnessEnhancerSetTargetGain(request);

  @override
  Future<AudioEffectSetEnabledResponse> audioEffectSetEnabled(
          AudioEffectSetEnabledRequest request) =>
      _playerAudioHandler.customAudioEffectSetEnabled(request);

  @override
  Future<SetAllowsExternalPlaybackResponse> setAllowsExternalPlayback(
          SetAllowsExternalPlaybackRequest request) =>
      _playerAudioHandler.customSetAllowsExternalPlayback(request);

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
      setCanUseNetworkResourcesForLiveStreamingWhilePaused(
              SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest
                  request) =>
          _playerAudioHandler
              .customSetCanUseNetworkResourcesForLiveStreamingWhilePaused(
                  request);

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
          SetPreferredPeakBitRateRequest request) =>
      _playerAudioHandler.customSetPreferredPeakBitRate(request);
}

class _PlayerAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final _lock = Lock();
  var _playerCompleter = _ValueCompleter<AudioPlayerPlatform>();
  PlaybackEventMessage _justAudioEvent = PlaybackEventMessage(
    processingState: ProcessingStateMessage.idle,
    updateTime: DateTime.now(),
    updatePosition: Duration.zero,
    bufferedPosition: Duration.zero,
    duration: null,
    icyMetadata: null,
    currentIndex: null,
    androidAudioSessionId: null,
  );
  AudioSourceMessage? _source;
  bool _playing = false;
  double _speed = 1.0;
  _Seeker? _seeker;
  AudioServiceRepeatMode _repeatMode = AudioServiceRepeatMode.none;
  AudioServiceShuffleMode _shuffleMode = AudioServiceShuffleMode.none;
  List<int> _shuffleIndices = [];
  List<int> _shuffleIndicesInv = [];
  List<int> _effectiveIndices = [];
  List<int> _effectiveIndicesInv = [];

  Future<AudioPlayerPlatform> get _player => _playerCompleter.future;
  int? index;
  MediaItem? get currentMediaItem =>
      index != null && index! >= 0 && index! < currentQueue.length
          ? currentQueue[index!]
          : null;

  List<MediaItem> get currentQueue => queue.value;
  StreamSubscription<TrackInfo>? _trackInfoSubscription;

  Future<void> _initPlayer(InitRequest initRequest) =>
      _lock.synchronized(() async {
        // XY Music 本地补丁：外层播放器不能经管线挂 AndroidEqualizer——
        // 其激活请求发生在首次 load 之前，而 Java 侧均衡器要等 ExoPlayer
        // attach 到 audio session（首次 load/prepare）才创建，提前取参
        // getNumberOfBands 空指针会中断 setPlatform，播放链路卡死。
        //
        // 修复方式：在真实平台播放器初始化时注入原生均衡器，但必须提供
        // 非空的默认 parameters，避免 just_audio 在 setPlatform 阶段主动
        // 调用 getNumberOfBands / getBandLevelRange 等方法读取参数。
        // 首次 load 完成后 audio session 建立，再由 xyAndroidEqualizer
        // 门面按需读写真实参数。
        //
        // 默认参数用 5 频段常见值占位（±15dB 范围），仅用于避免空指针，
        // 真实设备参数由 readInfo() 首次 load 后刷新。
        final defaultBands = [
          AndroidEqualizerBandMessage(
            index: 0,
            lowerFrequency: 30,
            upperFrequency: 120,
            centerFrequency: 60,
            gain: 0,
          ),
          AndroidEqualizerBandMessage(
            index: 1,
            lowerFrequency: 120,
            upperFrequency: 460,
            centerFrequency: 230,
            gain: 0,
          ),
          AndroidEqualizerBandMessage(
            index: 2,
            lowerFrequency: 460,
            upperFrequency: 1800,
            centerFrequency: 910,
            gain: 0,
          ),
          AndroidEqualizerBandMessage(
            index: 3,
            lowerFrequency: 1800,
            upperFrequency: 7200,
            centerFrequency: 3600,
            gain: 0,
          ),
          AndroidEqualizerBandMessage(
            index: 4,
            lowerFrequency: 7200,
            upperFrequency: 20000,
            centerFrequency: 14000,
            gain: 0,
          ),
        ];
        final defaultParams = AndroidEqualizerParametersMessage(
          minDecibels: -15,
          maxDecibels: 15,
          bands: defaultBands,
        );
        // 设备能力探测：音频 HAL 不提供对应效果时（见
        // [xyAndroidEqualizerSupported]）不注入，否则原生构造 AudioEffect
        // 会抛未捕获异常直接杀死进程。
        final injectedAudioEffects = <AudioEffectMessage>[
          ...initRequest.androidAudioEffects.where((effect) =>
              effect is! AndroidEqualizerMessage &&
              effect is! AndroidLoudnessEnhancerMessage),
        ];
        if (xyAndroidEqualizerSupported) {
          injectedAudioEffects.add(
            AndroidEqualizerMessage(enabled: false, parameters: defaultParams),
          );
        }
        if (xyAndroidLoudnessEnhancerSupported) {
          // 响度增益（整体 dB）与均衡器同机制注入：默认停用 + 占位
          // 参数，宿主经 xyLoudnessEnhancer 门面在 load 后按需启用。
          injectedAudioEffects.add(
            AndroidLoudnessEnhancerMessage(enabled: false, targetGain: 0),
          );
        }
        final realInit = InitRequest(
          id: initRequest.id,
          audioLoadConfiguration: initRequest.audioLoadConfiguration,
          androidAudioEffects: injectedAudioEffects,
          darwinAudioEffects: initRequest.darwinAudioEffects,
          androidAudioOffloadPreferences:
              initRequest.androidAudioOffloadPreferences,
          androidOffloadSchedulingEnabled:
              initRequest.androidOffloadSchedulingEnabled,
          useLazyPreparation: initRequest.useLazyPreparation,
        );
        final player = await _platform.init(realInit);
        xyAndroidEqualizer._bind(player);
        xyLoudnessEnhancer._bind(player);
        _playerCompleter.complete(player);
        final playbackEventMessageStream = player.playbackEventMessageStream;
        _trackInfoSubscription = playbackEventMessageStream
            .map((event) {
              index = event.currentIndex ?? _justAudioEvent.currentIndex;
              _justAudioEvent = event;
              customEvent.add(event);
              _broadcastState();
              return event;
            })
            .map((event) => TrackInfo(event.currentIndex, event.duration))
            .distinct()
            .debounceTime(const Duration(milliseconds: 100))
            .map((track) {
              // Platform may send us a null duration on dispose, which we should
              // ignore.
              final currentMediaItem = this.currentMediaItem;
              if (currentMediaItem != null) {
                if (track.duration == null &&
                    currentMediaItem.duration != null) {
                  return TrackInfo(track.index, currentMediaItem.duration);
                }
              }
              return track;
            })
            .distinct()
            .listen((track) {
              if (currentMediaItem != null && index != null) {
                if (track.duration != currentMediaItem!.duration &&
                    (index! < queue.nvalue!.length && track.duration != null)) {
                  currentQueue[index!] =
                      currentQueue[index!].copyWith(duration: track.duration);
                  queue.add(currentQueue);
                }
                mediaItem.add(currentMediaItem!);
              }
            }, onError: (Object e, [StackTrace? st]) {});
      });

  Future<void> cancelStreamSubscriptions() async {
    final trackInfoSubscription = _trackInfoSubscription;
    if (trackInfoSubscription != null) {
      _trackInfoSubscription = null;
      await trackInfoSubscription.cancel();
    }
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    this.queue.add(queue);
    if (mediaItem.nvalue == null &&
        index != null &&
        index! >= 0 &&
        index! < queue.length) {
      mediaItem.add(queue[index!]);
    }
  }

  Future<LoadResponse> customLoad(LoadRequest request) async {
    _source = request.audioSourceMessage;
    _updateShuffleIndices();
    _updateQueue();
    final response = await (await _player).load(LoadRequest(
      audioSourceMessage: _source!,
      initialPosition: request.initialPosition,
      initialIndex: request.initialIndex,
    ));
    // XY Music 本地补丁：load 完成（audio session attach、原生均衡器就绪）
    // 后重放门面缓存的开关与增益——audio session 变化会重建原生均衡器
    // 并把增益复位为 0。异步执行不阻塞 load 返回。
    unawaited(xyAndroidEqualizer._onSourceLoaded());
    unawaited(xyLoudnessEnhancer._onSourceLoaded());
    return LoadResponse(duration: response.duration);
  }

  Future<SetVolumeResponse> customSetVolume(SetVolumeRequest request) async =>
      await (await _player).setVolume(request);

  Future<SetSpeedResponse> customSetSpeed(SetSpeedRequest request) async =>
      await (await _player).setSpeed(request);

  Future<SetPitchResponse> customSetPitch(SetPitchRequest request) async =>
      await (await _player).setPitch(request);

  Future<SetSkipSilenceResponse> customSetSkipSilence(
          SetSkipSilenceRequest request) async =>
      await (await _player).setSkipSilence(request);

  Future<SeekResponse> customPlayerSeek(SeekRequest request) async =>
      await (await _player).seek(request);

  Future<SetShuffleOrderResponse> customSetShuffleOrder(
      SetShuffleOrderRequest request) async {
    _source = request.audioSourceMessage;
    _updateShuffleIndices();
    _broadcastStateIfActive();
    return await (await _player).setShuffleOrder(SetShuffleOrderRequest(
      audioSourceMessage: _source!,
    ));
  }

  Future<SetWebCrossOriginResponse> customSetWebCrossOrigin(
      SetWebCrossOriginRequest request) async {
    return await (await _player).setWebCrossOrigin(request);
  }

  Future<SetWebSinkIdResponse> customSetWebSinkId(
      SetWebSinkIdRequest request) async {
    return await (await _player).setWebSinkId(request);
  }

  Future<ConcatenatingInsertAllResponse> customConcatenatingInsertAll(
      ConcatenatingInsertAllRequest request) async {
    final cat = _source!.findCat(request.id)!;
    cat.children.insertAll(request.index, request.children);
    cat.shuffleOrder
        .replaceRange(0, cat.shuffleOrder.length, request.shuffleOrder);
    _updateShuffleIndices();
    _broadcastStateIfActive();
    _updateQueue();
    return await (await _player).concatenatingInsertAll(request);
  }

  Future<ConcatenatingRemoveRangeResponse> customConcatenatingRemoveRange(
      ConcatenatingRemoveRangeRequest request) async {
    final cat = _source!.findCat(request.id)!;
    cat.children.removeRange(request.startIndex, request.endIndex);
    cat.shuffleOrder
        .replaceRange(0, cat.shuffleOrder.length, request.shuffleOrder);
    _updateShuffleIndices();
    _broadcastStateIfActive();
    _updateQueue();
    return await (await _player).concatenatingRemoveRange(request);
  }

  Future<ConcatenatingMoveResponse> customConcatenatingMove(
      ConcatenatingMoveRequest request) async {
    final cat = _source!.findCat(request.id)!;
    cat.children
        .insert(request.newIndex, cat.children.removeAt(request.currentIndex));
    cat.shuffleOrder
        .replaceRange(0, cat.shuffleOrder.length, request.shuffleOrder);
    _updateShuffleIndices();
    _broadcastStateIfActive();
    _updateQueue();
    return await (await _player).concatenatingMove(request);
  }

  Future<SetAndroidAudioAttributesResponse> customSetAndroidAudioAttributes(
          SetAndroidAudioAttributesRequest request) async =>
      await (await _player).setAndroidAudioAttributes(request);

  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      customSetAutomaticallyWaitsToMinimizeStalling(
              SetAutomaticallyWaitsToMinimizeStallingRequest request) async =>
          await (await _player)
              .setAutomaticallyWaitsToMinimizeStalling(request);

  Future<AndroidEqualizerBandSetGainResponse> customAndroidEqualizerBandSetGain(
          AndroidEqualizerBandSetGainRequest request) async =>
      await (await _player).androidEqualizerBandSetGain(request);

  Future<AndroidEqualizerGetParametersResponse>
      customAndroidEqualizerGetParameters(
              AndroidEqualizerGetParametersRequest request) async =>
          await (await _player).androidEqualizerGetParameters(request);

  Future<AndroidLoudnessEnhancerSetTargetGainResponse>
      customAndroidLoudnessEnhancerSetTargetGain(
              AndroidLoudnessEnhancerSetTargetGainRequest request) async =>
          await (await _player).androidLoudnessEnhancerSetTargetGain(request);

  Future<AudioEffectSetEnabledResponse> customAudioEffectSetEnabled(
          AudioEffectSetEnabledRequest request) async =>
      await (await _player).audioEffectSetEnabled(request);

  Future<SetAllowsExternalPlaybackResponse> customSetAllowsExternalPlayback(
          SetAllowsExternalPlaybackRequest request) async =>
      await (await _player).setAllowsExternalPlayback(request);

  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
      customSetCanUseNetworkResourcesForLiveStreamingWhilePaused(
              SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest
                  request) async =>
          await (await _player)
              .setCanUseNetworkResourcesForLiveStreamingWhilePaused(request);

  Future<SetPreferredPeakBitRateResponse> customSetPreferredPeakBitRate(
          SetPreferredPeakBitRateRequest request) async =>
      await (await _player).setPreferredPeakBitRate(request);

  void _updateQueue() {
    assert(sequence.every((source) => source.tag is MediaItem),
        'Error : When using just_audio_background, you should always set a MediaItem tag on every AudioSource. See AudioSource.uri documentation for more information.');
    queue.add(sequence.map((source) => source.tag as MediaItem).toList());
  }

  void _updateShuffleIndices() {
    _shuffleIndices = _source?.shuffleIndices ?? [];
    _effectiveIndices = _shuffleMode != AudioServiceShuffleMode.none
        ? _shuffleIndices
        : List.generate(sequence.length, (i) => i);
    _shuffleIndicesInv = List.filled(_effectiveIndices.length, 0);
    for (var i = 0; i < _effectiveIndices.length; i++) {
      _shuffleIndicesInv[_effectiveIndices[i]] = i;
    }
    _effectiveIndicesInv = _shuffleMode != AudioServiceShuffleMode.none
        ? _shuffleIndicesInv
        : List.generate(sequence.length, (i) => i);
  }

  List<IndexedAudioSourceMessage> get sequence => _source?.sequence ?? [];
  List<int> get shuffleIndices => _shuffleIndices;
  List<int> get effectiveIndices => _effectiveIndices;
  List<int> get shuffleIndicesInv => _shuffleIndicesInv;
  List<int> get effectiveIndicesInv => _effectiveIndicesInv;
  int? get nextIndex => getRelativeIndex(1);
  int? get previousIndex => getRelativeIndex(-1);
  bool get hasNext => nextIndex != null;
  bool get hasPrevious => previousIndex != null;

  int? getRelativeIndex(int offset) {
    if (currentQueue.isEmpty || index == null) return null;
    if (_repeatMode == AudioServiceRepeatMode.one) return index;
    if (effectiveIndices.isEmpty) return null;
    if (index! >= effectiveIndicesInv.length) return null;
    final invPos = effectiveIndicesInv[index!];
    var newInvPos = invPos + offset;
    if (newInvPos >= effectiveIndices.length || newInvPos < 0) {
      if (_repeatMode == AudioServiceRepeatMode.all) {
        newInvPos %= effectiveIndices.length;
      } else {
        return null;
      }
    }
    final result = effectiveIndices[newInvPos];
    return result;
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    (await _player).seek(SeekRequest(position: Duration.zero, index: index));
  }

  @override
  Future<void> skipToNext() async {
    if (hasNext) {
      await skipToQueueItem(nextIndex!);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (hasPrevious) {
      await skipToQueueItem(previousIndex!);
    }
  }

  @override
  Future<void> play() async {
    if (_justAudioEvent.processingState == ProcessingStateMessage.completed) {
      await skipToQueueItem(0);
    }
    if (!_playing) {
      _updatePosition();
      customEvent.add(_PlayingEvent(_playing = true));
      _broadcastState();
      await (await _player).play(PlayRequest());
    }
  }

  @override
  Future<void> pause() async {
    _updatePosition();
    customEvent.add(_PlayingEvent(_playing = false));
    _broadcastState();
    await (await _player).pause(PauseRequest());
  }

  void _updatePosition() {
    _justAudioEvent = _justAudioEvent.copyWith(
      updatePosition: currentPosition,
      updateTime: DateTime.now(),
    );
  }

  @override
  Future<void> seek(Duration position) async =>
      await (await _player).seek(SeekRequest(position: position));

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await (await _player).setSpeed(SetSpeedRequest(speed: speed));
  }

  @override
  Future<void> fastForward() =>
      _seekRelative(AudioService.config.fastForwardInterval);

  @override
  Future<void> rewind() => _seekRelative(-AudioService.config.rewindInterval);

  @override
  Future<void> seekForward(bool begin) async => _seekContinuously(begin, 1);

  @override
  Future<void> seekBackward(bool begin) async => _seekContinuously(begin, -1);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _repeatMode = repeatMode;
    _broadcastStateIfActive();
    (await _player).setLoopMode(SetLoopModeRequest(
        loopMode: LoopModeMessage
            .values[min(LoopModeMessage.values.length - 1, repeatMode.index)]));
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    _shuffleMode = shuffleMode;
    _updateShuffleIndices();
    _broadcastStateIfActive();
    (await _player).setShuffleMode(SetShuffleModeRequest(
        shuffleMode: ShuffleModeMessage.values[
            min(ShuffleModeMessage.values.length - 1, shuffleMode.index)]));
  }

  @override
  Future<void> stop() => _lock.synchronized(() async {
        final player = _playerCompleter.value;
        if (player == null) return;
        _updatePosition();
        customEvent.add(_PlayingEvent(_playing = false));
        _justAudioEvent = _justAudioEvent.copyWith(
          processingState: ProcessingStateMessage.idle,
        );
        _broadcastState();
        _playerCompleter = _ValueCompleter<AudioPlayerPlatform>();
        await _platform.disposePlayer(DisposePlayerRequest(id: player.id));
      });

  Duration get currentPosition {
    if (_playing &&
        _justAudioEvent.processingState == ProcessingStateMessage.ready) {
      return Duration(
          milliseconds: (_justAudioEvent.updatePosition.inMilliseconds +
                  ((DateTime.now().millisecondsSinceEpoch -
                          _justAudioEvent.updateTime.millisecondsSinceEpoch) *
                      _speed))
              .toInt());
    } else {
      return _justAudioEvent.updatePosition;
    }
  }

  /// Jumps away from the current position by [offset].
  Future<void> _seekRelative(Duration offset) async {
    var newPosition = currentPosition + offset;
    // Make sure we don't jump out of bounds.
    if (newPosition < Duration.zero) newPosition = Duration.zero;
    if (newPosition > currentMediaItem!.duration!) {
      newPosition = currentMediaItem!.duration!;
    }
    // Perform the jump via a seek.
    await (await _player).seek(SeekRequest(position: newPosition));
  }

  /// Begins or stops a continuous seek in [direction]. After it begins it will
  /// continue seeking forward or backward by 10 seconds within the audio, at
  /// intervals of 1 second in app time.
  void _seekContinuously(bool begin, int direction) {
    _seeker?.stop();
    if (begin) {
      _seeker = _Seeker(this, Duration(seconds: 10 * direction),
          const Duration(seconds: 1), currentMediaItem!.duration!)
        ..start();
    }
  }

  void _broadcastStateIfActive() {
    if (_justAudioEvent.processingState != ProcessingStateMessage.idle) {
      _broadcastState();
    }
  }

  /// Broadcasts the current state to all clients.
  void _broadcastState() {
    final controls = [
      if (hasPrevious) MediaControl.skipToPrevious,
      if (_playing) MediaControl.pause else MediaControl.play,
      if (hasNext) MediaControl.skipToNext,
    ];
    // XY Music 本地补丁：通知栏不再放停止/桌面歌词等按钮。系统媒体
    // 通知由宿主 _MediaSessionBridge 完全重建控件列表（收藏/上一首/
    // 播放暂停/下一首/播放模式五键布局）；未装桥接时原生层也会强制
    // 置位切歌 action bits（AudioService.java），保证 Android 13+
    // 系统媒体卡片仍显示上一首/下一首。
    playbackState.add(playbackState.nvalue!.copyWith(
      controls: controls,
      systemActions: {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: List.generate(
        controls.length,
        (i) => i,
      ),
      processingState: _justAudioEvent.errorCode != null
          ? AudioProcessingState.error
          : const {
                ProcessingStateMessage.idle: AudioProcessingState.idle,
                ProcessingStateMessage.loading: AudioProcessingState.loading,
                ProcessingStateMessage.buffering:
                    AudioProcessingState.buffering,
                ProcessingStateMessage.ready: AudioProcessingState.ready,
                ProcessingStateMessage.completed:
                    AudioProcessingState.completed,
              }[_justAudioEvent.processingState] ??
              AudioProcessingState.idle,
      playing: _playing &&
          !{ProcessingStateMessage.idle, ProcessingStateMessage.completed}
              .contains(_justAudioEvent.processingState),
      updatePosition: currentPosition,
      bufferedPosition: _justAudioEvent.bufferedPosition,
      speed: _speed,
      queueIndex: _justAudioEvent.currentIndex,
      errorCode: _justAudioEvent.errorCode,
      errorMessage: _justAudioEvent.errorMessage,
    ));
  }
}

class _Seeker {
  final _PlayerAudioHandler handler;
  final Duration positionInterval;
  final Duration stepInterval;
  final Duration duration;
  bool _running = false;

  _Seeker(
    this.handler,
    this.positionInterval,
    this.stepInterval,
    this.duration,
  );

  Future<void> start() async {
    _running = true;
    while (_running) {
      Duration newPosition = handler.currentPosition + positionInterval;
      if (newPosition < Duration.zero) newPosition = Duration.zero;
      if (newPosition > duration) newPosition = duration;
      handler.seek(newPosition);
      await Future<dynamic>.delayed(stepInterval);
    }
  }

  void stop() {
    _running = false;
  }
}

extension _PlaybackEventMessageExtension on PlaybackEventMessage {
  PlaybackEventMessage copyWith({
    ProcessingStateMessage? processingState,
    DateTime? updateTime,
    Duration? updatePosition,
    Duration? bufferedPosition,
    Duration? duration,
    IcyMetadataMessage? icyMetadata,
    int? currentIndex,
    int? androidAudioSessionId,
  }) =>
      PlaybackEventMessage(
        processingState: processingState ?? this.processingState,
        updateTime: updateTime ?? this.updateTime,
        updatePosition: updatePosition ?? this.updatePosition,
        bufferedPosition: bufferedPosition ?? this.bufferedPosition,
        duration: duration ?? this.duration,
        icyMetadata: icyMetadata ?? this.icyMetadata,
        currentIndex: currentIndex ?? this.currentIndex,
        androidAudioSessionId:
            androidAudioSessionId ?? this.androidAudioSessionId,
      );
}

extension AudioSourceExtension on AudioSourceMessage {
  ConcatenatingAudioSourceMessage? findCat(String id) {
    final self = this;
    if (self is ConcatenatingAudioSourceMessage) {
      if (self.id == id) return self;
      return self.children
          .map((child) => child.findCat(id))
          .firstWhere((cat) => cat != null, orElse: () => null);
    } else if (self is LoopingAudioSourceMessage) {
      return self.child.findCat(id);
    } else {
      return null;
    }
  }

  List<IndexedAudioSourceMessage> get sequence {
    final self = this;
    if (self is ConcatenatingAudioSourceMessage) {
      return self.children.expand((child) => child.sequence).toList();
    } else if (self is LoopingAudioSourceMessage) {
      return List.generate(self.count, (i) => self.child.sequence)
          .expand((sequence) => sequence)
          .toList();
    } else {
      return [self as IndexedAudioSourceMessage];
    }
  }

  List<int> get shuffleIndices {
    final self = this;
    if (self is ConcatenatingAudioSourceMessage) {
      var offset = 0;
      final childIndicesList = <List<int>>[];
      for (final child in self.children) {
        final childIndices =
            child.shuffleIndices.map((i) => i + offset).toList();
        childIndicesList.add(childIndices);
        offset += childIndices.length;
      }
      final indices = <int>[];
      for (final index in self.shuffleOrder) {
        indices.addAll(childIndicesList[index]);
      }
      return indices;
    } else if (self is LoopingAudioSourceMessage) {
      // TODO: This should combine indices of the children, like ConcatenatingAudioSource.
      // Also should be fixed in the plugin frontend.
      return List.generate(self.count, (i) => i);
    } else {
      return [0];
    }
  }
}

@immutable
class TrackInfo {
  final int? index;
  final Duration? duration;

  const TrackInfo(this.index, this.duration);

  @override
  bool operator ==(Object other) =>
      other is TrackInfo && index == other.index && duration == other.duration;

  @override
  int get hashCode => Object.hash(index, duration);

  @override
  String toString() => '($index, $duration)';
}

/// Backwards compatible extensions on rxdart's ValueStream
extension _ValueStreamExtension<T> on ValueStream<T> {
  /// Backwards compatible version of valueOrNull.
  T? get nvalue => hasValue ? value : null;
}

class _PlayingEvent {
  final bool playing;

  const _PlayingEvent(this.playing);
}

class _ValueCompleter<T> {
  final _completer = Completer<T>();
  T? value;

  void complete(T value) {
    this.value = value;
    _completer.complete(value);
  }

  Future<T> get future => _completer.future;
}
