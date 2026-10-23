// 冒烟测试：验证封面幽灵层烘焙管线（buildGhostCover）的实际输出。
// 5540/5541 曾因 Impeller 离屏管线上 dstIn 遮罩与 imageFilter+colorFilter
// 组合失效，封面矩形轮廓始终清晰；管线改为多级降采样 + CPU 逐像素后，
// 输出必须满足：四角完全消融、中心可见、边缘弱于中心、整体压暗。

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

  test('ghost cover: corners dissolved, center visible, dimmed', () async {
    final src = await _solidImage(256, 220, 60, 60);
    final out = await buildGhostCover(src);
    expect(out.width, 256);
    expect(out.height, 256);

    // 四角完全消融（无矩形轮廓）。
    for (final (x, y) in [(2, 2), (253, 2), (2, 253), (253, 253)]) {
      final p = await _pixel(out, x, y);
      expect(p[3], 0, reason: '四角($x,$y)应完全透明，alpha=${p[3]}');
    }

    // 中心可见（降采样放大后中心即源色）。
    final center = await _pixel(out, 128, 128);
    expect(center[3], greaterThan(80), reason: '中心应可见，alpha=${center[3]}');

    // 边缘中点弱于中心（雾化收边）。
    final edge = await _pixel(out, 128, 2);
    expect(edge[3], lessThan(center[3]), reason: '上边缘应弱于中心');

    // 整体压暗降饱和：中心通道 ≤ 源色（0.66×灰度偏移后不可能超过源值）。
    expect(center[0], lessThan(220), reason: 'R 应被压暗，r=${center[0]}');
  });
}
