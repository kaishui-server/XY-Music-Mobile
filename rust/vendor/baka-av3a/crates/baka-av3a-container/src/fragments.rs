//! Fragment defaults, signed addressing and decode-time continuity.
use super::*;

#[derive(Clone, Copy)]
struct Defaults {
    track: u32,
    description: u32,
    duration: u32,
    size: u32,
}
fn optional<'a>(list: &[BoxRef<'a>], kind: &[u8; 4]) -> Result<Option<BoxRef<'a>>> {
    if list.iter().any(|b| &b.kind == kind) {
        Ok(Some(one(list, kind)?))
    } else {
        Ok(None)
    }
}
fn full(bytes: &[u8], versions: &[u8], allowed: u32) -> Result<u32> {
    let word = u32be(bytes, 0)?;
    if !versions.contains(&((word >> 24) as u8)) || word & 0xffffff & !allowed != 0 {
        return Err(Error("unsupported fragment version/flags"));
    }
    Ok(word & 0xffffff)
}
fn track_id(trak: &[BoxRef<'_>]) -> Result<u32> {
    let tkhd = one(trak, b"tkhd")?.body;
    let id = match tkhd.first() {
        Some(0) => u32be(tkhd, 12)?,
        Some(1) => u32be(tkhd, 20)?,
        _ => return Err(Error("unsupported tkhd version")),
    };
    if id == 0 {
        return Err(Error("zero track id"));
    }
    Ok(id)
}
fn next_u32(bytes: &[u8], position: &mut usize) -> Result<u32> {
    let value = u32be(bytes, *position)?;
    *position += 4;
    Ok(value)
}

pub(super) fn append(
    top: &[BoxRef<'_>],
    moov: &[BoxRef<'_>],
    trak: &[BoxRef<'_>],
    mdats: &[Range<usize>],
    description: usize,
    samples: &mut Vec<Sample>,
) -> Result<()> {
    let selected = track_id(trak)?;
    let mut track_ids = Vec::new();
    for track in moov.iter().filter(|b| b.kind == *b"trak") {
        let id = track_id(&children(*track)?)?;
        if track_ids.contains(&id) {
            return Err(Error("duplicate track id"));
        }
        track_ids.push(id);
    }
    let mvex = children(one(moov, b"mvex")?)?;
    let mut defaults = Vec::new();
    for trex in mvex.iter().filter(|b| b.kind == *b"trex") {
        full(trex.body, &[0], 0)?;
        if trex.body.len() != 24 {
            return Err(Error("trex length mismatch"));
        }
        let track = u32be(trex.body, 4)?;
        let description = u32be(trex.body, 8)?;
        if !track_ids.contains(&track)
            || description == 0
            || defaults.iter().any(|d: &Defaults| d.track == track)
        {
            return Err(Error("invalid/duplicate trex"));
        }
        defaults.push(Defaults {
            track,
            description,
            duration: u32be(trex.body, 12)?,
            size: u32be(trex.body, 16)?,
        });
    }
    if !defaults.iter().any(|d| d.track == selected) {
        return Err(Error("missing track defaults"));
    }
    let mut expected_dts = samples.last().map(|s| s.dts + u64::from(s.duration));
    let mut referenced = samples.len();
    let mut previous_sequence = None;
    for moof in top.iter().filter(|b| b.kind == *b"moof") {
        let boxes = children(*moof)?;
        let mfhd = one(&boxes, b"mfhd")?.body;
        full(mfhd, &[0], 0)?;
        if mfhd.len() != 8 {
            return Err(Error("mfhd length mismatch"));
        }
        let sequence = u32be(mfhd, 4)?;
        if previous_sequence.is_some_and(|prev| sequence <= prev) {
            return Err(Error("fragment sequence is not increasing"));
        }
        previous_sequence = Some(sequence);
        let trafs: Vec<_> = boxes.iter().filter(|b| b.kind == *b"traf").collect();
        if trafs.is_empty() {
            return Err(Error("fragment has no traf"));
        }
        let mut implicit_base = moof.start;
        for traf in trafs {
            let boxes = children(*traf)?;
            let header = one(&boxes, b"tfhd")?.body;
            let flags = full(header, &[0], 0x03003b)?;
            let id = u32be(header, 4)?;
            let mut values = *defaults
                .iter()
                .find(|d| d.track == id)
                .ok_or(Error("missing fragment track defaults"))?;
            let is_selected = id == selected;
            let mut position = 8;
            let base = if flags & 1 != 0 {
                let value = usize::try_from(u64be(header, position)?)
                    .map_err(|_| Error("fragment base overflow"))?;
                position += 8;
                value
            } else if flags & 0x020000 != 0 {
                moof.start
            } else {
                implicit_base
            };
            if flags & 2 != 0 {
                values.description = next_u32(header, &mut position)?;
            }
            if flags & 8 != 0 {
                values.duration = next_u32(header, &mut position)?;
            }
            if flags & 16 != 0 {
                values.size = next_u32(header, &mut position)?;
            }
            if flags & 32 != 0 {
                next_u32(header, &mut position)?;
            }
            if position != header.len() {
                return Err(Error("tfhd length mismatch"));
            }
            if values.description == 0 {
                return Err(Error("zero fragment description index"));
            }
            if is_selected && values.description as usize != description + 1 {
                return Err(Error("fragment sample description changed"));
            }
            let timestamp = if let Some(tfdt) = optional(&boxes, b"tfdt")? {
                full(tfdt.body, &[0, 1], 0)?;
                match tfdt.body[0] {
                    0 if tfdt.body.len() == 8 => u64::from(u32be(tfdt.body, 4)?),
                    1 if tfdt.body.len() == 12 => u64be(tfdt.body, 4)?,
                    _ => return Err(Error("tfdt length mismatch")),
                }
            } else {
                if is_selected {
                    expected_dts.unwrap_or(0)
                } else {
                    0
                }
            };
            if is_selected && expected_dts.is_some_and(|dts| dts != timestamp) {
                return Err(Error("fragment decode-time discontinuity"));
            }
            let mut dts = timestamp;
            let mut data_end = None;
            for run in boxes.iter().filter(|b| b.kind == *b"trun") {
                let flags_run = full(run.body, &[0, 1], 0xf05)?;
                if flags_run & 4 != 0 && flags_run & 0x400 != 0 {
                    return Err(Error("conflicting sample flags"));
                }
                let count = u32be(run.body, 4)? as usize;
                referenced = referenced
                    .checked_add(count)
                    .filter(|&n| n <= MAX_SAMPLES)
                    .ok_or(Error("too many fragment samples"))?;
                if flags & 0x010000 != 0 && count != 0 {
                    return Err(Error("nonempty duration-is-empty fragment"));
                }
                let mut p = 8;
                let mut offset = if flags_run & 1 != 0 {
                    let relative = next_u32(run.body, &mut p)? as i32;
                    usize::try_from((base as i128) + i128::from(relative))
                        .map_err(|_| Error("signed fragment offset overflow"))?
                } else {
                    data_end.unwrap_or(base)
                };
                if flags_run & 4 != 0 {
                    next_u32(run.body, &mut p)?;
                }
                let width = (flags_run & 0xf00).count_ones() as usize * 4;
                if count.checked_mul(width).and_then(|n| n.checked_add(p)) != Some(run.body.len()) {
                    return Err(Error("trun length/count mismatch"));
                }
                for _ in 0..count {
                    let duration = if flags_run & 0x100 != 0 {
                        next_u32(run.body, &mut p)?
                    } else {
                        values.duration
                    };
                    let size = if flags_run & 0x200 != 0 {
                        next_u32(run.body, &mut p)?
                    } else {
                        values.size
                    } as usize;
                    if flags_run & 0x400 != 0 {
                        next_u32(run.body, &mut p)?;
                    }
                    if flags_run & 0x800 != 0 {
                        let composition = next_u32(run.body, &mut p)?;
                        if is_selected && composition != 0 {
                            return Err(Error("audio composition offset is unsupported"));
                        }
                    }
                    if size == 0 || (is_selected && (size > 1024 * 1024 || duration == 0)) {
                        return Err(Error("invalid fragment sample size/duration"));
                    }
                    let end = offset
                        .checked_add(size)
                        .ok_or(Error("fragment sample range overflow"))?;
                    if !in_mdat(mdats, offset..end) {
                        return Err(Error("fragment sample outside mdat"));
                    }
                    if is_selected {
                        samples.push(Sample {
                            range: offset..end,
                            dts,
                            duration,
                        });
                    }
                    dts = dts
                        .checked_add(u64::from(duration))
                        .ok_or(Error("fragment timestamp overflow"))?;
                    offset = end;
                }
                data_end = Some(offset);
            }
            implicit_base = data_end.unwrap_or(base);
            if is_selected {
                expected_dts = Some(dts);
            }
        }
    }
    Ok(())
}
