use baka_av3a_core::{
    metadata::{
        AudioPack, Content, DynamicMetadata, DynamicObject, EncodedGain, HoaPack, ObjectParameters,
        ObjectPosition, Programme, SpatialControls, StaticChannel, StaticMetadata, StaticObject,
    },
    render::{
        BedLayout, BinauralLfe, BinauralSceneConfig, HoaDecoder, HoaNearField, HoaNormalization,
        HrirBank, LookAheadLimiter, NearFieldConfig, SceneBinauralRenderer, SceneNearFieldConfig,
        SceneRenderConfig, SceneRenderer, ScreenEdges, SpeakerBinauralRenderer,
    },
};

fn object(index: u8, packs: Vec<u8>) -> StaticObject {
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
        packs,
    }
}
fn pack(index: u8, label: u8, mapping: Vec<(u8, Option<u8>)>) -> AudioPack {
    AudioPack {
        index,
        importance: None,
        type_label: label,
        absolute_distance: 23,
        hoa: None,
        format_id: if label == 1 { Some(2) } else { None },
        matrix_outputs: vec![],
        start_index: None,
        channels: mapping,
    }
}
fn metadata(order: u8, mixed: bool) -> StaticMetadata {
    let count = (order + 1).pow(2);
    let mapping: Vec<_> = (0..count).map(|i| (i, Some(count - 1 - i))).collect();
    let mut a = pack(0, 4, mapping.clone());
    a.hoa = Some(HoaPack {
        normalization: 0,
        nfc_distance: 4,
        screen_reference: false,
        order,
    });
    let mut b = pack(1, 4, mapping);
    b.hoa = a.hoa.clone();
    b.hoa.as_mut().unwrap().nfc_distance = 13;
    let mut packs = vec![a, b];
    let mut objects = vec![object(0, vec![0]), object(1, vec![1]), object(2, vec![0])];
    objects[2].gain = Some(EncodedGain {
        decibels: false,
        upper: false,
        index: 31,
    });
    if mixed {
        packs.push(pack(2, 1, vec![(0, Some(0)), (1, Some(1))]));
        packs.push(pack(3, 3, vec![(0, Some(0))]));
        objects.push(object(3, vec![2]));
        objects.push(object(4, vec![3]));
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
            objects: objects.iter().map(|o| o.index).collect(),
        }],
        objects,
        packs,
        channels: (0..count.max(2))
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
fn config(output: BedLayout) -> SceneRenderConfig {
    SceneRenderConfig {
        output,
        reproduction_screen: None,
        near_field: Some(SceneNearFieldConfig {
            sample_rate: 48000,
            speaker_distance: 2.0,
        }),
    }
}
fn dynamic(block: usize) -> DynamicMetadata {
    DynamicMetadata {
        level: 0,
        objects: vec![DynamicObject {
            transport_channel: 0,
            parameters: Some(ObjectParameters {
                position: if block.is_multiple_of(2) {
                    ObjectPosition::Cartesian([40, 18, 4])
                } else {
                    ObjectPosition::Spherical([-50, 10, 8])
                },
                extent: Some([20, 4, 2]),
                gain: Some(32),
                diffuse: Some(64),
                jump_position: block == 1,
                importance: None,
                controls: None,
            }),
        }],
    }
}
fn sparse_signal(channels: usize) -> Vec<f32> {
    let mut signal = vec![0.; 8 * 1024 * channels];
    for block in 0..3 {
        for frame in [0, 1, 511, 512, 1023] {
            for channel in 0..channels {
                signal[(block * 1024 + frame) * channels + channel] =
                    ((block * 31 + frame * 3 + channel * 11) % 101) as f32 * 0.00002 - 0.001;
            }
        }
    }
    signal
}
fn close(actual: &[f32], expected: &[f32], limit: f32) {
    let error = actual
        .iter()
        .zip(expected)
        .map(|(a, b)| (a - b).abs())
        .fold(0f32, f32::max);
    assert!(error < limit, "PCM error {error:e}");
}

