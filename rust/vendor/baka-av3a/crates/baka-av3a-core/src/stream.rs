//! Bounded pull decoder for arbitrary elementary-stream chunks.
use crate::{
    Error, FrameHeader,
    decoder::{Decoder, PcmFrame},
};

#[derive(Clone, Debug)]
pub struct ElementaryDecoder {
    decoder: Decoder,
    pending: Vec<u8>,
    position: usize,
    finished: bool,
}
impl ElementaryDecoder {
    pub const MAX_BUFFER: usize = 1024 * 1024;
    pub fn new(decoder: Decoder) -> Self {
        Self {
            decoder,
            pending: Vec::new(),
            position: 0,
            finished: false,
        }
    }
    pub fn buffered_bytes(&self) -> usize {
        self.pending.len() - self.position
    }
    pub fn decoded_frames(&self) -> u64 {
        self.decoder.decoded_frames()
    }
    /// Drain available frames before pushing more than the bounded queue can hold.
    pub fn push(&mut self, bytes: &[u8]) -> Result<(), Error> {
        if self.finished {
            return Err(Error::Invalid("input after EOF"));
        }
        if bytes.len() > Self::MAX_BUFFER - self.buffered_bytes() {
            return Err(Error::Unsupported("elementary buffer limit"));
        }
        if self.position != 0 {
            self.pending.drain(..self.position);
            self.position = 0;
        }
        self.pending.extend_from_slice(bytes);
        Ok(())
    }
    /// Marks EOF. `next_frame` distinguishes a clean end from a truncated packet.
    pub fn finish(&mut self) {
        self.finished = true;
    }
    pub fn reset(&mut self) {
        self.decoder.reset();
        self.pending.clear();
        self.position = 0;
        self.finished = false;
    }
    /// Returns None when more input is needed, or at a clean EOF. An error does
    /// not consume the pending packet or advance any decoder state.
    pub fn next_frame(&mut self) -> Result<Option<PcmFrame>, Error> {
        let bytes = &self.pending[self.position..];
        if bytes.is_empty() {
            return Ok(None);
        }
        let header = match FrameHeader::parse(bytes) {
            Err(Error::Truncated) if !self.finished => return Ok(None),
            value => value?,
        };
        let length = header.frame_bytes();
        if length > Self::MAX_BUFFER {
            return Err(Error::Unsupported("elementary frame limit"));
        }
        if bytes.len() < length {
            return if self.finished {
                Err(Error::Truncated)
            } else {
                Ok(None)
            };
        }
        let frame = self.decoder.decode(&bytes[..length])?;
        self.position += length;
        if self.position == self.pending.len() {
            self.pending.clear();
            self.position = 0;
        }
        Ok(Some(frame))
    }
}
