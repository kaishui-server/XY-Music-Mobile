//! IMDCT, sine windows and stream-local overlap history.
use crate::{Error, dsp::FftPlan};
use std::sync::Arc;

#[derive(Clone, Debug)]
pub(crate) struct ImdctPlan {
    fft: FftPlan,
    phases: Vec<(f32, f32)>,
    scale: f64,
}
impl ImdctPlan {
    pub(crate) fn new(lines: usize) -> Self {
        let frequency = 2.0 * std::f32::consts::PI / (2 * lines) as f32;
        let step = (
            f64::from(frequency).cos() as f32,
            f64::from(frequency).sin() as f32,
        );
        let angle = f64::from(frequency * 0.125);
        let (mut cos, mut sin) = (angle.cos() as f32, angle.sin() as f32);
        let mut phases = Vec::with_capacity(lines / 2);
        for _ in 0..lines / 2 {
            phases.push((cos, sin));
            let next = cos * step.0 - sin * step.1;
            sin = sin * step.0 + cos * step.1;
            cos = next;
        }
        Self {
            fft: FftPlan::new(lines / 2),
            phases,
            scale: ((2 * lines) as f64).sqrt(),
        }
    }
    pub(crate) fn run(&self, spectrum: &[f32]) -> Vec<f32> {
        let lines = self.phases.len() * 2;
        assert_eq!(spectrum.len(), lines);
        let (mut real, mut imag) = (vec![0.0; lines / 2], vec![0.0; lines / 2]);
        let mut signal = vec![0.0; lines * 2];
        self.run_into(spectrum, &mut real, &mut imag, &mut signal);
        signal
    }

    fn run_into(&self, spectrum: &[f32], real: &mut [f32], imag: &mut [f32], signal: &mut [f32]) {
        let lines = self.phases.len() * 2;
        assert_eq!(spectrum.len(), lines);
        assert_eq!(
            (real.len(), imag.len(), signal.len()),
            (lines / 2, lines / 2, lines * 2)
        );
        for (i, &(cos, sin)) in self.phases.iter().enumerate() {
            let (a, b) = (-spectrum[i * 2], spectrum[lines - 1 - i * 2]);
            real[i] = a * cos - b * sin;
            imag[i] = b * cos + a * sin;
        }
        self.fft.run(real, imag, true);
        // The mirrored writes below cover all 2 * lines samples, including
        // when the caller reuses a previous short block's output buffer.
        for (i, &(cos, sin)) in self.phases.iter().enumerate() {
            let r = (0.5 * (real[i] * cos - imag[i] * sin)) as f64 * self.scale;
            let j = (0.5 * (imag[i] * cos + real[i] * sin)) as f64 * self.scale;
            signal[lines + lines / 2 - 1 - i * 2] = r as f32;
            if i < lines / 4 {
                signal[lines + lines / 2 + i * 2] = r as f32;
                signal[lines / 2 - 1 - i * 2] = -j as f32;
            } else {
                signal[i * 2 - lines / 2] = -r as f32;
                signal[lines / 2 + lines * 2 - 1 - i * 2] = j as f32;
            }
            signal[lines / 2 + i * 2] = j as f32;
        }
    }

    pub(crate) fn forward(&self, signal: &[f32]) -> Vec<f32> {
        let lines = self.phases.len() * 2;
        assert_eq!(signal.len(), lines * 2);
        let (mut real, mut imag) = (vec![0.0; lines / 2], vec![0.0; lines / 2]);
        for (i, &(cos, sin)) in self.phases.iter().enumerate() {
            let reverse = lines - 1 - i * 2;
            let a = if i < lines / 4 {
                signal[lines / 2 + reverse] + signal[lines * 2 + lines / 2 - 1 - reverse]
            } else {
                signal[lines / 2 + reverse] - signal[lines / 2 - 1 - reverse]
            };
            let b = if i < lines / 4 {
                signal[lines / 2 + i * 2] - signal[lines / 2 - 1 - i * 2]
            } else {
                signal[lines / 2 + i * 2] + signal[lines * 2 + lines / 2 - 1 - i * 2]
            };
            real[i] = a * cos + b * sin;
            imag[i] = b * cos - a * sin;
        }
        self.fft.run(&mut real, &mut imag, false);
        let mut spectrum = vec![0.0; lines];
        for (i, &(cos, sin)) in self.phases.iter().enumerate() {
            let a = 2.0 * (real[i] * cos + imag[i] * sin);
            let b = 2.0 * (imag[i] * cos - real[i] * sin);
            spectrum[i * 2] = (-f64::from(a) / self.scale) as f32;
            spectrum[lines - 1 - i * 2] = (f64::from(b) / self.scale) as f32;
        }
        spectrum
    }
}

