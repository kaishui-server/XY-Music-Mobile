//! Coupling reversal and temporal noise shaping; LSF shaping follows these stages.
use crate::{
    Error,
    side::{CoreSide, McSide},
};

pub fn inverse_stereo(
    mut spectra: Vec<Vec<f32>>,
    index: Option<u8>,
) -> Result<Vec<Vec<f32>>, Error> {
    if spectra.len() != 2
        || spectra
            .iter()
            .any(|s| s.len() != 1024 || s.iter().any(|v| !v.is_finite()))
        || index.is_some_and(|i| !(1..=15).contains(&i))
    {
        return Err(Error::Invalid("stereo spectrum"));
    }
    if let Some(index) = index {
        for bin in 0..1024 {
            let (a, b) = (spectra[0][bin], spectra[1][bin]);
            spectra[0][bin] = std::f32::consts::FRAC_1_SQRT_2 * (a + b);
            spectra[1][bin] = std::f32::consts::FRAC_1_SQRT_2 * (a - b);
        }
        let ratio = 16.0 / f32::from(index) - 1.0;
        if ratio > 1.0 {
            for v in &mut spectra[1] {
                *v *= ratio;
            }
        } else if ratio < 1.0 {
            for v in &mut spectra[0] {
                *v *= 1.0 / ratio;
            }
        }
    }
    if spectra.iter().flatten().any(|v| !v.is_finite()) {
        return Err(Error::Invalid("stereo output"));
    }
    Ok(spectra)
}

pub fn uncouple(spectra: Vec<Vec<f32>>, mode: &McSide, lfe: bool) -> Result<Vec<Vec<f32>>, Error> {
    let bed_channels = spectra.len();
    uncouple_mixed(spectra, mode, bed_channels, lfe)
}

/// Reconstruct bed/object coupling while preserving the bed's LFE position.
/// Energy balance affects the non-LFE bed channels only.
pub fn uncouple_mixed(
    mut spectra: Vec<Vec<f32>>,
    mode: &McSide,
    bed_channels: usize,
    lfe: bool,
) -> Result<Vec<Vec<f32>>, Error> {
    let channels = spectra.len();
    if !(1..=16).contains(&channels)
        || bed_channels > channels
        || (lfe && bed_channels < 4)
        || mode.pairs.len() > 15
        || mode.silent.len() != channels
        || spectra
            .iter()
            .any(|v| v.len() != 1024 || v.iter().any(|f| !f.is_finite()))
    {
        return Err(Error::Invalid("coupled spectrum shape"));
    }
    let mut energy = vec![30; channels];
    for pair in &mode.pairs {
        if pair.channels.iter().any(|&v| v >= channels)
            || pair.channels[0] == pair.channels[1]
            || pair.energy_indices.iter().any(|&v| v >= 30)
        {
            return Err(Error::Invalid("spectral pair"));
        }
        for (i, &channel) in pair.channels.iter().enumerate() {
            energy[channel] = pair.energy_indices[i];
        }
    }
    let map = |i| {
        if !lfe || i < 3 || i >= bed_channels {
            i
        } else if i == bed_channels - 1 {
            3
        } else {
            i + 1
        }
    };
    let gain = std::f32::consts::FRAC_1_SQRT_2;
    for pair in mode.pairs.iter().rev() {
        let [left, right] = pair.channels.map(map);
        for bin in 0..1024 {
            let (mid, side) = (spectra[left][bin], spectra[right][bin]);
            spectra[left][bin] = (mid + side) * gain;
            spectra[right][bin] = (mid - side) * gain;
        }
    }
    for (channel, &index) in energy
        .iter()
        .take(bed_channels - usize::from(lfe))
        .enumerate()
    {
        if index != 30 {
            let (a, b) = RATIOS[usize::from(index)];
            let factor = f32::from(a) / f32::from(b);
            for value in &mut spectra[map(channel)] {
                *value *= factor;
            }
        }
    }
    if spectra.iter().flatten().any(|v| !v.is_finite()) {
        return Err(Error::Invalid("uncoupled spectrum"));
    }
    Ok(spectra)
}

