//! Guard synthesis PCM against the pre-optimization Rust 1.100.0 implementation.
use baka_av3a_core::synthesis::Synthesis;

fn spectrum(frame: usize) -> [f32; 1024] {
    std::array::from_fn(|i| match (i + frame) % 17 {
        0 => -0.0,
        1 => 0.0,
        2 => f32::from_bits(1),
        _ => ((i * 37 + frame * 53) % 257) as f32 / 128.0 - 1.0,
    })
}

#[test]
fn window_transitions_preserve_pcm_bits() {
    let mut synthesis = Synthesis::new();
    synthesis.reset();
    let mut hash = 0xcbf29ce484222325u64;
    for frame in 0..128 {
        let transform = [0, 2, 1, 1, 3, 0, 2, 1, 3][frame % 9];
        for sample in synthesis.process(&spectrum(frame), transform).unwrap() {
            for byte in sample.to_bits().to_le_bytes() {
                hash = (hash ^ u64::from(byte)).wrapping_mul(0x100000001b3);
            }
        }
    }
    // Recorded before workspace reuse: all 131,072 f32 output bit patterns,
    // including signed zero, subnormals and long/short transition history.
    assert_eq!(hash, 0xdce1b7a3479ff243);
}

#[test]
fn short_window_failures_and_reset_preserve_history() {
    let mut synthesis = Synthesis::new();
    synthesis.process(&spectrum(1), 2).unwrap();
    synthesis.process(&spectrum(2), 1).unwrap();
    let mut control = synthesis.clone();
    for bad in [f32::NAN, f32::INFINITY, f32::MAX] {
        assert!(synthesis.process(&[bad; 1024], 1).is_err());
    }
    let actual = synthesis.process(&spectrum(3), 1).unwrap();
    let expected = control.process(&spectrum(3), 1).unwrap();
    assert_eq!(actual.map(f32::to_bits), expected.map(f32::to_bits));
    synthesis.reset();
    let actual = synthesis.process(&spectrum(4), 1).unwrap();
    let expected = Synthesis::new().process(&spectrum(4), 1).unwrap();
    assert_eq!(actual.map(f32::to_bits), expected.map(f32::to_bits));
}

#[test]
#[ignore = "manual host timing; run release with --ignored --nocapture"]
fn short_window_measurement() {
    let mut synthesis = Synthesis::new();
    let input = spectrum(0);
    for _ in 0..100 {
        std::hint::black_box(synthesis.process(&input, 1).unwrap());
    }
    let mut times = [std::time::Duration::ZERO; 7];
    for time in &mut times {
        let start = std::time::Instant::now();
        for _ in 0..2000 {
            std::hint::black_box(synthesis.process(std::hint::black_box(&input), 1).unwrap());
        }
        *time = start.elapsed();
    }
    times.sort();
    eprintln!("2000 short frames median: {:?}", times[3]);
}
