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
    this.vocalRemoval = false,
    this.vibratoEnabled = false,
    this.vibratoRate = 5,
    this.vibratoDepth = 3,
    this.tremoloEnabled = false,
    this.tremoloRate = 6,
    this.tremoloDepth = 30,
    this.bassBoostEnabled = false,
    this.bassBoostGain = 6,
    this.bassBoostDynamic = true,
    this.trebleEnabled = false,
    this.trebleGain = 6,
    this.distortionEnabled = false,
    this.distortionAmount = 10,
    this.distortionType = 'soft',
    this.delayEnabled = false,
    this.delayTime = 300,
    this.delayFeedback = 40,
    this.delayMix = 30,
    this.delayType = 'single',
    this.flangerEnabled = false,
    this.flangerRate = 0.5,
    this.flangerDepth = 2,
    this.flangerFeedback = 30,
    this.flangerMix = 35,
    this.phaserEnabled = false,
    this.phaserRate = 0.5,
    this.phaserDepth = 1,
    this.phaserFeedback = 30,
    this.phaserMix = 50,
    this.compressorEnabled = false,
    this.compressorThreshold = -18,
    this.compressorRatio = 4,
    this.compressorAttack = 8,
    this.compressorRelease = 400,
    this.noiseGateEnabled = false,
    this.noiseGateThreshold = -60,
    this.limiterEnabled = false,
    this.limiterThreshold = -1,
    this.exciterEnabled = false,
    this.exciterAmount = 20,
    this.exciterFrequency = 3000,
    this.subBassEnabled = false,
    this.subBassAmount = 30,
    this.subBassFrequency = 120,
    this.loFiEnabled = false,
    this.loFiSampleRate = 8000,
    this.loFiBitDepth = 8,
    this.stereoWidenEnabled = false,
    this.stereoWidenAmount = 1.5,
    this.monoMerge = false,
    this.channelSwap = false,
    this.v4aEnabled = false,
    this.bypass = false,
    this.audioBoost = 0,
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
  final bool vocalRemoval;
  final bool vibratoEnabled;
  final double vibratoRate;
  final double vibratoDepth;
  final bool tremoloEnabled;
  final double tremoloRate;
  final double tremoloDepth;
  final bool bassBoostEnabled;
  final double bassBoostGain;
  final bool bassBoostDynamic;
  final bool trebleEnabled;
  final double trebleGain;
  final bool distortionEnabled;
  final double distortionAmount;
  final String distortionType;
  final bool delayEnabled;
  final double delayTime;
  final double delayFeedback;
  final double delayMix;
  final String delayType;
  final bool flangerEnabled;
  final double flangerRate;
  final double flangerDepth;
  final double flangerFeedback;
  final double flangerMix;
  final bool phaserEnabled;
  final double phaserRate;
  final double phaserDepth;
  final double phaserFeedback;
  final double phaserMix;
  final bool compressorEnabled;
  final double compressorThreshold;
  final double compressorRatio;
  final double compressorAttack;
  final double compressorRelease;
  final bool noiseGateEnabled;
  final double noiseGateThreshold;
  final bool limiterEnabled;
  final double limiterThreshold;
  final bool exciterEnabled;
  final double exciterAmount;
  final double exciterFrequency;
  final bool subBassEnabled;
  final double subBassAmount;
  final double subBassFrequency;
  final bool loFiEnabled;
  final double loFiSampleRate;
  final double loFiBitDepth;
  final bool stereoWidenEnabled;
  final double stereoWidenAmount;
  final bool monoMerge;
  final bool channelSwap;
  final bool v4aEnabled;
  final bool bypass;
  final double audioBoost;

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
    bool? vocalRemoval,
    bool? vibratoEnabled,
    double? vibratoRate,
    double? vibratoDepth,
    bool? tremoloEnabled,
    double? tremoloRate,
    double? tremoloDepth,
    bool? bassBoostEnabled,
    double? bassBoostGain,
    bool? bassBoostDynamic,
    bool? trebleEnabled,
    double? trebleGain,
    bool? distortionEnabled,
    double? distortionAmount,
    String? distortionType,
    bool? delayEnabled,
    double? delayTime,
    double? delayFeedback,
    double? delayMix,
    String? delayType,
    bool? flangerEnabled,
    double? flangerRate,
    double? flangerDepth,
    double? flangerFeedback,
    double? flangerMix,
    bool? phaserEnabled,
    double? phaserRate,
    double? phaserDepth,
    double? phaserFeedback,
    double? phaserMix,
    bool? compressorEnabled,
    double? compressorThreshold,
    double? compressorRatio,
    double? compressorAttack,
    double? compressorRelease,
    bool? noiseGateEnabled,
    double? noiseGateThreshold,
    bool? limiterEnabled,
    double? limiterThreshold,
    bool? exciterEnabled,
    double? exciterAmount,
    double? exciterFrequency,
    bool? subBassEnabled,
    double? subBassAmount,
    double? subBassFrequency,
    bool? loFiEnabled,
    double? loFiSampleRate,
    double? loFiBitDepth,
    bool? stereoWidenEnabled,
    double? stereoWidenAmount,
    bool? monoMerge,
    bool? channelSwap,
    bool? v4aEnabled,
    bool? bypass,
    double? audioBoost,
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
    vocalRemoval: vocalRemoval ?? this.vocalRemoval,
    vibratoEnabled: vibratoEnabled ?? this.vibratoEnabled,
    vibratoRate: vibratoRate ?? this.vibratoRate,
    vibratoDepth: vibratoDepth ?? this.vibratoDepth,
    tremoloEnabled: tremoloEnabled ?? this.tremoloEnabled,
    tremoloRate: tremoloRate ?? this.tremoloRate,
    tremoloDepth: tremoloDepth ?? this.tremoloDepth,
    bassBoostEnabled: bassBoostEnabled ?? this.bassBoostEnabled,
    bassBoostGain: bassBoostGain ?? this.bassBoostGain,
    bassBoostDynamic: bassBoostDynamic ?? this.bassBoostDynamic,
    trebleEnabled: trebleEnabled ?? this.trebleEnabled,
    trebleGain: trebleGain ?? this.trebleGain,
    distortionEnabled: distortionEnabled ?? this.distortionEnabled,
    distortionAmount: distortionAmount ?? this.distortionAmount,
    distortionType: distortionType ?? this.distortionType,
    delayEnabled: delayEnabled ?? this.delayEnabled,
    delayTime: delayTime ?? this.delayTime,
    delayFeedback: delayFeedback ?? this.delayFeedback,
    delayMix: delayMix ?? this.delayMix,
    delayType: delayType ?? this.delayType,
    flangerEnabled: flangerEnabled ?? this.flangerEnabled,
    flangerRate: flangerRate ?? this.flangerRate,
    flangerDepth: flangerDepth ?? this.flangerDepth,
    flangerFeedback: flangerFeedback ?? this.flangerFeedback,
    flangerMix: flangerMix ?? this.flangerMix,
    phaserEnabled: phaserEnabled ?? this.phaserEnabled,
    phaserRate: phaserRate ?? this.phaserRate,
    phaserDepth: phaserDepth ?? this.phaserDepth,
    phaserFeedback: phaserFeedback ?? this.phaserFeedback,
    phaserMix: phaserMix ?? this.phaserMix,
    compressorEnabled: compressorEnabled ?? this.compressorEnabled,
    compressorThreshold: compressorThreshold ?? this.compressorThreshold,
    compressorRatio: compressorRatio ?? this.compressorRatio,
    compressorAttack: compressorAttack ?? this.compressorAttack,
    compressorRelease: compressorRelease ?? this.compressorRelease,
    noiseGateEnabled: noiseGateEnabled ?? this.noiseGateEnabled,
    noiseGateThreshold: noiseGateThreshold ?? this.noiseGateThreshold,
    limiterEnabled: limiterEnabled ?? this.limiterEnabled,
    limiterThreshold: limiterThreshold ?? this.limiterThreshold,
    exciterEnabled: exciterEnabled ?? this.exciterEnabled,
    exciterAmount: exciterAmount ?? this.exciterAmount,
    exciterFrequency: exciterFrequency ?? this.exciterFrequency,
    subBassEnabled: subBassEnabled ?? this.subBassEnabled,
    subBassAmount: subBassAmount ?? this.subBassAmount,
    subBassFrequency: subBassFrequency ?? this.subBassFrequency,
    loFiEnabled: loFiEnabled ?? this.loFiEnabled,
    loFiSampleRate: loFiSampleRate ?? this.loFiSampleRate,
    loFiBitDepth: loFiBitDepth ?? this.loFiBitDepth,
    stereoWidenEnabled: stereoWidenEnabled ?? this.stereoWidenEnabled,
    stereoWidenAmount: stereoWidenAmount ?? this.stereoWidenAmount,
    monoMerge: monoMerge ?? this.monoMerge,
    channelSwap: channelSwap ?? this.channelSwap,
    v4aEnabled: v4aEnabled ?? this.v4aEnabled,
    bypass: bypass ?? this.bypass,
    audioBoost: audioBoost ?? this.audioBoost,
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
        'vocalRemoval': vocalRemoval,
        'vibrato': {
          'enabled': vibratoEnabled,
          'rate': vibratoRate,
          'depth': vibratoDepth,
        },
        'tremolo': {
          'enabled': tremoloEnabled,
          'rate': tremoloRate,
          'depth': tremoloDepth,
        },
        'bassBoost': {
          'enabled': bassBoostEnabled,
          'gain': bassBoostGain,
          'dynamic': bassBoostDynamic,
        },
        'treble': {
          'enabled': trebleEnabled,
          'gain': trebleGain,
        },
        'distortion': {
          'enabled': distortionEnabled,
          'amount': distortionAmount,
          'distortionType': distortionType,
        },
        'delay': {
          'enabled': delayEnabled,
          'timeMs': delayTime,
          'feedback': delayFeedback,
          'mix': delayMix,
          'delayType': delayType,
        },
        'flanger': {
          'enabled': flangerEnabled,
          'rate': flangerRate,
          'depth': flangerDepth,
          'feedback': flangerFeedback,
          'mix': flangerMix,
        },
        'phaser': {
          'enabled': phaserEnabled,
          'rate': phaserRate,
          'depth': phaserDepth,
          'feedback': phaserFeedback,
          'mix': phaserMix,
        },
        'compressor': {
          'enabled': compressorEnabled,
          'threshold': compressorThreshold,
          'ratio': compressorRatio,
          'attack': compressorAttack,
          'release': compressorRelease,
        },
        'noiseGate': {
          'enabled': noiseGateEnabled,
          'threshold': noiseGateThreshold,
        },
        'limiter': {
          'enabled': limiterEnabled,
          'threshold': limiterThreshold,
        },
        'exciter': {
          'enabled': exciterEnabled,
          'amount': exciterAmount,
          'frequency': exciterFrequency,
        },
        'subBass': {
          'enabled': subBassEnabled,
          'amount': subBassAmount,
          'frequency': subBassFrequency,
        },
        'loFi': {
          'enabled': loFiEnabled,
          'sampleRate': loFiSampleRate,
          'bitDepth': loFiBitDepth,
        },
        'stereoWiden': {
          'enabled': stereoWidenEnabled,
          'amount': stereoWidenAmount,
        },
        'monoMerge': monoMerge,
        'channelSwap': channelSwap,
        'v4aEnabled': v4aEnabled,
        'bypass': bypass,
        'audioBoost': audioBoost,
      };

  /// 是否有任一音效处于启用状态（bypass 属于旁路关闭，不计入）：
  /// 供播放页更多菜单等处的「开/关」指示使用。
  bool get hasActiveEffects =>
      equalizerEnabled ||
      pitchShift != 100 ||
      playbackRate != 100 ||
      reverbKind != 'none' ||
      spatialMode != 'none' ||
      vocalRemoval ||
      vibratoEnabled ||
      tremoloEnabled ||
      bassBoostEnabled ||
      trebleEnabled ||
      distortionEnabled ||
      delayEnabled ||
      flangerEnabled ||
      phaserEnabled ||
      compressorEnabled ||
      noiseGateEnabled ||
      limiterEnabled ||
      exciterEnabled ||
      subBassEnabled ||
      loFiEnabled ||
      stereoWidenEnabled ||
      monoMerge ||
      channelSwap ||
      v4aEnabled ||
      audioBoost != 0;

  Map<String, dynamic> toJson() => {
        ...toEqualizerRustJson(),
        ...toRustJson(),
      };

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
      reverbDry: (j['reverbDry'] as num?)?.toDouble() ?? 0,
      reverbWet: (j['reverbWet'] as num?)?.toDouble() ?? 0,
      spatialMode: j['spatialMode'] as String? ?? 'none',
      spatialSpeed: (j['spatialSpeed'] as num?)?.toDouble() ?? 10,
      spatialRadius: (j['spatialRadius'] as num?)?.toDouble() ?? 5,
      spatialIntensity: (j['spatialIntensity'] as num?)?.toDouble() ?? 9,
      virtualSurroundMode: j['virtualSurroundMode'] as String? ?? '7.1',
      virtualSurroundSpread: (j['virtualSurroundSpread'] as num?)?.toDouble() ?? 10,
      vocalRemoval: j['vocalRemoval'] as bool? ?? false,
      vibratoEnabled: j['vibratoEnabled'] as bool? ?? false,
      vibratoRate: (j['vibratoRate'] as num?)?.toDouble() ?? 5,
      vibratoDepth: (j['vibratoDepth'] as num?)?.toDouble() ?? 3,
      tremoloEnabled: j['tremoloEnabled'] as bool? ?? false,
      tremoloRate: (j['tremoloRate'] as num?)?.toDouble() ?? 6,
      tremoloDepth: (j['tremoloDepth'] as num?)?.toDouble() ?? 30,
      bassBoostEnabled: j['bassBoostEnabled'] as bool? ?? false,
      bassBoostGain: (j['bassBoostGain'] as num?)?.toDouble() ?? 6,
      bassBoostDynamic: j['bassBoostDynamic'] as bool? ?? true,
      trebleEnabled: j['trebleEnabled'] as bool? ?? false,
      trebleGain: (j['trebleGain'] as num?)?.toDouble() ?? 6,
      distortionEnabled: j['distortionEnabled'] as bool? ?? false,
      distortionAmount: (j['distortionAmount'] as num?)?.toDouble() ?? 10,
      distortionType: j['distortionType'] as String? ?? 'soft',
      delayEnabled: j['delayEnabled'] as bool? ?? false,
      delayTime: (j['delayTime'] as num?)?.toDouble() ?? 300,
      delayFeedback: (j['delayFeedback'] as num?)?.toDouble() ?? 40,
      delayMix: (j['delayMix'] as num?)?.toDouble() ?? 30,
      delayType: j['delayType'] as String? ?? 'single',
      flangerEnabled: j['flangerEnabled'] as bool? ?? false,
      flangerRate: (j['flangerRate'] as num?)?.toDouble() ?? 0.5,
      flangerDepth: (j['flangerDepth'] as num?)?.toDouble() ?? 2,
      flangerFeedback: (j['flangerFeedback'] as num?)?.toDouble() ?? 30,
      flangerMix: (j['flangerMix'] as num?)?.toDouble() ?? 35,
      phaserEnabled: j['phaserEnabled'] as bool? ?? false,
      phaserRate: (j['phaserRate'] as num?)?.toDouble() ?? 0.5,
      phaserDepth: (j['phaserDepth'] as num?)?.toDouble() ?? 1,
      phaserFeedback: (j['phaserFeedback'] as num?)?.toDouble() ?? 30,
      phaserMix: (j['phaserMix'] as num?)?.toDouble() ?? 50,
      compressorEnabled: j['compressorEnabled'] as bool? ?? false,
      compressorThreshold: (j['compressorThreshold'] as num?)?.toDouble() ?? -18,
      compressorRatio: (j['compressorRatio'] as num?)?.toDouble() ?? 4,
      compressorAttack: (j['compressorAttack'] as num?)?.toDouble() ?? 8,
      compressorRelease: (j['compressorRelease'] as num?)?.toDouble() ?? 400,
      noiseGateEnabled: j['noiseGateEnabled'] as bool? ?? false,
      noiseGateThreshold: (j['noiseGateThreshold'] as num?)?.toDouble() ?? -60,
      limiterEnabled: j['limiterEnabled'] as bool? ?? false,
      limiterThreshold: (j['limiterThreshold'] as num?)?.toDouble() ?? -1,
      exciterEnabled: j['exciterEnabled'] as bool? ?? false,
      exciterAmount: (j['exciterAmount'] as num?)?.toDouble() ?? 20,
      exciterFrequency: (j['exciterFrequency'] as num?)?.toDouble() ?? 3000,
      subBassEnabled: j['subBassEnabled'] as bool? ?? false,
      subBassAmount: (j['subBassAmount'] as num?)?.toDouble() ?? 30,
      subBassFrequency: (j['subBassFrequency'] as num?)?.toDouble() ?? 120,
      loFiEnabled: j['loFiEnabled'] as bool? ?? false,
      loFiSampleRate: (j['loFiSampleRate'] as num?)?.toDouble() ?? 8000,
      loFiBitDepth: (j['loFiBitDepth'] as num?)?.toDouble() ?? 8,
      stereoWidenEnabled: j['stereoWidenEnabled'] as bool? ?? false,
      stereoWidenAmount: (j['stereoWidenAmount'] as num?)?.toDouble() ?? 1.5,
      monoMerge: j['monoMerge'] as bool? ?? false,
      channelSwap: j['channelSwap'] as bool? ?? false,
      v4aEnabled: j['v4aEnabled'] as bool? ?? false,
      bypass: j['bypass'] as bool? ?? false,
      audioBoost: (j['audioBoost'] as num?)?.toDouble() ?? 0,
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
