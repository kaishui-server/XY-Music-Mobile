use super::*;
use crate::ajoc::{History, common_timing};

#[derive(Default)]
struct Bits(Vec<bool>);
impl Bits {
    fn put(&mut self, value: u32, width: u8) {
        for shift in (0..width).rev() {
            self.0.push(value & (1 << shift) != 0);
        }
    }
    fn bytes(&self) -> Vec<u8> {
        let mut bytes = vec![0; self.0.len().div_ceil(8)];
        for (i, &bit) in self.0.iter().enumerate() {
            bytes[i / 8] |= u8::from(bit) << (7 - i % 8);
        }
        bytes
    }
    fn extension(&mut self, mut data: Bits) {
        while !data.0.len().is_multiple_of(8) {
            data.put(0, 1);
        }
        let bytes = data.0.len() / 8;
        self.put(1, 1);
        if bytes == 1 {
            self.put(0, 1);
        } else {
            self.put(1, 1);
            let mut remaining = bytes - 2;
            let mut digits = vec![(remaining % 4) as u32];
            while remaining >= 4 {
                remaining = (remaining >> 2) - 1;
                digits.push((remaining % 4) as u32);
            }
            for (index, &digit) in digits.iter().rev().enumerate() {
                self.put(digit, 2);
                self.put(u32::from(index + 1 < digits.len()), 1);
            }
        }
        self.0.extend(data.0);
    }
    fn parse(&self) -> CommonData {
        let bytes = self.bytes();
        let mut gb = BitReader::new(&bytes);
        let result = parse(&mut gb, self.0.len()).unwrap();
        assert_eq!(gb.bits_count(), self.0.len());
        result
    }
}

#[test]
fn extended_lengths_preserve_tail_and_leave_following_fields_unread() {
    for bytes in [1, 2, 5, 6, 17, 22, 100] {
        let mut b = Bits::default();
        b.put(1, 1);
        b.put(0, 1);
        let mut extra = Bits::default();
        extra.put(0, 1); // trim absent
        for _ in 1..bytes * 8 {
            extra.put(1, 1);
        }
        b.extension(extra);
        let end = b.0.len();
        b.put(0b10101, 5);
        let raw = b.bytes();
        let mut gb = BitReader::new(&raw);
        let parsed = parse(&mut gb, b.0.len()).unwrap();
        assert_eq!(gb.bits_count(), end);
        assert_eq!(gb.get_bits(5), 0b10101);
        assert_eq!(parsed.additional_bits, bytes * 8 - 1);
        assert_eq!(
            parsed.additional_data[0],
            if bytes == 1 { 0xfe } else { 0xff }
        );
        assert!(parsed.trim.is_none());
    }
}

#[test]
fn screen_ratio_defaults_and_explicit_endpoints() {
    let mut b = Bits::default();
    b.put(1, 1);
    b.put(0, 1);
    b.put(0, 1);
    assert_eq!(b.parse(), CommonData::default());
    for code in [0, 31] {
        let mut b = Bits::default();
        b.put(0, 1);
        b.put(code, 5);
        b.put(1, 1);
        b.put(0, 1);
        let actual = b.parse();
        assert_eq!(actual.master_screen_ratio, (code + 1) as f32 / 33.0);
        assert!(actual.bed_channel_distribution);
    }
}

#[test]
fn global_trim_modes_reserved_warp_and_opaque_tail() {
    for mode in [0, 1, 3] {
        let mut b = Bits::default();
        b.put(1, 1);
        b.put(0, 1);
        let mut extra = Bits::default();
        extra.put(1, 1);
        extra.put(3, 2);
        extra.put(0, 2);
        extra.put(mode, 2);
        extra.put(1, 1); // bed-render flag is retained, not interpreted
        b.extension(extra);
        let parsed = b.parse();
        assert_eq!(parsed.additional_bits, 1);
        assert_eq!(parsed.additional_data, [0x80]);
        let trim = parsed.trim.unwrap();
        assert_eq!(trim.warp, WarpMode::Reserved(3));
        let expected = [TrimMode::Default, TrimMode::Disabled, TrimMode::Reserved]
            [if mode == 3 { 2 } else { mode as usize }];
        assert_eq!(trim.global_mode, expected);
        assert!(
            trim.configurations
                .iter()
                .all(|c| c.mode == expected && c.centre.is_none())
        );
    }
}

