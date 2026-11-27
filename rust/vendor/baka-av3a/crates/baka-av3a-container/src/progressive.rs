//! Bounded forward-only MP4 input. Initialization must precede media.
use super::*;
use std::collections::VecDeque;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StreamInfo {
    pub sample_rate: u32,
    pub channels: u16,
    pub bit_depth: u16,
    pub timescale: u32,
}

#[derive(Clone, Debug)]
pub struct OwnedPacket {
    pub bytes: Vec<u8>,
    pub index: usize,
    pub dts: u64,
    pub duration: u32,
}

/// Call `next_packet` until it needs input before pushing another bounded chunk.
/// Failed parsing is terminal; a new stream is required after an error.
#[derive(Default)]
pub struct Mp4Stream {
    pending: Vec<u8>,
    position: usize,
    offset: usize,
    eof: bool,
    done: bool,
    failure: Option<Error>,
    info: Option<StreamInfo>,
    moov: Option<(usize, Vec<u8>)>,
    moof: Option<(usize, Vec<u8>)>,
    selection: (usize, usize),
    fragmented: bool,
    media_end: Option<usize>,
    skip_end: Option<usize>,
    samples: VecDeque<Sample>,
    previous: Option<Sample>,
    sequence: Option<u32>,
    initial_header: Option<FrameHeader>,
    packets: usize,
    boxes: usize,
}
impl Mp4Stream {
    pub const MAX_BUFFER: usize = 8 * 1024 * 1024;
    pub fn new() -> Self {
        Self::default()
    }
    pub fn info(&self) -> Option<StreamInfo> {
        self.info
    }
    pub fn buffered_bytes(&self) -> usize {
        self.pending.len() - self.position
    }
    pub fn emitted_packets(&self) -> usize {
        self.packets
    }
    /// True only after EOF has been fully drained and validated.
    pub fn is_finished(&self) -> bool {
        self.done
    }
    pub fn push(&mut self, bytes: &[u8]) -> Result<()> {
        if let Some(e) = &self.failure {
            return Err(e.clone());
        }
        if self.eof {
            return Err(Error("input after EOF"));
        }
        if bytes.len() > Self::MAX_BUFFER - self.buffered_bytes() {
            return Err(Error("MP4 input buffer limit; drain before pushing"));
        }
        if self
            .offset
            .checked_add(self.buffered_bytes())
            .and_then(|v| v.checked_add(bytes.len()))
            .is_none_or(|v| v > MAX_FILE_BYTES)
        {
            return Err(Error("stream exceeds 512 MiB limit"));
        }
        if self.position != 0 {
            self.pending.drain(..self.position);
            self.position = 0;
        }
        self.pending.extend_from_slice(bytes);
        Ok(())
    }
    pub fn finish(&mut self) {
        self.eof = true;
    }
    fn consume(&mut self, count: usize) {
        self.position += count;
        self.offset += count;
        if self.position == self.pending.len() {
            self.pending.clear();
            self.position = 0;
        }
    }
    pub fn next_packet(&mut self) -> Result<Option<OwnedPacket>> {
        if let Some(e) = &self.failure {
            return Err(e.clone());
        }
        let result = self.read_packet();
        if let Err(e) = &result {
            self.failure = Some(e.clone());
        }
        result
    }
    fn need_input(&self) -> Result<Option<OwnedPacket>> {
        if self.eof {
            Err(Error("truncated MP4 stream"))
        } else {
            Ok(None)
        }
    }
    fn read_packet(&mut self) -> Result<Option<OwnedPacket>> {
        loop {
            if let Some(end) = self.skip_end {
                let count = (end - self.offset).min(self.buffered_bytes());
                self.consume(count);
                if self.offset != end {
                    return self.need_input();
                }
                self.skip_end = None;
                continue;
            }
            if let Some(end) = self.media_end {
                if let Some(sample) = self.samples.front().cloned() {
                    if sample.range.start < self.offset {
                        return Err(Error("non-forward sample layout"));
                    }
                    if sample.range.start < end {
                        if sample.range.end > end {
                            return Err(Error("sample crosses mdat boundary"));
                        }
                        let skip = (sample.range.start - self.offset).min(self.buffered_bytes());
                        self.consume(skip);
                        if self.offset != sample.range.start {
                            return self.need_input();
                        }
                        let length = sample.range.len();
                        if self.buffered_bytes() < length {
                            return self.need_input();
                        }
                        let bytes = self.pending[self.position..self.position + length].to_vec();
                        self.validate_packet(&bytes, &sample)?;
                        let packet = OwnedPacket {
                            bytes,
                            index: self.packets,
                            dts: sample.dts,
                            duration: sample.duration,
                        };
                        self.previous = Some(sample);
                        self.samples.pop_front();
                        self.packets += 1;
                        if self.packets > MAX_SAMPLES {
                            return Err(Error("stream sample limit"));
                        }
                        self.consume(length);
                        return Ok(Some(packet));
                    }
                }
                let count = (end - self.offset).min(self.buffered_bytes());
                self.consume(count);
                if self.offset != end {
                    return self.need_input();
                }
                self.media_end = None;
                continue;
            }
            if self.buffered_bytes() == 0 && self.eof {
                if self.info.is_none()
                    || self.moof.is_some()
                    || !self.samples.is_empty()
                    || self.packets == 0
                {
                    return Err(Error("incomplete MP4 stream"));
                }
                self.done = true;
                return Ok(None);
            }
            let bytes = &self.pending[self.position..];
            if bytes.len() < 8 {
                return self.need_input();
            }
            let size32 = u32be(bytes, 0)?;
            let kind: [u8; 4] = bytes[4..8].try_into().unwrap();
            let (size, header) = match size32 {
                0 => return Err(Error("open-ended boxes require a seekable input")),
                1 if bytes.len() < 16 => return self.need_input(),
                1 => (
                    usize::try_from(u64be(bytes, 8)?).map_err(|_| Error("box size overflow"))?,
                    16,
                ),
                n => (n as usize, 8),
            };
            let end = self
                .offset
                .checked_add(size)
                .filter(|&v| v <= MAX_FILE_BYTES)
                .ok_or(Error("stream box range limit"))?;
            if size < header {
                return Err(Error("invalid box size"));
            }
            if &kind == b"moov" || &kind == b"moof" {
                if size > Self::MAX_BUFFER {
                    return Err(Error("stream metadata byte limit"));
                }
                if bytes.len() < size {
                    return self.need_input();
                }
            }
            self.boxes += 1;
            if self.boxes > 65536 {
                return Err(Error("stream box count limit"));
            }
            match &kind {
                b"moov" => {
                    if self.moov.is_some() {
                        return Err(Error("duplicate initialization"));
                    }
                    let owned = bytes[..size].to_vec();
                    let top = boxes(&owned, self.offset)?;
                    let address_space = 0..MAX_FILE_BYTES;
                    let track =
                        Track::from_boxes(&[], &top, std::slice::from_ref(&address_space), true)?;
                    let moov = children(top[0])?;
                    self.fragmented = moov.iter().any(|b| b.kind == *b"mvex");
                    if self.fragmented && !track.samples.is_empty() {
                        return Err(Error("hybrid initialization requires a seekable input"));
                    }
                    if track.samples.is_empty() && !self.fragmented {
                        return Err(Error("empty ordinary track"));
                    }
                    self.selection = track.selection;
                    self.info = Some(StreamInfo {
                        sample_rate: track.sample_rate,
                        channels: track.channels,
                        bit_depth: track.bit_depth,
                        timescale: track.timescale,
                    });
                    self.samples = forward_samples(track.samples, end)?;
                    self.moov = Some((self.offset, owned));
                    self.consume(size);
                }
                b"moof" => {
                    if !self.fragmented || self.moof.is_some() || !self.samples.is_empty() {
                        return Err(Error("unexpected fragment"));
                    }
                    let owned = bytes[..size].to_vec();
                    let top = boxes(&owned, self.offset)?;
                    let inner = children(top[0])?;
                    let mfhd = one(&inner, b"mfhd")?.body;
                    let sequence = u32be(mfhd, 4)?;
                    if self.sequence.is_some_and(|v| sequence <= v) {
                        return Err(Error("fragment sequence is not increasing"));
                    }
                    self.sequence = Some(sequence);
                    self.moof = Some((self.offset, owned));
                    self.consume(size);
                }
                b"mdat" => {
                    if self.info.is_none() {
                        return Err(Error("moov must precede media; use range input"));
                    }
                    if self.fragmented {
                        self.fragment_samples(self.offset + header, end)?;
                    }
                    self.media_end = Some(end);
                    self.consume(header);
                }
                _ => {
                    self.consume(header);
                    self.skip_end = Some(end);
                }
            }
        }
    }
    fn fragment_samples(&mut self, start: usize, end: usize) -> Result<()> {
        let (offset, bytes) = self
            .moof
            .as_ref()
            .ok_or(Error("fragment mdat without moof"))?;
        let (moov_offset, moov_bytes) = self.moov.as_ref().unwrap();
        let mut top = boxes(moov_bytes, *moov_offset)?;
        top.extend(boxes(bytes, *offset)?);
        let moov = children(top[0])?;
        let trak = moov
            .iter()
            .filter(|b| b.kind == *b"trak")
            .nth(self.selection.0)
            .ok_or(Error("missing selected track"))?;
        let mut samples: Vec<_> = self.previous.clone().into_iter().collect();
        let seeded = samples.len();
        let media = start..end;
        fragments::append(
            &top,
            &moov,
            &children(*trak)?,
            std::slice::from_ref(&media),
            self.selection.1,
            &mut samples,
        )?;
        samples.drain(..seeded);
        if samples.len() > MAX_SAMPLES - self.packets {
            return Err(Error("stream sample limit"));
        }
        self.samples = forward_samples(samples, start)?;
        self.moof = None;
        Ok(())
    }
    fn validate_packet(&mut self, bytes: &[u8], sample: &Sample) -> Result<()> {
        let mut h =
            FrameHeader::validate_crc(bytes).map_err(|_| Error("invalid AV3A packet/CRC"))?;
        let info = self.info.unwrap();
        if h.sample_rate != info.sample_rate
            || h.channels != info.channels
            || u16::from(h.bit_depth) != info.bit_depth
            || u64::from(sample.duration) * u64::from(h.sample_rate)
                != u64::from(FrameHeader::SAMPLES) * u64::from(info.timescale)
        {
            return Err(Error("container/frame format mismatch"));
        }
        h.crc = 0;
        if self.initial_header.as_ref().is_some_and(|v| v != &h) {
            return Err(Error("midstream configuration change"));
        }
        self.initial_header = Some(h);
        Ok(())
    }
}

