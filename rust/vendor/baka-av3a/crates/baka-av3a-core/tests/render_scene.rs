use baka_av3a_core::{
    metadata::{
        AudioPack, Content, DynamicMetadata, DynamicObject, EncodedGain, ObjectParameters,
        ObjectPosition, Programme, StaticChannel, StaticMetadata, StaticObject,
    },
    render::{BedLayout, BedRenderer, ObjectRenderer, PolarObject, SceneRenderer},
};

const LAYOUTS: [BedLayout; 7] = [
    BedLayout::Stereo,
    BedLayout::Surround51,
    BedLayout::Surround71,
    BedLayout::Surround512,
    BedLayout::Surround514,
    BedLayout::Surround712,
    BedLayout::Surround714,
];

fn pack(index: u8, format: Option<u8>, channels: &[(u8, u8)]) -> AudioPack {
    AudioPack {
        index,
        importance: None,
        type_label: if format.is_some() { 1 } else { 3 },
        absolute_distance: 0,
        hoa: None,
        format_id: format,
        matrix_outputs: vec![],
        start_index: None,
        channels: channels
            .iter()
            .map(|&(id, physical)| (id, Some(physical)))
            .collect(),
    }
}
fn object(index: u8, packs: &[u8]) -> StaticObject {
    StaticObject {
        index,
        language: None,
        dialogue: None,
        importance: None,
        disable_ducking: false,
        interaction: None,
        gain: None,
        head_locked: false,
        muted: false,
        packs: packs.to_vec(),
    }
}
fn scene(packs: Vec<AudioPack>, objects: Vec<StaticObject>) -> StaticMetadata {
    let ids: std::collections::BTreeSet<_> = packs
        .iter()
        .flat_map(|p| p.channels.iter().map(|p| p.0))
        .collect();
    StaticMetadata {
        basic_level: 0,
        programme: Programme {
            language: None,
            ducking_depth: None,
            loudness: None,
            screen: None,
            contents: vec![2],
        },
        contents: vec![Content {
            index: 2,
            language: None,
            loudness: None,
            dialogue: None,
            complementary_objects: vec![],
            objects: objects.iter().map(|o| o.index).collect(),
        }],
        objects,
        packs,
        channels: ids
            .into_iter()
            .map(|index| StaticChannel {
                index,
                gain: None,
                speaker: None,
                matrix_coefficients: vec![],
            })
            .collect(),
        vr: None,
    }
}
fn input(channels: usize) -> Vec<i16> {
    (0..1024 * channels)
        .map(|i| ((i * 1597 + 113) % 8192) as i16 - 4096)
        .collect()
}

fn equal_route(a: &[f32], b: &[f32], reversed: bool, format: u8, output: BedLayout) {
    let peak = a
        .iter()
        .zip(b)
        .map(|(a, b)| (a - b).abs())
        .fold(0.0f32, f32::max);
    // Reversing physical inputs changes f32 summation order, not the routing.
    assert!(
        if reversed { peak < 2e-7 } else { peak == 0.0 },
        "format={format}, output={output:?}, reversed={reversed}, peak={peak}"
    );
}

#[test]
fn predefined_pack_routes_match_bed_pcm_with_contiguous_and_reversed_transport() {
    for (format, layout) in [
        (2, BedLayout::Stereo),
        (3, BedLayout::Surround51),
        (4, BedLayout::Surround512),
        (5, BedLayout::Surround514),
        (15, BedLayout::Surround71),
        (23, BedLayout::Surround714),
    ] {
        let count = usize::from(layout.channels());
        for reused in [false, true] {
            let mapping: Vec<_> = (0..count)
                .map(|i| {
                    (
                        (31 - i) as u8,
                        if reused {
                            (count - 1 - i) as u8
                        } else {
                            i as u8
                        },
                    )
                })
                .collect();
            let mut p = pack(7, Some(format), &mapping);
            if !reused {
                p.start_index = Some(0);
                p.channels.iter_mut().for_each(|p| p.1 = None);
            }
            let metadata = scene(vec![p], vec![object(5, &[7])]);
            for output in LAYOUTS {
                let mut actual = SceneRenderer::new(&metadata, count as u16, output, None).unwrap();
                let mut expected = BedRenderer::new(layout, output);
                assert_eq!(actual.object_references(), []);
                let physical = input(count);
                let ordered: Vec<_> = physical
                    .chunks_exact(count)
                    .flat_map(|frame| {
                        mapping
                            .iter()
                            .map(|&(_, physical)| frame[usize::from(physical)])
                    })
                    .collect();
                let mut a = vec![0.0; 1024 * usize::from(output.channels())];
                let mut b = a.clone();
                for _ in 0..2 {
                    actual.process(&physical, None, &mut a).unwrap();
                    expected.process(&ordered, &mut b).unwrap();
                    equal_route(&a, &b, reused, format, output);
                }
                for _ in 0..3 {
                    actual.process_silence(&mut a).unwrap();
                    expected.process_silence(1024, &mut b).unwrap();
                    equal_route(&a, &b, reused, format, output);
                }
            }
        }
    }
}

