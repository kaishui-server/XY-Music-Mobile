// visualizer_scenes.dart — 可视化两个形态的场景渲染（5534 重写）。
//
// ①地形/云海：盒体柱状网格的 3D 渲染，顶点位移与着色公式 1:1 对齐
//   sonic-topography CustomShaderMaterial.ts 的 MapShaderMaterial：
//   - idle 海面（simplex + 行波，globalFalloff）
//   - 五频段分区抬升（subBass 中心重/ bass 噪声块 / lowMid 流动波 /
//     mid 对角河流 / highMid 散射尖刺）
//   - 噪声门限 max(0, elev-0.2)（静音时地面完全平坦）
//   - ripple 高斯环扩散（彩色 kick 波 + 白色锐波）
//   - 顶面发光 + 侧面暗柱 + 距离雾（远处 alpha 淡出）
//   - 专辑封面幽灵层（140×140 平面 @ (110,24,-110) rotY(-45°)，
//     对齐 MapScene 的 COVER_SCREEN_POSITION/ROTATION）
//   渲染走 CPU 投影 + ui.Vertices 单次提交，无 saveLayer。
//
// ②星云：对数螺旋星系盘（双臂 + 差速旋转 + 亮核呼吸 + 频段外扩 +
//   beat/点击脉冲环），粒子静态属性预生成，每帧只做位置计算。

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

import 'visualizer_engine.dart';
import 'visualizer_settings.dart';

/// 每帧渲染输入。
class VisFrame {
  final List<double> bands; // 64 段（已平滑+检测源增益）
  final double kickEnvelope; // 0..1 节拍包络
  final double rms; // 0..1 整体响度
  final double time; // 秒（真实时间流）
  final double blockPulse; // 悬浮方块脉冲（kickEnvelope 按「速度」平滑）
  final VisualizerSettings settings;
  final OrbitCamera camera;
  final VisRippleBuffer ripples;
  final ui.Image? coverImage; // 预处理后的封面幽灵图
  final List<VisMeteor> meteors; // 活跃流星
  const VisFrame({
    required this.bands,
    required this.kickEnvelope,
    required this.rms,
    required this.time,
    required this.blockPulse,
    required this.settings,
    required this.camera,
    required this.ripples,
    required this.coverImage,
    required this.meteors,
  });

  /// 单段地形均衡器曲线（对齐 groundEqSettings.applyGroundEqBandValue）：
  /// 默认 50 → ×1.0；>50 增益 ×(1+delta·1.8)；<50 衰减；关闭 → 0。
  double eqCurve(int i) {
    if (i < 0 || i >= settings.groundEq.length) return 0;
    final b = settings.groundEq[i];
    if (!b.on) return 0;
    final d = (b.value - 50) / 50;
    return d >= 0 ? 1 + d * 1.8 : (1 - d * 0.35) * (1 - d * 0.35);
  }

  /// 亮度感 = 高三段 EQ 曲线值占全段之和的比例
  /// （对齐 MapScene uBrightness 的占比公式）。
  double get brightness {
    final hi = eqCurve(5) + eqCurve(6) + eqCurve(7);
    var sum = 0.0;
    for (var i = 0; i < 8; i++) {
      sum += eqCurve(i);
    }
    return (hi / math.max(0.001, sum)).clamp(0.0, 1.0);
  }
}

Color _withAlpha(int value, double a) {
  final c = Color(value);
  return c.withValues(alpha: a.clamp(0.0, 1.0));
}

// ---------------------------------------------------------------------------
// 主题 → shader 调色板（对齐 MapShaderMaterial 默认色 + VisTheme 映射）
// ---------------------------------------------------------------------------

class _Palette {
  final double b1r, b1g, b1b; // uBaseColor1（极暗底）
  final double b2r, b2g, b2b; // uBaseColor2
  final double ccR, ccG, ccB; // coolCore
  final double ceR, ceG, ceB; // coolEdge
  final double wcR, wcG, wcB; // warmCore
  final double weR, weG, weB; // warmEdge
  final double rpR, rpG, rpB; // rippleColor
  const _Palette(
      this.b1r, this.b1g, this.b1b,
      this.b2r, this.b2g, this.b2b,
      this.ccR, this.ccG, this.ccB,
      this.ceR, this.ceG, this.ceB,
      this.wcR, this.wcG, this.wcB,
      this.weR, this.weG, this.weB,
      this.rpR, this.rpG, this.rpB);
}

_Palette _paletteFor(VisTheme theme) {
  final dim = Color(theme.dim);
  final main = Color(theme.main);
  final accent = Color(theme.accent);
  double dr(int v) => v / 255;
  // base1/2：由 dim 深化（对齐默认 (0.01,0.02,0.04)/(0.03,0.05,0.09) 的暗度级别）。
  double d1(int v) => dr(v) * 0.16;
  double d2(int v) => dr(v) * 0.34;
  // warm 系：从 accent/main 向暖色收敛（对齐默认 warmCore(1,.2,.1)/warmEdge(1,.6,0)）。
  double mixc(double a, double b, double t) => a + (b - a) * t;
  return _Palette(
    d1(dim.red), d1(dim.green), d1(dim.blue),
    d2(dim.red), d2(dim.green), d2(dim.blue),
    dr(accent.red), dr(accent.green), dr(accent.blue),
    dr(main.red), dr(main.green), dr(main.blue),
    mixc(dr(accent.red), 1.0, 0.7), mixc(dr(accent.green), 0.2, 0.7),
    mixc(dr(accent.blue), 0.1, 0.7),
    mixc(dr(main.red), 1.0, 0.7), mixc(dr(main.green), 0.6, 0.7),
    mixc(dr(main.blue), 0.0, 0.7),
    dr(accent.red), dr(accent.green), dr(accent.blue),
  );
}

