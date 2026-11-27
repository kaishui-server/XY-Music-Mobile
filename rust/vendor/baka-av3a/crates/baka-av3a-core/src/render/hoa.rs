use super::{
    BedLayout, GainRenderer, ObjectGains,
    panner::{PointPanner, direction},
};
use crate::{Error, Profile, metadata::HoaPack};

/// Input coefficient normalization. Channel order is always ACN, including FuMa
/// normalization; FuMa's legacy channel permutation must be resolved by callers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HoaNormalization {
    N3d,
    Sn3d,
    FuMa,
}

/// Prepared loudspeaker decoder matrix for complete ACN orders 0 through 3.
/// Construction integrates a bounded, equal-area virtual-speaker grid. It must
/// run outside the audio callback. No external point-set assets are needed.
#[derive(Clone, Debug)]
pub struct HoaDecoder {
    order: u8,
    normalization: HoaNormalization,
    output: BedLayout,
    matrix: Vec<f64>,
}

impl HoaDecoder {
    /// AV3A pack normalization 0 is SN3D; other wire codes are reserved.
    /// Near-field compensation and HOA screen semantics need explicit handling.
    pub fn from_pack(pack: &HoaPack, output: BedLayout) -> Result<Self, Error> {
        if pack.normalization != 0 {
            return Err(Error::Unsupported("reserved HOA normalization"));
        }
        if pack.nfc_distance > 15 {
            return Err(Error::Invalid("HOA near-field distance"));
        }
        if pack.nfc_distance != 0 {
            return Err(Error::Unsupported("HOA near-field compensation"));
        }
        if pack.screen_reference {
            return Err(Error::Unsupported("HOA screen reference"));
        }
        Self::new(pack.order, HoaNormalization::Sn3d, output, false)
    }
    pub fn new(
        order: u8,
        normalization: HoaNormalization,
        output: BedLayout,
        max_re: bool,
    ) -> Result<Self, Error> {
        Self::with_resolution(order, normalization, output, max_re, 64)
    }

    /// Even latitude counts 16..128; azimuth has twice that count. The default
    /// 64 uses 8192 virtual directions, independent of the input stream rate.
    pub fn with_resolution(
        order: u8,
        normalization: HoaNormalization,
        output: BedLayout,
        max_re: bool,
        latitudes: u16,
    ) -> Result<Self, Error> {
        if order > 3 || !(16..=128).contains(&latitudes) || !latitudes.is_multiple_of(2) {
            return Err(Error::Invalid(
                "HOA decoder order or integration resolution",
            ));
        }
        let channels = (usize::from(order) + 1).pow(2);
        let outputs = usize::from(output.channels());
        let panner = PointPanner::new(output);
        let mut matrix = vec![0.0; outputs * channels];
        let mut covariance = [[0.0; 16]; 16];
        let latitudes = usize::from(latitudes);
        let azimuths = latitudes * 2;
        let weight = 1.0 / (latitudes * azimuths) as f64;
        for row in 0..latitudes {
            let z = -1.0 + 2.0 * (row as f64 + 0.5) / latitudes as f64;
            let elevation = z.asin().to_degrees();
            for column in 0..azimuths {
                let azimuth = 360.0 * (column as f64 + 0.5) / azimuths as f64;
                let harmonic = harmonics(order, azimuth.to_radians(), z);
                let gains = panner.pan(direction(azimuth, elevation))?;
                for speaker in 0..outputs {
                    for channel in 0..channels {
                        matrix[speaker * channels + channel] +=
                            weight * gains[speaker] * harmonic[channel];
                    }
                }
                for a in 0..channels {
                    for b in 0..channels {
                        covariance[a][b] += weight * harmonic[a] * harmonic[b];
                    }
                }
            }
        }
        if max_re {
            let cosine = (137.9 / (f64::from(order) + 1.51)).to_radians().cos();
            let weights = [
                1.0,
                cosine,
                (3.0 * cosine * cosine - 1.0) / 2.0,
                (5.0 * cosine.powi(3) - 3.0 * cosine) / 2.0,
            ];
            for row in matrix.chunks_exact_mut(channels) {
                for (acn, value) in row.iter_mut().enumerate() {
                    *value *= weights[acn.isqrt()];
                }
            }
        }
        let mut power = 0.0;
        for row in matrix.chunks_exact(channels) {
            for a in 0..channels {
                for b in 0..channels {
                    power += row[a] * row[b] * covariance[a][b];
                }
            }
        }
        if !power.is_finite() || power <= 1e-16 {
            return Err(Error::Invalid("HOA decoder normalization"));
        }
        for row in matrix.chunks_exact_mut(channels) {
            for (acn, value) in row.iter_mut().enumerate() {
                let n = acn.isqrt();
                let m = (acn as isize - (n * n + n) as isize).unsigned_abs();
                let scale = match normalization {
                    HoaNormalization::N3d => 1.0,
                    HoaNormalization::Sn3d => (2.0 * n as f64 + 1.0).sqrt(),
                    HoaNormalization::FuMa => (2.0 * n as f64 + 1.0).sqrt() / fuma_scale(n, m),
                };
                *value *= scale / power.sqrt();
            }
        }
        Ok(Self {
            order,
            normalization,
            output,
            matrix,
        })
    }

