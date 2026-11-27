use super::{HyperModel, inference};
use crate::{
    Error,
    quantization::{Grouping, QuantizedChannel},
};

/// Explicit stream-local state; no process-global random generator.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NoiseState(u32);
impl Default for NoiseState {
    fn default() -> Self {
        Self(1)
    }
}
impl NoiseState {
    pub fn seeded(seed: u32) -> Self {
        Self(seed)
    }
    pub(crate) fn sample(&mut self) -> f32 {
        self.0 = self.0.wrapping_mul(214013).wrapping_add(2531011);
        let value = (self.0 >> 16) & 32767;
        value as f32 / 32767.0 * 2.0 - 1.0
    }
}

#[derive(Clone, Copy, Debug)]
pub struct SpectrumConfig {
    pub neural_type: u8,
    pub transform: u8,
    pub noise_lines: usize,
}

impl HyperModel {
    /// Reconstructs the neural spectrum and reverses short-window grouping.
    /// Coupling, BWE, TNS, LSF shaping and time synthesis follow this stage.
    /// The noise state is committed only after successful reconstruction.
    pub fn decode_spectrum(
        &self,
        quantized: &QuantizedChannel,
        grouping: &Grouping,
        config: SpectrumConfig,
        noise: &mut NoiseState,
    ) -> Result<Vec<f32>, Error> {
        if config.neural_type > 1
            || config.transform > 3
            || config.noise_lines > 1024
            || !(1..=2).contains(&grouping.count)
            || quantized.noise_indices.len() != usize::from(grouping.count)
            || quantized.noise_indices.iter().any(|&v| v > 7)
            || (config.neural_type == 0 && quantized.scale_index > 127)
            || (config.transform != 1 && grouping.count != 1)
        {
            return Err(Error::Invalid("spectrum configuration"));
        }
        let latent = self.decode_latents(quantized)?;
        let (lines, channels) = (self.base.latent_lines, self.base.latent_channels);
        let mut features = vec![0.0; lines * channels];
        for line in 0..lines {
            for channel in 0..channels {
                features[channel * lines + line] = latent.base.values[line * channels + channel]
                    as f32
                    + self.base.medians[channel];
            }
        }
        let noise_lines = if config.neural_type == 0 {
            self.base
                .decoder
                .iter()
                .fold(config.noise_lines, |lines, l| lines / l.stride)
        } else {
            config.noise_lines / channels
        };
        if noise_lines > lines || (grouping.count == 2 && !lines.is_multiple_of(8)) {
            return Err(Error::Invalid("noise feature shape"));
        }
        let transient = grouping.indicators.iter().filter(|&&v| !v).count();
        let ranges = if grouping.count == 1 {
            [0..noise_lines, 0..0]
        } else {
            let start = lines / 8 * transient;
            [
                0..noise_lines * transient / 8,
                start..start + noise_lines * (8 - transient) / 8,
            ]
        };
        let mut next = *noise;
        for (group, range) in ranges
            .into_iter()
            .take(usize::from(grouping.count))
            .enumerate()
        {
            let level = f32::from(quantized.noise_indices[group]) / 23.34;
            for line in range {
                for channel in 0..channels {
                    let value = &mut features[channel * lines + line];
                    if *value == self.base.medians[channel] {
                        *value += next.sample() * level;
                    }
                }
            }
        }
        let scale = if config.neural_type == 1 {
            10.0f64.powf(f64::from(
                (f32::from(quantized.scale_index) - 255.0) / 31.875,
            )) as f32
        } else if quantized.amplified {
            10.0f64.powf(f64::from(f32::from(quantized.scale_index) / 86.0)) as f32
        } else {
            f32::from(quantized.scale_index) / 127.0
        };
        let scale = if scale == 0.0 { 1.0 } else { scale };
        for value in &mut features {
            *value /= scale;
        }
        let mut spectrum = if config.neural_type == 0 {
            inference::synthesize(&self.base.decoder, features)?
        } else {
            if lines * channels != 1024 {
                return Err(Error::Unsupported("LC spectral shape"));
            }
            let mut values = vec![0.0; 1024];
            for line in 0..lines {
                for channel in 0..channels {
                    values[line * channels + channel] = features[channel * lines + line];
                }
            }
            values
        };
        if spectrum.len() != 1024 || spectrum.iter().any(|v| !v.is_finite()) {
            return Err(Error::Invalid("neural spectrum"));
        }
        if config.transform == 1 {
            degroup(&mut spectrum, &grouping.indicators);
        }
        *noise = next;
        Ok(spectrum)
    }
}

fn degroup(spectrum: &mut [f32], indicators: &[bool; 8]) {
    let original = spectrum.to_vec();
    let transient = indicators.iter().filter(|&&v| !v).count();
    let mut positions = [0usize; 2];
    for (block, &other) in indicators.iter().enumerate() {
        let group = usize::from(other);
        let count = if other { 8 - transient } else { transient };
        let offset = if other { transient * 128 } else { 0 };
        for bin in 0..128 {
            spectrum[block + bin * 8] = original[offset + positions[group] + bin * count];
        }
        positions[group] += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn deterministic_noise_and_degrouping() {
        let mut state = NoiseState::default();
        for value in [41, 18467, 6334, 26500, 19169] {
            assert_eq!(state.sample(), value as f32 / 32767.0 * 2.0 - 1.0);
        }
        let mut spectrum: Vec<_> = (0..1024).map(|v| v as f32).collect();
        degroup(
            &mut spectrum,
            &[false, true, false, true, false, true, false, true],
        );
        assert_eq!(
            &spectrum[..8],
            &[0.0, 512.0, 1.0, 513.0, 2.0, 514.0, 3.0, 515.0]
        );
        assert_eq!(
            &spectrum[8..16],
            &[4.0, 516.0, 5.0, 517.0, 6.0, 518.0, 7.0, 519.0]
        );
    }
}
