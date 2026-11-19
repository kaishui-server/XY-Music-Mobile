use super::super::cue::CueTrack;
use super::super::tags::{extract_detail_metadata, read_tagged_file_from_path_for_scan};
use super::super::types::Song;
use super::super::utils::{is_supported_library_extension, normalize_path};
use super::{
    build_album_key, fill_text_fields_from_tags, normalize_album_key_part, primary_artist_name,
    split_artist_names, ScanOptions, UNKNOWN_ALBUM, UNKNOWN_ARTIST, VARIOUS_ARTISTS,
    VARIOUS_ARTISTS_THRESHOLD,
};
use lofty::file::FileType;
use lofty::prelude::*;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;
use symphonia::core::codecs::CODEC_TYPE_NULL;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::{Limit, MetadataOptions};
use symphonia::core::probe::Hint;
use symphonia::core::units::TimeBase;

#[derive(Default)]
struct AudioIdentity {
    container: Option<String>,
    codec: Option<String>,
    duration_seconds: Option<u32>,
    sample_rate: Option<u32>,
    bit_depth: Option<u8>,
}

fn duration_seconds_from_timebase(time_base: TimeBase, frames: u64) -> u32 {
    let time = time_base.calc_time(frames);
    let rounded = time.seconds.saturating_add(u64::from(time.frac > 0.0));
    rounded.min(u32::MAX as u64) as u32
}

fn derive_bitrate_kbps(file_size: u64, duration: u32) -> u32 {
    if file_size == 0 || duration == 0 {
        return 0;
    }

    let bits = (file_size as u128).saturating_mul(8);
    let kbps = bits / (duration as u128) / 1000;
    kbps.min(u32::MAX as u128) as u32
}

fn system_time_to_unix_seconds(time: std::time::SystemTime) -> Option<u64> {
    time.duration_since(UNIX_EPOCH)
        .ok()
        .map(|duration| duration.as_secs())
}

pub(super) fn preferred_parse_workers(task_count: usize) -> usize {
    if task_count <= 1 {
        return 1;
    }

    let available = std::thread::available_parallelism()
        .map(|value| value.get())
        .unwrap_or(4);

    preferred_parse_workers_for_available(task_count, available)
}

pub(super) fn preferred_parse_workers_for_available(task_count: usize, available: usize) -> usize {
    if task_count <= 1 {
        return 1;
    }

    let reserved = if available <= 8 { 1 } else { 2 };
    let usable = available.saturating_sub(reserved).max(1);

    task_count.min(usable).max(1)
}

pub(super) fn song_metadata_incomplete(song: &Song) -> bool {
    super::is_missing_text(&song.artist, UNKNOWN_ARTIST)
        || super::is_missing_text(&song.album, UNKNOWN_ALBUM)
        || song.artist_names.is_empty()
        || song.album_artist.trim().is_empty()
        || song.album_key.trim().is_empty()
        || song.title.trim().is_empty()
        || song.duration == 0
}

pub(super) fn song_identity_missing(song: &Song) -> bool {
    song.format.trim().is_empty()
        && song
            .container
            .as_deref()
            .map(|value| value.trim().is_empty())
            .unwrap_or(true)
}

