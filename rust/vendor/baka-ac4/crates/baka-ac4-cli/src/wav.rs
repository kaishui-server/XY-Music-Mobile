//! WAV output with explicit speaker masks and a fixed stream format.
use std::io::{self, Seek, SeekFrom, Write};

pub struct WavWriter<W: Write + Seek> {
    out: W,
    channels: u16,
    sample_rate: u32,
    channel_mask: u32,
    float: bool,
    extensible: bool,
    data_bytes: u64,
    buf: Vec<u8>,
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

impl<W: Write + Seek> WavWriter<W> {
    pub fn start_fmt(mut out: W, float: bool) -> io::Result<Self> {
        out.write_all(&[0; 44])?;
        Ok(Self {
            out,
            channels: 0,
            sample_rate: 0,
            channel_mask: 0,
            float,
            extensible: false,
            data_bytes: 0,
            buf: Vec::new(),
        })
    }

    /// Speaker planes are in ascending mask-bit order. A zero mask preserves
    /// unassigned core signals; it must not imply a surround layout.
    pub fn write_frame_planar(
        &mut self,
        chans: &[Vec<f32>],
        sample_rate: u32,
        mask: u64,
    ) -> io::Result<()> {
        let channels = u16::try_from(chans.len()).map_err(|_| invalid("too many WAV channels"))?;
        let channel_mask = u32::try_from(mask)
            .map_err(|_| invalid("speaker mask cannot be represented in WAV"))?;
        let n = chans.first().map_or(0, Vec::len);
        if channels == 0 || sample_rate == 0 || n == 0 || chans.iter().any(|c| c.len() != n) {
            return Err(invalid("empty or inconsistent PCM frame"));
        }
        if mask != 0 && mask.count_ones() != channels as u32 {
            return Err(invalid("speaker mask does not match channel count"));
        }
        if chans.iter().flatten().any(|x| !x.is_finite()) {
            return Err(invalid("non-finite PCM sample"));
        }
        if self.channels != 0
            && (self.channels != channels
                || self.sample_rate != sample_rate
                || self.channel_mask != channel_mask)
        {
            return Err(invalid("PCM format changed within WAV output"));
        }
        let bps = if self.float { 4 } else { 2 };
        let block_align = channels
            .checked_mul(bps)
            .ok_or_else(|| invalid("WAV block alignment overflow"))?;
        sample_rate
            .checked_mul(block_align as u32)
            .ok_or_else(|| invalid("WAV byte rate overflow"))?;
        let bytes = n
            .checked_mul(block_align as usize)
            .ok_or_else(|| invalid("PCM frame size overflow"))?;
        let standard_mask = match channels {
            1 => 4,
            2 => 3,
            _ => 0,
        };
        let extensible = channels > 2 || channel_mask != standard_mask;
        let header_bytes = if extensible { 68u64 } else { 44 };
        let total = self
            .data_bytes
            .checked_add(bytes as u64)
            .filter(|&total| total <= u32::MAX as u64 - (header_bytes - 8))
            .ok_or_else(|| invalid("WAV exceeds RIFF size limit"))?;
        self.buf.clear();
        self.buf.reserve(bytes);
        for i in 0..n {
            for c in chans {
                let v = c[i];
                if self.float {
                    self.buf.extend_from_slice(&v.to_le_bytes());
                } else {
                    self.buf.extend_from_slice(
                        &((v * 32768.0).round().clamp(-32768.0, 32767.0) as i16).to_le_bytes(),
                    );
                }
            }
        }
        if self.channels == 0 {
            if extensible {
                self.out.write_all(&[0; 24])?;
            }
            self.channels = channels;
            self.sample_rate = sample_rate;
            self.channel_mask = channel_mask;
            self.extensible = extensible;
        }
        self.out.write_all(&self.buf)?;
        self.data_bytes = total;
        Ok(())
    }

