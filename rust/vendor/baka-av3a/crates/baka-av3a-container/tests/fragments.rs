use baka_av3a_container::{Track, playback::TrackDecoder};
use baka_av3a_core::{model::HyperModel, payload_crc, shaping::LsfCodebooks};
use std::sync::Arc;
#[path = "../../baka-av3a-core/tests/fixtures/bed_frame.rs"]
mod bed_frame;
#[path = "../../baka-av3a-core/tests/fixtures/lsf_asset.rs"]
mod lsf_asset;
#[path = "../../baka-av3a-core/tests/fixtures/model_record.rs"]
mod model_record;

fn atom(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
    [
        ((body.len() + 8) as u32).to_be_bytes().as_slice(),
        kind,
        body,
    ]
    .concat()
}
fn words(v: &[u32]) -> Vec<u8> {
    v.iter().flat_map(|v| v.to_be_bytes()).collect()
}
fn packet() -> Vec<u8> {
    let mut bytes = bed_frame::frame(true);
    let crc = payload_crc(&bytes[7..]);
    bytes[3] = (bytes[3] & 0xe0) | (crc >> 11) as u8;
    bytes[4] = (bytes[4] & 0x1f) | (((crc >> 8) as u8 & 7) << 5);
    bytes[6] = crc as u8;
    bytes
}
fn init(packet: &[u8], hybrid: bool, second: bool) -> Vec<u8> {
    let mut entry = vec![0; 28];
    entry[6..8].copy_from_slice(&1u16.to_be_bytes());
    entry[16..18].copy_from_slice(&12u16.to_be_bytes());
    entry[18..20].copy_from_slice(&16u16.to_be_bytes());
    entry[24..28].copy_from_slice(&(44100u32 << 16).to_be_bytes());
    let mut stsd = words(&[0, 1]);
    stsd.extend(atom(b"av3a", &entry));
    let mut stbl = atom(b"stsd", &stsd);
    let count = u32::from(hybrid);
    stbl.extend(atom(
        b"stsz",
        &if hybrid {
            words(&[0, packet.len() as u32, count])
        } else {
            words(&[0, 0, 0])
        },
    ));
    stbl.extend(atom(
        b"stsc",
        &if hybrid {
            words(&[0, 1, 1, 1, 1])
        } else {
            words(&[0, 0])
        },
    ));
    stbl.extend(atom(
        b"stts",
        &if hybrid {
            words(&[0, 1, 1, 1024])
        } else {
            words(&[0, 0])
        },
    ));
    stbl.extend(atom(
        b"stco",
        &if hybrid {
            words(&[0, 1, 8])
        } else {
            words(&[0, 0])
        },
    ));
    let mut mdia = atom(b"hdlr", &[&[0u8; 8][..], b"soun"].concat());
    mdia.extend(atom(b"mdhd", &words(&[0, 0, 0, 44100, 0, 0])));
    mdia.extend(atom(b"minf", &atom(b"stbl", &stbl)));
    let mut trak = atom(b"tkhd", &words(&[0, 0, 0, 1, 0]));
    trak.extend(atom(b"mdia", &mdia));
    let mut moov = atom(b"trak", &trak);
    if second {
        let mut other = atom(b"tkhd", &words(&[0, 0, 0, 2, 0]));
        other.extend(atom(
            b"mdia",
            &atom(b"hdlr", &[&[0u8; 8][..], b"vide"].concat()),
        ));
        moov.extend(atom(b"trak", &other));
    }
    let mut mvex = atom(b"trex", &words(&[0, 1, 1, 1024, packet.len() as u32, 0]));
    if second {
        mvex.extend(atom(b"trex", &words(&[0, 2, 1, 1, 3, 0])));
    }
    moov.extend(atom(b"mvex", &mvex));
    let mut out = if hybrid {
        atom(b"mdat", packet)
    } else {
        Vec::new()
    };
    out.extend(atom(b"moov", &moov));
    out
}
fn fragment(packet: &[u8], file_start: usize, sequence: u32, dts: u64, mode: u8) -> Vec<u8> {
    let mut media = Vec::new();
    if mode == 4 {
        media.extend([1, 2, 3]);
    }
    media.extend(packet);
    media.extend(packet);
    let make = |data_offset: i32, absolute: u64| {
        let mut body = atom(b"mfhd", &words(&[0, sequence]));
        if mode == 4 {
            let mut traf = atom(b"tfhd", &words(&[0x020000, 2]));
            traf.extend(atom(b"tfdt", &words(&[0, 0])));
            traf.extend(atom(b"trun", &words(&[1, 1, data_offset as u32])));
            body.extend(atom(b"traf", &traf));
        }
        let tfhd = if mode == 2 {
            let mut v = words(&[0x3b, 1]);
            v.extend(absolute.to_be_bytes());
            v.extend(words(&[1, 1024, packet.len() as u32, 0]));
            v
        } else {
            words(&[if matches!(mode, 1 | 4) { 0 } else { 0x020000 }, 1])
        };
        let mut traf = atom(b"tfhd", &tfhd);
        if !(mode == 5 && sequence == 2) {
            let mut time = words(&[0x01000000]);
            time.extend(dts.to_be_bytes());
            traf.extend(atom(b"tfdt", &time));
        }
        match mode {
            1 => {
                let mut run = words(&[0x01000f01, 2, data_offset as u32]);
                for _ in 0..2 {
                    run.extend(words(&[1024, packet.len() as u32, 0, 0]));
                }
                traf.extend(atom(b"trun", &run));
            }
            2 | 4 => {
                traf.extend(atom(b"trun", &words(&[0, 1])));
                traf.extend(atom(b"trun", &words(&[0, 1])));
            }
            5 => {
                traf.extend(atom(b"trun", &words(&[1, 1, data_offset as u32])));
                traf.extend(atom(b"trun", &words(&[0, 1])));
            }
            _ => {
                traf.extend(atom(b"trun", &words(&[5, 2, data_offset as u32, 0])));
            }
        }
        body.extend(atom(b"traf", &traf));
        atom(b"moof", &body)
    };
    let size = make(0, 0).len();
    let moof = make(
        if mode == 3 {
            8 - (media.len() + 8) as i32
        } else {
            (size + 8) as i32
        },
        (file_start + size + 8) as u64,
    );
    if mode == 3 {
        [atom(b"mdat", &media), moof].concat()
    } else {
        [moof, atom(b"mdat", &media)].concat()
    }
}
fn fixture(mode: u8, hybrid: bool) -> Vec<u8> {
    let p = packet();
    let mut bytes = init(&p, hybrid, mode == 4);
    let start = if hybrid { 1024 } else { 0 };
    for sequence in 1..=2 {
        let next = fragment(
            &p,
            bytes.len(),
            sequence,
            start + u64::from(sequence - 1) * 2048,
            mode,
        );
        bytes.extend(next);
    }
    bytes
}

