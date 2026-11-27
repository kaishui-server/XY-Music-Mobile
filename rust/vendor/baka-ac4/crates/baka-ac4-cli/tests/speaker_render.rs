//! Optional full recordings; media is never included in the repository.
use baka_ac4_cli::mp4;
use baka_ac4_core::ajoc::render::{RenderOptions, Screen, SpeakerLayout};
use baka_ac4_core::{Ac4Decoder, AudioKind};

#[test]
#[ignore = "set BAKA_AC4_IMMERSIVE_DIR to a local acceptance sample directory"]
fn complete_tiers_render_all_supported_speaker_layouts_and_reset() {
    std::thread::Builder::new()
        .stack_size(64 * 1024 * 1024)
        .spawn(|| {
            let root = std::path::PathBuf::from(
                std::env::var_os("BAKA_AC4_IMMERSIVE_DIR").expect("sample directory"),
            );
            for quality in ["dolbyajoc448", "dolbyajoc1500"] {
                let bytes = std::fs::read(root.join(format!("{quality}.mp4"))).unwrap();
                let track = mp4::read_ac4_track(&bytes).unwrap();
                for layout in [
                    SpeakerLayout::Stereo,
                    SpeakerLayout::Surround51,
                    SpeakerLayout::Surround71,
                    SpeakerLayout::Surround514,
                    SpeakerLayout::Surround714,
                ] {
                    let started = std::time::Instant::now();
                    let options = RenderOptions::new(layout);
                    let mut decoder = Ac4Decoder::new().unwrap();
                    decoder.set_ajoc_render(Some(options)).unwrap();
                    let mut pcm = Vec::new();
                    let mut first = Vec::new();
                    let mut peaks = vec![0f32; layout.channels()];
                    for (index, &(offset, size)) in track.samples.iter().enumerate() {
                        decoder.set_ajoc_render(Some(options)).unwrap();
                        let frame = decoder
                            .decode_frame_into(
                                &bytes[offset as usize..offset as usize + size as usize],
                                &mut pcm,
                            )
                            .unwrap_or_else(|e| panic!("{quality} {layout:?} frame {index}: {e}"))
                            .unwrap();
                        assert_eq!(frame.audio_kind, AudioKind::AjocSpeakerFeeds);
                        assert_eq!(frame.channel_mask, layout.channel_mask());
                        assert_eq!(pcm.len(), layout.channels());
                        for (j, plane) in pcm.iter().enumerate() {
                            assert_eq!(plane.len(), frame.nb_samples);
                            for &v in plane {
                                assert!(v.is_finite());
                                peaks[j] = peaks[j].max(v.abs());
                            }
                        }
                        if index < 6 {
                            first.push(pcm.clone());
                        }
                    }
                    assert!(
                        peaks.iter().all(|&v| v > 0.00001 && v < 100.),
                        "{quality} {layout:?}: {peaks:?}"
                    );
                    decoder.flush();
                    for (index, &(offset, size)) in track.samples[..6].iter().enumerate() {
                        decoder
                            .decode_frame_into(
                                &bytes[offset as usize..offset as usize + size as usize],
                                &mut pcm,
                            )
                            .unwrap()
                            .unwrap();
                        assert_eq!(pcm, first[index], "{quality} {layout:?} replay {index}");
                    }
                    let invalid = RenderOptions {
                        layout,
                        screen: Screen {
                            width: f64::NAN,
                            ..Default::default()
                        },
                    };
                    assert!(decoder.set_ajoc_render(Some(invalid)).is_err());
                    decoder.set_ajoc_render(None).unwrap();
                    let (offset, size) = track.samples[0];
                    let packet = &bytes[offset as usize..offset as usize + size as usize];
                    assert_eq!(
                        decoder
                            .decode_frame_into(packet, &mut pcm)
                            .unwrap()
                            .unwrap()
                            .audio_kind,
                        AudioKind::AjocObjectSignals
                    );
                    decoder.set_ajoc_render(Some(options)).unwrap();
                    decoder
                        .decode_frame_into(packet, &mut pcm)
                        .unwrap()
                        .unwrap();
                    assert_eq!(pcm, first[0]);
                    assert!(decoder.decode_frame_into(&[0; 7], &mut pcm).is_err());
                    assert!(pcm.is_empty());
                    assert!(decoder.ajoc_metadata().is_none());
                    eprintln!(
                        "{quality} {layout:?}: {} frames, peaks {peaks:?}, {:.3}s",
                        track.samples.len(),
                        started.elapsed().as_secs_f64()
                    );
                }
            }
        })
        .unwrap()
        .join()
        .unwrap();
}
