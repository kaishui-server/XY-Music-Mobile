// 冒烟测试：验证 TerrainScenePainter 的封面幽灵层是否真的画到屏幕上。
// 生成两张 1920×920 PNG（有封面/无封面），统计差异像素包围盒。

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/pages/visualizer/ghost_cover.dart';
import 'package:xy_music/pages/visualizer/visualizer_engine.dart';
import 'package:xy_music/pages/visualizer/visualizer_scenes.dart';
import 'package:xy_music/pages/visualizer/visualizer_settings.dart';

Future<ui.Image> _solidImage(int size, int r, int g, int b) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec, ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()));
  c.drawRect(
    ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    ui.Paint()..color = ui.Color.fromARGB(255, r, g, b),
  );
  final pic = rec.endRecording();
  final img = await pic.toImage(size, size);
  pic.dispose();
  return img;
}

Future<Uint8List> _snap(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

Future<void> _dumpPng(ui.Image image, String path) async {
  Directory(File(path).parent.path).createSync(recursive: true);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(data!.buffer.asUint8List());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cover ghost paints pixels on screen', () async {
    const w = 1920.0, h = 920.0;
    final camera = OrbitCamera();
    final ripples = VisRippleBuffer();
    final bands = List<double>.filled(64, 0.35);

    final cover = await _solidImage(256, 255, 40, 40);
    final ghost = await buildGhostTextures(cover);

    VisFrame make(VisualizerSettings s, GhostTextures? img) => VisFrame(
          bands: bands,
          kickEnvelope: 0,
          rms: 0.3,
          time: 0,
          blockPulse: 0,
          settings: s,
          camera: camera,
          ripples: ripples,
          coverImage: img,
          meteors: const [],
        );

    Future<ui.Image> paint(TerrainScenePainter p) async {
      final rec = ui.PictureRecorder();
      final c = ui.Canvas(rec, ui.Rect.fromLTWH(0, 0, w, h));
      p.paint(c, ui.Size(w, h));
      final pic = rec.endRecording();
      final img = await pic.toImage(w.toInt(), h.toInt());
      pic.dispose();
      return img;
    }

    // 全部主题过一遍（导出 PNG 供人工核对观感）。
    for (var ti = 0; ti < kVisThemes.length; ti++) {
      final s = VisualizerSettings(themeIndex: ti);
      final img = await paint(TerrainScenePainter(make(s, ghost)));
      await _dumpPng(img, 'build/vis_smoke/theme_${kVisThemes[ti].id}.png');
      final px = await _snap(img);
      // 统计天空区（顶部 25%）平均亮度，验证天空不再是纯黑。
      var sum = 0;
      final n = (h * 0.25).toInt() * w.toInt();
      for (int i = 0; i < n; i++) {
        final o = i * 4;
        sum += (px[o] + px[o + 1] + px[o + 2]) ~/ 3;
      }
      // ignore: avoid_print
      print('theme=${kVisThemes[ti].id} skyAvgLuma=${sum ~/ n}');
      expect(sum ~/ n, greaterThan(8), reason: '天空不应是纯黑');
    }

    final settings = const VisualizerSettings();
    final withCover = await paint(
        TerrainScenePainter(make(settings, ghost)));
    final without = await paint(
        TerrainScenePainter(make(settings, null)));

    await _dumpPng(withCover, 'build/vis_smoke/cover_on.png');
    await _dumpPng(without, 'build/vis_smoke/cover_off.png');

    final a = await _snap(withCover);
    final b = await _snap(without);
    var diff = 0;
    var minX = 1 << 30, maxX = -1, minY = 1 << 30, maxY = -1;
    for (int y = 0; y < h.toInt(); y++) {
      for (int x = 0; x < w.toInt(); x++) {
        final i = (y * w.toInt() + x) * 4;
        final dr = (a[i] - b[i]).abs();
        final dg = (a[i + 1] - b[i + 1]).abs();
        final db = (a[i + 2] - b[i + 2]).abs();
        if (dr + dg + db > 24) {
          diff++;
          minX = math.min(minX, x);
          maxX = math.max(maxX, x);
          minY = math.min(minY, y);
          maxY = math.max(maxY, y);
        }
      }
    }
    // ignore: avoid_print
    print('diffPixels=$diff bbox=($minX,$minY)-($maxX,$maxY)');
    expect(diff, greaterThan(1000), reason: '封面幽灵层应产生可见像素差异');
  });
}