    pub fn order(&self) -> u8 {
        self.order
    }
    pub fn normalization(&self) -> HoaNormalization {
        self.normalization
    }
    pub fn input_channels(&self) -> u16 {
        (u16::from(self.order) + 1).pow(2)
    }
    pub fn output_layout(&self) -> BedLayout {
        self.output
    }
    /// Output-major signed coefficients, with input ACN order in each row.
    pub fn coefficients(&self) -> &[f64] {
        &self.matrix
    }
}

fn fuma_scale(n: usize, m: usize) -> f64 {
    match (n, m) {
        (0, 0) => std::f64::consts::FRAC_1_SQRT_2,
        (2, 1 | 2) => 2.0 / 3.0_f64.sqrt(),
        (3, 1) => (45.0_f64 / 32.0).sqrt(),
        (3, 2) => 3.0 / 5.0_f64.sqrt(),
        (3, 3) => (8.0_f64 / 5.0).sqrt(),
        _ => 1.0,
    }
}

// Real N3D harmonics, without Condon-Shortley phase, in ACN order. Positive
// azimuth is left; negative m uses sin(|m| azimuth), positive m uses cos.
fn harmonics(order: u8, azimuth: f64, z: f64) -> [f64; 16] {
    let mut result = [0.0; 16];
    let radius = (1.0 - z * z).max(0.0).sqrt();
    for n in 0..=usize::from(order) {
        for m in 0..=n {
            let mut p = 1.0;
            for i in 1..=m {
                p *= (2 * i - 1) as f64 * radius;
            }
            if n > m {
                let mut previous = p;
                p *= (2 * m + 1) as f64 * z;
                for degree in m + 2..=n {
                    let next = ((2 * degree - 1) as f64 * z * p
                        - (degree + m - 1) as f64 * previous)
                        / (degree - m) as f64;
                    previous = p;
                    p = next;
                }
            }
            let factorial_ratio = if m == 0 {
                1.0
            } else {
                (n - m + 1..=n + m)
                    .map(|v| v as f64)
                    .product::<f64>()
                    .recip()
            };
            let base = ((2 * n + 1) as f64 * factorial_ratio).sqrt() * p;
            let center = n * n + n;
            if m == 0 {
                result[center] = base;
            } else {
                let (sine, cosine) = (m as f64 * azimuth).sin_cos();
                result[center - m] = std::f64::consts::SQRT_2 * base * sine;
                result[center + m] = std::f64::consts::SQRT_2 * base * cosine;
            }
        }
    }
    result
}

/// Stateful ACN HOA rendering through the shared delay, interpolation and
/// limiter path. Both floating point input and normalized i16 input are accepted.
#[derive(Clone, Debug)]
pub struct HoaRenderer {
    decoder: HoaDecoder,
    renderer: GainRenderer,
}

impl HoaRenderer {
    pub const DELAY_SAMPLES: usize = GainRenderer::DELAY_SAMPLES;
    pub fn new(decoder: HoaDecoder) -> Result<Self, Error> {
        let inputs = usize::from(decoder.input_channels());
        let outputs = usize::from(decoder.output.channels());
        let gains = (0..inputs)
            .map(|input| {
                ObjectGains::new(
                    (0..outputs)
                        .map(|output| decoder.matrix[output * inputs + input] as f32)
                        .collect(),
                    vec![0.0; outputs],
                )
            })
            .collect::<Result<Vec<_>, _>>()?;
        let renderer = GainRenderer::new(None, decoder.output, &gains)?;
        Ok(Self { decoder, renderer })
    }
    /// Raw AV3A HOA uses complete ACN/SN3D coefficient sets.
    pub fn from_profile(profile: Profile, output: BedLayout) -> Result<Self, Error> {
        let Profile::Hoa { order } = profile else {
            return Err(Error::Invalid("HOA renderer profile"));
        };
        Self::new(HoaDecoder::new(
            order,
            HoaNormalization::Sn3d,
            output,
            false,
        )?)
    }
    pub fn decoder(&self) -> &HoaDecoder {
        &self.decoder
    }
    pub(super) fn disable_limiter(&mut self) {
        self.renderer.disable_limiter();
    }
    pub fn process(&mut self, input: &[i16], output: &mut [f32]) -> Result<(), Error> {
        self.renderer.process(input, output)
    }
    pub fn process_f32(&mut self, input: &[f32], output: &mut [f32]) -> Result<(), Error> {
        self.renderer.process_f32(input, output)
    }
    pub(super) fn process_prefiltered(&mut self, input: &[f32], output: &mut [f32]) {
        self.renderer.process_prefiltered(input, output);
    }
    pub fn process_silence(&mut self, frames: usize, output: &mut [f32]) -> Result<(), Error> {
        self.renderer.process_silence(frames, output)
    }
    pub fn reset(&mut self) {
        self.renderer.reset();
    }
}
