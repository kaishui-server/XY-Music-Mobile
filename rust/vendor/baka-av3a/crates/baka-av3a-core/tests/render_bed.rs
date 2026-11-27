use baka_av3a_core::Profile;
use baka_av3a_core::render::{BedLayout, BedRenderer, GainRenderer};

const VECTORS: &[(u8, u8, u64)] = &[
    (1, 1, 0xcfb3be9d9a6eea00),
    (1, 2, 0x87a7e44f4b604226),
    (1, 3, 0x55bb6029553eb926),
    (1, 7, 0x55bb6029553eb926),
    (1, 8, 0x150345e05f9fd8a6),
    (1, 9, 0x150345e05f9fd8a6),
    (1, 10, 0xc98b411c81d480a6),
    (2, 1, 0x4977175bf26819f8),
    (2, 2, 0xa1870b5669ffe589),
    (2, 3, 0x7162faa2c46f4a69),
    (2, 7, 0x008285b79d4a0929),
    (2, 8, 0x935f67516723a549),
    (2, 9, 0x30f54d43f1163909),
    (2, 10, 0xe50a846c52f79a29),
    (3, 1, 0xaa99338855fe1acb),
    (3, 2, 0x3e99ca33d36d0f66),
    (3, 3, 0x3654bd5b3423339d),
    (3, 7, 0xc03295abe8f80da6),
    (3, 8, 0x08699666a6f97666),
    (3, 9, 0xe1fa10a89b5e1ddd),
    (3, 10, 0xc59740a71586619d),
    (7, 1, 0xaa99338855fe1acb),
    (7, 2, 0x2687032a93db209e),
    (7, 3, 0x04ad1452bdf8b1fe),
    (7, 7, 0x3654bd5b3423339d),
    (7, 8, 0xe1fa10a89b5e1ddd),
    (7, 9, 0x4d337c6ed3b0595d),
    (7, 10, 0x369522885e6e901d),
    (8, 1, 0x0a218d1b59d6cb43),
    (8, 2, 0x7657648c3366986c),
    (8, 3, 0x4c04ff5dbc6dd6cc),
    (8, 7, 0xb78a55d42a390fa7),
    (8, 8, 0x6d95665d1a838b85),
    (8, 9, 0xc7f6d3f9414375e7),
    (8, 10, 0x0fa5f9afe3613585),
    (9, 1, 0x0a218d1b59d6cb43),
    (9, 2, 0x2d133ae1b1a17976),
    (9, 3, 0x405bb72555429185),
    (9, 7, 0x4a71220f5f3b21b2),
    (9, 8, 0x2528d199bb46b532),
    (9, 9, 0x6d95665d1a838b85),
    (9, 10, 0x7cf54aefc8b845e5),
    (10, 1, 0x1e72f5c23ff5af68),
    (10, 2, 0x45724a75a8040d98),
    (10, 3, 0x2a3e911053c0a8bd),
    (10, 7, 0x7a5bb82d412871b6),
    (10, 8, 0xb5430fbf2eb08405),
    (10, 9, 0x15205a832dc2437b),
    (10, 10, 0x45bc77e724ebc100),
];

fn input(channels: usize) -> Vec<i16> {
    let mut result = vec![0; 8192 * channels];
    let mut state = 0x1234_5678_u32;
    for sample in &mut result[..4096 * channels] {
        state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        *sample = ((state % 16385) as i32 - 8192) as i16;
    }
    result
}

#[test]
fn channel_bed_continuous_vectors() {
    let mut mismatches = Vec::new();
    for &(from, to, expected) in VECTORS {
        let from_layout = BedLayout::from_configuration(from).unwrap();
        let to_layout = BedLayout::from_configuration(to).unwrap();
        let mut renderer = BedRenderer::new(from_layout, to_layout);
        let input = input(usize::from(from_layout.channels()));
        let mut output = vec![0.0; 8192 * usize::from(to_layout.channels())];
        renderer.process(&input, &mut output).unwrap();
        let mut generic = GainRenderer::new(Some(from_layout), to_layout, &[]).unwrap();
        let mut generic_output = vec![0.0; output.len()];
        generic.process(&input, &mut generic_output).unwrap();
        assert_eq!(generic_output, output);
        let hash = output
            .iter()
            .flat_map(|v| v.to_le_bytes())
            .fold(0xcbf2_9ce4_8422_2325_u64, |h, b| {
                (h ^ u64::from(b)).wrapping_mul(0x100_0000_01b3)
            });
        if hash != expected {
            mismatches.push((from, to, hash, expected));
        }
    }
    assert!(mismatches.is_empty(), "{mismatches:x?}");
}

