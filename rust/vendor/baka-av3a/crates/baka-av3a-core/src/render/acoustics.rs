use super::{BinauralSource, ListenerPose};
use crate::{
    Error,
    metadata::{AcousticEnvironment, Surface},
};
use std::sync::Arc;

const MAX_SURFACES: usize = 8;
const MAX_VERTICES: usize = 36;
const EPS: f64 = 1e-7;
type Point = [f64; 3];

/// Eight energy absorption/scattering coefficient pairs in transmitted order.
/// This type does not guess centre frequencies for those bands.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AcousticMaterial {
    bands: [[f64; 2]; 8],
}
impl AcousticMaterial {
    pub fn new(bands: [[f64; 2]; 8]) -> Result<Self, Error> {
        if bands
            .iter()
            .flatten()
            .any(|v| !v.is_finite() || !(0.0..=1.0).contains(v))
        {
            return Err(Error::Invalid("acoustic material energy coefficient"));
        }
        Ok(Self { bands })
    }
    pub fn bands(self) -> [[f64; 2]; 8] {
        self.bands
    }
    /// Positive real pressure coefficients for the specular contribution.
    /// Scattered energy is excluded, not silently converted to another mirror.
    pub fn specular_pressure(self) -> [f64; 8] {
        self.bands
            .map(|[absorption, scattering]| ((1.0 - absorption) * (1.0 - scattering)).sqrt())
    }
    pub fn scattered_energy(self) -> [f64; 8] {
        self.bands
            .map(|[absorption, scattering]| (1.0 - absorption) * scattering)
    }
}

/// One planar, strictly convex polygon, with either winding and 3..36 vertices.
/// Coordinates are metres: +X right, +Y front, +Z up. Walls are two-sided for
/// occlusion; no volume or inward-normal convention is inferred.
#[derive(Clone, Debug)]
pub struct AcousticSurface {
    vertices: Vec<Point>,
    normal: Point,
    material: AcousticMaterial,
    area: f64,
}
impl AcousticSurface {
    pub fn new(vertices: &[Point], material: AcousticMaterial) -> Result<Self, Error> {
        if !(3..=MAX_VERTICES).contains(&vertices.len()) {
            return Err(Error::Invalid("acoustic polygon vertex count"));
        }
        for &vertex in vertices {
            validate_position(vertex)?;
        }
        for (i, &a) in vertices.iter().enumerate() {
            if vertices[i + 1..].iter().any(|&b| norm(sub(a, b)) < EPS) {
                return Err(Error::Invalid("duplicate acoustic polygon vertex"));
            }
        }
        let origin = vertices[0];
        let mut area_normal = [0.0; 3];
        for edge in vertices[1..].windows(2) {
            area_normal = add(
                area_normal,
                cross(sub(edge[0], origin), sub(edge[1], origin)),
            );
        }
        let twice_area = norm(area_normal);
        if twice_area < 1e-8 {
            return Err(Error::Invalid("degenerate acoustic polygon"));
        }
        let normal = scale(area_normal, twice_area.recip());
        if vertices
            .iter()
            .any(|&v| dot(sub(v, origin), normal).abs() > EPS)
        {
            return Err(Error::Invalid("nonplanar acoustic polygon"));
        }
        // Every other vertex must lie strictly inside every oriented edge.
        // This also rejects collinear corners, crossed winding and concavity.
        for i in 0..vertices.len() {
            let a = vertices[i];
            let j = (i + 1) % vertices.len();
            let edge = sub(vertices[j], a);
            let length = norm(edge);
            for (k, &v) in vertices.iter().enumerate() {
                if k != i && k != j && dot(cross(edge, sub(v, a)), normal) <= EPS * length {
                    return Err(Error::Invalid("nonconvex acoustic polygon"));
                }
            }
        }
        Ok(Self {
            vertices: vertices.to_vec(),
            normal,
            material,
            area: twice_area * 0.5,
        })
    }
    pub fn from_metadata(
        surface: &Surface,
        materials: &[Option<AcousticMaterial>; 31],
    ) -> Result<Self, Error> {
        if !(3..=MAX_VERTICES).contains(&surface.vertices.len())
            || surface.material > 31
            || surface.vertices.iter().flatten().any(|v| *v > 127)
        {
            return Err(Error::Invalid("acoustic surface quantized fields"));
        }
        let material = if surface.material == 31 {
            let coefficients = surface
                .material_coefficients
                .ok_or(Error::Invalid("missing custom acoustic material"))?;
            if coefficients.iter().flatten().any(|v| *v > 127) {
                return Err(Error::Invalid("custom acoustic material index"));
            }
            AcousticMaterial::new(coefficients.map(|pair| pair.map(|v| f64::from(v) / 127.0)))?
        } else {
            if surface.material_coefficients.is_some() {
                return Err(Error::Invalid("unexpected custom acoustic material"));
            }
            materials[usize::from(surface.material)]
                .ok_or(Error::Unsupported("unresolved acoustic material preset"))?
        };
        let vertices: Vec<_> = surface
            .vertices
            .iter()
            .map(|v| v.map(|v| f64::from(i16::from(v) - 64) * (200.0 / 127.0)))
            .collect();
        Self::new(&vertices, material)
    }
    pub fn vertices(&self) -> &[Point] {
        &self.vertices
    }
    pub fn material(&self) -> AcousticMaterial {
        self.material
    }
    pub fn area_square_metres(&self) -> f64 {
        self.area
    }
    fn signed_distance(&self, p: Point) -> f64 {
        dot(sub(p, self.vertices[0]), self.normal)
    }
    fn contains(&self, p: Point) -> bool {
        self.vertices.iter().enumerate().all(|(i, &a)| {
            let edge = sub(self.vertices[(i + 1) % self.vertices.len()], a);
            dot(cross(edge, sub(p, a)), self.normal) >= -EPS * norm(edge)
        })
    }
    fn intersects_segment(&self, a: Point, b: Point) -> bool {
        let da = self.signed_distance(a);
        let db = self.signed_distance(b);
        // A ray coplanar with a surface has an ambiguous grazing path. Reject
        // it conservatively when the segment overlaps the polygon, including
        // a crossing with endpoints outside the polygon.
        if da.abs() <= EPS && db.abs() <= EPS {
            let mut low: f64 = 0.0;
            let mut high: f64 = 1.0;
            for (i, &v) in self.vertices.iter().enumerate() {
                let edge = sub(self.vertices[(i + 1) % self.vertices.len()], v);
                let first = dot(cross(edge, sub(a, v)), self.normal) / norm(edge);
                let last = dot(cross(edge, sub(b, v)), self.normal) / norm(edge);
                let delta = last - first;
                if delta.abs() < 1e-12 {
                    if first < -EPS {
                        return false;
                    }
                } else if delta > 0.0 {
                    low = low.max((-EPS - first) / delta);
                } else {
                    high = high.min((-EPS - first) / delta);
                }
            }
            return low <= high && high >= 0.0 && low <= 1.0;
        }
        if (da > EPS && db > EPS) || (da < -EPS && db < -EPS) {
            return false;
        }
        let denominator = da - db;
        if denominator.abs() < 1e-12 {
            return false;
        }
        let t = da / denominator;
        (0.0..=1.0).contains(&t) && self.contains(add(a, scale(sub(b, a), t)))
    }
}

