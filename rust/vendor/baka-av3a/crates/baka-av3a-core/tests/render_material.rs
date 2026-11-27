use baka_av3a_core::render::{
    AcousticBandLayout, AcousticMaterial, BinauralRenderer, BinauralSource,
    FilteredPropagationRenderer, HrirBank, MaterialFilter, MaterialFir, PropagationTarget,
};
fn layout() -> AcousticBandLayout {
    AcousticBandLayout::new(48000, [180., 420., 960., 2160., 4860., 10920., 18000.]).unwrap()
}
fn fir(gains: [f64; 8]) -> MaterialFir {
    MaterialFir::new(&layout(), gains).unwrap()
}
fn close(a: &[f32], b: &[f32], limit: f32) {
    let error = a
        .iter()
        .zip(b)
        .map(|(a, b)| (a - b).abs())
        .fold(0f32, f32::max);
    assert!(error < limit, "PCM error {error:e}");
}
#[test]
fn independent_scipy_complementary_fir_coefficients() {
    let bytes = include_bytes!("fixtures/material_fir.bin");
    assert_eq!(&bytes[..8], b"MATFIR01");
    let count = u32::from_le_bytes(bytes[8..12].try_into().unwrap()) as usize;
    let mut offset = 12;
    for _ in 0..count {
        let rate = u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap());
        offset += 4;
        let mut read = || {
            let v = f64::from_le_bytes(bytes[offset..offset + 8].try_into().unwrap());
            offset += 8;
            v
        };
        let edges = std::array::from_fn(|_| read());
        let gains = std::array::from_fn(|_| read());
        let filter =
            MaterialFir::new(&AcousticBandLayout::new(rate, edges).unwrap(), gains).unwrap();
        let mut expected = vec![];
        for _ in 0..1023 {
            expected.push(f32::from_le_bytes(
                bytes[offset..offset + 4].try_into().unwrap(),
            ));
            offset += 4;
        }
        close(filter.coefficients(), &expected, 3e-8);
        for (i, &tap) in filter.coefficients().iter().enumerate() {
            assert_eq!(tap, filter.coefficients()[1022 - i]);
        }
    }
    assert_eq!(count, 24);
    assert_eq!(offset, bytes.len());
}

#[test]
fn flat_pressure_has_exact_alignment_and_complementary_bands_reconstruct() {
    let layout = layout();
    let all = MaterialFir::new(&layout, [0.5; 8]).unwrap();
    assert_eq!(all.coefficients()[511], 0.5);
    assert!(
        all.coefficients()
            .iter()
            .enumerate()
            .all(|(i, v)| i == 511 || *v == 0.)
    );
    let mut sum = [0f64; 1023];
    for band in 0..8 {
        let mut gains = [0.; 8];
        gains[band] = 1.;
        let filter = MaterialFir::new(&layout, gains).unwrap();
        for (target, &value) in sum.iter_mut().zip(filter.coefficients()) {
            *target += f64::from(value);
        }
    }
    for (i, value) in sum.into_iter().enumerate() {
        assert!((value - if i == 511 { 1. } else { 0. }).abs() < 7e-8);
    }
    let mut renderer = MaterialFilter::new(&[all]).unwrap();
    let mut output = vec![0.; 2048];
    let mut source = [0.; 1024];
    source[3] = 0.25;
    renderer.process(&source, &mut output[..1024]).unwrap();
    renderer.process_silence(&mut output[1024..]).unwrap();
    assert!((output[514] - 0.125).abs() < 1e-8);
    assert!(
        output
            .iter()
            .enumerate()
            .all(|(i, v)| i == 514 || v.abs() < 1e-8)
    );
    assert_eq!(MaterialFilter::DELAY_SAMPLES, 511);
    assert_eq!(MaterialFilter::TAIL_SAMPLES, 1022);
}

