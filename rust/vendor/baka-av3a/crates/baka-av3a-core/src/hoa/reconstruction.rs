use super::{HoaConfig, HoaSide, SUBBANDS};
use crate::{Error, spectral::energy_gain, synthesis::ImdctPlan};
use std::sync::Arc;
#[cfg(test)]
mod tests;

#[derive(Clone, Debug)]
pub struct HoaBasis {
    coefficients: Vec<f32>,
}
impl HoaBasis {
    /// AV3HOA01 followed by 1343x16 entry/channel f32 LE coefficients.
    pub fn parse(bytes: &[u8]) -> Result<Self, Error> {
        if bytes.len() != 8 + 1343 * 16 * 4 || &bytes[..8] != b"AV3HOA01" {
            return Err(Error::Invalid("HOA basis asset format"));
        }
        let coefficients: Vec<_> = bytes[8..]
            .as_chunks::<4>()
            .0
            .iter()
            .map(|v| f32::from_le_bytes(*v))
            .collect();
        if coefficients.iter().any(|v| !v.is_finite() || v.abs() > 1.0) {
            return Err(Error::Invalid("HOA basis coefficient"));
        }
        Ok(Self { coefficients })
    }
}

impl HoaSide {
    /// Subband MS pairs are applied in wire order, followed by channel gain.
    /// The supplied spectra are owned; malformed shapes never change caller data.
    pub fn inverse_mix(
        &self,
        config: &HoaConfig,
        mut spectra: Vec<Vec<f32>>,
    ) -> Result<Vec<Vec<f32>>, Error> {
        if spectra.len() != config.transport_channels()
            || self.groups.len() != config.groups().len()
            || spectra
                .iter()
                .any(|s| s.len() != 1024 || s.iter().any(|v| !v.is_finite()))
        {
            return Err(Error::Invalid("HOA spectral shape"));
        }
        let mut offset = 0;
        for (group, side) in config.groups().iter().zip(&self.groups) {
            if side.energy.len() != group.channels || side.pairs.len() > 15 {
                return Err(Error::Invalid("HOA spectral group"));
            }
            for pair in &side.pairs {
                let [a, b] = pair.channels;
                if a >= b || b >= group.channels {
                    return Err(Error::Invalid("HOA spectral pair"));
                }
                for (band, &enabled) in pair.mask.iter().enumerate() {
                    if enabled {
                        for bin in SUBBANDS[band]..SUBBANDS[band + 1] {
                            let (left, right) =
                                (spectra[offset + a][bin], spectra[offset + b][bin]);
                            spectra[offset + a][bin] =
                                (left + right) * std::f32::consts::FRAC_1_SQRT_2;
                            spectra[offset + b][bin] =
                                (left - right) * std::f32::consts::FRAC_1_SQRT_2;
                        }
                    }
                }
            }
            for (channel, &index) in side.energy.iter().enumerate() {
                if index != 30 {
                    let gain = energy_gain(index)?;
                    for value in &mut spectra[offset + channel] {
                        *value *= gain;
                    }
                }
            }
            offset += group.channels;
        }
        if spectra.iter().flatten().any(|v| !v.is_finite()) {
            return Err(Error::Invalid("HOA spectral output"));
        }
        Ok(spectra)
    }
}

#[derive(Clone, Debug)]
pub(crate) struct HoaSynthesis {
    config: HoaConfig,
    plan: Arc<ImdctPlan>,
    window: Arc<[f32]>,
    previous: Vec<[f32; 512]>,
    overlap: Vec<[f32; 512]>,
    basis_delay: [[u16; 2]; 2],
}
impl HoaSynthesis {
    pub(crate) fn new(config: HoaConfig) -> Self {
        Self {
            previous: vec![[0.0; 512]; config.transport_channels()],
            overlap: vec![[0.0; 512]; config.output_channels()],
            config,
            plan: Arc::new(ImdctPlan::new(512)),
            window: (0..512)
                .map(|i| f64::from(std::f32::consts::PI / 1024.0 * (i as f32 + 0.5)).sin() as f32)
                .collect(),
            basis_delay: [[0; 2]; 2],
        }
    }
    /// Caller uses a cloned state and commits it only after the whole frame succeeds.
    pub(crate) fn process(
        &mut self,
        input: &[[f32; 1024]],
        side: &HoaSide,
        basis: Option<&HoaBasis>,
    ) -> Result<Vec<[f32; 1024]>, Error> {
        if input.len() != self.config.transport_channels()
            || side.spatial != self.config.spatial()
            || input.iter().flatten().any(|v| !v.is_finite())
        {
            return Err(Error::Invalid("HOA synthesis input"));
        }
        if side.spatial
            && (side.basis_indices.len() != 2 || side.basis_indices.iter().any(|&i| i >= 1343))
        {
            return Err(Error::Invalid("HOA synthesis basis"));
        }
        let mut spectra = vec![[0.0; 1024]; self.config.output_channels()];
        for (channel, pcm) in input.iter().enumerate() {
            for block in 0..2 {
                let mut signal = [0.0; 1024];
                for i in 0..512 {
                    let left = if block == 0 {
                        self.previous[channel][i]
                    } else {
                        pcm[i]
                    };
                    signal[i] = left * self.window[i];
                    signal[512 + i] = pcm[block * 512 + i] * self.window[511 - i];
                }
                spectra[channel][block * 512..(block + 1) * 512]
                    .copy_from_slice(&self.plan.forward(&signal));
            }
        }
        if side.spatial {
            let basis = basis.ok_or(Error::Unsupported("missing HOA basis asset"))?;
            let mut recovered = vec![[0.0; 1024]; self.config.output_channels()];
            for (channel, values) in recovered.iter_mut().enumerate() {
                let a = basis.coefficients[usize::from(self.basis_delay[0][0]) * 16 + channel];
                let b = basis.coefficients[usize::from(self.basis_delay[0][1]) * 16 + channel];
                for (line, value) in values.iter_mut().enumerate() {
                    *value = spectra[0][line] * a + spectra[1][line] * b;
                    if channel < self.config.transport_channels() - 2 {
                        *value += spectra[channel + 2][line];
                    }
                }
            }
            spectra = recovered;
        }
        let mut output = vec![[0.0; 1024]; self.config.output_channels()];
        for (channel, spectrum) in spectra.iter().enumerate() {
            for block in 0..2 {
                let signal = self.plan.run(&spectrum[block * 512..(block + 1) * 512]);
                for i in 0..512 {
                    output[channel][block * 512 + i] =
                        signal[i] * self.window[i] + self.overlap[channel][i];
                    self.overlap[channel][i] = signal[512 + i] * self.window[511 - i];
                }
            }
        }
        if output
            .iter()
            .flatten()
            .chain(self.overlap.iter().flatten())
            .any(|v| !v.is_finite())
        {
            return Err(Error::Invalid("HOA synthesis output"));
        }
        for (previous, pcm) in self.previous.iter_mut().zip(input) {
            previous.copy_from_slice(&pcm[512..]);
        }
        if side.spatial {
            self.basis_delay[0] = self.basis_delay[1];
            self.basis_delay[1].copy_from_slice(&side.basis_indices);
        }
        Ok(output)
    }
}
