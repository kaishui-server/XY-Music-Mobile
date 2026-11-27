//! Integer range decoding for externally supplied quantized distributions.
use crate::Error;

/// Validated cumulative frequencies. The last symbol is the escape symbol.
#[derive(Clone, Debug)]
pub struct Distribution<'a> {
    cumulative: &'a [u32],
    precision: u8,
    offset: i32,
}

impl<'a> Distribution<'a> {
    pub fn new(cumulative: &'a [u32], precision: u8, offset: i32) -> Result<Self, Error> {
        if !(1..=16).contains(&precision) || !(3..=65537).contains(&cumulative.len()) {
            return Err(Error::Invalid("CDF dimensions"));
        }
        if cumulative[0] != 0
            || cumulative.last() != Some(&(1u32 << precision))
            || cumulative.windows(2).any(|w| w[0] > w[1])
        {
            return Err(Error::Invalid("cumulative frequencies"));
        }
        Ok(Self {
            cumulative,
            precision,
            offset,
        })
    }
    pub fn symbol_count(&self) -> usize {
        self.cumulative.len() - 1
    }
}

/// Arithmetic streams omit trailing zero bytes. These counters expose that
/// padding separately from actual input consumption; they do not prove CRC integrity.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DecodedSymbols {
    pub values: Vec<i32>,
    pub bytes_consumed: usize,
    pub zero_padding_bytes: usize,
}

/// Owned probability tables from a little-endian model record. Network weights
/// and distribution count are separate model fields and are not inferred here.
#[derive(Clone, Debug)]
pub struct EntropyModel {
    cumulative: Vec<Vec<u32>>,
    offsets: Vec<i32>,
}

impl EntropyModel {
    /// Read lengths (u16), offsets (i16), then cumulative frequencies (u32).
    /// Returns the exact record size so the caller can parse the next model field.
    pub fn read(bytes: &[u8], count: usize) -> Result<(Self, usize), Error> {
        if !(1..=1024).contains(&count) {
            return Err(Error::Invalid("model distribution count"));
        }
        let header = count * 4;
        if bytes.len() < header {
            return Err(Error::Truncated);
        }
        let mut lengths = Vec::with_capacity(count);
        let mut entries = 0usize;
        for pair in bytes[..count * 2].as_chunks::<2>().0 {
            let length = usize::from(u16::from_le_bytes(*pair));
            if length < 3 {
                return Err(Error::Invalid("model CDF length"));
            }
            entries += length;
            if entries > 1024 * 1024 {
                return Err(Error::Unsupported("model CDF entry limit"));
            }
            lengths.push(length);
        }
        let consumed = header + entries * 4;
        if consumed > bytes.len() {
            return Err(Error::Truncated);
        }
        let offsets: Vec<_> = bytes[count * 2..header]
            .as_chunks::<2>()
            .0
            .iter()
            .map(|pair| i32::from(i16::from_le_bytes(*pair)))
            .collect();
        let mut cumulative = Vec::with_capacity(count);
        let mut position = header;
        for (length, offset) in lengths.into_iter().zip(&offsets) {
            let end = position + length * 4;
            let row: Vec<_> = bytes[position..end]
                .as_chunks::<4>()
                .0
                .iter()
                .map(|word| u32::from_le_bytes(*word))
                .collect();
            Distribution::new(&row, 16, *offset)?;
            cumulative.push(row);
            position = end;
        }
        Ok((
            Self {
                cumulative,
                offsets,
            },
            consumed,
        ))
    }

    pub fn distribution_count(&self) -> usize {
        self.cumulative.len()
    }

    pub fn decode(&self, input: &[u8], indices: &[usize]) -> Result<DecodedSymbols, Error> {
        let distributions: Vec<_> = self
            .cumulative
            .iter()
            .zip(&self.offsets)
            .map(|(cumulative, offset)| Distribution {
                cumulative,
                offset: *offset,
                precision: 16,
            })
            .collect();
        decode(input, &distributions, indices)
    }
}

#[derive(Clone, Copy, Debug)]
struct RangeState<'a> {
    bytes: &'a [u8],
    reads: usize,
    lower: u32,
    span: u64,
    code: u32,
}

