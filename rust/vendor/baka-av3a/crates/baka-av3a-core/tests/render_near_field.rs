use baka_av3a_core::render::{
    BedLayout, HoaDecoder, HoaNearField, HoaNormalization, HoaRenderer, NearFieldConfig,
    NearFieldHoaRenderer,
};

#[test]
fn independent_spherical_hankel_phase_and_fir_vectors() {
    let phases = include_bytes!("fixtures/near_field_phase.bin");
    assert_eq!(&phases[..8], b"NFCP0001");
    let count = u32::from_le_bytes(phases[8..12].try_into().unwrap()) as usize;
    assert_eq!(phases.len(), 12 + count * 48);
    let mut peak_phase = 0.0_f64;
    for row in phases[12..].as_chunks::<48>().0 {
        let fs = u32::from_le_bytes(row[..4].try_into().unwrap());
        let order = u32::from_le_bytes(row[4..8].try_into().unwrap()) as u8;
        let v: Vec<_> = row[8..]
            .as_chunks::<8>()
            .0
            .iter()
            .map(|v| f64::from_le_bytes(*v))
            .collect();
        let config = NearFieldConfig {
            reference_distance: v[0],
            speaker_distance: v[1],
            sample_rate: fs,
        };
        let actual = config.phase_response(order, v[2]).unwrap();
        for (a, b) in actual.into_iter().zip(&v[3..]) {
            peak_phase = peak_phase.max((a - b).abs());
            assert!((a - b).abs() < 1e-10);
        }
    }
    let filters = include_bytes!("fixtures/near_field_fir.bin");
    assert_eq!(&filters[..8], b"NFCF0001");
    let count = u32::from_le_bytes(filters[8..12].try_into().unwrap()) as usize;
    assert_eq!(filters.len(), 12 + count * 8216);
    let mut peak_fir = 0.0_f64;
    for row in filters[12..].as_chunks::<8216>().0 {
        let fs = u32::from_le_bytes(row[..4].try_into().unwrap());
        let order = u32::from_le_bytes(row[4..8].try_into().unwrap()) as u8;
        let v: Vec<_> = row[8..]
            .as_chunks::<8>()
            .0
            .iter()
            .map(|v| f64::from_le_bytes(*v))
            .collect();
        let filter = HoaNearField::new(
            order,
            NearFieldConfig {
                reference_distance: v[0],
                speaker_distance: v[1],
                sample_rate: fs,
            },
        )
        .unwrap();
        let taps = filter.coefficients(order).unwrap();
        for (a, b) in taps.iter().zip(&v[2..]) {
            peak_fir = peak_fir.max((f64::from(*a) - b).abs());
            assert!(
                (f64::from(*a) - b).abs() < 2e-7,
                "order{order} fs{fs} {a} != {b}"
            );
        }
    }
    eprintln!("NFC980 phase/140 FIR cases: phase max{peak_phase:e} FIR max{peak_fir:e}");
}

