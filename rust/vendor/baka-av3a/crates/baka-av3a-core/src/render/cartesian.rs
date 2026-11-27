use super::{BedLayout, ObjectGains};
use crate::Error;
use std::sync::Arc;

const XY: usize = 40;
const Z: usize = 20;
const FLOOR: f64 = 3.162277660168379e-7;

/// Room-relative object. +X is right, +Y front and +Z up. Coordinates are
/// in `[-1,1]`; size is the normalized extent on X/Y/Z, each in `[0,1]`.
/// Size is independent of polar angular width/height/depth.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CartesianObject {
    pub position: [f64; 3],
    pub size: [f64; 3],
    pub gain: f64,
    pub diffuse: f64,
}

impl Default for CartesianObject {
    fn default() -> Self {
        Self {
            position: [0.0, 1.0, 0.0],
            size: [0.0; 3],
            gain: 1.0,
            diffuse: 0.0,
        }
    }
}

impl CartesianObject {
    pub(super) fn validate(self) -> Result<(), Error> {
        if self
            .position
            .iter()
            .any(|v| !v.is_finite() || !(-1.0..=1.0).contains(v))
            || self
                .size
                .iter()
                .any(|v| !v.is_finite() || !(0.0..=1.0).contains(v))
            || !self.gain.is_finite()
            || !(0.0..=16.0).contains(&self.gain)
            || !self.diffuse.is_finite()
            || !(0.0..=1.0).contains(&self.diffuse)
        {
            return Err(Error::Invalid("Cartesian object parameters"));
        }
        Ok(())
    }
}

/// Room-coordinate controls. Lock candidates use Euclidean distance; selection
/// weights X/Y/Z by 1/16, 4 and 32. Divergence moves side sources along X.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CartesianControls {
    pub channel_lock: Option<f64>,
    pub divergence: f64,
    /// Side-source displacement in room coordinates, in `[0,1]`.
    pub position_range: f64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CartesianSpatialObject {
    pub object: CartesianObject,
    pub controls: CartesianControls,
}

impl From<CartesianObject> for CartesianSpatialObject {
    fn from(object: CartesianObject) -> Self {
        Self {
            object,
            controls: CartesianControls::default(),
        }
    }
}

#[derive(Debug)]
struct Plan {
    positions: [Option<[f64; 3]>; 12],
    axes: [[[f64; XY]; 3]; 12],
    dimension: usize,
}

/// Cartesian point and cuboid extent projection onto the seven bed layouts.
/// LFE output is silent. Immutable integration tables are shared by clones.
/// Construct outside the callback; project_into does not allocate. Returned
/// gains can be supplied to GainRenderer, including its frame jump API.
#[derive(Clone, Debug)]
pub struct CartesianProjector {
    layout: BedLayout,
    plan: Arc<Plan>,
}

impl CartesianProjector {
    pub fn new(layout: BedLayout) -> Self {
        let mut positions = [None; 12];
        for (slot, name) in positions.iter_mut().zip(layout.speaker_names()) {
            if name.starts_with("LFE") {
                continue;
            }
            let azimuth: i16 = name[1..].parse().expect("fixed speaker angle");
            let x = -f64::from(azimuth.signum());
            let y = match azimuth.abs() {
                0 | 30 | 45 => 1.0,
                90 => 0.0,
                _ => -1.0,
            };
            *slot = Some([x, y, if name.starts_with('U') { 1.0 } else { 0.0 }]);
        }
        let first = positions[0].expect("fixed front speaker");
        let dimension = (0..3)
            .filter(|&axis| positions.iter().flatten().any(|p| p[axis] != first[axis]))
            .count();
        let mut axes = [[[0.0; XY]; 3]; 12];
        for (i, position) in positions.iter().enumerate() {
            let Some(position) = position else {
                continue;
            };
            for (axis, samples) in axes[i].iter_mut().enumerate() {
                let count = if axis == 2 { Z } else { XY };
                for (sample, value) in samples[..count].iter_mut().enumerate() {
                    *value = axis_gain(&positions, *position, axis, coordinate(axis, sample));
                }
            }
        }
        Self {
            layout,
            plan: Arc::new(Plan {
                positions,
                axes,
                dimension,
            }),
        }
    }

    pub fn output_layout(&self) -> BedLayout {
        self.layout
    }

    pub fn project(&self, object: CartesianObject) -> Result<ObjectGains, Error> {
        let count = usize::from(self.layout.channels());
        let mut gains = ObjectGains::new(vec![0.0; count], vec![0.0; count])?;
        self.project_into(object, &mut gains)?;
        Ok(gains)
    }

    /// Reject invalid parameters or mismatched output before changing either vector.
    pub fn project_into(
        &self,
        object: CartesianObject,
        output: &mut ObjectGains,
    ) -> Result<(), Error> {
        object.validate()?;
        let count = usize::from(self.layout.channels());
        if output.direct.len() != count || output.diffuse.len() != count {
            return Err(Error::Invalid("Cartesian output layout"));
        }
        let amplitude = self.amplitude(object);
        for (i, amplitude) in amplitude[..count].iter().enumerate() {
            output.direct[i] = (amplitude * object.gain * (1.0 - object.diffuse).sqrt()) as f32;
            output.diffuse[i] = (amplitude * object.gain * object.diffuse.sqrt()) as f32;
        }
        Ok(())
    }

