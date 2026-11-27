use baka_av3a_container::Track;
use baka_av3a_core::{Error, decoder::Decoder, model::HyperModel, shaping::LsfCodebooks};
use std::{path::Path, sync::Arc};

#[test]
#[ignore = "requires local real media, model, LSF and continuous PCM oracle"]
fn local_progressive_pcm_before_download_completion() {
    use baka_av3a_container::progressive::Mp4Decoder;
    let model = Arc::new(
        HyperModel::parse(
            &std::fs::read(std::env::var_os("BAKA_AV3A_MODEL_PATH").unwrap()).unwrap(),
        )
        .unwrap(),
    );
    let lsf = Arc::new(
        LsfCodebooks::parse(
            &std::fs::read(std::env::var_os("BAKA_AV3A_LSF_PATH").unwrap()).unwrap(),
        )
        .unwrap(),
    );
    let directory = std::env::var_os("BAKA_AV3A_SAMPLE_DIR").unwrap();
    let data = std::fs::read(Path::new(&directory).join("3440171245.mp4")).unwrap();
    let expected = std::fs::read(std::env::var_os("BAKA_AV3A_PCM_PATH").unwrap()).unwrap();
    let mut count = 0;
    let mut first_input_bytes = None;
    let mut decoder = Mp4Decoder::new(Decoder::new(model, lsf)).unwrap();
    for (block_index, block) in data.chunks(1024).enumerate() {
        decoder.push(block).unwrap();
        while let Some(pcm) = decoder.next_frame().unwrap() {
            first_input_bytes.get_or_insert((block_index + 1) * 1024);
            let start = count * 1024 * 12 * 2;
            for (sample, word) in pcm
                .pcm
                .to_i16()
                .into_iter()
                .zip(expected[start..start + 1024 * 12 * 2].as_chunks::<2>().0)
            {
                assert_eq!(sample, i16::from_le_bytes(*word));
            }
            count += 1;
            if count == expected.len() / (1024 * 12 * 2) {
                assert!(first_input_bytes.unwrap() < 8192);
                assert!((block_index + 1) * 1024 < data.len());
                println!(
                    "{count} continuous real frames exact; first PCM after {} input bytes, full file {} bytes; buffered {} bytes",
                    first_input_bytes.unwrap(),
                    data.len(),
                    decoder.buffered_bytes()
                );
                return;
            }
        }
    }
    panic!("not enough real frames");
}

#[test]
#[ignore = "requires local fragment PCM cases, optional assets and independent PCM records"]
fn local_progressive_fragment_pcm() {
    use baka_av3a_container::progressive::Mp4Decoder;
    use baka_av3a_core::{hoa::HoaBasis, mcr::McrCodebooks};
    let root = std::path::PathBuf::from(std::env::var_os("BAKA_AV3A_ORACLE_DIR").unwrap());
    let model =
        Arc::new(HyperModel::parse(&std::fs::read(root.join("model.bin")).unwrap()).unwrap());
    let lsf = Arc::new(LsfCodebooks::parse(&std::fs::read(root.join("lsf.bin")).unwrap()).unwrap());
    let mcr = Arc::new(McrCodebooks::parse(&std::fs::read(root.join("mcr.bin")).unwrap()).unwrap());
    let hoa = Arc::new(HoaBasis::parse(&std::fs::read(root.join("hoa.bin")).unwrap()).unwrap());
    let cases = [
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
    ];
    let mut samples = 0;
    for (name, oracle) in cases {
        let data = std::fs::read(root.join(format!("fragment-pcm/{name}-fragments.mp4"))).unwrap();
        let expected = std::fs::read(root.join(oracle)).unwrap();
        let mut decoder = Mp4Decoder::new(
            Decoder::new(model.clone(), lsf.clone())
                .with_mcr(mcr.clone())
                .with_hoa(hoa.clone()),
        )
        .unwrap();
        let mut actual = Vec::new();
        for block in data.chunks(257) {
            decoder.push(block).unwrap();
            while let Some(pcm) = decoder.next_frame().unwrap() {
                actual.extend(pcm.pcm.to_i16().iter().flat_map(|v| v.to_le_bytes()));
            }
        }
        decoder.finish();
        assert!(decoder.next_frame().unwrap().is_none());
        assert!(decoder.is_finished());
        assert_eq!(actual, expected, "{name}");
        samples += actual.len() / 2;
    }
    println!("6 progressive fragmented cases, {samples} exact i16 PCM samples");
}

#[test]
#[ignore = "requires local decoded assets and continuous PCM oracle"]
fn local_continuous_pcm() {
    let model = HyperModel::parse(
        &std::fs::read(std::env::var_os("BAKA_AV3A_MODEL_PATH").unwrap()).unwrap(),
    )
    .unwrap();
    let lsf = LsfCodebooks::parse(
        &std::fs::read(std::env::var_os("BAKA_AV3A_LSF_PATH").unwrap()).unwrap(),
    )
    .unwrap();
    let samples = std::env::var_os("BAKA_AV3A_SAMPLE_DIR").unwrap();
    let bytes = std::fs::read(Path::new(&samples).join("3440171245.mp4")).unwrap();
    let track = Track::parse(&bytes).unwrap();
    track.validate_frames().unwrap();
    let expected = std::fs::read(std::env::var_os("BAKA_AV3A_PCM_PATH").unwrap()).unwrap();
    let record = 1024 * 12 * 2;
    assert_eq!(expected.len() % record, 0);
    let mut decoder = Decoder::new(Arc::new(model), Arc::new(lsf));
    let mut differences = 0;
    let mut max_difference = 0i32;
    for (index, reference) in expected.chunks_exact(record).enumerate() {
        let packet = track.packet(index).unwrap().bytes;
        if index % 31 == 0 {
            let mut corrupt = packet.to_vec();
            corrupt[100] ^= 1;
            assert_eq!(
                decoder.decode(&corrupt).unwrap_err(),
                Error::Invalid("frame CRC")
            );
            assert_eq!(decoder.decoded_frames(), index as u64);
        }
        let pcm = decoder.decode(packet).unwrap();
        assert_eq!(
            (pcm.sample_rate, pcm.channels, pcm.samples.len()),
            (44100, 12, 12288)
        );
        for (actual, word) in pcm.to_i16().into_iter().zip(reference.as_chunks::<2>().0) {
            let value = i16::from_le_bytes(*word);
            let delta = (i32::from(actual) - i32::from(value)).abs();
            differences += usize::from(delta != 0);
            max_difference = max_difference.max(delta);
        }
    }
    println!(
        "{} continuous frames, {differences} differing samples, maximum s16 difference {max_difference}",
        expected.len() / record
    );
    assert_eq!(differences, 0);
}
