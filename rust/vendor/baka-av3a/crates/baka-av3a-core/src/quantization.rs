//! Neural quantization side fields and separately packed entropy segments.
use crate::{BitReader, Error};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Grouping {
    pub count: u8,
    pub indicators: [bool; 8],
}
impl Grouping {
    /// Transform identifiers: 0 long, 1 short, 2 long-to-short, 3 short-to-long.
    pub fn parse(reader: &mut BitReader<'_>, transform: u8) -> Result<Self, Error> {
        if transform > 3 {
            return Err(Error::Invalid("transform type"));
        }
        let mut next = reader.clone();
        let mut result = Self {
            count: 1,
            indicators: [false; 8],
        };
        if transform == 1 {
            result.count = next.read(1)? as u8 + 1;
            if result.count == 2 {
                for value in &mut result.indicators {
                    *value = next.read(1)? != 0;
                }
            }
        }
        *reader = next;
        Ok(result)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QuantizedChannel {
    pub amplified: bool,
    pub scale_index: u8,
    pub noise_indices: Vec<u8>,
    pub context: Vec<u8>,
    pub base: Vec<u8>,
}
impl QuantizedChannel {
    /// `channel_bytes` is the entropy byte allocation, excluding side fields.
    /// The caller must first parse core/mode side information and allocate bytes.
    /// On any error, the bit reader is left unchanged.
    pub fn parse(
        reader: &mut BitReader<'_>,
        neural_type: u8,
        groups: u8,
        channel_bytes: usize,
    ) -> Result<Self, Error> {
        if neural_type > 1 || !(1..=2).contains(&groups) {
            return Err(Error::Invalid("quantizer configuration"));
        }
        if channel_bytes > 32767 {
            return Err(Error::Unsupported("channel byte allocation"));
        }
        let mut next = reader.clone();
        let (amplified, scale_index) = if neural_type == 0 {
            (next.read(1)? != 0, next.read(7)? as u8)
        } else {
            (false, next.read(8)? as u8)
        };
        let mut noise_indices = Vec::with_capacity(usize::from(groups));
        for _ in 0..groups {
            noise_indices.push(next.read(3)? as u8);
        }
        let context_bytes = next.read(8)? as usize;
        let base_bytes = channel_bytes
            .checked_sub(context_bytes)
            .ok_or(Error::Invalid("context byte allocation"))?;
        if channel_bytes > next.remaining() / 8 {
            return Err(Error::Truncated);
        }
        let context = next.read_bytes(context_bytes)?;
        let base = next.read_bytes(base_bytes)?;
        *reader = next;
        Ok(Self {
            amplified,
            scale_index,
            noise_indices,
            context,
            base,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn packed(fields: &[(u32, u8)]) -> (Vec<u8>, usize) {
        let n: usize = fields.iter().map(|(_, w)| usize::from(*w)).sum();
        let mut bytes = vec![0; n.div_ceil(8)];
        let mut pos = 0;
        for &(v, w) in fields {
            for i in (0..w).rev() {
                bytes[pos / 8] |= (((v >> i) & 1) as u8) << (7 - pos % 8);
                pos += 1;
            }
        }
        (bytes, n)
    }
    #[test]
    fn unaligned_main_lc_and_truncation_are_transactional() {
        for neural in [0, 1] {
            for groups in [1, 2] {
                let mut fields = vec![(5, 3), (0xaa, 8), (3, 3)];
                if groups == 2 {
                    fields.push((6, 3));
                }
                fields.extend([(2, 8), (0x12, 8), (0x34, 8), (0x56, 8)]);
                let (bytes, bits) = packed(&fields);
                for limit in 3..bits {
                    let mut r = BitReader::with_bit_len(&bytes, limit).unwrap();
                    r.read(3).unwrap();
                    assert!(QuantizedChannel::parse(&mut r, neural, groups, 3).is_err());
                    assert_eq!(r.position(), 3);
                }
                let mut r = BitReader::with_bit_len(&bytes, bits).unwrap();
                r.read(3).unwrap();
                let c = QuantizedChannel::parse(&mut r, neural, groups, 3).unwrap();
                assert_eq!(
                    (c.amplified, c.scale_index),
                    (neural == 0, if neural == 0 { 42 } else { 170 })
                );
                assert_eq!(c.context, [0x12, 0x34]);
                assert_eq!(c.base, [0x56]);
                assert_eq!(r.remaining(), 0);
            }
        }
    }
    #[test]
    fn invalid_allocation_and_grouping() {
        let mut r = BitReader::new(&[0, 0, 0xff]);
        assert!(QuantizedChannel::parse(&mut r, 0, 1, 0).is_err());
        assert_eq!(r.position(), 0);
        assert!(QuantizedChannel::parse(&mut r, 2, 1, 0).is_err());
        let mut r = BitReader::new(&[0xd5, 0]);
        assert_eq!(
            Grouping::parse(&mut r, 1).unwrap().indicators,
            [true, false, true, false, true, false, true, false]
        );
        assert_eq!(r.position(), 9);
        assert_eq!(Grouping::parse(&mut r, 0).unwrap().count, 1);
        assert_eq!(r.position(), 9);
    }
}