pub(crate) fn parse_song_from_file(path: &Path, path_str: &str, format: &str) -> Option<Song> {
    let mut artist = String::from("未知歌手");
    let mut album = String::from("未知专辑");
    let mut album_artist = String::new();
    let mut title = String::new();
    let mut duration = 0u32;
    let mut bitrate = 0u32;
    let mut sample_rate = 0u32;
    let mut bit_depth: Option<u8> = None;
    let mut file_size = 0u64;
    let mut file_created_at: Option<u64> = None;
    let mut file_modified_at: Option<u64> = None;
    let mut track_number: Option<String> = None;
    let mut disc_number: Option<String> = None;
    let mut comment: Option<String> = None;
    let mut container = Some(normalize_container_from_extension(format));
    let mut codec = None;
    let mut artist_avatar_bytes: Option<Vec<u8>> = None;

    if let Ok(meta) = fs::metadata(path) {
        file_size = meta.len();
        if let Ok(created) = meta.created() {
            file_created_at = system_time_to_unix_seconds(created);
        }
        if let Ok(modified) = meta.modified() {
            file_modified_at = system_time_to_unix_seconds(modified);
        }
    }

    if let Ok(tagged_file) =
        read_tagged_file_from_path_for_scan(path).map_err(|error| error.to_string())
    {
        let props = tagged_file.properties();
        duration = props.duration().as_secs() as u32;
        bitrate = props.audio_bitrate().unwrap_or(0);
        sample_rate = props.sample_rate().unwrap_or(0);
        bit_depth = props.bit_depth().map(|bits| bits as u8);
        container = Some(normalize_container(tagged_file.file_type()).to_string());

        fill_text_fields_from_tags(
            &tagged_file,
            &mut artist,
            &mut album,
            &mut title,
            &mut album_artist,
        );
        let detail_metadata = extract_detail_metadata(&tagged_file);
        track_number = detail_metadata.track_number;
        disc_number = detail_metadata.disc_number;
        comment = detail_metadata.comment;

        if let Some(pic) = super::super::tags::find_embedded_artist_picture(&tagged_file) {
            artist_avatar_bytes = Some(pic.data().to_vec());
        }
    }

    if duration == 0 || sample_rate == 0 || bit_depth.is_none() {
        let identity = detect_audio_identity(path, format);

        if duration == 0 {
            duration = identity.duration_seconds.unwrap_or(0);
        }
        if duration == 0 {
            // fMP4（如 B 站 m4s 音频段改后缀伪装成 mp3）的 mdhd 样本数
            // 为 0，上面两条链都拿不到时长；mvhd/mehd/sidx 里通常还
            // 留着总时长，逐层兜底解析出来。
            if let Some(seconds) = mp4_fallback_duration_seconds(path) {
                duration = seconds;
            }
        }
        if sample_rate == 0 {
            sample_rate = identity.sample_rate.unwrap_or(0);
        }
        if bit_depth.is_none() {
            bit_depth = identity.bit_depth;
        }
        if container
            .as_deref()
            .map(|value| value.trim().is_empty())
            .unwrap_or(true)
        {
            container = identity.container;
        }
        codec = identity.codec;
    }

    if bitrate == 0 {
        bitrate = derive_bitrate_kbps(file_size, duration);
    }
    if title.trim().is_empty() {
        title = path.file_stem()?.to_string_lossy().to_string();
    }
    if album_artist.trim().is_empty() {
        album_artist = artist.clone();
    }

    let artist_names = split_artist_names(&artist);
    let album_key = build_album_key(&album, &album_artist);

    Some(Song {
        id: None,
        artist_avatar_bytes,
        name: path.file_name()?.to_string_lossy().to_string(),
        path: path_str.to_string(),
        title,
        artist,
        artist_names: artist_names.clone(),
        effective_artist_names: artist_names,
        album,
        album_artist,
        album_key,
        is_various_artists_album: false,
        collapse_artist_credits: false,
        duration,
        cover_thumb_path: None,
        bitrate,
        sample_rate,
        bit_depth,
        format: format.to_string(),
        container,
        codec,
        file_size,
        track_number,
        disc_number,
        // Keep `added_at` as the frontend sort field, but source it from file time.
        added_at: file_created_at.or(file_modified_at),
        file_modified_at,
        cue_source_path: None,
        cue_start_offset: None,
        cue_end_offset: None,
        comment,
        artist_avatar_path: None,
    })
}

