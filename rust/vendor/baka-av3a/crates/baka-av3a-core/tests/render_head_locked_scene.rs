use baka_av3a_core::{
    metadata::{
        AudioPack, Content, DynamicMetadata, DynamicObject, EncodedGain, HoaPack, ObjectParameters,
        ObjectPosition, Programme, SpatialControls, StaticChannel, StaticMetadata, StaticObject,
    },
    render::{
        BedLayout, BinauralLfe, BinauralSceneConfig, HeadOrientation, HrirBank, LookAheadLimiter,
        SceneBinauralRenderer, SceneNearFieldConfig, SceneRenderConfig, SceneRenderer,
    },
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
const YAWS: [f64; 9] = [0., 90., -45., 180., 10., -90., 55., 0., 0.];

fn bank(constant: bool) -> HrirBank {
    let source = include_bytes!("fixtures/synthetic_hrir.bin");
    let mut bytes = source[..28].to_vec();
    bytes[16..20].copy_from_slice(&8u32.to_le_bytes());
    for direction in 0..6 {
        let offset = 28 + direction * 8200;
        bytes.extend_from_slice(&source[offset..offset + 8]);
        for ear in 0..2 {
            for tap in 0..8 {
                let value = if constant {
                    if tap == 0 { 0.05 } else { 0. }
                } else {
                    (direction + 1) as f32
                        * (ear + 1) as f32
                        * if tap == ear + 1 {
                            0.02
                        } else if tap == 7 {
                            -0.003
                        } else {
                            0.
                        }
                };
                bytes.extend_from_slice(&value.to_le_bytes());
            }
        }
    }
    bytes.extend_from_slice(&source[28 + 6 * 8200..]);
    HrirBank::from_bytes(&bytes).unwrap()
}
fn pack(index: u8, label: u8, channels: Vec<(u8, Option<u8>)>) -> AudioPack {
    AudioPack {
        index,
        importance: None,
        type_label: label,
        absolute_distance: 23,
        hoa: None,
        format_id: if label == 1 { Some(2) } else { None },
        matrix_outputs: vec![],
        start_index: None,
        channels,
    }
}
fn metadata(nfc: u8) -> StaticMetadata {
    let mut packs = vec![
        pack(0, 1, vec![(0, Some(0)), (1, Some(1))]),
        pack(1, 3, vec![(2, Some(2))]),
        pack(2, 3, vec![(3, Some(3))]),
    ];
    let mut objects: Vec<_> = (0..2)
        .map(|index| StaticObject {
            index,
            language: None,
            dialogue: None,
            importance: None,
            disable_ducking: false,
            interaction: None,
            gain: None,
            head_locked: index == 1,
            muted: false,
            packs: vec![0, index + 1],
        })
        .collect();
    objects[1].gain = Some(EncodedGain {
        decibels: false,
        upper: false,
        index: 31,
    });
    if nfc != 0 {
        let mut hoa = pack(3, 4, (0..4).map(|i| (i, Some(3 - i))).collect());
        hoa.hoa = Some(HoaPack {
            normalization: 0,
            nfc_distance: 7,
            screen_reference: false,
            order: 1,
        });
        packs.push(hoa);
        for (index, object) in objects.iter_mut().enumerate() {
            if nfc & (1 << index) != 0 {
                object.packs.push(3);
            }
        }
    }
    StaticMetadata {
        basic_level: 0,
        programme: Programme {
            language: None,
            ducking_depth: None,
            loudness: None,
            screen: None,
            contents: vec![0],
        },
        contents: vec![Content {
            index: 0,
            language: None,
            loudness: None,
            dialogue: None,
            complementary_objects: vec![],
            objects: vec![0, 1],
        }],
        objects,
        packs,
        channels: (0..4)
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
fn dynamic(block: usize) -> DynamicMetadata {
    DynamicMetadata {
        level: 0,
        objects: (2..4)
            .map(|transport_channel| DynamicObject {
                transport_channel,
                parameters: Some(ObjectParameters {
                    position: if transport_channel == 2 {
                        ObjectPosition::Spherical([30 + block as i16 * 8, 10, 8])
                    } else {
                        ObjectPosition::Cartesian([-30, 20, 5])
                    },
                    extent: Some([30, 6, 4]),
                    gain: Some(32),
                    diffuse: Some(64),
                    jump_position: block == 1,
                    importance: None,
                    controls: None,
                }),
            })
            .collect(),
    }
}
fn config(bank: &HrirBank, layout: BedLayout, nfc: u8) -> BinauralSceneConfig {
    BinauralSceneConfig {
        virtual_layout: layout,
        lfe: BinauralLfe::Mute,
        reproduction_screen: None,
        near_field: (nfc != 0).then_some(SceneNearFieldConfig {
            sample_rate: bank.sample_rate(),
            speaker_distance: f64::from(bank.measurement_radius()),
        }),
    }
}
fn signal(block: usize) -> Vec<f32> {
    (0..4096)
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
fn directions(layout: BedLayout) -> Vec<(f64, f64, f64)> {
    let (azimuths, upper): (&[f64], usize) = match layout {
        BedLayout::Stereo => (&[30., -30.], 2),
        BedLayout::Surround51 => (&[30., -30., 0., 0., 110., -110.], 6),
        BedLayout::Surround71 => (&[30., -30., 0., 0., 90., -90., 135., -135.], 8),
        BedLayout::Surround512 => (&[30., -30., 0., 0., 110., -110., 30., -30.], 6),
        BedLayout::Surround514 => (&[30., -30., 0., 0., 110., -110., 30., -30., 110., -110.], 6),
        BedLayout::Surround712 => (&[30., -30., 0., 0., 90., -90., 135., -135., 45., -45.], 8),
        BedLayout::Surround714 => (
            &[
                30., -30., 0., 0., 90., -90., 135., -135., 45., -45., 135., -135.,
            ],
            8,
        ),
    };
    azimuths
        .iter()
        .enumerate()
        .map(|(i, &azimuth)| {
            (
                azimuth,
                if i >= upper { 30. } else { 0. },
                if layout != BedLayout::Stereo && i == 3 {
                    0.
                } else {
                    1.
                },
            )
        })
        .collect()
}
fn taps(bank: &HrirBank, azimuth: f64, elevation: f64, gain: f64, ear: usize) -> Vec<f64> {
    let weights = bank
        .interpolate((azimuth + 180.).rem_euclid(360.) - 180., elevation)
        .unwrap();
    let mut taps = vec![0.; bank.tap_count()];
    for (index, weight) in weights.indices.into_iter().zip(weights.weights) {
        let response = &bank.measurements()[index];
        let values = if ear == 0 {
            &response.left
        } else {
            &response.right
        };
        for (target, &value) in taps.iter_mut().zip(values) {
            *target += f64::from(value) * weight * gain;
        }
    }
    taps
}

fn oracle(bank: HrirBank, layout: BedLayout, nfc: u8) {
    let metadata = metadata(nfc);
    let config = config(&bank, layout, nfc);
    let count = usize::from(layout.channels());
    let mut renderer =
        SceneBinauralRenderer::new(bank.clone(), bank.sample_rate(), &metadata, 4, None, config)
            .unwrap();
    let mut references: Vec<_> = (0..2)
        .map(|space| {
            let mut data = metadata.clone();
            for (index, object) in data.objects.iter_mut().enumerate() {
                object.head_locked = false;
                object.muted = index != space;
            }
            SceneRenderer::new_configured(
                &data,
                4,
                None,
                SceneRenderConfig {
                    output: layout,
                    reproduction_screen: None,
                    near_field: config.near_field,
                },
            )
            .unwrap()
        })
        .collect();
    let mut buses = [vec![0.; 9 * 1024 * count], vec![0.; 9 * 1024 * count]];
    let mut actual = vec![0.; 9 * 2048];
    for (block, &yaw) in YAWS.iter().enumerate() {
        renderer
            .set_orientation(
                HeadOrientation::from_yaw_pitch_roll(yaw, 0., 0.).unwrap(),
                block == 2,
            )
            .unwrap();
        if block < 3 {
            let signal = signal(block);
            let data = dynamic(block);
            renderer
                .process_f32(
                    &signal,
                    Some(&data),
                    &mut actual[block * 2048..(block + 1) * 2048],
                )
                .unwrap();
            for (index, reference) in references.iter_mut().enumerate() {
                reference
                    .process_f32(
                        &signal,
                        Some(&data),
                        &mut buses[index][block * 1024 * count..(block + 1) * 1024 * count],
                    )
                    .unwrap();
            }
        } else {
            renderer
                .process_silence(&mut actual[block * 2048..(block + 1) * 2048])
                .unwrap();
            for (index, reference) in references.iter_mut().enumerate() {
                reference
                    .process_silence(
                        &mut buses[index][block * 1024 * count..(block + 1) * 1024 * count],
                    )
                    .unwrap();
            }
        }
    }
    // Remove the quiet reference buses' 99-sample limiter alignment, perform
    // source-time FIR interpolation independently, then limit their sum once.
    let frames = 9 * 1024;
    let mut expected = vec![0f64; frames * 2];
    for (space, bus) in buses.iter().enumerate() {
        for (channel, (azimuth, elevation, gain)) in directions(layout).into_iter().enumerate() {
            for (block, &yaw) in YAWS.iter().enumerate() {
                let yaw = if space == 0 { yaw } else { 0. };
                let old_yaw = if space == 0 && block > 0 {
                    YAWS[block - 1]
                } else {
                    yaw
                };
                for ear in 0..2 {
                    let old = taps(&bank, azimuth - old_yaw, elevation, gain, ear);
                    let target = taps(&bank, azimuth - yaw, elevation, gain, ear);
                    for sample in 0..1024 {
                        let frame = block * 1024 + sample;
                        let input = bus
                            .get((frame + 99) * count + channel)
                            .copied()
                            .unwrap_or(0.);
                        let t = if block == 0 || block == 2 {
                            1.
                        } else {
                            sample as f64 / 1024.
                        };
                        for tap in 0..bank.tap_count().min(frames - frame) {
                            expected[(frame + tap) * 2 + ear] +=
                                f64::from(input) * (old[tap] * (1. - t) + target[tap] * t);
                        }
                    }
                }
            }
        }
    }
    let mut expected: Vec<_> = expected.into_iter().map(|v| v as f32).collect();
    LookAheadLimiter::new(2)
        .unwrap()
        .process(&mut expected)
        .unwrap();
    close(&actual, &expected, 3e-7);
    assert!(actual[8 * 2048..].iter().all(|v| v.abs() < 1e-10));
    assert_eq!(renderer.delay_samples(), if nfc == 0 { 2147 } else { 2659 });
    assert_eq!(renderer.object_references(), [2, 3]);
    assert_eq!(renderer.objects()[0], references[0].objects()[0]);
    assert_eq!(renderer.objects()[1], references[1].objects()[1]);
}

#[test]
fn independent_moving_fir_covers_shared_beds_objects_and_each_nfc_space() {
    for layout in LAYOUTS {
        oracle(bank(false), layout, 0);
    }
    for nfc in 1..=3 {
        oracle(bank(false), BedLayout::Surround714, nfc);
    }
}

#[test]
fn head_only_is_pose_invariant_and_selection_avoids_unused_head_paths() {
    let bank = bank(false);
    for nfc in [0, 2] {
        let metadata = metadata(nfc);
        let config = config(&bank, BedLayout::Surround714, nfc);
        let mut moving =
            SceneBinauralRenderer::new(bank.clone(), 48000, &metadata, 4, Some(&[1]), config)
                .unwrap();
        let mut fixed = moving.clone();
        let mut a = vec![0.; 2048];
        let mut b = a.clone();
        for block in 0..8 {
            moving
                .set_orientation(
                    HeadOrientation::from_yaw_pitch_roll(block as f64 * 41., -27., 13.).unwrap(),
                    block == 3,
                )
                .unwrap();
            moving
                .process_f32(&signal(block), Some(&dynamic(block)), &mut a)
                .unwrap();
            fixed
                .process_f32(&signal(block), Some(&dynamic(block)), &mut b)
                .unwrap();
            assert_eq!(a, b);
        }
        moving.reset().unwrap();
        fixed.reset().unwrap();
        for _ in 0..5 {
            moving.process_f32(&signal(0), None, &mut a).unwrap();
            fixed.process_f32(&signal(0), None, &mut b).unwrap();
            assert_eq!(a, b);
        }
    }
    let metadata = metadata(0);
    let config = config(&bank, BedLayout::Stereo, 0);
    let mut selected =
        SceneBinauralRenderer::new(bank.clone(), 48000, &metadata, 4, Some(&[0]), config).unwrap();
    let mut all_world = metadata.clone();
    all_world.objects[1].head_locked = false;
    let mut reference =
        SceneBinauralRenderer::new(bank, 48000, &all_world, 4, Some(&[0]), config).unwrap();
    let mut a = vec![0.; 2048];
    let mut b = a.clone();
    for _ in 0..5 {
        selected
            .process_f32(&signal(0), Some(&dynamic(0)), &mut a)
            .unwrap();
        reference
            .process_f32(&signal(0), Some(&dynamic(0)), &mut b)
            .unwrap();
        assert_eq!(a, b);
    }
}

#[test]
fn second_bus_failure_preserves_both_histories_pending_pose_and_current_targets() {
    let bank = bank(false);
    let metadata = metadata(3);
    let config = config(&bank, BedLayout::Surround714, 3);
    let mut renderer =
        SceneBinauralRenderer::new(bank.clone(), 48000, &metadata, 4, None, config).unwrap();
    let mut output = vec![0.; 2048];
    for _ in 0..3 {
        renderer
            .process_f32(&signal(0), Some(&dynamic(0)), &mut output)
            .unwrap();
    }
    let pose = HeadOrientation::from_yaw_pitch_roll(37., 18., -29.).unwrap();
    renderer.set_orientation(pose, true).unwrap();
    let mut reference = renderer.clone();
    let targets = renderer.objects().to_vec();
    let mut invalid = dynamic(1);
    invalid.objects[1].parameters.as_mut().unwrap().controls = Some(SpatialControls {
        channel_lock: None,
        divergence: None,
        screen_reference: Some(true),
        screen_edge_lock: None,
    });
    output.fill(123.);
    assert!(
        renderer
            .process_f32(&signal(1), Some(&invalid), &mut output)
            .is_err()
    );
    assert!(
        renderer
            .process_f32(&[f32::NAN; 4096], Some(&dynamic(1)), &mut output)
            .is_err()
    );
    assert!(
        renderer
            .process(&[1; 4095], Some(&dynamic(1)), &mut output)
            .is_err()
    );
    assert!(
        renderer
            .process(&[1; 4096], Some(&dynamic(1)), &mut output[..2047])
            .is_err()
    );
    assert!(output.iter().all(|v| *v == 123.));
    assert_eq!(renderer.objects(), targets);
    assert_eq!(renderer.orientation(), pose);
    let mut expected = output.clone();
    for _ in 0..4 {
        renderer.process_f32(&signal(0), None, &mut output).unwrap();
        reference
            .process_f32(&signal(0), None, &mut expected)
            .unwrap();
        assert_eq!(output, expected);
    }
    renderer.reset().unwrap();
    let mut fresh = SceneBinauralRenderer::new(bank, 48000, &metadata, 4, None, config).unwrap();
    fresh.set_orientation(pose, true).unwrap();
    for _ in 0..5 {
        renderer
            .process(&[1; 4096], Some(&dynamic(0)), &mut output)
            .unwrap();
        fresh
            .process(&[1; 4096], Some(&dynamic(0)), &mut expected)
            .unwrap();
        assert_eq!(output, expected);
    }
}

#[test]
fn one_final_limiter_retains_headroom_and_source_time_startup_alignment() {
    let bank = bank(true);
    let mut metadata = metadata(0);
    for object in &mut metadata.objects {
        object.gain = Some(EncodedGain {
            decibels: false,
            upper: true,
            index: 63,
        });
    }
    let config = config(&bank, BedLayout::Stereo, 0);
    for level in [0.5, 16.] {
        let mut renderer =
            SceneBinauralRenderer::new(bank.clone(), 48000, &metadata, 4, None, config).unwrap();
        renderer
            .set_orientation(
                HeadOrientation::from_yaw_pitch_roll(90., 0., 0.).unwrap(),
                false,
            )
            .unwrap();
        let mut actual = vec![0.; 10 * 2048];
        let mut expected = actual.clone();
        for frame in 0..5 * 1024 {
            let t = if frame < 1024 {
                frame as f32 / 1024.
            } else {
                1.
            };
            for ear in 0..2 {
                expected[(frame + 2048) * 2 + ear] = level * t * (16. * 0.85) * 0.05 * 2.;
            }
        }
        LookAheadLimiter::new(2)
            .unwrap()
            .process(&mut expected)
            .unwrap();
        let input: Vec<_> = (0..1024).flat_map(|_| [level, 0., 0., 0.]).collect();
        for block in 0..10 {
            if block < 5 {
                renderer
                    .process_f32(&input, None, &mut actual[block * 2048..(block + 1) * 2048])
                    .unwrap();
            } else {
                renderer
                    .process_silence(&mut actual[block * 2048..(block + 1) * 2048])
                    .unwrap();
            }
        }
        close(&actual, &expected, 3e-5);
        let first = actual
            .as_chunks::<2>()
            .0
            .iter()
            .position(|frame| frame.iter().any(|v| v.abs() > 1e-5))
            .unwrap();
        assert_eq!(first, 2148);
        if level == 0.5 {
            assert!(
                actual[4 * 2048..5 * 2048]
                    .iter()
                    .all(|v| (*v - 0.68).abs() < 3e-7)
            );
        }
    }
}

#[test]
#[ignore = "requires private measured HRIR bank through BAKA_AV3A_HRIR_BANK"]
fn measured_world_head_locked_motion_and_nfc_match_scalar_fir() {
    let bank = HrirBank::from_bytes(
        &std::fs::read(std::env::var("BAKA_AV3A_HRIR_BANK").unwrap()).unwrap(),
    )
    .unwrap();
    oracle(bank, BedLayout::Surround714, 3);
}

#[test]
fn eight_shared_hoa_packs_keep_independent_clone_reset_and_integer_float_state() {
    let bank = bank(false);
    let mut metadata = metadata(3);
    let template = metadata.packs[3].clone();
    metadata.packs = (0..8)
        .map(|index| {
            let mut pack = template.clone();
            pack.index = index;
            pack.channels = (0..16).map(|i| (i, Some(15 - i))).collect();
            pack.hoa.as_mut().unwrap().order = 3;
            pack.hoa.as_mut().unwrap().nfc_distance = index + 1;
            pack
        })
        .collect();
    metadata.channels = (0..16)
        .map(|index| StaticChannel {
            index,
            gain: None,
            speaker: None,
            matrix_coefficients: vec![],
        })
        .collect();
    for object in &mut metadata.objects {
        object.packs = (0..8).collect();
    }
    let config = config(&bank, BedLayout::Surround714, 3);
    let mut renderer =
        SceneBinauralRenderer::new(bank, 48000, &metadata, 16, None, config).unwrap();
    let mut reference = renderer.clone();
    let input: Vec<i16> = (0..16384).map(|i| (i % 31) as i16 - 15).collect();
    let floats: Vec<_> = input.iter().map(|v| f32::from(*v) / 32768.).collect();
    let mut a = vec![0.; 2048];
    let mut b = a.clone();
    for _ in 0..4 {
        renderer.process(&input, None, &mut a).unwrap();
        reference.process_f32(&floats, None, &mut b).unwrap();
        assert_eq!(a, b);
    }
    renderer.reset().unwrap();
    reference.reset().unwrap();
    for _ in 0..5 {
        renderer.process(&input, None, &mut a).unwrap();
        reference.process_f32(&floats, None, &mut b).unwrap();
        assert_eq!(a, b);
    }
    for _ in 0..6 {
        renderer.process_silence(&mut a).unwrap();
    }
    assert!(a.iter().all(|v| v.abs() < 1e-10));
    assert!(renderer.object_references().is_empty());
    assert!(renderer.objects().is_empty());
}