// Independent time-domain convolution and signed matrix multiplication. Raw
// object/bed paths use their existing, separately tested loudspeaker renderer;
// no production scene-NFC routing, delay ring or summation code is used here.
fn scalar(
    metadata: &StaticMetadata,
    physical: usize,
    layout: BedLayout,
    signal: &[f32],
    raw: &[f32],
) -> Vec<f32> {
    let frames = signal.len() / physical;
    let outputs = usize::from(layout.channels());
    let mut expected = vec![0.; frames * outputs];
    expected[512 * outputs..].copy_from_slice(&raw[..(frames - 512) * outputs]);
    let scene = metadata.resolve_scene(physical as u16, None).unwrap();
    for pack in metadata.packs.iter().filter(|p| p.type_label == 4) {
        let order = pack.hoa.as_ref().unwrap().order;
        let config = NearFieldConfig::from_pack(pack, 2., 48000)
            .unwrap()
            .unwrap();
        let filter = HoaNearField::new(order, config).unwrap();
        let decoder = HoaDecoder::new(order, HoaNormalization::Sn3d, layout, false).unwrap();
        let transports = pack.transport_channels().unwrap();
        for (acn, (&channel, &(definition, _))) in transports.iter().zip(&pack.channels).enumerate()
        {
            let factor: f64 = scene
                .channels()
                .iter()
                .filter(|p| p.pack_index == pack.index && p.channel_index == definition)
                .map(|p| p.gain)
                .sum();
            let taps = filter.coefficients(acn.isqrt() as u8).unwrap();
            let mut filtered = vec![0f64; frames];
            for frame in 0..frames {
                let ramp = if frame < 1024 {
                    frame as f32 / 1024.
                } else {
                    1.
                };
                let value = signal[frame * physical + usize::from(channel)] * ramp;
                if value == 0. {
                    continue;
                }
                for (tap, &coefficient) in taps.iter().take(frames - frame).enumerate() {
                    filtered[frame + tap] += f64::from(value) * f64::from(coefficient);
                }
            }
            for frame in 0..frames - 2147 {
                for speaker in 0..outputs {
                    let gain =
                        (decoder.coefficients()[speaker * transports.len() + acn] * factor) as f32;
                    expected[(frame + 2147) * outputs + speaker] +=
                        (filtered[frame] * f64::from(gain)) as f32;
                }
            }
        }
    }
    expected
}

#[test]
fn shared_transports_with_two_distances_keep_objects_beds_and_source_time_updates() {
    for order in 0..=3 {
        for layout in [BedLayout::Stereo, BedLayout::Surround714] {
            let metadata = metadata(order, true);
            let physical = usize::from((order + 1).pow(2)).max(2);
            let signal = sparse_signal(physical);
            let mut raw_metadata = metadata.clone();
            for object in &mut raw_metadata.objects[..3] {
                object.muted = true;
            }
            for pack in &mut raw_metadata.packs[..2] {
                pack.hoa.as_mut().unwrap().nfc_distance = 0;
            }
            let screen = ScreenEdges::polar(-10., 5., 1., 80., 21. / 9.).unwrap();
            let mut reference = SceneRenderer::new_with_screen(
                &raw_metadata,
                physical as u16,
                layout,
                None,
                screen,
            )
            .unwrap();
            let mut config = config(layout);
            config.reproduction_screen = Some(screen);
            let mut renderer =
                SceneRenderer::new_configured(&metadata, physical as u16, None, config).unwrap();
            let outputs = usize::from(layout.channels());
            let mut raw = vec![0.; 8 * 1024 * outputs];
            let mut actual = raw.clone();
            for block in 0..8 {
                let mut data = dynamic(block);
                data.objects[0].parameters.as_mut().unwrap().controls = Some(SpatialControls {
                    channel_lock: None,
                    divergence: None,
                    screen_reference: Some(true),
                    screen_edge_lock: Some(0),
                });
                let source = &signal[block * 1024 * physical..(block + 1) * 1024 * physical];
                reference
                    .process_f32(
                        source,
                        Some(&data),
                        &mut raw[block * 1024 * outputs..(block + 1) * 1024 * outputs],
                    )
                    .unwrap();
                renderer
                    .process_f32(
                        source,
                        Some(&data),
                        &mut actual[block * 1024 * outputs..(block + 1) * 1024 * outputs],
                    )
                    .unwrap();
            }
            close(
                &actual,
                &scalar(&metadata, physical, layout, &signal, &raw),
                3e-7,
            );
            assert_eq!(renderer.delay_samples(), 2659);
            assert_eq!(renderer.tail_samples(), 3170);
            assert!(actual[7 * 1024 * outputs..].iter().all(|v| v.abs() < 1e-10));
        }
    }
}

