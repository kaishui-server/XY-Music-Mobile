use super::*;
use crate::ajoc::ObjectMatrix;
use crate::ajoc::oamd::{ObjectTiming, ObjectUpdate};

fn update(sample: u16, ramp: u16, x: f32, db: Option<i16>) -> ObjectUpdate {
    ObjectUpdate {
        timing: ObjectTiming { sample, ramp },
        properties: ObjectProperties {
            active: true,
            gain_db: db,
            position: [x, 0.0, 0.0],
            ..Default::default()
        },
    }
}
fn metadata(updates: Vec<Vec<ObjectUpdate>>, lfe: bool) -> AjocMetadata {
    AjocMetadata {
        objects: vec![ObjectMatrix::default(); updates.len() - usize::from(lfe)],
        upmix_metadata: updates,
        ..Default::default()
    }
}

#[test]
fn gain_and_hard_panning_preserve_left_right_identity() {
    let m = metadata(
        vec![
            vec![update(0, 0, 0.0, Some(0))],
            vec![update(0, 0, 1.0, Some(-6))],
        ],
        false,
    );
    let mut out = Vec::new();
    StereoPreview::default()
        .process_into(&m, &[vec![1.0, 2.0], vec![2.0, -1.0]], &mut out)
        .unwrap();
    assert_eq!(out[0], [1.0, 2.0]);
    assert!((out[1][0] - 1.0023744).abs() < 1e-6);
    assert!((out[1][1] + 0.5011872).abs() < 1e-6);
}

#[test]
fn center_has_equal_power_and_lfe_has_explicit_half_gain() {
    let p = update(0, 0, 0.5, Some(0)).properties;
    let gains = panning(&p, false);
    assert!((gains[0] - gains[1]).abs() < 1e-7);
    assert!((gains.iter().map(|v| v * v).sum::<f32>() - 1.0).abs() < 1e-6);
    let m = metadata(
        vec![
            vec![update(0, 0, 0.0, Some(0))],
            vec![update(0, 0, 1.0, None)],
        ],
        true,
    );
    let mut out = Vec::new();
    StereoPreview::default()
        .process_into(&m, &[vec![1.0; 3], vec![5.0; 3]], &mut out)
        .unwrap();
    assert_eq!(out, [vec![0.5; 3], vec![0.5; 3]]);
}

#[test]
fn timing_ramps_carry_across_frames_without_updates_and_reset() {
    let mut renderer = StereoPreview::default();
    let mut out = Vec::new();
    let m = metadata(vec![vec![update(2, 8, 0.0, Some(0))]], false);
    renderer
        .process_into(&m, &[vec![1.0; 6]], &mut out)
        .unwrap();
    assert_eq!(out[0], [0.0, 0.0, 0.0, 0.125, 0.25, 0.375]);
    let reuse = metadata(vec![vec![]], false);
    renderer
        .process_into(&reuse, &[vec![1.0; 6]], &mut out)
        .unwrap();
    assert_eq!(out[0], [0.5, 0.625, 0.75, 0.875, 1.0, 1.0]);
    renderer.reset();
    renderer
        .process_into(&reuse, &[vec![1.0; 6]], &mut out)
        .unwrap();
    assert_eq!(out, [vec![0.0; 6], vec![0.0; 6]]);
}

#[test]
fn inactive_update_mutes_and_second_update_interrupts_ramp() {
    let mut mute = update(4, 0, 0.0, Some(0));
    mute.properties.active = false;
    let m = metadata(
        vec![vec![
            update(0, 8, 0.0, Some(0)),
            update(2, 1, 1.0, Some(0)),
            mute,
        ]],
        false,
    );
    let mut out = Vec::new();
    StereoPreview::default()
        .process_into(&m, &[vec![1.0; 6]], &mut out)
        .unwrap();
    assert_eq!(out[0], [0.0, 0.125, 0.25, 0.0, 0.0, 0.0]);
    assert_eq!(out[1], [0.0, 0.0, 0.0, 1.0, 0.0, 0.0]);
}

#[test]
fn invalid_inputs_do_not_advance_history_and_arithmetic_failure_clears_it() {
    let mut renderer = StereoPreview::default();
    let mut out = Vec::new();
    let m = metadata(vec![vec![update(0, 0, 0.0, Some(0))]], false);
    renderer.process_into(&m, &[vec![1.0]], &mut out).unwrap();
    let mut bad = m.clone();
    bad.upmix_metadata[0][0].properties.position[0] = f32::NAN;
    assert!(renderer.process_into(&bad, &[vec![1.0]], &mut out).is_err());
    assert!(out.is_empty());
    let reuse = metadata(vec![vec![]], false);
    renderer
        .process_into(&reuse, &[vec![1.0]], &mut out)
        .unwrap();
    assert_eq!(out[0], [1.0]);
    let boost = metadata(vec![vec![update(0, 0, 0.0, Some(15))]], false);
    assert!(
        renderer
            .process_into(&boost, &[vec![f32::MAX]], &mut out)
            .is_err()
    );
    assert!(out.is_empty());
    assert!(renderer.ramps.is_empty());
}