fn mixed() -> StaticMetadata {
    scene(
        vec![
            pack(7, Some(2), &[(10, 2), (2, 0)]),
            pack(1, None, &[(27, 3), (30, 1)]),
        ],
        vec![object(3, &[1]), object(6, &[1]), object(0, &[7])],
    )
}
fn parameters(position: [i16; 3]) -> ObjectParameters {
    ObjectParameters {
        position: ObjectPosition::Spherical(position),
        extent: Some([30, 6, 4]),
        gain: Some(32),
        diffuse: Some(64),
        jump_position: false,
        importance: None,
        controls: None,
    }
}
fn dynamic() -> DynamicMetadata {
    DynamicMetadata {
        level: 0,
        objects: vec![
            DynamicObject {
                transport_channel: 3,
                parameters: Some(parameters([40, 12, 8])),
            },
            DynamicObject {
                transport_channel: 1,
                parameters: Some(parameters([-40, 0, 15])),
            },
        ],
    }
}
fn polar(p: &ObjectParameters, factor: f64) -> PolarObject {
    let [azimuth, elevation, distance] = p.position.coordinates();
    let [width, height, depth] = p.extent_values().unwrap();
    PolarObject {
        azimuth: azimuth.into(),
        elevation: elevation.into(),
        distance: distance.into(),
        width: width.into(),
        height: height.into(),
        depth: depth.into(),
        gain: f64::from(p.linear_gain().unwrap()) * factor,
        diffuse: p.diffuseness().unwrap().into(),
    }
}

#[test]
fn shared_object_paths_and_permuted_bed_match_manually_ordered_pcm() {
    let metadata = mixed();
    let physical = input(4);
    let ordered: Vec<_> = physical
        .as_chunks::<4>()
        .0
        .iter()
        .flat_map(|f| [f[2], f[0], f[1], f[3]])
        .collect();
    let data = dynamic();
    for output in LAYOUTS {
        let mut actual = SceneRenderer::new(&metadata, 4, output, None).unwrap();
        let initial = [PolarObject {
            gain: 2.0,
            ..Default::default()
        }; 2];
        let mut expected = ObjectRenderer::new(Some(BedLayout::Stereo), output, &initial).unwrap();
        assert_eq!(actual.object_references(), &[1, 3]);
        let mut a = vec![0.0; 1024 * usize::from(output.channels())];
        let mut b = a.clone();
        let objects = [
            polar(data.objects[1].parameters.as_ref().unwrap(), 2.0),
            polar(data.objects[0].parameters.as_ref().unwrap(), 2.0),
        ];
        expected.set_objects(&objects).unwrap();
        actual.process(&physical, Some(&data), &mut a).unwrap();
        expected.process(&ordered, &mut b).unwrap();
        assert_eq!(a, b);
        for _ in 0..4 {
            actual.process(&physical, None, &mut a).unwrap();
            expected.process(&ordered, &mut b).unwrap();
            assert_eq!(a, b);
        }
        for _ in 0..3 {
            actual.process_silence(&mut a).unwrap();
            expected.process_silence(1024, &mut b).unwrap();
            assert_eq!(a, b);
        }
    }
}

#[test]
fn static_gain_products_retain_headroom_and_static_mute_is_persistent() {
    let mut metadata = scene(
        vec![pack(0, Some(2), &[(0, 0), (1, 1)])],
        vec![object(0, &[0])],
    );
    let max_gain = EncodedGain {
        decibels: false,
        upper: true,
        index: 63,
    };
    metadata.objects[0].gain = Some(max_gain.clone());
    metadata.channels[0].gain = Some(max_gain);
    let mut actual = SceneRenderer::new(&metadata, 2, BedLayout::Stereo, None).unwrap();
    let quiet_input: Vec<_> = (0..1024).flat_map(|_| [1, 0]).collect();
    let mut output = vec![0.0; 2048];
    for _ in 0..8 {
        actual.process(&quiet_input, None, &mut output).unwrap();
    }
    for f in output.as_chunks::<2>().0 {
        assert!((f[0] - 256.0 * 0.85 / 32768.0).abs() < 1e-8);
        assert_eq!(f[1], 0.0);
    }
    let mut metadata = mixed();
    metadata.objects.iter_mut().for_each(|o| o.muted = true);
    let mut actual = SceneRenderer::new(&metadata, 4, BedLayout::Stereo, None).unwrap();
    for _ in 0..6 {
        actual
            .process(&input(4), Some(&dynamic()), &mut output)
            .unwrap();
    }
    assert!(output.iter().all(|&v| v == 0.0));
}

#[test]
fn errors_preserve_audio_history_and_reset_restores_initial_targets() {
    let metadata = mixed();
    let mut actual = SceneRenderer::new(&metadata, 4, BedLayout::Stereo, None).unwrap();
    let mut output = vec![0.0; 2048];
    actual
        .process(&input(4), Some(&dynamic()), &mut output)
        .unwrap();
    let mut control = actual.clone();
    let original = actual.objects().to_vec();
    let mut bad = dynamic();
    bad.objects[0].parameters.as_mut().unwrap().position = ObjectPosition::Cartesian([128, 0, 0]);
    for metadata in [
        bad,
        DynamicMetadata {
            level: 0,
            objects: vec![],
        },
    ] {
        output.fill(123.0);
        assert!(
            actual
                .process(&input(4), Some(&metadata), &mut output)
                .is_err()
        );
        assert!(output.iter().all(|&v| v == 123.0));
        assert_eq!(actual.objects(), original);
    }
    assert!(
        actual
            .process(&input(4)[..4095], None, &mut output)
            .is_err()
    );
    assert!(
        actual
            .process(&input(4), None, &mut output[..2047])
            .is_err()
    );
    assert!(actual.process_silence(&mut output[..2047]).is_err());
    let mut expected = output.clone();
    for _ in 0..4 {
        actual.process(&input(4), None, &mut output).unwrap();
        control.process(&input(4), None, &mut expected).unwrap();
        assert_eq!(output, expected);
    }
    actual.reset().unwrap();
    let mut fresh = SceneRenderer::new(&metadata, 4, BedLayout::Stereo, None).unwrap();
    for _ in 0..4 {
        actual.process(&input(4), None, &mut output).unwrap();
        fresh.process(&input(4), None, &mut expected).unwrap();
        assert_eq!(output, expected);
    }
}

