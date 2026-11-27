# baka-av3a-cli

Command-line AV3A inspection, extraction and signed 16-bit PCM WAV decoding in pure Rust.
Requires Rust 1.100.0.

```sh
cargo install baka-av3a-cli --version 0.1.2 --locked
baka-av3a inspect input.mp4
baka-av3a decode input.mp4 output.wav MODEL.bin LSF.bin
```

Model weights and LSF codebooks are required and **not bundled**. Some modes also require
MCR/HOA assets supplied after the LSF argument. Use compatible assets you are entitled to use.

```sh
baka-av3a inspect-payload input.mp4
baka-av3a extract input.mp4 output.av3a
baka-av3a inspect-es output.av3a
baka-av3a decode input.mp4 output.wav MODEL.bin LSF.bin [MCR.bin] [HOA.bin]
```

WAV export preserves decoded channels, refuses to overwrite existing files and does not
automatically downmix or apply spatial effects. It does not trim decoder delay or add a
synthetic tail. Later decoding/I/O failure may leave a partial output file.
Inspection commands do not reconstruct PCM; JSON flags describe the checks performed.
The CLI reads the bounded complete input file; streaming playback uses the library APIs instead.

[Documentation and asset formats](https://github.com/Zencok/baka-av3a)
· [Chinese documentation](https://github.com/Zencok/baka-av3a/blob/main/README.zh-CN.md)

GPL-3.0-or-later; see LICENSE and NOTICE.
