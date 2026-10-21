// beat_detector.dart — 节拍检测（移植自 sonic-topography src/lib/
// beatDetector.ts + kickEnvelope.ts，1:1 对齐算法常量与流程）。
//
// 输入为每帧频段能量数组（0..1），内部在 Deep/Classic/Punch/Wide 四个
// 低频窗口里自动挑选与当前音乐最匹配的窗口，做谱通量（flux）峰值检测，
// 输出 kick 包络供可视化场景驱动「脉冲触发」形变。

import 'dart:math' as math;

/// 频段窗口（对应原版 frequencyData 低段 bin 索引；Dart 侧传入的是
/// 64 段对数频谱的低段切片，索引语义一致）。
class BeatWindow {
  final String name;
  final int start;
  final int end;
  const BeatWindow(this.name, this.start, this.end);
}

const List<BeatWindow> kBeatWindows = [
  BeatWindow('Deep', 0, 2),
  BeatWindow('Classic', 1, 4),
  BeatWindow('Punch', 2, 6),
  BeatWindow('Wide', 0, 7),
];

class BeatDetectorState {
  int activeWindowIndex;
  List<double> windowScores;
  List<double> previousWindowLevels;
  List<double> fluxHistory;
  int fluxHistoryIndex;
  double smoothedFlux;
  double previousSmoothedFlux;
  double cooldownRemaining;
  KickEnvelopeState kickEnvelopeState;
  BeatDetectorState({
    this.activeWindowIndex = 1,
    required this.windowScores,
    required this.previousWindowLevels,
    required this.fluxHistory,
    this.fluxHistoryIndex = 0,
    this.smoothedFlux = 0,
    this.previousSmoothedFlux = 0,
    this.cooldownRemaining = 0,
    required this.kickEnvelopeState,
  });
}

class BeatDetectorOutput {
  final BeatDetectorState state;
  final double kickLevel;
  final double kickFlux;
  final double kickThreshold;
  final bool kickOnset;
  final double kickEnvelope;
  final double kickConfidence;
  final BeatWindow activeWindow;
  const BeatDetectorOutput({
    required this.state,
    required this.kickLevel,
    required this.kickFlux,
    required this.kickThreshold,
    required this.kickOnset,
    required this.kickEnvelope,
    required this.kickConfidence,
    required this.activeWindow,
  });
}

/// 灵敏度 0..100 映射出的检测参数（原版 deriveBeatDetectorParams）。
class BeatDetectorParams {
  final double thresholdStdDevGain;
  final double thresholdFloor;
  final double minTriggerFlux;
  const BeatDetectorParams({
    required this.thresholdStdDevGain,
    required this.thresholdFloor,
    required this.minTriggerFlux,
  });
}

const int _fluxHistorySize = 90;
const double _windowScoreDecay = 0.965;
const double _fluxSmoothing = 0.35;
const double _cooldownSeconds = 0.12;
const double _defaultSensitivity = 100;

const _strictParams = BeatDetectorParams(
  thresholdStdDevGain: 2.6,
  thresholdFloor: 0.05,
  minTriggerFlux: 0.07,
);
const _defaultParams = BeatDetectorParams(
  thresholdStdDevGain: 1.8,
  thresholdFloor: 0.028,
  minTriggerFlux: 0.045,
);
const _sensitiveParams = BeatDetectorParams(
  thresholdStdDevGain: 1.1,
  thresholdFloor: 0.016,
  minTriggerFlux: 0.025,
);

double _clamp(double v, double min, double max) =>
    v < min ? min : (v > max ? max : v);

double _lerp(double a, double b, double t) => a + (b - a) * t;

