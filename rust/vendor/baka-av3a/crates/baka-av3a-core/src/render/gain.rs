use super::{
    BedLayout, Channel,
    convolution::{BLOCK, Convolver, Kernel},
};
use crate::Error;

/// Per-output-speaker gains for one already projected object.
///
/// These are amplitude coefficients, not azimuth, elevation or extent metadata.
/// A geometric projector must calculate the direct and diffuse vectors first.
#[derive(Clone, Debug)]
pub struct ObjectGains {
    pub(super) direct: Vec<f32>,
    pub(super) diffuse: Vec<f32>,
}

impl ObjectGains {
    /// Accept 1–12 speakers, matching vector lengths, and finite gains in `[-16, 16]`.
    pub fn new(direct: Vec<f32>, diffuse: Vec<f32>) -> Result<Self, Error> {
        if direct.is_empty() || direct.len() > 12 || direct.len() != diffuse.len() {
            return Err(Error::Invalid("object gain dimensions"));
        }
        if direct
            .iter()
            .chain(&diffuse)
            .any(|v| !v.is_finite() || v.abs() > 16.0)
        {
            return Err(Error::Invalid("object gain coefficient"));
        }
        Ok(Self { direct, diffuse })
    }

    pub fn direct(&self) -> &[f32] {
        &self.direct
    }
    pub fn diffuse(&self) -> &[f32] {
        &self.diffuse
    }
}

/// Render a channel bed and projected objects through direct and diffuse paths.
///
/// Input order is bed channels followed by one channel per object. This is the
/// audio application stage: it does not project position or extent metadata.
/// Filters and buffers are prepared at construction, never during processing.
#[derive(Clone, Debug)]
pub struct GainRenderer {
    layout: BedLayout,
    bed_channels: usize,
    inputs: usize,
    direct: Vec<f32>,
    diffuse: Vec<f32>,
    previous_direct: Vec<f32>,
    previous_diffuse: Vec<f32>,
    jump: Vec<bool>,
    start_direct: Vec<f32>,
    start_diffuse: Vec<f32>,
    input: Vec<f32>,
    ready: Vec<f32>,
    delayed: Vec<f32>,
    diffuse_input: Vec<f32>,
    convolution_output: Vec<f32>,
    convolvers: Vec<Convolver>,
    limiters: Vec<Channel>,
    position: usize,
    limiting: bool,
}

impl GainRenderer {
    /// Direct path delay, also sufficient to drain both paths after EOF.
    pub const DELAY_SAMPLES: usize = super::BedRenderer::DELAY_SAMPLES;
    /// First-sample delay of the diffuse path, before its 511-sample FIR tail.
    pub const DIFFUSE_DELAY_SAMPLES: usize = BLOCK + super::LookAheadLimiter::DELAY_SAMPLES;

    pub fn new(
        bed: Option<BedLayout>,
        output: BedLayout,
        objects: &[ObjectGains],
    ) -> Result<Self, Error> {
        let bed_channels = bed.map_or(0, |layout| usize::from(layout.channels()));
        let outputs = usize::from(output.channels());
        if objects.len() > 16
            || bed_channels + objects.len() > 16
            || bed_channels + objects.len() == 0
        {
            return Err(Error::Invalid("renderer input channel count"));
        }
        if objects.iter().any(|g| g.direct.len() != outputs) {
            return Err(Error::Invalid("object output layout"));
        }
        let inputs = bed_channels + objects.len();
        let mut direct = vec![0.0; inputs * outputs];
        let mut diffuse = direct.clone();
        if let Some(bed) = bed {
            for (value, &index) in direct.iter_mut().zip(bed.gains_to(output)) {
                *value = super::layouts::gain(index);
            }
        }
        for (i, object) in objects.iter().enumerate() {
            let start = (bed_channels + i) * outputs;
            direct[start..start + outputs].copy_from_slice(&object.direct);
            diffuse[start..start + outputs].copy_from_slice(&object.diffuse);
        }
        let names = output.speaker_names();
        let convolvers = names
            .iter()
            .map(|name| {
                let seed = names.iter().filter(|other| *other < name).count() as u32;
                Convolver::new(Kernel::new(seed))
            })
            .collect();
        Ok(Self {
            layout: output,
            bed_channels,
            inputs,
            previous_direct: vec![0.0; direct.len()],
            previous_diffuse: vec![0.0; diffuse.len()],
            jump: vec![false; inputs],
            start_direct: vec![0.0; direct.len()],
            start_diffuse: vec![0.0; diffuse.len()],
            direct,
            diffuse,
            input: vec![0.0; BLOCK * inputs],
            ready: vec![0.0; BLOCK * outputs],
            delayed: vec![0.0; BLOCK * outputs],
            diffuse_input: vec![0.0; BLOCK * outputs],
            convolution_output: vec![0.0; BLOCK],
            convolvers,
            limiters: vec![Channel::default(); outputs],
            position: 0,
            limiting: true,
        })
    }