int _argb(double a, double r, double g, double b) {
  int ai = (a.clamp(0, 1) * 255).round();
  int ri = (r.clamp(0, 1) * 255).round();
  int gi = (g.clamp(0, 1) * 255).round();
  int bi = (b.clamp(0, 1) * 255).round();
  return (ai << 24) | (ri << 16) | (gi << 8) | bi;
}

// ---------------------------------------------------------------------------
// 地形网格静态缓存（每密度一份，rnd/midS 等不随时间变化）
// ---------------------------------------------------------------------------

class _TerrainGrid {
  final int n;
  final double spacing;
  final double halfW;
  final Float64List px, pz, dist, falloff, rnd, bassGate, midS, rnd11, rnd77;
  final Uint8List spikeFlag;

  const _TerrainGrid._(this.n, this.spacing, this.halfW, this.px, this.pz,
      this.dist, this.falloff, this.rnd, this.bassGate, this.midS, this.rnd11,
      this.rnd77, this.spikeFlag);

  static final Map<int, _TerrainGrid> _cache = {};

  /// density 0..100 → n 48..96（对齐 deriveTerrainGridSettings 的映射，
  /// 网格规模按移动端性能收敛）。
  static int gridSizeFor(int density) =>
      (48 + (96 - 48) * density.clamp(0, 100) / 100).round();

  factory _TerrainGrid.forDensity(int density) {
    final n = gridSizeFor(density);
    return _cache.putIfAbsent(n, () => _build(n));
  }

  static _TerrainGrid _build(int n) {
    const baseSize = 168.0;
    final spacing = baseSize / n;
    final halfW = spacing * 0.9 / 1.05 / 2; // boxWidth = spacing*0.857
    final offset = n * spacing / 2;
    final count = n * n;
    final px = Float64List(count);
    final pz = Float64List(count);
    final dist = Float64List(count);
    final falloff = Float64List(count);
    final rnd = Float64List(count);
    final bassGate = Float64List(count);
    final midS = Float64List(count);
    final rnd11 = Float64List(count);
    final rnd77 = Float64List(count);
    final spike = Uint8List(count);
    for (int x = 0; x < n; x++) {
      for (int z = 0; z < n; z++) {
        final i = x * n + z;
        final wx = x * spacing - offset;
        final wz = z * spacing - offset;
        px[i] = wx;
        pz[i] = wz;
        final d = math.sqrt(wx * wx + wz * wz);
        dist[i] = d;
        falloff[i] = glslSmoothstep(60, 30, d);
        final r = glslHash(wx, wz);
        rnd[i] = r;
        // smoothstep(0,1, rnd + uDensity*0.5)；uDensity（音色密度）取固定 0.35。
        bassGate[i] = glslSmoothstep(0, 1, r + 0.35);
        midS[i] = snoise2D(wx * 0.1, wz * 0.1);
        rnd11[i] = glslFract(r * 11.0);
        rnd77[i] = glslFract(r * 7.7);
        spike[i] = glslFract(r * 13.3) > 0.8 ? 1 : 0;
      }
    }
    return _TerrainGrid._(
        n, spacing, halfW, px, pz, dist, falloff, rnd, bassGate, midS, rnd11,
        rnd77, spike);
  }
}

// ---------------------------------------------------------------------------
// 悬浮方块预生成（静态属性：位置/相位/自旋/尺寸抖动）
// ---------------------------------------------------------------------------

class Offset3 {
  final double x, y, z;
  const Offset3(this.x, this.y, this.z);
}

class _Block {
  final double x, z, baseY, baseScale, phase, spd;
  const _Block(this.x, this.z, this.baseY, this.baseScale, this.phase,
      this.spd);
}

final List<_Block> _blocks = _makeBlocks();

/// 对齐 MapScene floatingBlocks：五圈螺旋环形分布（半径 14..75、高度
/// 6..24、基准尺寸 0.75..1.15、确定性伪随机相位/自旋）。
List<_Block> _makeBlocks() {
  const count = 120;
  return List.generate(count, (i) {
    final ring = i / count;
    final angle = ring * math.pi * 2 * 5.0 + math.sin(i * 12.9898) * 0.7;
    final radius = 14.0 + (i * 37) % 62;
    final height = 6.0 + (i * 17) % 19;
    return _Block(
      math.cos(angle) * radius,
      math.sin(angle) * radius,
      height,
      0.75 + (i * 11) % 9 * 0.05,
      i * 0.73,
      0.18 + (i * 7) % 10 * 0.035,
    );
  });
}

// ---------------------------------------------------------------------------
// 地形 / 云海
// ---------------------------------------------------------------------------

class TerrainScenePainter extends CustomPainter {
  final VisFrame f;
  TerrainScenePainter(this.f, {super.repaint});

