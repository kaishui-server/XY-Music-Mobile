use baka_av3a_container::Track;
use baka_av3a_core::{
    model::{HyperModel, NoiseState, SpectrumConfig},
    side::ChannelBedFrame,
};

#[test]
#[ignore = "requires local samples, decoded model and spectrum oracle records"]
fn local_neural_spectra() {
    check_spectra("spectrum");
}

#[test]
#[ignore = "requires local samples, decoded model and postprocessing oracle records"]
fn local_uncoupled_tns_spectra() {
    check_spectra("post");
}

#[test]
#[ignore = "requires local samples, decoded model, LSF assets and shaping oracle records"]
fn local_shaped_spectra() {
    check_spectra("shaping");
}

fn check_spectra(stage: &str) {
    let shaping = if stage == "shaping" {
        Some(
            baka_av3a_core::shaping::LsfCodebooks::parse(
                &std::fs::read(std::env::var_os("BAKA_AV3A_LSF_PATH").unwrap()).unwrap(),
            )
            .unwrap(),
        )
    } else {
        None
    };
    let model = HyperModel::parse(
        &std::fs::read(std::env::var_os("BAKA_AV3A_MODEL_PATH").unwrap()).unwrap(),
    )
    .unwrap();
    let samples = std::env::var_os("BAKA_AV3A_SAMPLE_DIR").unwrap();
    let oracle = std::env::var_os("BAKA_AV3A_ORACLE_DIR").unwrap();
    let mut compared = 0;
    let mut max_error = 0.0f32;
    let mut short = 0;
    for id in [
        "3383921500",
        "3397415408",
        "3438952240",
        "3440171245",
        "139774",
        "347230",
    ] {
        let bytes =
            std::fs::read(std::path::Path::new(&samples).join(format!("{id}.mp4"))).unwrap();
        let track = Track::parse(&bytes).unwrap();
        track.validate_frames().unwrap();
        let expected =
            std::fs::read(std::path::Path::new(&oracle).join(format!("{id}-{stage}.bin"))).unwrap();
        const RECORD: usize = 4 + 12 * 1024 * 4;
        assert_eq!(expected.len() % RECORD, 0);
        assert!(expected.len() >= track.packet_count().div_ceil(997) * RECORD);
        let mut previous = None;
        for record in expected.as_chunks::<RECORD>().0 {
            let index = u32::from_le_bytes(record[..4].try_into().unwrap()) as usize;
            assert!(previous.is_none_or(|p| p < index));
            previous = Some(index);
            let frame = ChannelBedFrame::parse(track.packet(index).unwrap().bytes).unwrap();
            let mut noise = NoiseState::default();
            let mut spectra = Vec::new();
            for channel in 0..12 {
                let config = SpectrumConfig {
                    neural_type: frame.header.neural_type,
                    transform: frame.cores[channel].transform,
                    noise_lines: 1024,
                };
                let spectrum = model
                    .decode_spectrum(
                        &frame.quantized[channel],
                        &frame.groups[channel],
                        config,
                        &mut noise,
                    )
                    .unwrap();
                short += usize::from(config.transform == 1);
                spectra.push(spectrum);
            }
            if stage != "spectrum" {
                spectra =
                    baka_av3a_core::spectral::uncouple(spectra, frame.mc_mode().unwrap(), true)
                        .unwrap();
                for (spectrum, core) in spectra.iter_mut().zip(&frame.cores) {
                    baka_av3a_core::spectral::inverse_tns(
                        spectrum.as_mut_slice().try_into().unwrap(),
                        core,
                    )
                    .unwrap();
                    if let Some(shaping) = &shaping {
                        shaping
                            .apply(
                                spectrum.as_mut_slice().try_into().unwrap(),
                                &core.lsf_indices,
                            )
                            .unwrap();
                    }
                }
            }
            for (channel, spectrum) in spectra.iter().enumerate() {
                for (bin, &value) in spectrum.iter().enumerate() {
                    let start = 4 + (channel * 1024 + bin) * 4;
                    let reference =
                        f32::from_le_bytes(record[start..start + 4].try_into().unwrap());
                    assert!(reference.is_finite());
                    let error = (value - reference).abs() / reference.abs().max(1.0);
                    max_error = max_error.max(error);
                    assert!(
                        error <= 2e-6,
                        "{id} frame {index} channel {channel} bin {bin}: {value} != {reference}, {error}"
                    );
                    compared += 1;
                }
            }
        }
    }
    println!(
        "{compared} spectral values, {short} short-window channels, max relative-scaled error {max_error}"
    );
}