pub(super) fn parse_audio_files_internal(paths: Vec<String>, options: ScanOptions) -> Vec<Song> {
    let mut songs = Vec::new();
    let mut seen_paths = HashSet::new();

    for raw_path in paths {
        let normalized_path = normalize_path(&raw_path);
        if normalized_path.is_empty() || !seen_paths.insert(normalized_path.clone()) {
            continue;
        }

        let path = PathBuf::from(&normalized_path);
        if !path.is_file() {
            continue;
        }

        let extension = path
            .extension()
            .and_then(|ext| ext.to_str())
            .map(|ext| ext.to_ascii_lowercase());

        let Some(extension) = extension else {
            continue;
        };

        if !options.is_ext_allowed(&extension) {
            continue;
        }

        if let Some(song) = parse_song_from_file(&path, &normalized_path, &extension) {
            if options.minimum_duration_seconds > 0
                && song.duration < options.minimum_duration_seconds
            {
                continue;
            }

            songs.push(song);
        }
    }

    songs
}

fn normalize_container(file_type: FileType) -> &'static str {
    match file_type {
        FileType::Aac => "aac",
        FileType::Aiff => "aiff",
        FileType::Ape => "ape",
        FileType::Flac => "flac",
        FileType::Mpeg => "mpeg",
        FileType::Mp4 => "mp4",
        FileType::Mpc => "mpc",
        FileType::Opus | FileType::Speex | FileType::Vorbis => "ogg",
        FileType::Wav => "wav",
        FileType::WavPack => "wavpack",
        FileType::Custom(name) => name,
        _ => "unknown",
    }
}

fn normalize_container_from_extension(ext: &str) -> String {
    match ext.to_ascii_lowercase().as_str() {
        "aif" | "aiff" => "aiff".to_string(),
        "m4a" | "m4b" | "m4p" | "mp4" => "mp4".to_string(),
        "mp1" | "mp2" | "mp3" => "mpeg".to_string(),
        "oga" | "ogg" | "opus" | "spx" | "speex" | "vorbis" => "ogg".to_string(),
        "wav" | "wave" => "wav".to_string(),
        "wv" => "wavpack".to_string(),
        other => other.to_string(),
    }
}

fn normalize_codec(short_name: &str) -> String {
    let codec = short_name.to_ascii_lowercase();
    if codec.starts_with("pcm_") {
        "pcm".to_string()
    } else if codec.starts_with("adpcm_") {
        "adpcm".to_string()
    } else {
        codec
    }
}

fn detect_audio_identity(path: &Path, ext: &str) -> AudioIdentity {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(_) => {
            return AudioIdentity {
                container: Some(normalize_container_from_extension(ext)),
                ..Default::default()
            };
        }
    };

    let media_source = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    hint.with_extension(ext);

    let probed = match symphonia::default::get_probe().format(
        &hint,
        media_source,
        &FormatOptions::default(),
        &MetadataOptions {
            limit_visual_bytes: Limit::Maximum(0),
            ..Default::default()
        },
    ) {
        Ok(probed) => probed,
        Err(_) => {
            return AudioIdentity {
                container: Some(normalize_container_from_extension(ext)),
                ..Default::default()
            };
        }
    };

    let track = match probed
        .format
        .tracks()
        .iter()
        .find(|track| track.codec_params.codec != CODEC_TYPE_NULL)
    {
        Some(track) => track,
        None => {
            return AudioIdentity {
                container: Some(normalize_container_from_extension(ext)),
                ..Default::default()
            };
        }
    };

    let duration_seconds = match (track.codec_params.time_base, track.codec_params.n_frames) {
        (Some(time_base), Some(frames)) if frames > 0 => {
            Some(duration_seconds_from_timebase(time_base, frames))
        }
        _ => None,
    };
    let sample_rate = track.codec_params.sample_rate;
    let bit_depth = track
        .codec_params
        .bits_per_sample
        .or(track.codec_params.bits_per_coded_sample)
        .and_then(|depth| u8::try_from(depth).ok());
    let codec = symphonia::default::get_codecs()
        .get_codec(track.codec_params.codec)
        .map(|descriptor| normalize_codec(descriptor.short_name));

    AudioIdentity {
        container: Some(normalize_container_from_extension(ext)),
        codec,
        duration_seconds,
        sample_rate,
        bit_depth,
    }
}