  @override
  void paint(Canvas canvas, Size size) {
    final rig = CameraRig(f.camera, size);
    final a = BandPartition.of(f.bands);
    final pal = _paletteFor(f.settings.theme);
    final grid = _TerrainGrid.forDensity(f.settings.terrainDensity);
    final t = f.time;
    // 地形均衡器：sub/bass 走 terrainResponse.deriveKickFollowLowBands 的
    // 加法混合（kick 节拍包络主导：1.28/1.15，频段能量基底 0.22/0.20），
    // 再按 EQ delta 曲线缩放（默认 50 → ×1.0）；中频段直接乘 EQ 曲线。
    final kickNorm = (f.kickEnvelope / 0.75).clamp(0.0, 1.0);
    double lowMix(double energy, double baseGain, double kickGain, int i,
        double maxV) {
      final b = f.settings.groundEq[i];
      if (!b.on) return 0;
      final d = (b.value - 50) / 50;
      final raw = energy * baseGain + kickNorm * kickGain;
      final v = d >= 0
          ? raw * (1 + d * 1.8)
          : math.max(0, raw + d * 0.35) * (1 + d * 0.35);
      return math.min(v, maxV);
    }

    final subU = lowMix(a.subBass, 0.22, 1.28, 0, 1.2);
    final bassU = lowMix(a.bass, 0.20, 1.15, 1, 1.15);
    final gLowMid = f.eqCurve(2);
    final gMid = f.eqCurve(3);
    final gHighMid = f.eqCurve(4);

    final warmth = a.warmth;
    final uBrightness = f.brightness;
    // 振幅：≤50 线性衰减到 0；>50 平方放最大到 15×（对齐 MapScene）。
    final amp = f.settings.amplitude <= 50
        ? f.settings.amplitude / 50
        : 1.0 +
            math.pow((f.settings.amplitude - 50) / 50, 2).toDouble() * 14.0;

    // 活跃 ripple 列表（避免每柱体扫 10 槽）。
    final act = <VisRipple>[];
    for (final r in f.ripples.slots) {
      if (r.active && t - r.t0 < 5.0) act.add(r);
    }

    // 顶面颜色常量（不随柱体变化的中间量）。
    final brightCoolR = pal.ccR + (1.0 - pal.ccR) * 0.24;
    final brightCoolG = pal.ccG + (1.0 - pal.ccG) * 0.24;
    final brightCoolB = pal.ccB + (1.0 - pal.ccB) * 0.24;
    final atmosR = pal.b1r + (pal.b2r - pal.b1r) * 0.4;
    final atmosG = pal.b1g + (pal.b2g - pal.b1g) * 0.4;
    final atmosB = pal.b1b + (pal.b2b - pal.b1b) * 0.4;
    // 可见侧面（法线朝相机的两个正交面）由 fxSign/fzSign 决定；
    // sideGlow 顶缘强度 = normElev×1.5（uSharpness 取 0.35 的简化）。

    // —— 第一遍：逐柱体算高度/颜色/深度 ——
    final n2 = grid.n * grid.n;
    final depths = Float64List(n2);
    final heights = Float64List(n2);
    final topCols = Int32List(n2);
    final sideTopCols = Int32List(n2);
    final sideBotCols = Int32List(n2);
    final order = <int>[];

    for (int i = 0; i < n2; i++) {
      final d = grid.dist[i];
      // 距离雾 alpha（对齐 alphaFade=1-smoothstep(55,78,vDistance)）。
      final alpha = 1.0 - glslSmoothstep(55, 78, d);
      if (alpha <= 0.015) continue;

      final wx = grid.px[i];
      final wz = grid.pz[i];
      final falloff = grid.falloff[i];

      // ① idle 海面。
      final baseNoise =
          (snoise2D(wx * 0.05 + t * 0.1, wz * 0.05 + t * 0.05) + 1) * 0.5;
      final wave = math.sin(wx * 0.15 + wz * 0.1 - t * 0.6) * 0.5 + 0.5;
      final idle = (baseNoise + (wave - baseNoise) * 0.45) * 0.8 * falloff;

      // ② 五频段分区抬升（受地形均衡器增益与总振幅控制）。
      var audio = subU * glslSmoothstep(25, 0, d) * 5.0 +
          bassU *
              glslSmoothstep(
                  35, 5, d + snoise2D(wx * 0.1, wz * 0.1 - t * 0.2) * 5) *
              grid.bassGate[i] *
              4.0 +
          a.lowMid *
              gLowMid *
              (snoise2D(wx * 0.05 + t * 0.1, wz * 0.05) * 0.5 + 0.5) *
              2.5 +
          a.mid *
              gMid *
              math.max(0.0,
                  math.sin(wx * 0.2 + wz * 0.2 + grid.midS[i] * 2.0 - t * 2.0)) *
              3.0;
      if (grid.spikeFlag[i] == 1) {
        audio += a.highMid * gHighMid * glslSmoothstep(10, 45, d) *
            grid.rnd77[i] * 2.5;
      }
      audio *= falloff * amp;
      audio = math.max(0.0, audio - 0.2); // 噪声门限

      // ③ ripple 高斯环。
      double rippleElev = 0;
      double ripN = 0;
      double ripW = 0;
      for (int k = 0; k < act.length; k++) {
        final r = act[k];
        final ddx = wx - r.x;
        final ddz = wz - r.z;
        final dd = math.sqrt(ddx * ddx + ddz * ddz);
        final speed = r.white ? 20.0 : 15.0;
        final width = r.white ? 1.0 : 3.0;
        final fadeDist = r.white ? 8.0 : 15.0;
        final elevScale = r.white ? 1.0 : 4.0;
        final radius = (t - r.t0) * speed;
        if (radius < 0) continue;
        final ring = dd - radius;
        if (ring > 3 * math.sqrt(width) || ring < -3 * math.sqrt(width)) {
          continue;
        }
        final pulse =
            math.exp(-ring * ring / width) * math.exp(-radius / fadeDist) *
                r.strength;
        rippleElev += pulse * elevScale;
        if (r.white) {
          ripW += pulse;
        } else {
          ripN += pulse;
        }
      }
      ripN = ripN.clamp(0.0, 1.0);
      ripW = ripW.clamp(0.0, 1.0);

      final elev = idle + audio + rippleElev;
      final normElev = (elev / 8.0).clamp(0.0, 1.0);

      // —— 着色（对齐 fragment shader）——
      final distFade = 1.0 - glslSmoothstep(40, 75, d);
      final warmBlend = glslSmoothstep(0, 1, warmth * 1.5 + (0.5 - d / 80));
      final zcR = pal.ccR + (pal.wcR - pal.ccR) * warmBlend;
      final zcG = pal.ccG + (pal.wcG - pal.ccG) * warmBlend;
      final zcB = pal.ccB + (pal.wcB - pal.ccB) * warmBlend;
      final zeR = pal.ceR + (pal.weR - pal.ceR) * warmBlend;
      final zeG = pal.ceG + (pal.weG - pal.ceG) * warmBlend;
      final zeB = pal.ceB + (pal.weB - pal.ceB) * warmBlend;
      var tgR = zcR + (zeR - zcR) * grid.rnd11[i];
      var tgG = zcG + (zeG - zcG) * grid.rnd11[i];
      var tgB = zcB + (zeB - zcB) * grid.rnd11[i];
      tgR += (brightCoolR - tgR) * uBrightness * 0.6;
      tgG += (brightCoolG - tgG) * uBrightness * 0.6;
      tgB += (brightCoolB - tgB) * uBrightness * 0.6;
      // glow = mix(base2, targetGlow, normElev) * distFade
      final glowR = (pal.b2r + (tgR - pal.b2r) * normElev) * distFade;
      final glowG = (pal.b2g + (tgG - pal.b2g) * normElev) * distFade;
      final glowB = (pal.b2b + (tgB - pal.b2b) * normElev) * distFade;
      // 顶面：topIntensity = smoothstep(0, 0.4, normElev)
      final topInt = glslSmoothstep(0, 0.4, normElev);
      var cR = pal.b2r + (glowR - pal.b2r) * topInt;
      var cG = pal.b2g + (glowG - pal.b2g) * topInt;
      var cB = pal.b2b + (glowB - pal.b2b) * topInt;
      // ripple 颜色覆盖。
      cR += (pal.rpR - cR) * ripN;
      cG += (pal.rpG - cG) * ripN;
      cB += (pal.rpB - cB) * ripN;
      cR += (1.0 - cR) * ripW;
      cG += (1.0 - cG) * ripW;
      cB += (1.0 - cB) * ripW;
      // aerial fog。
      final fogT = glslSmoothstep(30, 65, d) * 0.35;
      cR += (atmosR - cR) * fogT;
      cG += (atmosG - cG) * fogT;
      cB += (atmosB - cB) * fogT;

      // 侧面：顶缘混 glow（sideGlow 顶缘=1×normElev×1.5），底部回 base1。
      final sideTopInt = (normElev * 1.5).clamp(0.0, 1.0);
      var sTopR = (pal.b1r + (pal.b2r - pal.b1r) * distFade) +
          (glowR - pal.b2r) * sideTopInt;
      var sTopG = (pal.b1g + (pal.b2g - pal.b1g) * distFade) +
          (glowG - pal.b2g) * sideTopInt;
      var sTopB = (pal.b1b + (pal.b2b - pal.b1b) * distFade) +
          (glowB - pal.b2b) * sideTopInt;
      sTopR += (pal.rpR - sTopR) * ripN;
      sTopG += (pal.rpG - sTopG) * ripN;
      sTopB += (pal.rpB - sTopB) * ripN;
      final sBotR = pal.b1r, sBotG = pal.b1g, sBotB = pal.b1b;
      // 侧面同样 aerial fog。
      sTopR += (atmosR - sTopR) * fogT;
      sTopG += (atmosG - sTopG) * fogT;
      sTopB += (atmosB - sTopB) * fogT;

      depths[i] = rig.depthOf(wx, 0, wz);
      heights[i] = 1.0 + elev;
      topCols[i] = _argb(alpha, cR, cG, cB);
      sideTopCols[i] = _argb(alpha, sTopR, sTopG, sTopB);
      sideBotCols[i] = _argb(alpha * 0.9, sBotR, sBotG, sBotB);
      order.add(i);
    }

    // —— 封面幽灵层（在柱体之前绘制：位于地形后方，被近处柱体遮出层次）——
    _paintCover(canvas, rig, a);

    // —— 第二遍：从远到近排序后一次 drawVertices ——
    order.sort((ia, ib) => depths[ib].compareTo(depths[ia]));
    final vertsPerCol = 18; // 顶面 6 + 两侧面 12
    final positions = Float32List(order.length * vertsPerCol * 2);
    final colors = Int32List(order.length * vertsPerCol);
    var vi = 0;
    var ci = 0;
    final hw = grid.halfW;
    final sinT = math.sin(f.camera.theta);
    final cosT = math.cos(f.camera.theta);
    final fxSign = sinT >= 0 ? 1 : -1;
    final fzSign = cosT >= 0 ? 1 : -1;

    void emit(Offset p, int color) {
      positions[vi++] = p.dx;
      positions[vi++] = p.dy;
      colors[ci++] = color;
    }

    for (final i in order) {
      final wx = grid.px[i];
      final wz = grid.pz[i];
      final h = heights[i];
      final top = topCols[i];
      final sTop = sideTopCols[i];
      final sBot = sideBotCols[i];
      // 四个顶角。
      final pa = rig.project(wx - hw, h, wz - hw);
      final pb = rig.project(wx + hw, h, wz - hw);
      final pc = rig.project(wx + hw, h, wz + hw);
      final pd = rig.project(wx - hw, h, wz + hw);
      if (pa == null || pb == null || pc == null || pd == null) continue;
      // 可见侧面（法线朝相机的两个正交面），顶/底点按 x(或 z) 端点显式取，
      // 保证顶底一一配对。
      final exX = wx + fxSign * hw; // X 面外沿 x
      final ezZ = wz + fzSign * hw; // Z 面外沿 z
      final tx0 = rig.project(exX, h, wz - hw);
      final tx1 = rig.project(exX, h, wz + hw);
      final bx0 = rig.project(exX, 0, wz - hw);
      final bx1 = rig.project(exX, 0, wz + hw);
      final tz0 = rig.project(wx + hw, h, ezZ);
      final tz1 = rig.project(wx - hw, h, ezZ);
      final bz0 = rig.project(wx + hw, 0, ezZ);
      final bz1 = rig.project(wx - hw, 0, ezZ);
      if (tx0 == null ||
          tx1 == null ||
          bx0 == null ||
          bx1 == null ||
          tz0 == null ||
          tz1 == null ||
          bz0 == null ||
          bz1 == null) {
        continue;
      }

      // 顶面两三角（A,B,C + A,C,D）。
      emit(pa, top); emit(pb, top); emit(pc, top);
      emit(pa, top); emit(pc, top); emit(pd, top);
      // X 侧面两三角（顶0,顶1,底1 + 顶0,底1,底0）。
      emit(tx0, sTop); emit(tx1, sTop); emit(bx1, sBot);
      emit(tx0, sTop); emit(bx1, sBot); emit(bx0, sBot);
      // Z 侧面两三角。
      emit(tz0, sTop); emit(tz1, sTop); emit(bz1, sBot);
      emit(tz0, sTop); emit(bz1, sBot); emit(bz0, sBot);
    }

    if (vi > 0) {
      final vertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        positions.sublist(0, vi),
        colors: colors.sublist(0, ci),
      );
      canvas.drawVertices(vertices, ui.BlendMode.srcOver, Paint());
      vertices.dispose();
    }

