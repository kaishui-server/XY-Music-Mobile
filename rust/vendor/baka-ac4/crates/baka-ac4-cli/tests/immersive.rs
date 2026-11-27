//! Optional local-media acceptance; no copyrighted recordings or URLs embedded.
use baka_ac4_cli::mp4;
use baka_ac4_core::{Ac4Decoder, AudioKind};

#[test]
#[ignore = "set BAKA_AC4_IMMERSIVE_DIR to a local acceptance sample directory"]
fn complete_ajoc_tiers_have_finite_sample_timed_stereo_preview() {
    std::thread::Builder::new().stack_size(64*1024*1024).spawn(|| {
        let root=std::path::PathBuf::from(std::env::var_os("BAKA_AC4_IMMERSIVE_DIR").expect("sample directory"));
        for quality in ["dolbyajoc448","dolbyajoc1500"] {
            let bytes=std::fs::read(root.join(format!("{quality}.mp4"))).unwrap();
            let track=mp4::read_ac4_track(&bytes).unwrap();
            let mut decoder=Ac4Decoder::new().unwrap();decoder.set_ajoc_stereo_preview(true);
            let mut pcm=Vec::new();let mut first=Vec::new();let mut peak=0.0f32;let mut difference=0.0f64;
            for (index,&(offset,size)) in track.samples.iter().enumerate() {
                decoder.set_ajoc_stereo_preview(true); // repeated configuration must preserve history
                let frame=decoder.decode_frame_into(&bytes[offset as usize..offset as usize+size as usize],&mut pcm)
                    .unwrap_or_else(|e|panic!("{quality} preview frame {index}: {e}")).unwrap();
                assert_eq!(frame.audio_kind,AudioKind::AjocStereoPreview);assert_eq!(frame.channel_mask,3);
                assert_eq!(pcm.len(),2);assert!(pcm.iter().all(|p|p.len()==frame.nb_samples));
                for sample in 0..frame.nb_samples {
                    for plane in &pcm { assert!(plane[sample].is_finite());peak=peak.max(plane[sample].abs()); }
                    difference+=f64::from((pcm[0][sample]-pcm[1][sample]).abs());
                }
                if index<6 { first.push(pcm.clone()); }
            }
            assert!(peak>0.01 && peak<100.0);assert!(difference>1.0);
            decoder.flush();
            for (index,&(offset,size)) in track.samples[..6].iter().enumerate() {
                decoder.decode_frame_into(&bytes[offset as usize..offset as usize+size as usize],&mut pcm).unwrap().unwrap();
                assert_eq!(pcm,first[index],"{quality} preview reset frame {index}");
            }
            let (offset,size)=track.samples[0];let packet=&bytes[offset as usize..offset as usize+size as usize];
            decoder.set_ajoc_stereo_preview(false);
            assert_eq!(decoder.decode_frame_into(packet,&mut pcm).unwrap().unwrap().audio_kind,AudioKind::AjocObjectSignals);
            assert_eq!(pcm.len(),21);
            decoder.set_ajoc_stereo_preview(true);decoder.decode_frame_into(packet,&mut pcm).unwrap().unwrap();
            assert_eq!(pcm.len(),2);
            decoder.set_ajoc_object_signals(true);
            assert_eq!(decoder.decode_frame_into(packet,&mut pcm).unwrap().unwrap().audio_kind,AudioKind::AjocObjectSignals);
            assert!(decoder.decode_frame_into(&[0;7],&mut pcm).is_err());assert!(pcm.is_empty());
            eprintln!("{quality}: {} stereo-preview frames, peak {peak}, L/R difference {difference:.3}",track.samples.len());
        }
    }).unwrap().join().unwrap();
}

