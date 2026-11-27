use baka_av3a_core::render::{
    BedLayout, ObjectProjector, PolarControls, PolarObject, ScreenEdge, ScreenEdges,
    ScreenTransform, SpatialObject,
};
#[path = "fixtures/screen_vectors.rs"]
mod fixtures;
fn geometry(index: usize) -> ScreenEdges {
    let g = &fixtures::GEOMETRIES[index];
    let v = g.values;
    if g.kind == 0 {
        ScreenEdges::polar(v[0], v[1], v[2], v[3], v[4]).unwrap()
    } else {
        ScreenEdges::cartesian([v[0], v[1], v[2]], v[3], v[4]).unwrap()
    }
}
fn edge(value: u8) -> Option<ScreenEdge> {
    if value == 4 {
        None
    } else {
        Some(ScreenEdge::try_from(value).unwrap())
    }
}

#[test]
fn independent_screen_geometry_and_mapping() {
    for (i, g) in fixtures::GEOMETRIES.iter().enumerate() {
        let actual = geometry(i).angles();
        for (a, b) in actual.into_iter().zip(g.edges) {
            assert!(
                (a - b).abs() < 1e-10,
                "geometry={i} actual={a} expected={b}"
            );
        }
    }
    let mut peak = 0.0f64;
    for (i, v) in fixtures::MAPPINGS.iter().enumerate() {
        let mapping = ScreenTransform::new(geometry(v.reference), geometry(v.reproduction));
        let actual = mapping
            .apply(
                PolarObject {
                    azimuth: v.position[0],
                    elevation: v.position[1],
                    distance: v.position[2],
                    ..Default::default()
                },
                v.scale,
                edge(v.edge),
            )
            .unwrap();
        for (axis, (a, b)) in [actual.azimuth, actual.elevation, actual.distance]
            .into_iter()
            .zip(v.expected)
            .enumerate()
        {
            // The two azimuth endpoints name the same physical direction.
            let error = if axis == 0 {
                ((a - b + 180.0).rem_euclid(360.0) - 180.0).abs()
            } else {
                (a - b).abs()
            };
            peak = peak.max(error);
            assert!(error < 1e-10, "mapping={i} actual={a} expected={b}");
        }
    }
    println!(
        "geometry={} mappings={} max_abs_degrees={peak}",
        fixtures::GEOMETRIES.len(),
        fixtures::MAPPINGS.len()
    );
}

#[test]
fn independent_screen_to_speaker_gains() {
    let mut peak = 0.0f64;
    for config in [1, 2, 3, 7, 8, 9, 10] {
        let projector =
            ObjectProjector::new(BedLayout::from_configuration(config).unwrap()).unwrap();
        for (i, v) in fixtures::GAINS
            .iter()
            .enumerate()
            .filter(|(_, v)| v.layout == config)
        {
            let p = v.object;
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
            let mapping = ScreenTransform::new(geometry(v.reference), geometry(v.reproduction));
            let object = mapping.apply(object, v.scale, edge(v.edge)).unwrap();
            let gains = projector
                .project_controlled(SpatialObject {
                    object,
                    controls: PolarControls {
                        channel_lock: (v.lock >= 0.0).then_some(v.lock),
                        divergence: v.divergence,
                        azimuth_range: v.range,
                    },
                })
                .unwrap();
            for (&a, &b) in gains
                .direct()
                .iter()
                .zip(&v.direct)
                .chain(gains.diffuse().iter().zip(&v.diffuse))
            {
                let error = (f64::from(a) - b).abs();
                peak = peak.max(error);
                assert!(error < 2e-6, "gains={i} error={error}");
            }
        }
    }
    println!(
        "gain_vectors={} max_abs_error={peak}",
        fixtures::GAINS.len()
    );
}

