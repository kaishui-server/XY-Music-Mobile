use baka_av3a_core::{Error, model::HyperModel};

#[path = "fixtures/model_record.rs"]
mod model_record;
use model_record::{fixture, float, integer};

#[test]
fn model_to_context_coefficients_and_feature_layout() {
    let bytes = fixture();
    let model = HyperModel::parse(&bytes).unwrap();
    assert_eq!(
        (model.base().latent_lines, model.context().latent_lines),
        (512, 256)
    );
    assert_eq!(model.base().scales, [1.0, 2.0]);
    assert_eq!(model.base().encoder[0].weights, [2.0]);
    assert_eq!(model.context().end_offset, bytes.len());
    let decoded = model.decode_context(&[0; 32]).unwrap();
    assert_eq!(decoded.values, vec![0; 256]);
    assert_eq!(
        model.context_features(&decoded.values).unwrap(),
        vec![1.25; 256]
    );
    assert!(model.context_features(&[]).is_err());
    let mut noise = baka_av3a_core::model::NoiseState::default();
    let group = baka_av3a_core::quantization::Grouping {
        count: 1,
        indicators: [false; 8],
    };
    let q = baka_av3a_core::quantization::QuantizedChannel {
        amplified: false,
        scale_index: 0,
        noise_indices: vec![0],
        context: vec![0; 32],
        base: vec![0; 64],
    };
    let config = baka_av3a_core::model::SpectrumConfig {
        neural_type: 0,
        transform: 0,
        noise_lines: 1024,
    };
    let spectrum = model
        .decode_spectrum(&q, &group, config, &mut noise)
        .unwrap();
    assert_eq!(spectrum.len(), 1024);
    assert!(spectrum.iter().all(|v| v.is_finite()));
    let before = noise;
    let bad = baka_av3a_core::model::SpectrumConfig {
        neural_type: 2,
        ..config
    };
    assert!(model.decode_spectrum(&q, &group, bad, &mut noise).is_err());
    assert_eq!(noise, before);
    for prefix in 0..bytes.len() {
        assert!(
            HyperModel::parse(&bytes[..prefix]).is_err(),
            "prefix {prefix}"
        );
    }
    let mut trailing = bytes;
    trailing.push(0);
    assert!(HyperModel::parse(&trailing).is_err());
}

#[test]
fn malformed_dimensions_and_floats_are_rejected() {
    let original = fixture();
    for (offset, value) in [
        (0, -1),
        (0, 11),
        (4, 0),
        (6, 2),
        (10, 0),
        (12, 256),
        (14, 257),
    ] {
        let mut bytes = original.clone();
        bytes[offset..offset + 2].copy_from_slice(&i16::to_le_bytes(value));
        assert!(
            HyperModel::parse(&bytes).is_err(),
            "offset {offset}, value {value}"
        );
    }
    for value in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
        let mut bytes = original.clone();
        bytes[16..20].copy_from_slice(&value.to_le_bytes());
        assert_eq!(
            HyperModel::parse(&bytes).unwrap_err(),
            Error::Invalid("model float")
        );
    }
    for (offset, value) in [(24, 0.0f32), (28, -0.5), (70, 0.0), (74, 0.5)] {
        let mut bytes = original.clone();
        bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        assert!(HyperModel::parse(&bytes).is_err());
    }
    let mut random = 123491u32;
    for _ in 0..2000 {
        let mut bytes = original.clone();
        for _ in 0..8 {
            random ^= random << 13;
            random ^= random >> 17;
            random ^= random << 5;
            let index = random as usize % bytes.len();
            bytes[index] = random as u8;
        }
        let _ = HyperModel::parse(&bytes);
    }
}

#[test]
fn context_medians_and_channel_major_order() {
    let mut bytes = Vec::new();
    for hyper in [true, false] {
        for transpose in [false, true] {
            integer(&mut bytes, 1);
            let (input, output) = if hyper {
                if transpose { (2, 1) } else { (1, 2) }
            } else {
                (2, 2)
            };
            for value in [0, 2, 0, 1, 1, input, output] {
                integer(&mut bytes, value);
            }
            for _ in 0..input * output {
                float(&mut bytes, 1.0);
            }
        }
        float(&mut bytes, 1.25);
        float(&mut bytes, -2.5);
        if hyper {
            integer(&mut bytes, 2);
            float(&mut bytes, 1.0);
            float(&mut bytes, 2.0);
        }
        for _ in 0..2 {
            integer(&mut bytes, 3);
        }
        for _ in 0..2 {
            integer(&mut bytes, 0);
        }
        for _ in 0..2 {
            for value in [0u32, 32768, 65536] {
                bytes.extend(value.to_le_bytes());
            }
        }
    }
    let model = HyperModel::parse(&bytes).unwrap();
    let values: Vec<_> = (0..256).flat_map(|i| [i, -i]).collect();
    let features = model.context_features(&values).unwrap();
    assert_eq!(features.len(), 512);
    for i in 0..256 {
        assert_eq!(features[i], i as f32 + 1.25);
        assert_eq!(features[256 + i], -(i as f32) - 2.5);
    }
}

#[test]
#[ignore = "requires BAKA_AV3A_MODEL_PATH pointing to a local decoded model"]
fn local_model() {
    let bytes = std::fs::read(std::env::var_os("BAKA_AV3A_MODEL_PATH").unwrap()).unwrap();
    let model = HyperModel::parse(&bytes).unwrap();
    assert_eq!(
        (model.base().encoder.len(), model.base().decoder.len()),
        (4, 4)
    );
    assert_eq!(
        (model.context().encoder.len(), model.context().decoder.len()),
        (3, 3)
    );
    assert_eq!(
        (model.base().latent_lines, model.base().latent_channels),
        (64, 16)
    );
    assert_eq!(
        (
            model.context().latent_lines,
            model.context().latent_channels
        ),
        (16, 16)
    );
    assert_eq!(
        (
            model.base().entropy.distribution_count(),
            model.context().entropy.distribution_count()
        ),
        (64, 16)
    );
    assert_eq!(
        (model.base().end_offset, model.context().end_offset),
        (60450, 79930)
    );
}
