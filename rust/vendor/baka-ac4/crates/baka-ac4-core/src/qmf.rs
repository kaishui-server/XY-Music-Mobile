//! FFT-based 64-band QMF analysis/synthesis.
//!
//! Analysis (per timeslot): with `v[n] = u[n]·e^{iπn/128}` and an
//! (unnormalized, e^{+2πikn/N}) 128-point inverse FFT,
//!
//! ```text
//! C[sb] = e^{-iπ(sb+0.5)/128} · V[sb],  sb < 64
//! Q0[sb] = Re C[sb],  Q1[sb] = Im C[sb]     (equals sum u·cos/sin over n)
//! ```
//!
//! Synthesis (per timeslot): with `D[k] = Q0[k] + i·Q1[k]`,
//!
//! ```text
//! E[k] = D[k] · e^{-2πi(k+0.5)·127.5/128}   (k < 64, zero padded to 128)
//! U = IFFT_128(E);  qsyn[n] = Re(e^{iπn/128} · U[n]) / 64
//! ```
//!
//! Both identities match the direct cosine/sine sums to machine precision
//! (verified against the naive dot products in the unit tests); O(n log n)
//! replaces the 64×128 / 128×64 matrix-vector products.

use rustfft::Fft;
use rustfft::FftPlanner;
use rustfft::num_complex::Complex32;
use std::cell::RefCell;
use std::sync::Arc;

const BANDS: usize = 64;
const FFT_LEN: usize = 2 * BANDS;

fn exp_i(a: f64) -> Complex32 {
    Complex32::new(a.cos() as f32, a.sin() as f32)
}

pub struct QmfAnalysis {
    fft: Arc<dyn Fft<f32>>,
    mod_tw: Vec<Complex32>,
    out_tw: Vec<Complex32>,
    /// Transform data followed by rustfft workspace; allocated once per context.
    scratch: RefCell<Vec<Complex32>>,
}

impl Default for QmfAnalysis {
    fn default() -> Self {
        Self::new()
    }
}

impl QmfAnalysis {
    pub fn new() -> Self {
        let mut planner = FftPlanner::<f32>::new();
        let fft = planner.plan_fft_inverse(FFT_LEN);
        let workspace_len = FFT_LEN + fft.get_inplace_scratch_len();
        let f = std::f64::consts::PI / FFT_LEN as f64;
        QmfAnalysis {
            fft,
            mod_tw: (0..FFT_LEN).map(|n| exp_i(f * n as f64)).collect(),
            out_tw: (0..BANDS).map(|sb| exp_i(-f * (sb as f64 + 0.5))).collect(),
            scratch: RefCell::new(vec![Complex32::new(0.0, 0.0); workspace_len]),
        }
    }

    /// `u[128]` -> subband samples `q0/q1[64]` for one timeslot.
    pub fn bands(&self, u: &[f32], q0: &mut [f32], q1: &mut [f32]) {
        let mut guard = self.scratch.borrow_mut();
        let (buf, fft_scratch) = guard.split_at_mut(FFT_LEN);
        for n in 0..FFT_LEN {
            buf[n] = self.mod_tw[n].scale(u[n]);
        }
        self.fft.process_with_scratch(buf, fft_scratch);
        for sb in 0..BANDS {
            let v = self.out_tw[sb] * buf[sb];
            q0[sb] = v.re;
            q1[sb] = v.im;
        }
    }
}

pub struct QmfSynthesis {
    fft: Arc<dyn Fft<f32>>,
    pre_tw: Vec<Complex32>,
    post_tw: Vec<Complex32>,
    /// Transform data followed by rustfft workspace; allocated once per context.
    scratch: RefCell<Vec<Complex32>>,
}

impl Default for QmfSynthesis {
    fn default() -> Self {
        Self::new()
    }
}

impl QmfSynthesis {
    /// Synthesize one 64-sample PCM slot with caller-owned stream history.
    /// The history is initialized to zero and kept independently per signal.
    pub fn synthesize_slot(
        &self,
        history: &mut [f32; 1280],
        real: &[f32; 64],
        imaginary: &[f32; 64],
        output: &mut [f32; 64],
    ) {
        history.copy_within(0..1152, 128);
        self.filterbank(real, imaginary, &mut history[..128]);
        output.fill(0.0);
        for n in 0..10 {
            let src = 128 * n + 64 * (n & 1);
            let samples = &history[src..src + 64];
            let window = &crate::tables::QWIN[n * 64..n * 64 + 64];
            for j in 0..64 {
                output[j] += samples[j] * window[j];
            }
        }
    }

