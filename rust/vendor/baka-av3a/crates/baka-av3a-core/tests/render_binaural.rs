use baka_av3a_core::render::{BinauralRenderer, BinauralSource, HrirBank, HrirMeasurement};
fn bank() -> HrirBank {
    HrirBank::from_bytes(include_bytes!("fixtures/synthetic_hrir.bin")).unwrap()
}

#[test]
fn reactivation_after_silent_direction_changes_rebuilds_the_correct_old_spectrum() {
    let initial = BinauralSource {
        azimuth: 90.,
        elevation: 0.,
        gain: 1.,
    };
    let held = BinauralSource {
        azimuth: 120.,
        elevation: 20.,
        gain: 0.75,
    };
    let target = BinauralSource {
        azimuth: -90.,
        elevation: -20.,
        gain: 0.5,
    };
    let mut actual = BinauralRenderer::new(bank(), 48000, &[initial]).unwrap();
    let input: Vec<_> = (0..1024)
        .map(|i| ((i * 37 % 101) as f32 - 50.) * 0.001)
        .collect();
    let mut a = vec![0.; 2048];
    let mut b = a.clone();
    actual.process(&input, &mut a).unwrap();
    for azimuth in [-30., 0., 120.] {
        actual
            .set_sources(&[BinauralSource { azimuth, ..held }], &[false])
            .unwrap();
        actual.process_silence(&mut a).unwrap();
    }
    assert!(a.iter().all(|v| *v == 0.));
    let mut reference = BinauralRenderer::new(bank(), 48000, &[held]).unwrap();
    reference.process_silence(&mut b).unwrap();
    actual.set_sources(&[target], &[false]).unwrap();
    reference.set_sources(&[target], &[false]).unwrap();
    for _ in 0..4 {
        actual.process(&input, &mut a).unwrap();
        reference.process(&input, &mut b).unwrap();
        assert_eq!(a, b);
    }
}
fn stages() -> [[BinauralSource; 3]; 5] {
    [
        [(0., 0., 1.), (-90., 0., 0.5), (0., 90., 0.75)],
        [(90., 0., 0.8), (-30., 20., 1.), (0., 60., 0.5)],
        [(-90., 0., 0.6), (30., -20., 0.5), (0., -90., 0.25)],
        [(120., 10., 0.4), (0., 0., 0.), (90., 0., 0.5)],
        [(0., 0., 1.), (-90., 0., 0.5), (0., 90., 0.75)],
    ]
    .map(|stage| {
        stage.map(|(azimuth, elevation, gain)| BinauralSource {
            azimuth,
            elevation,
            gain,
        })
    })
}
fn jumps(block: usize) -> [bool; 3] {
    match block {
        2 => [true, false, true],
        4 => [true, false, false],
        _ => [false; 3],
    }
}
fn signal(block: usize) -> Vec<f32> {
    (0..1024)
        .flat_map(|i| {
            (0..3).map(move |source| {
                ((i * 1597 + source * 711 + block * 113) % 8192) as f32 / 32768. - 0.125
            })
        })
        .collect()
}

#[test]
fn independent_fir_updates_jumps_and_complete_tail() {
    let fixture = include_bytes!("fixtures/binaural_pcm.bin");
    assert_eq!(&fixture[..8], b"BNPCM001");
    let frames = u32::from_le_bytes(fixture[8..12].try_into().unwrap()) as usize;
    assert_eq!(fixture.len(), 12 + frames * 8);
    let expected: Vec<_> = fixture[12..]
        .as_chunks::<4>()
        .0
        .iter()
        .map(|v| f32::from_le_bytes(*v))
        .collect();
    let stage = stages();
    let mut renderer = BinauralRenderer::new(bank(), 48000, &stage[0]).unwrap();
    let mut actual = vec![0.0; frames * 2];
    for (block, stage) in stage.iter().enumerate() {
        renderer.set_sources(stage, &jumps(block)).unwrap();
        renderer
            .process(
                &signal(block),
                &mut actual[block * 2048..(block + 1) * 2048],
            )
            .unwrap();
    }
    for block in 5..8 {
        renderer
            .process_silence(&mut actual[block * 2048..(block + 1) * 2048])
            .unwrap();
    }
    let peak = actual
        .iter()
        .zip(expected)
        .map(|(a, b)| (a - b).abs())
        .fold(0.0_f32, f32::max);
    assert!(peak < 3e-7, "PCM max {peak}");
    eprintln!("independent binaural dynamic FIR PCM max{peak:e}");
    assert!(actual[7 * 2048..].iter().all(|v| *v == 0.0));
    assert_eq!(renderer.tail_samples(), 1122);
    assert_eq!(BinauralRenderer::DELAY_SAMPLES, 99);
}

