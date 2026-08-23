import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../src/favorites/favorites_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/recognize/recognize_service.dart';
import '../../src/recognize/system_audio_capture.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/top_notice.dart';

enum _RecognizeStatus { idle, recording, recognizing, success, failed }

class RecognizePage extends ConsumerStatefulWidget {
  const RecognizePage({super.key});

  @override
  ConsumerState<RecognizePage> createState() => _RecognizePageState();
}

class _RecognizePageState extends ConsumerState<RecognizePage>
    with SingleTickerProviderStateMixin {
  static const _microphonePreference = 'recognize_use_microphone_v1';
  static const _systemPreference = 'recognize_use_system_audio_v1';

  final AudioRecorder _recorder = AudioRecorder();
  final SystemAudioCapture _systemCapture = const SystemAudioCapture();
  final List<int> _microphonePcm = [];
  final List<int> _systemPcm = [];
  StreamSubscription<Uint8List>? _microphoneSubscription;
  StreamSubscription<Uint8List>? _systemSubscription;
  Timer? _timer;
  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  _RecognizeStatus _status = _RecognizeStatus.idle;
  List<RecognizeMatch> _matches = const [];
  String _errorMessage = '';
  int _recordingSeconds = 0;
  bool _finishing = false;
  bool _useMicrophone = true;
  bool _useSystemAudio = false;
  bool _systemAudioSupported = false;
  int _operationId = 0;

  bool get _isBusy =>
      _status == _RecognizeStatus.recording ||
      _status == _RecognizeStatus.recognizing;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSourcePreferences());
  }

  Future<void> _loadSourcePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final supported = Platform.isAndroid && await _systemCapture.isSupported();
    if (!mounted) return;
    setState(() {
      _useMicrophone = prefs.getBool(_microphonePreference) ?? true;
      _useSystemAudio =
          supported && (prefs.getBool(_systemPreference) ?? false);
      _systemAudioSupported = supported;
      if (!_useMicrophone && !_useSystemAudio) _useMicrophone = true;
    });
  }

  @override
  void dispose() {
    _operationId++;
    _timer?.cancel();
    unawaited(_disposeCapture());
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _disposeCapture() async {
    await _stopCaptureSources();
    try {
      await cancelRecognizeSystemAudio();
    } catch (_) {}
    try {
      await _recorder.dispose();
    } catch (_) {}
  }

  Future<void> _startRecognition() async {
    if (_isBusy) return;
    if (!_useMicrophone && !_useSystemAudio) {
      _fail('请至少选择一种识别声音来源');
      return;
    }
    final operationId = ++_operationId;
    _microphonePcm.clear();
    _systemPcm.clear();
    _matches = const [];
    _errorMessage = '';
    _recordingSeconds = 0;
    _finishing = false;
    setState(() => _status = _RecognizeStatus.recording);
    try {
      if (_useSystemAudio) {
        if (!_systemAudioSupported) {
          throw Exception('系统声音识别需要 Android 10 或更高版本');
        }
        _systemSubscription = _systemCapture.audioStream.listen(
          _systemPcm.addAll,
          onError: (Object error) =>
              _abortWithError(operationId, '系统声音采集失败：$error'),
        );
        final granted = await _systemCapture.start().timeout(
          const Duration(seconds: 30),
        );
        if (!granted) throw Exception('未授予系统声音录制权限');
      }

      if (_useMicrophone) {
        final allowed = await _recorder.hasPermission().timeout(
          const Duration(seconds: 15),
        );
        if (!allowed) throw Exception('需要麦克风权限才能识别麦克风声音');
        final stream = await _recorder
            .startStream(
              const RecordConfig(
                encoder: AudioEncoder.pcm16bits,
                sampleRate: recognizeCaptureSampleRate,
                numChannels: 1,
                autoGain: true,
              ),
            )
            .timeout(const Duration(seconds: 10));
        _microphoneSubscription = stream.listen(
          _microphonePcm.addAll,
          onError: (Object error) =>
              _abortWithError(operationId, '麦克风采集失败：$error'),
        );
      }

      if (!mounted || operationId != _operationId) {
        await _stopCaptureSources();
        return;
      }
      _pulseController.repeat(reverse: true);
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted ||
            operationId != _operationId ||
            _status != _RecognizeStatus.recording) {
          return;
        }
        setState(() => _recordingSeconds++);
        if (_recordingSeconds >= recognizeMaxSeconds) {
          unawaited(_finishRecognition(operationId));
        }
      });
    } on TimeoutException {
      await _stopCaptureSources();
      _failFor(operationId, '启动声音采集超时，请重试');
    } catch (error) {
      await _stopCaptureSources();
      _failFor(operationId, error.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _finishRecognition(int operationId) async {
    if (_finishing ||
        operationId != _operationId ||
        _status != _RecognizeStatus.recording) {
      return;
    }
    _finishing = true;
    _timer?.cancel();
    _pulseController.stop();
    if (mounted) setState(() => _status = _RecognizeStatus.recognizing);
    try {
      await _stopCaptureSources();
      if (!mounted || operationId != _operationId) return;
      final pcm = prepareRecognitionPcm(
        microphone: _useMicrophone ? _microphonePcm : const [],
        systemAudio: _useSystemAudio ? _systemPcm : const [],
      );
      if (pcm.length < recognizeTargetSampleRate * 2 * 3) {
        throw Exception('有效录音不足 3 秒，请重试');
      }
      if (pcm16Peak(pcm) < 96) {
        throw Exception('没有检测到可识别的声音，请调高音量后重试');
      }
      final matches = await recognizePcm(pcm);
      if (!mounted || operationId != _operationId) return;
      setState(() {
        _matches = matches;
        if (matches.isEmpty) {
          _status = _RecognizeStatus.failed;
          _errorMessage = '未识别到歌曲，请靠近声源后重试';
        } else {
          _status = _RecognizeStatus.success;
        }
      });
    } catch (error) {
      if (!mounted || operationId != _operationId) return;
      final message = error.toString().replaceFirst('Exception: ', '');
      if (!message.contains(recognizeCancelledMessage)) {
        _failFor(operationId, message);
      }
    } finally {
      if (operationId == _operationId) _finishing = false;
    }
  }

  void _cancelRecognition() {
    if (!_isBusy) return;
    _operationId++;
    _timer?.cancel();
    _pulseController.stop();
    _finishing = false;
    if (mounted) {
      setState(() {
        _status = _RecognizeStatus.idle;
        _recordingSeconds = 0;
      });
    }
    unawaited(_stopCaptureSources());
    unawaited(cancelRecognizeSystemAudio());
  }

  Future<void> _stopCaptureSources() async {
    _timer?.cancel();
    final microphoneSubscription = _microphoneSubscription;
    _microphoneSubscription = null;
    final systemSubscription = _systemSubscription;
    _systemSubscription = null;
    await Future.wait([
      _ignoreCaptureError(_recorder.stop()),
      if (microphoneSubscription != null)
        _ignoreCaptureError(microphoneSubscription.cancel()),
      _ignoreCaptureError(_systemCapture.stop()),
      if (systemSubscription != null)
        _ignoreCaptureError(systemSubscription.cancel()),
    ]);
  }

  Future<void> _ignoreCaptureError(Future<dynamic> operation) async {
    try {
      await operation.timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  void _abortWithError(int operationId, String message) {
    if (operationId != _operationId) return;
    _operationId++;
    _timer?.cancel();
    _pulseController.stop();
    unawaited(_stopCaptureSources());
    _fail(message);
  }

  Future<void> _setSource({bool? microphone, bool? systemAudio}) async {
    final nextMicrophone = microphone ?? _useMicrophone;
    final nextSystem = systemAudio ?? _useSystemAudio;
    if (!nextMicrophone && !nextSystem) {
      XyNotice.show(context, message: '请至少保留一种声音来源');
      return;
    }
    if (nextSystem && !_systemAudioSupported) {
      XyNotice.show(
        context,
        message: '系统声音识别需要 Android 10 或更高版本',
        type: XyNoticeType.warning,
      );
      return;
    }
    setState(() {
      _useMicrophone = nextMicrophone;
      _useSystemAudio = nextSystem;
    });
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setBool(_microphonePreference, nextMicrophone),
      prefs.setBool(_systemPreference, nextSystem),
    ]);
  }

  void _failFor(int operationId, String message) {
    if (operationId != _operationId) return;
    _fail(message);
  }

  void _fail(String message) {
    _timer?.cancel();
    _pulseController.stop();
    if (!mounted) return;
    setState(() {
      _status = _RecognizeStatus.failed;
      _errorMessage = message;
    });
  }

  Future<void> _play(int index) async {
    final songs = _matches.map((match) => match.song).toList();
    final playback = ref.read(libraryProvider.notifier).playList(songs, index);
    if (mounted) unawaited(context.push<void>('/player'));
    await playback;
  }

  Future<void> _toggleFavorite(RecognizeMatch match) async {
    final added = await ref
        .read(favoritesProvider.notifier)
        .toggle(
          match.song.path,
          song: FavoriteSongSnapshot.fromSong(match.song),
        );
    if (!mounted) return;
    XyNotice.show(
      context,
      message: added ? '已收藏' : '已取消收藏',
      duration: const Duration(seconds: 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('听歌识曲'),
        actions: [
          if (_isBusy)
            TextButton(onPressed: _cancelRecognition, child: const Text('取消')),
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        child: _status == _RecognizeStatus.success
            ? _buildResults()
            : _buildRecognizer(),
      ),
    );
  }

  Widget _buildRecognizer() {
    final scheme = Theme.of(context).colorScheme;
    final recording = _status == _RecognizeStatus.recording;
    final recognizing = _status == _RecognizeStatus.recognizing;
    final failed = _status == _RecognizeStatus.failed;
    final statusText = switch (_status) {
      _RecognizeStatus.recording =>
        '正在聆听… $_recordingSeconds/$recognizeMaxSeconds 秒',
      _RecognizeStatus.recognizing => '正在识别… 最长 20 秒',
      _RecognizeStatus.failed => _errorMessage,
      _ => '点击麦克风开始识别',
    };
    return Center(
      key: const ValueKey('recognizer'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 116),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ScaleTransition(
              scale: Tween(begin: 1.0, end: 1.08).animate(
                CurvedAnimation(
                  parent: _pulseController,
                  curve: Curves.easeInOut,
                ),
              ),
              child: SizedBox(
                width: 112,
                height: 112,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    backgroundColor: recording
                        ? scheme.primary
                        : scheme.primaryContainer,
                    foregroundColor: recording
                        ? scheme.onPrimary
                        : scheme.onPrimaryContainer,
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: recording || recognizing
                      ? _cancelRecognition
                      : _startRecognition,
                  child: recognizing
                      ? const SizedBox(
                          width: 34,
                          height: 34,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        )
                      : Icon(
                          recording ? Icons.stop_rounded : Icons.mic_rounded,
                          size: 42,
                        ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              statusText,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: failed ? scheme.error : scheme.onSurface,
              ),
            ),
            const SizedBox(height: 22),
            _ListeningWaves(active: recording),
            const SizedBox(height: 26),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Column(
                children: [
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    secondary: const Icon(Icons.volume_up_outlined),
                    title: const Text('识别系统声音'),
                    subtitle: const Text('采集手机正在播放的声音'),
                    value: _useSystemAudio,
                    onChanged: _isBusy || !_systemAudioSupported
                        ? null
                        : (selected) => _setSource(systemAudio: selected),
                  ),
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    secondary: const Icon(Icons.mic_none_rounded),
                    title: const Text('识别麦克风声音'),
                    subtitle: const Text('采集手机周围的声音'),
                    value: _useMicrophone,
                    onChanged: _isBusy
                        ? null
                        : (selected) => _setSource(microphone: selected),
                  ),
                ],
              ),
            ),
            if (!_systemAudioSupported) ...[
              const SizedBox(height: 8),
              Text(
                '系统声音采集仅支持 Android 10 及以上版本',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 24),
            Text(
              _useSystemAudio && _useMicrophone
                  ? '同时录制系统与麦克风声音 10 秒，混音后识别'
                  : _useSystemAudio
                  ? '录制系统正在播放的声音 10 秒后识别'
                  : '使用麦克风聆听 10 秒\n请将手机靠近正在播放音乐的声源',
              textAlign: TextAlign.center,
              style: TextStyle(
                height: 1.6,
                fontSize: 13,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    final favorites = ref.watch(favoritesProvider);
    return Column(
      key: const ValueKey('results'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '识别到 ${_matches.length} 首匹配',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                onPressed: () => setState(() {
                  _status = _RecognizeStatus.idle;
                  _matches = const [];
                }),
                icon: const Icon(Icons.refresh_rounded, size: 19),
                label: const Text('重新识别'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 112),
            itemCount: _matches.length,
            separatorBuilder: (_, _) => const SizedBox(height: 4),
            itemBuilder: (context, index) {
              final match = _matches[index];
              final song = match.song;
              final favorite = favorites.contains(song.path);
              return Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  onTap: () => _play(index),
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 9,
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 48,
                          child: Column(
                            children: [
                              Text(
                                '${(match.confidence * 100).round()}%',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const Text('匹配度', style: TextStyle(fontSize: 10)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        CoverImage(
                          songPath: song.path,
                          imageUrl: song.coverUrl,
                          width: 58,
                          height: 58,
                          radius: 12,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${song.artist} · ${song.album}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: favorite ? '取消收藏' : '收藏',
                          onPressed: () => _toggleFavorite(match),
                          icon: Icon(
                            favorite ? Icons.favorite : Icons.favorite_border,
                            color: const Color(0xFFEC4141),
                          ),
                        ),
                        IconButton(
                          tooltip: '播放',
                          onPressed: () => _play(index),
                          icon: const Icon(Icons.play_arrow_rounded),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ListeningWaves extends StatefulWidget {
  const _ListeningWaves({required this.active});

  final bool active;

  @override
  State<_ListeningWaves> createState() => _ListeningWavesState();
}

class _ListeningWavesState extends State<_ListeningWaves>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_ListeningWaves oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    if (widget.active) {
      _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: 34,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(7, (index) {
            final phase = ((_controller.value + index * .13) % 1.0);
            final height = widget.active
                ? 7 + (1 - (phase * 2 - 1).abs()) * 27
                : 7.0;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Container(
                width: 4,
                height: height,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: widget.active ? 1 : .28),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