/// 分片 MP4（fMP4，如 B 站 m4s 音频段改后缀伪装成 mp3）的时长兜底。
///
/// 这类文件的 `mdhd` 样本数为 0，lofty（时长只认 mdhd）与 symphonia
/// 回退（依赖 n_frames）都解析不出；但 `mvhd`（整片时长）、`mehd`
/// （分片总时长，使用 mvhd 时标）或 `sidx`（分片索引）里通常完整
/// 保留了总时长（实测 B 站音频段三者齐全）。按 mvhd → mehd → sidx
/// 逐层兜底，返回向下取整的秒数；都拿不到则返回 None。
fn mp4_fallback_duration_seconds(path: &Path) -> Option<u32> {
    let mut file = File::open(path).ok()?;
    read_mp4_duration_seconds(&mut file)
}

/// MP4 box 头：四字符类型 + 载荷范围（body_start..body_end）。
type Mp4BoxRange = ([u8; 4], u64, u64);

/// 读取一个 MP4 box 头（兼容 size==1 的 64 位 largesize 与 size==0 的
/// 「延伸到末尾」写法），返回类型与载荷范围。
fn next_mp4_box<R: Read + Seek>(reader: &mut R, limit_end: u64) -> Option<Mp4BoxRange> {
    let start = reader.stream_position().ok()?;
    if limit_end.checked_sub(start)? < 8 {
        return None;
    }

    let mut head = [0u8; 8];
    reader.read_exact(&mut head).ok()?;

    let mut body_start = start + 8;
    let total = match u32::from_be_bytes([head[0], head[1], head[2], head[3]]) {
        0 => limit_end - start,
        1 => {
            let mut extended = [0u8; 8];
            reader.read_exact(&mut extended).ok()?;
            body_start += 8;
            u64::from_be_bytes(extended)
        }
        size => u64::from(size),
    };

    if total < body_start - start {
        return None;
    }
    let end = start.checked_add(total)?;
    (end <= limit_end).then_some(([head[4], head[5], head[6], head[7]], body_start, end))
}

fn read_u32_be<R: Read>(reader: &mut R) -> Option<u32> {
    let mut buf = [0u8; 4];
    reader.read_exact(&mut buf).ok()?;
    Some(u32::from_be_bytes(buf))
}

fn read_u64_be<R: Read>(reader: &mut R) -> Option<u64> {
    let mut buf = [0u8; 8];
    reader.read_exact(&mut buf).ok()?;
    Some(u64::from_be_bytes(buf))
}

/// 遍历一个容器 box 的子 box，回调返回 false 时提前停止。
fn walk_mp4_children<R: Read + Seek>(
    reader: &mut R,
    body_start: u64,
    body_end: u64,
    mut on_box: impl FnMut(&mut R, Mp4BoxRange) -> bool,
) {
    let mut pos = body_start;
    while pos + 8 <= body_end {
        if reader.seek(SeekFrom::Start(pos)).is_err() {
            return;
        }
        let Some((kind, box_body_start, box_body_end)) = next_mp4_box(reader, body_end) else {
            return;
        };
        if !on_box(reader, (kind, box_body_start, box_body_end)) {
            return;
        }
        pos = box_body_end;
    }
}

/// 解析 mvhd / mehd 共有的「version + flags + 时间字段」布局，
/// 返回（timescale, duration）。
fn read_movie_header<R: Read + Seek>(reader: &mut R, body_start: u64) -> Option<(u32, u64)> {
    reader.seek(SeekFrom::Start(body_start)).ok()?;
    let version = {
        let mut byte = [0u8; 1];
        reader.read_exact(&mut byte).ok()?;
        byte[0]
    };
    let _flags = {
        let mut bytes = [0u8; 3];
        reader.read_exact(&mut bytes).ok()?;
        bytes
    };
    // version 0: creation(4) + modification(4)；version 1: 各 8 字节
    let skipped = match version {
        1 => read_u64_be(reader)? + read_u64_be(reader)?,
        _ => u64::from(read_u32_be(reader)?) + u64::from(read_u32_be(reader)?),
    };
    let _ = skipped;
    let timescale = read_u32_be(reader)?;
    let duration = match version {
        1 => read_u64_be(reader)?,
        _ => u64::from(read_u32_be(reader)?),
    };
    Some((timescale, duration))
}

