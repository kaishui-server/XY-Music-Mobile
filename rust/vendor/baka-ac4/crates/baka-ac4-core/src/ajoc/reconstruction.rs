//! QMF matrix reconstruction, ETSI TS 103 190-2 clauses 5.7.3.1/4/6.
//! The backend supplies decorrelation/ducking; [`super::decorrelation::AjocDecorrelation`]
//! implements the specified filters. Speaker/headphone rendering is separate.

use super::{AjocMetadata, ObjectMatrix};
use crate::error::{Result, invalid};

/// One complex 64-band QMF time slot: [subband][real, imaginary].
pub type QmfSlot = [[f32; 2]; 64];
/// Fullband signal planes, each containing 1..=32 time slots. LFE is separate.
pub type QmfPlanes = Vec<Vec<QmfSlot>>;

/// Supplies one enabled decorrelation/ducking instance. The implementation owns
/// its filter histories. A failed call invalidates the frame and resets both
/// the matrix engine and this backend before returning the error.
pub trait Decorrelation {
    fn process(&mut self, index: usize, input: &QmfSlot, output: &mut QmfSlot) -> Result<()>;
    fn reset(&mut self);
}

pub(super) const PARAMETER_BAND_ENDS_15: [usize; 15] =
    [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 14, 18, 23, 35, 64];

/// Map a QMF subband to its transmitted A-JOC parameter band.
pub fn parameter_band(bands: usize, subband: usize) -> Result<usize> {
    let ends: &[usize] = match bands {
        23 => &[
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16, 18, 20, 23, 26, 30, 35, 41, 48, 64,
        ],
        15 => &PARAMETER_BAND_ENDS_15,
        12 => &[1, 2, 3, 4, 6, 8, 11, 14, 18, 23, 35, 64],
        9 => &[1, 2, 3, 5, 7, 9, 14, 23, 64],
        7 => &[1, 2, 4, 8, 14, 23, 64],
        5 => &[1, 3, 9, 23, 64],
        3 => &[3, 14, 64],
        1 => &[64],
        _ => return Err(invalid("A-JOC parameter band count")),
    };
    if subband >= 64 {
        return Err(invalid("A-JOC QMF subband"));
    }
    Ok(ends.partition_point(|&end| subband >= end))
}

#[derive(Clone, Copy, Default)]
struct Ramp {
    value: f32,
    target: f32,
    increment: f32,
    remaining: u8,
}

impl Ramp {
    fn advance(&mut self) {
        if self.remaining != 0 {
            self.remaining -= 1;
            self.value = if self.remaining == 0 {
                self.target
            } else {
                self.value + self.increment
            };
        }
    }

    fn target(&mut self, value: f32, length: u8) {
        self.target = value;
        self.increment = (value - self.value) / length as f32;
        self.remaining = length;
    }
}

struct State {
    downmix: usize,
    objects: usize,
    decorrelators: usize,
    // Object-major/input-major tables, one ramp per QMF subband.
    dry: Vec<[Ramp; 64]>,
    wet: Vec<[Ramp; 64]>,
    pre: Vec<[Ramp; 64]>,
}

impl State {
    fn new(downmix: usize, objects: usize, decorrelators: usize) -> Self {
        Self {
            downmix,
            objects,
            decorrelators,
            dry: vec![[Ramp::default(); 64]; objects * downmix],
            wet: vec![[Ramp::default(); 64]; objects * decorrelators],
            pre: vec![[Ramp::default(); 64]; decorrelators * downmix],
        }
    }

    fn advance(&mut self) {
        for table in [&mut self.dry, &mut self.wet, &mut self.pre] {
            for row in table {
                for ramp in row {
                    ramp.advance();
                }
            }
        }
    }

    fn update(&mut self, metadata: &AjocMetadata, dp: usize) {
        let length = metadata.points[dp].ramp;
        for row in &mut self.pre {
            for ramp in row {
                ramp.target(0.0, length);
            }
        }
        for (o, object) in metadata.objects.iter().enumerate() {
            if !object.present {
                continue;
            }
            for sb in 0..64 {
                // Metadata was validated before any state/backend mutation.
                let pb = parameter_band(object.bands, sb).expect("validated bands");
                for ch in 0..self.downmix {
                    let gain = coefficient(object, dp, ch, pb, false);
                    self.dry[o * self.downmix + ch][sb].target(gain, length);
                }
                for de in 0..self.decorrelators {
                    let gain = coefficient(object, dp, de, pb, true);
                    self.wet[o * self.decorrelators + de][sb].target(gain, length);
                    for ch in 0..self.downmix {
                        // Accumulate the target before calculating its slope.
                        self.pre[de * self.downmix + ch][sb].target +=
                            gain.abs() * coefficient(object, dp, ch, pb, false);
                    }
                }
            }
        }
        for row in &mut self.pre {
            for ramp in row {
                ramp.target(ramp.target, length);
            }
        }
    }

