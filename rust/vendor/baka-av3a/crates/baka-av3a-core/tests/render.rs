use baka_av3a_core::render::LookAheadLimiter;

fn signal() -> Vec<f32> {
    let mut samples = vec![0.0; 4096];
    samples[0] = 0.25;
    samples[128] = -0.5;
    samples[256] = 3.0;
    samples[257] = -3.0;
    let mut state = 0x1234_5678_u32;
    for sample in &mut samples[512..3996] {
        state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        *sample = ((state % 196_609) as i32 - 98_304) as f32 / 32768.0;
    }
    samples
}

#[test]
fn limiting_vector() {
    let mut samples = signal();
    LookAheadLimiter::new(1)
        .unwrap()
        .process(&mut samples)
        .unwrap();
    let hash = samples
        .iter()
        .flat_map(|v| v.to_le_bytes())
        .fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
            (hash ^ u64::from(byte)).wrapping_mul(0x100_0000_01b3)
        });
    assert_eq!(hash, 0x11b2_894e_f420_41ef);
    assert_eq!(samples[99], 0.25);
    assert_eq!(samples[227], -0.5);
    assert_eq!(samples[355].to_bits(), 0x3f81_3f74);
    assert_eq!(samples[356].to_bits(), 0xbf81_42c2);
}

#[test]
fn blocks_clone_reset_and_channels() {
    let mono = signal();
    let mut expected = mono.clone();
    LookAheadLimiter::new(1)
        .unwrap()
        .process(&mut expected)
        .unwrap();
    for channels in 1..=16 {
        let mut samples: Vec<_> = mono
            .iter()
            .flat_map(|v| (0..channels).map(move |channel| if channel == 0 { *v } else { 0.0 }))
            .collect();
        let mut limiter = LookAheadLimiter::new(channels).unwrap();
        assert_eq!(limiter.channels(), channels);
        let width = usize::from(channels);
        for block in samples.chunks_mut(37 * width) {
            limiter.process(block).unwrap();
        }
        for (frame, expected) in samples.chunks_exact(width).zip(&expected) {
            assert_eq!(frame[0].to_bits(), expected.to_bits());
            assert!(frame[1..].iter().all(|v| *v == 0.0));
        }
        let mut cloned = limiter.clone();
        let mut a = vec![0.5; 123 * width];
        let mut b = a.clone();
        limiter.process(&mut a).unwrap();
        cloned.process(&mut b).unwrap();
        assert_eq!(a, b);
        limiter.reset();
        let mut impulse = vec![0.0; 200 * width];
        impulse[0] = 0.5;
        limiter.process(&mut impulse).unwrap();
        assert_eq!(impulse[LookAheadLimiter::DELAY_SAMPLES * width], 0.5);
        assert_eq!(impulse.iter().filter(|v| **v != 0.0).count(), 1);
    }
}

#[test]
fn validation_preserves_input_and_history() {
    assert!(LookAheadLimiter::new(0).is_err());
    assert!(LookAheadLimiter::new(17).is_err());
    let mut limiter = LookAheadLimiter::new(2).unwrap();
    limiter.process(&mut [0.3; 260]).unwrap();
    let mut reference = limiter.clone();
    for mut invalid in [
        vec![0.5],
        vec![0.4, f32::NAN],
        vec![f32::INFINITY, 0.1],
        vec![0.4, f32::NEG_INFINITY],
    ] {
        let original: Vec<_> = invalid.iter().map(|v| v.to_bits()).collect();
        assert!(limiter.process(&mut invalid).is_err());
        assert_eq!(
            invalid.iter().map(|v| v.to_bits()).collect::<Vec<_>>(),
            original
        );
    }
    limiter.process(&mut []).unwrap();
    let mut a = vec![0.2; 512];
    let mut b = a.clone();
    limiter.process(&mut a).unwrap();
    reference.process(&mut b).unwrap();
    assert_eq!(a, b);
}
