// visualizer_settings.dart — 可视化页全部设置面板的模型与持久化
// （SharedPreferences JSON，独立于全局 settingsProvider）。
//
// 面板对齐 sonic-topography：主题配色 / 地形均衡器 / 悬浮方块 /
// 脉冲触发 / 流星触发 / 歌词设置 / 音频检测。

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 可视化形态。
enum VisualizerForm { terrain, nebula }

/// 主题色板（对齐「主题配色」五个预设色卡）。
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
  VisTheme('ink', '墨韵', 0xFFE8EAED, 0xFF4E5257, 0xFFFFFFFF),
  VisTheme('night', '暗夜', 0xFF7FD8F5, 0xFF2E6E86, 0xFFB8ECFF),
  VisTheme('neon', '霓虹', 0xFFC0A6FF, 0xFF4A3B73, 0xFFE2D6FF),
  VisTheme('cyber', '赛博', 0xFFB8E986, 0xFF4E6B33, 0xFFE0F7C0),
  VisTheme('minimal', '极简', 0xFFB9BDC4, 0xFF3A3E44, 0xFF8E959E),
  // 烈焰（5540 新增，对齐 LX-X 火焰橙红紫观感；追加末位保持旧 themeIndex 稳定）。
  VisTheme('ember', '烈焰', 0xFFFFB05C, 0xFF6E2440, 0xFFFF5A36),
];

/// 触发器模式（脉冲/流星共用）。
enum TriggerMode { autoBeat, advanced }

/// 歌词显示模式。
enum LyricsMode { classic, bounce, space3d }

/// 地形 EQ 单频段。
class VisEqBand {
  final bool on;
  final double value; // 0..100
  const VisEqBand({this.on = true, this.value = 50});
  VisEqBand copyWith({bool? on, double? value}) =>
      VisEqBand(on: on ?? this.on, value: value ?? this.value);
}

/// 8 频段地形 EQ（Sub/Bass/LoMid/Mid/HiMid/Pres/Brill/Air）。
const kEqBandNames = ['Sub', 'Bass', 'LoMid', 'Mid', 'HiMid', 'Pres', 'Brill', 'Air'];

class VisualizerSettings {
  // —— 主题配色 ——
  final int themeIndex;
  final bool showCover; // 显示封面幽灵层
  // —— 地形均衡器 ——
  final List<VisEqBand> groundEq; // 8 段
  final double motionSpeed; // 0..100 运动速度（默认 50）
  final double amplitude; // 0..100 振幅（默认 50）
  final int terrainDensity; // 0..100 地形密度（默认 46）
  // —— 悬浮方块 ——
  final bool blocksEnabled;
  final double blockIntensity; // 0..100
  final double blockMinSize; // 0..100
  final double blockMaxSize; // 0..100
  final double blockSpeed; // 0..100
  // —— 脉冲触发 ——
  final bool kickEnabled;
  final TriggerMode kickMode;
  final bool kickAutoTrack; // 自动追踪
  final double kickSensitivity; // 0..1
  final double kickCooldownFrames; // 0..240
  final double kickStrength; // 0..1
  // —— 流星触发 ——
  final bool meteorEnabled;
  final TriggerMode meteorMode;
  final double meteorSensitivity; // 0..1
  final double meteorCooldownFrames; // 0..240
  final double meteorStrength; // 0..1
  // —— 歌词设置 ——
  final LyricsMode lyricsMode;
  final bool lyricsShow;
  final double lyricsActiveSize; // 活跃字号
  final double lyricsInactiveSize; // 非活跃字号
  final double lyricsMaxChars; // 每行最大字数
  final int lyricsColor; // 字体颜色（ARGB，独立于主题不随配色变化）
  final bool lyricsFollowTheme; // 卡拉OK颜色跟随主题
  final bool lyricsSerif; // Serif / Sans
  final double lyricsOffsetX; // 空间偏移
  // —— 音频检测 ——
  final double detectLevel; // 0..100 节拍检测灵敏度
  // —— Advanced 触发频段（共用） ——
  final int bandStart;
  final int bandEnd;
  // —— 形态 ——
  final VisualizerForm form;

