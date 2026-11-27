use super::*;
use std::cell::RefCell;
thread_local! { static TRACE: RefCell<Option<Vec<(u8, u8)>>> = const { RefCell::new(None) }; }
pub(super) fn record(width: u8, value: u8) {
    TRACE.with(|trace| {
        if let Some(trace) = &mut *trace.borrow_mut() {
            trace.push((width, value));
        }
    });
}

#[test]
fn independent_static_field_reads_and_all_prefixes() {
    let fixture = include_bytes!("../../../tests/fixtures/static_metadata.bin");
    assert_eq!(&fixture[..8], b"MSTA0001");
    let word =
        |offset| u32::from_le_bytes(fixture[offset..offset + 4].try_into().unwrap()) as usize;
    assert_eq!(word(8), 258);
    let mut offset = 12;
    for case in 0..258 {
        let bits = word(offset);
        offset += 4;
        let bytes = &fixture[offset..offset + bits.div_ceil(8)];
        offset += bytes.len();
        let size = word(offset);
        offset += 4;
        let expected = &fixture[offset..offset + size];
        offset += size;
        let mut reader = BitReader::with_bit_len(bytes, bits).unwrap();
        TRACE.with(|trace| *trace.borrow_mut() = Some(Vec::new()));
        let result =
            StaticMetadata::parse(&mut reader).unwrap_or_else(|e| panic!("case {case}: {e}"));
        let trace = TRACE.with(|trace| trace.borrow_mut().take().unwrap());
        let actual: Vec<u8> = trace
            .iter()
            .flat_map(|&(width, value)| {
                [
                    u32::from(width).to_le_bytes(),
                    u32::from(value).to_le_bytes(),
                ]
                .concat()
            })
            .collect();
        assert_eq!(actual, expected, "case {case} field trace");
        assert_eq!(reader.position(), bits);
        if case < 256 {
            assert_eq!(result.basic_level, (case as u8 % 8).min(1));
            assert_eq!(result.objects[0].muted, case & 128 != 0);
            assert_eq!(result.vr.is_some(), case >= 128);
            if let Some(interaction) = &result.objects[0].interaction {
                assert_eq!(interaction.name, std::array::from_fn(|i| (case + i) as u8));
            }
        } else {
            assert_eq!(result.channels.len(), 32);
        }
        for prefix in 0..bits {
            let mut reader = BitReader::with_bit_len(bytes, prefix).unwrap();
            assert_eq!(
                StaticMetadata::parse(&mut reader),
                Err(Error::Truncated),
                "case {case} prefix {prefix}"
            );
            assert_eq!(reader.position(), 0);
        }
    }
    assert_eq!(offset, fixture.len());
}

#[test]
fn unmapped_channels_and_random_payloads_are_bounded() {
    let fixture = include_bytes!("../../../tests/fixtures/static_metadata.bin");
    let bits = u32::from_le_bytes(fixture[12..16].try_into().unwrap()) as usize;
    let mut packet = fixture[16..16 + bits.div_ceil(8)].to_vec();
    // The minimal first vector defines only channel 0. Change the final
    // channel index to 1; its layout cannot be inferred from any pack.
    packet[(bits - 2) / 8] |= 1 << (7 - (bits - 2) % 8);
    let mut reader = BitReader::with_bit_len(&packet, bits).unwrap();
    assert_eq!(
        StaticMetadata::parse(&mut reader),
        Err(Error::Invalid("static channel pack reference"))
    );
    assert_eq!(reader.position(), 0);
    let mut seed = 1u32;
    for _ in 0..2000 {
        let mut bytes = [0u8; 256];
        for byte in &mut bytes {
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            *byte = (seed >> 24) as u8;
        }
        let mut reader = BitReader::new(&bytes);
        if StaticMetadata::parse(&mut reader).is_err() {
            assert_eq!(reader.position(), 0);
        }
    }
}
