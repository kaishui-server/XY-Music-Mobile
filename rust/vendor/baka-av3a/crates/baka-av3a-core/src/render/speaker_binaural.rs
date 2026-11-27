use super::{
    BedLayout, BinauralRenderer, BinauralSource, HeadOrientation, HoaDecoder, HoaRenderer,
    HrirBank, LookAheadLimiter, ObjectTarget, SceneNearFieldConfig, SceneRenderConfig,
    SceneRenderer, ScreenEdges, hrir::BLOCK, scene_near_field::PcmBlock,
};
use crate::{
    Error,
    metadata::{DynamicMetadata, StaticMetadata},
};

/// LFE handling is explicit: mute it or convolve it with the frontal HRIR at
/// the specified gain. Frontal LFE is head-locked; no extra bass filtering is
/// imposed, so callers must supply appropriately band-limited LFE material.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum BinauralLfe {
    Mute,
    Front { gain: f32 },
}

/// Virtual loudspeaker rendering to measured stereo HRIRs. The input layout is
/// fixed, head rotation changes world-fixed speaker directions, and LFE handling
/// is explicit. This is a discrete virtual-speaker approximation, not a direct
/// continuous-order sound-field/HRTF decoder. Listener translation is not applied.
#[derive(Clone, Debug)]
pub struct SpeakerBinauralRenderer {
    renderer: BinauralRenderer,
    layout: BedLayout,
    lfe: BinauralLfe,
    orientation: HeadOrientation,
    targets: Vec<BinauralSource>,
    started: bool,
}

impl SpeakerBinauralRenderer {
    pub const DELAY_SAMPLES: usize = BinauralRenderer::DELAY_SAMPLES;
    pub fn new(
        bank: HrirBank,
        sample_rate: u32,
        layout: BedLayout,
        lfe: BinauralLfe,
    ) -> Result<Self, Error> {
        let targets = speaker_targets(layout, lfe, HeadOrientation::default())?;
        let count = usize::from(layout.channels());
        let mut renderer = BinauralRenderer::new(bank, sample_rate, &targets[..count])?;
        // The upstream renderer already supplies its own source startup ramp.
        renderer.set_sources(&targets[..count], &[true; 12][..count])?;
        Ok(Self {
            renderer,
            layout,
            lfe,
            orientation: HeadOrientation::default(),
            targets: targets[..count].to_vec(),
            started: false,
        })
    }
    pub fn input_layout(&self) -> BedLayout {
        self.layout
    }
    pub fn orientation(&self) -> HeadOrientation {
        self.orientation
    }
    pub fn lfe_policy(&self) -> BinauralLfe {
        self.lfe
    }
    pub fn sources(&self) -> &[BinauralSource] {
        self.renderer.sources()
    }
    pub fn tail_samples(&self) -> usize {
        self.renderer.tail_samples()
    }
    pub fn set_orientation(
        &mut self,
        orientation: HeadOrientation,
        jump: bool,
    ) -> Result<(), Error> {
        let targets = speaker_targets(self.layout, self.lfe, orientation)?;
        let count = self.targets.len();
        self.renderer
            .set_sources(&targets[..count], &[jump || !self.started; 12][..count])?;
        self.targets.copy_from_slice(&targets[..count]);
        self.orientation = orientation;
        Ok(())
    }
    pub fn process(&mut self, input: &[f32], output: &mut [f32]) -> Result<(), Error> {
        self.renderer.process(input, output)?;
        self.started = true;
        Ok(())
    }
    pub fn process_silence(&mut self, output: &mut [f32]) -> Result<(), Error> {
        self.renderer.process_silence(output)?;
        self.started = true;
        Ok(())
    }
    pub(super) fn process_bus(&mut self, input: &[f32], output: &mut [f32]) {
        self.renderer.process_prefiltered(input, output);
        self.started = true;
    }
    pub(super) fn disable_limiter(&mut self) {
        self.renderer.disable_limiter();
    }
    pub fn reset(&mut self) {
        self.renderer.reset();
        self.started = false;
        self.renderer
            .set_sources(&self.targets, &[true; 12][..self.targets.len()])
            .expect("retained speaker targets are valid");
    }
}

