use super::{CartesianSpatialObject, PolarObject, SpatialObject};

/// Explicit coordinate system for one object's projection parameters.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ObjectTarget {
    Polar(SpatialObject),
    Cartesian(CartesianSpatialObject),
}

impl Default for ObjectTarget {
    fn default() -> Self {
        PolarObject::default().into()
    }
}

impl From<PolarObject> for ObjectTarget {
    fn from(object: PolarObject) -> Self {
        Self::Polar(object.into())
    }
}

impl From<SpatialObject> for ObjectTarget {
    fn from(object: SpatialObject) -> Self {
        Self::Polar(object)
    }
}

impl From<CartesianSpatialObject> for ObjectTarget {
    fn from(object: CartesianSpatialObject) -> Self {
        Self::Cartesian(object)
    }
}

impl ObjectTarget {
    pub fn polar(self) -> Option<SpatialObject> {
        match self {
            Self::Polar(object) => Some(object),
            Self::Cartesian(_) => None,
        }
    }
    pub fn cartesian(self) -> Option<CartesianSpatialObject> {
        match self {
            Self::Cartesian(object) => Some(object),
            Self::Polar(_) => None,
        }
    }
}
