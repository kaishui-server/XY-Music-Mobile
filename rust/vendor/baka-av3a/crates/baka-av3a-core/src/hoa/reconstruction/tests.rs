use super::*;
use crate::{
    FrameHeader,
    hoa::{HoaFrame, HoaGroupSide, HoaPair},
};

fn side(config: &HoaConfig) -> HoaSide {
    HoaSide {
        scene: 0,
        spatial: config.spatial(),
        basis_indices: if config.spatial() {
            vec![0, 0]
        } else {
            Vec::new()
        },
        groups: config
            .groups()
            .iter()
            .map(|g| HoaGroupSide {
                pairs: Vec::new(),
                energy: vec![30; g.channels],
                ratio: 8,
                channel_ratios: vec![1; g.channels],
            })
            .collect(),
    }
}

#[test]
fn asset_and_spectral_errors_are_bounded() {
    let mut bytes = b"AV3HOA01".to_vec();
    bytes.resize(8 + 1343 * 16 * 4, 0);
    let basis = HoaBasis::parse(&bytes).unwrap();
    for length in 0..bytes.len() {
        assert!(HoaBasis::parse(&bytes[..length]).is_err());
    }
    bytes[8..12].copy_from_slice(&f32::NAN.to_le_bytes());
    assert!(HoaBasis::parse(&bytes).is_err());
    let config = HoaConfig::new(1, 48000).unwrap();
    let mut side = side(&config);
    side.groups[0].pairs.push(HoaPair {
        channels: [0, 1],
        mask: [true; 21],
    });
    let input = vec![vec![1.0; 1024]; 4];
    let output = side.inverse_mix(&config, input.clone()).unwrap();
    assert_eq!(output[0][0], 2.0 * std::f32::consts::FRAC_1_SQRT_2);
    assert_eq!(output[1][0], 0.0);
    assert_eq!(output[0][768], 1.0);
    side.groups[0].energy[0] = 31;
    assert!(side.inverse_mix(&config, input).is_err());
    let config = HoaConfig::new(3, 256000).unwrap();
    let side = self::side(&config);
    let mut synthesis = HoaSynthesis::new(config);
    assert!(synthesis.process(&[[0.0; 1024]; 8], &side, None).is_err());
    assert!(synthesis.previous.iter().flatten().all(|&v| v == 0.0));
    assert!(
        synthesis
            .process(&[[0.0; 1024]; 8], &side, Some(&basis))
            .unwrap()
            .iter()
            .flatten()
            .all(|&v| v == 0.0)
    );
}

#[test]
#[ignore = "requires local independent HOA float records and basis asset"]
fn local_hoa_floating_stages() {
    let basis =
        HoaBasis::parse(&std::fs::read(std::env::var_os("BAKA_AV3A_HOA_PATH").unwrap()).unwrap())
            .unwrap();
    let root = std::path::PathBuf::from(std::env::var_os("BAKA_AV3A_HOA_MATRIX_DIR").unwrap());
    let mut cases: Vec<_> = std::fs::read_dir(&root)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "float"))
        .collect();
    cases.sort();
    assert_eq!(cases.len(), 18);
    let mut values = 0;
    for path in cases {
        let bytes = std::fs::read(path.with_extension("av3a")).unwrap();
        let reference = std::fs::read(&path).unwrap();
        let mut expected = reference
            .as_chunks::<4>()
            .0
            .iter()
            .map(|v| f32::from_le_bytes(*v));
        let mut position = 0;
        let mut history = None;
        for frame in 0..8 {
            let header = FrameHeader::parse(&bytes[position..]).unwrap();
            let packet =
                HoaFrame::parse(&bytes[position..position + header.frame_bytes()]).unwrap();
            let n = packet.config.transport_channels();
            let input: Vec<_> = (0..n)
                .map(|ch| {
                    (0..1024)
                        .map(|i| {
                            ((i * 7 + ch * 13 + frame * 17) % 101) as f32 / 128.0 - 50.0 / 128.0
                        })
                        .collect()
                })
                .collect();
            let mixed = packet.side.inverse_mix(&packet.config, input).unwrap();
            for value in mixed.iter().flatten() {
                assert_eq!(
                    *value,
                    expected.next().unwrap(),
                    "{} frame {frame} inverse-mix value {values}",
                    path.display()
                );
                values += 1;
            }
            let pcm: Vec<[f32; 1024]> = (0..n)
                .map(|ch| {
                    std::array::from_fn(|i| {
                        ((i * 11 + ch * 23 + frame * 31) % 137) as f32 / 64.0 - 68.0 / 64.0
                    })
                })
                .collect();
            let state = history.get_or_insert_with(|| HoaSynthesis::new(packet.config.clone()));
            let output = state.process(&pcm, &packet.side, Some(&basis)).unwrap();
            for value in output.iter().flatten() {
                assert_eq!(
                    *value,
                    expected.next().unwrap(),
                    "{} frame {frame} synthesis value {values}",
                    path.display()
                );
                values += 1;
            }
            position += header.frame_bytes();
        }
        assert_eq!(position, bytes.len());
        assert!(expected.next().is_none());
    }
    println!("18 HOA float cases, {values} exact inverse-mix and synthesis values");
}