fn forward_samples(samples: Vec<Sample>, minimum: usize) -> Result<VecDeque<Sample>> {
    let mut end = minimum;
    for s in &samples {
        if s.range.start < end {
            return Err(Error("non-forward sample layout"));
        }
        end = s.range.end;
    }
    Ok(samples.into())
}

/// Incremental demux and PCM decode, preserving the failing packet on codec error.
pub struct Mp4Decoder {
    input: Mp4Stream,
    decoder: baka_av3a_core::decoder::Decoder,
    held: Option<OwnedPacket>,
}
impl Mp4Decoder {
    pub fn new(decoder: baka_av3a_core::decoder::Decoder) -> Result<Self> {
        if decoder.decoded_frames() != 0 {
            return Err(Error("decoder already has stream history"));
        }
        Ok(Self {
            input: Mp4Stream::new(),
            decoder,
            held: None,
        })
    }
    pub fn info(&self) -> Option<StreamInfo> {
        self.input.info()
    }
    pub fn buffered_bytes(&self) -> usize {
        self.input.buffered_bytes()
    }
    pub fn decoded_frames(&self) -> u64 {
        self.decoder.decoded_frames()
    }
    pub fn is_finished(&self) -> bool {
        self.input.is_finished() && self.held.is_none()
    }
    pub fn push(&mut self, bytes: &[u8]) -> Result<()> {
        self.input.push(bytes)
    }
    pub fn finish(&mut self) {
        self.input.finish();
    }
    pub fn static_metadata(&self) -> Option<&baka_av3a_core::metadata::StaticMetadata> {
        self.decoder.static_metadata()
    }
    pub fn dynamic_metadata(&self) -> Option<&baka_av3a_core::metadata::DynamicMetadata> {
        self.decoder.dynamic_metadata()
    }
    pub fn next_frame(
        &mut self,
    ) -> std::result::Result<Option<playback::TimedPcm>, playback::Error> {
        if self.held.is_none() {
            self.held = self
                .input
                .next_packet()
                .map_err(playback::Error::Container)?;
        }
        let Some(packet) = &self.held else {
            return Ok(None);
        };
        let pcm = self
            .decoder
            .decode(&packet.bytes)
            .map_err(playback::Error::Decode)?;
        let value = playback::TimedPcm {
            packet_index: packet.index,
            dts: packet.dts,
            skipped_samples: 0,
            pcm,
        };
        self.held = None;
        Ok(Some(value))
    }
}