    pub fn input_channels(&self) -> u16 {
        self.inputs as u16
    }
    pub fn output_layout(&self) -> BedLayout {
        self.layout
    }
    // Only construction of an internal render bus uses this. The final mixing
    // stage supplies the one limiter and its 99-sample alignment.
    pub(super) fn disable_limiter(&mut self) {
        self.limiting = false;
    }
    pub fn object_count(&self) -> usize {
        self.inputs - self.bed_channels
    }

    /// Set the next block's target gains. The channel configuration is fixed.
    ///
    /// Updates take effect when the current 1024-sample input block completes,
    /// with a one-block interpolation from the previous targets. Align updates
    /// with input block boundaries when associating them with frame metadata.
    /// Invalid dimensions leave both targets and history unchanged.
    pub fn set_objects(&mut self, objects: &[ObjectGains]) -> Result<(), Error> {
        let outputs = self.limiters.len();
        if objects.len() != self.object_count() || objects.iter().any(|g| g.direct.len() != outputs)
        {
            return Err(Error::Invalid("object gain update dimensions"));
        }
        self.jump.fill(false);
        for (i, object) in objects.iter().enumerate() {
            let start = (self.bed_channels + i) * outputs;
            self.direct[start..start + outputs].copy_from_slice(&object.direct);
            self.diffuse[start..start + outputs].copy_from_slice(&object.diffuse);
        }
        Ok(())
    }

    /// At a 1024-frame boundary, replace selected objects' gains immediately
    /// for the next block. Other objects and the bed retain ordinary interpolation.
    /// Flags last for one block; invalid updates preserve all pending state.
    pub fn set_objects_with_jump(
        &mut self,
        objects: &[ObjectGains],
        jumps: &[bool],
    ) -> Result<(), Error> {
        self.set_objects_from_starts(objects, jumps, objects)
    }

    pub(super) fn at_block_boundary(&self) -> bool {
        self.position == 0
    }

    pub(super) fn set_objects_from_starts(
        &mut self,
        objects: &[ObjectGains],
        jumps: &[bool],
        starts: &[ObjectGains],
    ) -> Result<(), Error> {
        let outputs = self.limiters.len();
        if !self.at_block_boundary()
            || jumps.len() != self.object_count()
            || starts.len() != jumps.len()
            || starts
                .iter()
                .any(|g| g.direct.len() != outputs || g.diffuse.len() != outputs)
        {
            return Err(Error::Invalid("object jump update boundary or dimensions"));
        }
        self.set_objects(objects)?;
        for (i, (&jump, start)) in jumps.iter().zip(starts).enumerate() {
            let input = self.bed_channels + i;
            self.jump[input] = jump;
            let offset = input * outputs;
            self.start_direct[offset..offset + outputs].copy_from_slice(&start.direct);
            self.start_diffuse[offset..offset + outputs].copy_from_slice(&start.diffuse);
        }
        Ok(())
    }

    /// Clear all queued audio and history, preserving the current gain targets.
    pub fn reset(&mut self) {
        self.input.fill(0.0);
        self.ready.fill(0.0);
        self.delayed.fill(0.0);
        self.diffuse_input.fill(0.0);
        self.convolution_output.fill(0.0);
        self.previous_direct.fill(0.0);
        self.previous_diffuse.fill(0.0);
        self.jump.fill(false);
        self.start_direct.fill(0.0);
        self.start_diffuse.fill(0.0);
        self.limiters.fill(Channel::default());
        for convolver in &mut self.convolvers {
            convolver.reset();
        }
        self.position = 0;
    }

    /// Process interleaved i16 input into normalized interleaved f32 output.
    /// Output must contain exactly the same number of frames. No allocation.
    pub fn process(&mut self, input: &[i16], output: &mut [f32]) -> Result<(), Error> {
        if !input.len().is_multiple_of(self.inputs) {
            return Err(Error::Invalid("renderer input frame length"));
        }
        self.validate_output(input.len() / self.inputs, output)?;
        let outputs = self.limiters.len();
        for (frame, output) in input
            .chunks_exact(self.inputs)
            .zip(output.chunks_exact_mut(outputs))
        {
            let start = self.position * self.inputs;
            for (target, sample) in self.input[start..start + self.inputs].iter_mut().zip(frame) {
                *target = f32::from(*sample) / 32768.0;
            }
            self.output_frame(output);
        }
        Ok(())
    }

