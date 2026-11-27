use baka_av3a_core::render::{
    AcousticBandLayout, AcousticMaterial, AcousticRoom, AcousticSurface, BinauralRenderer,
    BinauralSource, EarlyRoomBinauralRenderer, EarlyRoomConfig, FilteredPropagationRenderer,
    HeadOrientation, HrirBank, ListenerPose, LookAheadLimiter, MaterialFir, PropagationTarget,
};
fn config() -> EarlyRoomConfig {
    EarlyRoomConfig {
        maximum_delay_seconds: 0.1,
        speed_of_sound: 340.,
        reference_distance: 1.,
        minimum_distance: 0.1,
        direct_gain: 1.,
        early_gain: 0.8,
    }
}
fn bands(rate: u32) -> AcousticBandLayout {
    AcousticBandLayout::new(
        rate,
        [30., 70., 160., 360., 810., 1820., 3000.].map(|v| v * f64::from(rate) / 8000.),
    )
    .unwrap()
}
fn material() -> AcousticMaterial {
    AcousticMaterial::new(std::array::from_fn(|i| [0.1 * i as f64, 0.2])).unwrap()
}
fn room() -> AcousticRoom {
    AcousticRoom::new(vec![
        AcousticSurface::new(
            &[[0., -5., -5.], [0., 5., -5.], [0., 5., 5.], [0., -5., 5.]],
            material(),
        )
        .unwrap(),
    ])
    .unwrap()
}
fn bank() -> HrirBank {
    HrirBank::from_bytes(include_bytes!("fixtures/synthetic_hrir.bin")).unwrap()
}
fn pose(block: usize) -> ListenerPose {
    ListenerPose::new(
        [1. + (block % 3) as f64 * 0.1, -0.3, 0.2],
        HeadOrientation::from_yaw_pitch_roll(block as f64 * 31., 13., -17.).unwrap(),
    )
    .unwrap()
}
fn input(block: usize, count: usize) -> Vec<f32> {
    (0..1024 * count)
        .map(|i| {
            if block < 3 {
                ((i * 37 + block * 11) % 101) as f32 * 0.00001 - 0.0005
            } else {
                0.
            }
        })
        .collect()
}
fn close(a: &[f32], b: &[f32], limit: f32) {
    let error = a
        .iter()
        .zip(b)
        .map(|(a, b)| (a - b).abs())
        .fold(0f32, f32::max);
    assert!(error < limit, "PCM error {error:e}");
}

