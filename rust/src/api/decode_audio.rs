//! 空间音频本地解码（AC-4 / AV3A 编码流 → WAV），供 Flutter 播放空间音质档时调用。
//!
//! 背景：Baka[T] 等插件在 dolby/dts 档位返回 AC-4 编码流、atmos 系档位返回
//! AV3A 编码流（多为 MP4 容器），Android 平台播放器（ExoPlayer）不具备这两
//! 种编码的软解能力。播放前把整条流交给本模块转成交错 f32 WAV，再由
//! just_audio 播放本地文件。解码器均为纯 Rust 实现（GPL-3.0-or-later，与
//! 本项目 AGPL-3.0 兼容），vendored 于 `rust/vendor/`：
//! - baka-ac4：AC-4 解码 + MP4/裸流 demux + WavWriter（wav 模块为 XY 导出）。
//! - baka-av3a：AV3A 解码（需外置 model/lsf 参数资产，由 Flutter 打包并在
//!   运行时解到应用私有目录后传入路径）。
//!
//! 错误约定：所有可预期失败一律返回 `Err(String)`，探测识别不了返回
//! `"other"`，不 panic、不抛异常；Dart 侧捕获任何异常后回退直连播放，
//! 保证空间音质「能试」不会变成「必挂」。

use std::fs::File;
use std::io::BufWriter;
use std::sync::Arc;

use baka_ac4_cli::wav::WavWriter;
use baka_ac4_core::ajoc::render::{RenderOptions, SpeakerLayout};
use baka_ac4_core::Ac4Decoder;
use baka_av3a_container::Track;
use baka_av3a_core::decoder::Decoder as Av3aDecoder;
use baka_av3a_core::model::HyperModel;
use baka_av3a_core::shaping::LsfCodebooks;

// =========================================================================
// 格式探测
// =========================================================================

/// 探测文件的空间音频编码格式，返回 `"ac4"` | `"av3a"` | `"other"`。
///
/// MP4：扫顶层 box，找 stsd 里的 'ac-4'（或 'AC-4'）/'av3a' 采样入口；
/// 裸流：按 AC-4 同步字（0xAC 0x40/0x41）判断；识别不了返回 `"other"`，
/// 不抛异常（Dart 侧拿到 "other" 或错误时回退直连播放）。
pub fn probe_spatial_format(path: String) -> Result<String, String> {
    let data = std::fs::read(&path).map_err(|e| format!("读取文件失败 {path}: {e}"))?;
    Ok(probe_format_bytes(&data))
}

/// AC-4 裸流帧头同步字判定（对齐 vendored cli `raw::is_raw_ac4`）。
fn is_sync_word(d: &[u8], off: usize) -> bool {
    d.len() > off + 1 && d[off] == 0xAC && (d[off + 1] == 0x40 || d[off + 1] == 0x41)
}

fn probe_format_bytes(data: &[u8]) -> String {
    if data.len() >= 12 && &data[4..8] == b"ftyp" {
        return probe_mp4(data);
    }
    // 裸流：帧头附近出现 AC-4 同步字即认为裸 AC-4（容忍少量前导填充）。
    let head = &data[..data.len().min(4096)];
    for off in 0..head.len().saturating_sub(1) {
        if is_sync_word(head, off) {
            return "ac4".to_string();
        }
    }
    "other".to_string()
}

/// 遍历 `[start, end)` 内的顶层子 box，回调 (类型, 内容起始, box 结束)。
fn for_each_box<F: FnMut(&str, usize, usize)>(data: &[u8], start: usize, end: usize, mut f: F) {
    let mut off = start;
    while off + 8 <= end {
        let size = u32::from_be_bytes([data[off], data[off + 1], data[off + 2], data[off + 3]]);
        let ty = match std::str::from_utf8(&data[off + 4..off + 8]) {
            Ok(t) => t,
            Err(_) => break,
        };
        let (size, hdr) = if size == 1 {
            // largesize 扩展头
            if off + 16 > end {
                break;
            }
            let ext = u64::from_be_bytes(data[off + 8..off + 16].try_into().unwrap_or([0; 8]));
            let ext = match usize::try_from(ext) {
                Ok(v) => v,
                Err(_) => break,
            };
            (ext, 16)
        } else {
            (size as usize, 8)
        };
        if size == 0 {
            // box 延伸到所属容器末尾：只会是最后一个 box。
            f(ty, off + hdr, end);
            break;
        }
        if size < hdr || off + size > end {
            break;
        }
        f(ty, off + hdr, off + size);
        off += size;
    }
}

