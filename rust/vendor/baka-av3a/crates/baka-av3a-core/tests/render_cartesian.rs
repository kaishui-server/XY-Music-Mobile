use baka_av3a_core::render::{BedLayout, CartesianObject, CartesianProjector, GainRenderer};

fn layouts() -> impl Iterator<Item = BedLayout> {
    [1, 2, 3, 7, 8, 9, 10]
        .into_iter()
        .map(|n| BedLayout::from_configuration(n).unwrap())
}

#[test]
fn independent_cartesian_point_and_extent_vectors() {
    let fixture = include_bytes!("fixtures/cartesian_vectors.bin");
    assert_eq!(&fixture[..8], b"CART0001");
    let count = u32::from_le_bytes(fixture[8..12].try_into().unwrap()) as usize;
    assert_eq!(fixture.len(), 12 + count * 260);
    let projectors: Vec<_> = layouts().map(CartesianProjector::new).collect();
    let mut peak = 0.0_f64;
    for (index, record) in fixture[12..].as_chunks::<260>().0.iter().enumerate() {
        let config = u32::from_le_bytes(record[..4].try_into().unwrap()) as u8;
        let values: Vec<_> = record[4..]
            .as_chunks::<8>()
            .0
            .iter()
            .map(|v| f64::from_le_bytes(*v))
            .collect();
        let object = CartesianObject {
            position: values[..3].try_into().unwrap(),
            size: values[3..6].try_into().unwrap(),
            gain: values[6],
            diffuse: values[7],
        };
        let projector = projectors
            .iter()
            .find(|p| p.output_layout().configuration() == config)
            .unwrap();
        let actual = projector.project(object).unwrap();
        for (actual, expected) in actual
            .direct()
            .iter()
            .zip(&values[8..20])
            .chain(actual.diffuse().iter().zip(&values[20..32]))
        {
            let error = (f64::from(*actual) - expected).abs();
            peak = peak.max(error);
            assert!(
                error < 1e-6,
                "vector {index}, config {config}, {object:?}: actual {actual}, expected {expected}, error {error}"
            );
        }
    }
    eprintln!("{count} Cartesian vectors, peak absolute error {peak:e}");
}

#[test]
fn cartesian_energy_axes_and_rendered_audio() {
    for layout in layouts() {
        let projector = CartesianProjector::new(layout);
        let gains = projector
            .project(CartesianObject {
                position: [-1.0, 1.0, 0.0],
                ..CartesianObject::default()
            })
            .unwrap();
        assert_eq!(gains.direct()[0], 1.0);
        assert!(gains.direct()[1..].iter().all(|v| *v == 0.0));
        let clone = projector.clone();
        for position in [[0.0, 0.0, 0.0], [-0.8, 0.3, 0.5], [1.0, -1.0, -1.0]] {
            let object = CartesianObject {
                position,
                size: [0.2, 0.5, 0.75],
                diffuse: 0.3,
                ..CartesianObject::default()
            };
            let mut actual = projector.project(object).unwrap();
            clone.project_into(object, &mut actual).unwrap();
            let power: f32 = actual
                .direct()
                .iter()
                .chain(actual.diffuse())
                .map(|v| v * v)
                .sum();
            assert!((power - 1.0).abs() < 2e-7);
            if layout != BedLayout::Stereo {
                assert_eq!(actual.direct()[3], 0.0);
                assert_eq!(actual.diffuse()[3], 0.0);
            }
        }
        let mut renderer = GainRenderer::new(None, layout, &[gains]).unwrap();
        let channels = usize::from(layout.channels());
        let mut audio = vec![0.0; 1024 * channels];
        for _ in 0..5 {
            renderer.process(&[1024; 1024], &mut audio).unwrap();
        }
        assert!(
            audio
                .chunks_exact(channels)
                .all(|f| (f[0] - 0.03125).abs() < 1e-7 && f[1..].iter().all(|v| *v == 0.0))
        );
    }
}

#[test]
fn invalid_cartesian_updates_preserve_gain_vectors() {
    let projector = CartesianProjector::new(BedLayout::Stereo);
    let mut output = projector.project(CartesianObject::default()).unwrap();
    let before = output.clone();
    for invalid in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -1.01, 1.01] {
        let mut object = CartesianObject::default();
        object.position[0] = invalid;
        assert!(projector.project_into(object, &mut output).is_err());
        assert_eq!(output.direct(), before.direct());
        assert_eq!(output.diffuse(), before.diffuse());
    }
    for invalid in [f64::NAN, f64::INFINITY, -0.01, 1.01] {
        for axis in 0..3 {
            let mut object = CartesianObject::default();
            object.size[axis] = invalid;
            assert!(projector.project_into(object, &mut output).is_err());
        }
        assert!(
            projector
                .project(CartesianObject {
                    diffuse: invalid,
                    ..CartesianObject::default()
                })
                .is_err()
        );
    }
    for gain in [f64::NAN, f64::INFINITY, -0.01, 16.01] {
        assert!(
            projector
                .project(CartesianObject {
                    gain,
                    ..CartesianObject::default()
                })
                .is_err()
        );
    }
    let mut wrong = CartesianProjector::new(BedLayout::Surround714)
        .project(CartesianObject::default())
        .unwrap();
    assert!(
        projector
            .project_into(CartesianObject::default(), &mut wrong)
            .is_err()
    );
}