// Independent analytic x=0 mirror geometry and explicit composition of the
// already verified propagation/material/HRIR primitives. At quiet levels,
// individual reference limiters are unity and their shared99 delay commutes
// with the final sum. A separate loud test verifies one nonlinear limiter.
fn plans(
    source: [f64; 3],
    listener: ListenerPose,
    rate: u32,
) -> ([PropagationTarget; 2], [BinauralSource; 2]) {
    let images = [source, [-source[0], source[1], source[2]]];
    let targets = std::array::from_fn(|i| {
        let distance = images[i]
            .iter()
            .zip(listener.position())
            .map(|(a, b)| (a - b).powi(2))
            .sum::<f64>()
            .sqrt();
        PropagationTarget {
            delay_samples: distance / 340. * f64::from(rate),
            gain: ((if i == 0 { 1. } else { 0.8 }) / distance.max(0.1)) as f32,
        }
    });
    let directions = images.map(|image| {
        let [x, y, z] = listener.relative_position(image).unwrap();
        BinauralSource {
            azimuth: (-x).atan2(y).to_degrees(),
            elevation: z.atan2(x.hypot(y)).to_degrees(),
            gain: 1.,
        }
    });
    (targets, directions)
}
fn moving_oracle(bank: HrirBank) {
    let rate = bank.sample_rate();
    let layout = bands(rate);
    let sources = [[2., 0.4, 0.7], [3., -0.2, 0.5]];
    let mut actual =
        EarlyRoomBinauralRenderer::new(room(), &layout, bank.clone(), &sources, pose(0), config())
            .unwrap();
    let filters = [
        MaterialFir::new(&layout, [1.; 8]).unwrap(),
        MaterialFir::new(&layout, material().specular_pressure()).unwrap(),
    ];
    let mut reference: Vec<_> = sources
        .map(|source| {
            let (targets, directions) = plans(source, pose(0), rate);
            let propagation =
                FilteredPropagationRenderer::new(rate, 0.1, &targets, &filters).unwrap();
            let mut binaural = BinauralRenderer::new(bank.clone(), rate, &directions).unwrap();
            binaural.set_sources(&directions, &[true; 2]).unwrap();
            (propagation, binaural)
        })
        .into_iter()
        .collect();
    let mut a = vec![0.; 9 * 2048];
    let mut b = a.clone();
    let mut path_audio = [0.; 2048];
    let mut stereo = [0.; 2048];
    for block in 0..9 {
        let listener = pose(block);
        let jump = block == 2;
        actual.set_listener(listener, jump).unwrap();
        let pcm = input(block, 2);
        if block < 3 {
            actual
                .process(&pcm, &mut a[block * 2048..(block + 1) * 2048])
                .unwrap();
        } else {
            actual
                .process_silence(&mut a[block * 2048..(block + 1) * 2048])
                .unwrap();
        }
        for (index, (propagation, binaural)) in reference.iter_mut().enumerate() {
            let (targets, directions) = plans(sources[index], listener, rate);
            propagation
                .set_targets(&targets, &[jump || block == 0; 2])
                .unwrap();
            binaural
                .set_sources(&directions, &[jump || block == 0; 2])
                .unwrap();
            let mono: Vec<_> = pcm.as_chunks::<2>().0.iter().map(|v| v[index]).collect();
            propagation.process(&mono, &mut path_audio).unwrap();
            binaural.process(&path_audio, &mut stereo).unwrap();
            for (target, &value) in b[block * 2048..(block + 1) * 2048].iter_mut().zip(&stereo) {
                *target += value;
            }
        }
    }
    close(&a, &b, 5e-8);
    assert!(a[8 * 2048..].iter().all(|v| *v == 0.));
    assert_eq!(actual.source_positions(), sources);
    assert_eq!(actual.paths_per_source(), 2);
    assert_eq!(
        actual.tail_samples(),
        (0.1 * f64::from(rate)).ceil() as usize + 1022 + bank.tap_count() - 1 + 99
    );
}
#[test]
fn moving_listener_translation_rotation_and_jump_match_analytic_mirror_routes() {
    moving_oracle(bank());
}