/// 按路径逐层查找 box（如 `trak/mdia/minf/stbl/stsd`），返回最内层 box 的
/// 内容区间列表。
fn find_boxes_path(
    data: &[u8],
    start: usize,
    end: usize,
    path: &[&str],
) -> Vec<(usize, usize)> {
    let mut cur = vec![(start, end)];
    for seg in path {
        let mut next = Vec::new();
        for (s, e) in &cur {
            for_each_box(data, *s, *e, |ty, bs, be| {
                if ty == *seg {
                    next.push((bs, be));
                }
            });
        }
        cur = next;
    }
    cur
}

fn probe_mp4(data: &[u8]) -> String {
    let mut found_ac4 = false;
    let mut found_av3a = false;
    for (moov_s, moov_e) in find_boxes_path(data, 0, data.len(), &["moov"]) {
        for (stsd_s, stsd_e) in
            find_boxes_path(data, moov_s, moov_e, &["trak", "mdia", "minf", "stbl", "stsd"])
        {
            // stsd 是 FullBox：4 字节 version/flags + 4 字节 entry_count，
            // 之后是采样入口序列（每个入口：4 字节 size + 4 字节格式 fourcc）。
            let mut off = stsd_s + 8;
            while off + 8 <= stsd_e {
                let size =
                    u32::from_be_bytes([data[off], data[off + 1], data[off + 2], data[off + 3]])
                        as usize;
                if size < 8 || off + size > stsd_e {
                    break;
                }
                if let Ok(entry) = std::str::from_utf8(&data[off + 4..off + 8]) {
                    if entry == "ac-4" || entry == "AC-4" {
                        found_ac4 = true;
                    } else if entry.eq_ignore_ascii_case("av3a") {
                        found_av3a = true;
                    }
                }
                off += size;
            }
        }
    }
    if found_ac4 {
        "ac4".to_string()
    } else if found_av3a {
        "av3a".to_string()
    } else {
        "other".to_string()
    }
}

// =========================================================================
// 解码
// =========================================================================

/// 解码结果信息：采样率 / 声道数 / 解出的帧数 / 总时长（毫秒）。
#[derive(Debug, Clone, Copy)]
pub struct AudioDecodeResult {
    pub sample_rate: i32,
    pub channels: i32,
    pub frames: i64,
    pub duration_ms: i64,
}

/// 解码器 DSP 栈占用较大（上游 CLI 跑解码都放在大栈线程上，debug 下尤甚），
/// 统一放到专用大栈线程执行，避免 FRB 工作线程默认栈溢出。
fn run_on_decode_thread<F, T>(name: &str, task: F) -> Result<T, String>
where
    F: FnOnce() -> Result<T, String> + Send + 'static,
    T: Send + 'static,
{
    let worker = std::thread::Builder::new()
        .name(name.into())
        .stack_size(64 * 1024 * 1024)
        .spawn(task)
        .map_err(|e| format!("解码线程创建失败: {e}"))?;
    worker.join().map_err(|_| "解码线程异常退出".to_string())?
}

/// 把 AC-4 编码文件（MP4/M4A 容器或裸流）解码为交错 f32 WAV。
///
/// - `render`：渲染布局，当前支持 `"stereo"`（A-JOC 对象渲染成立体声），
///   其他值保持解码器默认输出。
///
/// MP4 解不出音轨时自动尝试裸流；`decode_frame_into` 返回 `Ok(None)` 表示
/// 还在等第一个 iframe（需更多输入），跳过该包即可；个别坏包忽略不计，
/// 只要解出至少一帧就算成功。
pub fn decode_ac4_to_wav(
    input_path: String,
    output_path: String,
    render: String,
) -> Result<AudioDecodeResult, String> {
    run_on_decode_thread("ac4-decode", move || decode_ac4_sync(input_path, output_path, render))
}

