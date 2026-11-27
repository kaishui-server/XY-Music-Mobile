# Neural normalization performance

## 2026-11-24: reuse input squares per spectral line

GDN/IGDN normalization previously copied the entire layer output and recomputed
each input square for every output channel. It now gathers input squares for
one spectral line before modifying that line. All output channels reuse this
contiguous scratch buffer. Other lines remain untouched until their turn.
The multiplication rounding, four independent dot-product lanes, tail sum,
beta addition, square root, division/multiplication and validation order are
unchanged. No model, codebook, transform, decoder mode, output mapping or public
API change is involved.

Scratch storage falls from `channels * lines * 4` bytes to `channels * 4` bytes.
The input-square count falls from `lines * channels * channels` to
`lines * channels`. The weighted dot products remain quadratic in channel count;
this is not a complete inference or allocation-free decoder optimization.

## Host timing

Windows, Rust 1.100.0, release profile with thin LTO and one codegen unit.
The manual benchmark compares production activation with a frozen original
implementation in the same executable. Each sample restores input and applies
IGDN 100 times; three warmups precede seven samples in alternating measurement
order. Scratch allocation and input restoration are included. Model construction
is outside the timer. No elapsed-time threshold is asserted.

| Channels / lines | Original median | Optimized median | Scratch before / after |
| --- | ---: | ---: | ---: |
| 16 / 64 | 1.678 ms | 1.243 ms | 4096 / 64 bytes |
| 32 / 128 | 10.134 ms | 8.051 ms | 16384 / 128 bytes |
| 64 / 256 | 93.295 ms | 58.852 ms | 65536 / 256 bytes |

The measured normalization step takes roughly 21–37% less time in these fixtures.
This does not measure end-to-end decoding, rendering, playback, battery use or
physical-device performance. Reproduce with:

```powershell
cargo test -p baka-av3a-core --release --lib normalization_measurement -- --ignored --nocapture
```

## Validation

- `cargo fmt --all -- --check`, `cargo check --workspace` and
  `cargo clippy --workspace --all-targets -- -D warnings`: passed.
- `cargo test --workspace`: 190 passed, 34 ignored. New tests compare GDN and
  IGDN output bits against the original implementation across channel counts
  that exercise all accumulation lanes and tails, several line counts, signed
  zero, subnormal values, normalization overflow, NaNs, infinities and invalid
  norms. Result errors and partially written output buffers also match.
- Local release mode matrices: all six existing `local_` tests passed with
  caller-supplied model, LSF, MCR and HOA assets. Channel beds, mixed/object
  transport, HOA, static metadata and dynamic metadata cover 4,288 decoded frames
  and 35,717,120 exact signed-16 PCM samples against the existing independent
  records. These tests also exercise CRC failures, retained metadata and reset.
  The MCR spectral test covers 768 vectors / 1,572,864 exact float32 values.
  Those assets, media and independent records remain under ignored `.local/`.

The mode matrices verify signed-16 PCM equivalence; they do not claim every
real-stream float32 PCM sample is bit-identical. The new normalization-specific
fixtures do compare float32 bits directly. No new Android/Apple build, installed
application update, or device listening/performance validation was performed.

Release 0.1.1 includes this optimization. The BakaMusicFlutter application can
consume the published core and container 0.1.1 packages without a Git dependency.
Publication does not update an installed application; rebuilding remains required.

## 2026-11-24: short-window IMDCT workspace

Source after release 0.1.1 uses caller-owned scratch for the eight 128-line
transforms in `Synthesis::process(..., 1)`. Two 64-float FFT arrays and one
256-float time array occupy 1.5 KiB on the stack and are reused for every block.
Every element is overwritten before reuse. The multiply/add order, windows,
overlap commit and error checks are unchanged. No extra state is cloned for
decoder checkpoints. Long-window and forward-transform allocation behavior is
unchanged; this is not a claim of allocation-free packet decoding.

Windows x86-64, Rust 1.100.0, release build: a local thread-scoped counting
allocator measured 24 allocations before and zero after for one short-window
process call, excluding initialization. The allocator harness remains ignored
under `.local/`; the committed workspace continues to forbid unsafe code.
A seven-round host microbenchmark (2,000 short frames per round) measured a
24.188 ms median before and 17.107 ms after. This single-host measurement does
not establish whole-decoder throughput, Android performance or battery savings.
Reproduce current timing with:

```powershell
cargo test --locked -p baka-av3a-core --release --test synthesis_workspace short_window_measurement -- --ignored --nocapture
```

The PCM regression records the pre-change `e4cf76c` output hash for 128 frames
(131,072 float32 samples), exercising long/start/short/stop transitions, signed
zero and subnormal inputs. Separate checks reject NaN, infinity and finite
overflow without corrupting the next short frame, and compare reset output
bits against a fresh synthesis instance. Existing local mode matrices retain
the independent signed-16 PCM and MCR references described above.

Final validation: workspace fmt/check and strict all-target Clippy passed;
workspace tests passed 192 tests with 35 optional/manual tests ignored. All six
local release mode-matrix tests passed against the existing independent records.

Release 0.1.2 includes this change. Applications must update their locked
dependencies and rebuild to use it. Publication does not imply an installed
application update or new device verification.