    // —— 悬浮方块（地形上空漂浮的发光立方体群）——
    if (f.settings.blocksEnabled) {
      _paintBlocks(canvas, rig, a, t);
    }
    // —— 流星（触发器生成的飞行光点）——
    _paintMeteors(canvas, rig, t);
  }

  // -----------------------------------------------------------------------
  // 悬浮方块：数量随强度（默认 80）、脉冲尺寸/抬升随 kick 包络平滑值。
  // -----------------------------------------------------------------------
  void _paintBlocks(
      Canvas canvas, CameraRig rig, BandPartition a, double t) {
    final s = f.settings;
    // 数量：默认强度 55 → 80 个（对齐 DEFAULT_FLOATING_BLOCK_COUNT）。
    final count = (80 * s.blockIntensity / 55).round().clamp(0, 120);
    // 脉冲尺寸混合（对齐 MapScene floatingBlock）：
    // sizeMix = pulse·(0.5 + intensity·1.7) → pulseScale lerp(min, max)。
    final intensity = s.blockIntensity / 100;
    final pulse = f.blockPulse;
    final sizeMix = (pulse * (0.5 + intensity * 1.7)).clamp(0.0, 1.0);
    // 尺寸映射回世界单位量级（静止即可见，脉冲时放大）：
    // min 0.9+2.0·minSize%，max 1.4+3.6·maxSize%（默认 9/26 → 1.08/2.34）。
    final minVisual = 0.9 + 2.0 * s.blockMinSize / 100;
    final maxVisual = math.max(
        minVisual + 0.3, 1.4 + 3.6 * s.blockMaxSize / 100);
    final pulseScale = minVisual + (maxVisual - minVisual) * sizeMix;

    for (int bi = 0; bi < count && bi < _blocks.length; bi++) {
      final b = _blocks[bi];
      final half = b.baseScale * pulseScale / 2;
      // 浮动：小幅正弦漂移（±0.45）+ kick 脉冲抬升。
      final bob = math.sin(t * (0.55 + b.spd) + b.phase) * 0.45;
      final cy = b.baseY + bob + pulse * intensity * 1.4;
      // 旋转（慢速自旋）。
      final ang = t * b.spd + b.phase;
      final ca = math.cos(ang), sa = math.sin(ang);
      // 距离雾（与柱体一致）。
      final dc = math.sqrt(b.x * b.x + b.z * b.z);
      final alpha = 1.0 - glslSmoothstep(55, 78, dc);
      if (alpha <= 0.03) continue;

      // 8 顶点（rotY 后）。
      final corners = <Offset3>[];
      for (int ci2 = 0; ci2 < 8; ci2++) {
        final lx = ((ci2 & 1) == 0 ? -half : half);
        final ly = ((ci2 & 2) == 0 ? -half : half);
        final lz = ((ci2 & 4) == 0 ? -half : half);
        corners.add(Offset3(
          b.x + lx * ca + lz * sa,
          cy + ly,
          b.z + -lx * sa + lz * ca,
        ));
      }
      // 6 面（索引 + 外法线）。
      const faces = <List<int>>[
        [0, 1, 3, 2], // -Y 底
        [4, 6, 7, 5], // +Y 顶
        [0, 4, 5, 1], // -Z
        [2, 3, 7, 6], // +Z
        [0, 2, 6, 4], // -X
        [1, 5, 7, 3], // +X
      ];
      const norms = <Offset3>[
        Offset3(0, -1, 0),
        Offset3(0, 1, 0),
        Offset3(0, 0, -1),
        Offset3(0, 0, 1),
        Offset3(-1, 0, 0),
        Offset3(1, 0, 0),
      ];
      // 面颜色：顶面最亮，侧面随法线方向渐暗；bass 脉冲提亮。
      final glow = (0.30 + 0.45 * intensity +
              (a.bass * 0.5 + pulse * 0.35) * 0.8)
          .clamp(0.0, 1.0);
      final cTop = _withAlpha(0xFFFFFFFF, alpha);
      final cMain =
          _withAlpha(f.settings.theme.accent, alpha * glow);
      final cDark =
          _withAlpha(f.settings.theme.dim, alpha * glow * 0.45);

      // 投影 8 点。
      final proj = <Offset?>[
        for (final c in corners) rig.project(c.x, c.y, c.z),
      ];
      if (proj.any((p) => p == null)) continue;

      // 背面剔除：dot(法线, 相机-面心) > 0 才可见；可见面按深度从远到近。
      final visible = <int>[];
      for (int fi = 0; fi < 6; fi++) {
        final n = norms[fi];
        // 旋转法线。
        final nx = n.x * ca + n.z * sa;
        final nz = -n.x * sa + n.z * ca;
        final fcx = b.x + nx * half;
        final fcy = cy + n.y * half;
        final fcz = b.z + nz * half;
        final vx = rig.px - fcx, vy = rig.py - fcy, vz = rig.pz - fcz;
        if (nx * vx + n.y * vy + nz * vz > 0) visible.add(fi);
      }
      visible.sort((fa, fb) {
        double d(List<int> face) {
          double sum = 0;
          for (final ii in face) {
            sum += rig.depthOf(corners[ii].x, corners[ii].y, corners[ii].z);
          }
          return sum / face.length;
        }

        return d(faces[fb]).compareTo(d(faces[fa]));
      });
      final path = Path();
      for (final fi in visible) {
        final face = faces[fi];
        final p0 = proj[face[0]]!;
        path.moveTo(p0.dx, p0.dy);
        for (int k = 1; k < 4; k++) {
          path.lineTo(proj[face[k]]!.dx, proj[face[k]]!.dy);
        }
        path.close();
        // 顶面/主色/暗面：+Y 用白亮，-Y 用暗，侧面用主色。
        final color = fi == 1
            ? cTop
            : (fi == 0
                ? cDark
                : cMain);
        canvas.drawPath(path, Paint()..color = color);
        // 顶缘描一条亮线增强发光感。
        if (fi == 1) {
          canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.8
              ..color = _withAlpha(f.settings.theme.accent, alpha * 0.9),
          );
        }
      }
    }
  }

  // -----------------------------------------------------------------------
  // 流星：世界坐标飞行光点 + 拖尾，越老越淡。
  // -----------------------------------------------------------------------
  void _paintMeteors(Canvas canvas, CameraRig rig, double t) {
    final accent = f.settings.theme.accent;
    for (final m in f.meteors) {
      final dt = t - m.t0;
      if (dt < 0) continue;
      final px = m.x + m.vx * dt;
      final py = m.y + m.vy * dt;
      final pz = m.z + m.vz * dt;
      if (py < 0 || dt > 3.2) continue;
      const tail = 0.16; // 拖尾秒数
      final head = rig.project(px, py, pz);
      final tailP = rig.project(
          px - m.vx * tail, py - m.vy * tail, pz - m.vz * tail);
      if (head == null || tailP == null) continue;
      final fade = (math.exp(-dt * 1.1) * m.strength).clamp(0.0, 1.0);
      // 拖尾：三段渐细。
      final paint = Paint()
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      for (int k = 0; k < 3; k++) {
        final t0 = tail * k / 3, t1 = tail * (k + 1) / 3;
        final a0 = rig.project(px - m.vx * t0, py - m.vy * t0,
            pz - m.vz * t0);
        final a1 = rig.project(px - m.vx * t1, py - m.vy * t1,
            pz - m.vz * t1);
        if (a0 == null || a1 == null) continue;
        paint.strokeWidth = 3.2 - k * 0.9;
        paint.color = _withAlpha(k == 0 ? 0xFFFFFFFF : accent,
            fade * (1 - k * 0.28));
        canvas.drawLine(a0, a1, paint);
      }
      // 头部光点。
      canvas.drawCircle(
        head,
        2.6,
        Paint()..color = _withAlpha(0xFFFFFFFF, fade),
      );
      canvas.drawCircle(
        head,
        5.5,
        Paint()..color = _withAlpha(accent, fade * 0.35),
      );
    }
  }

  /// 封面幽灵层：140×140 平面 @ (110,24,-110)，rotY(-π/4) 起始、
  /// 按「旋转速度」缓慢自旋；脉冲对齐 MapScene：uPulse = bass*0.4 + subBass*0.2。
  void _paintCover(Canvas canvas, CameraRig rig, BandPartition a) {
    final img = f.coverImage;
    if (img == null || !f.settings.showCover) return;
    final coverPulse = (a.bass * 0.4 + a.subBass * 0.2).clamp(0.0, 1.0);
    // 动态旋转角（rotationSpeed 0.2 → 约 0.12 rad/s）。
    final ang = -math.pi / 4 + f.time * f.settings.rotationSpeed * 0.6;
    final ca = math.cos(ang), sa = math.sin(ang);
    // 四角投影检查（在视野内才画）。
    const cx0 = 110.0, cy0 = 24.0, cz0 = -110.0;
    const half = 70.0;
    final c0 = rig.project(cx0 - half * ca, cy0 + half, cz0 + half * sa);
    final c1 = rig.project(cx0 + half * ca, cy0 + half, cz0 - half * sa);
    final c2 = rig.project(cx0 + half * ca, cy0 - half, cz0 - half * sa);
    final c3 = rig.project(cx0 - half * ca, cy0 - half, cz0 + half * sa);
    if (c0 == null || c1 == null || c2 == null || c3 == null) return;

    // MVP（column-major）= S(视口) · P(透视) · V(lookAt) · M(模型)。
    final mvp = _coverMvp(rig, ang);
    canvas.save();
    canvas.transform(mvp);
    final bright = 1.0 + coverPulse * 0.8;
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTRB(-half, half, half, -half), // 垂直翻转保证封面正立
      Paint()
        ..filterQuality = FilterQuality.medium
        ..colorFilter = ColorFilter.matrix(<double>[
          bright, 0, 0, 0, 0,
          0, bright, 0, 0, 0,
          0, 0, bright, 0, 0,
          0, 0, 0, 1, 0,
        ]),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant TerrainScenePainter old) => true;
}

