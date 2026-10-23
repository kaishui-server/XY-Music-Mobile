// 冒烟测试：验证封面幽灵层「解码器直出双层纹理 + 顶点色雾化网格」管线。
// 5540-5543 实测 Impeller 离屏管线上 dstIn 遮罩/toByteData 回读不可靠
// （真机矩形轮廓始终清晰），故纹理为解码直出零加工，雾化/暗化全部由
// 顶点色承载（drawVertices 与地形网格同管线）。
// 5546 双层化：内层 512px 清晰纹理（人物轮廓可辨）+ 外层 64px 糊化
// 纹理雾环（边缘高斯模糊感）+ 雾气漂浮（顶点 alpha/位置随时间扰动）。

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
    // 顶点色承载，任何 CPU 像素加工都会重新引入真机不可靠管线。
    final center = await _pixel(tex.sharp, 128, 128);
    expect(center, [220, 60, 60, 255]);
    final blurCenter = await _pixel(tex.blur, 32, 32);
    expect(blurCenter, [90, 140, 220, 255]);
    tex.dispose();
  });

  int alphaAt(
    double fx,
    double fy, {
    required GhostLayer layer,
    double base = 0.62,
    double time = 0,
  }) {
    final c = ghostVertexColor(
      fx,
      fy,
      layer: layer,
      bright: 1.0,
      baseAlpha: base,
      time: time,
    );
    return (c >> 24) & 0xFF;
  }

  test('inner layer: corners dissolved, center visible', () {
    // 四角完全消融（圆形雾化投影，无矩形轮廓）。
    expect(alphaAt(0, 0, layer: GhostLayer.inner), 0);
    expect(alphaAt(1, 0, layer: GhostLayer.inner), 0);
    expect(alphaAt(0, 1, layer: GhostLayer.inner), 0);
    expect(alphaAt(1, 1, layer: GhostLayer.inner), 0);
    // 中心全显。
    final center = alphaAt(0.5, 0.5, layer: GhostLayer.inner);
    expect(center, greaterThan(120));
    expect(center, lessThan(200));
  });

  test('outer layer: mist ring peaks off-center, corners dissolved', () {
    // 中心透明（雾环不遮清晰区）、d≈0.4 处峰值、四角完全消融。
    expect(alphaAt(0.5, 0.5, layer: GhostLayer.outer), 0);
    final ring = alphaAt(0.7, 0.5, layer: GhostLayer.outer);
    expect(ring, greaterThan(0), reason: '雾环应有可见 alpha');
    expect(alphaAt(0, 0, layer: GhostLayer.outer), 0);
    expect(alphaAt(1, 1, layer: GhostLayer.outer), 0);
  });

  test('mist flicker: outer layer alpha varies with time, inner static',
      () {
    var innerChanged = false;
    var outerChanged = false;
    for (final t in [0.0, 0.4, 1.1, 2.3]) {
      final a0 = alphaAt(0.8, 0.6, layer: GhostLayer.outer, time: t);
      final a1 = alphaAt(0.8, 0.6, layer: GhostLayer.outer, time: 0.0);
      if (a0 != a1) outerChanged = true;
      final i0 = alphaAt(0.5, 0.2, layer: GhostLayer.inner, time: t);
      final i1 = alphaAt(0.5, 0.2, layer: GhostLayer.inner, time: 0.0);
      if (i0 != i1) innerChanged = true;
    }
    expect(outerChanged, isTrue, reason: '外层雾气应随时间漂浮波动');
    expect(innerChanged, isFalse, reason: '内层清晰区应静止');
  });

  test('vertex colors: bright modulates RGB (night tint), alpha intact', () {
    const base = 0.62;
    final c =
        ghostVertexColor(0.5, 0.5, layer: GhostLayer.inner, bright: 1.0, baseAlpha: base, time: 0);
    final b = ghostVertexColor(
        0.5, 0.5, layer: GhostLayer.inner, bright: 1.3, baseAlpha: base, time: 0);
    expect(((b >> 24) & 0xFF), ((c >> 24) & 0xFF),
        reason: 'bright 只调 RGB 不调 alpha');
    // 乘性暗化：RGB 按夜空色调制（0.62/0.66/0.74），亮度提升等比放大。
    expect(((c >> 16) & 0xFF), (0.62 * 255).round());
    expect(((c >> 8) & 0xFF), (0.66 * 255).round());
    expect((c & 0xFF), (0.74 * 255).round());
    expect(((b >> 16) & 0xFF), (1.3 * 0.62 * 255).round());
  });
}