  const VisualizerSettings({
    this.themeIndex = 1, // 默认暗夜（对齐参考版默认观感）
    this.showCover = true,
    this.groundEq = const [
      VisEqBand(value: 50), VisEqBand(value: 50), VisEqBand(value: 50),
      VisEqBand(value: 50), VisEqBand(value: 50), VisEqBand(value: 50),
      VisEqBand(value: 50), VisEqBand(value: 50),
    ],
    this.motionSpeed = 50,
    this.amplitude = 50,
    this.terrainDensity = 46,
    this.blocksEnabled = false,
    this.blockIntensity = 55,
    this.blockMinSize = 9,
    this.blockMaxSize = 26,
    this.blockSpeed = 77,
    this.kickEnabled = true,
    this.kickMode = TriggerMode.autoBeat,
    this.kickAutoTrack = true,
    this.kickSensitivity = 0.8,
    this.kickCooldownFrames = 15,
    this.kickStrength = 0.5, // 默认脉冲强度（0.2 的节拍/单击波纹偏弱）
    this.meteorEnabled = true,
    this.meteorMode = TriggerMode.autoBeat,
    this.meteorSensitivity = 0.5,
    this.meteorCooldownFrames = 241,
    this.meteorStrength = 0.5,
    this.lyricsMode = LyricsMode.classic,
    this.lyricsShow = true,
    this.lyricsActiveSize = 15,
    this.lyricsInactiveSize = 10,
    this.lyricsMaxChars = 48,
    this.lyricsColor = 0xFFFFFFFF,
    this.lyricsFollowTheme = true,
    this.lyricsSerif = false,
    this.lyricsOffsetX = 0,
    this.detectLevel = 100,
    this.bandStart = 0,
    this.bandEnd = 7,
    this.form = VisualizerForm.terrain,
  });

  VisTheme get theme =>
      themeIndex >= 0 && themeIndex < kVisThemes.length
          ? kVisThemes[themeIndex]
          : kVisThemes.first;

  /// EQ 增益（0..1，off→0）。
  double eqGain(int i) =>
      i >= 0 && i < groundEq.length && groundEq[i].on
          ? (groundEq[i].value / 100).clamp(0.0, 1.0)
          : 0.0;

  VisualizerSettings copyWith({
    int? themeIndex,
    bool? showCover,
    List<VisEqBand>? groundEq,
    double? motionSpeed,
    double? amplitude,
    int? terrainDensity,
    bool? blocksEnabled,
    double? blockIntensity,
    double? blockMinSize,
    double? blockMaxSize,
    double? blockSpeed,
    bool? kickEnabled,
    TriggerMode? kickMode,
    bool? kickAutoTrack,
    double? kickSensitivity,
    double? kickCooldownFrames,
    double? kickStrength,
    bool? meteorEnabled,
    TriggerMode? meteorMode,
    double? meteorSensitivity,
    double? meteorCooldownFrames,
    double? meteorStrength,
    LyricsMode? lyricsMode,
    bool? lyricsShow,
    double? lyricsActiveSize,
    double? lyricsInactiveSize,
    double? lyricsMaxChars,
    int? lyricsColor,
    bool? lyricsFollowTheme,
    bool? lyricsSerif,
    double? lyricsOffsetX,
    double? detectLevel,
    int? bandStart,
    int? bandEnd,
    VisualizerForm? form,
  }) {
    return VisualizerSettings(
      themeIndex: themeIndex ?? this.themeIndex,
      showCover: showCover ?? this.showCover,
      groundEq: groundEq ?? this.groundEq,
      motionSpeed: motionSpeed ?? this.motionSpeed,
      amplitude: amplitude ?? this.amplitude,
      terrainDensity: terrainDensity ?? this.terrainDensity,
      blocksEnabled: blocksEnabled ?? this.blocksEnabled,
      blockIntensity: blockIntensity ?? this.blockIntensity,
      blockMinSize: blockMinSize ?? this.blockMinSize,
      blockMaxSize: blockMaxSize ?? this.blockMaxSize,
      blockSpeed: blockSpeed ?? this.blockSpeed,
      kickEnabled: kickEnabled ?? this.kickEnabled,
      kickMode: kickMode ?? this.kickMode,
      kickAutoTrack: kickAutoTrack ?? this.kickAutoTrack,
      kickSensitivity: kickSensitivity ?? this.kickSensitivity,
      kickCooldownFrames: kickCooldownFrames ?? this.kickCooldownFrames,
      kickStrength: kickStrength ?? this.kickStrength,
      meteorEnabled: meteorEnabled ?? this.meteorEnabled,
      meteorMode: meteorMode ?? this.meteorMode,
      meteorSensitivity: meteorSensitivity ?? this.meteorSensitivity,
      meteorCooldownFrames: meteorCooldownFrames ?? this.meteorCooldownFrames,
      meteorStrength: meteorStrength ?? this.meteorStrength,
      lyricsMode: lyricsMode ?? this.lyricsMode,
      lyricsShow: lyricsShow ?? this.lyricsShow,
      lyricsActiveSize: lyricsActiveSize ?? this.lyricsActiveSize,
      lyricsInactiveSize: lyricsInactiveSize ?? this.lyricsInactiveSize,
      lyricsMaxChars: lyricsMaxChars ?? this.lyricsMaxChars,
      lyricsColor: lyricsColor ?? this.lyricsColor,
      lyricsFollowTheme: lyricsFollowTheme ?? this.lyricsFollowTheme,
      lyricsSerif: lyricsSerif ?? this.lyricsSerif,
      lyricsOffsetX: lyricsOffsetX ?? this.lyricsOffsetX,
      detectLevel: detectLevel ?? this.detectLevel,
      bandStart: bandStart ?? this.bandStart,
      bandEnd: bandEnd ?? this.bandEnd,
      form: form ?? this.form,
    );
  }

