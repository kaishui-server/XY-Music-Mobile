// visualizer_settings.dart — 可视化页设置（脉冲触发 / 主题颜色 / 音频检测）
// 的模型与持久化（SharedPreferences JSON，独立于全局 settingsProvider）。

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 可视化形态。
enum VisualizerForm { terrain, nebula }

/// 主题色板（对齐视频里「主题颜色」五个预设）。
class VisTheme {
  final String id;
  final String name;
  /// 粒子主体色（亮部）。
  final int main;
  /// 粒子暗部/远景色。
  final int dim;
  /// 高亮/脉冲强调色。
  final int accent;
  const VisTheme(this.id, this.name, this.main, this.dim, this.accent);
}

const kVisThemes = <VisTheme>[
  VisTheme('daylight', '极昼白', 0xFFFFFFFF, 0xFF9AA0A6, 0xFFE8EAED),
  VisTheme('ice', '冰湖蓝', 0xFF7FD8F5, 0xFF2E6E86, 0xFFB8ECFF),
  VisTheme('violet', '紫阳', 0xFFC0A6FF, 0xFF4A3B73, 0xFFE2D6FF),
  VisTheme('lime', '青柠绿', 0xFFB8E986, 0xFF4E6B33, 0xFFE0F7C0),
  VisTheme('dark', '暗黑', 0xFFB9BDC4, 0xFF4E5257, 0xFF8E959E),
];

/// 脉冲触发模式。
enum PulseMode { autoBeat, advanced }

class VisualizerSettings {
  // —— 脉冲触发 ——
  final bool pulseEnabled;
  final PulseMode pulseMode;
  final bool autoPulse;
  final double sensitivity; // 0..100
  final double beatDuration; // 0..30（节拍形变回复时长，秒×0.1 语义）
  final double brightness; // 0..1
  // —— 主题颜色 ——
  final int themeIndex;
  final bool explicitPlot; // 显式标绘图
  final int terrainDensity; // 0..100 地形网格密度（默认 33 ≈ 64×64 柱体）
  // —— 音频检测 ——
  final double detectLevel; // 0..100 检测源灵敏度
  // —— Advanced 触发频段 ——
  final int bandStart;
  final int bandEnd;
  // —— 形态 ——
  final VisualizerForm form;

  const VisualizerSettings({
    this.pulseEnabled = true,
    this.pulseMode = PulseMode.autoBeat,
    this.autoPulse = true,
    this.sensitivity = 79,
    this.beatDuration = 10,
    this.brightness = 0.7,
    this.themeIndex = 0,
    this.explicitPlot = false,
    this.terrainDensity = 33,
    this.detectLevel = 100,
    this.bandStart = 0,
    this.bandEnd = 7,
    this.form = VisualizerForm.terrain,
  });

  VisTheme get theme =>
      themeIndex >= 0 && themeIndex < kVisThemes.length
          ? kVisThemes[themeIndex]
          : kVisThemes.first;

  VisualizerSettings copyWith({
    bool? pulseEnabled,
    PulseMode? pulseMode,
    bool? autoPulse,
    double? sensitivity,
    double? beatDuration,
    double? brightness,
    int? themeIndex,
    bool? explicitPlot,
    int? terrainDensity,
    double? detectLevel,
    int? bandStart,
    int? bandEnd,
    VisualizerForm? form,
  }) {
    return VisualizerSettings(
      pulseEnabled: pulseEnabled ?? this.pulseEnabled,
      pulseMode: pulseMode ?? this.pulseMode,
      autoPulse: autoPulse ?? this.autoPulse,
      sensitivity: sensitivity ?? this.sensitivity,
      beatDuration: beatDuration ?? this.beatDuration,
      brightness: brightness ?? this.brightness,
      themeIndex: themeIndex ?? this.themeIndex,
      explicitPlot: explicitPlot ?? this.explicitPlot,
      terrainDensity: terrainDensity ?? this.terrainDensity,
      detectLevel: detectLevel ?? this.detectLevel,
      bandStart: bandStart ?? this.bandStart,
      bandEnd: bandEnd ?? this.bandEnd,
      form: form ?? this.form,
    );
  }

  Map<String, dynamic> toJson() => {
        'pulseEnabled': pulseEnabled,
        'pulseMode': pulseMode == PulseMode.autoBeat ? 'auto' : 'advanced',
        'autoPulse': autoPulse,
        'sensitivity': sensitivity,
        'beatDuration': beatDuration,
        'brightness': brightness,
        'themeIndex': themeIndex,
        'explicitPlot': explicitPlot,
        'terrainDensity': terrainDensity,
        'detectLevel': detectLevel,
        'bandStart': bandStart,
        'bandEnd': bandEnd,
        'form': form == VisualizerForm.terrain ? 'terrain' : 'nebula',
      };

  static VisualizerSettings fromJson(Map<String, dynamic> j) {
    return VisualizerSettings(
      pulseEnabled: j['pulseEnabled'] is bool ? j['pulseEnabled'] : true,
      pulseMode: j['pulseMode'] == 'advanced' ? PulseMode.advanced : PulseMode.autoBeat,
      autoPulse: j['autoPulse'] is bool ? j['autoPulse'] : true,
      sensitivity: (j['sensitivity'] as num?)?.toDouble() ?? 79,
      beatDuration: (j['beatDuration'] as num?)?.toDouble() ?? 10,
      brightness: (j['brightness'] as num?)?.toDouble() ?? 0.7,
      themeIndex: (j['themeIndex'] as num?)?.toInt() ?? 0,
      explicitPlot: j['explicitPlot'] is bool ? j['explicitPlot'] : false,
      terrainDensity: (j['terrainDensity'] as num?)?.toInt() ?? 33,
      detectLevel: (j['detectLevel'] as num?)?.toDouble() ?? 100,
      bandStart: (j['bandStart'] as num?)?.toInt() ?? 0,
      bandEnd: (j['bandEnd'] as num?)?.toInt() ?? 7,
      form: j['form'] == 'nebula' ? VisualizerForm.nebula : VisualizerForm.terrain,
    );
  }
}

const String _kPrefsKey = 'visualizer.settings.v1';

class VisualizerSettingsNotifier extends StateNotifier<VisualizerSettings> {
  VisualizerSettingsNotifier() : super(const VisualizerSettings()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        state = VisualizerSettings.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // 读取失败保持默认。
    }
  }

  Future<void> update(VisualizerSettings Function(VisualizerSettings) fn) async {
    final next = fn(state);
    state = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefsKey, jsonEncode(next.toJson()));
    } catch (_) {}
  }
}

final visualizerSettingsProvider =
    StateNotifierProvider<VisualizerSettingsNotifier, VisualizerSettings>(
  (ref) => VisualizerSettingsNotifier(),
);
