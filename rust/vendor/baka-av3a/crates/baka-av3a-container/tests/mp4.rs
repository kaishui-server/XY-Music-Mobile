use baka_av3a_container::Track;
#[path = "../../baka-av3a-core/tests/fixtures/bed_frame.rs"]
mod bed_frame;
#[path = "../../baka-av3a-core/tests/fixtures/lsf_asset.rs"]
mod lsf_asset;
#[path = "../../baka-av3a-core/tests/fixtures/model_record.rs"]
mod model_record;

fn atom(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
    let mut b = ((body.len() + 8) as u32).to_be_bytes().to_vec();
    b.extend(kind);
    b.extend(body);
    b
}
fn words(values: &[u32]) -> Vec<u8> {
    values.iter().flat_map(|n| n.to_be_bytes()).collect()
}
fn fixture(wide: bool, variable: bool) -> Vec<u8> {
    let mut entry = vec![0; 28];
    entry[6..8].copy_from_slice(&1u16.to_be_bytes());
    entry[16..18].copy_from_slice(&12u16.to_be_bytes());
    entry[18..20].copy_from_slice(&16u16.to_be_bytes());
    entry[24..28].copy_from_slice(&(44100u32 << 16).to_be_bytes());
    let mut stsd = words(&[0, 1]);
    stsd.extend(atom(b"av3a", &entry));
    let stsz = if variable {
        words(&[0, 0, 2, 2415, 2415])
    } else {
        words(&[0, 2415, 2])
    };
    let offsets = if wide {
        words(&[0, 1, 0, 8])
    } else {
        words(&[0, 1, 8])
    };
    let mut stbl = atom(b"stsd", &stsd);
    stbl.extend(atom(b"stsz", &stsz));
    stbl.extend(atom(if wide { b"co64" } else { b"stco" }, &offsets));
    stbl.extend(atom(b"stsc", &words(&[0, 1, 1, 2, 1])));
    stbl.extend(atom(b"stts", &words(&[0, 1, 2, 1024])));
    let mut mdia = atom(b"hdlr", &[&[0u8; 8][..], b"soun"].concat());
    mdia.extend(atom(b"mdhd", &words(&[0, 0, 0, 44100, 2048, 0])));
    mdia.extend(atom(b"minf", &atom(b"stbl", &stbl)));
    let mut packet = vec![0; 2415];
    let fields = [
        (0xfffu32, 12),
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
    ];
    let mut pos = 0;
    for (value, width) in fields {
        for bit in (0..width).rev() {
            packet[pos / 8] |= (((value >> bit) & 1) as u8) << (7 - pos % 8);
            pos += 1;
        }
    }
    let mut data = atom(b"mdat", &[&packet[..], &packet[..]].concat());
    data.extend(atom(b"moov", &atom(b"trak", &atom(b"mdia", &mdia))));
    data
}

fn front_fixture(wide: bool) -> Vec<u8> {
    let original = fixture(wide, true);
    let mdat_size = u32::from_be_bytes(original[..4].try_into().unwrap()) as usize;
    let mut moov = original[mdat_size..].to_vec();
    let kind = if wide { b"co64" } else { b"stco" };
    let position = moov.windows(4).position(|v| v == kind).unwrap() + 12;
    let offset = moov.len() + 8;
    if wide {
        moov[position..position + 8].copy_from_slice(&(offset as u64).to_be_bytes());
    } else {
        moov[position..position + 4].copy_from_slice(&(offset as u32).to_be_bytes());
    }
    let mut p = bed_frame::frame(true);
    let crc = baka_av3a_core::payload_crc(&p[7..]);
    p[3] = (p[3] & 0xe0) | (crc >> 11) as u8;
    p[4] = (p[4] & 0x1f) | (((crc >> 8) as u8 & 7) << 5);
    p[6] = crc as u8;
    moov.extend(atom(b"mdat", &[p.as_slice(), p.as_slice()].concat()));
    moov
}