#[test]
fn inactive_objects_allow_unsupported_spatial_modes_but_not_invalid_indices() {
    let mut actual = SceneRenderer::new(&mixed(), 4, BedLayout::Stereo, Some(&[0])).unwrap();
    let mut data = dynamic();
    let p = data.objects[0].parameters.as_mut().unwrap();
    p.position = ObjectPosition::Cartesian([0; 3]);
    p.jump_position = true;
    p.controls = Some(baka_av3a_core::metadata::SpatialControls {
        channel_lock: None,
        divergence: None,
        screen_reference: None,
        screen_edge_lock: Some(0),
    });
    let mut output = vec![0.0; 2048];
    actual.process(&input(4), Some(&data), &mut output).unwrap();
    data.objects[0]
        .parameters
        .as_mut()
        .unwrap()
        .controls
        .as_mut()
        .unwrap()
        .screen_edge_lock = Some(4);
    assert!(actual.process(&input(4), Some(&data), &mut output).is_err());
    data.objects[0].parameters.as_mut().unwrap().controls = None;
    data.objects[0].parameters.as_mut().unwrap().position = ObjectPosition::Cartesian([128, 0, 0]);
    assert!(actual.process(&input(4), Some(&data), &mut output).is_err());
}

#[test]
fn unsupported_packs_and_configuration_limits_are_explicit() {
    for format in [1, 12, 14, 22, 63] {
        let metadata = scene(
            vec![pack(0, Some(format), &[(0, 0), (1, 1)])],
            vec![object(0, &[0])],
        );
        assert!(SceneRenderer::new(&metadata, 2, BedLayout::Stereo, None).is_err());
    }
    let mut metadata = mixed();
    metadata.packs[0].format_id = Some(3); // six-channel format with only two definitions
    assert!(SceneRenderer::new(&metadata, 4, BedLayout::Stereo, None).is_err());
    for count in [0, 3, 17, 32] {
        assert!(SceneRenderer::new(&mixed(), count, BedLayout::Stereo, None).is_err());
    }
    for label in [2, 4, 5] {
        let mut metadata = mixed();
        metadata.packs[1].type_label = label;
        assert!(SceneRenderer::new(&metadata, 4, BedLayout::Stereo, None).is_err());
        assert!(SceneRenderer::new(&metadata, 4, BedLayout::Stereo, Some(&[0])).is_ok());
    }
    let mut metadata = mixed();
    metadata.objects[0].head_locked = true;
    assert!(SceneRenderer::new(&metadata, 4, BedLayout::Stereo, None).is_err());
    assert!(SceneRenderer::new(&metadata, 4, BedLayout::Stereo, Some(&[0])).is_ok());
}

#[test]
fn dynamic_and_scene_control_updates_match_explicit_spatial_objects() {
    use baka_av3a_core::{
        Profile,
        metadata::{ChannelLock, ObjectDivergence, SpatialControls},
        render::{DynamicObjectRenderer, PolarControls, SpatialObject},
    };
    let metadata = mixed();
    let layout = BedLayout::Surround714;
    let mut actual = SceneRenderer::new(&metadata, 4, layout, None).unwrap();
    let mut expected = ObjectRenderer::new(
        Some(BedLayout::Stereo),
        layout,
        &[PolarObject::default(); 2],
    )
    .unwrap();
    let mut data = dynamic();
    let physical = input(4);
    let ordered: Vec<_> = physical
        .as_chunks::<4>()
        .0
        .iter()
        .flat_map(|f| [f[2], f[0], f[1], f[3]])
        .collect();
    let mut a = vec![0.0; 12288];
    let mut b = a.clone();
    let mut adapter = DynamicObjectRenderer::new(
        Profile::Objects { count: 1 },
        layout,
        &[3],
        &[PolarObject::default()],
    )
    .unwrap();
    let mut manual = ObjectRenderer::new(None, layout, &[PolarObject::default()]).unwrap();
    for enabled in [true, false, true] {
        let lock = if enabled {
            ChannelLock::Within(15)
        } else {
            ChannelLock::Disabled
        };
        let divergence = ObjectDivergence {
            amount: if enabled { 8 } else { 0 },
            azimuth_range: enabled.then_some(16),
        };
        let controls = PolarControls {
            channel_lock: lock.maximum_distance().map(f64::from),
            divergence: divergence.amount().into(),
            azimuth_range: divergence.azimuth_degrees().unwrap_or(0.0).into(),
        };
        for item in &mut data.objects {
            item.parameters.as_mut().unwrap().controls = Some(SpatialControls {
                channel_lock: Some(lock.clone()),
                divergence: Some(divergence.clone()),
                screen_reference: Some(false),
                screen_edge_lock: None,
            });
        }
        let objects = [
            SpatialObject {
                object: polar(data.objects[1].parameters.as_ref().unwrap(), 2.0),
                controls,
            },
            SpatialObject {
                object: polar(data.objects[0].parameters.as_ref().unwrap(), 2.0),
                controls,
            },
        ];
        expected.set_controlled_objects(&objects).unwrap();
        manual
            .set_controlled_objects(&[SpatialObject {
                object: polar(data.objects[0].parameters.as_ref().unwrap(), 1.0),
                controls,
            }])
            .unwrap();
        let one = DynamicMetadata {
            level: 1,
            objects: vec![data.objects[0].clone()],
        };
        for _ in 0..4 {
            actual.process(&physical, Some(&data), &mut a).unwrap();
            expected.process(&ordered, &mut b).unwrap();
            assert_eq!(a, b);
            adapter.process(&input(1), Some(&one), &mut a).unwrap();
            manual.process(&input(1), &mut b).unwrap();
            assert_eq!(a, b);
        }
    }
}

