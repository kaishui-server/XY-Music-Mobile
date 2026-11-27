//! Sparse MP4 indexing and exact HTTP range response checks. No transport is owned here.
use super::*;
use crate::progressive::StreamInfo;
pub mod playback;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RangeRequest {
    pub id: u64,
    /// Half-open file range; HTTP uses an inclusive final byte.
    pub bytes: Range<usize>,
}
impl RangeRequest {
    pub fn range_header(&self) -> Result<String> {
        if self.bytes.start >= self.bytes.end {
            return Err(Error("empty or reversed range"));
        }
        Ok(format!("bytes={}-{}", self.bytes.start, self.bytes.end - 1))
    }
}

/// Pins the representation across range requests. Send `if_range()` and
/// `Accept-Encoding: identity`; supply the unmodified response body.
pub struct HttpRangeSession {
    length: usize,
    etag: String,
}
impl HttpRangeSession {
    pub fn new(length: usize, etag: &str) -> Result<Self> {
        check_length(length)?;
        if etag.len() < 2
            || etag.len() > 512
            || !etag.starts_with('"')
            || !etag.ends_with('"')
            || etag.as_bytes()[1..etag.len() - 1]
                .iter()
                .any(|&b| b != 0x21 && !(0x23..=0x7e).contains(&b))
        {
            return Err(Error("a bounded strong ASCII ETag is required"));
        }
        Ok(Self {
            length,
            etag: etag.to_owned(),
        })
    }
    pub fn if_range(&self) -> &str {
        &self.etag
    }
    pub fn validate(&self, request: &RangeRequest, response: HttpRangeResponse<'_>) -> Result<()> {
        let range = &request.bytes;
        if range.start >= range.end
            || range.end > self.length
            || range.len() > RangeProbe::MAX_METADATA_BOX
        {
            return Err(Error("invalid requested HTTP range"));
        }
        if response.status != 206 {
            return Err(Error(
                "expected HTTP 206; full-body fallback is not accepted",
            ));
        }
        if response.etag != self.etag {
            return Err(Error("HTTP representation ETag changed"));
        }
        if !response.content_encoding.is_empty()
            && !response.content_encoding.eq_ignore_ascii_case("identity")
        {
            return Err(Error("encoded range bodies are unsupported"));
        }
        let header = response.content_range;
        if header.len() > 128 {
            return Err(Error("Content-Range length limit"));
        }
        let (bounds, total) = header
            .strip_prefix("bytes ")
            .and_then(|v| v.split_once('/'))
            .ok_or(Error("invalid Content-Range"))?;
        let (start, end) = bounds
            .split_once('-')
            .ok_or(Error("invalid Content-Range"))?;
        let number = |v: &str| -> Result<usize> {
            if v.is_empty() || !v.bytes().all(|b| b.is_ascii_digit()) {
                return Err(Error("invalid Content-Range integer"));
            }
            v.parse()
                .map_err(|_| Error("Content-Range integer overflow"))
        };
        if number(start)? != range.start
            || number(end)?.checked_add(1) != Some(range.end)
            || number(total)? != self.length
            || response.body.len() != range.len()
        {
            return Err(Error("HTTP range or body length mismatch"));
        }
        Ok(())
    }
}

pub struct HttpRangeResponse<'a> {
    pub status: u16,
    pub content_range: &'a str,
    pub etag: &'a str,
    pub content_encoding: &'a str,
    pub body: &'a [u8],
}

fn check_length(length: usize) -> Result<()> {
    if length == 0 || length > MAX_FILE_BYTES {
        return Err(Error("file length must be 1..512 MiB"));
    }
    Ok(())
}

/// A sample index without retained media. Packet bytes are checked only when fetched.
#[derive(Clone, Debug)]
pub struct RangeTrack {
    samples: Vec<Sample>,
    info: StreamInfo,
    duration: u64,
    length: usize,
    prefix: Vec<u8>,
}
impl RangeTrack {
    pub fn info(&self) -> StreamInfo {
        self.info
    }
    pub fn duration_ticks(&self) -> u64 {
        self.duration
    }
    pub fn file_length(&self) -> usize {
        self.length
    }
    pub fn packet_count(&self) -> usize {
        self.samples.len()
    }
    pub fn packet_range(&self, index: usize) -> Option<Range<usize>> {
        self.samples.get(index).map(|s| s.range.clone())
    }
    pub fn packet_index_at(&self, ticks: u64) -> usize {
        self.samples
            .partition_point(|s| s.dts <= ticks)
            .saturating_sub(1)
    }
    pub fn validate_packet<'a>(&self, index: usize, bytes: &'a [u8]) -> Result<Packet<'a>> {
        let s = self
            .samples
            .get(index)
            .ok_or(Error("packet index out of range"))?;
        if bytes.len() != s.range.len() {
            return Err(Error("packet byte count mismatch"));
        }
        let h = FrameHeader::validate_crc(bytes).map_err(|_| Error("invalid AV3A packet/CRC"))?;
        if h.sample_rate != self.info.sample_rate
            || h.channels != self.info.channels
            || u16::from(h.bit_depth) != self.info.bit_depth
            || u64::from(s.duration) * u64::from(h.sample_rate)
                != u64::from(FrameHeader::SAMPLES) * u64::from(self.info.timescale)
        {
            return Err(Error("container/frame format mismatch"));
        }
        Ok(Packet {
            bytes,
            index,
            dts: s.dts,
            duration: s.duration,
        })
    }
}

