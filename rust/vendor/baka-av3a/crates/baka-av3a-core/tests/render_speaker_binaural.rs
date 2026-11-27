use baka_av3a_core::{
    metadata::{
        AudioPack, Content, DynamicMetadata, DynamicObject, EncodedGain, ObjectParameters,
        ObjectPosition, Programme, StaticChannel, StaticMetadata, StaticObject,
    },
    render::{
        BedLayout, BinauralLfe, BinauralRenderer, BinauralSceneConfig, BinauralSource,
        HeadOrientation, HoaBinauralRenderer, HoaDecoder, HoaNormalization, HoaRenderer, HrirBank,
        SceneBinauralRenderer, SceneRenderer, SpeakerBinauralRenderer,
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

fn bank(constant: bool) -> HrirBank {
    let original = include_bytes!("fixtures/synthetic_hrir.bin");
    let mut bytes = original[..28].to_vec();
    bytes[16..20].copy_from_slice(&8u32.to_le_bytes());
    for direction in 0..6 {
        let offset = 28 + direction * (8 + 8192);
        bytes.extend_from_slice(&original[offset..offset + 8]);
        for ear in 0..2 {
            for tap in 0..8 {
                let value = if constant {
                    if tap == 0 { 0.05 } else { 0.0 }
                } else {
                    (direction + 1) as f32
                        * (ear + 1) as f32
                        * if tap == ear + 1 {
                            0.02
                        } else if tap == 7 {
                            -0.003
                        } else {
                            0.0
                        }
                };
                bytes.extend_from_slice(&value.to_le_bytes());
            }
        }
    }
    bytes.extend_from_slice(&original[28 + 6 * (8 + 8192)..]);
    HrirBank::from_bytes(&bytes).unwrap()
}

fn metadata(bed: bool) -> StaticMetadata {
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
            objects: vec![0],
        }],
        objects: vec![StaticObject {
            index: 0,
            language: None,
            dialogue: None,
            importance: None,
            disable_ducking: false,
            interaction: None,
            gain: None,
            head_locked: false,
            muted: false,
            packs: vec![0],
        }],
        packs: vec![AudioPack {
            index: 0,
            importance: None,
            type_label: if bed { 1 } else { 3 },
            absolute_distance: 0,
            hoa: None,
            format_id: if bed { Some(2) } else { None },
            matrix_outputs: vec![],
            start_index: None,
            channels: vec![(0, Some(0)), (1, Some(1))],
        }],
        channels: (0..2)
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
fn dynamic() -> DynamicMetadata {
    DynamicMetadata {
        level: 0,
        objects: (0..2)
            .map(|transport_channel| DynamicObject {
                transport_channel,
                parameters: Some(ObjectParameters {
                    position: if transport_channel == 0 {
                        ObjectPosition::Spherical([40, 12, 8])
                    } else {
                        ObjectPosition::Cartesian([30, 20, 5])
                    },
                    extent: Some([30, 6, 4]),
                    gain: Some(32),
                    diffuse: Some(64),
                    jump_position: false,
                    importance: None,
                    controls: None,
                }),
            })
            .collect(),
    }
}
fn config(layout: BedLayout) -> BinauralSceneConfig {
    BinauralSceneConfig {
        virtual_layout: layout,
        lfe: BinauralLfe::Front { gain: 0.5 },
        reproduction_screen: None,
        near_field: None,
    }
}
fn close(actual: &[f32], expected: &[f32]) {
    let peak = actual
        .iter()
        .zip(expected)
        .map(|(a, b)| (a - b).abs())
        .fold(0f32, f32::max);
    assert!(peak < 2e-7, "PCM error {peak:e}");
}

// Scalar time-domain convolution is independent of the production FFT path.
// The quiet loudspeaker reference already contains the single limiter delay.
fn fir(bank: &HrirBank, bus: &[f32], sources: &[BinauralSource]) -> Vec<f32> {
    let frames = bus.len() / sources.len();
    let mut output = vec![0f32; frames * 2];
    for (channel, source) in sources.iter().enumerate() {
        let weights = bank.interpolate(source.azimuth, source.elevation).unwrap();
        for (index, weight) in weights.indices.into_iter().zip(weights.weights) {
            let measurement = &bank.measurements()[index];
            for (ear, taps) in [&measurement.left, &measurement.right]
                .into_iter()
                .enumerate()
            {
                for (tap, coefficient) in taps.iter().enumerate() {
                    for frame in 0..frames - tap {
                        output[(frame + tap) * 2 + ear] += bus[frame * sources.len() + channel]
                            * (*coefficient * weight as f32 * source.gain);
                    }
                }
            }
        }
    }
    output
}

#[test]
fn scene_extent_diffusion_and_cartesian_match_scalar_fir_in_seven_layouts() {
    let bank = bank(false);
    let scene = metadata(false);
    for layout in LAYOUTS {
        let sources = SpeakerBinauralRenderer::new(
            bank.clone(),
            48000,
            layout,
            BinauralLfe::Front { gain: 0.5 },
        )
        .unwrap()
        .sources()
        .to_vec();
        let mut reference = SceneRenderer::new(&scene, 2, layout, None).unwrap();
        let mut renderer =
            SceneBinauralRenderer::new(bank.clone(), 48000, &scene, 2, None, config(layout))
                .unwrap();
        let count = usize::from(layout.channels());
        let mut bus = vec![0.; 8 * 1024 * count];
        let mut actual = vec![0.; 8 * 2048];
        for block in 0..8 {
            let output = &mut actual[block * 2048..(block + 1) * 2048];
            let speaker = &mut bus[block * 1024 * count..(block + 1) * 1024 * count];
            if block < 3 {
                let signal: Vec<_> = (0..2048)
                    .map(|i| ((i * 37 + block * 11) % 101) as f32 * 1e-5)
                    .collect();
                let data = dynamic();
                reference
                    .process_f32(&signal, Some(&data), speaker)
                    .unwrap();
                renderer.process_f32(&signal, Some(&data), output).unwrap();
            } else {
                reference.process_silence(speaker).unwrap();
                renderer.process_silence(output).unwrap();
            }
        }
        close(&actual, &fir(&bank, &bus, &sources));
        assert!(actual[7 * 2048..].iter().all(|v| v.abs() < 1e-12));
        assert_eq!(renderer.tail_samples(), 2154);
    }
}

#[test]
fn hoa_all_orders_and_layouts_match_signed_matrix_then_scalar_fir() {
    let bank = bank(false);
    for layout in LAYOUTS {
        let sources = SpeakerBinauralRenderer::new(bank.clone(), 48000, layout, BinauralLfe::Mute)
            .unwrap()
            .sources()
            .to_vec();
        for order in 0..=3 {
            let decoder =
                HoaDecoder::with_resolution(order, HoaNormalization::Sn3d, layout, true, 16)
                    .unwrap();
            let inputs = usize::from(decoder.input_channels());
            let mut reference = HoaRenderer::new(decoder.clone()).unwrap();
            let mut renderer = HoaBinauralRenderer::new(decoder, bank.clone(), 48000).unwrap();
            let count = usize::from(layout.channels());
            let mut bus = vec![0.; 5 * 1024 * count];
            let mut actual = vec![0.; 5 * 2048];
            for block in 0..5 {
                let signal: Vec<_> = (0..1024 * inputs)
                    .map(|i| {
                        if block == 0 {
                            ((i * 37 % 101) as f32 - 50.) * 1e-5
                        } else {
                            0.
                        }
                    })
                    .collect();
                reference
                    .process_f32(
                        &signal,
                        &mut bus[block * 1024 * count..(block + 1) * 1024 * count],
                    )
                    .unwrap();
                renderer
                    .process_f32(&signal, &mut actual[block * 2048..(block + 1) * 2048])
                    .unwrap();
            }
            close(&actual, &fir(&bank, &bus, &sources));
            assert!(actual[4 * 2048..].iter().all(|v| v.abs() < 1e-10));
        }
    }
}

#[test]
fn intermediate_bus_retains_headroom_and_has_no_second_limiter_delay() {
    let mut scene = metadata(true);
    scene.objects[0].gain = Some(EncodedGain {
        decibels: false,
        upper: true,
        index: 63,
    });
    let mut renderer = SceneBinauralRenderer::new(
        bank(true),
        48000,
        &scene,
        2,
        None,
        config(BedLayout::Stereo),
    )
    .unwrap();
    let signal: Vec<_> = (0..1024).flat_map(|_| [0.5, 0.]).collect();
    let mut output = vec![0.; 2048];
    for _ in 0..6 {
        renderer.process_f32(&signal, None, &mut output).unwrap();
    }
    for value in &output {
        // Stereo-to-stereo bed coefficients include the existing 0.85 gain.
        assert!((value - 0.34).abs() < 2e-7, "{value}");
    }
    renderer.reset().unwrap();
    let mut all = vec![0.; 4 * 2048];
    let mut pulse = vec![0.; 2048];
    // Sample zero is deliberately muted by the upstream startup ramp.
    pulse[2] = 0.001;
    renderer
        .process_f32(&pulse, None, &mut all[..2048])
        .unwrap();
    for block in 1..4 {
        renderer
            .process_silence(&mut all[block * 2048..(block + 1) * 2048])
            .unwrap();
    }
    let first = all
        .as_chunks::<2>()
        .0
        .iter()
        .position(|frame| frame.iter().any(|v| v.abs() > 1e-10))
        .unwrap();
    assert_eq!(first, SceneBinauralRenderer::DELAY_SAMPLES + 1);
    assert_eq!(first, 2148);
}

#[test]
fn yaw_rotates_world_speakers_but_preserves_frontal_lfe_and_reset() {
    for layout in LAYOUTS {
        let mut actual = SpeakerBinauralRenderer::new(
            bank(false),
            48000,
            layout,
            BinauralLfe::Front { gain: 0.75 },
        )
        .unwrap();
        let mut sources = actual.sources().to_vec();
        for (index, source) in sources.iter_mut().enumerate() {
            if layout == BedLayout::Stereo || index != 3 {
                source.azimuth = (source.azimuth - 90. + 180.).rem_euclid(360.) - 180.;
            }
        }
        let pose = HeadOrientation::from_yaw_pitch_roll(90., 0., 0.).unwrap();
        actual.set_orientation(pose, true).unwrap();
        let mut reference = BinauralRenderer::new(bank(false), 48000, &sources).unwrap();
        reference
            .set_sources(&sources, &vec![true; sources.len()])
            .unwrap();
        let signal: Vec<_> = (0..1024 * sources.len())
            .map(|i| (i % 101) as f32 * 1e-4)
            .collect();
        let mut a = vec![0.; 2048];
        let mut b = a.clone();
        for _ in 0..3 {
            actual.process(&signal, &mut a).unwrap();
            reference.process(&signal, &mut b).unwrap();
            close(&a, &b);
        }
        actual.reset();
        reference.reset();
        reference
            .set_sources(&sources, &vec![true; sources.len()])
            .unwrap();
        actual.process(&signal, &mut a).unwrap();
        reference.process(&signal, &mut b).unwrap();
        close(&a, &b);
        assert_eq!(actual.orientation(), pose);
    }
}

#[test]
fn rejected_blocks_preserve_pending_pose_history_and_outputs() {
    let scene = metadata(false);
    let mut renderer = SceneBinauralRenderer::new(
        bank(false),
        48000,
        &scene,
        2,
        None,
        config(BedLayout::Surround714),
    )
    .unwrap();
    renderer
        .set_orientation(
            HeadOrientation::from_yaw_pitch_roll(37., 18., -29.).unwrap(),
            true,
        )
        .unwrap();
    let mut reference = renderer.clone();
    let mut output = vec![123.; 2048];
    assert!(
        renderer
            .process_f32(&[f32::NAN; 2048], None, &mut output)
            .is_err()
    );
    assert!(
        renderer
            .process_f32(&[257.; 2048], None, &mut output)
            .is_err()
    );
    assert!(renderer.process(&[0; 2047], None, &mut output).is_err());
    let mut bad = dynamic();
    bad.objects[0].transport_channel = 31;
    assert!(
        renderer
            .process(&[0; 2048], Some(&bad), &mut output)
            .is_err()
    );
    assert!(output.iter().all(|v| *v == 123.));
    let mut short = [123.; 2];
    assert!(renderer.process(&[1; 2048], None, &mut short).is_err());
    assert_eq!(short, [123.; 2]);
    let mut expected = vec![0.; 2048];
    for _ in 0..4 {
        renderer.process(&[1; 2048], None, &mut output).unwrap();
        reference.process(&[1; 2048], None, &mut expected).unwrap();
        assert_eq!(output, expected);
    }
    for gain in [f32::NAN, -1., 16.01] {
        assert!(
            SpeakerBinauralRenderer::new(
                bank(false),
                48000,
                BedLayout::Stereo,
                BinauralLfe::Front { gain }
            )
            .is_err()
        );
    }
    assert!(
        SpeakerBinauralRenderer::new(bank(false), 44100, BedLayout::Stereo, BinauralLfe::Mute)
            .is_err()
    );
}

#[test]
fn hoa_integer_float_reset_and_invalid_blocks_preserve_state() {
    let decoder =
        HoaDecoder::with_resolution(3, HoaNormalization::N3d, BedLayout::Surround714, false, 16)
            .unwrap();
    let mut renderer = HoaBinauralRenderer::new(decoder, bank(false), 48000).unwrap();
    renderer
        .set_orientation(
            HeadOrientation::from_yaw_pitch_roll(28., -19., 13.).unwrap(),
            true,
        )
        .unwrap();
    let mut reference = renderer.clone();
    let input: Vec<i16> = (0..16384).map(|i| (i % 71) as i16 - 35).collect();
    let floats: Vec<_> = input.iter().map(|v| f32::from(*v) / 32768.).collect();
    let mut a = vec![57.; 2048];
    let mut b = vec![0.; 2048];
    assert!(
        renderer
            .process_f32(&[f32::INFINITY; 16384], &mut a)
            .is_err()
    );
    assert!(renderer.process(&input[..16383], &mut a).is_err());
    assert!(renderer.process(&input, &mut a[..2047]).is_err());
    assert!(a.iter().all(|v| *v == 57.));
    for _ in 0..4 {
        renderer.process(&input, &mut a).unwrap();
        reference.process_f32(&floats, &mut b).unwrap();
        assert_eq!(a, b);
    }
    renderer.reset();
    reference.reset();
    for _ in 0..4 {
        renderer.process(&input, &mut a).unwrap();
        reference.process_f32(&floats, &mut b).unwrap();
        assert_eq!(a, b);
    }
    for _ in 0..4 {
        renderer.process_silence(&mut a).unwrap();
    }
    assert!(a.iter().all(|v| v.abs() < 1e-10));
}

#[test]
fn lfe_policy_is_explicit_and_only_final_stereo_sum_is_limited() {
    let bank = bank(true);
    let mut muted = SpeakerBinauralRenderer::new(
        bank.clone(),
        48000,
        BedLayout::Surround51,
        BinauralLfe::Mute,
    )
    .unwrap();
    let mut front = SpeakerBinauralRenderer::new(
        bank.clone(),
        48000,
        BedLayout::Surround51,
        BinauralLfe::Front { gain: 2. },
    )
    .unwrap();
    let signal: Vec<_> = (0..1024).flat_map(|_| [0., 0., 0., 0.25, 0., 0.]).collect();
    let mut a = vec![0.; 2048];
    let mut b = a.clone();
    for _ in 0..3 {
        muted.process(&signal, &mut a).unwrap();
        front.process(&signal, &mut b).unwrap();
    }
    assert!(a.iter().all(|v| *v == 0.));
    assert!(b.iter().all(|v| (*v - 0.025).abs() < 1e-7));
    // Each virtual speaker alone would produce 0.6, but their sum is 3.6.
    // This must engage the final limiter after summation, rather than six
    // separate unity limiters that could let 3.6 reach the output.
    let signal = vec![12.; 6144];
    for _ in 0..12 {
        front.process(&signal, &mut b).unwrap();
    }
    assert!(b.iter().all(|v| v.is_finite() && *v > 0.9 && *v < 1.001));
}

#[test]
#[ignore = "requires private measured HRIR bank through BAKA_AV3A_HRIR_BANK"]
fn measured_scene_and_hoa_match_scalar_convolution() {
    let bank = HrirBank::from_bytes(
        &std::fs::read(std::env::var("BAKA_AV3A_HRIR_BANK").unwrap()).unwrap(),
    )
    .unwrap();
    let layout = BedLayout::Surround714;
    let rate = bank.sample_rate();
    let sources = SpeakerBinauralRenderer::new(bank.clone(), rate, layout, BinauralLfe::Mute)
        .unwrap()
        .sources()
        .to_vec();
    let scene = metadata(false);
    let mut config = config(layout);
    config.lfe = BinauralLfe::Mute;
    let mut renderer =
        SceneBinauralRenderer::new(bank.clone(), rate, &scene, 2, None, config).unwrap();
    let mut reference = SceneRenderer::new(&scene, 2, layout, None).unwrap();
    let mut actual = vec![0.; 6 * 2048];
    let mut bus = vec![0.; 6 * 12288];
    for block in 0..6 {
        let signal: Vec<_> = (0..2048)
            .map(|i| {
                if block == 0 {
                    ((i * 37 % 101) as f32 - 50.) * 1e-5
                } else {
                    0.
                }
            })
            .collect();
        reference
            .process_f32(
                &signal,
                Some(&dynamic()),
                &mut bus[block * 12288..(block + 1) * 12288],
            )
            .unwrap();
        renderer
            .process_f32(
                &signal,
                Some(&dynamic()),
                &mut actual[block * 2048..(block + 1) * 2048],
            )
            .unwrap();
    }
    close(&actual, &fir(&bank, &bus, &sources));
    let decoder = HoaDecoder::with_resolution(3, HoaNormalization::Sn3d, layout, true, 16).unwrap();
    let mut reference = HoaRenderer::new(decoder.clone()).unwrap();
    let mut renderer = HoaBinauralRenderer::new(decoder, bank.clone(), rate).unwrap();
    for block in 0..6 {
        let signal: Vec<_> = (0..16384)
            .map(|i| {
                if block == 0 {
                    ((i * 37 % 101) as f32 - 50.) * 1e-5
                } else {
                    0.
                }
            })
            .collect();
        reference
            .process_f32(&signal, &mut bus[block * 12288..(block + 1) * 12288])
            .unwrap();
        renderer
            .process_f32(&signal, &mut actual[block * 2048..(block + 1) * 2048])
            .unwrap();
    }
    close(&actual, &fir(&bank, &bus, &sources));
    eprintln!(
        "measured scene/HOA scalar FIR passed: rate={rate}, taps={}",
        bank.tap_count()
    );
}
