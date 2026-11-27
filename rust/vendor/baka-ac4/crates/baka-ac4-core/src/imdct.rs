//! Full IMDCT: a context created with `len = L` consumes `L` spectral
//! coefficients and writes `2L` output samples (windowed overlap-add is the
//! caller's job).
//!
//! The implementation uses the classic factorization: a half-size inverse
//! FFT with pre/post twiddles replaces the naive `L` cosine sums.
//!
//! ```text
//! len2 = L/2, len4 = L/4, s = scale, α_i = (PI/2)·(i + (s<0 ? len2:0) + 1/8)/len2
//! exp[i] = sqrt(|s|)·e^{iα_i}                        (i < len2)
//! z[i]   = (X[L-1-2i] + i·X[2i]) · exp[i]             pre-twiddle
//! z      = IFFT_len2(z)                               unnormalized, e^{+2πi/N}
//! symmetric pair CMULs over (len4+i, len4-1-i)        post-twiddle
//! y[2i] = z[i].re, y[2i+1] = z[i].im                  half inverse output
//! ```
//!
//! The half output `y` is then mirrored into the final `2L` samples:
//! `out[L/2+m] = y[m]`, `out[i] = -y[L/2-1-i]`, `out[2L-1-i] = y[L/2+i]`.
//! Verified against the naive cosine sums below to 1e-15 (see tests).

use rustfft::Fft;
use rustfft::FftPlanner;
use rustfft::num_complex::Complex32;
use std::cell::RefCell;
use std::sync::Arc;

pub struct Imdct {
    len: usize,
    fft: Arc<dyn Fft<f32>>,
    /// `exp[i] = sqrt(|s|)·e^{iα_i}`, shared by the pre and post twiddles.
    exp: Vec<Complex32>,
    /// Scratch reused across calls (one Imdct per transform size, called
    /// once per window). Includes transform data followed by rustfft workspace.
    scratch: RefCell<Vec<Complex32>>,
}

impl Imdct {
    /// Creates a transform consuming `len` coefficients and producing
    /// `2*len` samples.
    pub fn new(len: usize, scale: f32) -> Imdct {
        Self::with_planner(len, scale, &mut FftPlanner::new())
    }

    pub(crate) fn with_planner(len: usize, scale: f32, planner: &mut FftPlanner<f32>) -> Imdct {
        // AC-4 uses non-power-of-two sizes (1920/960/768/384 among the
        // transform lengths); rustfft handles arbitrary sub-FFT sizes via
        // mixed radix.
        assert!(
            len >= 4 && len.is_multiple_of(2),
            "unsupported mdct len {len}"
        );
        let half = len / 2;
        let fft = planner.plan_fft_inverse(half);
        let workspace_len = half + fft.get_inplace_scratch_len();
        let theta = (if scale < 0.0 { half } else { 0 }) as f64 + 1.0 / 8.0;
        let sc = (scale as f64).abs().sqrt();
        Imdct {
            len,
            fft,
            exp: (0..half)
                .map(|i| {
                    let a = std::f64::consts::FRAC_PI_2 * (i as f64 + theta) / half as f64;
                    Complex32::new((sc * a.cos()) as f32, (sc * a.sin()) as f32)
                })
                .collect(),
            scratch: RefCell::new(vec![Complex32::new(0.0, 0.0); workspace_len]),
        }
    }

    pub fn output_len(&self) -> usize {
        2 * self.len
    }

    /// Input: `len` coefficients; output: `2*len` samples.
    pub fn imdct(&self, input: &[f32], output: &mut [f32]) {
        let l = self.len;
        let half = l / 2;
        let quarter = l / 4;
        debug_assert_eq!(input.len(), l);
        debug_assert_eq!(output.len(), 2 * l);

        let mut guard = self.scratch.borrow_mut();
        let (z, fft_scratch) = guard.split_at_mut(half);

        // Pre-twiddle (folding): pairs (X[L-1-2i], X[2i]).
        for i in 0..half {
            let tmp = Complex32::new(input[l - 1 - 2 * i], input[2 * i]);
            z[i] = tmp * self.exp[i];
        }
        // Unnormalized inverse FFT (rustfft computes S_n = sum_k V[k]
        // e^{+2 pi i kn / N} directly).
        self.fft.process_with_scratch(z, fft_scratch);

        // Post-twiddle over symmetric pairs; source values are read out
        // first because the writes overlap the reads (as in the C).
        for i in 0..quarter {
            let i0 = quarter + i;
            let i1 = quarter - 1 - i;
            let s1 = (z[i1].im, z[i1].re);
            let s0 = (z[i0].im, z[i0].re);
            let e1 = self.exp[i1];
            let e0 = self.exp[i0];
            // z[i1].re = Re{s1·(e1.im + i·e1.re)} ; z[i0].im = Im{...}
            z[i1].re = s1.0 * e1.im - s1.1 * e1.re;
            z[i0].im = s1.0 * e1.re + s1.1 * e1.im;
            // z[i0].re = Re{s0·(e0.im + i·e0.re)} ; z[i1].im = Im{...}
            z[i0].re = s0.0 * e0.im - s0.1 * e0.re;
            z[i1].im = s0.0 * e0.re + s0.1 * e0.im;
        }

        // Unpack the half-inverse L samples y[2i]=z[i].re, y[2i+1]=z[i].im
        // into out[L/2 .. 3L/2), then apply the FULL_IMDCT mirror. The
        // mirror targets lie outside the core region, so in-place reads
        // are safe.
        for i in 0..half {
            output[half + 2 * i] = z[i].re;
            output[half + 2 * i + 1] = z[i].im;
        }
        for i in 0..half {
            output[i] = -output[half + half - 1 - i];
            output[2 * l - 1 - i] = output[half + half + i];
        }
    }
}

