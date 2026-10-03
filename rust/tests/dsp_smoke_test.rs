//! 临时诊断测试：验证 DSP 链对 Dart 真实 JSON 契约的响应。
//! 用完即删（bug4 排查专用）。

use xymusic_core::player::sound_effect::SoundEffectBlockProcessor;
use xymusic_core::player::sound_effect::SoundEffectSettings;

fn sine_wave(frames: usize, channels: u16, freq: f32) -> Vec<f32> {
    let sr = 44100.0f32;
    let mut out = Vec::with_capacity(frames * channels as usize);
    for i in 0..frames {
        let s = (std::f32::consts::TAU * freq * i as f32 / sr).sin() * 0.5;
        for _ in 0..channels {
            out.push(s);
        }
    }
    out
}

fn rms(v: &[f32]) -> f32 {
    (v.iter().map(|s| s * s).sum::<f32>() / v.len().max(1) as f32).sqrt()
}

/// Dart toRustJson() 的真实字段全集（音效页开启混响时的典型输出）。
const DART_JSON_REVERB: &str = r#"{
  "pitchShift": 100.0, "playbackRate": 100.0, "preservesPitch": true,
  "reverbKind": "algorithmic", "reverbPreset": "hall",
  "reverbDry": 0.5, "reverbWet": 0.8,
  "spatialMode": "none", "spatialSpeed": 0.0, "spatialRadius": 0.0,
  "spatialIntensity": 0.0, "virtualSurroundMode": "7.1", "virtualSurroundSpread": 0.0,
  "vocalRemoval": false,
  "vibrato": {"enabled": false, "rate": 0.0, "depth": 0.0},
  "tremolo": {"enabled": false, "rate": 0.0, "depth": 0.0},
  "bassBoost": {"enabled": false, "gain": 0.0, "dynamic": false},
  "treble": {"enabled": false, "gain": 0.0},
  "distortion": {"enabled": false, "amount": 0.0, "distortionType": "soft"},
  "delay": {"enabled": false, "timeMs": 0.0, "feedback": 0.0, "mix": 0.0, "delayType": "single"},
  "flanger": {"enabled": false, "rate": 0.0, "depth": 0.0, "feedback": 0.0, "mix": 0.0},
  "phaser": {"enabled": false, "rate": 0.0, "depth": 0.0, "feedback": 0.0, "mix": 0.0},
  "compressor": {"enabled": false, "threshold": 0.0, "ratio": 0.0, "attack": 0.0, "release": 0.0},
  "noiseGate": {"enabled": false, "threshold": 0.0},
  "limiter": {"enabled": false, "threshold": 0.0},
  "exciter": {"enabled": false, "amount": 0.0, "frequency": 0.0},
  "subBass": {"enabled": false, "amount": 0.0, "frequency": 0.0},
  "loFi": {"enabled": false, "sampleRate": 0.0, "bitDepth": 0.0},
  "stereoWiden": {"enabled": false, "amount": 0.0},
  "monoMerge": false, "channelSwap": false,
  "v4aEnabled": false, "bypass": false, "audioBoost": 0.0
}"#;

#[test]
fn dart_json_contract_parses() {
    let s: SoundEffectSettings = serde_json::from_str(DART_JSON_REVERB)
        .expect("Dart JSON 必须能被 Rust 反序列化（否则整套音效静默失效）");
    assert_eq!(
        s.reverb_kind,
        xymusic_core::player::sound_effect::ReverbKind::Algorithmic
    );
    assert_eq!(s.reverb_wet, 0.8);
}

#[test]
fn reverb_produces_audible_diff() {
    // 算法混响（algoReverbPresets 路径）
    let settings: SoundEffectSettings = serde_json::from_str(DART_JSON_REVERB).unwrap();
    let input = sine_wave(44100, 2, 440.0);
    let mut proc = SoundEffectBlockProcessor::new(44100, 2);
    proc.set_settings(settings);
    let out = proc.process_block(input.clone());
    let in_rms = rms(&input);
    let out_rms = rms(&out);
    println!(
        "reverb(algo): in_rms={in_rms:.4} out_rms={out_rms:.4} len_in={} len_out={}",
        input.len(),
        out.len()
    );
    assert!(
        (out_rms - in_rms).abs() > 0.005,
        "混响未产生可听差异: in={in_rms} out={out_rms}"
    );
}

