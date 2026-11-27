use baka_av3a_core::{
    BitReader, FrameHeader,
    hoa::{HoaConfig, HoaFrame, HoaSide},
};
#[derive(Default)]
struct Writer {
    bytes: Vec<u8>,
    bits: usize,
}
impl Writer {
    fn put(&mut self, value: u32, width: usize) {
        for bit in (0..width).rev() {
            if self.bits.is_multiple_of(8) {
                self.bytes.push(0);
            }
            self.bytes[self.bits / 8] |= (((value >> bit) & 1) as u8) << (7 - self.bits % 8);
            self.bits += 1;
        }
    }
}

#[test]
fn side_validation_and_transactional_truncation() {
    let config = HoaConfig::new(3, 256000).unwrap();
    assert_eq!(
        (config.output_channels(), config.transport_channels()),
        (16, 8)
    );
    let mut writer = Writer::default();
    writer.put(3, 4);
    writer.put(1, 1);
    writer.put(2, 4);
    writer.put(0, 12);
    writer.put(1342, 12);
    for count in [2, 6] {
        writer.put(0, 4);
        writer.put(8, 4);
        for _ in 0..count {
            writer.put(1, 4);
        }
    }
    for length in 0..writer.bits {
        let mut reader = BitReader::with_bit_len(&writer.bytes, length).unwrap();
        assert!(HoaSide::parse(&mut reader, &config).is_err());
        assert_eq!(reader.position(), 0);
    }
    let side = HoaSide::parse(&mut BitReader::new(&writer.bytes), &config).unwrap();
    assert_eq!(side.basis_indices, [0, 1342]);
    let bytes = side.allocate(&config, 803).unwrap();
    assert_eq!(bytes, [25, 25, 10, 8, 8, 8, 8, 8]);
    let mut invalid = side;
    invalid.groups[0].channel_ratios.fill(0);
    assert!(invalid.allocate(&config, 803).is_err());
    assert!(HoaConfig::new(4, 256000).is_err());
    assert!(HoaConfig::new(2, 448000).is_err());
    let mut bytes = writer.bytes;
    bytes[0] &= !8;
    let mut reader = BitReader::new(&bytes);
    assert!(HoaSide::parse(&mut reader, &config).is_err());
    assert_eq!(reader.position(), 0);
}

#[test]
fn malformed_payloads_are_bounded() {
    let mut header = Writer::default();
    for (value, width) in [
        (0xfff, 12),
        (2, 4),
        (0, 1),
        (0, 3),
        (2, 3),
        (2, 4),
        (0, 8),
        (0, 4),
        (1, 2),
        (0, 4),
        (0, 8),
    ] {
        header.put(value, width);
    }
    let parsed = FrameHeader::parse(&header.bytes).unwrap();
    let mut seed = 1u32;
    for _ in 0..2000 {
        let mut packet = header.bytes.clone();
        packet.resize(parsed.frame_bytes(), 0);
        for byte in &mut packet[7..] {
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            *byte = (seed >> 24) as u8;
        }
        packet[7] &= 0x3f;
        let _ = HoaFrame::parse(&packet);
    }
    for (basis_count, basis, expected) in
        [(0, 0, "HOA foreground count"), (2, 1343, "HOA basis index")]
    {
        let mut writer = Writer::default();
        writer.put(0, 4);
        writer.put(1, 1);
        writer.put(basis_count, 4);
        writer.put(basis, 12);
        let mut reader = BitReader::new(&writer.bytes);
        assert_eq!(
            HoaSide::parse(&mut reader, &HoaConfig::new(3, 256000).unwrap()),
            Err(baka_av3a_core::Error::Invalid(expected))
        );
        assert_eq!(reader.position(), 0);
    }
}