#[test]
fn convolution_pcm_clone_tail_reset_and_validation() {
    let config = NearFieldConfig {
        reference_distance: 0.25,
        speaker_distance: 2.0,
        sample_rate: 48000,
    };
    let mut filter = HoaNearField::new(3, config).unwrap();
    let mut cloned = filter.clone();
    let frames = 4096;
    let channels = 16;
    let mut input = vec![0.0; frames * channels];
    for (i, sample) in input[..(1024 + 47) * channels].iter_mut().enumerate() {
        *sample = ((i * 97 % 101) as f32 - 50.0) / 200.0;
    }
    let mut actual = vec![0.0; input.len()];
    let mut expected = actual.clone();
    for (block, (source, target)) in input
        .chunks(1024 * channels)
        .zip(actual.chunks_mut(1024 * channels))
        .enumerate()
    {
        filter.process(source, target).unwrap();
        let mut control = vec![0.0; target.len()];
        cloned.process(source, &mut control).unwrap();
        assert_eq!(target, control);
        if block == 0 {
            let mut bad = source.to_vec();
            bad[0] = f32::NAN;
            let mut out = vec![42.0; target.len()];
            assert!(filter.process(&bad, &mut out).is_err());
            assert!(out.iter().all(|v| *v == 42.0));
        }
    }
    let mut peak = 0.0_f64;
    for (i, frame) in expected.chunks_exact_mut(channels).enumerate() {
        for (acn, sample) in frame.iter_mut().enumerate() {
            let taps = filter.coefficients(acn.isqrt() as u8).unwrap();
            let value: f64 = taps
                .iter()
                .take(i + 1)
                .enumerate()
                .map(|(j, &tap)| f64::from(tap) * f64::from(input[(i - j) * channels + acn]))
                .sum();
            *sample = value as f32;
            peak = peak.max((f64::from(actual[i * channels + acn]) - value).abs());
        }
    }
    assert!(peak < 5e-7, "PCM max{peak}");
    eprintln!("NFC scalar FIR PCM max{peak:e}");
    assert!(
        actual[(1024 + 47 + 1023) * channels..]
            .iter()
            .all(|v| v.abs() < 1e-7)
    );
    filter.reset();
    let mut out = vec![42.0; 1024 * channels];
    filter.process_silence(&mut out).unwrap();
    assert!(out.iter().all(|v| *v == 0.0));
    let equal = HoaNearField::new(
        3,
        NearFieldConfig {
            speaker_distance: config.reference_distance,
            ..config
        },
    )
    .unwrap();
    for order in 0..=3 {
        for (i, &tap) in equal.coefficients(order).unwrap().iter().enumerate() {
            assert_eq!(tap, if i == 512 { 1.0 } else { 0.0 });
        }
    }
    for radius in [0.0, -1.0, f64::NAN, f64::INFINITY, 1001.0] {
        assert!(
            HoaNearField::new(
                1,
                NearFieldConfig {
                    reference_distance: radius,
                    ..config
                }
            )
            .is_err()
        );
    }
    for fs in [0, 7999, 192001] {
        assert!(
            HoaNearField::new(
                1,
                NearFieldConfig {
                    sample_rate: fs,
                    ..config
                }
            )
            .is_err()
        );
    }
    assert!(HoaNearField::new(4, config).is_err());
    for frequency in [f64::MIN_POSITIVE, 1e-300, 1e-100] {
        for order in 0..=3 {
            assert!(
                config
                    .phase_response(order, frequency)
                    .unwrap()
                    .iter()
                    .all(|v| v.is_finite())
            );
        }
    }
    assert!(config.phase_response(1, -1.0).is_err());
    assert!(config.phase_response(1, 24001.0).is_err());
    assert!(config.phase_response(4, 1.0).is_err());
}

#[test]
fn near_field_hoa_renderer_matches_filter_then_decoder_without_requantization() {
    let decoder =
        HoaDecoder::new(1, HoaNormalization::Sn3d, BedLayout::Surround714, false).unwrap();
    let config = NearFieldConfig {
        reference_distance: 0.1,
        speaker_distance: 1.5,
        sample_rate: 44100,
    };
    let mut actual = NearFieldHoaRenderer::new(decoder.clone(), config).unwrap();
    let mut integer = actual.clone();
    let mut filter = HoaNearField::new(1, config).unwrap();
    let mut reference = HoaRenderer::new(decoder).unwrap();
    let input: Vec<i16> = (0..4096)
        .map(|i| ((i * 1193 % 8192) as i16) - 4096)
        .collect();
    let floats: Vec<_> = input.iter().map(|&v| f32::from(v) / 32768.0).collect();
    let mut filtered = vec![0.0; 4096];
    let mut a = vec![0.0; 12288];
    let mut b = a.clone();
    let mut c = a.clone();
    for _ in 0..4 {
        actual.process_f32(&floats, &mut a).unwrap();
        integer.process(&input, &mut c).unwrap();
        filter.process(&floats, &mut filtered).unwrap();
        reference.process_f32(&filtered, &mut b).unwrap();
        assert_eq!(a, b);
        assert_eq!(a, c);
    }
    let mut cloned = actual.clone();
    let mut bad = floats.clone();
    bad[0] = f32::INFINITY;
    a.fill(42.0);
    assert!(actual.process_f32(&bad, &mut a).is_err());
    assert!(a.iter().all(|v| *v == 42.0));
    assert!(actual.process(&input[..4095], &mut a).is_err());
    assert!(actual.process_f32(&floats, &mut a[..12287]).is_err());
    for _ in 0..4 {
        actual.process_silence(&mut a).unwrap();
        cloned.process_silence(&mut b).unwrap();
        assert_eq!(a, b);
    }
    assert!(a[98 * 12..].iter().all(|v| v.abs() < 1e-7));
    actual.reset();
    integer.reset();
    actual.process_f32(&floats, &mut a).unwrap();
    integer.process(&input, &mut b).unwrap();
    assert_eq!(a, b);
    // Equal-radius compensation is still aligned by512 samples at high headroom.
    let decoder = HoaDecoder::new(1, HoaNormalization::Sn3d, BedLayout::Stereo, false).unwrap();
    let mut loud = NearFieldHoaRenderer::new(
        decoder,
        NearFieldConfig {
            speaker_distance: config.reference_distance,
            ..config
        },
    )
    .unwrap();
    let mut out = vec![0.0; 2048];
    for _ in 0..4 {
        loud.process_f32(&[256.0; 4096], &mut out).unwrap();
    }
    assert!(out.iter().all(|v| v.is_finite()));
    assert_eq!(NearFieldHoaRenderer::DELAY_SAMPLES, 2659);
    assert_eq!(NearFieldHoaRenderer::TAIL_SAMPLES, 3170);
}

