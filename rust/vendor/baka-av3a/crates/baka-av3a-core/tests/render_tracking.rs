use baka_av3a_core::render::{
    BinauralRenderer, BinauralSource, HeadOrientation, HrirBank, ListenerPose, SourceSpace,
    TrackedBinauralRenderer, TrackedSource,
};
fn bank() -> HrirBank {
    HrirBank::from_bytes(include_bytes!("fixtures/synthetic_hrir.bin")).unwrap()
}
fn pose(yaw: f64, pitch: f64, roll: f64, position: [f64; 3]) -> ListenerPose {
    ListenerPose::new(
        position,
        HeadOrientation::from_yaw_pitch_roll(yaw, pitch, roll).unwrap(),
    )
    .unwrap()
}
fn signal() -> Vec<f32> {
    (0..3072)
        .map(|i| ((i * 1597 + 113) % 8192) as f32 / 32768.0 - 0.125)
        .collect()
}
fn equivalent(a: [f64; 4], b: [f64; 4]) {
    let dot = a.iter().zip(b).map(|(a, b)| a * b).sum::<f64>().abs();
    assert!((dot - 1.0).abs() < 1e-12, "q{a:?} !={b:?}");
}
#[test]
fn independent_pose_rotation_and_shortest_path_slerp_vectors() {
    let fixture = include_bytes!("fixtures/head_tracking.bin");
    assert_eq!(&fixture[..8], b"HTRK0001");
    let count = u32::from_le_bytes(fixture[8..12].try_into().unwrap()) as usize;
    assert_eq!(fixture.len(), 12 + count * 248);
    let mut peak = 0.0_f64;
    for row in fixture[12..].as_chunks::<248>().0 {
        let v: Vec<_> = row
            .as_chunks::<8>()
            .0
            .iter()
            .map(|v| f64::from_le_bytes(*v))
            .collect();
        let orientation = HeadOrientation::from_yaw_pitch_roll(v[0], v[1], v[2]).unwrap();
        equivalent(orientation.quaternion(), v[3..7].try_into().unwrap());
        let listener = ListenerPose::new(v[7..10].try_into().unwrap(), orientation).unwrap();
        let source: [f64; 3] = v[10..13].try_into().unwrap();
        for (a, b) in listener
            .relative_position(source)
            .unwrap()
            .iter()
            .zip(&v[13..16])
        {
            let delta = (a - b).abs();
            peak = peak.max(delta);
            assert!(delta < 1e-10);
        }
        let other = HeadOrientation::new(v[16..20].try_into().unwrap()).unwrap();
        let fraction = v[20];
        let next = ListenerPose::new(v[25..28].try_into().unwrap(), other).unwrap();
        let interpolated = listener.interpolate(next, fraction).unwrap();
        equivalent(
            interpolated.orientation().quaternion(),
            v[21..25].try_into().unwrap(),
        );
        for (a, b) in interpolated.position().iter().zip(&v[28..31]) {
            assert!((a - b).abs() < 1e-12);
        }
        let vector = orientation.head_to_world(source).unwrap();
        for (a, b) in orientation
            .world_to_head(vector)
            .unwrap()
            .into_iter()
            .zip(source)
        {
            assert!((a - b).abs() < 1e-10);
        }
    }
    eprintln!("{count} independent tracking poses/SLERP cases max position error{peak:e}");
}