#[test]
#[ignore = "requires local independent HOA transport records"]
fn local_hoa_transport_matrix() {
    let directory = std::path::PathBuf::from(std::env::var_os("BAKA_AV3A_HOA_MATRIX_DIR").unwrap());
    let mut files: Vec<_> = std::fs::read_dir(directory)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "av3a"))
        .collect();
    files.sort();
    assert_eq!(files.len(), 72);
    let mut total = 0;
    for file in files {
        let bytes = std::fs::read(&file).unwrap();
        let reference = std::fs::read(file.with_extension("side")).unwrap();
        let mut words = reference
            .as_chunks::<4>()
            .0
            .iter()
            .map(|v| u32::from_le_bytes(*v) as usize);
        let mut offset = 0;
        let mut frame_index = 0;
        while offset < bytes.len() {
            let header = FrameHeader::parse(&bytes[offset..]).unwrap();
            let packet = &bytes[offset..offset + header.frame_bytes()];
            FrameHeader::validate_crc(packet).unwrap();
            let frame = HoaFrame::parse(packet)
                .unwrap_or_else(|e| panic!("{} frame {frame_index}: {e}", file.display()));
            assert_eq!(
                frame.side_bits,
                words.next().unwrap(),
                "{} frame {frame_index}",
                file.display()
            );
            for value in &frame.channel_bytes {
                assert_eq!(*value, words.next().unwrap());
            }
            assert_eq!(
                header.payload_bits - frame.unused_bits,
                words.next().unwrap()
            );
            assert_eq!(frame.side.scene, frame_index);
            assert_eq!(frame.cores.len(), frame.config.transport_channels());
            assert_eq!(frame.side.spatial, frame.config.spatial());
            let mut channel = 0;
            for (group, side) in frame.config.groups().iter().zip(&frame.side.groups) {
                assert_eq!(side.pairs.len(), usize::from(frame_index % 3));
                assert_eq!(side.ratio, 5 + frame_index);
                for (local, &ratio) in side.channel_ratios.iter().enumerate() {
                    assert_eq!(ratio, (frame_index + local as u8) % 15 + 1);
                    assert_eq!(
                        side.energy[local],
                        if side.pairs.is_empty() {
                            30
                        } else {
                            (frame_index + local as u8) % 31
                        }
                    );
                }
                for (index, pair) in side.pairs.iter().enumerate() {
                    let [low, high] = pair.channels;
                    assert!(low < high && high < group.channels);
                    assert_eq!(
                        high * (high - 1) / 2 + low,
                        (usize::from(frame_index) + index)
                            % (group.channels * (group.channels - 1) / 2)
                    );
                    for (band, &enabled) in pair.mask.iter().enumerate() {
                        assert_eq!(
                            enabled,
                            (usize::from(frame_index) + index) % 2 == 0
                                || (usize::from(frame_index) + band) % 2 != 0
                        );
                    }
                }
                for _ in 0..group.channels {
                    assert_eq!(frame.bwe_side[channel].is_some(), group.bwe);
                    if let Some(bwe) = &frame.bwe_side[channel] {
                        for (band, &envelope) in bwe.envelopes.iter().enumerate() {
                            assert_eq!(
                                usize::from(envelope),
                                (9 + band * 8 + usize::from(frame_index) * 3) % 128
                            );
                        }
                        for (tile, &level) in bwe.whitening.iter().enumerate() {
                            assert_eq!(
                                usize::from(level),
                                (usize::from(frame_index) + tile + channel) % 3
                            );
                        }
                    }
                    channel += 1;
                }
            }
            for (channel, (core, q)) in frame.cores.iter().zip(&frame.quantized).enumerate() {
                assert_eq!(
                    core.transform,
                    [0, 2, 1, 3][(usize::from(frame_index) + channel) % 4]
                );
                assert!(q.context.iter().chain(&q.base).all(|&v| v == 0));
                assert_eq!(q.context.len(), 2);
                assert_eq!(q.base.len() + q.context.len(), frame.channel_bytes[channel]);
            }
            if frame.config.spatial() {
                assert_eq!(
                    frame.side.basis_indices,
                    [
                        (u16::from(frame_index) * 193) % 1343,
                        (u16::from(frame_index) * 337 + 1342) % 1343
                    ]
                );
            }
            offset += header.frame_bytes();
            total += 1;
            frame_index += 1;
        }
        assert!(words.next().is_none());
        assert_eq!(frame_index, 8);
    }
    assert_eq!(total, 576);
    println!("72 HOA configurations, 576 exact side/allocation/entropy boundaries");
}
