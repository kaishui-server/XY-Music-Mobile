use super::*;

fn reference_activate(layer: &Layer, values: &mut [f32]) -> Result<(), Error> {
    if values.iter().any(|v| !v.is_finite()) {
        return Err(Error::Invalid("network preactivation"));
    }
    if matches!(layer.activation, Activation::Gdn | Activation::Igdn) {
        let original = values.to_vec();
        for line in 0..layer.output_lines {
            for output in 0..layer.output_channels {
                let norm = dot(layer.output_channels, |input| {
                    let value = original[input * layer.output_lines + line];
                    value * value * layer.gamma[input * layer.output_channels + output]
                });
                let norm = norm + layer.beta[output];
                if !norm.is_finite() || norm <= 0.0 {
                    return Err(Error::Invalid("network normalization"));
                }
                let norm = norm.sqrt();
                let value = &mut values[output * layer.output_lines + line];
                if layer.activation == Activation::Gdn {
                    *value /= norm;
                } else {
                    *value *= norm;
                }
            }
        }
    } else {
        for value in values.iter_mut() {
            *value = match layer.activation {
                Activation::Relu => value.max(0.0),
                Activation::Linear => *value,
                Activation::Sigmoid => 1.0 / (1.0 + (-*value).exp()),
                Activation::Tanh => value.tanh(),
                _ => unreachable!(),
            };
        }
    }
    if values.iter().any(|v| !v.is_finite()) {
        return Err(Error::Invalid("network output"));
    }
    Ok(())
}

fn normalization_layer(channels: usize, lines: usize, activation: Activation) -> Layer {
    Layer {
        transpose: true,
        stride: 1,
        kernel_size: 1,
        input_channels: channels,
        output_channels: channels,
        input_lines: lines,
        output_lines: lines,
        activation,
        weights: vec![],
        bias: vec![],
        beta: (0..channels).map(|i| 0.5 + i as f32 / 7.).collect(),
        gamma: (0..channels * channels)
            .map(|i| (i * 37 % 101) as f32 / 101.)
            .collect(),
    }
}

fn assert_matches(layer: &Layer, input: &[f32]) {
    let mut expected = input.to_vec();
    let mut actual = expected.clone();
    assert_eq!(
        activate(layer, &mut actual),
        reference_activate(layer, &mut expected)
    );
    assert_eq!(
        actual.iter().map(|v| v.to_bits()).collect::<Vec<_>>(),
        expected.iter().map(|v| v.to_bits()).collect::<Vec<_>>(),
        "channels={} lines={} activation={:?}",
        layer.output_channels,
        layer.output_lines,
        layer.activation,
    );
}

#[test]
fn normalization_preserves_original_float_bits_and_partial_error_results() {
    for channels in [1, 2, 3, 7, 8, 9, 16, 31, 32, 64] {
        for lines in [1, 2, 17, 128] {
            for activation in [Activation::Gdn, Activation::Igdn] {
                let layer = normalization_layer(channels, lines, activation);
                let values: Vec<_> = (0..channels * lines)
                    .map(|i| {
                        [
                            0.,
                            -0.,
                            f32::from_bits(1),
                            f32::MIN_POSITIVE,
                            (i * 7919 % 65537) as f32 / 1024. - 32.,
                        ][i % 5]
                    })
                    .collect();
                assert_matches(&layer, &values);
                let mut invalid = layer.clone();
                invalid.beta[channels - 1] = -f32::MAX;
                assert_matches(&invalid, &values);
                for exceptional in [f32::MAX, f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
                    let mut input = values.clone();
                    input[0] = exceptional;
                    assert_matches(&layer, &input);
                }
                let mut invalid = layer.clone();
                invalid.gamma.fill(0.);
                let mut input = values.clone();
                input[0] = f32::MAX;
                assert_matches(&invalid, &input);
            }
        }
    }
}

#[test]
#[ignore = "manual release host timing; not a device benchmark"]
fn normalization_measurement() {
    use std::{hint::black_box, time::Instant};
    type Activate = fn(&Layer, &mut [f32]) -> Result<(), Error>;
    for (channels, lines) in [(16, 64), (32, 128), (64, 256)] {
        let layer = normalization_layer(channels, lines, Activation::Igdn);
        let original: Vec<_> = (0..channels * lines)
            .map(|i| (i * 491 % 997) as f32 / 997. - 0.5)
            .collect();
        let mut work = original.clone();
        let mut measure = |activate: Activate| {
            let started = Instant::now();
            for _ in 0..100 {
                work.copy_from_slice(&original);
                activate(black_box(&layer), black_box(&mut work)).unwrap();
                black_box(&work);
            }
            started.elapsed().as_micros()
        };
        let mut before = Vec::new();
        let mut after = Vec::new();
        for round in 0..10 {
            let (a, b) = if round % 2 == 0 {
                (measure(reference_activate), measure(activate))
            } else {
                let b = measure(activate);
                (measure(reference_activate), b)
            };
            if round >= 3 {
                before.push(a);
                after.push(b);
            }
        }
        before.sort_unstable();
        after.sort_unstable();
        eprintln!(
            "AV3A normalization channels={channels} lines={lines} runs=100 medianUs: before={} after={} scratchBytesBefore={} scratchBytesAfter={}",
            before[3],
            after[3],
            channels * lines * 4,
            channels * 4
        );
    }
}
