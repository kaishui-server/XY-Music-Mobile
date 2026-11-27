# Changelog

## 0.2.2 - 2026-11-24

- Precompute the decorrelator's fixed 15-band mapping in a 64-byte table,
  eliminating 128 repeated binary searches per time slot.
- Preserve filter, ducking and float accumulation behavior without new state
  or runtime allocations.
- Add stateful bitwise comparisons against the original mapping and an opt-in
  host benchmark. No public API or stream/layout support changes.
- Keep core and CLI versions aligned. See PERFORMANCE.md for validation limits.

## 0.2.1 — 2026-11-24

- Reuse speaker geometry and contiguous probe buffers in A-JOC spread panning,
  reducing temporary allocations and repeated neighbor searches.
- Preserve gain bits, speaker order, ramps and supported stream/layout behavior.
- Add original-algorithm comparisons, allocation regressions and an opt-in host
  benchmark. See PERFORMANCE.md for measurements and validation limits.
- Keep core and CLI package versions aligned; no public API changes.

## 0.2.0 - 2026-11-22

- Add opt-in A-JOC object reconstruction for tested 448/1500 kbit/s streams:
  dry/wet matrices, differential/dequantized parameters, decorrelation/ducking,
  cross-frame ramps and independent object QMF synthesis.
- Resolve OAMD object gain, position, timing and shared screen/trim controls.
- Add an explicit basic stereo preview and spatial speaker rendering to stereo,
  5.1, 7.1, 5.1.4 and 7.1.4 with size/divergence, zones, snap and trim.
- Expose speaker rendering through `set_ajoc_render(...)` and CLI `--render=...`;
  identify raw core signals, reconstructed objects, preview and speaker feeds
  separately through `AudioKind` and speaker masks.
- Validate 79 automated tests and both complete A-JOC tiers in all five speaker
  layouts. Preserve ordinary decoding baselines and earlier object/preview PCM.

- Remove redundant Cargo homepage metadata so strict regression checks stay
  warning-free on the pinned toolchain.

- Preserve multichannel speaker masks and PCM/float subtypes in extensible WAV;
  reject format changes, non-finite samples, empty output and RIFF overflow.

- Reset all per-stream DSP/TOC histories on `flush()` and core-mode changes;
  replay after reset matches a fresh decoder bit for bit.

- Add explicit A-JOC core-signal decoding for tested 448/1500 kbit/s streams,
  indexed audio substream selection, variable channel elements and bounded reads.
- Report `AudioKind` and preserve zero speaker masks for unanchored signals.

- Reject truncated MP4 sample payloads, incomplete sample mappings and oversized
  table counts before decoding; CLI commands report an error instead of panicking.
- Handle extended-size MP4 boxes and correctly recover track timescale/duration.

Binaural rendering, native-reference PCM parity and additional A-JOC assignments
remain outside the validated profile. Default decoding still requires an explicit
A-JOC output mode. See `docs/AC4_DELIVERY.md` for detailed support boundaries.

## 0.1.0

- Initial Rust AC-4 decoder and file-conversion CLI.
- Planar f32 output, frame metadata and reusable PCM buffers.
- Channel-coded audio, ASF/SSF frontends, QMF, SAP, companding and A-SPX processing.
- MP4/M4A and raw AC-4 input; s16/f32 WAV output, JSON inspection and benchmarks.
- Reusable FFT workspaces, shared immutable tables and long-code VLC lookup improvements.
- Embedded regression fixtures, robustness tests and transform-allocation checks.

Object-coded audio is unsupported. ACPL successful decoding and additional stream layouts require further validation.
