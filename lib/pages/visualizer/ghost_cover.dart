import 'dart:ui' as ui;

/// 封面幽灵层（对齐 LX-X / lxwalnut「天空中的巨大圆形雾化显影」）。
///
/// 渲染管线（5548 定稿，全部使用真机长期实证可靠的绘制原语）：
///
/// ① 纹理 = 解码器直出的原始封面，**零任何像素加工**——5542/5545 实测
///    Impeller 真机上 PictureRecorder.toImage + toByteData 回读产物损坏
///    （测试环境全过、真机封面不显示），CPU 加工一律不做；
/// ② 绘制 = **单层** sharp 纹理按 20×20 网格分块 drawImageRect，逐格
///    alpha = 径向消散（0.32 内全显 → 0.68 归零，收在内接圆里杜绝方形
///    残影）× 雾气行波。两条已证伪的路：ui.Vertices 顶点色 alpha（探针
///    实测软件渲染下不可预测）；paint.color 的 alpha 与 colorFilter 同挂
///    被光栅管线整体忽略（冒烟 PNG 实证画出实心方块）——最终逐格 alpha
///    编码进 ColorFilter.matrix 的 alpha 行 m[18]（矩阵在非预乘域运算，
///    只缩 alpha 行 = 纯透明度调制）。5547 教训：叠加第二层 blur 纹理
///    会形成可辨重影、雾色矩形罩与真实渐变天空有色差形成光圈，均已
///    移除——无叠加层即无色差无重影；
/// ③ 压暗 ×0.50/0.54/0.63 + 降饱和 ×0.42 由**单一** colorFilter 矩阵承载
///    （5542 教训：colorFilter 与 imageFilter 同挂会被吞，只挂一个安全）；
/// ④ 雾气漂浮 = 逐格 alpha 行波（雾掠过封面的明暗流动）+ 封面前方两团
///    低透明度漂移雾（天空色 radial 渐变，多频漂移 + 半径呼吸）。
class GhostTextures {
  const GhostTextures({required this.sharp, required this.blur});
  final ui.Image sharp;
  final ui.Image blur;
  void dispose() {
    sharp.dispose();
    blur.dispose();
  }
}

/// 组装双层纹理（调用方用 instantiateImageCodec 分别解码两个尺寸）。
GhostTextures buildGhostTextures({
  required ui.Image sharpSrc,
  required ui.Image blurSrc,
}) {
  return GhostTextures(sharp: sharpSrc, blur: blurSrc);
}

/// 封面压暗 + 降饱和的 20 值 ColorFilter 矩阵。
///
/// 先做饱和度（lum = 0.2126R + 0.7152G + 0.0722B），再按夜空色调
/// 乘性压暗（5539 教训：向白提亮会冲淡饱和发灰，故只压不提）。
/// 5548 对齐 lxwalnut 目标观感再压暗一档：R×0.50 / G×0.54 / B×0.63、
/// 饱和度 0.42（截图对比：旧 0.62/0.66/0.74 偏亮偏彩，目标是近乎
/// 溶进夜空的暗灰显影）。[bright] 为脉冲亮度增益（1.0 起，鼓点最高
/// ×1.3）。
///
/// 5553 改回 5547 定稿观感：纯乘性夜色 tint，见 ghostDimMatrix。
List<double> ghostDimMatrix({required double bright}) {
  // 5553 恢复 5547 定稿压暗：纯乘性夜色 tint（RGB×0.62/0.66/0.74），
  // 保 V 压暗、不降饱和（5539 教训：向白提亮会冲淡饱和发灰，只压不提）；
  // bright 脉冲保留。
  final r = 0.62 * bright, g = 0.66 * bright, b = 0.74 * bright;
  return <double>[
    r, 0, 0, 0, 0, //
    0, g, 0, 0, 0, //
    0, 0, b, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}
