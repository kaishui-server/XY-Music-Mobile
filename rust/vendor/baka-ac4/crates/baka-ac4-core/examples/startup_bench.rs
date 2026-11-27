use baka_ac4_core::Ac4Decoder;
use std::{hint::black_box, time::Instant};

fn main() {
    let cold = Instant::now();
    black_box(Ac4Decoder::new().unwrap());
    println!("cold_us={}", cold.elapsed().as_micros());
    let mut times = Vec::new();
    for _ in 0..100 {
        let start = Instant::now();
        black_box(Ac4Decoder::new().unwrap());
        times.push(start.elapsed().as_micros());
    }
    times.sort_unstable();
    println!("warm_min_us={} warm_median_us={}", times[0], times[50]);
}