#[test]
fn configured_screen_metadata_matches_manual_pcm_and_preserves_history_on_error() {
    use baka_av3a_core::{
        Profile,
        metadata::{Screen, SpatialControls},
        render::{DynamicObjectRenderer, ScreenEdge, ScreenEdges, ScreenTransform},
    };
    let mut metadata = mixed();
    metadata.programme.screen = Some(Screen {
        cartesian: false,
        aspect_ratio: 0,
        position: [140, 6, 15],
        width: 41,
    });
    let reproduction = ScreenEdges::polar(-10.0, 5.0, 1.0, 80.0, 21.0 / 9.0).unwrap();
    let screen = ScreenTransform::new(
        ScreenEdges::from_metadata(metadata.programme.screen.as_ref().unwrap()).unwrap(),
        reproduction,
    );
    let layout = BedLayout::Surround714;
    let mut actual =
        SceneRenderer::new_with_screen(&metadata, 4, layout, None, reproduction).unwrap();
    let mut expected = ObjectRenderer::new(
        Some(BedLayout::Stereo),
        layout,
        &[PolarObject::default(); 2],
    )
    .unwrap();
    let mut adapter = DynamicObjectRenderer::new_with_screen(
        Profile::Objects { count: 1 },
        layout,
        &[3],
        &[PolarObject::default()],
        screen,
    )
    .unwrap();
    let mut manual = ObjectRenderer::new(None, layout, &[PolarObject::default()]).unwrap();
    let physical = input(4);
    let ordered: Vec<_> = physical
        .as_chunks::<4>()
        .0
        .iter()
        .flat_map(|f| [f[2], f[0], f[1], f[3]])
        .collect();
    let mut a = vec![0.0; 12288];
    let mut b = a.clone();
    let mut data = dynamic();
    for scale in [false, true] {
        for code in 0..5 {
            let edge = if code == 4 {
                None
            } else {
                Some(ScreenEdge::try_from(code).unwrap())
            };
            for object in &mut data.objects {
                object.parameters.as_mut().unwrap().controls = Some(SpatialControls {
                    channel_lock: None,
                    divergence: None,
                    screen_reference: Some(scale),
                    screen_edge_lock: (code != 4).then_some(code),
                });
            }
            let objects = [
                screen
                    .apply(
                        polar(data.objects[1].parameters.as_ref().unwrap(), 2.0),
                        scale,
                        edge,
                    )
                    .unwrap(),
                screen
                    .apply(
                        polar(data.objects[0].parameters.as_ref().unwrap(), 2.0),
                        scale,
                        edge,
                    )
                    .unwrap(),
            ];
            expected.set_objects(&objects).unwrap();
            manual
                .set_objects(&[screen
                    .apply(
                        polar(data.objects[0].parameters.as_ref().unwrap(), 1.0),
                        scale,
                        edge,
                    )
                    .unwrap()])
                .unwrap();
            let one = DynamicMetadata {
                level: 1,
                objects: vec![data.objects[0].clone()],
            };
            for _ in 0..4 {
                actual.process(&physical, Some(&data), &mut a).unwrap();
                expected.process(&ordered, &mut b).unwrap();
                assert_eq!(a, b);
                adapter.process(&input(1), Some(&one), &mut a).unwrap();
                manual.process(&input(1), &mut b).unwrap();
                assert_eq!(a, b);
            }
        }
    }
    let mut saved = actual.clone();
    data.objects[0]
        .parameters
        .as_mut()
        .unwrap()
        .controls
        .as_mut()
        .unwrap()
        .screen_edge_lock = Some(4);
    a.fill(42.0);
    assert!(actual.process(&physical, Some(&data), &mut a).is_err());
    assert!(a.iter().all(|&v| v == 42.0));
    for _ in 0..4 {
        actual.process(&physical, None, &mut a).unwrap();
        saved.process(&physical, None, &mut b).unwrap();
        assert_eq!(a, b);
    }
    actual.reset().unwrap();
    let mut fresh =
        SceneRenderer::new_with_screen(&metadata, 4, layout, None, reproduction).unwrap();
    for _ in 0..4 {
        actual.process(&physical, None, &mut a).unwrap();
        fresh.process(&physical, None, &mut b).unwrap();
        assert_eq!(a, b);
    }
    metadata.programme.screen.as_mut().unwrap().aspect_ratio = 7;
    assert!(SceneRenderer::new_with_screen(&metadata, 4, layout, None, reproduction).is_err());
    assert!(SceneRenderer::new(&metadata, 4, layout, None).is_ok());
}