#[test]
fn unified_limiter_follows_all_paths_and_order_zero_has_exact_alignment() {
    let mut metadata = metadata(0, true);
    metadata.packs.pop();
    metadata.objects.pop();
    metadata.contents[0].objects.pop();
    for object in &mut metadata.objects {
        object.gain = Some(EncodedGain {
            decibels: false,
            upper: true,
            index: 63,
        });
    }
    let layout = BedLayout::Stereo;
    let mut renderer = SceneRenderer::new_configured(&metadata, 2, None, config(layout)).unwrap();
    let coefficient = HoaDecoder::new(0, HoaNormalization::Sn3d, layout, false)
        .unwrap()
        .coefficients()[0] as f32;
    let mut expected = vec![0.; 10 * 2048];
    let mut actual = expected.clone();
    for frame in 0..6 * 1024 {
        let gain = if frame < 1024 {
            frame as f32 / 1024.
        } else {
            1.
        };
        expected[(frame + 2560) * 2] = 0.5 * gain * (16. * 0.85 + 48. * coefficient);
        expected[(frame + 2560) * 2 + 1] = 0.5 * gain * 48. * coefficient;
    }
    LookAheadLimiter::new(2)
        .unwrap()
        .process(&mut expected)
        .unwrap();
    for block in 0..10 {
        if block < 6 {
            let source: Vec<_> = (0..1024).flat_map(|_| [0.5, 0.]).collect();
            renderer
                .process_f32(&source, None, &mut actual[block * 2048..(block + 1) * 2048])
                .unwrap();
        } else {
            renderer
                .process_silence(&mut actual[block * 2048..(block + 1) * 2048])
                .unwrap();
        }
    }
    close(&actual, &expected, 3e-6);
    renderer.reset().unwrap();
    let mut pulse = [0.; 2048];
    pulse[2] = 0.001;
    actual.fill(0.);
    renderer
        .process_f32(&pulse, None, &mut actual[..2048])
        .unwrap();
    for block in 1..10 {
        renderer
            .process_silence(&mut actual[block * 2048..(block + 1) * 2048])
            .unwrap();
    }
    let first = actual
        .as_chunks::<2>()
        .0
        .iter()
        .position(|f| f.iter().any(|x| x.abs() > 1e-10))
        .unwrap();
    assert_eq!(first, 2660);
}

