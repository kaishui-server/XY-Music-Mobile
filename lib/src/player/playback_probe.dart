import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../logging/app_log_store.dart';

/// 久播卡死探针（小米澎湃 HyperOS 等机型长时间播放后无声卡住）。
///
/// 目的：区分卡死发生在「媒体层」（解码/网络/ExoPlayer，表现为
/// processingState 卡在 loading/buffering）还是「音频输出层」
/// （AudioTrack/AAudio 停摆：进度停滞但原生 isMusicActive=false），
/// 以及是否为「主 isolate 冻结」（采样定时器自身长时间不触发）。
///
/// 采集策略：默认只记录异常，避免污染日志；
/// - 每 5 分钟一条紧凑心跳，保证永久卡死时日志里有卡死前最近的现场；
/// - 命中异常时把内存里最近 12 次采样（约 1 分钟）整段落盘，还原过程。
class PlaybackProbe {
  PlaybackProbe({required this.sample, this.interval = const Duration(seconds: 5)});

  /// 采样回调：返回当前播放快照；返回 null 表示当前无歌曲/不应采样。
  final PlaybackProbeSample? Function() sample;

  /// 采样间隔。
  final Duration interval;

  static const _channel = MethodChannel('com.xymusic.mobile/device_info');
  static const _ringSize = 12;
  static const _stallSamples = 3; // 连续 3 次（约 15s）未推进判为停滞
  static const _heartbeatTicks = 60; // 每 60 次采样（约 5 分钟）打一条心跳
  static const _anomalyCooldown = Duration(minutes: 2);

  Timer? _timer;
  final List<PlaybackProbeSample> _ring = <PlaybackProbeSample>[];
  int _ticks = 0;
  int _stallStreak = 0;
  PlaybackProbeSample? _last;
  DateTime _lastAnomalyLog = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastTickWall = DateTime.now();
  int _seq = 0;

  void start() {
    _timer?.cancel();
    _lastTickWall = DateTime.now();
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    final now = DateTime.now();
    // 采样定时器自身的调度间隙：远超间隔说明主 isolate 被长时间阻塞
    // （UI 冻结类卡死）。先记录冻结事实，再继续正常采样。
    final gapMs = now.difference(_lastTickWall).inMilliseconds;
    _lastTickWall = now;
    final expectedMs = interval.inMilliseconds;
    if (gapMs > expectedMs * 2 + 1500) {
      _log(
        '[PROBE] 主线程冻结 ${gapMs}ms（采样间隔应为 ${expectedMs}ms）',
        force: true,
      );
    }

    final current = sample();
    if (current == null) {
      _last = null;
      _stallStreak = 0;
      return;
    }

    _seq++;
    _ring.add(current);
    if (_ring.length > _ringSize) _ring.removeAt(0);

    // 进度停滞判定：playing 且位置较上次推进不足 300ms。
    final prev = _last;
    if (current.playing && prev != null && current.positionMs - prev.positionMs < 300) {
      _stallStreak++;
    } else {
      _stallStreak = 0;
    }
    _last = current;

    final native = await _nativeAudio();
    if (_stallStreak >= _stallSamples) {
      _reportStall(current, native, gapMs);
    } else if (_ticks % _heartbeatTicks == 0) {
      _log('[PROBE] 心跳 #$_seq $current $native');
    }
    _ticks++;
  }

  /// 命中停滞：按原生输出层是否出声给出定性结论 + 整段过程快照。
  void _reportStall(
    PlaybackProbeSample current,
    String native,
    int gapMs,
  ) {
    final verdict = _verdict(current, native);
    _log(
      '[PROBE] 进度停滞 $verdict | 当前 $current | 原生 $native | 采样间隙 ${gapMs}ms',
      force: true,
    );
    if (_ring.isEmpty) return;
    final trace = _ring.map((s) => '  #${s.positionMs}ms ${s.processingState} '
        'playing=${s.playing} dsp=${s.dspActive}/${s.dspPlaying}').join('\n');
    _log('[PROBE] 停滞前过程（最近 ${_ring.length} 次采样）：\n$trace', force: true);
  }

  String _verdict(PlaybackProbeSample s, String native) {
    if (s.processingState == 'loading' || s.processingState == 'buffering') {
      return '→ 判定媒体层停滞（processingState=${s.processingState}，解码/网络未就绪）';
    }
    if (s.dspActive && s.dspPlaying) {
      return '→ 判定疑似 DSP/AAudio 管线卡住（进度停滞但管线标记为播放中）';
    }
    if (native.contains('isMusicActive=false')) {
      return '→ 判定疑似音频输出层失活（进度停滞且系统无音乐输出，AudioTrack/AAudio 停摆）';
    }
    return '→ 进展停滞但系统仍有音乐输出（疑似上报/时钟错位，非输出层故障）';
  }

  /// 原生音频层信号：Android 才有意义，失败时返回占位串不抛错。
  Future<String> _nativeAudio() async {
    if (!Platform.isAndroid) return 'isMusicActive=n/a';
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'audioProbe',
      );
      if (result == null) return 'isMusicActive=n/a';
      final active = result['isMusicActive'];
      final volume = result['musicVolume'];
      final max = result['musicVolumeMax'];
      final mode = result['mode'];
      return 'isMusicActive=$active musicVol=$volume/$max mode=$mode';
    } catch (_) {
      return 'isMusicActive=n/a(探测失败)';
    }
  }

  void _log(String message, {bool force = false}) {
    if (!force) {
      // 心跳本身不设冷却；异常按冷却窗口限流，避免连续卡死刷屏。
      AppLogStore.instance.add(message);
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastAnomalyLog) < _anomalyCooldown) return;
    _lastAnomalyLog = now;
    AppLogStore.instance.add(message);
  }
}

/// 一次采样快照。
class PlaybackProbeSample {
  const PlaybackProbeSample({
    required this.positionMs,
    required this.bufferedMs,
    required this.durationMs,
    required this.processingState,
    required this.playing,
    required this.dspActive,
    required this.dspPlaying,
  });

  final int positionMs;
  final int bufferedMs;
  final int durationMs;

  /// just_audio 的处理状态：idle/loading/buffering/ready/completed。
  final String processingState;
  final bool playing;

  /// 高级音效 DSP 管线（Rust AAudio 共享模式）是否在接管出声。
  final bool dspActive;
  final bool dspPlaying;

  @override
  String toString() =>
      'pos=${positionMs}ms buf=${bufferedMs}ms dur=${durationMs}ms '
      'state=$processingState playing=$playing dsp=$dspActive/$dspPlaying';
}