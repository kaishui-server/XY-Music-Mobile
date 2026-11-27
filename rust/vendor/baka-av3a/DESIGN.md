# Architecture

The primary pipeline is compressed AV3A packets → interleaved multichannel PCM.
Spatial processing is optional and does not run implicitly during decoding.

## Components

| Crate | Responsibility |
|---|---|
| `baka-av3a-core` | Framing, CRC, entropy/model inference, spectral reconstruction, synthesis, metadata and owned PCM |
| `baka-av3a-container` | Bounded MP4 extraction, fragment indexing, progressive delivery, Range scheduling and seek replay |
| `baka-av3a-cli` | Offline inspection, elementary-stream extraction and signed 16-bit WAV export |

All runtime code is Rust 2024, requires Rust 1.100.0 and forbids unsafe code.
The workspace has no external runtime crate dependencies.

## Assets and stream state

`HyperModel`, `LsfCodebooks`, optional `McrCodebooks` and `HoaBasis` are immutable,
caller-supplied assets that can be shared using `Arc`. They are not bundled.
`Decoder` owns noise, overlap/synthesis, metadata and configuration history for one stream.
Reset explicitly at a new stream boundary. Missing required assets and unsupported
configuration changes are errors, not requests to silently substitute another format.
See [asset requirements](docs/assets.md).

`PcmFrame` carries sample rate, channel count, interleaved float samples and frame metadata.
Metadata accessors retain the most recent successful static/dynamic blocks; absent optional
fields are not automatically merged into earlier metadata objects.
Invalid packets do not commit decoder history. PCM is not automatically downmixed,
normalized for a device, spatially rendered or scheduled for playback.

## Input and timing

`Track` borrows a complete bounded MP4 buffer. Progressive decoding accepts sequential
chunks and releases consumed audio data. Sparse Range playback asks the caller for
specific byte ranges, validates responses and retains bounded cache/history state.
Network I/O, authentication, URL refresh, retries and audio-device management remain external.

Container timestamps are media times. Nontrivial edit-list presentation mapping is unsupported.
Seek rebuilds codec history by replay; it is not constant-time random-access decoding.
Pending seeks use separate state and can be cancelled without replacing committed playback.
Do not deliver stale requests to a new Range generation.

## Input boundaries

Treat compressed media, metadata and assets as untrusted input. Parsers check lengths,
integer bounds, finite numeric values and configuration limits before committing state.
CRC checks detect malformed packets; they do not authenticate content.
The container enforces a 512 MiB file limit, up to 2,000,000 indexed samples and bounded
metadata boxes. Sparse playback defaults to 64 KiB merged requests and caps batches at 1 MiB.
The model parser limits asset size and tensor/workspace dimensions; see the public parser APIs.

The CLI requires a new output path. It validates track headers, all packet CRCs and the
first decoded packet before creating a WAV, but later payload or I/O failures can leave a
partial output file. The caller may remove such a file before retrying.

## Scheduling and optional processing

Run decoding away from the device's hard real-time callback and buffer PCM according to
your player's latency requirements. Current APIs allocate owned frames and working state;
they do not promise callback-time zero allocation. Measure asset initialization, first
packet decoding, steady decoding, network startup and device output separately.

Short-window synthesis reuses 1.5 KiB of local stack workspace across its eight
IMDCT blocks, avoiding 24 heap allocations per channel/frame. Workspace is not
stored in `Synthesis`, so checkpoint size, clone behavior and committed overlap
history are unchanged. Long-window and forward transforms retain owned buffers.

Optional `render` APIs operate on PCM and explicit configurations. They do not add a
requirement to use room acoustics, measured HRIR data or head tracking in ordinary playback.
See [optional spatial processing](docs/spatial-rendering.md) for their boundary.
