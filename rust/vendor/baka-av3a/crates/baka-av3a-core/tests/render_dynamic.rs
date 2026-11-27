use baka_av3a_core::{
    Profile,
    metadata::{
        ChannelLock, DynamicMetadata, DynamicObject, ObjectParameters, ObjectPosition,
        SpatialControls,
    },
    render::{BedLayout, DynamicObjectRenderer, ObjectRenderer, PolarObject},
};

fn parameters(position: [i16; 3]) -> ObjectParameters {
    ObjectParameters {
        position: ObjectPosition::Spherical(position),
        extent: None,
        gain: None,
        diffuse: None,
        jump_position: false,
        importance: None,
        controls: None,
    }
}
fn object(reference: u8, parameters: Option<ObjectParameters>) -> DynamicObject {
    DynamicObject {
        transport_channel: reference,
        parameters,
    }
}
fn metadata(objects: Vec<DynamicObject>) -> DynamicMetadata {
    DynamicMetadata { level: 0, objects }
}
fn defaults() -> [PolarObject; 2] {
    [
        PolarObject {
            azimuth: -30.0,
            gain: 0.8,
            diffuse: 0.25,
            width: 10.0,
            ..Default::default()
        },
        PolarObject {
            azimuth: 45.0,
            gain: 0.4,
            ..Default::default()
        },
    ]
}
fn renderer() -> DynamicObjectRenderer {
    DynamicObjectRenderer::new(
        Profile::BedObjects {
            configuration: 1,
            objects: 2,
        },
        BedLayout::Surround714,
        &[29, 3],
        &defaults(),
    )
    .unwrap()
}
fn input() -> Vec<i16> {
    (0..4096)
        .map(|i| ((i * 1337 + 42) % 32768 - 16384) as i16)
        .collect()
}

#[test]
fn reordered_references_match_manual_pcm_and_absent_blocks_hold_targets() {
    let mut actual = renderer();
    let mut expected =
        ObjectRenderer::new(Some(BedLayout::Stereo), BedLayout::Surround714, &defaults()).unwrap();
    let mut p = parameters([64, 16, 6]);
    p.extent = Some([127, 31, 15]);
    p.gain = Some(127);
    p.diffuse = Some(127);
    let data = metadata(vec![object(3, None), object(29, Some(p.clone()))]);
    let [azimuth, elevation, distance] = p.position.coordinates();
    let [width, height, depth] = p.extent_values().unwrap();
    let targets = [
        PolarObject {
            azimuth: azimuth.into(),
            elevation: elevation.into(),
            distance: distance.into(),
            width: f64::from(width).min(360.0),
            height: f64::from(height).min(360.0),
            depth: depth.into(),
            gain: p.linear_gain().unwrap().into(),
            diffuse: p.diffuseness().unwrap().into(),
        },
        PolarObject {
            gain: 0.0,
            ..defaults()[1]
        },
    ];
    let mut a = vec![0.0; 12288];
    let mut b = a.clone();
    expected.set_objects(&targets).unwrap();
    actual.process(&input(), Some(&data), &mut a).unwrap();
    expected.process(&input(), &mut b).unwrap();
    assert_eq!(
        actual
            .objects()
            .iter()
            .map(|o| o.polar().unwrap().object)
            .collect::<Vec<_>>(),
        targets
    );
    assert_eq!(a, b);
    for _ in 0..6 {
        actual.process(&input(), None, &mut a).unwrap();
        expected.process(&input(), &mut b).unwrap();
        assert_eq!(a, b);
    }
    for _ in 0..4 {
        actual.process_silence(&mut a).unwrap();
        expected.process_silence(1024, &mut b).unwrap();
        assert_eq!(a, b);
    }
    // Unmute with omitted fields: use explicit defaults, not the last full block.
    let data = metadata(vec![
        object(29, Some(parameters([0, 0, 15]))),
        object(3, Some(parameters([-21, 0, 15]))),
    ]);
    actual.process(&input(), Some(&data), &mut a).unwrap();
    assert_eq!(
        actual.objects()[0].polar().unwrap().object.gain,
        defaults()[0].gain
    );
    assert_eq!(
        actual.objects()[0].polar().unwrap().object.width,
        defaults()[0].width
    );
    assert_eq!(
        actual.objects()[0].polar().unwrap().object.diffuse,
        defaults()[0].diffuse
    );
    assert_eq!(
        actual.objects()[1].polar().unwrap().object.gain,
        defaults()[1].gain
    );
}

