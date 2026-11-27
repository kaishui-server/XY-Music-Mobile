use baka_av3a_container::{
    Track,
    range::{
        RangeProbe, RangeTrack,
        playback::{DecodeStep, RangeDecoder},
    },
};
use baka_av3a_core::{decoder::Decoder, model::HyperModel, shaping::LsfCodebooks};
use std::sync::Arc;
#[path = "fixtures/range_file.rs"]
mod fixture;
#[path = "../../baka-av3a-core/tests/fixtures/lsf_asset.rs"]
mod lsf_asset;
#[path = "../../baka-av3a-core/tests/fixtures/model_record.rs"]
mod model_record;

fn index(bytes: &[u8]) -> (RangeTrack, usize) {
    let mut probe = RangeProbe::new(bytes.len()).unwrap();
    let mut fetched = 0;
    while let Some(request) = probe.next_request().unwrap() {
        assert_eq!(probe.next_request().unwrap(), Some(request.clone()));
        let body = &bytes[request.bytes.clone()];
        assert!(probe.accept(&request, &body[..body.len() - 1]).is_err());
        probe.accept(&request, body).unwrap();
        assert!(probe.accept(&request, body).is_err());
        fetched += body.len();
    }
    (probe.into_track().unwrap(), fetched)
}
fn decoder() -> Decoder {
    Decoder::new(
        Arc::new(HyperModel::parse(&model_record::fixture()).unwrap()),
        Arc::new(LsfCodebooks::parse(&lsf_asset::asset()).unwrap()),
    )
}
fn next(decoder: &mut RangeDecoder, bytes: &[u8]) -> baka_av3a_container::playback::TimedPcm {
    loop {
        match decoder.next_frame().unwrap() {
            DecodeStep::NeedInput => {
                let request = decoder.next_request().unwrap();
                decoder
                    .accept(&request, &bytes[request.bytes.clone()])
                    .unwrap();
            }
            DecodeStep::Preroll { .. } => {}
            DecodeStep::Frame(pcm) => return pcm,
            DecodeStep::Finished => panic!("unexpected EOF"),
        }
    }
}

#[test]
fn sparse_front_tail_and_wide_offsets_match_full_parser() {
    for front in [false, true] {
        for wide in [false, true] {
            let bytes = fixture::file(front, wide, 200_000);
            let (index, fetched) = index(&bytes);
            assert!(fetched < 70_000 && fetched < bytes.len() / 2);
            let track = Track::parse(&bytes).unwrap();
            assert_eq!(index.packet_count(), track.packet_count());
            assert_eq!(index.duration_ticks(), track.duration_ticks);
            assert_eq!(index.packet_index_at(1024), 1);
            for p in track.packets() {
                let range = index.packet_range(p.index).unwrap();
                assert_eq!(p.bytes, &bytes[range]);
                let actual = index.validate_packet(p.index, p.bytes).unwrap();
                assert_eq!((actual.dts, actual.duration), (p.dts, p.duration));
                assert!(
                    index
                        .validate_packet(p.index, &p.bytes[..p.bytes.len() - 1])
                        .is_err()
                );
            }
            let mut reader = RangeDecoder::new(index, decoder()).unwrap();
            let mut expected = decoder();
            let request = reader.next_request().unwrap();
            assert_eq!(request.bytes.len(), 4 * 2415); // One batch, four frames.
            reader
                .accept(&request, &bytes[request.bytes.clone()])
                .unwrap();
            for p in track.packets() {
                let frame = next(&mut reader, &bytes);
                assert_eq!(frame.pcm.samples, expected.decode(p.bytes).unwrap().samples);
                assert!(reader.next_request().is_none());
            }
            assert!(matches!(reader.next_frame().unwrap(), DecodeStep::Finished));
        }
    }
}

#[test]
fn cached_prefix_can_decode_without_another_request() {
    let mut bytes = fixture::file(true, false, 0);
    let mdat = u32::from_be_bytes(bytes[..4].try_into().unwrap()) as usize;
    bytes[mdat..mdat + 4].fill(0); // A known file length resolves an open-ended mdat.
    let (index, fetched) = index(&bytes);
    assert_eq!(fetched, bytes.len());
    let mut reader = RangeDecoder::new(index, decoder()).unwrap();
    assert!(reader.next_request().is_none());
    assert!(matches!(reader.next_frame().unwrap(), DecodeStep::Frame(_)));
}

