use baka_av3a_core::render::{BedLayout, DiffuseFilter, GainRenderer, ObjectGains};

fn signal(channels: usize, frames: usize) -> Vec<i16> {
    let mut result = vec![0; channels * frames];
    let mut state = 0x1234_5678_u32;
    for value in result.iter_mut().take(4096 * channels) {
        state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        *value = ((state % 16385) as i32 - 8192) as i16;
    }
    result
}

#[test]
fn direct_and_diffuse_have_distinct_delays_and_complete_tails() {
    let gains = ObjectGains::new(vec![0.5, 0.25], vec![0.5, 0.25]).unwrap();
    let mut renderer = GainRenderer::new(None, BedLayout::Stereo, &[gains]).unwrap();
    let mut input = vec![0; 2048];
    input[1024] = 8192;
    let mut output = vec![0.0; (input.len() + GainRenderer::DELAY_SAMPLES) * 2];
    renderer.process(&input, &mut output[..4096]).unwrap();
    renderer
        .process_silence(GainRenderer::DELAY_SAMPLES, &mut output[4096..])
        .unwrap();
    for channel in 0..2 {
        let filter = DiffuseFilter::new(channel as u32);
        let gain = if channel == 0 { 0.125 } else { 0.0625 };
        for frame in 0..output.len() / 2 {
            let diffuse_offset = frame.checked_sub(1024 + GainRenderer::DIFFUSE_DELAY_SAMPLES);
            let mut expected = diffuse_offset
                .and_then(|i| filter.coefficients().get(i))
                .copied()
                .unwrap_or(0.0)
                * gain;
            if frame == 1024 + GainRenderer::DELAY_SAMPLES {
                expected += gain;
            }
            assert!(
                (output[frame * 2 + channel] - expected).abs() < 1e-7,
                "{frame} {channel}"
            );
        }
    }
}

#[test]
fn blocks_updates_clone_reset_and_errors_preserve_history() {
    let first = ObjectGains::new(vec![0.5, 0.25], vec![0.5, 0.25]).unwrap();
    let second = ObjectGains::new(vec![0.2, 0.7], vec![0.1, 0.4]).unwrap();
    let mut a = GainRenderer::new(
        Some(BedLayout::Stereo),
        BedLayout::Stereo,
        std::slice::from_ref(&first),
    )
    .unwrap();
    let mut b = a.clone();
    let input = signal(3, 8192);
    let mut expected = vec![0.0; 8192 * 2];
    let mut output = expected.clone();
    a.process(&input[..1024 * 3], &mut expected[..2048])
        .unwrap();
    for (source, result) in input[..1024 * 3]
        .chunks(17 * 3)
        .zip(output[..2048].chunks_mut(17 * 2))
    {
        b.process(source, result).unwrap();
    }
    a.set_objects(std::slice::from_ref(&second)).unwrap();
    b.set_objects(std::slice::from_ref(&second)).unwrap();
    a.process(&input[1024 * 3..], &mut expected[2048..])
        .unwrap();
    for (source, result) in input[1024 * 3..]
        .chunks(137 * 3)
        .zip(output[2048..].chunks_mut(137 * 2))
    {
        b.process(source, result).unwrap();
    }
    assert_eq!(output, expected);
    let mut c = b.clone();
    let mut invalid = [123.0; 6];
    assert!(b.process(&[1, 2], &mut invalid).is_err());
    assert!(b.process(&[1, 2, 3], &mut invalid).is_err());
    assert!(b.process_silence(usize::MAX, &mut invalid).is_err());
    assert!(b.set_objects(&[]).is_err());
    assert!(
        b.set_objects(&[ObjectGains::new(vec![1.0; 6], vec![0.0; 6]).unwrap()])
            .is_err()
    );
    assert_eq!(invalid, [123.0; 6]);
    b.process(&[], &mut []).unwrap();
    b.process(&input, &mut output).unwrap();
    c.process(&input, &mut expected).unwrap();
    assert_eq!(output, expected);
    b.reset();
    let mut fresh =
        GainRenderer::new(Some(BedLayout::Stereo), BedLayout::Stereo, &[second]).unwrap();
    b.process(&input, &mut output).unwrap();
    fresh.process(&input, &mut expected).unwrap();
    assert_eq!(output, expected);
    assert_eq!(b.input_channels(), 3);
    assert_eq!(b.object_count(), 1);
    assert_eq!(b.output_layout(), BedLayout::Stereo);
}

#[test]
fn gains_and_configuration_are_bounded() {
    for (direct, diffuse) in [
        (vec![], vec![]),
        (vec![1.0], vec![]),
        (vec![0.0; 13], vec![0.0; 13]),
        (vec![f32::NAN], vec![0.0]),
        (vec![0.0], vec![f32::INFINITY]),
        (vec![16.1], vec![0.0]),
        (vec![-16.1], vec![0.0]),
    ] {
        assert!(ObjectGains::new(direct, diffuse).is_err());
    }
    let gains = ObjectGains::new(vec![1.0; 2], vec![0.0; 2]).unwrap();
    assert_eq!(gains.direct(), &[1.0; 2]);
    assert_eq!(gains.diffuse(), &[0.0; 2]);
    assert!(GainRenderer::new(None, BedLayout::Stereo, &[]).is_err());
    assert!(GainRenderer::new(None, BedLayout::Stereo, &vec![gains.clone(); 17]).is_err());
    assert!(
        GainRenderer::new(
            Some(BedLayout::Stereo),
            BedLayout::Stereo,
            &vec![gains.clone(); 15]
        )
        .is_err()
    );
    assert!(GainRenderer::new(None, BedLayout::Surround51, &[gains]).is_err());
}

