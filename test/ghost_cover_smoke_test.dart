// 冒烟测试：验证封面幽灵层「解码器直出双层纹理 + drawImageRect + 渐变
// 雾罩」管线。
// 5546 真机「一团白」根因：drawVertices 的 paint 从未绑定 ImageShader，
// 纹理坐标无纹理可采，只画出顶点色灰团。5547 改为 drawImageRect 直出
// （5540-5543 真机实证可见），压暗/降饱和由 ghostDimMatrix 单一
// colorFilter 承载，消散/渐隐由 gradient shader 直绘（零离屏、零顶点
// 色、零像素回读）。

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/pages/visualizer/ghost_cover.dart';

Future<ui.Image> _solidImage(int size, int r, int g, int b) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(
    rec,
    ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
  );
  c.drawRect(
    ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    ui.Paint()..color = ui.Color.fromARGB(255, r, g, b),
  );
  final pic = rec.endRecording();
  final img = await pic.toImage(size, size);
  pic.dispose();
  return img;
}

Future<List<int>> _pixel(ui.Image image, int x, int y) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final px = data!.buffer.asUint8List();
  final o = (y * image.width + x) * 4;
  return [px[o], px[o + 1], px[o + 2], px[o + 3]];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ghost textures: zero-offscreen pass-through of both decodes',
      () async {
    final sharpSrc = await _solidImage(256, 220, 60, 60);
    final blurSrc = await _solidImage(64, 90, 140, 220);
    final tex = buildGhostTextures(sharpSrc: sharpSrc, blurSrc: blurSrc);
    expect(tex.sharp.width, 256);
    expect(tex.sharp.height, 256);
    expect(tex.blur.width, 64);
    expect(tex.blur.height, 64);

    // 纹理即解码直出的原始像素（alpha/RGB 均不加工）——暗化/去饱和由
    // colorFilter 矩阵承载，任何 CPU 像素加工都会重新引入真机不可靠管线。
    final center = await _pixel(tex.sharp, 128, 128);
    expect(center, [220, 60, 60, 255]);
    final blurCenter = await _pixel(tex.blur, 32, 32);
    expect(blurCenter, [90, 140, 220, 255]);
    tex.dispose();
  });

  test('dim matrix: night tint (0.50/0.54/0.63) × saturation 0.42', () {
    final m = ghostDimMatrix(bright: 1.0);
    expect(m.length, 20);
    // 亮度基準系数（0.2126/0.7152/0.0722，sat=0.42）：
    // R 行 = 0.50 × [0.2126×0.58+0.42, 0.7152×0.58, 0.0722×0.58, 0, 0]。
    expect(m[0], closeTo(0.50 * (0.2126 * 0.58 + 0.42), 1e-9));
    expect(m[1], closeTo(0.50 * (0.7152 * 0.58), 1e-9));
    expect(m[2], closeTo(0.50 * (0.0722 * 0.58), 1e-9));
    expect(m[3], 0);
    expect(m[4], 0);
    // G 行 = 0.54 × [0.1063, 0.8358, 0.0419, ...]。
    expect(m[5], closeTo(0.54 * (0.2126 * 0.58), 1e-9));
    expect(m[6], closeTo(0.54 * (0.7152 * 0.58 + 0.42), 1e-9));
    // B 行 = 0.63 × [0.1063, 0.4148, 0.5619, 0, 0]。
    expect(m[10], closeTo(0.63 * (0.2126 * 0.58), 1e-9));
    expect(m[11], closeTo(0.63 * (0.7152 * 0.58), 1e-9));
    expect(m[12], closeTo(0.63 * (0.0722 * 0.58 + 0.42), 1e-9));
    // alpha 行恒等（不改动纹理透明度）。
    expect(m[15], 0);
    expect(m[16], 0);
    expect(m[17], 0);
    expect(m[18], 1);
    expect(m[19], 0);
  });

  test('dim matrix: bright scales RGB rows proportionally, alpha intact', () {
    final a = ghostDimMatrix(bright: 1.0);
    final b = ghostDimMatrix(bright: 1.3);
    for (var i = 0; i < 15; i++) {
      expect(b[i], closeTo(a[i] * 1.3, 1e-9), reason: 'index $i');
    }
    // bright 只调 RGB 不调 alpha 行。
    for (var i = 15; i < 20; i++) {
      expect(b[i], a[i], reason: 'index $i');
    }
  });

  test('dim matrix: desaturates pure red (G/B lifted, channel spread shrunk)',
      () {
    final m = ghostDimMatrix(bright: 1.0);
    // 纯红 (255,0,0) 输出：
    // R = 0.50×0.5433×255 ≈ 69.3，G = 0.54×0.1233×255 ≈ 17.0，
    // B = 0.63×0.1233×255 ≈ 19.8 —— 降饱和后的暗红（G/B 不再为 0）。
    final r = 0.50 * (0.2126 * 0.58 + 0.42) * 255;
    final g = 0.54 * (0.2126 * 0.58) * 255;
    final b = 0.63 * (0.2126 * 0.58) * 255;
    expect(m[0] * 255, closeTo(r, 0.01));
    expect(m[5] * 255, closeTo(g, 0.01));
    expect(m[10] * 255, closeTo(b, 0.01));
    expect(g, greaterThan(0));
    expect(b, greaterThan(0));
  });
}
