//! Explicit stereo preview of reconstructed objects. This is an equal-power
//! X-axis projection, not a binaural or reference-equivalent immersive renderer.
//! Y/Z, zone/extent, trims, distance and divergence are retained in metadata but
//! not applied here. LFE, when present, is mixed equally at 0.5 into each side.

use super::AjocMetadata;
use super::oamd::ObjectProperties;
use crate::error::{Result, invalid};

#[derive(Clone, Copy, Default)]
struct Ramp {
    current: [f32; 2],
    target: [f32; 2],
    increment: [f32; 2],
    remaining: u16,
}

impl Ramp {
    fn target(&mut self, target: [f32; 2], duration: u16) {
        self.target = target;
        self.remaining = duration;
        if duration == 0 {
            self.current = target;
        } else {
            self.increment =
                std::array::from_fn(|side| (target[side] - self.current[side]) / duration as f32);
        }
    }
    fn advance(&mut self) {
        if self.remaining == 0 {
            return;
        }
        self.remaining -= 1;
        for side in 0..2 {
            self.current[side] = if self.remaining == 0 {
                self.target[side]
            } else {
                self.current[side] + self.increment[side]
            };
        }
    }
}

fn panning(properties: &ObjectProperties, lfe: bool) -> [f32; 2] {
    let gain = properties.linear_gain();
    if lfe {
        return [gain * 0.5; 2];
    }
    let x = properties.position[0].clamp(0.0, 1.0);
    if x == 0.0 {
        return [gain, 0.0];
    }
    if x == 1.0 {
        return [0.0, gain];
    }
    let angle = x * std::f32::consts::FRAC_PI_2;
    [gain * angle.cos(), gain * angle.sin()]
}

/// Sample-timed basic stereo preview. No normalization, clipping or limiter is
/// applied. Float PCM may exceed unity. The caller explicitly chooses this
/// projection and must not identify it as an immersive headphone renderer.
#[derive(Default)]
pub struct StereoPreview {
    ramps: Vec<Ramp>,
}

impl StereoPreview {
    pub fn reset(&mut self) {
        self.ramps.clear();
    }

    pub fn process_into(
        &mut self,
        metadata: &AjocMetadata,
        objects: &[Vec<f32>],
        stereo: &mut Vec<Vec<f32>>,
    ) -> Result<()> {
        if let Err(error) = validate(metadata, objects) {
            stereo.clear();
            return Err(error);
        }
        if !self.ramps.is_empty() && self.ramps.len() != objects.len() {
            stereo.clear();
            return Err(invalid(
                "stereo preview signal count changed; reset required",
            ));
        }
        let samples = objects[0].len();
        self.ramps.resize(objects.len(), Ramp::default());
        stereo.resize_with(2, Vec::new);
        for side in stereo.iter_mut() {
            side.resize(samples, 0.0);
            side.fill(0.0);
        }
        let has_lfe = objects.len() == metadata.objects.len() + 1;
        for (index, (plane, updates)) in objects.iter().zip(&metadata.upmix_metadata).enumerate() {
            let ramp = &mut self.ramps[index];
            let mut next = 0;
            for (sample, &value) in plane.iter().enumerate() {
                while next < updates.len() && updates[next].timing.sample as usize == sample {
                    let update = &updates[next];
                    ramp.target(
                        panning(&update.properties, has_lfe && index == 0),
                        update.timing.ramp,
                    );
                    next += 1;
                }
                for side in 0..2 {
                    stereo[side][sample] += value * ramp.current[side];
                }
                ramp.advance();
            }
        }
        if stereo.iter().flatten().any(|v| !v.is_finite()) {
            stereo.clear();
            self.reset();
            return Err(invalid("non-finite stereo preview"));
        }
        Ok(())
    }
}

pub(super) fn validate(metadata: &AjocMetadata, objects: &[Vec<f32>]) -> Result<()> {
    if !(1..=65).contains(&objects.len())
        || !(1..=64).contains(&metadata.objects.len())
        || objects.len() != metadata.upmix_metadata.len()
        || !(metadata.objects.len()..=metadata.objects.len() + 1).contains(&objects.len())
    {
        return Err(invalid("stereo preview dimensions"));
    }
    let samples = objects[0].len();
    if !(1..=2048).contains(&samples)
        || objects
            .iter()
            .any(|p| p.len() != samples || p.iter().any(|v| !v.is_finite()))
    {
        return Err(invalid("stereo preview PCM"));
    }
    for updates in &metadata.upmix_metadata {
        if updates.len() > 7 {
            return Err(invalid("stereo preview object update count"));
        }
        let mut previous = None;
        for update in updates {
            if update.timing.sample as usize >= samples
                || update.timing.ramp > 2048
                || previous.is_some_and(|p| update.timing.sample < p)
                || update
                    .properties
                    .gain_db
                    .is_some_and(|db| !(-49..=15).contains(&db))
                || update.properties.position.iter().any(|v| !v.is_finite())
            {
                return Err(invalid("stereo preview object properties or timing"));
            }
            previous = Some(update.timing.sample);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
