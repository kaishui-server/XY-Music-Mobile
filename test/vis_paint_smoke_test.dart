// 可视化 paint 冒烟测试：在本地真实执行 TerrainScenePainter.paint，
// 渲染 PNG 输出，验证是否抛异常 + 直观看画面亮度。
// 运行：flutter test test/vis_paint_smoke_test.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xy_music/pages/visualizer/visualizer_engine.dart';
import 'package:xy_music/pages/visualizer/visualizer_scenes.dart';
import 'package:xy_music/pages/visualizer/visualizer_settings.dart';

Future<void> _render(String name, VisFrame frame, Size size) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec, Offset.zero & size);
  final painter = TerrainScenePainter(frame);
  painter.paint(canvas, size); // 抛异常则测试失败
  final pic = rec.endRecording();
  final img = await pic.toImage(size.width.round(), size.height.round());
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  final out = File('build/vis_smoke_$name.png');
  await out.create(recursive: true);
  await out.writeAsBytes(bytes!.buffer.asUint8List());
  // 统计平均亮度。
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final px = data!.buffer.asUint8List();
  double sum = 0;
  for (int i = 0; i < px.length; i += 4) {
    sum += 0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2];
  }
  // ignore: avoid_print
  print('[$name] avg luminance = ${(sum / (px.length / 4)).toStringAsFixed(2)}'
      ' -> ${out.path}');
}

void main() {
  test('terrain paint smoke: 静音首帧 / 有音乐 / 踢脉冲', () async {
    const size = Size(2400, 1080);
    final cam = OrbitCamera();
    final ripples = VisRippleBuffer();
    const settings = VisualizerSettings();

    // ① 静音首帧（进入页面第一画：bands 全 0、time 0、无封面）。
    await _render(
      'silent_first_frame',
      VisFrame(
        bands: List.filled(64, 0),
        kickEnvelope: 0,
        rms: 0,
        time: 0,
        blockPulse: 0,
        settings: settings,
        camera: cam,
        ripples: ripples,
        coverImage: null,
        meteors: const [],
      ),
      size,
    );

    // ② 有音乐（中等能量频段）。
    final bands = List.generate(64, (i) {
      final x = i / 63;
      return (0.9 - x * 0.65) * (0.55 + 0.45 * math.sin(i * 1.7));
    });
    await _render(
      'music_playing',
      VisFrame(
        bands: bands,
        kickEnvelope: 0.5,
        rms: 0.4,
        time: 12.5,
        blockPulse: 0.35,
        settings: settings,
        camera: cam,
        ripples: ripples,
        coverImage: null,
        meteors: const [],
      ),
      size,
    );

    // ③ 强踢脉冲（点击涟漪 + 高包络）。
    ripples.add(10, -8, 2.0, white: true, time: 12.5);
    await _render(
      'kick_ripple',
      VisFrame(
        bands: bands,
        kickEnvelope: 1.0,
        rms: 0.7,
        time: 12.6,
        blockPulse: 1.0,
        settings: settings,
        camera: cam,
        ripples: ripples,
        coverImage: null,
        meteors: const [],
      ),
      size,
    );
  });
}
