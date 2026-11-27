use crate::{BitReader, Error};

const RATES: &[u32] = &[
    192000, 96000, 48000, 44100, 32000, 24000, 22050, 16000, 8000,
];
const CHANNELS: &[u16] = &[1, 2, 6, 8, 12, 24, 4, 8, 10, 10, 12, 4, 9, 16];
const BITRATES: &[&[u32]] = &[
    &[
        16000, 32000, 44000, 56000, 64000, 72000, 80000, 96000, 128000, 144000, 164000, 192000,
    ],
    &[
        24000, 32000, 48000, 64000, 80000, 96000, 128000, 144000, 192000, 256000, 320000,
    ],
    &[
        192000, 256000, 320000, 384000, 448000, 512000, 640000, 720000, 144000, 96000, 128000,
        160000,
    ],
    &[
        192000, 480000, 256000, 384000, 576000, 640000, 128000, 160000,
    ],
    &[],
    &[],
    &[48000, 96000, 128000, 192000, 256000],
    &[152000, 320000, 480000, 576000],
    &[176000, 384000, 576000, 704000, 256000, 448000],
    &[216000, 480000, 576000, 384000, 768000],
    &[240000, 608000, 384000, 512000, 832000],
    &[48000, 96000, 128000, 192000, 256000],
    &[192000, 256000, 320000, 384000, 480000, 512000, 640000],
    &[256000, 320000, 384000, 512000, 640000, 896000],
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Profile {
    ChannelBed { configuration: u8 },
    Objects { count: u16 },
    BedObjects { configuration: u8, objects: u16 },
    Hoa { order: u8 },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FrameHeader {
    pub profile: Profile,
    pub neural_type: u8,
    pub sample_rate: u32,
    pub channels: u16,
    pub bit_depth: u8,
    pub bitrate: u32,
    /// Separate bed budget for bed+object streams; absent for other profiles.
    pub bed_bitrate: Option<u32>,
    /// Stored checksum; `validate_crc` checks the complete payload bytes.
    pub crc: u16,
    pub header_bytes: usize,
    pub payload_bits: usize,
}

fn bitrate(config: usize, index: u32) -> Result<u32, Error> {
    BITRATES
        .get(config)
        .and_then(|t| t.get(index as usize))
        .copied()
        .ok_or(Error::Unsupported("bitrate configuration"))
}

fn bed(config: u32) -> Result<u16, Error> {
    if config > 10 || BITRATES[config as usize].is_empty() {
        return Err(Error::Unsupported("channel configuration"));
    }
    Ok(CHANNELS[config as usize])
}

impl FrameHeader {
    pub const SAMPLES: u32 = 1024;

    pub fn parse(bytes: &[u8]) -> Result<Self, Error> {
        let mut r = BitReader::new(bytes);
        if r.read(12)? != 0xfff || r.read(4)? != 2 {
            return Err(Error::Invalid("AV3A sync/codec"));
        }
        if r.read(1)? != 0 {
            return Err(Error::Unsupported("ancillary data"));
        }
        let neural_type = r.read(3)? as u8;
        if neural_type > 1 {
            return Err(Error::Unsupported("neural type"));
        }
        let coding = r.read(3)?;
        let sample_rate = *RATES
            .get(r.read(4)? as usize)
            .ok_or(Error::Invalid("sample rate"))?;
        let crc_high = r.read(8)?;
        let mut bed_bitrate = None;
        let (profile, channels, config, mixed_bitrate) = match coding {
            0 => {
                let c = r.read(7)?;
                (
                    Profile::ChannelBed {
                        configuration: c as u8,
                    },
                    bed(c)?,
                    c as usize,
                    None,
                )
            }
            1 => match r.read(2)? {
                0 => {
                    let count = r.read(7)? as u16 + 1;
                    let total = bitrate(0, r.read(4)?)? * u32::from(count);
                    (Profile::Objects { count }, count, 0, Some(total))
                }
                1 => {
                    let c = r.read(7)?;
                    let channels = bed(c)?;
                    let bed_rate = bitrate(c as usize, r.read(4)?)?;
                    bed_bitrate = Some(bed_rate);
                    let objects = r.read(7)? as u16 + 1;
                    let total = bed_rate + bitrate(0, r.read(4)?)? * u32::from(objects);
                    (
                        Profile::BedObjects {
                            configuration: c as u8,
                            objects,
                        },
                        channels + objects,
                        c as usize,
                        Some(total),
                    )
                }
                _ => return Err(Error::Unsupported("sound bed type")),
            },
            2 => {
                let order = r.read(4)? as u8 + 1;
                if order > 3 {
                    return Err(Error::Unsupported("HOA order"));
                }
                let c = usize::from(order) + 10;
                (Profile::Hoa { order }, CHANNELS[c], c, None)
            }
            _ => return Err(Error::Unsupported("coding profile")),
        };
        let bit_depth = match r.read(2)? {
            0 => 8,
            1 => 16,
            2 => 24,
            _ => return Err(Error::Invalid("resolution")),
        };
        let bitrate = match mixed_bitrate {
            Some(value) => value,
            None => bitrate(config, r.read(4)?)?,
        };
        let crc = ((crc_high << 8) | r.read(8)?) as u16;
        let header_bytes = r.position().div_ceil(8);
        // Frame bit budgets use single-precision arithmetic.
        let total_bits = ((bitrate as f32 / sample_rate as f32) * Self::SAMPLES as f32) as usize;
        let payload_bits = total_bits
            .checked_sub(header_bytes * 8)
            .filter(|n| *n > 0)
            .ok_or(Error::Invalid("frame bit budget"))?;
        Ok(Self {
            profile,
            neural_type,
            sample_rate,
            channels,
            bit_depth,
            bitrate,
            bed_bitrate,
            crc,
            header_bytes,
            payload_bits,
        })
    }

    pub fn frame_bytes(&self) -> usize {
        self.header_bytes + self.payload_bits.div_ceil(8)
    }

    pub fn validate_packet(bytes: &[u8]) -> Result<Self, Error> {
        let header = Self::parse(bytes)?;
        if bytes.len() != header.frame_bytes() {
            return Err(Error::Invalid("packet length"));
        }
        Ok(header)
    }

    pub fn validate_crc(bytes: &[u8]) -> Result<Self, Error> {
        let header = Self::validate_packet(bytes)?;
        let actual = payload_crc(&bytes[header.header_bytes..]);
        if actual != header.crc {
            return Err(Error::Invalid("frame CRC"));
        }
        Ok(header)
    }
}

/// Polynomial 0x1021, initial remainder 0xffff, input shifted into the register.
pub fn payload_crc(bytes: &[u8]) -> u16 {
    let mut remainder = 0xffffu16;
    for &byte in bytes {
        for bit in (0..8).rev() {
            let high = remainder & 0x8000 != 0;
            remainder = (remainder << 1) | u16::from((byte >> bit) & 1);
            if high {
                remainder ^= 0x1021;
            }
        }
    }
    remainder
}

#[cfg(test)]
mod tests {
    use super::*;
    fn pack(fields: &[(u32, usize)]) -> Vec<u8> {
        let mut bits = Vec::new();
        for &(v, n) in fields {
            for i in (0..n).rev() {
                bits.push(((v >> i) & 1) as u8);
            }
        }
        let mut bytes = vec![0; bits.len().div_ceil(8)];
        for (i, b) in bits.into_iter().enumerate() {
            bytes[i / 8] |= b << (7 - i % 8);
        }
        bytes
    }
    #[test]
    fn channel_bed_and_every_prefix() {
        let bytes = pack(&[
            (0xfff, 12),
            (2, 4),
            (0, 1),
            (0, 3),
            (0, 3),
            (3, 4),
            (0xab, 8),
            (10, 7),
            (1, 2),
            (4, 4),
            (0xcd, 8),
        ]);
        let h = FrameHeader::parse(&bytes).unwrap();
        assert_eq!(
            (
                h.channels,
                h.sample_rate,
                h.bitrate,
                h.crc,
                h.header_bytes,
                h.frame_bytes()
            ),
            (12, 44100, 832000, 0xabcd, 7, 2415)
        );
        for n in 0..bytes.len() {
            assert_eq!(FrameHeader::parse(&bytes[..n]), Err(Error::Truncated));
        }
        let mut packet = bytes;
        packet.resize(h.frame_bytes(), 0);
        assert_eq!(FrameHeader::validate_packet(&packet), Ok(h));
        packet.pop();
        assert!(FrameHeader::validate_packet(&packet).is_err());
    }
    #[test]
    fn objects_and_hoa() {
        let obj = pack(&[
            (0xfff, 12),
            (2, 4),
            (0, 1),
            (1, 3),
            (1, 3),
            (2, 4),
            (0, 8),
            (0, 2),
            (2, 7),
            (4, 4),
            (2, 2),
            (0, 8),
        ]);
        let h = FrameHeader::parse(&obj).unwrap();
        assert_eq!((h.channels, h.bitrate, h.header_bytes), (3, 192000, 8));
        let hoa = pack(&[
            (0xfff, 12),
            (2, 4),
            (0, 1),
            (0, 3),
            (2, 3),
            (2, 4),
            (0, 8),
            (2, 4),
            (1, 2),
            (0, 4),
            (0, 8),
        ]);
        let h = FrameHeader::parse(&hoa).unwrap();
        assert_eq!((h.channels, h.bitrate, h.header_bytes), (16, 256000, 7));
    }
    #[test]
    fn mixed_bed_budget_is_part_of_configuration() {
        let mixed = |bed_index, object_index| {
            pack(&[
                (0xfff, 12),
                (2, 4),
                (0, 1),
                (0, 3),
                (1, 3),
                (2, 4),
                (0, 8),
                (1, 2),
                (2, 7),
                (bed_index, 4),
                (1, 7),
                (object_index, 4),
                (1, 2),
                (0, 8),
            ])
        };
        let first = FrameHeader::parse(&mixed(0, 8)).unwrap();
        let second = FrameHeader::parse(&mixed(2, 4)).unwrap();
        assert_eq!(
            first.profile,
            Profile::BedObjects {
                configuration: 2,
                objects: 2
            }
        );
        assert_eq!(
            (first.channels, first.bitrate, first.header_bytes),
            (8, 448000, 9)
        );
        assert_eq!((second.channels, second.bitrate), (8, 448000));
        assert_eq!(first.bed_bitrate, Some(192000));
        assert_eq!(second.bed_bitrate, Some(320000));
        assert_ne!(first, second);
    }

    #[test]
    fn arbitrary_headers_never_panic() {
        let mut seed = 1u32;
        for _ in 0..10000 {
            let mut bytes = [0; 12];
            for b in &mut bytes {
                seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
                *b = (seed >> 24) as u8;
            }
            let _ = FrameHeader::parse(&bytes);
            bytes[0] = 0xff;
            bytes[1] = 0xf2;
            let _ = FrameHeader::parse(&bytes);
        }
    }
}
