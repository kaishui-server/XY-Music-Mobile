use super::{
    BedLayout, CartesianProjector, GainRenderer, HoaDecoder, ObjectGains, ObjectProjector,
    ObjectTarget, PolarObject, SceneNearFieldConfig, ScreenEdges, ScreenTransform,
    dynamic::{ObjectUpdate, map_parameters},
    scene_near_field::{PackPlan, PcmBlock, SceneNearField},
};
use crate::{
    Error,
    metadata::{DynamicMetadata, StaticMetadata},
};

const BLOCK: usize = 1024;

#[derive(Clone, Copy, Debug)]
pub struct SceneRenderConfig {
    pub output: BedLayout,
    pub reproduction_screen: Option<ScreenEdges>,
    pub near_field: Option<SceneNearFieldConfig>,
}

/// Fixed static scene with frame-aligned polar/Cartesian object updates and speaker PCM.
///
/// Input is in physical transport order; shared object paths are summed into
/// each physical input's speaker coefficients before DSP. Static gains multiply
/// dynamic gains, and static muting cannot be undone by a dynamic update.
/// Uses forward, unit-distance point objects before the first dynamic block;
/// omitted polar fields use those defaults; omitted Cartesian extent is zero.
///
/// Supports polar/Cartesian Objects packs with speaker lock/divergence and predefined DirectSpeakers pack IDs
/// 2, 3, 4, 5, 15 and 23, plus complete ACN/SN3D HOA packs through order 3.
/// Matrix, binaural, custom speaker packs, VR and
/// selected head-locked objects are rejected. Loudness normalization, ducking
/// and user interaction are not applied. Nonzero HOA near-field distance needs
/// explicit playback configuration; HOA screen reference remains unsupported.
/// Rebuild on static scene changes.
/// Cartesian wire divergence uses the absent position range's zero default.
#[derive(Clone, Debug)]
pub struct SceneRenderer {
    renderer: GainRenderer,
    projector: ObjectProjector,
    cartesian: CartesianProjector,
    base: Vec<ObjectGains>,
    targets: Vec<ObjectGains>,
    factors: [f64; 16],
    references: Vec<u8>,
    defaults: Vec<PolarObject>,
    current: Vec<ObjectTarget>,
    cached: Vec<ObjectTarget>,
    projected: Vec<ObjectGains>,
    active: u16,
    screen: Option<ScreenTransform>,
    started: bool,
    jump_starts: Vec<ObjectGains>,
    near_field: Option<SceneNearField>,
}

impl SceneRenderer {
    /// Baseline latency without configured NFC; use delay_samples() per instance.
    pub const DELAY_SAMPLES: usize = GainRenderer::DELAY_SAMPLES;

    /// Prepare bounded geometry, filters and buffers outside the audio callback.
    /// `selected_objects` has the same exact-set semantics as `resolve_scene`.
    /// At most 16 physical PCM inputs, regardless of the number of graph paths.
    pub fn new(
        metadata: &StaticMetadata,
        physical_channels: u16,
        output: BedLayout,
        selected_objects: Option<&[u8]>,
    ) -> Result<Self, Error> {
        Self::new_configured(
            metadata,
            physical_channels,
            selected_objects,
            SceneRenderConfig {
                output,
                reproduction_screen: None,
                near_field: None,
            },
        )
    }

    /// Prepare optional screen geometry and per-pack phase-only HOA correction.
    /// Any active corrected pack aligns all other scene paths by 512 samples.
    pub fn new_configured(
        metadata: &StaticMetadata,
        physical_channels: u16,
        selected_objects: Option<&[u8]>,
        config: SceneRenderConfig,
    ) -> Result<Self, Error> {
        Self::new_for_space(metadata, physical_channels, selected_objects, config, None)
    }