#[test]
fn address_defaults_runs_and_initial_samples_decode_identically() {
    let model = Arc::new(HyperModel::parse(&model_record::fixture()).unwrap());
    let lsf = Arc::new(LsfCodebooks::parse(&lsf_asset::asset()).unwrap());
    for mode in 0..6 {
        for hybrid in [false, true] {
            let bytes = fixture(mode, hybrid);
            let track = Track::parse(&bytes).unwrap();
            track.validate_frames().unwrap();
            let n = 4 + usize::from(hybrid);
            assert_eq!(track.packet_count(), n);
            assert_eq!(track.duration_ticks, n as u64 * 1024);
            for (i, p) in track.packets().enumerate() {
                assert_eq!(p.bytes, packet());
                assert_eq!((p.dts, p.duration), (i as u64 * 1024, 1024));
            }
            let mut timed = TrackDecoder::new(track, model.clone(), lsf.clone()).unwrap();
            let mut reference = baka_av3a_core::decoder::Decoder::new(model.clone(), lsf.clone());
            for _ in 0..n {
                assert_eq!(
                    timed.next_frame().unwrap().unwrap().pcm.samples,
                    reference.decode(&packet()).unwrap().samples
                );
            }
            assert!(timed.next_frame().unwrap().is_none());
            let mut reference = baka_av3a_core::decoder::Decoder::new(model.clone(), lsf.clone());
            reference.decode(&packet()).unwrap();
            let second = reference.decode(&packet()).unwrap();
            let seek = timed.seek(1024 + 17).unwrap().unwrap();
            assert_eq!(seek.skipped_samples, 17);
            assert_eq!(seek.pcm.samples, &second.samples[17 * 12..]);
        }
    }
}