    pub fn project_controlled(&self, object: CartesianSpatialObject) -> Result<ObjectGains, Error> {
        let count = usize::from(self.layout.channels());
        let mut gains = ObjectGains::new(vec![0.0; count], vec![0.0; count])?;
        self.project_controlled_into(object, &mut gains)?;
        Ok(gains)
    }

    /// Lock before divergence, combine source powers, then split direct/diffuse.
    /// Invalid updates preserve output; this method does not allocate.
    pub fn project_controlled_into(
        &self,
        value: CartesianSpatialObject,
        output: &mut ObjectGains,
    ) -> Result<(), Error> {
        value.object.validate()?;
        let controls = value.controls;
        if !controls.divergence.is_finite()
            || !(0.0..=1.0).contains(&controls.divergence)
            || !controls.position_range.is_finite()
            || !(0.0..=1.0).contains(&controls.position_range)
            || controls
                .channel_lock
                .is_some_and(|v| !v.is_finite() || !(0.0..=4.0).contains(&v))
        {
            return Err(Error::Invalid("Cartesian spatial controls"));
        }
        let count = usize::from(self.layout.channels());
        if output.direct.len() != count || output.diffuse.len() != count {
            return Err(Error::Invalid("Cartesian output layout"));
        }
        let mut object = value.object;
        if let Some(limit) = controls.channel_lock {
            object.position = self.lock(object.position, limit);
        }
        if controls.divergence == 0.0 || controls.position_range == 0.0 {
            return self.project_into(object, output);
        }
        let side = controls.divergence / (1.0 + controls.divergence);
        let mut power = [0.0; 12];
        for (offset, weight) in [
            (
                0.0,
                (1.0 - controls.divergence) / (1.0 + controls.divergence),
            ),
            (controls.position_range, side),
            (-controls.position_range, side),
        ] {
            if weight == 0.0 {
                continue;
            }
            let mut source = object;
            source.position[0] = (source.position[0] + offset).clamp(-1.0, 1.0);
            for (power, amplitude) in power.iter_mut().zip(self.amplitude(source)) {
                *power += weight * amplitude * amplitude;
            }
        }
        for (i, power) in power[..count].iter().enumerate() {
            output.direct[i] = (power.sqrt() * object.gain * (1.0 - object.diffuse).sqrt()) as f32;
            output.diffuse[i] = (power.sqrt() * object.gain * object.diffuse.sqrt()) as f32;
        }
        Ok(())
    }

    fn lock(&self, position: [f64; 3], limit: f64) -> [f64; 3] {
        let mut distances = [f64::INFINITY; 12];
        for (i, speaker) in self.plan.positions.iter().enumerate() {
            let Some(speaker) = speaker else {
                continue;
            };
            let delta: [f64; 3] = std::array::from_fn(|i| position[i] - speaker[i]);
            if delta.iter().map(|v| v * v).sum::<f64>().sqrt() < limit + 1e-5 {
                distances[i] = (delta[0] * delta[0] / 16.0
                    + 4.0 * delta[1] * delta[1]
                    + 32.0 * delta[2] * delta[2])
                    .sqrt();
            }
        }
        let closest = distances.iter().copied().fold(f64::INFINITY, f64::min);
        let mut choice: Option<([i16; 4], [f64; 3])> = None;
        for (i, name) in self.layout.speaker_names().iter().enumerate() {
            if distances[i] < closest + 1e-5 {
                let azimuth: i16 = name[1..].parse().expect("fixed speaker angle");
                let elevation: i16 = if name.starts_with('U') { 30 } else { 0 };
                let priority = [elevation.abs(), elevation, azimuth.abs(), azimuth];
                if choice.as_ref().is_none_or(|(old, _)| priority < *old) {
                    choice = Some((priority, self.plan.positions[i].unwrap()));
                }
            }
        }
        choice.map_or(position, |(_, position)| position)
    }

    fn point(&self, position: [f64; 3]) -> [f64; 12] {
        std::array::from_fn(|i| {
            self.plan.positions[i].map_or(0.0, |speaker| {
                (0..3)
                    .map(|axis| axis_gain(&self.plan.positions, speaker, axis, position[axis]))
                    .product()
            })
        })
    }