    // Internal scene buses can select one coordinate space without changing
    // static selection or the complete dynamic transport binding contract.
    pub(super) fn new_for_space(
        metadata: &StaticMetadata,
        physical_channels: u16,
        selected_objects: Option<&[u8]>,
        config: SceneRenderConfig,
        head_locked: Option<bool>,
    ) -> Result<Self, Error> {
        let output = config.output;
        if let Some(near_field) = config.near_field {
            near_field.validate()?;
        }
        if !(1..=16).contains(&physical_channels) {
            return Err(Error::Invalid("scene renderer input channel count"));
        }
        if metadata.vr.is_some() {
            return Err(Error::Unsupported("VR scene rendering"));
        }
        let scene = metadata.resolve_scene(physical_channels, selected_objects)?;
        let inputs = usize::from(physical_channels);
        let outputs = usize::from(output.channels());
        let mut coefficients = [0.0f64; 192];
        let mut factors = [0.0f64; 16];
        let mut hoa: [Option<HoaDecoder>; 8] = std::array::from_fn(|_| None);
        let mut near_plans: [Option<PackPlan>; 8] = std::array::from_fn(|_| None);
        for path in scene.channels() {
            if head_locked.is_some_and(|space| path.head_locked != space) {
                continue;
            }
            if head_locked.is_none() && path.head_locked {
                return Err(Error::Unsupported("head-locked scene objects"));
            }
            let input = usize::from(path.transport_channel);
            match path.type_label {
                1 => {
                    let pack = metadata
                        .packs
                        .iter()
                        .find(|p| p.index == path.pack_index)
                        .unwrap();
                    let layout = pack_layout(pack.format_id)?;
                    if pack.channels.len() != usize::from(layout.channels()) {
                        return Err(Error::Invalid("direct speaker pack channel count"));
                    }
                    let ordinal = pack
                        .channels
                        .iter()
                        .position(|p| p.0 == path.channel_index)
                        .unwrap();
                    let gains = layout.gains_to(output);
                    for speaker in 0..outputs {
                        coefficients[input * outputs + speaker] += path.gain
                            * f64::from(super::layouts::gain(gains[ordinal * outputs + speaker]));
                    }
                }
                3 => factors[input] += path.gain,
                4 => {
                    let pack = metadata
                        .packs
                        .iter()
                        .find(|p| p.index == path.pack_index)
                        .unwrap();
                    let parameters = pack
                        .hoa
                        .as_ref()
                        .ok_or(Error::Invalid("missing HOA pack parameters"))?;
                    if parameters.nfc_distance != 0
                        && let Some(playback) = config.near_field
                    {
                        let slot = &mut near_plans[usize::from(pack.index)];
                        if slot.is_none() {
                            *slot = Some(PackPlan::new(pack, output, playback)?);
                        }
                        slot.as_mut().unwrap().add(path.channel_index, path.gain);
                        continue;
                    }
                    let slot = &mut hoa[usize::from(pack.index)];
                    if slot.is_none() {
                        let parameters = pack
                            .hoa
                            .as_ref()
                            .ok_or(Error::Invalid("missing HOA pack parameters"))?;
                        let decoder = HoaDecoder::from_pack(parameters, output)?;
                        if pack.channels.len() != usize::from(decoder.input_channels()) {
                            return Err(Error::Invalid("HOA pack component count"));
                        }
                        *slot = Some(decoder);
                    }
                    let decoder = slot.as_ref().unwrap();
                    let ordinal = pack
                        .channels
                        .iter()
                        .position(|p| p.0 == path.channel_index)
                        .unwrap();
                    let inputs = usize::from(decoder.input_channels());
                    for speaker in 0..outputs {
                        coefficients[input * outputs + speaker] +=
                            path.gain * decoder.coefficients()[speaker * inputs + ordinal];
                    }
                }
                _ => return Err(Error::Unsupported("scene pack rendering type")),
            }
        }
        // Include inactive object transports: a dynamic block still describes
        // all encoded objects after programme selection, including muted paths.
        let mut object_transports = [false; 16];
        for pack in metadata.packs.iter().filter(|p| p.type_label == 3) {
            for reference in pack.transport_channels()? {
                object_transports[usize::from(reference)] = true;
            }
        }
        let references: Vec<u8> = object_transports
            .iter()
            .enumerate()
            .filter_map(|(i, &used)| used.then_some(i as u8))
            .collect();
        let active = references.iter().enumerate().fold(0, |mask, (i, &r)| {
            mask | if factors[usize::from(r)] != 0.0 {
                1 << i
            } else {
                0
            }
        });
        let defaults = vec![PolarObject::default(); references.len()];
        let base: Vec<_> = (0..inputs)
            .map(|input| ObjectGains {
                direct: coefficients[input * outputs..(input + 1) * outputs]
                    .iter()
                    .map(|&v| v as f32)
                    .collect(),
                diffuse: vec![0.0; outputs],
            })
            .collect();
        let projector = ObjectProjector::new(output)?;
        let projected: Vec<_> = defaults
            .iter()
            .map(|&p| projector.project(p))
            .collect::<Result<_, _>>()?;
        let targets = base.clone();
        let jump_starts = base
            .iter()
            .map(|g| ObjectGains {
                direct: vec![0.0; g.direct.len()],
                diffuse: vec![0.0; g.diffuse.len()],
            })
            .collect();
        let mut renderer = GainRenderer::new(None, output, &targets)?;
        let near_field = if near_plans.iter().any(Option::is_some) {
            renderer.disable_limiter();
            Some(SceneNearField::new(near_plans, output)?)
        } else {
            None
        };
        let mut result = Self {
            renderer,
            projector,
            cartesian: CartesianProjector::new(output),
            base,
            targets,
            factors,
            references,
            current: defaults.iter().copied().map(ObjectTarget::from).collect(),
            cached: defaults.iter().copied().map(ObjectTarget::from).collect(),
            defaults,
            projected,
            active,
            screen: None,
            started: false,
            jump_starts,
            near_field,
        };
        let initial = [ObjectTarget::default(); 16];
        result.prepare(&initial[..result.references.len()], None)?;
        if let Some(reproduction) = config.reproduction_screen {
            result.configure_screen(metadata, reproduction)?;
        }
        Ok(result)
    }

