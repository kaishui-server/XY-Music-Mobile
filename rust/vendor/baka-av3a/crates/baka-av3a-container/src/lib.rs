//! Borrowed, bounded sample extraction for AV3A MP4 files.
use baka_av3a_core::FrameHeader;
use std::ops::Range;
mod fragments;
pub mod playback;
pub mod progressive;
pub mod range;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error(pub &'static str);
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}
impl std::error::Error for Error {}
type Result<T> = std::result::Result<T, Error>;

const MAX_SAMPLES: usize = 2_000_000;
const MAX_FILE_BYTES: usize = 512 * 1024 * 1024;

fn u16be(b: &[u8], p: usize) -> Result<u16> {
    Ok(u16::from_be_bytes(
        b.get(p..p + 2)
            .ok_or(Error("truncated u16"))?
            .try_into()
            .unwrap(),
    ))
}
fn u32be(b: &[u8], p: usize) -> Result<u32> {
    Ok(u32::from_be_bytes(
        b.get(p..p + 4)
            .ok_or(Error("truncated u32"))?
            .try_into()
            .unwrap(),
    ))
}
fn u64be(b: &[u8], p: usize) -> Result<u64> {
    Ok(u64::from_be_bytes(
        b.get(p..p + 8)
            .ok_or(Error("truncated u64"))?
            .try_into()
            .unwrap(),
    ))
}

#[derive(Clone, Copy)]
struct BoxRef<'a> {
    kind: [u8; 4],
    body: &'a [u8],
    offset: usize,
    start: usize,
}
fn boxes(mut bytes: &[u8], mut offset: usize) -> Result<Vec<BoxRef<'_>>> {
    let mut out = Vec::new();
    while !bytes.is_empty() {
        if out.len() >= 65536 {
            return Err(Error("too many boxes"));
        }
        let size = u32be(bytes, 0)?;
        let kind = bytes
            .get(4..8)
            .ok_or(Error("truncated box header"))?
            .try_into()
            .unwrap();
        let (size, header) = match size {
            0 => (bytes.len(), 8),
            1 => (
                usize::try_from(u64be(bytes, 8)?).map_err(|_| Error("box size overflow"))?,
                16,
            ),
            n => (n as usize, 8),
        };
        if size < header || size > bytes.len() {
            return Err(Error("invalid box size"));
        }
        out.push(BoxRef {
            kind,
            body: &bytes[header..size],
            offset: offset + header,
            start: offset,
        });
        bytes = &bytes[size..];
        offset += size;
    }
    Ok(out)
}
fn one<'a>(list: &[BoxRef<'a>], kind: &[u8; 4]) -> Result<BoxRef<'a>> {
    let mut found = list.iter().filter(|b| &b.kind == kind);
    let value = *found.next().ok_or(Error("missing box"))?;
    if found.next().is_some() {
        return Err(Error("duplicate box"));
    }
    Ok(value)
}
fn children(b: BoxRef<'_>) -> Result<Vec<BoxRef<'_>>> {
    boxes(b.body, b.offset)
}
fn table(bytes: &[u8], width: usize) -> Result<usize> {
    if u32be(bytes, 0)? != 0 {
        return Err(Error("unsupported full-box version/flags"));
    }
    let count = u32be(bytes, 4)? as usize;
    if count > MAX_SAMPLES
        || count.checked_mul(width).and_then(|n| n.checked_add(8)) != Some(bytes.len())
    {
        return Err(Error("invalid table length"));
    }
    Ok(count)
}

#[derive(Clone, Debug)]
struct Sample {
    range: Range<usize>,
    dts: u64,
    duration: u32,
}

#[derive(Debug)]
pub struct Track<'a> {
    data: &'a [u8],
    samples: Vec<Sample>,
    pub sample_rate: u32,
    pub channels: u16,
    pub bit_depth: u16,
    pub timescale: u32,
    pub duration_ticks: u64,
    selection: (usize, usize),
}

#[derive(Debug)]
pub struct Packet<'a> {
    pub bytes: &'a [u8],
    pub index: usize,
    pub dts: u64,
    pub duration: u32,
}

