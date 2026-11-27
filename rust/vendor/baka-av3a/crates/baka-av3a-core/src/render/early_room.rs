use super::{
    AcousticBandLayout, AcousticRoom, BinauralRenderer, BinauralSource,
    FilteredPropagationRenderer, HrirBank, ListenerPose, MaterialFir, PropagationTarget,
    binaural::MAX_BUS_SOURCES,
};
use crate::Error;

const BLOCK: usize = 1024;
type Point = [f64; 3];

/// Explicit first-order specular room policy. Distances are metres. Direct and
/// early gain are linear `[0,1]`; reference/minimum must not exceed16, bounding
/// the pressure entering each propagation tap. No late reverb is implied.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EarlyRoomConfig {
    pub maximum_delay_seconds: f64,
    pub speed_of_sound: f64,
    pub reference_distance: f64,
    pub minimum_distance: f64,
    pub direct_gain: f64,
    pub early_gain: f64,
}
impl EarlyRoomConfig {
    fn validate(self) -> Result<(), Error> {
        if !self.maximum_delay_seconds.is_finite()
            || !(0. < self.maximum_delay_seconds && self.maximum_delay_seconds <= 2.)
            || !self.speed_of_sound.is_finite()
            || !(250.0..=400.).contains(&self.speed_of_sound)
            || [self.reference_distance, self.minimum_distance]
                .iter()
                .any(|v| !v.is_finite() || !(0.001..=1000.).contains(v))
            || self.reference_distance / self.minimum_distance > 16.
            || [self.direct_gain, self.early_gain]
                .iter()
                .any(|v| !v.is_finite() || !(0.0..=1.).contains(v))
        {
            return Err(Error::Invalid("early room propagation policy"));
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
struct Source {
    images: [Point; 9],
    propagation: FilteredPropagationRenderer,
}

/// Fixed world point sources in a static finite-surface room, with listener
/// rotation/translation, distance gain, first reflections, spectral materials,
/// fractional propagation and measured HRIRs. One final stereo limiter.
///
/// Listener updates are block snapshots: future emissions use the new path
/// length/visibility, old emissions retain their scheduled arrival time. HRIR
/// direction uses the current pose and each fixed world image. This is not a
/// continuous-velocity/retarded-time or Doppler solver. Sources and room are
/// immutable until a new renderer is prepared outside the callback.
#[derive(Clone, Debug)]
pub struct EarlyRoomBinauralRenderer {
    room: AcousticRoom,
    config: EarlyRoomConfig,
    positions: Vec<Point>,
    sources: Vec<Source>,
    listener: ListenerPose,
    sample_rate: u32,
    paths: usize,
    input: [f32; BLOCK],
    bus: Vec<f32>,
    hrir_bus: Vec<f32>,
    binaural: BinauralRenderer,
    started: bool,
}
impl EarlyRoomBinauralRenderer {
    /// Constant material+limiter alignment, excluding propagation and ear taps.
    pub const ALIGNMENT_SAMPLES: usize =
        MaterialFir::DELAY_SAMPLES + BinauralRenderer::DELAY_SAMPLES;
    pub fn new(
        room: AcousticRoom,
        bands: &AcousticBandLayout,
        bank: HrirBank,
        positions: &[Point],
        listener: ListenerPose,
        config: EarlyRoomConfig,
    ) -> Result<Self, Error> {
        config.validate()?;
        if !(1..=16).contains(&positions.len()) || bands.sample_rate() != bank.sample_rate() {
            return Err(Error::Invalid("early room source count or sample rate"));
        }
        let sample_rate = bank.sample_rate();
        let paths = room.surfaces().len() + 1;
        // Validate every geometric plan before allocating source delay rings.
        let mut plans = [Plan::default(); 16];
        let mut images = [[[0.; 3]; 9]; 16];
        for (index, &position) in positions.iter().enumerate() {
            images[index] = room.images(position)?;
            plans[index] = plan(
                &room,
                position,
                &images[index],
                listener,
                sample_rate,
                config,
            )?;
        }
        let mut filters = Vec::with_capacity(paths);
        filters.push(MaterialFir::new(bands, [1.; 8])?);
        for surface in room.surfaces() {
            filters.push(MaterialFir::new(
                bands,
                surface.material().specular_pressure(),
            )?);
        }
        let mut sources = Vec::with_capacity(positions.len());
        let mut directions = [BinauralSource::default(); MAX_BUS_SOURCES];
        for index in 0..positions.len() {
            let propagation = FilteredPropagationRenderer::new(
                sample_rate,
                config.maximum_delay_seconds,
                &plans[index].propagation[..paths],
                &filters,
            )?;
            directions[index * paths..(index + 1) * paths]
                .copy_from_slice(&plans[index].directions[..paths]);
            sources.push(Source {
                images: images[index],
                propagation,
            });
        }
        let total = paths * positions.len();
        let mut binaural = BinauralRenderer::new_bus(bank, sample_rate, &directions[..total])?;
        binaural.set_sources(&directions[..total], &[true; MAX_BUS_SOURCES][..total])?;
        Ok(Self {
            room,
            config,
            positions: positions.to_vec(),
            sources,
            listener,
            sample_rate,
            paths,
            input: [0.; BLOCK],
            bus: vec![0.; BLOCK * paths],
            hrir_bus: vec![0.; BLOCK * total],
            binaural,
            started: false,
        })
    }
    pub fn source_positions(&self) -> &[Point] {
        &self.positions
    }
    pub fn room(&self) -> &AcousticRoom {
        &self.room
    }
    pub fn listener(&self) -> ListenerPose {
        self.listener
    }
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }
    pub fn paths_per_source(&self) -> usize {
        self.paths
    }
    /// Conservative maximum from last source sample through propagation,
    /// material, both-ear IR and the single limiter, including prior emissions.
    pub fn tail_samples(&self) -> usize {
        self.sources[0].propagation.tail_samples() + self.binaural.tail_samples()
    }
    /// Block-boundary update. Every source/path/HRIR validates before any live
    /// targets commit. Occluded paths stop future emissions but keep old tails;
    /// their fixed world image still follows current head pose at arrival.
    pub fn set_listener(&mut self, listener: ListenerPose, jump: bool) -> Result<(), Error> {
        let mut plans = [Plan::default(); 16];
        let mut directions = [BinauralSource::default(); MAX_BUS_SOURCES];
        let jumps = [jump || !self.started; MAX_BUS_SOURCES];
        for (index, source) in self.sources.iter().enumerate() {
            plans[index] = plan(
                &self.room,
                self.positions[index],
                &source.images,
                listener,
                self.sample_rate,
                self.config,
            )?;
            directions[index * self.paths..(index + 1) * self.paths]
                .copy_from_slice(&plans[index].directions[..self.paths]);
        }
        let total = self.sources.len() * self.paths;
        let update = self
            .binaural
            .prepare_update(&directions[..total], &jumps[..total])?;
        for (index, source) in self.sources.iter_mut().enumerate() {
            source
                .propagation
                .set_targets(
                    &plans[index].propagation[..self.paths],
                    &jumps[..self.paths],
                )
                .expect("complete early-room plans have bounded propagation targets");
        }
        self.binaural.commit_update(update);
        self.listener = listener;
        Ok(())
    }
    /// Exactly1024 interleaved source frames to2048 stereo f32 samples. Finite
    /// input magnitude<=256; validation failures preserve output and all state.
    pub fn process(&mut self, input: &[f32], output: &mut [f32]) -> Result<(), Error> {
        self.validate_output(output)?;
        if input.len() != BLOCK * self.sources.len()
            || input.iter().any(|v| !v.is_finite() || v.abs() > 256.)
        {
            return Err(Error::Invalid("early room source PCM"));
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
        if output.len() != BLOCK * 2 {
            return Err(Error::Invalid("early room stereo output length"));
        }
        Ok(())
    }
    fn apply(&mut self, input: Option<&[f32]>, output: &mut [f32]) {
        let count = self.sources.len();
        let total = count * self.paths;
        for (index, source) in self.sources.iter_mut().enumerate() {
            for (frame, target) in self.input.iter_mut().enumerate() {
                *target = input.map_or(0., |v| v[frame * count + index]);
            }
            source
                .propagation
                .process(&self.input, &mut self.bus)
                .expect("validated source block");
            for (frame, paths) in self.bus.chunks_exact(self.paths).enumerate() {
                let start = frame * total + index * self.paths;
                self.hrir_bus[start..start + self.paths].copy_from_slice(paths);
            }
        }
        self.binaural.process_prefiltered(&self.hrir_bus, output);
        self.started = true;
    }
    /// Clear all audio histories, retaining current listener and emission targets.
    pub fn reset(&mut self) {
        for source in &mut self.sources {
            source.propagation.reset();
        }
        self.binaural.reset();
        let total = self.paths * self.sources.len();
        let mut targets = [BinauralSource::default(); MAX_BUS_SOURCES];
        targets[..total].copy_from_slice(self.binaural.sources());
        self.binaural
            .set_sources(&targets[..total], &[true; MAX_BUS_SOURCES][..total])
            .expect("retained room directions");
        self.input.fill(0.);
        self.bus.fill(0.);
        self.hrir_bus.fill(0.);
        self.started = false;
    }
}

#[derive(Clone, Copy)]
struct Plan {
    propagation: [PropagationTarget; 9],
    directions: [BinauralSource; 9],
}
impl Default for Plan {
    fn default() -> Self {
        Self {
            propagation: [PropagationTarget {
                delay_samples: 0.,
                gain: 0.,
            }; 9],
            directions: [BinauralSource::default(); 9],
        }
    }
}
fn plan(
    room: &AcousticRoom,
    source: Point,
    images: &[Point; 9],
    listener: ListenerPose,
    rate: u32,
    config: EarlyRoomConfig,
) -> Result<Plan, Error> {
    let paths = room.paths(source, listener.position())?;
    let mut result = Plan::default();
    for index in 0..room.surfaces().len() + 1 {
        let [x, y, z] = listener.relative_position(images[index])?;
        result.directions[index] = BinauralSource {
            azimuth: if x == 0. && y == 0. {
                0.
            } else {
                (-x).atan2(y).to_degrees()
            },
            elevation: z.atan2(x.hypot(y)).to_degrees(),
            gain: 1.,
        };
        if let Some(path) = paths[index] {
            let delay = path.delay_samples(rate, config.speed_of_sound)?;
            if delay > config.maximum_delay_seconds * f64::from(rate) {
                return Err(Error::Invalid("early room path exceeds delay budget"));
            }
            let gain = config.reference_distance
                / path.distance_metres().max(config.minimum_distance)
                * if index == 0 {
                    config.direct_gain
                } else {
                    config.early_gain
                };
            result.propagation[index] = PropagationTarget {
                delay_samples: delay,
                gain: gain as f32,
            };
        }
    }
    Ok(result)
}