#[test]
fn colored_pressure_fft_pcm_matches_scalar_fir_and_full_tail() {
    let filters = [
        fir([0.1, 0.2, 0.4, 0.8, 0.6, 0.3, 0.2, 0.1]),
        fir([1.; 8]),
        fir([0.; 8]),
    ];
    let mut renderer = MaterialFilter::new(&filters).unwrap();
    let mut source = vec![0.; 5 * 3072];
    for (i, v) in source[..3 * 3072].iter_mut().enumerate() {
        *v = ((i * 37) % 101) as f32 * 0.001 - 0.05;
    }
    let mut actual = vec![0.; source.len()];
    let mut expected = vec![0f64; source.len()];
    for block in 0..5 {
        renderer
            .process(
                &source[block * 3072..(block + 1) * 3072],
                &mut actual[block * 3072..(block + 1) * 3072],
            )
            .unwrap();
    }
    for path in 0..3 {
        for frame in 0..3 * 1024 {
            for (tap, &value) in filters[path].coefficients().iter().enumerate() {
                expected[(frame + tap) * 3 + path] +=
                    f64::from(source[frame * 3 + path]) * f64::from(value);
            }
        }
    }
    close(
        &actual,
        &expected.into_iter().map(|v| v as f32).collect::<Vec<_>>(),
        5e-8,
    );
    assert!(actual[4 * 3072..].iter().all(|v| *v == 0.));
}

#[test]
fn frequency_plateaus_and_material_pressure_are_preserved() {
    let material = AcousticMaterial::new(std::array::from_fn(|i| [i as f64 * 0.1, 0.2])).unwrap();
    let gains = material.specular_pressure();
    let filter = MaterialFir::new(&layout(), gains).unwrap();
    let frequencies = [30., 300., 650., 1450., 3500., 7500., 14000., 22000.];
    for (band, frequency) in frequencies.into_iter().enumerate() {
        let response: f64 = filter
            .coefficients()
            .iter()
            .enumerate()
            .map(|(i, &v)| {
                f64::from(v)
                    * (std::f64::consts::TAU * frequency / 48000. * (i as f64 - 511.)).cos()
            })
            .sum();
        assert!(
            (response - gains[band]).abs() < 0.003,
            "band{band}: {response} != {}",
            gains[band]
        );
    }
}

#[test]
fn filtered_propagation_retains_fractional_arrivals_headroom_and_errors() {
    let filters = [
        fir([0.25; 8]),
        fir([0.1, 0.2, 0.4, 0.8, 0.6, 0.3, 0.2, 0.1]),
    ];
    let targets = [
        PropagationTarget {
            delay_samples: 12.25,
            gain: 16.,
        },
        PropagationTarget {
            delay_samples: 1100.5,
            gain: 0.5,
        },
    ];
    let mut renderer = FilteredPropagationRenderer::new(48000, 0.1, &targets, &filters).unwrap();
    let mut reference = renderer.clone();
    let mut a = vec![123.; 2048];
    let mut b = a.clone();
    assert!(renderer.process(&[f32::NAN; 1024], &mut a).is_err());
    assert!(renderer.process(&[0.; 1023], &mut a).is_err());
    assert!(renderer.process(&[0.; 1024], &mut a[..2047]).is_err());
    assert!(a.iter().all(|v| *v == 123.));
    assert!(
        renderer
            .set_targets(
                &[PropagationTarget {
                    delay_samples: 4800.1,
                    gain: 1.
                }; 2],
                &[true; 2]
            )
            .is_err()
    );
    let mut output = vec![0.; 6 * 2048];
    for block in 0..6 {
        let mut input = [0.; 1024];
        if block == 0 {
            input[1] = 256.;
        }
        renderer.process(&input, &mut a).unwrap();
        reference.process(&input, &mut b).unwrap();
        assert_eq!(a, b);
        output[block * 2048..(block + 1) * 2048].copy_from_slice(&a);
    }
    // Internal pressure16*source256 exceeds public material input256, and must
    // retain its headroom through this prevalidated composed path.
    assert!((output[(1 + 12 + 511) * 2] - 768.).abs() < 0.0002);
    assert!((output[(1 + 13 + 511) * 2] - 256.).abs() < 0.0002);
    for (tap, &value) in filters[1].coefficients().iter().enumerate() {
        let frame = 1 + 1100 + tap;
        let expected = f64::from(value) * 64.
            + if tap > 0 {
                f64::from(filters[1].coefficients()[tap - 1]) * 64.
            } else {
                0.
            };
        assert!((f64::from(output[frame * 2 + 1]) - expected).abs() < 1e-5);
    }
    assert_eq!(renderer.tail_samples(), 5822);
    let changed = [PropagationTarget {
        delay_samples: 100.,
        gain: 0.2,
    }; 2];
    renderer.set_targets(&changed, &[true; 2]).unwrap();
    renderer.reset();
    let mut fresh = FilteredPropagationRenderer::new(48000, 0.1, &changed, &filters).unwrap();
    for _ in 0..4 {
        renderer.process(&[0.25; 1024], &mut a).unwrap();
        fresh.process(&[0.25; 1024], &mut b).unwrap();
        assert_eq!(a, b);
    }
    for _ in 0..7 {
        renderer.process_silence(&mut a).unwrap();
    }
    assert!(a.iter().all(|v| *v == 0.));
}