/// 4×4 矩阵乘（column-major，a·b）。
Float64List _mat4Mul(Float64List a, Float64List b) {
  final out = Float64List(16);
  for (int c = 0; c < 4; c++) {
    for (int r = 0; r < 4; r++) {
      double s = 0;
      for (int k = 0; k < 4; k++) {
        s += a[k * 4 + r] * b[c * 4 + k];
      }
      out[c * 4 + r] = s;
    }
  }
  return out;
}

/// 封面平面的完整 MVP（透视 fov45 + lookAt + rotY(ang) + 平移 + 视口）。
Float64List _coverMvp(CameraRig rig, double ang) {
  const near = 0.5, far = 900.0;
  final fn = 1.0 / rig.tanHalfFov;
  final aspect = rig.aspect;
  final p = Float64List.fromList(<double>[
    fn / aspect, 0, 0, 0,
    0, fn, 0, 0,
    0, 0, (far + near) / (near - far), -1,
    0, 0, 2 * far * near / (near - far), 0,
  ]);
  // lookAt：basis r/u/f，行 [r;-r·p][u;-u·p][-f;f·p]。
  final rp = rig.rx * rig.px + rig.ry * rig.py + rig.rz * rig.pz;
  final up = rig.ux * rig.px + rig.uy * rig.py + rig.uz * rig.pz;
  final fp = -(rig.fx * rig.px + rig.fy * rig.py + rig.fz * rig.pz);
  final v = Float64List.fromList(<double>[
    rig.rx, rig.ux, -rig.fx, 0,
    rig.ry, rig.uy, -rig.fy, 0,
    rig.rz, rig.uz, -rig.fz, 0,
    -rp, -up, fp, 1,
  ]);
  // 模型：rotY(ang) + 平移 (110,24,-110)。
  final k = math.cos(ang);
  final s2 = math.sin(ang);
  final m = Float64List.fromList(<double>[
    k, 0, -s2, 0,
    0, 1, 0, 0,
    s2, 0, k, 0,
    110, 24, -110, 1,
  ]);
  // 视口：x=(x+1)/2*w，y=(1-y)/2*h。
  final s = Float64List.fromList(<double>[
    rig.w / 2, 0, 0, 0,
    0, -rig.h / 2, 0, 0,
    0, 0, 1, 0,
    rig.w / 2, rig.h / 2, 0, 1,
  ]);
  return _mat4Mul(s, _mat4Mul(p, _mat4Mul(v, m)));
}

