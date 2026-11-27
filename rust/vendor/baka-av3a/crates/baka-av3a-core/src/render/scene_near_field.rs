use super::{BedLayout, Channel, HoaDecoder, HoaNearField, NearFieldConfig};
use crate::{Error, metadata::AudioPack};

const BLOCK: usize = 1024;

/// Playback geometry for the phase-only HOA near-field policy. Each active
/// pack supplies its own reference radius; all speakers share this radius.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SceneNearFieldConfig {
    pub sample_rate: u32,
    pub speaker_distance: f64,
}
impl SceneNearFieldConfig {
    pub(super) fn validate(self) -> Result<(), Error> {
        NearFieldConfig {
            reference_distance: 1.0,
            speaker_distance: self.speaker_distance,
            sample_rate: self.sample_rate,
        }
        .phase_response(0, 0.0)?;
        Ok(())
    }
}

#[derive(Debug)]
pub(super) struct PackPlan {
    index: u8,
    channels: Vec<u8>,
    transports: Vec<u8>,
    decoder: HoaDecoder,
    config: NearFieldConfig,
    gains: Vec<f64>,
}
impl PackPlan {
    pub(super) fn new(
        pack: &AudioPack,
        output: BedLayout,
        playback: SceneNearFieldConfig,
    ) -> Result<Self, Error> {
        let config =
            NearFieldConfig::from_pack(pack, playback.speaker_distance, playback.sample_rate)?
                .ok_or(Error::Invalid("disabled scene near-field pack"))?;
        let mut parameters = pack
            .hoa
            .clone()
            .ok_or(Error::Invalid("missing HOA parameters"))?;
        parameters.nfc_distance = 0;
        let decoder = HoaDecoder::from_pack(&parameters, output)?;
        if pack.channels.len() != usize::from(decoder.input_channels()) {
            return Err(Error::Invalid("HOA pack component count"));
        }
        Ok(Self {
            index: pack.index,
            channels: pack.channels.iter().map(|p| p.0).collect(),
            transports: pack.transport_channels()?,
            gains: vec![0.0; pack.channels.len()],
            decoder,
            config,
        })
    }
    pub(super) fn add(&mut self, channel: u8, gain: f64) {
        let ordinal = self
            .channels
            .iter()
            .position(|&p| p == channel)
            .expect("resolved channel belongs to its pack");
        self.gains[ordinal] += gain;
    }
    fn prepare(self) -> Result<PackRenderer, Error> {
        let count = self.gains.len();
        let outputs = usize::from(self.decoder.output_layout().channels());
        let mut coefficients = self.decoder.coefficients().to_vec();
        for row in coefficients.chunks_exact_mut(count) {
            for (value, gain) in row.iter_mut().zip(&self.gains) {
                *value *= gain;
            }
        }
        if coefficients
            .iter()
            .any(|v| !v.is_finite() || v.abs() > 16_777_216.0)
        {
            return Err(Error::Invalid("scene near-field aggregate coefficient"));
        }
        Ok(PackRenderer {
            index: self.index,
            transports: self.transports,
            filter: Some(HoaNearField::new(self.decoder.order(), self.config)?),
            coefficients: coefficients.into_iter().map(|v| v as f32).collect(),
            input: vec![0.0; BLOCK * count],
            filtered: vec![0.0; BLOCK * count],
            delayed: vec![0.0; 2 * BLOCK * outputs],
            slot: 0,
            blocks: 0,
        })
    }
}

#[derive(Clone, Copy)]
pub(super) enum PcmBlock<'a> {
    Integer(&'a [i16]),
    Float(&'a [f32]),
    Silence,
}
impl PcmBlock<'_> {
    fn sample(self, index: usize) -> f32 {
        match self {
            Self::Integer(v) => f32::from(v[index]) / 32768.0,
            Self::Float(v) => v[index],
            Self::Silence => 0.0,
        }
    }
}

