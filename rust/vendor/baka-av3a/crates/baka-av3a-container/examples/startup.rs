//! Measure progressive first PCM from a local file, stopping after 256 frames.
use baka_av3a_container::progressive::Mp4Decoder;
use baka_av3a_core::{decoder::Decoder, model::HyperModel, shaping::LsfCodebooks};
use std::{error::Error, io::Read, sync::Arc, time::Instant};

fn asset(path: &std::ffi::OsStr, limit: u64) -> Result<Vec<u8>, Box<dyn Error>> {
    let mut bytes = Vec::new();
    std::fs::File::open(path)?
        .take(limit + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err("asset byte limit".into());
    }
    Ok(bytes)
}

fn main() -> Result<(), Box<dyn Error>> {
    if cfg!(debug_assertions) {
        return Err("run with --release".into());
    }
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 3 {
        return Err("usage: startup MODEL.bin LSF.bin INPUT.mp4".into());
    }
    let model = Arc::new(HyperModel::parse(&asset(&args[0], 32 * 1024 * 1024)?)?);
    let lsf = Arc::new(LsfCodebooks::parse(&asset(&args[1], 64 * 1024)?)?);
    let mut decoder = Mp4Decoder::new(Decoder::new(model, lsf))?;
    let start = Instant::now();
    let mut input = std::fs::File::open(&args[2])?;
    let mut block = [0; 1024];
    let mut received = 0;
    let mut samples = 0;
    let mut hash = 0xcbf29ce484222325u64;
    loop {
        let count = input.read(&mut block)?;
        if count == 0 {
            decoder.finish();
        } else {
            decoder.push(&block[..count])?;
        }
        received += count;
        while let Some(frame) = decoder.next_frame()? {
            if decoder.decoded_frames() == 1 {
                println!(
                    "first_pcm_ms={:.3} input_bytes={received} sample_rate={} channels={}",
                    start.elapsed().as_secs_f64() * 1000.0,
                    frame.pcm.sample_rate,
                    frame.pcm.channels
                );
            }
            let pcm = frame.pcm.to_i16();
            samples += pcm.len();
            for byte in pcm.iter().flat_map(|v| v.to_le_bytes()) {
                hash = (hash ^ u64::from(byte)).wrapping_mul(0x100000001b3);
            }
            if decoder.decoded_frames() == 256 {
                break;
            }
        }
        if decoder.decoded_frames() == 256 || decoder.is_finished() {
            break;
        }
    }
    println!(
        "frames={} samples={samples} received_bytes={received} buffered_bytes={} pcm_i16_fnv1a64={hash:016x}",
        decoder.decoded_frames(),
        decoder.buffered_bytes()
    );
    Ok(())
}