// ---------------------------------------------------------------------------
// 星云（螺旋星系盘）
// ---------------------------------------------------------------------------

class _NebulaParticle {
  final double angle0;
  final double r01; // 0 中心 → 1 边缘
  final int bandSlot;
  final double size;
  final double brightnessJitter;
  const _NebulaParticle(this.angle0, this.r01, this.bandSlot, this.size,
      this.brightnessJitter);
}

class NebulaScenePainter extends CustomPainter {
  final VisFrame f;
  NebulaScenePainter(this.f, {super.repaint});

  static final List<_NebulaParticle> _particles = _makeParticles();
  static final List<Offset> _bgStars = _makeStars();

  /// 双臂对数螺旋 + 中心核球聚集。
  static List<_NebulaParticle> _makeParticles() {
    final rnd = math.Random(20260421);
    final list = <_NebulaParticle>[];
    for (int i = 0; i < 2400; i++) {
      final isBulge = rnd.nextDouble() < 0.18; // 18% 核球
      final double r01;
      final double ang;
      if (isBulge) {
        r01 = math.pow(rnd.nextDouble(), 2.2) * 0.22;
        ang = rnd.nextDouble() * math.pi * 2;
      } else {
        r01 = 0.10 + 0.90 * math.pow(rnd.nextDouble(), 0.72);
        final arm = i % 2;
        final jitter = (rnd.nextDouble() - 0.5) *
            (0.55 + 0.85 * (1 - r01)); // 内圈更散
        ang = arm * math.pi + r01 * 4.6 + jitter;
      }
      list.add(_NebulaParticle(
        ang,
        r01,
        (math.pow(rnd.nextDouble(), 1.8) * 40).clamp(0, 39).toInt(),
        0.7 + rnd.nextDouble() * 0.9,
        rnd.nextDouble(),
      ));
    }
    return list;
  }

