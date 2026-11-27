use crate::Error;

const BLOCK: usize = 1024;

/// One propagation tap. Delay is fractional samples; gain is finite pressure
/// amplitude in `[0,16]`. Spectral filtering and arrival direction are separate.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PropagationTarget {
    pub delay_samples: f64,
    pub gain: f32,
}

/// Source-time propagation for one mono source and 1..9 independent paths.
/// Each emitted sample is scheduled into a bounded future ring using two-tap
/// fractional delay interpolation. Path motion crossfades old/new emissions
/// over one block; already emitted tails remain at their original arrival time.
/// No amplitude limiter, spectral material model or Doppler model is implied.
#[derive(Clone, Debug)]
pub struct PropagationRenderer {
    targets: Vec<PropagationTarget>,
    previous: Vec<PropagationTarget>,
    jumps: Vec<bool>,
    ring: Vec<f32>,
    position: usize,
    frames: usize,
    maximum: f64,
}
impl PropagationRenderer {
    /// Prepare outside callbacks; max delay is (0,2] seconds at 8..192kHz.
    /// At most 9*(384000+2) f32 values are retained (about 13.2MiB).
    /// Initial targets apply immediately; upstream controls the startup gain.
    pub fn new(
        sample_rate: u32,
        maximum_delay_seconds: f64,
        targets: &[PropagationTarget],
    ) -> Result<Self, Error> {
        if !(8000..=192000).contains(&sample_rate)
            || !maximum_delay_seconds.is_finite()
            || !(0.0 < maximum_delay_seconds && maximum_delay_seconds <= 2.0)
            || !(1..=9).contains(&targets.len())
        {
            return Err(Error::Invalid("propagation configuration"));
        }
        let maximum = maximum_delay_seconds * f64::from(sample_rate);
        validate(targets, maximum)?;
        let frames = maximum.ceil() as usize + 2;
        Ok(Self {
            targets: targets.to_vec(),
            previous: targets.to_vec(),
            jumps: vec![false; targets.len()],
            ring: vec![0.; frames * targets.len()],
            position: 0,
            frames,
            maximum,
        })
    }
    pub fn paths(&self) -> usize {
        self.targets.len()
    }
    pub fn targets(&self) -> &[PropagationTarget] {
        &self.targets
    }
    /// Maximum possible tail, including outstanding emissions from old targets.
    pub fn tail_samples(&self) -> usize {
        self.maximum.ceil() as usize
    }
    /// Updates affect future emissions only. Invalid targets preserve pending
    /// updates and all scheduled arrivals. Explicit jumps still preserve tails.
    pub fn set_targets(
        &mut self,
        targets: &[PropagationTarget],
        jumps: &[bool],
    ) -> Result<(), Error> {
        if targets.len() != self.paths() || jumps.len() != targets.len() {
            return Err(Error::Invalid("propagation update path count"));
        }
        validate(targets, self.maximum)?;
        self.targets.copy_from_slice(targets);
        self.jumps.copy_from_slice(jumps);
        Ok(())
    }
    /// Exactly 1024 mono samples to 1024 interleaved path frames. No allocation.
    pub fn process(&mut self, input: &[f32], output: &mut [f32]) -> Result<(), Error> {
        self.validate_output(output)?;
        if input.len() != BLOCK || input.iter().any(|v| !v.is_finite() || v.abs() > 256.) {
            return Err(Error::Invalid("propagation input PCM"));
        }
        self.apply(Some(input), output);
        Ok(())
    }
    pub fn process_silence(&mut self, output: &mut [f32]) -> Result<(), Error> {
        self.validate_output(output)?;
        self.apply(None, output);
        Ok(())
    }
    fn validate_output(&self, output: &[f32]) -> Result<(), Error> {
        if output.len() != BLOCK * self.paths() {
            return Err(Error::Invalid("propagation output length"));
        }
        Ok(())
    }
    fn apply(&mut self, input: Option<&[f32]>, output: &mut [f32]) {
        let paths = self.paths();
        for sample in 0..BLOCK {
            let value = input.map_or(0., |v| v[sample]);
            let fraction = sample as f32 / BLOCK as f32;
            for path in 0..paths {
                if self.jumps[path] || self.previous[path] == self.targets[path] {
                    self.schedule(path, self.targets[path], value);
                } else {
                    self.schedule(path, self.previous[path], value * (1. - fraction));
                    self.schedule(path, self.targets[path], value * fraction);
                }
                let index = self.position * paths + path;
                output[sample * paths + path] = self.ring[index];
                self.ring[index] = 0.;
            }
            self.position = (self.position + 1) % self.frames;
        }
        self.previous.copy_from_slice(&self.targets);
        self.jumps.fill(false);
    }
    fn schedule(&mut self, path: usize, target: PropagationTarget, value: f32) {
        if value == 0. || target.gain == 0. {
            return;
        }
        let delay = target.delay_samples.floor() as usize;
        let fraction = (target.delay_samples - delay as f64) as f32;
        let first = (self.position + delay) % self.frames;
        let last = (first + 1) % self.frames;
        let paths = self.paths();
        self.ring[first * paths + path] += value * target.gain * (1. - fraction);
        self.ring[last * paths + path] += value * target.gain * fraction;
    }
    /// Clear scheduled arrivals and pending jumps, preserving current targets.
    pub fn reset(&mut self) {
        self.ring.fill(0.);
        self.position = 0;
        self.previous.copy_from_slice(&self.targets);
        self.jumps.fill(false);
    }
}
fn validate(targets: &[PropagationTarget], maximum: f64) -> Result<(), Error> {
    if targets.iter().any(|t| {
        !t.delay_samples.is_finite()
            || !(0.0..=maximum).contains(&t.delay_samples)
            || !t.gain.is_finite()
            || !(0.0..=16.).contains(&t.gain)
    }) {
        return Err(Error::Invalid("propagation delay or gain"));
    }
    Ok(())
}