    pub fn finish(mut self) -> io::Result<()> {
        if self.channels == 0 {
            return Err(invalid("no audio frames decoded"));
        }
        let bps = if self.float { 4u16 } else { 2 };
        let align = self.channels * bps;
        let tag = if self.float { 3u16 } else { 1 };
        let header_bytes = if self.extensible { 68u32 } else { 44 };
        let mut hdr = Vec::with_capacity(header_bytes as usize);
        hdr.extend_from_slice(b"RIFF");
        hdr.extend_from_slice(&(self.data_bytes as u32 + (header_bytes - 8)).to_le_bytes());
        hdr.extend_from_slice(b"WAVEfmt ");
        hdr.extend_from_slice(&(if self.extensible { 40u32 } else { 16 }).to_le_bytes());
        hdr.extend_from_slice(&(if self.extensible { 0xfffeu16 } else { tag }).to_le_bytes());
        hdr.extend_from_slice(&self.channels.to_le_bytes());
        hdr.extend_from_slice(&self.sample_rate.to_le_bytes());
        hdr.extend_from_slice(&(self.sample_rate * align as u32).to_le_bytes());
        hdr.extend_from_slice(&align.to_le_bytes());
        hdr.extend_from_slice(&(bps * 8).to_le_bytes());
        if self.extensible {
            hdr.extend_from_slice(&22u16.to_le_bytes());
            hdr.extend_from_slice(&(bps * 8).to_le_bytes());
            hdr.extend_from_slice(&self.channel_mask.to_le_bytes());
            hdr.extend_from_slice(&(tag as u32).to_le_bytes());
            hdr.extend_from_slice(&[0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71]);
        }
        hdr.extend_from_slice(b"data");
        hdr.extend_from_slice(&(self.data_bytes as u32).to_le_bytes());
        self.out.seek(SeekFrom::Start(0))?;
        self.out.write_all(&hdr)?;
        self.out.flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    fn u16at(d: &[u8], i: usize) -> u16 {
        u16::from_le_bytes(d[i..i + 2].try_into().unwrap())
    }
    fn u32at(d: &[u8], i: usize) -> u32 {
        u32::from_le_bytes(d[i..i + 4].try_into().unwrap())
    }
    #[test]
    fn preserves_masks_subtypes_and_interleaving() {
        for float in [false, true] {
            for (channels, mask) in [(2, 3), (6, 0x60f), (12, 0x2d63f), (12, 0)] {
                let mut bytes = Cursor::new(Vec::new());
                let mut writer = WavWriter::start_fmt(&mut bytes, float).unwrap();
                let planes: Vec<Vec<f32>> = (0..channels)
                    .map(|c| vec![c as f32 / 16.0, -0.25])
                    .collect();
                writer.write_frame_planar(&planes, 48000, mask).unwrap();
                writer.finish().unwrap();
                let d = bytes.into_inner();
                let start = if channels > 2 { 68 } else { 44 };
                assert_eq!(u32at(&d, 4) as usize + 8, d.len());
                assert_eq!(u16at(&d, 22), channels as u16);
                assert_eq!(u32at(&d, start - 4) as usize, d.len() - start);
                if channels > 2 {
                    assert_eq!(u16at(&d, 20), 0xfffe);
                    assert_eq!(u32at(&d, 40), mask as u32);
                    assert_eq!(u32at(&d, 44), if float { 3 } else { 1 });
                }
                if float {
                    assert_eq!(&d[start + 4..start + 8], &(1.0f32 / 16.0).to_le_bytes());
                } else {
                    assert_eq!(
                        i16::from_le_bytes(d[start + 2..start + 4].try_into().unwrap()),
                        2048
                    );
                }
            }
        }
    }
    #[test]
    fn rejects_riff_and_byte_rate_overflow_before_writing() {
        let mut bytes = Cursor::new(Vec::new());
        let mut writer = WavWriter::start_fmt(&mut bytes, true).unwrap();
        let planes = [vec![0.0; 2], vec![0.0; 2]];
        assert!(writer.write_frame_planar(&planes, u32::MAX, 3).is_err());
        writer.write_frame_planar(&planes, 48000, 3).unwrap();
        writer.data_bytes = u32::MAX as u64 - 36;
        assert!(writer.write_frame_planar(&planes, 48000, 3).is_err());
        assert_eq!(writer.out.get_ref().len(), 60);
    }

    #[test]
    fn rejects_layout_changes_bad_frames_and_empty_output() {
        let mut bytes = Cursor::new(Vec::new());
        let mut writer = WavWriter::start_fmt(&mut bytes, true).unwrap();
        writer
            .write_frame_planar(&[vec![0.0; 2], vec![0.0; 2]], 48000, 3)
            .unwrap();
        for (planes, rate, mask) in [
            (vec![vec![0.0; 2]; 6], 48000, 0x60f),
            (vec![vec![0.0; 2]; 2], 44100, 3),
            (vec![vec![0.0; 2]; 2], 48000, 0),
            (vec![vec![f32::NAN; 2]; 2], 48000, 3),
            (vec![vec![0.0; 2], vec![0.0]], 48000, 3),
        ] {
            assert!(writer.write_frame_planar(&planes, rate, mask).is_err());
        }
        writer.finish().unwrap();
        assert_eq!(bytes.get_ref().len(), 44 + 16);
        assert!(
            WavWriter::start_fmt(Cursor::new(Vec::new()), false)
                .unwrap()
                .finish()
                .is_err()
        );
    }
}
