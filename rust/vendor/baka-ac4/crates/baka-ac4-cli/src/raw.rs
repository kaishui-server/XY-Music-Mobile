//! Raw AC-4 elementary stream reader: splits a concatenated .ac4 file into
//! frames using the sync header size fields: `total = 4 + frame_size`,
//! extended size `total = 7 + ext24`, and 0xAC41 frames carry a trailing
//! 2-byte substream index (`total += 2`).

use crate::mp4::Track;

pub fn is_raw_ac4(data: &[u8]) -> bool {
    data.len() >= 2 && data[0] == 0xAC && (data[1] == 0x40 || data[1] == 0x41)
}

pub fn read_ac4_frames(data: &[u8]) -> Result<Track, String> {
    let mut samples = Vec::new();
    let mut off = 0usize;
    while off + 4 <= data.len() {
        if data[off] != 0xAC || (data[off + 1] != 0x40 && data[off + 1] != 0x41) {
            let trailing = data.len() - off;
            if samples.is_empty() {
                return Err(format!("no AC-4 syncword found (got {:#04x})", data[0]));
            }
            eprintln!(
                "warning: {trailing} trailing bytes after {} frames",
                samples.len()
            );
            break;
        }
        let mut total = u16::from_be_bytes([data[off + 2], data[off + 3]]) as usize + 4;
        if total == 4 + 0xFFFF {
            if off + 7 > data.len() {
                break;
            }
            let ext = ((data[off + 4] as usize) << 16)
                | ((data[off + 5] as usize) << 8)
                | data[off + 6] as usize;
            total = 7 + ext;
        }
        if data[off + 1] == 0x41 {
            total += 2;
        }
        if off + total > data.len() {
            let trailing = data.len() - off;
            eprintln!("warning: truncated final frame ({trailing} of {total} bytes); dropped");
            break;
        }
        samples.push((off as u64, total as u32));
        off += total;
    }
    if samples.is_empty() {
        return Err("no complete AC-4 frames found".into());
    }
    Ok(Track {
        codec: "ac4-raw".into(),
        channels: 0,
        sample_rate: 0,
        timescale: 0,
        duration_units: 0,
        samples,
    })
}
