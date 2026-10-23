// 冒烟测试：验证封面幽灵层「CPU 暗化双层纹理 + 顶点色雾化网格」管线。
// 5540-5543 实测 Impeller 离屏管线上 dstIn 遮罩/toByteData 回读不可靠
// （真机矩形轮廓始终清晰），故雾化由顶点色承载（drawVertices 与地形
// 网格同管线）；纹理只做 CPU 压暗降饱和（纯 Dart、与设备无关）。
// 5545 双层化：内层 256px 清晰纹理（人物轮廓可辨）+ 外层 64px 糊化
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

  test('ghost textures: sharp 256px + blur 64px, dimmed, alpha intact',
      () async {
    final src = await _solidImage(256, 220, 60, 60);
    final tex = await buildGhostTextures(src);
    expect(tex.sharp.width, 256);
    expect(tex.sharp.height, 256);
    expect(tex.blur.width, 64);
    expect(tex.blur.height, 64);

    final center = await _pixel(tex.sharp, 128, 128);
    // alpha 不动（雾化交给顶点色），RGB 压暗降饱和。
    expect(center[3], 255);
    expect(center[0], lessThan(220), reason: 'R 应被压暗：${center[0]}');
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

  test('vertex colors: bright only affects RGB', () {
    const base = 0.62;
    final c =
        ghostVertexColor(0.5, 0.5, layer: GhostLayer.inner, bright: 1.0, baseAlpha: base, time: 0);
    final b = ghostVertexColor(
        0.5, 0.5, layer: GhostLayer.inner, bright: 1.3, baseAlpha: base, time: 0);
    expect(((b >> 24) & 0xFF), ((c >> 24) & 0xFF));
    expect(((b >> 16) & 0xFF), 255);
  });
}