/// A finite, unobstructed straight or once-reflected source-to-receiver path.
/// Image position encodes the arrival direction, not a new physical source.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AcousticPath {
    receiver: Point,
    image: Point,
    reflection: Option<Point>,
    surface: Option<usize>,
    distance: f64,
    specular: [f64; 8],
}
impl AcousticPath {
    pub fn image_position(self) -> Point {
        self.image
    }
    pub fn reflection_point(self) -> Option<Point> {
        self.reflection
    }
    pub fn surface_index(self) -> Option<usize> {
        self.surface
    }
    pub fn distance_metres(self) -> f64 {
        self.distance
    }
    pub fn specular_pressure(self) -> [f64; 8] {
        self.specular
    }
    /// Absolute propagation time, excluding filter/DSP alignment and HRIR delay.
    pub fn delay_samples(self, sample_rate: u32, speed_of_sound: f64) -> Result<f64, Error> {
        if !(8000..=192000).contains(&sample_rate)
            || !speed_of_sound.is_finite()
            || !(250.0..=400.0).contains(&speed_of_sound)
        {
            return Err(Error::Invalid("acoustic propagation rate or speed"));
        }
        Ok(self.distance * f64::from(sample_rate) / speed_of_sound)
    }
    /// Explicit inverse-distance pressure policy, unity at reference distance.
    /// Minimum distance caps gain for coincident/very close source positions.
    /// Material bands remain separate; no frequency-flat average is invented.
    pub fn pressure_gains(
        self,
        reference_distance: f64,
        minimum_distance: f64,
    ) -> Result<[f64; 8], Error> {
        if [reference_distance, minimum_distance]
            .iter()
            .any(|v| !v.is_finite() || !(0.001..=1000.0).contains(v))
        {
            return Err(Error::Invalid("acoustic distance gain reference"));
        }
        let spreading = reference_distance / self.distance.max(minimum_distance);
        Ok(self.specular.map(|v| v * spreading))
    }
    /// Direction only: no spectral or distance gain is folded into the HRIR
    /// target. The receiver must match the pose used to request this path.
    pub fn binaural_direction(self, listener: ListenerPose) -> Result<BinauralSource, Error> {
        if norm(sub(listener.position(), self.receiver)) > EPS {
            return Err(Error::Invalid("acoustic path listener position mismatch"));
        }
        let relative = listener.relative_position(self.image)?;
        let [x, y, z] = relative;
        Ok(BinauralSource {
            azimuth: if x == 0.0 && y == 0.0 {
                0.0
            } else {
                (-x).atan2(y).to_degrees()
            },
            elevation: z.atan2(x.hypot(y)).to_degrees(),
            gain: 1.0,
        })
    }
}

