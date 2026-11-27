#[path = "../../../baka-av3a-core/tests/fixtures/bed_frame.rs"]
mod bed_frame;

pub fn atom(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
    [
        ((body.len() + 8) as u32).to_be_bytes().as_slice(),
        kind,
        body,
    ]
    .concat()
}
fn words(values: &[u32]) -> Vec<u8> {
    values.iter().flat_map(|v| v.to_be_bytes()).collect()
}

pub fn file(front: bool, wide: bool, padding: usize) -> Vec<u8> {
    let mut p = bed_frame::frame(true);
    let crc = baka_av3a_core::payload_crc(&p[7..]);
    p[3] = (p[3] & 0xe0) | (crc >> 11) as u8;
    p[4] = (p[4] & 0x1f) | (((crc >> 8) as u8 & 7) << 5);
    p[6] = crc as u8;
    let moov = |offset: u64| {
        let mut entry = vec![0; 28];
        entry[6..8].copy_from_slice(&1u16.to_be_bytes());
        entry[16..20].copy_from_slice(&[0, 12, 0, 16]);
        entry[24..28].copy_from_slice(&(44100u32 << 16).to_be_bytes());
        let mut stsd = words(&[0, 1]);
        stsd.extend(atom(b"av3a", &entry));
        let mut stbl = atom(b"stsd", &stsd);
        stbl.extend(atom(b"stsz", &words(&[0, p.len() as u32, 4])));
        let mut offsets = words(&[0, 1]);
        if wide {
            offsets.extend(offset.to_be_bytes());
        } else {
            offsets.extend((offset as u32).to_be_bytes());
        }
        stbl.extend(atom(if wide { b"co64" } else { b"stco" }, &offsets));
        stbl.extend(atom(b"stsc", &words(&[0, 1, 1, 4, 1])));
        stbl.extend(atom(b"stts", &words(&[0, 1, 4, 1024])));
        let mut mdia = atom(b"hdlr", &[&[0; 8][..], b"soun"].concat());
        mdia.extend(atom(b"mdhd", &words(&[0, 0, 0, 44100, 4096, 0])));
        mdia.extend(atom(b"minf", &atom(b"stbl", &stbl)));
        atom(b"moov", &atom(b"trak", &atom(b"mdia", &mdia)))
    };
    let mut media = vec![0; padding];
    media.extend(p.repeat(4));
    let mdat = atom(b"mdat", &media);
    if front {
        [moov((moov(0).len() + 8 + padding) as u64), mdat].concat()
    } else {
        [mdat, moov((8 + padding) as u64)].concat()
    }
}