BeatDetectorParams deriveBeatDetectorParams(double sensitivity) {
  final s = _clamp(sensitivity.roundToDouble(), 0, 100);
  final lowerHalf = s <= 50 ? s / 50 : 1.0;
  final upperHalf = s > 50 ? (s - 50) / 50 : 0.0;
  final fromStrict = BeatDetectorParams(
    thresholdStdDevGain:
        _lerp(_strictParams.thresholdStdDevGain, _defaultParams.thresholdStdDevGain, lowerHalf),
    thresholdFloor: _lerp(_strictParams.thresholdFloor, _defaultParams.thresholdFloor, lowerHalf),
    minTriggerFlux: _lerp(_strictParams.minTriggerFlux, _defaultParams.minTriggerFlux, lowerHalf),
  );
  return BeatDetectorParams(
    thresholdStdDevGain:
        _lerp(fromStrict.thresholdStdDevGain, _sensitiveParams.thresholdStdDevGain, upperHalf),
    thresholdFloor: _lerp(fromStrict.thresholdFloor, _sensitiveParams.thresholdFloor, upperHalf),
    minTriggerFlux: _lerp(fromStrict.minTriggerFlux, _sensitiveParams.minTriggerFlux, upperHalf),
  );
}

BeatDetectorState createBeatDetectorState() {
  return BeatDetectorState(
    activeWindowIndex: 1,
    windowScores: List.filled(kBeatWindows.length, 0),
    previousWindowLevels: List.filled(kBeatWindows.length, 0),
    fluxHistory: List.filled(_fluxHistorySize, 0),
    kickEnvelopeState: createKickEnvelopeState(),
  );
}

/// 计算单个窗口的加权能量（原版 readWindowLevel）。
double _readWindowLevel(List<double> bands, BeatWindow window) {
  final end = math.min(window.end, bands.length - 1);
  if (end < window.start) return 0;
  double weighted = 0;
  double weightTotal = 0;
  final center = (window.start + end) / 2;
  final halfWidth = math.max(1.0, (end - window.start + 1) / 2);
  for (int bin = window.start; bin <= end; bin++) {
    final distance = (bin - center).abs();
    final weight = 0.35 + 0.65 * (1 - math.min(1.0, distance / halfWidth));
    weighted += bands[bin] * weight;
    weightTotal += weight;
  }
  return weightTotal > 0 ? weighted / weightTotal : 0;
}

({double avg, double stdDev}) _fluxStats(List<double> history) {
  final n = history.length;
  if (n == 0) return (avg: 0.0, stdDev: 0.0);
  double sum = 0;
  for (final v in history) {
    sum += v;
  }
  final avg = sum / n;
  double varSum = 0;
  for (final v in history) {
    varSum += (v - avg) * (v - avg);
  }
  return (avg: avg, stdDev: math.sqrt(varSum / n));
}

/// 推进一步检测。`windowBands` 为低频窗口切片的频段能量（0..1）。
BeatDetectorOutput stepBeatDetector({
  required BeatDetectorState state,
  required List<double> windowBands,
  required double deltaSeconds,
  required double sensitivity,
}) {
  final safeDelta = deltaSeconds.isFinite && deltaSeconds > 0 ? deltaSeconds : 0.0;
  final params = deriveBeatDetectorParams(sensitivity);
  final windowLevels = [
    for (final w in kBeatWindows) _readWindowLevel(windowBands, w),
  ];
  final nextScores = List<double>.generate(state.windowScores.length, (i) {
    final flux = math.max(
      0.0,
      windowLevels[i] - state.previousWindowLevels[i],
    );
    final windowWidth =
        kBeatWindows[i].end - kBeatWindows[i].start + 1;
    final focusBonus = 1 / math.sqrt(windowWidth.toDouble());
    return state.windowScores[i] * _windowScoreDecay + flux * focusBonus;
  });

  var activeWindowIndex = state.activeWindowIndex;
  for (int i = 0; i < nextScores.length; i++) {
    if (nextScores[i] > nextScores[activeWindowIndex] * 1.03) {
      activeWindowIndex = i;
    }
  }

  final rawFlux = math.max(
    0.0,
    windowLevels[activeWindowIndex] - state.previousWindowLevels[activeWindowIndex],
  );
  final smoothedFlux = state.smoothedFlux + (rawFlux - state.smoothedFlux) * _fluxSmoothing;
  final stats = _fluxStats(state.fluxHistory);
  final threshold = math.max(
    params.thresholdFloor,
    stats.avg + stats.stdDev * params.thresholdStdDevGain,
  );
  final cooldownRemaining = math.max(0.0, state.cooldownRemaining - safeDelta);
  final isPeak = state.previousSmoothedFlux > threshold &&
      state.previousSmoothedFlux >= smoothedFlux &&
      state.previousSmoothedFlux >= params.minTriggerFlux;
  final onset = cooldownRemaining <= 0 && isPeak;
  final displayedFlux = onset ? state.previousSmoothedFlux : smoothedFlux;

  final nextHistory = List<double>.of(state.fluxHistory);
  nextHistory[state.fluxHistoryIndex] = smoothedFlux;
  final nextHistoryIndex = (state.fluxHistoryIndex + 1) % nextHistory.length;
  final nextEnvelope = stepKickEnvelope(
    state: state.kickEnvelopeState,
    rawKickLevel: windowLevels[activeWindowIndex],
    onset: onset,
    deltaSeconds: safeDelta > 0 ? safeDelta : 1 / 60,
  );
  final confidence =
      _clamp(displayedFlux / math.max(0.001, threshold * 2.2), 0, 1);

  return BeatDetectorOutput(
    state: BeatDetectorState(
      activeWindowIndex: activeWindowIndex,
      windowScores: nextScores,
      previousWindowLevels: windowLevels,
      fluxHistory: nextHistory,
      fluxHistoryIndex: nextHistoryIndex,
      smoothedFlux: smoothedFlux,
      previousSmoothedFlux: smoothedFlux,
      cooldownRemaining: onset ? _cooldownSeconds : cooldownRemaining,
      kickEnvelopeState: nextEnvelope,
    ),
    kickLevel: nextEnvelope.kickLevel,
    kickFlux: displayedFlux,
    kickThreshold: threshold,
    kickOnset: onset,
    kickEnvelope: nextEnvelope.kickEnvelope,
    kickConfidence: confidence,
    activeWindow: kBeatWindows[activeWindowIndex],
  );
}