    fn run(
        &mut self,
        metadata: &AjocMetadata,
        input: &[Vec<QmfSlot>],
        backend: &mut impl Decorrelation,
        output: &mut QmfPlanes,
    ) -> Result<()> {
        let slots = input[0].len();
        let mut wet = [[[0.0; 2]; 64]; 7];
        for ts in 0..slots {
            self.advance();
            for (de, &enabled) in metadata.decorrelators.iter().enumerate() {
                wet[de] = [[0.0; 2]; 64];
                if !enabled {
                    continue;
                }
                let mut pre = [[0.0; 2]; 64];
                for (ch, plane) in input.iter().enumerate() {
                    for (sb, sample) in pre.iter_mut().enumerate() {
                        let gain = self.pre[de * self.downmix + ch][sb].value;
                        for (component, &source) in sample.iter_mut().zip(&plane[ts][sb]) {
                            *component += source * gain;
                        }
                    }
                }
                if pre.iter().flatten().any(|x| !x.is_finite()) {
                    return Err(invalid("non-finite A-JOC decorrelator input"));
                }
                backend.process(de, &pre, &mut wet[de])?;
                if wet[de].iter().flatten().any(|x| !x.is_finite()) {
                    return Err(invalid("non-finite A-JOC decorrelator output"));
                }
            }
            for (o, object) in metadata.objects.iter().enumerate() {
                if !object.present {
                    continue;
                }
                for sb in 0..64 {
                    for component in 0..2 {
                        let dry = input
                            .iter()
                            .enumerate()
                            .map(|(ch, plane)| {
                                plane[ts][sb][component] * self.dry[o * self.downmix + ch][sb].value
                            })
                            .sum::<f32>();
                        let diffuse = wet[..self.decorrelators]
                            .iter()
                            .enumerate()
                            .map(|(de, plane)| {
                                plane[sb][component]
                                    * self.wet[o * self.decorrelators + de][sb].value
                            })
                            .sum::<f32>();
                        let sample = dry + diffuse;
                        if !sample.is_finite() {
                            return Err(invalid("non-finite A-JOC reconstruction"));
                        }
                        output[o][ts][sb][component] = sample;
                    }
                }
            }
            // A start at ts affects subsequent slots; retain the old value in
            // this slot, then reach the target in exactly ramp slots. Retain
            // unfinished ramps across frames, including frames with no points.
            for (dp, point) in metadata.points.iter().enumerate() {
                if point.start as usize == ts {
                    self.update(metadata, dp);
                }
            }
        }
        Ok(())
    }
}

fn coefficient(o: &ObjectMatrix, dp: usize, input: usize, band: usize, wet: bool) -> f32 {
    let rows = if wet { &o.wet } else { &o.dry };
    rows[dp][input].as_ref().map_or(0.0, |m| m.gains[band])
}

/// Reusable dry/wet reconstruction engine. Produces object QMF planes, not
/// speaker feeds or PCM. LFE and object rendering remain the caller's concern.
/// An explicit decorrelation backend is required.
#[derive(Default)]
pub struct Reconstructor {
    state: Option<State>,
}

impl Reconstructor {
    /// Clear matrix histories. Reset the backend separately on seek/new stream.
    pub fn reset(&mut self) {
        self.state = None;
    }

    /// Reuse output storage; dimensions may change only after reset. Metadata
    /// and input are validated before modifying histories or calling a backend.
    /// A backend/arithmetic failure clears output and resets both histories.
    pub fn process_into(
        &mut self,
        metadata: &AjocMetadata,
        input: &[Vec<QmfSlot>],
        backend: &mut impl Decorrelation,
        output: &mut QmfPlanes,
    ) -> Result<()> {
        if let Err(error) = validate(metadata, input) {
            output.clear();
            return Err(error);
        }
        let dims = (
            input.len(),
            metadata.objects.len(),
            metadata.decorrelators.len(),
        );
        if let Some(s) = &self.state
            && dims != (s.downmix, s.objects, s.decorrelators)
        {
            output.clear();
            return Err(invalid(
                "A-JOC reconstruction dimensions changed; reset required",
            ));
        }
        let state = self
            .state
            .get_or_insert_with(|| State::new(dims.0, dims.1, dims.2));
        output.resize_with(dims.1, Vec::new);
        for plane in output.iter_mut() {
            plane.resize(input[0].len(), [[0.0; 2]; 64]);
            plane.fill([[0.0; 2]; 64]);
        }
        if let Err(error) = state.run(metadata, input, backend, output) {
            output.clear();
            self.reset();
            backend.reset();
            return Err(error);
        }
        Ok(())
    }
}

fn validate(metadata: &AjocMetadata, input: &[Vec<QmfSlot>]) -> Result<()> {
    if !(1..=16).contains(&input.len())
        || !(1..=64).contains(&metadata.objects.len())
        || metadata.decorrelators.len() > 7
        || metadata.points.len() > 2
    {
        return Err(invalid("A-JOC reconstruction dimensions"));
    }
    let slots = input[0].len();
    if !(1..=32).contains(&slots)
        || input
            .iter()
            .any(|p| p.len() != slots || p.iter().flatten().flatten().any(|v| !v.is_finite()))
    {
        return Err(invalid("A-JOC QMF input"));
    }
    let mut previous = None;
    for point in &metadata.points {
        if point.start as usize >= slots
            || !(1..=64).contains(&point.ramp)
            || previous.is_some_and(|p| point.start <= p)
        {
            return Err(invalid("A-JOC parameter update timing"));
        }
        previous = Some(point.start);
    }
    for object in &metadata.objects {
        if !object.present || metadata.points.is_empty() {
            continue;
        }
        parameter_band(object.bands, 63)?;
        for (rows, count, bound) in [
            (&object.dry, input.len(), 5.005),
            (&object.wet, metadata.decorrelators.len(), 2.002),
        ] {
            if rows.len() != metadata.points.len() {
                return Err(invalid("A-JOC matrix point count"));
            }
            for row in rows {
                if row.len() != count {
                    return Err(invalid("A-JOC matrix input count"));
                }
                for element in row.iter().flatten() {
                    if element.gains.len() != object.bands
                        || element
                            .gains
                            .iter()
                            .any(|v| !v.is_finite() || v.abs() > bound)
                    {
                        return Err(invalid("A-JOC matrix gain"));
                    }
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
