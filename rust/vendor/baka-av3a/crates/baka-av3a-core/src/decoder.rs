//! Stateful packet-to-PCM decoding for supported channel beds.
use crate::{
    Error, FrameHeader, Profile,
    hoa::{HoaBasis, HoaFrame, HoaSynthesis},
    mcr::McrCodebooks,
    metadata::{DynamicMetadata, FrameMetadata, StaticMetadata},
    model::{HyperModel, NoiseState, SpectrumConfig},
    shaping::LsfCodebooks,
    side::{BedMode, ChannelBedFrame},
    spectral,
    synthesis::Synthesis,
};
use std::sync::Arc;

#[derive(Clone, Debug)]
pub struct PcmFrame {
    pub sample_rate: u32,
    pub channels: u16,
    /// Interleaved, nominal full scale +/-1; headroom is retained until conversion.
    pub samples: Vec<f32>,
    pub metadata: FrameMetadata,
}
impl PcmFrame {
    /// Round using floor(x+0.5), then saturate to signed 16-bit PCM.
    pub fn to_i16(&self) -> Vec<i16> {
        self.samples
            .iter()
            .map(|&v| (v * 32768.0 + 0.5).floor().clamp(-32768.0, 32767.0) as i16)
            .collect()
    }
}

#[derive(Clone, Debug)]
pub struct Decoder {
    model: Arc<HyperModel>,
    shaping: Arc<LsfCodebooks>,
    mcr: Option<Arc<McrCodebooks>>,
    hoa_basis: Option<Arc<HoaBasis>>,
    hoa_synthesis: Option<HoaSynthesis>,
    metadata: Option<Arc<DynamicMetadata>>,
    static_metadata: Option<Arc<StaticMetadata>>,
    configuration: Option<FrameHeader>,
    noise: NoiseState,
    synthesis: Vec<Synthesis>,
    frames: u64,
}
impl Decoder {
    pub fn new(model: Arc<HyperModel>, shaping: Arc<LsfCodebooks>) -> Self {
        Self {
            model,
            shaping,
            mcr: None,
            hoa_basis: None,
            hoa_synthesis: None,
            metadata: None,
            static_metadata: None,
            configuration: None,
            noise: NoiseState::default(),
            synthesis: Vec::new(),
            frames: 0,
        }
    }
    /// Supply external angle codebooks to enable low-rate MCR stereo.
    pub fn with_mcr(mut self, codebooks: Arc<McrCodebooks>) -> Self {
        self.mcr = Some(codebooks);
        self
    }
    /// Supply spatial basis coefficients for reduced-transport third-order HOA.
    pub fn with_hoa(mut self, basis: Arc<HoaBasis>) -> Self {
        self.hoa_basis = Some(basis);
        self
    }
    pub fn reset(&mut self) {
        self.reset_with_seed(1);
    }
    pub fn reset_with_seed(&mut self, seed: u32) {
        self.configuration = None;
        self.noise = NoiseState::seeded(seed);
        self.synthesis.clear();
        self.hoa_synthesis = None;
        self.metadata = None;
        self.static_metadata = None;
        self.frames = 0;
    }
    /// Most recent successfully decoded static definition; absent packets preserve it.
    pub fn static_metadata(&self) -> Option<&StaticMetadata> {
        self.static_metadata.as_deref()
    }
    /// Most recent dynamic block; optional fields describe that block, not merged updates.
    pub fn dynamic_metadata(&self) -> Option<&DynamicMetadata> {
        self.metadata.as_deref()
    }
    pub fn decoded_frames(&self) -> u64 {
        self.frames
    }