#[test]
fn progressive_ordinary_packets_and_pcm_before_eof() {
    use baka_av3a_container::progressive::{Mp4Decoder, Mp4Stream};
    use baka_av3a_core::{decoder::Decoder, model::HyperModel, shaping::LsfCodebooks};
    use std::sync::Arc;
    let model = Arc::new(HyperModel::parse(&model_record::fixture()).unwrap());
    let lsf = Arc::new(LsfCodebooks::parse(&lsf_asset::asset()).unwrap());
    for wide in [false, true] {
        let bytes = front_fixture(wide);
        let track = Track::parse(&bytes).unwrap();
        for chunk in [1, 7, 16, 97, 2415, bytes.len()] {
            let mut stream = Mp4Stream::new();
            let mut index = 0;
            for block in bytes.chunks(chunk) {
                stream.push(block).unwrap();
                while let Some(packet) = stream.next_packet().unwrap() {
                    let p = track.packet(index).unwrap();
                    assert_eq!(packet.bytes, p.bytes);
                    assert_eq!(
                        (packet.index, packet.dts, packet.duration),
                        (index, p.dts, p.duration)
                    );
                    index += 1;
                }
            }
            assert_eq!(index, 2);
            stream.finish();
            assert!(stream.next_packet().unwrap().is_none());
        }
        let mut stream = Mp4Decoder::new(Decoder::new(model.clone(), lsf.clone())).unwrap();
        let mut reference = Decoder::new(model.clone(), lsf.clone());
        let mut index = 0;
        for block in bytes.chunks(109) {
            stream.push(block).unwrap();
            while let Some(pcm) = stream.next_frame().unwrap() {
                assert_eq!(
                    pcm.pcm.samples,
                    reference
                        .decode(track.packet(index).unwrap().bytes)
                        .unwrap()
                        .samples
                );
                index += 1;
            }
        }
        assert_eq!(index, 2);
        stream.finish();
        assert!(stream.next_frame().unwrap().is_none());
    }
}

#[test]
fn progressive_ordinary_prefixes_and_bad_ranges_fail_at_eof() {
    use baka_av3a_container::progressive::Mp4Stream;
    let original = front_fixture(false);
    for length in 0..original.len() {
        let mut stream = Mp4Stream::new();
        stream.push(&original[..length]).unwrap();
        stream.finish();
        loop {
            match stream.next_packet() {
                Ok(Some(_)) => {}
                Ok(None) => panic!("truncation accepted at {length}"),
                Err(_) => break,
            }
        }
    }
    let mut bad = original.clone();
    let stco = bad.windows(4).position(|w| w == b"stco").unwrap();
    bad[stco + 12..stco + 16].copy_from_slice(&8u32.to_be_bytes());
    let mut stream = Mp4Stream::new();
    stream.push(&bad).unwrap();
    assert!(stream.next_packet().is_err());
    let mut stream = Mp4Stream::new();
    stream.push(&fixture(false, false)).unwrap();
    assert!(stream.next_packet().is_err());
    for (length, kind) in [
        (0u32, b"mdat"),
        (7, b"free"),
        ((Mp4Stream::MAX_BUFFER + 1) as u32, b"moov"),
    ] {
        let mut stream = Mp4Stream::new();
        stream
            .push(&[length.to_be_bytes().as_slice(), kind].concat())
            .unwrap();
        assert!(stream.next_packet().is_err());
    }
}

#[test]
fn progressive_extended_box_headers() {
    use baka_av3a_container::progressive::Mp4Stream;
    let original = front_fixture(false);
    let size = u32::from_be_bytes(original[..4].try_into().unwrap()) as usize;
    let mut moov = original[8..size].to_vec();
    let stco = moov.windows(4).position(|v| v == b"stco").unwrap() + 12;
    let offset = u32::from_be_bytes(moov[stco..stco + 4].try_into().unwrap()) + 16;
    moov[stco..stco + 4].copy_from_slice(&offset.to_be_bytes());
    let mut bytes = [
        1u32.to_be_bytes().as_slice(),
        b"moov",
        &((size + 8) as u64).to_be_bytes(),
        &moov,
    ]
    .concat();
    bytes.extend(
        [
            1u32.to_be_bytes().as_slice(),
            b"mdat",
            &((original.len() - size + 8) as u64).to_be_bytes(),
            &original[size + 8..],
        ]
        .concat(),
    );
    let reference = Track::parse(&bytes).unwrap();
    let mut stream = Mp4Stream::new();
    let mut count = 0;
    for b in &bytes {
        stream.push(std::slice::from_ref(b)).unwrap();
        while let Some(p) = stream.next_packet().unwrap() {
            assert_eq!(p.bytes, reference.packet(count).unwrap().bytes);
            count += 1;
        }
    }
    stream.finish();
    assert!(stream.next_packet().unwrap().is_none());
    assert_eq!(count, 2);
}

