//! baka-ac4 command line tool: `toc` dumps per-frame decode info as JSON,
//! `decode` converts an MP4-wrapped or raw `.ac4` stream to a WAV file.

use baka_ac4_cli::{mp4, raw};
mod wav;

use std::fs::File;
use std::io::BufWriter;
use std::process::ExitCode;

use baka_ac4_core::StreamFeatures;
use baka_ac4_core::ajoc::render::{RenderOptions, SpeakerLayout};
use std::collections::BTreeMap;

#[derive(Clone, Copy)]
enum SignalOutput {
    Channels,
    Core,
    Objects,
    StereoPreview,
    Speakers(SpeakerLayout),
}

impl SignalOutput {
    fn configure(self, decoder: &mut baka_ac4_core::Ac4Decoder) {
        match self {
            Self::Channels => decoder.set_ajoc_core_signals(false),
            Self::Core => decoder.set_ajoc_core_signals(true),
            Self::Objects => decoder.set_ajoc_object_signals(true),
            Self::StereoPreview => decoder.set_ajoc_stereo_preview(true),
            Self::Speakers(layout) => decoder
                .set_ajoc_render(Some(RenderOptions::new(layout)))
                .expect("built-in screen geometry is valid"),
        }
    }
}

fn main() -> ExitCode {
    // Decoder history and DSP scratch can exceed Windows' default main stack,
    // especially in debug builds. Keep the command on an explicitly sized stack.
    match std::thread::Builder::new()
        .name("baka-ac4".into())
        .stack_size(64 * 1024 * 1024)
        .spawn(run)
    {
        Ok(worker) => match worker.join() {
            Ok(code) => code,
            Err(_) => {
                eprintln!("error: decoder worker failed");
                ExitCode::FAILURE
            }
        },
        Err(_) => {
            eprintln!("error: cannot start decoder worker");
            ExitCode::FAILURE
        }
    }
}

fn run() -> ExitCode {
    let core = std::env::args().any(|a| a == "--core-signals");
    let objects = std::env::args().any(|a| a == "--object-signals");
    let preview = std::env::args().any(|a| a == "--stereo-preview");
    let render_args = std::env::args()
        .filter(|a| a.starts_with("--render"))
        .collect::<Vec<_>>();
    let mut render = None;
    for arg in &render_args {
        render = Some(match arg.as_str() {
            "--render=stereo" => SpeakerLayout::Stereo,
            "--render=5.1" => SpeakerLayout::Surround51,
            "--render=7.1" => SpeakerLayout::Surround71,
            "--render=5.1.4" => SpeakerLayout::Surround514,
            "--render=7.1.4" => SpeakerLayout::Surround714,
            _ => {
                eprintln!("error: --render requires stereo, 5.1, 7.1, 5.1.4 or 7.1.4");
                return ExitCode::FAILURE;
            }
        });
    }
    let args: Vec<String> = std::env::args()
        .filter(|a| {
            a != "--core-signals"
                && a != "--object-signals"
                && a != "--stereo-preview"
                && !a.starts_with("--render")
        })
        .collect();
    if usize::from(core) + usize::from(objects) + usize::from(preview) + render_args.len() > 1 {
        eprintln!("error: choose one A-JOC output mode");
        return ExitCode::FAILURE;
    }
    if (objects || preview || render.is_some()) && args.iter().any(|a| a == "--fast") {
        eprintln!("error: object reconstruction requires full QMF processing; remove --fast");
        return ExitCode::FAILURE;
    }
    let signals = if let Some(layout) = render {
        SignalOutput::Speakers(layout)
    } else if preview {
        SignalOutput::StereoPreview
    } else if objects {
        SignalOutput::Objects
    } else if core {
        SignalOutput::Core
    } else {
        SignalOutput::Channels
    };
    if preview {
        eprintln!(
            "A-JOC stereo preview selected: object gain and left/right position only; no immersive/binaural rendering, normalization or limiting."
        );
    }
    if objects {
        eprintln!(
            "A-JOC object-signal output selected: LFE first when present; no speaker/headphone rendering or OAMD object gains."
        );
    }
    if core {
        eprintln!(
            "A-JOC core-signal output selected: unanchored signals are not rendered speaker feeds."
        );
    }
    match args.get(1).map(String::as_str) {
        Some("toc") if args.len() == 3 => toc(&args[2], signals),
        Some("bench") if (3..=4).contains(&args.len()) => {
            bench(&args[2], args.get(3).map(String::as_str), signals)
        }
        Some("decode") => {
            let rest: Vec<&String> = args[2..].iter().filter(|a| !a.starts_with('-')).collect();
            let fast = args.iter().any(|a| a == "--fast");
            let f32out = args.iter().any(|a| a == "--f32");
            if rest.len() == 2 {
                decode(rest[0], rest[1], fast, f32out, signals)
            } else {
                usage()
            }
        }
        _ => usage(),
    }
}

