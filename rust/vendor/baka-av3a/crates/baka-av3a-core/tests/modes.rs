use baka_av3a_core::{
    FrameHeader, decoder::Decoder, hoa::HoaBasis, mcr::McrCodebooks, model::HyperModel,
    shaping::LsfCodebooks,
};
use std::{path::Path, sync::Arc};

#[test]
#[ignore = "requires local model, LSF assets and independently generated mode matrix"]
fn local_channel_bed_matrix() {
    run_matrix("BAKA_AV3A_MODE_MATRIX_DIR", 136);
}

#[test]
#[ignore = "requires local assets and independent object/mixed PCM records"]
fn local_mixed_matrix() {
    run_matrix("BAKA_AV3A_MIXED_MATRIX_DIR", 232);
}

#[test]
#[ignore = "requires local model, LSF, HOA basis and independent PCM records"]
fn local_hoa_pcm_matrix() {
    run_matrix("BAKA_AV3A_HOA_MATRIX_DIR", 72);
}

#[test]
#[ignore = "requires local assets and independent dynamic metadata PCM records"]
fn local_dynamic_pcm_matrix() {
    run_matrix("BAKA_AV3A_DYNAMIC_MATRIX_DIR", 64);
}

#[test]
#[ignore = "requires local assets and independent static metadata PCM records"]
fn local_static_pcm_matrix() {
    run_matrix("BAKA_AV3A_STATIC_MATRIX_DIR", 32);
}

fn run_matrix(directory_variable: &str, minimum: usize) {
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
    let mcr = Arc::new(
        McrCodebooks::parse(
            &std::fs::read(std::env::var_os("BAKA_AV3A_MCR_PATH").unwrap()).unwrap(),
        )
        .unwrap(),
    );
    let hoa = std::env::var_os("BAKA_AV3A_HOA_PATH")
        .map(|p| Arc::new(HoaBasis::parse(&std::fs::read(p).unwrap()).unwrap()));
    let directory = std::env::var_os(directory_variable).unwrap();
    let mut files: Vec<_> = std::fs::read_dir(Path::new(&directory))
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "av3a"))
        .collect();
    files.sort();
    assert!(files.len() >= minimum);
    let (mut frames, mut samples) = (0usize, 0usize);
    for file in files {
        let bytes = std::fs::read(&file).unwrap();
        let expected = std::fs::read(file.with_extension("pcm")).unwrap();
        let mut decoder = Decoder::new(model.clone(), lsf.clone()).with_mcr(mcr.clone());
        if let Some(basis) = &hoa {
            decoder = decoder.with_hoa(basis.clone());
        }
        let first = FrameHeader::parse(&bytes).unwrap();
        if first.channels == 2 && first.bitrate <= 32000 {
            let mut missing = Decoder::new(model.clone(), lsf.clone());
            assert_eq!(
                missing.decode(&bytes[..first.frame_bytes()]).unwrap_err(),
                baka_av3a_core::Error::Unsupported("missing MCR codebooks")
            );
            assert_eq!(missing.decoded_frames(), 0);
            decoder = missing.with_mcr(mcr.clone());
        }
        if matches!(first.profile, baka_av3a_core::Profile::Hoa { order: 3 })
            && first.bitrate < 896000
        {
            let mut missing = Decoder::new(model.clone(), lsf.clone());
            assert_eq!(
                missing.decode(&bytes[..first.frame_bytes()]).unwrap_err(),
                baka_av3a_core::Error::Unsupported("missing HOA basis asset")
            );
            assert_eq!(missing.decoded_frames(), 0);
            let basis = hoa.as_ref().unwrap().clone();
            decoder = missing.with_hoa(basis);
        }
        let (mut position, mut sample) = (0, 0);
        let mut latest_metadata = None;
        let mut latest_static = None;
        while position < bytes.len() {
            let header = FrameHeader::parse(&bytes[position..]).unwrap();
            let size = header.frame_bytes();
            if decoder.decoded_frames() == 3 {
                let mut corrupt = bytes[position..position + size].to_vec();
                corrupt[size - 1] ^= 1;
                let saved_metadata = decoder.dynamic_metadata().cloned();
                let saved_static = decoder.static_metadata().cloned();
                assert!(decoder.decode(&corrupt).is_err());
                assert_eq!(decoder.dynamic_metadata(), saved_metadata.as_ref());
                assert_eq!(decoder.static_metadata(), saved_static.as_ref());
                assert_eq!(decoder.decoded_frames(), 3);
            }
            let pcm = decoder
                .decode(&bytes[position..position + size])
                .unwrap_or_else(|e| {
                    panic!("{} frame {}: {e}", file.display(), decoder.decoded_frames())
                });
            if pcm.metadata.dynamic.is_some() {
                latest_metadata = pcm.metadata.dynamic.clone();
            }
            if pcm.metadata.static_data.is_some() {
                latest_static = pcm.metadata.static_data.clone();
            }
            assert_eq!(decoder.static_metadata(), latest_static.as_deref());
            assert_eq!(decoder.dynamic_metadata(), latest_metadata.as_deref());
            for value in pcm.to_i16() {
                let reference =
                    i16::from_le_bytes(expected[sample..sample + 2].try_into().unwrap());
                assert_eq!(
                    value,
                    reference,
                    "{} frame {} sample {}",
                    file.display(),
                    decoder.decoded_frames() - 1,
                    sample / 2
                );
                sample += 2;
                samples += 1;
            }
            position += size;
            frames += 1;
        }
        assert_eq!(sample, expected.len());
        decoder.reset();
        assert!(decoder.dynamic_metadata().is_none());
        assert!(decoder.static_metadata().is_none());
        let first_pcm = decoder
            .decode(&bytes[..first.frame_bytes()])
            .unwrap()
            .to_i16();
        for (value, word) in first_pcm.iter().zip(expected.as_chunks::<2>().0) {
            assert_eq!(*value, i16::from_le_bytes(*word));
        }
    }
    println!("{frames} mode-matrix frames, {samples} exact s16 samples");
}

