//! Bounded frame metadata. Dynamic values retain their quantized wire values.
use crate::{BitReader, Error, FrameHeader, Profile};
use std::sync::Arc;
mod scene;
mod static_data;
pub use scene::{ResolvedChannel, ResolvedScene};
pub use static_data::*;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ObjectPosition {
    /// Biased signed azimuth/elevation indices and unsigned distance index.
    Spherical([i16; 3]),
    /// Biased signed x/y/z indices; widths are 8/6/4 bits.
    Cartesian([i16; 3]),
}
impl ObjectPosition {
    /// Spherical output uses degrees/degrees/unit distance; Cartesian is unit coordinates.
    /// Offset-binary quantization is asymmetric at its endpoints.
    pub fn coordinates(&self) -> [f32; 3] {
        let (values, scale) = match self {
            Self::Spherical(v) => (v, [360.0 / 255.0, 180.0 / 63.0, 1.0 / 15.0]),
            Self::Cartesian(v) => (v, [2.0 / 255.0, 2.0 / 63.0, 2.0 / 15.0]),
        };
        std::array::from_fn(|i| f32::from(values[i]) * scale[i])
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChannelLock {
    Disabled,
    Within(u8),
}
impl ChannelLock {
    pub fn maximum_distance(&self) -> Option<f32> {
        match self {
            Self::Disabled => None,
            Self::Within(v) => Some(f32::from(*v) * (2.0 / 15.0)),
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ObjectDivergence {
    pub amount: u8,
    pub azimuth_range: Option<u8>,
}
impl ObjectDivergence {
    pub fn amount(&self) -> f32 {
        f32::from(self.amount) * (1.0 / 15.0)
    }
    pub fn azimuth_degrees(&self) -> Option<f32> {
        self.azimuth_range.map(|v| f32::from(v) * (180.0 / 63.0))
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpatialControls {
    pub channel_lock: Option<ChannelLock>,
    pub divergence: Option<ObjectDivergence>,
    pub screen_reference: Option<bool>,
    pub screen_edge_lock: Option<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ObjectParameters {
    pub position: ObjectPosition,
    /// Width/height/depth indices (7/5/4 bits), interpreted in position coordinates.
    pub extent: Option<[u8; 3]>,
    pub gain: Option<u8>,
    pub diffuse: Option<u8>,
    pub jump_position: bool,
    /// Clamped to 10 while preserving the parser's full four-bit consumption.
    pub importance: Option<u8>,
    pub controls: Option<SpatialControls>,
}
impl ObjectParameters {
    pub fn extent_values(&self) -> Option<[f32; 3]> {
        self.extent.map(|v| {
            let scale = match self.position {
                ObjectPosition::Spherical(_) => [360.0 / 127.0, 360.0 / 31.0, 1.0 / 15.0],
                ObjectPosition::Cartesian(_) => [1.0 / 127.0, 1.0 / 31.0, 1.0 / 15.0],
            };
            std::array::from_fn(|i| f32::from(v[i]) * scale[i])
        })
    }
    pub fn linear_gain(&self) -> Option<f32> {
        self.gain.map(|v| f32::from(v) * (6.0 / 127.0))
    }
    pub fn diffuseness(&self) -> Option<f32> {
        self.diffuse.map(|v| f32::from(v) * (1.0 / 127.0))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DynamicObject {
    /// Five-bit transmitted channel reference; not an index into the object array.
    pub transport_channel: u8,
    /// None means the object is muted; no parameter bits are present.
    pub parameters: Option<ObjectParameters>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DynamicMetadata {
    /// 0: position/basic parameters; 1: also spatial controls.
    pub level: u8,
    pub objects: Vec<DynamicObject>,
}
impl DynamicMetadata {
    pub fn parse(reader: &mut BitReader<'_>, objects: usize) -> Result<Self, Error> {
        if objects > 16 {
            return Err(Error::Unsupported("dynamic metadata object count"));
        }
        let mut next = reader.clone();
        let level = next.read(3)? as u8;
        if level > 1 {
            return Err(Error::Unsupported("dynamic metadata level"));
        }
        let mut result = Vec::with_capacity(objects);
        for _ in 0..objects {
            let muted = next.read(1)? != 0;
            let transport_channel = next.read(5)? as u8;
            let parameters = if muted {
                None
            } else {
                let cartesian = next.read(1)? != 0;
                let extent_present = next.read(1)? != 0;
                let gain_present = next.read(1)? != 0;
                let diffuse_present = next.read(1)? != 0;
                let importance_present = next.read(1)? != 0;
                let mut coordinates = [
                    next.read(8)? as i16 - 128,
                    next.read(6)? as i16 - 32,
                    next.read(4)? as i16,
                ];
                if cartesian {
                    coordinates[2] -= 8;
                }
                let position = if cartesian {
                    ObjectPosition::Cartesian(coordinates)
                } else {
                    ObjectPosition::Spherical(coordinates)
                };
                let extent = if extent_present {
                    Some([
                        next.read(7)? as u8,
                        next.read(5)? as u8,
                        next.read(4)? as u8,
                    ])
                } else {
                    None
                };
                let gain = if gain_present {
                    Some(next.read(7)? as u8)
                } else {
                    None
                };
                let diffuse = if diffuse_present {
                    Some(next.read(7)? as u8)
                } else {
                    None
                };
                let jump_position = next.read(1)? != 0;
                let importance = if importance_present {
                    Some((next.read(4)? as u8).min(10))
                } else {
                    None
                };
                let controls = if level == 1 {
                    Some(parse_controls(&mut next)?)
                } else {
                    None
                };
                Some(ObjectParameters {
                    position,
                    extent,
                    gain,
                    diffuse,
                    jump_position,
                    importance,
                    controls,
                })
            };
            result.push(DynamicObject {
                transport_channel,
                parameters,
            });
        }
        *reader = next;
        Ok(Self {
            level,
            objects: result,
        })
    }
}
fn parse_controls(reader: &mut BitReader<'_>) -> Result<SpatialControls, Error> {
    let channel_lock = if reader.read(1)? != 0 {
        Some(if reader.read(1)? != 0 {
            ChannelLock::Within(reader.read(4)? as u8)
        } else {
            ChannelLock::Disabled
        })
    } else {
        None
    };
    let divergence = if reader.read(1)? != 0 {
        let amount = reader.read(4)? as u8;
        let azimuth_range = if amount != 0 {
            Some(reader.read(6)? as u8)
        } else {
            None
        };
        Some(ObjectDivergence {
            amount,
            azimuth_range,
        })
    } else {
        None
    };
    let screen_reference = if reader.read(1)? != 0 {
        Some(reader.read(1)? != 0)
    } else {
        None
    };
    let screen_edge_lock = if reader.read(1)? != 0 {
        Some(reader.read(2)? as u8)
    } else {
        None
    };
    Ok(SpatialControls {
        channel_lock,
        divergence,
        screen_reference,
        screen_edge_lock,
    })
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FrameMetadata {
    pub static_data: Option<Arc<StaticMetadata>>,
    /// Current packet only; None means no dynamic metadata was transmitted.
    pub dynamic: Option<Arc<DynamicMetadata>>,
}
impl FrameMetadata {
    /// Transactional frame prefix parser; flags surround variable-length blocks.
    pub fn parse(reader: &mut BitReader<'_>, header: &FrameHeader) -> Result<Self, Error> {
        let mut next = reader.clone();
        let static_data = if next.read(1)? != 0 {
            Some(Arc::new(StaticMetadata::parse(&mut next)?))
        } else {
            None
        };
        let dynamic = if next.read(1)? != 0 {
            let count = match header.profile {
                Profile::Objects { count } => count,
                Profile::BedObjects { objects, .. } => objects,
                _ => 0,
            };
            Some(Arc::new(DynamicMetadata::parse(
                &mut next,
                usize::from(count),
            )?))
        } else {
            None
        };
        *reader = next;
        Ok(Self {
            static_data,
            dynamic,
        })
    }
}