    /// Configure an actual reproduction screen. The programme's reference
    /// screen is decoded when present; otherwise the default reference is used.
    /// Reserved or degenerate reference screen values are rejected explicitly.
    pub fn new_with_screen(
        metadata: &StaticMetadata,
        physical_channels: u16,
        output: BedLayout,
        selected_objects: Option<&[u8]>,
        reproduction: ScreenEdges,
    ) -> Result<Self, Error> {
        Self::new_configured(
            metadata,
            physical_channels,
            selected_objects,
            SceneRenderConfig {
                output,
                reproduction_screen: Some(reproduction),
                near_field: None,
            },
        )
    }
    fn configure_screen(
        &mut self,
        metadata: &StaticMetadata,
        reproduction: ScreenEdges,
    ) -> Result<(), Error> {
        let reference = metadata
            .programme
            .screen
            .as_ref()
            .map(ScreenEdges::from_metadata)
            .transpose()?
            .unwrap_or_default();
        self.screen = Some(ScreenTransform::new(reference, reproduction));
        Ok(())
    }

    pub fn input_channels(&self) -> u16 {
        self.renderer.input_channels()
    }
    pub fn output_layout(&self) -> BedLayout {
        self.renderer.output_layout()
    }
    pub(super) fn disable_limiter(&mut self) {
        self.renderer.disable_limiter();
        if let Some(near_field) = &mut self.near_field {
            near_field.limiting = false;
        }
    }
    pub(super) fn align_near_field(&mut self) -> Result<(), Error> {
        if self.near_field.is_none() {
            self.near_field = Some(SceneNearField::new(
                std::array::from_fn(|_| None),
                self.output_layout(),
            )?);
            self.renderer.disable_limiter();
        }
        Ok(())
    }
    pub(super) fn active_objects(&self) -> u16 {
        self.active
    }
    pub(super) fn reuse_near_field(&mut self, shared: &Self) {
        if let (Some(own), Some(other)) = (&mut self.near_field, &shared.near_field) {
            own.reuse_filters(other);
        }
    }
    /// Nominal direct alignment. Active phase-only HOA adds a 512-sample FIR
    /// centre offset; higher-order phase/group delay remains frequency dependent.
    pub fn delay_samples(&self) -> usize {
        Self::DELAY_SAMPLES
            + if self.near_field.is_some() {
                super::HoaNearField::DELAY_SAMPLES
            } else {
                0
            }
    }
    pub fn tail_samples(&self) -> usize {
        Self::DELAY_SAMPLES
            + if self.near_field.is_some() {
                super::HoaNearField::FILTER_LENGTH - 1
            } else {
                0
            }
    }
    pub fn object_references(&self) -> &[u8] {
        &self.references
    }
    /// Current typed targets after metadata/screen mapping, before speaker lock.
    pub fn objects(&self) -> &[ObjectTarget] {
        &self.current
    }