fn in_mdat(mdats: &[Range<usize>], range: Range<usize>) -> bool {
    let index = mdats.partition_point(|m| m.start <= range.start);
    index > 0 && range.end <= mdats[index - 1].end
}

fn classic_samples(
    stbl: &[BoxRef<'_>],
    mdats: &[Range<usize>],
    description: usize,
) -> Result<Vec<Sample>> {
    let sizes_box = one(stbl, b"stsz")?.body;
    if u32be(sizes_box, 0)? != 0 {
        return Err(Error("unsupported stsz version"));
    }
    let uniform = u32be(sizes_box, 4)?;
    let count = u32be(sizes_box, 8)? as usize;
    if count > MAX_SAMPLES {
        return Err(Error("invalid sample count"));
    }
    let expected = 12 + if uniform == 0 { count * 4 } else { 0 };
    if sizes_box.len() != expected {
        return Err(Error("stsz length mismatch"));
    }
    if count == 0 {
        for (kind, width) in [(b"stts", 8), (b"stsc", 12)] {
            if table(one(stbl, kind)?.body, width)? != 0 {
                return Err(Error("nonempty initialization table"));
            }
        }
        let offset = match (
            stbl.iter().any(|b| b.kind == *b"stco"),
            stbl.iter().any(|b| b.kind == *b"co64"),
        ) {
            (true, false) => (one(stbl, b"stco")?, 4),
            (false, true) => (one(stbl, b"co64")?, 8),
            _ => return Err(Error("missing or conflicting chunk offsets")),
        };
        if table(offset.0.body, offset.1)? != 0 {
            return Err(Error("nonempty initialization offsets"));
        }
        return Ok(Vec::new());
    }
    let mut sizes = Vec::with_capacity(count);
    for i in 0..count {
        let size = if uniform == 0 {
            u32be(sizes_box, 12 + i * 4)?
        } else {
            uniform
        } as usize;
        if size == 0 || size > 1024 * 1024 {
            return Err(Error("invalid packet size"));
        }
        sizes.push(size);
    }
    let offsets = match (
        stbl.iter().any(|b| b.kind == *b"stco"),
        stbl.iter().any(|b| b.kind == *b"co64"),
    ) {
        (true, false) => (one(stbl, b"stco")?.body, 4),
        (false, true) => (one(stbl, b"co64")?.body, 8),
        _ => return Err(Error("missing or conflicting chunk offsets")),
    };
    let chunks = table(offsets.0, offsets.1)?;
    if chunks == 0 || chunks > count {
        return Err(Error("invalid chunk count"));
    }
    let sc = one(stbl, b"stsc")?.body;
    let rules_count = table(sc, 12)?;
    if rules_count == 0 {
        return Err(Error("empty stsc"));
    }
    let mut rules = Vec::with_capacity(rules_count);
    for i in 0..rules_count {
        let p = 8 + i * 12;
        let first = u32be(sc, p)? as usize;
        let per = u32be(sc, p + 4)? as usize;
        if first == 0
            || first > chunks
            || per == 0
            || per > count
            || u32be(sc, p + 8)? as usize != description + 1
            || (i == 0 && first != 1)
            || rules.last().is_some_and(|(prev, _)| *prev >= first)
        {
            return Err(Error("invalid stsc rule"));
        }
        rules.push((first, per));
    }
    let mut samples = Vec::with_capacity(count);
    let mut rule = 0;
    for chunk in 0..chunks {
        while rule + 1 < rules.len() && rules[rule + 1].0 <= chunk + 1 {
            rule += 1;
        }
        let p = 8 + chunk * offsets.1;
        let mut offset = if offsets.1 == 4 {
            u32be(offsets.0, p)? as usize
        } else {
            usize::try_from(u64be(offsets.0, p)?).map_err(|_| Error("chunk offset overflow"))?
        };
        for _ in 0..rules[rule].1 {
            let size = *sizes
                .get(samples.len())
                .ok_or(Error("too many mapped samples"))?;
            let end = offset
                .checked_add(size)
                .ok_or(Error("sample range overflow"))?;
            if !in_mdat(mdats, offset..end) {
                return Err(Error("sample outside mdat"));
            }
            samples.push(Sample {
                range: offset..end,
                dts: 0,
                duration: 0,
            });
            offset = end;
        }
    }
    if samples.len() != count {
        return Err(Error("unmapped samples"));
    }
    let ts = one(stbl, b"stts")?.body;
    let runs = table(ts, 8)?;
    let mut index = 0;
    let mut dts = 0u64;
    for i in 0..runs {
        let n = u32be(ts, 8 + i * 8)? as usize;
        let duration = u32be(ts, 12 + i * 8)?;
        if n == 0 || duration == 0 || n > count - index {
            return Err(Error("invalid stts run"));
        }
        for sample in &mut samples[index..index + n] {
            sample.dts = dts;
            sample.duration = duration;
            dts = dts
                .checked_add(u64::from(duration))
                .ok_or(Error("duration overflow"))?;
        }
        index += n;
    }
    if index != count {
        return Err(Error("duration/count mismatch"));
    }
    Ok(samples)
}

impl<'a> Track<'a> {
    pub fn parse(data: &'a [u8]) -> Result<Self> {
        if data.len() > MAX_FILE_BYTES {
            return Err(Error("file exceeds 512 MiB limit"));
        }
        let top = boxes(data, 0)?;
        let mdats: Vec<_> = top
            .iter()
            .filter(|b| b.kind == *b"mdat")
            .map(|b| b.offset..b.offset + b.body.len())
            .collect();
        Self::from_boxes(data, &top, &mdats, false)
    }

    fn from_boxes(
        data: &'a [u8],
        top: &[BoxRef<'_>],
        mdats: &[Range<usize>],
        initialization: bool,
    ) -> Result<Self> {
        let fragmented = top.iter().any(|b| b.kind == *b"moof");
        let moov = children(one(top, b"moov")?)?;
        let mut selected = None;
        for (track_index, trak) in moov.iter().filter(|b| b.kind == *b"trak").enumerate() {
            let trak = children(*trak)?;
            let mdia = children(one(&trak, b"mdia")?)?;
            let hdlr = one(&mdia, b"hdlr")?;
            if hdlr.body.get(8..12) != Some(b"soun") {
                continue;
            }
            let minf = children(one(&mdia, b"minf")?)?;
            let stbl = children(one(&minf, b"stbl")?)?;
            let stsd = one(&stbl, b"stsd")?;
            if u32be(stsd.body, 0)? != 0 {
                return Err(Error("unsupported stsd version"));
            }
            let entries = boxes(
                stsd.body.get(8..).ok_or(Error("truncated stsd"))?,
                stsd.offset + 8,
            )?;
            if entries.len() != u32be(stsd.body, 4)? as usize {
                return Err(Error("stsd count mismatch"));
            }
            let av3a: Vec<_> = entries
                .iter()
                .enumerate()
                .filter(|(_, e)| e.kind == *b"av3a")
                .collect();
            if av3a.is_empty() {
                continue;
            }
            if selected.is_some() || av3a.len() != 1 {
                return Err(Error("ambiguous AV3A tracks"));
            }
            let (description, entry) = av3a[0];
            if u16be(entry.body, 6)? != 1 || u16be(entry.body, 8)? != 0 {
                return Err(Error("unsupported audio sample entry"));
            }
            // Sample-entry child boxes are structurally checked, including extended sizes.
            boxes(
                entry.body.get(28..).ok_or(Error("short audio entry"))?,
                entry.offset + 28,
            )?;
            let sample_rate_fixed = u32be(entry.body, 24)?;
            if sample_rate_fixed & 0xffff != 0 {
                return Err(Error("fractional audio sample rate"));
            }
            let sample_rate = sample_rate_fixed >> 16;
            let channels = u16be(entry.body, 16)?;
            let bit_depth = u16be(entry.body, 18)?;
            if sample_rate == 0 || channels == 0 || channels > 256 {
                return Err(Error("invalid audio format"));
            }
            let mdhd = one(&mdia, b"mdhd")?.body;
            let (timescale, declared_duration) = match mdhd.first() {
                Some(0) => (u32be(mdhd, 12)?, u64::from(u32be(mdhd, 16)?)),
                Some(1) => (u32be(mdhd, 20)?, u64be(mdhd, 24)?),
                _ => return Err(Error("unsupported mdhd version")),
            };
            if timescale == 0 {
                return Err(Error("zero timescale"));
            }
            let mut samples = classic_samples(&stbl, mdats, description)?;
            let initial_duration = samples.last().map_or(0, |s| s.dts + u64::from(s.duration));
            if fragmented {
                fragments::append(top, &moov, &trak, mdats, description, &mut samples)?;
            }
            if samples.is_empty() && !initialization {
                return Err(Error("empty audio track"));
            }
            let dts = samples
                .last()
                .map_or(Some(0), |s| s.dts.checked_add(u64::from(s.duration)))
                .ok_or(Error("duration overflow"))?;
            let unknown = if mdhd[0] == 0 {
                u64::from(u32::MAX)
            } else {
                u64::MAX
            };
            if !(initialization && samples.is_empty())
                && declared_duration != dts
                && !(fragmented
                    && (declared_duration == 0
                        || declared_duration == unknown
                        || declared_duration == initial_duration))
            {
                return Err(Error("duration/count mismatch"));
            }
            let mut ranges: Vec<_> = samples.iter().map(|s| s.range.clone()).collect();
            ranges.sort_unstable_by_key(|r| r.start);
            if ranges.windows(2).any(|w| w[0].end > w[1].start) {
                return Err(Error("overlapping samples"));
            }
            selected = Some(Self {
                data,
                samples,
                sample_rate,
                channels,
                bit_depth,
                timescale,
                duration_ticks: dts,
                selection: (track_index, description),
            });
        }
        selected.ok_or(Error("no AV3A audio track"))
    }

    pub fn packet_count(&self) -> usize {
        self.samples.len()
    }
    pub fn packet(&self, index: usize) -> Option<Packet<'a>> {
        self.samples.get(index).map(|s| Packet {
            bytes: &self.data[s.range.clone()],
            index,
            dts: s.dts,
            duration: s.duration,
        })
    }
    pub fn packets(&self) -> impl ExactSizeIterator<Item = Packet<'a>> + '_ {
        self.samples.iter().enumerate().map(|(index, s)| Packet {
            bytes: &self.data[s.range.clone()],
            index,
            dts: s.dts,
            duration: s.duration,
        })
    }
    /// Packet at or immediately before a decode timestamp. Decoder preroll is separate.
    pub fn packet_at(&self, ticks: u64) -> Packet<'a> {
        let index = self
            .samples
            .partition_point(|s| s.dts <= ticks)
            .saturating_sub(1);
        self.packet(index).expect("validated nonempty track")
    }
    /// Validate every packet, configuration continuity and media timing.
    pub fn validate_frames(&self) -> Result<FrameHeader> {
        let mut initial = None;
        for p in self.packets() {
            let h =
                FrameHeader::validate_packet(p.bytes).map_err(|_| Error("invalid AV3A packet"))?;
            if h.sample_rate != self.sample_rate
                || h.channels != self.channels
                || u16::from(h.bit_depth) != self.bit_depth
                || u64::from(p.duration) * u64::from(h.sample_rate)
                    != u64::from(FrameHeader::SAMPLES) * u64::from(self.timescale)
            {
                return Err(Error("container/frame format mismatch"));
            }
            if let Some(prev) = &initial {
                let prev: &FrameHeader = prev;
                if prev.profile != h.profile
                    || prev.neural_type != h.neural_type
                    || prev.bitrate != h.bitrate
                    || prev.bed_bitrate != h.bed_bitrate
                {
                    return Err(Error("midstream configuration change"));
                }
            } else {
                initial = Some(h);
            }
        }
        initial.ok_or(Error("empty track"))
    }
}