    /// Accept one exact packet, verify CRC and preserve all state on failure.
    /// Dynamic format changes require an explicit reset at a stream boundary.
    pub fn decode(&mut self, packet: &[u8]) -> Result<PcmFrame, Error> {
        let mut configuration = FrameHeader::validate_crc(packet)?;
        configuration.crc = 0;
        if self
            .configuration
            .as_ref()
            .is_some_and(|h| h != &configuration)
        {
            return Err(Error::Unsupported("decoder configuration change"));
        }
        if matches!(configuration.profile, Profile::Hoa { .. }) {
            return self.decode_hoa(packet, configuration);
        }
        let frame = ChannelBedFrame::parse(packet)?;
        let count = usize::from(frame.header.channels);
        let lfe = frame.has_lfe();
        let mut noise = self.noise;
        let mut spectra = Vec::with_capacity(count);
        for i in 0..frame.quantized.len() {
            spectra.push(self.model.decode_spectrum(
                &frame.quantized[i],
                &frame.groups[i],
                SpectrumConfig {
                    neural_type: frame.header.neural_type,
                    transform: frame.cores[i].transform,
                    noise_lines: frame.bwe.as_ref().map_or(1024, |b| b.start_line()),
                },
                &mut noise,
            )?);
        }
        let mut spectra = match &frame.mode {
            BedMode::Mono => spectra,
            BedMode::Mcr(side) => self
                .mcr
                .as_ref()
                .ok_or(Error::Unsupported("missing MCR codebooks"))?
                .reconstruct(&spectra[0], side)?,
            BedMode::Stereo { mid_side, .. } => spectral::inverse_stereo(spectra, *mid_side)?,
            BedMode::Multi(mode) => spectral::uncouple(spectra, mode, lfe)?,
            BedMode::Mixed { side, bed_channels } => {
                spectral::uncouple_mixed(spectra, side, *bed_channels, lfe)?
            }
        };
        let mut synthesis = if self.synthesis.is_empty() {
            vec![Synthesis::new(); count]
        } else {
            self.synthesis.clone()
        };
        let mut samples = vec![0.0; 1024 * count];
        for (i, (values, state)) in spectra.iter_mut().zip(&mut synthesis).enumerate() {
            let spectrum: &mut [f32; 1024] = values
                .as_mut_slice()
                .try_into()
                .map_err(|_| Error::Invalid("spectral shape"))?;
            if let Some(config) = &frame.bwe {
                config.apply(spectrum, &frame.bwe_side[i], &mut noise)?;
            }
            spectral::inverse_tns(spectrum, &frame.cores[i])?;
            self.shaping.apply(spectrum, &frame.cores[i].lsf_indices)?;
            if lfe && i == 3 {
                spectrum[32..].fill(0.0);
            }
            if frame.cores[i].transform == 1 {
                let source = *spectrum;
                for block in 0..8 {
                    for bin in 0..128 {
                        spectrum[block * 128 + bin] = source[bin * 8 + block];
                    }
                }
            }
            let pcm = state.process(spectrum, frame.cores[i].transform)?;
            for (line, value) in pcm.into_iter().enumerate() {
                samples[line * count + i] = value / 32768.0;
            }
        }
        let frames = self
            .frames
            .checked_add(1)
            .ok_or(Error::Invalid("decoded frame counter"))?;
        if let Some(value) = &frame.metadata.static_data {
            self.static_metadata = Some(value.clone());
        }
        if let Some(dynamic) = &frame.metadata.dynamic {
            self.metadata = Some(dynamic.clone());
        }
        self.configuration = Some(configuration);
        self.synthesis = synthesis;
        self.noise = noise;
        self.frames = frames;
        Ok(PcmFrame {
            sample_rate: frame.header.sample_rate,
            channels: frame.header.channels,
            samples,
            metadata: frame.metadata,
        })
    }
    fn decode_hoa(&mut self, packet: &[u8], configuration: FrameHeader) -> Result<PcmFrame, Error> {
        let frame = HoaFrame::parse(packet)?;
        if frame.config.spatial() && self.hoa_basis.is_none() {
            return Err(Error::Unsupported("missing HOA basis asset"));
        }
        let count = frame.config.transport_channels();
        let bwe = if frame.bwe_side.iter().any(Option::is_some) {
            Some(frame.config.bwe_config()?)
        } else {
            None
        };
        let mut noise = self.noise;
        let mut spectra = Vec::with_capacity(count);
        for i in 0..count {
            spectra.push(self.model.decode_spectrum(
                &frame.quantized[i],
                &frame.groups[i],
                SpectrumConfig {
                    neural_type: configuration.neural_type,
                    transform: frame.cores[i].transform,
                    noise_lines: if frame.bwe_side[i].is_some() {
                        bwe.as_ref().unwrap().start_line()
                    } else {
                        1024
                    },
                },
                &mut noise,
            )?);
        }
        let mut spectra = frame.side.inverse_mix(&frame.config, spectra)?;
        let mut synthesis = if self.synthesis.is_empty() {
            vec![Synthesis::new(); count]
        } else {
            self.synthesis.clone()
        };
        let mut intermediate = Vec::with_capacity(count);
        for (i, (values, state)) in spectra.iter_mut().zip(&mut synthesis).enumerate() {
            let spectrum: &mut [f32; 1024] = values
                .as_mut_slice()
                .try_into()
                .map_err(|_| Error::Invalid("HOA core shape"))?;
            if let Some(side) = &frame.bwe_side[i] {
                bwe.as_ref().unwrap().apply(spectrum, side, &mut noise)?;
            }
            spectral::inverse_tns(spectrum, &frame.cores[i])?;
            self.shaping.apply(spectrum, &frame.cores[i].lsf_indices)?;
            if frame.cores[i].transform == 1 {
                let source = *spectrum;
                for block in 0..8 {
                    for bin in 0..128 {
                        spectrum[block * 128 + bin] = source[bin * 8 + block];
                    }
                }
            }
            intermediate.push(state.process(spectrum, frame.cores[i].transform)?);
        }
        let mut hoa = self
            .hoa_synthesis
            .clone()
            .unwrap_or_else(|| HoaSynthesis::new(frame.config.clone()));
        let output = hoa.process(&intermediate, &frame.side, self.hoa_basis.as_deref())?;
        let channels = frame.config.output_channels();
        let mut samples = vec![0.0; channels * 1024];
        for (channel, values) in output.iter().enumerate() {
            for (line, &value) in values.iter().enumerate() {
                samples[line * channels + channel] = value / 32768.0;
            }
        }
        let frames = self
            .frames
            .checked_add(1)
            .ok_or(Error::Invalid("decoded frame counter"))?;
        if let Some(value) = &frame.metadata.static_data {
            self.static_metadata = Some(value.clone());
        }
        if let Some(dynamic) = &frame.metadata.dynamic {
            self.metadata = Some(dynamic.clone());
        }
        self.configuration = Some(configuration);
        self.noise = noise;
        self.synthesis = synthesis;
        self.hoa_synthesis = Some(hoa);
        self.frames = frames;
        Ok(PcmFrame {
            sample_rate: frame.header.sample_rate,
            channels: frame.header.channels,
            samples,
            metadata: frame.metadata,
        })
    }
}