/// AC-4 解码主体（运行在专用大栈线程上）。
fn decode_ac4_sync(
    input_path: String,
    output_path: String,
    render: String,
) -> Result<AudioDecodeResult, String> {
    let data = std::fs::read(&input_path).map_err(|e| format!("读取输入失败: {e}"))?;
    // 先按 MP4 容器解 demux，失败再按裸流切包（对齐上游 CLI 的 load 逻辑）。
    let track = match baka_ac4_cli::mp4::read_ac4_track(&data) {
        Ok(t) => t,
        Err(mp4_err) => {
            if baka_ac4_cli::raw::is_raw_ac4(&data) {
                baka_ac4_cli::raw::read_ac4_frames(&data)?
            } else {
                return Err(format!(
                    "无法提取 AC-4 包（MP4: {mp4_err}；裸流亦未识别到同步字）"
                ));
            }
        }
    };

    let mut dec = Ac4Decoder::new().map_err(|e| format!("解码器初始化失败: {e}"))?;
    if render.eq_ignore_ascii_case("stereo") {
        dec.set_ajoc_render(Some(RenderOptions::new(SpeakerLayout::Stereo)))
            .map_err(|e| format!("配置立体声渲染失败: {e}"))?;
    }

    let out = File::create(&output_path).map_err(|e| format!("创建输出文件失败: {e}"))?;
    // float=true：写 32-bit float WAV（解码器原生输出 f32，免二次量化）。
    let mut wav = WavWriter::start_fmt(BufWriter::new(out), true)
        .map_err(|e| format!("WAV 初始化失败: {e}"))?;

    let mut pcm: Vec<Vec<f32>> = Vec::new();
    let mut ok_frames: i64 = 0;
    let mut total_samples: u64 = 0;
    let mut sample_rate = 0i32;
    let mut channels = 0i32;

    for (index, (off, size)) in track.samples.iter().enumerate() {
        let pkt = &data[*off as usize..(*off + *size as u64) as usize];
        match dec.decode_frame_into(pkt, &mut pcm) {
            Ok(Some(info)) => {
                let n = pcm.first().map_or(0, Vec::len);
                if info.sample_rate == 0 || n == 0 || pcm.is_empty() {
                    continue;
                }
                if let Err(e) = wav.write_frame_planar(&pcm, info.sample_rate, info.channel_mask)
                {
                    return Err(format!("WAV 写入失败（第 {index} 包）: {e}"));
                }
                if ok_frames == 0 {
                    channels = pcm.len() as i32;
                    sample_rate = info.sample_rate as i32;
                }
                total_samples += n as u64;
                ok_frames += 1;
            }
            // Ok(None)：解码器仍在等第一个 iframe，跳过该包继续喂。
            Ok(None) => {}
            // 个别坏包忽略，保持健壮（对齐上游 CLI 的容错策略）。
            Err(_) => {}
        }
    }

    finish_wav_and_result(wav, ok_frames, total_samples, sample_rate, channels)
}

/// 把 AV3A 编码文件（MP4 容器）解码为交错 f32 WAV。
///
/// AV3A 解码需要两个外置参数资产（由 App 打包并在运行时解到私有目录）：
/// - `model_path`：HyperModel 权重（model.bin）
/// - `lsf_path`：LSF 码本（lsf.bin）
///
/// 容器由 vendored baka-av3a-container 的 `Track::parse` demux；解码逐包进
/// 行，个别坏包忽略（`Decoder::decode` 失败时内部状态保持不变，后续包不受
/// 影响），只要解出至少一帧就算成功。上游 AV3A 是 MP4 封装，不提供裸流
/// 路径——裸流在 `Track::parse` 失败时直接报错并交由 Dart 侧回退。
pub fn decode_av3a_to_wav(
    input_path: String,
    output_path: String,
    model_path: String,
    lsf_path: String,
) -> Result<AudioDecodeResult, String> {
    run_on_decode_thread("av3a-decode", move || {
        decode_av3a_sync(input_path, output_path, model_path, lsf_path)
    })
}

