use super::{BedLayout, CartesianObject, PolarObject, panner::direction, room};
use crate::{Error, metadata::Screen};

/// Validated angular screen edges, in degrees. Positive azimuth is left.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScreenEdges {
    left: f64,
    right: f64,
    bottom: f64,
    top: f64,
}

impl ScreenEdges {
    pub fn new(left: f64, right: f64, bottom: f64, top: f64) -> Result<Self, Error> {
        if [left, right, bottom, top].iter().any(|v| !v.is_finite())
            || !(-180.0 < right && right < left && left < 180.0)
            || !(-90.0 < bottom && bottom < top && top < 90.0)
        {
            return Err(Error::Invalid("screen angular edges"));
        }
        Ok(Self {
            left,
            right,
            bottom,
            top,
        })
    }

    /// A tangent-plane screen centred at a polar position. Width is the full
    /// horizontal angular size (0,180); aspect ratio and distance are positive.
    pub fn polar(
        azimuth: f64,
        elevation: f64,
        distance: f64,
        width: f64,
        aspect: f64,
    ) -> Result<Self, Error> {
        if [azimuth, elevation, distance, width, aspect]
            .iter()
            .any(|v| !v.is_finite())
            || !(-90.0 < elevation && elevation < 90.0)
            || distance <= 0.0
            || width <= 0.0
            || width >= 180.0
            || aspect <= 0.0
        {
            return Err(Error::Invalid("polar screen geometry"));
        }
        let azimuth = (azimuth + 180.0).rem_euclid(360.0) - 180.0;
        let centre = direction(azimuth, elevation).map(|v| v * distance);
        let half_width = distance * (width * 0.5).to_radians().tan();
        let horizontal = direction(azimuth + 90.0, 0.0).map(|v| v * half_width);
        let vertical = direction(azimuth, elevation + 90.0).map(|v| v * half_width / aspect);
        Self::plane(centre, horizontal, vertical)
    }

    /// Axis-aligned Cartesian screen: +X right, +Y front, +Z up. Width is the
    /// full horizontal size, in the same units as the centre coordinates.
    pub fn cartesian(centre: [f64; 3], width: f64, aspect: f64) -> Result<Self, Error> {
        if centre
            .iter()
            .chain([&width, &aspect])
            .any(|v| !v.is_finite())
            || width <= 0.0
            || aspect <= 0.0
        {
            return Err(Error::Invalid("Cartesian screen geometry"));
        }
        Self::plane(
            [-centre[0], centre[1], centre[2]],
            [width * 0.5, 0.0, 0.0],
            [0.0, 0.0, width * 0.5 / aspect],
        )
    }

    pub fn from_metadata(screen: &Screen) -> Result<Self, Error> {
        if screen.position[1] > 63 || screen.position[2] > 15 || screen.width > 127 {
            return Err(Error::Invalid("quantized reference screen"));
        }
        let aspect = match screen.aspect_ratio {
            0 => 16.0 / 9.0,
            1 => 21.0 / 9.0,
            _ => return Err(Error::Unsupported("reference screen aspect ratio")),
        };
        let p = screen.coordinates().map(f64::from);
        let width = f64::from(screen.width_value());
        if screen.cartesian {
            Self::cartesian(p, width, aspect)
        } else {
            Self::polar(p[0], p[1], p[2], width, aspect)
        }
    }

    fn plane(centre: [f64; 3], horizontal: [f64; 3], vertical: [f64; 3]) -> Result<Self, Error> {
        let add = |a: [f64; 3], b: [f64; 3], sign: f64| std::array::from_fn(|i| a[i] + sign * b[i]);
        let az = |p: [f64; 3]| p[0].atan2(p[1]).to_degrees();
        let el = |p: [f64; 3]| {
            let scale = p.into_iter().map(f64::abs).fold(0.0, f64::max);
            if scale == 0.0 {
                0.0
            } else {
                (p[2] / scale)
                    .atan2((p[0] / scale).hypot(p[1] / scale))
                    .to_degrees()
            }
        };
        let bottom = add(centre, vertical, -1.0);
        let top = add(centre, vertical, 1.0);
        let left = add(centre, horizontal, 1.0);
        let right = add(centre, horizontal, -1.0);
        if centre
            .iter()
            .chain(&horizontal)
            .chain(&vertical)
            .chain(&left)
            .chain(&right)
            .chain(&bottom)
            .chain(&top)
            .any(|v| !v.is_finite())
            || (az(bottom) - az(top)).abs() > 1e-3
        {
            return Err(Error::Invalid("screen crossing a pole"));
        }
        Self::new(az(left), az(right), el(bottom), el(top))
    }

    /// Left/right/bottom/top edges, in degrees.
    pub fn angles(self) -> [f64; 4] {
        [self.left, self.right, self.bottom, self.top]
    }
}

