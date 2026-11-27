//! Prefix-code (VLC) decoder: codes are read MSB-first and the
//! (bits, codes) tables form a prefix-free code set.
//!
//! Tables whose longest code is <= `MAX_FLAT_LEN` bits are decoded through a
//! flat 2^max_len lookup (peek the bits, one indexed access, skip the code
//! length). Longer tables (a few A-SPX codebooks reach 23 bits) keep the
//! compact binary trie (one node per bit, without scanning the codebook).

use crate::bitreader::BitReader;
use crate::error::{Result, invalid};

const MAX_FLAT_LEN: u8 = 17;

enum Table {
    /// Packed entries: `(len << 24) | symbol` (symbols are small
    /// non-negative indices); len == 0 marks an invalid prefix. One cache
    /// line per decode instead of two.
    Flat {
        entries: Vec<u32>,
    },
    Walk {
        nodes: Vec<Node>,
    },
}

#[derive(Default)]
struct Node {
    children: [Option<usize>; 2],
    symbol: Option<i32>,
}

pub struct Vlc {
    table: Table,
    max_len: u8,
}

/// Widening conversion for code tables of varying integer widths.
pub trait CodeVal {
    fn code_val(self) -> u32;
}
impl CodeVal for u8 {
    fn code_val(self) -> u32 {
        self as u32
    }
}
impl CodeVal for u16 {
    fn code_val(self) -> u32 {
        self as u32
    }
}
impl CodeVal for u32 {
    fn code_val(self) -> u32 {
        self
    }
}

impl Vlc {
    /// VLC without a symbol table: the decoded value is the entry index.
    pub fn new<C: CodeVal + Copy>(bits: &[u8], codes: &[C]) -> Result<Vlc> {
        assert_eq!(bits.len(), codes.len(), "bits/codes length mismatch");
        let symbols: Vec<i32> = (0..bits.len() as i32).collect();
        let wide: Vec<u32> = codes.iter().map(|&c| c.code_val()).collect();
        Self::with_symbols(bits, &wide, &symbols)
    }

    /// Sparse variant: entries with `bits == 0` are skipped; the decoded
    /// value is `symbols[i]` (which equals `i` when no symbol table is used).
    pub fn with_symbols(bits: &[u8], codes: &[u32], symbols: &[i32]) -> Result<Vlc> {
        assert_eq!(bits.len(), codes.len(), "bits/codes length mismatch");
        assert_eq!(bits.len(), symbols.len(), "bits/symbols length mismatch");

        let mut entries: Vec<(u8, u32, i32)> = Vec::with_capacity(bits.len());
        let mut max_len = 0u8;
        for i in 0..bits.len() {
            let b = bits[i];
            let c = codes[i];
            if b == 0 {
                continue;
            }
            if b > 32 {
                return Err(invalid("vlc: bad code length"));
            }
            if (b as u32) < 32 && c >= (1u32 << b) {
                return Err(invalid("vlc: code does not fit in its length"));
            }
            entries.push((b, c, symbols[i]));
            max_len = max_len.max(b);
        }
        if entries.is_empty() {
            return Err(invalid("vlc: empty table"));
        }
        // Duplicate (length, code) pairs would break any decoder path.
        let mut sorted = entries.clone();
        sorted.sort_unstable();
        for w in sorted.windows(2) {
            if w[0].0 == w[1].0 && w[0].1 == w[1].1 {
                return Err(invalid("vlc: duplicate (length, code) pair"));
            }
        }
        // Reject any code that is a prefix of another (guards against
        // translation mistakes in the generated tables).
        let mut by_len = entries.clone();
        by_len.sort_by_key(|e| e.0);
        for i in 0..by_len.len() {
            for j in i + 1..by_len.len() {
                let (li, ci, _) = by_len[i];
                let (lj, cj, _) = by_len[j];
                if li == lj {
                    continue;
                }
                if cj >> (lj - li) == ci {
                    return Err(invalid("vlc: table is not prefix-free"));
                }
            }
        }

        let table = if max_len <= MAX_FLAT_LEN {
            let size = 1usize << max_len;
            let mut flat = vec![0u32; size];
            for &(b, c, sym) in &entries {
                let start = (c as usize) << (max_len - b);
                let span = 1usize << (max_len - b);
                let packed = ((b as u32) << 24) | (sym as u32 & 0x00ff_ffff);
                flat[start..start + span].fill(packed);
            }
            Table::Flat { entries: flat }
        } else {
            let mut nodes = vec![Node::default()];
            for &(length, code, symbol) in &entries {
                let mut index = 0;
                for bit in (0..length).rev() {
                    let branch = ((code >> bit) & 1) as usize;
                    index = if let Some(child) = nodes[index].children[branch] {
                        child
                    } else {
                        let child = nodes.len();
                        nodes.push(Node::default());
                        nodes[index].children[branch] = Some(child);
                        child
                    };
                }
                nodes[index].symbol = Some(symbol);
            }
            Table::Walk { nodes }
        };

        Ok(Vlc { table, max_len })
    }