#[test]
fn seek_replay_trim_cancel_and_stale_responses() {
    let bytes = fixture::file(false, false, 200_000);
    let (index, _) = index(&bytes);
    let mut reader = RangeDecoder::new(index, decoder()).unwrap();
    let old_request = reader.next_request().unwrap();
    reader.begin_seek(2 * 1024 + 17).unwrap();
    assert_eq!(reader.next_packet_index(), 0);
    assert!(
        reader
            .accept(&old_request, &bytes[old_request.bytes.clone()])
            .is_err()
    );
    let request = reader.next_request().unwrap();
    reader
        .accept(&request, &bytes[request.bytes.clone()])
        .unwrap();
    assert!(matches!(
        reader.next_frame().unwrap(),
        DecodeStep::Preroll { packet_index: 0 }
    ));
    assert!(reader.cancel_seek().unwrap());
    assert_eq!(reader.next_packet_index(), 0);
    let first = next(&mut reader, &bytes);
    assert_eq!(first.packet_index, 0);
    reader.begin_seek(2 * 1024 + 17).unwrap();
    let seek = next(&mut reader, &bytes);
    assert_eq!((seek.packet_index, seek.skipped_samples), (2, 17));
    let track = Track::parse(&bytes).unwrap();
    let mut expected = decoder();
    expected.decode(track.packet(0).unwrap().bytes).unwrap();
    expected.decode(track.packet(1).unwrap().bytes).unwrap();
    assert_eq!(
        seek.pcm.samples,
        &expected
            .decode(track.packet(2).unwrap().bytes)
            .unwrap()
            .samples[17 * 12..]
    );
    reader.begin_seek(0).unwrap();
    assert_eq!(next(&mut reader, &bytes).pcm.samples, first.pcm.samples);
    reader.begin_seek(u64::MAX).unwrap();
    assert!(matches!(reader.next_frame().unwrap(), DecodeStep::Finished));
    reader.begin_seek(1024).unwrap();
    assert_eq!(next(&mut reader, &bytes).packet_index, 1);
}

#[test]
fn malformed_metadata_range_and_crc_do_not_advance_playback() {
    assert!(RangeProbe::new(0).is_err());
    assert!(RangeProbe::new(512 * 1024 * 1024 + 1).is_err());
    for bytes in [vec![0; 7], fixture::atom(b"moof", &[])] {
        let mut probe = RangeProbe::new(bytes.len()).unwrap();
        let error = loop {
            match probe.next_request() {
                Ok(Some(r)) => probe.accept(&r, &bytes[r.bytes.clone()]).unwrap(),
                Ok(None) => panic!("malformed index accepted"),
                Err(e) => break e,
            }
        };
        assert_eq!(probe.next_request().unwrap_err(), error);
    }
    let bytes = fixture::file(false, false, 200_000);
    let (index, _) = index(&bytes);
    let mut reader = RangeDecoder::new(index, decoder()).unwrap();
    let request = reader.next_request().unwrap();
    let mut body = bytes[request.bytes.clone()].to_vec();
    body[100] ^= 1;
    assert!(reader.accept(&request, &body[..body.len() - 1]).is_err());
    assert_eq!(reader.next_request(), Some(request.clone()));
    reader.accept(&request, &body).unwrap();
    let error = reader.next_frame().unwrap_err().to_string();
    assert_eq!(reader.next_frame().unwrap_err().to_string(), error);
    assert_eq!(reader.next_packet_index(), 0);
    // Cancellation invalidates old responses without changing committed history.
    reader.begin_seek(0).unwrap();
    reader.cancel_seek().unwrap();
    reader.clear_cache().unwrap();
    let retried = reader.next_request().unwrap();
    assert_ne!(retried.id, request.id);
    reader
        .accept(&retried, &bytes[retried.bytes.clone()])
        .unwrap();
    assert_eq!(next(&mut reader, &bytes).packet_index, 0);
    assert!(
        reader
            .accept(&request, &bytes[request.bytes.clone()])
            .is_err()
    );
}

#[test]
fn truncated_metadata_and_huge_boxes_are_rejected_before_allocation() {
    let bytes = fixture::file(false, true, 0);
    for length in 1..bytes.len() {
        let mut probe = RangeProbe::new(length).unwrap();
        loop {
            match probe.next_request() {
                Ok(Some(r)) => probe.accept(&r, &bytes[r.bytes.clone()]).unwrap(),
                Ok(None) => panic!("truncated index accepted at {length}"),
                Err(_) => break,
            }
        }
    }
    let mut probe = RangeProbe::new(10 * 1024 * 1024).unwrap();
    let r = probe.next_request().unwrap().unwrap();
    let mut bytes = vec![0; r.bytes.len()];
    bytes[..4].copy_from_slice(&(9u32 * 1024 * 1024).to_be_bytes());
    bytes[4..8].copy_from_slice(b"moov");
    probe.accept(&r, &bytes).unwrap();
    assert_eq!(
        probe.next_request().unwrap_err().0,
        "range metadata byte limit"
    );
    for size in [0u64, 7, u64::MAX] {
        let mut bytes = vec![0; 16];
        bytes[..4].copy_from_slice(&1u32.to_be_bytes());
        bytes[4..8].copy_from_slice(b"free");
        bytes[8..].copy_from_slice(&size.to_be_bytes());
        let mut probe = RangeProbe::new(16).unwrap();
        let r = probe.next_request().unwrap().unwrap();
        probe.accept(&r, &bytes).unwrap();
        assert!(probe.next_request().is_err());
    }
}