#[test]
fn configured_decoder_seed_survives_backward_seek() {
    use baka_av3a_core::decoder::Decoder;
    let model = Arc::new(HyperModel::parse(&model_record::fixture()).unwrap());
    let lsf = Arc::new(LsfCodebooks::parse(&lsf_asset::asset()).unwrap());
    let mut decoder = Decoder::new(model, lsf);
    decoder.reset_with_seed(17);
    let bytes = fixture(0, false);
    let mut reference = decoder.clone();
    let first = reference.decode(&packet()).unwrap();
    assert!(TrackDecoder::from_decoder(Track::parse(&bytes).unwrap(), reference).is_err());
    let mut timed = TrackDecoder::from_decoder(Track::parse(&bytes).unwrap(), decoder).unwrap();
    for _ in 0..4 {
        timed.next_frame().unwrap().unwrap();
    }
    assert_eq!(timed.seek(0).unwrap().unwrap().pcm.samples, first.samples);
}
fn field(bytes: &[u8], kind: &[u8; 4], occurrence: usize) -> usize {
    bytes
        .windows(4)
        .enumerate()
        .filter(|(_, v)| *v == kind)
        .nth(occurrence)
        .unwrap()
        .0
        + 4
}
#[test]
fn malformed_fragment_fields_and_ranges_rejected() {
    let original = fixture(0, false);
    for (kind, occurrence, offset, value) in [
        (b"tfhd", 0, 0, 0x008000u32),
        (b"tfhd", 0, 4, 99),
        (b"trun", 0, 4, 2_000_001),
        (b"trun", 0, 8, u32::MAX / 2),
        (b"mfhd", 1, 4, 1),
        (b"tfdt", 1, 8, 2049),
        (b"trex", 0, 8, 2),
        (b"trex", 0, 4, 99),
        (b"trex", 0, 16, 0),
    ] {
        let mut bad = original.clone();
        let p = field(&bad, kind, occurrence) + offset;
        bad[p..p + 4].copy_from_slice(&value.to_be_bytes());
        assert!(Track::parse(&bad).is_err(), "{kind:?} {offset}");
    }
    let mut cts = fixture(1, false);
    let p = field(&cts, b"trun", 0) + 24;
    cts[p..p + 4].copy_from_slice(&1u32.to_be_bytes());
    assert!(Track::parse(&cts).is_err());
    let mut duplicate = fixture(4, false);
    let p = field(&duplicate, b"tkhd", 1) + 12;
    duplicate[p..p + 4].copy_from_slice(&1u32.to_be_bytes());
    assert!(Track::parse(&duplicate).is_err());
    for length in 0..original.len() {
        if let Ok(track) = Track::parse(&original[..length]) {
            track.validate_frames().unwrap();
            assert_eq!(track.packet_count(), 2);
            for p in track.packets() {
                assert_eq!(p.bytes, packet());
            }
        }
    }
}

