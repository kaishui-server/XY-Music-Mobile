//! Bounded parsing of externally supplied, decoded little-endian hyper models.
//! No model weights are embedded.
mod inference;
mod spectrum;
use crate::{
    Error,
    entropy::{DecodedSymbols, EntropyModel},
};
pub use spectrum::{NoiseState, SpectrumConfig};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Activation {
    Relu,
    Linear,
    Sigmoid,
    Tanh,
    Gdn,
    Igdn,
}

#[derive(Clone, Debug)]
pub struct Layer {
    pub transpose: bool,
    pub stride: usize,
    pub kernel_size: usize,
    pub input_channels: usize,
    pub output_channels: usize,
    pub input_lines: usize,
    pub output_lines: usize,
    pub activation: Activation,
    /// Kernel-major; ordinary convolution then indexes input/output channels,
    /// transpose convolution indexes output/input channels.
    pub weights: Vec<f32>,
    pub bias: Vec<f32>,
    pub beta: Vec<f32>,
    /// Serialized row-major matrix (output channels squared).
    pub gamma: Vec<f32>,
}

#[derive(Clone, Debug)]
pub struct Codec {
    pub encoder: Vec<Layer>,
    pub decoder: Vec<Layer>,
    pub latent_lines: usize,
    pub latent_channels: usize,
    pub medians: Vec<f32>,
    pub scales: Vec<f32>,
    pub entropy: EntropyModel,
    /// End offset in the supplied model record.
    pub end_offset: usize,
}

#[derive(Clone, Debug)]
pub struct HyperModel {
    base: Codec,
    context: Codec,
}

#[derive(Clone, Debug)]
pub struct Latents {
    pub context: DecodedSymbols,
    pub base: DecodedSymbols,
    /// Wire order (line/channel), including the final-scale saturation rule.
    pub base_distributions: Vec<usize>,
}

impl HyperModel {
    /// Parse an exact, already decoded model. Encoded wrappers must be handled
    /// by the caller. Trailing data, non-finite floats and incompatible shapes fail.
    pub fn parse(bytes: &[u8]) -> Result<Self, Error> {
        if bytes.len() > 32 * 1024 * 1024 {
            return Err(Error::Unsupported("model byte limit"));
        }
        let mut reader = Reader { bytes, position: 0 };
        let base = reader.codec(1024, 1, true)?;
        let context = reader.codec(base.latent_lines, base.latent_channels, false)?;
        if context
            .decoder
            .last()
            .map(|l| (l.output_lines, l.output_channels))
            != Some((base.latent_lines, base.latent_channels))
        {
            return Err(Error::Invalid("context output shape"));
        }
        if reader.position != bytes.len() {
            return Err(Error::Invalid("trailing model data"));
        }
        Ok(Self { base, context })
    }
    pub fn base(&self) -> &Codec {
        &self.base
    }
    pub fn context(&self) -> &Codec {
        &self.context
    }

    pub fn context_prediction(&self, values: &[i32]) -> Result<Vec<f32>, Error> {
        inference::synthesize(&self.context.decoder, self.context_features(values)?)
    }

    pub fn decode_latents(
        &self,
        quantized: &crate::quantization::QuantizedChannel,
    ) -> Result<Latents, Error> {
        let context = self.decode_context(&quantized.context)?;
        let prediction = self.context_prediction(&context.values)?;
        let mut base_distributions = Vec::with_capacity(prediction.len());
        for line in 0..self.base.latent_lines {
            for channel in 0..self.base.latent_channels {
                let value = prediction[channel * self.base.latent_lines + line];
                let index = self.base.scales.partition_point(|&scale| scale < value);
                base_distributions.push(index.min(self.base.scales.len() - 1));
            }
        }
        let base = self
            .base
            .entropy
            .decode(&quantized.base, &base_distributions)?;
        Ok(Latents {
            context,
            base,
            base_distributions,
        })
    }

    /// Decode context integers in wire order: line-major, channels interleaved.
    /// Counters expose virtual zero padding; they do not establish frame integrity.
    pub fn decode_context(&self, bytes: &[u8]) -> Result<DecodedSymbols, Error> {
        let count = self.context.latent_lines * self.context.latent_channels;
        let indices: Vec<_> = (0..count)
            .map(|i| i % self.context.latent_channels)
            .collect();
        self.context.entropy.decode(bytes, &indices)
    }

    /// Add channel medians and transpose wire integers to channel-major features.
    pub fn context_features(&self, values: &[i32]) -> Result<Vec<f32>, Error> {
        let (lines, channels) = (self.context.latent_lines, self.context.latent_channels);
        if values.len() != lines * channels {
            return Err(Error::Invalid("context latent shape"));
        }
        let mut output = vec![0.0; values.len()];
        for line in 0..lines {
            for channel in 0..channels {
                let value =
                    values[line * channels + channel] as f32 + self.context.medians[channel];
                if !value.is_finite() {
                    return Err(Error::Invalid("context feature value"));
                }
                output[channel * lines + line] = value;
            }
        }
        Ok(output)
    }
}

