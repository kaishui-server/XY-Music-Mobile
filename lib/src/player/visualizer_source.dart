// visualizer_source.dart — Android 系统可视化器数据源。
//
// 通过原生 VisualizerBridge（android.media.audiofx.Visualizer，挂在输出
// 混音 session 0）以约 20Hz 推送 FFT + waveform 原始字节；Dart 侧把 FFT
// 换算成 64 段对数频段能量（40Hz–16kHz，ratio² 边界，对齐 Rust
// spectrum.rs 的分段方式），并暴露逐帧 attack/release 平滑接口供渲染
// Ticker 调用。
//
// 健壮性（5534）：
// - FFT 与 waveform 双通道采集；部分设备/路由下 FFT 恒为零但波形正常，
//   此时自动切换到波形带通兜底（低/中/高三级 one-pole 能量映射频段），
//   保证「音频动态脉冲」律动不失效；
// - active 标志：最近 1.5s 内有非零数据才算活跃，页面据此显示提示。
//
// 权限：Visualizer 需要 RECORD_AUDIO 运行时授权，此处负责申请与轮询。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';

/// 频段划分常量（对齐 rust/src/player/spectrum.rs）。
const double kVisMinFreq = 40.0;
const double kVisMaxFreq = 16000.0;
const int kVisBandCount = 64;
/// 输出混音采样率（Android 输出混音绝大多数设备为 48kHz；waveform 兜底
/// 使用原生回传的实际 samplingRate）。
const double _mixSampleRate = 48000.0;

/// FFT 字节为有符号 8 位（实部/虚部交错）。
int _signedByte(int v) => v >= 128 ? v - 256 : v;

class VisualizerSource {
  VisualizerSource._();
  static final VisualizerSource instance = VisualizerSource._();

  static const _method = MethodChannel('com.xymusic.mobile/visualizer');
  static const _events = EventChannel('com.xymusic.mobile/visualizer_events');

  StreamSubscription? _sub;
  bool _started = false;
  bool _starting = false;

  /// 事件流写入的目标频段（未经帧间平滑）。
  List<double> _targetBands = List.filled(kVisBandCount, 0);
  /// 帧间平滑后的当前频段（渲染层每帧调用 [stepSmoothed] 推进）。
  final List<double> _smoothedBands = List.filled(kVisBandCount, 0);

  /// 最近一次 FFT 的整体 RMS（0..1，供星云核心等使用）。
  double rms = 0;

  DateTime _lastDataAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastNonZeroFftAt = DateTime.fromMillisecondsSinceEpoch(0);
  double _lastWaveRms = 0;
  bool _lastWaveValid = false;

  /// 是否有活跃数据（权限被拒/未开始/静音超时为 false，页面可显示提示）。
  bool get hasData =>
      _started &&
      DateTime.now().difference(_lastDataAt).inMilliseconds < 1500;

  /// FFT 是否长期无效（全零），已切波形兜底。
  bool get fftFallbackActive =>
      _lastWaveValid &&
      DateTime.now().difference(_lastNonZeroFftAt).inMilliseconds > 2500;

  /// 目标频段副本（调试/降级绘制用）。
  List<double> get targetBands => List.unmodifiable(_targetBands);