/// Prepared set of up to eight finite convex surfaces, total at most 36
/// vertices. It may describe an enclosure or obstacles; no closed-room volume,
/// late reverberation, diffraction or higher-order reflections are inferred.
#[derive(Clone, Debug)]
pub struct AcousticRoom {
    surfaces: Arc<Vec<AcousticSurface>>,
}
impl AcousticRoom {
    pub fn new(surfaces: Vec<AcousticSurface>) -> Result<Self, Error> {
        if surfaces.len() > MAX_SURFACES
            || surfaces.iter().map(|s| s.vertices.len()).sum::<usize>() > MAX_VERTICES
        {
            return Err(Error::Invalid("acoustic room geometry budget"));
        }
        Ok(Self {
            surfaces: Arc::new(surfaces),
        })
    }
    /// Extract geometry/materials only. This does not execute reverb_type,
    /// gains, low-frequency processing or select a convolution preset.
    pub fn from_environment(
        environment: &AcousticEnvironment,
        materials: &[Option<AcousticMaterial>; 31],
    ) -> Result<Self, Error> {
        if environment.surfaces.is_empty()
            || environment.surfaces.len() > MAX_SURFACES
            || environment
                .surfaces
                .iter()
                .map(|s| s.vertices.len())
                .sum::<usize>()
                > MAX_VERTICES
        {
            return Err(Error::Invalid("acoustic environment geometry budget"));
        }
        Self::new(
            environment
                .surfaces
                .iter()
                .map(|s| AcousticSurface::from_metadata(s, materials))
                .collect::<Result<_, _>>()?,
        )
    }
    pub fn surfaces(&self) -> &[AcousticSurface] {
        &self.surfaces
    }
    pub(super) fn images(&self, source: Point) -> Result<[Point; 9], Error> {
        validate_position(source)?;
        let mut images = [source; 9];
        for (index, surface) in self.surfaces.iter().enumerate() {
            images[index + 1] = sub(
                source,
                scale(surface.normal, 2.0 * surface.signed_distance(source)),
            );
        }
        Ok(images)
    }
    /// Query without allocation. Slot zero is direct sound, slots1..8 map to
    /// surface indices; absent slots mean occluded, grazing or invalid bounce.
    /// Both endpoints must be off every wall polygon; points on a wall are
    /// ambiguous and rejected before generating any paths.
    pub fn paths(
        &self,
        source: Point,
        receiver: Point,
    ) -> Result<[Option<AcousticPath>; 9], Error> {
        validate_position(source)?;
        validate_position(receiver)?;
        if self.surfaces.iter().any(|s| {
            (s.signed_distance(source).abs() <= EPS && s.contains(source))
                || (s.signed_distance(receiver).abs() <= EPS && s.contains(receiver))
        }) {
            return Err(Error::Invalid("acoustic endpoint on wall"));
        }
        let mut paths = [None; 9];
        if self.visible(source, receiver, None) {
            paths[0] = Some(AcousticPath {
                receiver,
                image: source,
                reflection: None,
                surface: None,
                distance: norm(sub(source, receiver)),
                specular: [1.0; 8],
            });
        }
        for (index, surface) in self.surfaces.iter().enumerate() {
            let a = surface.signed_distance(source);
            let b = surface.signed_distance(receiver);
            if a.abs() <= EPS || b.abs() <= EPS || a.signum() != b.signum() {
                continue;
            }
            let image = sub(source, scale(surface.normal, 2.0 * a));
            let t = b / (a + b);
            let reflection = add(receiver, scale(sub(image, receiver), t));
            if !surface.contains(reflection)
                || !self.visible(source, reflection, Some(index))
                || !self.visible(reflection, receiver, Some(index))
            {
                continue;
            }
            paths[index + 1] = Some(AcousticPath {
                receiver,
                image,
                reflection: Some(reflection),
                surface: Some(index),
                distance: norm(sub(source, reflection)) + norm(sub(receiver, reflection)),
                specular: surface.material.specular_pressure(),
            });
        }
        Ok(paths)
    }
    fn visible(&self, a: Point, b: Point, ignore: Option<usize>) -> bool {
        self.surfaces
            .iter()
            .enumerate()
            .all(|(i, s)| Some(i) == ignore || !s.intersects_segment(a, b))
    }
}

fn validate_position(value: Point) -> Result<(), Error> {
    if value.iter().any(|v| !v.is_finite() || v.abs() > 1000.0) {
        return Err(Error::Invalid("acoustic coordinate"));
    }
    Ok(())
}
fn add(a: Point, b: Point) -> Point {
    std::array::from_fn(|i| a[i] + b[i])
}
fn sub(a: Point, b: Point) -> Point {
    std::array::from_fn(|i| a[i] - b[i])
}
fn scale(a: Point, s: f64) -> Point {
    a.map(|v| v * s)
}
fn dot(a: Point, b: Point) -> f64 {
    a.iter().zip(b).map(|(a, b)| a * b).sum()
}
fn norm(a: Point) -> f64 {
    dot(a, a).sqrt()
}
fn cross(a: Point, b: Point) -> Point {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