fn bench(path: &str, rounds: Option<&str>, signals: SignalOutput) -> ExitCode {
    let (data, track) = match load(path) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    let rounds: usize = match rounds {
        None => 10,
        Some(raw) => match raw.parse() {
            Ok(value) if value > 0 && value <= 10000 => value,
            _ => {
                eprintln!("error: rounds must be an integer in 1..=10000");
                return ExitCode::FAILURE;
            }
        },
    };
    let mut best = f64::INFINITY;
    let mut times = Vec::with_capacity(rounds);
    let mut pcm: Vec<Vec<f32>> = Vec::new();
    let mut peak = 0.0f32;
    for r in 0..rounds {
        let mut dec = match baka_ac4_core::Ac4Decoder::new() {
            Ok(d) => d,
            Err(e) => {
                eprintln!("error: decoder init failed: {e}");
                return ExitCode::FAILURE;
            }
        };
        signals.configure(&mut dec);
        pcm.clear();
        let t = std::time::Instant::now();
        let mut produced = 0;
        for (index, (off, size)) in track.samples.iter().enumerate() {
            let pkt = &data[*off as usize..(*off + *size as u64) as usize];
            let frame = match dec.decode_frame_into(pkt, &mut pcm) {
                Ok(frame) => frame,
                Err(error) => {
                    eprintln!("error: round {} frame {index}: {error}", r + 1);
                    return ExitCode::FAILURE;
                }
            };
            if frame.is_some() {
                produced += 1;
                if r == 0 {
                    for ch in &pcm {
                        for &v in ch.iter() {
                            peak = peak.max(v.abs());
                        }
                    }
                }
            }
        }
        if produced == 0 {
            eprintln!("error: no audio frames decoded");
            return ExitCode::FAILURE;
        }
        let el = t.elapsed().as_secs_f64();
        times.push(el);
        best = best.min(el);
    }
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let total_samples = track.samples.len();
    println!(
        "bench {path}: {rounds} rounds, frames={total_samples}, min={:.3}s med={:.3}s, peak={peak:.4}",
        best,
        times[rounds / 2]
    );
    ExitCode::SUCCESS
}

fn usage() -> ExitCode {
    eprintln!("optional: --core-signals decodes A-JOC downmix essence without object rendering");
    eprintln!(
        "optional: --object-signals reconstructs A-JOC object signals without speaker/headphone rendering"
    );
    eprintln!(
        "optional: --stereo-preview projects A-JOC objects to stereo using gain and X position only"
    );
    eprintln!(
        "optional: --render=stereo|5.1|7.1|5.1.4|7.1.4 renders dynamic A-JOC objects to speaker feeds"
    );
    eprintln!("usage: baka-ac4 toc <input.mp4 | input.ac4>");
    eprintln!("       baka-ac4 decode [--fast] [--f32] <input.mp4 | input.ac4> <output.wav>");
    eprintln!("       --fast skips the QMF round trip for simple streams (slightly");
    eprintln!("               lower fidelity, noticeably faster)");
    ExitCode::FAILURE
}

fn load(path: &str) -> Result<(Vec<u8>, mp4::Track), String> {
    let data = std::fs::read(path).map_err(|e| format!("cannot read {path}: {e}"))?;
    let track = if raw::is_raw_ac4(&data) {
        raw::read_ac4_frames(&data)?
    } else {
        mp4::read_ac4_track(&data)?
    };
    Ok((data, track))
}