#[test]
fn invalid_updates_and_lengths_preserve_output_targets_and_history() {
    let mut actual = renderer();
    let mut a = vec![0.0; 12288];
    actual.process(&input(), None, &mut a).unwrap();
    let mut control = actual.clone();
    let mut bad = vec![
        metadata(vec![]),
        metadata(vec![object(29, None), object(29, None)]),
        metadata(vec![object(29, None), object(31, None)]),
    ];
    for p in [
        ObjectParameters {
            position: ObjectPosition::Cartesian([128, 0, 0]),
            ..parameters([0, 0, 15])
        },
        ObjectParameters {
            importance: Some(11),
            ..parameters([0, 0, 15])
        },
        ObjectParameters {
            gain: Some(128),
            ..parameters([0, 0, 15])
        },
        ObjectParameters {
            extent: Some([0, 32, 0]),
            ..parameters([0, 0, 15])
        },
        ObjectParameters {
            diffuse: Some(128),
            ..parameters([0, 0, 15])
        },
        ObjectParameters {
            controls: Some(SpatialControls {
                channel_lock: Some(ChannelLock::Within(16)),
                divergence: None,
                screen_reference: None,
                screen_edge_lock: None,
            }),
            ..parameters([0, 0, 15])
        },
        parameters([0, -33, 15]),
        parameters([0, 0, 16]),
        parameters([128, 0, 15]),
        ObjectParameters {
            controls: Some(SpatialControls {
                channel_lock: None,
                divergence: None,
                screen_reference: None,
                screen_edge_lock: Some(0),
            }),
            ..parameters([0, 0, 15])
        },
    ] {
        // First valid item must not commit when a later item fails.
        bad.push(metadata(vec![
            object(29, Some(parameters([64, 0, 15]))),
            object(3, Some(p)),
        ]));
    }
    bad.push(DynamicMetadata {
        level: 2,
        objects: vec![object(29, None), object(3, None)],
    });
    for data in &bad {
        a.fill(42.0);
        assert!(actual.process(&input(), Some(data), &mut a).is_err());
        assert!(a.iter().all(|&v| v == 42.0));
        assert_eq!(actual.objects(), control.objects());
    }
    for n in [0, 1, 4095, 4097, 8192] {
        assert!(actual.process(&vec![0; n], None, &mut a).is_err());
    }
    for n in [0, 1, 12287, 12289] {
        let mut output = vec![42.0; n];
        assert!(actual.process(&input(), None, &mut output).is_err());
        assert!(actual.process_silence(&mut output).is_err());
        assert!(output.iter().all(|&v| v == 42.0));
    }
    let mut b = a.clone();
    for _ in 0..5 {
        actual.process(&input(), None, &mut a).unwrap();
        control.process(&input(), None, &mut b).unwrap();
        assert_eq!(a, b);
    }
}

#[test]
fn reset_binding_limits_and_offset_binary_south_pole() {
    let mut actual = renderer();
    let data = metadata(vec![
        object(3, None),
        object(29, Some(parameters([-128, -32, 0]))),
    ]);
    let mut a = vec![0.0; 12288];
    actual.process(&input(), Some(&data), &mut a).unwrap();
    let original = parameters([-128, -32, 0]).position.coordinates();
    let reflected = actual.objects()[0].polar().unwrap().object;
    for (az, el) in [
        (f64::from(original[0]), f64::from(original[1])),
        (reflected.azimuth, reflected.elevation),
    ] {
        let direction = [
            az.to_radians().sin() * el.to_radians().cos(),
            az.to_radians().cos() * el.to_radians().cos(),
            el.to_radians().sin(),
        ];
        let target = [
            reflected.azimuth.to_radians().sin() * reflected.elevation.to_radians().cos(),
            reflected.azimuth.to_radians().cos() * reflected.elevation.to_radians().cos(),
            reflected.elevation.to_radians().sin(),
        ];
        for (a, b) in direction.into_iter().zip(target) {
            assert!((a - b).abs() < 1e-14);
        }
    }
    actual.reset().unwrap();
    let mut fresh = renderer();
    let mut b = a.clone();
    for _ in 0..4 {
        actual.process(&input(), None, &mut a).unwrap();
        fresh.process(&input(), None, &mut b).unwrap();
        assert_eq!(a, b);
    }
    for refs in [&[3, 3][..], &[32, 3], &[3], &[]] {
        assert!(
            DynamicObjectRenderer::new(
                Profile::Objects { count: 2 },
                BedLayout::Stereo,
                refs,
                &defaults()
            )
            .is_err()
        );
    }
    assert!(
        DynamicObjectRenderer::new(Profile::Hoa { order: 1 }, BedLayout::Stereo, &[], &[]).is_err()
    );
}

