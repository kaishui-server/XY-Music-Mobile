import 'package:flutter/material.dart';

/// 自定义主题色调色弹窗：HSV 三滑杆 + 实时预览 + 十六进制输入。
///
/// 返回 0xAARRGGBB 整数（alpha 固定 0xFF）；取消返回 null。
Future<int?> showCustomColorPicker(
  BuildContext context, {
  int initialColor = 0xFFEC4141,
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _CustomColorPickerSheet(initialColor: initialColor),
  );
}

class _CustomColorPickerSheet extends StatefulWidget {
  const _CustomColorPickerSheet({required this.initialColor});
  final int initialColor;

  @override
  State<_CustomColorPickerSheet> createState() =>
      _CustomColorPickerSheetState();
}

class _CustomColorPickerSheetState extends State<_CustomColorPickerSheet> {
  late HSVColor _hsv;
  final TextEditingController _hexController = TextEditingController();
  bool _syncingHex = false;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(Color(widget.initialColor));
    _syncHexField();
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  int get _argb {
    final rgba = _hsv.toColor();
    final r = (rgba.r * 255.0).round().clamp(0, 255);
    final g = (rgba.g * 255.0).round().clamp(0, 255);
    final b = (rgba.b * 255.0).round().clamp(0, 255);
    return (0xFF << 24) | (r << 16) | (g << 8) | b;
  }

  /// 滑杆变化后同步十六进制输入框。
  void _syncHexField() {
    _syncingHex = true;
    _hexController.text = _argb.toRadixString(16).padLeft(6, '0').toUpperCase();
    _syncingHex = false;
  }

  void _update({double? hue, double? saturation, double? value}) {
    setState(() {
      _hsv = _hsv
          .withHue(hue ?? _hsv.hue)
          .withSaturation(saturation ?? _hsv.saturation)
          .withValue(value ?? _hsv.value);
      _syncHexField();
    });
  }

  /// 十六进制输入解析：支持 6 位 RGB，非法输入忽略。
  void _applyHex(String text) {
    if (_syncingHex) return;
    final normalized = text.trim().replaceFirst('#', '');
    if (normalized.length != 6) return;
    final parsed = int.tryParse(normalized, radix: 16);
    if (parsed == null || parsed < 0 || parsed > 0xFFFFFF) return;
    setState(() {
      _hsv = HSVColor.fromColor(Color(0xFF000000 | parsed));
      _syncHexField();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('自定义主题色', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: _hsv.toColor(),
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.outlineVariant),
                  boxShadow: [
                    BoxShadow(
                      color: _hsv.toColor().withValues(alpha: .4),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '#${_hexController.text}',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'H ${_hsv.hue.round()}°  S ${(_hsv.saturation * 100).round()}%  V ${(_hsv.value * 100).round()}%',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 108,
                child: TextField(
                  controller: _hexController,
                  onChanged: _applyHex,
                  style: const TextStyle(fontSize: 13),
                  maxLength: 6,
                  decoration: InputDecoration(
                    isDense: true,
                    counterText: '',
                    prefixText: '# ',
                    hintText: 'RRGGBB',
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _HueSlider(
            hue: _hsv.hue,
            onChanged: (v) => _update(hue: v),
          ),
          const SizedBox(height: 6),
          _GradientSlider(
            label: '饱和度',
            value: _hsv.saturation,
            colors: [
              _hsv.withSaturation(0).toColor(),
              _hsv.withSaturation(1).toColor(),
            ],
            onChanged: (v) => _update(saturation: v),
          ),
          const SizedBox(height: 6),
          _GradientSlider(
            label: '明度',
            value: _hsv.value,
            colors: [_hsv.withValue(0).toColor(), _hsv.withValue(1).toColor()],
            onChanged: (v) => _update(value: v),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.pop(context, _argb),
                child: const Text('应用'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 色相滑杆：0-360° 彩虹渐变轨道。
class _HueSlider extends StatelessWidget {
  const _HueSlider({required this.hue, required this.onChanged});
  final double hue;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(
            '色相',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanDown: (details) => onChanged(
                (details.localPosition.dx / width * 360).clamp(0, 360),
              ),
              onPanUpdate: (details) => onChanged(
                (details.localPosition.dx / width * 360).clamp(0, 360),
              ),
              child: SizedBox(
                height: 28,
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Color(0xFFFF0000),
                              Color(0xFFFFFF00),
                              Color(0xFF00FF00),
                              Color(0xFF00FFFF),
                              Color(0xFF0000FF),
                              Color(0xFFFF00FF),
                              Color(0xFFFF0000),
                            ],
                          ),
                        ),
                        child: SizedBox(width: double.infinity, height: 28),
                      ),
                    ),
                    Positioned(
                      left: (hue / 360 * (width - 4)).clamp(0.0, width - 4),
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
                          border: Border.all(color: Colors.white, width: 2.5),
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black26,
                              blurRadius: 4,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// 通用渐变滑杆：饱和度/明度共用，轨道颜色随当前 HSV 联动。
class _GradientSlider extends StatelessWidget {
  const _GradientSlider({
    required this.label,
    required this.value,
    required this.colors,
    required this.onChanged,
  });
  final String label;
  final double value;
  final List<Color> colors;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanDown: (details) =>
                  onChanged((details.localPosition.dx / width).clamp(0.0, 1.0)),
              onPanUpdate: (details) =>
                  onChanged((details.localPosition.dx / width).clamp(0.0, 1.0)),
              child: SizedBox(
                height: 28,
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: colors),
                        ),
                        child: const SizedBox(
                          width: double.infinity,
                          height: 28,
                        ),
                      ),
                    ),
                    Positioned(
                      left: (value * (width - 4)).clamp(0.0, width - 4),
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: colors.last,
                          border: Border.all(color: Colors.white, width: 2.5),
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black26,
                              blurRadius: 4,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