    /// Render exactly 1024 physical interleaved i16 frames to interleaved f32.
    /// No allocation. Validation failures preserve live targets, audio history
    /// and output; an absent whole dynamic block holds the previous parameters.
    /// Dynamic blocks must cover all unique Objects-pack physical references.
    pub fn process(
        &mut self,
        input: &[i16],
        metadata: Option<&DynamicMetadata>,
        output: &mut [f32],
    ) -> Result<(), Error> {
        self.validate_block(input.len(), output.len())?;
        self.update_objects(metadata)?;
        self.process_bus(PcmBlock::Integer(input), output, None);
        Ok(())
    }

    /// Frame-aligned normalized float PCM, retaining decoded headroom. Invalid
    /// data is rejected before metadata or any audio state is committed.
    pub fn process_f32(
        &mut self,
        input: &[f32],
        metadata: Option<&DynamicMetadata>,
        output: &mut [f32],
    ) -> Result<(), Error> {
        self.validate_block(input.len(), output.len())?;
        if input.iter().any(|v| !v.is_finite() || v.abs() > 256.0) {
            return Err(Error::Invalid("renderer non-finite or excessive PCM"));
        }
        self.update_objects(metadata)?;
        self.process_bus(PcmBlock::Float(input), output, None);
        Ok(())
    }

    fn update_objects(&mut self, metadata: Option<&DynamicMetadata>) -> Result<(), Error> {
        let next = self.stage_update(metadata)?;
        self.commit_update(next);
        Ok(())
    }

    // Staging may update projection caches and scratch coefficients, never
    // live targets, pending jumps or DSP history. Multiple buses can validate
    // completely before committing any of their updates.
    pub(super) fn stage_update(
        &mut self,
        metadata: Option<&DynamicMetadata>,
    ) -> Result<Option<ObjectUpdate>, Error> {
        if let Some(metadata) = metadata {
            let next = map_parameters(
                metadata,
                &self.references,
                &self.defaults,
                self.active,
                self.screen.as_ref(),
                self.output_layout(),
            )?;
            self.prepare_targets(&next.objects[..self.references.len()])?;
            Ok(Some(next))
        } else {
            Ok(None)
        }
    }
    pub(super) fn commit_update(&mut self, next: Option<ObjectUpdate>) {
        if let Some(next) = next {
            self.commit_targets(Some(&next.jumps[..self.references.len()]))
                .expect("staged scene targets have fixed dimensions and block alignment");
            for (current, next) in self.current.iter_mut().zip(next.objects) {
                *current = next;
            }
        }
    }

    /// Feed exactly 1024 zero frames. After the final audio block, three calls
    /// suffice without NFC, four with NFC; use delay_samples() to trim latency.
    pub fn process_silence(&mut self, output: &mut [f32]) -> Result<(), Error> {
        self.validate_block(BLOCK * usize::from(self.input_channels()), output.len())?;
        self.process_bus(PcmBlock::Silence, output, None);
        Ok(())
    }
    // Source PCM and all bus updates are validated before this entry. A shared
    // scene has processed the same packet first, so common pack FIRs can be
    // borrowed without advancing a second copy of their history.
    pub(super) fn process_bus(
        &mut self,
        input: PcmBlock<'_>,
        output: &mut [f32],
        shared: Option<&Self>,
    ) {
        debug_assert_eq!(
            output.len(),
            BLOCK * usize::from(self.output_layout().channels())
        );
        match input {
            PcmBlock::Integer(pcm) => self
                .renderer
                .process(pcm, output)
                .expect("validated scene PCM dimensions"),
            PcmBlock::Float(pcm) => self.renderer.process_prefiltered(pcm, output),
            PcmBlock::Silence => self
                .renderer
                .process_silence(BLOCK, output)
                .expect("fixed scene silence dimensions"),
        }
        if let Some(near_field) = &mut self.near_field {
            near_field.mix(
                input,
                usize::from(self.renderer.input_channels()),
                output,
                shared.and_then(|s| s.near_field.as_ref()),
            );
        }
        self.started = true;
    }

