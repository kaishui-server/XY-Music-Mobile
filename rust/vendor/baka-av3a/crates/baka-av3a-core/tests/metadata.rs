use baka_av3a_core::{
    BitReader, Error, FrameHeader, Profile,
    metadata::{ChannelLock, DynamicMetadata, FrameMetadata, ObjectPosition},
};

fn header() -> FrameHeader {
    FrameHeader {
        profile: Profile::Objects { count: 1 },
        neural_type: 0,
        sample_rate: 48000,
        channels: 1,
        bit_depth: 16,
        bitrate: 16000,
        bed_bitrate: None,
        crc: 0,
        header_bytes: 8,
        payload_bits: 1,
    }
}
fn integer(bytes: &mut Vec<u8>, value: impl Into<u32>) {
    bytes.extend_from_slice(&value.into().to_le_bytes());
}
fn float(bytes: &mut Vec<u8>, value: f32) {
    bytes.extend_from_slice(&value.to_le_bytes());
}
fn canonical(data: &DynamicMetadata) -> Vec<u8> {
    let mut bytes = Vec::new();
    integer(&mut bytes, data.level);
    let object = &data.objects[0];
    integer(&mut bytes, object.parameters.is_none());
    integer(&mut bytes, object.transport_channel);
    if let Some(p) = &object.parameters {
        integer(
            &mut bytes,
            matches!(p.position, ObjectPosition::Cartesian(_)),
        );
        for present in [
            p.extent.is_some(),
            p.gain.is_some(),
            p.diffuse.is_some(),
            p.importance.is_some(),
        ] {
            integer(&mut bytes, present);
        }
        for value in p.position.coordinates() {
            float(&mut bytes, value);
        }
        if let Some(values) = p.extent_values() {
            for value in values {
                float(&mut bytes, value);
            }
        }
        if let Some(value) = p.linear_gain() {
            float(&mut bytes, value);
        }
        if let Some(value) = p.diffuseness() {
            float(&mut bytes, value);
        }
        integer(&mut bytes, p.jump_position);
        if let Some(value) = p.importance {
            integer(&mut bytes, value);
        }
        if let Some(c) = &p.controls {
            integer(&mut bytes, c.channel_lock.is_some());
            if let Some(lock) = &c.channel_lock {
                integer(&mut bytes, matches!(lock, ChannelLock::Within(_)));
                if let Some(value) = lock.maximum_distance() {
                    float(&mut bytes, value);
                }
            }
            integer(&mut bytes, c.divergence.is_some());
            if let Some(divergence) = &c.divergence {
                float(&mut bytes, divergence.amount());
                if let Some(value) = divergence.azimuth_degrees() {
                    float(&mut bytes, value);
                }
            }
            integer(&mut bytes, c.screen_reference.is_some());
            if let Some(value) = c.screen_reference {
                integer(&mut bytes, value);
            }
            integer(&mut bytes, c.screen_edge_lock.is_some());
            if let Some(value) = c.screen_edge_lock {
                integer(&mut bytes, value);
            }
        }
    }
    bytes
}

#[test]
fn independent_dynamic_metadata_vectors_and_all_prefixes() {
    let fixture = include_bytes!("fixtures/dynamic_metadata.bin");
    assert_eq!(&fixture[..8], b"MDYN0001");
    let integer =
        |offset| u32::from_le_bytes(fixture[offset..offset + 4].try_into().unwrap()) as usize;
    assert_eq!(integer(8), 1058);
    let mut position = 12;
    for case in 0..1058 {
        let bits = integer(position);
        position += 4;
        let bytes = &fixture[position..position + bits.div_ceil(8)];
        position += bytes.len();
        let length = integer(position);
        position += 4;
        let expected = &fixture[position..position + length];
        position += length;
        let mut reader = BitReader::with_bit_len(bytes, bits).unwrap();
        let parsed = FrameMetadata::parse(&mut reader, &header()).unwrap();
        assert_eq!(reader.position(), bits);
        assert_eq!(
            canonical(parsed.dynamic.as_deref().unwrap()),
            expected,
            "case {case}"
        );
        for prefix in 0..bits {
            let mut reader = BitReader::with_bit_len(bytes, prefix).unwrap();
            assert_eq!(
                FrameMetadata::parse(&mut reader, &header()),
                Err(Error::Truncated),
                "case {case} prefix {prefix}"
            );
            assert_eq!(reader.position(), 0);
        }
    }
    assert_eq!(position, fixture.len());
}

#[test]
fn unsupported_levels_and_counts_preserve_cursor() {
    for level in 2..8 {
        let bytes = [0x40 | (level << 3)];
        let mut reader = BitReader::new(&bytes);
        assert_eq!(
            FrameMetadata::parse(&mut reader, &header()),
            Err(Error::Unsupported("dynamic metadata level"))
        );
        assert_eq!(reader.position(), 0);
    }
    let mut reader = BitReader::new(&[0]);
    assert_eq!(
        DynamicMetadata::parse(&mut reader, 17),
        Err(Error::Unsupported("dynamic metadata object count"))
    );
    assert_eq!(reader.position(), 0);
}

#[test]
fn empty_object_blocks_and_random_inputs_are_bounded() {
    for profile in [
        Profile::ChannelBed { configuration: 0 },
        Profile::Hoa { order: 1 },
    ] {
        let mut header = header();
        header.profile = profile;
        for level in [0, 1] {
            let bytes = [0x40 | (level << 3)];
            let mut reader = BitReader::new(&bytes);
            let block = FrameMetadata::parse(&mut reader, &header).unwrap();
            assert_eq!(reader.position(), 5);
            assert_eq!(block.dynamic.as_ref().unwrap().level, level);
            assert!(block.dynamic.unwrap().objects.is_empty());
        }
    }
    let mut seed = 1u32;
    for count in 0..=16 {
        for _ in 0..128 {
            let mut bytes = [0u8; 128];
            for byte in &mut bytes {
                seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
                *byte = (seed >> 24) as u8;
            }
            let mut reader = BitReader::new(&bytes);
            let result = DynamicMetadata::parse(&mut reader, count);
            match result {
                Ok(value) => assert_eq!(value.objects.len(), count),
                Err(_) => assert_eq!(reader.position(), 0),
            }
        }
    }
}
