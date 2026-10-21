// visualizer_scenes.dart — 可视化两个形态的 CustomPainter：
// ①地形/云海：粒子网格山脊，低频能量抬升山体，节拍脉冲造成整体形变
//   （对齐 sonic-topography terrainResponse 的 kickDeform 反应曲线）；
// ②星云：环绕亮核的粒子星环，频段能量驱动半径呼吸，脉冲向外扩散。
//
// 性能约定：静态粒子属性预生成，每帧只做位置计算，全部走
// Canvas.drawPoints 单次调用，无 saveLayer/离屏。

import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

import 'visualizer_settings.dart';

/// 场景绘制输入。
class VisSceneData {
  final List<double> bands; // 0..1 ×64
  final double kickEnvelope; // 0..1 节拍包络
  final double kickDeform; // 0..0.75 地形形变量
  final double rms; // 0..1 整体响度
  final double brightness; // 0..1
  final double depthStrength; // 0..1
  final bool explicitPlot;
  final double time; // 秒
  final VisTheme theme;
  const VisSceneData({
    required this.bands,
    required this.kickEnvelope,
    required this.kickDeform,
    required this.rms,
    required this.brightness,
    required this.depthStrength,
    required this.explicitPlot,
    required this.time,
    required this.theme,
  });
}

Color _withAlpha(int value, double a) {
  final c = Color(value);
  return c.withValues(alpha: a.clamp(0.0, 1.0));
}

// ---------------------------------------------------------------------------
// 地形 / 云海
// ---------------------------------------------------------------------------

class TerrainScenePainter extends CustomPainter {
  final VisSceneData data;
  TerrainScenePainter(this.data);

  static const int _cols = 96;
  static const int _rows = 38;
  static final List<double> _ridgeNoise = _makeRidge();

  /// 山脊静态轮廓（value noise 两层叠加）。
  static List<double> _makeRidge() {
    final rnd = math.Random(7);
    final coarse = List<double>.generate(17, (_) => rnd.nextDouble());
    final fine = List<double>.generate(65, (_) => rnd.nextDouble());
    double sample(List<double> g, double x) {
      final scaled = x * (g.length - 1);
      final i = scaled.floor();
      final f = scaled - i;
      final s = f * f * (3 - 2 * f); // smoothstep
      final a = g[i.clamp(0, g.length - 1)];
      final b = g[(i + 1).clamp(0, g.length - 1)];
      return a + (b - a) * s;
    }

    return List<double>.generate(129, (i) {
      final x = i / 128;
      return sample(coarse, x) * 0.72 + sample(fine, x) * 0.28;
    });
  }