  /// 请求 RECORD_AUDIO 运行时权限并等待授权（最多 ~8s，覆盖系统弹窗）。
  Future<bool> ensurePermission() async {
    try {
      if (await _method.invokeMethod<bool>('hasPermission') == true) {
        return true;
      }
      await _method.invokeMethod<bool>('requestPermission');
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (await _method.invokeMethod<bool>('hasPermission') == true) {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 启动采集。返回 false 表示权限被拒或引擎启动失败。
  Future<bool> start() async {
    if (_started || _starting) return _started;
    _starting = true;
    try {
      if (!await ensurePermission()) return false;
      // 先订阅再启动，避免丢首批事件。
      _sub = _events.receiveBroadcastStream().listen(_onEvent, onError: (_) {});
      final ok = await _method.invokeMethod<bool>('start');
      _started = ok == true;
      return _started;
    } catch (_) {
      return false;
    } finally {
      _starting = false;
    }
  }

  Future<void> stop() async {
    _started = false;
    _lastWaveValid = false;
    await _sub?.cancel();
    _sub = null;
    try {
      await _method.invokeMethod<void>('stop');
    } catch (_) {}
  }

  /// 统一事件入口：原生发 ["f", fft] / ["w", wave, samplingRate]。
  void _onEvent(dynamic data) {
    if (data is List && data.length >= 2) {
      final tag = data[0];
      final payload = data[1];
      if (tag == 'f' && payload is Uint8List) {
        _onFft(payload);
      } else if (tag == 'w' && payload is Uint8List) {
        final rate = data.length > 2 ? (data[2] as num?)?.toDouble() : null;
        _onWave(payload, rate ?? _mixSampleRate);
      }
    } else if (data is Uint8List) {
      // 兼容旧桥（仅 FFT）。
      _onFft(data);
    }
  }

  void _onFft(Uint8List data) {
    if (data.length < 4) return;
    final binCount = data.length ~/ 2; // 实部/虚部交错
    if (binCount < 8) return;
    final binWidth = _mixSampleRate / (binCount * 2);

    // 每 band 的频率边界（ratio² 对数式分布，对齐 Rust 分段）。
    final next = List.filled(kVisBandCount, 0.0);
    double rmsAcc = 0;
    int rmsN = 0;
    double maxMag = 0;
    for (int band = 0; band < kVisBandCount; band++) {
      final startRatio = band / kVisBandCount;
      final endRatio = (band + 1) / kVisBandCount;
      final startFreq =
          kVisMinFreq + (kVisMaxFreq - kVisMinFreq) * startRatio * startRatio;
      final endFreq =
          kVisMinFreq + (kVisMaxFreq - kVisMinFreq) * endRatio * endRatio;
      final startBin = math
          .max(1, (startFreq / binWidth).floor())
          .clamp(0, binCount - 1);
      final endBin = math
          .max(startBin + 1, (endFreq / binWidth).ceil())
          .clamp(startBin + 1, binCount);
      double peak = 0;
      for (int i = startBin; i < endBin; i++) {
        final re = _signedByte(data[i * 2]).toDouble();
        final im = _signedByte(data[i * 2 + 1]).toDouble();
        final mag = math.sqrt(re * re + im * im) / 128.0;
        if (mag > peak) peak = mag;
        if (mag > maxMag) maxMag = mag;
        rmsAcc += re * re + im * im;
        rmsN++;
      }
      // 峰值压缩（对齐 Rust powf(0.55)），再加检测源增益在设置层处理。
      next[band] = math.min(1.0, math.pow(peak, 0.55).toDouble());
    }
    if (maxMag > 0.002) {
      _lastNonZeroFftAt = DateTime.now();
    }
    _lastDataAt = DateTime.now();
    _targetBands = next;
    rms = rmsN > 0 ? math.min(1.0, math.sqrt(rmsAcc / rmsN / 32768.0) * 8) : 0;
  }

  // 波形兜底：三级 one-pole 带通能量 → 频段映射（仅 FFT 失效时启用）。
  double _lpLow = 0, _lpMid = 0;

  void _onWave(Uint8List data, double sampleRate) {
    if (data.length < 64) return;
    _lastWaveValid = true;
    _lastDataAt = DateTime.now();

    double acc = 0;
    double lowAcc = 0, midAcc = 0, highAcc = 0;
    final aLow = _onePoleAlpha(90.0, sampleRate);
    final aMid = _onePoleAlpha(900.0, sampleRate);
    for (final b in data) {
      final v = (b - 128) / 128.0;
      acc += v * v;
      _lpLow += (v - _lpLow) * aLow;
      _lpMid += (v - _lpMid) * aMid;
      lowAcc += _lpLow * _lpLow;
      final midB = _lpMid - _lpLow;
      midAcc += midB * midB;
      final highB = v - _lpMid;
      highAcc += highB * highB;
    }
    final n = data.length.toDouble();
    final waveRms = math.sqrt(acc / n);
    _lastWaveRms = waveRms;
    rms = math.min(1.0, waveRms * 4.5);

    // FFT 活跃时波形仅做 rms/ring 参考，不写频段。
    if (DateTime.now().difference(_lastNonZeroFftAt).inMilliseconds <= 2500) {
      return;
    }
    // FFT 失效：用三段能量构造频段轮廓（对数内高外低 + 时间波动造型）。
    final lowE = math.min(1.0, math.sqrt(lowAcc / n) * 5.5);
    final midE = math.min(1.0, math.sqrt(midAcc / n) * 6.5);
    final highE = math.min(1.0, math.sqrt(highAcc / n) * 8.0);
    final t = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final next = List.filled(kVisBandCount, 0.0);
    for (int i = 0; i < kVisBandCount; i++) {
      final x = i / (kVisBandCount - 1);
      double e;
      if (x < 0.28) {
        e = lowE * (1 - x * 1.2);
      } else if (x < 0.55) {
        e = midE * (1.15 - x);
      } else {
        e = highE * (0.9 - (x - 0.55) * 0.9);
      }
      // 段间波动造型，避免兜底形态过于死板。
      e *= 0.72 + 0.28 * math.sin(t * 6.0 + i * 1.31);
      next[i] = e.clamp(0.0, 1.0);
    }
    _targetBands = next;
  }

  /// one-pole 低通系数（fc Hz @ sampleRate）。
  static double _onePoleAlpha(double fc, double fs) {
    final w = 2 * math.pi * fc / fs;
    return w / (w + 1);
  }

  double get waveRms => _lastWaveRms;

  /// 渲染层每帧调用：向目标频段做 attack/release 平滑（30ms/180ms，
  /// 对齐 Rust RealtimeSpectrumAnalyzer），返回平滑后的频段列表。
  /// [ratePerSecond]：对齐 sonic-topography 的响应速率
  /// responseRate = lerp(2.2, 60, motionSpeed/100)——统一指数趋近，
  /// 不区分 attack/release；为空时走默认 30ms/180ms 攻丝释放。
  List<double> stepSmoothed(double dt, {double? ratePerSecond}) {
    final double attack;
    final double release;
    if (ratePerSecond != null) {
      attack = release = 1.0 - math.exp(-ratePerSecond * dt);
    } else {
      attack = 1.0 - math.exp(-dt / 0.03);
      release = 1.0 - math.exp(-dt / 0.18);
    }
    for (int i = 0; i < kVisBandCount; i++) {
      final target = _targetBands[i];
      final cur = _smoothedBands[i];
      _smoothedBands[i] = cur + (target - cur) * (target > cur ? attack : release);
    }
    return _smoothedBands;
  }
}