    fn amplitude(&self, object: CartesianObject) -> [f64; 12] {
        if object.size == [0.0; 3] {
            return self.point(object.position);
        }
        let position = [
            object.position[0],
            object.position[1],
            object.position[2].max(0.0),
        ];
        let sizes: [f64; 3] = std::array::from_fn(|axis| {
            scale_size(object.size[axis]).max(2.0 / (if axis == 2 { Z - 1 } else { XY - 1 }) as f64)
        });
        let mut sorted = sizes;
        sorted[..self.plan.dimension].sort_by(f64::total_cmp);
        let effective = match self.plan.dimension {
            1 => sizes[0],
            2 => (sorted[0] + 3.0 * sorted[1]) / 4.0,
            _ => (sorted[0] + 2.0 * sorted[1] + 6.0 * sorted[2]) / 9.0,
        };
        let exponent = if effective <= 0.5 {
            6.0
        } else {
            6.0 - 4.0 * (effective - 0.5) / 2.3
        };
        let mut weights = [[0.0; XY]; 3];
        for axis in 0..3 {
            let count = if axis == 2 { Z } else { XY };
            for (i, weight) in weights[axis][..count].iter_mut().enumerate() {
                let value = coordinate(axis, i);
                let distance =
                    (if axis == 2 { 1.5 } else { 0.75 }) * (value - position[axis]) / sizes[axis];
                *weight = 10.0_f64.powf(-distance.powi(4).min(6.5));
                if axis == 2 {
                    *weight *= (value * std::f64::consts::PI * 3.0 / 7.0).cos();
                }
            }
        }
        let mut integral = [[0.0; 3]; 12];
        let mut boundary = [[0.0; 3]; 12];
        for (i, speaker) in self.plan.axes.iter().enumerate() {
            for axis in 0..3 {
                let count = if axis == 2 { Z } else { XY };
                let sum: f64 = speaker[axis][..count]
                    .iter()
                    .zip(&weights[axis])
                    .map(|(a, b)| (a * b).powf(exponent))
                    .sum();
                integral[i][axis] = if sum < FLOOR { 0.0 } else { sum };
                boundary[i][axis] = (speaker[axis][0] * weights[axis][0]).powf(exponent)
                    + (speaker[axis][count - 1] * weights[axis][count - 1]).powf(exponent);
            }
        }
        let inside = normalize(std::array::from_fn(|i| integral[i].iter().product()));
        let edge_distance = position[..self.plan.dimension]
            .iter()
            .map(|v| 1.0 - v.abs())
            .fold(f64::INFINITY, f64::min);
        let volume: f64 = sizes[..self.plan.dimension]
            .iter()
            .map(|&size| {
                if edge_distance >= (2.0 * size).max(0.4) {
                    (2.0 * size).max(0.4).powi(3) / (0.32 * size)
                } else {
                    edge_distance.powi(3) / 0.32
                }
            })
            .product();
        let mu = volume.powf(1.0 / self.plan.dimension as f64);
        let extended = normalize(std::array::from_fn(|i| {
            let [x, y, z] = integral[i];
            let [bx, by, bz] = boundary[i];
            (bx * y * z + x * by * z + x * y * bz + mu * inside[i]).powf(1.0 / exponent)
        }));
        let point = self.point(position);
        let (alpha, beta) = if effective < 0.2 {
            let (s, c) = (effective * std::f64::consts::PI / 0.4).sin_cos();
            (c, s)
        } else {
            (0.0, 1.0)
        };
        normalize(std::array::from_fn(|i| {
            alpha * point[i] + beta * extended[i]
        }))
    }
}

fn coordinate(axis: usize, index: usize) -> f64 {
    if axis == 2 {
        index as f64 / (Z - 1) as f64
    } else {
        -1.0 + 2.0 * index as f64 / (XY - 1) as f64
    }
}

fn normalize(mut values: [f64; 12]) -> [f64; 12] {
    let norm = values.iter().map(|v| v * v).sum::<f64>().sqrt();
    if norm > 1e-16 {
        for value in &mut values {
            *value /= norm;
        }
    } else {
        values.fill(0.0);
    }
    values
}

fn scale_size(value: f64) -> f64 {
    let knots = [0.0, 0.2, 0.5, 0.75, 1.0];
    let sizes = [0.0, 0.3, 1.0, 1.8, 2.8];
    let i = (0..3).find(|&i| value < knots[i + 1]).unwrap_or(3);
    sizes[i] + (sizes[i + 1] - sizes[i]) * (value - knots[i]) / (knots[i + 1] - knots[i])
}

// Select bounding planes, then rows, then columns. Missing outer bounds use
// the nearest surface, so planar layouts also support positions above/below.
fn axis_gain(
    positions: &[Option<[f64; 3]>; 12],
    speaker: [f64; 3],
    axis: usize,
    value: f64,
) -> f64 {
    let mut lower = f64::NEG_INFINITY;
    let mut upper = f64::INFINITY;
    for position in positions.iter().flatten() {
        if position[axis + 1..] != speaker[axis + 1..] {
            continue;
        }
        if position[axis] <= value {
            lower = lower.max(position[axis]);
        }
        if position[axis] >= value {
            upper = upper.min(position[axis]);
        }
    }
    if !lower.is_finite() {
        lower = upper;
    }
    if !upper.is_finite() {
        upper = lower;
    }
    let current = speaker[axis];
    if current < lower || current > upper {
        0.0
    } else if lower == upper {
        1.0
    } else {
        let angle = (value - lower) / (upper - lower) * std::f64::consts::FRAC_PI_2;
        if current == lower {
            angle.cos()
        } else {
            angle.sin()
        }
    }
}