    /// `get_vlc2()` equivalent. Returns Err on an invalid code word.
    #[inline]
    pub fn decode(&self, br: &mut BitReader) -> Result<i32> {
        match &self.table {
            Table::Flat { entries } => {
                let idx = br.peek_bits(self.max_len as u32) as usize;
                let packed = entries[idx];
                let len = packed >> 24;
                if len == 0 {
                    // Consume nothing; caller treats this as invalid data.
                    return Err(invalid("vlc: invalid code word"));
                }
                br.skip_bits(len);
                Ok((packed & 0x00ff_ffff) as i32)
            }
            Table::Walk { nodes } => {
                let mut index = Some(0);
                for _ in 0..self.max_len {
                    let branch = br.get_bits1() as usize;
                    index = index.and_then(|i| nodes[i].children[branch]);
                    if let Some(symbol) = index.and_then(|i| nodes[i].symbol) {
                        return Ok(symbol);
                    }
                }
                Err(invalid("vlc: invalid code word"))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn long_codes_match_linear_reference_including_invalid_prefixes() {
        let bits: Vec<u8> = (1..=32).collect();
        let codes: Vec<u32> = bits.iter().map(|&n| (u32::MAX >> (32 - n)) - 1).collect();
        let symbols: Vec<i32> = (0..32).map(|n| n - 12).collect();
        let vlc = Vlc::with_symbols(&bits, &codes, &symbols).unwrap();
        let mut inputs = codes
            .iter()
            .zip(&bits)
            .map(|(&code, &length)| code << (32 - length))
            .collect::<Vec<_>>();
        inputs.push(u32::MAX);
        let mut seed = 0x12345678u32;
        for _ in 0..10000 {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            inputs.push(seed);
        }
        for input in inputs {
            let data = input.to_be_bytes();
            let mut actual = BitReader::new(&data);
            let mut reference = BitReader::new(&data);
            let mut code = 0;
            let mut expected = None;
            for length in 1..=32 {
                code = (code << 1) | reference.get_bits1();
                expected = bits
                    .iter()
                    .zip(&codes)
                    .zip(&symbols)
                    .find(|&((&n, &c), _)| n == length && c == code)
                    .map(|(_, &symbol)| symbol);
                if expected.is_some() {
                    break;
                }
            }
            assert_eq!(vlc.decode(&mut actual).ok(), expected);
            assert_eq!(actual.bits_count(), reference.bits_count());
        }
    }

    #[test]
    fn roundtrip_simple_table() {
        let bits = [1u8, 2, 4, 4];
        let codes = [0u32, 2, 12, 13];
        let vlc = Vlc::new(&bits, &codes).unwrap();
        let mut buf: Vec<bool> = vec![];
        for sym in 0..4 {
            let b = bits[sym] as u32;
            let c = codes[sym];
            for i in 0..b {
                buf.push((c >> (b - 1 - i)) & 1 == 1);
            }
        }
        let mut bytes = vec![0u8; buf.len().div_ceil(8)];
        for (i, &b) in buf.iter().enumerate() {
            if b {
                bytes[i / 8] |= 0x80 >> (i % 8);
            }
        }
        let mut br = BitReader::new(&bytes);
        for sym in 0..4 {
            assert_eq!(vlc.decode(&mut br).unwrap(), sym);
        }
    }

    #[test]
    fn rejects_prefix_collision() {
        // "0" (len 1) prefixes "01" (len 2, code 1)
        let bits = [1u8, 2];
        let codes = [0u32, 1];
        assert!(Vlc::new(&bits, &codes).is_err());
    }

    #[test]
    fn rejects_prefix_collision_high_bits() {
        // "10" (len 2, code 2) prefixes "101" (len 3, code 5)
        let bits = [2u8, 3];
        let codes = [2u32, 5];
        assert!(Vlc::new(&bits, &codes).is_err());
    }

    #[test]
    fn skips_zero_length_entries() {
        // bits==0 entries are ignored; symbol 1 is unreachable.
        let bits = [1u8, 0, 2];
        let codes = [0u32, 0, 2];
        let vlc = Vlc::new(&bits, &codes).unwrap();
        let data = [0b0100_0000]; // "0" then "10"
        let mut br = BitReader::new(&data);
        assert_eq!(vlc.decode(&mut br).unwrap(), 0);
        assert_eq!(vlc.decode(&mut br).unwrap(), 2);
    }

    #[test]
    fn flat_and_walk_agree() {
        // Same code set decoded once through the flat path (max_len <= 17)
        // and once through the walk path (a 19-bit entry forces Walk).
        let short = Vlc::with_symbols(&[2u8, 3, 3], &[0u32, 4, 5], &[7, 8, 9]).unwrap();
        let long =
            Vlc::with_symbols(&[2u8, 3, 3, 19], &[0u32, 4, 5, 3 << 16], &[7, 8, 9, 10]).unwrap();
        // "100" decodes to symbols[1] in both tables.
        let data = [0b1000_0000];
        let mut br = BitReader::new(&data);
        assert_eq!(short.decode(&mut br).unwrap(), 8);
        let mut br = BitReader::new(&data);
        assert_eq!(long.decode(&mut br).unwrap(), 8);
    }
}
