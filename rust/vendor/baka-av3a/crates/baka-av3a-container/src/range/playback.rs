//! Pull requests for PCM and transactional asynchronous seek replay.
use super::{RangeRequest, RangeTrack};
use crate::playback::{Error, TimedPcm};
use baka_av3a_core::decoder::Decoder;

struct Seek {
    decoder: Decoder,
    cursor: usize,
    target: usize,
    ticks: u64,
}

#[derive(Debug)]
pub enum DecodeStep {
    NeedInput,
    Preroll { packet_index: usize },
    Frame(TimedPcm),
    Finished,
}

pub struct RangeDecoder {
    track: RangeTrack,
    decoder: Decoder,
    initial: Decoder,
    cursor: usize,
    generation: u64,
    seek: Option<Seek>,
    cache_start: usize,
    cache: Vec<u8>,
}
impl RangeDecoder {
    pub fn new(track: RangeTrack, decoder: Decoder) -> Result<Self, Error> {
        if decoder.decoded_frames() != 0 {
            return Err(Error::Container(crate::Error(
                "decoder already has stream history",
            )));
        }
        let cache = track.prefix.clone();
        Ok(Self {
            track,
            initial: decoder.clone(),
            decoder,
            cursor: 0,
            generation: 0,
            seek: None,
            cache_start: 0,
            cache,
        })
    }
    pub fn track(&self) -> &RangeTrack {
        &self.track
    }
    /// Committed playback position; it does not change while a seek is pending.
    pub fn next_packet_index(&self) -> usize {
        self.cursor
    }
    pub fn seeking(&self) -> bool {
        self.seek.is_some()
    }
    pub fn cached_bytes(&self) -> usize {
        self.cache.len()
    }
    /// Drop a failed batch, preserving decoder history and any pending seek.
    /// A retry uses a new request ID so previous responses cannot be applied.
    pub fn clear_cache(&mut self) -> Result<(), Error> {
        self.generation = self.next_generation()?;
        self.cache.clear();
        self.cache_start = 0;
        Ok(())
    }
    fn work_cursor(&self) -> usize {
        self.seek.as_ref().map_or(self.cursor, |s| s.cursor)
    }
    fn cached_packet(&self, range: &std::ops::Range<usize>) -> Option<&[u8]> {
        self.cache.get(
            range.start.checked_sub(self.cache_start)?..range.end.checked_sub(self.cache_start)?,
        )
    }
    pub fn static_metadata(&self) -> Option<&baka_av3a_core::metadata::StaticMetadata> {
        self.decoder.static_metadata()
    }
    pub fn dynamic_metadata(&self) -> Option<&baka_av3a_core::metadata::DynamicMetadata> {
        self.decoder.dynamic_metadata()
    }
    fn next_generation(&self) -> Result<u64, Error> {
        self.generation
            .checked_add(1)
            .ok_or(Error::Container(crate::Error(
                "range request serial overflow",
            )))
    }
    pub fn next_request(&self) -> Option<RangeRequest> {
        let cursor = self.work_cursor();
        let mut bytes = self.track.packet_range(cursor)?;
        if self.cached_packet(&bytes).is_some() {
            return None;
        }
        for s in self.track.samples.iter().skip(cursor + 1) {
            if s.range.start < bytes.end || s.range.end - bytes.start > super::RangeProbe::WINDOW {
                break;
            }
            bytes.end = s.range.end;
        }
        Some(RangeRequest {
            id: self.generation,
            bytes,
        })
    }
    /// Retain a bounded batch. HTTP identity validation must precede this call.
    pub fn accept(&mut self, request: &RangeRequest, bytes: &[u8]) -> Result<(), Error> {
        if self.next_request().as_ref() != Some(request) || bytes.len() != request.bytes.len() {
            return Err(Error::Container(crate::Error(
                "stale playback range response",
            )));
        }
        let generation = self.next_generation()?;
        self.cache_start = request.bytes.start;
        self.cache = bytes.to_vec();
        self.generation = generation;
        Ok(())
    }
    /// Decode at most one packet, allowing cancellation between preroll frames.
    pub fn next_frame(&mut self) -> Result<DecodeStep, Error> {
        let cursor = self.work_cursor();
        let Some(range) = self.track.packet_range(cursor) else {
            return Ok(DecodeStep::Finished);
        };
        let Some(start) = range.start.checked_sub(self.cache_start) else {
            return Ok(DecodeStep::NeedInput);
        };
        let Some(end) = range.end.checked_sub(self.cache_start) else {
            return Ok(DecodeStep::NeedInput);
        };
        let Some(bytes) = self.cache.get(start..end) else {
            return Ok(DecodeStep::NeedInput);
        };
        let generation = self.next_generation()?;
        let packet = self
            .track
            .validate_packet(cursor, bytes)
            .map_err(Error::Container)?;
        if let Some(seek) = &mut self.seek {
            let mut pcm = seek.decoder.decode(packet.bytes).map_err(Error::Decode)?;
            self.generation = generation;
            if cursor < seek.target {
                seek.cursor += 1;
                return Ok(DecodeStep::Preroll {
                    packet_index: cursor,
                });
            }
            let skip = (u128::from(seek.ticks.saturating_sub(packet.dts))
                * u128::from(pcm.sample_rate)
                / u128::from(self.track.info().timescale))
            .min(1024) as u16;
            pcm.samples
                .drain(..usize::from(skip) * usize::from(pcm.channels));
            let seek = self.seek.take().unwrap();
            self.decoder = seek.decoder;
            self.cursor = cursor + 1;
            Ok(DecodeStep::Frame(TimedPcm {
                packet_index: cursor,
                dts: packet.dts,
                skipped_samples: skip,
                pcm,
            }))
        } else {
            let pcm = self.decoder.decode(packet.bytes).map_err(Error::Decode)?;
            self.cursor += 1;
            self.generation = generation;
            Ok(DecodeStep::Frame(TimedPcm {
                packet_index: cursor,
                dts: packet.dts,
                skipped_samples: 0,
                pcm,
            }))
        }
    }
    /// Replays all required history, never pretending that arbitrary packets are independent.
    /// Returns false for a seek to EOF; no data request is needed in that case.
    pub fn begin_seek(&mut self, ticks: u64) -> Result<bool, Error> {
        let generation = self.next_generation()?;
        self.generation = generation;
        if ticks >= self.track.duration_ticks() {
            self.seek = None;
            self.cursor = self.track.packet_count();
            return Ok(false);
        }
        let target = self.track.packet_index_at(ticks);
        let (decoder, cursor) = if target < self.cursor {
            (self.initial.clone(), 0)
        } else {
            (self.decoder.clone(), self.cursor)
        };
        self.seek = Some(Seek {
            decoder,
            cursor,
            target,
            ticks,
        });
        Ok(true)
    }
    pub fn cancel_seek(&mut self) -> Result<bool, Error> {
        if self.seek.is_none() {
            return Ok(false);
        }
        self.generation = self.next_generation()?;
        self.seek = None;
        Ok(true)
    }
}