/// AV3A 解码主体（运行在专用大栈线程上）。
fn decode_av3a_sync(
    input_path: String,
    output_path: String,
    model_path: String,
    lsf_path: String,
) -> Result<AudioDecodeResult, String> {
    let data = std::fs::read(&input_path).map_err(|e| format!("读取输入失败: {e}"))?;
    let model_bytes = std::fs::read(&model_path).map_err(|e| format!("读取 AV3A 模型失败: {e}"))?;
    let lsf_bytes = std::fs::read(&lsf_path).map_err(|e| format!("读取 AV3A 码本失败: {e}"))?;

    let track = Track::parse(&data).map_err(|e| format!("AV3A MP4 解析失败: {e}"))?;
    if track.packet_count() == 0 {
        return Err("AV3A 音轨没有任何包".into());
    }
    let model = HyperModel::parse(&model_bytes).map_err(|e| format!("AV3A 模型解析失败: {e}"))?;
    let lsf = LsfCodebooks::parse(&lsf_bytes).map_err(|e| format!("AV3A 码本解析失败: {e}"))?;
    let mut dec = Av3aDecoder::new(Arc::new(model), Arc::new(lsf));

    let out = File::create(&output_path).map_err(|e| format!("创建输出文件失败: {e}"))?;
    // 与 AC-4 路径统一：float WAV（解码器原生输出交错 f32）。
    let mut wav = WavWriter::start_fmt(BufWriter::new(out), true)
        .map_err(|e| format!("WAV 初始化失败: {e}"))?;

    let mut ok_frames: i64 = 0;
    let mut total_samples: u64 = 0;
    let mut sample_rate = 0i32;
    let mut channels = 0i32;

    for packet in track.packets() {
        match dec.decode(packet.bytes) {
            Ok(frame) => {
                let ch = frame.channels as usize;
                let n = if ch == 0 { 0 } else { frame.samples.len() / ch };
                if frame.sample_rate == 0 || ch == 0 || n == 0 {
                    continue;
                }
                // PcmFrame.samples 是交错排列，WavWriter 按声道平面写入，
                // 这里解交错；声道掩码：单声道 4 / 立体声 3 / 其余置 0
                // （WavWriter 对 0 掩码保留未指定布局，写 extensible 头）。
                let mut planar: Vec<Vec<f32>> = (0..ch)
                    .map(|_| Vec::with_capacity(n))
                    .collect();
                for (i, v) in frame.samples.iter().enumerate() {
                    planar[i % ch].push(*v);
                }
                let mask: u64 = match ch {
                    1 => 4,
                    2 => 3,
                    _ => 0,
                };
                if let Err(e) = wav.write_frame_planar(&planar, frame.sample_rate, mask) {
                    return Err(format!(
                        "WAV 写入失败（第 {} 包）: {e}",
                        packet.index
                    ));
                }
                if ok_frames == 0 {
                    channels = frame.channels as i32;
                    sample_rate = frame.sample_rate as i32;
                }
                total_samples += n as u64;
                ok_frames += 1;
            }
            // 坏包忽略：decode 失败时解码器状态保持不变，后续包继续。
            Err(_) => {}
        }
    }

    finish_wav_and_result(wav, ok_frames, total_samples, sample_rate, channels)
}

/// 统一收尾：校验至少解出一帧、写 WAV 头、按总采样数折算时长。
/// `finish(self)` 按值消费 writer，这里直接接管所有权。
fn finish_wav_and_result<W: std::io::Write + std::io::Seek>(
    wav: WavWriter<W>,
    ok_frames: i64,
    total_samples: u64,
    sample_rate: i32,
    channels: i32,
) -> Result<AudioDecodeResult, String> {
    if ok_frames == 0 {
        return Err("未能从输入解出任何音频帧（可能不是 AC-4/AV3A 编码或流已损坏）".into());
    }
    wav.finish().map_err(|e| format!("WAV 收尾失败: {e}"))?;
    let duration_ms = if sample_rate > 0 {
        (total_samples as f64 / f64::from(sample_rate) * 1000.0).round() as i64
    } else {
        0
    };
    Ok(AudioDecodeResult {
        sample_rate,
        channels,
        frames: ok_frames,
        duration_ms,
    })
}

