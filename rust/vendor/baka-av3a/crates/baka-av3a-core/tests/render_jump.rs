use baka_av3a_core::render::{
    BedLayout, DiffuseFilter, GainRenderer, LookAheadLimiter, ObjectGains,
};

fn gains(direct: [f32; 2], diffuse: [f32; 2]) -> ObjectGains {
    ObjectGains::new(direct.to_vec(), diffuse.to_vec()).unwrap()
}

#[test]
fn gain_jumps_match_scalar_direct_delay_and_diffuse_fir() {
    let targets = [
        ([0.5, 0.25], [0.1, 0.2]),
        ([0.0, 0.75], [0.4, 0.0]),
        ([0.25, 0.5], [0.1, 0.2]),
        ([0.25, 0.5], [0.1, 0.2]),
    ];
    let mut renderer = GainRenderer::new(
        None,
        BedLayout::Stereo,
        &[gains(targets[0].0, targets[0].1)],
    )
    .unwrap();
    let mut signal = vec![0i16; 8192];
    for (i, s) in signal.iter_mut().enumerate().take(4096) {
        *s = ((i * 3571) % 2048) as i16 - 1024;
    }
    let mut actual = vec![0.0; 16384];
    let mut dry = vec![[0.0f32; 2]; 8192];
    let mut wet = dry.clone();
    let timeline = include_bytes!("fixtures/jump_timeline.bin");
    assert_eq!(&timeline[..8], b"JUMP0001");
    assert_eq!(
        u32::from_le_bytes(timeline[8..12].try_into().unwrap()),
        4096
    );
    assert_eq!(timeline.len(), 12 + 4096 * 4 * 4);
    let coefficients: Vec<_> = timeline[12..]
        .as_chunks::<4>()
        .0
        .iter()
        .map(|v| f32::from_le_bytes(*v))
        .collect();
    for (block, &target) in targets.iter().enumerate() {
        if block == 1 {
            renderer
                .set_objects_with_jump(&[gains(target.0, target.1)], &[true])
                .unwrap();
        } else {
            renderer.set_objects(&[gains(target.0, target.1)]).unwrap();
        }
        renderer
            .process(
                &signal[block * 1024..(block + 1) * 1024],
                &mut actual[block * 2048..(block + 1) * 2048],
            )
            .unwrap();
        for i in 0..1024 {
            let index = block * 1024 + i;
            for channel in 0..2 {
                let d = coefficients[index * 4 + channel];
                let w = coefficients[index * 4 + channel + 2];
                dry[index][channel] = f32::from(signal[index]) / 32768.0 * d;
                wet[index][channel] = f32::from(signal[index]) / 32768.0 * w;
            }
        }
    }
    renderer.process_silence(4096, &mut actual[8192..]).unwrap();
    let filters = [DiffuseFilter::new(0), DiffuseFilter::new(1)];
    let mut expected = vec![0.0; 16384];
    for (i, output) in expected.as_chunks_mut::<2>().0.iter_mut().enumerate() {
        for channel in 0..2 {
            let mut value = if i >= 2048 {
                f64::from(dry[i - 2048][channel])
            } else {
                0.0
            };
            for (tap, &coefficient) in filters[channel].coefficients().iter().enumerate() {
                if let Some(index) = i.checked_sub(1024 + tap) {
                    value += f64::from(wet[index][channel]) * f64::from(coefficient);
                }
            }
            output[channel] = value as f32;
        }
    }
    LookAheadLimiter::new(2)
        .unwrap()
        .process(&mut expected)
        .unwrap();
    let peak = actual
        .iter()
        .zip(&expected)
        .map(|(a, b)| (a - b).abs())
        .fold(0.0f32, f32::max);
    assert!(peak < 2e-7, "peak={peak}");
}

#[test]
fn per_object_flags_take_effect_at_the_first_source_sample() {
    let left = gains([0.5, 0.0], [0.0; 2]);
    let right = gains([0.0, 0.5], [0.0; 2]);
    let mut renderer =
        GainRenderer::new(None, BedLayout::Stereo, &[left.clone(), left.clone()]).unwrap();
    let input = vec![1024i16; 2048];
    let mut first = vec![0.0; 2048];
    renderer.process(&input, &mut first).unwrap();
    renderer
        .set_objects_with_jump(&[right.clone(), right], &[true, false])
        .unwrap();
    let mut output = vec![0.0; 8192];
    renderer.process(&input, &mut output[..2048]).unwrap();
    renderer.process_silence(3072, &mut output[2048..]).unwrap();
    // Output starts one input block after stream start, so this index is the
    // second input block's first sample after the direct-path delay.
    let index = GainRenderer::DELAY_SAMPLES;
    assert_eq!(output[index * 2], 1024.0 / 32768.0 * 0.5); // non-jumping object still left
    assert_eq!(output[index * 2 + 1], 1024.0 / 32768.0 * 0.5); // jumping object already right
    let middle = index + 512;
    assert_eq!(output[middle * 2], 1024.0 / 32768.0 * 0.25);
    assert_eq!(output[middle * 2 + 1], 1024.0 / 32768.0 * 0.75);
}

#[test]
fn pending_jumps_clone_cancel_reset_and_reject_partial_block_updates() {
    let a = gains([0.2, 0.4], [0.1, 0.0]);
    let b = gains([0.4, 0.2], [0.0, 0.1]);
    let mut actual = GainRenderer::new(None, BedLayout::Stereo, std::slice::from_ref(&a)).unwrap();
    actual
        .set_objects_with_jump(std::slice::from_ref(&b), &[true])
        .unwrap();
    let mut control = actual.clone();
    assert!(actual.set_objects_with_jump(&[], &[]).is_err());
    assert!(
        actual
            .set_objects_with_jump(std::slice::from_ref(&b), &[])
            .is_err()
    );
    assert!(actual.set_objects(&[]).is_err());
    let input = vec![1000; 4096];
    let mut out = vec![0.0; 8192];
    let mut expected = out.clone();
    actual.process(&input[..17], &mut out[..34]).unwrap();
    control.process(&input[..17], &mut expected[..34]).unwrap();
    assert!(
        actual
            .set_objects_with_jump(std::slice::from_ref(&a), &[false])
            .is_err()
    );
    actual.process(&input[17..], &mut out[34..]).unwrap();
    control.process(&input[17..], &mut expected[34..]).unwrap();
    assert_eq!(out, expected);
    actual
        .set_objects_with_jump(std::slice::from_ref(&a), &[true])
        .unwrap();
    actual.set_objects(std::slice::from_ref(&b)).unwrap(); // ordinary replacement cancels pending jump
    control.set_objects(std::slice::from_ref(&b)).unwrap();
    actual.process(&input, &mut out).unwrap();
    control.process(&input, &mut expected).unwrap();
    assert_eq!(out, expected);
    actual
        .set_objects_with_jump(std::slice::from_ref(&a), &[true])
        .unwrap();
    actual.reset();
    let mut fresh = GainRenderer::new(None, BedLayout::Stereo, &[a]).unwrap();
    actual.process(&input, &mut out).unwrap();
    fresh.process(&input, &mut expected).unwrap();
    assert_eq!(out, expected);
}
