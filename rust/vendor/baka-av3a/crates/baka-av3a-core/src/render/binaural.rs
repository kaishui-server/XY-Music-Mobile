use super::{
    HrirBank, HrirWeights, LookAheadLimiter,
    hrir::{BLOCK, FFT},
};
use crate::Error;
pub(super) const MAX_BUS_SOURCES: usize = 16 * 9;

/// A point source at the HRIR bank's fixed measurement radius. Gain is linear
/// amplitude `[0,16]`. Positions are listener-relative; positive azimuth is left.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BinauralSource {
    pub azimuth: f64,
    pub elevation: f64,
    pub gain: f32,
}
impl Default for BinauralSource {
    fn default() -> Self {
        Self {
            azimuth: 0.0,
            elevation: 0.0,
            gain: 1.0,
        }
    }
}

#[derive(Clone, Debug)]
struct Source {
    old: HrirWeights,
    target: HrirWeights,
    gain: f32,
    jump: bool,
    cached: Option<HrirWeights>,
    kernel_real: [Vec<f32>; 2],
    kernel_imag: [Vec<f32>; 2],
}

pub(super) struct BinauralUpdate {
    targets: [BinauralSource; MAX_BUS_SOURCES],
    weights: [Option<HrirWeights>; MAX_BUS_SOURCES],
    jumps: [bool; MAX_BUS_SOURCES],
    count: usize,
}

/// HRIR convolution for 1..16 interleaved point sources, producing stereo.
/// Updates interpolate the source contributions over1024 input samples, keeping
/// old impulse-response tails intact. Ear filters share input FFTs. Construct
/// outside callbacks; processing, updates and reset do not allocate.
#[derive(Clone, Debug)]
pub struct BinauralRenderer {
    bank: HrirBank,
    targets: Vec<BinauralSource>,
    sources: Vec<Source>,
    real: Vec<f32>,
    imag: Vec<f32>,
    old_real: Vec<f32>,
    old_imag: Vec<f32>,
    kernel_real: Vec<f32>,
    kernel_imag: Vec<f32>,
    mix_real: [Vec<f32>; 2],
    mix_imag: [Vec<f32>; 2],
    overlap: [[f32; BLOCK]; 2],
    limiter: LookAheadLimiter,
    limiting: bool,
}