#[test]
fn jumped_objects_preserve_a_shared_beds_startup_ramp_and_only_jump_once() {
    use baka_av3a_core::metadata::{ChannelLock, SpatialControls};
    let metadata = scene(
        vec![
            pack(0, Some(2), &[(0, 0), (1, 1)]),
            pack(1, None, &[(2, 0)]),
        ],
        vec![object(0, &[0]), object(1, &[1])],
    );
    let mut renderer = SceneRenderer::new(&metadata, 2, BedLayout::Stereo, None).unwrap();
    let mut p = parameters([21, 0, 15]);
    p.extent = None;
    p.gain = None;
    p.diffuse = None;
    p.jump_position = true;
    p.controls = Some(SpatialControls {
        channel_lock: Some(ChannelLock::Within(15)),
        divergence: None,
        screen_reference: None,
        screen_edge_lock: None,
    });
    let mut data = DynamicMetadata {
        level: 1,
        objects: vec![DynamicObject {
            transport_channel: 0,
            parameters: Some(p),
        }],
    };
    let input: Vec<_> = (0..1024).flat_map(|_| [1024, 0]).collect();
    let mut output = vec![0.0; 6 * 2048];
    let mut invalid = data.clone();
    invalid.objects[0]
        .parameters
        .as_mut()
        .unwrap()
        .controls
        .as_mut()
        .unwrap()
        .screen_edge_lock = Some(4);
    assert!(
        renderer
            .process(&input, Some(&invalid), &mut output[..2048])
            .is_err()
    );
    renderer
        .process(&input, Some(&data), &mut output[..2048])
        .unwrap();
    renderer
        .process(&input, None, &mut output[2048..4096])
        .unwrap();
    data.objects[0].parameters.as_mut().unwrap().position = ObjectPosition::Spherical([-21, 0, 15]);
    renderer
        .process(&input, Some(&data), &mut output[4096..6144])
        .unwrap();
    for block in 3..6 {
        renderer
            .process_silence(&mut output[block * 2048..(block + 1) * 2048])
            .unwrap();
    }
    let delay = SceneRenderer::DELAY_SAMPLES;
    for i in [0, 1, 512, 1023] {
        let coefficient = 1.0 + 0.85 * i as f32 / 1024.0;
        assert!((output[(delay + i) * 2] - 1024.0 / 32768.0 * coefficient).abs() < 1e-7);
        assert_eq!(output[(delay + i) * 2 + 1], 0.0);
    }
    assert!((output[(delay + 1024) * 2] - 1024.0 / 32768.0 * 1.85).abs() < 1e-7);
    assert!((output[(delay + 2048) * 2] - 1024.0 / 32768.0 * 0.85).abs() < 1e-7);
    assert_eq!(output[(delay + 2048) * 2 + 1], 1024.0 / 32768.0);
    renderer.reset().unwrap();
    let mut fresh = SceneRenderer::new(&metadata, 2, BedLayout::Stereo, None).unwrap();
    let mut a = vec![0.0; 2048];
    let mut b = a.clone();
    for _ in 0..4 {
        renderer.process(&input, Some(&data), &mut a).unwrap();
        fresh.process(&input, Some(&data), &mut b).unwrap();
        assert_eq!(a, b);
    }
}

#[test]
fn dynamic_jump_bits_map_to_the_correct_physical_object() {
    use baka_av3a_core::{
        Profile,
        render::{DynamicObjectRenderer, SpatialObject},
    };
    let mut renderer = SceneRenderer::new(&mixed(), 4, BedLayout::Surround714, None).unwrap();
    let mut manual = ObjectRenderer::new(
        Some(BedLayout::Stereo),
        BedLayout::Surround714,
        &[PolarObject::default(); 2],
    )
    .unwrap();
    let mut adapter = DynamicObjectRenderer::new(
        Profile::Objects { count: 1 },
        BedLayout::Surround714,
        &[3],
        &[PolarObject::default()],
    )
    .unwrap();
    let mut single =
        ObjectRenderer::new(None, BedLayout::Surround714, &[PolarObject::default()]).unwrap();
    let mut data = dynamic();
    let physical = input(4);
    let ordered: Vec<_> = physical
        .as_chunks::<4>()
        .0
        .iter()
        .flat_map(|f| [f[2], f[0], f[1], f[3]])
        .collect();
    let mut a = vec![0.0; 12288];
    let mut b = a.clone();
    for phase in 0..3 {
        for (i, item) in data.objects.iter_mut().enumerate() {
            let p = item.parameters.as_mut().unwrap();
            p.jump_position = (phase + i) % 3 == 0;
            p.position =
                ObjectPosition::Spherical([(phase as i16 - 1) * 35 + i as i16 * 20, 0, 15]);
        }
        let flags = [
            data.objects[1].parameters.as_ref().unwrap().jump_position,
            data.objects[0].parameters.as_ref().unwrap().jump_position,
        ];
        let objects = [
            SpatialObject::from(polar(data.objects[1].parameters.as_ref().unwrap(), 2.0)),
            SpatialObject::from(polar(data.objects[0].parameters.as_ref().unwrap(), 2.0)),
        ];
        manual
            .set_controlled_objects_with_jump(&objects, &flags)
            .unwrap();
        single
            .set_controlled_objects_with_jump(
                &[polar(data.objects[0].parameters.as_ref().unwrap(), 1.0).into()],
                &[flags[1]],
            )
            .unwrap();
        let one = DynamicMetadata {
            level: 0,
            objects: vec![data.objects[0].clone()],
        };
        for block in 0..4 {
            renderer
                .process(&physical, (block == 0).then_some(&data), &mut a)
                .unwrap();
            manual.process(&ordered, &mut b).unwrap();
            assert_eq!(a, b);
            adapter
                .process(&input(1), (block == 0).then_some(&one), &mut a)
                .unwrap();
            single.process(&input(1), &mut b).unwrap();
            assert_eq!(a, b);
        }
    }
}