#[test]
#[ignore = "requires BAKA_AV3A_RENDER_ORACLE_DIR with local native render records"]
fn local_projected_object_rendering() {
    run_native_cases(false);
}

#[test]
#[ignore = "requires BAKA_AV3A_RENDER_ORACLE_DIR with local native render records"]
fn local_polar_object_rendering() {
    run_native_cases(true);
}

fn run_native_cases(project: bool) {
    let root = std::env::var_os("BAKA_AV3A_RENDER_ORACLE_DIR").unwrap();
    let mut paths: Vec<_> = std::fs::read_dir(root)
        .unwrap()
        .map(|p| p.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "av3render"))
        .collect();
    paths.sort();
    assert!(!paths.is_empty());
    let mut maximum = 0.0_f32;
    let mut samples = 0;
    for path in &paths {
        assert!(std::fs::metadata(path).unwrap().len() <= 512 * 1024);
        let bytes = std::fs::read(path).unwrap();
        assert_eq!(&bytes[..8], b"AV3REND1");
        let bed = BedLayout::from_configuration(bytes[8]).unwrap();
        let layout = BedLayout::from_configuration(bytes[9]).unwrap();
        let count = usize::from(u16::from_le_bytes(bytes[10..12].try_into().unwrap()));
        let frames = u32::from_le_bytes(bytes[12..16].try_into().unwrap()) as usize;
        assert!((1..=16).contains(&count));
        assert!((1..=8192).contains(&frames));
        let outputs = usize::from(layout.channels());
        let values: Vec<_> = bytes[16..]
            .as_chunks::<4>()
            .0
            .iter()
            .map(|b| f32::from_le_bytes(*b))
            .collect();
        assert_eq!(values.len(), count * outputs * 2 + frames * outputs);
        let mut gains: Vec<_> = values[..count * outputs * 2]
            .chunks_exact(outputs * 2)
            .map(|g| ObjectGains::new(g[..outputs].to_vec(), g[outputs..].to_vec()).unwrap())
            .collect();
        if project {
            use baka_av3a_core::render::{ObjectProjector, PolarObject};
            let metadata = std::fs::read(path.with_extension("objects")).unwrap();
            assert_eq!(metadata.len(), count * 64);
            let projector = ObjectProjector::new(layout).unwrap();
            gains = metadata
                .as_chunks::<64>()
                .0
                .iter()
                .map(|bytes| {
                    let v: [f64; 8] = std::array::from_fn(|i| {
                        f64::from_le_bytes(bytes[i * 8..i * 8 + 8].try_into().unwrap())
                    });
                    projector
                        .project(PolarObject {
                            azimuth: v[0],
                            elevation: v[1],
                            distance: v[2],
                            width: v[3],
                            height: v[4],
                            depth: v[5],
                            gain: v[6],
                            diffuse: v[7],
                        })
                        .unwrap()
                })
                .collect();
        }
        let mut renderer = GainRenderer::new(Some(bed), layout, &gains).unwrap();
        let input = signal(usize::from(renderer.input_channels()), frames);
        let mut output = vec![0.0; frames * outputs];
        for (source, dest) in input
            .chunks(137 * usize::from(renderer.input_channels()))
            .zip(output.chunks_mut(137 * outputs))
        {
            renderer.process(source, dest).unwrap();
        }
        let expected = &values[count * outputs * 2..];
        let mut squared = 0.0;
        let mut peak = 0.0_f32;
        for (a, b) in output.iter().zip(expected) {
            assert!(a.is_finite() && b.is_finite());
            let error = (a - b).abs();
            peak = peak.max(error);
            squared += f64::from(error).powi(2);
        }
        assert!(peak < 2e-6, "{} peak={peak}", path.display());
        assert!(
            (squared / output.len() as f64).sqrt() < 2e-7,
            "{}",
            path.display()
        );
        maximum = maximum.max(peak);
        samples += output.len();
    }
    println!(
        "cases={} samples={samples} max_abs_error={maximum}",
        paths.len()
    );
}

#[test]
fn diffusion_filter_vectors() {
    let hashes = [
        0x36e99c07b365ce6e_u64,
        0x4ad88496d1bd96e9_u64,
        0x0511587c9a5ee648_u64,
        0xda33a328e4768933_u64,
        0xa6b78bde3217f598_u64,
        0x47015ee8969ab066_u64,
        0x8678ab5aa23069c9_u64,
        0xa1d651ef6b584699_u64,
        0x17f41b08cfb8bf82_u64,
        0x6d368e0d7b98aece_u64,
        0x26fa386b7ed58f64_u64,
        0xf95e60b159ba4493_u64,
    ];
    for (seed, expected) in hashes.into_iter().enumerate() {
        let filter = DiffuseFilter::new(seed as u32);
        let hash = filter
            .coefficients()
            .iter()
            .flat_map(|v| v.to_le_bytes())
            .fold(0xcbf2_9ce4_8422_2325_u64, |h, b| {
                (h ^ u64::from(b)).wrapping_mul(0x100_0000_01b3)
            });
        assert_eq!(hash, expected);
    }
}