#[test]
fn directions_roundtrip_and_bounded_asset_validation() {
    let bank = bank();
    let encoded = bank.to_bytes();
    let copy = HrirBank::from_bytes(&encoded).unwrap();
    assert_eq!(encoded, copy.to_bytes());
    for (index, m) in bank.measurements().iter().enumerate() {
        let w = copy.interpolate(m.azimuth, m.elevation).unwrap();
        let mut all = [0.0; 6];
        for (&i, &weight) in w.indices.iter().zip(&w.weights) {
            all[i] += weight;
        }
        for (i, &weight) in all.iter().enumerate() {
            assert!((weight - if i == index { 1.0 } else { 0.0 }).abs() < 1e-12);
        }
    }
    for azimuth in (-180..=180).step_by(5) {
        for elevation in (-90..=90).step_by(5) {
            let w = bank
                .interpolate(f64::from(azimuth), f64::from(elevation))
                .unwrap();
            assert!(w.weights.iter().all(|v| v.is_finite() && *v >= 0.0));
            assert!((w.weights.iter().sum::<f64>() - 1.0).abs() < 1e-12);
        }
    }
    for length in [0, 7, 8, 12, 27, 28, 1024, encoded.len() - 1] {
        assert!(HrirBank::from_bytes(&encoded[..length]).is_err());
    }
    for (offset, value) in [
        (8, 0),
        (12, 3),
        (12, 2049),
        (16, 0),
        (16, 1025),
        (20, 0),
        (20, 4097),
        (24, f32::NAN.to_bits()),
        (28, f32::NAN.to_bits()),
        (36, f32::INFINITY.to_bits()),
        (36, 17.0_f32.to_bits()),
    ] {
        let mut bad = encoded.clone();
        bad[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        assert!(
            HrirBank::from_bytes(&bad).is_err(),
            "offset{offset} value{value}"
        );
    }
    let mut extra = encoded.clone();
    extra.push(0);
    assert!(HrirBank::from_bytes(&extra).is_err());
    let mut excessive = encoded.clone();
    for i in 0..65 {
        excessive[36 + i * 4..40 + i * 4].copy_from_slice(&1.0_f32.to_le_bytes());
    }
    assert!(HrirBank::from_bytes(&excessive).is_err());
    let mut open = encoded.clone();
    open[20..24].copy_from_slice(&7u32.to_le_bytes());
    open.truncate(open.len() - 12);
    assert!(HrirBank::from_bytes(&open).is_err());
    // Corrupt the first face, an edge, a repeated face, or a duplicate direction.
    let faces = 28 + 6 * (8 + 1024 * 8);
    for (offset, value) in [(faces, 6u32), (faces + 4, 6u32)] {
        let mut bad = encoded.clone();
        bad[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        assert!(HrirBank::from_bytes(&bad).is_err());
    }
    let mut bad = encoded.clone();
    let face = bad[faces..faces + 12].to_vec();
    bad[faces + 12..faces + 24].copy_from_slice(&face);
    assert!(HrirBank::from_bytes(&bad).is_err());
    let mut bad = encoded.clone();
    let angle = bad[28..36].to_vec();
    bad[28 + 8200..36 + 8200].copy_from_slice(&angle);
    assert!(HrirBank::from_bytes(&bad).is_err());
    for angles in [(f64::NAN, 0.), (0., f64::INFINITY), (0., 91.)] {
        assert!(bank.interpolate(angles.0, angles.1).is_err());
    }
    assert_eq!(bank.sample_rate(), 48000);
    assert_eq!(bank.measurement_radius(), 1.0);
    let invalid = HrirMeasurement {
        azimuth: 0.,
        elevation: 0.,
        left: vec![0.; 4],
        right: vec![0.; 3],
    };
    assert!(HrirBank::new(48000, 1.0, vec![invalid; 4], vec![[0, 1, 2]; 4]).is_err());
}

#[test]
fn invalid_updates_preserve_pending_jumps_clone_audio_and_reset() {
    let stages = stages();
    let mut actual = BinauralRenderer::new(bank(), 48000, &stages[0]).unwrap();
    let mut a = vec![0.0; 2048];
    let mut b = a.clone();
    actual.process(&signal(0), &mut a).unwrap();
    actual.set_sources(&stages[2], &jumps(2)).unwrap();
    let mut cloned = actual.clone();
    let mut bad = stages[1];
    bad[2].elevation = 91.0;
    assert!(actual.set_sources(&bad, &[false; 3]).is_err());
    assert_eq!(actual.sources(), stages[2]);
    assert!(actual.set_sources(&stages[1][..2], &[false; 2]).is_err());
    for invalid in [f32::NAN, f32::INFINITY, -257., 257.] {
        let mut bad = signal(1);
        bad[3000] = invalid;
        a.fill(42.);
        assert!(actual.process(&bad, &mut a).is_err());
        assert!(a.iter().all(|v| *v == 42.));
    }
    assert!(actual.process(&signal(1)[..3071], &mut a).is_err());
    assert!(actual.process(&signal(1), &mut a[..2047]).is_err());
    for block in 1..5 {
        actual.process(&signal(block), &mut a).unwrap();
        cloned.process(&signal(block), &mut b).unwrap();
        assert_eq!(a, b);
    }
    actual.reset();
    let mut fresh = BinauralRenderer::new(bank(), 48000, &stages[2]).unwrap();
    actual.process(&signal(1), &mut a).unwrap();
    fresh.process(&signal(1), &mut b).unwrap();
    assert_eq!(a, b);
    assert!(BinauralRenderer::new(bank(), 44100, &stages[0]).is_err());
    assert!(BinauralRenderer::new(bank(), 48000, &[]).is_err());
    assert!(BinauralRenderer::new(bank(), 48000, &[BinauralSource::default(); 17]).is_err());
    let mut loud = BinauralRenderer::new(
        bank(),
        48000,
        &[BinauralSource {
            gain: 16.0,
            ..Default::default()
        }; 16],
    )
    .unwrap();
    for _ in 0..3 {
        loud.process(&[256.; 16384], &mut a).unwrap();
    }
    assert!(a.iter().all(|v| v.is_finite()));
}

#[test]
#[ignore = "requires private measured HRIR bank in BAKA_AV3A_HRIR_BANK"]
fn measured_hrir_impulse_and_interaural_cues() {
    let bytes = std::fs::read(std::env::var("BAKA_AV3A_HRIR_BANK").unwrap()).unwrap();
    let bank = HrirBank::from_bytes(&bytes).unwrap();
    let mut peak = 0.0_f32;
    for index in 0..bank.measurements().len() {
        let m = &bank.measurements()[index];
        let source = BinauralSource {
            azimuth: m.azimuth,
            elevation: m.elevation,
            gain: 1.0,
        };
        let mut renderer =
            BinauralRenderer::new(bank.clone(), bank.sample_rate(), &[source]).unwrap();
        renderer.set_sources(&[source], &[true]).unwrap();
        let mut input = [0.0; 1024];
        input[0] = 0.25;
        let mut output = [0.0; 2048];
        renderer.process(&input, &mut output).unwrap();
        for (ear, taps) in [&m.left, &m.right].iter().enumerate() {
            for i in 0usize..1024 {
                let expected = i
                    .checked_sub(99)
                    .and_then(|n| taps.get(n))
                    .copied()
                    .unwrap_or(0.0)
                    * 0.25;
                let delta = (output[i * 2 + ear] - expected).abs();
                peak = peak.max(delta);
                assert!(delta < 2e-7);
            }
        }
    }
    let measured = bank.measurements();
    let left = measured
        .iter()
        .min_by(|a, b| {
            ((a.azimuth - 90.0).powi(2) + a.elevation.powi(2))
                .total_cmp(&((b.azimuth - 90.0).powi(2) + b.elevation.powi(2)))
        })
        .unwrap();
    let right = measured
        .iter()
        .min_by(|a, b| {
            ((a.azimuth + 90.0).powi(2) + a.elevation.powi(2))
                .total_cmp(&((b.azimuth + 90.0).powi(2) + b.elevation.powi(2)))
        })
        .unwrap();
    let energy = |v: &[f32]| v.iter().map(|v| f64::from(*v).powi(2)).sum::<f64>();
    assert!(energy(&left.left) > energy(&left.right));
    assert!(energy(&right.right) > energy(&right.left));
    eprintln!(
        "{} measured HRIR directions, impulse max error{peak:e}",
        measured.len()
    );
}

#[test]
#[ignore = "requires private HRIR bank and independent motion oracle"]
fn measured_hrir_motion_matches_direct_fir() {
    let bank = HrirBank::from_bytes(
        &std::fs::read(std::env::var("BAKA_AV3A_HRIR_BANK").unwrap()).unwrap(),
    )
    .unwrap();
    let fixture = std::fs::read(std::env::var("BAKA_AV3A_HRIR_MOTION").unwrap()).unwrap();
    assert_eq!(&fixture[..8], b"BNPCM001");
    let frames = u32::from_le_bytes(fixture[8..12].try_into().unwrap()) as usize;
    assert_eq!(frames, 8192);
    assert_eq!(fixture.len(), 12 + frames * 8);
    let expected: Vec<_> = fixture[12..]
        .as_chunks::<4>()
        .0
        .iter()
        .map(|v| f32::from_le_bytes(*v))
        .collect();
    let stage = stages();
    let mut renderer = BinauralRenderer::new(bank.clone(), bank.sample_rate(), &stage[0]).unwrap();
    let mut actual = vec![0.0; frames * 2];
    for (block, stage) in stage.iter().enumerate() {
        renderer.set_sources(stage, &jumps(block)).unwrap();
        renderer
            .process(
                &signal(block),
                &mut actual[block * 2048..(block + 1) * 2048],
            )
            .unwrap();
    }
    for block in 5..8 {
        renderer
            .process_silence(&mut actual[block * 2048..(block + 1) * 2048])
            .unwrap();
    }
    let peak = actual
        .iter()
        .zip(expected)
        .map(|(a, b)| (a - b).abs())
        .fold(0.0_f32, f32::max);
    assert!(peak < 5e-7, "measured motion PCM max {peak}");
    eprintln!(
        "measured HRIR{}Hz independent dynamic PCM max{peak:e}",
        bank.sample_rate()
    );
}
