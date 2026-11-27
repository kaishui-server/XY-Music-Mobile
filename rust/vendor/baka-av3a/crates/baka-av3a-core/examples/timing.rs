//! Release-only, in-memory timing; paths and media stay outside the repository.
use baka_av3a_core::{
    FrameHeader,
    decoder::Decoder,
    model::{HyperModel, NoiseState, SpectrumConfig},
    shaping::LsfCodebooks,
    side::ChannelBedFrame,
};
use std::{error::Error, hint::black_box, io::Read, sync::Arc, time::Instant};

fn read(path: &std::ffi::OsStr, limit: u64) -> Result<Vec<u8>, Box<dyn Error>> {
    let mut bytes = Vec::new();
    std::fs::File::open(path)?
        .take(limit + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err("input byte limit".into());
    }
    Ok(bytes)
}

fn main() -> Result<(), Box<dyn Error>> {
    if cfg!(debug_assertions) {
        return Err("run with --release".into());
    }
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 3 {
        return Err("usage: timing MODEL.bin LSF.bin INPUT.av3a".into());
    }
    let start = Instant::now();
    let model_bytes = read(&args[0], 32 * 1024 * 1024)?;
    let lsf_bytes = read(&args[1], 64 * 1024)?;
    let asset_read_ms = start.elapsed().as_secs_f64() * 1000.0;
    let start = Instant::now();
    let model = Arc::new(HyperModel::parse(&model_bytes)?);
    let lsf = Arc::new(LsfCodebooks::parse(&lsf_bytes)?);
    let asset_parse_ms = start.elapsed().as_secs_f64() * 1000.0;
    let bytes = read(&args[2], 512 * 1024 * 1024)?;
    let h = FrameHeader::parse(&bytes)?;
    let mut packets = Vec::new();
    let mut position = 0;
    while position < bytes.len() && packets.len() < 256 {
        let header = FrameHeader::parse(&bytes[position..])?;
        let end = position
            .checked_add(header.frame_bytes())
            .ok_or("packet overflow")?;
        packets.push(bytes.get(position..end).ok_or("truncated packet")?);
        position = end;
    }
    let start = Instant::now();
    let mut decoder = Decoder::new(model.clone(), lsf);
    let decoder_init_ms = start.elapsed().as_secs_f64() * 1000.0;
    let start = Instant::now();
    let first = black_box(decoder.decode(packets[0])?);
    let first_pcm_ms = start.elapsed().as_secs_f64() * 1000.0;
    let mut pcm_hash = 0xcbf29ce484222325u64;
    let hash_pcm = |pcm: &baka_av3a_core::decoder::PcmFrame, hash: &mut u64| {
        for byte in pcm.to_i16().iter().flat_map(|v| v.to_le_bytes()) {
            *hash = (*hash ^ u64::from(byte)).wrapping_mul(0x100000001b3);
        }
    };
    hash_pcm(&first, &mut pcm_hash);
    let mut timings = Vec::new();
    for packet in packets.iter().skip(1) {
        let start = Instant::now();
        let pcm = black_box(decoder.decode(packet)?);
        timings.push(start.elapsed().as_secs_f64() * 1000.0);
        hash_pcm(&pcm, &mut pcm_hash);
    }
    if timings.is_empty() {
        return Err("need at least two packets".into());
    }
    let mean = timings.iter().sum::<f64>() / timings.len() as f64;
    timings.sort_by(f64::total_cmp);
    // Measure side parsing and the neural spectrum stage separately, using the
    // same first packets. This is diagnostic repetition, not an additive profile.
    let start = Instant::now();
    for packet in &packets {
        black_box(ChannelBedFrame::parse(packet)?);
    }
    let side_ms = start.elapsed().as_secs_f64() * 1000.0 / packets.len() as f64;
    let mut frames = Vec::new();
    for packet in &packets {
        frames.push(ChannelBedFrame::parse(packet)?);
    }
    let mut noise = NoiseState::default();
    let start = Instant::now();
    for frame in &frames {
        for i in 0..frame.quantized.len() {
            black_box(model.decode_spectrum(
                &frame.quantized[i],
                &frame.groups[i],
                SpectrumConfig {
                    neural_type: frame.header.neural_type,
                    transform: frame.cores[i].transform,
                    noise_lines: frame.bwe.as_ref().map_or(1024, |b| b.start_line()),
                },
                &mut noise,
            )?);
        }
    }
    let spectrum_ms = start.elapsed().as_secs_f64() * 1000.0 / frames.len() as f64;
    println!(
        "asset_read_ms={asset_read_ms:.3} asset_parse_ms={asset_parse_ms:.3} decoder_init_ms={decoder_init_ms:.3}"
    );
    println!(
        "channels={} sample_rate={} packets={} frame_audio_ms={:.3}",
        h.channels,
        h.sample_rate,
        packets.len(),
        1024000.0 / f64::from(h.sample_rate)
    );
    println!(
        "first_pcm_ms={first_pcm_ms:.3} warm_mean_ms={mean:.3} warm_p50_ms={:.3} warm_p95_ms={:.3} warm_max_ms={:.3} rtf={:.4}",
        timings[timings.len() / 2],
        timings[(timings.len() - 1) * 95 / 100],
        timings[timings.len() - 1],
        mean * f64::from(h.sample_rate) / 1024000.0
    );
    println!("side_parse_ms={side_ms:.3} neural_spectrum_ms={spectrum_ms:.3}");
    println!("pcm_i16_fnv1a64={pcm_hash:016x}");
    Ok(())
}