#[test]
fn metadata_screens_default_geometry_and_degenerate_inputs() {
    use baka_av3a_core::metadata::Screen;
    let default = ScreenEdges::default().angles();
    let polar = ScreenEdges::polar(0.0, 0.0, 1.0, 58.0, 1.78)
        .unwrap()
        .angles();
    let cartesian = ScreenEdges::cartesian([0.0, 1.0, 0.0], 2.0 * 29.0f64.to_radians().tan(), 1.78)
        .unwrap()
        .angles();
    for edges in [polar, cartesian] {
        for (a, b) in default.into_iter().zip(edges) {
            assert!((a - b).abs() < 1e-12);
        }
    }
    for aspect_ratio in 0..2 {
        let screen = Screen {
            cartesian: false,
            aspect_ratio,
            position: [128, 0, 15],
            width: 41,
        };
        let actual = ScreenEdges::from_metadata(&screen).unwrap().angles();
        let expected = ScreenEdges::polar(
            0.0,
            0.0,
            1.0,
            f64::from(screen.width_value()),
            if aspect_ratio == 0 {
                16.0 / 9.0
            } else {
                21.0 / 9.0
            },
        )
        .unwrap()
        .angles();
        assert_eq!(actual, expected);
    }
    let mut screen = Screen {
        cartesian: true,
        aspect_ratio: 0,
        position: [128, 63, 8],
        width: 64,
    };
    assert!(ScreenEdges::from_metadata(&screen).is_ok());
    for aspect_ratio in 2..8 {
        screen.aspect_ratio = aspect_ratio;
        assert!(ScreenEdges::from_metadata(&screen).is_err());
    }
    for p in [
        [0.0, 0.0, 0.0, 0.0],
        [180.0, -180.0, -10.0, 10.0],
        [-20.0, 20.0, -10.0, 10.0],
        [20.0, -20.0, 10.0, -10.0],
        [20.0, -20.0, -90.0, 90.0],
        [f64::NAN, -20.0, -10.0, 10.0],
    ] {
        assert!(ScreenEdges::new(p[0], p[1], p[2], p[3]).is_err());
    }
    for p in [
        [0.0, 0.0, 0.0, 58.0, 1.78],
        [0.0, 0.0, 1.0, 0.0, 1.78],
        [0.0, 0.0, 1.0, 180.0, 1.78],
        [170.0, 0.0, 1.0, 40.0, 1.0],
        [30.0, 75.0, 1.0, 40.0, 1.0],
        [0.0, 0.0, 1.0, 58.0, 0.0],
    ] {
        assert!(ScreenEdges::polar(p[0], p[1], p[2], p[3], p[4]).is_err());
    }
    assert!(ScreenEdges::cartesian([0.0; 3], 1.0, 1.0).is_err());
    assert!(ScreenEdges::cartesian([0.0, 1.0, 0.0], 1.0, f64::MIN_POSITIVE / 2.0).is_err());
    assert!(ScreenEdge::try_from(4).is_err());
    assert!(ScreenEdges::cartesian([f64::MAX, f64::MAX, 0.0], f64::MAX, 1.78).is_err());
    let mapping = ScreenTransform::new(ScreenEdges::default(), ScreenEdges::default());
    let object = PolarObject {
        azimuth: 180.0,
        elevation: 90.0,
        ..Default::default()
    };
    assert_eq!(mapping.apply(object, false, None).unwrap(), object);
    let mapped = mapping.apply(object, true, Some(ScreenEdge::Left)).unwrap();
    assert_eq!(mapped.distance, object.distance);
    assert_eq!(mapped.azimuth, 29.0);
    let normal = ScreenEdges::cartesian([1.4, 1.4, 1.0], 0.1, 16.0 / 9.0)
        .unwrap()
        .angles();
    let huge = ScreenEdges::cartesian([1.4e308, 1.4e308, 1.0e308], 1.0e307, 16.0 / 9.0)
        .unwrap()
        .angles();
    for (a, b) in normal.into_iter().zip(huge) {
        assert!((a - b).abs() < 1e-12);
    }
}