/// 解析 mehd（MovieFragmentHeaderBox，分片总时长，时标沿用 mvhd）。
/// 注意 mehd 是 FullBox：version + flags 后直接跟 fragment_duration，
/// 没有 mvhd 的 creation/modification/timescale 字段；version 0 为
/// u32，version 1 为 u64。
fn read_mehd_duration<R: Read + Seek>(reader: &mut R, body_start: u64) -> Option<u64> {
    reader.seek(SeekFrom::Start(body_start)).ok()?;
    let mut ver_flags = [0u8; 4];
    reader.read_exact(&mut ver_flags).ok()?;
    match ver_flags[0] {
        1 => read_u64_be(reader),
        _ => read_u32_be(reader).map(u64::from),
    }
}

/// 解析 sidx 分片索引：总时长 = earliest_presentation_time +
/// Σ subsegment_duration（sidx 自带时标）。
fn read_sidx_duration<R: Read + Seek>(reader: &mut R, body_start: u64) -> Option<u64> {
    reader.seek(SeekFrom::Start(body_start)).ok()?;
    let version = {
        let mut byte = [0u8; 1];
        reader.read_exact(&mut byte).ok()?;
        byte[0]
    };
    let _flags = {
        let mut bytes = [0u8; 3];
        reader.read_exact(&mut bytes).ok()?;
        bytes
    };
    let _reference_id = read_u32_be(reader)?;
    let timescale = read_u32_be(reader)?;
    let earliest_presentation = match version {
        1 => read_u64_be(reader)?,
        _ => u64::from(read_u32_be(reader)?),
    };
    let _first_offset = match version {
        1 => read_u64_be(reader)?,
        _ => u64::from(read_u32_be(reader)?),
    };
    let reserved = read_u32_be(reader)?;
    let reference_count = (reserved & 0xFFFF) as usize;

    let mut total = earliest_presentation;
    for _ in 0..reference_count {
        let _reference = read_u32_be(reader)?;
        total += u64::from(read_u32_be(reader)?); // subsegment_duration
        let _sap = read_u32_be(reader)?;
    }
    (timescale > 0).then(|| total / u64::from(timescale))
}

fn read_mp4_duration_seconds<R: Read + Seek>(reader: &mut R) -> Option<u32> {
    let file_len = reader.seek(SeekFrom::End(0)).ok()?;
    reader.seek(SeekFrom::Start(0)).ok()?;

    let mut moov_range: Option<(u64, u64)> = None;
    let mut sidx_range: Option<(u64, u64)> = None;
    let mut pos = 0u64;
    while pos + 8 <= file_len {
        reader.seek(SeekFrom::Start(pos)).ok()?;
        let Some((kind, body_start, body_end)) = next_mp4_box(reader, file_len) else {
            break;
        };
        if kind == *b"moov" {
            moov_range = Some((body_start, body_end));
        } else if kind == *b"sidx" && sidx_range.is_none() {
            sidx_range = Some((body_start, body_end));
        }
        if body_end <= pos {
            break;
        }
        pos = body_end;
    }

    let (body_start, body_end) = moov_range?;
    let mut movie_timescale: u32 = 0;
    let mut movie_duration: u64 = 0;
    let mut fragment_duration: Option<u64> = None;
    walk_mp4_children(reader, body_start, body_end, |reader, (kind, start, _)| {
        match &kind {
            b"mvhd" => {
                if let Some((timescale, duration)) = read_movie_header(reader, start) {
                    movie_timescale = timescale;
                    movie_duration = duration;
                }
            }
            b"mehd" => {
                fragment_duration = read_mehd_duration(reader, start);
            }
            _ => {}
        }
        // mvhd 与 mehd 都拿齐后即可停
        !(movie_duration > 0 && fragment_duration.is_some())
    });

    let seconds = if movie_timescale > 0 && movie_duration > 0 {
        movie_duration / u64::from(movie_timescale)
    } else if movie_timescale > 0 {
        match fragment_duration.filter(|duration| *duration > 0) {
            Some(duration) => duration / u64::from(movie_timescale),
            None => {
                let (sidx_start, _sidx_end) = sidx_range?;
                let seconds = read_sidx_duration(reader, sidx_start)?;
                if seconds == 0 {
                    return None;
                }
                seconds
            }
        }
    } else {
        let (sidx_start, _sidx_end) = sidx_range?;
        let seconds = read_sidx_duration(reader, sidx_start)?;
        if seconds == 0 {
            return None;
        }
        seconds
    };

    (seconds > 0).then(|| seconds.min(u32::MAX as u64) as u32)
}

