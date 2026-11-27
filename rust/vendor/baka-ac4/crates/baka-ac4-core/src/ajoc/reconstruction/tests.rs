use super::*;
use crate::ajoc::{DataPoint, MatrixElement};

struct Probe {
    calls: usize,
    resets: usize,
    fail: bool,
    nonfinite: bool,
    last_input: QmfSlot,
}

impl Default for Probe {
    fn default() -> Self {
        Self {
            calls: 0,
            resets: 0,
            fail: false,
            nonfinite: false,
            last_input: [[0.0; 2]; 64],
        }
    }
}

impl Decorrelation for Probe {
    fn process(&mut self, _: usize, input: &QmfSlot, output: &mut QmfSlot) -> Result<()> {
        self.calls += 1;
        self.last_input = *input;
        if self.fail {
            return Err(invalid("authored backend failure"));
        }
        *output = *input; // Deliberate identity test probe, not a decorrelator.
        if self.nonfinite {
            output[0][0] = f32::NAN;
        }
        Ok(())
    }
    fn reset(&mut self) {
        self.resets += 1;
    }
}

fn element(gain: f32, bands: usize) -> Option<MatrixElement> {
    Some(MatrixElement {
        time_delta: false,
        values: vec![],
        gains: vec![gain; bands],
    })
}

fn metadata(dry: &[f32], wet: &[f32], ramp: u8) -> AjocMetadata {
    assert_eq!(dry.len(), wet.len());
    AjocMetadata {
        decorrelators: vec![true],
        points: vec![DataPoint { start: 0, ramp }],
        objects: dry
            .iter()
            .zip(wet)
            .map(|(&d, &w)| ObjectMatrix {
                present: true,
                bands: 1,
                coarse: false,
                dry: vec![vec![element(d, 1)]],
                wet: vec![vec![element(w, 1)]],
            })
            .collect(),
        ..Default::default()
    }
}

fn input(slots: usize) -> QmfPlanes {
    vec![vec![[[1.0, -2.0]; 64]; slots]]
}

#[test]
fn all_parameter_band_maps_match_normative_table_rows() {
    let rows = [
        (1, [0, 0, 0, 0, 0, 0, 0, 0]),
        (2, [1, 1, 1, 1, 1, 1, 0, 0]),
        (3, [2, 2, 2, 2, 2, 1, 0, 0]),
        (4, [3, 3, 3, 3, 2, 2, 1, 0]),
        (5, [4, 4, 4, 3, 3, 2, 1, 0]),
        (6, [5, 5, 4, 4, 3, 2, 1, 0]),
        (7, [6, 6, 5, 4, 3, 2, 1, 0]),
        (8, [7, 7, 5, 5, 3, 2, 1, 0]),
        (9, [8, 8, 6, 5, 4, 2, 1, 0]),
        (10, [9, 9, 6, 6, 4, 3, 1, 0]),
        (11, [10, 9, 6, 6, 4, 3, 1, 0]),
        (12, [11, 10, 7, 6, 4, 3, 1, 0]),
        (14, [12, 10, 7, 6, 4, 3, 1, 0]),
        (16, [13, 11, 8, 7, 5, 3, 2, 0]),
        (18, [14, 11, 8, 7, 5, 3, 2, 0]),
        (20, [15, 12, 9, 7, 5, 3, 2, 0]),
        (23, [16, 12, 9, 7, 5, 3, 2, 0]),
        (26, [17, 13, 10, 8, 6, 4, 2, 0]),
        (30, [18, 13, 10, 8, 6, 4, 2, 0]),
        (35, [19, 13, 10, 8, 6, 4, 2, 0]),
        (41, [20, 14, 11, 8, 6, 4, 2, 0]),
        (48, [21, 14, 11, 8, 6, 4, 2, 0]),
        (64, [22, 14, 11, 8, 6, 4, 2, 0]),
    ];
    let mut start = 0;
    for (end, expected) in rows {
        for sb in start..end {
            for (bands, band) in [23, 15, 12, 9, 7, 5, 3, 1].into_iter().zip(expected) {
                assert_eq!(
                    parameter_band(bands, sb).unwrap(),
                    band,
                    "{bands} bands, sb {sb}"
                );
            }
        }
        start = end;
    }
    assert!(parameter_band(2, 0).is_err());
    assert!(parameter_band(23, 64).is_err());
}