#[derive(Clone, Debug)]
pub struct Synthesis {
    long: Arc<ImdctPlan>,
    short: Arc<ImdctPlan>,
    long_window: Arc<[f32]>,
    short_window: Arc<[f32]>,
    overlap: [f32; 1024],
}
impl Default for Synthesis {
    fn default() -> Self {
        Self::new()
    }
}
impl Synthesis {
    pub fn new() -> Self {
        let window = |size| -> Arc<[f32]> {
            (0..size)
                .map(|i| {
                    f64::from((std::f32::consts::PI / (2 * size) as f32) * (i as f32 + 0.5)).sin()
                        as f32
                })
                .collect()
        };
        Self {
            long: Arc::new(ImdctPlan::new(1024)),
            short: Arc::new(ImdctPlan::new(128)),
            long_window: window(1024),
            short_window: window(128),
            overlap: [0.0; 1024],
        }
    }
    pub fn reset(&mut self) {
        self.overlap.fill(0.0);
    }
    /// Input is block-major for short windows. Commit overlap only on success.
    pub fn process(&mut self, spectrum: &[f32; 1024], transform: u8) -> Result<[f32; 1024], Error> {
        if transform > 3 || spectrum.iter().any(|v| !v.is_finite()) {
            return Err(Error::Invalid("synthesis input"));
        }
        let (mut output, mut next) = ([0.0; 1024], [0.0; 1024]);
        if transform == 1 {
            let mut history = [0.0; 128];
            history.copy_from_slice(&self.overlap[448..576]);
            let mut current = [0.0; 1024];
            // Eight short transforms share 1.5 KiB of bounded local workspace.
            // Keep this out of stream state so checkpoint clones stay unchanged.
            let (mut real, mut imag, mut time) = ([0.0; 64], [0.0; 64], [0.0; 256]);
            for (block, chunk) in spectrum.as_chunks::<128>().0.iter().enumerate() {
                self.short.run_into(chunk, &mut real, &mut imag, &mut time);
                for i in 0..128 {
                    current[block * 128 + i] = time[i] * self.short_window[i] + history[i];
                    history[i] = time[128 + i] * self.short_window[127 - i];
                }
            }
            output[..448].copy_from_slice(&self.overlap[..448]);
            output[448..].copy_from_slice(&current[..576]);
            next[..448].copy_from_slice(&current[576..]);
            next[448..576].copy_from_slice(&history);
        } else {
            let mut time = self.long.run(spectrum);
            for i in 0..1024 {
                let left = if transform == 3 {
                    if i < 448 {
                        0.0
                    } else if i < 576 {
                        self.short_window[i - 448]
                    } else {
                        1.0
                    }
                } else {
                    self.long_window[i]
                };
                let right = if transform == 2 {
                    if i < 448 {
                        1.0
                    } else if i < 576 {
                        self.short_window[575 - i]
                    } else {
                        0.0
                    }
                } else {
                    self.long_window[1023 - i]
                };
                time[i] *= left;
                time[1024 + i] *= right;
                output[i] = time[i] + self.overlap[i];
                next[i] = time[1024 + i];
            }
        }
        if output.iter().chain(&next).any(|v| !v.is_finite()) {
            return Err(Error::Invalid("synthesis output"));
        }
        self.overlap = next;
        Ok(output)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn forward_mdct_matches_direct_definition() {
        let plan = ImdctPlan::new(128);
        let input: Vec<_> = (0..256)
            .map(|i| ((i * 13 % 37) as f32 - 18.0) / 32.0)
            .collect();
        for (k, value) in plan.forward(&input).iter().enumerate() {
            let expected = input
                .iter()
                .enumerate()
                .map(|(n, &v)| {
                    f64::from(v)
                        * (std::f64::consts::PI / 128.0
                            * (n as f64 + 0.5 + 64.0)
                            * (k as f64 + 0.5))
                            .cos()
                })
                .sum::<f64>()
                * (2.0f64 / 128.0).sqrt();
            assert!((f64::from(*value) - expected).abs() < 1e-5);
        }
    }
    #[test]
    fn imdct_matches_direct_definition() {
        let plan = ImdctPlan::new(128);
        let mut spectrum = [0.0; 128];
        spectrum[0] = 1.0;
        spectrum[19] = -0.3;
        let output = plan.run(&spectrum);
        for (n, &actual) in output.iter().enumerate() {
            let mut expected = 0.0f64;
            for (k, &v) in spectrum.iter().enumerate() {
                expected += f64::from(v)
                    * (std::f64::consts::PI / 128.0 * (n as f64 + 0.5 + 64.0) * (k as f64 + 0.5))
                        .cos();
            }
            expected *= (2.0f64 / 128.0).sqrt();
            assert!((f64::from(actual) - expected).abs() < 2e-6);
        }
    }
    #[test]
    fn reset_and_invalid_input_preserve_history() {
        let mut synthesis = Synthesis::new();
        let mut spectrum = [0.0; 1024];
        spectrum[17] = 1.0;
        let expected = synthesis.process(&spectrum, 0).unwrap();
        let saved = synthesis.clone();
        spectrum[17] = f32::NAN;
        assert!(synthesis.process(&spectrum, 0).is_err());
        assert_eq!(synthesis.overlap, saved.overlap);
        spectrum[17] = 1.0;
        synthesis.reset();
        assert_eq!(synthesis.process(&spectrum, 0).unwrap(), expected);
    }
}
