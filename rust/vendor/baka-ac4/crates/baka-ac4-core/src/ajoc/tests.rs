use super::*;

#[derive(Default)]
struct Bits(Vec<bool>);
impl Bits {
    fn put(&mut self, value: u32, n: u8) {
        for shift in (0..n).rev() {
            self.0.push(value & (1 << shift) != 0);
        }
    }
    fn bytes(&self) -> Vec<u8> {
        let mut bytes = vec![0; self.0.len().div_ceil(8)];
        for (i, &bit) in self.0.iter().enumerate() {
            bytes[i / 8] |= u8::from(bit) << (7 - i % 8);
        }
        bytes
    }
    fn object(&mut self, iframe: bool) {
        self.put(0, 1); // active
        if iframe {
            self.put(1, 1); // default basic information
            self.put(0, 17); // absolute position
            self.put(1, 1); // default zone
            self.put(1, 1); // default other properties
        } else {
            self.put(3, 2);
        } // reuse basic and render data
        self.put(0, 1); // no additional data
    }
}

fn payload(iframe: bool) -> Bits {
    let mut b = Bits::default();
    b.put(1, 1); // individual downmix timing
    b.put(0, 1);
    b.put(1, 3); // offset zero, one block
    b.put(0, 6);
    b.put(0, 2);
    b.object(iframe);
    b.put(0, 1); // no extension
    b.put(0, 3); // no decorrelators
    b.put(1, 1); // object present
    b.put(1, 2); // one matrix update
    b.put(0, 5);
    b.put(0, 6); // start=0, ramp=1
    b.put(7, 3);
    b.put(0, 1);
    b.put(0, 1); // one band, fine, dense
    b.put(u32::from(iframe), 1); // nodt
    if iframe {
        b.put(AJOC_HCB_DRY_FINE_F0_CW[60], AJOC_HCB_DRY_FINE_F0_LEN[60]);
    } else {
        b.put(1, 1); // time differential
        b.put(AJOC_HCB_DRY_FINE_DT_CW[101], AJOC_HCB_DRY_FINE_DT_LEN[101]);
    }
    b.put(1, 1);
    b.put(1, 1);
    b.put(0, 2);
    b.put(0, 1); // dialogue config, keep, max gain, empty mask
    b.put(0, 1);
    b.put(1, 1); // upmix derives downmix timing
    b.object(iframe);
    b
}

#[test]
fn authored_matrix_frequency_then_time_and_transactional_error() {
    let mut h = History::default();
    let key = payload(true);
    let frame = parse(
        &mut BitReader::new(&key.bytes()),
        key.0.len(),
        1,
        1,
        false,
        true,
        &mut h,
    )
    .unwrap();
    assert_eq!(frame.padding_bits, 0);
    assert_eq!(frame.upmix_blocks, 1);
    assert_eq!(
        frame.objects[0].dry[0][0].as_ref().unwrap().gains,
        [1025.0 / 1024.0]
    );
    let next = payload(false);
    assert!(
        parse(
            &mut BitReader::new(&next.bytes()),
            next.0.len() - 1,
            1,
            1,
            false,
            false,
            &mut h
        )
        .is_err()
    );
    let frame = parse(
        &mut BitReader::new(&next.bytes()),
        next.0.len(),
        1,
        1,
        false,
        false,
        &mut h,
    )
    .unwrap();
    let m = frame.objects[0].dry[0][0].as_ref().unwrap();
    assert!(m.time_delta);
    assert_eq!(m.values, [1]);
    assert_eq!(m.gains, [2255.0 / 2048.0]);
}