fn resolve_album_artist_for_group(songs: &[Song]) -> (String, bool, bool) {
    let tagged_album_artists: Vec<String> = songs
        .iter()
        .filter_map(|song| {
            let trimmed = song.album_artist.trim();
            (!trimmed.is_empty() && !trimmed.eq_ignore_ascii_case(&song.artist))
                .then(|| trimmed.to_string())
        })
        .collect();

    let primary_artists: Vec<String> = songs.iter().map(primary_artist_name).collect();
    let unique_primary_artists: HashSet<String> = primary_artists
        .iter()
        .map(|name| name.to_lowercase())
        .collect();

    if !tagged_album_artists.is_empty() {
        let unique_tagged: HashSet<String> = tagged_album_artists
            .iter()
            .map(|name| name.to_lowercase())
            .collect();
        let resolved = tagged_album_artists[0].clone();
        let is_various = unique_tagged.len() > 1 && unique_primary_artists.len() > 1;
        let collapse = unique_primary_artists.len() > VARIOUS_ARTISTS_THRESHOLD;
        return (
            if is_various {
                VARIOUS_ARTISTS.to_string()
            } else {
                resolved
            },
            is_various,
            collapse,
        );
    }

    if unique_primary_artists.len() <= 1 {
        return (
            primary_artists
                .first()
                .cloned()
                .unwrap_or_else(|| UNKNOWN_ARTIST.to_string()),
            false,
            false,
        );
    }

    let mut counts: HashMap<String, usize> = HashMap::new();
    for name in &primary_artists {
        *counts.entry(name.clone()).or_insert(0) += 1;
    }

    let dominant_artist = counts
        .into_iter()
        .max_by(|(left_name, left_count), (right_name, right_count)| {
            left_count
                .cmp(right_count)
                .then_with(|| right_name.cmp(left_name))
        })
        .map(|(name, _)| name)
        .unwrap_or_else(|| UNKNOWN_ARTIST.to_string());

    let all_unique = unique_primary_artists.len() == songs.len();
    let collapse = unique_primary_artists.len() > VARIOUS_ARTISTS_THRESHOLD;
    let is_various = collapse || all_unique;

    (
        if is_various {
            VARIOUS_ARTISTS.to_string()
        } else {
            dominant_artist
        },
        is_various,
        collapse,
    )
}

