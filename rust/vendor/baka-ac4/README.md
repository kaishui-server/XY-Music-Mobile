<div align="center">

# baka-ac4

**AC-4 audio decoding and A-JOC speaker rendering in pure Rust.**

[![Rust](https://img.shields.io/badge/Rust-2024-DEA584?logo=rust&logoColor=white)](Cargo.toml)
[![License](https://img.shields.io/badge/License-GPL--3.0--or--later-blue)](LICENSE)

**English** · [简体中文](README.zh-CN.md)

[Quick start](#quick-start) · [Rust API](#rust-api) · [Output modes](#output-modes) · [Integration](#integration)

</div>

`baka-ac4` provides a reusable decoder library and a CLI for converting MP4, M4A and raw AC-4 files to WAV. The decoder runs entirely in Rust, without a C decoder dependency.

Requires Rust **1.100.0**, pinned in `rust-toolchain.toml`.

## Quick start

```sh
cargo install baka-ac4-cli --version 0.2.2 --locked

# Convert channel-coded AC-4 to WAV
baka-ac4 decode input.mp4 output.wav

# Render A-JOC audio to stereo float PCM
baka-ac4 decode --render=stereo --f32 input.mp4 stereo.wav

# Render A-JOC audio to 7.1.4 speaker feeds
baka-ac4 decode --render=7.1.4 --f32 input.mp4 surround.wav

# Inspect frame metadata or benchmark decoding
baka-ac4 toc --render=stereo input.mp4
baka-ac4 bench --render=stereo input.mp4 10
```

MP4/M4A input must contain an AC-4 track. Choose an explicit output mode for A-JOC audio; use `--render=stereo` for two-channel listening output. Output is 16-bit PCM by default. Use `--f32` to preserve floating-point samples, including peaks above unity.

## Rust API

```toml
[dependencies]
baka-ac4-core = "0.2"
```

```rust
use baka_ac4_core::{Ac4Decoder, Result};
use baka_ac4_core::ajoc::render::{RenderOptions, SpeakerLayout};

pub fn decode_packets(packets: &[Vec<u8>]) -> Result<()> {
    let mut decoder = Ac4Decoder::new()?;
    // Enable A-JOC stereo rendering. Channel-coded streams keep their layout.
    decoder.set_ajoc_render(Some(RenderOptions::new(SpeakerLayout::Stereo)))?;
    let mut pcm = Vec::new();

    for packet in packets {
        if let Some(frame) = decoder.decode_frame_into(packet, &mut pcm)? {
            // pcm[channel][sample]: consume samples before the next decode.
            println!("{} Hz, {} channels", frame.sample_rate, pcm.len());
        }
    }
    Ok(())
}
```

Packets may include an AC-4 sync header. `Ok(None)` means the decoder is waiting for an independently decodable frame. Frame metadata includes `audio_kind`, `sample_rate`, `channel_mask`, `nb_samples` and `key_frame`.

## Output modes

| Output | Rust configuration | CLI option |
| --- | --- | --- |
| Channel-coded PCM | Default | No additional option |
| A-JOC speaker feeds | `set_ajoc_render(Some(options))` | `--render=stereo`, `--render=5.1`, `--render=7.1`, `--render=5.1.4` or `--render=7.1.4` |
| Reconstructed object signals | `set_ajoc_object_signals(true)` | `--object-signals` |
| Core downmix signals | `set_ajoc_core_signals(true)` | `--core-signals` |
| Basic gain/left-right projection | `set_ajoc_stereo_preview(true)` | `--stereo-preview` |

For A-JOC playback, prefer speaker rendering. It applies three-dimensional panning, object size and divergence, screen mapping, zone/elevation restrictions, snap, trim and timed gain updates. Stereo mixes LFE equally at 0.5 per side; surround layouts retain a discrete LFE channel.

Object and core outputs are intended for custom audio processing. A zero speaker mask means the planes have no assigned speaker layout. Core output retains a speaker assignment when one is present. Object output has a zero mask, places LFE first when present and does not apply object gain or spatial rendering. The basic stereo preview applies gain and left/right position only.

Select one A-JOC mode at a time. Rendering, object reconstruction and preview require full QMF processing and cannot be combined with `--fast`. The `--fast` option is a channel-decoding shortcut that changes the output.

Speaker feeds use ascending WAVE speaker-mask order. Multichannel WAV uses WAVE_FORMAT_EXTENSIBLE. No output limiter or loudness normalization is applied.

### Supported scope

- Channel-coded AC-4 with TOC v1/v2, ASF/SSF and A-SPX processing.
- A-JOC 448/1500 kbit/s with dynamic-only object assignments and a non-alternative presentation.
- Speaker output to stereo, 5.1, 7.1, 5.1.4 and 7.1.4.

Object reconstruction/rendering does not support bed/mixed A-JOC assignments, zone codes 6/7 or reserved rendering codes. ACPL support is limited. The library does not provide HRTF headphone rendering, bass management, dialogue enhancement or presentation loudness processing. Distance, Y-warp and balance extensions are available as metadata but do not affect rendering.

## Integration

The host application owns demuxing, timestamps, playback devices and source access. The core accepts compressed packets and returns planar `f32` PCM; it does not provide networking or DRM decryption. The CLI loads the input file into memory and is intended for conversion and inspection.

Decoding is stateful. To seek, start at a suitable independently decodable frame and discard pre-roll before the target. `flush()` clears stream history while preserving transform plans and output options. Call it on the playback control path because it allocates fresh history.

Changing A-JOC rendering options resets decoding history. Reapplying identical options preserves it. Configure the output before feeding packets, and reuse the PCM buffers between calls.

See the [core API guide](crates/baka-ac4-core/README.md) and [CLI guide](crates/baka-ac4-cli/README.md).

## Development

```sh
cargo build --release --locked
cargo test --release --locked
cargo clippy --release --all-targets --locked -- -D warnings
```

Use release builds for playback and performance measurements.

## License

[GPL-3.0-or-later](LICENSE). Third-party notices are included in [NOTICE](NOTICE).
