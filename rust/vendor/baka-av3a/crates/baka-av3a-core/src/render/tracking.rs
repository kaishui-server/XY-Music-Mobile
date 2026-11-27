use super::{BinauralRenderer, BinauralSource, HrirBank};
use crate::Error;

/// Unit quaternion in `[w,x,y,z]` order, rotating head-local coordinates into
/// world coordinates. Axes are +X right, +Y front, +Z up, in a right-handed frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HeadOrientation {
    quaternion: [f64; 4],
}

impl Default for HeadOrientation {
    fn default() -> Self {
        Self {
            quaternion: [1.0, 0.0, 0.0, 0.0],
        }
    }
}

impl HeadOrientation {
    pub fn new(quaternion: [f64; 4]) -> Result<Self, Error> {
        if quaternion.iter().any(|v| !v.is_finite()) {
            return Err(Error::Invalid("head quaternion"));
        }
        let scale = quaternion.iter().map(|v| v.abs()).fold(0.0_f64, f64::max);
        if scale == 0.0 {
            return Err(Error::Invalid("zero head quaternion"));
        }
        let mut quaternion = quaternion.map(|v| v / scale);
        let norm = quaternion.iter().map(|v| v * v).sum::<f64>().sqrt();
        for value in &mut quaternion {
            *value /= norm;
        }
        Ok(Self { quaternion })
    }
    /// Intrinsic yaw(Z), pitch(local X), roll(local Y), in degrees. Positive
    /// yaw turns left, pitch looks up, roll lowers the right ear.
    pub fn from_yaw_pitch_roll(yaw: f64, pitch: f64, roll: f64) -> Result<Self, Error> {
        if [yaw, pitch, roll].iter().any(|v| !v.is_finite()) {
            return Err(Error::Invalid("head angles"));
        }
        let half = |v: f64| (v.rem_euclid(360.0).to_radians() / 2.0).sin_cos();
        let (sy, cy) = half(yaw);
        let (sp, cp) = half(pitch);
        let (sr, cr) = half(roll);
        Self::new(multiply(
            multiply([cy, 0.0, 0.0, sy], [cp, sp, 0.0, 0.0]),
            [cr, 0.0, sr, 0.0],
        ))
    }
    pub fn quaternion(self) -> [f64; 4] {
        self.quaternion
    }
    /// Shortest-path spherical interpolation. q and -q describe the same pose.
    pub fn interpolate(self, other: Self, fraction: f64) -> Result<Self, Error> {
        if !fraction.is_finite() || !(0.0..=1.0).contains(&fraction) {
            return Err(Error::Invalid("head interpolation fraction"));
        }
        if fraction == 0.0 {
            return Ok(self);
        }
        if fraction == 1.0 {
            return Ok(other);
        }
        let a = self.quaternion;
        let mut b = other.quaternion;
        let mut dot = a.iter().zip(b).map(|(a, b)| a * b).sum::<f64>();
        if dot < 0.0 {
            b = b.map(|v| -v);
            dot = -dot;
        }
        let (left, right) = if dot > 0.9995 {
            (1.0 - fraction, fraction)
        } else {
            let theta = dot.clamp(-1.0, 1.0).acos();
            (
                ((1.0 - fraction) * theta).sin() / theta.sin(),
                (fraction * theta).sin() / theta.sin(),
            )
        };
        Self::new(std::array::from_fn(|i| left * a[i] + right * b[i]))
    }
    pub fn head_to_world(self, vector: [f64; 3]) -> Result<[f64; 3], Error> {
        validate_vector(vector)?;
        Ok(rotate(self.quaternion, vector))
    }
    pub fn world_to_head(self, vector: [f64; 3]) -> Result<[f64; 3], Error> {
        validate_vector(vector)?;
        Ok(self.inverse_rotate(vector))
    }
    fn inverse_rotate(self, vector: [f64; 3]) -> [f64; 3] {
        let [w, x, y, z] = self.quaternion;
        rotate([w, -x, -y, -z], vector)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ListenerPose {
    position: [f64; 3],
    orientation: HeadOrientation,
}
impl ListenerPose {
    pub fn new(position: [f64; 3], orientation: HeadOrientation) -> Result<Self, Error> {
        validate_position(position)?;
        Ok(Self {
            position,
            orientation,
        })
    }
    pub fn position(self) -> [f64; 3] {
        self.position
    }
    pub fn orientation(self) -> HeadOrientation {
        self.orientation
    }
    pub fn interpolate(self, other: Self, fraction: f64) -> Result<Self, Error> {
        let orientation = self.orientation.interpolate(other.orientation, fraction)?;
        Self::new(
            std::array::from_fn(|i| {
                self.position[i] * (1.0 - fraction) + other.position[i] * fraction
            }),
            orientation,
        )
    }
    pub fn relative_position(self, world: [f64; 3]) -> Result<[f64; 3], Error> {
        validate_position(world)?;
        Ok(self
            .orientation
            .inverse_rotate(std::array::from_fn(|i| world[i] - self.position[i])))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceSpace {
    World,
    HeadLocked,
}

/// Position in metres, either fixed in world space or relative to the head.
/// Head-locked sources bypass both listener translation and orientation.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TrackedSource {
    pub position: [f64; 3],
    pub space: SourceSpace,
    pub gain: f32,
}

impl TrackedSource {
    /// Geometric listener-relative position and distance, not an acoustic model.
    pub fn relative_position(self, pose: ListenerPose) -> Result<[f64; 3], Error> {
        validate_position(self.position)?;
        match self.space {
            SourceSpace::World => pose.relative_position(self.position),
            SourceSpace::HeadLocked => Ok(self.position),
        }
    }
    /// Resolve direction at the bank's measurement radius. This does not add
    /// distance attenuation/propagation or simulate room acoustics. A coincident
    /// position has the defined forward direction (0,0), retaining gain.
    pub fn binaural(self, pose: ListenerPose) -> Result<BinauralSource, Error> {
        if !self.gain.is_finite() || !(0.0..=16.0).contains(&self.gain) {
            return Err(Error::Invalid("tracked source gain"));
        }
        let [x, y, z] = self.relative_position(pose)?;
        let radius = x.hypot(y);
        let (azimuth, elevation) = if radius == 0.0 && z == 0.0 {
            (0.0, 0.0)
        } else {
            ((-x).atan2(y).to_degrees(), z.atan2(radius).to_degrees())
        };
        Ok(BinauralSource {
            azimuth,
            elevation,
            gain: self.gain,
        })
    }
}

/// Frame-updated six-degree-of-freedom geometry for point-source binaural audio.
/// Pose/source changes queue an input-time HRIR crossfade or explicit jump. This
/// is head tracking, not the AV3A VR environment/effects interpreter.
#[derive(Clone, Debug)]
pub struct TrackedBinauralRenderer {
    renderer: BinauralRenderer,
    pose: ListenerPose,
    sources: Vec<TrackedSource>,
}

impl TrackedBinauralRenderer {
    pub fn new(
        bank: HrirBank,
        sample_rate: u32,
        pose: ListenerPose,
        sources: &[TrackedSource],
    ) -> Result<Self, Error> {
        if sources.is_empty() || sources.len() > 16 {
            return Err(Error::Invalid("tracked source count"));
        }
        let mut targets = [BinauralSource::default(); 16];
        for (target, &source) in targets.iter_mut().zip(sources) {
            *target = source.binaural(pose)?;
        }
        let renderer = BinauralRenderer::new(bank, sample_rate, &targets[..sources.len()])?;
        Ok(Self {
            renderer,
            pose,
            sources: sources.to_vec(),
        })
    }
    /// Atomically set listener and source targets before the next1024-frame block.
    pub fn set_scene(
        &mut self,
        pose: ListenerPose,
        sources: &[TrackedSource],
        jumps: &[bool],
    ) -> Result<(), Error> {
        if sources.len() != self.sources.len() || jumps.len() != sources.len() {
            return Err(Error::Invalid("tracked update count"));
        }
        let mut targets = [BinauralSource::default(); 16];
        for (target, &source) in targets.iter_mut().zip(sources) {
            *target = source.binaural(pose)?;
        }
        self.renderer
            .set_sources(&targets[..sources.len()], jumps)?;
        self.pose = pose;
        self.sources.copy_from_slice(sources);
        Ok(())
    }
    pub fn set_listener(&mut self, pose: ListenerPose, jump: bool) -> Result<(), Error> {
        let mut targets = [BinauralSource::default(); 16];
        for (target, &source) in targets.iter_mut().zip(&self.sources) {
            *target = source.binaural(pose)?;
        }
        self.renderer.set_sources(
            &targets[..self.sources.len()],
            &[jump; 16][..self.sources.len()],
        )?;
        self.pose = pose;
        Ok(())
    }
    pub fn listener(&self) -> ListenerPose {
        self.pose
    }
    pub fn sources(&self) -> &[TrackedSource] {
        &self.sources
    }
    pub fn resolved_sources(&self) -> &[BinauralSource] {
        self.renderer.sources()
    }
    pub fn tail_samples(&self) -> usize {
        self.renderer.tail_samples()
    }
    pub fn process(&mut self, input: &[f32], output: &mut [f32]) -> Result<(), Error> {
        self.renderer.process(input, output)
    }
    pub fn process_silence(&mut self, output: &mut [f32]) -> Result<(), Error> {
        self.renderer.process_silence(output)
    }
    pub fn reset(&mut self) {
        self.renderer.reset();
    }
}

fn validate_position(position: [f64; 3]) -> Result<(), Error> {
    if position.iter().any(|v| !v.is_finite() || v.abs() > 1e6) {
        return Err(Error::Invalid("tracking position"));
    }
    Ok(())
}
// A rotation-invariant bound avoids accepting a position vector and then
// rejecting its inverse rotation merely because a rotated component is larger.
fn validate_vector(vector: [f64; 3]) -> Result<(), Error> {
    if vector.iter().any(|v| !v.is_finite())
        || vector[0].hypot(vector[1]).hypot(vector[2]) > 4e6 + 1e-8
    {
        return Err(Error::Invalid("tracking vector"));
    }
    Ok(())
}
fn multiply(a: [f64; 4], b: [f64; 4]) -> [f64; 4] {
    let [w, x, y, z] = a;
    let [s, u, v, t] = b;
    [
        w * s - x * u - y * v - z * t,
        w * u + x * s + y * t - z * v,
        w * v - x * t + y * s + z * u,
        w * t + x * v - y * u + z * s,
    ]
}
fn rotate(q: [f64; 4], v: [f64; 3]) -> [f64; 3] {
    let [w, x, y, z] = q;
    let [a, b, c] = v;
    let cross = [y * c - z * b, z * a - x * c, x * b - y * a].map(|v| v * 2.0);
    [
        a + w * cross[0] + y * cross[2] - z * cross[1],
        b + w * cross[1] + z * cross[0] - x * cross[2],
        c + w * cross[2] + x * cross[1] - y * cross[0],
    ]
}
