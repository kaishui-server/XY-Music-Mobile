//! Channel-bed side information and entropy segment boundaries.
mod allocation;
mod tns;

use crate::{
    BitReader, Error, FrameHeader, Profile,
    bwe::{BweConfig, BweSide},
    mcr::McrSide,
    metadata::FrameMetadata,
    quantization::{Grouping, QuantizedChannel},
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CoreSide {
    pub transform: u8,
    pub lsf_indices: Vec<u8>,
    /// Quantized signed reflection indices, in filter order; empty means disabled.
    pub tns: [Vec<i8>; 2],
}

impl CoreSide {
    /// The caller supplies the LSF configuration and must exclude BWE fields.
    /// Leaves the reader unchanged on failure.
    pub fn parse_without_bwe(
        reader: &mut BitReader<'_>,
        low_rate_lsf: bool,
    ) -> Result<Self, Error> {
        let mut next = reader.clone();
        let transform = next.read(2)? as u8;
        let widths: &[u8] = if low_rate_lsf {
            &[8, 8, 7, 7, 6]
        } else {
            &[8, 8, 7, 7, 6, 5, 5]
        };
        let lsf_indices = widths
            .iter()
            .map(|&w| next.read(w).map(|v| v as u8))
            .collect::<Result<_, _>>()?;
        let mut filters = [Vec::new(), Vec::new()];
        for filter in &mut filters {
            if next.read(1)? != 0 {
                let order = next.read(3)? as usize + 1;
                for coefficient in 0..order {
                    filter.push(tns::read_index(&mut next, coefficient)?);
                }
            }
        }
        *reader = next;
        Ok(Self {
            transform,
            lsf_indices,
            tns: filters,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChannelPair {
    /// MC coupling order: the LFE channel follows the other bed channels.
    pub channels: [usize; 2],
    pub energy_indices: [u8; 2],
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct McSide {
    /// Output channel order, including the LFE channel at index 3 if present.
    pub silent: Vec<bool>,
    pub pairs: Vec<ChannelPair>,
    /// Packed ratios for active non-LFE channels in output order.
    pub ratios: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BedMode {
    Mono,
    Stereo { mid_side: Option<u8>, ratio: u8 },
    Multi(McSide),
    Mcr(McrSide),
    Mixed { side: McSide, bed_channels: usize },
}

impl McSide {
    fn parse(reader: &mut BitReader<'_>, channels: usize, lfe: bool) -> Result<Self, Error> {
        let mut silent = vec![false; channels];
        if reader.read(1)? != 0 {
            for (i, flag) in silent.iter_mut().enumerate() {
                if !(lfe && i == 3) {
                    *flag = reader.read(1)? != 0;
                }
            }
        }
        let count = reader.read(4)?;
        let pair_count = channels * (channels - 1) / 2;
        let width = (usize::BITS - (pair_count - 1).leading_zeros()) as u8;
        let mut pairs = Vec::new();
        for _ in 0..count {
            let mut index = reader.read(width)? as usize;
            if index >= pair_count {
                return Err(Error::Invalid("channel pair index"));
            }
            let mut first = 0;
            while index >= channels - first - 1 {
                index -= channels - first - 1;
                first += 1;
            }
            let energy_indices = [reader.read(5)? as u8, reader.read(5)? as u8];
            if energy_indices.iter().any(|&v| v >= 30) {
                return Err(Error::Invalid("channel energy index"));
            }
            pairs.push(ChannelPair {
                channels: [first, first + index + 1],
                energy_indices,
            });
        }
        let mut ratios = Vec::new();
        for (i, &flag) in silent.iter().enumerate() {
            if !flag && !(lfe && i == 3) {
                ratios.push(reader.read(6)? as u8);
            }
        }
        Ok(Self {
            silent,
            pairs,
            ratios,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChannelBedFrame {
    pub header: FrameHeader,
    pub metadata: FrameMetadata,
    pub cores: Vec<CoreSide>,
    /// Quantized channels only; MCR has one group and one entropy segment.
    pub groups: Vec<Grouping>,
    pub mode: BedMode,
    pub bwe: Option<BweConfig>,
    pub bwe_side: Vec<BweSide>,
    pub channel_bytes: Vec<usize>,
    pub quantized: Vec<QuantizedChannel>,
    /// Position relative to the payload before the first quantizer side field.
    pub side_bits: usize,
    /// Unused bits within the declared payload, excluding final byte padding.
    pub unused_bits: usize,
}

impl ChannelBedFrame {
    pub fn mc_mode(&self) -> Option<&McSide> {
        match &self.mode {
            BedMode::Multi(mode) | BedMode::Mixed { side: mode, .. } => Some(mode),
            _ => None,
        }
    }
    pub fn has_lfe(&self) -> bool {
        matches!(
            self.header.profile,
            Profile::ChannelBed {
                configuration: 2 | 3 | 7..=10
            } | Profile::BedObjects {
                configuration: 2 | 3 | 7..=10,
                ..
            }
        )
    }
    /// Parses one exact packet. HOA uses its own payload parser.
    /// This does not reconstruct PCM or check CRC.
    pub fn parse(packet: &[u8]) -> Result<Self, Error> {
        let header = FrameHeader::validate_packet(packet)?;
        let channels = usize::from(header.channels);
        if !(1..=16).contains(&channels) {
            return Err(Error::Unsupported("payload channel count"));
        }
        let bed_count = |configuration| -> Result<usize, Error> {
            match configuration {
                0 => Ok(1),
                1 => Ok(2),
                2 => Ok(6),
                3 | 7 => Ok(8),
                6 => Ok(4),
                8 | 9 => Ok(10),
                10 => Ok(12),
                _ => Err(Error::Unsupported("channel-bed configuration")),
            }
        };
        let (configuration, expected, mixed_bed) = match header.profile {
            Profile::ChannelBed { configuration } => {
                (configuration, bed_count(configuration)?, None)
            }
            Profile::Objects { count } => (
                match count {
                    1 => 0,
                    2 => 1,
                    _ => 255,
                },
                usize::from(count),
                if count >= 3 { Some(0) } else { None },
            ),
            Profile::BedObjects {
                configuration,
                objects,
            } => {
                if configuration == 0 {
                    return Err(Error::Unsupported("mono bed with objects"));
                }
                let bed = bed_count(configuration)?;
                (255, bed + usize::from(objects), Some(bed))
            }
            _ => return Err(Error::Unsupported("channel-bed payload profile")),
        };
        if channels != expected {
            return Err(Error::Invalid("channel count"));
        }
        let lfe = match header.profile {
            Profile::ChannelBed { configuration } | Profile::BedObjects { configuration, .. } => {
                matches!(configuration, 2 | 3 | 7..=10)
            }
            _ => false,
        };
        let coupled = channels - usize::from(lfe);
        let mcr = configuration == 1 && header.bitrate <= 32000;
        let bwe = BweConfig::for_header(&header)?;
        let low_rate_lsf = header.bitrate as f32 / coupled as f32 <= 32000.0;
        let mut reader =
            BitReader::with_bit_len(&packet[header.header_bytes..], header.payload_bits)?;
        let metadata = FrameMetadata::parse(&mut reader, &header)?;
        let mut cores = Vec::with_capacity(channels);
        let mut groups = Vec::with_capacity(channels);
        let mut bwe_side = Vec::new();
        for _ in 0..channels {
            cores.push(CoreSide::parse_without_bwe(&mut reader, low_rate_lsf)?);
            if let Some(config) = &bwe {
                bwe_side.push(BweSide::parse(&mut reader, config)?);
            }
        }
        for core in cores.iter().take(if mcr { 1 } else { channels }) {
            groups.push(Grouping::parse(&mut reader, core.transform)?);
        }
        let mode = match configuration {
            0 => BedMode::Mono,
            1 if mcr => BedMode::Mcr(McrSide::parse(&mut reader, cores[0].transform == 1)?),
            1 => {
                let mid_side = if reader.read(1)? != 0 {
                    let index = reader.read(4)? as u8;
                    if index == 0 {
                        return Err(Error::Invalid("stereo energy index"));
                    }
                    Some(index)
                } else {
                    None
                };
                let ratio = reader.read(3)? as u8;
                if ratio == 0 {
                    return Err(Error::Invalid("stereo split ratio"));
                }
                BedMode::Stereo { mid_side, ratio }
            }
            _ => {
                let side = McSide::parse(&mut reader, channels, lfe)?;
                if let Some(bed_channels) = mixed_bed {
                    BedMode::Mixed { side, bed_channels }
                } else {
                    BedMode::Multi(side)
                }
            }
        };
        let side_bits = reader.position();
        let quantizer_bits: usize = groups.iter().map(|g| 16 + 3 * usize::from(g.count)).sum();
        let available = reader
            .remaining()
            .checked_sub(quantizer_bits)
            .ok_or(Error::Truncated)?;
        let lfe_bytes = if lfe {
            let bed_coupled = mixed_bed.unwrap_or(channels) - 1;
            match header.bed_bitrate.unwrap_or(header.bitrate) * 2 / bed_coupled as u32 {
                0..64000 => 10,
                64000..96000 => 15,
                _ => 20,
            }
        } else {
            0
        };
        let bytes = available / 8;
        let channel_bytes = match &mode {
            BedMode::Mono | BedMode::Mcr(_) => vec![bytes],
            BedMode::Stereo { ratio, .. } => {
                let left = usize::from(*ratio) * (bytes / 8);
                vec![left, bytes - left]
            }
            BedMode::Multi(mode) | BedMode::Mixed { side: mode, .. } => {
                allocation::allocate(bytes, mode, lfe_bytes)?
            }
        };
        let mut quantized = Vec::with_capacity(channels);
        for (group, &bytes) in groups.iter().zip(&channel_bytes) {
            quantized.push(QuantizedChannel::parse(
                &mut reader,
                header.neural_type,
                group.count,
                bytes,
            )?);
        }
        let unused_bits = reader.remaining();
        if unused_bits >= 8 {
            return Err(Error::Invalid("entropy allocation total"));
        }
        Ok(Self {
            header,
            metadata,
            cores,
            groups,
            mode,
            bwe,
            bwe_side,
            channel_bytes,
            quantized,
            side_bits,
            unused_bits,
        })
    }
}
