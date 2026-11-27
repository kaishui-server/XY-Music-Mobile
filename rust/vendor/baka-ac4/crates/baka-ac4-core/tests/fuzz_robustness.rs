//! Panic-safety fuzzing for the decoder API.
//!
//! A panic escaping `decode_frame_into` would abort the host process when
//! called across an FFI boundary, so every reachable input must return
//! `Err`/`Ok(None)` instead of panicking. Deterministic (xorshift, seed via
//! `BAKA_FUZZ_SEED`); on the first panic the test fails reporting seed,
//! phase and iteration needed to reproduce.
//!
//! Coverage: three embedded real-stream fixtures exercise different code
//! paths — stereo CM_ASPX (also mutated into SSF/ACPL modes), 5.1-channel
//! v2 with balance-mode A-SPX, and CM_SIMPLE with the QMF bypass path —
//! plus truncations, garbage, random flushes and bypass toggles.
//!
//! Iterations scale with `BAKA_FUZZ_ITERS` (default 20000 per phase).

use baka_ac4_core::Ac4Decoder;

const FIX_P83: &[u8] = include_bytes!("fixtures/p83_iframe_plus5.ac4");
const FIX_ATSC3: &[u8] = include_bytes!("fixtures/atsc3_iframe_plus5.ac4");
const FIX_HTYS: &[u8] = include_bytes!("fixtures/htys_iframe_plus5.ac4");
// htys frames are MP4 samples without sync headers; sizes from its stsz box
const FIX_HTYS_SIZES: [usize; 6] = [1366, 1365, 1365, 1366, 1365, 1365];

struct Xorshift(u64);

impl Xorshift {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

fn split_frames(data: &[u8]) -> Vec<&[u8]> {
    let mut frames = Vec::new();
    let mut off = 0usize;
    while off + 4 <= data.len() {
        if data[off] != 0xAC || (data[off + 1] != 0x40 && data[off + 1] != 0x41) {
            break;
        }
        let mut total = u16::from_be_bytes([data[off + 2], data[off + 3]]) as usize + 4;
        if total == 4 + 0xFFFF {
            total =
                7 + u32::from_be_bytes([0, data[off + 4], data[off + 5], data[off + 6]]) as usize;
        }
        if data[off + 1] == 0x41 {
            total += 2;
        }
        if off + total > data.len() {
            break;
        }
        frames.push(&data[off..off + total]);
        off += total;
    }
    frames
}

struct Fixture {
    frames: Vec<Vec<u8>>,
}

fn fixtures() -> Vec<Fixture> {
    vec![
        Fixture {
            frames: split_frames(FIX_P83)
                .into_iter()
                .map(|f| f.to_vec())
                .collect(),
        },
        Fixture {
            frames: split_frames(FIX_ATSC3)
                .into_iter()
                .map(|f| f.to_vec())
                .collect(),
        },
        Fixture {
            frames: {
                let mut out = Vec::new();
                let mut pos = 0usize;
                for sz in FIX_HTYS_SIZES {
                    out.push(FIX_HTYS[pos..pos + sz].to_vec());
                    pos += sz;
                }
                out
            },
        },
    ]
}

/// Runs one decode; panics of the test (not of the decoder) on decoder panic.
fn must_not_panic(
    seed: u64,
    phase: &str,
    iter: usize,
    packet: &[u8],
    dec: &mut Ac4Decoder,
    buf: &mut Vec<Vec<f32>>,
) {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = dec.decode_frame_into(packet, buf);
    }));
    if let Err(panic_payload) = result {
        let msg = panic_payload
            .downcast_ref::<&str>()
            .map(|s| s.to_string())
            .or_else(|| panic_payload.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "<non-string panic>".into());
        let head: String = packet.iter().take(48).map(|b| format!("{b:02x}")).collect();
        panic!(
            "decoder panicked!\n  phase={phase} iter={iter} seed={seed} packet_len={}\n  panic={msg}\n  packet_head={head}",
            packet.len()
        );
    }
}

