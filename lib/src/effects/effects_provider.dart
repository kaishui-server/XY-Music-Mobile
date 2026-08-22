import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api.dart';

class EffectsSettings {
  const EffectsSettings({
    this.equalizerEnabled = false,
    this.preamp = 0,
    this.gains = const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    this.reverbPreset = '',
    this.spatialMode = 'none',
    this.bassBoost = false,
    this.stereoWiden = false,
    this.vocalRemoval = false,
    this.audioBoost = 0,
  });

  final bool equalizerEnabled;
  final double preamp;
  final List<double> gains;
  final String reverbPreset;
  final String spatialMode;
  final bool bassBoost;
  final bool stereoWiden;
  final bool vocalRemoval;
  final double audioBoost;

  EffectsSettings copyWith({
    bool? equalizerEnabled,
    double? preamp,
    List<double>? gains,
    String? reverbPreset,
    String? spatialMode,
    bool? bassBoost,
    bool? stereoWiden,
    bool? vocalRemoval,
    double? audioBoost,
  }) => EffectsSettings(
    equalizerEnabled: equalizerEnabled ?? this.equalizerEnabled,
    preamp: preamp ?? this.preamp,
    gains: gains ?? this.gains,
    reverbPreset: reverbPreset ?? this.reverbPreset,
    spatialMode: spatialMode ?? this.spatialMode,
    bassBoost: bassBoost ?? this.bassBoost,
    stereoWiden: stereoWiden ?? this.stereoWiden,
    vocalRemoval: vocalRemoval ?? this.vocalRemoval,
    audioBoost: audioBoost ?? this.audioBoost,
  );

  Map<String, dynamic> toJson() => {
    'equalizerEnabled': equalizerEnabled,
    'preamp': preamp,
    'gains': gains,
    'reverbPreset': reverbPreset,
    'spatialMode': spatialMode,
    'bassBoost': bassBoost,
    'stereoWiden': stereoWiden,
    'vocalRemoval': vocalRemoval,
    'audioBoost': audioBoost,
  };

  factory EffectsSettings.fromJson(Map<String, dynamic> json) {
    final rawGains = (json['gains'] as List? ?? const [])
        .map((value) => (value as num).toDouble())
        .toList();
    return EffectsSettings(
      equalizerEnabled: json['equalizerEnabled'] as bool? ?? false,
      preamp: (json['preamp'] as num?)?.toDouble() ?? 0,
      gains: rawGains.length == 10
          ? rawGains
          : const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      reverbPreset: json['reverbPreset'] as String? ?? '',
      spatialMode: json['spatialMode'] as String? ?? 'none',
      bassBoost: json['bassBoost'] as bool? ?? false,
      stereoWiden: json['stereoWiden'] as bool? ?? false,
      vocalRemoval: json['vocalRemoval'] as bool? ?? false,
      audioBoost: (json['audioBoost'] as num?)?.toDouble() ?? 0,
    );
  }
}

class EffectsNotifier extends AsyncNotifier<EffectsSettings> {
  static const _storageKey = 'mobileEffectsSettings';
  Timer? _persistTimer;

  @override
  Future<EffectsSettings> build() async {
    ref.onDispose(() => _persistTimer?.cancel());
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return const EffectsSettings();
    try {
      return EffectsSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const EffectsSettings();
    }
  }

  Future<void> save(EffectsSettings next) async {
    state = AsyncData(next);
    // 滑块拖动时状态逐帧更新，但本地存储延迟合并写入，避免在低端手机上
    // 因频繁磁盘写入造成掉帧。
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 180), () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(next.toJson()));
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

  Future<void> applyPreset(List<double> gains) async {
    final current = state.valueOrNull ?? const EffectsSettings();
    await save(current.copyWith(equalizerEnabled: true, gains: [...gains]));
  }

  Future<void> _applyToExclusiveOutput(EffectsSettings settings) async {
    try {
      if (!await isUsbExclusiveActive()) return;
      await setUsbExclusiveEqualizer(
        settingsJson: jsonEncode({
          'enabled': settings.equalizerEnabled,
          'preamp': settings.preamp,
          'gains': settings.gains,
        }),
      );
      await setUsbExclusiveSoundEffect(
        settingsJson: jsonEncode({
          'reverbKind': settings.reverbPreset.isEmpty ? 'none' : 'algorithmic',
          'reverbPreset': settings.reverbPreset,
          'reverbDry': .82,
          'reverbWet': settings.reverbPreset.isEmpty ? 0 : .28,
          'spatialMode': settings.spatialMode,
          'spatialSpeed': 10,
          'spatialRadius': 1,
          'spatialIntensity': 6,
          'bassBoost': {
            'enabled': settings.bassBoost,
            'gain': 6,
            'dynamic': true,
          },
          'stereoWiden': {'enabled': settings.stereoWiden, 'amount': 1.35},
          'vocalRemoval': settings.vocalRemoval,
          'audioBoost': settings.audioBoost,
        }),
      );
    } catch (_) {
      // 当前不是独占输出或设备已断开时仍保留设置，下次启动播放时应用。
    }
  }
}

final effectsProvider = AsyncNotifierProvider<EffectsNotifier, EffectsSettings>(
  EffectsNotifier.new,
);
