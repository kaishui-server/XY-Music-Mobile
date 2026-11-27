//! Channel-bed, polar/Cartesian object and projected-gain loudspeaker rendering.

mod acoustics;
mod bed;
mod binaural;
mod cartesian;
mod controls;
mod convolution;
mod dynamic;
mod early_room;
mod filter;
mod gain;
mod hoa;
mod hrir;
mod layouts;
mod material;
mod near_field;
mod object;
mod panner;
mod projector;
mod propagation;
mod room;
mod scene;
mod scene_near_field;
mod screen;
mod speaker_binaural;
mod target;
mod tracking;
pub use acoustics::{AcousticMaterial, AcousticPath, AcousticRoom, AcousticSurface};
pub use bed::BedRenderer;
pub use binaural::{BinauralRenderer, BinauralSource};
pub use cartesian::{
    CartesianControls, CartesianObject, CartesianProjector, CartesianSpatialObject,
};
pub use controls::{PolarControls, SpatialObject};
pub use dynamic::DynamicObjectRenderer;
pub use early_room::{EarlyRoomBinauralRenderer, EarlyRoomConfig};
pub use filter::DiffuseFilter;
pub use gain::{GainRenderer, ObjectGains};
pub use hoa::{HoaDecoder, HoaNormalization, HoaRenderer};
pub use hrir::{HrirBank, HrirMeasurement, HrirWeights};
pub use layouts::BedLayout;
pub use material::{AcousticBandLayout, FilteredPropagationRenderer, MaterialFilter, MaterialFir};
pub use near_field::{HoaNearField, NearFieldConfig, NearFieldHoaRenderer};
pub use object::ObjectRenderer;
pub use projector::{ObjectProjector, PolarObject};
pub use propagation::{PropagationRenderer, PropagationTarget};
pub use scene::{SceneRenderConfig, SceneRenderer};
pub use scene_near_field::SceneNearFieldConfig;
pub use screen::{ScreenEdge, ScreenEdges, ScreenTransform};
pub use speaker_binaural::{
    BinauralLfe, BinauralSceneConfig, HoaBinauralRenderer, SceneBinauralRenderer,
    SpeakerBinauralRenderer,
};
pub use target::ObjectTarget;
pub use tracking::{
    HeadOrientation, ListenerPose, SourceSpace, TrackedBinauralRenderer, TrackedSource,
};

use crate::Error;

const RING_LENGTH: usize = 100;
const SMOOTHING: f32 = f32::from_bits(0x3a83_126f);
const RELEASE: f32 = f32::from_bits(0x3f7f_f972);
const THRESHOLD: f32 = f32::from_bits(0x3f7f_f972);

#[derive(Clone, Debug)]
struct Channel {
    ring: [f32; RING_LENGTH],
    index: usize,
    peak: f32,
    gain: f32,
}

impl Default for Channel {
    fn default() -> Self {
        Self {
            ring: [0.0; RING_LENGTH],
            index: 0,
            peak: 0.0,
            gain: 1.0,
        }
    }
}

impl Channel {
    fn process(&mut self, input: f32) -> f32 {
        self.ring[self.index] = input;
        let decayed = self.peak * RELEASE;
        self.peak = if input.abs() < decayed {
            decayed
        } else {
            input.abs()
        };
        let target = if self.peak > THRESHOLD {
            THRESHOLD / self.peak
        } else {
            1.0
        };
        let previous = self.gain * SMOOTHING;
        let next = target * (1.0 - SMOOTHING);
        self.gain = previous + next;
        self.index = (self.index + 1) % RING_LENGTH;
        self.ring[self.index] * self.gain
    }
}

/// Independent per-channel look-ahead limiting for normalized interleaved f32 PCM.
///
/// The first 99 samples per channel are silence. To retrieve the pending tail,
/// process another 99 zero samples per channel. Reset on stream discontinuities;
/// keep this instance between successive blocks. This primitive does not mix
/// channels, render objects, or provide a hard clipping guarantee.
#[derive(Clone, Debug)]
pub struct LookAheadLimiter {
    channels: Vec<Channel>,
}

impl LookAheadLimiter {
    /// Delay of this primitive, in samples per channel, independent of sample rate.
    pub const DELAY_SAMPLES: usize = RING_LENGTH - 1;

    /// Allocate bounded state for 1 through 16 channels.
    pub fn new(channels: u16) -> Result<Self, Error> {
        if !(1..=16).contains(&channels) {
            return Err(Error::Invalid("limiter channel count"));
        }
        Ok(Self {
            channels: vec![Channel::default(); usize::from(channels)],
        })
    }

    pub fn channels(&self) -> u16 {
        self.channels.len() as u16
    }

    /// Clear pending audio, peak tracking, and gain history without allocating.
    pub fn reset(&mut self) {
        self.channels.fill(Channel::default());
    }

    /// Process complete interleaved frames in place without allocating.
    ///
    /// Rejects incomplete frames and non-finite samples before changing either
    /// the input or internal state. Finite values outside `[-1, 1]` are allowed.
    pub fn process(&mut self, samples: &mut [f32]) -> Result<(), Error> {
        if !samples.len().is_multiple_of(self.channels.len()) {
            return Err(Error::Invalid("limiter interleaved frame length"));
        }
        if samples.iter().any(|sample| !sample.is_finite()) {
            return Err(Error::Invalid("limiter non-finite sample"));
        }
        for frame in samples.chunks_exact_mut(self.channels.len()) {
            for (sample, channel) in frame.iter_mut().zip(&mut self.channels) {
                *sample = channel.process(*sample);
            }
        }
        Ok(())
    }
}