#[test]
fn invalid_layouts_filters_and_pcm_leave_history_untouched() {
    let valid = [10., 20., 40., 80., 160., 320., 640.];
    for rate in [7999, 192001] {
        assert!(AcousticBandLayout::new(rate, valid).is_err());
    }
    for edges in [
        [f64::NAN; 7],
        [0.; 7],
        [24000.; 7],
        [10.; 7],
        [20., 10., 40., 80., 160., 320., 640.],
    ] {
        assert!(AcousticBandLayout::new(48000, edges).is_err());
    }
    let tiny = AcousticBandLayout::new(192000, [1., 2., 3., 4., 5., 6., 7.]).unwrap();
    assert!(MaterialFir::new(&tiny, [0.5; 8]).is_ok());
    for gain in [f64::INFINITY, -0.001, 1.001] {
        assert!(MaterialFir::new(&layout(), [gain; 8]).is_err());
    }
    let filter = fir([0.5; 8]);
    let mut renderer = MaterialFilter::new(std::slice::from_ref(&filter)).unwrap();
    let mut reference = renderer.clone();
    let mut a = [123.; 1024];
    let mut b = [0.; 1024];
    assert!(renderer.process(&[f32::NAN; 1024], &mut a).is_err());
    assert!(renderer.process(&[257.; 1024], &mut a).is_err());
    assert!(renderer.process(&[0.; 1023], &mut a).is_err());
    assert!(renderer.process(&[0.; 1024], &mut a[..1023]).is_err());
    assert_eq!(a, [123.; 1024]);
    for _ in 0..4 {
        renderer.process(&[0.25; 1024], &mut a).unwrap();
        reference.process(&[0.25; 1024], &mut b).unwrap();
        assert_eq!(a, b);
    }
    renderer.reset();
    reference.reset();
    renderer.process(&[0.25; 1024], &mut a).unwrap();
    reference.process(&[0.25; 1024], &mut b).unwrap();
    assert_eq!(a, b);
    assert!(MaterialFilter::new(&[]).is_err());
    assert!(MaterialFilter::new(&vec![filter.clone(); 10]).is_err());
    let other = MaterialFir::new(&AcousticBandLayout::new(44100, valid).unwrap(), [1.; 8]).unwrap();
    assert!(MaterialFilter::new(&[filter.clone(), other]).is_err());
    assert!(
        FilteredPropagationRenderer::new(
            44100,
            0.1,
            &[PropagationTarget {
                delay_samples: 1.,
                gain: 1.
            }],
            std::slice::from_ref(&filter)
        )
        .is_err()
    );
    assert!(FilteredPropagationRenderer::new(48000, 0.1, &[], &[filter]).is_err());
}