#[test]
#[ignore = "set BAKA_AC4_IMMERSIVE_DIR to a local acceptance sample directory"]
fn complete_ajoc_tiers_reconstruct_object_signals_and_reset() {
    std::thread::Builder::new()
        .stack_size(64 * 1024 * 1024)
        .spawn(|| {
            let root = std::path::PathBuf::from(
                std::env::var_os("BAKA_AC4_IMMERSIVE_DIR").expect("sample directory"),
            );
            for quality in ["dolbyajoc448", "dolbyajoc1500"] {
                let bytes = std::fs::read(root.join(format!("{quality}.mp4"))).unwrap();
                let track = mp4::read_ac4_track(&bytes).unwrap();
                let mut decoder = Ac4Decoder::new().unwrap();
                decoder.set_qmf_bypass(true); // object mode must still use full QMF
                decoder.set_ajoc_object_signals(true);
                let mut pcm = Vec::new();
                let mut first = Vec::new();
                let mut peak = 0.0f32;
                let mut active = [false; 21];
                let started = std::time::Instant::now();
                for (index, &(offset, size)) in track.samples.iter().enumerate() {
                    let packet = &bytes[offset as usize..offset as usize + size as usize];
                    let frame = decoder
                        .decode_frame_into(packet, &mut pcm)
                        .unwrap_or_else(|e| panic!("{quality} object frame {index}: {e}"))
                        .unwrap();
                    assert_eq!(frame.audio_kind, AudioKind::AjocObjectSignals);
                    assert_eq!(frame.channel_mask, 0);
                    assert_eq!(pcm.len(), 21);
                    assert_eq!(frame.sample_rate, 48000);
                    assert_eq!(frame.nb_samples, 2048);
                    for (signal, plane) in pcm.iter().enumerate() {
                        assert_eq!(plane.len(), frame.nb_samples);
                        for &x in plane {
                            assert!(x.is_finite());
                            peak = peak.max(x.abs());
                            active[signal] |= x.abs() > 1.0e-6;
                        }
                    }
                    if index < 6 {
                        first.push(pcm.clone());
                    }
                }
                assert!(
                    active.into_iter().all(|a| a),
                    "{quality}: inactive objects {active:?}"
                );
                assert!(peak > 0.01 && peak < 10.0, "{quality}: peak {peak}");
                eprintln!(
                    "{quality}: {} reconstructed object frames, peak {peak}, {:.3}s",
                    track.samples.len(),
                    started.elapsed().as_secs_f64()
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
                    assert_eq!(pcm, first[index], "{quality}: reset frame {index}");
                }
                decoder.set_ajoc_object_signals(false);
                decoder.set_qmf_bypass(false);
                let (offset, size) = track.samples[0];
                let core = decoder
                    .decode_frame_into(
                        &bytes[offset as usize..offset as usize + size as usize],
                        &mut pcm,
                    )
                    .unwrap()
                    .unwrap();
                assert_eq!(core.audio_kind, AudioKind::AjocCoreSignals);
                assert_eq!(
                    pcm[0], first[0][0],
                    "LFE must retain the core plane and order"
                );
                assert_eq!(pcm.len(), if quality.ends_with("448") { 8 } else { 12 });
                decoder.set_ajoc_object_signals(true);
                decoder
                    .decode_frame_into(
                        &bytes[offset as usize..offset as usize + size as usize],
                        &mut pcm,
                    )
                    .unwrap()
                    .unwrap();
                assert_eq!(pcm.len(), 21);
                assert!(decoder.decode_frame_into(&[0; 7], &mut pcm).is_err());
                assert!(pcm.is_empty());
                decoder.set_ajoc_core_signals(false);
                let (offset, size) = track.samples[0];
                assert!(
                    decoder
                        .decode_frame_into(
                            &bytes[offset as usize..offset as usize + size as usize],
                            &mut pcm
                        )
                        .is_err()
                );
            }
        })
        .unwrap()
        .join()
        .unwrap();
}

