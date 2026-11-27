use super::{
    BedLayout, CartesianControls, CartesianObject, CartesianSpatialObject, ObjectRenderer,
    ObjectTarget, PolarControls, PolarObject, ScreenEdge, ScreenTransform, SpatialObject,
};
use crate::{
    Error, Profile,
    metadata::{DynamicMetadata, ObjectParameters, ObjectPosition},
};

const BLOCK: usize = 1024;

/// Frame-aligned dynamic metadata adapter with explicit transport bindings.
///
/// `references[i]` identifies PCM object channel `i` (after the bed). References
/// are five-bit wire identifiers, not array indices. Each transmitted block must
/// contain every bound reference exactly once, in any order. Missing whole blocks
/// hold the last targets. Missing polar fields use the caller's `defaults`;
/// Cartesian extent defaults to zero and gain/diffuse use the same defaults.
/// Values do not leak from a previous block. Muting changes gain to zero.
///
/// This adapter does not interpret static scene graphs or choose their defaults.
/// Polar and Cartesian positions, extent, speaker lock and frame jumps are applied.
/// Cartesian wire divergence has no transmitted position range, so its side
/// sources use the zero default. Angular range is never treated as displacement.
/// Active screen controls require new_with_screen.
/// Construct outside the audio callback; processing and reset do not allocate.
#[derive(Clone, Debug)]
pub struct DynamicObjectRenderer {
    renderer: ObjectRenderer,
    references: Vec<u8>,
    defaults: Vec<PolarObject>,
    current: Vec<ObjectTarget>,
    screen: Option<ScreenTransform>,
}

impl DynamicObjectRenderer {
    pub const DELAY_SAMPLES: usize = ObjectRenderer::DELAY_SAMPLES;

    pub fn new(
        profile: Profile,
        output: BedLayout,
        references: &[u8],
        defaults: &[PolarObject],
    ) -> Result<Self, Error> {
        if references.len() != defaults.len() || references.len() > 16 {
            return Err(Error::Invalid("dynamic transport binding count"));
        }
        let mut seen = 0u32;
        for &reference in references {
            if reference >= 32 || seen & (1 << reference) != 0 {
                return Err(Error::Invalid("dynamic transport binding"));
            }
            seen |= 1 << reference;
        }
        Ok(Self {
            renderer: ObjectRenderer::from_profile(profile, output, defaults)?,
            references: references.to_vec(),
            defaults: defaults.to_vec(),
            current: defaults.iter().copied().map(ObjectTarget::from).collect(),
            screen: None,
        })
    }

    /// Configure both reference and actual screen geometry before processing.
    pub fn new_with_screen(
        profile: Profile,
        output: BedLayout,
        references: &[u8],
        defaults: &[PolarObject],
        screen: ScreenTransform,
    ) -> Result<Self, Error> {
        let mut renderer = Self::new(profile, output, references, defaults)?;
        renderer.screen = Some(screen);
        Ok(renderer)
    }

    pub fn input_channels(&self) -> u16 {
        self.renderer.input_channels()
    }
    pub fn output_layout(&self) -> BedLayout {
        self.renderer.output_layout()
    }
    /// Current typed targets after metadata/screen mapping, before speaker lock.
    pub fn objects(&self) -> &[ObjectTarget] {
        &self.current
    }

    /// Apply one metadata block and exactly 1024 frames of interleaved PCM.
    /// Invalid metadata or lengths preserve all audio history, targets and output.
    /// Pass only dynamic metadata; resolve static object/channel gains and scene
    /// selection before constructing this adapter's defaults and reference map.
    pub fn process(
        &mut self,
        input: &[i16],
        metadata: Option<&DynamicMetadata>,
        output: &mut [f32],
    ) -> Result<(), Error> {
        if input.len() != BLOCK * usize::from(self.input_channels())
            || output.len() != BLOCK * usize::from(self.output_layout().channels())
        {
            return Err(Error::Invalid("dynamic renderer block length"));
        }
        if let Some(metadata) = metadata {
            let next = map_parameters(
                metadata,
                &self.references,
                &self.defaults,
                u16::MAX,
                self.screen.as_ref(),
                self.output_layout(),
            )?;
            self.renderer.set_targets_with_jump(
                &next.objects[..self.current.len()],
                &next.jumps[..self.current.len()],
            )?;
            for (current, next) in self.current.iter_mut().zip(next.objects) {
                *current = next;
            }
        }
        self.renderer.process(input, output)
    }

