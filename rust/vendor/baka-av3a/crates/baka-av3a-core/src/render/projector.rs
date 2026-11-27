use super::{
    BedLayout, ObjectGains, SpatialObject,
    panner::{PointPanner, direction, dot},
};
use crate::Error;
use std::sync::Arc;

fn split(amplitude: [f64; 12], object: PolarObject) -> ([f32; 12], [f32; 12]) {
    let mut direct = [0.0; 12];
    let mut diffuse = [0.0; 12];
    for i in 0..12 {
        let value = amplitude[i] * object.gain;
        direct[i] = (value * (1.0 - object.diffuse).sqrt()) as f32;
        diffuse[i] = (value * object.diffuse.sqrt()) as f32;
    }
    (direct, diffuse)
}

/// Polar object parameters, in degrees and distance units consistent with depth.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PolarObject {
    pub azimuth: f64,
    pub elevation: f64,
    pub distance: f64,
    pub width: f64,
    pub height: f64,
    pub depth: f64,
    pub gain: f64,
    pub diffuse: f64,
}

impl Default for PolarObject {
    fn default() -> Self {
        Self {
            azimuth: 0.0,
            elevation: 0.0,
            distance: 1.0,
            width: 0.0,
            height: 0.0,
            depth: 0.0,
            gain: 1.0,
            diffuse: 0.0,
        }
    }
}

impl PolarObject {
    pub(super) fn validate(self) -> Result<(), Error> {
        let values = [
            self.azimuth,
            self.elevation,
            self.distance,
            self.width,
            self.height,
            self.depth,
            self.gain,
            self.diffuse,
        ];
        if values.iter().any(|v| !v.is_finite())
            || !(-90.0..=90.0).contains(&self.elevation)
            || !(0.0..=1e6).contains(&self.distance)
            || !(0.0..=360.0).contains(&self.width)
            || !(0.0..=360.0).contains(&self.height)
            || !(0.0..=1e6).contains(&self.depth)
            || !(0.0..=16.0).contains(&self.gain)
            || !(0.0..=1.0).contains(&self.diffuse)
        {
            return Err(Error::Invalid("polar object parameters"));
        }
        Ok(())
    }
}

#[derive(Debug)]
struct Sample {
    direction: [f64; 3],
    gains: [f64; 12],
}

#[derive(Debug)]
struct Plan {
    point: PointPanner,
    sphere: Vec<Sample>,
}

/// Projects polar point and extended objects onto a fixed loudspeaker layout.
///
/// Prepare once outside the audio callback. Clones share immutable geometry and
/// the precomputed spherical integration grid. Projection allocates the two
/// returned gain vectors; applying those gains to PCM does not allocate.
#[derive(Clone, Debug)]
pub struct ObjectProjector {
    layout: BedLayout,
    plan: Arc<Plan>,
}

impl ObjectProjector {
    pub fn new(layout: BedLayout) -> Result<Self, Error> {
        let point = PointPanner::new(layout);
        let mut sphere = Vec::new();
        for row in 0..37 {
            let elevation = -90.0 + 5.0 * f64::from(row);
            let count = (72.0 * elevation.to_radians().cos()).round().max(1.0) as usize;
            for index in 0..count {
                let direction = direction(360.0 * index as f64 / count as f64, elevation);
                sphere.push(Sample {
                    direction,
                    gains: point.pan(direction)?,
                });
            }
        }
        Ok(Self {
            layout,
            plan: Arc::new(Plan { point, sphere }),
        })
    }

    pub fn output_layout(&self) -> BedLayout {
        self.layout
    }

    pub fn project(&self, object: PolarObject) -> Result<ObjectGains, Error> {
        let (direct, diffuse) = self.coefficients(object)?;
        let outputs = usize::from(self.layout.channels());
        ObjectGains::new(direct[..outputs].to_vec(), diffuse[..outputs].to_vec())
    }

    /// Update existing output vectors without allocating. Errors preserve them.
    pub fn project_into(&self, object: PolarObject, output: &mut ObjectGains) -> Result<(), Error> {
        let outputs = usize::from(self.layout.channels());
        if output.direct.len() != outputs {
            return Err(Error::Invalid("object output layout"));
        }
        let (direct, diffuse) = self.coefficients(object)?;
        output.direct.copy_from_slice(&direct[..outputs]);
        output.diffuse.copy_from_slice(&diffuse[..outputs]);
        Ok(())
    }

    pub fn project_controlled(&self, object: SpatialObject) -> Result<ObjectGains, Error> {
        let outputs = usize::from(self.layout.channels());
        let mut gains = ObjectGains::new(vec![0.0; outputs], vec![0.0; outputs])?;
        self.project_controlled_into(object, &mut gains)?;
        Ok(gains)
    }

    /// Lock position to a nearby speaker, then distribute divergence in power.
    /// Errors preserve both vectors; valid updates do not allocate.
    pub fn project_controlled_into(
        &self,
        object: SpatialObject,
        output: &mut ObjectGains,
    ) -> Result<(), Error> {
        object.object.validate()?;
        if output.direct.len() != usize::from(self.layout.channels()) {
            return Err(Error::Invalid("object output layout"));
        }
        let sources = object.controls.sources(self.layout, object.object)?;
        if sources[0].1 == 1.0 {
            return self.project_into(sources[0].0, output);
        }
        let mut power = [0.0; 12];
        for (source, weight) in sources {
            if weight == 0.0 {
                continue;
            }
            let amplitude = self.amplitude(source)?;
            for (power, amplitude) in power.iter_mut().zip(amplitude) {
                *power += weight * amplitude * amplitude;
            }
        }
        let (direct, diffuse) = split(power.map(f64::sqrt), object.object);
        let count = output.direct.len();
        output.direct.copy_from_slice(&direct[..count]);
        let count = output.diffuse.len();
        output.diffuse.copy_from_slice(&diffuse[..count]);
        Ok(())
    }

