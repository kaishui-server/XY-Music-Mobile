use super::BedLayout;
use crate::Error;

type V3 = [f64; 3];

pub(super) fn dot(a: V3, b: V3) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
fn cross(a: V3, b: V3) -> V3 {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
fn sub(a: V3, b: V3) -> V3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}
fn add(a: V3, b: V3) -> V3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}
fn scale(a: V3, b: f64) -> V3 {
    [a[0] * b, a[1] * b, a[2] * b]
}

pub(super) fn direction(azimuth: f64, elevation: f64) -> V3 {
    let (a, c) = azimuth.to_radians().sin_cos();
    let (z, r) = elevation.to_radians().sin_cos();
    [a * r, c * r, z]
}

fn normalize(values: &mut [f64]) {
    let norm = values.iter().map(|v| v * v).sum::<f64>().sqrt();
    if norm > 0.0 {
        for value in values {
            *value /= norm;
        }
    }
}

fn solve(columns: [V3; 3], right: V3) -> Option<V3> {
    let determinant = dot(columns[0], cross(columns[1], columns[2]));
    if determinant.abs() < 1e-13 {
        return None;
    }
    Some([
        dot(right, cross(columns[1], columns[2])) / determinant,
        dot(columns[0], cross(right, columns[2])) / determinant,
        dot(columns[0], cross(columns[1], right)) / determinant,
    ])
}

#[derive(Clone, Debug)]
struct Vertex {
    position: V3,
    output: usize,
}

#[derive(Clone, Debug)]
struct Cap {
    center: V3,
    boundary: Vec<usize>,
}

#[derive(Clone, Debug)]
pub(super) struct PointPanner {
    vertices: Vec<Vertex>,
    caps: Vec<Cap>,
    faces: Vec<Vec<usize>>,
    stereo: bool,
    outputs: usize,
}

impl PointPanner {
    pub(super) fn new(layout: BedLayout) -> Self {
        let stereo = layout == BedLayout::Stereo;
        let physical = if stereo {
            BedLayout::Surround51
        } else {
            layout
        };
        let mut vertices = Vec::new();
        let mut mid = Vec::new();
        let mut highest_azimuth: Option<f64> = None;
        for (output, name) in physical.speaker_names().iter().enumerate() {
            if name.starts_with("LFE") {
                continue;
            }
            let azimuth: f64 = name[1..].parse().expect("fixed speaker azimuth");
            let elevation = if name.starts_with('U') { 30.0 } else { 0.0 };
            vertices.push(Vertex {
                position: direction(azimuth, elevation),
                output,
            });
            if elevation == 0.0 {
                mid.push((azimuth, output));
            } else {
                highest_azimuth = Some(highest_azimuth.unwrap_or(0.0).max(azimuth.abs()));
            }
        }
        for elevation in [-30.0, 30.0] {
            let limit = if elevation < 0.0 {
                0.0
            } else {
                highest_azimuth.map_or(0.0, |v| v + 40.0)
            };
            for &(azimuth, output) in &mid {
                if azimuth.abs() >= limit - 1e-5 {
                    vertices.push(Vertex {
                        position: direction(azimuth, elevation),
                        output,
                    });
                }
            }
        }
        let mut positions: Vec<_> = vertices.iter().map(|v| v.position).collect();
        let first_cap = positions.len();
        positions.extend([[0.0, 0.0, -1.0], [0.0, 0.0, 1.0]]);
        let hull = hull_faces(&positions);
        let mut caps = Vec::new();
        for index in first_cap..positions.len() {
            let mut boundary: Vec<_> = hull
                .iter()
                .filter(|f| f.contains(&index))
                .flat_map(|f| f.iter().copied())
                .filter(|&i| i != index)
                .collect();
            boundary.sort_unstable();
            boundary.dedup();
            boundary.sort_by(|&a, &b| {
                positions[a][0]
                    .atan2(positions[a][1])
                    .total_cmp(&positions[b][0].atan2(positions[b][1]))
            });
            caps.push(Cap {
                center: positions[index],
                boundary,
            });
        }
        let faces = hull
            .into_iter()
            .filter(|face| face.iter().all(|&i| i < first_cap))
            .map(|face| order_face(&positions, face))
            .collect();
        Self {
            vertices,
            caps,
            faces,
            stereo,
            outputs: usize::from(physical.channels()),
        }
    }

    pub(super) fn pan(&self, position: V3) -> Result<[f64; 12], Error> {
        for cap in &self.caps {
            for edge in 0..cap.boundary.len() {
                let a = cap.boundary[edge];
                let b = cap.boundary[(edge + 1) % cap.boundary.len()];
                if let Some(g) = solve(
                    [
                        self.vertices[a].position,
                        self.vertices[b].position,
                        cap.center,
                    ],
                    position,
                ) && g.iter().all(|&v| v >= -1e-10)
                {
                    let mut result = [0.0; 12];
                    let center = g[2].max(0.0) / (cap.boundary.len() as f64).sqrt();
                    for &i in &cap.boundary {
                        result[self.vertices[i].output] += center;
                    }
                    result[self.vertices[a].output] += g[0].max(0.0);
                    result[self.vertices[b].output] += g[1].max(0.0);
                    return Ok(self.finish(result));
                }
            }
        }
        for face in &self.faces {
            let weights = match *face.as_slice() {
                [a, b, c] => solve(
                    [
                        self.vertices[a].position,
                        self.vertices[b].position,
                        self.vertices[c].position,
                    ],
                    position,
                )
                .filter(|g| g.iter().all(|&v| v >= -1e-10))
                .map(|g| [g[0], g[1], g[2], 0.0]),
                [a, b, c, d] => quad(
                    [
                        self.vertices[a].position,
                        self.vertices[b].position,
                        self.vertices[c].position,
                        self.vertices[d].position,
                    ],
                    position,
                ),
                _ => None,
            };
            if let Some(weights) = weights {
                let mut result = [0.0; 12];
                for (&index, weight) in face.iter().zip(weights) {
                    result[self.vertices[index].output] += weight.max(0.0);
                }
                return Ok(self.finish(result));
            }
        }
        Err(Error::Invalid("uncovered object direction"))
    }

