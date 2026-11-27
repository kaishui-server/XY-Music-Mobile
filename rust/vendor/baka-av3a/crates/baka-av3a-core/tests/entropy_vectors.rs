use baka_av3a_core::entropy::{Distribution, EntropyModel, decode};
use baka_av3a_core::{BitReader, quantization::QuantizedChannel};

struct Cdf<'a> {
    values: &'a [u32],
    offset: i32,
}
struct Vector<'a> {
    cdfs: &'a [Cdf<'a>],
    indices: &'a [usize],
    expected: &'a [i32],
    encoded: &'a [u8],
}
include!("fixtures/entropy_vectors.rs");

#[test]
fn independently_encoded_vectors_match_exactly() {
    let mut total = 0;
    for (index, vector) in VECTORS.iter().enumerate() {
        let cdfs: Vec<_> = vector
            .cdfs
            .iter()
            .map(|d| Distribution::new(d.values, 16, d.offset).unwrap())
            .collect();
        let decoded = decode(vector.encoded, &cdfs, vector.indices).unwrap();
        assert_eq!(decoded.values, vector.expected, "vector {index}");
        assert!(decoded.bytes_consumed <= vector.encoded.len());
        assert!(
            decoded.zero_padding_bytes <= 4,
            "vector {index}: {} padding bytes",
            decoded.zero_padding_bytes
        );
        total += decoded.values.len();
    }
    println!(
        "{} independent vectors, {total} exact coefficients",
        VECTORS.len()
    );
}

#[test]
fn invalid_offsets_and_indices_return_errors() {
    let cdf = Distribution::new(&[0, 0, 65536], 16, i32::MAX).unwrap();
    assert!(decode(&[], &[cdf], &[0]).is_err());
    let vector = &VECTORS[0];
    assert!(decode(vector.encoded, &[], vector.indices).is_err());
}

#[test]
fn model_record_to_coefficients_matches_and_leaves_following_fields() {
    for vector in VECTORS {
        let mut bytes = Vec::new();
        for cdf in vector.cdfs {
            bytes.extend((cdf.values.len() as u16).to_le_bytes());
        }
        for cdf in vector.cdfs {
            bytes.extend((cdf.offset as i16).to_le_bytes());
        }
        for cdf in vector.cdfs {
            for value in cdf.values {
                bytes.extend(value.to_le_bytes());
            }
        }
        let expected_size = bytes.len();
        bytes.extend([0xfa, 0xce]);
        let (model, consumed) = EntropyModel::read(&bytes, vector.cdfs.len()).unwrap();
        assert_eq!(consumed, expected_size);
        assert_eq!(&bytes[consumed..], &[0xfa, 0xce]);
        assert_eq!(model.distribution_count(), vector.cdfs.len());
        assert_eq!(
            model.decode(vector.encoded, vector.indices).unwrap().values,
            vector.expected
        );
        for n in 0..expected_size {
            assert!(EntropyModel::read(&bytes[..n], vector.cdfs.len()).is_err());
        }
    }
}

#[test]
fn malformed_model_metadata_is_bounded() {
    assert!(EntropyModel::read(&[], 0).is_err());
    assert!(EntropyModel::read(&[], 1025).is_err());
    assert!(EntropyModel::read(&[0, 0, 0, 0], 1).is_err());
    let mut oversized = vec![255; 1024 * 4];
    oversized[2048..].fill(0);
    assert!(EntropyModel::read(&oversized, 1024).is_err());
    let mut invalid = vec![3, 0, 0, 0];
    invalid.extend([1u32, 8, 65536].into_iter().flat_map(u32::to_le_bytes));
    assert!(EntropyModel::read(&invalid, 1).is_err());
}

#[test]
fn unaligned_quantized_channel_to_context_and_base_coefficients() {
    let context = &VECTORS[0];
    let base = &VECTORS[11];
    assert!(context.encoded.len() <= 255);
    let mut fields = vec![
        (5u32, 3u8),
        (1, 1),
        (100, 7),
        (3, 3),
        (6, 3),
        (context.encoded.len() as u32, 8),
    ];
    fields.extend(
        context
            .encoded
            .iter()
            .chain(base.encoded)
            .map(|b| (u32::from(*b), 8)),
    );
    let bits: usize = fields.iter().map(|(_, n)| usize::from(*n)).sum();
    let mut packet = vec![0u8; bits.div_ceil(8)];
    let mut position = 0;
    for (value, width) in fields {
        for n in (0..width).rev() {
            packet[position / 8] |= (((value >> n) & 1) as u8) << (7 - position % 8);
            position += 1;
        }
    }
    let mut reader = BitReader::with_bit_len(&packet, bits).unwrap();
    assert_eq!(reader.read(3).unwrap(), 5);
    let channel = QuantizedChannel::parse(
        &mut reader,
        0,
        2,
        context.encoded.len() + base.encoded.len(),
    )
    .unwrap();
    assert!(channel.amplified);
    assert_eq!(channel.scale_index, 100);
    assert_eq!(channel.noise_indices, [3, 6]);
    assert_eq!(reader.remaining(), 0);
    for (vector, bytes) in [(context, channel.context), (base, channel.base)] {
        let cdfs: Vec<_> = vector
            .cdfs
            .iter()
            .map(|d| Distribution::new(d.values, 16, d.offset).unwrap())
            .collect();
        assert_eq!(
            decode(&bytes, &cdfs, vector.indices).unwrap().values,
            vector.expected
        );
    }
}
