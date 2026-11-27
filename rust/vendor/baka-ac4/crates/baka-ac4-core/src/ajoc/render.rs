//! Dynamic-object loudspeaker renderer, using TS 103 448 V1.1.1 algorithms.
//! This is not a binaural headphone processor. No loudness correction, dialogue
//! enhancement, bass management, normalization or limiting is added here.

mod layout;
mod panner;
use super::AjocMetadata;
use super::common::{CommonData, TrimGain, TrimMode};
use super::oamd::{Divergence, ObjectProperties};
use crate::error::{Result, invalid, unsupported};
pub use layout::SpeakerLayout;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Screen {
    pub width: f64,
    pub height: f64,
    pub origin_x: f64,
    pub origin_z: f64,
}
impl Default for Screen {
    fn default() -> Self {
        Self {
            width: 1.,
            height: 1.,
            origin_x: 0.5,
            origin_z: 0.,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RenderOptions {
    pub layout: SpeakerLayout,
    pub screen: Screen,
}
impl RenderOptions {
    pub fn new(layout: SpeakerLayout) -> Self {
        Self {
            layout,
            screen: Screen::default(),
        }
    }
    pub(crate) fn validate(self) -> Result<()> {
        let s = self.screen;
        if [s.width, s.height, s.origin_x, s.origin_z]
            .iter()
            .any(|v| !v.is_finite())
            || !(0.0..=1.0).contains(&s.width)
            || !(0.0..=1.0).contains(&s.height)
            || (s.origin_x - 0.5).abs() * 2. + s.width > 1. + 1e-10
            || s.origin_z.abs() + s.height > 1. + 1e-10
        {
            return Err(invalid("speaker renderer screen geometry"));
        }
        Ok(())
    }
}

#[derive(Default)]
struct Ramp {
    current: Vec<f64>,
    target: Vec<f64>,
    delta: Vec<f64>,
    remaining: usize,
}
impl Ramp {
    fn new(channels: usize) -> Self {
        Self {
            current: vec![0.; channels],
            target: vec![0.; channels],
            delta: vec![0.; channels],
            remaining: 0,
        }
    }
    fn target(&mut self, target: &[f64], duration: u16) {
        self.remaining = usize::from(duration) + 1;
        self.target.copy_from_slice(target);
        for (j, &v) in target.iter().enumerate() {
            self.delta[j] = (v - self.current[j]) / self.remaining as f64;
        }
    }
    fn advance(&mut self) {
        if self.remaining == 0 {
            return;
        }
        self.remaining -= 1;
        for j in 0..self.current.len() {
            self.current[j] = if self.remaining == 0 {
                self.target[j]
            } else {
                self.current[j] + self.delta[j]
            };
        }
    }
}

/// Reusable renderer for reconstructed dynamic objects. Output is in ascending
/// WAVE speaker-mask order. LFE is discrete in surround layouts; stereo folds
/// it equally at 0.5 per side as an explicit no-bass-management policy.
pub struct SpeakerRenderer {
    options: RenderOptions,
    ramps: Vec<Ramp>,
    shape: Option<(usize, bool)>,
}
impl SpeakerRenderer {
    pub fn new(options: RenderOptions) -> Result<Self> {
        options.validate()?;
        Ok(Self {
            options,
            ramps: Vec::new(),
            shape: None,
        })
    }
    pub fn reset(&mut self) {
        self.ramps.clear();
        self.shape = None;
    }
    pub fn process_into(
        &mut self,
        metadata: &AjocMetadata,
        objects: &[Vec<f32>],
        output: &mut Vec<Vec<f32>>,
    ) -> Result<()> {
        if let Err(error) = super::stereo::validate(metadata, objects) {
            output.clear();
            return Err(error);
        }
        let lfe = objects.len() == metadata.objects.len() + 1;
        let shape = (metadata.objects.len(), lfe);
        if self.shape.is_some_and(|previous| previous != shape) {
            output.clear();
            return Err(invalid(
                "speaker renderer signal count changed; reset required",
            ));
        }
        // Validate every target before committing ramp history or output.
        let targets = metadata
            .upmix_metadata
            .iter()
            .enumerate()
            .map(|(i, updates)| {
                updates
                    .iter()
                    .map(|u| self.target(&u.properties, metadata.common.as_ref(), lfe && i == 0))
                    .collect::<Result<Vec<_>>>()
            })
            .collect::<Result<Vec<_>>>();
        let targets = match targets {
            Ok(v) => v,
            Err(e) => {
                output.clear();
                return Err(e);
            }
        };
        let channels = self.options.layout.channels();
        self.shape = Some(shape);
        self.ramps
            .resize_with(objects.len(), || Ramp::new(channels));
        output.resize_with(channels, Vec::new);
        for plane in output.iter_mut() {
            plane.resize(objects[0].len(), 0.);
            plane.fill(0.);
        }
        for (i, plane) in objects.iter().enumerate() {
            let mut next = 0;
            let ramp = &mut self.ramps[i];
            let updates = &metadata.upmix_metadata[i];
            for (sample, &value) in plane.iter().enumerate() {
                while next < updates.len() && updates[next].timing.sample as usize == sample {
                    ramp.target(&targets[i][next], updates[next].timing.ramp);
                    next += 1;
                }
                ramp.advance();
                for (j, &gain) in ramp.current.iter().enumerate() {
                    output[j][sample] += (f64::from(value) * gain) as f32;
                }
            }
        }
        if output.iter().flatten().any(|v| !v.is_finite()) {
            output.clear();
            self.reset();
            return Err(invalid("non-finite speaker renderer output"));
        }
        Ok(())
    }

    fn target(
        &self,
        p: &ObjectProperties,
        common: Option<&CommonData>,
        lfe: bool,
    ) -> Result<Vec<f64>> {
        let layout = self.options.layout;
        let mut result = vec![0.; layout.channels()];
        if !p.active || p.gain_db.is_none() {
            return Ok(result);
        }
        let gain = f64::from(p.linear_gain());
        if lfe {
            if layout == SpeakerLayout::Stereo {
                result[0] = gain * 0.5;
                result[1] = gain * 0.5;
            } else {
                result[3] = gain;
            }
            return Ok(result);
        }
        validate_properties(p)?;
        let mut position = p.position.map(f64::from);
        let mut width = p.other.width.map(f64::from);
        let mut divergence = divergence(p.other.divergence)?;
        let screen = p.other.screen_factor > 0.;
        if screen {
            position = screen_scale(position, p, self.options);
        }
        let (mid, _) = layout.counts();
        let mut speakers = layout.speakers();
        speakers.retain(|s| !layout::excluded(s.zone, p.zone_mask, p.elevation, false, mid));
        if speakers.is_empty() {
            return Err(unsupported("object zone excludes all speakers"));
        }
        if !p.elevation {
            position[2] = 0.;
        }
        if p.snap && !screen {
            let targets = layout::snap_targets(p.zone_mask, p.elevation);
            position = targets
                .iter()
                .min_by(|a, b| {
                    let distance = |s: &layout::Speaker| {
                        (s.position[0] - position[0]).powi(2) / 16.
                            + 4. * (s.position[1] - position[1]).powi(2)
                            + 32. * (s.position[2] - position[2]).powi(2)
                    };
                    distance(a).total_cmp(&distance(b))
                })
                .ok_or_else(|| invalid("empty snap targets"))?
                .position;
            width = [0.; 3];
            divergence = 0.;
        }
        // Supported output layouts have no bottom plane. Extended precision can
        // put positions just outside nominal room bounds; saturate for panning.
        let panner_position = position.map(|v| v.clamp(0., 1.));
        let trim = trim_gain(layout, &speakers, position, p.trim_disabled, common)?;
        for (speaker, value) in
            speakers
                .iter()
                .zip(panner::gains(&speakers, panner_position, width, divergence))
        {
            result[speaker.channel] = value * gain * trim;
        }
        if result.iter().any(|v| !v.is_finite()) {
            return Err(invalid("non-finite speaker gains"));
        }
        Ok(result)
    }
}

fn validate_properties(p: &ObjectProperties) -> Result<()> {
    if p.zone_mask > 5
        || p.other.depth_code > 3
        || !(0.0..=1.0).contains(&p.other.screen_factor)
        || p.other
            .width
            .iter()
            .any(|v| !v.is_finite() || !(0.0..=1.0).contains(v))
    {
        return Err(unsupported("object rendering property code or range"));
    }
    Ok(())
}

fn screen_scale(mut pos: [f64; 3], p: &ObjectProperties, options: RenderOptions) -> [f64; 3] {
    let s = options.screen;
    let y = pos[1]
        .clamp(0., 1.)
        .powf([0.25, 0.5, 1., 2.][p.other.depth_code as usize]);
    let factor = f64::from(p.other.screen_factor) * (1. - y);
    pos[0] += factor * ((pos[0] - 0.5) * s.width + s.origin_x - pos[0]);
    if options.layout.counts().1 > 0 {
        pos[2] += factor * (pos[2] * s.height + s.origin_z - pos[2]);
    }
    pos
}

fn trim_gain(
    layout: SpeakerLayout,
    speakers: &[layout::Speaker],
    p: [f64; 3],
    disabled: bool,
    common: Option<&CommonData>,
) -> Result<f64> {
    if disabled {
        return Ok(1.);
    }
    let mid = speakers
        .iter()
        .filter(|s| matches!(s.zone, layout::Zone::Side | layout::Zone::Back))
        .count();
    let top = speakers
        .iter()
        .filter(|s| s.zone == layout::Zone::Height)
        .count();
    let cfg = if top == 0 {
        0
    } else if top == 2 {
        3
    } else {
        6
    } + if mid == 0 {
        0
    } else if mid < 4 {
        1
    } else {
        2
    };
    let trim = common
        .and_then(|c| c.trim.as_ref())
        .map(|t| t.configurations[cfg]);
    let mode = trim.map_or(TrimMode::Default, |t| t.mode);
    let db = match mode {
        TrimMode::Disabled => 0.,
        TrimMode::Default => {
            let maximum =
                (-4.5 + 3. * (mid as f64 / 4.).min(1.) + 1.5 * (top as f64 / 4.).min(1.)).min(0.);
            maximum
                * ((p[1] / 0.6).clamp(0., 1.) + ((p[2].abs() - 0.2) / 0.8).clamp(0., 1.))
                    .clamp(0., 1.)
        }
        TrimMode::Custom => {
            let t = trim.unwrap();
            let value = |v| match v {
                None => Ok(0.),
                Some(TrimGain::Db(v)) if v.is_finite() => Ok(f64::from(v)),
                _ => Err(unsupported("reserved trim gain")),
            };
            let centre = if layout == SpeakerLayout::Stereo {
                let edge = (p[0] - 0.5).abs() - 0.05;
                (1. - (edge.max(p[1] - 0.05).max(p[2].abs() - 0.05) / 0.1).clamp(0., 1.))
                    * value(t.centre)?
            } else {
                0.
            };
            centre
                + value(t.surround)? * (2. * p[1]).clamp(0., 1.)
                + value(t.height)? * p[2].abs().min(1.)
        }
        TrimMode::Reserved => return Err(unsupported("reserved trim mode")),
    };
    Ok(10f64.powf(db / 20.))
}

fn divergence(value: Divergence) -> Result<f64> {
    const TABLE: [f64; 64] = [
        0., 0., 0.004026, 0.00716, 0.012731, 0.020173, 0.028485, 0.04021, 0.050582, 0.063601,
        0.079914, 0.100299, 0.125666, 0.140532, 0.157027, 0.175282, 0.195417, 0.217536, 0.241718,
        0.268002, 0.296377, 0.326766, 0.359017, 0.392895, 0.428081, 0.464184, 0.500755, 0.537316,
        0.573389, 0.608529, 0.642346, 0.674524, 0.704833, 0.733123, 0.75932, 0.783416, 0.805451,
        0.825506, 0.843686, 0.860112, 0.874914, 0.888222, 0.900168, 0.910875, 0.920461, 0.929035,
        0.936698, 0.943544, 0.949656, 0.955112, 0.95998, 0.964322, 0.968195, 0.974729, 0.979923,
        0.98405, 0.98733, 0.989935, 0.992874, 0.994955, 0.996817, 0.99821, 0.998993, 1.,
    ];
    match value {
        Divergence::Default => Ok(0.),
        Divergence::Table(v) if v < 4 => Ok(TABLE[[26, 29, 32, 63][v as usize]]),
        Divergence::Code(v) if (1..64).contains(&v) => Ok(TABLE[v as usize]),
        _ => Err(unsupported("reserved object divergence")),
    }
}

#[cfg(test)]
mod tests;
