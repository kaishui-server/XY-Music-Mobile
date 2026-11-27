use baka_av3a_core::render::{BedLayout, ObjectProjector};
#[path = "fixtures/object_vectors.rs"]
mod fixture;
#[test]
fn polar_projection_vectors() {
    let mut mismatches = Vec::new();
    let mut maximum = 0.0_f32;
    for config in [1, 2, 3, 7, 8, 9, 10] {
        let p = ObjectProjector::new(BedLayout::from_configuration(config).unwrap()).unwrap();
        for (index, case) in fixture::VECTORS.iter().enumerate() {
            if case.output != config {
                continue;
            }
            let gains = p.project(case.object).unwrap();
            let err = gains
                .direct()
                .iter()
                .zip(case.direct)
                .chain(gains.diffuse().iter().zip(case.diffuse))
                .map(|(a, b)| (*a - f32::from_bits(*b)).abs())
                .fold(0.0_f32, f32::max);
            maximum = maximum.max(err);
            if err > 5e-6 {
                mismatches.push((index, config, err));
            }
        }
    }
    println!(
        "vectors={} maximum_gain_error={maximum}",
        fixture::VECTORS.len()
    );
    assert!(mismatches.is_empty(), "{mismatches:?}");
}
