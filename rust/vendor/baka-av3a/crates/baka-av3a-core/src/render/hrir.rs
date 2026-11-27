use super::panner::{direction, dot};
use crate::{Error, dsp::FftPlan};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Arc,
};

pub(super) const BLOCK: usize = 1024;
pub(super) const FFT: usize = 2048;
const MAX_MEASUREMENTS: usize = 2048;
const MAX_FACES: usize = 4096;

/// One measured stereo impulse response. Positive azimuth is left, elevation
/// is up, angles are degrees. Ear order is left then right; taps include delay.
#[derive(Clone, Debug)]
pub struct HrirMeasurement {
    pub azimuth: f64,
    pub elevation: f64,
    pub left: Vec<f32>,
    pub right: Vec<f32>,
}

#[derive(Clone, Copy, Debug)]
struct Face {
    indices: [usize; 3],
    inverse: [[f64; 3]; 3],
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HrirWeights {
    pub indices: [usize; 3],
    pub weights: [f64; 3],
}

#[derive(Debug)]
struct Plan {
    sample_rate: u32,
    radius: f32,
    measurements: Vec<HrirMeasurement>,
    faces: Vec<Face>,
    spectra: Vec<[[Vec<f32>; 2]; 2]>,
    fft: FftPlan,
}

/// Validated full-sphere triangulated HRIR bank at a fixed measurement radius.
/// Prepare outside the callback. Clones share immutable taps and FFT spectra.
/// The binary format is bounded, little endian and does not embed a SOFA parser.
#[derive(Clone, Debug)]
pub struct HrirBank {
    plan: Arc<Plan>,
}

impl HrirBank {
    pub fn new(
        sample_rate: u32,
        radius: f32,
        mut measurements: Vec<HrirMeasurement>,
        triangles: Vec<[usize; 3]>,
    ) -> Result<Self, Error> {
        let count = measurements.len();
        if !(8000..=192000).contains(&sample_rate)
            || !radius.is_finite()
            || !(0.01..=1000.0).contains(&radius)
            || !(4..=MAX_MEASUREMENTS).contains(&count)
            || !(4..=MAX_FACES).contains(&triangles.len())
        {
            return Err(Error::Invalid("HRIR bank dimensions or measurement radius"));
        }
        let taps = measurements[0].left.len();
        if !(1..=BLOCK).contains(&taps) {
            return Err(Error::Invalid("HRIR tap count"));
        }
        let mut positions = Vec::with_capacity(count);
        for measurement in &mut measurements {
            if !measurement.azimuth.is_finite()
                || !measurement.elevation.is_finite()
                || !(-180.0..=180.0).contains(&measurement.azimuth)
                || !(-90.0..=90.0).contains(&measurement.elevation)
                || measurement.left.len() != taps
                || measurement.right.len() != taps
            {
                return Err(Error::Invalid("HRIR measurement"));
            }
            for ear in [&measurement.left, &measurement.right] {
                if ear.iter().any(|v| !v.is_finite() || v.abs() > 16.0)
                    || ear.iter().map(|v| f64::from(v.abs())).sum::<f64>() > 64.0
                {
                    return Err(Error::Invalid("HRIR coefficients"));
                }
            }
            // Canonical binary precision makes serialization/reloading stable.
            measurement.azimuth = f64::from(measurement.azimuth as f32);
            measurement.elevation = f64::from(measurement.elevation as f32);
            let position = direction(measurement.azimuth, measurement.elevation);
            if positions
                .iter()
                .any(|&p| dot(sub(p, position), sub(p, position)) < 1e-12)
            {
                return Err(Error::Invalid("duplicate HRIR direction"));
            }
            positions.push(position);
        }
        let mut edges = BTreeMap::new();
        let mut unique = BTreeSet::new();
        let mut faces = Vec::with_capacity(triangles.len());
        for indices in triangles {
            if indices.iter().any(|&i| i >= count)
                || indices[0] == indices[1]
                || indices[0] == indices[2]
                || indices[1] == indices[2]
            {
                return Err(Error::Invalid("HRIR triangle indices"));
            }
            let mut sorted = indices;
            sorted.sort_unstable();
            if !unique.insert(sorted) {
                return Err(Error::Invalid("duplicate HRIR triangle"));
            }
            let [a, b, c] = indices.map(|i| positions[i]);
            let determinant = dot(a, cross(b, c));
            if determinant.abs() < 1e-9 {
                return Err(Error::Invalid("degenerate HRIR triangle"));
            }
            let inverse =
                [cross(b, c), cross(c, a), cross(a, b)].map(|r| r.map(|v| v / determinant));
            let mut normal = cross(sub(b, a), sub(c, a));
            let mut plane = dot(normal, a);
            if plane < 0.0 {
                normal = normal.map(|v| -v);
                plane = -plane;
            }
            if plane < 1e-9 || positions.iter().any(|&p| dot(normal, p) > plane + 1e-8) {
                return Err(Error::Invalid("non-convex HRIR surface"));
            }
            for (a, b) in [
                (indices[0], indices[1]),
                (indices[1], indices[2]),
                (indices[2], indices[0]),
            ] {
                *edges.entry((a.min(b), a.max(b))).or_insert(0usize) += 1;
            }
            faces.push(Face { indices, inverse });
        }
        if edges.values().any(|&n| n != 2)
            || edges
                .keys()
                .flat_map(|&(a, b)| [a, b])
                .collect::<BTreeSet<_>>()
                .len()
                != count
        {
            return Err(Error::Invalid("open HRIR triangulation"));
        }
        let fft = FftPlan::for_render(FFT);
        let spectra = measurements
            .iter()
            .map(|measurement| {
                std::array::from_fn(|ear| {
                    let taps = if ear == 0 {
                        &measurement.left
                    } else {
                        &measurement.right
                    };
                    let mut real = vec![0.0; FFT];
                    let mut imag = vec![0.0; FFT];
                    real[..taps.len()].copy_from_slice(taps);
                    fft.run(&mut real, &mut imag, false);
                    [real, imag]
                })
            })
            .collect();
        Ok(Self {
            plan: Arc::new(Plan {
                sample_rate,
                radius,
                measurements,
                faces,
                spectra,
                fft,
            }),
        })
    }
    pub fn sample_rate(&self) -> u32 {
        self.plan.sample_rate
    }
    pub fn measurement_radius(&self) -> f32 {
        self.plan.radius
    }
    pub fn tap_count(&self) -> usize {
        self.plan.measurements[0].left.len()
    }
    pub fn measurements(&self) -> &[HrirMeasurement] {
        &self.plan.measurements
    }
    pub fn interpolate(&self, azimuth: f64, elevation: f64) -> Result<HrirWeights, Error> {
        if !azimuth.is_finite() || !elevation.is_finite() || !(-90.0..=90.0).contains(&elevation) {
            return Err(Error::Invalid("HRIR source direction"));
        }
        let ray = direction((azimuth + 180.0).rem_euclid(360.0) - 180.0, elevation);
        for face in &self.plan.faces {
            let weights = face.inverse.map(|r| dot(r, ray));
            if weights.iter().all(|&v| v >= -1e-9) {
                let mut weights = weights.map(|v| v.max(0.0));
                let sum = weights.iter().sum::<f64>();
                if sum > 1e-12 {
                    for v in &mut weights {
                        *v /= sum;
                    }
                    return Ok(HrirWeights {
                        indices: face.indices,
                        weights,
                    });
                }
            }
        }
        Err(Error::Invalid("uncovered HRIR direction"))
    }
    pub(super) fn blend(
        &self,
        weights: HrirWeights,
        ear: usize,
        real: &mut [f32],
        imag: &mut [f32],
    ) {
        real.fill(0.0);
        imag.fill(0.0);
        for (&index, &weight) in weights.indices.iter().zip(&weights.weights) {
            if weight == 0.0 {
                continue;
            }
            let [r, i] = &self.plan.spectra[index][ear];
            let weight = weight as f32;
            for bin in 0..FFT {
                real[bin] += r[bin] * weight;
                imag[bin] += i[bin] * weight;
            }
        }
    }
    pub(super) fn fft(&self) -> &FftPlan {
        &self.plan.fft
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self, Error> {
        if bytes.len() < 28 || &bytes[..8] != b"BHRIR001" {
            return Err(Error::Invalid("HRIR bank header"));
        }
        let read = |offset| u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap());
        let sample_rate = read(8);
        let count = read(12) as usize;
        let taps = read(16) as usize;
        let faces = read(20) as usize;
        let radius = f32::from_bits(read(24));
        if !(4..=MAX_MEASUREMENTS).contains(&count)
            || !(1..=BLOCK).contains(&taps)
            || !(4..=MAX_FACES).contains(&faces)
        {
            return Err(Error::Invalid("HRIR bank dimensions"));
        }
        let expected = 28 + count * (8 + 8 * taps) + faces * 12;
        if bytes.len() != expected {
            return Err(Error::Invalid("HRIR bank length"));
        }
        let mut offset = 28;
        let mut measurements = Vec::with_capacity(count);
        for _ in 0..count {
            let azimuth = f64::from(f32::from_bits(read(offset)));
            let elevation = f64::from(f32::from_bits(read(offset + 4)));
            offset += 8;
            let mut ears = [Vec::with_capacity(taps), Vec::with_capacity(taps)];
            for ear in &mut ears {
                for _ in 0..taps {
                    ear.push(f32::from_bits(read(offset)));
                    offset += 4;
                }
            }
            let [left, right] = ears;
            measurements.push(HrirMeasurement {
                azimuth,
                elevation,
                left,
                right,
            });
        }
        let mut triangles = Vec::with_capacity(faces);
        for _ in 0..faces {
            triangles.push(std::array::from_fn(|i| read(offset + i * 4) as usize));
            offset += 12;
        }
        Self::new(sample_rate, radius, measurements, triangles)
    }
    /// Encode angles as f32 degrees. The resulting bank has the same validated
    /// dimensions and coefficients; serialization allocates outside callbacks.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut bytes = b"BHRIR001".to_vec();
        for value in [
            self.sample_rate(),
            self.measurements().len() as u32,
            self.tap_count() as u32,
            self.plan.faces.len() as u32,
            self.plan.radius.to_bits(),
        ] {
            bytes.extend(value.to_le_bytes());
        }
        for measurement in self.measurements() {
            for value in [measurement.azimuth as f32, measurement.elevation as f32] {
                bytes.extend(value.to_le_bytes());
            }
            for &value in measurement.left.iter().chain(&measurement.right) {
                bytes.extend(value.to_le_bytes());
            }
        }
        for face in &self.plan.faces {
            for index in face.indices {
                bytes.extend((index as u32).to_le_bytes());
            }
        }
        bytes
    }
}

fn sub(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    std::array::from_fn(|i| a[i] - b[i])
}
fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