#[test]
#[ignore = "requires private native renderer fixtures in BAKA_AV3A_SCENE_ORACLE_DIR"]
fn local_scene_native_pcm() {
    let root = std::env::var_os("BAKA_AV3A_SCENE_ORACLE_DIR").unwrap();
    let mut paths: Vec<_> = std::fs::read_dir(root)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "scene"))
        .collect();
    paths.sort();
    assert_eq!(paths.len(), 7);
    let mut metadata = mixed();
    metadata.packs[0].channels = vec![(10, Some(0)), (2, Some(1))];
    metadata.packs[1].channels = vec![(27, Some(2)), (30, Some(3))];
    let mut data = dynamic();
    data.objects[0].transport_channel = 3;
    data.objects[1].transport_channel = 2;
    let mut signal = vec![0i16; 8192 * 4];
    let mut state = 0x1234_5678_u32;
    for sample in signal.iter_mut().take(4096 * 4) {
        state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        *sample = ((state % 16385) as i32 - 8192) as i16;
    }
    let mut maximum = 0.0f32;
    let mut samples = 0;
    for path in paths {
        assert!(std::fs::metadata(&path).unwrap().len() < 512 * 1024);
        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(&bytes[..8], b"SCENE001");
        let config = u32::from_le_bytes(bytes[8..12].try_into().unwrap());
        let frames = u32::from_le_bytes(bytes[12..16].try_into().unwrap());
        assert_eq!(frames, 8192);
        let layout = BedLayout::from_configuration(config.try_into().unwrap()).unwrap();
        let outputs = usize::from(layout.channels());
        assert_eq!(bytes.len(), 16 + 8192 * outputs * 4);
        let expected: Vec<_> = bytes[16..]
            .as_chunks::<4>()
            .0
            .iter()
            .map(|b| f32::from_le_bytes(*b))
            .collect();
        let mut actual = vec![0.0; expected.len()];
        let mut renderer = SceneRenderer::new(&metadata, 4, layout, None).unwrap();
        for (input, output) in signal.chunks(4096).zip(actual.chunks_mut(1024 * outputs)) {
            renderer.process(input, Some(&data), output).unwrap();
        }
        let mut squared = 0.0;
        let mut peak = 0.0f32;
        for (&a, &b) in actual.iter().zip(&expected) {
            assert!(a.is_finite() && b.is_finite());
            peak = peak.max((a - b).abs());
            squared += f64::from(a - b).powi(2);
        }
        assert!(peak < 2e-6, "{} peak={peak}", path.display());
        assert!((squared / actual.len() as f64).sqrt() < 2e-7);
        maximum = maximum.max(peak);
        samples += actual.len();
    }
    println!("cases=7 samples={samples} max_abs_error={maximum}");
}

#[test]
fn mixed_coordinate_scene_matches_explicit_transport_and_static_gains() {
    use baka_av3a_core::{
        Profile,
        metadata::{ChannelLock, SpatialControls},
        render::{
            CartesianControls, CartesianObject, CartesianSpatialObject, DynamicObjectRenderer,
            ObjectTarget,
        },
    };
    let metadata = mixed();
    let physical = input(4);
    let ordered: Vec<_> = physical
        .as_chunks::<4>()
        .0
        .iter()
        .flat_map(|f| [f[2], f[0], f[1], f[3]])
        .collect();
    for layout in LAYOUTS {
        let mut actual = SceneRenderer::new(&metadata, 4, layout, None).unwrap();
        let initial = [PolarObject {
            gain: 2.0,
            ..Default::default()
        }; 2];
        let mut explicit = ObjectRenderer::new(Some(BedLayout::Stereo), layout, &initial).unwrap();
        let mut adapter = DynamicObjectRenderer::new(
            Profile::BedObjects {
                configuration: 1,
                objects: 2,
            },
            layout,
            &[1, 3],
            &initial,
        )
        .unwrap();
        let mut a = vec![0.0; 1024 * usize::from(layout.channels())];
        let mut b = a.clone();
        let mut c = a.clone();
        for phase in 0..4 {
            let mut p = parameters([0, 0, 15]);
            p.position = ObjectPosition::Cartesian(if phase % 2 == 0 {
                [-128, 0, 0]
            } else {
                [127, 31, 7]
            });
            p.extent = Some([64, 16, 8]);
            p.gain = None;
            p.diffuse = None;
            p.jump_position = phase % 2 == 0;
            p.controls = Some(SpatialControls {
                channel_lock: Some(ChannelLock::Within(3)),
                divergence: None,
                screen_reference: None,
                screen_edge_lock: None,
            });
            let cart = CartesianSpatialObject {
                object: CartesianObject {
                    position: p
                        .position
                        .coordinates()
                        .map(|v| f64::from(v).clamp(-1.0, 1.0)),
                    size: p.extent_values().unwrap().map(f64::from),
                    gain: 2.0,
                    diffuse: 0.0,
                },
                controls: CartesianControls {
                    channel_lock: Some(f64::from(3.0_f32 * (2.0 / 15.0))),
                    ..Default::default()
                },
            };
            let data = DynamicMetadata {
                level: 1,
                objects: vec![
                    DynamicObject {
                        transport_channel: 3,
                        parameters: Some(p),
                    },
                    DynamicObject {
                        transport_channel: 1,
                        parameters: Some(ObjectParameters {
                            gain: None,
                            diffuse: None,
                            extent: None,
                            ..parameters([0, 0, 15])
                        }),
                    },
                ],
            };
            let targets = [
                ObjectTarget::from(initial[0]),
                ObjectTarget::Cartesian(cart),
            ];
            explicit
                .set_targets_with_jump(&targets, &[false, phase % 2 == 0])
                .unwrap();
            actual.process(&physical, Some(&data), &mut a).unwrap();
            explicit.process(&ordered, &mut b).unwrap();
            adapter.process(&ordered, Some(&data), &mut c).unwrap();
            assert_eq!(a, b);
            assert_eq!(b, c);
            assert!(actual.objects()[1].cartesian().is_some());
            for _ in 0..3 {
                actual.process(&physical, None, &mut a).unwrap();
                explicit.process(&ordered, &mut b).unwrap();
                adapter.process(&ordered, None, &mut c).unwrap();
                assert_eq!(a, b);
                assert_eq!(b, c);
            }
        }
        for _ in 0..3 {
            actual.process_silence(&mut a).unwrap();
            explicit.process_silence(1024, &mut b).unwrap();
            assert_eq!(a, b);
        }
        actual.reset().unwrap();
        let mut fresh = SceneRenderer::new(&metadata, 4, layout, None).unwrap();
        for _ in 0..4 {
            actual.process(&physical, None, &mut a).unwrap();
            fresh.process(&physical, None, &mut b).unwrap();
            assert_eq!(a, b);
        }
    }
}

