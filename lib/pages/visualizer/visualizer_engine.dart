// visualizer_engine.dart — 可视化 3D 引擎件。
//
// ①GLSL simplex 噪声（Ashima 2D）逐行移植，保证与 sonic-topography
//   CustomShaderMaterial.ts 的地形噪声形态一致；
// ②轨道相机：默认机位 1:1 对齐 sceneDefaults.ts 的 DEFAULT_CAMERA_STATE
//   （pos (-37.58, 25.72, 92.26) → 球坐标 theta/phi/dist），fov 45°，
//   边界对齐 OrbitControls（dist 5..120，极角上限 π/2-0.1）；
// ③ripple 环形缓冲（10 槽，对齐 shader uRipples[10]）；
// ④64 段对数频谱 → 五频段分区（subBass/bass/lowMid/mid/highMid）。
//
// 全部为纯数学，无 Flutter 依赖（除 Offset），便于复用与测试。

import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

// ---------------------------------------------------------------------------
// GLSL 工具函数
// ---------------------------------------------------------------------------

/// GLSL smoothstep（允许 e0>e1 的反向用法，与 shader 行为一致）。
double glslSmoothstep(double e0, double e1, double x) {
  final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// GLSL fract。
double glslFract(double x) => x - x.floorToDouble();

/// GLSL random(vec2)：fract(sin(dot(st,(12.9898,78.233)))*43758.5453123)。
double glslHash(double x, double y) =>
    glslFract(math.sin(x * 12.9898 + y * 78.233) * 43758.5453123);

// ---------------------------------------------------------------------------
// Simplex 噪声（Ashima 2D，逐行移植自 shader 的 snoise）
// ---------------------------------------------------------------------------

const double _c0 = 0.211324865405187;
const double _c1 = 0.366025403784439;
const double _cn = -0.577350269189626;
const double _c3 = 0.024390243902439;

double _mod289(double x) => x - (x * (1.0 / 289.0)).floorToDouble() * 289.0;

/// 二维 simplex 噪声，输出约 -1..1。
double snoise2D(double vx, double vy) {
  // vec2 i = floor(v + dot(v, C.yy))
  final s = (vx + vy) * _c1;
  final ix = (vx + s).floorToDouble();
  final iy = (vy + s).floorToDouble();
  // vec2 x0 = v - i + dot(i, C.xx)
  final t = (ix + iy) * _c0;
  final x0x = vx - ix + t;
  final x0y = vy - iy + t;
  // i1 = x0.x > x0.y ? (1,0) : (0,1)
  final i1x = x0x > x0y ? 1.0 : 0.0;
  final i1y = x0x > x0y ? 0.0 : 1.0;
  // x12 = x0.xyxy + C.xxzz - i1
  final x1x = x0x + _c0 - i1x;
  final x1y = x0y + _c1 - i1y;
  final x2x = x0x + _cn;
  final x2y = x0y + _c0;
  // i = mod289(i)
  final mx = _mod289(ix);
  final my = _mod289(iy);
  // p = permute(permute(i.y + (0, i1.y, 1)) + i.x + (0, i1.x, 1))
  double perm(double x) => _mod289(((x * 34.0) + 1.0) * x);
  final p0 = perm(perm(my + 0.0) + mx + 0.0);
  final p1 = perm(perm(my + i1y + 1.0) + mx + i1x + 1.0);
  final p2 = perm(perm(my + 1.0) + mx + 1.0);
  // m = max(0.5 - d, 0)^4
  double m0 = 0.5 - (x0x * x0x + x0y * x0y);
  double m1 = 0.5 - (x1x * x1x + x1y * x1y);
  double m2 = 0.5 - (x2x * x2x + x2y * x2y);
  m0 = m0 < 0 ? 0 : m0 * m0;
  m0 = m0 * m0;
  m1 = m1 < 0 ? 0 : m1 * m1;
  m1 = m1 * m1;
  m2 = m2 < 0 ? 0 : m2 * m2;
  m2 = m2 * m2;
  // x = 2*fract(p*C.www)-1：展开三点梯度（每维两个哈希分量近似
  // shader 的三维 x 向量，形态与 Ashima 实现一致）。
  double corner(double px, double dx, double dy, double mm) {
    final xx = 2.0 * glslFract(px * _c3) - 1.0;
    final ox = (xx + 0.5).floorToDouble();
    final a0 = xx - ox;
    final mm2 = mm * (1.79284291400159 - 0.85373472095314 * (a0 * a0 + (xx.abs() - 0.5) * (xx.abs() - 0.5)));
    // shader 的 g = a0·d（二维梯度点积，a0 为二维，但该哈希只有一维标量；
    // Ashima 原实现里 x 是三维向量——这里用两个独立哈希分量近似第二维。
    final yy = 2.0 * glslFract(px * 0.01720202) - 1.0;
    final oy2 = (yy + 0.5).floorToDouble();
    final a0y = yy - oy2;
    return mm2 * 130.0 * (a0 * dx + a0y * dy);
  }

  final g0 = corner(p0, x0x, x0y, m0);
  final g1 = corner(p1, x1x, x1y, m1);
  final g2 = corner(p2, x2x, x2y, m2);
  return g0 + g1 + g2;
}

// ---------------------------------------------------------------------------
// Ripple 环形缓冲（对齐 shader uRipples[10]）
// ---------------------------------------------------------------------------

class VisRipple {
  double x = 0, z = 0;
  double t0 = -1000;
  double strength = 0;
  bool white = false;
  bool active = false;
}

class VisRippleBuffer {
  final List<VisRipple> slots =
      List.generate(10, (_) => VisRipple()..t0 = -1000);
  int _idx = 0;

  void add(double x, double z, double strength,
      {bool white = false, required double time}) {
    final r = slots[_idx];
    r.x = x;
    r.z = z;
    r.t0 = time;
    r.strength = strength;
    r.white = white;
    r.active = true;
    _idx = (_idx + 1) % slots.length;
  }

  void clear() {
    for (final r in slots) {
      r.active = false;
      r.t0 = -1000;
    }
  }
}

// ---------------------------------------------------------------------------
// 频段分区：64 段对数频谱 → 五频段 uniform
// ---------------------------------------------------------------------------

/// 对齐 AudioEngine 的频段语义（近似边界，见 visualizer_source 的对数分段）。
class BandPartition {
  final double subBass;
  final double bass;
  final double lowMid;
  final double mid;
  final double highMid;
  final double warmth;
  final double brightnessRatio;
  const BandPartition({
    required this.subBass,
    required this.bass,
    required this.lowMid,
    required this.mid,
    required this.highMid,
    required this.warmth,
    required this.brightnessRatio,
  });

  static double _avg(List<double> b, int s, int e) {
    double sum = 0;
    final en = e.clamp(s, b.length - 1);
    for (int i = s; i <= en; i++) {
      sum += b[i];
    }
    return sum / (en - s + 1);
  }

  factory BandPartition.of(List<double> bands) {
    final sub = _avg(bands, 0, 2);
    final bass = _avg(bands, 3, 6);
    final lowMid = _avg(bands, 7, 13);
    final mid = _avg(bands, 14, 23);
    final highMid = _avg(bands, 24, 34);
    final presence = _avg(bands, 35, 45);
    final air = _avg(bands, 46, 63);
    final lowSum = sub + bass + lowMid + mid;
    final highSum = highMid + presence + air;
    final total = lowSum + highSum;
    return BandPartition(
      subBass: sub,
      bass: bass,
      lowMid: lowMid,
      mid: mid,
      highMid: highMid,
      warmth: total > 0.0001 ? lowSum / total : 0,
      brightnessRatio: total > 0.0001 ? highSum / total : 0,
    );
  }
}

// ---------------------------------------------------------------------------
// 轨道相机（OrbitControls 语义）
// ---------------------------------------------------------------------------

/// 默认机位对齐 DEFAULT_CAMERA_STATE：
/// pos (-37.5836, 25.7189, 92.2569)、target (0,0,0)、fov 45°。
/// dist = |pos| = 102.885；theta = atan2(x,z) = -0.3867；
/// phi = acos(y/dist) = 1.3182。
class OrbitCamera {
  double theta; // 方位角（绕 Y）
  double phi; // 极角（从 +Y 轴起）
  double dist;

  OrbitCamera()
      : theta = -0.386650,
        phi = 1.318150,
        dist = 102.885;

  static const double _minPhi = 0.12;
  static const double _maxPhi = math.pi / 2 - 0.1; // OrbitControls maxPolarAngle

  double get posX => dist * math.sin(phi) * math.sin(theta);
  double get posY => dist * math.cos(phi);
  double get posZ => dist * math.sin(phi) * math.cos(theta);

  /// 单指旋转（对齐 OrbitControls：按屏幕尺寸归一化角速度）。
  void orbit(double dxPx, double dyPx, double width, double height) {
    theta -= 2 * math.pi * dxPx / math.max(1, height);
    phi -= 2 * math.pi * dyPx / math.max(1, height);
    phi = phi.clamp(_minPhi, _maxPhi);
  }

  /// 双指缩放（factor>1 拉远）。
  void dolly(double factor) {
    dist = (dist * factor).clamp(5.0, 120.0);
  }

  /// 屏幕点 → 与 y=0 地形平面交点（用于点击触发的 ripple 落点）。
  /// 返回 null 表示射线朝上无交点。
  Offset? screenToGround(Offset screen, double w, double h) {
    final rig = CameraRig(this, Size(w, h));
    return rig.groundPoint(screen);
  }
}

/// 每帧相机缓存：基向量 + 投影。
class CameraRig {
  final double px, py, pz;
  final double rx, ry, rz; // right
  final double ux, uy, uz; // up'
  final double fx, fy, fz; // forward
  final double tanHalfFov;
  final double aspect;
  final double w, h;

  factory CameraRig(OrbitCamera cam, Size size) {
    final px = cam.posX, py = cam.posY, pz = cam.posZ;
    final len = math.sqrt(px * px + py * py + pz * pz);
    final fx = -px / len, fy = -py / len, fz = -pz / len;
    // r = normalize(cross(f, up(0,1,0)))；cross(f, up) = (f.z, 0, -f.x)
    var rxx = fz, rzz = -fx;
    final rl = math.sqrt(rxx * rxx + rzz * rzz);
    if (rl < 1e-6) {
      rxx = 1;
      rzz = 0;
    } else {
      rxx /= rl;
      rzz /= rl;
    }
    final rx = rxx, ry = 0.0, rz = rzz;
    // u = cross(r, f)
    final ux = ry * fz - rz * fy;
    final uy = rz * fx - rx * fz;
    final uz = rx * fy - ry * fx;
    return CameraRig._(
      px: px, py: py, pz: pz,
      rx: rx, ry: ry, rz: rz,
      ux: ux, uy: uy, uz: uz,
      fx: fx, fy: fy, fz: fz,
      tanHalfFov: math.tan(45 * math.pi / 360),
      aspect: size.width / math.max(1, size.height),
      w: size.width,
      h: size.height,
    );
  }

  const CameraRig._({
    required this.px, required this.py, required this.pz,
    required this.rx, required this.ry, required this.rz,
    required this.ux, required this.uy, required this.uz,
    required this.fx, required this.fy, required this.fz,
    required this.tanHalfFov,
    required this.aspect,
    required this.w,
    required this.h,
  });

  /// 世界坐标 → 屏幕像素。相机背后返回 null。
  Offset? project(double x, double y, double z) {
    final dx = x - px;
    final dy = y - py;
    final dz = z - pz;
    final cx = dx * rx + dy * ry + dz * rz;
    final cy = dx * ux + dy * uy + dz * uz;
    final cz = -(dx * fx + dy * fy + dz * fz);
    if (cz < 0.5) return null;
    final inv = 1.0 / (cz * tanHalfFov);
    final ndcX = cx * inv / aspect;
    final ndcY = cy * inv;
    return Offset(
      (ndcX * 0.5 + 0.5) * w,
      (1 - (ndcY * 0.5 + 0.5)) * h,
    );
  }

  /// 世界坐标深度（相机空间 z，越大越远）。
  double depthOf(double x, double y, double z) {
    final dx = x - px;
    final dy = y - py;
    final dz = z - pz;
    return -(dx * fx + dy * fy + dz * fz);
  }

  /// 屏幕点反投影与 y=0 平面的交点（世界 xz）。
  Offset? groundPoint(Offset screen) {
    final ndcX = (screen.dx / w) * 2 - 1;
    final ndcY = 1 - (screen.dy / h) * 2;
    final dxx = rx * (ndcX * tanHalfFov * aspect) +
        ux * (ndcY * tanHalfFov) +
        fx;
    final dyy = ry * (ndcX * tanHalfFov * aspect) +
        uy * (ndcY * tanHalfFov) +
        fy;
    if (dyy >= -1e-4) return null;
    final t = -py / dyy;
    return Offset(px + dxx * t, pz + dyy * t);
  }
}