pub(crate) fn build_cue_track_song(
    cue_path: &str,
    flac_path: &str,
    track: &CueTrack,
    album_title: Option<&str>,
    album_performer: Option<&str>,
    flac_duration_ms: u32,
) -> Option<Song> {
    let title = track
        .title
        .clone()
        .unwrap_or_else(|| format!("Track {:02}", track.track_number));
    let performer = track
        .performer
        .clone()
        .unwrap_or_else(|| UNKNOWN_ARTIST.to_string());
    let album = album_title.unwrap_or(UNKNOWN_ALBUM).to_string();
    let album_artist = album_performer.unwrap_or(&performer).to_string();
    let artist_names = split_artist_names(&performer);
    let synthetic_path = format!("{}::track{:02}", cue_path, track.track_number);

    let end_ms = track.end_ms.unwrap_or(flac_duration_ms as u64);
    let track_duration = if end_ms > track.index01_start_ms {
        ((end_ms - track.index01_start_ms) / 1000) as u32
    } else {
        0
    };

    let flac_path_buf = std::path::PathBuf::from(flac_path);
    let (cover_thumb_path, bitrate, sample_rate, bit_depth, codec_name) =
        probe_flac_for_cue_metadata(&flac_path_buf);

    let name = format!("{:02}. {}", track.track_number, title);

    Some(Song {
        id: None,
        artist_avatar_bytes: None,
        name,
        path: synthetic_path,
        title,
        artist: performer.clone(),
        artist_names: artist_names.clone(),
        effective_artist_names: artist_names,
        album,
        album_artist,
        album_key: build_album_key(
            album_title.unwrap_or(UNKNOWN_ALBUM),
            album_performer.unwrap_or(&performer),
        ),
        is_various_artists_album: false,
        collapse_artist_credits: false,
        duration: track_duration,
        cover_thumb_path,
        bitrate,
        sample_rate,
        bit_depth,
        format: "flac".to_string(),
        container: Some("flac".to_string()),
        codec: codec_name,
        file_size: std::fs::metadata(&flac_path_buf)
            .map(|m| m.len())
            .unwrap_or(0),
        track_number: Some(track.track_number.to_string()),
        disc_number: None,
        added_at: None,
        file_modified_at: None,
        cue_source_path: Some(flac_path.to_string()),
        cue_start_offset: Some(track.index01_start_ms as u32),
        cue_end_offset: Some(end_ms as u32),
        comment: None,
        artist_avatar_path: None,
    })
}

fn probe_flac_for_cue_metadata(
    flac_path: &std::path::Path,
) -> (Option<String>, u32, u32, Option<u8>, Option<String>) {
    let tagged_file = read_tagged_file_from_path_for_scan(flac_path).ok();
    let cover_thumb_path = None; // Will be generated by cover cache later
    let bitrate = tagged_file
        .as_ref()
        .and_then(|f| f.properties().audio_bitrate())
        .unwrap_or(0);
    let sample_rate = tagged_file
        .as_ref()
        .and_then(|f| f.properties().sample_rate())
        .unwrap_or(0);
    let bit_depth = tagged_file
        .as_ref()
        .and_then(|f| f.properties().bit_depth())
        .map(|b| b as u8);
    let codec_name = None;

    (
        cover_thumb_path,
        bitrate,
        sample_rate,
        bit_depth,
        codec_name,
    )
}

pub(super) fn enrich_album_groups(songs: &mut [Song]) {
    let mut grouped_paths: HashMap<String, Vec<usize>> = HashMap::new();

    for (index, song) in songs.iter().enumerate() {
        let parent_folder = Path::new(&song.path)
            .parent()
            .map(|path| path.to_string_lossy().to_string())
            .unwrap_or_default();
        let album_group_key = format!(
            "{}::{}",
            parent_folder,
            normalize_album_key_part(&song.album, UNKNOWN_ALBUM)
        );
        grouped_paths
            .entry(album_group_key)
            .or_default()
            .push(index);
    }

    for indexes in grouped_paths.into_values() {
        let group_songs: Vec<Song> = indexes.iter().map(|index| songs[*index].clone()).collect();
        let (album_artist, is_various, collapse) = resolve_album_artist_for_group(&group_songs);

        for index in indexes {
            let song = &mut songs[index];
            song.album_artist = album_artist.clone();
            song.album_key = build_album_key(&song.album, &song.album_artist);
            song.is_various_artists_album = is_various;
            song.collapse_artist_credits = collapse;
            song.effective_artist_names = if collapse {
                vec![VARIOUS_ARTISTS.to_string()]
            } else {
                song.artist_names.clone()
            };
        }
    }
}

#[cfg(test)]
mod mp4_duration_tests {
    use super::read_mp4_duration_seconds;
    use std::io::Cursor;

    fn box_with(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut out = ((8 + body.len()) as u32).to_be_bytes().to_vec();
        out.extend_from_slice(kind);
        out.extend_from_slice(body);
        out
    }