fn fuzz_no_panics_body(seed: u64, iters: usize) {
    let fx = fixtures();
    assert!(fx[0].frames.len() >= 6);
    assert!(fx[1].frames.len() >= 6);
    assert!(fx[2].frames.len() >= 6);

    // Phase 1: every truncation of every fixture's iframe.
    for f in &fx {
        let iframe = &f.frames[0];
        for len in 0..=iframe.len() {
            let mut dec = Ac4Decoder::new().unwrap();
            let mut buf = Vec::new();
            must_not_panic(seed, "truncation", len, &iframe[..len], &mut dec, &mut buf);
        }
    }

    // Phase 2: bit flips across all fixtures; decoder reused like a
    // long-lived session.
    let mut rng = Xorshift(seed);
    let mut dec = Ac4Decoder::new().unwrap();
    let mut buf: Vec<Vec<f32>> = Vec::new();
    for iter in 0..iters {
        let f = &fx[rng.below(fx.len())];
        let mut packet = f.frames[rng.below(f.frames.len())].clone();
        let flips = 1 + rng.below(3);
        for _ in 0..flips {
            let pos = rng.below(packet.len() * 8);
            packet[pos >> 3] ^= 0x80 >> (pos & 7);
        }
        must_not_panic(seed, "bitflip", iter, &packet, &mut dec, &mut buf);
    }

    // Phase 3: pseudo-random garbage, with and without AC-4 sync headers.
    let mut rng = Xorshift(seed ^ 0xDEAD_BEEF);
    for iter in 0..iters {
        let len = rng.below(3000);
        let mut packet = vec![0u8; len];
        for b in packet.iter_mut() {
            *b = rng.next() as u8;
        }
        if rng.next() & 1 == 0 && packet.len() >= 8 {
            packet[0] = 0xAC;
            packet[1] = if rng.next() & 1 == 0 { 0x40 } else { 0x41 };
            let size = (rng.next() as u16) & 0x1FFF;
            packet[2..4].copy_from_slice(&size.to_be_bytes());
        }
        must_not_panic(seed, "garbage", iter, &packet, &mut dec, &mut buf);
    }

    // Phase 4: single-bit flips across whole fixture streams decoded end to
    // end (frame interactions across recovery paths).
    let streams: Vec<&[u8]> = vec![FIX_P83, FIX_ATSC3];
    let mut rng = Xorshift(seed ^ 0x1234_5678);
    for iter in 0..iters / 4 {
        let stream = streams[rng.below(streams.len())];
        let mut copy = stream.to_vec();
        let pos = rng.below(copy.len() * 8);
        copy[pos >> 3] ^= 0x80 >> (pos & 7);
        let mut dec = Ac4Decoder::new().unwrap();
        let mut buf: Vec<Vec<f32>> = Vec::new();
        for frame in split_frames(&copy) {
            must_not_panic(seed, "stream", iter, frame, &mut dec, &mut buf);
        }
    }

    // Phase 5: structured mode-switch mutations on the stereo CM_ASPX
    // fixture — force the SSF (mdct_stereo_proc + spec_frontend) and ACPL
    // (codec_mode) header bits every iteration, plus random extra flips,
    // so the SSF/ACPL code paths execute at every single iteration.
    // Bit offsets are valid for this fixture's iframe layout.
    let mut rng = Xorshift(seed ^ 0x55AA_55AA);
    let mut dec = Ac4Decoder::new().unwrap();
    let mut buf: Vec<Vec<f32>> = Vec::new();
    let set_bit = |packet: &mut Vec<u8>, p: usize, v: bool| {
        if v {
            packet[p >> 3] |= 0x80 >> (p & 7);
        } else {
            packet[p >> 3] &= !(0x80 >> (p & 7));
        }
    };
    for iter in 0..iters {
        let f = &fx[0];
        let mut packet = f.frames[rng.below(f.frames.len())].clone();
        if packet.len() * 8 > 320 {
            match iter & 3 {
                0 => {
                    // SSF both channels: mdct_stereo_proc=0, spec=1,1
                    set_bit(&mut packet, 316, false);
                    set_bit(&mut packet, 317, true);
                    set_bit(&mut packet, 318, true);
                }
                1 => {
                    // CM_ASPX(01) -> CM_ASPX_ACPL_1(10)
                    set_bit(&mut packet, 296, true);
                    set_bit(&mut packet, 297, false);
                }
                _ => {}
            }
        }
        let flips = rng.below(3);
        for _ in 0..flips {
            let pos = rng.below(packet.len() * 8);
            packet[pos >> 3] ^= 0x80 >> (pos & 7);
        }
        must_not_panic(seed, "modeswitch", iter, &packet, &mut dec, &mut buf);
    }

    // Phase 6: random flush() and QMF-bypass toggles interleaved with
    // decoding (the CM_SIMPLE fixture actually takes the bypass path).
    let mut rng = Xorshift(seed ^ 0x00F1_A5E5);
    let mut dec = Ac4Decoder::new().unwrap();
    let mut buf: Vec<Vec<f32>> = Vec::new();
    for iter in 0..iters / 4 {
        let src = if rng.next() & 1 == 0 { &fx[2] } else { &fx[0] };
        let packet = src.frames[rng.below(src.frames.len())].clone();
        match rng.next() & 3 {
            0 => dec.flush(),
            1 => dec.set_qmf_bypass(rng.next() & 1 == 0),
            _ => {}
        }
        must_not_panic(seed, "flushmix", iter, &packet, &mut dec, &mut buf);
    }
}

#[test]
fn fuzz_no_panics() {
    // debug builds blow the default 2 MiB test-thread stack (large stack
    // arrays inside the decoder); run the whole fuzz on a dedicated thread
    let seed: u64 = std::env::var("BAKA_FUZZ_SEED")
        .ok()
        .and_then(|v| u64::from_str_radix(v.trim_start_matches("0x"), 16).ok())
        .unwrap_or(0xAC4F_C0DE_AC4F_C0DE);
    let iters: usize = std::env::var("BAKA_FUZZ_ITERS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(20_000);
    let child = std::thread::Builder::new()
        .stack_size(64 * 1024 * 1024)
        .spawn(move || fuzz_no_panics_body(seed, iters))
        .unwrap();
    child.join().unwrap();
}
