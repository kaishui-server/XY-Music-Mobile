use baka_av3a_core::shaping::LsfCodebooks;
#[path = "fixtures/lsf_asset.rs"]
mod lsf_asset;

#[test]
fn external_codebooks_indices_and_truncation() {
    let bytes = lsf_asset::asset();
    let codebooks = LsfCodebooks::parse(&bytes).unwrap();
    let expected: Vec<_> = (1..=16).map(|i| 1400.0 * i as f32).collect();
    assert_eq!(codebooks.frequencies(&[0; 7]).unwrap().as_slice(), expected);
    assert_eq!(codebooks.frequencies(&[0; 5]).unwrap().as_slice(), expected);
    for indices in [
        &[0u8, 0, 128, 0, 0, 0, 0][..],
        &[0; 6][..],
        &[0, 0, 0, 0, 64][..],
    ] {
        assert!(codebooks.frequencies(indices).is_err());
    }
    let gains = codebooks.gains(&[0; 7]).unwrap();
    assert!(gains.iter().all(|v| v.is_finite() && *v > 0.0));
    let mut spectrum = [1.0; 1024];
    codebooks.apply(&mut spectrum, &[0; 7]).unwrap();
    assert_eq!(spectrum, gains);
    for n in 0..bytes.len() {
        assert!(LsfCodebooks::parse(&bytes[..n]).is_err());
    }
    let mut bad = bytes.clone();
    bad[0] = 0;
    assert!(LsfCodebooks::parse(&bad).is_err());
    let mut bad = bytes.clone();
    bad[8..12].copy_from_slice(&f32::NAN.to_le_bytes());
    assert!(LsfCodebooks::parse(&bad).is_err());
    let mut bad = bytes;
    bad.push(0);
    assert!(LsfCodebooks::parse(&bad).is_err());
}