    pub fn new() -> Self {
        let mut planner = FftPlanner::<f32>::new();
        let fft = planner.plan_fft_inverse(FFT_LEN);
        let workspace_len = FFT_LEN + fft.get_inplace_scratch_len();
        let f = 2.0 * std::f64::consts::PI / FFT_LEN as f64;
        let shift = (2.0 * FFT_LEN as f64 - 1.0) / 2.0; // 127.5: from (2n - 255)
        QmfSynthesis {
            fft,
            pre_tw: (0..BANDS)
                .map(|k| exp_i(-f * (k as f64 + 0.5) * shift))
                .collect(),
            post_tw: (0..FFT_LEN)
                .map(|n| exp_i(std::f64::consts::PI * n as f64 / FFT_LEN as f64))
                .collect(),
            scratch: RefCell::new(vec![Complex32::new(0.0, 0.0); workspace_len]),
        }
    }

    /// Subband samples `q0/q1[64]` -> 128 filterbank samples for one
    /// timeslot.
    pub fn filterbank(&self, q0: &[f32], q1: &[f32], qsyn: &mut [f32]) {
        let mut guard = self.scratch.borrow_mut();
        let (buf, fft_scratch) = guard.split_at_mut(FFT_LEN);
        for k in 0..BANDS {
            buf[k] = self.pre_tw[k] * Complex32::new(q0[k], q1[k]);
        }
        for b in buf.iter_mut().skip(BANDS) {
            *b = Complex32::new(0.0, 0.0);
        }
        self.fft.process_with_scratch(buf, fft_scratch);
        for n in 0..FFT_LEN {
            let v = self.post_tw[n] * buf[n];
            qsyn[n] = v.re / BANDS as f32;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn xorshift(state: &mut u64) -> f32 {
        *state ^= *state << 13;
        *state ^= *state >> 7;
        *state ^= *state << 17;
        ((*state >> 40) as f32 / 8388608.0) - 1.0
    }

    /// Naive analysis dot products (reference for the FFT path).
    #[test]
    fn analysis_matches_naive() {
        let mut st = 0x1234_5678_9abc_def0u64;
        let ana = QmfAnalysis::new();
        for _ in 0..4 {
            let u: Vec<f32> = (0..FFT_LEN).map(|_| xorshift(&mut st)).collect();
            let mut q0 = [0.0f32; BANDS];
            let mut q1 = [0.0f32; BANDS];
            ana.bands(&u, &mut q0, &mut q1);
            let f = std::f64::consts::PI / FFT_LEN as f64;
            for sb in 0..BANDS {
                let mut d0 = 0.0f64;
                let mut d1 = 0.0f64;
                for (n, &un) in u.iter().enumerate() {
                    let a = f * (sb as f64 + 0.5) * ((2 * n) as f64 - 1.0);
                    d0 += un as f64 * a.cos();
                    d1 += un as f64 * a.sin();
                }
                assert!(
                    (q0[sb] as f64 - d0).abs() < 1e-4 * (1.0 + d0.abs()),
                    "q0[{sb}]: {} vs {d0}",
                    q0[sb]
                );
                assert!(
                    (q1[sb] as f64 - d1).abs() < 1e-4 * (1.0 + d1.abs()),
                    "q1[{sb}]: {} vs {d1}",
                    q1[sb]
                );
            }
        }
    }

    /// Naive synthesis dot products (reference for the FFT path).
    #[test]
    fn synthesis_matches_naive() {
        let mut st = 0x0fed_cba9_8765_4321u64;
        let syn = QmfSynthesis::new();
        for _ in 0..4 {
            let q0: Vec<f32> = (0..BANDS).map(|_| xorshift(&mut st)).collect();
            let q1: Vec<f32> = (0..BANDS).map(|_| xorshift(&mut st)).collect();
            let mut out = [0.0f32; FFT_LEN];
            syn.filterbank(&q0, &q1, &mut out);
            let f = std::f64::consts::PI / FFT_LEN as f64;
            for (n, &on) in out.iter().enumerate() {
                let mut d = 0.0f64;
                for k in 0..BANDS {
                    let a = f * (k as f64 + 0.5) * ((2 * n) as f64 - 255.0);
                    d += (q0[k] as f64 * a.cos() - q1[k] as f64 * a.sin()) / BANDS as f64;
                }
                assert!(
                    (on as f64 - d).abs() < 1e-4 * (1.0 + d.abs()),
                    "out[{n}]: {} vs {d}",
                    on
                );
            }
        }
    }
}
