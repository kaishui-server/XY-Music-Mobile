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

  test('dim matrix: night tint 0.62/0.66/0.74 (pure multiplicative)', () {
    final m = ghostDimMatrix(bright: 1.0);
    expect(m.length, 20);
    // 5553 恢复 5547 定稿：纯乘性夜色 tint（对角矩阵），保 V 压暗、
    // 不降饱和——R×0.62 / G×0.66 / B×0.74。
    expect(m[0], closeTo(0.62, 1e-9));
    expect(m[1], 0);
    expect(m[2], 0);
    expect(m[3], 0);
    expect(m[4], 0);
    expect(m[5], 0);
    expect(m[6], closeTo(0.66, 1e-9));
    expect(m[7], 0);
    expect(m[10], 0);
    expect(m[11], 0);
    expect(m[12], closeTo(0.74, 1e-9));
    expect(m[13], 0);
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

  test('dim matrix: keeps pure red pure (no desaturation, G/B stay 0)', () {
    final m = ghostDimMatrix(bright: 1.0);
    // 纯红 (255,0,0) 输出 R = 0.62×255 ≈ 158.1，G/B = 0——纯乘性压暗
    // 不做亮度混合降饱和（5539 教训：降饱和会把彩色封面洗灰）。
    expect(m[0] * 255, closeTo(0.62 * 255, 0.01));
    expect(m[5], 0);
    expect(m[10], 0);
  });
}
