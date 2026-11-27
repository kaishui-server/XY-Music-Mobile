//! Use local seek/read as a transport adapter for sparse MP4 startup timing.
use baka_av3a_container::range::{
    RangeProbe, RangeRequest,
    playback::{DecodeStep, RangeDecoder},
};
use baka_av3a_core::{decoder::Decoder, model::HyperModel, shaping::LsfCodebooks};
use std::{
    error::Error,
    io::{Read, Seek, SeekFrom},
    sync::Arc,
    time::Instant,
};

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
fn fetch(file: &mut std::fs::File, request: &RangeRequest) -> Result<Vec<u8>, Box<dyn Error>> {
    file.seek(SeekFrom::Start(request.bytes.start as u64))?;
    let mut bytes = vec![0; request.bytes.len()];
    file.read_exact(&mut bytes)?;
    Ok(bytes)
}
fn main() -> Result<(), Box<dyn Error>> {
    if cfg!(debug_assertions) {
        return Err("run with --release".into());
    }
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 3 {
        return Err("usage: range_startup MODEL.bin LSF.bin INPUT.mp4".into());
    }
    let model = Arc::new(HyperModel::parse(&asset(&args[0], 32 * 1024 * 1024)?)?);
    let lsf = Arc::new(LsfCodebooks::parse(&asset(&args[1], 64 * 1024)?)?);
    let start = Instant::now();
    let mut file = std::fs::File::open(&args[2])?;
    let length = usize::try_from(file.metadata()?.len())?;
    let mut probe = RangeProbe::new(length)?;
    let mut requests = 0;
    let mut fetched = 0;
    while let Some(r) = probe.next_request()? {
        let body = fetch(&mut file, &r)?;
        fetched += body.len();
        requests += 1;
        probe.accept(&r, &body)?;
    }
    let index = probe.into_track()?;
    println!(
        "indexed_packets={} metadata_requests={requests} fetched_bytes={fetched} file_bytes={length}",
        index.packet_count()
    );
    let mut reader = RangeDecoder::new(index, Decoder::new(model, lsf))?;
    let mut frames = 0;
    let mut samples = 0;
    let mut hash = 0xcbf29ce484222325u64;
    loop {
        match reader.next_frame()? {
            DecodeStep::NeedInput => {
                let r = reader.next_request().ok_or("missing range request")?;
                let body = fetch(&mut file, &r)?;
                fetched += body.len();
                requests += 1;
                reader.accept(&r, &body)?;
            }
            DecodeStep::Frame(frame) => {
                frames += 1;
                if frames == 1 {
                    println!(
                        "first_pcm_ms={:.3} requests={requests} fetched_bytes={fetched}",
                        start.elapsed().as_secs_f64() * 1000.0
                    );
                }
                let pcm = frame.pcm.to_i16();
                samples += pcm.len();
                for byte in pcm.iter().flat_map(|v| v.to_le_bytes()) {
                    hash = (hash ^ u64::from(byte)).wrapping_mul(0x100000001b3);
                }
                if frames == 256 {
                    break;
                }
            }
            DecodeStep::Preroll { .. } => {}
            DecodeStep::Finished => break,
        }
    }
    println!(
        "frames={frames} samples={samples} requests={requests} fetched_bytes={fetched} pcm_i16_fnv1a64={hash:016x}"
    );
    Ok(())
}
