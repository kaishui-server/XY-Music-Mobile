use baka_av3a_core::render::{
    BedLayout, ObjectProjector, PolarControls, PolarObject, SpatialObject,
};
#[path = "fixtures/control_vectors.rs"]
mod fixtures;

#[test]
fn independent_spatial_control_vectors() {
    let mut maximum = 0.0f64;
    for config in [1, 2, 3, 7, 8, 9, 10] {
        let layout = BedLayout::from_configuration(config).unwrap();
        let projector = ObjectProjector::new(layout).unwrap();
        for (index, v) in fixtures::VECTORS
            .iter()
            .enumerate()
            .filter(|(_, v)| v.layout == config)
        {
            let p = v.object;
            let object = SpatialObject {
                object: PolarObject {
                    azimuth: p[0],
                    elevation: p[1],
                    distance: p[2],
                    width: p[3],
                    height: p[4],
                    depth: p[5],
                    gain: p[6],
                    diffuse: p[7],
                },
                controls: PolarControls {
                    channel_lock: (v.controls[0] >= 0.0).then_some(v.controls[0]),
                    divergence: v.controls[1],
                    azimuth_range: v.controls[2],
                },
            };
            let actual = projector.project_controlled(object).unwrap();
            for (&a, &b) in actual
                .direct()
                .iter()
                .zip(&v.direct)
                .chain(actual.diffuse().iter().zip(&v.diffuse))
            {
                let error = (f64::from(a) - b).abs();
                maximum = maximum.max(error);
                assert!(
                    error < 2e-6,
                    "vector={index} layout={layout:?} error={error} actual={a} expected={b}"
                );
            }
        }
    }
    println!(
        "vectors={} max_abs_error={maximum}",
        fixtures::VECTORS.len()
    );
}

#[test]
fn controls_are_validated_atomically_and_preserve_power() {
    let projector = ObjectProjector::new(BedLayout::Surround714).unwrap();
    let object = PolarObject {
        azimuth: 23.0,
        elevation: 40.0,
        gain: 2.0,
        diffuse: 0.4,
        ..Default::default()
    };
    let mut gains = projector.project(object).unwrap();
    let original = (gains.direct().to_vec(), gains.diffuse().to_vec());
    for controls in [
        PolarControls {
            divergence: f64::NAN,
            ..Default::default()
        },
        PolarControls {
            divergence: 1.1,
            ..Default::default()
        },
        PolarControls {
            channel_lock: Some(-0.1),
            ..Default::default()
        },
        PolarControls {
            channel_lock: Some(f64::INFINITY),
            ..Default::default()
        },
        PolarControls {
            azimuth_range: 181.0,
            ..Default::default()
        },
    ] {
        assert!(
            projector
                .project_controlled_into(SpatialObject { object, controls }, &mut gains)
                .is_err()
        );
        assert_eq!(gains.direct(), original.0);
        assert_eq!(gains.diffuse(), original.1);
    }
    projector
        .project_controlled_into(
            SpatialObject {
                object,
                controls: PolarControls {
                    divergence: 0.6,
                    azimuth_range: 70.0,
                    channel_lock: None,
                },
            },
            &mut gains,
        )
        .unwrap();
    let power: f64 = gains
        .direct()
        .iter()
        .chain(gains.diffuse())
        .map(|&v| f64::from(v).powi(2))
        .sum();
    assert!((power - 4.0).abs() < 1e-6);
    assert_eq!(gains.direct()[3], 0.0); // never route an object into the LFE
    let controls = PolarControls {
        channel_lock: Some(2.0),
        divergence: 0.5,
        azimuth_range: 45.0,
    };
    let a = projector
        .project_controlled(SpatialObject { object, controls })
        .unwrap();
    let b = projector
        .project_controlled(SpatialObject {
            object: PolarObject {
                azimuth: object.azimuth + 360.0,
                ..object
            },
            controls,
        })
        .unwrap();
    assert_eq!(a.direct(), b.direct());
    assert_eq!(a.diffuse(), b.diffuse());
    let extreme = projector
        .project_controlled(SpatialObject {
            object: PolarObject {
                azimuth: f64::MAX,
                ..object
            },
            controls,
        })
        .unwrap();
    assert!(
        extreme
            .direct()
            .iter()
            .chain(extreme.diffuse())
            .all(|v| v.is_finite())
    );
}

