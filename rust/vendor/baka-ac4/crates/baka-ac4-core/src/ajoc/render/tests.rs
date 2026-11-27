use super::*;
use crate::ajoc::{
    ObjectMatrix,
    common::{TrimConfiguration, TrimMetadata},
    oamd::{ObjectTiming, ObjectUpdate},
};

fn properties(position: [f32; 3]) -> ObjectProperties {
    ObjectProperties {
        active: true,
        gain_db: Some(0),
        position,
        elevation: true,
        trim_disabled: true,
        ..Default::default()
    }
}
fn metadata(properties: ObjectProperties, sample: u16, ramp: u16) -> AjocMetadata {
    AjocMetadata {
        objects: vec![ObjectMatrix::default()],
        upmix_metadata: vec![vec![ObjectUpdate {
            properties,
            timing: ObjectTiming { sample, ramp },
        }]],
        ..Default::default()
    }
}
fn power(gains: &[f64]) -> f64 {
    gains.iter().map(|v| v * v).sum()
}

#[test]
fn speaker_masks_point_targets_and_three_axis_energy() {
    for layout in [
        SpeakerLayout::Stereo,
        SpeakerLayout::Surround51,
        SpeakerLayout::Surround71,
        SpeakerLayout::Surround514,
        SpeakerLayout::Surround714,
    ] {
        let speakers = layout.speakers();
        assert_eq!(
            speakers.len(),
            layout.channels() - usize::from(layout != SpeakerLayout::Stereo)
        );
        let renderer = SpeakerRenderer::new(RenderOptions::new(layout)).unwrap();
        for speaker in &speakers {
            let p = properties(speaker.position.map(|v| v as f32));
            let gains = renderer.target(&p, None, false).unwrap();
            assert!((gains[speaker.channel] - 1.).abs() < 1e-10);
            assert!((power(&gains) - 1.).abs() < 1e-10);
        }
        for x in [0., 0.2, 0.5, 0.75, 1.] {
            for y in [0., 0.25, 0.5, 0.8, 1.] {
                for z in [0., 0.3, 0.8, 1.] {
                    let gains = renderer
                        .target(&properties([x, y, z]), None, false)
                        .unwrap();
                    assert!(
                        (power(&gains) - 1.).abs() < 1e-10,
                        "{layout:?}: {x},{y},{z}"
                    );
                }
            }
        }
    }
}

#[test]
fn zone_and_elevation_exclusions_do_not_leak_energy() {
    let renderer = SpeakerRenderer::new(RenderOptions::new(SpeakerLayout::Surround714)).unwrap();
    for mask in 0..=5 {
        let mut p = properties([0.5, 0.5, 0.7]);
        p.zone_mask = mask;
        p.elevation = false;
        let gains = renderer.target(&p, None, false).unwrap();
        assert!(gains[8..].iter().all(|&v| v == 0.));
        if mask == 1 || mask == 4 {
            assert_eq!(&gains[4..6], &[0., 0.]);
        }
        if [2, 3, 4].contains(&mask) {
            assert_eq!(&gains[6..8], &[0., 0.]);
        }
        if mask == 5 {
            assert_eq!(&gains[..3], &[0., 0., 0.]);
        }
        assert!((power(&gains) - 1.).abs() < 1e-10);
    }
}

#[test]
fn spread_and_divergence_preserve_energy_and_mirror_symmetry() {
    let speakers = SpeakerLayout::Surround714.speakers();
    for width in [
        [0., 0., 0.],
        [0.001, 0., 0.],
        [0.2; 3],
        [0.5; 3],
        [1.; 3],
        [0., 1., 0.],
    ] {
        let gains = panner::gains(&speakers, [0.5, 0.5, 0.5], width, 0.);
        assert!(gains.iter().all(|v| v.is_finite() && *v >= 0.));
        assert!((power(&gains) - 1.).abs() < 1e-9);
        assert!((gains[0] - gains[1]).abs() < 1e-10);
    }
    for code in 1..64 {
        let div = divergence(Divergence::Code(code)).unwrap();
        let gains = panner::gains(&speakers, [0.5, 0., 0.], [1.; 3], div);
        assert!((power(&gains) - 1.).abs() < 1e-10);
        assert!((gains[0] - gains[1]).abs() < 1e-10);
    }
    let full = panner::gains(&speakers, [0.5, 0., 0.], [0.; 3], 1.);
    assert!(full[2].abs() < 1e-10);
    assert!((full[0] - std::f64::consts::FRAC_1_SQRT_2).abs() < 1e-10);
    assert!(divergence(Divergence::Code(0)).is_err());
}