#[test]
fn sixteen_objects_and_bed_only_use_the_same_frame_contract() {
    let defaults = [PolarObject::default(); 16];
    let refs: Vec<u8> = (16..32).collect();
    let mut renderer = DynamicObjectRenderer::new(
        Profile::Objects { count: 16 },
        BedLayout::Stereo,
        &refs,
        &defaults,
    )
    .unwrap();
    let data = metadata(
        (16..32)
            .rev()
            .map(|r| object(r, Some(parameters([(i16::from(r) - 24) * 15, 0, 15]))))
            .collect(),
    );
    let input = vec![1024; 16 * 1024];
    let mut output = vec![0.0; 2048];
    renderer.process(&input, Some(&data), &mut output).unwrap();
    for (i, target) in renderer.objects().iter().enumerate() {
        let value = target.polar().unwrap().object;
        assert_eq!(
            value.azimuth,
            f64::from(
                parameters([(i as i16 - 8) * 15, 0, 15])
                    .position
                    .coordinates()[0]
            )
        );
    }
    for _ in 0..5 {
        renderer.process(&input, None, &mut output).unwrap();
    }
    assert!(output.iter().all(|v| v.is_finite()));
    assert!(output.iter().any(|v| *v != 0.0));
    let mut bed = DynamicObjectRenderer::new(
        Profile::ChannelBed { configuration: 1 },
        BedLayout::Stereo,
        &[],
        &[],
    )
    .unwrap();
    bed.process(&vec![1024; 2048], Some(&metadata(vec![])), &mut output)
        .unwrap();
    assert_eq!(bed.objects(), []);
    let bad = [PolarObject {
        gain: f64::NAN,
        ..Default::default()
    }];
    assert!(
        DynamicObjectRenderer::new(Profile::Objects { count: 1 }, BedLayout::Stereo, &[0], &bad)
            .is_err()
    );
}