impl<'a> RangeState<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        let mut state = Self {
            bytes,
            reads: 0,
            lower: 0,
            span: 1u64 << 32,
            code: 0,
        };
        for _ in 0..4 {
            state.shift_byte();
        }
        state
    }
    fn shift_byte(&mut self) {
        let byte = self.bytes.get(self.reads).copied().unwrap_or(0);
        self.code = (self.code << 8) | u32::from(byte);
        self.reads += 1;
    }
    fn target(&self, precision: u8) -> Result<u64, Error> {
        let distance = u64::from(self.code.wrapping_sub(self.lower));
        if distance >= self.span {
            return Err(Error::Invalid("arithmetic code interval"));
        }
        Ok((((distance + 1) << precision) - 1) / self.span)
    }
    fn narrow(&mut self, low: u32, high: u32, precision: u8) -> Result<(), Error> {
        let start = (self.span * u64::from(low)) >> precision;
        let end = (self.span * u64::from(high)) >> precision;
        if end <= start {
            return Err(Error::Invalid("empty arithmetic interval"));
        }
        self.lower = self.lower.wrapping_add(start as u32);
        self.span = end - start;
        if self.span <= 65536 {
            self.lower <<= 16;
            self.span <<= 16;
            self.shift_byte();
            self.shift_byte();
        }
        Ok(())
    }
    fn symbol(&mut self, distribution: &Distribution<'_>) -> Result<usize, Error> {
        let target = self.target(distribution.precision)?;
        let end = distribution
            .cumulative
            .partition_point(|v| u64::from(*v) <= target);
        if end == 0 || end >= distribution.cumulative.len() {
            return Err(Error::Invalid("CDF lookup"));
        }
        self.narrow(
            distribution.cumulative[end - 1],
            distribution.cumulative[end],
            distribution.precision,
        )?;
        Ok(end - 1)
    }
    fn nibble(&mut self) -> Result<u32, Error> {
        let value = self.target(4)? as u32;
        self.narrow(value, value + 1, 4)?;
        Ok(value)
    }
    fn value(&mut self, distribution: &Distribution<'_>) -> Result<i32, Error> {
        let symbol = self.symbol(distribution)? as i64;
        let escape = distribution.symbol_count() as i64 - 1;
        let value = if symbol == escape {
            let mut sections = 0u32;
            loop {
                let n = self.nibble()?;
                sections += n;
                if sections > 8 {
                    return Err(Error::Invalid("arithmetic escape width"));
                }
                if n != 15 {
                    break;
                }
            }
            let mut raw = 0u32;
            for section in 0..sections {
                raw |= self.nibble()? << (section * 4);
            }
            if raw & 1 == 0 {
                i64::from(raw >> 1) + escape
            } else {
                -i64::from(raw >> 1) - 1
            }
        } else {
            symbol
        };
        i32::try_from(value + i64::from(distribution.offset))
            .map_err(|_| Error::Invalid("decoded coefficient range"))
    }
}

/// Decode one bounded entropy segment. Each index selects a distribution for
/// the next coefficient. Model parameters and symbol count are supplied by the caller.
/// Framing/CRC must detect truncation: arithmetic zero padding alone cannot do so.
pub fn decode(
    input: &[u8],
    distributions: &[Distribution<'_>],
    indices: &[usize],
) -> Result<DecodedSymbols, Error> {
    if input.len() > 1024 * 1024 || indices.len() > 1024 * 1024 {
        return Err(Error::Unsupported("entropy segment limit"));
    }
    if indices.iter().any(|i| *i >= distributions.len()) {
        return Err(Error::Invalid("CDF index"));
    }
    if indices.is_empty() {
        return Ok(DecodedSymbols {
            values: Vec::new(),
            bytes_consumed: 0,
            zero_padding_bytes: 0,
        });
    }
    let mut state = RangeState::new(input);
    let mut values = Vec::with_capacity(indices.len());
    for index in indices {
        values.push(state.value(&distributions[*index])?);
    }
    Ok(DecodedSymbols {
        values,
        bytes_consumed: state.reads.min(input.len()),
        zero_padding_bytes: state.reads.saturating_sub(input.len()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cdf_validation_and_zero_probability_symbols() {
        assert!(Distribution::new(&[0, 10, 9, 65536], 16, 0).is_err());
        assert!(Distribution::new(&[1, 5, 16], 4, 0).is_err());
        assert!(Distribution::new(&[0, 4, 15], 4, 0).is_err());
        assert!(Distribution::new(&[0, 8, 16], 0, 0).is_err());
        let d = Distribution::new(&[0, 0, 65535, 65536], 16, -1).unwrap();
        let decoded = decode(&[], &[d], &[0]).unwrap();
        assert_eq!(decoded.values, [0]);
        assert_eq!(decoded.bytes_consumed, 0);
        assert!(decoded.zero_padding_bytes >= 4);
        assert!(decode(&[], &[], &[0]).is_err());
    }
    #[test]
    fn uniform_binary_and_padding_accounting() {
        let d = Distribution::new(&[0, 32768, 65536], 16, 0).unwrap();
        let decoded = decode(&[0x40], &[d], &[0, 0]).unwrap();
        assert_eq!(decoded.values, [0, 1]);
        assert_eq!(decoded.bytes_consumed, 1);
    }
    #[test]
    fn malformed_bytes_never_panic_or_allocate_unbounded_output() {
        let d = Distribution::new(&[0, 1, 2, 65536], 16, 0).unwrap();
        for n in 0..256u32 {
            let _ = decode(&n.to_be_bytes(), std::slice::from_ref(&d), &[0; 256]);
        }
        assert!(decode(&[], &[d], &vec![0; 1024 * 1024 + 1]).is_err());
    }
}
