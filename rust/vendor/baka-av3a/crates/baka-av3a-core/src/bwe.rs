//! Bandwidth extension from copied tiles, optional whitening and transmitted energy.
use crate::{BitReader, Error, FrameHeader, Profile, model::NoiseState};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BweConfig {
    bands: &'static [usize],
    tiles: &'static [usize],
    sources: &'static [usize],
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BweSide {
    pub envelopes: Vec<u8>,
    pub whitening: Vec<u8>,
}

impl BweConfig {
    pub fn start_line(&self) -> usize {
        self.tiles[0]
    }
    pub fn stop_line(&self) -> usize {
        *self.tiles.last().unwrap()
    }
    pub fn band_count(&self) -> usize {
        self.bands.len() - 1
    }
    pub fn tile_count(&self) -> usize {
        self.sources.len()
    }
    pub fn for_header(header: &FrameHeader) -> Result<Option<Self>, Error> {
        let configuration = match header.profile {
            Profile::ChannelBed { configuration } => configuration,
            Profile::Objects { count: 1 } => 0,
            Profile::Objects { count: 2 } => 1,
            Profile::Objects { .. } | Profile::BedObjects { .. } => 255,
            _ => return Err(Error::Unsupported("BWE profile")),
        };
        let index = match configuration {
            0 => match header.bitrate {
                0..=32000 => 0,
                44000 | 56000 => 1,
                64000 | 72000 => 2,
                80000 | 96000 => 3,
                96001.. => return Ok(None),
                _ => return Err(Error::Unsupported("mono BWE bitrate")),
            },
            1 => match header.bitrate {
                0..=48000 => 4,
                48001..=64000 => 5,
                64001..=96000 => 6,
                96001..=128000 => 7,
                _ => return Ok(None),
            },
            2 | 3 | 6..=10 | 255 => {
                let count = match configuration {
                    2 => 6,
                    3 | 7 => 8,
                    6 => 4,
                    8 | 9 => 10,
                    10 => 12,
                    255 => header.channels,
                    _ => unreachable!(),
                };
                if header.channels != count {
                    return Err(Error::Invalid("BWE channel count"));
                }
                let lfe = match header.profile {
                    Profile::Objects { .. } => false,
                    Profile::BedObjects { configuration, .. } => !matches!(configuration, 1 | 6),
                    _ => configuration != 6,
                };
                let coupled = count
                    .checked_sub(u16::from(lfe))
                    .filter(|&v| v > 0)
                    .ok_or(Error::Invalid("BWE channel count"))?;
                let rate = (header.bitrate as f32 * 2.0 / f32::from(coupled)) as u32;
                match rate {
                    0..=56000 => 8,
                    56001..=75000 => 9,
                    75001..=108000 => 10,
                    108001..=128000 => 11,
                    _ => return Ok(None),
                }
            }
            _ => return Err(Error::Unsupported("BWE channel configuration")),
        };
        Ok(Some(Self::table(index)))
    }
    pub(crate) fn table(index: usize) -> Self {
        let (bands, tiles, sources): (&'static [usize], &'static [usize], &'static [usize]) =
            match index {
                0 | 4 | 5 => (
                    &[352, 416, 480, 544, 608, 672, 768],
                    &[352, 480, 608, 768],
                    &[64, 96, 144],
                ),
                1 => (
                    &[448, 496, 544, 608, 672, 736, 832],
                    &[448, 544, 672, 832],
                    &[96, 144, 192],
                ),
                2 | 6 | 10 | 14 => (&[544, 608, 672, 736, 832], &[544, 672, 832], &[144, 192]),
                3 | 7 | 11 | 15 => (&[672, 736, 832], &[672, 832], &[192]),
                12 => (&[352, 416, 480, 544, 736], &[352, 480, 736], &[64, 96]),
                13 => (
                    &[384, 448, 512, 576, 672, 736, 832],
                    &[384, 512, 672, 832],
                    &[96, 144, 192],
                ),
                8 => (
                    &[352, 400, 448, 512, 576, 672, 768],
                    &[352, 448, 576, 768],
                    &[64, 96, 144],
                ),
                9 => (
                    &[400, 448, 512, 576, 672, 768],
                    &[400, 512, 672, 768],
                    &[64, 96, 144],
                ),
                _ => unreachable!(),
            };
        Self {
            bands,
            tiles,
            sources,
        }
    }
    /// Does not mutate either spectrum or random state on failure.
    pub fn apply(
        &self,
        spectrum: &mut [f32; 1024],
        side: &BweSide,
        noise: &mut NoiseState,
    ) -> Result<(), Error> {
        if side.envelopes.len() != self.band_count()
            || side.whitening.len() != self.tile_count()
            || side.envelopes.iter().any(|&v| v > 127)
            || side.whitening.iter().any(|&v| v > 2)
            || spectrum.iter().any(|v| !v.is_finite())
        {
            return Err(Error::Invalid("BWE data"));
        }
        let mut copied = [0.0f32; 1024];
        copied[..self.start_line()].copy_from_slice(&spectrum[..self.start_line()]);
        for (tile, &source) in self.sources.iter().enumerate() {
            let (start, stop) = (self.tiles[tile], self.tiles[tile + 1]);
            copied[start..stop].copy_from_slice(&spectrum[source..source + stop - start]);
        }
        let mut next = *noise;
        let mut whitened = [0.0f32; 1024];
        for (tile, &level) in side.whitening.iter().enumerate() {
            let (start, stop) = (self.tiles[tile], self.tiles[tile + 1]);
            match level {
                0 => whitened[start..stop].copy_from_slice(&copied[start..stop]),
                1 => {
                    for i in start..stop {
                        let mut energy = 0.0f32;
                        for &value in &copied[i - 7..=i + 7] {
                            energy += value * value;
                        }
                        if !energy.is_finite() {
                            return Err(Error::Invalid("BWE whitening energy"));
                        }
                        let average = f64::from(energy / 15.0).sqrt() as f32;
                        whitened[i] = if average == 0.0 {
                            copied[i]
                        } else {
                            copied[i] / average
                        };
                    }
                }
                2 => {
                    let mut sum = 0.0f32;
                    for &value in &copied[start..stop] {
                        sum += value.abs();
                    }
                    if !sum.is_finite() {
                        return Err(Error::Invalid("BWE spectrum magnitude"));
                    }
                    if sum > 0.0 {
                        for value in &mut whitened[start..stop] {
                            *value = next.sample();
                        }
                    }
                }
                _ => unreachable!(),
            }
        }
        let mut output = *spectrum;
        for (band, &index) in side.envelopes.iter().enumerate() {
            let (start, stop) = (self.bands[band], self.bands[band + 1]);
            let mut energy = 0.0f32;
            for &value in &whitened[start..stop] {
                energy += value * value;
            }
            energy /= (stop - start) as f32;
            if !energy.is_finite() {
                return Err(Error::Invalid("BWE envelope energy"));
            }
            let target = 2.0f64.powf(f64::from(f32::from(index) / 4.24966 - 4.0)) as f32;
            let gain = if energy == 0.0 {
                1.0
            } else {
                f64::from(target / energy).sqrt() as f32
            };
            for i in start..stop {
                output[i] = whitened[i] * gain;
            }
        }
        output[self.stop_line()..].fill(0.0);
        if output.iter().any(|v| !v.is_finite()) {
            return Err(Error::Invalid("BWE output"));
        }
        *noise = next;
        *spectrum = output;
        Ok(())
    }
}

impl BweSide {
    pub fn parse(reader: &mut BitReader<'_>, config: &BweConfig) -> Result<Self, Error> {
        let mut next = reader.clone();
        let mut envelopes = Vec::with_capacity(config.band_count());
        for _ in 0..config.band_count() {
            envelopes.push(next.read(7)? as u8);
        }
        let mut whitening = Vec::with_capacity(config.tile_count());
        for _ in 0..config.tile_count() {
            whitening.push(if next.read(1)? == 0 {
                0
            } else {
                1 + next.read(1)? as u8
            });
        }
        *reader = next;
        Ok(Self {
            envelopes,
            whitening,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn header(configuration: u8, bitrate: u32, channels: u16) -> FrameHeader {
        FrameHeader {
            profile: Profile::ChannelBed { configuration },
            neural_type: 0,
            sample_rate: 48000,
            channels,
            bit_depth: 16,
            bitrate,
            bed_bitrate: None,
            crc: 0,
            header_bytes: 7,
            payload_bits: 1,
        }
    }
    #[test]
    fn independent_whitening_and_envelope_vectors() {
        const RECORD: usize = 20 + 1024 * 4;
        let vectors = include_bytes!("../tests/fixtures/bwe_vectors.bin");
        assert_eq!(vectors.len(), 48 * RECORD);
        for (case, record) in vectors.as_chunks::<RECORD>().0.iter().enumerate() {
            let integer =
                |offset| u32::from_le_bytes(record[offset..offset + 4].try_into().unwrap());
            let config = if integer(0) >= 12 {
                crate::hoa::HoaConfig::new(2, integer(4))
                    .unwrap()
                    .bwe_config()
                    .unwrap()
            } else {
                BweConfig::for_header(&header(integer(0) as u8, integer(4), integer(8) as u16))
                    .unwrap()
                    .unwrap()
            };
            let side = BweSide {
                envelopes: (0..config.band_count())
                    .map(|i| ((i * 17 + case / 3 * 5) % 128) as u8)
                    .collect(),
                whitening: vec![integer(12) as u8; config.tile_count()],
            };
            let mut spectrum = std::array::from_fn(|i| ((i % 37) as f32 - 18.0) / 64.0);
            let mut noise = NoiseState::default();
            config.apply(&mut spectrum, &side, &mut noise).unwrap();
            for (i, &value) in spectrum.iter().enumerate() {
                let start = 20 + i * 4;
                let expected = f32::from_le_bytes(record[start..start + 4].try_into().unwrap());
                assert_eq!(value, expected, "case {case} bin {i}");
            }
            assert_eq!(
                noise.sample(),
                f32::from_le_bytes(record[16..20].try_into().unwrap()),
                "noise case {case}"
            );
        }
    }
    #[test]
    fn parsing_is_transactional_and_zero_whitening_preserves_noise() {
        let config = BweConfig::for_header(&header(0, 32000, 1))
            .unwrap()
            .unwrap();
        let bytes = [0u8; 7];
        let mut reader = BitReader::with_bit_len(&bytes, 45).unwrap();
        let side = BweSide::parse(&mut reader, &config).unwrap();
        assert_eq!(reader.position(), 45);
        for bits in 0..45 {
            let mut reader = BitReader::with_bit_len(&bytes, bits).unwrap();
            assert!(BweSide::parse(&mut reader, &config).is_err());
            assert_eq!(reader.position(), 0);
        }
        let mut spectrum = [0.0; 1024];
        let mut noise = NoiseState::default();
        let before = noise;
        let mut side = side;
        side.whitening.fill(2);
        config.apply(&mut spectrum, &side, &mut noise).unwrap();
        assert_eq!(noise, before);
        assert_eq!(spectrum, [0.0; 1024]);
        side.envelopes.push(0);
        assert!(config.apply(&mut spectrum, &side, &mut noise).is_err());
        assert_eq!(noise, before);
    }
}
