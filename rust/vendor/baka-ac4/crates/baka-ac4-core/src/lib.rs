//! baka-ac4-core — pure Rust Dolby AC-4 audio decoder.

pub mod ajoc;
mod ajoc_tables;
pub mod bitreader;
// The decoder uses index-based loops and multi-argument parse functions
// throughout; silencing these lints crate-wide keeps the hot paths explicit.
#[allow(clippy::needless_range_loop, clippy::too_many_arguments)]
pub mod decoder;
pub mod error;
pub mod imdct;
pub mod kbd;
pub mod qmf;
pub mod tables;
pub mod vlc;

pub use decoder::{Ac4Decoder, AudioKind, Frame, FrameInfo, StreamFeatures};
pub use error::{Ac4Error, Result};