    fn container(kind: &[u8; 4], children: &[u8]) -> Vec<u8> {
        box_with(kind, children)
    }

    fn movie_header_box(kind: &[u8; 4], timescale: u32, duration: u32) -> Vec<u8> {
        let mut body = Vec::new();
        body.push(0u8); // version 0
        body.extend_from_slice(&[0, 0, 0]); // flags
        body.extend_from_slice(&0u32.to_be_bytes()); // creation
        body.extend_from_slice(&0u32.to_be_bytes()); // modification
        body.extend_from_slice(&timescale.to_be_bytes());
        body.extend_from_slice(&duration.to_be_bytes());
        box_with(kind, &body)
    }

    fn sidx_v0(timescale: u32, subsegment_durations: &[u32]) -> Vec<u8> {
        let mut body = Vec::new();
        body.push(0u8); // version 0
        body.extend_from_slice(&[0, 0, 0]); // flags
        body.extend_from_slice(&1u32.to_be_bytes()); // reference_ID
        body.extend_from_slice(&timescale.to_be_bytes());
        body.extend_from_slice(&0u32.to_be_bytes()); // earliest_presentation_time
        body.extend_from_slice(&0u32.to_be_bytes()); // first_offset
        let mut reserved_and_count = 0u32;
        reserved_and_count |= subsegment_durations.len() as u32;
        body.extend_from_slice(&reserved_and_count.to_be_bytes());
        for duration in subsegment_durations {
            body.extend_from_slice(&0u32.to_be_bytes()); // reference_type + size
            body.extend_from_slice(&duration.to_be_bytes());
            body.extend_from_slice(&0u32.to_be_bytes()); // SAP info
        }
        box_with(b"sidx", &body)
    }

    fn minimal_fmp4(moov_box: &[u8], sidx: &[u8]) -> Cursor<Vec<u8>> {
        let mut data = Vec::new();
        data.extend_from_slice(&box_with(
            b"ftyp",
            b"isom\x00\x00\x02\x00isomiso2avc1mp41",
        ));
        data.extend_from_slice(moov_box);
        if !sidx.is_empty() {
            data.extend_from_slice(sidx);
        }
        data.extend_from_slice(&box_with(b"moof", &[0u8; 16]));
        data.extend_from_slice(&box_with(b"mdat", &[0u8; 32]));
        Cursor::new(data)
    }

    #[test]
    fn mvhd_duration_wins() {
        let moov = container(
            b"moov",
            &movie_header_box(b"mvhd", 1000, 214_000),
        );
        let mut reader = minimal_fmp4(&moov, &[]);
        assert_eq!(read_mp4_duration_seconds(&mut reader), Some(214));
    }

    #[test]
    fn mvhd_zero_falls_back_to_mehd() {
        // 标准布局的 mehd：version + flags + fragment_duration
        // （mehd 无 creation/modification/timescale 字段，时标沿用 mvhd 的 1000）
        let mehd_body = {
            let mut body = Vec::new();
            body.push(0u8);
            body.extend_from_slice(&[0, 0, 0]);
            body.extend_from_slice(&213_996u32.to_be_bytes());
            box_with(b"mehd", &body)
        };
        let moov = container(
            b"moov",
            &[
                movie_header_box(b"mvhd", 1000, 0).as_slice(),
                mehd_body.as_slice(),
            ]
            .concat(),
        );
        let mut reader = minimal_fmp4(&moov, &[]);
        assert_eq!(read_mp4_duration_seconds(&mut reader), Some(213));
    }

    #[test]
    fn sidx_fallback_when_movie_durations_zero() {
        let moov = container(
            b"moov",
            &movie_header_box(b"mvhd", 1000, 0),
        );
        let durations: Vec<u32> = vec![44_100; 36]; // 36 段各 1 秒（44100 时标）
        let sidx = sidx_v0(44_100, &durations);
        let mut reader = minimal_fmp4(&moov, &sidx);
        assert_eq!(read_mp4_duration_seconds(&mut reader), Some(36));
    }
}