#[test]
fn rejection_reset_integer_and_selection_preserve_state_and_configuration() {
    let metadata = metadata(1, true);
    let config = config(BedLayout::Surround714);
    let mut renderer = SceneRenderer::new_configured(&metadata, 4, None, config).unwrap();
    let signal: Vec<i16> = (0..4096).map(|i| (i % 31) as i16 - 15).collect();
    let floats: Vec<_> = signal.iter().map(|v| f32::from(*v) / 32768.).collect();
    let mut reference = renderer.clone();
    let mut a = vec![0.; 12288];
    let mut b = a.clone();
    for _ in 0..4 {
        renderer
            .process(&signal, Some(&dynamic(0)), &mut a)
            .unwrap();
        reference
            .process_f32(&floats, Some(&dynamic(0)), &mut b)
            .unwrap();
        assert_eq!(a, b);
    }
    a.fill(123.);
    assert!(
        renderer
            .process_f32(&[f32::NAN; 4096], None, &mut a)
            .is_err()
    );
    assert!(renderer.process_f32(&[257.; 4096], None, &mut a).is_err());
    assert!(renderer.process(&signal[..4095], None, &mut a).is_err());
    assert!(renderer.process(&signal, None, &mut a[..12287]).is_err());
    let mut invalid = dynamic(0);
    invalid.objects[0].transport_channel = 31;
    assert!(renderer.process(&signal, Some(&invalid), &mut a).is_err());
    assert!(a.iter().all(|v| *v == 123.));
    for _ in 0..4 {
        renderer.process(&signal, None, &mut a).unwrap();
        reference.process_f32(&floats, None, &mut b).unwrap();
        assert_eq!(a, b);
    }
    renderer.reset().unwrap();
    let mut fresh = SceneRenderer::new_configured(&metadata, 4, None, config).unwrap();
    for _ in 0..5 {
        renderer
            .process(&signal, Some(&dynamic(0)), &mut a)
            .unwrap();
        fresh.process(&signal, Some(&dynamic(0)), &mut b).unwrap();
        assert_eq!(a, b);
    }
    let selected = SceneRenderer::new_configured(&metadata, 4, Some(&[3, 4]), config).unwrap();
    assert_eq!(selected.delay_samples(), 2147);
    assert_eq!(selected.tail_samples(), 2147);
    assert!(SceneRenderer::new(&metadata, 4, BedLayout::Stereo, None).is_err());
    for distance in [f64::NAN, 0., 1000.1] {
        let mut bad = config;
        bad.near_field.as_mut().unwrap().speaker_distance = distance;
        assert!(SceneRenderer::new_configured(&metadata, 4, None, bad).is_err());
    }
    let mut bad = config;
    bad.near_field.as_mut().unwrap().sample_rate = 7999;
    assert!(SceneRenderer::new_configured(&metadata, 4, None, bad).is_err());
}

#[test]
fn scene_binaural_configured_nfc_preserves_delay_reset_and_errors() {
    let bank = HrirBank::from_bytes(include_bytes!("fixtures/synthetic_hrir.bin")).unwrap();
    let metadata = metadata(1, true);
    let config = BinauralSceneConfig {
        virtual_layout: BedLayout::Surround714,
        lfe: BinauralLfe::Mute,
        reproduction_screen: None,
        near_field: Some(SceneNearFieldConfig {
            sample_rate: 48000,
            speaker_distance: f64::from(bank.measurement_radius()),
        }),
    };
    let mut renderer =
        SceneBinauralRenderer::new(bank.clone(), 48000, &metadata, 4, None, config).unwrap();
    assert_eq!(renderer.delay_samples(), 2659);
    assert_eq!(renderer.tail_samples(), 4193);
    let mut output = vec![0.; 2048];
    for _ in 0..4 {
        renderer.process(&[1; 4096], None, &mut output).unwrap();
    }
    renderer.reset().unwrap();
    let mut fresh =
        SceneBinauralRenderer::new(bank.clone(), 48000, &metadata, 4, None, config).unwrap();
    let mut expected = output.clone();
    for _ in 0..6 {
        renderer
            .process(&[1; 4096], Some(&dynamic(0)), &mut output)
            .unwrap();
        fresh
            .process(&[1; 4096], Some(&dynamic(0)), &mut expected)
            .unwrap();
        assert_eq!(output, expected);
    }
    let mut bad = config;
    bad.near_field.as_mut().unwrap().sample_rate = 44100;
    assert!(SceneBinauralRenderer::new(bank.clone(), 48000, &metadata, 4, None, bad).is_err());
    let mut bad = config;
    bad.near_field.as_mut().unwrap().speaker_distance += 0.1;
    assert!(SceneBinauralRenderer::new(bank, 48000, &metadata, 4, None, bad).is_err());
}