#[test]
fn both_offsets_and_size_tables() {
    for wide in [false, true] {
        for variable in [false, true] {
            let data = fixture(wide, variable);
            let t = Track::parse(&data).unwrap();
            assert_eq!(t.packet_count(), 2);
            assert_eq!(t.validate_frames().unwrap().channels, 12);
            assert_eq!(t.packet_at(0).index, 0);
            assert_eq!(t.packet_at(1024).index, 1);
            assert_eq!(t.packet_at(u64::MAX).index, 1);
            assert!(t.packet(2).is_none());
        }
    }
}

#[test]
fn truncation_and_bad_offsets_rejected() {
    let original = fixture(false, false);
    for n in 0..original.len() {
        assert!(Track::parse(&original[..n]).is_err(), "prefix {n}");
    }
    let mut bad = original.clone();
    let stco = bad.windows(4).position(|w| w == b"stco").unwrap();
    bad[stco + 12..stco + 16].copy_from_slice(&u32::MAX.to_be_bytes());
    assert!(Track::parse(&bad).is_err());
    let mut bad = original;
    bad[8] = 0;
    assert!(Track::parse(&bad).unwrap().validate_frames().is_err());
}

#[test]
fn extended_size_and_empty_fragment_rejection() {
    let data = fixture(true, true);
    let mut extended = 1u32.to_be_bytes().to_vec();
    extended.extend(b"free");
    extended.extend(16u64.to_be_bytes());
    // Put an extended-size box after all absolute media offsets.
    let mut valid = data.clone();
    valid.extend(&extended);
    assert!(Track::parse(&valid).is_ok());
    let mut fragmented = data;
    fragmented.extend(atom(b"moof", &[]));
    assert!(Track::parse(&fragmented).is_err());
    extended[8..16].copy_from_slice(&u64::MAX.to_be_bytes());
    assert!(Track::parse(&extended).is_err());
}

#[test]
fn playback_seek_trims_exactly_and_cancellation_rolls_back() {
    use baka_av3a_container::playback::{Error, TrackDecoder};
    use baka_av3a_core::{model::HyperModel, payload_crc, shaping::LsfCodebooks};
    use std::sync::Arc;
    let mut data = fixture(false, false);
    let mut packet = bed_frame::frame(true);
    let crc = payload_crc(&packet[7..]);
    packet[3] = (packet[3] & 0xe0) | (crc >> 11) as u8;
    packet[4] = (packet[4] & 0x1f) | (((crc >> 8) as u8 & 7) << 5);
    packet[6] = crc as u8;
    for bytes in data[8..8 + packet.len() * 2].chunks_exact_mut(packet.len()) {
        bytes.copy_from_slice(&packet);
    }
    let mut player = TrackDecoder::new(
        Track::parse(&data).unwrap(),
        Arc::new(HyperModel::parse(&model_record::fixture()).unwrap()),
        Arc::new(LsfCodebooks::parse(&lsf_asset::asset()).unwrap()),
    )
    .unwrap();
    let first = player.next_frame().unwrap().unwrap();
    let second = player.next_frame().unwrap().unwrap();
    assert!(player.next_frame().unwrap().is_none());
    let seek = player.seek(1024 + 513).unwrap().unwrap();
    assert_eq!((seek.packet_index, seek.skipped_samples), (1, 513));
    assert_eq!(seek.pcm.samples, second.pcm.samples[513 * 12..]);
    assert_eq!(
        player.seek(0).unwrap().unwrap().pcm.samples,
        first.pcm.samples
    );
    let mut calls = 0;
    assert!(matches!(
        player.seek_with_cancel(1536, || {
            calls += 1;
            calls == 3
        }),
        Err(Error::Cancelled)
    ));
    assert_eq!(player.next_packet_index(), 1);
    assert_eq!(
        player.next_frame().unwrap().unwrap().pcm.samples,
        second.pcm.samples
    );
    assert!(player.seek(u64::MAX).unwrap().is_none());
    assert!(player.next_frame().unwrap().is_none());
    assert_eq!(
        player.seek(1024).unwrap().unwrap().pcm.samples,
        second.pcm.samples
    );
}

