# AC-4 A-JOC spread panner optimization

## Scope

This change optimizes the dynamic-object speaker renderer imported from the
local `baka-ac4` repository. It does not change supported stream types, speaker
layouts, channel masks, downmix policy, PCM precision, loudness or decoder
selection. The upstream revision and imported file hashes are recorded in
`rust/crates/baka-ac4-core/UPSTREAM.json`.

For an object with spatial width, the original spread panner probes each axis
at 48 interior positions and six boundaries. Each probe searches the same
speaker geometry and allocates a gain vector. The optimized implementation
prepares each axis's neighbor table once and stores its probe gains in one
contiguous buffer. The weighted reduction reads those buffers in the original
order. Multiplication, exponentiation, probe, speaker, summation and normalization
order remain unchanged. The point-source and divergence paths are unchanged.

The 54 temporary probe vectors become three neighbor tables and three contiguous
gain buffers, reducing that part by 48 allocations per spread target. This is not
an allocation-free renderer: targets, geometry and other gain vectors still
allocate. A deterministic allocation upper bound guards against reintroducing
per-probe arrays. The final warmed single-object 7.1.4 fixture records 24
allocations per metadata update.

## Host measurements

Windows, Rust 1.100.0, upstream release profile (thin LTO, one codegen unit).
The manual benchmark compares the frozen original implementation with production
in one executable. Each sample evaluates 1,000 moving object targets; three
warmups precede seven samples with alternating measurement order.

| Layout | Width | Original median | Optimized median |
| --- | --- | ---: | ---: |
| Stereo | 0.2 on all axes | 4.734 ms | 3.798 ms |
| 5.1 | 0.2 on all axes | 8.324 ms | 6.246 ms |
| 7.1 | 0.2 on all axes | 11.523 ms | 8.069 ms |
| 5.1.4 | 0.2 on all axes | 14.558 ms | 10.221 ms |
| 7.1.4 | 0.2 on all axes | 17.829 ms | 12.166 ms |
| 7.1.4 | 0.73 / 0.21 / 0.49 | 17.776 ms | 12.141 ms |

These are panner-only host timings, not full decoder or device speedups. Point
targets retain the original path (7.1.4: 0.617 / 0.599 ms for 1,000 calls).
No timing threshold is asserted. Reproduce from the upstream checkout with:

```powershell
cargo test -p baka-ac4-core --release --lib spread_preparation_measurement -- --ignored --nocapture
```

## Equivalence and limitations

A frozen test-only copy of the prior panner compares `f64` gain bits across all
five layouts, all zone masks, both elevation settings, representative positions,
spread scale boundaries and divergence values. A separate axis test compares
speaker coordinates and positions immediately beside them. The unit point-source
and divergent-source algorithms remain unchanged. Tests retain gain energy,
speaker ordering, ramp history and invalid-input coverage.

No installed application library, APK or device session is changed by the source
update. Rebuilding the native library is required. Host gain equivalence and
timings do not establish perceptual correctness, real-time device speed, power
consumption, physical twelve-channel output or headphone spatial rendering.

Validation of the final upstream implementation: `cargo test -p baka-ac4-core
--release` passed 71 tests with one manual benchmark ignored, including the
default 20,000-iteration-per-phase robustness test. `cargo clippy -p
baka-ac4-core --lib --tests -- -D warnings` passed without warnings.

## 2026-11-24: fixed decorrelation parameter-band map

Source after release 0.2.1 replaces 128 binary searches per decorrelator time
slot with a compile-time 64-byte table. The table and the generic mapper share
the same 15 parameter-band boundaries. Other band counts, public mapper errors,
allpass filters, transient ducking, accumulation order and reset behavior are
unchanged. No stream state, allocation or runtime initialization is added.

A reference test retains the original search-based processing. All 64 table
entries match the generic mapper. For each of D0/D1/D2, 512 successive slots
of impulses, silence, signed zero and varying complex inputs produce identical
float32 output bits, including filter/ducker history across ring wraparound.
Existing seven-instance independence and invalid-input/reset tests also pass.

Windows x86-64, Rust 1.100.0 release host timing: seven alternating rounds of
4,096 slots measured a median of 4.130 ms for the original searches and 3.456 ms
for table lookup (about 16% less time for this decorrelation microbenchmark).
The measured region includes allpass filtering and ducking, excludes state
construction, and asserts no timing threshold. It does not measure whole-decoder
throughput, device playback or battery savings. Reproduce with:

```powershell
cargo test --locked -p baka-ac4-core --release --lib fixed_band_map_measurement -- --ignored --nocapture
```

Validation: workspace fmt/check, strict all-target Clippy, and 83 workspace
release tests passed (six optional/manual tests ignored). The manual benchmark
and its bitwise reference test passed separately. Release 0.2.2 includes this
optimization. Applications must update their locked dependency and rebuild;
publication does not establish a new APK or device acceptance.
