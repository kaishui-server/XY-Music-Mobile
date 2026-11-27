use baka_av3a_core::{
    BitReader, Error,
    side::{ChannelBedFrame, CoreSide},
};

#[path = "fixtures/bed_frame.rs"]
mod bed_frame;
use bed_frame::{Writer, frame};

#[test]
fn object_payload_limits_are_checked_before_core_data() {
    use baka_av3a_core::FrameHeader;
    for count in [16u32, 17, 128] {
        let mut writer = Writer::default();
        for (value, width) in [
            (0xfff, 12),
            (2, 4),
            (0, 1),
            (0, 3),
            (1, 3),
            (2, 4),
            (0, 8),
            (0, 2),
            (count - 1, 7),
            (0, 4),
            (1, 2),
            (0, 8),
        ] {
            writer.put(value, width);
        }
        let header = FrameHeader::parse(&writer.bytes).unwrap();
        writer.bytes.resize(header.frame_bytes(), 0);
        writer.bytes[header.header_bytes] = 0x80;
        if count == 16 {
            let frame = ChannelBedFrame::parse(&writer.bytes).unwrap();
            assert!(frame.metadata.static_data.is_some());
        } else {
            assert_eq!(
                ChannelBedFrame::parse(&writer.bytes),
                Err(Error::Unsupported("payload channel count"))
            );
        }
    }
}

#[test]
fn complete_packet_segments_and_all_prefixes() {
    let bytes = frame(false);
    let parsed = ChannelBedFrame::parse(&bytes).unwrap();
    assert_eq!((parsed.side_bits, parsed.unused_bits), (673, 2));
    assert_eq!(
        parsed.channel_bytes,
        [205, 207, 207, 20, 207, 207, 207, 207, 207, 207, 207, 207]
    );
    for (q, &budget) in parsed.quantized.iter().zip(&parsed.channel_bytes) {
        assert_eq!(q.scale_index, 73);
        assert_eq!(q.noise_indices, [3]);
        assert_eq!(q.context, [0, 1]);
        assert_eq!(q.base.len(), budget - 2);
        assert_eq!(q.base[0], 2);
    }
    for n in 0..bytes.len() {
        assert!(ChannelBedFrame::parse(&bytes[..n]).is_err(), "prefix {n}");
    }
    let mut extended = bytes.clone();
    extended.push(0);
    assert!(ChannelBedFrame::parse(&extended).is_err());
    let mut metadata = bytes;
    metadata[7] |= 0x80;
    assert!(ChannelBedFrame::parse(&metadata).is_err());
}

#[test]
fn tns_signed_indices_and_transactional_truncation() {
    let mut w = Writer::default();
    w.put(1, 2);
    for width in [8, 8, 7, 7, 6] {
        w.put(1, width);
    }
    w.put(1, 1);
    w.put(7, 3);
    // All eight coefficient orders, including maximum-length and negative codes.
    for (value, width) in [
        (4053, 12),
        (1921, 12),
        (27138, 15),
        (4352, 13),
        (2048, 13),
        (8275, 14),
        (13315, 14),
        (10497, 14),
    ] {
        w.put(value, width);
    }
    w.put(0, 1);
    let parsed = CoreSide::parse_without_bwe(
        &mut BitReader::with_bit_len(&w.bytes, w.bits).unwrap(),
        true,
    )
    .unwrap();
    assert_eq!(parsed.transform, 1);
    assert_eq!(parsed.lsf_indices, [1; 5]);
    assert_eq!(parsed.tns[0], [-8, 7, 7, 7, 7, 7, 7, 0]);
    assert!(parsed.tns[1].is_empty());
    for n in 0..w.bits {
        let mut reader = BitReader::with_bit_len(&w.bytes, n).unwrap();
        assert!(CoreSide::parse_without_bwe(&mut reader, true).is_err());
        assert_eq!(reader.position(), 0);
    }
}

#[test]
fn unsupported_metadata_and_invalid_mode_rejected() {
    let original = frame(false);
    let mut bytes = original.clone();
    bytes[7] |= 0x78;
    assert_eq!(
        ChannelBedFrame::parse(&bytes),
        Err(Error::Unsupported("dynamic metadata level"))
    );
    let mut bytes = original.clone();
    bytes[5] &= 0xf0;
    bytes.truncate(
        baka_av3a_core::FrameHeader::parse(&bytes)
            .unwrap()
            .frame_bytes(),
    );
    // Changing only the bitrate does not turn a high-rate payload into a BWE frame.
    assert!(ChannelBedFrame::parse(&bytes).is_err());
    let mut bytes = original;
    // MC pair count = 1; pair index = 127, outside the 66 possible pairs.
    for (start, value, width) in [(56 + 603, 1, 4), (56 + 607, 127, 7)] {
        for bit in 0..width {
            let pos = start + bit;
            let mask = 1 << (7 - pos % 8);
            bytes[pos / 8] = (bytes[pos / 8] & !mask)
                | ((((value >> (width - bit - 1)) & 1) as u8) << (7 - pos % 8));
        }
    }
    assert_eq!(
        ChannelBedFrame::parse(&bytes),
        Err(Error::Invalid("channel pair index"))
    );
}

#[test]
fn malformed_payloads_remain_bounded() {
    let mut bytes = frame(false);
    let mut random = 0xc9712a83u32;
    for _ in 0..2000 {
        for byte in &mut bytes[7..] {
            random ^= random << 13;
            random ^= random >> 17;
            random ^= random << 5;
            *byte = random as u8;
        }
        bytes[7] &= 0x3f; // Exercise core/mode parsing beyond metadata flags.
        let _ = ChannelBedFrame::parse(&bytes);
    }
}
