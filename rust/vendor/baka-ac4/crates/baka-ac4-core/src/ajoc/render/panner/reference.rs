// Frozen pre-optimization panner from upstream 7586e0f. Test-only oracle.
//! Independent Rust implementation of TS 103 448 clauses 5.2.2–5.2.4.
use super::super::layout::Speaker;
use std::f64::consts::FRAC_PI_2;

fn axis(speakers: &[Speaker], axis: usize, value: f64) -> Vec<f64> {
    speakers
        .iter()
        .map(|speaker| {
            let here = speaker.position[axis];
            let other = speakers
                .iter()
                .filter(|candidate| {
                    (axis + 1..3)
                        .all(|a| (candidate.position[a] - speaker.position[a]).abs() < 0.001)
                })
                .map(|s| s.position[axis])
                .filter(|&v| if here >= value { v < here } else { v > here })
                .reduce(|a, b| if here >= value { a.max(b) } else { a.min(b) });
            match other {
                None => 1.,
                Some(_) if here == value => 1.,
                Some(v) if v == value => 0.,
                Some(v) if (v - value).signum() == (here - value).signum() && here != value => 0.,
                Some(v) => ((here - value) / (v - here) * FRAC_PI_2).cos().max(0.),
            }
        })
        .collect()
}

fn normalize(gains: &mut [f64]) {
    let norm = gains.iter().map(|v| v * v).sum::<f64>().sqrt().max(1e-5);
    for gain in gains {
        *gain /= norm;
    }
}

pub(super) fn point(speakers: &[Speaker], position: [f64; 3]) -> Vec<f64> {
    let axes = std::array::from_fn::<_, 3, _>(|a| axis(speakers, a, position[a]));
    (0..speakers.len())
        .map(|j| axes[0][j] * axes[1][j] * axes[2][j])
        .collect()
}

pub(super) fn gains(
    speakers: &[Speaker],
    position: [f64; 3],
    width: [f64; 3],
    divergence: f64,
) -> Vec<f64> {
    if divergence > 0. {
        let half = divergence.min(1. - (position[0] - 0.5).abs() * 2.).max(0.) / 2.;
        let left = point(speakers, [position[0] - half, position[1], position[2]]);
        let right = point(speakers, [position[0] + half, position[1], position[2]]);
        let mut gains = left
            .iter()
            .zip(right)
            .map(|(a, b)| a + b)
            .collect::<Vec<_>>();
        normalize(&mut gains);
        return gains;
    }
    if width.iter().all(|&v| v < 1e-5) {
        return point(speakers, position);
    }
    size(speakers, position, width)
}

fn scale(x: f64) -> f64 {
    if x < 1e-5 {
        0.
    } else if x <= 0.2 {
        1.5 * x
    } else if x <= 0.5 {
        7. / 3. * x - 1. / 6.
    } else if x <= 0.75 {
        3.2 * x - 0.6
    } else {
        4. * x - 1.2
    }
}
fn weight(a: f64, b: f64, c: f64) -> f64 {
    10f64.powf(-(1.5 * (a - b) / c).powi(4))
}
fn fade(position: f64, size: f64) -> f64 {
    ((position.min(1. - position)) / size.max(0.2)).clamp(0., 1.)
}

fn size(speakers: &[Speaker], position: [f64; 3], width: [f64; 3]) -> Vec<f64> {
    let sizes = width.map(scale);
    let mut sorted = sizes;
    sorted.sort_by(|a, b| b.total_cmp(a));
    let effective = (6. * sorted[0] + 2. * sorted[1] + sorted[2]) / 9.;
    let power = if effective > 0.5 {
        6. - (effective - 0.5) * 4. / 2.3
    } else {
        6.
    };
    let counts = [20, 20, 8];
    let lower = std::array::from_fn::<_, 3, _>(|a| sizes[a].max(2. / (counts[a] - 1) as f64));
    let weighted = std::array::from_fn::<_, 3, _>(|a| {
        let mut sum = vec![0.; speakers.len()];
        for i in 0..counts[a] {
            let v = i as f64 / (counts[a] - 1) as f64;
            let w = weight(v, position[a], lower[a]);
            for (target, gain) in sum.iter_mut().zip(axis(speakers, a, v)) {
                *target += (gain * w).powf(power);
            }
        }
        sum
    });
    let mut inside = (0..speakers.len())
        .map(|j| (weighted[0][j] * weighted[1][j] * weighted[2][j]).powf(1. / power))
        .collect::<Vec<_>>();
    normalize(&mut inside);
    let mut boundary = vec![0.; speakers.len()];
    for a in 0..3 {
        for edge in [0., 1.] {
            for (j, gain) in axis(speakers, a, edge).iter().enumerate() {
                let others = (0..3)
                    .filter(|&b| b != a)
                    .map(|b| weighted[b][j])
                    .product::<f64>();
                boundary[j] += (gain * weight(edge, position[a], lower[a])).powf(power) * others;
            }
        }
    }
    normalize(&mut boundary);
    let outside = (0..3).map(|a| fade(position[a], lower[a])).product::<f64>();
    let mut spread = boundary
        .iter()
        .zip(inside)
        .map(|(b, i)| (b + outside * i).powf(1. / power))
        .collect::<Vec<_>>();
    normalize(&mut spread);
    let angle = (effective / 0.2).min(1.) * FRAC_PI_2;
    let mut result = point(speakers, position)
        .iter()
        .zip(spread)
        .map(|(p, s)| angle.cos() * p + angle.sin() * s)
        .collect::<Vec<_>>();
    normalize(&mut result);
    result
}