#[test]
fn independent_cartesian_screen_positions_and_projected_gains() {
    use baka_av3a_core::render::{CartesianObject, CartesianProjector};
    let fixture = include_bytes!("fixtures/cartesian_screens.bin");
    assert_eq!(&fixture[..8], b"CSCR0001");
    let count = u32::from_le_bytes(fixture[8..12].try_into().unwrap()) as usize;
    assert_eq!(fixture.len(), 12 + count * 356);
    let projectors: Vec<_> = [1, 2, 3, 7, 8, 9, 10]
        .into_iter()
        .map(|c| CartesianProjector::new(BedLayout::from_configuration(c).unwrap()))
        .collect();
    let mut peak_position = 0.0_f64;
    let mut peak_gain = 0.0_f64;
    for (index, record) in fixture[12..].as_chunks::<356>().0.iter().enumerate() {
        let config = u32::from_le_bytes(record[..4].try_into().unwrap()) as u8;
        let scale = u32::from_le_bytes(record[4..8].try_into().unwrap()) != 0;
        let code = u32::from_le_bytes(record[8..12].try_into().unwrap()) as u8;
        let v: Vec<_> = record[12..]
            .as_chunks::<8>()
            .0
            .iter()
            .map(|v| f64::from_le_bytes(*v))
            .collect();
        let reference = ScreenEdges::new(v[0], v[1], v[2], v[3]).unwrap();
        let reproduction = ScreenEdges::new(v[4], v[5], v[6], v[7]).unwrap();
        let transform = ScreenTransform::new(reference, reproduction);
        let projector = projectors
            .iter()
            .find(|p| p.output_layout().configuration() == config)
            .unwrap();
        let input = CartesianObject {
            position: v[8..11].try_into().unwrap(),
            size: v[11..14].try_into().unwrap(),
            gain: v[14],
            diffuse: v[15],
        };
        let actual = transform
            .apply_cartesian(input, projector.output_layout(), scale, edge(code))
            .unwrap();
        assert_eq!(actual.size, input.size);
        assert_eq!(actual.gain, input.gain);
        assert_eq!(actual.diffuse, input.diffuse);
        for (actual, expected) in actual.position.iter().zip(&v[16..19]) {
            let error = (actual - expected).abs();
            peak_position = peak_position.max(error);
            assert!(
                error < 1e-10,
                "vector {index} config {config} scale {scale} edge {code} input {input:?} actual {actual} expected {expected}"
            );
        }
        let gains = projector.project(actual).unwrap();
        for (actual, expected) in gains
            .direct()
            .iter()
            .zip(&v[19..31])
            .chain(gains.diffuse().iter().zip(&v[31..43]))
        {
            let error = (f64::from(*actual) - expected).abs();
            peak_gain = peak_gain.max(error);
            assert!(
                error < 1e-6,
                "gain vector {index} config {config} delta {error}"
            );
        }
    }
    eprintln!(
        "{count} Cartesian screen vectors: position max {peak_position:e}, gain max {peak_gain:e}"
    );
}

#[test]
fn cartesian_screen_identity_roundtrip_and_invalid_parameters() {
    use baka_av3a_core::render::CartesianObject;
    let same = ScreenTransform::new(ScreenEdges::default(), ScreenEdges::default());
    for layout in [
        BedLayout::Stereo,
        BedLayout::Surround51,
        BedLayout::Surround514,
    ] {
        for x in [-1.0, -0.8, 0.0, 0.8, 1.0] {
            for y in [-1.0, 0.0, 1.0] {
                for z in [-1.0, 0.0, 1.0] {
                    let object = CartesianObject {
                        position: [x, y, z],
                        ..Default::default()
                    };
                    assert_eq!(
                        same.apply_cartesian(object, layout, false, None).unwrap(),
                        object
                    );
                    let actual = same.apply_cartesian(object, layout, true, None).unwrap();
                    for (actual, expected) in actual.position.into_iter().zip(object.position) {
                        assert!((actual - expected).abs() < 1e-12);
                    }
                }
            }
        }
    }
    for invalid in [f64::NAN, f64::INFINITY, -1.01, 1.01] {
        assert!(
            same.apply_cartesian(
                CartesianObject {
                    position: [invalid, 0.0, 0.0],
                    ..Default::default()
                },
                BedLayout::Stereo,
                false,
                None
            )
            .is_err()
        );
    }
}
