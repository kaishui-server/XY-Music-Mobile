//! Pure Rust AV3A framing and decoding. Supported payload modes are documented in README.
mod bits;
pub mod bwe;
pub mod decoder;
mod dsp;
pub mod entropy;
mod header;
pub mod hoa;
pub mod mcr;
pub mod metadata;
pub mod model;
pub mod quantization;
pub mod render;
pub mod shaping;
pub mod side;
pub mod spectral;
pub mod stream;
pub mod synthesis;
pub use bits::BitReader;
pub use header::{FrameHeader, Profile, payload_crc};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    Truncated,
    Invalid(&'static str),
    Unsupported(&'static str),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Truncated => f.write_str("truncated bitstream"),
            Self::Invalid(field) => write!(f, "invalid {field}"),
            Self::Unsupported(feature) => write!(f, "unsupported {feature}"),
        }
    }
}
impl std::error::Error for Error {}
