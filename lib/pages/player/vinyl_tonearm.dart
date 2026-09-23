import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 黑胶唱针（经典款），一比一复刻自 BakaMusic 的 ClassicVinylTonearm
/// inner reach 变体：viewBox 230x410，pivot 在 SVG 本地 (179, 46) =
/// (77.8%, 11.2%)，摆放到 stage 的 (94%, 5%)。唱臂整体放大 1.108 倍
/// （宽 40.9%），播放 +3 度时针尖深入盘面、落在唱片中心 ~33% 处
/// （标签封面 61.8% 直径之外，不遮挡封面）；暂停 -17 度时悬在盘缘外。
/// 旋转过渡 720ms cubic-bezier(0.3, 1.2, 0.4, 1)，末端轻微回弹。
class VinylTonearm extends StatelessWidget {
  const VinylTonearm({super.key, required this.playing});

  final bool playing;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: playing ? 3.0 : -17.0),
      duration: const Duration(milliseconds: 720),
      curve: const Cubic(0.3, 1.2, 0.4, 1),
      builder: (context, angle, _) => CustomPaint(
        painter: _TonearmPainter(angle),
      ),
    );
  }
}

const Color _armWhite = Color(0xFFF4F5F7);
const Color _armShade = Color.fromRGBO(150, 156, 168, 0.3);
const Color _cartridgeDark = Color(0xFF3A3D44);
const Color _grooveGray = Color(0xFFC4C9D1);

Matrix4 _rotateAround(double cx, double cy, double radians) {
  final m = Matrix4.identity();
  m.multiply(Matrix4.translationValues(cx, cy, 0));
  m.multiply(Matrix4.rotationZ(radians));
  m.multiply(Matrix4.translationValues(-cx, -cy, 0));
  return m;
}

class _TonearmPainter extends CustomPainter {
  const _TonearmPainter(this.angleDeg);

  final double angleDeg;

  @override
  void paint(Canvas canvas, Size size) {
    final stage = size.width;
    if (stage <= 0) return;
    // SVG viewBox 230x410 占 stage 宽 40.9%（BakaMusic classic inner 摆放值）。
    final unit = stage * 0.409 / 230;
    // SVG origin 位于 stage 的 (62.2%, -3.2%)，使 pivot (179,46) 落在 (94%, 5%)。
    final origin = Offset(stage * 0.622, -stage * 0.032);

    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(unit, unit);
    // 围绕 SVG 本地 pivot (179, 46) 旋转。
    canvas.translate(179, 46);
    canvas.rotate(angleDeg * math.pi / 180);
    canvas.translate(-179, -46);
    _drawArm(canvas);
    canvas.restore();

    _drawBase(canvas, stage);
  }

  void _drawArm(Canvas canvas) {
    final counterweightArm = Path()
      ..moveTo(179, 46)
      ..lineTo(174.3, -3.8);
    final mainArm = Path()
      ..moveTo(179, 46)
      ..cubicTo(190.3, 177.3, 164.6, 318.5, 119, 386);
    final armShade = Path()
      ..moveTo(182.5, 47.4)
      ..cubicTo(193.8, 178.7, 168.1, 319.9, 122.5, 387.4);

    // 配重块：绕 (175, 4.2) 自旋 -5.4 度。
    final counterweight = (Path()
          ..addRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTWH(162, -10.8, 26, 30),
              const Radius.circular(9),
            ),
          ))
        .transform(
          _rotateAround(175, 4.2, -5.4 * math.pi / 180).storage,
        );

    // 唱头组：绕 (119, 386) 旋转 34 度。
    final headMatrix = _rotateAround(119, 386, 34 * math.pi / 180);
    final cartridge = (Path()
          ..addRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTWH(109, 379, 20, 14),
              const Radius.circular(4),
            ),
          ))
        .transform(headMatrix.storage);
    final head = (Path()
          ..addRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTWH(106, 393, 26, 30),
              const Radius.circular(5),
            ),
          ))
        .transform(headMatrix.storage);
    final grooves = Path.combine(
      PathOperation.union,
      (Path()
            ..moveTo(114, 413)
            ..lineTo(114, 420))
          .transform(headMatrix.storage),
      (Path()
            ..moveTo(124, 413)
            ..lineTo(124, 420))
          .transform(headMatrix.storage),
    );

    // 投影 pass：drop-shadow(0 9 15 rgba(0,0,0,.34))。
    final shadowPaint = Paint()
      ..color = const Color.fromRGBO(0, 0, 0, 0.34)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15);
    canvas.save();
    canvas.translate(9, 15);
    _stroke(canvas, counterweightArm, shadowPaint, 16, cap: StrokeCap.round);
    _stroke(canvas, mainArm, shadowPaint, 16, cap: StrokeCap.round);
    canvas.drawPath(counterweight, shadowPaint);
    canvas.drawPath(head, shadowPaint);
    canvas.restore();

    // 本体 pass。
    _stroke(
      canvas,
      counterweightArm,
      Paint()..color = _armWhite,
      16,
      cap: StrokeCap.round,
    );
    canvas.drawPath(counterweight, Paint()..color = _armWhite);
    _stroke(canvas, counterweight, Paint()..color = _armShade, 1.8);
    _stroke(
      canvas,
      mainArm,
      Paint()..color = _armWhite,
      16,
      cap: StrokeCap.round,
      join: StrokeJoin.round,
    );
    _stroke(
      canvas,
      armShade,
      Paint()..color = _armShade,
      1.8,
      cap: StrokeCap.round,
    );
    canvas.drawPath(cartridge, Paint()..color = _cartridgeDark);
    canvas.drawPath(head, Paint()..color = _armWhite);
    _stroke(
      canvas,
      grooves,
      Paint()..color = _grooveGray,
      1.6,
      cap: StrokeCap.round,
    );
  }

  void _stroke(
    Canvas canvas,
    Path path,
    Paint paint,
    double width, {
    StrokeCap cap = StrokeCap.butt,
    StrokeJoin join = StrokeJoin.miter,
  }) {
    canvas.drawPath(
      path,
      Paint.from(paint)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = cap
        ..strokeJoin = join,
    );
  }

  /// 底座（不随唱臂旋转）：stage (94%, 5%) 处直径 11.5% 的白色圆盘，
  /// 盖在唱臂根部之上，内部再叠一枚 36% 直径的顶帽圆。
  void _drawBase(Canvas canvas, double stage) {
    final center = Offset(stage * 0.94, stage * 0.05);
    final radius = stage * 0.0575;

    // 外投影：0 14px 30px rgba(0,0,0,.3)。
    canvas.drawCircle(
      center.translate(0, stage * 0.014),
      radius,
      Paint()
        ..color = const Color.fromRGBO(0, 0, 0, 0.3)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, stage * 0.03),
    );
    // 底盘：linear-gradient(180deg, #ffffff, #e7eaef)。
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFFFFF), Color(0xFFE7EAEF)],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    // 上缘内高光：inset 0 1px 0 rgba(255,255,255,.95)。
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 1),
      -math.pi * 0.9,
      math.pi * 0.8,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color.fromRGBO(255, 255, 255, 0.95),
    );
    // 顶帽：inset 32%，linear-gradient(180deg, #ffffff, #eef0f4)。
    final capRadius = radius * 0.36;
    canvas.drawCircle(
      center,
      capRadius,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFFFFF), Color(0xFFEEF0F4)],
        ).createShader(Rect.fromCircle(center: center, radius: capRadius)),
    );
  }

  @override
  bool shouldRepaint(_TonearmPainter old) => old.angleDeg != angleDeg;
}
