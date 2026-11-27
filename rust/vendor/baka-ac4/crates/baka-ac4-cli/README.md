# baka-ac4-cli

Convert AC-4 files to WAV, inspect frame metadata and measure decoding performance. The executable is named **`baka-ac4`**.

## Install

```sh
cargo install baka-ac4-cli --version 0.2.2 --locked
```

Requires Rust 1.100.0.

## Convert audio

```sh
# Channel-coded AC-4
baka-ac4 decode input.mp4 output.wav

# A-JOC to stereo
baka-ac4 decode --render=stereo --f32 input.mp4 stereo.wav

# A-JOC to surround speaker feeds
baka-ac4 decode --render=7.1.4 --f32 input.mp4 surround.wav
```

Input may be MP4/M4A containing an AC-4 track, or a raw `.ac4` stream. Output is 16-bit PCM WAV by default; `--f32` selects float32 WAV and preserves peaks above unity. Multichannel output includes the WAVE speaker mask.

A-JOC audio requires an explicit output mode:

| Option | Output |
| --- | --- |
| `--render=stereo` | Two-channel speaker rendering |
| `--render=5.1`, `--render=7.1` | Surround speaker rendering |
| `--render=5.1.4`, `--render=7.1.4` | Surround rendering with height channels |
| `--object-signals` | Object PCM without object gain/spatial rendering; LFE first when present |
| `--core-signals` | Core downmix signals |
| `--stereo-preview` | Basic gain and left-right projection |

Use `--render` for playback output. Core and object modes are intended for custom processing. Object output has a zero speaker mask; core output retains an explicit speaker assignment when present. A zero mask means no assigned layout. The preview applies gain and left/right position only. Choose one A-JOC mode at a time.

Speaker rendering applies three-dimensional panning, size/divergence, zones, snap, screen mapping, trim and timed gain updates. Stereo folds LFE equally at 0.5 per side; surround retains discrete LFE. Output has no limiter or loudness normalization.

The `decode --fast` option skips part of the QMF processing and changes the output. It cannot be combined with rendering, object reconstruction or preview.

## Inspect and benchmark

```sh
baka-ac4 toc --render=stereo input.mp4
baka-ac4 bench --render=stereo input.mp4 10
```

`toc` writes JSON containing per-frame output kind, speaker mask and coding-tool information. Use the same output mode as your decode command.

`bench` reports minimum and median decode time. The round count defaults to 10 and accepts `1..=10000`.

## Supported scope

A-JOC support covers 448/1500 kbit/s, dynamic-only object assignments and a non-alternative presentation. Bed/mixed assignments and unsupported rendering codes return errors. ACPL support is limited. HRTF headphone rendering, bass management, dialogue enhancement and presentation loudness processing are not provided.

The CLI loads the input into memory. It provides file conversion rather than streaming playback, and does not decrypt DRM. A change in output format requires a separate WAV file.

[Project and Rust API](https://github.com/Zencok/baka-ac4) · [简体中文](https://github.com/Zencok/baka-ac4/blob/main/README.zh-CN.md)

GPL-3.0-or-later. See `LICENSE` and `NOTICE`.
