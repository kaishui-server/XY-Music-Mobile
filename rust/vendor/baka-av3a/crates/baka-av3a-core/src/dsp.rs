//! Radix-two complex transforms shared by shaping and time synthesis.
#[derive(Clone, Debug)]
pub(crate) struct FftPlan {
    twiddles: Vec<(f32, f32)>,
    bits: u32,
}
impl FftPlan {
    pub(crate) fn for_render(size: usize) -> Self {
        assert!(size.is_power_of_two());
        Self {
            twiddles: (0..size / 2)
                .map(|i| {
                    let angle = -std::f64::consts::TAU * i as f64 / size as f64;
                    (angle.cos() as f32, angle.sin() as f32)
                })
                .collect(),
            bits: size.ilog2(),
        }
    }

    pub(crate) fn new(size: usize) -> Self {
        assert!(size.is_power_of_two());
        let twiddles = (0..size / 2)
            .map(|i| {
                // Codec twiddles use the f32 value of pi and eight decimal places.
                let angle = -2.0 * f64::from(std::f32::consts::PI) * i as f64 / size as f64;
                (
                    ((angle.cos() * 1e8).round() / 1e8) as f32,
                    ((angle.sin() * 1e8).round() / 1e8) as f32,
                )
            })
            .collect();
        Self {
            twiddles,
            bits: size.ilog2(),
        }
    }
    pub(crate) fn run(&self, real: &mut [f32], imag: &mut [f32], inverse: bool) {
        if inverse {
            self.forward(imag, real);
            let scale = 1.0 / real.len() as f32;
            for v in real.iter_mut().chain(imag) {
                *v *= scale;
            }
        } else {
            self.forward(real, imag);
        }
    }
    fn forward(&self, real: &mut [f32], imag: &mut [f32]) {
        let size = 1usize << self.bits;
        assert_eq!((real.len(), imag.len()), (size, size));
        for i in 0..size {
            let j = i.reverse_bits() >> (usize::BITS - self.bits);
            if i < j {
                real.swap(i, j);
                imag.swap(i, j);
            }
        }
        let mut span = 2;
        while span <= size {
            for start in (0..size).step_by(span) {
                for offset in 0..span / 2 {
                    let (cos, sin) = self.twiddles[offset * (size / span)];
                    let (a, b) = (start + offset, start + offset + span / 2);
                    let r = real[b] * cos - imag[b] * sin;
                    let i = real[b] * sin + imag[b] * cos;
                    real[b] = real[a] - r;
                    real[a] += r;
                    imag[b] = imag[a] - i;
                    imag[a] += i;
                }
            }
            span *= 2;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fft_matches_dft_and_roundtrip() {
        let plan = FftPlan::new(64);
        let original: Vec<_> = (0..64)
            .map(|i| ((i * 37 % 53) as f32 - 26.0) / 13.0)
            .collect();
        let mut real = original.clone();
        let mut imag = vec![0.0; 64];
        plan.run(&mut real, &mut imag, false);
        for k in 0..64 {
            let (mut r, mut i) = (0.0f64, 0.0f64);
            for (n, &v) in original.iter().enumerate() {
                let angle = -std::f64::consts::TAU * k as f64 * n as f64 / 64.0;
                r += f64::from(v) * angle.cos();
                i += f64::from(v) * angle.sin();
            }
            // The wire-compatible f32-pi twiddles approximate an ideal DFT.
            assert!((f64::from(real[k]) - r).abs() < 1e-5);
            assert!((f64::from(imag[k]) - i).abs() < 1e-5);
        }
        plan.run(&mut real, &mut imag, true);
        for (&a, &b) in real.iter().zip(&original) {
            assert!((a - b).abs() < 8e-7);
        }
    }
}
