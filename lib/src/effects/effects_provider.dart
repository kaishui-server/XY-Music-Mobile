import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api.dart';

const eqFreqLabels = ['31', '62', '125', '250', '500', '1k', '2k', '4k', '8k', '16k'];

/// 均衡器各频段中心频率（Hz），与 [eqFreqLabels] 下标一一对应。
/// 应用到系统原生均衡器时按对数频率轴插值映射到设备实际频段。
const eqCenterFrequencies = <double>[
  31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
];

class EqPreset {
  final String name;
  final List<double> gains;
  const EqPreset(this.name, this.gains);
}

List<EqPreset> get eqPresets => <EqPreset>[
  const EqPreset('默认', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  const EqPreset('流行', [-1, 0, 1, 2, 2, 1, 0, -1, -1, -1]),
  const EqPreset('摇滚', [3, 2, 1, 0, -1, -1, 0, 1, 2, 3]),
  const EqPreset('爵士', [2, 1, 0, 1, 1, 0, -1, 0, 1, 2]),
  const EqPreset('古典', [2, 1, 0, -1, -1, -1, 0, 1, 2, 3]),
  const EqPreset('电子', [3, 2, 1, 0, -1, 0, 1, 2, 3, 4]),
  const EqPreset('低音增强', [4, 3, 2, 1, 0, 0, 0, 0, 0, 0]),
  const EqPreset('人声', [-1, -1, -1, 1, 2, 3, 2, 1, 0, -1]),
  const EqPreset('高音增强', [0, 0, 0, 0, 0, 1, 2, 3, 4, 4]),
];

class ReverbPreset {
  final String label;
  final int dry;
  final int wet;
  const ReverbPreset(this.label, this.dry, this.wet);
}

List<ReverbPreset> get reverbPresets => const <ReverbPreset>[
  ReverbPreset('大厅', 80, 40),
  ReverbPreset('房间', 85, 30),
  ReverbPreset('浴室', 75, 50),
  ReverbPreset('隧道', 70, 60),
  ReverbPreset('峡谷', 65, 55),
  ReverbPreset('教堂', 60, 45),
];

List<ReverbPreset> get algoReverbPresets => const <ReverbPreset>[
  ReverbPreset('算法大厅', 85, 40),
  ReverbPreset('算法房间', 90, 30),
  ReverbPreset('算法板式', 80, 50),
  ReverbPreset('算法弹簧', 88, 35),
];

class CustomEqPreset {
  final String name;
  final List<double> gains;
  const CustomEqPreset(this.name, this.gains);

  Map<String, dynamic> toJson() => {'name': name, 'gains': gains};

  factory CustomEqPreset.fromJson(Map<String, dynamic> j) => CustomEqPreset(
        j['name'] as String? ?? '未命名',
        (j['gains'] as List? ?? const [])
            .map((e) => (e as num).toDouble())
            .toList(),
      );
}

class EffectsSettings {
  const EffectsSettings({
    this.equalizerEnabled = false,
    this.preamp = 0,
    this.gains = const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    this.pitchShift = 100,
    this.playbackRate = 100,
    this.preservesPitch = true,
    this.reverbKind = 'none',
    this.reverbPreset = '',
    this.reverbDry = 0,
    this.reverbWet = 0,
    this.spatialMode = 'none',
    this.spatialSpeed = 10,
    this.spatialRadius = 5,
    this.spatialIntensity = 9,
    this.virtualSurroundMode = '7.1',
    this.virtualSurroundSpread = 10,
    this.bypass = false,
  });

  final bool equalizerEnabled;
  final double preamp;
  final List<double> gains;

  final double pitchShift;
  final double playbackRate;
  final bool preservesPitch;
  final String reverbKind;
  final String reverbPreset;
  final double reverbDry;
  final double reverbWet;
  final String spatialMode;
  final double spatialSpeed;
  final double spatialRadius;
  final double spatialIntensity;
  final String virtualSurroundMode;
  final double virtualSurroundSpread;
  final bool bypass;

  EffectsSettings copyWith({
    bool? equalizerEnabled,
    double? preamp,
    List<double>? gains,
    double? pitchShift,
    double? playbackRate,
    bool? preservesPitch,
    String? reverbKind,
    String? reverbPreset,
    double? reverbDry,
    double? reverbWet,
    String? spatialMode,
    double? spatialSpeed,
    double? spatialRadius,
    double? spatialIntensity,
    String? virtualSurroundMode,
    double? virtualSurroundSpread,
    bool? bypass,
  }) => EffectsSettings(
    equalizerEnabled: equalizerEnabled ?? this.equalizerEnabled,
    preamp: preamp ?? this.preamp,
    gains: gains ?? this.gains,
    pitchShift: pitchShift ?? this.pitchShift,
    playbackRate: playbackRate ?? this.playbackRate,
    preservesPitch: preservesPitch ?? this.preservesPitch,
    reverbKind: reverbKind ?? this.reverbKind,
    reverbPreset: reverbPreset ?? this.reverbPreset,
    reverbDry: reverbDry ?? this.reverbDry,
    reverbWet: reverbWet ?? this.reverbWet,
    spatialMode: spatialMode ?? this.spatialMode,
    spatialSpeed: spatialSpeed ?? this.spatialSpeed,
    spatialRadius: spatialRadius ?? this.spatialRadius,
    spatialIntensity: spatialIntensity ?? this.spatialIntensity,
    virtualSurroundMode: virtualSurroundMode ?? this.virtualSurroundMode,
    virtualSurroundSpread: virtualSurroundSpread ?? this.virtualSurroundSpread,
    bypass: bypass ?? this.bypass,
  );

  Map<String, dynamic> toEqualizerRustJson() => {
        'enabled': equalizerEnabled,
        'preamp': preamp,
        'gains': gains,
      };

  Map<String, dynamic> toRustJson() => {
        'pitchShift': pitchShift,
        'playbackRate': playbackRate,
        'preservesPitch': preservesPitch,
        'reverbKind': reverbKind,
        'reverbPreset': reverbPreset,
        'reverbDry': reverbDry.clamp(0.0, 1.0),
        'reverbWet': reverbWet.clamp(0.0, 1.0),
        'spatialMode': spatialMode,
        'spatialSpeed': spatialSpeed,
        'spatialRadius': spatialRadius,
        'spatialIntensity': spatialIntensity,
        'virtualSurroundMode': virtualSurroundMode,
        'virtualSurroundSpread': virtualSurroundSpread,
        'bypass': bypass,
      };

  /// 是否有任一音效处于启用状态（bypass 属于旁路关闭，不计入）：
  /// 供播放页更多菜单等处的「开/关」指示使用。
  bool get hasActiveEffects =>
      equalizerEnabled ||
      pitchShift != 100 ||
      playbackRate != 100 ||
      reverbKind != 'none' ||
      spatialMode != 'none';

  Map<String, dynamic> toJson() => {
        ...toEqualizerRustJson(),
        ...toRustJson(),
      };

  /// 干/湿声归一化到 0..1。旧版本混响预设曾把 0..100 的百分比直接存入，
  /// 读取时对 >1 的值按百分比折算，避免历史存档把干湿比压成满值。
  static double _normalizeReverbMix(num? raw) {
    final v = raw?.toDouble() ?? 0;
    if (v > 1) return (v / 100).clamp(0.0, 1.0);
    return v.clamp(0.0, 1.0);
  }

  factory EffectsSettings.fromJson(Map<String, dynamic> j) {
    final rawGains = (j['gains'] as List? ?? const [])
        .map((v) => (v as num).toDouble())
        .toList();
    return EffectsSettings(
      equalizerEnabled: j['equalizerEnabled'] as bool? ?? false,
      preamp: (j['preamp'] as num?)?.toDouble() ?? 0,
      gains: rawGains.length == 10 ? rawGains : const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      pitchShift: (j['pitchShift'] as num?)?.toDouble() ?? 100,
      playbackRate: (j['playbackRate'] as num?)?.toDouble() ?? 100,
      preservesPitch: j['preservesPitch'] as bool? ?? true,
      reverbKind: j['reverbKind'] as String? ?? 'none',
      reverbPreset: j['reverbPreset'] as String? ?? '',
      reverbDry: _normalizeReverbMix(j['reverbDry'] as num?),
      reverbWet: _normalizeReverbMix(j['reverbWet'] as num?),
      spatialMode: j['spatialMode'] as String? ?? 'none',
      spatialSpeed: (j['spatialSpeed'] as num?)?.toDouble() ?? 10,
      spatialRadius: (j['spatialRadius'] as num?)?.toDouble() ?? 5,
      spatialIntensity: (j['spatialIntensity'] as num?)?.toDouble() ?? 9,
      virtualSurroundMode: j['virtualSurroundMode'] as String? ?? '7.1',
      virtualSurroundSpread: (j['virtualSurroundSpread'] as num?)?.toDouble() ?? 10,
      bypass: j['bypass'] as bool? ?? false,
    );
  }
}

class EffectsNotifier extends AsyncNotifier<EffectsSettings> {
  static const _storageKey = 'mobileEffectsSettings';
  Timer? _persistTimer;
  List<CustomEqPreset> _customEqPresets = const [];

  @override
  Future<EffectsSettings> build() async {
    ref.onDispose(() => _persistTimer?.cancel());
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return const EffectsSettings();
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final settings = EffectsSettings.fromJson(
        decoded.containsKey('settings')
            ? decoded['settings'] as Map<String, dynamic>
            : decoded,
      );
      _customEqPresets = (decoded['customEqPresets'] as List? ?? const [])
          .map((e) => CustomEqPreset.fromJson(e as Map<String, dynamic>))
          .toList();
      return settings;
    } catch (_) {
      return const EffectsSettings();
    }
  }

  List<CustomEqPreset> get customEqPresets => _customEqPresets;

  Future<void> save(EffectsSettings next) async {
    state = AsyncData(next);
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 180), () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode({
        'settings': next.toJson(),
        'customEqPresets': _customEqPresets.map((p) => p.toJson()).toList(),
      }));
    });
    await _applyToExclusiveOutput(next);
  }

  Future<void> setBand(int index, double value) async {
    final current = state.valueOrNull ?? const EffectsSettings();
    final gains = [...current.gains];
    gains[index] = value;
    await save(current.copyWith(gains: gains));
  }

  Future<void> resetEqualizer() async {
    final current = state.valueOrNull ?? const EffectsSettings();
    await save(current.copyWith(preamp: 0, gains: List.filled(10, 0)));
  }

  Future<void> applyPreset(List<double> presetGains) async {
    final current = state.valueOrNull ?? const EffectsSettings();
    await save(current.copyWith(equalizerEnabled: true, gains: [...presetGains]));
  }

  Future<void> applyEqPreset(String name) async {
    final preset = eqPresets.where((p) => p.name == name).toList();
    if (preset.isEmpty) return;
    await applyPreset([...preset.first.gains]);
  }

  Future<void> saveCustomEqPreset(String name) async {
    final g = name.trim();
    if (g.isEmpty) return;
    final current = state.valueOrNull ?? const EffectsSettings();
    final preset = CustomEqPreset(g, [...current.gains]);
    final list = [..._customEqPresets];
    final idx = list.indexWhere((p) => p.name == g);
    if (idx >= 0) {
      list[idx] = preset;
    } else {
      list.add(preset);
    }
    _customEqPresets = list;
    await _persistCustom();
    _notifyCustomChange();
  }

  Future<void> renameCustomEqPreset(String oldName, String newName) async {
    final g = newName.trim();
    if (g.isEmpty || g == oldName) return;
    final list = [..._customEqPresets];
    final idx = list.indexWhere((p) => p.name == oldName);
    if (idx < 0) return;
    list[idx] = CustomEqPreset(g, list[idx].gains);
    _customEqPresets = list;
    await _persistCustom();
    _notifyCustomChange();
  }

  Future<void> deleteCustomEqPreset(String name) async {
    _customEqPresets = _customEqPresets.where((p) => p.name != name).toList();
    await _persistCustom();
    _notifyCustomChange();
  }

  void _notifyCustomChange() {
    final current = state.valueOrNull ?? const EffectsSettings();
    state = AsyncData(current.copyWith());
  }

  Future<void> applyCustomEqPreset(String name) async {
    final preset = _customEqPresets.where((p) => p.name == name).toList();
    if (preset.isEmpty) return;
    await applyPreset([...preset.first.gains]);
  }

  Future<void> _persistCustom() async {
    final prefs = await SharedPreferences.getInstance();
    final current = state.valueOrNull ?? const EffectsSettings();
    await prefs.setString(_storageKey, jsonEncode({
      'settings': current.toJson(),
      'customEqPresets': _customEqPresets.map((p) => p.toJson()).toList(),
    }));
  }

  Future<void> setReverb(String kind, String preset, double dry, double wet) async {
    final current = state.valueOrNull ?? const EffectsSettings();
    await save(current.copyWith(reverbKind: kind, reverbPreset: preset, reverbDry: dry, reverbWet: wet));
  }

  Future<void> clearReverb() async {
    final current = state.valueOrNull ?? const EffectsSettings();
    await save(current.copyWith(reverbKind: 'none', reverbPreset: '', reverbDry: 0, reverbWet: 0));
  }

  Future<void> setSpatial(String mode, {double? speed, double? radius}) async {
    final current = state.valueOrNull ?? const EffectsSettings();
    await save(current.copyWith(
      spatialMode: mode,
      spatialSpeed: speed ?? current.spatialSpeed,
      spatialRadius: radius ?? current.spatialRadius,
    ));
  }

  Future<void> resetAll() async {
    _customEqPresets = const [];
    await save(const EffectsSettings());
  }

  Future<void> _applyToExclusiveOutput(EffectsSettings settings) async {
    // DSP 共享管线接管期间由播放器统一下发音效 JSON：其 JSON 已合成
    // 播放页倍速（静音时钟对齐），此处原始 toRustJson 直发会与之
    // 竞态互相覆盖，导致管线变速与进度错位。仅 USB 独占模式直发。
    if (dspPipelineOwnsEffects) return;
    try {
      if (!await isUsbExclusiveActive()) return;
      await setUsbExclusiveEqualizer(
        settingsJson: jsonEncode(settings.toEqualizerRustJson()),
      );
      await setUsbExclusiveSoundEffect(
        settingsJson: jsonEncode(settings.toRustJson()),
      );
    } catch (_) {}
  }
}

/// 播放器 DSP 共享管线是否接管出声（由 player_provider 维护）。
/// true 时本文件 save() 的独占直发让位，见 [_applyToExclusiveOutput]。
bool dspPipelineOwnsEffects = false;

final effectsProvider = AsyncNotifierProvider<EffectsNotifier, EffectsSettings>(
  EffectsNotifier.new,
);
