//! HOA transport configuration, side information and entropy segment boundaries.
//! Parsing does not reconstruct the output sound field or PCM.
use crate::{
    BitReader, Error, FrameHeader, Profile,
    bwe::{BweConfig, BweSide},
    metadata::FrameMetadata,
    quantization::{Grouping, QuantizedChannel},
    side::CoreSide,
};
mod reconstruction;
pub use reconstruction::HoaBasis;
pub(crate) use reconstruction::HoaSynthesis;

pub const SUBBANDS: [usize; 22] = [
    0, 8, 24, 40, 56, 72, 88, 104, 128, 160, 192, 224, 256, 288, 336, 384, 432, 480, 544, 608, 672,
    768,
];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HoaGroup {
    pub channels: usize,
    pub code_lines: usize,
    pub bwe: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HoaConfig {
    order: u8,
    bitrate: u32,
    spatial: bool,
    groups: Vec<HoaGroup>,
}
impl HoaConfig {
    pub fn new(order: u8, bitrate: u32) -> Result<Self, Error> {
        let (spatial, counts, lines, bwe): (bool, &[usize], &[usize], &[bool]) =
            match (order, bitrate) {
                (1, 48000 | 96000 | 128000 | 192000 | 256000) => (false, &[4], &[1024], &[true]),
                (2, 192000) => (false, &[9], &[352], &[true]),
                (2, 256000) => (false, &[9], &[384], &[true]),
                (2, 320000) => (false, &[9], &[544], &[true]),
                (2, 384000 | 480000) => (false, &[9], &[672], &[true]),
                (2, 512000) => (false, &[9], &[768], &[false]),
                (2, 640000) => (false, &[9], &[800], &[false]),
                (3, 256000) => (true, &[2, 6], &[732, 384], &[false, true]),
                (3, 320000) => (true, &[2, 7], &[732, 384], &[false, true]),
                (3, 384000) => (true, &[2, 9], &[768, 384], &[false, true]),
                (3, 512000) => (true, &[2, 10], &[768, 544], &[false, true]),
                (3, 640000) => (true, &[2, 12], &[768, 672], &[false, true]),
                (3, 896000) => (false, &[16], &[672], &[true]),
                _ => return Err(Error::Unsupported("HOA configuration")),
            };
        let groups = counts
            .iter()
            .zip(lines)
            .zip(bwe)
            .map(|((&channels, &code_lines), &bwe)| HoaGroup {
                channels,
                code_lines,
                bwe,
            })
            .collect();
        Ok(Self {
            order,
            bitrate,
            spatial,
            groups,
        })
    }
    pub fn order(&self) -> u8 {
        self.order
    }
    pub fn bitrate(&self) -> u32 {
        self.bitrate
    }
    pub fn spatial(&self) -> bool {
        self.spatial
    }
    pub fn output_channels(&self) -> usize {
        (usize::from(self.order) + 1).pow(2)
    }
    pub fn transport_channels(&self) -> usize {
        self.groups.iter().map(|g| g.channels).sum()
    }
    pub fn groups(&self) -> &[HoaGroup] {
        &self.groups
    }
    pub fn bwe_config(&self) -> Result<BweConfig, Error> {
        let index = match (self.order, self.bitrate) {
            (1, 0..=128000) | (2, 256000) | (3, 256000..=384000) => 13,
            (2, 192000) => 12,
            (1, 192000) | (2, 320000) | (3, 512000) => 14,
            (1, 256000) | (2, 384000..=480000) | (3, 640000..) => 15,
            _ => return Err(Error::Unsupported("HOA BWE configuration")),
        };
        Ok(BweConfig::table(index))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HoaPair {
    /// Local group indices, enumerated by upper channel then lower channel.
    pub channels: [usize; 2],
    pub mask: [bool; 21],
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HoaGroupSide {
    pub pairs: Vec<HoaPair>,
    /// 30 means unity gain, otherwise a quantized energy index.
    pub energy: Vec<u8>,
    pub ratio: u8,
    pub channel_ratios: Vec<u8>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HoaSide {
    pub scene: u8,
    pub spatial: bool,
    pub basis_indices: Vec<u16>,
    pub groups: Vec<HoaGroupSide>,
}
impl HoaSide {
    /// Transactional: no cursor movement on malformed or truncated data.
    pub fn parse(reader: &mut BitReader<'_>, config: &HoaConfig) -> Result<Self, Error> {
        let mut next = reader.clone();
        let scene = next.read(4)? as u8;
        let spatial = next.read(1)? != 0;
        // Transport layout is fixed by the header configuration. A mismatch
        // would interpret foreground/residual spectra with incompatible shapes.
        if spatial != config.spatial {
            return Err(Error::Invalid("HOA spatial layout"));
        }
        let mut basis_indices = Vec::new();
        if spatial {
            let count = next.read(4)? as usize;
            if count != config.groups[0].channels {
                return Err(Error::Invalid("HOA foreground count"));
            }
            for _ in 0..count {
                let index = next.read(12)? as u16;
                if index >= 1343 {
                    return Err(Error::Invalid("HOA basis index"));
                }
                basis_indices.push(index);
            }
        }
        let mut groups = Vec::new();
        for group in &config.groups {
            let pair_count = group.channels * (group.channels - 1) / 2;
            let width = (usize::BITS - (pair_count - 1).leading_zeros()).max(1) as u8;
            let count = next.read(4)? as usize;
            let mut pairs = Vec::new();
            for _ in 0..count {
                let mut index = next.read(width)? as usize;
                if index >= pair_count {
                    return Err(Error::Invalid("HOA pair index"));
                }
                let mut high = 1;
                while index >= high {
                    index -= high;
                    high += 1;
                }
                let selective = next.read(1)? != 0;
                let mut mask = [true; 21];
                if selective {
                    for value in &mut mask {
                        *value = next.read(1)? != 0;
                    }
                }
                pairs.push(HoaPair {
                    channels: [index, high],
                    mask,
                });
            }
            let mut energy = vec![30; group.channels];
            if count != 0 {
                for index in &mut energy {
                    *index = next.read(5)? as u8;
                    if *index > 30 {
                        return Err(Error::Invalid("HOA energy index"));
                    }
                }
            }
            let ratio = next.read(4)? as u8;
            let channel_ratios = (0..group.channels)
                .map(|_| next.read(4).map(|v| v as u8))
                .collect::<Result<Vec<_>, _>>()?;
            if channel_ratios.iter().all(|&v| v == 0) {
                return Err(Error::Invalid("HOA channel ratios"));
            }
            groups.push(HoaGroupSide {
                pairs,
                energy,
                ratio,
                channel_ratios,
            });
        }
        *reader = next;
        Ok(Self {
            scene,
            spatial,
            basis_indices,
            groups,
        })
    }

    pub fn allocate(&self, config: &HoaConfig, bits: usize) -> Result<Vec<usize>, Error> {
        if self.groups.len() != config.groups.len() || bits > 32767 {
            return Err(Error::Invalid("HOA allocation shape"));
        }
        let total = bits / 8;
        let mut remaining = total;
        let mut result = Vec::new();
        for (index, (group, side)) in config.groups.iter().zip(&self.groups).enumerate() {
            if side.channel_ratios.len() != group.channels
                || side.ratio > 15
                || side.channel_ratios.iter().any(|&v| v > 15)
            {
                return Err(Error::Invalid("HOA allocation ratios"));
            }
            let budget = if index + 1 == config.groups.len() {
                remaining
            } else {
                total * usize::from(side.ratio) / 16
            };
            remaining = remaining
                .checked_sub(budget)
                .ok_or(Error::Invalid("HOA group budget"))?;
            let sum: usize = side.channel_ratios.iter().map(|&v| usize::from(v)).sum();
            if sum == 0 {
                return Err(Error::Invalid("HOA channel ratios"));
            }
            let (unit, residue) = (budget / sum, budget % sum);
            for (channel, &ratio) in side.channel_ratios.iter().enumerate() {
                let extra = if residue >= group.channels {
                    residue / group.channels
                        + if channel == 0 {
                            residue % group.channels
                        } else {
                            0
                        }
                } else if channel == 0 {
                    residue
                } else {
                    0
                };
                result.push(unit * usize::from(ratio) + extra);
            }
        }
        if result.iter().sum::<usize>() != total {
            return Err(Error::Invalid("HOA allocation total"));
        }
        Ok(result)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HoaFrame {
    pub header: FrameHeader,
    pub metadata: FrameMetadata,
    pub config: HoaConfig,
    pub cores: Vec<CoreSide>,
    pub bwe_side: Vec<Option<BweSide>>,
    pub groups: Vec<Grouping>,
    pub side: HoaSide,
    pub channel_bytes: Vec<usize>,
    pub quantized: Vec<QuantizedChannel>,
    pub side_bits: usize,
    pub unused_bits: usize,
}
impl HoaFrame {
    /// Parses one exact packet; CRC and PCM reconstruction are separate steps.
    pub fn parse(packet: &[u8]) -> Result<Self, Error> {
        let header = FrameHeader::validate_packet(packet)?;
        let Profile::Hoa { order } = header.profile else {
            return Err(Error::Unsupported("HOA payload profile"));
        };
        let config = HoaConfig::new(order, header.bitrate)?;
        if usize::from(header.channels) != config.output_channels() {
            return Err(Error::Invalid("HOA output channels"));
        }
        let mut reader =
            BitReader::with_bit_len(&packet[header.header_bytes..], header.payload_bits)?;
        let metadata = FrameMetadata::parse(&mut reader, &header)?;
        let low_lsf = header.bitrate as f32 / config.transport_channels() as f32 <= 32000.0;
        let bwe = if config.groups.iter().any(|g| g.bwe) {
            Some(config.bwe_config()?)
        } else {
            None
        };
        let mut cores = Vec::new();
        let mut bwe_side = Vec::new();
        for group in &config.groups {
            for _ in 0..group.channels {
                cores.push(CoreSide::parse_without_bwe(&mut reader, low_lsf)?);
                bwe_side.push(if group.bwe {
                    Some(BweSide::parse(&mut reader, bwe.as_ref().unwrap())?)
                } else {
                    None
                });
            }
        }
        let groups = cores
            .iter()
            .map(|core| Grouping::parse(&mut reader, core.transform))
            .collect::<Result<Vec<_>, _>>()?;
        let side = HoaSide::parse(&mut reader, &config)?;
        let side_bits = reader.position();
        let quantizer_bits: usize = groups.iter().map(|g| 16 + 3 * usize::from(g.count)).sum();
        let available = reader
            .remaining()
            .checked_sub(quantizer_bits)
            .ok_or(Error::Truncated)?;
        let channel_bytes = side.allocate(&config, available)?;
        let quantized = groups
            .iter()
            .zip(&channel_bytes)
            .map(|(g, &bytes)| {
                QuantizedChannel::parse(&mut reader, header.neural_type, g.count, bytes)
            })
            .collect::<Result<Vec<_>, _>>()?;
        let unused_bits = reader.remaining();
        if unused_bits >= 8 {
            return Err(Error::Invalid("HOA entropy allocation total"));
        }
        Ok(Self {
            header,
            metadata,
            config,
            cores,
            bwe_side,
            groups,
            side,
            channel_bytes,
            quantized,
            side_bits,
            unused_bits,
        })
    }
}
