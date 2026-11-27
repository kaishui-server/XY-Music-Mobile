# baka-av3a-container

Bounded AV3A MP4 demuxing, progressive decoding and sparse Range playback in pure Rust.
Requires Rust 1.100.0. The only runtime dependency is `baka-av3a-core`.

```rust,no_run
use baka_av3a_container::Track;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let bytes = std::fs::read("input.mp4")?;
    let track = Track::parse(&bytes)?;
    for packet in track.packets() {
        // Feed packet.bytes into your stateful baka_av3a_core::decoder::Decoder.
        let _ = packet.bytes;
    }
    Ok(())
}
```

- `Track`: borrow packets from a complete regular or fragmented MP4 buffer.
- `progressive::Mp4Decoder`: feed sequential chunks and retrieve PCM without downloading the whole file.
- `range::RangeProbe`: build a sparse track index, including trailing `moov`.
- `range::HttpRangeSession`: validate Range response metadata; does not send HTTP requests.
- `range::playback::RangeDecoder`: request byte ranges, decode and perform cancellable seek replay.

PCM decoding requires externally supplied model/LSF assets and optional mode-specific
codebooks. Assets, HTTP/TLS transport and audio-device management are not bundled.
MP4 edit-list presentation mapping is unsupported; timestamps refer to media time.
Seek may replay earlier packets to rebuild codec history.

[Documentation and integration](https://github.com/Zencok/baka-av3a)
· [Chinese documentation](https://github.com/Zencok/baka-av3a/blob/main/README.zh-CN.md)

GPL-3.0-or-later; see LICENSE and NOTICE.
