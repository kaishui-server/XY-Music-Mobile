use baka_av3a_container::Track;
use baka_av3a_core::{
    FrameHeader, decoder::Decoder, hoa::HoaBasis, mcr::McrCodebooks, model::HyperModel,
    shaping::LsfCodebooks,
};
use std::{
    error::Error,
    fs::OpenOptions,
    io::{BufWriter, Write},
    path::Path,
    sync::Arc,
};

pub fn decode(
    data: &[u8],
    model: &[u8],
    lsf: &[u8],
    mcr: Option<&[u8]>,
    hoa: Option<&[u8]>,
    destination: &Path,
) -> Result<(usize, u32, u16), Box<dyn Error>> {
    let track = Track::parse(data)?;
    let header = track.validate_frames()?;
    let mut decoder = Decoder::new(
        Arc::new(HyperModel::parse(model)?),
        Arc::new(LsfCodebooks::parse(lsf)?),
    );
    if let Some(bytes) = mcr {
        decoder = decoder.with_mcr(Arc::new(McrCodebooks::parse(bytes)?));
    }
    if let Some(bytes) = hoa {
        decoder = decoder.with_hoa(Arc::new(HoaBasis::parse(bytes)?));
    }
    let bytes = track.packet_count() as u64 * 1024 * u64::from(header.channels) * 2;
    let size = u32::try_from(bytes)
        .ok()
        .filter(|&v| v <= u32::MAX - 36)
        .ok_or("WAV exceeds RIFF size limit")?;
    // Complete packet integrity checks before creating the output file.
    for packet in track.packets() {
        FrameHeader::validate_crc(packet.bytes)?;
    }
    let first = decoder.decode(track.packet(0).ok_or("empty audio track")?.bytes)?;
    let mut out = BufWriter::new(
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(destination)?,
    );
    out.write_all(&header_bytes(header.sample_rate, header.channels, size))?;
    for value in first.to_i16() {
        out.write_all(&value.to_le_bytes())?;
    }
    for packet in track.packets().skip(1) {
        for value in decoder.decode(packet.bytes)?.to_i16() {
            out.write_all(&value.to_le_bytes())?;
        }
    }
    out.flush()?;
    Ok((track.packet_count(), header.sample_rate, header.channels))
}

fn header_bytes(rate: u32, channels: u16, bytes: u32) -> [u8; 44] {
    let mut header = [0u8; 44];
    header[..4].copy_from_slice(b"RIFF");
    header[4..8].copy_from_slice(&(36 + bytes).to_le_bytes());
    header[8..16].copy_from_slice(b"WAVEfmt ");
    header[16..20].copy_from_slice(&16u32.to_le_bytes());
    header[20..22].copy_from_slice(&1u16.to_le_bytes());
    header[22..24].copy_from_slice(&channels.to_le_bytes());
    header[24..28].copy_from_slice(&rate.to_le_bytes());
    header[28..32].copy_from_slice(&(rate * u32::from(channels) * 2).to_le_bytes());
    header[32..34].copy_from_slice(&(channels * 2).to_le_bytes());
    header[34..36].copy_from_slice(&16u16.to_le_bytes());
    header[36..40].copy_from_slice(b"data");
    header[40..44].copy_from_slice(&bytes.to_le_bytes());
    header
}
