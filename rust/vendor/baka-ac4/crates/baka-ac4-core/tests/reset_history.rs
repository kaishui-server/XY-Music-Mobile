use baka_ac4_core::Ac4Decoder;

fn framed_packets(source: &[u8]) -> Vec<&[u8]> {
    let mut packets = Vec::new();
    let mut offset = 0;
    while offset + 4 <= source.len() {
        let size = u16::from_be_bytes([source[offset + 2], source[offset + 3]]) as usize
            + 4
            + usize::from(source[offset + 1] == 0x41) * 2;
        packets.push(&source[offset..offset + size]);
        offset += size;
    }
    packets
}

#[test]
fn flush_matches_fresh_qmf_overlap_aspx_and_bypass_history() {
    std::thread::Builder::new()
        .stack_size(64 * 1024 * 1024)
        .spawn(|| {
            let p83 = framed_packets(include_bytes!("fixtures/p83_iframe_plus5.ac4"));
            let atsc3 = framed_packets(include_bytes!("fixtures/atsc3_iframe_plus5.ac4"));
            let stereo: &[u8] = include_bytes!("fixtures/htys_iframe_plus5.ac4");
            let mut htys = Vec::new();
            let mut offset = 0;
            for size in [1366, 1365, 1365, 1366, 1365, 1365] {
                htys.push(&stereo[offset..offset + size]);
                offset += size;
            }
            for packets in [&p83, &atsc3, &htys] {
                for bypass in [false, true] {
                    let mut used = Ac4Decoder::new().unwrap();
                    used.set_qmf_bypass(bypass);
                    used.set_ajoc_core_signals(true);
                    let mut actual = Vec::new();
                    for packet in packets {
                        used.decode_frame_into(packet, &mut actual).unwrap();
                    }
                    used.flush();
                    let mut fresh = Ac4Decoder::new().unwrap();
                    fresh.set_qmf_bypass(bypass);
                    fresh.set_ajoc_core_signals(true);
                    let mut expected = Vec::new();
                    for (index, packet) in packets.iter().enumerate() {
                        let a = used
                            .decode_frame_into(packet, &mut actual)
                            .unwrap()
                            .unwrap();
                        let b = fresh
                            .decode_frame_into(packet, &mut expected)
                            .unwrap()
                            .unwrap();
                        assert_eq!(
                            (a.sample_rate, a.channel_mask, a.nb_samples, a.audio_kind),
                            (b.sample_rate, b.channel_mask, b.nb_samples, b.audio_kind)
                        );
                        assert_eq!(actual.len(), expected.len());
                        for (left, right) in actual.iter().zip(&expected) {
                            assert_eq!(left.len(), right.len());
                            assert!(
                                left.iter()
                                    .zip(right)
                                    .all(|(a, b)| a.to_bits() == b.to_bits()),
                                "frame {index}, bypass={bypass}"
                            );
                        }
                    }
                }
            }
        })
        .unwrap()
        .join()
        .unwrap();
}
