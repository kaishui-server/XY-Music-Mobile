//! A-JOC decorrelation and transient ducking. ETSI TS 103 190-1 V1.3.1,
//! 5.7.7.4, tables 197–200; TS 103 190-2 5.7.3.5 instance ordering.

use super::reconstruction::{Decorrelation, PARAMETER_BAND_ENDS_15, QmfSlot};
use crate::error::{Result, invalid};

// This backend always uses 15 parameter bands. Share the transmitted band's
// boundaries with the generic mapper, but resolve all 64 indices at compile time.
const PARAMETER_BANDS: [u8; 64] = {
    let mut map = [0; 64];
    let (mut subband, mut band) = (0, 0);
    while subband < map.len() {
        while subband >= PARAMETER_BAND_ENDS_15[band] {
            band += 1;
        }
        map[subband] = band as u8;
        subband += 1;
    }
    map
};

// [D0/D1/D2][frequency region][denominator coefficient]. Numerator is reversed.
const COEFFICIENTS: [[[f64; 8]; 3]; 3] = [
    [
        [
            1.0, 0.5306, -0.4533, -0.6248, 0.0424, 0.4237, 0.4311, 0.1688,
        ],
        [1.0, 0.5561, -0.3039, -0.5024, -0.1850, 0.0, 0.0, 0.0],
        [1.0, 0.5773, 0.3321, 0.0, 0.0, 0.0, 0.0, 0.0],
    ],
    [
        [
            1.0, -0.4178, 0.1082, -0.2368, -0.1014, -0.1052, -0.3528, 0.4665,
        ],
        [1.0, 0.0425, 0.3235, -0.1556, 0.4958, 0.0, 0.0, 0.0],
        [1.0, 0.2327, -0.3901, 0.0, 0.0, 0.0, 0.0, 0.0],
    ],
    [
        [
            1.0, 0.4007, 0.4747, 0.2611, -0.1211, -0.4248, -0.2989, -0.1932,
        ],
        [1.0, -0.4361, 0.0345, 0.5215, -0.4178, 0.0, 0.0, 0.0],
        [1.0, -0.6057, 0.3804, 0.0, 0.0, 0.0, 0.0, 0.0],
    ],
];

#[derive(Clone, Default)]
struct BandHistory {
    x: [[f64; 2]; 15],
    y: [[f64; 2]; 7],
}

#[derive(Clone, Copy, Default)]
struct Ducker {
    peak: f64,
    smooth: f64,
    difference: f64,
}

impl Ducker {
    fn gain(&mut self, energy: f64) -> f64 {
        self.peak = (0.76592833836465 * self.peak).max(energy);
        self.smooth = 0.75 * self.smooth + 0.25 * energy;
        self.difference = 0.75 * self.difference + 0.25 * (self.peak - energy);
        if 1.5 * self.difference > self.smooth {
            self.smooth / (1.5 * (self.difference + 1.0e-9))
        } else {
            1.0
        }
    }
}

struct Instance {
    bands: Vec<BandHistory>,
    duckers: [Ducker; 15],
    cursor: usize,
}

impl Default for Instance {
    fn default() -> Self {
        Self {
            bands: vec![BandHistory::default(); 64],
            duckers: [Ducker::default(); 15],
            cursor: 0,
        }
    }
}

impl Instance {
    fn filter(&mut self, kind: usize, input: &QmfSlot) -> [[f64; 2]; 64] {
        let mut output = [[0.0; 2]; 64];
        for (sb, (sample, history)) in output.iter_mut().zip(&mut self.bands).enumerate() {
            let (region, delay, length) = if sb < 7 {
                (0, 7, 7)
            } else if sb < 23 {
                (1, 10, 4)
            } else {
                (2, 12, 2)
            };
            let a = &COEFFICIENTS[kind][region];
            history.x[self.cursor % 15] = input[sb].map(f64::from);
            for (component, value) in sample.iter_mut().enumerate() {
                *value = a[length] * history.x[(self.cursor + 15 - delay) % 15][component];
                for i in 1..=length {
                    *value += a[length - i]
                        * history.x[(self.cursor + 15 - delay - i) % 15][component]
                        - a[i] * history.y[(self.cursor + 7 - i) % 7][component];
                }
            }
            history.y[self.cursor % 7] = *sample;
        }
        // 105 is the joint period of the 15/7-sample circular histories.
        self.cursor = (self.cursor + 1) % 105;
        output
    }

    fn process(&mut self, kind: usize, input: &QmfSlot, output: &mut QmfSlot) {
        let filtered = self.filter(kind, input);
        let mut energy = [0.0; 15];
        for (sb, sample) in input.iter().enumerate() {
            let pb = usize::from(PARAMETER_BANDS[sb]);
            energy[pb] += sample.iter().map(|&v| f64::from(v).powi(2)).sum::<f64>();
        }
        let gains: [f64; 15] = std::array::from_fn(|pb| self.duckers[pb].gain(energy[pb]));
        for (sb, sample) in output.iter_mut().enumerate() {
            let gain = gains[usize::from(PARAMETER_BANDS[sb])];
            *sample = filtered[sb].map(|v| (v * gain) as f32);
        }
    }
}

/// Seven independent filter/ducker histories with cyclic D0,D2,D1 coefficients.
/// Uses f64 filter state to reduce numerical drift in the seventh-order section;
/// the external QMF representation remains f32.
pub struct AjocDecorrelation {
    instances: [Instance; 7],
}

impl Default for AjocDecorrelation {
    fn default() -> Self {
        Self {
            instances: std::array::from_fn(|_| Instance::default()),
        }
    }
}

impl Decorrelation for AjocDecorrelation {
    fn process(&mut self, index: usize, input: &QmfSlot, output: &mut QmfSlot) -> Result<()> {
        if index >= 7 || input.iter().flatten().any(|v| !v.is_finite()) {
            return Err(invalid("A-JOC decorrelator input or index"));
        }
        self.instances[index].process([0, 2, 1][index % 3], input, output);
        if output.iter().flatten().any(|v| !v.is_finite()) {
            self.reset();
            output.fill([0.0; 2]);
            return Err(invalid("A-JOC decorrelator arithmetic overflow"));
        }
        Ok(())
    }

    fn reset(&mut self) {
        for instance in &mut self.instances {
            instance.bands.fill(BandHistory::default());
            instance.duckers.fill(Ducker::default());
            instance.cursor = 0;
        }
    }
}

#[cfg(test)]
mod tests;
