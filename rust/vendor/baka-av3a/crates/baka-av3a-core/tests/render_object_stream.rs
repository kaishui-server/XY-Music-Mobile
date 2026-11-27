use baka_av3a_core::render::{
    BedLayout, GainRenderer, ObjectProjector, ObjectRenderer, PolarObject,
};

#[test]
fn pure_objects_match_a_silent_bed_and_updates_are_atomic() {
    let objects = [
        PolarObject {
            azimuth: 45.0,
            width: 90.0,
            height: 45.0,
            diffuse: 0.7,
            ..PolarObject::default()
        },
        PolarObject {
            azimuth: -90.0,
            ..PolarObject::default()
        },
    ];
    let layout = BedLayout::Surround714;
    let mut pure = ObjectRenderer::new(None, layout, &objects).unwrap();
    let mut mixed = ObjectRenderer::new(Some(BedLayout::Stereo), layout, &objects).unwrap();
    let mut input = vec![0; 4096 * 2];
    for (i, v) in input.iter_mut().enumerate() {
        *v = ((i * 97 % 16001) as i32 - 8000) as i16;
    }
    let with_bed: Vec<_> = input
        .as_chunks::<2>()
        .0
        .iter()
        .flat_map(|f| [0, 0, f[0], f[1]])
        .collect();
    let mut a = vec![0.0; 4096 * 12];
    let mut b = a.clone();
    pure.process(&input, &mut a).unwrap();
    mixed.process(&with_bed, &mut b).unwrap();
    assert_eq!(a, b);
    assert_eq!(pure.input_channels(), 2);
    assert_eq!(mixed.input_channels(), 4);
    assert_eq!(pure.object_count(), 2);
    assert_eq!(pure.output_layout(), layout);
    let mut reference = pure.clone();
    let changed = PolarObject {
        azimuth: 120.0,
        ..objects[0]
    };
    let invalid = PolarObject {
        gain: f64::NAN,
        ..objects[1]
    };
    assert!(pure.set_objects(&[changed, invalid]).is_err());
    assert!(pure.set_objects(&[changed]).is_err());
    pure.process(&input, &mut a).unwrap();
    reference.process(&input, &mut b).unwrap();
    assert_eq!(a, b);
    pure.set_objects(&[changed, objects[1]]).unwrap();
    reference.set_objects(&[changed, objects[1]]).unwrap();
    pure.process(&input, &mut a).unwrap();
    for (chunk, output) in input.chunks(137 * 2).zip(b.chunks_mut(137 * 12)) {
        reference.process(chunk, output).unwrap();
    }
    assert_eq!(a, b);
    pure.reset();
    let mut fresh = ObjectRenderer::new(None, layout, &[changed, objects[1]]).unwrap();
    pure.process(&input, &mut a).unwrap();
    fresh.process(&input, &mut b).unwrap();
    assert_eq!(a, b);
    pure.process_silence(4096, &mut a).unwrap();
    fresh.process_silence(4096, &mut b).unwrap();
    assert_eq!(a, b);
}

#[test]
fn projection_reuses_vectors_and_rejects_invalid_parameters() {
    let p = ObjectProjector::new(BedLayout::Stereo).unwrap();
    let mut g = p.project(PolarObject::default()).unwrap();
    assert_eq!(p.output_layout(), BedLayout::Stereo);
    let before = (g.direct().to_vec(), g.diffuse().to_vec());
    let reference = PolarObject::default();
    for object in [
        PolarObject {
            azimuth: f64::NAN,
            ..reference
        },
        PolarObject {
            elevation: 91.0,
            ..reference
        },
        PolarObject {
            distance: -1.0,
            ..reference
        },
        PolarObject {
            distance: f64::INFINITY,
            ..reference
        },
        PolarObject {
            width: 361.0,
            ..reference
        },
        PolarObject {
            height: 361.0,
            ..reference
        },
        PolarObject {
            depth: -0.1,
            ..reference
        },
        PolarObject {
            gain: 16.1,
            ..reference
        },
        PolarObject {
            diffuse: 1.01,
            ..reference
        },
    ] {
        assert!(p.project(object).is_err());
        assert!(p.project_into(object, &mut g).is_err());
        assert_eq!(g.direct(), before.0);
        assert_eq!(g.diffuse(), before.1);
    }
    let change = PolarObject {
        azimuth: 120.0,
        width: 45.0,
        diffuse: 0.5,
        ..reference
    };
    let expected = p.project(change).unwrap();
    p.clone().project_into(change, &mut g).unwrap();
    assert_eq!(g.direct(), expected.direct());
    assert_eq!(g.diffuse(), expected.diffuse());
    assert!(
        ObjectProjector::new(BedLayout::Surround51)
            .unwrap()
            .project_into(change, &mut g)
            .is_err()
    );
    let a = p
        .project(PolarObject {
            azimuth: 35.0,
            ..reference
        })
        .unwrap();
    let b = p
        .project(PolarObject {
            azimuth: 395.0,
            ..reference
        })
        .unwrap();
    assert_eq!(a.direct(), b.direct());
    for distance in [0.0, 0.001, 0.1, 1.0, 1e6] {
        let object = PolarObject {
            distance,
            height: 360.0,
            width: 360.0,
            depth: 1e6,
            ..reference
        };
        let gains = p.project(object).unwrap();
        assert!(gains.direct().iter().all(|v| v.is_finite()));
    }
}

#[test]
fn object_and_gain_renderers_compose_identically() {
    let object = PolarObject {
        azimuth: -45.0,
        elevation: 45.0,
        width: 120.0,
        height: 60.0,
        depth: 0.5,
        diffuse: 0.6,
        ..PolarObject::default()
    };
    let layout = BedLayout::Surround512;
    let projector = ObjectProjector::new(layout).unwrap();
    let gains = projector.project(object).unwrap();
    let mut lower = GainRenderer::new(None, layout, &[gains]).unwrap();
    let mut upper = ObjectRenderer::new(None, layout, &[object]).unwrap();
    let mut a = vec![0.0; 4096 * 8];
    let mut b = a.clone();
    let input = vec![8192; 4096];
    lower.process(&input, &mut a).unwrap();
    upper.process(&input, &mut b).unwrap();
    assert_eq!(a, b);
    assert!(ObjectRenderer::new(None, layout, &[]).is_err());
    assert!(ObjectRenderer::new(Some(BedLayout::Stereo), layout, &[object; 15]).is_err());
    assert!(ObjectRenderer::new(None, layout, &[object; 17]).is_err());
    use baka_av3a_core::Profile;
    assert!(
        ObjectRenderer::from_profile(Profile::Objects { count: 2 }, layout, &[object]).is_err()
    );
    assert!(
        ObjectRenderer::from_profile(Profile::ChannelBed { configuration: 1 }, layout, &[object])
            .is_err()
    );
    assert!(ObjectRenderer::from_profile(Profile::Hoa { order: 1 }, layout, &[]).is_err());
    let mixed = ObjectRenderer::from_profile(
        Profile::BedObjects {
            configuration: 1,
            objects: 1,
        },
        layout,
        &[object],
    )
    .unwrap();
    assert_eq!(mixed.input_channels(), 3);
    let pure =
        ObjectRenderer::from_profile(Profile::Objects { count: 1 }, layout, &[object]).unwrap();
    assert_eq!(pure.input_channels(), 1);
}
