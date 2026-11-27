//! Low-rate stereo reconstruction using caller-supplied angle codebooks.
use crate::{BitReader, Error};

const BANDS: [usize; 19] = [
    0, 4, 8, 12, 16, 22, 28, 34, 40, 48, 56, 64, 76, 88, 100, 116, 132, 154, 176,
];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct McrSide {
    /// Even and odd spectral lines, each containing six three-angle vectors.
    pub indices: [[u16; 6]; 2],
    pub short: bool,
}
impl McrSide {
    pub fn parse(reader: &mut BitReader<'_>, short: bool) -> Result<Self, Error> {
        let mut next = reader.clone();
        let mut indices = [[0; 6]; 2];
        for vector in 0..6 {
            for parity in &mut indices {
                parity[vector] = next.read(if short { 8 } else { 9 })? as u16;
            }
        }
        *reader = next;
        Ok(Self { indices, short })
    }
}

#[derive(Clone, Debug)]
pub struct McrCodebooks {
    values: Vec<f32>,
}
impl McrCodebooks {
    /// AV3MCR01 followed by 512x3 long and 256x3 short f32 LE angles.
    /// The exact 9,224-byte asset remains external to the crate.
    pub fn parse(bytes: &[u8]) -> Result<Self, Error> {
        if bytes.len() != 9224 || &bytes[..8] != b"AV3MCR01" {
            return Err(Error::Invalid("MCR asset format"));
        }
        let values: Vec<_> = bytes[8..]
            .as_chunks::<4>()
            .0
            .iter()
            .map(|v| f32::from_le_bytes(*v))
            .collect();
        if values
            .iter()
            .any(|v| !v.is_finite() || v.abs() > std::f32::consts::PI)
        {
            return Err(Error::Invalid("MCR angle"));
        }
        Ok(Self { values })
    }

    pub fn reconstruct(&self, mono: &[f32], side: &McrSide) -> Result<Vec<Vec<f32>>, Error> {
        if mono.len() != 1024 || mono.iter().any(|v| !v.is_finite()) {
            return Err(Error::Invalid("MCR spectrum"));
        }
        let count = if side.short { 256 } else { 512 };
        if side
            .indices
            .iter()
            .flatten()
            .any(|&i| usize::from(i) >= count)
        {
            return Err(Error::Invalid("MCR vector index"));
        }
        let offset = if side.short { 512 * 3 } else { 0 };
        let mut output = vec![mono.to_vec(), mono.to_vec()];
        for band in 0..18 {
            for (parity, indices) in side.indices.iter().enumerate() {
                let index = usize::from(indices[band / 3]);
                let theta = -self.values[offset + index * 3 + band % 3];
                let cosine = f64::from(theta).cos() as f32;
                let sine = f64::from(theta).sin() as f32;
                for bin in BANDS[band]..BANDS[band + 1] {
                    let line = bin * 2 + parity;
                    output[0][line] = cosine * mono[line] + sine * mono[line];
                    output[1][line] = -sine * mono[line] + cosine * mono[line];
                }
            }
        }
        if output.iter().flatten().any(|v| !v.is_finite()) {
            return Err(Error::Invalid("MCR output"));
        }
        Ok(output)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn external_asset_and_rotation() {
        let mut bytes = b"AV3MCR01".to_vec();
        for _ in 0..768 {
            for angle in [
                0.0f32,
                std::f32::consts::FRAC_PI_2,
                -std::f32::consts::FRAC_PI_2,
            ] {
                bytes.extend_from_slice(&angle.to_le_bytes());
            }
        }
        let books = McrCodebooks::parse(&bytes).unwrap();
        for short in [false, true] {
            let mut side = McrSide {
                indices: [[0; 6]; 2],
                short,
            };
            let output = books.reconstruct(&[1.0; 1024], &side).unwrap();
            assert_eq!(&output[0][..8], &[1.0; 8]);
            assert!((output[0][8] + 1.0).abs() < 1e-6);
            assert!((output[1][8] - 1.0).abs() < 1e-6);
            assert_eq!(&output[0][352..], &[1.0; 672]);
            side.indices[0][0] = 512;
            assert!(books.reconstruct(&[1.0; 1024], &side).is_err());
        }
        for len in 0..bytes.len() {
            assert!(McrCodebooks::parse(&bytes[..len]).is_err());
        }
        bytes[8..12].copy_from_slice(&f32::NAN.to_le_bytes());
        assert!(McrCodebooks::parse(&bytes).is_err());
    }

    #[test]
    fn side_truncation_is_transactional() {
        for short in [false, true] {
            let length = if short { 96 } else { 108 };
            for bits in 0..length {
                let data = [0xff; 14];
                let mut reader = BitReader::with_bit_len(&data, bits).unwrap();
                assert!(McrSide::parse(&mut reader, short).is_err());
                assert_eq!(reader.position(), 0);
            }
            let mut reader = BitReader::new(&[0xff; 14]);
            let side = McrSide::parse(&mut reader, short).unwrap();
            assert_eq!(side.indices, [[if short { 255 } else { 511 }; 6]; 2]);
            assert_eq!(reader.position(), length);
        }
    }
}