#[test]
fn screen_mapping_and_snap_use_ordered_global_targets() {
    let mut p = properties([0., 0., 0.]);
    p.other.screen_factor = 1.;
    let options = RenderOptions {
        layout: SpeakerLayout::Surround714,
        screen: Screen {
            width: 0.5,
            height: 0.5,
            origin_x: 0.5,
            origin_z: 0.1,
        },
    };
    assert_eq!(screen_scale([0., 0., 0.], &p, options), [0.25, 0., 0.1]);
    assert_eq!(screen_scale([0., 1., 0.], &p, options), [0., 1., 0.]);
    let renderer = SpeakerRenderer::new(RenderOptions::new(SpeakerLayout::Surround714)).unwrap();
    let mut p = properties([0.48, 0., 0.]);
    p.snap = true;
    p.other.width = [1.; 3];
    p.other.divergence = Divergence::Table(3);
    let gains = renderer.target(&p, None, false).unwrap();
    assert_eq!(gains[2], 1.);
    assert_eq!(power(&gains), 1.);
    assert!(
        SpeakerRenderer::new(RenderOptions {
            layout: SpeakerLayout::Stereo,
            screen: Screen {
                width: f64::NAN,
                ..Default::default()
            }
        })
        .is_err()
    );
}

#[test]
fn default_custom_and_disabled_trim_and_configuration_selection() {
    let layout = SpeakerLayout::Stereo;
    let speakers = layout.speakers();
    assert_eq!(
        trim_gain(layout, &speakers, [0.5, 0., 0.], false, None).unwrap(),
        1.
    );
    assert!(
        (trim_gain(layout, &speakers, [0.5, 1., 1.], false, None).unwrap()
            - 10f64.powf(-4.5 / 20.))
        .abs()
            < 1e-10
    );
    let mut common = CommonData {
        trim: Some(TrimMetadata::default()),
        ..Default::default()
    };
    common.trim.as_mut().unwrap().configurations[0] = TrimConfiguration {
        mode: TrimMode::Custom,
        centre: Some(TrimGain::Db(6.)),
        surround: Some(TrimGain::Db(-6.)),
        height: Some(TrimGain::Db(-12.)),
        ..Default::default()
    };
    assert!(
        (trim_gain(layout, &speakers, [0.5, 0., 0.], false, Some(&common)).unwrap()
            - 10f64.powf(6. / 20.))
        .abs()
            < 1e-10
    );
    assert!(
        (trim_gain(layout, &speakers, [0., 1., 1.], false, Some(&common)).unwrap()
            - 10f64.powf(-18. / 20.))
        .abs()
            < 1e-10
    );
    assert_eq!(
        trim_gain(layout, &speakers, [0., 1., 1.], true, Some(&common)).unwrap(),
        1.
    );
    for (layout, cfg) in [
        (SpeakerLayout::Surround51, 1),
        (SpeakerLayout::Surround71, 2),
        (SpeakerLayout::Surround514, 7),
        (SpeakerLayout::Surround714, 8),
    ] {
        common.trim.as_mut().unwrap().configurations[cfg].mode = TrimMode::Disabled;
        assert_eq!(
            trim_gain(
                layout,
                &layout.speakers(),
                [0.5, 1., 1.],
                false,
                Some(&common)
            )
            .unwrap(),
            1.
        );
    }
}

#[test]
fn normative_ramp_includes_update_sample_and_carries_across_frames() {
    let mut renderer = SpeakerRenderer::new(RenderOptions::new(SpeakerLayout::Stereo)).unwrap();
    let mut out = Vec::new();
    renderer
        .process_into(
            &metadata(properties([0., 0., 0.]), 2, 7),
            &[vec![1.; 6]],
            &mut out,
        )
        .unwrap();
    assert_eq!(out[0], [0., 0., 0.125, 0.25, 0.375, 0.5]);
    let reuse = AjocMetadata {
        objects: vec![ObjectMatrix::default()],
        upmix_metadata: vec![vec![]],
        ..Default::default()
    };
    renderer
        .process_into(&reuse, &[vec![1.; 6]], &mut out)
        .unwrap();
    assert_eq!(out[0], [0.625, 0.75, 0.875, 1., 1., 1.]);
    renderer.reset();
    renderer
        .process_into(&reuse, &[vec![1.; 6]], &mut out)
        .unwrap();
    assert_eq!(out[0], [0.; 6]);
}

