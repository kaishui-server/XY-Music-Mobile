//! Timed decoding and exact sample trimming, replaying history for backward seeks.
use crate::Track;
use baka_av3a_core::{
    decoder::{Decoder, PcmFrame},
    model::HyperModel,
    shaping::LsfCodebooks,
};
use std::sync::Arc;

#[derive(Debug)]
pub enum Error {
    Container(crate::Error),
    Decode(baka_av3a_core::Error),
    Cancelled,
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Container(e) => e.fmt(f),
            Self::Decode(e) => e.fmt(f),
            Self::Cancelled => f.write_str("decoding cancelled"),
        }
    }
}
impl std::error::Error for Error {}

#[derive(Clone, Debug)]
pub struct TimedPcm {
    pub packet_index: usize,
    /// Original packet DTS in the MP4 media timescale.
    pub dts: u64,
    /// Samples removed from the start of this packet by seeking.
    pub skipped_samples: u16,
    pub pcm: PcmFrame,
}

pub struct TrackDecoder<'a> {
    track: Track<'a>,
    decoder: Decoder,
    initial_decoder: Decoder,
    cursor: usize,
}
impl<'a> TrackDecoder<'a> {
    pub fn new(
        track: Track<'a>,
        model: Arc<HyperModel>,
        shaping: Arc<LsfCodebooks>,
    ) -> Result<Self, Error> {
        Self::from_decoder(track, Decoder::new(model, shaping))
    }
    /// Use a fresh decoder configured with optional MCR/HOA assets or a noise seed.
    /// A decoder with prior frames must be reset before starting a new track.
    pub fn from_decoder(track: Track<'a>, decoder: Decoder) -> Result<Self, Error> {
        track.validate_frames().map_err(Error::Container)?;
        if decoder.decoded_frames() != 0 {
            return Err(Error::Decode(baka_av3a_core::Error::Invalid(
                "decoder already has stream history",
            )));
        }
        Ok(Self {
            track,
            initial_decoder: decoder.clone(),
            decoder,
            cursor: 0,
        })
    }
    pub fn timescale(&self) -> u32 {
        self.track.timescale
    }
    pub fn next_packet_index(&self) -> usize {
        self.cursor
    }
    pub fn static_metadata(&self) -> Option<&baka_av3a_core::metadata::StaticMetadata> {
        self.decoder.static_metadata()
    }
    pub fn dynamic_metadata(&self) -> Option<&baka_av3a_core::metadata::DynamicMetadata> {
        self.decoder.dynamic_metadata()
    }
    pub fn next_frame(&mut self) -> Result<Option<TimedPcm>, Error> {
        let Some(packet) = self.track.packet(self.cursor) else {
            return Ok(None);
        };
        let pcm = self.decoder.decode(packet.bytes).map_err(Error::Decode)?;
        self.cursor += 1;
        Ok(Some(TimedPcm {
            packet_index: packet.index,
            dts: packet.dts,
            skipped_samples: 0,
            pcm,
        }))
    }
    pub fn seek(&mut self, ticks: u64) -> Result<Option<TimedPcm>, Error> {
        self.seek_with_cancel(ticks, || false)
    }
    /// Restore all filter/noise history by replay, then trim to the target sample.
    /// Cancellation is checked between packets and preserves the previous position.
    /// Media timestamps are used; MP4 edit lists are not applied here.
    pub fn seek_with_cancel(
        &mut self,
        ticks: u64,
        mut cancelled: impl FnMut() -> bool,
    ) -> Result<Option<TimedPcm>, Error> {
        if cancelled() {
            return Err(Error::Cancelled);
        }
        if ticks >= self.track.duration_ticks {
            self.cursor = self.track.packet_count();
            return Ok(None);
        }
        let target = self.track.packet_at(ticks);
        let mut decoder = self.decoder.clone();
        let mut cursor = self.cursor;
        if target.index < cursor {
            decoder = self.initial_decoder.clone();
            cursor = 0;
        }
        while cursor < target.index {
            if cancelled() {
                return Err(Error::Cancelled);
            }
            decoder
                .decode(self.track.packet(cursor).unwrap().bytes)
                .map_err(Error::Decode)?;
            cursor += 1;
        }
        if cancelled() {
            return Err(Error::Cancelled);
        }
        let mut pcm = decoder.decode(target.bytes).map_err(Error::Decode)?;
        if cancelled() {
            return Err(Error::Cancelled);
        }
        let skip = (u128::from(ticks.saturating_sub(target.dts)) * u128::from(pcm.sample_rate)
            / u128::from(self.track.timescale))
        .min(1024) as u16;
        pcm.samples
            .drain(..usize::from(skip) * usize::from(pcm.channels));
        self.decoder = decoder;
        self.cursor = target.index + 1;
        Ok(Some(TimedPcm {
            packet_index: target.index,
            dts: target.dts,
            skipped_samples: skip,
            pcm,
        }))
    }
}
