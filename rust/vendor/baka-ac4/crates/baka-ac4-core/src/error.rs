//! Error type for the AC-4 decoder.

use thiserror::Error;

#[derive(Error, Debug, Clone, PartialEq, Eq)]
pub enum Ac4Error {
    #[error("invalid data: {0}")]
    InvalidData(&'static str),
    #[error("unsupported feature: {0}")]
    Unsupported(&'static str),
    #[error("packet too small")]
    PacketTooSmall,
}

pub type Result<T> = core::result::Result<T, Ac4Error>;

/// Malformed bitstream data.
pub fn invalid(msg: &'static str) -> Ac4Error {
    Ac4Error::InvalidData(msg)
}

/// A valid but unimplemented feature was encountered.
pub fn unsupported(msg: &'static str) -> Ac4Error {
    Ac4Error::Unsupported(msg)
}