#[test]
fn cartesian_screen_controls_flow_through_scene_and_dynamic_pcm() {
    use baka_av3a_core::{
        Profile,
        metadata::{ChannelLock, Screen, SpatialControls},
        render::{
            CartesianControls, CartesianObject, CartesianSpatialObject, DynamicObjectRenderer,
            ObjectTarget, ScreenEdge, ScreenEdges, ScreenTransform,
        },
    };
    let mut metadata = mixed();
    metadata.programme.screen = Some(Screen {
        cartesian: false,
        aspect_ratio: 1,
        position: [140, 5, 15],
        width: 41,
    });
    let reproduction = ScreenEdges::cartesian([0.25, 1.0, 0.15], 1.2, 16.0 / 9.0).unwrap();
    let screen = ScreenTransform::new(
        ScreenEdges::from_metadata(metadata.programme.screen.as_ref().unwrap()).unwrap(),
        reproduction,
    );
    let physical = input(4);
    let ordered: Vec<_> = physical
        .as_chunks::<4>()
        .0
        .iter()
        .flat_map(|f| [f[2], f[0], f[1], f[3]])
        .collect();
    let defaults = [PolarObject {
        gain: 2.0,
        ..Default::default()
    }; 2];
    for layout in LAYOUTS {
        let mut actual =
            SceneRenderer::new_with_screen(&metadata, 4, layout, None, reproduction).unwrap();
        let mut dynamic = DynamicObjectRenderer::new_with_screen(
            Profile::BedObjects {
                configuration: 1,
                objects: 2,
            },
            layout,
            &[1, 3],
            &defaults,
            screen,
        )
        .unwrap();
        let mut explicit = ObjectRenderer::new(Some(BedLayout::Stereo), layout, &defaults).unwrap();
        let mut a = vec![0.0; 1024 * usize::from(layout.channels())];
        let mut b = a.clone();
        let mut c = a.clone();
        for scale in [false, true] {
            for code in 0..5 {
                let edge = if code == 4 {
                    None
                } else {
                    Some(ScreenEdge::try_from(code).unwrap())
                };
                let mut p = parameters([0, 0, 15]);
                p.position = ObjectPosition::Cartesian([if scale { -100 } else { 100 }, 15, 5]);
                p.extent = Some([32, 16, 4]);
                p.gain = None;
                p.diffuse = None;
                p.jump_position = code % 2 == 0;
                p.controls = Some(SpatialControls {
                    channel_lock: Some(ChannelLock::Within(3)),
                    divergence: None,
                    screen_reference: Some(scale),
                    screen_edge_lock: (code < 4).then_some(code),
                });
                let object = CartesianObject {
                    position: p.position.coordinates().map(f64::from),
                    size: p.extent_values().unwrap().map(f64::from),
                    gain: 2.0,
                    diffuse: 0.0,
                };
                let transformed = screen.apply_cartesian(object, layout, scale, edge).unwrap();
                let targets = [
                    ObjectTarget::from(defaults[0]),
                    ObjectTarget::Cartesian(CartesianSpatialObject {
                        object: transformed,
                        controls: CartesianControls {
                            channel_lock: Some(f64::from(3.0_f32 * (2.0 / 15.0))),
                            ..Default::default()
                        },
                    }),
                ];
                let data = DynamicMetadata {
                    level: 1,
                    objects: vec![
                        DynamicObject {
                            transport_channel: 3,
                            parameters: Some(p),
                        },
                        DynamicObject {
                            transport_channel: 1,
                            parameters: Some(ObjectParameters {
                                gain: None,
                                diffuse: None,
                                extent: None,
                                ..parameters([0, 0, 15])
                            }),
                        },
                    ],
                };
                explicit
                    .set_targets_with_jump(&targets, &[false, code % 2 == 0])
                    .unwrap();
                actual.process(&physical, Some(&data), &mut a).unwrap();
                dynamic.process(&ordered, Some(&data), &mut b).unwrap();
                explicit.process(&ordered, &mut c).unwrap();
                assert_eq!(a, c);
                assert_eq!(b, c);
                assert_eq!(
                    actual.objects()[1].cartesian().unwrap().object.position,
                    transformed.position
                );
                for _ in 0..3 {
                    actual.process(&physical, None, &mut a).unwrap();
                    dynamic.process(&ordered, None, &mut b).unwrap();
                    explicit.process(&ordered, &mut c).unwrap();
                    assert_eq!(a, c);
                    assert_eq!(b, c);
                }
                let mut invalid = data.clone();
                invalid.objects[0]
                    .parameters
                    .as_mut()
                    .unwrap()
                    .controls
                    .as_mut()
                    .unwrap()
                    .screen_edge_lock = Some(4);
                let mut cloned = actual.clone();
                a.fill(42.0);
                assert!(actual.process(&physical, Some(&invalid), &mut a).is_err());
                assert!(a.iter().all(|v| *v == 42.0));
                actual.process(&physical, None, &mut a).unwrap();
                cloned.process(&physical, None, &mut c).unwrap();
                assert_eq!(a, c);
                dynamic.process(&ordered, None, &mut b).unwrap();
                explicit.process(&ordered, &mut c).unwrap();
                assert_eq!(a, c);
                assert_eq!(b, c);
                let mut no_screen = SceneRenderer::new(&metadata, 4, layout, None).unwrap();
                if scale || edge.is_some() {
                    assert!(no_screen.process(&physical, Some(&data), &mut a).is_err());
                }
            }
        }
        actual.reset().unwrap();
        dynamic.reset().unwrap();
        let mut fresh =
            SceneRenderer::new_with_screen(&metadata, 4, layout, None, reproduction).unwrap();
        for _ in 0..4 {
            actual.process(&physical, None, &mut a).unwrap();
            fresh.process(&physical, None, &mut c).unwrap();
            dynamic.process(&ordered, None, &mut b).unwrap();
            assert_eq!(a, c);
            assert_eq!(a, b);
        }
    }
}