  static List<Offset> _makeStars() {
    final rnd = math.Random(777);
    return List.generate(260, (i) {
      final a = rnd.nextDouble() * math.pi * 2;
      final r = math.sqrt(rnd.nextDouble());
      return Offset(math.cos(a) * r, math.sin(a) * r);
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final d = f;
    final th = d.settings.theme;
    final center = Offset(size.width / 2, size.height * 0.47);
    final maxR = math.min(size.width, size.height) * 0.46;
    const tilt = 0.62;
    final t = d.time;
    // 背景星野（静态微光）。
    final starPaint = Paint()
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..color = _withAlpha(0xFFFFFFFF, 0.10);
    final starPts = <Offset>[
      for (final s in _bgStars)
        center + Offset(s.dx * maxR * 1.55, s.dy * maxR * 1.55 * tilt),
    ];
    canvas.drawPoints(PointMode.points, starPts, starPaint);

    // 流星（屏幕空间飞行光点，归一化坐标 → maxR 尺度）。
    for (final m in d.meteors) {
      final dt = t - m.t0;
      if (dt < 0 || dt > 3.2) continue;
      final hx = center.dx + (m.x + m.vx * dt) * maxR;
      final hy = center.dy + (m.y + m.vy * dt) * maxR * tilt;
      const tail = 0.16;
      final tx = center.dx + (m.x + m.vx * (dt - tail)) * maxR;
      final ty = center.dy + (m.y + m.vy * (dt - tail)) * maxR * tilt;
      final fade = (math.exp(-dt * 1.1) * m.strength).clamp(0.0, 1.0);
      canvas.drawLine(
        Offset(tx, ty),
        Offset(hx, hy),
        Paint()
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..color = _withAlpha(0xFFFFFFFF, fade * 0.85),
      );
      canvas.drawCircle(
        Offset(hx, hy),
        2.2,
        Paint()..color = _withAlpha(0xFFFFFFFF, fade),
      );
      canvas.drawCircle(
        Offset(hx, hy),
        5.0,
        Paint()..color = _withAlpha(th.accent, fade * 0.3),
      );
    }

    // 脉冲环（beat/点击触发，从中心/落点扩散）。
    for (final r in d.ripples.slots) {
      if (!r.active) continue;
      final dt = t - r.t0;
      if (dt < 0 || dt > 4) continue;
      final ringR = dt * maxR * 0.85;
      final alpha =
          (math.exp(-ringR / (maxR * 0.45)) * r.strength).clamp(0.0, 0.85);
      if (alpha < 0.02) continue;
      final origin = Offset(
        center.dx + r.x * maxR * 0.5,
        center.dy + r.z * maxR * 0.5 * tilt,
      );
      canvas.save();
      canvas.translate(origin.dx, origin.dy);
      canvas.scale(1, tilt);
      canvas.drawCircle(
        Offset.zero,
        ringR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = _withAlpha(r.white ? 0xFFFFFFFF : th.accent, alpha),
      );
      canvas.restore();
    }

    // 亮核：多层径向渐变（白 → accent → 透明），随 rms/kick 呼吸。
    final coreGlow =
        (0.35 + 0.4 * d.rms + 0.45 * d.kickEnvelope).clamp(0.0, 1.1) *
            (0.4 + 0.6 * d.brightness);
    final coreR = maxR * (0.13 + 0.10 * d.rms + 0.07 * d.kickEnvelope);
    final coreRect = Rect.fromCircle(center: center, radius: coreR);
    canvas.drawCircle(
      center,
      coreR,
      Paint()
        ..shader = RadialGradient(colors: [
          _withAlpha(0xFFFFFFFF, (0.85 * coreGlow).clamp(0, 1)),
          _withAlpha(th.accent, (0.40 * coreGlow).clamp(0, 1)),
          _withAlpha(th.main, (0.14 * coreGlow).clamp(0, 1)),
          _withAlpha(th.main, 0),
        ], stops: const [0.0, 0.25, 0.62, 1.0]).createShader(coreRect),
    );
    // 外晕。
    canvas.drawOval(
      Rect.fromCenter(
          center: center,
          width: maxR * 1.5,
          height: maxR * 1.5 * tilt),
      Paint()
        ..shader = RadialGradient(colors: [
          _withAlpha(th.main, (0.10 * coreGlow).clamp(0, 1)),
          _withAlpha(th.main, 0),
        ]).createShader(Rect.fromCircle(center: center, radius: maxR * 0.75)),
    );

    // 粒子：差速旋转（内快外慢）+ 频段径向外扩 + 环 lift。
    final ptsDim = <Offset>[];
    final ptsMid = <Offset>[];
    final ptsHot = <Offset>[];
    for (final p in _particles) {
      final band = d.bands[p.bandSlot];
      final omega = 0.14 / (0.18 + p.r01); // 差速旋转
      final ang = p.angle0 + t * omega;
      var r = maxR *
          (0.05 + 0.95 * p.r01) *
          (1.0 + band * 0.30 * (1.25 - p.r01));
      // 脉冲环对粒子的外推与提亮。
      double lift = 0;
      for (final rp in d.ripples.slots) {
        if (!rp.active) continue;
        final dt = t - rp.t0;
        if (dt < 0 || dt > 3) continue;
        final ringR = dt * maxR * 0.85;
        final pr = p.r01 * maxR;
        final diff = (pr - ringR).abs();
        if (diff < maxR * 0.09) {
          final w = 1 - diff / (maxR * 0.09);
          lift = math.max(
              lift,
              w *
                  math.exp(-ringR / (maxR * 0.5)) *
                  rp.strength);
          r += w * rp.strength * maxR * 0.03;
        }
      }
      final pos = Offset(
        center.dx + math.cos(ang) * r,
        center.dy + math.sin(ang) * r * tilt,
      );
      if (lift > 0.12) {
        ptsHot.add(pos);
      } else if (p.r01 < 0.34 ||
          band > 0.45 ||
          p.brightnessJitter > 0.72) {
        ptsMid.add(pos);
      } else {
        ptsDim.add(pos);
      }
    }
    final aBase = 0.30 + 0.55 * d.brightness;
    void drawPts(List<Offset> pts, Color color, double width) {
      if (pts.isEmpty) return;
      canvas.drawPoints(
        PointMode.points,
        pts,
        Paint()
          ..color = color
          ..strokeWidth = width
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }

    drawPts(ptsDim, _withAlpha(th.dim, aBase * 0.55), 1.1);
    drawPts(ptsMid, _withAlpha(th.main, aBase), 1.5);
    drawPts(ptsHot, _withAlpha(th.accent, (aBase * 0.9 + 0.3).clamp(0, 1)),
        1.8);
  }

  @override
  bool shouldRepaint(covariant NebulaScenePainter old) => true;
}
