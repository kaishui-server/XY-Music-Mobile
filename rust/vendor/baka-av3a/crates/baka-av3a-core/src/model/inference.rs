use super::{Activation, Layer};
use crate::Error;

/// Layers originate from a validated immutable HyperModel.
pub(super) fn synthesize(layers: &[Layer], mut features: Vec<f32>) -> Result<Vec<f32>, Error> {
    layers.iter().try_fold(0usize, |total, l| {
        let features = l
            .output_lines
            .checked_mul(l.output_channels)
            .ok_or(Error::Unsupported("network work limit"))?;
        let normalization = if matches!(l.activation, Activation::Gdn | Activation::Igdn) {
            features.checked_mul(l.output_channels)
        } else {
            Some(0)
        }
        .ok_or(Error::Unsupported("network work limit"))?;
        features
            .checked_mul(l.input_channels)
            .and_then(|v| v.checked_mul(l.kernel_size))
            .and_then(|v| v.checked_add(normalization))
            .and_then(|v| v.checked_add(total))
            .filter(|&v| v <= 64 * 1024 * 1024)
            .ok_or(Error::Unsupported("network work limit"))
    })?;
    for layer in layers {
        if !layer.transpose || features.len() != layer.input_lines * layer.input_channels {
            return Err(Error::Invalid("synthesis network input"));
        }
        let mut output = vec![0.0; layer.output_lines * layer.output_channels];
        let padding = (layer.kernel_size - 1) / 2;
        for out_channel in 0..layer.output_channels {
            for line in 0..layer.output_lines {
                let first_tap = (layer.stride - 1 + padding + layer.stride - line % layer.stride)
                    % layer.stride;
                let taps = (layer.kernel_size + layer.stride - 1 - first_tap) / layer.stride;
                let mut value = dot(layer.input_channels * taps, |index| {
                    let in_channel = index / taps;
                    let tap = first_tap + (index % taps) * layer.stride;
                    let Some(position) = (line + tap).checked_sub(padding) else {
                        return 0.0;
                    };
                    let input_line = position / layer.stride;
                    if input_line >= layer.input_lines {
                        return 0.0;
                    }
                    let kernel = layer.kernel_size - 1 - tap;
                    let weight = layer.weights[(kernel * layer.output_channels + out_channel)
                        * layer.input_channels
                        + in_channel];
                    weight * features[in_channel * layer.input_lines + input_line]
                });
                if !layer.bias.is_empty() {
                    value += layer.bias[out_channel];
                }
                output[out_channel * layer.output_lines + line] = value;
            }
        }
        activate(layer, &mut output)?;
        features = output;
    }
    Ok(features)
}

fn activate(layer: &Layer, values: &mut [f32]) -> Result<(), Error> {
    if values.iter().any(|v| !v.is_finite()) {
        return Err(Error::Invalid("network preactivation"));
    }
    if matches!(layer.activation, Activation::Gdn | Activation::Igdn) {
        // Every output at this line consumes the same original input squares.
        // Cache them before writing any normalized values; other lines remain
        // untouched. Preserve dot's four-lane f32 accumulation order.
        let mut squared = vec![0.; layer.output_channels];
        for line in 0..layer.output_lines {
            for (input, square) in squared.iter_mut().enumerate() {
                let value = values[input * layer.output_lines + line];
                *square = value * value;
            }
            for output in 0..layer.output_channels {
                let norm = dot(layer.output_channels, |input| {
                    squared[input] * layer.gamma[input * layer.output_channels + output]
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

#[cfg(test)]
mod normalization_tests;

// Preserve the four independent accumulation lanes and final remainder sum.
fn dot(count: usize, mut product: impl FnMut(usize) -> f32) -> f32 {
    let mut lanes = [0.0f32; 4];
    let bulk = count / 8 * 8;
    for start in (0..bulk).step_by(8) {
        for (lane, value) in lanes.iter_mut().enumerate() {
            *value += product(start + lane * 2);
            *value += product(start + lane * 2 + 1);
        }
    }
    let mut tail = 0.0;
    for index in bulk..count {
        tail += product(index);
    }
    ((lanes[0] + lanes[1]) + (lanes[2] + lanes[3])) + tail
}

#[cfg(test)]
mod tests {
    use super::*;
    fn layer(kernel_size: usize, stride: usize, weights: Vec<f32>) -> Layer {
        Layer {
            transpose: true,
            stride,
            kernel_size,
            input_channels: 1,
            output_channels: 1,
            input_lines: 2,
            output_lines: 2 * stride,
            activation: Activation::Linear,
            weights,
            bias: vec![],
            beta: vec![],
            gamma: vec![],
        }
    }
    #[test]
    fn transpose_alignment_and_bias() {
        assert_eq!(
            synthesize(&[layer(3, 2, vec![1.0, 10.0, 100.0])], vec![2.0, 3.0]).unwrap(),
            [2.0, 20.0, 203.0, 30.0]
        );
        assert_eq!(
            synthesize(
                &[layer(5, 2, vec![1.0, 10.0, 100.0, 1000.0, 10000.0])],
                vec![2.0, 3.0]
            )
            .unwrap(),
            [20.0, 203.0, 2030.0, 20300.0]
        );
        let mut l = layer(3, 1, vec![1.0, 10.0, 100.0]);
        l.bias = vec![1.0];
        assert_eq!(synthesize(&[l], vec![2.0, 3.0]).unwrap(), [24.0, 231.0]);
    }
    #[test]
    fn asymmetric_normalization_and_nonfinite_output() {
        let mut l = layer(1, 1, vec![1.0]);
        l.output_lines = 1;
        l.output_channels = 2;
        l.beta = vec![1.0, 2.0];
        l.gamma = vec![1.0, 2.0, 3.0, 4.0];
        l.activation = Activation::Gdn;
        let mut values = vec![3.0, 4.0];
        activate(&l, &mut values).unwrap();
        assert_eq!(values, [3.0 / 58.0f32.sqrt(), 4.0 / 84.0f32.sqrt()]);
        let mut l = layer(1, 1, vec![f32::MAX]);
        l.activation = Activation::Relu;
        assert!(synthesize(&[l], vec![f32::MAX; 2]).is_err());
    }
    #[test]
    fn normalization_work_is_included_in_budget() {
        let mut l = layer(1, 1, vec![1.0; 256]);
        l.input_lines = 1024;
        l.output_lines = 1024;
        l.output_channels = 256;
        l.activation = Activation::Gdn;
        l.beta = vec![1.0; 256];
        l.gamma = vec![0.0; 256 * 256];
        assert_eq!(
            synthesize(&[l], vec![0.0; 1024]),
            Err(Error::Unsupported("network work limit"))
        );
    }
}
