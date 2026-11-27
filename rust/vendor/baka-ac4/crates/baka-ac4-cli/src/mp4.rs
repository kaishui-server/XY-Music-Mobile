//! Minimal MP4 reader: extracts the sample table of the first AC-4 audio
//! track (stsd/stts/stsc/stsz/stco/co64). Not a general-purpose demuxer.

#[allow(dead_code)] // sample_rate/duration_units are part of the track header info
pub struct Track {
    pub codec: String,
    pub channels: u16,
    pub sample_rate: u32,
    pub timescale: u32,
    pub duration_units: u64,
    /// (offset, size) of every sample, in decode order.
    pub samples: Vec<(u64, u32)>,
}

struct Reader<'a> {
    d: &'a [u8],
}

impl<'a> Reader<'a> {
    fn u16(&self, o: usize) -> Option<u16> {
        Some(u16::from_be_bytes([*self.d.get(o)?, *self.d.get(o + 1)?]))
    }
    fn u32(&self, o: usize) -> Option<u32> {
        Some(u32::from_be_bytes([
            *self.d.get(o)?,
            *self.d.get(o + 1)?,
            *self.d.get(o + 2)?,
            *self.d.get(o + 3)?,
        ]))
    }
    fn u64(&self, o: usize) -> Option<u64> {
        let hi = self.u32(o)? as u64;
        let lo = self.u32(o + 4)? as u64;
        Some((hi << 32) | lo)
    }
    fn type4(&self, o: usize) -> Option<String> {
        Some(String::from_utf8_lossy(self.d.get(o..o + 4)?).into_owned())
    }
}

/// Calls `f(fullbox_header_offset, body_offset)` for each child box of the
/// box spanning `start..end`.
fn walk_boxes<F>(r: &Reader, start: usize, end: usize, mut f: F)
where
    F: FnMut(&Reader, &str, usize, usize),
{
    let mut o = start;
    while o + 8 <= end {
        let size = match r.u32(o) {
            Some(s) => s as usize,
            None => break,
        };
        let name = match r.type4(o + 4) {
            Some(n) => n,
            None => break,
        };
        let (size, hdr) = if size == 1 {
            let Some(extended) = r.u64(o + 8).and_then(|n| usize::try_from(n).ok()) else {
                break;
            };
            (extended, 16)
        } else {
            (size, 8)
        };
        if size == 0 {
            // box extends to the end of the enclosing box/file
            f(r, &name, o + hdr, end);
            break;
        }
        if size < hdr || size > end - o {
            break;
        }
        f(r, &name, o + hdr, o + size);
        o += size;
    }
}

fn find_boxes(r: &Reader, start: usize, end: usize, path: &str) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let (head, tail) = match path.split_once('/') {
        Some((h, t)) => (h, Some(t)),
        None => (path, None),
    };
    walk_boxes(r, start, end, |r, name, bs, be| {
        if name == head {
            match tail {
                Some(t) => out.extend(find_boxes(r, bs, be, t)),
                None => out.push((bs, be)),
            }
        }
    });
    out
}