#[test]
#[ignore = "requires BAKA_AV3A_SAMPLE_DIR pointing to local media"]
fn local_corpus() {
    let root = std::env::var_os("BAKA_AV3A_SAMPLE_DIR").expect("BAKA_AV3A_SAMPLE_DIR");
    let oracle = std::env::var_os("BAKA_AV3A_ORACLE_DIR");
    for id in [
        "3383921500",
        "3397415408",
        "3438952240",
        "3440171245",
        "139774",
        "347230",
    ] {
        let data = std::fs::read(std::path::Path::new(&root).join(format!("{id}.mp4"))).unwrap();
        let t = Track::parse(&data).unwrap();
        let h = t.validate_frames().unwrap();
        let expected: Option<Vec<String>> = oracle.as_ref().map(|dir| {
            std::fs::read_to_string(std::path::Path::new(dir).join(format!("{id}-side.txt")))
                .unwrap()
                .lines()
                .map(str::to_owned)
                .collect()
        });
        if let Some(lines) = &expected {
            assert_eq!(lines.len(), t.packet_count());
        }
        assert_eq!((h.sample_rate, h.channels, h.bitrate), (44100, 12, 832000));
        for packet in t.packets() {
            let parsed = baka_av3a_core::side::ChannelBedFrame::parse(packet.bytes)
                .unwrap_or_else(|e| panic!("{id} packet {}: {e}", packet.index));
            assert_eq!(parsed.quantized.len(), 12);
            assert!(parsed.unused_bits < 8);
            if let Some(lines) = &expected {
                let expected_hash = lines[packet.index].split_whitespace().last().unwrap();
                assert_eq!(
                    format!("{:016x}", side_digest(&parsed)),
                    expected_hash,
                    "{id} packet {}",
                    packet.index
                );
            }
        }
        println!(
            "{id}: {} frames, {} ticks / {}",
            t.packet_count(),
            t.duration_ticks,
            t.timescale
        );
    }
}

// Canonical little-endian u32 stream for comparison with an external local oracle.
fn side_digest(frame: &baka_av3a_core::side::ChannelBedFrame) -> u64 {
    let mut hash = 14695981039346656037u64;
    let mut add = |value: u32| {
        for byte in value.to_le_bytes() {
            hash = (hash ^ u64::from(byte)).wrapping_mul(1099511628211);
        }
    };
    for core in &frame.cores {
        add(u32::from(core.transform));
        for &v in &core.lsf_indices {
            add(u32::from(v));
        }
        for filter in &core.tns {
            add(filter.len() as u32);
            for &v in filter {
                add(i32::from(v) as u32);
            }
        }
    }
    for group in &frame.groups {
        add(u32::from(group.count));
        for &v in &group.indicators {
            add(u32::from(v));
        }
    }
    for &v in &frame.mc_mode().unwrap().silent {
        add(u32::from(v));
    }
    add(frame.mc_mode().unwrap().pairs.len() as u32);
    let mut energies = vec![30; frame.cores.len()];
    for pair in &frame.mc_mode().unwrap().pairs {
        for &v in &pair.channels {
            add(v as u32);
        }
        for i in 0..2 {
            energies[pair.channels[i]] = u32::from(pair.energy_indices[i]);
        }
    }
    for value in energies {
        add(value);
    }
    add(frame.side_bits as u32);
    for &bytes in &frame.channel_bytes {
        add(bytes as u32);
    }
    for q in &frame.quantized {
        add(u32::from(q.amplified));
        add(u32::from(q.scale_index));
        for &v in &q.noise_indices {
            add(u32::from(v));
        }
        add(q.context.len() as u32);
        for &v in &q.context {
            add(u32::from(v));
        }
        add(q.base.len() as u32);
        for &v in &q.base {
            add(u32::from(v));
        }
    }
    add(frame.unused_bits as u32);
    hash
}