fn speaker_targets(
    layout: BedLayout,
    lfe: BinauralLfe,
    orientation: HeadOrientation,
) -> Result<[BinauralSource; 12], Error> {
    let lfe_gain = match lfe {
        BinauralLfe::Mute => 0.0,
        BinauralLfe::Front { gain } => gain,
    };
    if !lfe_gain.is_finite() || !(0.0..=16.0).contains(&lfe_gain) {
        return Err(Error::Invalid("binaural LFE gain"));
    }
    let mut targets = [BinauralSource::default(); 12];
    for (target, name) in targets.iter_mut().zip(layout.speaker_names()) {
        if name.starts_with("LFE") {
            *target = BinauralSource {
                gain: lfe_gain,
                ..Default::default()
            };
            continue;
        }
        let azimuth: f64 = name[1..].parse().expect("fixed speaker azimuth");
        let elevation: f64 = if name.starts_with('U') { 30.0 } else { 0.0 };
        let (s, c) = azimuth.to_radians().sin_cos();
        let (z, r) = elevation.to_radians().sin_cos();
        let [x, y, z] = orientation.world_to_head([-s * r, c * r, z])?;
        *target = BinauralSource {
            azimuth: (-x).atan2(y).to_degrees(),
            elevation: z.atan2(x.hypot(y)).to_degrees(),
            gain: 1.0,
        };
    }
    Ok(targets)
}

#[derive(Clone, Copy, Debug)]
pub struct BinauralSceneConfig {
    pub virtual_layout: BedLayout,
    pub lfe: BinauralLfe,
    pub reproduction_screen: Option<ScreenEdges>,
    pub near_field: Option<SceneNearFieldConfig>,
}

/// Static/dynamic scene to a virtual loudspeaker bus, followed by measured
/// binaural convolution. Extent, diffusion, static sharing, gain and HOA pack
/// routing use SceneRenderer. Only the final stereo mix is limited. Unsupported
/// scene features still fail explicitly. World and head-locked paths retain
/// separate buses and convolution histories before one final stereo limiter.
#[derive(Clone, Debug)]
pub struct SceneBinauralRenderer {
    scene: SceneRenderer,
    binaural: SpeakerBinauralRenderer,
    bus: Vec<f32>,
    head_locked: Option<HeadLockedScene>,
}

