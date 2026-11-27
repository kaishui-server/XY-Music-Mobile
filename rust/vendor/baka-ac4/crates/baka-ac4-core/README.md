# baka-ac4-core

Pure Rust AC-4 decoding and A-JOC speaker rendering. Compressed packets in, planar `f32` PCM out.

## Usage

```toml
[dependencies]
baka-ac4-core = "0.2"
```

```rust
use baka_ac4_core::{Ac4Decoder, Result};
use baka_ac4_core::ajoc::render::{RenderOptions, SpeakerLayout};

pub fn decode_packets(packets: &[Vec<u8>]) -> Result<()> {
    let mut decoder = Ac4Decoder::new()?;
    decoder.set_ajoc_render(Some(RenderOptions::new(SpeakerLayout::Stereo)))?;
    let mut pcm = Vec::new();
    for packet in packets {
        if let Some(frame) = decoder.decode_frame_into(packet, &mut pcm)? {
            println!("{} Hz, {} channels", frame.sample_rate, pcm.len());
            // Consume pcm[channel][sample] before the next decode call.
        }
    }
    Ok(())
}
```

Channel-coded streams retain their original layout. A-JOC requires an explicit output mode. `Ok(None)` means the decoder is waiting for an independently decodable frame. Packets may include an AC-4 sync header.

## Choose an output

| Configuration | `AudioKind` | Output |
| --- | --- | --- |
| Default | `Channels` | Channel-coded audio |
| `set_ajoc_render(Some(options))` | `AjocSpeakerFeeds` | Rendered speaker feeds |
| `set_ajoc_object_signals(true)` | `AjocObjectSignals` | Object PCM, LFE first when present |
| `set_ajoc_core_signals(true)` | `AjocCoreSignals` | Core downmix PCM |
| `set_ajoc_stereo_preview(true)` | `AjocStereoPreview` | Basic gain/left-right projection |

For playback, use `set_ajoc_render` with `SpeakerLayout::Stereo`, `Surround51`, `Surround71`, `Surround514` or `Surround714`. `RenderOptions::screen` configures playback screen geometry; defaults preserve coordinates. The renderer applies position, size, divergence, screen mapping, zone/elevation restrictions, snap, trim and timed gain updates.

Speaker feeds use ascending WAVE mask-bit order. Stereo folds LFE equally at 0.5 per side; surround layouts use a discrete LFE channel. No limiter, loudness normalization or bass management is applied. Float samples can exceed unity.

Use core and object signals for custom processing. A zero speaker mask means no speaker assignment; do not infer a surround layout from the plane count. Core output retains an explicit speaker assignment when present. Object output has a zero mask and does not apply object gains or spatial rendering. The basic stereo preview applies gain and X position only; use speaker rendering for the full supported spatial controls.

Disabling an active renderer or preview retains raw object output. Selecting raw object output disables rendering and preview. Disabling object mode retains core/metadata mode; disabling metadata or core mode also disables object output and rendering.

## Metadata and custom processing

`FrameInfo` provides `audio_kind`, `sample_rate`, `channel_mask`, `nb_samples` and `key_frame`.

Call `set_ajoc_metadata(true)` to enable A-JOC metadata with core PCM output, then read `ajoc_metadata()` after each successful frame. Object and rendering modes enable this automatically. Metadata includes reconstruction matrices, object properties, sample-timed updates and shared screen/trim controls. Metadata is cleared on flush, errors or frames without A-JOC output. Disabling metadata retains core output.

For custom DSP, `ajoc::reconstruction::Reconstructor` accepts a decorrelation backend; `ajoc::decorrelation::AjocDecorrelation` supplies the built-in implementation. `copy_ajoc_core_qmf` exposes fullband QMF planes from the last decoded A-JOC metadata frame and requires full QMF processing. `ajoc::render::SpeakerRenderer` renders object PCM independently of the decoder. Reset standalone processors when starting a new stream or changing signal layout.

## Playback lifecycle

- Configure output before submitting packets. Repeating identical rendering options preserves history; changing options resets decoding history. Invalid options leave the current configuration intact.
- Reuse the PCM buffers and consume samples before the next decode call.
- For seeking, decode from a suitable independently decodable frame and discard pre-roll. `flush()` clears all stream history while preserving transform plans and output options.
- Call `flush()` on the control path because it allocates fresh history. Object processing and rendering also allocate storage; keep them outside an allocation-free audio callback.

The host owns demuxing, timestamps, source access and playback devices. This library does not provide networking or DRM decryption.

Release 0.2.2 resolves the decorrelator's fixed 15-band mapping at compile
time, preserving filter, ducking and PCM arithmetic. See [host measurements and
validation limits](../../PERFORMANCE.md).

## Supported scope

Supports channel-coded AC-4 with TOC v1/v2, ASF/SSF and A-SPX, and dynamic-only A-JOC 448/1500 kbit/s with a non-alternative presentation. ACPL support is limited.

Object reconstruction/rendering does not support bed/mixed assignments, zone codes 6/7 or reserved rendering codes. HRTF headphone rendering, dialogue enhancement and presentation loudness processing are not provided. Distance, Y-warp and balance extensions remain available as metadata without affecting rendering.

[Project and CLI](https://github.com/Zencok/baka-ac4) · [简体中文](https://github.com/Zencok/baka-ac4/blob/main/README.zh-CN.md)

GPL-3.0-or-later. See `LICENSE` and `NOTICE`.
