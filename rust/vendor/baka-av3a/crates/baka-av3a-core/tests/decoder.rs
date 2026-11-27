use baka_av3a_core::{
    Error, FrameHeader, decoder::Decoder, model::HyperModel, payload_crc, shaping::LsfCodebooks,
};
use std::sync::Arc;
#[path = "fixtures/bed_frame.rs"]
mod bed_frame;
#[path = "fixtures/lsf_asset.rs"]
mod lsf_asset;
#[path = "fixtures/model_record.rs"]
mod model_record;

fn checksum(packet: &mut [u8]) {
    let crc = payload_crc(&packet[7..]);
    packet[3] = (packet[3] & 0xe0) | (crc >> 11) as u8;
    packet[4] = (packet[4] & 0x1f) | (((crc >> 8) as u8 & 7) << 5);
    packet[6] = crc as u8;
}

fn configured() -> Decoder {
    Decoder::new(
        Arc::new(HyperModel::parse(&model_record::fixture()).unwrap()),
        Arc::new(LsfCodebooks::parse(&lsf_asset::asset()).unwrap()),
    )
}

#[test]
fn continuous_pcm_reset_and_error_state() {
    let mut packet = bed_frame::frame(true);
    checksum(&mut packet);
    FrameHeader::validate_crc(&packet).unwrap();
    let mut decoder = configured();
    let first = decoder.decode(&packet).unwrap();
    assert_eq!((first.channels, first.samples.len()), (12, 12288));
    let mut untouched = decoder.clone();
    let mut bad = packet.clone();
    bad[100] ^= 1;
    assert_eq!(
        decoder.decode(&bad).unwrap_err(),
        Error::Invalid("frame CRC")
    );
    let mut bad = packet.clone();
    bad[7] |= 0x80;
    checksum(&mut bad);
    assert!(decoder.decode(&bad).is_err());
    let mut changed = packet.clone();
    changed[5] = (changed[5] & !0x30) | 0x20;
    assert_eq!(
        decoder.decode(&changed).unwrap_err(),
        Error::Unsupported("decoder configuration change")
    );
    assert_eq!(decoder.decoded_frames(), 1);
    assert_eq!(
        decoder.decode(&packet).unwrap().samples,
        untouched.decode(&packet).unwrap().samples
    );
    decoder.reset();
    assert_eq!(decoder.decoded_frames(), 0);
    assert_eq!(decoder.decode(&packet).unwrap().samples, first.samples);
}

#[test]
fn elementary_chunks_eof_and_buffer_limit() {
    use baka_av3a_core::stream::ElementaryDecoder;
    let mut packet = bed_frame::frame(true);
    checksum(&mut packet);
    let expected = configured().decode(&packet).unwrap();
    let mut stream = ElementaryDecoder::new(configured());
    for &byte in &packet[..packet.len() - 1] {
        stream.push(&[byte]).unwrap();
        assert!(stream.next_frame().unwrap().is_none());
    }
    stream.push(&packet[packet.len() - 1..]).unwrap();
    assert_eq!(
        stream.next_frame().unwrap().unwrap().samples,
        expected.samples
    );
    assert_eq!((stream.buffered_bytes(), stream.decoded_frames()), (0, 1));
    stream.finish();
    assert!(stream.next_frame().unwrap().is_none());
    assert!(stream.push(&[]).is_err());
    stream.reset();
    stream.push(&packet[..packet.len() - 1]).unwrap();
    stream.finish();
    assert_eq!(stream.next_frame().unwrap_err(), Error::Truncated);
    assert_eq!(stream.decoded_frames(), 0);
    stream.reset();
    stream
        .push(&vec![0; ElementaryDecoder::MAX_BUFFER])
        .unwrap();
    let before = stream.buffered_bytes();
    assert!(stream.push(&[0]).is_err());
    assert_eq!(stream.buffered_bytes(), before);
}

#[test]
fn pcm_rounding_and_clipping() {
    let pcm = baka_av3a_core::decoder::PcmFrame {
        sample_rate: 48000,
        channels: 1,
        metadata: Default::default(),
        samples: vec![-2.0, -1.0, -0.5 / 32768.0, 0.5 / 32768.0, 1.0, 2.0],
    };
    assert_eq!(pcm.to_i16(), [-32768, -32768, 0, 1, 32767, 32767]);
}
