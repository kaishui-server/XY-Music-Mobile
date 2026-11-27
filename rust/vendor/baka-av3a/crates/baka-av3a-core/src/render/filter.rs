/// Deterministic, unit-magnitude random-phase diffusion filter.
///
/// Generate once per output speaker and share between renderer instances. The
/// seed identifies a speaker, rather than an object or audio block.
#[derive(Clone, Debug)]
pub struct DiffuseFilter {
    coefficients: [f32; Self::LENGTH],
}

impl DiffuseFilter {
    pub const LENGTH: usize = 512;

    pub fn new(seed: u32) -> Self {
        let mut random = Mt19937::new(seed);
        let mut spectrum = [(0.0, 0.0); Self::LENGTH];
        spectrum[0].0 = 1.0;
        spectrum[Self::LENGTH / 2].0 = 1.0;
        for bin in 1..Self::LENGTH / 2 {
            let phase = f64::from(random.next()) * (1.0 / 4294967296.0) * std::f64::consts::TAU;
            let (imag, real) = phase.sin_cos();
            spectrum[bin] = (real, imag);
            spectrum[Self::LENGTH - bin] = (real, -imag);
        }
        inverse(&mut spectrum);
        Self {
            coefficients: spectrum.map(|(real, _)| (real / Self::LENGTH as f64) as f32),
        }
    }

    pub fn coefficients(&self) -> &[f32; Self::LENGTH] {
        &self.coefficients
    }
}

fn inverse(values: &mut [(f64, f64); DiffuseFilter::LENGTH]) {
    let length = values.len();
    for index in 0..length {
        let reverse = index.reverse_bits() >> (usize::BITS - length.ilog2());
        if index < reverse {
            values.swap(index, reverse);
        }
    }
    let mut span = 2;
    while span <= length {
        for offset in 0..span / 2 {
            let (sin, cos) = (std::f64::consts::TAU * offset as f64 / span as f64).sin_cos();
            for start in (0..length).step_by(span) {
                let a = start + offset;
                let b = a + span / 2;
                let (real, imag) = values[b];
                let real = real * cos - imag * sin;
                let imag = values[b].0 * sin + imag * cos;
                values[b] = (values[a].0 - real, values[a].1 - imag);
                values[a] = (values[a].0 + real, values[a].1 + imag);
            }
        }
        span *= 2;
    }
}

struct Mt19937 {
    state: [u32; 624],
    index: usize,
}

impl Mt19937 {
    fn new(seed: u32) -> Self {
        let mut state = [0; 624];
        state[0] = seed;
        for i in 1..state.len() {
            let previous = state[i - 1];
            state[i] = (previous ^ (previous >> 30))
                .wrapping_mul(1_812_433_253)
                .wrapping_add(i as u32);
        }
        Self { state, index: 0 }
    }

    fn next(&mut self) -> u32 {
        let i = self.index;
        let next = (i + 1) % self.state.len();
        let joined = (self.state[i] & 0x8000_0000) | (self.state[next] & 0x7fff_ffff);
        let low = if joined & 1 == 0 { 0 } else { 0x9908_b0df };
        self.state[i] = self.state[(i + 397) % self.state.len()] ^ (joined >> 1) ^ low;
        self.index = next;
        let mut value = self.state[i];
        value ^= value >> 11;
        value ^= (value << 7) & 0x9d2c_5680;
        value ^= (value << 15) & 0xefc6_0000;
        value ^ (value >> 18)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn random_sequence() {
        let mut random = Mt19937::new(5489);
        for expected in [3499211612, 581869302, 3890346734, 3586334585, 545404204] {
            assert_eq!(random.next(), expected);
        }
    }

    #[test]
    fn filter_has_unit_spectral_magnitude() {
        let filter = DiffuseFilter::new(42);
        for bin in 0..=DiffuseFilter::LENGTH / 2 {
            let mut real = 0.0;
            let mut imag = 0.0;
            for (i, &coefficient) in filter.coefficients().iter().enumerate() {
                let (sin, cos) = (std::f64::consts::TAU * (bin * i) as f64 / 512.0).sin_cos();
                real += f64::from(coefficient) * cos;
                imag += f64::from(coefficient) * sin;
            }
            assert!((real.hypot(imag) - 1.0).abs() < 1e-6);
        }
    }
}
