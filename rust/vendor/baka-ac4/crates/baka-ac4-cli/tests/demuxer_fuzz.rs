//! Panic-safety fuzzing for the CLI demuxers (MP4 sample-table reader and
//! raw .ac4 framer) — these parse untrusted user files directly.

use baka_ac4_cli::{mp4, raw};

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

fn check(name: &str, iter: usize, data: &[u8]) {
    let r = std::panic::catch_unwind(|| {
        let _ = mp4::read_ac4_track(data);
        let _ = raw::read_ac4_frames(data);
    });
    if r.is_err() {
        let head: String = data.iter().take(32).map(|b| format!("{b:02x}")).collect();
        panic!(
            "demuxer panicked! {name} iter={iter} len={} head={head}",
            data.len()
        );
    }
}

#[test]
fn demuxers_no_panics() {
    let iters: usize = std::env::var("BAKA_FUZZ_ITERS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(20000);

    // Phase 1: raw garbage.
    let mut rng = Xorshift(0xDEAD_10CC);
    for iter in 0..iters {
        let len = rng.below(4000);
        let d: Vec<u8> = (0..len).map(|_| rng.next() as u8).collect();
        check("garbage", iter, &d);
    }

    // Phase 2: MP4-ish scaffolding (ftyp/moov/stsz/stco atoms) with mutated
    // fields, so the parser walks real atom structure but sees hostile
    // sizes/counts/offsets, plus random truncation.
    let mut rng = Xorshift(0xBEEF_CAFE);
    for iter in 0..iters {
        let mut d = Vec::new();
        let put = |d: &mut Vec<u8>, tag: &[u8], body: &[u8]| {
            d.extend_from_slice(&((body.len() as u32 + 8).to_be_bytes()));
            d.extend_from_slice(tag);
            d.extend_from_slice(body);
        };
        put(&mut d, b"ftyp", b"isom");
        let stsz_count = (rng.next() as u32) % 3000;
        let stsz_uniform = (rng.next() as u32) % 64;
        let mut stsz = vec![0u8; 8];
        stsz[..4].copy_from_slice(&stsz_uniform.to_be_bytes());
        stsz[4..].copy_from_slice(&stsz_count.to_be_bytes());
        for _ in 0..rng.below(64) {
            stsz.extend_from_slice(&(rng.next() as u32).to_be_bytes());
        }
        put(&mut d, b"stsz", &stsz);
        let stco_count = (rng.next() as u32) % 512;
        let mut stco = vec![0u8; 4];
        stco[..4].copy_from_slice(&stco_count.to_be_bytes());
        for _ in 0..rng.below(128) {
            stco.extend_from_slice(&(rng.next() as u32).to_be_bytes());
        }
        put(&mut d, b"stco", &stco);
        let cut = rng.below(d.len() + 1);
        d.truncate(cut);
        check("mp4ish", iter, &d);
    }

    // Phase 3: a real MP4 with byte flips, truncations and spoils.
    let base: &[u8] = include_bytes!("fixtures/mp4_probe.mp4");
    for iter in 0..iters / 2 {
        let mut d = base.to_vec();
        match rng.next() & 3 {
            0 => {
                let pos = rng.below(d.len());
                d[pos] ^= 1 << rng.below(8);
            }
            1 => {
                let cut = rng.below(d.len());
                d.truncate(cut);
            }
            2 => {
                let pos = rng.below(d.len());
                let n = 1 + rng.below(16);
                for k in 0..n {
                    if pos + k < d.len() {
                        d[pos + k] = rng.next() as u8;
                    }
                }
            }
            _ => {
                let pos = rng.below(d.len());
                d[pos] = 0xFF;
            }
        }
        check("realmut", iter, &d);
    }
}