#[test]
fn independent_cartesian_lock_and_divergence_vectors() {
    use baka_av3a_core::render::{CartesianControls, CartesianSpatialObject};
    let fixture = include_bytes!("fixtures/cartesian_controls.bin");
    assert_eq!(&fixture[..8], b"CTLC0001");
    let count = u32::from_le_bytes(fixture[8..12].try_into().unwrap()) as usize;
    assert_eq!(fixture.len(), 12 + count * 284);
    let projectors: Vec<_> = layouts().map(CartesianProjector::new).collect();
    let mut peak = 0.0_f64;
    for (index, record) in fixture[12..].as_chunks::<284>().0.iter().enumerate() {
        let config = u32::from_le_bytes(record[..4].try_into().unwrap()) as u8;
        let values: Vec<_> = record[4..]
            .as_chunks::<8>()
            .0
            .iter()
            .map(|v| f64::from_le_bytes(*v))
            .collect();
        let target = CartesianSpatialObject {
            object: CartesianObject {
                position: values[..3].try_into().unwrap(),
                size: values[3..6].try_into().unwrap(),
                gain: values[6],
                diffuse: values[7],
            },
            controls: CartesianControls {
                channel_lock: (values[8] >= 0.0).then_some(values[8]),
                divergence: values[9],
                position_range: values[10],
            },
        };
        let projector = projectors
            .iter()
            .find(|p| p.output_layout().configuration() == config)
            .unwrap();
        let actual = projector.project_controlled(target).unwrap();
        for (a, b) in actual
            .direct()
            .iter()
            .zip(&values[11..23])
            .chain(actual.diffuse().iter().zip(&values[23..35]))
        {
            let error = (f64::from(*a) - b).abs();
            peak = peak.max(error);
            assert!(
                error < 1e-6,
                "{index} config {config} {target:?}: {a} != {b}, delta {error}"
            );
        }
    }
    eprintln!("{count} Cartesian controlled vectors, peak error {peak:e}");
    let projector = &projectors[0];
    let mut output = projector.project(CartesianObject::default()).unwrap();
    let before = output.clone();
    for invalid in [f64::NAN, f64::INFINITY, -0.01, 4.01] {
        let controls = CartesianControls {
            channel_lock: Some(invalid),
            ..Default::default()
        };
        assert!(
            projector
                .project_controlled_into(
                    CartesianSpatialObject {
                        controls,
                        ..Default::default()
                    },
                    &mut output
                )
                .is_err()
        );
        assert_eq!(output.direct(), before.direct());
        assert_eq!(output.diffuse(), before.diffuse());
    }
    for invalid in [f64::NAN, f64::INFINITY, -0.01, 1.01] {
        for controls in [
            CartesianControls {
                divergence: invalid,
                ..Default::default()
            },
            CartesianControls {
                position_range: invalid,
                ..Default::default()
            },
        ] {
            assert!(
                projector
                    .project_controlled_into(
                        CartesianSpatialObject {
                            controls,
                            ..Default::default()
                        },
                        &mut output
                    )
                    .is_err()
            );
            assert_eq!(output.direct(), before.direct());
            assert_eq!(output.diffuse(), before.diffuse());
        }
    }
}

#[test]
fn wire_cartesian_angular_range_uses_absent_position_range_default() {
    use baka_av3a_core::render::{CartesianControls, CartesianObject, CartesianSpatialObject};
    let fixture = include_bytes!("fixtures/cartesian_wire_divergence.bin");
    assert_eq!(&fixture[..8], b"CWDV0001");
    let count = u32::from_le_bytes(fixture[8..12].try_into().unwrap()) as usize;
    assert_eq!(fixture.len(), 12 + count * 228);
    let projectors: Vec<_> = layouts().map(CartesianProjector::new).collect();
    let mut peak = 0.0_f64;
    for record in fixture[12..].as_chunks::<228>().0 {
        let header: Vec<_> = record[..12]
            .as_chunks::<4>()
            .0
            .iter()
            .map(|v| u32::from_le_bytes(*v))
            .collect();
        let values: Vec<_> = record[12..]
            .as_chunks::<8>()
            .0
            .iter()
            .map(|v| f64::from_le_bytes(*v))
            .collect();
        let projector = projectors
            .iter()
            .find(|p| p.output_layout().configuration() == header[0] as u8)
            .unwrap();
        let object = CartesianSpatialObject {
            object: CartesianObject {
                position: values[..3].try_into().unwrap(),
                size: [0.25, 0.5, 0.75],
                gain: 0.5,
                diffuse: 0.25,
            },
            controls: CartesianControls {
                divergence: f64::from(header[1] as f32 * (1.0 / 15.0)),
                position_range: 0.0,
                channel_lock: None,
            },
        };
        let actual = projector.project_controlled(object).unwrap();
        for (a, b) in actual
            .direct()
            .iter()
            .zip(&values[3..15])
            .chain(actual.diffuse().iter().zip(&values[15..27]))
        {
            let delta = (f64::from(*a) - b).abs();
            peak = peak.max(delta);
            assert!(delta < 1e-7);
        }
    }
    eprintln!("{count} independent wire Cartesian divergence vectors, max {peak:e}");
}
