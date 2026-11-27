use super::{
    HoaDecoder, HoaRenderer,
    convolution::{BLOCK, Convolver, Kernel},
};
use crate::{Error, dsp::FftPlan, metadata::AudioPack};
use std::sync::Arc;

const DESIGN_FFT: usize = 32768;

/// Phase-only HOA near-field correction. Distances are positive metres in
/// `[0.001,1000]`, sample rate is 8..192 kHz. Equal distances are an aligned
/// identity, not a shortcut removing delay. Zero metadata distance disables
/// correction and should be represented by not constructing this filter.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct NearFieldConfig {
    pub reference_distance: f64,
    pub speaker_distance: f64,
    pub sample_rate: u32,
}

impl NearFieldConfig {
    /// Resolve the HOA pack's reference distance in metres. A transmitted zero
    /// means disabled; other distances require nonzero absoluteDistance.
    /// This does not reorder transport channels or apply any filtering.
    pub fn from_pack(
        pack: &AudioPack,
        speaker_distance: f64,
        sample_rate: u32,
    ) -> Result<Option<Self>, Error> {
        if pack.type_label != 4 || pack.absolute_distance > 31 {
            return Err(Error::Invalid("near-field HOA pack"));
        }
        let hoa = pack
            .hoa
            .as_ref()
            .ok_or(Error::Invalid("missing HOA pack parameters"))?;
        if hoa.nfc_distance > 15 {
            return Err(Error::Invalid("HOA near-field distance"));
        }
        // Validate the reproduction configuration even if this pack disables NFC.
        Self {
            reference_distance: 1.0,
            speaker_distance,
            sample_rate,
        }
        .validate()?;
        if hoa.nfc_distance == 0 {
            return Ok(None);
        }
        let value = Self {
            reference_distance: f64::from(pack.absolute_distance_value())
                * f64::from(hoa.nfc_reference_distance()),
            speaker_distance,
            sample_rate,
        };
        value.validate()?;
        Ok(Some(value))
    }
    fn validate(self) -> Result<(), Error> {
        if [self.reference_distance, self.speaker_distance]
            .iter()
            .any(|v| !v.is_finite() || !(0.001..=1000.0).contains(v))
            || !(8000..=192000).contains(&self.sample_rate)
        {
            return Err(Error::Invalid("near-field distances or sample rate"));
        }
        Ok(())
    }

    /// Complex unit-magnitude correction at an actual frequency in Hz. DC
    /// uses its continuous zero-phase limit. No magnitude boost is applied.
    pub fn phase_response(self, order: u8, frequency: f64) -> Result<[f64; 2], Error> {
        self.validate()?;
        if order > 3
            || !frequency.is_finite()
            || !(0.0..=f64::from(self.sample_rate) / 2.0).contains(&frequency)
        {
            return Err(Error::Invalid("near-field order or frequency"));
        }
        Ok(self.response(order, frequency))
    }

    fn response(self, order: u8, frequency: f64) -> [f64; 2] {
        if order == 0 || frequency == 0.0 || self.reference_distance == self.speaker_distance {
            return [1.0, 0.0];
        }
        let wave = std::f64::consts::TAU * frequency / 340.0;
        let a = radial(order, wave * self.reference_distance);
        let b = radial(order, wave * self.speaker_distance);
        let norm = a[0].hypot(a[1]) * b[0].hypot(b[1]);
        [
            (a[0] * b[0] + a[1] * b[1]) / norm,
            (a[1] * b[0] - a[0] * b[1]) / norm,
        ]
    }
}

// Finite spherical Hankel radial polynomials, after removing the common
// propagation term. The common term cancels between reference/playback radii.
fn radial(order: u8, x: f64) -> [f64; 2] {
    // Multiply by x^order, a positive real factor: phase is unchanged and
    // arbitrarily small positive frequencies cannot overflow inverse powers.
    match order {
        0 => [1.0, 0.0],
        1 => [x, -1.0],
        2 => [x * x - 3.0, -3.0 * x],
        _ => [x * x * x - 15.0 * x, 15.0 - 6.0 * x * x],
    }
}

/// Prepared, order-dependent 1024-tap FIR kernels. All ACN components of the
/// same order share a kernel, but retain independent convolution histories.
#[derive(Clone, Debug)]
pub struct HoaNearField {
    config: NearFieldConfig,
    order: u8,
    taps: Arc<Vec<[f32; BLOCK]>>,
    convolvers: Vec<Convolver>,
    input: [f32; BLOCK],
    output: [f32; BLOCK],
}