#[test]
fn occlusion_stops_future_emissions_but_keeps_old_reflection_tail() {
    let bank = bank();
    let layout = bands(48000);
    let source = [2., 0., 0.];
    let initial = ListenerPose::new([1., 0., 0.], HeadOrientation::default()).unwrap();
    let mut actual =
        EarlyRoomBinauralRenderer::new(room(), &layout, bank.clone(), &[source], initial, config())
            .unwrap();
    let filters = [
        MaterialFir::new(&layout, [1.; 8]).unwrap(),
        MaterialFir::new(&layout, material().specular_pressure()).unwrap(),
    ];
    let (targets, directions) = plans(source, initial, 48000);
    let mut propagation = FilteredPropagationRenderer::new(48000, 0.1, &targets, &filters).unwrap();
    let mut reference = BinauralRenderer::new(bank, 48000, &directions).unwrap();
    reference.set_sources(&directions, &[true; 2]).unwrap();
    let mut a = vec![0.; 6 * 2048];
    let mut b = a.clone();
    let mut mono = [0.; 1024];
    mono[1023] = 0.01;
    let mut bus = [0.; 2048];
    actual.process(&mono, &mut a[..2048]).unwrap();
    propagation.process(&mono, &mut bus).unwrap();
    reference.process(&bus, &mut b[..2048]).unwrap();
    // The receiver crosses the wall. Direct sound is blocked and no same-side
    // reflection exists. Previously emitted arrivals must still be audible.
    let listener = ListenerPose::new([-1., 0., 0.], HeadOrientation::default()).unwrap();
    actual.set_listener(listener, true).unwrap();
    let images = [source, [-2., 0., 0.]];
    let directions = images.map(|image| {
        let [x, y, z] = listener.relative_position(image).unwrap();
        BinauralSource {
            azimuth: (-x).atan2(y).to_degrees(),
            elevation: z.atan2(x.hypot(y)).to_degrees(),
            gain: 1.,
        }
    });
    propagation
        .set_targets(
            &[PropagationTarget {
                delay_samples: 0.,
                gain: 0.,
            }; 2],
            &[true; 2],
        )
        .unwrap();
    reference.set_sources(&directions, &[true; 2]).unwrap();
    for block in 1..6 {
        actual
            .process(&[0.01; 1024], &mut a[block * 2048..(block + 1) * 2048])
            .unwrap();
        propagation.process(&[0.01; 1024], &mut bus).unwrap();
        reference
            .process(&bus, &mut b[block * 2048..(block + 1) * 2048])
            .unwrap();
    }
    close(&a, &b, 5e-8);
    assert!(a[2048..4 * 2048].iter().any(|v| v.abs() > 1e-6));
    assert!(a[5 * 2048..].iter().all(|v| *v == 0.));
}

#[test]
fn all_source_plans_validate_before_commit_and_reset_preserves_pose() {
    let bank = bank();
    let layout = bands(48000);
    let mut cfg = config();
    cfg.maximum_delay_seconds = 0.02;
    let sources = [[2., 0., 0.], [3., 0., 0.]];
    let initial = ListenerPose::new([1., 0., 0.], HeadOrientation::default()).unwrap();
    let mut actual = EarlyRoomBinauralRenderer::new(
        AcousticRoom::new(vec![]).unwrap(),
        &layout,
        bank.clone(),
        &sources,
        initial,
        cfg,
    )
    .unwrap();
    let mut a = [0.; 2048];
    for _ in 0..3 {
        actual.process(&input(0, 2), &mut a).unwrap();
    }
    let good = ListenerPose::new(
        [1.1, 0., 0.],
        HeadOrientation::from_yaw_pitch_roll(37., -13., 17.).unwrap(),
    )
    .unwrap();
    actual.set_listener(good, true).unwrap();
    let mut reference = actual.clone();
    // First source fits the budget, second does not. No first-source changes
    // may commit when validation subsequently fails on the second source.
    let bad = ListenerPose::new([-4., 0., 0.], HeadOrientation::default()).unwrap();
    assert!(actual.set_listener(bad, false).is_err());
    assert_eq!(actual.listener(), good);
    a.fill(123.);
    assert!(actual.process(&[f32::NAN; 2048], &mut a).is_err());
    assert!(actual.process(&[257.; 2048], &mut a).is_err());
    assert!(actual.process(&[0.; 2047], &mut a).is_err());
    assert!(actual.process(&[0.; 2048], &mut a[..2047]).is_err());
    assert_eq!(a, [123.; 2048]);
    let mut b = [0.; 2048];
    for _ in 0..5 {
        actual.process(&input(0, 2), &mut a).unwrap();
        reference.process(&input(0, 2), &mut b).unwrap();
        assert_eq!(a, b);
    }
    actual.reset();
    let mut fresh = EarlyRoomBinauralRenderer::new(
        AcousticRoom::new(vec![]).unwrap(),
        &layout,
        bank,
        &sources,
        good,
        cfg,
    )
    .unwrap();
    for _ in 0..6 {
        actual.process(&input(0, 2), &mut a).unwrap();
        fresh.process(&input(0, 2), &mut b).unwrap();
        assert_eq!(a, b);
    }
}