/// Fetch only top-level headers and metadata, skipping media by declared box size.
/// One request may be retried; a mismatched response never advances the probe.
pub struct RangeProbe {
    length: usize,
    cursor: usize,
    cache_start: usize,
    cache: Vec<u8>,
    prefix: Vec<u8>,
    metadata: Vec<(usize, Vec<u8>)>,
    metadata_bytes: usize,
    mdats: Vec<Range<usize>>,
    count: usize,
    serial: u64,
    pending: Option<RangeRequest>,
    failure: Option<Error>,
    track: Option<RangeTrack>,
}
impl RangeProbe {
    pub const WINDOW: usize = 64 * 1024;
    pub const MAX_METADATA_BOX: usize = 8 * 1024 * 1024;
    pub const MAX_METADATA_TOTAL: usize = 16 * 1024 * 1024;
    pub fn new(length: usize) -> Result<Self> {
        check_length(length)?;
        Ok(Self {
            length,
            cursor: 0,
            cache_start: 0,
            cache: Vec::new(),
            prefix: Vec::new(),
            metadata: Vec::new(),
            metadata_bytes: 0,
            mdats: Vec::new(),
            count: 0,
            serial: 0,
            pending: None,
            failure: None,
            track: None,
        })
    }
    pub fn next_request(&mut self) -> Result<Option<RangeRequest>> {
        if let Some(e) = &self.failure {
            return Err(e.clone());
        }
        let result = self.advance();
        if let Err(e) = &result {
            self.failure = Some(e.clone());
        }
        result
    }
    pub fn accept(&mut self, request: &RangeRequest, bytes: &[u8]) -> Result<()> {
        if let Some(e) = &self.failure {
            return Err(e.clone());
        }
        if self.pending.as_ref() != Some(request) || bytes.len() != request.bytes.len() {
            return Err(Error("stale or incomplete probe response"));
        }
        self.cache_start = request.bytes.start;
        if self.cache_start == 0 && bytes.len() <= Self::WINDOW && self.prefix.is_empty() {
            self.prefix = bytes.to_vec();
        }
        self.cache = bytes.to_vec();
        self.pending = None;
        Ok(())
    }
    pub fn into_track(mut self) -> Result<RangeTrack> {
        if self.next_request()?.is_some() {
            return Err(Error("range probe needs more metadata"));
        }
        self.track.take().ok_or(Error("range probe incomplete"))
    }
    fn cached(&self, bytes: Range<usize>) -> Option<&[u8]> {
        let start = bytes.start.checked_sub(self.cache_start)?;
        let end = bytes.end.checked_sub(self.cache_start)?;
        self.cache.get(start..end)
    }
    fn request(&mut self, end: usize) -> Result<Option<RangeRequest>> {
        self.serial = self
            .serial
            .checked_add(1)
            .ok_or(Error("range request serial overflow"))?;
        let request = RangeRequest {
            id: self.serial,
            bytes: self.cursor..end,
        };
        self.pending = Some(request.clone());
        Ok(Some(request))
    }
    fn advance(&mut self) -> Result<Option<RangeRequest>> {
        if let Some(pending) = &self.pending {
            return Ok(Some(pending.clone()));
        }
        if self.track.is_some() {
            return Ok(None);
        }
        while self.cursor < self.length {
            let header_end = self
                .cursor
                .checked_add(8)
                .filter(|&v| v <= self.length)
                .ok_or(Error("truncated top-level box header"))?;
            let Some(header) = self.cached(self.cursor..header_end) else {
                return self.request((self.cursor + Self::WINDOW).min(self.length));
            };
            let size32 = u32be(header, 0)?;
            let kind: [u8; 4] = header[4..8].try_into().unwrap();
            let (size, header_size) = match size32 {
                0 => (self.length - self.cursor, 8),
                1 => {
                    let end = self.cursor + 16;
                    if end > self.length {
                        return Err(Error("truncated extended box header"));
                    }
                    let Some(header) = self.cached(self.cursor..end) else {
                        return self.request((self.cursor + Self::WINDOW).min(self.length));
                    };
                    (
                        usize::try_from(u64be(header, 8)?)
                            .map_err(|_| Error("box size overflow"))?,
                        16,
                    )
                }
                n => (n as usize, 8),
            };
            let end = self
                .cursor
                .checked_add(size)
                .filter(|&v| v <= self.length)
                .ok_or(Error("box outside file"))?;
            if size < header_size {
                return Err(Error("invalid box size"));
            }
            if &kind == b"moov" || &kind == b"moof" {
                if size > Self::MAX_METADATA_BOX
                    || size > Self::MAX_METADATA_TOTAL - self.metadata_bytes
                {
                    return Err(Error("range metadata byte limit"));
                }
                let Some(bytes) = self.cached(self.cursor..end) else {
                    return self.request(end);
                };
                let owned = bytes.to_vec();
                self.metadata_bytes += owned.len();
                self.metadata.push((self.cursor, owned));
            } else if &kind == b"mdat" {
                self.mdats.push(self.cursor + header_size..end);
            }
            self.count += 1;
            if self.count > 65536 {
                return Err(Error("too many top-level boxes"));
            }
            self.cursor = end;
        }
        let mut top = Vec::new();
        for (offset, bytes) in &self.metadata {
            top.extend(boxes(bytes, *offset)?);
        }
        let index = Track::from_boxes(&[], &top, &self.mdats, false)?;
        self.track = Some(RangeTrack {
            info: StreamInfo {
                sample_rate: index.sample_rate,
                channels: index.channels,
                bit_depth: index.bit_depth,
                timescale: index.timescale,
            },
            duration: index.duration_ticks,
            samples: index.samples,
            length: self.length,
            prefix: std::mem::take(&mut self.prefix),
        });
        self.cache.clear();
        self.metadata.clear();
        Ok(None)
    }
}