#[test]
fn axes_head_lock_translation_and_quaternion_validation() {
    let front = TrackedSource {
        position: [0., 1., 0.],
        space: SourceSpace::World,
        gain: 1.,
    };
    let left = front.binaural(pose(90., 0., 0., [0.; 3])).unwrap();
    assert!((left.azimuth + 90.).abs() < 1e-12);
    assert!(left.elevation.abs() < 1e-12);
    let up = front.binaural(pose(0., 90., 0., [0.; 3])).unwrap();
    assert!((up.elevation + 90.).abs() < 1e-12);
    let translated = front.binaural(pose(0., 0., 0., [1., 0., 0.])).unwrap();
    assert!((translated.azimuth - 45.).abs() < 1e-12);
    let head = TrackedSource {
        space: SourceSpace::HeadLocked,
        ..front
    };
    assert_eq!(
        head.binaural(pose(80., 20., 30., [5., 6., 7.])).unwrap(),
        BinauralSource::default()
    );
    let zero = TrackedSource {
        position: [0.; 3],
        ..front
    };
    assert_eq!(
        zero.binaural(ListenerPose::default()).unwrap(),
        BinauralSource::default()
    );
    let roll = HeadOrientation::from_yaw_pitch_roll(0., 0., 90.)
        .unwrap()
        .head_to_world([1., 0., 0.])
        .unwrap();
    assert!((roll[2] + 1.).abs() < 1e-12);
    let a = HeadOrientation::from_yaw_pitch_roll(179., 0., 0.).unwrap();
    let b = HeadOrientation::from_yaw_pitch_roll(-179., 0., 0.).unwrap();
    let center = a
        .interpolate(b, 0.5)
        .unwrap()
        .head_to_world([0., 1., 0.])
        .unwrap();
    assert!((center[1] + 1.).abs() < 1e-12);
    let opposite = HeadOrientation::new(a.quaternion().map(|v| -v)).unwrap();
    equivalent(
        a.interpolate(opposite, 0.5).unwrap().quaternion(),
        a.quaternion(),
    );
    for scale in [f64::MIN_POSITIVE, f64::MAX, 1e-300] {
        let q = HeadOrientation::new([scale; 4]).unwrap();
        assert!(q.quaternion().iter().all(|v| v.is_finite()));
        assert!((q.quaternion()[0] - 0.5).abs() < 1e-12);
    }
    for q in [[0.; 4], [f64::NAN, 0., 0., 0.], [1., f64::INFINITY, 0., 0.]] {
        assert!(HeadOrientation::new(q).is_err());
    }
    for fraction in [f64::NAN, -0.01, 1.01] {
        assert!(a.interpolate(b, fraction).is_err());
        assert!(
            ListenerPose::default()
                .interpolate(ListenerPose::default(), fraction)
                .is_err()
        );
    }
    for coordinate in [f64::NAN, f64::INFINITY, 1e6 + 1.] {
        let p = [coordinate, 0., 0.];
        assert!(ListenerPose::new(p, a).is_err());
        assert!(
            TrackedSource {
                position: p,
                ..front
            }
            .binaural(ListenerPose::default())
            .is_err()
        );
    }
    assert!(HeadOrientation::from_yaw_pitch_roll(f64::NAN, 0., 0.).is_err());
    for bad in [
        [f64::NAN, 0.0, 0.0],
        [f64::INFINITY, 0.0, 0.0],
        [4e6 + 1.0, 0.0, 0.0],
    ] {
        assert!(a.head_to_world(bad).is_err());
        assert!(a.world_to_head(bad).is_err());
    }
    let vector = [1e6; 3];
    let rotated = a.head_to_world(vector).unwrap();
    for (actual, expected) in a.world_to_head(rotated).unwrap().into_iter().zip(vector) {
        assert!((actual - expected).abs() < 1e-8);
    }
    assert!(
        TrackedSource { gain: 17., ..front }
            .binaural(ListenerPose::default())
            .is_err()
    );
}