    fn coefficients(&self, object: PolarObject) -> Result<([f32; 12], [f32; 12]), Error> {
        object.validate()?;
        Ok(split(self.amplitude(object)?, object))
    }

    fn amplitude(&self, object: PolarObject) -> Result<[f64; 12], Error> {
        let mut object = object;
        object.azimuth = (object.azimuth + 180.0).rem_euclid(360.0) - 180.0;
        let position = direction(object.azimuth, object.elevation);
        let near = (object.distance - object.depth / 2.0).max(0.0);
        let far = object.distance + object.depth / 2.0;
        let a = self.spread(position, object, near)?;
        let b = if object.depth == 0.0 {
            a
        } else {
            self.spread(position, object, far)?
        };
        let outputs = usize::from(self.layout.channels());
        let mut values = [0.0; 12];
        for i in 0..outputs {
            values[i] = ((a[i] * a[i] + b[i] * b[i]) * 0.5).sqrt();
        }
        Ok(values)
    }

    fn spread(
        &self,
        position: [f64; 3],
        object: PolarObject,
        distance: f64,
    ) -> Result<[f64; 12], Error> {
        let width = angular_size(object.width, distance);
        let height = angular_size(object.height, distance);
        let fraction = (width.max(height) / 10.0).clamp(0.0, 1.0);
        let point = self.plan.point.pan(position)?;
        if fraction == 0.0 {
            return Ok(point);
        }
        let shape = Shape::new(
            object.azimuth,
            object.elevation,
            width.max(5.0),
            height.max(5.0),
        );
        let mut spread = [0.0; 12];
        let outputs = usize::from(self.layout.channels());
        for sample in &self.plan.sphere {
            let weight = shape.weight(sample.direction);
            if weight == 0.0 {
                continue;
            }
            for (target, gain) in spread[..outputs].iter_mut().zip(&sample.gains) {
                *target += weight * gain;
            }
        }
        let norm = spread.iter().map(|v| v * v).sum::<f64>().sqrt();
        if norm == 0.0 {
            return Err(Error::Invalid("empty object extent"));
        }
        for i in 0..outputs {
            let distributed = spread[i] / norm;
            spread[i] = ((1.0 - fraction) * point[i] * point[i]
                + fraction * distributed * distributed)
                .sqrt();
        }
        Ok(spread)
    }
}

fn angular_size(extent: f64, distance: f64) -> f64 {
    let radius = 0.2 + 0.8 * extent / 360.0;
    let reference = 4.0 * radius.atan().to_degrees();
    let angle = 4.0 * radius.atan2(distance).to_degrees();
    if angle <= reference {
        extent * angle / reference
    } else {
        extent + (360.0 - extent) * (angle - reference) / (360.0 - reference)
    }
}

struct Shape {
    horizontal: [f64; 3],
    forward: [f64; 3],
    vertical: [f64; 3],
    arc: f64,
    radius: f64,
}

impl Shape {
    fn new(azimuth: f64, elevation: f64, width: f64, height: f64) -> Self {
        let azimuth = if elevation.abs() > 90.0 - 1e-5 {
            0.0
        } else {
            azimuth
        };
        let (a, c) = azimuth.to_radians().sin_cos();
        let (z, r) = elevation.to_radians().sin_cos();
        let mut horizontal = [c, -a, 0.0];
        let mut vertical = [-a * z, -c * z, r];
        let forward = [a * r, c * r, z];
        let mut half_width = width.to_radians() / 2.0;
        let mut half_height = height.to_radians() / 2.0;
        if half_height > half_width {
            std::mem::swap(&mut half_width, &mut half_height);
            let old = horizontal;
            horizontal = vertical;
            vertical = old.map(|v| -v);
        }
        let quarter = std::f64::consts::FRAC_PI_4;
        let wrap = ((half_width - 2.0 * quarter) / (2.0 * quarter)).max(0.0);
        let fade = 1.0 - ((half_height - quarter) / quarter).clamp(0.0, 1.0);
        half_width += wrap * half_height * fade;
        Self {
            horizontal,
            forward,
            vertical,
            arc: half_width - half_height,
            radius: half_height,
        }
    }

    fn weight(&self, point: [f64; 3]) -> f64 {
        let x = dot(point, self.horizontal).abs();
        let y = dot(point, self.forward);
        let z = dot(point, self.vertical).abs().clamp(0.0, 1.0);
        let azimuth = x.atan2(y);
        let distance = if azimuth <= self.arc {
            z.asin()
        } else {
            let (s, c) = self.arc.sin_cos();
            (x * s + y * c).clamp(-1.0, 1.0).acos()
        };
        ((self.radius + 10.0_f64.to_radians() - distance) / 10.0_f64.to_radians()).clamp(0.0, 1.0)
    }
}
