use crate::Error;

/// MSB-first reader. Failed reads leave the cursor unchanged.
#[derive(Clone, Debug)]
pub struct BitReader<'a> {
    bytes: &'a [u8],
    position: usize,
    limit: usize,
}

impl<'a> BitReader<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        Self {
            bytes,
            position: 0,
            limit: bytes.len().saturating_mul(8),
        }
    }
    pub fn with_bit_len(bytes: &'a [u8], limit: usize) -> Result<Self, Error> {
        if limit > bytes.len().saturating_mul(8) {
            return Err(Error::Truncated);
        }
        Ok(Self {
            bytes,
            position: 0,
            limit,
        })
    }
    pub fn remaining(&self) -> usize {
        self.limit - self.position
    }
    /// Read packed bytes even when the cursor is not byte aligned.
    pub fn read_bytes(&mut self, count: usize) -> Result<Vec<u8>, Error> {
        if count > 1024 * 1024 {
            return Err(Error::Unsupported("byte read limit"));
        }
        if count > self.remaining() / 8 {
            return Err(Error::Truncated);
        }
        let mut bytes = Vec::with_capacity(count);
        for _ in 0..count {
            bytes.push(self.read(8)? as u8);
        }
        Ok(bytes)
    }
    pub fn position(&self) -> usize {
        self.position
    }
    pub fn read(&mut self, width: u8) -> Result<u32, Error> {
        if width > 32 {
            return Err(Error::Invalid("bit width"));
        }
        let end = self
            .position
            .checked_add(usize::from(width))
            .ok_or(Error::Truncated)?;
        if end > self.limit {
            return Err(Error::Truncated);
        }
        let mut value = 0;
        for bit in self.position..end {
            value = (value << 1) | u32::from((self.bytes[bit / 8] >> (7 - bit % 8)) & 1);
        }
        self.position = end;
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cross_byte_and_transactional_failure() {
        let mut r = BitReader::new(&[0xab, 0xcd]);
        assert_eq!(r.read(4), Ok(10));
        assert_eq!(r.read(9), Ok(377));
        assert_eq!(r.read(4), Err(Error::Truncated));
        assert_eq!(r.position(), 13);
        assert_eq!(r.read(3), Ok(5));
        assert!(r.read(33).is_err());
    }
}
