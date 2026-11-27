use super::{
    BedLayout, CartesianProjector, GainRenderer, ObjectGains, ObjectProjector, ObjectTarget,
    PolarObject, SpatialObject,
};
use crate::{Error, Profile};

/// Polar/Cartesian object and optional channel-bed loudspeaker renderer.
///
/// Projects position, width, height, depth, gain and diffuseness, then applies
/// gain interpolation, independent direct/diffuse timing, convolution and
/// limiting. Input channels are the bed followed by the objects in array order.
/// This API does not implicitly interpret transport references or scene metadata.
#[derive(Clone, Debug)]
pub struct ObjectRenderer {
    projector: ObjectProjector,
    cartesian: CartesianProjector,
    gains: Vec<ObjectGains>,
    cached_parameters: Vec<ObjectTarget>,
    renderer: GainRenderer,
}

impl ObjectRenderer {
    pub const DELAY_SAMPLES: usize = GainRenderer::DELAY_SAMPLES;
    pub const DIFFUSE_DELAY_SAMPLES: usize = GainRenderer::DIFFUSE_DELAY_SAMPLES;

    /// Check the decoded profile's bed layout and exact object count.
    /// Objects must already be ordered by their decoded transport channels.
    pub fn from_profile(
        profile: Profile,
        output: BedLayout,
        objects: &[PolarObject],
    ) -> Result<Self, Error> {
        let (bed, count) = match profile {
            Profile::ChannelBed { configuration } => {
                (Some(BedLayout::from_configuration(configuration)?), 0)
            }
            Profile::BedObjects {
                configuration,
                objects,
            } => (
                Some(BedLayout::from_configuration(configuration)?),
                usize::from(objects),
            ),
            Profile::Objects { count } => (None, usize::from(count)),
            Profile::Hoa { .. } => return Err(Error::Unsupported("HOA loudspeaker rendering")),
        };
        if objects.len() != count {
            return Err(Error::Invalid("profile object count"));
        }
        Self::new(bed, output, objects)
    }

    pub fn new(
        bed: Option<BedLayout>,
        output: BedLayout,
        objects: &[PolarObject],
    ) -> Result<Self, Error> {
        if objects.len() > 16 {
            return Err(Error::Invalid("renderer input channel count"));
        }
        let count = bed.map_or(0, |l| usize::from(l.channels())) + objects.len();
        if count == 0 || count > 16 {
            return Err(Error::Invalid("renderer input channel count"));
        }
        let projector = ObjectProjector::new(output)?;
        let gains: Vec<_> = objects
            .iter()
            .map(|&o| projector.project(o))
            .collect::<Result<_, _>>()?;
        let renderer = GainRenderer::new(bed, output, &gains)?;
        Ok(Self {
            projector,
            cartesian: CartesianProjector::new(output),
            gains,
            cached_parameters: objects.iter().copied().map(ObjectTarget::from).collect(),
            renderer,
        })
    }

    pub fn input_channels(&self) -> u16 {
        self.renderer.input_channels()
    }
    pub fn output_layout(&self) -> BedLayout {
        self.renderer.output_layout()
    }
    pub fn object_count(&self) -> usize {
        self.renderer.object_count()
    }

    /// Prepare the next input block's targets without allocating or mutating
    /// active targets on error. Call at 1024-sample boundaries for frame updates.
    pub fn set_objects(&mut self, objects: &[PolarObject]) -> Result<(), Error> {
        if objects.len() > 16 {
            return Err(Error::Invalid("object count change"));
        }
        let mut next = [SpatialObject::default(); 16];
        for (next, &object) in next.iter_mut().zip(objects) {
            *next = object.into();
        }
        self.set_controlled_objects(&next[..objects.len()])
    }

    /// Update polar objects including speaker lock and divergence controls.
    /// Changing controls alone invalidates the projection cache.
    pub fn set_controlled_objects(&mut self, objects: &[SpatialObject]) -> Result<(), Error> {
        let mut targets = [ObjectTarget::default(); 16];
        if objects.len() > 16 {
            return Err(Error::Invalid("object count change"));
        }
        for (target, &object) in targets.iter_mut().zip(objects) {
            *target = object.into();
        }
        self.prepare(&targets[..objects.len()])?;
        self.renderer.set_objects(&self.gains)
    }

    /// Frame-aligned update with a one-block jump flag per object. A jump
    /// switches gains at the first sample without clearing delayed audio.
    pub fn set_controlled_objects_with_jump(
        &mut self,
        objects: &[SpatialObject],
        jumps: &[bool],
    ) -> Result<(), Error> {
        if !self.renderer.at_block_boundary() || jumps.len() != self.gains.len() {
            return Err(Error::Invalid("object jump boundary or count"));
        }
        let mut targets = [ObjectTarget::default(); 16];
        if objects.len() > 16 {
            return Err(Error::Invalid("object count change"));
        }
        for (target, &object) in targets.iter_mut().zip(objects) {
            *target = object.into();
        }
        self.prepare(&targets[..objects.len()])?;
        self.renderer.set_objects_with_jump(&self.gains, jumps)
    }

    /// Update mixed polar and Cartesian targets at a complete input-block boundary.
    pub fn set_targets_with_jump(
        &mut self,
        objects: &[ObjectTarget],
        jumps: &[bool],
    ) -> Result<(), Error> {
        if !self.renderer.at_block_boundary() || jumps.len() != self.gains.len() {
            return Err(Error::Invalid("object jump boundary or count"));
        }
        self.prepare(objects)?;
        self.renderer.set_objects_with_jump(&self.gains, jumps)
    }

    fn prepare(&mut self, objects: &[ObjectTarget]) -> Result<(), Error> {
        if objects.len() != self.gains.len() {
            return Err(Error::Invalid("object count change"));
        }
        for ((&object, cached), gains) in objects
            .iter()
            .zip(&mut self.cached_parameters)
            .zip(&mut self.gains)
        {
            if object != *cached {
                match object {
                    ObjectTarget::Polar(object) => {
                        self.projector.project_controlled_into(object, gains)?
                    }
                    ObjectTarget::Cartesian(object) => {
                        self.cartesian.project_controlled_into(object, gains)?
                    }
                }
                *cached = object;
            }
        }
        Ok(())
    }

    pub fn reset(&mut self) {
        self.renderer.reset();
    }
    pub fn process(&mut self, input: &[i16], output: &mut [f32]) -> Result<(), Error> {
        self.renderer.process(input, output)
    }
    pub fn process_silence(&mut self, frames: usize, output: &mut [f32]) -> Result<(), Error> {
        self.renderer.process_silence(frames, output)
    }
}
