//! Physical values derived from quantized fields without altering stored indices.
use super::*;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum GainValue {
    Linear(f32),
    Decibels(f32),
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DynamicsValues {
    pub attack_ms: f32,
    pub release_ms: f32,
    pub threshold_db: f32,
    pub pre_gain_db: f32,
    pub post_gain_db: f32,
    pub ratio: f32,
}
fn cartesian(v: [u8; 3]) -> [f32; 3] {
    [
        (i16::from(v[0]) - 128) as f32 * (2.0 / 255.0),
        (i16::from(v[1]) - 32) as f32 * (2.0 / 63.0),
        (i16::from(v[2]) - 8) as f32 * (2.0 / 15.0),
    ]
}
fn loudness(v: [Option<u8>; 6]) -> [Option<f32>; 6] {
    std::array::from_fn(|i| {
        v[i].map(|v| {
            if i == 1 {
                f32::from(v) * (60.0 / 31.0) + 10.0
            } else {
                f32::from(v) * (-70.0 / 31.0)
            }
        })
    })
}
impl EncodedGain {
    /// Both object and channel gains use these resolutions; dB remains dB.
    pub fn value(&self) -> GainValue {
        let index = f32::from(self.index);
        if self.decibels {
            GainValue::Decibels(
                index
                    * if self.upper {
                        24.0 / 63.0
                    } else {
                        -80.0 / 63.0
                    },
            )
        } else {
            GainValue::Linear(if self.upper {
                index * (15.0 / 63.0) + 1.0
            } else {
                index * (1.0 / 63.0)
            })
        }
    }
}
impl GainInteraction {
    /// Min/max in dB when decibels is true, otherwise linear gain.
    pub fn values(&self) -> [f32; 2] {
        if self.decibels {
            [
                f32::from(self.range[0]) * (-80.0 / 127.0),
                f32::from(self.range[1]) * (24.0 / 127.0),
            ]
        } else {
            [
                f32::from(self.range[0]) * (1.0 / 127.0),
                f32::from(self.range[1]) * (15.0 / 127.0) + 1.0,
            ]
        }
    }
}
impl PositionInteraction {
    /// Per-axis min/max: degrees/degrees/unit distance for polar coordinates.
    pub fn values(&self) -> [[f32; 2]; 3] {
        if self.cartesian {
            let scales = [2.0 / 255.0, 2.0 / 63.0, 2.0 / 15.0];
            let biases = [128i16, 32, 8];
            std::array::from_fn(|i| {
                std::array::from_fn(|j| {
                    (i16::from(self.ranges[i][j]) - biases[i]) as f32 * scales[i]
                })
            })
        } else {
            [
                [
                    f32::from(self.ranges[0][0]) * (-180.0 / 255.0),
                    f32::from(self.ranges[0][1]) * (180.0 / 255.0),
                ],
                [
                    f32::from(self.ranges[1][0]) * (-90.0 / 63.0),
                    f32::from(self.ranges[1][1]) * (90.0 / 63.0),
                ],
                [
                    f32::from(self.ranges[2][0]) * (1.0 / 15.0),
                    f32::from(self.ranges[2][1]) * (1.0 / 15.0),
                ],
            ]
        }
    }
}
impl Programme {
    pub fn ducking_decibels(&self) -> Option<f32> {
        self.ducking_depth.map(|v| f32::from(v) * (-62.0 / 31.0))
    }
    /// Integrated/range/true-peak/momentary/short-term/dialogue, in encoded order.
    pub fn loudness_values(&self) -> Option<[Option<f32>; 6]> {
        self.loudness.map(loudness)
    }
}
impl Content {
    pub fn loudness_values(&self) -> Option<[Option<f32>; 6]> {
        self.loudness.map(loudness)
    }
}
impl Screen {
    /// Polar screen elevation is unsigned, unlike object/speaker elevation.
    pub fn coordinates(&self) -> [f32; 3] {
        if self.cartesian {
            cartesian(self.position)
        } else {
            [
                (i16::from(self.position[0]) - 128) as f32 * (360.0 / 255.0),
                f32::from(self.position[1]) * (90.0 / 63.0),
                f32::from(self.position[2]) * (1.0 / 15.0),
            ]
        }
    }
    /// Polar width is degrees; Cartesian width uses unit coordinates.
    pub fn width_value(&self) -> f32 {
        f32::from(self.width)
            * if self.cartesian {
                1.0 / 127.0
            } else {
                180.0 / 127.0
            }
    }
}
impl SpeakerPosition {
    pub fn polar_coordinates(&self) -> [f32; 3] {
        [
            (i16::from(self.coordinates[0]) - 128) as f32 * (360.0 / 255.0),
            (i16::from(self.coordinates[1]) - 32) as f32 * (180.0 / 63.0),
            f32::from(self.coordinates[2]) * (1.0 / 15.0),
        ]
    }
}
impl HoaPack {
    pub fn nfc_reference_distance(&self) -> f32 {
        f32::from(self.nfc_distance) * (1.0 / 15.0)
    }
}
impl AudioPack {
    pub fn absolute_distance_value(&self) -> f32 {
        10.0f32.powf(f32::from(self.absolute_distance) * (1.230448 / 31.0)) - 1.0
    }
}
impl StaticChannel {
    pub fn matrix_values(&self) -> Vec<f32> {
        self.matrix_coefficients
            .iter()
            .map(|&v| f32::from(v) * (9.9 / 255.0) + 0.1)
            .collect()
    }
}
impl EqBand {
    pub fn frequency_hz(&self) -> f32 {
        10.0f32
            .powf((f32::from(self.frequency) * (58.061_8 / 127.0) + 20.0 * 20.0f32.log10()) / 20.0)
    }
    pub fn q_value(&self) -> f32 {
        if self.upper_q {
            f32::from(self.q) * (11.0 / 63.0) + 1.0
        } else {
            f32::from(self.q) * (0.9 / 63.0) + 0.1
        }
    }
    pub fn gain_decibels(&self) -> f32 {
        (i16::from(self.gain) - 64) as f32 * (40.0 / 127.0)
    }
}
impl AudioEffects {
    pub fn dynamics_values(&self) -> Option<DynamicsValues> {
        self.dynamics.map(|v| DynamicsValues {
            attack_ms: f32::from(v[0]) * (99.0 / 15.0) + 1.0,
            release_ms: f32::from(v[1]) * (250.0 / 15.0) + 50.0,
            threshold_db: f32::from(v[2]) * (90.0 / 127.0) - 80.0,
            pre_gain_db: (i16::from(v[3]) - 64) as f32 * (20.0 / 127.0),
            post_gain_db: f32::from(v[4]) * (20.0 / 127.0),
            ratio: f32::from(v[5]) * (99.0 / 127.0) + 1.0,
        })
    }
    pub fn gain_decibels(&self) -> Option<f32> {
        self.gain
            .map(|v| (i16::from(v) - 64) as f32 * (40.0 / 127.0))
    }
}
impl Surface {
    pub fn material_values(&self) -> Option<[[f32; 2]; 8]> {
        self.material_coefficients
            .map(|values| values.map(|pair| pair.map(|v| f32::from(v) * (1.0 / 127.0))))
    }
    pub fn vertex_values(&self) -> Vec<[f32; 3]> {
        self.vertices
            .iter()
            .map(|v| v.map(|v| (i16::from(v) - 64) as f32 * (200.0 / 127.0)))
            .collect()
    }
}
impl AcousticEnvironment {
    pub fn early_reflection_gain(&self) -> Option<f32> {
        self.early_gain.map(|v| f32::from(v) * (1.0 / 127.0))
    }
    pub fn late_reverb_gain(&self) -> Option<f32> {
        self.late_gain.map(|v| f32::from(v) * (1.0 / 127.0))
    }
}