#[test]
fn dry_wet_complex_mix_and_absolute_wet_prematrix() {
    let m = metadata(&[1.0, 2.0], &[-0.5, 1.0], 1);
    let mut backend = Probe::default();
    let mut engine = Reconstructor::default();
    let mut output = Vec::new();
    engine
        .process_into(&m, &input(3), &mut backend, &mut output)
        .unwrap();
    assert_eq!(backend.calls, 3);
    assert_eq!(backend.last_input[0], [2.5, -5.0]);
    assert_eq!(output[0][0][0], [0.0, 0.0]);
    assert_eq!(output[0][1][0], [-0.25, 0.5]);
    assert_eq!(output[1][1][0], [4.5, -9.0]);
    assert_eq!(output[1][2][63], [4.5, -9.0]);
}

#[test]
fn ramp_crosses_frames_without_new_points_and_reaches_target_once() {
    let m = metadata(&[1.0], &[0.0], 64);
    let mut backend = Probe::default();
    let mut engine = Reconstructor::default();
    let mut out = Vec::new();
    engine
        .process_into(&m, &input(32), &mut backend, &mut out)
        .unwrap();
    assert_eq!(out[0][31][0][0], 31.0 / 64.0);
    let mut carry = m.clone();
    carry.points.clear();
    carry.objects[0].dry.clear();
    carry.objects[0].wet.clear();
    carry.objects[0].bands = 0;
    engine
        .process_into(&carry, &input(32), &mut backend, &mut out)
        .unwrap();
    assert_eq!(out[0][0][0][0], 0.5);
    assert_eq!(out[0][31][0][0], 63.0 / 64.0);
    engine
        .process_into(&carry, &input(32), &mut backend, &mut out)
        .unwrap();
    assert!(out[0].iter().all(|slot| slot[0] == [1.0, -2.0]));
}

#[test]
fn second_point_interrupts_ramp_sparse_zeros_and_disabled_decorrelation() {
    let mut m = metadata(&[1.0], &[1.0], 4);
    m.decorrelators[0] = false;
    m.points.push(DataPoint { start: 2, ramp: 1 });
    m.objects[0].dry.push(vec![None]);
    m.objects[0].wet.push(vec![None]);
    let mut backend = Probe::default();
    let mut out = Vec::new();
    Reconstructor::default()
        .process_into(&m, &input(5), &mut backend, &mut out)
        .unwrap();
    assert_eq!(backend.calls, 0);
    assert_eq!(
        out[0].iter().map(|x| x[0][0]).collect::<Vec<_>>(),
        [0.0, 0.25, 0.5, 0.0, 0.0]
    );
}

#[test]
fn malformed_input_is_rejected_before_backend_and_retains_history() {
    let mut m = metadata(&[1.0], &[0.0], 1);
    let mut engine = Reconstructor::default();
    let mut backend = Probe::default();
    let mut out = Vec::new();
    engine
        .process_into(&m, &input(2), &mut backend, &mut out)
        .unwrap();
    let calls = backend.calls;
    m.objects[0].dry[0][0].as_mut().unwrap().gains.clear();
    assert!(
        engine
            .process_into(&m, &input(2), &mut backend, &mut out)
            .is_err()
    );
    assert!(out.is_empty());
    assert_eq!(backend.calls, calls);
    m.points.clear();
    engine
        .process_into(&m, &input(1), &mut backend, &mut out)
        .unwrap();
    assert_eq!(out[0][0][0], [1.0, -2.0]);
    let mut nan = input(2);
    nan[0][0][0][0] = f32::NAN;
    assert!(
        engine
            .process_into(&m, &nan, &mut backend, &mut out)
            .is_err()
    );
}

#[test]
fn backend_failure_and_nonfinite_output_reset_both_histories() {
    for nonfinite in [false, true] {
        let m = metadata(&[1.0], &[1.0], 1);
        let mut engine = Reconstructor::default();
        let mut backend = Probe {
            fail: !nonfinite,
            nonfinite,
            ..Default::default()
        };
        let mut out = Vec::new();
        assert!(
            engine
                .process_into(&m, &input(2), &mut backend, &mut out)
                .is_err()
        );
        assert!(out.is_empty());
        assert!(engine.state.is_none());
        assert_eq!(backend.resets, 1);
        backend.fail = false;
        backend.nonfinite = false;
        engine
            .process_into(&m, &input(2), &mut backend, &mut out)
            .unwrap();
        assert_eq!(out[0][0][0], [0.0, 0.0]);
        assert_eq!(out[0][1][0], [2.0, -4.0]);
    }
}