#[derive(Clone, Debug)]
struct HeadLockedScene {
    scene: SceneRenderer,
    binaural: SpeakerBinauralRenderer,
    bus: Vec<f32>,
    stereo: Vec<f32>,
    limiter: LookAheadLimiter,
    objects: Vec<ObjectTarget>,
}
impl SceneBinauralRenderer {
    /// Baseline alignment without NFC, excluding measured ear delays. The intermediate
    /// bus omits its limiter, so there is exactly one 99-sample limiter delay.
    pub const DELAY_SAMPLES: usize = SceneRenderer::DELAY_SAMPLES;
    pub fn new(
        bank: HrirBank,
        sample_rate: u32,
        metadata: &StaticMetadata,
        physical_channels: u16,
        selected_objects: Option<&[u8]>,
        config: BinauralSceneConfig,
    ) -> Result<Self, Error> {
        if config
            .near_field
            .is_some_and(|n| n.sample_rate != sample_rate)
        {
            return Err(Error::Invalid(
                "scene near-field/binaural sample rate mismatch",
            ));
        }
        // This bank represents one physical measurement sphere. NFC may not
        // silently assume another reproduction radius without radial HRTFs.
        if config
            .near_field
            .is_some_and(|n| n.speaker_distance as f32 != bank.measurement_radius())
        {
            return Err(Error::Invalid("scene near-field/HRIR radius mismatch"));
        }
        let scene_config = SceneRenderConfig {
            output: config.virtual_layout,
            reproduction_screen: config.reproduction_screen,
            near_field: config.near_field,
        };
        let has_head = metadata
            .resolve_scene(physical_channels, selected_objects)?
            .channels()
            .iter()
            .any(|p| p.head_locked);
        let mut binaural = SpeakerBinauralRenderer::new(
            bank.clone(),
            sample_rate,
            config.virtual_layout,
            config.lfe,
        )?;
        let mut scene = SceneRenderer::new_for_space(
            metadata,
            physical_channels,
            selected_objects,
            scene_config,
            Some(false),
        )?;
        let mut head_locked = if has_head {
            let mut head_scene = SceneRenderer::new_for_space(
                metadata,
                physical_channels,
                selected_objects,
                scene_config,
                Some(true),
            )?;
            if scene.delay_samples() != head_scene.delay_samples() {
                scene.align_near_field()?;
                head_scene.align_near_field()?;
            }
            head_scene.reuse_near_field(&scene);
            head_scene.disable_limiter();
            let mut head_binaural =
                SpeakerBinauralRenderer::new(bank, sample_rate, config.virtual_layout, config.lfe)?;
            head_binaural.disable_limiter();
            binaural.disable_limiter();
            Some(HeadLockedScene {
                objects: scene.objects().to_vec(),
                scene: head_scene,
                binaural: head_binaural,
                bus: vec![0.0; BLOCK * usize::from(config.virtual_layout.channels())],
                stereo: vec![0.0; BLOCK * 2],
                limiter: LookAheadLimiter::new(2)?,
            })
        } else {
            None
        };
        scene.disable_limiter();
        if let Some(head) = &mut head_locked {
            head.refresh_objects(&scene);
        }
        Ok(Self {
            scene,
            binaural,
            bus: vec![0.0; BLOCK * usize::from(config.virtual_layout.channels())],
            head_locked,
        })
    }
    pub fn input_channels(&self) -> u16 {
        self.scene.input_channels()
    }
    pub fn virtual_layout(&self) -> BedLayout {
        self.binaural.input_layout()
    }
    pub fn orientation(&self) -> HeadOrientation {
        self.binaural.orientation()
    }
    pub fn objects(&self) -> &[super::ObjectTarget] {
        self.head_locked
            .as_ref()
            .map_or_else(|| self.scene.objects(), |head| head.objects.as_slice())
    }
    pub fn object_references(&self) -> &[u8] {
        self.scene.object_references()
    }
    /// Sufficient tail after the last input sample, including both bus paths.
    pub fn tail_samples(&self) -> usize {
        self.scene.tail_samples() + self.binaural.renderer.bank().tap_count() - 1
    }
    /// Configured nominal direct alignment; active near-field FIR adds 512 samples.
    pub fn delay_samples(&self) -> usize {
        self.scene.delay_samples()
    }
    pub fn set_orientation(
        &mut self,
        orientation: HeadOrientation,
        jump: bool,
    ) -> Result<(), Error> {
        self.binaural.set_orientation(orientation, jump)
    }
    pub fn process(
        &mut self,
        input: &[i16],
        metadata: Option<&DynamicMetadata>,
        output: &mut [f32],
    ) -> Result<(), Error> {
        validate_stereo(output)?;
        if self.head_locked.is_some() {
            self.validate_input(input.len())?;
            self.update_buses(metadata)?;
            self.scene
                .process_bus(PcmBlock::Integer(input), &mut self.bus, None);
            let head = self.head_locked.as_mut().unwrap();
            head.scene
                .process_bus(PcmBlock::Integer(input), &mut head.bus, Some(&self.scene));
        } else {
            self.scene.process(input, metadata, &mut self.bus)?;
        }
        self.output_buses(output);
        Ok(())
    }
    pub fn process_f32(
        &mut self,
        input: &[f32],
        metadata: Option<&DynamicMetadata>,
        output: &mut [f32],
    ) -> Result<(), Error> {
        validate_stereo(output)?;
        if self.head_locked.is_some() {
            self.validate_input(input.len())?;
            if input.iter().any(|v| !v.is_finite() || v.abs() > 256.0) {
                return Err(Error::Invalid("binaural scene input PCM"));
            }
            self.update_buses(metadata)?;
            self.scene
                .process_bus(PcmBlock::Float(input), &mut self.bus, None);
            let head = self.head_locked.as_mut().unwrap();
            head.scene
                .process_bus(PcmBlock::Float(input), &mut head.bus, Some(&self.scene));
        } else {
            self.scene.process_f32(input, metadata, &mut self.bus)?;
        }
        self.output_buses(output);
        Ok(())
    }
    pub fn process_silence(&mut self, output: &mut [f32]) -> Result<(), Error> {
        validate_stereo(output)?;
        self.scene.process_silence(&mut self.bus)?;
        if let Some(head) = &mut self.head_locked {
            head.scene
                .process_bus(PcmBlock::Silence, &mut head.bus, Some(&self.scene));
        }
        self.output_buses(output);
        Ok(())
    }
    pub fn reset(&mut self) -> Result<(), Error> {
        self.scene.reset()?;
        self.binaural.reset();
        self.bus.fill(0.0);
        if let Some(head) = &mut self.head_locked {
            head.scene.reset()?;
            head.binaural.reset();
            head.bus.fill(0.0);
            head.stereo.fill(0.0);
            head.limiter.reset();
            head.refresh_objects(&self.scene);
        }
        Ok(())
    }
    fn validate_input(&self, len: usize) -> Result<(), Error> {
        if len != BLOCK * usize::from(self.input_channels()) {
            return Err(Error::Invalid("binaural scene input block length"));
        }
        Ok(())
    }
    fn update_buses(&mut self, metadata: Option<&DynamicMetadata>) -> Result<(), Error> {
        let world = self.scene.stage_update(metadata)?;
        let head = self.head_locked.as_mut().unwrap();
        let locked = head.scene.stage_update(metadata)?;
        self.scene.commit_update(world);
        head.scene.commit_update(locked);
        head.refresh_objects(&self.scene);
        Ok(())
    }
    fn output_buses(&mut self, output: &mut [f32]) {
        self.binaural.process_bus(&self.bus, output);
        if let Some(head) = &mut self.head_locked {
            head.binaural.process_bus(&head.bus, &mut head.stereo);
            for (target, locked) in output.iter_mut().zip(&head.stereo) {
                *target += locked;
            }
            head.limiter
                .process(output)
                .expect("bounded world/head-locked mix is finite");
        }
    }
}
impl HeadLockedScene {
    fn refresh_objects(&mut self, world: &SceneRenderer) {
        for (index, target) in self.objects.iter_mut().enumerate() {
            *target = if self.scene.active_objects() & (1 << index) != 0 {
                self.scene.objects()[index]
            } else {
                world.objects()[index]
            };
        }
    }
}