#[test]
fn lfe_routes_to_discrete_channel_and_stereo_fold_policy() {
    for layout in [
        SpeakerLayout::Stereo,
        SpeakerLayout::Surround51,
        SpeakerLayout::Surround714,
    ] {
        let renderer = SpeakerRenderer::new(RenderOptions::new(layout)).unwrap();
        let gains = renderer
            .target(&properties([0.5, 0.5, 0.]), None, true)
            .unwrap();
        if layout == SpeakerLayout::Stereo {
            assert_eq!(gains, [0.5, 0.5]);
        } else {
            assert_eq!(gains[3], 1.);
            assert_eq!(power(&gains), 1.);
        }
    }
}

#[test]
fn invalid_metadata_is_transactional_and_overflow_resets_history() {
    let mut renderer = SpeakerRenderer::new(RenderOptions::new(SpeakerLayout::Stereo)).unwrap();
    let mut out = Vec::new();
    let m = metadata(properties([0., 0., 0.]), 0, 0);
    renderer.process_into(&m, &[vec![1.]], &mut out).unwrap();
    let mut bad = m.clone();
    bad.upmix_metadata[0][0].properties.other.width[1] = f32::NAN;
    assert!(renderer.process_into(&bad, &[vec![1.]], &mut out).is_err());
    assert!(out.is_empty());
    assert_eq!(renderer.ramps[0].current, [1., 0.]);
    let mut huge = m;
    huge.upmix_metadata[0][0].properties.gain_db = Some(15);
    assert!(
        renderer
            .process_into(&huge, &[vec![f32::MAX]], &mut out)
            .is_err()
    );
    assert!(renderer.ramps.is_empty());
    assert!(out.is_empty());
}

#[test]
fn room_center_has_independently_calculated_height_and_side_gains() {
    let renderer = SpeakerRenderer::new(RenderOptions::new(SpeakerLayout::Surround714)).unwrap();
    let gains = renderer.target(&properties([0.5; 3]), None, false).unwrap();
    for &v in &gains[..6] {
        assert!(v.abs() < 1e-10);
    }
    assert!((gains[6] - 0.5).abs() < 1e-10);
    assert!((gains[7] - 0.5).abs() < 1e-10);
    for &v in &gains[8..] {
        assert!((v - 0.5 * std::f64::consts::FRAC_1_SQRT_2).abs() < 1e-10);
    }
}

#[test]
fn interrupted_ramp_and_inactive_update_preserve_sample_order() {
    let mut m = metadata(properties([0., 0., 0.]), 0, 3);
    let mut inactive = properties([0.; 3]);
    inactive.active = false;
    m.upmix_metadata[0].extend([
        ObjectUpdate {
            properties: properties([1., 0., 0.]),
            timing: ObjectTiming { sample: 2, ramp: 1 },
        },
        ObjectUpdate {
            properties: inactive,
            timing: ObjectTiming { sample: 4, ramp: 0 },
        },
    ]);
    let mut renderer = SpeakerRenderer::new(RenderOptions::new(SpeakerLayout::Stereo)).unwrap();
    let mut out = Vec::new();
    renderer.process_into(&m, &[vec![1.; 6]], &mut out).unwrap();
    assert_eq!(out[0], [0.25, 0.5, 0.25, 0., 0., 0.]);
    assert_eq!(out[1], [0., 0., 0.5, 1., 0., 0.]);
    let mut bad = m;
    bad.upmix_metadata[0][0].properties.zone_mask = 6;
    assert!(
        renderer
            .process_into(&bad, &[vec![1.; 6]], &mut out)
            .is_err()
    );
    assert!(out.is_empty());
}

#[test]
fn same_plane_count_with_changed_lfe_meaning_requires_reset() {
    let mut m = metadata(properties([0., 0., 0.]), 0, 0);
    m.objects.push(ObjectMatrix::default());
    m.upmix_metadata.push(m.upmix_metadata[0].clone());
    let mut renderer = SpeakerRenderer::new(RenderOptions::new(SpeakerLayout::Surround51)).unwrap();
    let mut out = Vec::new();
    renderer
        .process_into(&m, &[vec![1.], vec![1.]], &mut out)
        .unwrap();
    m.objects.pop();
    assert!(
        renderer
            .process_into(&m, &[vec![1.], vec![1.]], &mut out)
            .is_err()
    );
    assert!(out.is_empty());
    renderer.reset();
    renderer
        .process_into(&m, &[vec![1.], vec![1.]], &mut out)
        .unwrap();
    assert_eq!(out[3], [1.]);
}