impl HoaNearField {
    pub const BLOCK_FRAMES: usize = BLOCK;
    pub const FILTER_LENGTH: usize = BLOCK;
    pub const DELAY_SAMPLES: usize = BLOCK / 2;

    /// Prepare outside the callback. The conjugate-symmetric 32768-bin response
    /// is inverse transformed, centred and truncated to 1024 causal taps.
    pub fn new(order: u8, config: NearFieldConfig) -> Result<Self, Error> {
        config.validate()?;
        if order > 3 {
            return Err(Error::Invalid("near-field HOA order"));
        }
        let plan = FftPlan::for_render(DESIGN_FFT);
        let mut real = vec![0.0; DESIGN_FFT];
        let mut imag = vec![0.0; DESIGN_FFT];
        let mut taps = vec![[0.0; BLOCK]; usize::from(order) + 1];
        let mut kernels = Vec::with_capacity(taps.len());
        for (n, taps) in taps.iter_mut().enumerate() {
            if n == 0 || config.reference_distance == config.speaker_distance {
                taps[Self::DELAY_SAMPLES] = 1.0;
            } else {
                real.fill(0.0);
                imag.fill(0.0);
                for bin in 0..=DESIGN_FFT / 2 {
                    let response = config.response(
                        n as u8,
                        bin as f64 * f64::from(config.sample_rate) / DESIGN_FFT as f64,
                    );
                    real[bin] = response[0] as f32;
                    if bin != 0 && bin != DESIGN_FFT / 2 {
                        imag[bin] = response[1] as f32;
                        real[DESIGN_FFT - bin] = real[bin];
                        imag[DESIGN_FFT - bin] = -imag[bin];
                    }
                }
                plan.run(&mut real, &mut imag, true);
                for (i, tap) in taps.iter_mut().enumerate() {
                    *tap = real[(DESIGN_FFT + i - Self::DELAY_SAMPLES) % DESIGN_FFT];
                }
            }
            kernels.push(Kernel::from_taps(taps));
        }
        let channels = (usize::from(order) + 1).pow(2);
        let convolvers = (0..channels)
            .map(|acn| Convolver::new(Arc::clone(&kernels[acn.isqrt()])))
            .collect();
        Ok(Self {
            config,
            order,
            taps: Arc::new(taps),
            convolvers,
            input: [0.0; BLOCK],
            output: [0.0; BLOCK],
        })
    }
    pub fn config(&self) -> NearFieldConfig {
        self.config
    }
    pub fn order(&self) -> u8 {
        self.order
    }
    pub fn channels(&self) -> usize {
        self.convolvers.len()
    }
    pub fn coefficients(&self, order: u8) -> Option<&[f32]> {
        self.taps.get(usize::from(order)).map(|t| t.as_slice())
    }

    /// Exactly 1024 interleaved frames. Invalid lengths/non-finite samples or
    /// input magnitude >256 leave both output and convolution history intact.
    pub fn process(&mut self, input: &[f32], output: &mut [f32]) -> Result<(), Error> {
        self.validate(input, output.len())?;
        self.apply(input, output);
        Ok(())
    }
    fn validate(&self, input: &[f32], output: usize) -> Result<(), Error> {
        if input.len() != BLOCK * self.channels() || output != input.len() {
            return Err(Error::Invalid("near-field block length"));
        }
        if input.iter().any(|v| !v.is_finite() || v.abs() > 256.0) {
            return Err(Error::Invalid("near-field PCM"));
        }
        Ok(())
    }
    pub(super) fn apply(&mut self, input: &[f32], output: &mut [f32]) {
        debug_assert_eq!(input.len(), BLOCK * self.channels());
        debug_assert_eq!(output.len(), input.len());
        debug_assert!(input.iter().all(|v| v.is_finite()));
        let channels = self.channels();
        for (channel, convolver) in self.convolvers.iter_mut().enumerate() {
            for (i, sample) in self.input.iter_mut().enumerate() {
                *sample = input[i * channels + channel];
            }
            convolver.process(&self.input, &mut self.output);
            for (i, &sample) in self.output.iter().enumerate() {
                output[i * channels + channel] = sample;
            }
        }
    }
    pub fn process_silence(&mut self, output: &mut [f32]) -> Result<(), Error> {
        let channels = self.channels();
        if output.len() != BLOCK * channels {
            return Err(Error::Invalid("near-field block length"));
        }
        self.input.fill(0.0);
        for (channel, convolver) in self.convolvers.iter_mut().enumerate() {
            convolver.process(&self.input, &mut self.output);
            for (i, &sample) in self.output.iter().enumerate() {
                output[i * channels + channel] = sample;
            }
        }
        Ok(())
    }
    pub fn reset(&mut self) {
        for convolver in &mut self.convolvers {
            convolver.reset();
        }
        self.input.fill(0.0);
        self.output.fill(0.0);
    }
}

