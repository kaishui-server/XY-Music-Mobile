#[derive(Default)]
pub struct Writer {
    pub bytes: Vec<u8>,
    pub bits: usize,
}
impl Writer {
    pub fn put(&mut self, value: u32, width: u8) {
        for bit in (0..width).rev() {
            if self.bits.is_multiple_of(8) {
                self.bytes.push(0);
            }
            self.bytes[self.bits / 8] |= (((value >> bit) & 1) as u8) << (7 - self.bits % 8);
            self.bits += 1;
        }
    }
}

pub fn frame(zero_entropy: bool) -> Vec<u8> {
    let mut w = Writer::default();
    for (v, n) in [
        (0xfff, 12),
        (2, 4),
        (0, 1),
        (0, 3),
        (0, 3),
        (3, 4),
        (0, 8),
        (10, 7),
        (1, 2),
        (4, 4),
        (0, 8),
    ] {
        w.put(v, n);
    }
    assert_eq!(w.bits, 56);
    w.put(0, 2); // Absent static and dynamic metadata.
    for _ in 0..12 {
        w.put(0, 2);
        for width in [8, 8, 7, 7, 6, 5, 5] {
            w.put(0, width);
        }
        w.put(0, 2); // Both TNS filters disabled; long windows need no grouping bits.
    }
    w.put(0, 1);
    w.put(0, 4); // No silence map or coupling pairs.
    for _ in 0..11 {
        w.put(6, 6);
    }
    assert_eq!(w.bits - 56, 673);
    for ch in 0..12 {
        let budget = if ch == 3 {
            20
        } else if ch == 0 {
            205
        } else {
            207
        };
        w.put(0, 1);
        w.put(73, 7);
        w.put(3, 3);
        w.put(2, 8);
        for i in 0..budget {
            w.put(if zero_entropy { 0 } else { i as u32 & 255 }, 8);
        }
    }
    assert_eq!(w.bits, 56 + 19261);
    w.put(0, 2);
    w.bytes
}