    fn finish(&self, mut values: [f64; 12]) -> [f64; 12] {
        normalize(&mut values[..self.outputs]);
        if self.stereo {
            let mut result = [0.0; 12];
            result[0] = values[0] + values[2] / 3.0_f64.sqrt() + values[4] * 0.5_f64.sqrt();
            result[1] = values[1] + values[2] / 3.0_f64.sqrt() + values[5] * 0.5_f64.sqrt();
            normalize(&mut result[..2]);
            let front = values[..3].iter().copied().fold(0.0, f64::max);
            let back = values[4].max(values[5]);
            let rear_level = 0.5_f64.powf(0.5 * back / (front + back));
            result[0] *= rear_level;
            result[1] *= rear_level;
            result
        } else {
            values
        }
    }
}

fn hull_faces(points: &[V3]) -> Vec<Vec<usize>> {
    let mut faces = std::collections::BTreeSet::new();
    for a in 0..points.len() {
        for b in a + 1..points.len() {
            for c in b + 1..points.len() {
                let n = cross(sub(points[b], points[a]), sub(points[c], points[a]));
                let length = dot(n, n).sqrt();
                if length < 1e-10 {
                    continue;
                }
                let mut n = scale(n, 1.0 / length);
                let mut plane = dot(n, points[a]);
                if plane < 0.0 {
                    n = scale(n, -1.0);
                    plane = -plane;
                }
                if points.iter().any(|&p| dot(n, p) > plane + 1e-8) {
                    continue;
                }
                faces.insert(
                    points
                        .iter()
                        .enumerate()
                        .filter_map(|(i, &p)| (dot(n, p) - plane).abs().lt(&1e-8).then_some(i))
                        .collect::<Vec<_>>(),
                );
            }
        }
    }
    faces.into_iter().collect()
}

fn order_face(points: &[V3], mut face: Vec<usize>) -> Vec<usize> {
    let center = scale(
        face.iter().fold([0.0; 3], |v, &i| add(v, points[i])),
        1.0 / face.len() as f64,
    );
    let axis = sub(points[face[0]], center);
    let perpendicular = cross(center, axis);
    face.sort_by(|&a, &b| {
        let a = sub(points[a], center);
        let b = sub(points[b], center);
        dot(a, perpendicular)
            .atan2(dot(a, axis))
            .total_cmp(&dot(b, perpendicular).atan2(dot(b, axis)))
    });
    face
}

fn quad(corners: [V3; 4], direction: V3) -> Option<[f64; 4]> {
    let [a, b, c, d] = corners;
    let horizontal = sub(b, a);
    let vertical = sub(d, a);
    let bend = add(sub(c, b), sub(a, d));
    let mut u = 0.5;
    let mut v = 0.5;
    let mut distance = 0.5;
    for _ in 0..24 {
        let point = add(
            add(a, scale(horizontal, u)),
            add(scale(vertical, v), scale(bend, u * v)),
        );
        let residual = sub(point, scale(direction, distance));
        if dot(residual, residual) < 1e-24 {
            break;
        }
        let change = solve(
            [
                add(horizontal, scale(bend, v)),
                add(vertical, scale(bend, u)),
                scale(direction, -1.0),
            ],
            residual,
        )?;
        u -= change[0];
        v -= change[1];
        distance -= change[2];
    }
    if distance <= 0.0 || !(-1e-9..=1.0 + 1e-9).contains(&u) || !(-1e-9..=1.0 + 1e-9).contains(&v) {
        return None;
    }
    u = u.clamp(0.0, 1.0);
    v = v.clamp(0.0, 1.0);
    let weights = [(1.0 - u) * (1.0 - v), u * (1.0 - v), u * v, (1.0 - u) * v];
    let point = corners
        .into_iter()
        .zip(weights)
        .fold([0.0; 3], |sum, (p, w)| add(sum, scale(p, w)));
    let residual = cross(point, direction);
    (dot(residual, residual) < 1e-18).then_some(weights)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn complete_sphere_and_speaker_directions() {
        for config in [1, 2, 3, 7, 8, 9, 10] {
            let layout = BedLayout::from_configuration(config).unwrap();
            let panner = PointPanner::new(layout);
            for elevation in (-90..=90).step_by(5) {
                for azimuth in (-180..180).step_by(5) {
                    let result = panner
                        .pan(direction(f64::from(azimuth), f64::from(elevation)))
                        .unwrap_or_else(|e| panic!("{config} {azimuth} {elevation} {e}"));
                    assert!(result.iter().all(|v| v.is_finite() && *v >= 0.0));
                    let power = result.iter().map(|v| v * v).sum::<f64>();
                    assert!((0.499999..=1.000001).contains(&power));
                }
            }
        }
    }
}