fn compare(bank: HrirBank) {
    let sources = [
        TrackedSource {
            position: [0., 2., 0.],
            space: SourceSpace::World,
            gain: 0.5,
        },
        TrackedSource {
            position: [-2., 0., 0.5],
            space: SourceSpace::World,
            gain: 0.25,
        },
        TrackedSource {
            position: [1., 1., 0.],
            space: SourceSpace::HeadLocked,
            gain: 0.5,
        },
    ];
    let mut actual = TrackedBinauralRenderer::new(
        bank.clone(),
        bank.sample_rate(),
        ListenerPose::default(),
        &sources,
    )
    .unwrap();
    let initial: Vec<_> = sources
        .iter()
        .map(|&s| s.binaural(ListenerPose::default()).unwrap())
        .collect();
    let mut explicit = BinauralRenderer::new(bank.clone(), bank.sample_rate(), &initial).unwrap();
    let mut a = vec![0.; 2048];
    let mut b = a.clone();
    for (i, next) in [
        ListenerPose::default(),
        pose(90., 0., 0., [0.; 3]),
        pose(-90., 20., 30., [0.5, 0., 0.]),
        pose(179., -30., -40., [0., 0.25, -0.25]),
    ]
    .into_iter()
    .enumerate()
    {
        let targets: Vec<_> = sources.iter().map(|&s| s.binaural(next).unwrap()).collect();
        actual.set_listener(next, i % 2 == 1).unwrap();
        explicit.set_sources(&targets, &[i % 2 == 1; 3]).unwrap();
        actual.process(&signal(), &mut a).unwrap();
        explicit.process(&signal(), &mut b).unwrap();
        assert_eq!(a, b);
        assert_eq!(actual.listener(), next);
        assert_eq!(actual.resolved_sources()[2], initial[2]);
        let mut clone = actual.clone();
        let before = actual.sources().to_vec();
        let mut bad = sources;
        bad[2].position[0] = f64::NAN;
        assert!(
            actual
                .set_scene(ListenerPose::default(), &bad, &[true; 3])
                .is_err()
        );
        assert_eq!(actual.sources(), before);
        assert_eq!(actual.listener(), next);
        assert!(actual.set_scene(next, &sources[..2], &[false; 2]).is_err());
        a.fill(42.);
        let mut bad = signal();
        bad[0] = f32::NAN;
        assert!(actual.process(&bad, &mut a).is_err());
        assert!(a.iter().all(|v| *v == 42.));
        actual.process(&signal(), &mut a).unwrap();
        clone.process(&signal(), &mut b).unwrap();
        assert_eq!(a, b);
        explicit.process(&signal(), &mut b).unwrap();
        assert_eq!(a, b);
    }
    let moved = [
        TrackedSource {
            position: [-1., 1., 1.],
            gain: 0.2,
            ..sources[0]
        },
        sources[1],
        sources[2],
    ];
    actual
        .set_scene(ListenerPose::default(), &moved, &[false; 3])
        .unwrap();
    let targets: Vec<_> = moved
        .iter()
        .map(|&s| s.binaural(ListenerPose::default()).unwrap())
        .collect();
    explicit.set_sources(&targets, &[false; 3]).unwrap();
    actual.process(&signal(), &mut a).unwrap();
    explicit.process(&signal(), &mut b).unwrap();
    assert_eq!(a, b);
    for _ in 0..3 {
        actual.process_silence(&mut a).unwrap();
        explicit.process_silence(&mut b).unwrap();
        assert_eq!(a, b);
    }
    actual.reset();
    let mut fresh = TrackedBinauralRenderer::new(
        bank.clone(),
        bank.sample_rate(),
        actual.listener(),
        actual.sources(),
    )
    .unwrap();
    actual.process(&signal(), &mut a).unwrap();
    fresh.process(&signal(), &mut b).unwrap();
    assert_eq!(a, b);
    assert_eq!(actual.tail_samples(), bank.tap_count() - 1 + 99);
}
#[test]
fn tracked_binaural_pcm_matches_explicit_listener_coordinates() {
    compare(bank());
}
#[test]
#[ignore = "requires private measured HRIR bank in BAKA_AV3A_HRIR_BANK"]
fn measured_tracked_binaural_pcm() {
    compare(
        HrirBank::from_bytes(
            &std::fs::read(std::env::var("BAKA_AV3A_HRIR_BANK").unwrap()).unwrap(),
        )
        .unwrap(),
    );
}
