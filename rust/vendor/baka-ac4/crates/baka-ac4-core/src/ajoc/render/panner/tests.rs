use super::super::layout::{self, SpeakerLayout};
use super::*;

fn layouts() -> [SpeakerLayout; 5] {
    [
        SpeakerLayout::Stereo,
        SpeakerLayout::Surround51,
        SpeakerLayout::Surround71,
        SpeakerLayout::Surround514,
        SpeakerLayout::Surround714,
    ]
}

#[test]
fn prepared_spread_matches_original_gain_bits_for_all_layouts_and_zones() {
    for layout in layouts() {
        for mask in 0..=5 {
            for elevation in [false, true] {
                let mut speakers = layout.speakers();
                speakers.retain(|s| {
                    !layout::excluded(s.zone, mask, elevation, false, layout.counts().0)
                });
                if speakers.is_empty() {
                    continue;
                }
                for position in [
                    [0.; 3],
                    [1.; 3],
                    [0.5; 3],
                    [0.13, 0.72, 0.36],
                    [0.91, 0.07, 0.83],
                ] {
                    for width in [
                        [0.; 3],
                        [0.000009; 3],
                        [0.00001; 3],
                        [0.2; 3],
                        [0.5; 3],
                        [0.75; 3],
                        [1.; 3],
                        [0., 1., 0.],
                        [0.73, 0.21, 0.49],
                    ] {
                        for divergence in [0., 0.125, 1.] {
                            let expected = reference::gains(&speakers, position, width, divergence);
                            let actual = gains(&speakers, position, width, divergence);
                            assert_eq!(
                                actual.iter().map(|v| v.to_bits()).collect::<Vec<_>>(),
                                expected.iter().map(|v| v.to_bits()).collect::<Vec<_>>(),
                                "{layout:?} mask={mask} elevation={elevation} position={position:?} width={width:?} divergence={divergence}",
                            );
                        }
                    }
                }
            }
        }
    }
}

#[test]
fn prepared_axes_match_original_at_speaker_positions_and_near_boundaries() {
    for layout in layouts() {
        let speakers = layout.speakers();
        for a in 0..3 {
            let prepared = prepare_axis(&speakers, a);
            for value in speakers.iter().flat_map(|s| {
                let v = s.position[a];
                [v - 1e-12, v, v + 1e-12]
            }) {
                let expected = axis(&speakers, a, value);
                for (speaker, expected) in prepared.iter().zip(expected) {
                    assert_eq!(speaker.gain(value).to_bits(), expected.to_bits());
                }
            }
        }
    }
}

#[test]
#[ignore = "manual release host timing; not a device benchmark"]
fn spread_preparation_measurement() {
    use std::hint::black_box;
    use std::time::Instant;

    type Panner = fn(&[Speaker], [f64; 3], [f64; 3], f64) -> Vec<f64>;
    fn measure(speakers: &[Speaker], width: [f64; 3], panner: Panner) -> u128 {
        let start = Instant::now();
        for i in 0..1000 {
            let position = [(i % 101) as f64 / 100., 0.37, 0.69];
            black_box(panner(black_box(speakers), position, width, 0.));
        }
        start.elapsed().as_micros()
    }

    for layout in layouts() {
        let speakers = layout.speakers();
        for width in [[0.; 3], [0.2; 3], [0.73, 0.21, 0.49]] {
            let mut original = Vec::new();
            let mut prepared = Vec::new();
            for round in 0..10 {
                let (before, after) = if round % 2 == 0 {
                    (
                        measure(&speakers, width, reference::gains),
                        measure(&speakers, width, gains),
                    )
                } else {
                    let after = measure(&speakers, width, gains);
                    (measure(&speakers, width, reference::gains), after)
                };
                if round >= 3 {
                    original.push(before);
                    prepared.push(after);
                }
            }
            original.sort_unstable();
            prepared.sort_unstable();
            eprintln!(
                "spread {layout:?} width={width:?} runs=1000 medianUs: original={} prepared={}",
                original[3], prepared[3]
            );
        }
    }
}