struct Reader<'a> {
    bytes: &'a [u8],
    position: usize,
}
impl<'a> Reader<'a> {
    fn take(&mut self, size: usize) -> Result<&'a [u8], Error> {
        let end = self
            .position
            .checked_add(size)
            .ok_or(Error::Invalid("model size"))?;
        let bytes = self.bytes.get(self.position..end).ok_or(Error::Truncated)?;
        self.position = end;
        Ok(bytes)
    }
    fn integer(&mut self) -> Result<usize, Error> {
        let bytes = self.take(2)?;
        let value = i16::from_le_bytes([bytes[0], bytes[1]]);
        usize::try_from(value).map_err(|_| Error::Invalid("negative model dimension"))
    }
    fn floats(&mut self, count: usize) -> Result<Vec<f32>, Error> {
        if count > 1024 * 1024 {
            return Err(Error::Unsupported("model tensor limit"));
        }
        let bytes = self.take(count * 4)?;
        bytes
            .as_chunks::<4>()
            .0
            .iter()
            .map(|word| {
                let value = f32::from_le_bytes(*word);
                if value.is_finite() {
                    Ok(value)
                } else {
                    Err(Error::Invalid("model float"))
                }
            })
            .collect()
    }
    fn network(
        &mut self,
        mut lines: usize,
        mut channels: usize,
        transpose: bool,
    ) -> Result<Vec<Layer>, Error> {
        let count = self.integer()?;
        if !(1..=10).contains(&count) {
            return Err(Error::Invalid("model layer count"));
        }
        let mut layers = Vec::with_capacity(count);
        for _ in 0..count {
            let padding = self.integer()?;
            let stride = self.integer()?;
            let bias = self.integer()?;
            let activation = match self.integer()? {
                0 => Activation::Relu,
                1 => Activation::Linear,
                2 => Activation::Sigmoid,
                3 => Activation::Tanh,
                4 => Activation::Gdn,
                5 => Activation::Igdn,
                _ => return Err(Error::Unsupported("model activation")),
            };
            let kernel_size = self.integer()?;
            let input_channels = self.integer()?;
            let output_channels = self.integer()?;
            if padding != 0 {
                return Err(Error::Unsupported("model padding"));
            }
            if !(1..=2).contains(&stride)
                || bias > 1
                || !(1..=31).contains(&kernel_size)
                || !(1..=256).contains(&output_channels)
                || input_channels != channels
            {
                return Err(Error::Invalid("model layer dimensions"));
            }
            let output_lines = if transpose {
                lines * stride
            } else {
                if !lines.is_multiple_of(stride) {
                    return Err(Error::Invalid("model feature stride"));
                }
                lines / stride
            };
            if output_lines == 0 || output_lines * output_channels > 1024 * 1024 {
                return Err(Error::Unsupported("model feature limit"));
            }
            let weights = self.floats(kernel_size * input_channels * output_channels)?;
            let bias = self.floats(bias * output_channels)?;
            let (beta, gamma) = if matches!(activation, Activation::Gdn | Activation::Igdn) {
                let beta = self.floats(output_channels)?;
                let gamma = self.floats(output_channels * output_channels)?;
                if beta.iter().any(|&v| v <= 0.0) || gamma.iter().any(|&v| v < 0.0) {
                    return Err(Error::Invalid("model normalization parameters"));
                }
                (beta, gamma)
            } else {
                (Vec::new(), Vec::new())
            };
            layers.push(Layer {
                transpose,
                stride,
                kernel_size,
                input_channels,
                output_channels,
                input_lines: lines,
                output_lines,
                activation,
                weights,
                bias,
                beta,
                gamma,
            });
            lines = output_lines;
            channels = output_channels;
        }
        Ok(layers)
    }
    fn codec(&mut self, lines: usize, channels: usize, hyper: bool) -> Result<Codec, Error> {
        let encoder = self.network(lines, channels, false)?;
        let last = encoder.last().unwrap();
        let (latent_lines, latent_channels) = (last.output_lines, last.output_channels);
        let decoder = self.network(latent_lines, latent_channels, true)?;
        let last = decoder.last().unwrap();
        if (last.output_lines, last.output_channels) != (lines, channels) {
            return Err(Error::Invalid("model reconstruction shape"));
        }
        let medians = self.floats(latent_channels)?;
        let scales = if hyper {
            let count = self.integer()?;
            if !(1..=1024).contains(&count) {
                return Err(Error::Invalid("model scale count"));
            }
            let values = self.floats(count)?;
            if values.iter().any(|&v| v <= 0.0) || values.windows(2).any(|w| w[0] >= w[1]) {
                return Err(Error::Invalid("model context scales"));
            }
            values
        } else {
            Vec::new()
        };
        let count = if hyper { scales.len() } else { latent_channels };
        let (entropy, size) = EntropyModel::read(&self.bytes[self.position..], count)?;
        self.position += size;
        Ok(Codec {
            encoder,
            decoder,
            latent_lines,
            latent_channels,
            medians,
            scales,
            entropy,
            end_offset: self.position,
        })
    }
}