#[test]
fn order_zero_impulse_has_the_documented_alignment() {
    let decoder = HoaDecoder::new(0, HoaNormalization::Sn3d, BedLayout::Stereo, false).unwrap();
    let coefficients = decoder.coefficients().to_vec();
    let mut renderer = NearFieldHoaRenderer::new(
        decoder,
        NearFieldConfig {
            reference_distance: 0.25,
            speaker_distance: 2.0,
            sample_rate: 48000,
        },
    )
    .unwrap();
    let mut output = vec![0.0; 8192];
    for block in 0..4 {
        let mut input = [0.0; 1024];
        if block == 1 {
            input[0] = 0.25;
        }
        renderer
            .process_f32(&input, &mut output[block * 2048..(block + 1) * 2048])
            .unwrap();
    }
    for (i, frame) in output.as_chunks::<2>().0.iter().enumerate() {
        for channel in 0..2 {
            let expected = if i == 1024 + NearFieldHoaRenderer::DELAY_SAMPLES {
                coefficients[channel] as f32 * 0.25
            } else {
                0.0
            };
            assert!(
                (frame[channel] - expected).abs() < 1e-7,
                "sample{i} channel{channel}"
            );
        }
    }
}

#[test]
fn pack_distance_resolution_disabled_and_invalid_metadata() {
    use baka_av3a_core::metadata::{AudioPack, HoaPack};
    let mut pack = AudioPack {
        index: 0,
        importance: None,
        type_label: 4,
        absolute_distance: 31,
        hoa: Some(HoaPack {
            normalization: 0,
            nfc_distance: 15,
            screen_reference: false,
            order: 1,
        }),
        format_id: None,
        matrix_outputs: vec![],
        start_index: Some(2),
        channels: (0..4).map(|i| (i, None)).collect(),
    };
    let value = NearFieldConfig::from_pack(&pack, 2.0, 48000)
        .unwrap()
        .unwrap();
    assert!((value.reference_distance - f64::from(pack.absolute_distance_value())).abs() < 1e-6);
    assert_eq!(pack.transport_channels().unwrap(), [2, 3, 4, 5]);
    let prepared = NearFieldHoaRenderer::from_pack(&pack, BedLayout::Stereo, 2.0, 48000).unwrap();
    assert_eq!(prepared.filter().config(), value);
    pack.hoa.as_mut().unwrap().nfc_distance = 0;
    assert_eq!(NearFieldConfig::from_pack(&pack, 2.0, 48000).unwrap(), None);
    assert!(NearFieldHoaRenderer::from_pack(&pack, BedLayout::Stereo, 2.0, 48000).is_err());
    pack.hoa.as_mut().unwrap().nfc_distance = 15;
    pack.absolute_distance = 0;
    assert!(NearFieldConfig::from_pack(&pack, 2.0, 48000).is_err());
    pack.absolute_distance = 31;
    for distance in 1..=15 {
        pack.hoa.as_mut().unwrap().nfc_distance = distance;
        assert!(
            NearFieldConfig::from_pack(&pack, 2.0, 48000)
                .unwrap()
                .unwrap()
                .reference_distance
                > 0.0
        );
    }
    pack.hoa.as_mut().unwrap().nfc_distance = 16;
    assert!(NearFieldConfig::from_pack(&pack, 2.0, 48000).is_err());
    pack.hoa.as_mut().unwrap().nfc_distance = 15;
    for normalization in 1..=3 {
        pack.hoa.as_mut().unwrap().normalization = normalization;
        assert!(NearFieldHoaRenderer::from_pack(&pack, BedLayout::Stereo, 2.0, 48000).is_err());
    }
    pack.hoa.as_mut().unwrap().normalization = 0;
    pack.channels.pop();
    assert!(NearFieldHoaRenderer::from_pack(&pack, BedLayout::Stereo, 2.0, 48000).is_err());
    assert!(NearFieldConfig::from_pack(&pack, 0.0, 48000).is_err());
    assert!(NearFieldConfig::from_pack(&pack, 2.0, 0).is_err());
}