fn toc(path: &str, signals: SignalOutput) -> ExitCode {
    let (data, track) = match load(path) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    let mut dec = match baka_ac4_core::Ac4Decoder::new() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("error: decoder init failed: {e}");
            return ExitCode::FAILURE;
        }
    };

    signals.configure(&mut dec);
    println!("{{");
    println!(
        "  \"codec\": \"{}\", \"channels\": {}, \"timescale\": {}, \"samples\": {},",
        track.codec,
        track.channels,
        track.timescale,
        track.samples.len()
    );
    println!("  \"frames\": [");

    let mut tool_counts: BTreeMap<String, usize> = BTreeMap::new();
    let n = track.samples.len();
    for (i, (off, size)) in track.samples.iter().enumerate() {
        let pkt = &data[*off as usize..(*off + *size as u64) as usize];
        let entry = match dec.decode_frame(pkt) {
            Ok(Some(f)) => {
                let feats = dec.features();
                *tool_counts.entry(feature_key(&feats)).or_default() += 1;
                format!(
                    "{{ \"i\": {}, \"size\": {}, \"ok\": true, \"key\": {}, \"ch\": {}, \"rate\": {}, \"n\": {}, \"cm\": {}, \"mask\": {}, \"output\": \"{}\", \"sf\": [{}, {}, {}, {}] }}",
                    i,
                    size,
                    f.key_frame,
                    f.data.len(),
                    f.sample_rate,
                    f.nb_samples,
                    feats.codec_mode,
                    f.channel_mask,
                    match f.audio_kind {
                        baka_ac4_core::AudioKind::AjocCoreSignals => "ajoc-core-signals",
                        baka_ac4_core::AudioKind::AjocObjectSignals => "ajoc-object-signals",
                        baka_ac4_core::AudioKind::AjocStereoPreview => "ajoc-stereo-preview",
                        baka_ac4_core::AudioKind::AjocSpeakerFeeds => "ajoc-speaker-feeds",
                        baka_ac4_core::AudioKind::Channels => "channels",
                    },
                    feats.spec_frontend_l,
                    feats.spec_frontend_r,
                    feats.spec_frontend_m,
                    feats.spec_frontend_s
                )
            }
            Ok(None) => format!(
                "{{ \"i\": {}, \"size\": {}, \"ok\": false, \"reason\": \"waiting_for_iframe\" }}",
                i, size
            ),
            Err(e) => format!(
                "{{ \"i\": {}, \"size\": {}, \"ok\": false, \"reason\": \"{}\" }}",
                i,
                size,
                e.to_string().replace('"', "'")
            ),
        };
        let comma = if i + 1 < n { "," } else { "" };
        println!("    {entry}{comma}");
    }
    println!("  ],");
    println!("  \"tools\": {{");
    let m = tool_counts.len();
    for (i, (k, v)) in tool_counts.iter().enumerate() {
        let comma = if i + 1 < m { "," } else { "" };
        println!("    \"{k}\": {v}{comma}");
    }
    println!("  }}");
    println!("}}");
    ExitCode::SUCCESS
}

/// Aggregate key: codec_mode + spectral frontends actually used (only the
/// frontends of channel elements present in this stream carry meaning, so
/// the key collects all four values and dedups naturally in the map).
fn feature_key(f: &StreamFeatures) -> String {
    let cm = match f.codec_mode {
        0 => "CM_SIMPLE",
        1 => "CM_ASPX",
        2 => "CM_ASPX_ACPL_1",
        3 => "CM_ASPX_ACPL_2",
        4 => "CM_ASPX_ACPL_3",
        other => return format!("cm{other}"),
    };
    let sf = |v: i32| {
        if v == 0 {
            "asf"
        } else if v == 1 {
            "ssf"
        } else {
            "?"
        }
    };
    format!(
        "{cm}(l={}, r={}, m={}, s={})",
        sf(f.spec_frontend_l),
        sf(f.spec_frontend_r),
        sf(f.spec_frontend_m),
        sf(f.spec_frontend_s)
    )
}

fn decode(path: &str, out_path: &str, fast: bool, f32out: bool, signals: SignalOutput) -> ExitCode {
    let (data, track) = match load(path) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };
    let mut dec = match baka_ac4_core::Ac4Decoder::new() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("error: decoder init failed: {e}");
            return ExitCode::FAILURE;
        }
    };
    dec.set_qmf_bypass(fast);
    signals.configure(&mut dec);
    let out = match File::create(out_path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("error: cannot create {out_path}: {e}");
            return ExitCode::FAILURE;
        }
    };
    let mut wav = match wav::WavWriter::start_fmt(BufWriter::new(out), f32out) {
        Ok(w) => w,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };

    let mut ok_frames = 0usize;
    let mut wait_frames = 0usize;
    let mut err_frames = 0usize;
    let mut peak = 0.0f32;
    let mut pcm: Vec<Vec<f32>> = Vec::new();

    for (i, (off, size)) in track.samples.iter().enumerate() {
        let pkt = &data[*off as usize..(*off + *size as u64) as usize];
        match dec.decode_frame_into(pkt, &mut pcm) {
            Ok(Some(info)) => {
                for ch in &pcm {
                    for &v in ch.iter() {
                        peak = peak.max(v.abs());
                    }
                }
                if let Err(e) = wav.write_frame_planar(&pcm, info.sample_rate, info.channel_mask) {
                    eprintln!("error: wav write failed: {e}");
                    return ExitCode::FAILURE;
                }
                ok_frames += 1;
            }
            Ok(None) => {
                wait_frames += 1;
            }
            Err(e) => {
                err_frames += 1;
                if err_frames <= 5 {
                    eprintln!("frame {i}: {e}");
                }
            }
        }
    }

    if let Err(e) = wav.finish() {
        eprintln!("error: wav finish failed: {e}");
        return ExitCode::FAILURE;
    }
    println!(
        "decoded {ok_frames} frames ({wait_frames} waiting, {err_frames} errors), peak {peak:.4}"
    );
    if err_frames > 0 {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}