// ==========================================================================
// kickEnvelope.ts 移植
// ==========================================================================

class KickEnvelopeState {
  double noiseFloor;
  double kickLevel;
  double kickEnvelope;
  KickEnvelopeState({
    this.noiseFloor = 0,
    this.kickLevel = 0,
    this.kickEnvelope = 0,
  });
}

const double _noiseFloorAttackRate = 1.15;
const double _noiseFloorReleaseRate = 0.35;
const double _levelGate = 0.025;
const double _breathGain = 0.18;
const double _maxBreath = 0.11;
const double _onsetMinImpulse = 0.48;
const double _onsetGain = 0.95;
const double _envelopeAttackRate = 42;
const double _envelopeReleaseRate = 11.5;

double _blendForRate(double rate, double deltaSeconds) {
  final safeDelta = deltaSeconds.isFinite && deltaSeconds > 0 ? deltaSeconds : 0.0;
  return _clamp(1 - math.exp(-rate * safeDelta), 0, 1);
}

KickEnvelopeState createKickEnvelopeState() => KickEnvelopeState();

KickEnvelopeState stepKickEnvelope({
  required KickEnvelopeState state,
  required double rawKickLevel,
  required bool onset,
  required double deltaSeconds,
}) {
  final safeRaw = _clamp(rawKickLevel.isFinite ? rawKickLevel : 0, 0, 1);
  final floorRate = safeRaw > state.noiseFloor
      ? _noiseFloorAttackRate
      : _noiseFloorReleaseRate;
  final noiseFloor =
      state.noiseFloor + (safeRaw - state.noiseFloor) * _blendForRate(floorRate, deltaSeconds);
  final kickLevel = _clamp(safeRaw - noiseFloor - _levelGate, 0, 1);
  final breathTarget = math.min(_maxBreath, kickLevel * _breathGain);
  final onsetTarget = onset ? math.max(_onsetMinImpulse, kickLevel * _onsetGain) : 0.0;
  final targetEnvelope = math.max(breathTarget, onsetTarget);
  final envelopeRate = targetEnvelope > state.kickEnvelope
      ? _envelopeAttackRate
      : _envelopeReleaseRate;
  final kickEnvelope = math.max(
    breathTarget,
    state.kickEnvelope +
        (targetEnvelope - state.kickEnvelope) * _blendForRate(envelopeRate, deltaSeconds),
  );

  return KickEnvelopeState(
    noiseFloor: noiseFloor,
    kickLevel: kickLevel,
    kickEnvelope: _clamp(kickEnvelope, 0, 1),
  );
}