impl Default for ScreenEdges {
    fn default() -> Self {
        // Default reference geometry: centre (0,0,1), width 58 degrees, ratio 1.78.
        let half_height = (29.0f64.to_radians().tan() / 1.78).atan().to_degrees();
        Self {
            left: 29.0,
            right: -29.0,
            bottom: -half_height,
            top: half_height,
        }
    }
}

/// Screen edge codes used in dynamic metadata. Every value is active, including zero.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScreenEdge {
    Left,
    Right,
    Top,
    Bottom,
}
impl TryFrom<u8> for ScreenEdge {
    type Error = Error;
    fn try_from(value: u8) -> Result<Self, Error> {
        match value {
            0 => Ok(Self::Left),
            1 => Ok(Self::Right),
            2 => Ok(Self::Top),
            3 => Ok(Self::Bottom),
            _ => Err(Error::Invalid("screen edge code")),
        }
    }
}

/// Immutable reference-to-reproduction screen mapping for polar/room objects.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScreenTransform {
    reference: ScreenEdges,
    reproduction: ScreenEdges,
}
impl ScreenTransform {
    /// Transform room position without changing extent, gain or diffuseness.
    /// Each active screen stage performs room/polar conversion and applies
    /// layout height compensation before speaker lock and extent projection.
    pub fn apply_cartesian(
        self,
        mut object: CartesianObject,
        layout: BedLayout,
        scale: bool,
        edge: Option<ScreenEdge>,
    ) -> Result<CartesianObject, Error> {
        object.validate()?;
        if scale {
            object.position = self.room_stage(object.position, layout, true, None)?;
        }
        if edge.is_some() {
            object.position = self.room_stage(object.position, layout, false, edge)?;
        }
        Ok(object)
    }

    fn room_stage(
        self,
        position: [f64; 3],
        layout: BedLayout,
        scale: bool,
        edge: Option<ScreenEdge>,
    ) -> Result<[f64; 3], Error> {
        let [azimuth, elevation, distance] = room::to_polar(position);
        let mut polar = self.apply(
            PolarObject {
                azimuth,
                elevation,
                distance,
                ..Default::default()
            },
            scale,
            edge,
        )?;
        if matches!(layout, BedLayout::Surround712 | BedLayout::Surround714) {
            let elevation = polar.elevation.clamp(0.0, 90.0);
            let right = if elevation <= 30.0 {
                30.0 - elevation / 3.0
            } else {
                20.0 + (elevation - 30.0) / 6.0
            };
            polar.azimuth = interpolate(
                polar.azimuth,
                [-180.0, -30.0, 30.0, 180.0],
                [-180.0, -right, right, 180.0],
            );
        }
        Ok(room::from_polar([
            polar.azimuth,
            polar.elevation,
            polar.distance,
        ]))
    }

    pub fn new(reference: ScreenEdges, reproduction: ScreenEdges) -> Self {
        Self {
            reference,
            reproduction,
        }
    }

    /// Scale azimuth/elevation independently, then apply an edge lock. Distance,
    /// extent, gain and diffuseness are preserved. Apply before speaker locking.
    pub fn apply(
        self,
        mut object: PolarObject,
        scale: bool,
        edge: Option<ScreenEdge>,
    ) -> Result<PolarObject, Error> {
        object.validate()?;
        if !scale && edge.is_none() {
            return Ok(object);
        }
        object.azimuth = (object.azimuth + 180.0).rem_euclid(360.0) - 180.0;
        if object.distance == 0.0 {
            object.azimuth = 0.0;
            object.elevation = 0.0;
        }
        let r = self.reference;
        let p = self.reproduction;
        if scale {
            object.azimuth = interpolate(
                object.azimuth,
                [-180.0, r.right, r.left, 180.0],
                [-180.0, p.right, p.left, 180.0],
            );
            object.elevation = interpolate(
                object.elevation,
                [-90.0, r.bottom, r.top, 90.0],
                [-90.0, p.bottom, p.top, 90.0],
            );
        }
        match edge {
            Some(ScreenEdge::Left) => object.azimuth = p.left,
            Some(ScreenEdge::Right) => object.azimuth = p.right,
            Some(ScreenEdge::Top) => object.elevation = p.top,
            Some(ScreenEdge::Bottom) => object.elevation = p.bottom,
            None => {}
        }
        Ok(object)
    }
}

fn interpolate(value: f64, from: [f64; 4], to: [f64; 4]) -> f64 {
    let index = if value < from[1] {
        0
    } else if value < from[2] {
        1
    } else {
        2
    };
    let fraction = (value - from[index]) / (from[index + 1] - from[index]);
    to[index] + fraction * (to[index + 1] - to[index])
}