fn custom() -> Bits {
    let mut b = Bits::default();
    b.put(1, 1);
    b.put(1, 1);
    let mut extra = Bits::default();
    extra.put(1, 1);
    extra.put(1, 2);
    extra.put(0, 2);
    extra.put(2, 2);
    extra.put(1, 1); // configuration 0: default
    extra.put(0, 1);
    extra.put(1, 1); // configuration 1: disabled
    extra.put(0, 2);
    extra.put(31, 5); // configuration 2: all fields
    extra.put(0, 4);
    extra.put(15, 4);
    extra.put(2, 4);
    extra.put(0, 1);
    extra.put(15, 4); // front -1
    extra.put(1, 1);
    extra.put(0, 4); // back +1/16
    extra.put(0, 2);
    extra.put(0, 5); // configuration 3: custom absent values
    for _ in 4..9 {
        extra.put(1, 1);
    }
    extra.put(0b10101, 5); // opaque bed-render/future data
    b.extension(extra);
    b
}

#[test]
fn nine_custom_configurations_balance_sign_and_gain_tables() {
    let parsed = custom().parse();
    let trim = parsed.trim.unwrap();
    assert_eq!(trim.warp, WarpMode::DoubleY);
    assert_eq!(trim.configurations[0].mode, TrimMode::Default);
    assert_eq!(trim.configurations[1].mode, TrimMode::Disabled);
    let c = trim.configurations[2];
    assert_eq!(c.centre, Some(TrimGain::Db(6.0)));
    assert_eq!(c.surround, Some(TrimGain::Db(-36.0)));
    assert_eq!(c.height, Some(TrimGain::Reserved(2)));
    assert_eq!(c.balance_top_bottom, Some(-1.0));
    assert_eq!(c.balance_listener, Some(1.0 / 16.0));
    assert_eq!(trim.configurations[3].centre, None);
    assert_eq!(trim.configurations[3].mode, TrimMode::Custom);
    assert_eq!(parsed.additional_data[0] >> 3, 0b10101);
    for code in 0..16 {
        let mut b = Bits::default();
        b.put(code, 4);
        let bytes = b.bytes();
        let mut gb = BitReader::new(&bytes);
        let mut r = Reader {
            gb: &mut gb,
            end: 4,
        };
        assert!(matches!(r.trim_gain(true).unwrap(), TrimGain::Db(_)));
        let mut gb = BitReader::new(&bytes);
        let mut r = Reader {
            gb: &mut gb,
            end: 4,
        };
        assert_eq!(
            matches!(r.trim_gain(false).unwrap(), TrimGain::Reserved(_)),
            code < 4
        );
    }
}

#[test]
fn every_truncation_and_nested_length_cannot_borrow_outer_bits() {
    let b = custom();
    let bytes = b.bytes();
    for end in 0..b.0.len() {
        let mut gb = BitReader::new(&bytes);
        assert!(parse(&mut gb, end).is_err(), "accepted truncation at {end}");
    }
    let mut b = Bits::default();
    b.put(1, 1);
    b.put(0, 1);
    let mut extra = Bits::default();
    extra.put(1, 1);
    extra.put(0, 2);
    extra.put(0, 2);
    extra.put(2, 2);
    extra.put(0, 1);
    b.extension(extra); // declares one byte, custom configuration cannot fit
    b.put(0, 32); // valid outer data must not satisfy the inner read
    let bytes = b.bytes();
    let mut gb = BitReader::new(&bytes);
    assert!(parse(&mut gb, b.0.len()).is_err());
    assert!(gb.bits_count() <= 12);
}

#[test]
fn shared_common_and_timing_commit_together_and_absence_reuses_controls() {
    let mut b = Bits::default();
    b.put(1, 1);
    b.0.extend(custom().0);
    b.put(1, 1);
    b.put(0, 1);
    b.put(1, 3);
    b.put(2, 6);
    b.put(0, 2);
    let bytes = b.bytes();
    let mut history = History::default();
    for end in 0..b.0.len() {
        let mut gb = BitReader::new(&bytes);
        assert!(common_timing(&mut gb, end, &mut history).is_err());
        assert!(history.common.is_none());
        assert!(history.common_oamd.is_empty());
    }
    let mut gb = BitReader::new(&bytes);
    common_timing(&mut gb, b.0.len(), &mut history).unwrap();
    assert_eq!(history.common_oamd[0].sample, 64);
    let expected = history.common.clone();
    let expected_timing = history.common_oamd.clone();
    for end in 0..b.0.len() {
        let mut gb = BitReader::new(&bytes);
        assert!(common_timing(&mut gb, end, &mut history).is_err());
        assert_eq!(history.common, expected);
        assert_eq!(history.common_oamd, expected_timing);
    }
    let mut gb = BitReader::new(&[0]);
    common_timing(&mut gb, 2, &mut history).unwrap();
    assert_eq!(history.common, expected);
    assert!(history.common_oamd.is_empty());
}