  Map<String, dynamic> toJson() => {
        'v': kVisSettingsVersion,
        'themeIndex': themeIndex,
        'showCover': showCover,
        'groundEq': [
          for (final b in groundEq) {'on': b.on, 'v': b.value}
        ],
        'motionSpeed': motionSpeed,
        'amplitude': amplitude,
        'terrainDensity': terrainDensity,
        'blocksEnabled': blocksEnabled,
        'blockIntensity': blockIntensity,
        'blockMinSize': blockMinSize,
        'blockMaxSize': blockMaxSize,
        'blockSpeed': blockSpeed,
        'kickEnabled': kickEnabled,
        'kickMode': kickMode == TriggerMode.autoBeat ? 'auto' : 'advanced',
        'kickAutoTrack': kickAutoTrack,
        'kickSensitivity': kickSensitivity,
        'kickCooldownFrames': kickCooldownFrames,
        'kickStrength': kickStrength,
        'meteorEnabled': meteorEnabled,
        'meteorMode': meteorMode == TriggerMode.autoBeat ? 'auto' : 'advanced',
        'meteorSensitivity': meteorSensitivity,
        'meteorCooldownFrames': meteorCooldownFrames,
        'meteorStrength': meteorStrength,
        'lyricsMode': lyricsMode.index,
        'lyricsShow': lyricsShow,
        'lyricsActiveSize': lyricsActiveSize,
        'lyricsInactiveSize': lyricsInactiveSize,
        'lyricsMaxChars': lyricsMaxChars,
        'lyricsColor': lyricsColor,
        'lyricsFollowTheme': lyricsFollowTheme,
        'lyricsSerif': lyricsSerif,
        'lyricsOffsetX': lyricsOffsetX,
        'detectLevel': detectLevel,
        'bandStart': bandStart,
        'bandEnd': bandEnd,
        'form': form == VisualizerForm.terrain ? 'terrain' : 'nebula',
      };

