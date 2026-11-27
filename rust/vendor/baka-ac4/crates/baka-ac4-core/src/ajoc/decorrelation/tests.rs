use super::*;
use crate::ajoc::reconstruction::parameter_band;

// Original search-based processing; filter arithmetic and ducking are unchanged.
fn reference_process(state: &mut Instance, kind: usize, input: &QmfSlot, output: &mut QmfSlot) {
    let filtered = state.filter(kind, input);
    let mut energy = [0.0; 15];
    for (sb, sample) in input.iter().enumerate() {
        let pb = parameter_band(15, sb).expect("fixed band map");
        energy[pb] += sample.iter().map(|&v| f64::from(v).powi(2)).sum::<f64>();
    }
    let gains: [f64; 15] = std::array::from_fn(|pb| state.duckers[pb].gain(energy[pb]));
    for (sb, sample) in output.iter_mut().enumerate() {
        let gain = gains[parameter_band(15, sb).expect("fixed band map")];
        *sample = filtered[sb].map(|v| (v * gain) as f32);
    }
}

#[test]
fn fixed_band_map_and_stateful_output_match_original_search() {
    for (sb, &band) in PARAMETER_BANDS.iter().enumerate() {
        assert_eq!(usize::from(band), parameter_band(15, sb).unwrap());
    }
    for kind in 0..3 {
        let mut original = Instance::default();
        let mut optimized = Instance::default();
        for slot in 0..512 {
            let input = std::array::from_fn(|sb| match slot % 64 {
                0 => [1.0, -2.0],
                1..=15 => [0.0, -0.0],
                _ => [
                    ((slot * 31 + sb * 7) % 257) as f32 / 128.0 - 1.0,
                    ((slot * 17 + sb * 13) % 251) as f32 / 256.0 - 0.5,
                ],
            });
            let (mut a, mut b) = ([[0.0; 2]; 64], [[0.0; 2]; 64]);
            reference_process(&mut original, kind, &input, &mut a);
            optimized.process(kind, &input, &mut b);
            assert_eq!(
                a.map(|v| v.map(f32::to_bits)),
                b.map(|v| v.map(f32::to_bits))
            );
        }
    }
}

#[test]
#[ignore = "manual host timing; run release with --ignored --nocapture"]
fn fixed_band_map_measurement() {
    type Process = fn(&mut Instance, usize, &QmfSlot, &mut QmfSlot);
    let input = std::array::from_fn(|sb| [sb as f32 / 64.0, -0.5]);
    let mut timings = [[std::time::Duration::ZERO; 2]; 7];
    for (round, times) in timings.iter_mut().enumerate() {
        for index in [round % 2, 1 - round % 2] {
            let process: Process = [reference_process, Instance::process][index];
            let mut state = Instance::default();
            let mut output = [[0.0; 2]; 64];
            let start = std::time::Instant::now();
            for slot in 0..4096 {
                process(
                    &mut state,
                    slot % 3,
                    std::hint::black_box(&input),
                    &mut output,
                );
                std::hint::black_box(&output);
            }
            times[index] = start.elapsed();
        }
    }
    for (index, label) in ["search", "lookup"].into_iter().enumerate() {
        let mut times: [_; 7] = std::array::from_fn(|round| timings[round][index]);
        times.sort();
        eprintln!("{label}, 4096 slots median: {:?}", times[3]);
    }
}

#[test]
fn allpass_impulse_has_specified_delay_first_tap_and_unit_energy() {
    let taps = [
        [0.1688, -0.1850, 0.3321],
        [0.4665, 0.4958, -0.3901],
        [-0.1932, -0.4178, 0.3804],
    ];
    for (kind, expected) in taps.iter().enumerate() {
        let mut filter = Instance::default();
        let mut energy = [0.0; 3];
        for ts in 0..4096 {
            let mut input = [[0.0; 2]; 64];
            if ts == 0 {
                for sb in [0, 7, 23] {
                    input[sb] = [1.0, -2.0];
                }
            }
            let output = filter.filter(kind, &input);
            for (region, (sb, delay)) in [(0, 7), (7, 10), (23, 12)].into_iter().enumerate() {
                if ts < delay {
                    assert_eq!(output[sb], [0.0; 2]);
                }
                if ts == delay {
                    assert_eq!(output[sb], [expected[region], -2.0 * expected[region]]);
                }
                energy[region] += output[sb].iter().map(|v| v * v).sum::<f64>();
            }
        }
        for value in energy {
            assert!((value - 5.0).abs() < 1.0e-8, "D{kind}: {value}");
        }
    }
}

#[test]
fn transient_ducker_tracks_peak_and_attenuates_reverberation_tail() {
    let mut d = Ducker::default();
    assert_eq!(d.gain(1.0), 1.0);
    let gain = d.gain(0.0);
    assert!((gain - 0.65280258).abs() < 1.0e-7);
    for _ in 0..100 {
        let gain = d.gain(0.0);
        assert!((0.0..=1.0).contains(&gain));
    }
    assert_eq!(d.gain(2.0), 1.0);
}

#[test]
fn seven_instances_are_independent_and_follow_coefficient_cycle() {
    let mut backend = AjocDecorrelation::default();
    let mut output = [[0.0; 2]; 64];
    for ts in 0..40 {
        let input = [[if ts == 0 { 1.0 } else { 0.0 }, 0.0]; 64];
        let mut results = Vec::new();
        for index in 0..7 {
            backend.process(index, &input, &mut output).unwrap();
            results.push(output);
        }
        assert_eq!(results[0], results[3]);
        assert_eq!(results[3], results[6]);
        assert_eq!(results[1], results[4]);
        assert_eq!(results[2], results[5]);
        if ts == 7 {
            assert!(results[0][0][0] > 0.0);
            assert!(results[1][0][0] < 0.0);
            assert!(results[2][0][0] > 0.0);
        }
    }
}

#[test]
fn reset_reproduces_fresh_backend_and_invalid_input_does_not_mutate() {
    let mut used = AjocDecorrelation::default();
    let mut fresh = AjocDecorrelation::default();
    let mut a = [[0.0; 2]; 64];
    let mut b = a;
    used.process(0, &[[1.0, 2.0]; 64], &mut a).unwrap();
    used.reset();
    assert!(used.process(7, &a, &mut b).is_err());
    assert!(used.process(0, &[[f32::NAN, 0.0]; 64], &mut b).is_err());
    for ts in 0..128 {
        let input = [[(ts as f32 * 0.37).sin(), (ts as f32 * 0.19).cos()]; 64];
        used.process(0, &input, &mut a).unwrap();
        fresh.process(0, &input, &mut b).unwrap();
        assert_eq!(a, b);
        assert!(a.iter().flatten().all(|v| v.is_finite()));
    }
}