#[test]
fn modulo_frequency_sparse_zero_and_incompatible_time_history() {
    let mut previous = vec![vec![100, 100, 100]];
    let mut rows = vec![vec![Some(MatrixElement {
        time_delta: false,
        values: vec![100, 2, 100],
        gains: vec![],
    })]];
    reconstruct(&mut rows, &mut previous, 3, false, false, true).unwrap();
    assert_eq!(previous[0], [100, 1, 0]);
    let mut zero = vec![vec![None]];
    reconstruct(&mut zero, &mut previous, 3, false, false, true).unwrap();
    assert_eq!(previous[0], [50, 50, 50]);
    let mut delta = vec![vec![Some(MatrixElement {
        time_delta: true,
        values: vec![1, -1, 0],
        gains: vec![],
    })]];
    assert!(reconstruct(&mut delta, &mut previous, 3, false, false, false).is_err());
    reconstruct(&mut delta, &mut previous, 3, false, false, true).unwrap();
    assert_eq!(previous[0], [51, 49, 50]);
}

#[test]
fn bounded_payload_mutations_never_panic() {
    let source = payload(true);
    for bit in 0..source.0.len() {
        let mut bytes = source.bytes();
        bytes[bit / 8] ^= 1 << (7 - bit % 8);
        let _ = parse(
            &mut BitReader::new(&bytes),
            source.0.len(),
            1,
            1,
            false,
            true,
            &mut History::default(),
        );
    }
}

#[test]
fn every_bit_truncation_of_authored_payload_is_rejected() {
    let b = payload(true);
    for end in 0..b.0.len() {
        assert!(
            parse(
                &mut BitReader::new(&b.bytes()),
                end,
                1,
                1,
                false,
                true,
                &mut History::default()
            )
            .is_err(),
            "accepted {end}"
        );
    }
}

#[test]
fn all_codebook_symbols_roundtrip_with_exact_bit_consumption() {
    macro_rules! check {
        ($lens:ident, $codes:ident, $book:expr) => {
            for (symbol, (&len, &code)) in $lens.iter().zip(&$codes).enumerate() {
                let mut bits = Bits::default();
                bits.put(code, len);
                let bytes = bits.bytes();
                let mut reader = BitReader::new(&bytes);
                assert_eq!($book.decode(&mut reader).unwrap(), symbol as i32);
                assert_eq!(reader.bits_count(), len as usize);
            }
        };
    }
    check!(
        AJOC_HCB_DRY_FINE_F0_LEN,
        AJOC_HCB_DRY_FINE_F0_CW,
        codebooks()[0][0]
    );
    check!(
        AJOC_HCB_DRY_FINE_DF_LEN,
        AJOC_HCB_DRY_FINE_DF_CW,
        codebooks()[0][1]
    );
    check!(
        AJOC_HCB_DRY_FINE_DT_LEN,
        AJOC_HCB_DRY_FINE_DT_CW,
        codebooks()[0][2]
    );
    check!(
        AJOC_HCB_DRY_COARSE_F0_LEN,
        AJOC_HCB_DRY_COARSE_F0_CW,
        codebooks()[1][0]
    );
    check!(
        AJOC_HCB_DRY_COARSE_DF_LEN,
        AJOC_HCB_DRY_COARSE_DF_CW,
        codebooks()[1][1]
    );
    check!(
        AJOC_HCB_DRY_COARSE_DT_LEN,
        AJOC_HCB_DRY_COARSE_DT_CW,
        codebooks()[1][2]
    );
    check!(
        AJOC_HCB_WET_FINE_F0_LEN,
        AJOC_HCB_WET_FINE_F0_CW,
        codebooks()[2][0]
    );
    check!(
        AJOC_HCB_WET_FINE_DF_LEN,
        AJOC_HCB_WET_FINE_DF_CW,
        codebooks()[2][1]
    );
    check!(
        AJOC_HCB_WET_FINE_DT_LEN,
        AJOC_HCB_WET_FINE_DT_CW,
        codebooks()[2][2]
    );
    check!(
        AJOC_HCB_WET_COARSE_F0_LEN,
        AJOC_HCB_WET_COARSE_F0_CW,
        codebooks()[3][0]
    );
    check!(
        AJOC_HCB_WET_COARSE_DF_LEN,
        AJOC_HCB_WET_COARSE_DF_CW,
        codebooks()[3][1]
    );
    check!(
        AJOC_HCB_WET_COARSE_DT_LEN,
        AJOC_HCB_WET_COARSE_DT_CW,
        codebooks()[3][2]
    );
}
