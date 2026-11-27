use super::DiffuseFilter;
use crate::dsp::FftPlan;
use std::sync::Arc;

pub(super) const BLOCK: usize = 1024;
const FFT: usize = BLOCK * 2;

#[derive(Debug)]
pub(super) struct Kernel {
    plan: FftPlan,
    real: Vec<f32>,
    imag: Vec<f32>,
}

impl Kernel {
    pub(super) fn new(seed: u32) -> Arc<Self> {
        Self::from_taps(DiffuseFilter::new(seed).coefficients())
    }

    pub(super) fn from_taps(taps: &[f32]) -> Arc<Self> {
        assert!(!taps.is_empty() && taps.len() <= BLOCK);
        let plan = FftPlan::for_render(FFT);
        let mut real = vec![0.0; FFT];
        let mut imag = vec![0.0; FFT];
        real[..taps.len()].copy_from_slice(taps);
        plan.run(&mut real, &mut imag, false);
        Arc::new(Self { plan, real, imag })
    }
}

#[derive(Clone, Debug)]
pub(super) struct Convolver {
    kernel: Arc<Kernel>,
    real: Vec<f32>,
    imag: Vec<f32>,
    overlap: Vec<f32>,
}

impl Convolver {
    pub(super) fn new(kernel: Arc<Kernel>) -> Self {
        Self {
            kernel,
            real: vec![0.0; FFT],
            imag: vec![0.0; FFT],
            overlap: vec![0.0; BLOCK],
        }
    }

    pub(super) fn reset(&mut self) {
        self.real.fill(0.0);
        self.imag.fill(0.0);
        self.overlap.fill(0.0);
    }

    pub(super) fn process(&mut self, input: &[f32], output: &mut [f32]) {
        debug_assert_eq!(input.len(), BLOCK);
        debug_assert_eq!(output.len(), BLOCK);
        if input.iter().all(|&v| v == 0.0) {
            output.copy_from_slice(&self.overlap);
            self.overlap.fill(0.0);
            return;
        }
        self.real[..BLOCK].copy_from_slice(input);
        self.real[BLOCK..].fill(0.0);
        self.imag.fill(0.0);
        self.kernel.plan.run(&mut self.real, &mut self.imag, false);
        for i in 0..FFT {
            let real = self.real[i] * self.kernel.real[i] - self.imag[i] * self.kernel.imag[i];
            let imag = self.real[i] * self.kernel.imag[i] + self.imag[i] * self.kernel.real[i];
            self.real[i] = real;
            self.imag[i] = imag;
        }
        self.kernel.plan.run(&mut self.real, &mut self.imag, true);
        for i in 0..BLOCK {
            output[i] = self.real[i] + self.overlap[i];
        }
        self.overlap.copy_from_slice(&self.real[BLOCK..]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn block_convolution_matches_scalar_and_flushes_tail() {
        let filter = DiffuseFilter::new(3);
        let mut convolver = Convolver::new(Kernel::new(3));
        let mut input = vec![0.0; BLOCK * 3];
        for (i, v) in input[..BLOCK + 271].iter_mut().enumerate() {
            *v = ((i * 97 % 101) as f32 - 50.0) / 100.0;
        }
        let mut output = vec![0.0; input.len()];
        for (input, output) in input.chunks(BLOCK).zip(output.chunks_mut(BLOCK)) {
            convolver.process(input, output);
        }
        for i in 0..input.len() {
            let expected: f64 = filter
                .coefficients()
                .iter()
                .take(i + 1)
                .enumerate()
                .map(|(tap, &v)| f64::from(v) * f64::from(input[i - tap]))
                .sum();
            assert!((f64::from(output[i]) - expected).abs() < 5e-7, "{i}");
        }
        let mut tail = vec![1.0; BLOCK];
        convolver.process(&[0.0; BLOCK], &mut tail);
        assert!(tail.iter().all(|v| v.abs() < 1e-7));
        convolver.reset();
        convolver.process(&[0.0; BLOCK], &mut tail);
        assert!(tail.iter().all(|v| *v == 0.0));
    }
}
