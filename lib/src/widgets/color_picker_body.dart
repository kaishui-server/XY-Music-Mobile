import 'package:flutter/material.dart';

/// 自定义颜色选择器（色板 + RGB/十六进制），从设置页桌面歌词「歌词样式」
/// 面板抽出为共享组件，供桌面歌词样式与播放详情页歌词设置等复用。
///
/// - 色板（饱和度×明度二维面板 + 色相条）为公共取色区，两种模式共用；
/// - 模式切换：RGB 三通道滑块 / 十六进制输入（支持粘贴 # / 0x 前缀），
///   默认显示 RGB；
/// - 纯内容组件（不带对话框/底部弹层壳）：每次变色经 [onChanged] 即时
///   回调，由宿主写入设置，调整过程实时生效。
class ColorPickerBody extends StatefulWidget {
  const ColorPickerBody({
    super.key,
    required this.initial,
    required this.onChanged,
  });

  final int initial;
  final ValueChanged<int> onChanged;

  @override
  State<ColorPickerBody> createState() => _ColorPickerBodyState();
}

class _ColorPickerBodyState extends State<ColorPickerBody> {
  static const _tabs = ['RGB', '十六进制'];

  late Color _color;
  late HSVColor _hsv;
  int _tabIndex = 0;
  final _hexController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _color = Color(widget.initial);
    _hsv = HSVColor.fromColor(_color);
    _hexController.text = _hexOf(_color);
  }

  @override
  void didUpdateWidget(covariant ColorPickerBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 宿主切换取色目标（歌词/翻译/背景等）时以新 initial 重置内部状态。
    if (oldWidget.initial != widget.initial) {
      _color = Color(widget.initial);
      _hsv = HSVColor.fromColor(_color);
      _hexController.text = _hexOf(_color);
    }
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  static String _hexOf(Color c) {
    String part(double v) =>
        (v * 255).round().toRadixString(16).padLeft(2, '0').toUpperCase();
    return '${part(c.r)}${part(c.g)}${part(c.b)}';
  }

  /// 统一改色入口：同步 HSV 状态与 hex 输入框（[updateHex] 为 false 时
  /// 不回写输入框，避免用户输入中被覆盖导致光标跳动），并即时回调宿主。
  void _applyColor(Color c, {bool updateHex = true}) {
    setState(() {
      _color = c;
      _hsv = HSVColor.fromColor(c);
      if (updateHex) _hexController.text = _hexOf(c);
    });
    widget.onChanged(_color.toARGB32());
  }

  /// 色板/色相条拖动：只更新对应分量，另一分量保持。
  void _applyHsv(HSVColor v) {
    final c = v.toColor();
    setState(() {
      _color = c;
      _hsv = v;
      _hexController.text = _hexOf(c);
    });
    widget.onChanged(_color.toARGB32());
  }

  void _applyHex(String text) {
    var hex = text.trim();
    if (hex.startsWith('#')) hex = hex.substring(1);
    if (hex.toLowerCase().startsWith('0x')) hex = hex.substring(2);
    hex = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (hex.length < 6) return; // 不足 6 位不应用（保留当前色）
    final value = int.tryParse(hex.substring(0, 6), radix: 16);
    if (value == null) return;
    _applyColor(Color(0xFF000000 | value), updateHex: false);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 色板为公共取色区：两种模式（RGB/十六进制）下都显示。
        _buildPalette(),
        const SizedBox(height: 10),
        SegmentedButton<int>(
          segments: [
            for (var i = 0; i < _tabs.length; i++)
              ButtonSegment(value: i, label: Text(_tabs[i])),
          ],
          selected: {_tabIndex},
          showSelectedIcon: false,
          onSelectionChanged: (selection) =>
              setState(() => _tabIndex = selection.first),
        ),
        const SizedBox(height: 12),
        if (_tabIndex == 0)
          _buildRgb()
        else
          _buildHex(),
      ],
    );
  }

  /// 色板模式：饱和度×明度二维面板 + 色相条。
  Widget _buildPalette() {
    final hsv = _hsv;
    return Column(
      children: [
        SizedBox(
          height: 180,
          child: LayoutBuilder(
            builder: (context, constraints) {
              void pick(Offset local) {
                final s = (local.dx / constraints.maxWidth)
                    .clamp(0.0, 1.0)
                    .toDouble();
                final v = (1 - local.dy / constraints.maxHeight)
                    .clamp(0.0, 1.0)
                    .toDouble();
                _applyHsv(hsv.withSaturation(s).withValue(v));
              }

              return GestureDetector(
                onTapDown: (d) => pick(d.localPosition),
                onPanStart: (d) => pick(d.localPosition),
                onPanUpdate: (d) => pick(d.localPosition),
                child: CustomPaint(
                  painter: _HsPalettePainter(hue: hsv.hue),
                  child: Stack(
                    children: [
                      // 当前色指示点：s→横坐标、v→纵坐标（底部为明度 0）。
                      Positioned(
                        left: hsv.saturation * constraints.maxWidth - 9,
                        top: (1 - hsv.value) * constraints.maxHeight - 9,
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _color,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: const [
                              BoxShadow(color: Colors.black38, blurRadius: 3),
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
        ),
        const SizedBox(height: 10),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 10,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: hsv.hue.clamp(0.0, 360.0),
            max: 360,
            onChanged: (h) => _applyHsv(hsv.withHue(h)),
          ),
        ),
      ],
    );
  }

  /// RGB 模式：三通道滑块（保留原有调色方式）。
  Widget _buildRgb() {
    final c = _color;
    final r = (c.r * 255).round();
    final g = (c.g * 255).round();
    final b = (c.b * 255).round();
    return Column(
      children: [
        _channelSlider(
          '红',
          r.toDouble(),
          Colors.red,
          (value) => _applyColor(
            Color.fromARGB(255, value.round(), g, b),
          ),
        ),
        _channelSlider(
          '绿',
          g.toDouble(),
          Colors.green,
          (value) => _applyColor(
            Color.fromARGB(255, r, value.round(), b),
          ),
        ),
        _channelSlider(
          '蓝',
          b.toDouble(),
          Colors.blue,
          (value) => _applyColor(
            Color.fromARGB(255, r, g, value.round()),
          ),
        ),
      ],
    );
  }

  /// 十六进制模式：色块 + 输入框（支持粘贴 # / 0x 前缀）。
  Widget _buildHex() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _color,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white24),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _hexController,
                onChanged: _applyHex,
                maxLength: 8,
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                  letterSpacing: 1.2,
                ),
                decoration: const InputDecoration(
                  counterText: '',
                  hintText: 'RRGGBB',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          '输入或粘贴 6 位色值，支持 # 或 0x 前缀',
          style: TextStyle(color: Colors.white38, fontSize: 11),
        ),
      ],
    );
  }

  Widget _channelSlider(
    String label,
    double value,
    Color activeColor,
    ValueChanged<double> onChanged,
  ) {
    return Row(
      children: [
        SizedBox(width: 26, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            min: 0,
            max: 255,
            divisions: 255,
            activeColor: activeColor,
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 30, child: Text(value.round().toString())),
      ],
    );
  }
}

/// 饱和度×明度二维渐变色板：底色为当前色相的纯色，横向白→纯色
/// （饱和度 0→1）、纵向透→黑（明度 1→0），两层渐变叠画即得 HSV 取色面。
class _HsPalettePainter extends CustomPainter {
  _HsPalettePainter({required this.hue});

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final pure = HSVColor.fromAHSV(1, hue, 1, 1).toColor();
    final saturationPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [Colors.white, pure],
      ).createShader(rect);
    canvas.drawRect(rect, saturationPaint);
    final valuePaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.black],
      ).createShader(rect);
    canvas.drawRect(rect, valuePaint);
  }

  @override
  bool shouldRepaint(_HsPalettePainter oldDelegate) =>
      oldDelegate.hue != hue;
}
