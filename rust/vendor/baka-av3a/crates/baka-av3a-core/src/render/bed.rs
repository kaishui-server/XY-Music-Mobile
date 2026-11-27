use super::{Channel, layouts::BedLayout};
use crate::Error;

const BLOCK: usize = 1024;

/// Fixed-layout channel-bed renderer with interpolated gains and output limiting.
///
/// Input is interleaved i16 PCM in the decoder's channel order; output is
/// normalized interleaved f32. Reuse between blocks and reset after a stream
/// discontinuity. This renderer does not interpret object or HOA metadata.
#[derive(Clone, Debug)]
pub struct BedRenderer {
    input_layout: BedLayout,
    output_layout: BedLayout,
    gains: &'static [u8],
    input: Vec<f32>,
    ready: Vec<f32>,
    delayed: Vec<f32>,
    limiters: Vec<Channel>,
    position: usize,
    started: bool,
}

impl BedRenderer {
    /// Signal delay in samples per output channel, independent of sample rate.
    pub const DELAY_SAMPLES: usize = 2 * BLOCK + super::LookAheadLimiter::DELAY_SAMPLES;

    /// Allocate fixed buffers for a channel-bed conversion.
    pub fn new(input_layout: BedLayout, output_layout: BedLayout) -> Self {
        let inputs = usize::from(input_layout.channels());
        let outputs = usize::from(output_layout.channels());
        Self {
            input_layout,
            output_layout,
            gains: input_layout.gains_to(output_layout),
            input: vec![0.0; inputs * BLOCK],
            ready: vec![0.0; outputs * BLOCK],
            delayed: vec![0.0; outputs * BLOCK],
            limiters: vec![Channel::default(); outputs],
            position: 0,
            started: false,
        }
    }

    pub fn input_layout(&self) -> BedLayout {
        self.input_layout
    }

    pub fn output_layout(&self) -> BedLayout {
        self.output_layout
    }

    /// Clear all audio, interpolation and limiter history without reallocating.
    pub fn reset(&mut self) {
        self.input.fill(0.0);
        self.ready.fill(0.0);
        self.delayed.fill(0.0);
        self.limiters.fill(Channel::default());
        self.position = 0;
        self.started = false;
    }

    /// Render complete interleaved frames without allocation.
    ///
    /// Output must contain the same number of frames in the output layout.
    /// Invalid lengths leave output and renderer history unchanged. Call sizes
    /// need not align to the internal 1024-sample block size.
    pub fn process(&mut self, input: &[i16], output: &mut [f32]) -> Result<(), Error> {
        let inputs = usize::from(self.input_layout.channels());
        if !input.len().is_multiple_of(inputs) {
            return Err(Error::Invalid("renderer input frame length"));
        }
        self.validate_output(input.len() / inputs, output)?;
        let outputs = usize::from(self.output_layout.channels());
        for (frame, result) in input
            .chunks_exact(inputs)
            .zip(output.chunks_exact_mut(outputs))
        {
            let start = self.position * inputs;
            for (dest, value) in self.input[start..start + inputs].iter_mut().zip(frame) {
                *dest = f32::from(*value) / 32768.0;
            }
            self.output_frame(result);
        }
        Ok(())
    }

    /// Render zero input without constructing a temporary input buffer.
    ///
    /// After EOF, render `DELAY_SAMPLES` frames to retrieve the pending signal.
    /// This does not reset or close the renderer.
    pub fn process_silence(&mut self, frames: usize, output: &mut [f32]) -> Result<(), Error> {
        self.validate_output(frames, output)?;
        let inputs = usize::from(self.input_layout.channels());
        let outputs = usize::from(self.output_layout.channels());
        for result in output.chunks_exact_mut(outputs) {
            let start = self.position * inputs;
            self.input[start..start + inputs].fill(0.0);
            self.output_frame(result);
        }
        Ok(())
    }

    fn validate_output(&self, frames: usize, output: &[f32]) -> Result<(), Error> {
        if frames.checked_mul(usize::from(self.output_layout.channels())) != Some(output.len()) {
            return Err(Error::Invalid("renderer output frame length"));
        }
        Ok(())
    }

    fn output_frame(&mut self, output: &mut [f32]) {
        let outputs = self.limiters.len();
        let start = self.position * outputs;
        for ((dest, input), limiter) in output
            .iter_mut()
            .zip(&self.ready[start..start + outputs])
            .zip(&mut self.limiters)
        {
            *dest = limiter.process(*input);
        }
        self.position += 1;
        if self.position == BLOCK {
            self.mix_block();
            self.position = 0;
        }
    }

    fn mix_block(&mut self) {
        let inputs = usize::from(self.input_layout.channels());
        let outputs = self.limiters.len();
        self.ready.copy_from_slice(&self.delayed);
        self.delayed.fill(0.0);
        for input in 0..inputs {
            for output in 0..outputs {
                let gain = super::layouts::gain(self.gains[input * outputs + output]);
                if gain == 0.0 {
                    continue;
                }
                let previous = if self.started { gain } else { 0.0 };
                for sample in 0..BLOCK {
                    let t = sample as f32 * (1.0 / BLOCK as f32);
                    let rising = gain * t;
                    let falling = previous * (1.0 - t);
                    let interpolated = rising + falling;
                    self.delayed[sample * outputs + output] +=
                        self.input[sample * inputs + input] * interpolated;
                }
            }
        }
        self.started = true;
    }
}
