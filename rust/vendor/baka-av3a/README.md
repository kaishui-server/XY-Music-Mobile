# baka-av3a

**AV3A audio decoding in pure Rust.**

[English](README.md) · [简体中文](README.zh-CN.md)

`baka-av3a` turns compressed AV3A packets into interleaved multichannel `f32` PCM.
It also provides MP4 demuxing, progressive input, range-based playback and a CLI.
The runtime has no third-party crate dependencies, native decoder FFI or decoder subprocesses.
Requires **Rust 1.100.0**, edition 2024.

## Quick start

```sh
cargo install baka-av3a-cli --version 0.1.2 --locked
baka-av3a inspect input.mp4
baka-av3a decode input.mp4 output.wav MODEL.bin LSF.bin
```

Model weights and external codebooks are **not bundled**. Obtain compatible assets
you are entitled to use; see [asset requirements](docs/assets.md).
The CLI writes interleaved signed 16-bit PCM WAV and refuses to overwrite existing files.
It preserves decoded channels and does not automatically downmix or apply spatial effects.
The CLI reads the bounded input file into memory; use the library's progressive or Range APIs for playback.

From a source checkout:

```sh
cargo run --release -p baka-av3a-cli -- inspect input.mp4
cargo run --release -p baka-av3a-cli -- decode input.mp4 output.wav MODEL.bin LSF.bin
```

## Rust API

```toml
[dependencies]
baka-av3a-core = "0.1.2"
baka-av3a-container = "0.1.2" # optional MP4 support
```

```rust,no_run
use std::{error::Error, sync::Arc};
use baka_av3a_core::{decoder::Decoder, model::HyperModel, shaping::LsfCodebooks};
use baka_av3a_container::Track;

fn main() -> Result<(), Box<dyn Error>> {
    let model = Arc::new(HyperModel::parse(&std::fs::read("MODEL.bin")?)?);
    let lsf = Arc::new(LsfCodebooks::parse(&std::fs::read("LSF.bin")?)?);
    let mut decoder = Decoder::new(model, lsf);
    let bytes = std::fs::read("input.mp4")?;
    let track = Track::parse(&bytes)?;
    for packet in track.packets() {
        let pcm = decoder.decode(packet.bytes)?;
        // pcm.samples: interleaved f32; pcm.sample_rate and pcm.channels describe the block.
        // Pass PCM to your audio pipeline, or use pcm.to_i16() for rounded, saturated i16.
        let _ = pcm;
    }
    Ok(())
}
```

Parse immutable assets once and share them through `Arc`. Keep one `Decoder` per stream.
Each decoded packet produces 1,024 samples per output channel. Float PCM retains
headroom; integer conversion rounds using `floor(x + 0.5)` and saturates.
Invalid packets do not commit decoder state. Configuration changes require an explicit `reset()`.

## Support

| Area | Support and boundaries |
|---|---|
| PCM decoding | Mono, stereo, multichannel beds, object-only and mixed bed/object transport; main and LC paths |
| Low-rate stereo | MCR modes require an additional external MCR codebook |
| HOA | Orders 1–3; reduced-transport third-order configurations require an external basis asset |
| Metadata | Static and dynamic metadata accompany PCM; parsing does not imply automatic effect processing |
| MP4 | Regular and fragmented MP4; sequential progressive input and sparse Range reads |
| Seek | Media-time positioning with history replay, preroll, PCM trimming and seek cancellation |
| Validation | CRC, input bounds, truncation, track ambiguity and unsupported configuration checks |
| Timing | Media timestamps; MP4 edit-list presentation-time mapping is not implemented |

Object streams expose decoded transport channels; HOA streams expose HOA components.
These outputs are not automatically mapped to physical speakers.
The application owns downmixing, device output, HTTP/TLS, retries and its playback lifecycle.
WAV export does not trim decoder delay or append a synthetic codec tail.
Format support is limited to the implemented configurations; this is not a conformance claim for every AV3A stream.

## Streaming integration

| API | Purpose |
|---|---|
| `core::stream::ElementaryDecoder` | Incremental raw AV3A packet input |
| `container::progressive::Mp4Decoder` | Sequential MP4 chunks to PCM before download completion |
| `container::range::RangeProbe` | Build a bounded sparse track index, including trailing `moov` |
| `container::range::HttpRangeSession` | Validate HTTP Range response metadata |
| `container::range::playback::RangeDecoder` | Request audio ranges, decode and perform cancellable seek replay |

`core::` and `container::` above abbreviate the corresponding crate names.
Feed input and decode on a worker appropriate to your player; the APIs return owned PCM
and allocate working buffers. They do not promise an allocation-free audio callback.
First PCM availability is separate from network buffering and audible device startup.
See [architecture and integration boundaries](DESIGN.md).

[Optional spatial processing](docs/spatial-rendering.md) is separate from the direct decoder path.
Multichannel decoding does not require room geometry, HRIR datasets or head tracking.

## CLI commands

```sh
baka-av3a inspect input.mp4
baka-av3a inspect-payload input.mp4
baka-av3a extract input.mp4 output.av3a
baka-av3a inspect-es output.av3a
baka-av3a decode input.mp4 output.wav MODEL.bin LSF.bin [MCR.bin] [HOA.bin]
```

Inspection does not reconstruct PCM. Check the JSON `pcm_decode` and `crc_verified`
fields for what a command actually verified. Optional MCR/HOA arguments are recognized
by their file magic and may be supplied in either order.

## Development

```sh
cargo fmt --all --check
cargo check --all-targets
cargo test --all-targets
cargo clippy --all-targets --all-features -- -D warnings
cargo doc --workspace --no-deps
```

Default tests use synthetic fixtures. Tests marked ignored require externally supplied
assets or media and do not run in the default test suite.
Performance examples must be built with `--release`; their local-file measurements
do not include HTTP or device playback latency.

## License

[GPL-3.0-or-later](LICENSE). See [NOTICE](NOTICE) for the distribution boundary.