impl BinauralRenderer {
    pub const BLOCK_FRAMES: usize = BLOCK;
    /// Fixed DSP alignment only; measured ear delays remain in the HRIR taps.
    pub const DELAY_SAMPLES: usize = LookAheadLimiter::DELAY_SAMPLES;
    pub fn new(
        bank: HrirBank,
        sample_rate: u32,
        sources: &[BinauralSource],
    ) -> Result<Self, Error> {
        if sources.is_empty() || sources.len() > 16 {
            return Err(Error::Invalid("binaural source count"));
        }
        Self::new_bus(bank, sample_rate, sources)
    }
    // Internal room construction only:16 physical sources times9 paths.
    // The public point-source constructor retains its16-channel contract.
    pub(super) fn new_bus(
        bank: HrirBank,
        sample_rate: u32,
        sources: &[BinauralSource],
    ) -> Result<Self, Error> {
        if sample_rate != bank.sample_rate() {
            return Err(Error::Invalid("HRIR sample rate mismatch"));
        }
        if sources.is_empty() || sources.len() > MAX_BUS_SOURCES {
            return Err(Error::Invalid("binaural source count"));
        }
        let prepared = sources
            .iter()
            .map(|&s| prepare(&bank, s))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Self {
            bank,
            targets: sources.to_vec(),
            sources: prepared
                .into_iter()
                .map(|weights| Source {
                    old: weights,
                    target: weights,
                    gain: 0.0,
                    jump: false,
                    cached: None,
                    kernel_real: std::array::from_fn(|_| vec![0.; FFT]),
                    kernel_imag: std::array::from_fn(|_| vec![0.; FFT]),
                })
                .collect(),
            real: vec![0.0; FFT],
            imag: vec![0.0; FFT],
            old_real: vec![0.0; FFT],
            old_imag: vec![0.0; FFT],
            kernel_real: vec![0.0; FFT],
            kernel_imag: vec![0.0; FFT],
            mix_real: std::array::from_fn(|_| vec![0.; FFT]),
            mix_imag: std::array::from_fn(|_| vec![0.; FFT]),
            overlap: [[0.; BLOCK]; 2],
            limiter: LookAheadLimiter::new(2)?,
            limiting: true,
        })
    }
    pub fn bank(&self) -> &HrirBank {
        &self.bank
    }
    pub(super) fn disable_limiter(&mut self) {
        self.limiting = false;
    }
    pub fn input_channels(&self) -> usize {
        self.sources.len()
    }
    pub fn sources(&self) -> &[BinauralSource] {
        &self.targets
    }
    pub fn tail_samples(&self) -> usize {
        self.bank.tap_count() - 1 + Self::DELAY_SAMPLES
    }

    /// Queue targets for the next full input block. A true jump flag selects
    /// the new filter from its first source sample, without erasing old tails.
    /// Invalid updates leave all pending targets/flags and audio state intact.
    pub fn set_sources(&mut self, targets: &[BinauralSource], jumps: &[bool]) -> Result<(), Error> {
        let update = self.prepare_update(targets, jumps)?;
        self.commit_update(update);
        Ok(())
    }
    pub(super) fn commit_update(&mut self, update: BinauralUpdate) {
        debug_assert_eq!(self.sources.len(), update.count);
        self.targets
            .copy_from_slice(&update.targets[..update.count]);
        for ((source, weights), jump) in self
            .sources
            .iter_mut()
            .zip(update.weights)
            .zip(update.jumps)
        {
            source.target = weights.unwrap();
            source.jump = jump;
        }
    }
    pub(super) fn prepare_update(
        &self,
        targets: &[BinauralSource],
        jumps: &[bool],
    ) -> Result<BinauralUpdate, Error> {
        if targets.len() != self.sources.len() || jumps.len() != targets.len() {
            return Err(Error::Invalid("binaural update count"));
        }
        let mut weights = [None; MAX_BUS_SOURCES];
        for (slot, &target) in weights.iter_mut().zip(targets) {
            *slot = Some(prepare(&self.bank, target)?);
        }
        let mut update = BinauralUpdate {
            targets: [BinauralSource::default(); MAX_BUS_SOURCES],
            weights,
            jumps: [false; MAX_BUS_SOURCES],
            count: targets.len(),
        };
        update.targets[..targets.len()].copy_from_slice(targets);
        update.jumps[..targets.len()].copy_from_slice(jumps);
        Ok(update)
    }
    pub fn process(&mut self, input: &[f32], output: &mut [f32]) -> Result<(), Error> {
        self.validate_output(output)?;
        if input.len() != BLOCK * self.sources.len() {
            return Err(Error::Invalid("binaural input block length"));
        }
        if input.iter().any(|v| !v.is_finite() || v.abs() > 256.0) {
            return Err(Error::Invalid("binaural input PCM"));
        }
        self.process_inner(Some(input), output);
        Ok(())
    }
    pub fn process_silence(&mut self, output: &mut [f32]) -> Result<(), Error> {
        self.validate_output(output)?;
        self.process_inner(None, output);
        Ok(())
    }
    // Only validated, bounded internal render buses may exceed the public
    // source PCM limit. Fixed dimensions are checked before advancing that bus.
    pub(super) fn process_prefiltered(&mut self, input: &[f32], output: &mut [f32]) {
        debug_assert_eq!(input.len(), BLOCK * self.sources.len());
        debug_assert_eq!(output.len(), BLOCK * 2);
        debug_assert!(input.iter().all(|v| v.is_finite()));
        self.process_inner(Some(input), output);
    }
    fn validate_output(&self, output: &[f32]) -> Result<(), Error> {
        if output.len() != BLOCK * 2 {
            return Err(Error::Invalid("binaural output block length"));
        }
        Ok(())
    }
    fn process_inner(&mut self, input: Option<&[f32]>, output: &mut [f32]) {
        for ear in 0..2 {
            self.mix_real[ear].fill(0.);
            self.mix_imag[ear].fill(0.);
        }
        let mut any_active = false;
        let channels = self.sources.len();
        for (channel, (source, target)) in self.sources.iter_mut().zip(&self.targets).enumerate() {
            self.real.fill(0.0);
            self.imag.fill(0.0);
            self.old_real.fill(0.0);
            self.old_imag.fill(0.0);
            let changing = !source.jump && source.old != source.target && source.gain != 0.0;
            for i in 0..BLOCK {
                let sample = input.map_or(0.0, |v| v[i * channels + channel]);
                let t = i as f32 / BLOCK as f32;
                if source.jump {
                    self.real[i] = sample * target.gain;
                } else if changing {
                    self.real[i] = sample * target.gain * t;
                    // Pack the old real signal into the imaginary component.
                    // One complex FFT recovers both real signal spectra.
                    self.imag[i] = sample * source.gain * (1.0 - t);
                } else {
                    self.real[i] = sample * (target.gain * t + source.gain * (1.0 - t));
                }
            }
            let active = self.real[..BLOCK].iter().any(|&v| v != 0.0)
                || (changing && self.imag[..BLOCK].iter().any(|&v| v != 0.0));
            if active {
                any_active = true;
                self.bank.fft().run(&mut self.real, &mut self.imag, false);
                if changing {
                    for bin in 0..=FFT / 2 {
                        let mirror = (FFT - bin) % FFT;
                        let (r, i, mr, mi) = (
                            self.real[bin],
                            self.imag[bin],
                            self.real[mirror],
                            self.imag[mirror],
                        );
                        let (new_real, new_imag) = ((r + mr) * 0.5, (i - mi) * 0.5);
                        let (old_real, old_imag) = ((i + mi) * 0.5, (mr - r) * 0.5);
                        self.real[bin] = new_real;
                        self.real[mirror] = new_real;
                        self.imag[bin] = new_imag;
                        self.imag[mirror] = -new_imag;
                        self.old_real[bin] = old_real;
                        self.old_real[mirror] = old_real;
                        self.old_imag[bin] = old_imag;
                        self.old_imag[mirror] = -old_imag;
                    }
                }
            }
            for ear in 0..2 {
                if active {
                    // Keep the prior target spectrum. Motion only needs to
                    // blend the new direction; static blocks reuse both ears.
                    if changing && source.cached != Some(source.old) {
                        self.bank.blend(
                            source.old,
                            ear,
                            &mut source.kernel_real[ear],
                            &mut source.kernel_imag[ear],
                        );
                    }
                    let cached_target = !changing && source.cached == Some(source.target);
                    if !cached_target {
                        self.bank.blend(
                            source.target,
                            ear,
                            &mut self.kernel_real,
                            &mut self.kernel_imag,
                        );
                    }
                    let (kernel_real, kernel_imag) = if cached_target {
                        (&source.kernel_real[ear], &source.kernel_imag[ear])
                    } else {
                        (&self.kernel_real, &self.kernel_imag)
                    };
                    for bin in 0..FFT {
                        self.mix_real[ear][bin] +=
                            self.real[bin] * kernel_real[bin] - self.imag[bin] * kernel_imag[bin];
                        self.mix_imag[ear][bin] +=
                            self.real[bin] * kernel_imag[bin] + self.imag[bin] * kernel_real[bin];
                    }
                    if changing {
                        for bin in 0..FFT {
                            self.mix_real[ear][bin] += self.old_real[bin]
                                * source.kernel_real[ear][bin]
                                - self.old_imag[bin] * source.kernel_imag[ear][bin];
                            self.mix_imag[ear][bin] += self.old_real[bin]
                                * source.kernel_imag[ear][bin]
                                + self.old_imag[bin] * source.kernel_real[ear][bin];
                        }
                    }
                    if !cached_target {
                        source.kernel_real[ear].copy_from_slice(&self.kernel_real);
                        source.kernel_imag[ear].copy_from_slice(&self.kernel_imag);
                    }
                }
            }
            if active {
                source.cached = Some(source.target);
            }
            source.old = source.target;
            source.gain = target.gain;
            source.jump = false;
        }
        // Convolution is linear before the limiter. Sum all source spectra
        // first, then perform only one inverse FFT per ear. Prior-block tails
        // remain in a shared overlap buffer when directions or gains change.
        for ear in 0..2 {
            if any_active {
                self.bank
                    .fft()
                    .run(&mut self.mix_real[ear], &mut self.mix_imag[ear], true);
                for i in 0..BLOCK {
                    output[i * 2 + ear] = self.mix_real[ear][i] + self.overlap[ear][i];
                }
                self.overlap[ear].copy_from_slice(&self.mix_real[ear][BLOCK..]);
            } else {
                for i in 0..BLOCK {
                    output[i * 2 + ear] = self.overlap[ear][i];
                }
                self.overlap[ear].fill(0.);
            }
        }
        // Validated finite sources and bounded HRIR L1/gains cannot overflow.
        if self.limiting {
            self.limiter
                .process(output)
                .expect("bounded binaural convolution is finite");
        }
    }
    /// Clear history, pending jumps and startup gain while retaining targets.
    pub fn reset(&mut self) {
        for source in &mut self.sources {
            source.old = source.target;
            source.gain = 0.0;
            source.jump = false;
        }
        self.limiter.reset();
        self.overlap = [[0.; BLOCK]; 2];
    }
}

fn prepare(bank: &HrirBank, source: BinauralSource) -> Result<HrirWeights, Error> {
    if !source.gain.is_finite() || !(0.0..=16.0).contains(&source.gain) {
        return Err(Error::Invalid("binaural source gain"));
    }
    bank.interpolate(source.azimuth, source.elevation)
}