fn constant_bank() -> HrirBank {
    let source = include_bytes!("fixtures/synthetic_hrir.bin");
    let mut bytes = source[..28].to_vec();
    bytes[16..20].copy_from_slice(&8u32.to_le_bytes());
    for direction in 0..6 {
        let offset = 28 + direction * 8200;
        bytes.extend_from_slice(&source[offset..offset + 8]);
        for _ in 0..2 {
            for tap in 0..8 {
                bytes.extend_from_slice(&(if tap == 0 { 0.05f32 } else { 0. }).to_le_bytes());
            }
        }
    }
    bytes.extend_from_slice(&source[28 + 6 * 8200..]);
    HrirBank::from_bytes(&bytes).unwrap()
}
#[test]
fn sixteen_sources_mix_before_one_limiter_with_no_extra_alignment() {
    let bank = constant_bank();
    let layout = bands(48000);
    let positions = [[0., 1., 0.]; 16];
    let direct = MaterialFir::new(&layout, [1.; 8]).unwrap();
    let target = PropagationTarget {
        delay_samples: 48000. / 340.,
        gain: 1.,
    };
    for level in [1., 4.] {
        let mut renderer = EarlyRoomBinauralRenderer::new(
            AcousticRoom::new(vec![]).unwrap(),
            &layout,
            bank.clone(),
            &positions,
            ListenerPose::default(),
            config(),
        )
        .unwrap();
        let mut propagation =
            FilteredPropagationRenderer::new(48000, 0.1, &[target], std::slice::from_ref(&direct))
                .unwrap();
        let mut limiter = LookAheadLimiter::new(2).unwrap();
        let mut a = [0.; 2048];
        let mut b = [0.; 2048];
        let mut bus = [0.; 1024];
        for _ in 0..8 {
            renderer.process(&vec![level; 16384], &mut a).unwrap();
            propagation.process(&[level; 1024], &mut bus).unwrap();
            for (frame, &value) in bus.iter().enumerate() {
                b[frame * 2] = value * 0.05 * 16.;
                b[frame * 2 + 1] = b[frame * 2];
            }
            limiter.process(&mut b).unwrap();
            close(&a, &b, 2e-6);
        }
        if level == 1. {
            assert!(a.iter().all(|v| (*v - 0.8).abs() < 1e-6));
        }
    }
    assert_eq!(EarlyRoomBinauralRenderer::ALIGNMENT_SAMPLES, 610);
}

#[test]
fn construction_limits_and_initial_listener_update_are_explicit() {
    let bank = bank();
    let layout = bands(48000);
    let room = room();
    let sources = [[2., 0., 0.]];
    let cfg = config();
    let listener = pose(0);
    assert!(
        EarlyRoomBinauralRenderer::new(room.clone(), &layout, bank.clone(), &[], listener, cfg)
            .is_err()
    );
    assert!(
        EarlyRoomBinauralRenderer::new(
            room.clone(),
            &layout,
            bank.clone(),
            &[[2., 0., 0.]; 17],
            listener,
            cfg
        )
        .is_err()
    );
    assert!(
        EarlyRoomBinauralRenderer::new(
            room.clone(),
            &bands(44100),
            bank.clone(),
            &sources,
            listener,
            cfg
        )
        .is_err()
    );
    for invalid in [
        EarlyRoomConfig {
            maximum_delay_seconds: 2.01,
            ..cfg
        },
        EarlyRoomConfig {
            speed_of_sound: f64::NAN,
            ..cfg
        },
        EarlyRoomConfig {
            minimum_distance: 0.,
            ..cfg
        },
        EarlyRoomConfig {
            reference_distance: 2.,
            minimum_distance: 0.1,
            ..cfg
        },
        EarlyRoomConfig {
            early_gain: 1.01,
            ..cfg
        },
    ] {
        assert!(
            EarlyRoomBinauralRenderer::new(
                room.clone(),
                &layout,
                bank.clone(),
                &sources,
                listener,
                invalid
            )
            .is_err()
        );
    }
    assert!(
        EarlyRoomBinauralRenderer::new(
            room.clone(),
            &layout,
            bank.clone(),
            &[[0., 0., 0.]],
            listener,
            cfg
        )
        .is_err()
    );
    let mut a = EarlyRoomBinauralRenderer::new(
        room.clone(),
        &layout,
        bank.clone(),
        &sources,
        listener,
        cfg,
    )
    .unwrap();
    let new = pose(1);
    a.set_listener(new, false).unwrap();
    let mut b = EarlyRoomBinauralRenderer::new(room, &layout, bank, &sources, new, cfg).unwrap();
    let mut x = [0.; 2048];
    let mut y = x;
    for _ in 0..6 {
        a.process(&[0.001; 1024], &mut x).unwrap();
        b.process(&[0.001; 1024], &mut y).unwrap();
        assert_eq!(x, y);
    }
}