#[derive(Clone, Debug)]
struct PackRenderer {
    index: u8,
    transports: Vec<u8>,
    filter: Option<HoaNearField>,
    coefficients: Vec<f32>,
    input: Vec<f32>,
    filtered: Vec<f32>,
    delayed: Vec<f32>,
    slot: usize,
    blocks: u64,
}
impl PackRenderer {
    fn mix(
        &mut self,
        source: PcmBlock<'_>,
        physical: usize,
        output: &mut [f32],
        shared: Option<&Self>,
    ) {
        let count = self.transports.len();
        let outputs = output.len() / BLOCK;
        let filtered = if let Some(shared) = shared {
            debug_assert_eq!(shared.blocks, self.blocks.saturating_add(1));
            debug_assert!(self.filter.is_none());
            debug_assert_eq!(shared.filtered.len(), BLOCK * count);
            &shared.filtered
        } else {
            for frame in 0..BLOCK {
                // Apply the common startup envelope at source time, before FIR
                // convolution; it must not move 512 samples ahead of the source.
                let ramp = if self.blocks != 0 {
                    1.0
                } else {
                    frame as f32 / BLOCK as f32
                };
                for (acn, &transport) in self.transports.iter().enumerate() {
                    self.input[frame * count + acn] =
                        source.sample(frame * physical + usize::from(transport)) * ramp;
                }
            }
            self.filter
                .as_mut()
                .expect("nonshared pack owns its FIR history")
                .apply(&self.input, &mut self.filtered);
            &self.filtered
        };
        let start = self.slot * output.len();
        for (frame, input) in filtered.chunks_exact(count).enumerate() {
            for (speaker, coefficients) in self.coefficients.chunks_exact(count).enumerate() {
                let index = frame * outputs + speaker;
                output[index] += self.delayed[start + index];
                self.delayed[start + index] =
                    input.iter().zip(coefficients).map(|(x, g)| x * g).sum();
            }
        }
        self.slot ^= 1;
        self.blocks = self.blocks.saturating_add(1);
    }
    fn reset(&mut self) {
        if let Some(filter) = &mut self.filter {
            filter.reset();
        }
        self.input.fill(0.0);
        self.filtered.fill(0.0);
        self.delayed.fill(0.0);
        self.slot = 0;
        self.blocks = 0;
    }
}

/// Raw paths retain source-time object interpolation, then receive the common
/// 512-sample alignment. Filtered packs retain separate histories even when
/// they reuse a physical transport. Only the final output mix is limited.
#[derive(Clone, Debug)]
pub(super) struct SceneNearField {
    packs: Vec<PackRenderer>,
    raw_delay: Vec<f32>,
    position: usize,
    limiters: Vec<Channel>,
    pub(super) limiting: bool,
}
impl SceneNearField {
    // Construction only: immutable static routing guarantees these packs will
    // borrow the first bus's result for every frame, including silence/reset.
    // Release the unused duplicate filter histories and staging buffers now.
    pub(super) fn reuse_filters(&mut self, shared: &Self) {
        for pack in &mut self.packs {
            if let Some(cached) = shared.packs.iter().find(|p| p.index == pack.index) {
                debug_assert_eq!(pack.transports, cached.transports);
                debug_assert_eq!(
                    pack.filter.as_ref().unwrap().config(),
                    cached.filter.as_ref().unwrap().config()
                );
                pack.filter = None;
                pack.input = Vec::new();
                pack.filtered = Vec::new();
            }
        }
    }
    pub(super) fn new(plans: [Option<PackPlan>; 8], output: BedLayout) -> Result<Self, Error> {
        let packs = plans
            .into_iter()
            .flatten()
            .map(PackPlan::prepare)
            .collect::<Result<Vec<_>, _>>()?;
        let count = usize::from(output.channels());
        Ok(Self {
            packs,
            raw_delay: vec![0.0; HoaNearField::DELAY_SAMPLES * count],
            position: 0,
            limiters: vec![Channel::default(); count],
            limiting: true,
        })
    }
    pub(super) fn mix(
        &mut self,
        input: PcmBlock<'_>,
        physical: usize,
        output: &mut [f32],
        shared: Option<&Self>,
    ) {
        for sample in output.iter_mut() {
            std::mem::swap(sample, &mut self.raw_delay[self.position]);
            self.position = (self.position + 1) % self.raw_delay.len();
        }
        for pack in &mut self.packs {
            // A pack's source-time FIR is independent of static path gains or
            // head/world space. Reuse this frame's result across those buses.
            let cached = shared.and_then(|s| s.packs.iter().find(|p| p.index == pack.index));
            pack.mix(input, physical, output, cached);
        }
        if self.limiting {
            for frame in output.chunks_exact_mut(self.limiters.len()) {
                for (sample, limiter) in frame.iter_mut().zip(&mut self.limiters) {
                    *sample = limiter.process(*sample);
                }
            }
        }
    }
    pub(super) fn reset(&mut self) {
        for pack in &mut self.packs {
            pack.reset();
        }
        self.raw_delay.fill(0.0);
        self.position = 0;
        self.limiters.fill(Channel::default());
    }
}