#[test]
fn cartesian_metadata_switches_modes_and_preserves_history_on_invalid_updates() {
    use baka_av3a_core::render::{
        CartesianControls, CartesianObject, CartesianSpatialObject, ObjectTarget,
    };
    let profile = Profile::BedObjects {
        configuration: 1,
        objects: 2,
    };
    let defaults = [PolarObject {
        gain: 0.5,
        diffuse: 0.25,
        width: 45.0,
        ..Default::default()
    }; 2];
    for layout in [BedLayout::Stereo, BedLayout::Surround714] {
        let mut actual = DynamicObjectRenderer::new(profile, layout, &[29, 3], &defaults).unwrap();
        let mut manual = ObjectRenderer::new(Some(BedLayout::Stereo), layout, &defaults).unwrap();
        let mut a = vec![0.0; 1024 * usize::from(layout.channels())];
        let mut b = a.clone();
        for phase in 0..4 {
            let mut p = parameters([0, 0, 15]);
            p.position = ObjectPosition::Cartesian(if phase == 0 {
                [-128, -32, -8]
            } else {
                [127, 31, 7]
            });
            p.extent = (phase == 1).then_some([127, 31, 15]);
            if phase == 2 {
                p.position = ObjectPosition::Spherical([0, 0, 15]);
            }
            p.jump_position = phase % 2 == 0;
            p.controls = Some(SpatialControls {
                channel_lock: Some(ChannelLock::Within(0)),
                divergence: None,
                screen_reference: Some(false),
                screen_edge_lock: None,
            });
            let data = metadata(vec![
                object(3, Some(parameters([0, 0, 15]))),
                object(29, Some(p.clone())),
            ]);
            let target = CartesianSpatialObject {
                object: CartesianObject {
                    position: if phase == 0 {
                        [-1.0; 3]
                    } else {
                        [
                            f64::from(127.0_f32 * (2.0 / 255.0)),
                            f64::from(31.0_f32 * (2.0 / 63.0)),
                            f64::from(7.0_f32 * (2.0 / 15.0)),
                        ]
                    },
                    size: if phase == 1 { [1.0; 3] } else { [0.0; 3] },
                    gain: 0.5,
                    diffuse: 0.25,
                },
                controls: CartesianControls {
                    channel_lock: Some(0.0),
                    ..Default::default()
                },
            };
            let first = if phase == 2 {
                baka_av3a_core::render::SpatialObject {
                    object: defaults[0],
                    controls: baka_av3a_core::render::PolarControls {
                        channel_lock: Some(0.0),
                        ..Default::default()
                    },
                }
                .into()
            } else {
                ObjectTarget::Cartesian(target)
            };
            let targets = [first, defaults[1].into()];
            manual
                .set_targets_with_jump(&targets, &[p.jump_position, false])
                .unwrap();
            actual.process(&input(), Some(&data), &mut a).unwrap();
            manual.process(&input(), &mut b).unwrap();
            assert_eq!(actual.objects(), targets);
            assert_eq!(a, b);
            for _ in 0..3 {
                actual.process(&input(), None, &mut a).unwrap();
                manual.process(&input(), &mut b).unwrap();
                assert_eq!(a, b);
            }
            // Unsupported controls and invalid wire indices preserve typed targets, PCM, and history.
            let mut control = actual.clone();
            let before = actual.objects().to_vec();
            for invalid in 0..3 {
                let mut bad = p.clone();
                bad.position = ObjectPosition::Cartesian([0; 3]);
                if invalid == 0 {
                    bad.position = ObjectPosition::Cartesian([0, 0, -9]);
                }
                if invalid == 1 {
                    bad.controls.as_mut().unwrap().divergence =
                        Some(baka_av3a_core::metadata::ObjectDivergence {
                            amount: 16,
                            azimuth_range: Some(1),
                        });
                }
                if invalid == 2 {
                    bad.controls.as_mut().unwrap().screen_reference = Some(true);
                }
                let bad = metadata(vec![object(29, Some(bad)), object(3, None)]);
                a.fill(42.0);
                assert!(actual.process(&input(), Some(&bad), &mut a).is_err());
                assert!(a.iter().all(|v| *v == 42.0));
                assert_eq!(actual.objects(), before);
            }
            actual.process(&input(), None, &mut a).unwrap();
            control.process(&input(), None, &mut b).unwrap();
            assert_eq!(a, b);
            // Keep the explicit renderer aligned after the error control check.
            manual.process(&input(), &mut b).unwrap();
            assert_eq!(a, b);
        }
        let muted = metadata(vec![object(29, None), object(3, None)]);
        actual.process(&input(), Some(&muted), &mut a).unwrap();
        assert!(
            actual
                .objects()
                .iter()
                .all(|t| t.polar().unwrap().object.gain == 0.0)
        );
        actual.reset().unwrap();
        let mut fresh = DynamicObjectRenderer::new(profile, layout, &[29, 3], &defaults).unwrap();
        for _ in 0..4 {
            actual.process(&input(), None, &mut a).unwrap();
            fresh.process(&input(), None, &mut b).unwrap();
            assert_eq!(a, b);
        }
    }
}

#[test]
fn cartesian_wire_divergence_preserves_amount_and_uses_zero_displacement() {
    use baka_av3a_core::metadata::ObjectDivergence;
    let defaults = [PolarObject::default()];
    let source = vec![8192; 1024];
    let mut actual = DynamicObjectRenderer::new(
        Profile::Objects { count: 1 },
        BedLayout::Surround714,
        &[3],
        &defaults,
    )
    .unwrap();
    let mut plain = actual.clone();
    let mut a = vec![0.0; 12288];
    let mut b = a.clone();
    for amount in 0..16 {
        for angular in [0, 16, 32, 63] {
            let mut p = parameters([0, 0, 0]);
            p.position = ObjectPosition::Cartesian([-64, 16, 4]);
            p.extent = Some([30, 6, 4]);
            let normal = metadata(vec![object(3, Some(p.clone()))]);
            p.controls = Some(SpatialControls {
                channel_lock: None,
                divergence: Some(ObjectDivergence {
                    amount,
                    azimuth_range: Some(angular),
                }),
                screen_reference: None,
                screen_edge_lock: None,
            });
            let data = metadata(vec![object(3, Some(p))]);
            actual.process(&source, Some(&data), &mut a).unwrap();
            plain.process(&source, Some(&normal), &mut b).unwrap();
            assert_eq!(a, b);
            let controls = actual.objects()[0].cartesian().unwrap().controls;
            assert_eq!(
                controls.divergence,
                f64::from(f32::from(amount) * (1.0 / 15.0))
            );
            assert_eq!(controls.position_range, 0.0);
        }
    }
}