#[test]
fn chunks_and_silence_preserve_all_layouts() {
    for &(from, to, _) in VECTORS {
        let from = BedLayout::from_configuration(from).unwrap();
        let to = BedLayout::from_configuration(to).unwrap();
        let inputs = usize::from(from.channels());
        let outputs = usize::from(to.channels());
        let signal = input(inputs);
        let mut contiguous = BedRenderer::new(from, to);
        let mut expected = vec![0.0; 8192 * outputs];
        contiguous.process(&signal, &mut expected).unwrap();
        let mut renderer = BedRenderer::new(from, to);
        let mut result = vec![0.0; expected.len()];
        let mut frame = 0;
        for count in [1, 17, 1023, 997, 2048, 10] {
            renderer
                .process(
                    &signal[frame * inputs..(frame + count) * inputs],
                    &mut result[frame * outputs..(frame + count) * outputs],
                )
                .unwrap();
            frame += count;
        }
        // The final 4096 input frames are silent, including a partial block.
        renderer
            .process(
                &signal[frame * inputs..4096 * inputs],
                &mut result[frame * outputs..4096 * outputs],
            )
            .unwrap();
        renderer
            .process_silence(4096, &mut result[4096 * outputs..])
            .unwrap();
        assert_eq!(result, expected, "{from:?} {to:?}");
        assert_eq!(renderer.input_layout(), from);
        assert_eq!(renderer.output_layout(), to);
    }
}

#[test]
fn reset_clone_and_validation_are_atomic() {
    let mut renderer = BedRenderer::new(BedLayout::Surround714, BedLayout::Stereo);
    let signal = input(12);
    let prefix = 1777;
    renderer
        .process(&signal[..prefix * 12], &mut vec![0.0; prefix * 2])
        .unwrap();
    let mut reference = renderer.clone();
    let mut invalid = [123.0; 6];
    assert!(renderer.process(&[0; 13], &mut invalid).is_err());
    assert!(renderer.process(&[0; 12], &mut invalid).is_err());
    assert!(renderer.process_silence(usize::MAX, &mut invalid).is_err());
    assert_eq!(invalid, [123.0; 6]);
    renderer.process(&[], &mut []).unwrap();
    let remaining = &signal[prefix * 12..];
    let mut actual = vec![0.0; remaining.len() / 6];
    let mut expected = actual.clone();
    renderer.process(remaining, &mut actual).unwrap();
    reference.process(remaining, &mut expected).unwrap();
    assert_eq!(actual, expected);
    renderer.reset();
    let mut fresh = BedRenderer::new(BedLayout::Surround714, BedLayout::Stereo);
    renderer.process(remaining, &mut actual).unwrap();
    fresh.process(remaining, &mut expected).unwrap();
    assert_eq!(actual, expected);
}

#[test]
fn delay_ramp_and_tail_are_sample_exact() {
    let mut renderer = BedRenderer::new(BedLayout::Stereo, BedLayout::Stereo);
    let mut signal = vec![0; 36];
    signal[2] = 8192;
    let mut output = vec![0.0; 36];
    renderer.process(&signal, &mut output).unwrap();
    assert!(output.iter().all(|v| *v == 0.0));
    let mut tail = vec![0.0; BedRenderer::DELAY_SAMPLES * 2];
    renderer
        .process_silence(BedRenderer::DELAY_SAMPLES, &mut tail)
        .unwrap();
    assert_eq!(tail.iter().filter(|v| **v != 0.0).count(), 1);
    let index = (BedRenderer::DELAY_SAMPLES + 1 - 18) * 2;
    assert_eq!(tail[index], 0.25 * 0.85 / 1024.0);
    assert_eq!(tail[index + 1], 0.0);
}

#[test]
fn unsupported_profiles_are_explicit() {
    for config in [0, 4, 5, 6, 11, 12, 13, 14, 255] {
        assert!(BedLayout::from_configuration(config).is_err());
    }
    for profile in [
        Profile::Objects { count: 2 },
        Profile::BedObjects {
            configuration: 1,
            objects: 1,
        },
        Profile::Hoa { order: 1 },
    ] {
        assert!(BedLayout::from_profile(profile).is_err());
    }
    for &(configuration, _, _) in VECTORS {
        let layout = BedLayout::from_profile(Profile::ChannelBed { configuration }).unwrap();
        assert_eq!(layout.configuration(), configuration);
    }
}
