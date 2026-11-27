use baka_av3a_container::Track;
use baka_av3a_core::{FrameHeader, Profile, hoa::HoaFrame, side::ChannelBedFrame};
use std::{
    error::Error,
    fs::{File, OpenOptions},
    io::{BufWriter, Read, Write},
    path::Path,
};
mod wave;

fn read_bounded(path: &Path) -> Result<Vec<u8>, Box<dyn Error>> {
    read_limit(path, 512 * 1024 * 1024)
}
fn read_limit(path: &Path, limit: u64) -> Result<Vec<u8>, Box<dyn Error>> {
    let file = File::open(path)?;
    if file.metadata()?.len() > limit {
        return Err("file exceeds input byte limit".into());
    }
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err("file exceeds input byte limit".into());
    }
    Ok(bytes)
}

fn run() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    let command = args.first().and_then(|s| s.to_str()).unwrap_or("");
    match (command,args.len()) {
        ("decode",5..=7) => {
            let data=read_bounded(Path::new(&args[1]))?;
            let model=read_limit(Path::new(&args[3]),32*1024*1024)?;
            let lsf=read_limit(Path::new(&args[4]),64*1024)?;
            let (mut mcr, mut hoa) = (None, None);
            for path in &args[5..] {
                let bytes = read_limit(Path::new(path), 128*1024)?;
                match bytes.get(..8) {
                    Some(b"AV3MCR01") if mcr.is_none() => mcr = Some(bytes),
                    Some(b"AV3HOA01") if hoa.is_none() => hoa = Some(bytes),
                    _ => return Err("invalid or duplicate optional asset".into()),
                }
            }
            let (packets,rate,channels)=wave::decode(&data,&model,&lsf,mcr.as_deref(),hoa.as_deref(),Path::new(&args[2]))?;
            println!("{{\"packets\":{packets},\"sample_rate\":{rate},\"channels\":{channels},\"samples_per_channel\":{},\"pcm_decode\":true,\"crc_verified\":true}}",packets as u64*1024);
        }
        ("inspect",2) | ("extract",3) => {
            let data = read_bounded(Path::new(&args[1]))?;
            let track = Track::parse(&data)?;
            let h = track.validate_frames()?;
            let bytes: usize = track.packets().map(|p| p.bytes.len()).sum();
            if command == "extract" {
                let mut out = BufWriter::new(OpenOptions::new().write(true).create_new(true).open(&args[2])?);
                for packet in track.packets() { out.write_all(packet.bytes)?; }
                out.flush()?;
            }
            println!("{{\"format\":\"av3a\",\"packets\":{},\"sample_rate\":{},\"channels\":{},\"bit_depth\":{},\"bitrate\":{},\"header_bytes\":{},\"payload_bits\":{},\"elementary_bytes\":{},\"duration_ticks\":{},\"timescale\":{},\"pcm_decode\":false,\"crc_verified\":false}}",
                track.packet_count(),h.sample_rate,h.channels,h.bit_depth,h.bitrate,h.header_bytes,h.payload_bits,bytes,track.duration_ticks,track.timescale);
        }
        ("inspect-payload",2) => {
            let data = read_bounded(Path::new(&args[1]))?;
            let track = Track::parse(&data)?;
            track.validate_frames()?;
            let (mut context_bytes, mut base_bytes, mut tns_filters, mut short_groups) = (0usize,0usize,0usize,0usize);
            let (mut metadata_blocks, mut metadata_objects, mut static_blocks) = (0usize, 0usize, 0usize);
            for packet in track.packets() {
                let (quantized, cores, groups, metadata) = if matches!(FrameHeader::parse(packet.bytes)?.profile, Profile::Hoa { .. }) {
                    let frame = HoaFrame::parse(packet.bytes)?;
                    (frame.quantized, frame.cores, frame.groups, frame.metadata)
                } else {
                    let frame = ChannelBedFrame::parse(packet.bytes)?;
                    (frame.quantized, frame.cores, frame.groups, frame.metadata)
                };
                static_blocks += usize::from(metadata.static_data.is_some());
                if let Some(dynamic) = &metadata.dynamic { metadata_blocks += 1; metadata_objects += dynamic.objects.len(); }
                for q in &quantized { context_bytes += q.context.len(); base_bytes += q.base.len(); }
                tns_filters += cores.iter().flat_map(|c| &c.tns).filter(|f| !f.is_empty()).count();
                short_groups += groups.iter().filter(|g| g.count == 2).count();
            }
            println!("{{\"packets\":{},\"context_bytes\":{context_bytes},\"base_bytes\":{base_bytes},\"tns_filters\":{tns_filters},\"two_group_channels\":{short_groups},\"static_metadata_blocks\":{static_blocks},\"dynamic_metadata_blocks\":{metadata_blocks},\"dynamic_metadata_objects\":{metadata_objects},\"pcm_decode\":false,\"crc_verified\":false}}",track.packet_count());
        }
        ("inspect-es",2) => {
            let data = read_bounded(Path::new(&args[1]))?;
            let mut remaining = data.as_slice();
            let mut count = 0usize;
            while !remaining.is_empty() {
                let h = FrameHeader::parse(remaining)?;
                let size = h.frame_bytes();
                let packet = remaining.get(..size).ok_or("truncated elementary frame")?;
                FrameHeader::validate_packet(packet)?;
                remaining = &remaining[size..]; count += 1;
            }
            if count == 0 { return Err("empty elementary stream".into()); }
            println!("{{\"packets\":{count},\"elementary_bytes\":{},\"pcm_decode\":false}}",data.len());
        }
        _ => return Err("usage: baka-av3a inspect INPUT.mp4 | inspect-payload INPUT.mp4 | extract INPUT.mp4 OUTPUT.av3a | inspect-es INPUT.av3a | decode INPUT.mp4 OUTPUT.wav MODEL.bin LSF.bin [MCR.bin] [HOA.bin]".into()),
    }
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("baka-av3a: {e}");
        std::process::exit(1);
    }
}
