// visualizer_source.dart — Android 系统可视化器数据源。
//
// 通过原生 VisualizerBridge（android.media.audiofx.Visualizer，挂在输出
// 混音 session 0）以约 20Hz 推送 FFT 原始字节；Dart 侧把 FFT 换算成 64
// 段对数频段能量（40Hz–16kHz，ratio² 边界，对齐 Rust spectrum.rs 的
// 分段方式），并暴露逐帧 attack/release 平滑接口供渲染 Ticker 调用。
//
// 权限：Visualizer 需要 RECORD_AUDIO 运行时授权，此处负责申请与轮询。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';

/// 频段划分常量（对齐 rust/src/player/spectrum.rs）。
const double kVisMinFreq = 40.0;
const double kVisMaxFreq = 16000.0;
const int kVisBandCount = 64;
/// 输出混音采样率（Android 输出混音绝大多数设备为 48kHz）。
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
  /// 是否有活跃数据（权限被拒/未开始时为 false，页面可显示提示）。
  bool get hasData => _started;

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
      final ok = await _method.invokeMethod<bool>('start');
      _sub = _events.receiveBroadcastStream().listen(_onFft, onError: (_) {});
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
    await _sub?.cancel();
    _sub = null;
    try {
      await _method.invokeMethod<void>('stop');
    } catch (_) {}
  }

  void _onFft(dynamic data) {
    if (data is! Uint8List || data.length < 4) return;
    final binCount = data.length ~/ 2; // 实部/虚部交错
    if (binCount < 8) return;
    final binWidth = _mixSampleRate / (binCount * 2);

    // 每 band 的频率边界（ratio² 对数式分布，对齐 Rust 分段）。
    final next = List.filled(kVisBandCount, 0.0);
    double rmsAcc = 0;
    int rmsN = 0;
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
        rmsAcc += re * re + im * im;
        rmsN++;
      }
      // 峰值压缩（对齐 Rust powf(0.55)），再加检测源增益在设置层处理。
      next[band] = math.min(1.0, math.pow(peak, 0.55).toDouble());
    }
    _targetBands = next;
    rms = rmsN > 0 ? math.min(1.0, math.sqrt(rmsAcc / rmsN / 32768.0) * 8) : 0;
  }

  /// 渲染层每帧调用：向目标频段做 attack/release 平滑（30ms/180ms，
  /// 对齐 Rust RealtimeSpectrumAnalyzer），返回平滑后的频段列表。
  List<double> stepSmoothed(double dt) {
    final attack = 1.0 - math.exp(-dt / 0.03);
    final release = 1.0 - math.exp(-dt / 0.18);
    for (int i = 0; i < kVisBandCount; i++) {
      final target = _targetBands[i];
      final cur = _smoothedBands[i];
      _smoothedBands[i] = cur + (target - cur) * (target > cur ? attack : release);
    }
    return _smoothedBands;
  }
}
