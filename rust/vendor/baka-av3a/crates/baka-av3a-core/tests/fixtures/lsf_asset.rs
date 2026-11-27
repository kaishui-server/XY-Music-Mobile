pub fn asset() -> Vec<u8> {
    let mut bytes = b"AV3LSF01".to_vec();
    for i in 1..=16 {
        bytes.extend((1400.0 * i as f32).to_le_bytes());
    }
    bytes.resize(43976, 0);
    bytes
}
