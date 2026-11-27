use baka_av3a_core::{
    Profile,
    render::{BedLayout, HoaDecoder, HoaNormalization, HoaRenderer, LookAheadLimiter},
};

fn normalization(index: u32) -> HoaNormalization {
    match index {
        0 => HoaNormalization::N3d,
        1 => HoaNormalization::Sn3d,
        2 => HoaNormalization::FuMa,
        _ => panic!("fixture normalization"),
    }
}

#[test]
fn independent_hoa_matrices_all_orders_normalizations_and_layouts() {
    let fixture = include_bytes!("fixtures/hoa_matrices.bin");
    assert_eq!(&fixture[..8], b"HOAM0001");
    let count = u32::from_le_bytes(fixture[8..12].try_into().unwrap()) as usize;
    assert_eq!(fixture.len(), 12 + count * 1552);
    let mut peak = 0.0_f64;
    for (index, record) in fixture[12..].as_chunks::<1552>().0.iter().enumerate() {
        let header: Vec<_> = record[..16]
            .as_chunks::<4>()
            .0
            .iter()
            .map(|v| u32::from_le_bytes(*v))
            .collect();
        let layout = BedLayout::from_configuration(header[0] as u8).unwrap();
        let decoder = HoaDecoder::new(
            header[1] as u8,
            normalization(header[2]),
            layout,
            header[3] != 0,
        )
        .unwrap();
        let expected: Vec<_> = record[16..]
            .as_chunks::<8>()
            .0
            .iter()
            .map(|v| f64::from_le_bytes(*v))
            .collect();
        let inputs = usize::from(decoder.input_channels());
        for (output, row) in decoder.coefficients().chunks_exact(inputs).enumerate() {
            for (input, &actual) in row.iter().enumerate() {
                let value = expected[output * 16 + input];
                let delta = (actual - value).abs();
                peak = peak.max(delta);
                assert!(
                    delta < 1e-9,
                    "case{index} layout{layout:?} order{} norm{} re{} [{output},{input}]:{actual} !={value} delta{delta}",
                    header[1],
                    header[2],
                    header[3]
                );
            }
            if output == 3 && layout != BedLayout::Stereo {
                assert!(row.iter().all(|v| *v == 0.0));
            }
        }
    }
    eprintln!("{count} independent HOA matrices: max error {peak:e}");
}

#[test]
fn hoa_float_pcm_matches_scalar_matrix_delay_ramp_and_limiter() {
    let decoder =
        HoaDecoder::new(1, HoaNormalization::Sn3d, BedLayout::Surround714, false).unwrap();
    let channels = usize::from(decoder.input_channels());
    let outputs = usize::from(decoder.output_layout().channels());
    let count = 4096;
    let input: Vec<i16> = (0..count * channels)
        .map(|i| ((i * 1597 + 113) % 8192) as i16 - 4096)
        .collect();
    let floats: Vec<_> = input.iter().map(|&v| f32::from(v) / 32768.0).collect();
    let mut renderer = HoaRenderer::new(decoder.clone()).unwrap();
    let mut integer = renderer.clone();
    let frames = count + HoaRenderer::DELAY_SAMPLES;
    let mut actual = vec![0.0; frames * outputs];
    let mut pcm = actual.clone();
    for (source, target) in floats
        .chunks(17 * channels)
        .zip(actual[..count * outputs].chunks_mut(17 * outputs))
    {
        renderer.process_f32(source, target).unwrap();
    }
    integer
        .process(&input, &mut pcm[..count * outputs])
        .unwrap();
    renderer
        .process_silence(HoaRenderer::DELAY_SAMPLES, &mut actual[count * outputs..])
        .unwrap();
    integer
        .process_silence(HoaRenderer::DELAY_SAMPLES, &mut pcm[count * outputs..])
        .unwrap();
    assert_eq!(actual, pcm);
    let mut expected = vec![0.0; actual.len()];
    for (i, frame) in floats.chunks_exact(channels).enumerate() {
        let ramp = (i.min(1024) as f32) / 1024.0;
        for (speaker, row) in decoder.coefficients().chunks_exact(channels).enumerate() {
            let sum: f32 = frame
                .iter()
                .zip(row)
                .map(|(sample, &gain)| sample * (gain as f32 * ramp))
                .sum();
            expected[(i + HoaRenderer::DELAY_SAMPLES) * outputs + speaker] = sum;
        }
    }
    // Scalar expected includes the limiter's delay separately from direct delay.
    let mut pre = vec![0.0; expected.len()];
    let delay = LookAheadLimiter::DELAY_SAMPLES * outputs;
    pre[..expected.len() - delay].copy_from_slice(&expected[delay..]);
    LookAheadLimiter::new(outputs as u16)
        .unwrap()
        .process(&mut pre)
        .unwrap();
    for (a, b) in actual.iter().zip(pre) {
        assert!((a - b).abs() < 1e-7);
    }
    let mut clone = renderer.clone();
    actual.fill(42.0);
    for invalid in [f32::NAN, f32::INFINITY, 257.0, -257.0] {
        let mut bad = vec![0.0; count * channels];
        bad[count * channels - 1] = invalid;
        assert!(
            renderer
                .process_f32(&bad, &mut actual[..count * outputs])
                .is_err()
        );
        assert!(actual.iter().all(|v| *v == 42.0));
    }
    renderer
        .process_f32(&floats, &mut actual[..count * outputs])
        .unwrap();
    clone
        .process_f32(&floats, &mut pcm[..count * outputs])
        .unwrap();
    assert_eq!(&actual[..count * outputs], &pcm[..count * outputs]);
    renderer.reset();
    let mut fresh = HoaRenderer::new(decoder).unwrap();
    renderer
        .process_f32(&floats, &mut actual[..count * outputs])
        .unwrap();
    fresh
        .process_f32(&floats, &mut pcm[..count * outputs])
        .unwrap();
    assert_eq!(&actual[..count * outputs], &pcm[..count * outputs]);
}

#[test]
fn hoa_configuration_and_quadrature_converge() {
    assert!(HoaDecoder::new(4, HoaNormalization::Sn3d, BedLayout::Stereo, false).is_err());
    assert!(HoaRenderer::from_profile(Profile::Objects { count: 4 }, BedLayout::Stereo).is_err());
    for resolution in [0, 15, 17, 129, 256] {
        assert!(
            HoaDecoder::with_resolution(
                1,
                HoaNormalization::Sn3d,
                BedLayout::Stereo,
                false,
                resolution
            )
            .is_err()
        );
    }
    let mut peak = 0.0_f64;
    for config in [1, 2, 3, 7, 8, 9, 10] {
        let layout = BedLayout::from_configuration(config).unwrap();
        let low = HoaDecoder::new(3, HoaNormalization::Sn3d, layout, false).unwrap();
        let high =
            HoaDecoder::with_resolution(3, HoaNormalization::Sn3d, layout, false, 128).unwrap();
        for (a, b) in low.coefficients().iter().zip(high.coefficients()) {
            peak = peak.max((a - b).abs());
        }
    }
    eprintln!("HOA 8192 vs32768 integration max coefficient delta {peak:e}");
    assert!(peak < 0.001);
}