  static VisualizerSettings fromJson(Map<String, dynamic> j) {
    // 旧版本存档（无 v 或 v < 当前）→ 一次性弃用，回到新版默认值
    // （5539 调整了暗夜主题/脉冲强度等默认观感，老存档的旧默认值不再适用）。
    final storedV = (j['v'] as num?)?.toInt() ?? 1;
    if (storedV < kVisSettingsVersion) {
      return const VisualizerSettings();
    }
    List<VisEqBand> eq = const [];
    if (j['groundEq'] is List) {
      eq = [
        for (final e in j['groundEq'] as List)
          if (e is Map)
            VisEqBand(
              on: e['on'] is bool ? e['on'] : true,
              value: (e['v'] as num?)?.toDouble() ?? 50,
            ),
      ];
    }
    return VisualizerSettings(
      themeIndex: (j['themeIndex'] as num?)?.toInt() ?? 1,
      showCover: j['showCover'] is bool ? j['showCover'] : true,
      groundEq: eq.length == 8
          ? eq
          : const [
              VisEqBand(value: 50), VisEqBand(value: 50), VisEqBand(value: 50),
              VisEqBand(value: 50), VisEqBand(value: 50), VisEqBand(value: 50),
              VisEqBand(value: 50), VisEqBand(value: 50),
            ],
      motionSpeed: (j['motionSpeed'] as num?)?.toDouble() ?? 50,
      amplitude: (j['amplitude'] as num?)?.toDouble() ?? 50,
      terrainDensity: (j['terrainDensity'] as num?)?.toInt() ?? 46,
      blocksEnabled: j['blocksEnabled'] is bool ? j['blocksEnabled'] : false,
      blockIntensity: (j['blockIntensity'] as num?)?.toDouble() ?? 55,
      blockMinSize: (j['blockMinSize'] as num?)?.toDouble() ?? 9,
      blockMaxSize: (j['blockMaxSize'] as num?)?.toDouble() ?? 26,
      blockSpeed: (j['blockSpeed'] as num?)?.toDouble() ?? 77,
      kickEnabled: j['kickEnabled'] is bool ? j['kickEnabled'] : true,
      kickMode:
          j['kickMode'] == 'advanced' ? TriggerMode.advanced : TriggerMode.autoBeat,
      kickAutoTrack: j['kickAutoTrack'] is bool ? j['kickAutoTrack'] : true,
      kickSensitivity: (j['kickSensitivity'] as num?)?.toDouble() ?? 0.8,
      kickCooldownFrames: (j['kickCooldownFrames'] as num?)?.toDouble() ?? 15,
      kickStrength: (j['kickStrength'] as num?)?.toDouble() ?? 0.2,
      meteorEnabled: j['meteorEnabled'] is bool ? j['meteorEnabled'] : true,
      meteorMode: j['meteorMode'] == 'advanced'
          ? TriggerMode.advanced
          : TriggerMode.autoBeat,
      meteorSensitivity: (j['meteorSensitivity'] as num?)?.toDouble() ?? 0.5,
      meteorCooldownFrames: (j['meteorCooldownFrames'] as num?)?.toDouble() ?? 241,
      meteorStrength: (j['meteorStrength'] as num?)?.toDouble() ?? 0.5,
      lyricsMode: LyricsMode.values.length >
              ((j['lyricsMode'] as num?)?.toInt() ?? 0)
          ? LyricsMode.values[(j['lyricsMode'] as num?)?.toInt() ?? 0]
          : LyricsMode.classic,
      lyricsShow: j['lyricsShow'] is bool ? j['lyricsShow'] : true,
      lyricsActiveSize: (j['lyricsActiveSize'] as num?)?.toDouble() ?? 15,
      lyricsInactiveSize: (j['lyricsInactiveSize'] as num?)?.toDouble() ?? 10,
      lyricsMaxChars: (j['lyricsMaxChars'] as num?)?.toDouble() ?? 48,
      lyricsColor: (j['lyricsColor'] as num?)?.toInt() ?? 0xFFFFFFFF,
      lyricsFollowTheme: j['lyricsFollowTheme'] is bool
          ? j['lyricsFollowTheme']
          : true,
      lyricsSerif: j['lyricsSerif'] is bool ? j['lyricsSerif'] : false,
      lyricsOffsetX: (j['lyricsOffsetX'] as num?)?.toDouble() ?? 0,
      detectLevel: (j['detectLevel'] as num?)?.toDouble() ?? 100,
      bandStart: (j['bandStart'] as num?)?.toInt() ?? 0,
      bandEnd: (j['bandEnd'] as num?)?.toInt() ?? 7,
      form: j['form'] == 'nebula' ? VisualizerForm.nebula : VisualizerForm.terrain,
    );
  }
}

const String _kPrefsKey = 'visualizer.settings.v2';

/// 设置存档版本：提升后旧存档一次性重置为新默认值。
const int kVisSettingsVersion = 2;

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
