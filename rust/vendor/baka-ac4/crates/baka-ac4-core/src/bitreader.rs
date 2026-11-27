//! MSB-first bit reader for bitstream parsing.
//!
//! Reads past the end of the buffer return zero bits, and the position may
//! advance past the end so `bits_left()` can go negative; call sites use this
//! to detect overreads instead of panicking mid-parse.

pub struct BitReader<'a> {
    data: &'a [u8],
    /// Bit position from the start of `data`.
    pos: usize,
    /// Size of the buffer in bits.
    size_bits: usize,
}

// Temporary bit-trace buffer for differential debugging (BAKA_TRACE=1).
std::thread_local! {
    pub static TRACE: std::cell::RefCell<Vec<(u32, u32, u32)>> = const { std::cell::RefCell::new(Vec::new()) };
}

pub fn trace_enabled() -> bool {
    static ENABLED: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ENABLED.get_or_init(|| std::env::var_os("BAKA_TRACE").is_some())
}

pub fn trace_dump() {
    TRACE.with(|t| {
        for (pos, n, v) in t.borrow().iter() {
            eprintln!("trace: pos={pos} n={n} val={v}");
        }
    });
}

impl<'a> BitReader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        BitReader {
            data,
            pos: 0,
            size_bits: data.len() * 8,
        }
    }

    /// `get_bits1()`
    #[inline]
    pub fn get_bits1(&mut self) -> u32 {
        let v = self.read(1);
        if trace_enabled() {
            TRACE.with(|t| {
                let mut t = t.borrow_mut();
                if t.len() < 16384 {
                    t.push((self.pos as u32, 1, v));
                }
            });
        }
        v
    }

    /// `get_bits(n)` for 1..=32 bits, MSB first.
    #[inline]
    pub fn get_bits(&mut self, n: u32) -> u32 {
        let v = self.read(n);
        if trace_enabled() {
            TRACE.with(|t| {
                let mut t = t.borrow_mut();
                if t.len() < 16384 {
                    t.push((self.pos as u32, n, v));
                }
            });
        }
        v
    }

    /// `get_bits_long()` — same as `get_bits` for our usage (n <= 25).
    #[inline]
    pub fn get_bits_long(&mut self, n: u32) -> u32 {
        self.get_bits(n)
    }

    /// Reads up to `n` (<= 32) bits at the current position WITHOUT consuming
    /// them; bits past the end of the buffer read as zero, like `read`.
    #[inline]
    pub fn peek_bits(&self, n: u32) -> u32 {
        debug_assert!(n > 0 && n <= 32);
        let byte_idx = self.pos >> 3;
        let shift = self.pos & 7;
        let mut bytes = [0u8; 8];
        let safe = byte_idx.min(self.data.len());
        let avail = (self.data.len() - safe).min(8);
        bytes[..avail].copy_from_slice(&self.data[safe..safe + avail]);
        let window = u64::from_be_bytes(bytes);
        ((window << shift) >> (64 - n)) as u32
    }

    #[inline]
    fn read(&mut self, n: u32) -> u32 {
        debug_assert!(n > 0 && n <= 32);
        let value = self.peek_bits(n);
        self.pos += n as usize;
        value
    }

    /// `skip_bits(n)`
    #[inline]
    pub fn skip_bits(&mut self, n: u32) {
        self.pos += n as usize;
    }

    /// `skip_bits_long(n)`
    #[inline]
    pub fn skip_bits_long(&mut self, n: i64) {
        self.pos = (self.pos as i64 + n) as usize;
    }

    /// `align_get_bits()` — advance to the next byte boundary.
    pub fn align(&mut self) {
        self.pos = (self.pos + 7) & !7;
    }

    /// `get_bits_count()`
    #[inline]
    pub fn bits_count(&self) -> usize {
        self.pos
    }

    /// `get_bits_left()`
    #[inline]
    pub fn bits_left(&self) -> i64 {
        self.size_bits as i64 - self.pos as i64
    }

    /// `get_unary(gb, stop, len)` from unary.h.
    pub fn get_unary(&mut self, stop: u32, len: u32) -> u32 {
        let mut i = 0u32;
        while i < len && self.get_bits1() != stop {
            i += 1;
        }
        i
    }

    /// Byte position of the reader (bits_count >> 3).
    #[inline]
    pub fn byte_pos(&self) -> usize {
        self.pos >> 3
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_msb_first() {
        let data = [0b1011_0010, 0b0100_0001];
        let mut br = BitReader::new(&data);
        assert_eq!(br.get_bits(3), 0b101);
        assert_eq!(br.get_bits1(), 1);
        assert_eq!(br.get_bits(4), 0b0010);
        assert_eq!(br.get_bits(8), 0b0100_0001);
    }

    #[test]
    fn past_end_returns_zero() {
        let data = [0xFF];
        let mut br = BitReader::new(&data);
        assert_eq!(br.get_bits(8), 0xFF);
        assert_eq!(br.get_bits1(), 0);
        assert_eq!(br.get_bits(4), 0);
        assert_eq!(br.bits_left(), -5);
    }

    #[test]
    fn peek_matches_read() {
        let data: Vec<u8> = vec![0b1100_1010, 0b0111_0001, 0b0000_0010, 0b0101_1010];
        for start in 0..16 {
            for n in [1u32, 2, 3, 5, 8, 13, 17, 24, 31] {
                let mut br = BitReader::new(&data);
                br.skip_bits(start);
                let peeked = br.peek_bits(n);
                assert_eq!(br.bits_count(), start as usize, "peek must not advance");
                let read = br.get_bits(n);
                assert_eq!(peeked, read, "start={start} n={n}");
            }
        }
    }

    #[test]
    fn peek_past_end_zero() {
        let data = [0xAB];
        let mut br = BitReader::new(&data);
        br.skip_bits(4);
        assert_eq!(br.peek_bits(8), 0xB0);
        br.skip_bits(8);
        assert_eq!(br.peek_bits(4), 0);
    }

    #[test]
    fn unary_decode() {
        // 0 1 1 0 => unary(stop=0) = 0 (first bit is the stop bit)
        let data = [0b0110_0000];
        let mut br = BitReader::new(&data);
        assert_eq!(br.get_unary(0, 31), 0);
        // now remaining: 110 0000
        assert_eq!(br.get_unary(0, 31), 2);
    }

    #[test]
    fn align_and_skip() {
        let data = [0xAB, 0xCD, 0xEF];
        let mut br = BitReader::new(&data);
        br.get_bits(3);
        br.align();
        assert_eq!(br.bits_count(), 8);
        br.skip_bits_long(8);
        assert_eq!(br.get_bits(8), 0xEF);
    }
}