#[test]
fn hoa_scene_transport_static_gain_and_float_pcm_match_standalone_decoder() {
    use baka_av3a_core::{
        metadata::HoaPack,
        render::{HoaDecoder, HoaNormalization, HoaRenderer},
    };
    for order in 0..=3 {
        let count = (usize::from(order) + 1).pow(2);
        let mapping: Vec<_> = (0..count)
            .map(|i| ((31 - i) as u8, (count - 1 - i) as u8))
            .collect();
        let mut pack = pack(2, None, &mapping);
        pack.type_label = 4;
        pack.hoa = Some(HoaPack {
            normalization: 0,
            nfc_distance: 0,
            screen_reference: false,
            order,
        });
        // Two selected paths share each physical HOA coefficient; gains sum to 2.
        let metadata = scene(vec![pack], vec![object(0, &[2]), object(1, &[2])]);
        let physical = input(count);
        let floats: Vec<_> = physical.iter().map(|&v| f32::from(v) / 32768.0).collect();
        let ordered: Vec<_> = floats
            .chunks_exact(count)
            .flat_map(|frame| {
                mapping
                    .iter()
                    .map(|&(_, physical)| frame[usize::from(physical)] * 2.0)
            })
            .collect();
        for layout in LAYOUTS {
            let mut actual = SceneRenderer::new(&metadata, count as u16, layout, None).unwrap();
            let mut integer = actual.clone();
            let mut explicit = HoaRenderer::new(
                HoaDecoder::new(order, HoaNormalization::Sn3d, layout, false).unwrap(),
            )
            .unwrap();
            let mut a = vec![0.0; 1024 * usize::from(layout.channels())];
            let mut b = a.clone();
            let mut c = a.clone();
            for _ in 0..4 {
                actual.process_f32(&floats, None, &mut a).unwrap();
                integer.process(&physical, None, &mut c).unwrap();
                explicit.process_f32(&ordered, &mut b).unwrap();
                assert_eq!(a, c);
                let peak = a
                    .iter()
                    .zip(&b)
                    .map(|(a, b)| (a - b).abs())
                    .fold(0.0_f32, f32::max);
                assert!(peak < 2e-7, "order{order} layout{layout:?} delta{peak}");
            }
            let mut clone = actual.clone();
            a.fill(42.0);
            let mut invalid = floats.clone();
            invalid[0] = f32::NAN;
            assert!(actual.process_f32(&invalid, None, &mut a).is_err());
            assert!(a.iter().all(|v| *v == 42.0));
            actual.process_f32(&floats, None, &mut a).unwrap();
            clone.process_f32(&floats, None, &mut c).unwrap();
            assert_eq!(a, c);
            actual.reset().unwrap();
            integer.reset().unwrap();
            actual.process_f32(&floats, None, &mut a).unwrap();
            integer.process(&physical, None, &mut c).unwrap();
            assert_eq!(a, c);
        }
        let mut invalid = metadata.clone();
        invalid.packs[0].channels.pop();
        assert!(SceneRenderer::new(&invalid, count as u16, BedLayout::Stereo, None).is_err());
        for normalization in 1..4 {
            let mut invalid = metadata.clone();
            invalid.packs[0].hoa.as_mut().unwrap().normalization = normalization;
            assert!(SceneRenderer::new(&invalid, count as u16, BedLayout::Stereo, None).is_err());
        }
    }
}
