// 冒烟测试：验证封面幽灵层「CPU 暗化纹理 + 顶点色雾化网格」管线。
// 5540-5543 实测 Impeller 离屏管线上 dstIn 遮罩/toByteData 回读不可靠
// （真机矩形轮廓始终清晰），故雾化改由顶点色承载（drawVertices 与地
// 形网格同管线），纹理只做 CPU 压暗降饱和（纯 Dart、与设备无关）。

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

  test('ghost texture: 128px, dimmed and desaturated, alpha intact',
      () async {
    final src = await _solidImage(256, 220, 60, 60);
    final tex = await buildGhostTexture(src);
    expect(tex.width, 128);
    expect(tex.height, 128);

    final center = await _pixel(tex, 64, 64);
    // alpha 不动（雾化交给顶点色），RGB 压暗降饱和。
    expect(center[3], 255);
    expect(center[0], lessThan(220), reason: 'R 应被压暗：${center[0]}');
  });

  test('ghost vertex colors: corners dissolved, center visible', () {
    const base = 0.62;
    int alphaAt(double fx, double fy) {
      final c = ghostVertexColor(fx, fy, bright: 1.0, baseAlpha: base);
      return (c >> 24) & 0xFF;
    }

    // 四角完全消融（圆形雾化投影，无矩形轮廓）。
    expect(alphaAt(0, 0), 0, reason: '左上角应透明');
    expect(alphaAt(1, 0), 0, reason: '右上角应透明');
    expect(alphaAt(0, 1), 0, reason: '左下角应透明');
    expect(alphaAt(1, 1), 0, reason: '右下角应透明');
    // 中心全显（baseAlpha=0.62 → ~158）。
    final center = alphaAt(0.5, 0.5);
    expect(center, greaterThan(120));
    expect(center, lessThan(200));
    // 边中点弱于中心（雾化收边）。
    expect(alphaAt(0.5, 0.0), lessThan(center), reason: '顶边中点应弱于中心');
    // 底部垂直渐隐。
    expect(alphaAt(0.5, 1.0), 0, reason: '底缘应完全渐隐');
    // 脉冲提亮只改 RGB（1.3×255 截断到 255），alpha 不受影响。
    final bright =
        ghostVertexColor(0.5, 0.5, bright: 1.3, baseAlpha: base);
    expect((bright >> 16) & 0xFF, 255);
    expect((bright >> 24) & 0xFF, center);
  });
}