#[test]
#[ignore = "requires local MCR asset and independent spectral records"]
fn local_mcr_spectra() {
    use baka_av3a_core::mcr::McrSide;
    let books = McrCodebooks::parse(
        &std::fs::read(std::env::var_os("BAKA_AV3A_MCR_PATH").unwrap()).unwrap(),
    )
    .unwrap();
    let directory = std::env::var_os("BAKA_AV3A_MODE_MATRIX_DIR").unwrap();
    let bytes = std::fs::read(Path::new(&directory).join("mcr-spectra.bin")).unwrap();
    const RECORD: usize = 8 + 2048 * 4;
    assert_eq!(bytes.len(), 768 * RECORD);
    let mono: Vec<_> = (0..1024).map(|i| (i % 37 - 18) as f32 / 64.0).collect();
    for (case, record) in bytes.as_chunks::<RECORD>().0.iter().enumerate() {
        let short = u32::from_le_bytes(record[..4].try_into().unwrap()) != 0;
        let index = u32::from_le_bytes(record[4..8].try_into().unwrap()) as u16;
        assert_eq!(
            (short, usize::from(index)),
            (case >= 512, if case < 512 { case } else { case - 512 })
        );
        let side = McrSide {
            indices: [[index; 6]; 2],
            short,
        };
        let output = books.reconstruct(&mono, &side).unwrap();
        for (line, (value, word)) in output
            .iter()
            .flatten()
            .zip(record[8..].as_chunks::<4>().0)
            .enumerate()
        {
            assert_eq!(*value, f32::from_le_bytes(*word), "case {case} line {line}");
        }
    }
    println!("768 MCR vectors, 1572864 exact f32 values");
}