#[test]
#[ignore = "requires local independently muxed BMFF files and packet records"]
fn local_independent_fragment_packets() {
    let root = std::path::PathBuf::from(std::env::var_os("BAKA_AV3A_FRAGMENT_NATIVE_DIR").unwrap());
    let mut count = 0;
    for name in [
        "base-moof",
        "absolute",
        "hybrid",
        "dash",
        "multi",
        "separate",
    ] {
        let bytes = std::fs::read(root.join(format!("{name}.mp4"))).unwrap();
        let expected = std::fs::read(root.join(format!("{name}.packets"))).unwrap();
        let track = Track::parse(&bytes).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(expected.len(), track.packet_count() * 36);
        for (packet, record) in track.packets().zip(expected.as_chunks::<36>().0) {
            let word = |p| u64::from_le_bytes(record[p..p + 8].try_into().unwrap());
            let (start, size) = (word(0) as usize, word(8) as usize);
            let duration = u32::from_le_bytes(record[24..28].try_into().unwrap());
            assert_eq!(
                packet.bytes.as_ptr(),
                bytes[start..].as_ptr(),
                "{name} offset"
            );
            assert_eq!(
                (packet.bytes.len(), packet.dts, packet.duration),
                (size, word(16), duration)
            );
            let hash = packet
                .bytes
                .iter()
                .fold(14695981039346656037u64, |hash, &b| {
                    (hash ^ u64::from(b)).wrapping_mul(1099511628211)
                });
            assert_eq!(hash, word(28));
            count += 1;
        }
    }
    assert_eq!(count, 270);
    println!("6 independent BMFF layouts, 270 exact offsets/sizes/timestamps/packet hashes");
}

#[test]
fn progressive_fragments_emit_before_eof_for_arbitrary_chunks() {
    use baka_av3a_container::progressive::Mp4Stream;
    for mode in [0, 1, 2, 4, 5] {
        let bytes = fixture(mode, false);
        for chunk in [1, 7, 16, 61, 2414, 4096, bytes.len()] {
            let mut stream = Mp4Stream::new();
            let mut count = 0;
            for block in bytes.chunks(chunk) {
                stream.push(block).unwrap();
                while let Some(p) = stream.next_packet().unwrap() {
                    assert_eq!(p.bytes, packet());
                    assert_eq!(
                        (p.index, p.dts, p.duration),
                        (count, count as u64 * 1024, 1024)
                    );
                    count += 1;
                }
            }
            assert_eq!(count, 4); // All output is available before finish().
            assert!(!stream.is_finished());
            stream.finish();
            assert!(stream.next_packet().unwrap().is_none());
            assert!(stream.is_finished());
            assert!(stream.push(&[]).is_err());
            assert_eq!(stream.buffered_bytes(), 0);
        }
    }
    let bytes = fixture(0, false);
    let first_end = field(&bytes, b"mdat", 0) + packet().len();
    let mut stream = Mp4Stream::new();
    stream.push(&bytes[..first_end]).unwrap();
    assert_eq!(stream.next_packet().unwrap().unwrap().index, 0);
    assert!(stream.next_packet().unwrap().is_none());
    stream.finish();
    assert!(stream.next_packet().is_err());
    for length in 0..bytes.len() {
        let expected = Track::parse(&bytes[..length])
            .ok()
            .map(|t| t.packet_count());
        let mut stream = Mp4Stream::new();
        stream.push(&bytes[..length]).unwrap();
        stream.finish();
        let mut count = 0;
        let actual = loop {
            match stream.next_packet() {
                Ok(Some(_)) => count += 1,
                Ok(None) => break Some(count),
                Err(_) => break None,
            }
        };
        assert_eq!(actual, expected, "fragment prefix {length}");
    }
}

