# Changelog

## 0.1.2 - 2026-11-24

- Reuse 1.5 KiB of local workspace across the eight short-window IMDCT blocks,
  removing 24 temporary allocations per channel/frame.
- Preserve transform arithmetic, overlap history, checkpoint size and errors.
- Add pre-change PCM bit-pattern, transition, failure/reset regressions and an
  opt-in host benchmark. No API, model or codebook format changes.
- Keep core, container and CLI versions aligned. See PERFORMANCE.md for scope.

## 0.1.1 — 2026-11-24

- Reuse per-line input squares in GDN/IGDN inference while preserving float
  accumulation order and error behavior.
- Reduce normalization scratch storage from channels × lines to channels.
- Add bitwise normalization regressions and an opt-in host benchmark. Existing
  local mode matrices retain exact signed-16 PCM output.
- Keep core, container and CLI package versions aligned; no public API or model
  format changes. See PERFORMANCE.md for measurements and validation limits.

## 0.1.0

- Initial public release of the pure Rust AV3A core, MP4 container library and CLI.
- Multichannel PCM decoding, external model/codebook loading and static/dynamic metadata.
- Regular/fragmented MP4, progressive input, bounded Range playback and cancellable seek replay.
- Offline stream inspection, packet extraction and signed 16-bit WAV export.
- Separate optional spatial-processing APIs.

External model/codebook assets and media are not included. See the README for supported
configurations and integration boundaries.