#[test]
fn every_quantized_divergence_code_is_accepted() {
    use baka_av3a_core::{
        Profile,
        metadata::{
            ChannelLock, DynamicMetadata, DynamicObject, ObjectDivergence, ObjectParameters,
            ObjectPosition, SpatialControls,
        },
        render::DynamicObjectRenderer,
    };
    let mut renderer = DynamicObjectRenderer::new(
        Profile::Objects { count: 1 },
        BedLayout::Stereo,
        &[0],
        &[PolarObject::default()],
    )
    .unwrap();
    let mut data = DynamicMetadata {
        level: 1,
        objects: vec![DynamicObject {
            transport_channel: 0,
            parameters: Some(ObjectParameters {
                position: ObjectPosition::Spherical([0, 0, 15]),
                extent: None,
                gain: None,
                diffuse: None,
                jump_position: false,
                importance: None,
                controls: Some(SpatialControls {
                    channel_lock: Some(ChannelLock::Within(15)),
                    divergence: None,
                    screen_reference: None,
                    screen_edge_lock: None,
                }),
            }),
        }],
    };
    let mut output = vec![0.0; 2048];
    for amount in 0..16 {
        for range in 0..64 {
            data.objects[0]
                .parameters
                .as_mut()
                .unwrap()
                .controls
                .as_mut()
                .unwrap()
                .divergence = Some(ObjectDivergence {
                amount,
                azimuth_range: (amount != 0).then_some(range),
            });
            renderer
                .process(&[0; 1024], Some(&data), &mut output)
                .unwrap();
        }
    }
}

#[test]
fn controlled_object_audio_updates_invalidate_cache_and_rollback_on_error() {
    use baka_av3a_core::render::{GainRenderer, ObjectGains, ObjectRenderer};
    let layout = BedLayout::Surround714;
    let first = fixtures::VECTORS
        .iter()
        .find(|v| v.layout == 10 && v.controls[1] > 0.0 && v.controls[2] > 0.0)
        .unwrap();
    let p = first.object;
    let object = PolarObject {
        azimuth: p[0],
        elevation: p[1],
        distance: p[2],
        width: p[3],
        height: p[4],
        depth: p[5],
        gain: p[6],
        diffuse: p[7],
    };
    let mut controlled = SpatialObject {
        object,
        controls: PolarControls {
            channel_lock: (first.controls[0] >= 0.0).then_some(first.controls[0]),
            divergence: first.controls[1],
            azimuth_range: first.controls[2],
        },
    };
    let mut actual = ObjectRenderer::new(None, layout, &[object]).unwrap();
    actual.set_controlled_objects(&[controlled]).unwrap();
    let expected_gains = ObjectGains::new(
        first.direct.map(|v| v as f32).to_vec(),
        first.diffuse.map(|v| v as f32).to_vec(),
    )
    .unwrap();
    let mut expected = GainRenderer::new(None, layout, &[expected_gains]).unwrap();
    let input: Vec<i16> = (0..1024)
        .map(|i| ((i * 539) % 8192 - 4096) as i16)
        .collect();
    let mut a = vec![0.0; 12288];
    let mut b = a.clone();
    for _ in 0..5 {
        actual.process(&input, &mut a).unwrap();
        expected.process(&input, &mut b).unwrap();
        assert!(a.iter().zip(&b).all(|(a, b)| (a - b).abs() < 2e-6));
    }
    let mut saved = actual.clone();
    controlled.controls.divergence = f64::NAN;
    assert!(actual.set_controlled_objects(&[controlled]).is_err());
    actual.process(&input, &mut a).unwrap();
    saved.process(&input, &mut b).unwrap();
    assert_eq!(a, b);
    actual.set_objects(&[object]).unwrap(); // clearing controls must also invalidate the cache
    let base = ObjectProjector::new(layout)
        .unwrap()
        .project(object)
        .unwrap();
    expected.process(&input, &mut b).unwrap(); // align with the rollback verification block
    expected.set_objects(&[base]).unwrap();
    for _ in 0..5 {
        actual.process(&input, &mut a).unwrap();
        expected.process(&input, &mut b).unwrap();
        assert!(a.iter().zip(&b).all(|(a, b)| (a - b).abs() < 2e-6));
    }
}