#[test]
fn progressive_fragment_pcm_and_failed_packet_history() {
    use baka_av3a_container::progressive::Mp4Decoder;
    use baka_av3a_core::decoder::Decoder;
    let model = Arc::new(HyperModel::parse(&model_record::fixture()).unwrap());
    let lsf = Arc::new(LsfCodebooks::parse(&lsf_asset::asset()).unwrap());
    for mode in [0, 1, 2, 4, 5] {
        let bytes = fixture(mode, false);
        let mut decoder = Mp4Decoder::new(Decoder::new(model.clone(), lsf.clone())).unwrap();
        let mut reference = Decoder::new(model.clone(), lsf.clone());
        for block in bytes.chunks(97) {
            decoder.push(block).unwrap();
            while let Some(frame) = decoder.next_frame().unwrap() {
                assert_eq!(
                    frame.pcm.samples,
                    reference.decode(&packet()).unwrap().samples
                );
            }
        }
        assert_eq!(decoder.decoded_frames(), 4);
        decoder.finish();
        assert!(decoder.next_frame().unwrap().is_none());
    }
    let mut bad = fixture(0, false);
    let start = field(&bad, b"mdat", 0);
    let p = &mut bad[start..start + packet().len()];
    p[7..].fill(255);
    let crc = payload_crc(&p[7..]);
    p[3] = (p[3] & 0xe0) | (crc >> 11) as u8;
    p[4] = (p[4] & 0x1f) | (((crc >> 8) as u8 & 7) << 5);
    p[6] = crc as u8;
    let mut decoder = Mp4Decoder::new(Decoder::new(model, lsf)).unwrap();
    decoder.push(&bad).unwrap();
    let error = decoder.next_frame().unwrap_err().to_string();
    assert_eq!(decoder.next_frame().unwrap_err().to_string(), error);
    assert_eq!(decoder.decoded_frames(), 0);
}

#[test]
fn progressive_errors_are_terminal_and_buffers_bounded() {
    use baka_av3a_container::progressive::Mp4Stream;
    let original = fixture(0, false);
    for (kind, occurrence, offset, value) in [
        (b"tfhd", 0, 4, 99u32),
        (b"trun", 0, 4, 2_000_001),
        (b"mfhd", 1, 4, 1),
        (b"tfdt", 1, 8, 2049),
    ] {
        let mut bad = original.clone();
        let p = field(&bad, kind, occurrence) + offset;
        bad[p..p + 4].copy_from_slice(&value.to_be_bytes());
        let mut stream = Mp4Stream::new();
        stream.push(&bad).unwrap();
        let error = loop {
            match stream.next_packet() {
                Ok(Some(_)) => {}
                Ok(None) => panic!("malformed input accepted"),
                Err(e) => break e,
            }
        };
        assert_eq!(stream.next_packet().unwrap_err(), error);
        assert_eq!(stream.push(&[]).unwrap_err(), error);
    }
    for bytes in [fixture(3, false), fixture(0, true)] {
        let mut stream = Mp4Stream::new();
        stream.push(&bytes).unwrap();
        assert!(stream.next_packet().is_err());
    }
    let mut stream = Mp4Stream::new();
    assert!(stream.push(&vec![0; Mp4Stream::MAX_BUFFER + 1]).is_err());
    assert_eq!(stream.buffered_bytes(), 0);
    stream.push(&original).unwrap();
    for _ in 0..4 {
        assert!(stream.next_packet().unwrap().is_some());
    }
    let mut corrupt = original;
    let p = field(&corrupt, b"mdat", 0) + 100;
    corrupt[p] ^= 1;
    let mut stream = Mp4Stream::new();
    stream.push(&corrupt).unwrap();
    assert_eq!(
        stream.next_packet().unwrap_err().0,
        "invalid AV3A packet/CRC"
    );
    assert_eq!(stream.emitted_packets(), 0);
}

#[test]
fn sparse_index_handles_backward_and_hybrid_fragments() {
    use baka_av3a_container::range::RangeProbe;
    for mode in 0..6 {
        for hybrid in [false, true] {
            let bytes = fixture(mode, hybrid);
            let reference = Track::parse(&bytes).unwrap();
            let mut probe = RangeProbe::new(bytes.len()).unwrap();
            while let Some(r) = probe.next_request().unwrap() {
                probe.accept(&r, &bytes[r.bytes.clone()]).unwrap();
            }
            let track = probe.into_track().unwrap();
            assert_eq!(track.packet_count(), reference.packet_count());
            for p in reference.packets() {
                let r = track.packet_range(p.index).unwrap();
                assert_eq!(&bytes[r], p.bytes);
                let actual = track.validate_packet(p.index, p.bytes).unwrap();
                assert_eq!((actual.dts, actual.duration), (p.dts, p.duration));
            }
        }
    }
}
