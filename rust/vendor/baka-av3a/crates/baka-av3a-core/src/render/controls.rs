use super::{
    BedLayout, PolarObject,
    panner::{direction, dot},
};
use crate::Error;

/// Polar spatial controls, applied before extent projection.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PolarControls {
    /// Maximum Euclidean distance to a unit-radius, non-LFE speaker, in
    /// `[0,1_000_001]`. None disables locking. All controls must be finite.
    pub channel_lock: Option<f64>,
    /// Power distribution between the centre and two lateral sources, in `[0,1]`.
    pub divergence: f64,
    /// Angle of each lateral source in the object's local horizontal plane, in degrees `[0,180]`.
    pub azimuth_range: f64,
}

/// Polar object with optional speaker locking and divergence.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SpatialObject {
    pub object: PolarObject,
    pub controls: PolarControls,
}

impl From<PolarObject> for SpatialObject {
    fn from(object: PolarObject) -> Self {
        Self {
            object,
            controls: PolarControls::default(),
        }
    }
}

impl PolarControls {
    pub(super) fn sources(
        self,
        layout: BedLayout,
        mut object: PolarObject,
    ) -> Result<[(PolarObject, f64); 3], Error> {
        if !self.divergence.is_finite()
            || !(0.0..=1.0).contains(&self.divergence)
            || !self.azimuth_range.is_finite()
            || !(0.0..=180.0).contains(&self.azimuth_range)
            || self
                .channel_lock
                .is_some_and(|v| !v.is_finite() || !(0.0..=1_000_001.0).contains(&v))
        {
            return Err(Error::Invalid("polar spatial controls"));
        }
        object.azimuth = (object.azimuth + 180.0).rem_euclid(360.0) - 180.0;
        let object = match self.channel_lock {
            Some(limit) => lock(layout, object, limit),
            None => object,
        };
        let mut result = [(object, 0.0); 3];
        if self.divergence == 0.0 || self.azimuth_range == 0.0 {
            result[0].1 = 1.0;
            return Ok(result);
        }
        let side = self.divergence / (1.0 + self.divergence);
        result[0].1 = (1.0 - self.divergence) / (1.0 + self.divergence);
        let front = direction(object.azimuth, object.elevation);
        let tangent = direction(object.azimuth + 90.0, 0.0);
        let (sine, cosine) = self.azimuth_range.to_radians().sin_cos();
        for (entry, sign) in result[1..].iter_mut().zip([1.0, -1.0]) {
            let ray: [f64; 3] =
                std::array::from_fn(|i| front[i] * cosine + tangent[i] * sine * sign);
            entry.0.azimuth = ray[0].atan2(ray[1]).to_degrees();
            entry.0.elevation = ray[2].atan2(ray[0].hypot(ray[1])).to_degrees();
            entry.1 = side;
        }
        Ok(result)
    }
}

fn speaker(name: &str) -> Option<(f64, f64)> {
    if name.starts_with("LFE") {
        return None;
    }
    let azimuth = name[1..].parse().expect("fixed speaker azimuth");
    Some((azimuth, if name.starts_with('U') { 30.0 } else { 0.0 }))
}

fn lock(layout: BedLayout, mut object: PolarObject, limit: f64) -> PolarObject {
    let ray = direction(object.azimuth, object.elevation);
    let position = ray.map(|v| v * object.distance);
    let mut distances = [f64::INFINITY; 12];
    for (i, name) in layout.speaker_names().iter().enumerate() {
        if let Some((azimuth, elevation)) = speaker(name) {
            let target = direction(azimuth, elevation);
            let delta = std::array::from_fn(|i| position[i] - target[i]);
            let distance = dot(delta, delta).sqrt();
            if distance < limit + 1e-5 {
                distances[i] = distance;
            }
        }
    }
    let closest = distances.iter().copied().fold(f64::INFINITY, f64::min);
    let mut choice: Option<([f64; 4], f64, f64)> = None;
    for (i, name) in layout.speaker_names().iter().enumerate() {
        if distances[i] < closest + 1e-5 {
            let (azimuth, elevation) = speaker(name).unwrap();
            let priority = [elevation.abs(), elevation, azimuth.abs(), azimuth];
            if choice.as_ref().is_none_or(|(old, _, _)| priority < *old) {
                choice = Some((priority, azimuth, elevation));
            }
        }
    }
    if let Some((_, azimuth, elevation)) = choice {
        object.azimuth = azimuth;
        object.elevation = elevation;
        object.distance = 1.0;
    }
    object
}