#[test]
fn convolution_reverb_produces_audible_diff() {
    // 卷积混响（reverbPresets 大厅/房间等 6 个预设的路径）
    let mut settings: SoundEffectSettings = serde_json::from_str(DART_JSON_REVERB).unwrap();
    settings.reverb_kind = xymusic_core::player::sound_effect::ReverbKind::Convolution;
    settings.reverb_preset = "大厅".to_string();
    settings.reverb_dry = 0.8;
    settings.reverb_wet = 0.4;
    let input = sine_wave(44100, 2, 440.0);
    let mut proc = SoundEffectBlockProcessor::new(44100, 2);
    proc.set_settings(settings);
    let out = proc.process_block(input.clone());
    let in_rms = rms(&input);
    let out_rms = rms(&out);
    println!(
        "reverb(conv): in_rms={in_rms:.4} out_rms={out_rms:.4} len_in={} len_out={}",
        input.len(),
        out.len()
    );
    assert!(
        (out_rms - in_rms).abs() > 0.005,
        "卷积混响未产生可听差异: in={in_rms} out={out_rms}"
    );
}

#[test]
fn bass_boost_produces_audible_diff() {
    let mut settings: SoundEffectSettings = serde_json::from_str(DART_JSON_REVERB).unwrap();
    // 关混响，开低音增强（gain=10dB）
    settings.reverb_kind = xymusic_core::player::sound_effect::ReverbKind::None;
    settings.reverb_wet = 0.0;
    settings.bass_boost.enabled = true;
    settings.bass_boost.gain = 10.0;
    // 80Hz 低频正弦（低音增强目标频段）
    let input = sine_wave(44100, 2, 80.0);
    let mut proc = SoundEffectBlockProcessor::new(44100, 2);
    proc.set_settings(settings);
    let out = proc.process_block(input.clone());
    let in_rms = rms(&input);
    let out_rms = rms(&out);
    println!("bass: in_rms={in_rms:.4} out_rms={out_rms:.4}");
    assert!(
        out_rms > in_rms * 1.2,
        "低音增强未放大低频: in={in_rms} out={out_rms}"
    );
}

/// 高音增强是前端音效页独有的开关。此前 Rust 侧缺少 `treble` 字段，
/// serde 会静默丢弃前端下发的参数，且 has_audible_processing() 不计入它，
/// 导致「只开高音增强」时整条音效链被硬旁路（出音与输入完全相同）。
/// 该用例同时覆盖「字段能被解析」与「确实产生增益」两点。
#[test]
fn treble_boost_produces_audible_diff() {
    let mut settings: SoundEffectSettings = serde_json::from_str(DART_JSON_REVERB).unwrap();
    settings.reverb_kind = xymusic_core::player::sound_effect::ReverbKind::None;
    settings.reverb_wet = 0.0;
    settings.treble.enabled = true;
    settings.treble.gain = 10.0;
    // 12kHz 高频正弦（highshelf @ 8kHz 的目标频段）
    let input = sine_wave(44100, 2, 12000.0);
    let mut proc = SoundEffectBlockProcessor::new(44100, 2);
    proc.set_settings(settings);
    let out = proc.process_block(input.clone());
    let in_rms = rms(&input);
    let out_rms = rms(&out);
    println!("treble: in_rms={in_rms:.4} out_rms={out_rms:.4}");
    assert!(
        out_rms > in_rms * 1.2,
        "高音增强未放大高频（字段可能被丢弃或整链被硬旁路）: in={in_rms} out={out_rms}"
    );
}

#[test]
fn vocal_removal_produces_audible_diff() {
    let mut settings: SoundEffectSettings = serde_json::from_str(DART_JSON_REVERB).unwrap();
    settings.reverb_kind = xymusic_core::player::sound_effect::ReverbKind::None;
    settings.reverb_wet = 0.0;
    settings.vocal_removal = true;
    // 立体声：L=R 同相（中央声道，人声典型分布）→ 消人声应大幅衰减
    let mut input = sine_wave(44100, 2, 440.0);
    for frame in input.chunks_mut(2) {
        frame[1] = frame[0]; // R = L（中央信号）
    }
    let mut proc = SoundEffectBlockProcessor::new(44100, 2);
    proc.set_settings(settings);
    let out = proc.process_block(input.clone());
    let in_rms = rms(&input);
    let out_rms = rms(&out);
    println!("vocal: in_rms={in_rms:.4} out_rms={out_rms:.4}");
    assert!(
        out_rms < in_rms * 0.5,
        "消人声未衰减相关信号: in={in_rms} out={out_rms}"
    );
}