#[test]
fn eight_distinct_corrected_packs_share_sixteen_transports_with_bounded_pcm() {
    let mut metadata = metadata(3, false);
    let template = metadata.packs[0].clone();
    metadata.packs = (0..8)
        .map(|index| {
            let mut p = template.clone();
            p.index = index;
            p.hoa.as_mut().unwrap().nfc_distance = index + 1;
            p
        })
        .collect();
    metadata.objects = vec![object(0, (0..8).collect())];
    metadata.contents[0].objects = vec![0];
    let mut renderer =
        SceneRenderer::new_configured(&metadata, 16, None, config(BedLayout::Surround714)).unwrap();
    let mut output = vec![0.; 12288];
    for _ in 0..3 {
        renderer
            .process_f32(&[256.; 16384], None, &mut output)
            .unwrap();
        assert!(output.iter().all(|v| v.is_finite()));
    }
    for _ in 0..5 {
        renderer.process_silence(&mut output).unwrap();
    }
    assert!(output.iter().all(|v| v.abs() < 1e-7));
}

#[test]
#[ignore = "requires private measured HRIR bank through BAKA_AV3A_HRIR_BANK"]
fn measured_binaural_scene_with_near_field_matches_scalar_hrir() {
    let bank = HrirBank::from_bytes(
        &std::fs::read(std::env::var("BAKA_AV3A_HRIR_BANK").unwrap()).unwrap(),
    )
    .unwrap();
    let metadata = metadata(1, true);
    let rate = bank.sample_rate();
    let layout = BedLayout::Surround714;
    let mut config = config(layout);
    config.near_field.as_mut().unwrap().sample_rate = rate;
    config.near_field.as_mut().unwrap().speaker_distance = f64::from(bank.measurement_radius());
    let mut reference = SceneRenderer::new_configured(&metadata, 4, None, config).unwrap();
    let sources = SpeakerBinauralRenderer::new(bank.clone(), rate, layout, BinauralLfe::Mute)
        .unwrap()
        .sources()
        .to_vec();
    let mut renderer = SceneBinauralRenderer::new(
        bank.clone(),
        rate,
        &metadata,
        4,
        None,
        BinauralSceneConfig {
            virtual_layout: layout,
            lfe: BinauralLfe::Mute,
            reproduction_screen: None,
            near_field: config.near_field,
        },
    )
    .unwrap();
    let signal = sparse_signal(4);
    let frames = signal.len() / 4;
    let mut bus = vec![0.; frames * 12];
    let mut actual = vec![0.; frames * 2];
    for block in 0..8 {
        let input = &signal[block * 4096..(block + 1) * 4096];
        let data = dynamic(block);
        reference
            .process_f32(
                input,
                Some(&data),
                &mut bus[block * 12288..(block + 1) * 12288],
            )
            .unwrap();
        renderer
            .process_f32(
                input,
                Some(&data),
                &mut actual[block * 2048..(block + 1) * 2048],
            )
            .unwrap();
    }
    let mut expected = vec![0f64; frames * 2];
    for (channel, source) in sources.iter().enumerate() {
        let weights = bank.interpolate(source.azimuth, source.elevation).unwrap();
        for ear in 0..2 {
            let mut taps = vec![0f64; bank.tap_count()];
            for (index, weight) in weights.indices.into_iter().zip(weights.weights) {
                let m = &bank.measurements()[index];
                let values = if ear == 0 { &m.left } else { &m.right };
                for (tap, value) in taps.iter_mut().zip(values) {
                    *tap += f64::from(*value) * weight * f64::from(source.gain);
                }
            }
            for frame in 0..frames {
                for (tap, coefficient) in taps.iter().take(frames - frame).enumerate() {
                    expected[(frame + tap) * 2 + ear] +=
                        f64::from(bus[frame * 12 + channel]) * coefficient;
                }
            }
        }
    }
    close(
        &actual,
        &expected.into_iter().map(|v| v as f32).collect::<Vec<_>>(),
        3e-7,
    );
    eprintln!("measured scene NFC/HRIR scalar PCM passed: {rate} Hz");
}
