use super::*;
use crate::bitreader::BitReader;

#[derive(Default)]
struct Bits(Vec<bool>);
impl Bits {
    fn put(&mut self, value: u32, width: u8) {
        for shift in (0..width).rev() {
            self.0.push(value & (1 << shift) != 0);
        }
    }
    fn bytes(&self) -> Vec<u8> {
        let mut out = vec![0; self.0.len().div_ceil(8)];
        for (i, &bit) in self.0.iter().enumerate() {
            out[i / 8] |= u8::from(bit) << (7 - i % 8);
        }
        out
    }
    fn key(&mut self, reuse_previous_object: bool) {
        self.put(0, 1); // active
        self.put(0, 1);
        self.put(0, 1); // non-default basic, gain only
        if reuse_previous_object {
            self.put(3, 2);
        } else {
            self.put(0, 1);
            self.put(20, 6);
        } // -6 dB
        self.put(0, 6);
        self.put(62, 6);
        self.put(1, 1);
        self.put(15, 4);
        self.put(1, 1);
        self.put(1, 1);
        self.put(0, 1); // zone/other defaults, no extension
    }
}

fn block(bits: &Bits, iframe: bool, state: &mut ObjectState) -> Result<ObjectProperties> {
    let bytes = bits.bytes();
    let mut gb = BitReader::new(&bytes);
    let mut r = Reader {
        gb: &mut gb,
        end: bits.0.len(),
    };
    let result = r.object_block(iframe, true, state, None)?;
    assert_eq!(r.gb.bits_count(), bits.0.len());
    Ok(result)
}

#[test]
fn gain_absolute_delta_precision_and_reuse_resolve_without_drift() {
    let mut key = Bits::default();
    key.key(false);
    let mut state = ObjectState::default();
    let p = block(&key, true, &mut state).unwrap();
    assert_eq!(p.gain_db, Some(-6));
    assert_eq!(p.position, [0.0, 1.0, 1.0]);
    assert!((p.linear_gain() - 0.5011872).abs() < 1e-6);
    let mut next = Bits::default();
    next.put(0, 1);
    next.put(1, 1);
    next.put(0, 1);
    next.put(1, 1);
    next.put(1, 3);
    next.put(1, 1); // partial: position only, delta
    next.put(1, 3);
    next.put(7, 3);
    next.put(7, 3);
    next.put(1, 1);
    next.put(0, 4); // one extension byte
    next.put(1, 1);
    next.put(1, 1);
    next.put(4, 3);
    next.put(1, 2);
    next.put(0, 1);
    let p = block(&next, false, &mut state).unwrap();
    assert_eq!(p.gain_db, Some(-6));
    assert!(p.trim_disabled);
    assert_eq!(p.position, [1.4 / 62.0, 61.0 / 62.0, 14.0 / 15.0]);
    let reuse = Bits(vec![false, true, true, false]);
    let p = block(&reuse, false, &mut state).unwrap();
    assert_eq!(p.position, [1.0 / 62.0, 61.0 / 62.0, 14.0 / 15.0]);
}

#[test]
fn gain_reuses_previous_object_in_the_same_update_block() {
    let mut bits = Bits::default();
    bits.key(false);
    bits.key(true);
    let bytes = bits.bytes();
    let mut gb = BitReader::new(&bytes);
    let mut r = Reader {
        gb: &mut gb,
        end: bits.0.len(),
    };
    let data = r
        .objects(
            2,
            false,
            &[ObjectTiming { sample: 0, ramp: 0 }],
            true,
            &mut Vec::new(),
        )
        .unwrap();
    assert_eq!(data[0][0].properties.gain_db, Some(-6));
    assert_eq!(data[1][0].properties.gain_db, Some(-6));
    let mut invalid = Bits::default();
    invalid.key(true);
    assert!(block(&invalid, true, &mut ObjectState::default()).is_err());
}

#[test]
fn inactive_object_resets_gain_priority_and_position() {
    let mut state = ObjectState::default();
    let mut key = Bits::default();
    key.key(false);
    block(&key, true, &mut state).unwrap();
    let mut inactive = Bits::default();
    inactive.put(2, 2); // inactive, no extension
    let p = block(&inactive, false, &mut state).unwrap();
    assert_eq!(p, ObjectProperties::default());
    assert_eq!(p.linear_gain(), 0.0);
}

#[test]
fn timing_offsets_and_ramp_tables_are_sample_accurate() {
    let mut b = Bits::default();
    b.put(3, 2);
    b.put(7, 5);
    b.put(2, 3); // explicit sample offset 7, two blocks
    b.put(4, 6);
    b.put(3, 2);
    b.put(1, 1);
    b.put(15, 4); // factor4, table2048
    b.put(63, 6);
    b.put(3, 2);
    b.put(0, 1);
    b.put(200, 11);
    let bytes = b.bytes();
    let mut gb = BitReader::new(&bytes);
    let mut r = Reader {
        gb: &mut gb,
        end: b.0.len(),
    };
    assert_eq!(
        r.timing().unwrap(),
        [
            ObjectTiming {
                sample: 135,
                ramp: 2048
            },
            ObjectTiming {
                sample: 2023,
                ramp: 200
            }
        ]
    );
}

#[test]
fn every_object_bit_truncation_is_rejected() {
    let mut key = Bits::default();
    key.key(false);
    let bytes = key.bytes();
    for end in 0..key.0.len() {
        let mut gb = BitReader::new(&bytes);
        let mut r = Reader { gb: &mut gb, end };
        assert!(
            r.object_block(true, true, &mut ObjectState::default(), None)
                .is_err(),
            "accepted {end}"
        );
    }
}