#[test]
#[ignore = "requires private HRIR bank through BAKA_AV3A_HRIR_BANK"]
fn measured_room_motion_matches_analytic_geometry_and_explicit_dsp() {
    moving_oracle(
        HrirBank::from_bytes(
            &std::fs::read(std::env::var("BAKA_AV3A_HRIR_BANK").unwrap()).unwrap(),
        )
        .unwrap(),
    );
}

#[test]
fn maximum_room_uses_144_internal_paths_while_public_point_limit_stays_sixteen() {
    let bank = bank();
    let layout = bands(48000);
    let mut surfaces = vec![];
    for side in 0..8 {
        let a = std::f64::consts::TAU * side as f64 / 8.;
        let b = std::f64::consts::TAU * (side + 1) as f64 / 8.;
        let (x, y) = (4. * a.cos(), 4. * a.sin());
        let (u, v) = (4. * b.cos(), 4. * b.sin());
        surfaces.push(
            AcousticSurface::new(
                &[[x, y, -4.], [u, v, -4.], [u, v, 4.], [x, y, 4.]],
                material(),
            )
            .unwrap(),
        );
    }
    let room = AcousticRoom::new(surfaces).unwrap();
    let positions = [[0., 1., 0.]; 16];
    let mut many = EarlyRoomBinauralRenderer::new(
        room.clone(),
        &layout,
        bank.clone(),
        &positions,
        ListenerPose::default(),
        config(),
    )
    .unwrap();
    let mut one = EarlyRoomBinauralRenderer::new(
        room,
        &layout,
        bank.clone(),
        &positions[..1],
        ListenerPose::default(),
        config(),
    )
    .unwrap();
    assert_eq!(many.paths_per_source(), 9);
    let mut a = [0.; 2048];
    let mut b = a;
    for block in 0..6 {
        let listener = ListenerPose::new(
            [0.01 * (block % 2) as f64, 0., 0.],
            HeadOrientation::from_yaw_pitch_roll(block as f64 * 7., 0., 0.).unwrap(),
        )
        .unwrap();
        many.set_listener(listener, false).unwrap();
        one.set_listener(listener, false).unwrap();
        let mono: Vec<_> = (0..1024)
            .map(|i| ((i * 37 % 101) as f32 - 50.) * 1e-5)
            .collect();
        let interleaved: Vec<_> = mono.iter().flat_map(|v| [*v; 16]).collect();
        many.process(&interleaved, &mut a).unwrap();
        one.process(&mono, &mut b).unwrap();
        for value in &mut b {
            *value *= 16.;
        }
        close(&a, &b, 3e-7);
    }
    many.reset();
    for _ in 0..3 {
        many.process_silence(&mut a).unwrap();
    }
    assert!(a.iter().all(|v| *v == 0.));
    assert!(BinauralRenderer::new(bank, 48000, &[BinauralSource::default(); 17]).is_err());
}