/// Frame-aligned near-field HOA loudspeaker renderer. The additional 512-sample
/// FIR alignment applies to every component, including order zero. The filter
/// tail extends beyond this alignment, so drain TAIL_SAMPLES after final input.
#[derive(Clone, Debug)]
pub struct NearFieldHoaRenderer {
    filter: HoaNearField,
    renderer: HoaRenderer,
    input: Vec<f32>,
    filtered: Vec<f32>,
}

impl NearFieldHoaRenderer {
    pub const DELAY_SAMPLES: usize = HoaRenderer::DELAY_SAMPLES + HoaNearField::DELAY_SAMPLES;
    pub const TAIL_SAMPLES: usize = HoaRenderer::DELAY_SAMPLES + HoaNearField::FILTER_LENGTH - 1;
    /// Construct from a complete, explicitly NFC-enabled ACN/SN3D pack. Input
    /// PCM must already be in pack/ACN order; use transport_channels() to reorder.
    pub fn from_pack(
        pack: &AudioPack,
        output: super::BedLayout,
        speaker_distance: f64,
        sample_rate: u32,
    ) -> Result<Self, Error> {
        let config = NearFieldConfig::from_pack(pack, speaker_distance, sample_rate)?
            .ok_or(Error::Invalid("near-field correction is disabled"))?;
        let parameters = pack.hoa.as_ref().unwrap();
        if parameters.normalization != 0 {
            return Err(Error::Unsupported("reserved HOA normalization"));
        }
        if parameters.screen_reference {
            return Err(Error::Unsupported("HOA screen reference"));
        }
        let decoder = HoaDecoder::new(
            parameters.order,
            super::HoaNormalization::Sn3d,
            output,
            false,
        )?;
        if pack.channels.len() != usize::from(decoder.input_channels()) {
            return Err(Error::Invalid("HOA pack component count"));
        }
        pack.transport_channels()?;
        Self::new(decoder, config)
    }
    pub fn new(decoder: HoaDecoder, config: NearFieldConfig) -> Result<Self, Error> {
        let filter = HoaNearField::new(decoder.order(), config)?;
        let samples = filter.channels() * BLOCK;
        Ok(Self {
            filter,
            renderer: HoaRenderer::new(decoder)?,
            input: vec![0.0; samples],
            filtered: vec![0.0; samples],
        })
    }
    pub fn filter(&self) -> &HoaNearField {
        &self.filter
    }
    pub fn renderer(&self) -> &HoaRenderer {
        &self.renderer
    }
    fn validate_output(&self, output: &[f32]) -> Result<(), Error> {
        if output.len() != BLOCK * usize::from(self.renderer.decoder().output_layout().channels()) {
            return Err(Error::Invalid("near-field renderer output length"));
        }
        Ok(())
    }
    pub fn process_f32(&mut self, input: &[f32], output: &mut [f32]) -> Result<(), Error> {
        self.validate_output(output)?;
        self.filter.validate(input, self.filtered.len())?;
        self.filter.apply(input, &mut self.filtered);
        self.renderer.process_prefiltered(&self.filtered, output);
        Ok(())
    }
    pub fn process(&mut self, input: &[i16], output: &mut [f32]) -> Result<(), Error> {
        self.validate_output(output)?;
        if input.len() != self.input.len() {
            return Err(Error::Invalid("near-field renderer input length"));
        }
        for (target, &source) in self.input.iter_mut().zip(input) {
            *target = f32::from(source) / 32768.0;
        }
        self.filter.apply(&self.input, &mut self.filtered);
        self.renderer.process_prefiltered(&self.filtered, output);
        Ok(())
    }
    pub fn process_silence(&mut self, output: &mut [f32]) -> Result<(), Error> {
        self.validate_output(output)?;
        self.filter.process_silence(&mut self.filtered)?;
        self.renderer.process_prefiltered(&self.filtered, output);
        Ok(())
    }
    pub fn reset(&mut self) {
        self.filter.reset();
        self.renderer.reset();
        self.input.fill(0.0);
        self.filtered.fill(0.0);
    }
}