    /// Flush whole blocks without changing object targets.
    pub fn process_silence(&mut self, output: &mut [f32]) -> Result<(), Error> {
        if output.len() != BLOCK * usize::from(self.output_layout().channels()) {
            return Err(Error::Invalid("dynamic renderer block length"));
        }
        self.renderer.process_silence(BLOCK, output)
    }

    /// Restore caller-supplied initial targets and clear all queued audio.
    pub fn reset(&mut self) -> Result<(), Error> {
        self.renderer.set_objects(&self.defaults)?;
        self.renderer.reset();
        for (current, &default) in self.current.iter_mut().zip(&self.defaults) {
            *current = default.into();
        }
        Ok(())
    }
}

pub(super) struct ObjectUpdate {
    pub objects: [ObjectTarget; 16],
    pub jumps: [bool; 16],
}

pub(super) fn map_parameters(
    metadata: &DynamicMetadata,
    references: &[u8],
    defaults: &[PolarObject],
    active: u16,
    screen: Option<&ScreenTransform>,
    output: BedLayout,
) -> Result<ObjectUpdate, Error> {
    if metadata.level > 1 {
        return Err(Error::Unsupported("dynamic metadata level"));
    }
    if metadata.objects.len() != references.len() {
        return Err(Error::Invalid("dynamic metadata binding count"));
    }
    let mut next = [ObjectTarget::default(); 16];
    let mut jumps = [false; 16];
    let mut seen = 0u16;
    for object in &metadata.objects {
        let index = references
            .iter()
            .position(|&r| r == object.transport_channel)
            .ok_or(Error::Invalid("unbound dynamic transport reference"))?;
        if seen & (1 << index) != 0 {
            return Err(Error::Invalid("duplicate dynamic transport reference"));
        }
        seen |= 1 << index;
        next[index] = match &object.parameters {
            Some(parameters) => {
                validate(parameters)?;
                if active & (1 << index) != 0 {
                    jumps[index] = parameters.jump_position;
                    match parameters.position {
                        ObjectPosition::Spherical(_) => {
                            polar(parameters, defaults[index], screen)?.into()
                        }
                        ObjectPosition::Cartesian(_) => {
                            cartesian(parameters, defaults[index], screen, output)?.into()
                        }
                    }
                } else {
                    defaults[index].into()
                }
            }
            None => SpatialObject::from(PolarObject {
                gain: 0.0,
                ..defaults[index]
            })
            .into(),
        };
    }
    Ok(ObjectUpdate {
        objects: next,
        jumps,
    })
}

fn validate(parameters: &ObjectParameters) -> Result<(), Error> {
    let (position, zrange) = match &parameters.position {
        ObjectPosition::Spherical(position) => (position, 0..=15),
        ObjectPosition::Cartesian(position) => (position, -8..=7),
    };
    if !(-128..=127).contains(&position[0])
        || !(-32..=31).contains(&position[1])
        || !zrange.contains(&position[2])
        || parameters
            .extent
            .is_some_and(|v| v[0] > 127 || v[1] > 31 || v[2] > 15)
        || parameters.gain.is_some_and(|v| v > 127)
        || parameters.diffuse.is_some_and(|v| v > 127)
        || parameters.importance.is_some_and(|v| v > 10)
    {
        return Err(Error::Invalid("dynamic object quantized parameters"));
    }
    if let Some(controls) = &parameters.controls {
        use crate::metadata::ChannelLock;
        if matches!(controls.channel_lock, Some(ChannelLock::Within(v)) if v > 15)
            || controls
                .divergence
                .as_ref()
                .is_some_and(|v| v.amount > 15 || v.azimuth_range.is_some_and(|r| r > 63))
            || controls.screen_edge_lock.is_some_and(|v| v > 3)
        {
            return Err(Error::Invalid("dynamic object quantized controls"));
        }
    }
    Ok(())
}

