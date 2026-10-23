import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 封面幽灵层（对齐 LX-X「圆形雾化投影」）：
///
/// ① [buildGhostTexture]：封面缩到 128px 后 CPU 逐像素压暗降饱和。
///    小图像素循环是纯 Dart 运算，不经过渲染引擎，结果与设备无关。
///    不做 blur、不做遮罩——5540-5543 实测 Impeller 离屏管线上
///    dstIn 遮罩/toByteData 回读均不可靠；GPU 放大 128px 纹理天然
///    柔焦（内容可辨、边缘发虚，对齐参考观感）。
/// ② [buildGhostVertices]：8×8 顶点色网格（drawVertices 渲染，与
///    地形网格同一条 GPU 管线、真机长期验证可靠）。径向雾化与垂直
///    渐隐全部编码在顶点色 alpha 里：中心全显、四角完全消融，
///    GPU 对每像素插值出「天空中的圆形投影」效果，零离屏、零
///    saveLayer，脉冲提亮每帧重建 81 个顶点色即可。

/// 128px 暗化纹理（压暗 ×0.66、降饱和 ×0.5，无提亮平移）。
Future<ui.Image> buildGhostTexture(ui.Image src) async {
  const side = 128.0;
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec, const ui.Rect.fromLTWH(0, 0, side, side));
  c.drawImageRect(
    src,
    ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    const ui.Rect.fromLTWH(0, 0, side, side),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  final pic = rec.endRecording();
  final small = await pic.toImage(side.toInt(), side.toInt());
  pic.dispose();
  final data = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
  small.dispose();
  final px = data!.buffer.asUint8List();
  const wr = 0.299, wg = 0.587, wb = 0.114;
  const sat = 0.5, dim = 0.66;
  for (var o = 0; o < px.length; o += 4) {
    if (px[o + 3] == 0) continue;
    final gray = wr * px[o] + wg * px[o + 1] + wb * px[o + 2];
    px[o] = _clamp255(dim * (gray + sat * (px[o] - gray)));
    px[o + 1] = _clamp255(dim * (gray + sat * (px[o + 1] - gray)));
    px[o + 2] = _clamp255(dim * (gray + sat * (px[o + 2] - gray)));
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    px,
    side.toInt(),
    side.toInt(),
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// 单顶点颜色：径向雾化 × 垂直渐隐 × 脉冲亮度（供网格构建与测试）。
///
/// [fx]/[fy] ∈ [0,1]（fy 0=顶 1=底）；返回 ARGB int。
int ghostVertexColor(
  double fx,
  double fy, {
  required double bright,
  required double baseAlpha,
}) {
  // 径向雾化（圆心=平面中心，四角 d≈1.41 远超消融半径）：
  // d≤0.52 全显 → 0.52..0.86 smoothstep 消散 → ≥0.86 完全透明。
  final dx = (fx - 0.5) * 2, dy = (fy - 0.5) * 2;
  final d = math.sqrt(dx * dx + dy * dy);
  final radial = d <= 0.52
      ? 1.0
      : d >= 0.86
          ? 0.0
          : 1 - _smoothstep((d - 0.52) / 0.34);
  // 垂直地平线渐隐：下部 55%→95% 渐隐入雾。
  final vert = fy < 0.55
      ? 1.0
      : fy < 0.95
          ? 1 - (fy - 0.55) / 0.40
          : 0.0;
  final a = (baseAlpha * radial * vert * 255).round().clamp(0, 255);
  final rgb = (bright * 255).round().clamp(0, 255);
  // 顶点色未预乘（drawVertices 按 non-premultiplied 处理后与纹理相乘，
  // 再经 paint 混合上屏）。
  return (a << 24) | (rgb << 16) | (rgb << 8) | rgb;
}

/// 顶点色网格：positions 为封面平面局部坐标（x,y ∈ [-half, half]，
/// y=+half 为顶部）、UV 映射整张纹理、顶点色 alpha 承载雾化。
///
/// [bright] 脉冲亮度增益（1.0 基准）；[baseAlpha] 中心整体不透明度。
ui.Vertices buildGhostVertices({
  required double half,
  required double bright,
  required int textureW,
  required int textureH,
  int gridN = 8,
  double baseAlpha = 0.62,
}) {
  final n = gridN + 1;
  final positions = Float32List(n * n * 2);
  final tex = Float32List(n * n * 2);
  final colors = Int32List(n * n);
  final indices = Uint16List(gridN * gridN * 6);
  for (var j = 0; j < n; j++) {
    final fy = j / gridN;
    final y = half - fy * 2 * half;
    for (var i = 0; i < n; i++) {
      final fx = i / gridN;
      final x = -half + fx * 2 * half;
      final k = j * n + i;
      positions[k * 2] = x;
      positions[k * 2 + 1] = y;
      tex[k * 2] = fx * textureW;
      tex[k * 2 + 1] = fy * textureH;
      colors[k] = ghostVertexColor(
        fx,
        fy,
        bright: bright,
        baseAlpha: baseAlpha,
      );
    }
  }
  var t = 0;
  for (var j = 0; j < gridN; j++) {
    for (var i = 0; i < gridN; i++) {
      final a0 = j * n + i, a1 = a0 + 1;
      final b0 = a0 + n, b1 = b0 + 1;
      indices[t++] = a0;
      indices[t++] = b0;
      indices[t++] = a1;
      indices[t++] = a1;
      indices[t++] = b0;
      indices[t++] = b1;
    }
  }
  return ui.Vertices.raw(
    ui.VertexMode.triangles,
    positions,
    textureCoordinates: tex,
    colors: colors,
    indices: indices,
  );
}

double _smoothstep(double t) {
  final x = t.clamp(0.0, 1.0);
  return x * x * (3 - 2 * x);
}

int _clamp255(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());
