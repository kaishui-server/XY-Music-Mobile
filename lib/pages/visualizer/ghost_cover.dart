import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 封面幽灵层（对齐 LX-X「天空中的巨大圆形雾化投影」）：
///
/// 观感拆解（以播放详情页的沉浸式封面背景为参照溶进天空层）：
/// ① 中心人物轮廓可辨 —— 内层「清晰纹理」（256px CPU 暗化降饱和，
///    GPU 放大轻度柔焦）；
/// ② 边缘高斯模糊 —— 外层「糊化纹理」（64px CPU 暗化，GPU 放大即强
///    柔焦），alpha 从内圈渐入、外圈渐出，形成雾化雾环；
/// ③ 圆形投影、四边完全消散 —— 两层顶点色都做径向消融（d≥0.9 全透，
///    无任何矩形轮廓）；
/// ④ 雾气漂浮 —— 外层顶点 alpha/位置随时间正弦扰动（每帧重建 81 个
///    顶点，成本可忽略）。
///
/// 管线：drawVertices 顶点色网格（与地形网格同一条 GPU 管线，真机长期
/// 验证可靠）。所有遮罩/颜色都编码在顶点色，零离屏烘焙——Impeller
/// 离屏管线上 dstIn 遮罩、toByteData 回读、saveLayer 组合实测不可靠
/// （5540-5543 真机矩形轮廓始终清晰的根因）。
///
/// 纹理生成是纯 Dart 像素循环（压暗 ×0.66、降饱和 ×0.5），结果与设备
/// 无关；不在这里做模糊/遮罩。

/// 双层纹理：[sharp] 内层清晰 / [blur] 外层雾环。
class GhostTextures {
  const GhostTextures({required this.sharp, required this.blur});
  final ui.Image sharp;
  final ui.Image blur;
  void dispose() {
    sharp.dispose();
    blur.dispose();
  }
}

/// 生成双层暗化纹理（sharp=256px / blur=64px）。
Future<GhostTextures> buildGhostTextures(ui.Image src) async {
  final sharp = await _bakeDimmed(src, 256);
  final blur = await _bakeDimmed(src, 64);
  return GhostTextures(sharp: sharp, blur: blur);
}

Future<ui.Image> _bakeDimmed(ui.Image src, int side) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(
    rec,
    ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
  );
  c.drawImageRect(
    src,
    ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  final pic = rec.endRecording();
  final small = await pic.toImage(side, side);
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
    side,
    side,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// 单层幽灵网格顶点颜色：径向包络 × 垂直渐隐 × 雾气波动 × 亮度。
///
/// [fx]/[fy] ∈ [0,1]（fy 0=顶 1=底）；[envelope] 决定该层的径向包络
/// （内层=清晰区渐出，外层=雾环）；[time] 秒，驱动雾气漂浮波动。
/// 返回 ARGB int。
int ghostVertexColor(
  double fx,
  double fy, {
  required GhostLayer layer,
  required double bright,
  required double baseAlpha,
  required double time,
}) {
  final dx = (fx - 0.5) * 2, dy = (fy - 0.5) * 2;
  final d = math.sqrt(dx * dx + dy * dy);
  final radial = _radialEnvelope(d, layer);
  // 垂直地平线渐隐：下部 55%→95% 渐隐入雾。
  final vert = fy < 0.55
      ? 1.0
      : fy < 0.95
          ? 1 - (fy - 0.55) / 0.40
          : 0.0;
  // 雾气漂浮：仅外层，空间相位噪声波（缓慢的呼吸式明暗）。
  var mist = 1.0;
  if (layer == GhostLayer.outer) {
    mist = 1 + 0.22 * math.sin(time * 0.8 + (fx * 2.7 + fy * 1.9) * 5.1);
  }
  final a =
      (baseAlpha * radial * vert * mist * 255).round().clamp(0, 255);
  final rgb = (bright * 255).round().clamp(0, 255);
  // 顶点色未预乘（drawVertices 按 non-premultiplied 处理后与纹理相乘，
  // 再经 paint 混合上屏）。
  return (a << 24) | (rgb << 16) | (rgb << 8) | rgb;
}

/// 径向包络（d=归一化径向距离，0 中心 → 1 边缘 → 1.41 四角）：
/// inner 层承载中心清晰区（0.52 内全显 → 0.80 消散）；
/// outer 层承载雾环（0.30 内透明 → 0.55 渐入峰值 → 0.95 完全消散，
/// 四角 d≈1.41 远超消融半径 → 圆形投影无矩形轮廓）。
double _radialEnvelope(double d, GhostLayer layer) {
  if (layer == GhostLayer.inner) {
    if (d <= 0.52) return 1.0;
    if (d >= 0.80) return 0.0;
    return 1 - _smoothstep((d - 0.52) / 0.28);
  }
  if (d <= 0.30 || d >= 0.95) return 0.0;
  if (d < 0.55) return _smoothstep((d - 0.30) / 0.25);
  return 1 - _smoothstep((d - 0.55) / 0.40);
}

enum GhostLayer { inner, outer }

/// 构建单层顶点色网格：positions 为封面平面局部坐标（x,y ∈
/// [-half, half]，y=+half 为顶部）、UV 映射整张纹理、顶点色 alpha
/// 承载雾化。外层顶点位置叠加雾气漂移扰动。
ui.Vertices buildGhostVertices({
  required GhostLayer layer,
  required double half,
  required double bright,
  required int textureW,
  required int textureH,
  required double time,
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
    var y = half - fy * 2 * half;
    for (var i = 0; i < n; i++) {
      final fx = i / gridN;
      var x = -half + fx * 2 * half;
      final k = j * n + i;
      // 雾气漂浮：外层顶点位置做缓慢的低频漂移（径向呼吸），幅度
      // 随离心距增大（中心锚定、边缘漂）。
      if (layer == GhostLayer.outer) {
        final dx = (fx - 0.5) * 2, dy = (fy - 0.5) * 2;
        final drift =
            0.05 * half * math.sin(time * 0.6 + (dx + dy) * 3.7);
        x += drift * dx;
        y -= drift * dy;
      }
      positions[k * 2] = x;
      positions[k * 2 + 1] = y;
      tex[k * 2] = fx * textureW;
      tex[k * 2 + 1] = fy * textureH;
      colors[k] = ghostVertexColor(
        fx,
        fy,
        layer: layer,
        bright: bright,
        baseAlpha: baseAlpha,
        time: time,
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