fn polar(
    parameters: &ObjectParameters,
    mut value: PolarObject,
    screen: Option<&ScreenTransform>,
) -> Result<SpatialObject, Error> {
    if !matches!(parameters.position, ObjectPosition::Spherical(_)) {
        return Err(Error::Unsupported("Cartesian object rendering"));
    }
    let [azimuth, elevation, distance] = parameters.position.coordinates();
    value.azimuth = f64::from(azimuth);
    value.elevation = f64::from(elevation);
    value.distance = f64::from(distance);
    // Offset-binary elevation includes one code below the south pole. Reflect
    // through the pole to preserve its Cartesian direction instead of clipping.
    if value.elevation < -90.0 {
        value.elevation = -180.0 - value.elevation;
        value.azimuth += 180.0;
    }
    if let Some([width, height, depth]) = parameters.extent_values() {
        value.width = f64::from(width).min(360.0);
        value.height = f64::from(height).min(360.0);
        value.depth = f64::from(depth);
    }
    if let Some(gain) = parameters.linear_gain() {
        value.gain = f64::from(gain);
    }
    if let Some(diffuse) = parameters.diffuseness() {
        value.diffuse = f64::from(diffuse);
    }
    if let Some(controls) = &parameters.controls
        && (controls.screen_reference == Some(true) || controls.screen_edge_lock.is_some())
    {
        let screen = screen.ok_or(Error::Unsupported("missing object screen configuration"))?;
        let edge = controls
            .screen_edge_lock
            .map(ScreenEdge::try_from)
            .transpose()?;
        value = screen.apply(value, controls.screen_reference == Some(true), edge)?;
    }
    let mut controls = PolarControls::default();
    if let Some(input) = &parameters.controls {
        controls.channel_lock = input
            .channel_lock
            .as_ref()
            .and_then(|lock| lock.maximum_distance())
            .map(f64::from);
        if let Some(divergence) = &input.divergence {
            controls.divergence = f64::from(divergence.amount());
            controls.azimuth_range = f64::from(divergence.azimuth_degrees().unwrap_or(0.0));
        }
    }
    Ok(SpatialObject {
        object: value,
        controls,
    })
}

// Preserve wire values in metadata; room projection clamps offset-binary endpoint
// overshoot. Cartesian extents are X/Y/Z, not angular width/height/depth.
fn cartesian(
    parameters: &ObjectParameters,
    defaults: PolarObject,
    screen: Option<&ScreenTransform>,
    output: BedLayout,
) -> Result<CartesianSpatialObject, Error> {
    let mut controls = CartesianControls::default();
    if let Some(input) = &parameters.controls {
        // The bitstream supplies azimuthRange, not positionRange. Cartesian
        // divergence therefore keeps its specified amount with zero displacement.
        if let Some(divergence) = &input.divergence {
            controls.divergence = f64::from(divergence.amount());
        }
        controls.channel_lock = input
            .channel_lock
            .as_ref()
            .and_then(|v| v.maximum_distance())
            .map(f64::from);
    }
    let mut value = CartesianSpatialObject {
        object: CartesianObject {
            position: parameters
                .position
                .coordinates()
                .map(|v| f64::from(v).clamp(-1.0, 1.0)),
            size: parameters
                .extent_values()
                .unwrap_or([0.0; 3])
                .map(|v| f64::from(v).clamp(0.0, 1.0)),
            gain: parameters.linear_gain().map_or(defaults.gain, f64::from),
            diffuse: parameters.diffuseness().map_or(defaults.diffuse, f64::from),
        },
        controls,
    };
    if let Some(input) = &parameters.controls
        && (input.screen_reference == Some(true) || input.screen_edge_lock.is_some())
    {
        let screen = screen.ok_or(Error::Unsupported("missing object screen configuration"))?;
        let edge = input
            .screen_edge_lock
            .map(ScreenEdge::try_from)
            .transpose()?;
        value.object = screen.apply_cartesian(
            value.object,
            output,
            input.screen_reference == Some(true),
            edge,
        )?;
    }
    Ok(value)
}