// =========================================================================
// 单元测试（合成字节验证 probe 分支；复用 vendored 合成模型/码本/帧做
// AC-4 探测与 AV3A 端到端解码冒烟）
// =========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    /// 组装一个标准 box（size + type + body）。
    fn push_box(out: &mut Vec<u8>, ty: &[u8; 4], body: &[u8]) {
        out.extend_from_slice(&((body.len() as u32) + 8).to_be_bytes());
        out.extend_from_slice(ty);
        out.extend_from_slice(body);
    }

    /// 构造最小 MP4：ftyp + moov/trak/mdia/minf/stbl/stsd(指定采样入口 fourcc)。
    fn mp4_with_stsd_entry(format: &[u8; 4]) -> Vec<u8> {
        // 采样入口固定 36 字节（size+format+6 保留+2 数据引用+2+2 版本/修订
        // +4 厂商+2 声道+2 位深+4 预留+2+2 保留+4 采样率16.16）。
        let mut entry = Vec::new();
        entry.extend_from_slice(&(36u32).to_be_bytes());
        entry.extend_from_slice(format);
        entry.extend_from_slice(&[0u8; 6]);
        entry.extend_from_slice(&1u16.to_be_bytes());
        entry.extend_from_slice(&[0u8; 8]);
        entry.extend_from_slice(&2u16.to_be_bytes());
        entry.extend_from_slice(&16u16.to_be_bytes());
        entry.extend_from_slice(&[0u8; 4]);
        entry.extend_from_slice(&(48000u32 << 16).to_be_bytes());
        assert_eq!(entry.len(), 36);

        let mut stsd = vec![0u8; 4]; // version/flags
        stsd.extend_from_slice(&1u32.to_be_bytes()); // entry_count
        stsd.extend_from_slice(&entry);

        let mut stbl = Vec::new();
        push_box(&mut stbl, b"stsd", &stsd);
        let mut minf = Vec::new();
        push_box(&mut minf, b"stbl", &stbl);
        let mut mdia = Vec::new();
        push_box(&mut mdia, b"minf", &minf);
        let mut trak = Vec::new();
        push_box(&mut trak, b"mdia", &mdia);
        let mut moov = Vec::new();
        push_box(&mut moov, b"trak", &trak);

        let mut mp4 = Vec::new();
        push_box(&mut mp4, b"ftyp", b"isom");
        push_box(&mut mp4, b"moov", &moov);
        mp4
    }

    #[test]
    fn probe_detects_mp4_ac4_av3a_and_other() {
        assert_eq!(probe_format_bytes(&mp4_with_stsd_entry(b"ac-4")), "ac4");
        // 大写变体同样识别为 ac4。
        assert_eq!(probe_format_bytes(&mp4_with_stsd_entry(b"AC-4")), "ac4");
        // av3a 采样入口（Baka 系 atmos 档位的封装）。
        assert_eq!(probe_format_bytes(&mp4_with_stsd_entry(b"av3a")), "av3a");
        assert_eq!(probe_format_bytes(&mp4_with_stsd_entry(b"AV3A")), "av3a");
        // 普通有损音轨不是空间音频格式。
        assert_eq!(probe_format_bytes(&mp4_with_stsd_entry(b"mp4a")), "other");
    }

    #[test]
    fn probe_detects_raw_ac4_syncword() {
        // 0xAC40 帧头 + size 字段 + 帧体。
        let mut raw = vec![0xAC, 0x40, 0x00, 0x10];
        raw.extend_from_slice(&[0u8; 16]);
        assert_eq!(probe_format_bytes(&raw), "ac4");
        // 0xAC41（带子流索引）帧头同样识别。
        let mut raw41 = vec![0xAC, 0x41, 0x00, 0x12];
        raw41.extend_from_slice(&[0u8; 18]);
        assert_eq!(probe_format_bytes(&raw41), "ac4");
    }

    #[test]
    fn probe_returns_other_for_garbage_and_empty() {
        assert_eq!(probe_format_bytes(&[]), "other");
        assert_eq!(probe_format_bytes(b"not an audio file at all......"), "other");
        assert_eq!(probe_format_bytes(&[0xFF; 64]), "other");
    }

    #[test]
    fn probe_matches_vendored_real_fixtures() {
        // 冒烟：vendored 上游自带样本应为可识别格式（裸流 / MP4 容器）。
        let raw_fix = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/vendor/baka-ac4/crates/baka-ac4-core/tests/fixtures/p83_iframe_plus5.ac4"
        );
        let data = std::fs::read(raw_fix).expect("裸流 fixture 应随 vendor 副本存在");
        assert_eq!(probe_format_bytes(&data), "ac4");

        let mp4_fix = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/vendor/baka-ac4/crates/baka-ac4-core/tests/fixtures/mp4_probe.mp4"
        );
        let data = std::fs::read(mp4_fix).expect("MP4 fixture 应随 vendor 副本存在");
        assert_eq!(probe_format_bytes(&data), "ac4");
    }

    // -----------------------------------------------------------------
    // AV3A 端到端冒烟：用 vendored 合成 model/lsf/帧 fixture 拼一个最小
    // MP4，走 Track::parse → Decoder → WAV 全链路（结构对齐上游
    // baka-av3a-container/tests/mp4.rs 的 front_fixture 构造）。
    // -----------------------------------------------------------------

    // #[path] 在嵌套内联模块里以合成目录（decode_audio/tests/）为基准，
    // 因此需要上跳四级到达 rust/vendor/。
    #[path = "../../../../vendor/baka-av3a/crates/baka-av3a-core/tests/fixtures/bed_frame.rs"]
    mod bed_frame;
    #[path = "../../../../vendor/baka-av3a/crates/baka-av3a-core/tests/fixtures/lsf_asset.rs"]
    mod lsf_asset;
    #[path = "../../../../vendor/baka-av3a/crates/baka-av3a-core/tests/fixtures/model_record.rs"]
    mod model_record;

    /// 给合成帧补 CRC（对齐上游测试的 checksum 辅助）。
    fn patch_crc(packet: &mut [u8]) {
        let crc = baka_av3a_core::payload_crc(&packet[7..]);
        packet[3] = (packet[3] & 0xe0) | (crc >> 11) as u8;
        packet[4] = (packet[4] & 0x1f) | (((crc >> 8) as u8 & 7) << 5);
        packet[6] = crc as u8;
    }

    /// u32 序列转大端字节（stsz/stco/stsc/stts 等表格共用）。
    fn be_words(values: &[u32]) -> Vec<u8> {
        let mut out = Vec::with_capacity(values.len() * 4);
        for v in values {
            out.extend_from_slice(&v.to_be_bytes());
        }
        out
    }

    /// 构造含 2 个可解码包的最小 AV3A MP4（mdat 在前、moov 在后，
    /// stco 绝对偏移指向 mdat 载荷；结构对齐上游 container 测试的
    /// fixture + playback 用例，包体用 CRC 补丁后的合成 bed 帧）。
    fn synthetic_av3a_mp4() -> Vec<u8> {
        let mut packet = bed_frame::frame(true);
        patch_crc(&mut packet);
        let pkt_len = packet.len() as u32;

        let mut entry = vec![0u8; 28];
        entry[6..8].copy_from_slice(&1u16.to_be_bytes()); // 数据引用计数
        entry[16..18].copy_from_slice(&12u16.to_be_bytes()); // 声道数
        entry[18..20].copy_from_slice(&16u16.to_be_bytes()); // 位深
        entry[24..28].copy_from_slice(&(44100u32 << 16).to_be_bytes());
        let mut entry_box = Vec::new();
        push_box(&mut entry_box, b"av3a", &entry);
        let mut stsd = vec![0u8; 4]; // version/flags
        stsd.extend_from_slice(&1u32.to_be_bytes()); // entry_count
        stsd.extend_from_slice(&entry_box);

        let mut stbl = Vec::new();
        push_box(&mut stbl, b"stsd", &stsd);
        // stsz：uniform 尺寸 2 包；stco：1 个 chunk，偏移 8（mdat 头后）。
        push_box(&mut stbl, b"stsz", &be_words(&[0, pkt_len, 2]));
        push_box(&mut stbl, b"stco", &be_words(&[0, 1, 8]));
        push_box(&mut stbl, b"stsc", &be_words(&[0, 1, 1, 2, 1]));
        push_box(&mut stbl, b"stts", &be_words(&[0, 1, 2, 1024]));
        let mut mdia = Vec::new();
        let mut hdlr = vec![0u8; 8];
        hdlr.extend_from_slice(b"soun");
        push_box(&mut mdia, b"hdlr", &hdlr);
        // mdhd：timescale 44100。
        push_box(&mut mdia, b"mdhd", &be_words(&[0, 0, 0, 44100, 2048, 0]));
        let mut minf = Vec::new();
        push_box(&mut minf, b"stbl", &stbl);
        push_box(&mut mdia, b"minf", &minf);
        let mut trak = Vec::new();
        push_box(&mut trak, b"mdia", &mdia);
        let moov = {
            let mut trak_box = Vec::new();
            push_box(&mut trak_box, b"trak", &trak);
            let mut moov_box = Vec::new();
            push_box(&mut moov_box, b"moov", &trak_box);
            moov_box
        };

        // mdat 载荷占位两包长度，再回填 CRC 补丁后的真实包内容。
        let payload_len = packet.len() * 2;
        let mut mp4 = Vec::new();
        push_box(&mut mp4, b"mdat", &vec![0u8; payload_len]);
        for chunk in mp4[8..8 + payload_len].chunks_exact_mut(packet.len()) {
            chunk.copy_from_slice(&packet);
        }
        mp4.extend_from_slice(&moov);
        mp4
    }

    /// 在系统临时目录写一份内容唯一的文件，返回路径。
    fn write_temp_file(tag: &str, bytes: &[u8]) -> std::path::PathBuf {
        let dir = std::env::temp_dir();
        let path = dir.join(format!(
            "xy-decode-audio-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::write(&path, bytes).expect("写测试临时文件失败");
        path
    }

    #[test]
    fn decode_av3a_synthetic_mp4_end_to_end() {
        let mp4 = write_temp_file("sample.mp4", &synthetic_av3a_mp4());
        let model = write_temp_file("model.bin", &model_record::fixture());
        let lsf = write_temp_file("lsf.bin", &lsf_asset::asset());
        let wav_path = mp4.with_extension("wav");

        let result = decode_av3a_to_wav(
            mp4.to_string_lossy().into_owned(),
            wav_path.to_string_lossy().into_owned(),
            model.to_string_lossy().into_owned(),
            lsf.to_string_lossy().into_owned(),
        )
        .expect("合成 AV3A MP4 应能端到端解出 WAV");

        // 合成帧是 12 声道 bed，每包 1024 样/声道，采样率 44100。
        assert_eq!((result.channels, result.frames), (12, 2));
        assert_eq!(result.sample_rate, 44100);
        let wav_bytes = std::fs::read(&wav_path).expect("WAV 应已写出");
        // 2 包 × 1024 样 × 12 声道 × 4 字节 float + extensible 头。
        assert_eq!(wav_bytes.len(), 68 + 2 * 1024 * 12 * 4);
        let _ = std::fs::remove_file(&mp4);
        let _ = std::fs::remove_file(&model);
        let _ = std::fs::remove_file(&lsf);
        let _ = std::fs::remove_file(&wav_path);
    }

    #[test]
    fn decode_av3a_rejects_non_mp4_input() {
        let garbage = write_temp_file("garbage.bin", b"definitely not an mp4");
        let model = write_temp_file("model2.bin", &model_record::fixture());
        let lsf = write_temp_file("lsf2.bin", &lsf_asset::asset());
        let wav_path = garbage.with_extension("wav");
        assert!(decode_av3a_to_wav(
            garbage.to_string_lossy().into_owned(),
            wav_path.to_string_lossy().into_owned(),
            model.to_string_lossy().into_owned(),
            lsf.to_string_lossy().into_owned(),
        )
        .is_err());
        let _ = std::fs::remove_file(&garbage);
        let _ = std::fs::remove_file(&model);
        let _ = std::fs::remove_file(&lsf);
    }
}
