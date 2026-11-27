// Point conversion between the square room perimeter and polar panning space.
// The room corners map to +/-30 and +/-110 degrees; height 1 maps to
// elevation 30 at the perimeter, rising continuously to the zenith.
const AZIMUTHS: [f64; 6] = [-110.0, -30.0, 0.0, 30.0, 110.0, 250.0];
const PERIMETER: [[f64; 2]; 6] = [
    [1.0, -1.0],
    [1.0, 1.0],
    [0.0, 1.0],
    [-1.0, 1.0],
    [-1.0, -1.0],
    [1.0, -1.0],
];

pub(super) fn to_polar([x, y, z]: [f64; 3]) -> [f64; 3] {
    if x.abs() < 1e-10 && y.abs() < 1e-10 {
        return if z.abs() < 1e-10 {
            [0.0; 3]
        } else {
            [0.0, z.signum() * 90.0, z.abs()]
        };
    }
    for i in 0..5 {
        let [ax, ay] = PERIMETER[i];
        let [bx, by] = PERIMETER[i + 1];
        let determinant = ax * by - ay * bx;
        let a = (x * by - y * bx) / determinant;
        let b = (ax * y - ay * x) / determinant;
        if a < -1e-12 || b < -1e-12 {
            continue;
        }
        let radius = a + b;
        let t = (b / radius).clamp(0.0, 1.0);
        let (right, left) = (t * std::f64::consts::FRAC_PI_2).sin_cos();
        let half_angle = (AZIMUTHS[i + 1] - AZIMUTHS[i]) / 2.0;
        let azimuth = (AZIMUTHS[i] + AZIMUTHS[i + 1]) / 2.0
            + ((2.0 * right / (left + right) - 1.0) * half_angle.to_radians().tan())
                .atan()
                .to_degrees();
        let azimuth = (azimuth + 180.0).rem_euclid(360.0) - 180.0;
        let height_angle = z.atan2(radius).to_degrees();
        let (elevation, distance) = if height_angle.abs() > 45.0 {
            (
                height_angle.signum() * (30.0 + (height_angle.abs() - 45.0) * 60.0 / 45.0),
                z.abs(),
            )
        } else {
            (height_angle * 30.0 / 45.0, radius)
        };
        return [azimuth, elevation, distance];
    }
    unreachable!("finite room point belongs to one perimeter sector")
}

pub(super) fn from_polar([azimuth, elevation, distance]: [f64; 3]) -> [f64; 3] {
    let azimuth = (azimuth + 110.0).rem_euclid(360.0) - 110.0;
    let i = (0..4).find(|&i| azimuth <= AZIMUTHS[i + 1]).unwrap_or(4);
    let midpoint = (AZIMUTHS[i] + AZIMUTHS[i + 1]) / 2.0;
    let half_angle = (AZIMUTHS[i + 1] - AZIMUTHS[i]) / 2.0;
    let gain = 0.5 + 0.5 * (azimuth - midpoint).to_radians().tan() / half_angle.to_radians().tan();
    let t = gain.atan2(1.0 - gain) * 2.0 / std::f64::consts::PI;
    let (radius, z) = if elevation.abs() > 30.0 {
        let angle = 45.0 + (elevation.abs() - 30.0) * 45.0 / 60.0;
        (
            distance * (90.0 - angle).to_radians().tan(),
            distance * elevation.signum(),
        )
    } else {
        (
            distance,
            distance * (elevation * 45.0 / 30.0).to_radians().tan(),
        )
    };
    let xy: [f64; 2] = std::array::from_fn(|axis| {
        radius * (PERIMETER[i][axis] + (PERIMETER[i + 1][axis] - PERIMETER[i][axis]) * t)
    });
    [xy[0], xy[1], z].map(|v| v.clamp(-1.0, 1.0))
}
