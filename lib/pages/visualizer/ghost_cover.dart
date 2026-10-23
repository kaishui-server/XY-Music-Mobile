import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

/// 封面幽灵层预处理（对齐 LX-X「天空中的模糊投影」）：多级降采样强模糊 →
/// CPU 逐像素压暗降饱和 → 径向雾化（四角/边缘完全消融）→ 垂直渐隐。
///
/// 不走 saveLayer/dstIn 烘焙与 ImageFilter：Impeller 离屏管线上 dstIn
/// 遮罩、以及同 paint 的 imageFilter+colorFilter 组合实测会失效
/// （5540/5541 封面矩形轮廓始终清晰的根因），逐像素处理结果与渲染引擎
/// 无关；烘焙一次，每帧零离屏直接贴。
Future<ui.Image> buildGhostCover(ui.Image src) async {
  const size = 256.0, blurSide = 48.0;
  const side = 256;
  // ① 强模糊 = 多级降采样放大：src → 48px（高质量缩小丢高频）→
  //    256px（高质量放大糊化），不依赖 ImageFilter.blur。
  final downRec = ui.PictureRecorder();
  final downC = ui.Canvas(
    downRec,
    const ui.Rect.fromLTWH(0, 0, blurSide, blurSide),
  );
  downC.drawImageRect(
    src,
    ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    const ui.Rect.fromLTWH(0, 0, blurSide, blurSide),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  final downPic = downRec.endRecording();
  final small = await downPic.toImage(blurSide.toInt(), blurSide.toInt());
  downPic.dispose();

  final upRec = ui.PictureRecorder();
  final upC = ui.Canvas(
    upRec,
    const ui.Rect.fromLTWH(0, 0, size, size),
  );
  upC.drawImageRect(
    small,
    const ui.Rect.fromLTWH(0, 0, blurSide, blurSide),
    const ui.Rect.fromLTWH(0, 0, size, size),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  final upPic = upRec.endRecording();
  final upscaled = await upPic.toImage(size.toInt(), size.toInt());
  upPic.dispose();
  small.dispose();

  // ② CPU 逐像素：颜色 dim*(gray + 0.5*(c-gray))、整体 alpha 0.5、
  //    径向雾化（中心全显，边缘中点剩约 19%，四角 0.707×size 处完全
  //    消融）、垂直地平线渐隐。无提亮平移（提亮会把封面洗成白雾团）。
  final data = await upscaled.toByteData(format: ui.ImageByteFormat.rawRgba);
  upscaled.dispose();
  final px = data!.buffer.asUint8List();
  const wr = 0.299, wg = 0.587, wb = 0.114;
  const sat = 0.5, dim = 0.66, baseAlpha = 0.5;
  const radius = 0.71 * side;
  const vertStart = 0.55 * side, vertEnd = 0.95 * side;
  for (var y = 0; y < side; y++) {
    final dy = (y + 0.5) / side - 0.5;
    final vert = y < vertStart
        ? 1.0
        : y < vertEnd
            ? 1 - (y - vertStart) / (vertEnd - vertStart)
            : 0.0;
    for (var x = 0; x < side; x++) {
      final o = (y * side + x) * 4;
      final a = px[o + 3];
      if (a == 0) continue;
      final gray = wr * px[o] + wg * px[o + 1] + wb * px[o + 2];
      px[o] = _clamp255(dim * (gray + sat * (px[o] - gray)));
      px[o + 1] = _clamp255(dim * (gray + sat * (px[o + 1] - gray)));
      px[o + 2] = _clamp255(dim * (gray + sat * (px[o + 2] - gray)));
      final dx = (x + 0.5) / size - 0.5;
      final t = math.sqrt(dx * dx + dy * dy) * size / radius;
      // 分段线性雾化：1.0 → 0.9 → 0.25 → 0。
      final radial = t < 0.38
          ? 1 - 0.1 * (t / 0.38)
          : t < 0.62
              ? 0.9 - 0.65 * ((t - 0.38) / 0.24)
              : t < 0.95
                  ? 0.25 * (1 - (t - 0.62) / 0.33)
                  : 0.0;
      px[o + 3] = _clamp255(a * baseAlpha * radial * vert);
    }
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    px,
    side,
    side,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

int _clamp255(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());