#[test]
#[ignore = "set BAKA_AC4_IMMERSIVE_DIR to a local acceptance sample directory"]
fn complete_ajoc_tiers_have_finite_core_pcm_and_honest_layouts() {
    std::thread::Builder::new()
        .stack_size(64 * 1024 * 1024)
        .spawn(|| {
            let root = std::path::PathBuf::from(
                std::env::var_os("BAKA_AC4_IMMERSIVE_DIR").expect("sample directory"),
            );
            for (quality, signals) in [("dolbyajoc448", 8), ("dolbyajoc1500", 12)] {
                let bytes = std::fs::read(root.join(format!("{quality}.mp4"))).unwrap();
                let track = mp4::read_ac4_track(&bytes).unwrap();
                assert!(track.samples.len() > 1000);
                let mut decoder = Ac4Decoder::new().unwrap();
                decoder.set_ajoc_core_signals(true);
                decoder.set_ajoc_metadata(true);
                let mut pcm = Vec::new();
                let mut peak = 0.0f32;
                let mut samples = 0usize;
                let mut max_padding = 0;
                let mut dt_count = 0;
                let mut positions = [f32::INFINITY; 3];
                let mut position_max = [f32::NEG_INFINITY; 3];
                let mut gains = (i16::MAX, i16::MIN);
                let mut shared_frames = 0;
                let mut first_common = None;
                for (index, &(offset, size)) in track.samples.iter().enumerate() {
                    let packet = &bytes[offset as usize..offset as usize + size as usize];
                    let frame = decoder
                        .decode_frame_into(packet, &mut pcm)
                        .unwrap_or_else(|e| panic!("{quality} frame {index}: {e}"))
                        .expect("decoded frame");
                    assert_eq!(frame.audio_kind, AudioKind::AjocCoreSignals);
                    assert_eq!(frame.channel_mask, 0);
                    assert_eq!(frame.sample_rate, 48000);
                    assert_eq!(pcm.len(), signals);
                    let metadata = decoder.ajoc_metadata().expect("requested A-JOC metadata");
                    assert_eq!(metadata.objects.len(), 20);
                    assert!(metadata.bits > 20);
                    assert!(
                        metadata.padding_bits <= 7,
                        "{quality} frame {index}: unparsed metadata"
                    );
                    assert_eq!(metadata.downmix_blocks, 1);
                    assert_eq!(metadata.upmix_blocks, 1);
                    assert_eq!(metadata.upmix_metadata.len(), 21);
                    if let Some(common) = &metadata.common {
                        shared_frames += 1;
                        assert!(common.master_screen_ratio > 0.0 && common.master_screen_ratio <= 1.0);
                        assert_eq!(common.additional_data.len(), common.additional_bits.div_ceil(8));
                        if index == 0 {
                            first_common = Some(common.clone());
                            eprintln!("shared controls: screen {}, bed distribution {}, trim {:?}, opaque bits {}",
                                common.master_screen_ratio, common.bed_channel_distribution,
                                common.trim.as_ref().map(|t| t.global_mode), common.additional_bits);
                        }
                    }
                    for update in metadata.upmix_metadata.iter().flatten() {
                        assert!(update.timing.sample < frame.nb_samples as u16);
                        assert!(update.timing.ramp <= 2048);
                        if let Some(db) = update.properties.gain_db {
                            gains.0 = gains.0.min(db);
                            gains.1 = gains.1.max(db);
                        }
                        for axis in 0..3 {
                            let position = update.properties.position[axis];
                            assert!(position.is_finite());
                            positions[axis] = positions[axis].min(position);
                            position_max[axis] = position_max[axis].max(position);
                        }
                    }
                    assert_eq!(metadata.decorrelators, [true, true, true]);
                    for object in metadata.objects.iter().filter(|o| o.present) {
                        assert_eq!(object.bands, if signals == 8 { 12 } else { 23 });
                        for matrix in object.dry.iter().chain(&object.wet).flatten().flatten() {
                            assert_eq!(matrix.gains.len(), object.bands);
                            assert!(
                                matrix
                                    .gains
                                    .iter()
                                    .all(|x| x.is_finite() && x.abs() <= 5.005)
                            );
                        }
                    }
                    max_padding = max_padding.max(metadata.padding_bits);
                    dt_count += metadata
                        .objects
                        .iter()
                        .flat_map(|o| o.dry.iter().chain(&o.wet))
                        .flatten()
                        .flatten()
                        .filter(|m| m.time_delta)
                        .count();
                    for channel in &pcm {
                        assert_eq!(channel.len(), frame.nb_samples);
                        for &x in channel {
                            assert!(x.is_finite(), "{quality} frame {index}");
                            peak = peak.max(x.abs());
                        }
                    }
                    samples += frame.nb_samples;
                }
                assert!(peak > 0.01 && peak < 2.0, "{quality}: {peak}");
                assert!(samples > 48000 * 100);
                assert!(dt_count > 100000, "must exercise cross-frame time deltas");
                assert_eq!(shared_frames, track.samples.len());
                decoder.flush();
                assert!(decoder.ajoc_metadata().is_none());
                let mut qmf = Vec::new();
                assert!(decoder.copy_ajoc_core_qmf(&mut qmf).is_err());
                let (offset, size) = track.samples[0];
                assert!(
                    decoder
                        .decode_frame_into(
                            &bytes[offset as usize..offset as usize + size as usize],
                            &mut pcm
                        )
                        .unwrap()
                        .is_some()
                );
                assert!(decoder.ajoc_metadata().is_some());
                assert_eq!(decoder.ajoc_metadata().unwrap().common, first_common);
                decoder.copy_ajoc_core_qmf(&mut qmf).unwrap();
                assert_eq!(qmf.len(), signals - 1);
                assert!(qmf.iter().all(|plane| plane.len() == 32));
                assert!(
                    qmf.iter()
                        .flatten()
                        .flatten()
                        .flatten()
                        .all(|v| v.is_finite())
                );
                assert!(decoder.decode_frame_into(&[0; 7], &mut pcm).is_err());
                assert!(decoder.ajoc_metadata().is_none());
                eprintln!(
                    "metadata: padding <= {max_padding} bits, {dt_count} time-delta elements"
                );
                eprintln!(
                    "OAMD: gain {}..{} dB, positions {positions:?}..{position_max:?}",
                    gains.0, gains.1
                );
                eprintln!("shared OAMD controls available in {shared_frames} frames");
                eprintln!(
                    "{quality}: {} frames, {samples} samples, {signals} signals, peak {peak}",
                    track.samples.len()
                );
            }
        })
        .unwrap()
        .join()
        .unwrap();
}
