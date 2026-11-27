pub fn integer(bytes: &mut Vec<u8>, value: i16) {
    bytes.extend(value.to_le_bytes());
}
pub fn float(bytes: &mut Vec<u8>, value: f32) {
    bytes.extend(value.to_le_bytes());
}
fn codec(bytes: &mut Vec<u8>, hyper: bool) {
    for activation in [4, 5] {
        integer(bytes, 1);
        for value in [0, 2, 1, activation, 1, 1, 1] {
            integer(bytes, value);
        }
        for value in [2.0, 0.0, 1.0, 0.25] {
            float(bytes, value);
        }
    }
    float(bytes, 1.25);
    let count = if hyper {
        integer(bytes, 2);
        float(bytes, 1.0);
        float(bytes, 2.0);
        2
    } else {
        1
    };
    for _ in 0..count {
        integer(bytes, 3);
    }
    for _ in 0..count {
        integer(bytes, 0);
    }
    for _ in 0..count {
        for value in [0u32, 32768, 65536] {
            bytes.extend(value.to_le_bytes());
        }
    }
}
pub fn fixture() -> Vec<u8> {
    let mut bytes = Vec::new();
    codec(&mut bytes, true);
    codec(&mut bytes, false);
    bytes
}