/// Runs both bands high-to-low, preserving the shared lattice state between bands.
pub fn inverse_tns(spectrum: &mut [f32; 1024], core: &CoreSide) -> Result<(), Error> {
    if core.transform > 3
        || core
            .tns
            .iter()
            .any(|f| f.len() > 8 || f.iter().any(|&v| !(-8..=7).contains(&v)))
        || spectrum.iter().any(|v| !v.is_finite())
    {
        return Err(Error::Invalid("TNS spectrum configuration"));
    }
    let mut values = *spectrum;
    if core.transform == 1 {
        for block in 0..8 {
            for bin in 0..128 {
                values[block * 128 + bin] = spectrum[bin * 8 + block];
            }
        }
    }
    let mut state = [0.0f32; 8];
    let bands = [
        (2048 * 660 / 48000, 2048 * 5400 / 48000),
        (2048 * 5400 / 48000, 2048 * 20000 / 48000),
    ];
    for band in (0..2).rev() {
        let indices = &core.tns[band];
        let order = indices.len();
        if order == 0 {
            continue;
        }
        let coefficients: Vec<f32> = indices
            .iter()
            .map(|&i| {
                let denominator = if i < 0 { 17.0 } else { 15.0 };
                (f64::from(i) * std::f64::consts::PI / denominator).sin() as f32
            })
            .collect();
        for value in &mut values[bands[band].0..bands[band].1] {
            let mut x = *value - coefficients[order - 1] * state[order - 1];
            for i in (0..order - 1).rev() {
                x -= coefficients[i] * state[i];
                state[i + 1] = coefficients[i] * x + state[i];
            }
            state[0] = x;
            *value = x;
        }
    }
    if values.iter().any(|v| !v.is_finite()) {
        return Err(Error::Invalid("TNS output"));
    }
    if core.transform == 1 {
        for block in 0..8 {
            for bin in 0..128 {
                spectrum[bin * 8 + block] = values[block * 128 + bin];
            }
        }
    } else {
        *spectrum = values;
    }
    Ok(())
}

const RATIOS: [(u8, u8); 30] = [
    (16, 9),
    (3, 4),
    (9, 16),
    (16, 5),
    (16, 3),
    (13, 16),
    (16, 15),
    (4, 1),
    (3, 16),
    (8, 7),
    (7, 16),
    (16, 11),
    (1, 8),
    (5, 8),
    (16, 7),
    (1, 2),
    (16, 1),
    (2, 1),
    (7, 8),
    (1, 4),
    (4, 3),
    (3, 8),
    (8, 5),
    (8, 1),
    (11, 16),
    (1, 16),
    (16, 13),
    (5, 16),
    (15, 16),
    (8, 3),
];

pub(crate) fn energy_gain(index: u8) -> Result<f32, Error> {
    if index == 30 {
        return Ok(1.0);
    }
    let &(a, b) = RATIOS
        .get(usize::from(index))
        .ok_or(Error::Invalid("energy index"))?;
    Ok(f32::from(a) / f32::from(b))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::side::ChannelPair;
    #[test]
    fn mixed_lfe_mapping_and_object_energy_scope() {
        let spectra: Vec<_> = (0..8).map(|i| vec![i as f32; 1024]).collect();
        let mode = McSide {
            silent: vec![false; 8],
            pairs: vec![ChannelPair {
                channels: [4, 6],
                energy_indices: [7, 23],
            }],
            ratios: vec![8; 7],
        };
        let output = uncouple_mixed(spectra.clone(), &mode, 6, true).unwrap();
        assert_eq!(output[3], spectra[3]);
        assert_eq!(output[7], spectra[7]);
        assert_eq!(output[5][0], 11.0 * std::f32::consts::FRAC_1_SQRT_2 * 4.0);
        assert_eq!(output[6][0], -std::f32::consts::FRAC_1_SQRT_2);
        let mode = McSide {
            pairs: vec![ChannelPair {
                channels: [0, 1],
                energy_indices: [16, 23],
            }],
            ..mode
        };
        let output = uncouple_mixed(spectra.clone(), &mode, 0, false).unwrap();
        assert_eq!(output[0][0], std::f32::consts::FRAC_1_SQRT_2);
        assert_eq!(output[1][0], -std::f32::consts::FRAC_1_SQRT_2);
        assert!(uncouple_mixed(spectra, &mode, 0, true).is_err());
    }

    #[test]
    fn energy_scaling_and_lfe_mapping() {
        let mut spectra = vec![vec![0.0; 1024]; 6];
        spectra[3].fill(9.0);
        spectra[4].fill(1.0);
        spectra[5].fill(3.0);
        let mode = McSide {
            silent: vec![false; 6],
            ratios: vec![],
            pairs: vec![ChannelPair {
                channels: [3, 4],
                energy_indices: [17, 15],
            }],
        };
        let out = uncouple(spectra, &mode, true).unwrap();
        assert_eq!(out[3][0], 9.0);
        assert_eq!(out[4][0], 4.0 * std::f32::consts::FRAC_1_SQRT_2 * 2.0);
        assert_eq!(out[5][0], -2.0 * std::f32::consts::FRAC_1_SQRT_2 * 0.5);
    }
    #[test]
    fn single_pole_tns_and_transactional_rejection() {
        let mut spectrum = [0.0; 1024];
        spectrum[28] = 1.0;
        let mut core = CoreSide {
            transform: 0,
            lsf_indices: vec![],
            tns: [vec![-1], vec![]],
        };
        inverse_tns(&mut spectrum, &core).unwrap();
        assert_eq!(spectrum[28], 1.0);
        assert_eq!(spectrum[29], -((-std::f64::consts::PI / 17.0).sin() as f32));
        let original = spectrum;
        core.tns[0].push(8);
        assert!(inverse_tns(&mut spectrum, &core).is_err());
        assert_eq!(spectrum, original);
    }
}
