use baka_ac4_core::{Ac4Decoder, AudioKind};

// Synthetic TOC: v2, 48 kHz, 2048 samples, dynamic downmix/upmix assignment,
// two preceding metadata substreams (19 + 8 bytes), then audio at byte 50.
// The audio essence is authored silence, not an excerpt from a recording.
fn silent_core(count: usize) -> Vec<u8> {
    assert!(count == 7 || count == 11);
    let mut packet = vec![0; 1325];
    packet[..23].copy_from_slice(&[
        0xbf, 0xbe, 0xfb, 0xc0, 0xd2, 0x00, 0x9a, 0x39, 0xd5, 0x56, 0xd3, 0x80, 0x12, 0xb7, 0x55,
        0xf1, 0x34, 0x30, 0x26, 0x02, 0x27, 0xda, 0x00,
    ]);
    if count == 7 {
        packet[14] = 0x35;
    }
    packet[50..52].copy_from_slice(&(512u16 << 1).to_be_bytes());
    packet
}

fn large_stack(f: impl FnOnce() + Send + 'static) {
    std::thread::Builder::new()
        .stack_size(64 * 1024 * 1024)
        .spawn(f)
        .unwrap()
        .join()
        .unwrap();
}

#[test]
fn core_is_explicit_and_dynamic_signals_are_not_speaker_feeds() {
    large_stack(|| {
        for count in [7, 11] {
            let packet = silent_core(count);
            let mut decoder = Ac4Decoder::new().unwrap();
            assert!(decoder.decode_frame(&packet).is_err());
            decoder.set_ajoc_core_signals(true);
            let frame = decoder.decode_frame(&packet).unwrap().unwrap();
            assert_eq!(frame.audio_kind, AudioKind::AjocCoreSignals);
            assert_eq!(frame.channel_mask, 0);
            assert_eq!(frame.data.len(), count + 1);
            assert_eq!(frame.sample_rate, 48000);
            assert_eq!(frame.nb_samples, 2048);
            assert!(frame.key_frame);
            assert!(frame.data.iter().flatten().all(|&x| x == 0.0));
            decoder.set_ajoc_core_signals(false);
            assert!(decoder.decode_frame(&packet).is_err());
        }
    });
}

#[test]
fn truncated_declared_substreams_never_produce_pcm() {
    large_stack(|| {
        let packet = silent_core(11);
        let mut decoder = Ac4Decoder::new().unwrap();
        decoder.set_ajoc_core_signals(true);
        for length in [
            0, 1, 2, 4, 8, 22, 23, 49, 50, 51, 52, 100, 300, 562, 1000, 1324,
        ] {
            let result = decoder.decode_frame(&packet[..length]);
            assert!(!matches!(result, Ok(Some(_))), "accepted {length} bytes");
        }
        assert!(decoder.decode_frame(&packet).unwrap().is_some());
    });
}

#[test]
fn bounded_toc_mutations_are_panic_free_in_core_mode() {
    large_stack(|| {
        let original = silent_core(11);
        let mut decoder = Ac4Decoder::new().unwrap();
        decoder.set_ajoc_core_signals(true);
        for bit in 0..23 * 8 {
            let mut packet = original.clone();
            packet[bit / 8] ^= 1 << (bit % 8);
            let _ = decoder.decode_frame(&packet);
        }
    });
}