    /// Restore initial object defaults and clear audio history without allocation.
    pub fn reset(&mut self) -> Result<(), Error> {
        let initial = [ObjectTarget::default(); 16];
        self.prepare(&initial[..self.references.len()], None)?;
        for (current, &default) in self.current.iter_mut().zip(&self.defaults) {
            *current = default.into();
        }
        self.renderer.reset();
        if let Some(near_field) = &mut self.near_field {
            near_field.reset();
        }
        self.started = false;
        Ok(())
    }

    fn validate_block(&self, input: usize, output: usize) -> Result<(), Error> {
        if input != BLOCK * usize::from(self.input_channels())
            || output != BLOCK * usize::from(self.output_layout().channels())
        {
            return Err(Error::Invalid("scene renderer block length"));
        }
        Ok(())
    }

    fn prepare(&mut self, objects: &[ObjectTarget], jumps: Option<&[bool]>) -> Result<(), Error> {
        self.prepare_targets(objects)?;
        self.commit_targets(jumps)
    }
    fn prepare_targets(&mut self, objects: &[ObjectTarget]) -> Result<(), Error> {
        for ((&object, cached), projected) in objects
            .iter()
            .zip(&mut self.cached)
            .zip(&mut self.projected)
        {
            if *cached != object {
                match object {
                    ObjectTarget::Polar(object) => {
                        self.projector.project_controlled_into(object, projected)?
                    }
                    ObjectTarget::Cartesian(object) => {
                        self.cartesian.project_controlled_into(object, projected)?
                    }
                }
                *cached = object;
            }
        }
        for (target, base) in self.targets.iter_mut().zip(&self.base) {
            target.direct.copy_from_slice(&base.direct);
            target.diffuse.fill(0.0);
        }
        for (&reference, projected) in self.references.iter().zip(&self.projected) {
            let input = usize::from(reference);
            let factor = self.factors[input];
            let target = &mut self.targets[input];
            let start = &mut self.jump_starts[input];
            for speaker in 0..target.direct.len() {
                target.direct[speaker] = (f64::from(target.direct[speaker])
                    + factor * f64::from(projected.direct[speaker]))
                    as f32;
                target.diffuse[speaker] = (factor * f64::from(projected.diffuse[speaker])) as f32;
                start.direct[speaker] = if self.started {
                    target.direct[speaker]
                } else {
                    (factor * f64::from(projected.direct[speaker])) as f32
                };
                start.diffuse[speaker] = target.diffuse[speaker];
            }
        }
        // Up to 2048 static paths, each with two gains <=16 and dynamic gain
        // <=16: < 2^24 aggregate amplitude. Internal matrices retain headroom;
        // the public ObjectGains constructor still enforces its [-16,16] limit.
        if self
            .targets
            .iter()
            .flat_map(|g| g.direct.iter().chain(&g.diffuse))
            .any(|v| !v.is_finite() || v.abs() > 16_777_216.0)
        {
            return Err(Error::Invalid("scene aggregate coefficient"));
        }
        Ok(())
    }
    fn commit_targets(&mut self, jumps: Option<&[bool]>) -> Result<(), Error> {
        if let Some(jumps) = jumps {
            let mut physical = [false; 16];
            for (&reference, &jump) in self.references.iter().zip(jumps) {
                physical[usize::from(reference)] = jump;
            }
            self.renderer.set_objects_from_starts(
                &self.targets,
                &physical[..self.targets.len()],
                &self.jump_starts,
            )
        } else {
            self.renderer.set_objects(&self.targets)
        }
    }
}

fn pack_layout(format: Option<u8>) -> Result<BedLayout, Error> {
    match format {
        Some(2) => Ok(BedLayout::Stereo),
        Some(3) => Ok(BedLayout::Surround51),
        Some(4) => Ok(BedLayout::Surround512),
        Some(5) => Ok(BedLayout::Surround514),
        Some(15) => Ok(BedLayout::Surround71),
        Some(23) => Ok(BedLayout::Surround714),
        // A 7.1.2 common pack uses U+/-090, unlike the codec layout's U+/-045.
        // Equal channel counts do not identify a speaker configuration.
        Some(_) => Err(Error::Unsupported("direct speaker pack format")),
        None => Err(Error::Invalid("missing direct speaker pack format")),
    }
}