  static double _ridge(double x01) {
    final scaled = x01 * 128;
    final i = scaled.floor();
    final f = scaled - i;
    final a = _ridgeNoise[i.clamp(0, 128)];
    final b = _ridgeNoise[math.min(128, i + 1)];
    return a + (b - a) * f;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final d = data;
    final horizon = size.height * (0.30 + 0.06 * d.depthStrength);
    final floorY = size.height * 0.92;
    final ampBase = size.height * 0.16 * (0.7 + 0.6 * d.brightness);

    // 频段采样：左→右用低→中频段（鼓点集中在左半），能量经检测源增益。
    double bandAt(double x01) {
      final idx = (math.pow(x01, 0.6) * 31).clamp(0, 31).toInt();
      final v = d.bands[idx];
      return v;
    }

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // 显式标绘图：山脊主线条。
    if (d.explicitPlot) {
      final path = Path();
      for (int c = 0; c <= _cols; c++) {
        final x01 = c / _cols;
        final h = _crestHeight(x01, d);
        final p = _project(x01, 0.16 + h, horizon, floorY, size.width, d.depthStrength);
        if (c == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      paint.color = _withAlpha(d.theme.accent, 0.55 + 0.35 * d.brightness);
      canvas.drawPath(path, paint);
    }

    final points = <Offset>[];
    final colors = <int>[];
    for (int r = 0; r < _rows; r++) {
      final z = r / (_rows - 1); // 0 前 → 1 后
      for (int c = 0; c <= _cols; c++) {
        final x01 = c / _cols;
        // 云海蓬松度：脊线高度 + 按深度的频段抖动 + 时间扰动。
        final crest = _crestHeight(x01, d);
        final puff =
            (bandAt((x01 + z * 0.13) % 1.0) * 0.55 + _ridge(x01 * 2.3 + z * 3.1) * 0.30) *
                (1.0 - z * 0.55);
        final h = (crest * 0.85 + puff * 0.5 + d.kickEnvelope * 0.22) *
            (0.55 + 0.45 * (1 - z));
        final p = _project(x01, z, horizon, floorY, size.width, d.depthStrength);
        final y = p.dy - h * ampBase;
        if (y < 0) continue;
        points.add(Offset(p.dx, y));

        // 颜色：近处亮、远处暗；节拍瞬间亮部染强调色。
        final depthAlpha = (0.85 - z * 0.62) * (0.35 + 0.65 * d.brightness);
        final beatGlow = (d.kickEnvelope * 0.45 * (1 - z)).clamp(0.0, 0.45);
        final color = beatGlow > 0.05 && c % 3 == 0
            ? _withAlpha(d.theme.accent, depthAlpha + beatGlow)
            : _withAlpha(d.theme.main, depthAlpha);
        colors.add(color.toARGB32());
      }
    }

    // drawPoints 需要 Paint.color 统一——逐色批量太多 draw call，改为
    // 亮度分层三批（远/中/近）+ 强调色一批，共 4 次 drawPoints。
    _drawBatches(canvas, points, colors, d.theme);
  }

  /// 山脊高度（0..1）：静态脊线 × 低频能量 × kick 形变。
  double _crestHeight(double x01, VisSceneData d) {
    final bass = (d.bands[0] * 0.5 + d.bands[1] * 0.3 + d.bands[2] * 0.2)
        .clamp(0.0, 1.0);
    final ridge = _ridge(x01);
    return (ridge * (0.35 + 0.65 * bass) + d.kickDeform * 0.55 * ridge)
        .clamp(0.0, 1.35);
  }

  /// 简单透视投影：z 0(前)→1(后)，x01 0..1。
  Offset _project(double x01, double z, double horizon, double floorY,
      double width, double depthStrength) {
    final persp = 1.0 / (1.0 + z * (1.2 + depthStrength * 2.6));
    final x = (x01 - 0.5) * width * (0.72 + 0.55 * persp) + width / 2;
    final y = horizon + (floorY - horizon) * (1 - persp) * 0.92;
    return Offset(x, y);
  }

  void _drawBatches(
      Canvas canvas, List<Offset> points, List<int> colors, VisTheme theme) {
    // 按 alpha 分四档批量绘制。
    final buckets = List.generate(4, (_) => <Offset>[]);
    final alphas = <double>[0.10, 0.24, 0.44, 0.72];
    for (int i = 0; i < points.length; i++) {
      final a = Color(colors[i]).a;
      int bucket = 0;
      double best = 999;
      for (int b = 0; b < alphas.length; b++) {
        final diff = (a - alphas[b]).abs();
        if (diff < best) {
          best = diff;
          bucket = b;
        }
      }
      buckets[bucket].add(points[i]);
    }
    for (int b = 0; b < buckets.length; b++) {
      if (buckets[b].isEmpty) continue;
      final paint = Paint()
        ..color = _withAlpha(theme.main, alphas[b])
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      canvas.drawPoints(PointMode.points, buckets[b], paint);
    }
  }

  @override
  bool shouldRepaint(covariant TerrainScenePainter old) => true;
}

// ---------------------------------------------------------------------------
// 星云
// ---------------------------------------------------------------------------

class _NebulaParticle {
  final double angle;
  final double radiusRatio; // 0 中心 → 1 边缘
  final int bandSlot;
  final double speed;
  final double sizeJitter;
  const _NebulaParticle(this.angle, this.radiusRatio, this.bandSlot, this.speed, this.sizeJitter);
}

class NebulaScenePainter extends CustomPainter {
  final VisSceneData data;
  NebulaScenePainter(this.data);

  static final List<_NebulaParticle> _particles = _makeParticles();

  static List<_NebulaParticle> _makeParticles() {
    final rnd = math.Random(42);
    return List.generate(2600, (i) {
      // 半径分布向中心聚拢（幂分布）。
      final rr = math.pow(rnd.nextDouble(), 1.6).toDouble();
      return _NebulaParticle(
        rnd.nextDouble() * math.pi * 2,
        rr,
        (math.pow(rnd.nextDouble(), 1.8) * 40).clamp(0, 39).toInt(),
        (0.05 + rnd.nextDouble() * 0.16) * (rnd.nextBool() ? 1 : -1),
        0.6 + rnd.nextDouble() * 0.9,
      );
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final d = data;
    final center = Offset(size.width / 2, size.height * 0.46);
    final maxR = math.min(size.width, size.height) * 0.46;
    final t = d.time;

    // 亮核：多层径向渐变圆。
    final coreGlow = (0.35 + 0.4 * d.rms + 0.35 * d.kickEnvelope)
        .clamp(0.0, 1.0) * (0.4 + 0.6 * d.brightness);
    final coreRect = Rect.fromCircle(center: center, radius: maxR * 0.5);
    final corePaint = Paint()
      ..shader = RadialGradient(
        colors: [
          _withAlpha(d.theme.accent, (0.30 * coreGlow).clamp(0.0, 1.0)),
          _withAlpha(d.theme.main, (0.10 * coreGlow).clamp(0.0, 1.0)),
          _withAlpha(d.theme.main, 0),
        ],
        stops: const [0.0, 0.35, 1.0],
      ).createShader(coreRect);
    canvas.drawCircle(center, maxR * 0.5, corePaint);

    // 显式标绘图：2 圈脉冲环。
    if (d.explicitPlot) {
      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = _withAlpha(d.theme.accent, 0.25 + 0.4 * d.kickEnvelope);
      canvas.drawCircle(center, maxR * (0.62 + d.kickEnvelope * 0.12), ringPaint);
      canvas.drawCircle(center, maxR * (0.42 + d.kickEnvelope * 0.1),
          ringPaint..color = _withAlpha(d.theme.accent, 0.18));
    }

    // 粒子：半径 = 基础 × 能量呼吸 + 脉冲外扩；角度随时间缓旋。
    final points = <Offset>[];
    final radii = <double>[];
    final basePulse = 1.0 + d.kickEnvelope * 0.16;
    for (final p in _particles) {
      final band = d.bands[p.bandSlot];
      final r = maxR *
          (0.16 + 0.84 * p.radiusRatio) *
          basePulse *
          (0.82 + 0.5 * band * (1.1 - p.radiusRatio));
      final ang = p.angle + t * p.speed * (0.4 + band * 1.2);
      points.add(Offset(
        center.dx + math.cos(ang) * r,
        center.dy + math.sin(ang) * r * 0.86, // 轻微椭圆更贴视频观感
      ));
      radii.add(p.sizeJitter);
    }

    // 三档亮度批量 + 强调色内圈一批。
    final inner = <Offset>[];
    final outer = <Offset>[];
    for (int i = 0; i < points.length; i++) {
      // 与生成顺序对应：radiusRatio < 0.35 视为内圈（存于 bandSlot 无关），
      // 这里用与中心距离近似判断。
      final dist = (points[i] - center).distance;
      if (dist < maxR * 0.45) {
        inner.add(points[i]);
      } else {
        outer.add(points[i]);
      }
    }
    final alphaBase = 0.28 + 0.52 * d.brightness;
    if (outer.isNotEmpty) {
      canvas.drawPoints(
        PointMode.points,
        outer,
        Paint()
          ..color = _withAlpha(d.theme.main, alphaBase * 0.55)
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }
    if (inner.isNotEmpty) {
      canvas.drawPoints(
        PointMode.points,
        inner,
        Paint()
          ..color = _withAlpha(d.theme.main, alphaBase)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant NebulaScenePainter old) => true;
}