/// Complete ACN HOA to virtual loudspeakers to measured binaural PCM. The HOA
/// matrix and both-ear responses retain signed coefficients and float headroom.
#[derive(Clone, Debug)]
pub struct HoaBinauralRenderer {
    hoa: HoaRenderer,
    binaural: SpeakerBinauralRenderer,
    bus: Vec<f32>,
}
impl HoaBinauralRenderer {
    pub const DELAY_SAMPLES: usize = HoaRenderer::DELAY_SAMPLES;
    pub fn new(decoder: HoaDecoder, bank: HrirBank, sample_rate: u32) -> Result<Self, Error> {
        let layout = decoder.output_layout();
        let binaural = SpeakerBinauralRenderer::new(bank, sample_rate, layout, BinauralLfe::Mute)?;
        let mut hoa = HoaRenderer::new(decoder)?;
        hoa.disable_limiter();
        Ok(Self {
            hoa,
            binaural,
            bus: vec![0.0; BLOCK * usize::from(layout.channels())],
        })
    }
    pub fn decoder(&self) -> &HoaDecoder {
        self.hoa.decoder()
    }
    pub fn orientation(&self) -> HeadOrientation {
        self.binaural.orientation()
    }
    pub fn tail_samples(&self) -> usize {
        Self::DELAY_SAMPLES + self.binaural.renderer.bank().tap_count() - 1
    }
    pub fn set_orientation(
        &mut self,
        orientation: HeadOrientation,
        jump: bool,
    ) -> Result<(), Error> {
        self.binaural.set_orientation(orientation, jump)
    }
    fn validate(&self, input: usize, output: &[f32]) -> Result<(), Error> {
        validate_stereo(output)?;
        if input != BLOCK * usize::from(self.decoder().input_channels()) {
            return Err(Error::Invalid("binaural HOA input block length"));
        }
        Ok(())
    }
    pub fn process(&mut self, input: &[i16], output: &mut [f32]) -> Result<(), Error> {
        self.validate(input.len(), output)?;
        self.hoa.process(input, &mut self.bus)?;
        self.binaural.process_bus(&self.bus, output);
        Ok(())
    }
    pub fn process_f32(&mut self, input: &[f32], output: &mut [f32]) -> Result<(), Error> {
        self.validate(input.len(), output)?;
        self.hoa.process_f32(input, &mut self.bus)?;
        self.binaural.process_bus(&self.bus, output);
        Ok(())
    }
    pub fn process_silence(&mut self, output: &mut [f32]) -> Result<(), Error> {
        validate_stereo(output)?;
        self.hoa.process_silence(BLOCK, &mut self.bus)?;
        self.binaural.process_bus(&self.bus, output);
        Ok(())
    }
    pub fn reset(&mut self) {
        self.hoa.reset();
        self.binaural.reset();
        self.bus.fill(0.0);
    }
}

fn validate_stereo(output: &[f32]) -> Result<(), Error> {
    if output.len() != BLOCK * 2 {
        return Err(Error::Invalid("binaural output block length"));
    }
    Ok(())
}
