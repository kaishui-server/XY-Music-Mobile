# baka-av3a-core

Pure Rust AV3A audio decoding to interleaved multichannel `f32` PCM.
Requires Rust 1.100.0. No external runtime dependencies, native decoder FFI or decoder subprocesses.

```rust,no_run
use std::{error::Error, sync::Arc};
use baka_av3a_core::{decoder::Decoder, model::HyperModel, shaping::LsfCodebooks};

fn decode(packet: &[u8]) -> Result<(), Box<dyn Error>> {
    let model = Arc::new(HyperModel::parse(&std::fs::read("MODEL.bin")?)?);
    let lsf = Arc::new(LsfCodebooks::parse(&std::fs::read("LSF.bin")?)?);
    let mut decoder = Decoder::new(model, lsf);
    let pcm = decoder.decode(packet)?;
    assert_eq!(pcm.samples.len(), 1024 * usize::from(pcm.channels));
    Ok(())
}
```

For playback, load/share immutable assets once and keep a decoder per stream across packets.
Each packet outputs 1,024 samples per channel. `PcmFrame` includes rate, channel count
and metadata. Float headroom is retained; `to_i16()` rounds and saturates. CRC or payload
errors do not commit decoder state. Configuration changes require explicit reset.

Model/LSF assets are required and are not bundled. MCR stereo and reduced-transport
third-order HOA require additional caller-provided codebooks/basis. Objects and HOA
produce transport channels/components, not automatically rendered speaker output.
Optional `render` APIs are separate from decoding.

GDN/IGDN inference reuses per-line input squares while retaining the original
floating-point accumulation order. See [normalization measurements and validation
limits](../../PERFORMANCE.md) for host results and reproducible checks.

Release 0.1.2 also reuses bounded short-window IMDCT workspace, eliminating
its 24 temporary allocations per channel/frame. This does not make the whole
decoder allocation-free.

[Documentation and asset formats](https://github.com/Zencok/baka-av3a)
· [Chinese documentation](https://github.com/Zencok/baka-av3a/blob/main/README.zh-CN.md)

GPL-3.0-or-later; see LICENSE and NOTICE. The license does not grant rights to external assets.