/// Parses the sample table of the first `ac-4` sound track.
pub fn read_ac4_track(data: &[u8]) -> Result<Track, String> {
    let r = Reader { d: data };
    if r.type4(4).as_deref() != Some("ftyp") {
        return Err("not an MP4 file (no ftyp box)".into());
    }

    let mut track: Option<Track> = None;
    for (moov_s, moov_e) in find_boxes(&r, 0, data.len(), "moov").iter() {
        for (stbl_s, stbl_e) in find_boxes(&r, *moov_s, *moov_e, "trak/mdia/minf/stbl") {
            // Only sound tracks whose stsd carries an ac-4 entry.
            let mut codec = String::new();
            let mut channels = 0u16;
            let mut sample_rate = 0u32;
            for (stsd_s, _stsd_e) in find_boxes(&r, stbl_s, stbl_e, "stsd") {
                // FullBox header (4B version/flags + 4B entry_count), then
                // the sample entry: size(4) format(4) 6 reserved + 2 data ref
                // idx version(2) revision(2) vendor(4) channels(2) ... rate(16.16)
                let entry = stsd_s + 8;
                codec = r.type4(entry + 4).unwrap_or_default();
                if codec != "ac-4" && codec != "AC-4" {
                    continue;
                }
                channels = r.u16(entry + 24).unwrap_or(0);
                sample_rate = r.u32(entry + 32).unwrap_or(0) >> 16;
            }
            if codec != "ac-4" && codec != "AC-4" {
                continue;
            }

            let mut sizes: Vec<u32> = Vec::new();
            for (b, e) in find_boxes(&r, stbl_s, stbl_e, "stsz").iter() {
                let sample_size = r.u32(*b + 4).unwrap_or(0);
                let count = r.u32(*b + 8).unwrap_or(0) as usize;
                if e - b < 12 || count > data.len() {
                    return Err("invalid stsz sample count".into());
                }
                if sample_size != 0 {
                    sizes = vec![sample_size; count];
                } else {
                    if count > (e - b - 12) / 4 {
                        return Err("truncated stsz table".into());
                    }
                    sizes.reserve(count);
                    for i in 0..count {
                        sizes.push(r.u32(*b + 12 + i * 4).unwrap_or(0));
                    }
                }
            }

            let mut stsc: Vec<(u32, u32)> = Vec::new(); // (first_chunk, samples_per_chunk)
            for (b, e) in find_boxes(&r, stbl_s, stbl_e, "stsc").iter() {
                let count = r.u32(*b + 4).unwrap_or(0) as usize;
                if e - b < 8 || count > (e - b - 8) / 12 {
                    return Err("truncated stsc table".into());
                }
                for i in 0..count {
                    let o = *b + 8 + i * 12;
                    stsc.push((r.u32(o).unwrap_or(0), r.u32(o + 4).unwrap_or(0)));
                }
            }

            let mut chunk_offsets: Vec<u64> = Vec::new();
            if !find_boxes(&r, stbl_s, stbl_e, "stco").is_empty() {
                for (b, e) in find_boxes(&r, stbl_s, stbl_e, "stco") {
                    let count = r.u32(b + 4).unwrap_or(0) as usize;
                    if e - b < 8 || count > (e - b - 8) / 4 {
                        return Err("truncated stco table".into());
                    }
                    for i in 0..count {
                        chunk_offsets.push(r.u32(b + 8 + i * 4).unwrap_or(0) as u64);
                    }
                }
            }
            for (b, e) in find_boxes(&r, stbl_s, stbl_e, "co64") {
                let count = r.u32(b + 4).unwrap_or(0) as usize;
                if e - b < 8 || count > (e - b - 8) / 8 {
                    return Err("truncated co64 table".into());
                }
                for i in 0..count {
                    chunk_offsets.push(r.u64(b + 8 + i * 8).unwrap_or(0));
                }
            }

            // Map chunks -> samples using stsc runs.
            let mut samples: Vec<(u64, u32)> = Vec::with_capacity(sizes.len());
            let mut si = 0usize;
            for (ci, &chunk_off) in chunk_offsets.iter().enumerate() {
                let chunk = ci as u32 + 1;
                // samples per chunk for this chunk (last run extends to end)
                let mut spc = stsc.last().map(|&(_, s)| s).unwrap_or(0);
                for w in stsc.windows(2) {
                    if chunk >= w[0].0 && chunk < w[1].0 {
                        spc = w[0].1;
                    }
                }
                if let Some(&(first, s)) = stsc.first()
                    && chunk < first
                {
                    spc = s;
                }
                let mut off = chunk_off;
                for _ in 0..spc {
                    if si >= sizes.len() {
                        break;
                    }
                    let sz = sizes[si];
                    let end = off
                        .checked_add(sz as u64)
                        .filter(|&end| end <= data.len() as u64)
                        .ok_or_else(|| "sample extends beyond MP4 input".to_string())?;
                    if sz == 0 {
                        return Err("empty MP4 sample".into());
                    }
                    samples.push((off, sz));
                    off = end;
                    si += 1;
                }
            }

            if samples.is_empty() || si != sizes.len() {
                return Err("incomplete MP4 sample mapping".into());
            }

            let mut timescale = 0u32;
            let mut duration_units = 0u64;
            // mdhd sits beside minf: find the trak that contains this stbl.
            for (trak_s, trak_e) in find_boxes(&r, *moov_s, *moov_e, "trak") {
                if trak_s <= stbl_s && stbl_e <= trak_e {
                    for (b, _) in find_boxes(&r, trak_s, trak_e, "mdia/mdhd") {
                        let version = r.d.get(b).copied().unwrap_or(0);
                        if version == 1 {
                            timescale = r.u32(b + 20).unwrap_or(0);
                            duration_units = r.u64(b + 24).unwrap_or(0);
                        } else {
                            timescale = r.u32(b + 12).unwrap_or(0);
                            duration_units = r.u32(b + 16).unwrap_or(0) as u64;
                        }
                    }
                    break;
                }
            }

            track = Some(Track {
                codec,
                channels,
                sample_rate,
                timescale,
                duration_units,
                samples,
            });
            break;
        }
    }

    track.ok_or_else(|| "no ac-4 audio track found".to_string())
}
