use baka_av3a_container::range::{
    RangeProbe, RangeTrack,
    playback::{DecodeStep, RangeDecoder},
};
use baka_av3a_core::{
    decoder::Decoder, hoa::HoaBasis, mcr::McrCodebooks, model::HyperModel, shaping::LsfCodebooks,
};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};

fn index(data: &[u8]) -> (RangeTrack, usize, usize) {
    let mut probe = RangeProbe::new(data.len()).unwrap();
    let mut fetched = 0;
    let mut requests = 0;
    while let Some(r) = probe.next_request().unwrap() {
        probe.accept(&r, &data[r.bytes.clone()]).unwrap();
        fetched += r.bytes.len();
        requests += 1;
    }
    (probe.into_track().unwrap(), requests, fetched)
}

#[test]
#[ignore = "requires local real media, optional assets, relocated moov and independent PCM records"]
fn local_sparse_pcm_and_seek() {
    let root = PathBuf::from(std::env::var_os("BAKA_AV3A_ORACLE_DIR").unwrap());
    let media = PathBuf::from(std::env::var_os("BAKA_AV3A_SAMPLE_DIR").unwrap());
    let model =
        Arc::new(HyperModel::parse(&std::fs::read(root.join("model.bin")).unwrap()).unwrap());
    let lsf = Arc::new(LsfCodebooks::parse(&std::fs::read(root.join("lsf.bin")).unwrap()).unwrap());
    let mcr = Arc::new(McrCodebooks::parse(&std::fs::read(root.join("mcr.bin")).unwrap()).unwrap());
    let hoa = Arc::new(HoaBasis::parse(&std::fs::read(root.join("hoa.bin")).unwrap()).unwrap());
    let mut cases = vec![
        (
            media.join("3440171245.mp4"),
            root.join("3440171245-prefix.pcm"),
        ),
        (
            root.join("range-tail.mp4"),
            root.join("3440171245-prefix.pcm"),
        ),
    ];
    for (name, oracle) in [
        ("3440171245", "3440171245-prefix.pcm"),
        ("bed-0-16000-nn0", "mode-matrix/bed-0-16000-nn0.pcm"),
        ("bed-1-24000-nn0", "mode-matrix/bed-1-24000-nn0.pcm"),
        ("bed-10-240000-nn1", "mode-matrix/bed-10-240000-nn1.pcm"),
        (
            "hoa-3-256000-48000-nn0",
            "hoa-matrix/hoa-3-256000-48000-nn0.pcm",
        ),
        (
            "mix--1-0-16-8-48000-nn0",
            "static-matrix/mix--1-0-16-8-48000-nn0.pcm",
        ),
    ] {
        for suffix in ["fragments", "hybrid"] {
            cases.push((
                root.join(format!("fragment-pcm/{name}-{suffix}.mp4")),
                root.join(oracle),
            ));
        }
    }
    let mut total_samples = 0;
    for (file, oracle) in cases {
        let bytes = std::fs::read(&file).unwrap();
        let expected = std::fs::read(oracle).unwrap();
        let (track, mut requests, mut fetched) = index(&bytes);
        let channels = usize::from(track.info().channels);
        let record = channels * 1024 * 2;
        let mut reader = RangeDecoder::new(
            track,
            Decoder::new(model.clone(), lsf.clone())
                .with_mcr(mcr.clone())
                .with_hoa(hoa.clone()),
        )
        .unwrap();
        let mut actual = Vec::new();
        while actual.len() < expected.len() {
            match reader.next_frame().unwrap() {
                DecodeStep::NeedInput => {
                    let r = reader.next_request().unwrap();
                    reader.accept(&r, &bytes[r.bytes.clone()]).unwrap();
                    requests += 1;
                    fetched += r.bytes.len();
                }
                DecodeStep::Frame(frame) => {
                    actual.extend(frame.pcm.to_i16().iter().flat_map(|v| v.to_le_bytes()))
                }
                _ => panic!("unexpected decode step"),
            }
        }
        assert_eq!(actual, expected, "{}", file.display());
        total_samples += actual.len() / 2;
        let target = if expected.len() / record > 128 {
            128
        } else {
            2
        };
        reader.begin_seek(target * 1024 + 17).unwrap();
        loop {
            match reader.next_frame().unwrap() {
                DecodeStep::NeedInput => {
                    let r = reader.next_request().unwrap();
                    reader.accept(&r, &bytes[r.bytes.clone()]).unwrap();
                }
                DecodeStep::Preroll { .. } => {}
                DecodeStep::Frame(frame) => {
                    assert_eq!(frame.skipped_samples, 17);
                    let actual: Vec<_> = frame
                        .pcm
                        .to_i16()
                        .iter()
                        .flat_map(|v| v.to_le_bytes())
                        .collect();
                    assert_eq!(
                        actual,
                        &expected[target as usize * record + 17 * channels * 2
                            ..(target as usize + 1) * record]
                    );
                    break;
                }
                DecodeStep::Finished => panic!("seek reached EOF"),
            }
        }
        println!(
            "{}: {} PCM samples exact; prefix read requests={requests} bytes={fetched}",
            file.file_name().unwrap().to_string_lossy(),
            expected.len() / 2
        );
    }
    println!("14 sparse PCM cases, {total_samples} exact i16 samples, exact trimmed seeks");
}

#[test]
#[ignore = "requires local six-song corpus"]
fn local_sparse_corpus_index() {
    let root = std::env::var_os("BAKA_AV3A_SAMPLE_DIR").unwrap();
    let mut total = 0;
    for id in [
        "3383921500",
        "3397415408",
        "3438952240",
        "3440171245",
        "139774",
        "347230",
    ] {
        let bytes = std::fs::read(Path::new(&root).join(format!("{id}.mp4"))).unwrap();
        let full = baka_av3a_container::Track::parse(&bytes).unwrap();
        let (index, _, fetched) = index(&bytes);
        assert!(fetched <= RangeProbe::WINDOW);
        assert_eq!(index.packet_count(), full.packet_count());
        assert_eq!(index.duration_ticks(), full.duration_ticks);
        for p in full.packets() {
            let range = index.packet_range(p.index).unwrap();
            assert_eq!(&bytes[range], p.bytes);
            let actual = index.validate_packet(p.index, p.bytes).unwrap();
            assert_eq!((actual.dts, actual.duration), (p.dts, p.duration));
            total += 1;
        }
    }
    println!("six sparse indexes: {total} exact packets and valid CRCs");
}