    /// Process normalized floating point PCM without requantizing to i16.
    /// Finite headroom up to 256 is preserved; reject invalid data before any
    /// state/output mutation and keep the same timing as the integer API.
    pub fn process_f32(&mut self, input: &[f32], output: &mut [f32]) -> Result<(), Error> {
        if !input.len().is_multiple_of(self.inputs) {
            return Err(Error::Invalid("renderer input frame length"));
        }
        self.validate_output(input.len() / self.inputs, output)?;
        if input.iter().any(|v| !v.is_finite() || v.abs() > 256.0) {
            return Err(Error::Invalid("renderer non-finite or excessive PCM"));
        }
        self.process_prefiltered(input, output);
        Ok(())
    }

    // Internal fixed FIRs can exceed the public source amplitude limit even
    // from valid PCM. Their bounded taps/input keep values finite; dimensions
    // have already been checked before the filter history is advanced.
    pub(super) fn process_prefiltered(&mut self, input: &[f32], output: &mut [f32]) {
        debug_assert!(input.len().is_multiple_of(self.inputs));
        debug_assert_eq!(
            output.len(),
            input.len() / self.inputs * self.limiters.len()
        );
        debug_assert!(input.iter().all(|v| v.is_finite()));
        let outputs = self.limiters.len();
        for (frame, output) in input
            .chunks_exact(self.inputs)
            .zip(output.chunks_exact_mut(outputs))
        {
            let start = self.position * self.inputs;
            self.input[start..start + self.inputs].copy_from_slice(frame);
            self.output_frame(output);
        }
    }

    /// Feed zero input to flush pending audio without allocating an input block.
    pub fn process_silence(&mut self, frames: usize, output: &mut [f32]) -> Result<(), Error> {
        self.validate_output(frames, output)?;
        let outputs = self.limiters.len();
        for output in output.chunks_exact_mut(outputs) {
            let start = self.position * self.inputs;
            self.input[start..start + self.inputs].fill(0.0);
            self.output_frame(output);
        }
        Ok(())
    }

    fn validate_output(&self, frames: usize, output: &[f32]) -> Result<(), Error> {
        if frames.checked_mul(self.limiters.len()) != Some(output.len()) {
            return Err(Error::Invalid("renderer output frame length"));
        }
        Ok(())
    }

    fn output_frame(&mut self, output: &mut [f32]) {
        let start = self.position * self.limiters.len();
        for ((target, sample), limiter) in output
            .iter_mut()
            .zip(&self.ready[start..start + self.limiters.len()])
            .zip(&mut self.limiters)
        {
            *target = if self.limiting {
                limiter.process(*sample)
            } else {
                *sample
            };
        }
        self.position += 1;
        if self.position == BLOCK {
            self.mix_block();
            self.position = 0;
        }
    }

    fn mix_block(&mut self) {
        let outputs = self.limiters.len();
        for output in 0..outputs {
            for sample in 0..BLOCK {
                self.ready[sample * outputs + output] = self.delayed[output * BLOCK + sample];
            }
        }
        mix(
            &self.input,
            self.inputs,
            &self.previous_direct,
            &self.direct,
            &self.start_direct,
            &self.jump,
            &mut self.delayed,
        );
        mix(
            &self.input,
            self.inputs,
            &self.previous_diffuse,
            &self.diffuse,
            &self.start_diffuse,
            &self.jump,
            &mut self.diffuse_input,
        );
        self.previous_direct.copy_from_slice(&self.direct);
        self.previous_diffuse.copy_from_slice(&self.diffuse);
        self.jump.fill(false);
        for output in 0..outputs {
            self.convolvers[output].process(
                &self.diffuse_input[output * BLOCK..(output + 1) * BLOCK],
                &mut self.convolution_output,
            );
            for sample in 0..BLOCK {
                self.ready[sample * outputs + output] += self.convolution_output[sample];
            }
        }
    }
}

fn mix(
    input: &[f32],
    inputs: usize,
    previous: &[f32],
    target: &[f32],
    starts: &[f32],
    jumps: &[bool],
    output: &mut [f32],
) {
    let outputs = target.len() / inputs;
    output.fill(0.0);
    for source in 0..inputs {
        for speaker in 0..outputs {
            let index = source * outputs + speaker;
            let old = if jumps[source] {
                starts[index]
            } else {
                previous[index]
            };
            let new = target[source * outputs + speaker];
            if old == 0.0 && new == 0.0 {
                continue;
            }
            for sample in 0..BLOCK {
                let t = sample as f32 / BLOCK as f32;
                let gain = if jumps[source] {
                    old + (new - old) * t
                } else {
                    let rising = new * t;
                    let falling = old * (1.0 - t);
                    rising + falling
                };
                output[speaker * BLOCK + sample] += input[sample * inputs + source] * gain;
            }
        }
    }
}