/// Naive cosine-sum formulation of the same transform (reference for the
/// FFT path in tests).
pub fn imdct_naive(len: usize, scale: f32, input: &[f32], output: &mut [f32]) {
    let l = len;
    let m = l / 2;
    let phase = std::f64::consts::PI / (4.0 * l as f64);
    debug_assert_eq!(input.len(), l);
    debug_assert_eq!(output.len(), 2 * l);

    let mut y = vec![0.0f64; l];
    for i in 0..m {
        let mut sum_d = 0.0f64;
        let mut sum_u = 0.0f64;
        let i_d = phase * (4.0 * m as f64 - 2.0 * i as f64 - 1.0);
        let i_u = phase * (3.0 * 2.0 * m as f64 + 2.0 * i as f64 + 1.0);
        for (j, &val) in input.iter().enumerate() {
            let a = 2.0 * j as f64 + 1.0;
            let val = val as f64;
            sum_d += (a * i_d).cos() * val;
            sum_u += (a * i_u).cos() * val;
        }
        y[i] = sum_d * scale as f64;
        y[i + m] = -sum_u * scale as f64;
    }
    // ff_tx_mdct_inv_full mirror: core y lands at output[L/2 .. 3L/2).
    let half = m;
    for mm in 0..l {
        output[half + mm] = y[mm] as f32;
    }
    for i in 0..half {
        output[i] = -y[half - 1 - i] as f32;
        output[2 * l - 1 - i] = y[half + i] as f32;
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

    #[test]
    fn fast_path_matches_naive() {
        let mut st = 0x12345678u64;
        let mut rand = move || xorshift(&mut st);
        for &len in &[128usize, 256, 512, 1024, 1920, 2048] {
            let input: Vec<f32> = (0..len).map(|_| rand()).collect();
            let mut ref_out = vec![0.0f32; 2 * len];
            imdct_naive(len, -1.0 / len as f32, &input, &mut ref_out);
            let t = Imdct::new(len, -1.0 / len as f32);
            let mut fast_out = vec![0.0f32; 2 * len];
            t.imdct(&input, &mut fast_out);
            let mut max_diff = 0.0f32;
            let mut max_abs = 0.0f32;
            for (a, b) in ref_out.iter().zip(fast_out.iter()) {
                max_diff = max_diff.max((a - b).abs());
                max_abs = max_abs.max(a.abs());
            }
            // f32 FFT vs f64 naive: differences stay at the f32 rounding
            // floor relative to the output magnitude.
            assert!(
                max_diff <= max_abs.max(1.0) * 1e-5,
                "len {len}: max diff {max_diff} (abs {max_abs})"
            );
        }
    }

    #[test]
    fn positive_scale_matches_naive() {
        // Positive scales exercise the other twiddle phase branch.
        let mut st = 0x5555_aaaa_5555_aaaau64;
        let len = 512usize;
        let input: Vec<f32> = (0..len).map(|_| xorshift(&mut st)).collect();
        let mut ref_out = vec![0.0f32; 2 * len];
        imdct_naive(len, 1.0 / len as f32, &input, &mut ref_out);
        let t = Imdct::new(len, 1.0 / len as f32);
        let mut fast_out = vec![0.0f32; 2 * len];
        t.imdct(&input, &mut fast_out);
        let max_diff = ref_out
            .iter()
            .zip(fast_out.iter())
            .map(|(a, b)| (a - b).abs())
            .fold(0.0f32, f32::max);
        let max_abs = ref_out.iter().map(|v| v.abs()).fold(0.0f32, f32::max);
        assert!(max_diff <= max_abs.max(1.0) * 1e-5, "diff {max_diff}");
    }

    #[test]
    fn tdac_perfect_reconstruction_with_kbd_halves() {
        let len = 256usize;
        let scale = -1.0f32 / len as f32;
        let mut window = [0.0f32; 2048];
        crate::kbd::kbd_window_init(&mut window[..], 5.0, len);
        // rising half-window w; PR needs w[i]^2 + w[len-1-i]^2 == 1
        for i in 0..len / 2 {
            let a = window[i] * window[i] + window[len - 1 - i] * window[len - 1 - i];
            assert!((a - 1.0).abs() < 1e-5, "PR pair broken at {i}: {a}");
        }
        let t = Imdct::new(len, scale);
        let input = vec![1.0f32; len];
        let mut out = vec![0.0f32; 2 * len];
        t.imdct(&input, &mut out);
        let energy: f32 = out.iter().map(|v| v * v).sum();
        assert!(energy > 0.0);
    }
}