fn stereo_oracle(bank: HrirBank) {
    let rate = bank.sample_rate();
    let layout = AcousticBandLayout::new(
        rate,
        [30., 70., 160., 360., 810., 1820., 3000.].map(|v| v * f64::from(rate) / 8000.),
    )
    .unwrap();
    let filters = [
        MaterialFir::new(&layout, [1.; 8]).unwrap(),
        MaterialFir::new(&layout, [0.1, 0.2, 0.4, 0.8, 0.6, 0.3, 0.2, 0.1]).unwrap(),
    ];
    let targets = [
        PropagationTarget {
            delay_samples: 17.25,
            gain: 1.,
        },
        PropagationTarget {
            delay_samples: 1100.5,
            gain: 0.5,
        },
    ];
    let mut propagation = FilteredPropagationRenderer::new(rate, 0.1, &targets, &filters).unwrap();
    let sources = [
        BinauralSource {
            azimuth: -90.,
            elevation: 0.,
            gain: 1.,
        },
        BinauralSource {
            azimuth: 90.,
            elevation: 0.,
            gain: 1.,
        },
    ];
    let mut renderer = BinauralRenderer::new(bank.clone(), rate, &sources).unwrap();
    renderer.set_sources(&sources, &[true; 2]).unwrap();
    let frames = 8 * 1024;
    let mut actual = vec![0.; frames * 2];
    let mut bus = [0.; 2048];
    for block in 0..8 {
        let mut input = [0.; 1024];
        if block == 0 {
            input[13] = 0.01;
            input[1023] = -0.005;
        }
        propagation.process(&input, &mut bus).unwrap();
        renderer
            .process(&bus, &mut actual[block * 2048..(block + 1) * 2048])
            .unwrap();
    }
    let mut expected = vec![0f64; actual.len()];
    for path in 0..2 {
        let weights = bank.interpolate(sources[path].azimuth, 0.).unwrap();
        for ear in 0..2 {
            let mut response = vec![0.; bank.tap_count()];
            for (index, weight) in weights.indices.into_iter().zip(weights.weights) {
                let m = &bank.measurements()[index];
                let values = if ear == 0 { &m.left } else { &m.right };
                for (target, &value) in response.iter_mut().zip(values) {
                    *target += f64::from(value) * weight;
                }
            }
            for (sample, value) in [(13, 0.01f32), (1023, -0.005f32)] {
                for (material_tap, &m) in filters[path].coefficients().iter().enumerate() {
                    if m == 0. {
                        continue;
                    }
                    for (hrir_tap, &h) in response.iter().enumerate() {
                        for (offset, weight) in [
                            (0, 1. - targets[path].delay_samples.fract()),
                            (1, targets[path].delay_samples.fract()),
                        ] {
                            let frame = sample
                                + material_tap
                                + hrir_tap
                                + targets[path].delay_samples.floor() as usize
                                + offset
                                + 99;
                            expected[frame * 2 + ear] += f64::from(value)
                                * f64::from(targets[path].gain)
                                * f64::from(m)
                                * h
                                * weight;
                        }
                    }
                }
            }
        }
    }
    close(
        &actual,
        &expected.into_iter().map(|v| v as f32).collect::<Vec<_>>(),
        5e-9,
    );
    assert!(actual[7 * 2048..].iter().all(|v| *v == 0.));
}
#[test]
fn spectral_propagation_then_hrir_matches_scalar_stereo_fir() {
    stereo_oracle(HrirBank::from_bytes(include_bytes!("fixtures/synthetic_hrir.bin")).unwrap());
}
#[test]
#[ignore = "requires private HRIR bank in BAKA_AV3A_HRIR_BANK"]
fn measured_spectral_propagation_then_hrir_matches_scalar_stereo_fir() {
    stereo_oracle(
        HrirBank::from_bytes(
            &std::fs::read(std::env::var("BAKA_AV3A_HRIR_BANK").unwrap()).unwrap(),
        )
        .unwrap(),
    );
}
