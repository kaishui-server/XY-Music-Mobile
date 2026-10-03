//! AAudio 独占模式实现（仅 Android）。
//!
//! 移植自 RawS `native_audio_engine.cpp` 的 AAudio DIRECT 路径：
//! - `AAUDIO_SHARING_MODE_EXCLUSIVE` 绕过 Android 混音器
//! - `setDeviceId` 路由到 USB DAC
//! - 浮点 32bit / Int16 双格式协商
//! - 失败时返回明确错误，供调用方降级到 `just_audio`
//!
//! 动态加载 `libaaudio.so`（API 26+），低版本自动降级。

#![allow(dead_code)]

use crate::player::buffered_source::{BlockProducer, BufferedSource};
use crate::player::equalizer::{Equalizer, EqualizerHandle, EqualizerSettings};
use crate::player::loudness::VolumeNormalizer;
use crate::player::qmc2::{
    extract_ekey_from_footer, looks_like_qmc_encrypted, QmcCrypto, QmcDecryptReader,
};
use crate::player::sound_effect::{SoundEffectBlockProcessor, SoundEffectSettings};
use crate::player::types::global_visualizer;
use std::io::{Read, Seek, SeekFrom};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, SyncSender};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

/// 从 URL 提取路径扩展名（去掉 query/fragment），供 symphonia 探测提示。
fn url_path_extension(url: &str) -> Option<String> {
    let no_query = url.split(['?', '#']).next().unwrap_or(url);
    let ext = std::path::Path::new(no_query)
        .extension()
        .and_then(|e| e.to_str())?;
    let ext = ext.to_ascii_lowercase();
    if ext.is_empty() || ext.len() > 8 {
        return None;
    }
    let clean: String = ext.chars().filter(|c| c.is_ascii_alphanumeric()).collect();
    if clean.is_empty() {
        None
    } else {
        Some(clean)
    }
}

/// 流缓存 Reader 的 MediaSource 适配：`Box<dyn ReadSeek>` 不自动实现
/// Read/Seek 超 trait，用具体 newtype 转发以满足 symphonia 的
/// `MediaSource` blanket impl。`total_shared` 为共享总长槽位（0 = 未知）：
/// symphonia FLAC/MP3 demuxer 的 seek 依赖 `byte_len()` 提供二分上界。
struct StreamCacheMediaReader {
    inner: Box<dyn crate::player::stream_cache::ReadSeek + Send + Sync>,
    total_shared: Option<Arc<AtomicU64>>,
}

impl std::io::Read for StreamCacheMediaReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.inner.read(buf)
    }
}

impl std::io::Seek for StreamCacheMediaReader {
    fn seek(&mut self, pos: std::io::SeekFrom) -> std::io::Result<u64> {
        self.inner.seek(pos)
    }
}

impl symphonia::core::io::MediaSource for StreamCacheMediaReader {
    fn is_seekable(&self) -> bool {
        true
    }

    fn byte_len(&self) -> Option<u64> {
        let v = self
            .total_shared
            .as_ref()
            .map(|t| t.load(Ordering::Relaxed))
            .unwrap_or(0);
        if v == 0 {
            None
        } else {
            Some(v)
        }
    }
}

// =========================================================================
// AAudio FFI 常量
// =========================================================================

const AAUDIO_OK: i32 = 0;
const AAUDIO_ERROR_TIMEOUT: i32 = -13;
const AAUDIO_SHARING_MODE_EXCLUSIVE: i32 = 0;
const AAUDIO_SHARING_MODE_SHARED: i32 = 1;
const AAUDIO_FORMAT_INVALID: i32 = 0;
const AAUDIO_FORMAT_PCM_I16: i32 = 1;
const AAUDIO_FORMAT_PCM_FLOAT: i32 = 2;
const AAUDIO_PERFORMANCE_MODE_LOW_LATENCY: i32 = 4;
const AAUDIO_DIRECTION_OUTPUT: i32 = 0;
/// 流已断开（设备移除/系统回收）。车机/蓝牙在流暂停期间常主动断开。
const AAUDIO_STREAM_STATE_DISCONNECTED: i32 = 13;

// =========================================================================
// AAudio FFI 类型
// =========================================================================

type AAudioStream = std::os::raw::c_void;
type AAudioStreamBuilder = std::os::raw::c_void;

// 函数指针类型
type FnCreateStreamBuilder = unsafe extern "C" fn(*mut *mut AAudioStreamBuilder) -> i32;
type FnBuilderDelete = unsafe extern "C" fn(*mut AAudioStreamBuilder) -> i32;
type FnBuilderSetDeviceId = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
type FnBuilderSetSampleRate = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
type FnBuilderSetChannelCount = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
type FnBuilderSetFormat = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
type FnBuilderSetSharingMode = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
type FnBuilderSetPerformanceMode = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
type FnBuilderSetBufferCapacity = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
type FnBuilderSetDirection = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
type FnBuilderOpenStream =
    unsafe extern "C" fn(*mut AAudioStreamBuilder, *mut *mut AAudioStream) -> i32;
type FnStreamRequestStart = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamRequestPause = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamRequestStop = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamClose = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamWrite =
    unsafe extern "C" fn(*mut AAudioStream, *const std::os::raw::c_void, i32, i64) -> i64;
type FnStreamGetAvailableFrames = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamGetXRunCount = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamGetSampleRate = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamGetChannelCount = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamGetFormat = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamGetState = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamGetBufferSize = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamGetTimestamp =
    unsafe extern "C" fn(*mut AAudioStream, *mut std::os::raw::c_int, *mut i64, *mut i64) -> i32;
type FnConvertResultToText = unsafe extern "C" fn(i32) -> *const std::os::raw::c_char;

/// 动态加载的 AAudio 函数表。
struct AAudioLib {
    _handle: *mut std::os::raw::c_void,
    create_stream_builder: FnCreateStreamBuilder,
    builder_delete: FnBuilderDelete,
    builder_set_device_id: FnBuilderSetDeviceId,
    builder_set_sample_rate: FnBuilderSetSampleRate,
    builder_set_channel_count: FnBuilderSetChannelCount,
    builder_set_format: FnBuilderSetFormat,
    builder_set_sharing_mode: FnBuilderSetSharingMode,
    builder_set_performance_mode: FnBuilderSetPerformanceMode,
    builder_set_buffer_capacity: FnBuilderSetBufferCapacity,
    builder_set_direction: FnBuilderSetDirection,
    builder_open_stream: FnBuilderOpenStream,
    stream_request_start: FnStreamRequestStart,
    stream_request_pause: FnStreamRequestPause,
    stream_request_stop: FnStreamRequestStop,
    stream_close: FnStreamClose,
    stream_write: FnStreamWrite,
    stream_get_available_frames: FnStreamGetAvailableFrames,
    stream_get_xrun_count: FnStreamGetXRunCount,
    stream_get_sample_rate: FnStreamGetSampleRate,
    stream_get_channel_count: FnStreamGetChannelCount,
    stream_get_format: FnStreamGetFormat,
    stream_get_state: FnStreamGetState,
    stream_get_buffer_size: FnStreamGetBufferSize,
    stream_get_timestamp: FnStreamGetTimestamp,
    convert_result_to_text: FnConvertResultToText,
}

unsafe impl Send for AAudioLib {}

impl AAudioLib {
    /// 动态加载 libaaudio.so。失败返回 None（API < 26 或库损坏）。
    fn load() -> Option<Self> {
        unsafe {
            let name = b"libaaudio.so\0".as_ptr();
            let handle = libc::dlopen(name as *const _, libc::RTLD_NOW);
            if handle.is_null() {
                return None;
            }

            macro_rules! sym {
                ($name:expr, $type:ty) => {{
                    let sym_name = concat!($name, "\0").as_ptr();
                    let ptr = libc::dlsym(handle, sym_name as *const _);
                    if ptr.is_null() {
                        libc::dlclose(handle);
                        return None;
                    }
                    std::mem::transmute::<*mut std::os::raw::c_void, $type>(ptr)
                }};
            }

            let lib = Self {
                _handle: handle,
                create_stream_builder: sym!("AAudio_createStreamBuilder", FnCreateStreamBuilder),
                builder_delete: sym!("AAudioStreamBuilder_delete", FnBuilderDelete),
                builder_set_device_id: sym!(
                    "AAudioStreamBuilder_setDeviceId",
                    FnBuilderSetDeviceId
                ),
                builder_set_sample_rate: sym!(
                    "AAudioStreamBuilder_setSampleRate",
                    FnBuilderSetSampleRate
                ),
                builder_set_channel_count: sym!(
                    "AAudioStreamBuilder_setChannelCount",
                    FnBuilderSetChannelCount
                ),
                builder_set_format: sym!("AAudioStreamBuilder_setFormat", FnBuilderSetFormat),
                builder_set_sharing_mode: sym!(
                    "AAudioStreamBuilder_setSharingMode",
                    FnBuilderSetSharingMode
                ),
                builder_set_performance_mode: sym!(
                    "AAudioStreamBuilder_setPerformanceMode",
                    FnBuilderSetPerformanceMode
                ),
                builder_set_buffer_capacity: sym!(
                    "AAudioStreamBuilder_setBufferCapacityInFrames",
                    FnBuilderSetBufferCapacity
                ),
                builder_set_direction: sym!(
                    "AAudioStreamBuilder_setDirection",
                    FnBuilderSetDirection
                ),
                builder_open_stream: sym!("AAudioStreamBuilder_openStream", FnBuilderOpenStream),
                stream_request_start: sym!("AAudioStream_requestStart", FnStreamRequestStart),
                stream_request_pause: sym!("AAudioStream_requestPause", FnStreamRequestPause),
                stream_request_stop: sym!("AAudioStream_requestStop", FnStreamRequestStop),
                stream_close: sym!("AAudioStream_close", FnStreamClose),
                stream_write: sym!("AAudioStream_write", FnStreamWrite),
                stream_get_available_frames: sym!(
                    "AAudioStream_getAvailableFrames",
                    FnStreamGetAvailableFrames
                ),
                stream_get_xrun_count: sym!("AAudioStream_getXRunCount", FnStreamGetXRunCount),
                stream_get_sample_rate: sym!("AAudioStream_getSampleRate", FnStreamGetSampleRate),
                stream_get_channel_count: sym!(
                    "AAudioStream_getChannelCount",
                    FnStreamGetChannelCount
                ),
                stream_get_format: sym!("AAudioStream_getFormat", FnStreamGetFormat),
                stream_get_state: sym!("AAudioStream_getState", FnStreamGetState),
                stream_get_buffer_size: sym!(
                    "AAudioStream_getBufferSizeInFrames",
                    FnStreamGetBufferSize
                ),
                stream_get_timestamp: sym!("AAudioStream_getTimestamp", FnStreamGetTimestamp),
                convert_result_to_text: sym!("AAudio_convertResultToText", FnConvertResultToText),
            };
            Some(lib)
        }
    }

    unsafe fn result_text(&self, result: i32) -> String {
        let ptr = (self.convert_result_to_text)(result);
        if ptr.is_null() {
            return format!("AAudio error {}", result);
        }
        let cstr = std::ffi::CStr::from_ptr(ptr);
        cstr.to_string_lossy().into_owned()
    }
}

// =========================================================================
// 设备格式
// =========================================================================

#[derive(Clone, Copy, PartialEq)]
enum DeviceFormat {
    Float32,
    Int16,
}

impl DeviceFormat {
    fn aaudio_format(self) -> i32 {
        match self {
            Self::Float32 => AAUDIO_FORMAT_PCM_FLOAT,
            Self::Int16 => AAUDIO_FORMAT_PCM_I16,
        }
    }

    fn bytes_per_sample(self) -> usize {
        match self {
            Self::Float32 => 4,
            Self::Int16 => 2,
        }
    }
}

/// f32 → 设备格式字节（小端 LE）。
fn push_sample_bytes(buf: &mut Vec<u8>, sample: f32, fmt: DeviceFormat) {
    let clamped = sample.clamp(-1.0, 1.0);
    match fmt {
        DeviceFormat::Float32 => {
            buf.extend_from_slice(&clamped.to_le_bytes());
        }
        DeviceFormat::Int16 => {
            let val = (clamped * 32767.0) as i16;
            buf.extend_from_slice(&val.to_le_bytes());
        }
    }
}

// =========================================================================
// Symphonia 解码器（BlockProducer）
// =========================================================================

struct SymphoniaDecoder {
    format_reader: Box<dyn symphonia::core::formats::FormatReader>,
    decoder: Box<dyn symphonia::core::codecs::Decoder>,
    track_id: u32,
    sample_rate: u32,
    channels: u16,
    total_duration: Option<Duration>,
    sample_buf: Option<symphonia::core::audio::SampleBuffer<f32>>,
    sample_buf_frames: usize,
    leftover: Vec<f32>,
    eof: bool,
}

impl SymphoniaDecoder {
    /// `stream_reader`：预构建的流缓存 Reader（在线直读）。Some 时
    /// 跳过本地文件构造，`path` 仅用于扩展名探测提示（应为直链 URL）。
    fn open(
        path: &str,
        stream_reader: Option<
            Box<dyn crate::player::stream_cache::ReadSeek + Send + Sync>,
        >,
        stream_state: Option<&crate::player::stream_cache::StreamingTempFileState>,
    ) -> Result<Self, String> {
        use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
        use symphonia::core::formats::FormatOptions;
        use symphonia::core::io::MediaSourceStream;
        use symphonia::core::meta::MetadataOptions;
        use symphonia::core::probe::Hint;

        let mut hint = Hint::new();
        let mss: MediaSourceStream = if let Some(reader) = stream_reader {
            // 流缓存直读：数据已由下载线程落盘（≥最小缓冲），探测头立即可读。
            // 扩展名从 URL 路径提取（去掉 query）供格式探测。
            if let Some(ext) = url_path_extension(path) {
                hint.with_extension(&ext);
            }
            MediaSourceStream::new(
                Box::new(StreamCacheMediaReader {
                    inner: reader,
                    total_shared: stream_state.map(|s| s.content_length_shared.clone()),
                }),
                Default::default(),
            )
        } else {
            let mut file = std::fs::File::open(path).map_err(|e| e.to_string())?;

            // 检查 QMC2 加密
            let mut header = [0u8; 8];
            let header_len = file.read(&mut header).unwrap_or(0);
            file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;

            let is_qmc = header_len >= 4 && looks_like_qmc_encrypted(&header[..header_len]);

            // 动态分发：普通文件 vs QMC 解密包装
            if is_qmc {
                // 读取文件末尾 1024 字节提取 ekey
                let file_size = file.seek(SeekFrom::End(0)).map_err(|e| e.to_string())?;
                let tail_size = (file_size.min(1024)) as usize;
                file.seek(SeekFrom::End(-(tail_size as i64)))
                    .map_err(|e| e.to_string())?;
                let mut tail = vec![0u8; tail_size];
                file.read_exact(&mut tail).ok();
                file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;

                let crypto = if let Some(ekey) = extract_ekey_from_footer(&tail) {
                    QmcCrypto::from_ekey(&ekey).unwrap_or_else(|_| QmcCrypto::qmc1())
                } else {
                    QmcCrypto::qmc1()
                };
                let reader = QmcDecryptReader::new(file, crypto);
                MediaSourceStream::new(Box::new(reader), Default::default())
            } else {
                MediaSourceStream::new(Box::new(file), Default::default())
            }
        };

        if stream_state.is_none() {
            if let Some(ext) = std::path::Path::new(path)
                .extension()
                .and_then(|e| e.to_str())
            {
                hint.with_extension(ext);
            }
        }

        let probed = symphonia::default::get_probe()
            .format(
                &hint,
                mss,
                &FormatOptions::default(),
                &MetadataOptions::default(),
            )
            .map_err(|e| e.to_string())?;

        let track = probed
            .format
            .tracks()
            .iter()
            .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
            .ok_or("未找到音频轨道")?;

        let track_id = track.id;
        let sample_rate = track.codec_params.sample_rate.unwrap_or(44100);
        let channels = track.codec_params.channels.map(|c| c.count()).unwrap_or(2) as u16;

        let total_duration = track
            .codec_params
            .time_base
            .and_then(|tb| track.codec_params.n_frames.map(|n| tb.calc_time(n)))
            .map(|t| Duration::from_secs(t.seconds));

        let decoder = symphonia::default::get_codecs()
            .make(&track.codec_params, &DecoderOptions::default())
            .map_err(|e| e.to_string())?;

        Ok(Self {
            format_reader: probed.format,
            decoder,
            track_id,
            sample_rate,
            channels,
            total_duration,
            sample_buf: None,
            sample_buf_frames: 0,
            leftover: Vec::new(),
            eof: false,
        })
    }
}

impl BlockProducer for SymphoniaDecoder {
    fn produce(&mut self, max_samples: usize) -> Option<Vec<f32>> {
        if self.eof {
            return None;
        }

        // 先消费上次剩余的样本
        if !self.leftover.is_empty() {
            let take = self.leftover.len().min(max_samples);
            let out = self.leftover.drain(..take).collect::<Vec<_>>();
            return Some(out);
        }

        use symphonia::core::audio::SampleBuffer;

        loop {
            let packet = match self.format_reader.next_packet() {
                Ok(p) => p,
                Err(symphonia::core::errors::Error::ResetRequired) => {
                    self.decoder.reset();
                    continue;
                }
                Err(symphonia::core::errors::Error::IoError(ref e))
                    if e.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    self.eof = true;
                    return None;
                }
                Err(_) => {
                    self.eof = true;
                    return None;
                }
            };

            let decoded = match self.decoder.decode(&packet) {
                Ok(d) => d,
                Err(_) => continue,
            };

            let frames = decoded.frames();
            if frames == 0 {
                continue;
            }

            let spec = *decoded.spec();
            if self.sample_buf.is_none() || self.sample_buf_frames < frames {
                self.sample_buf = Some(SampleBuffer::<f32>::new(frames as u64, spec));
                self.sample_buf_frames = frames;
            }

            if let Some(ref mut buf) = self.sample_buf {
                buf.copy_interleaved_ref(decoded);
                let samples = buf.samples().to_vec();
                if samples.len() > max_samples {
                    self.leftover = samples[max_samples..].to_vec();
                    return Some(samples[..max_samples].to_vec());
                }
                return Some(samples);
            }
        }
    }

    fn try_seek(&mut self, pos: Duration) -> Result<(), String> {
        use symphonia::core::formats::{SeekMode, SeekTo};
        use symphonia::core::units::Time;

        let seek_to = SeekTo::Time {
            time: Time::new(pos.as_secs(), 0.0),
            track_id: Some(self.track_id),
        };

        self.format_reader
            .seek(SeekMode::Accurate, seek_to)
            .map_err(|e| e.to_string())?;

        self.decoder.reset();
        self.leftover.clear();
        self.eof = false;
        Ok(())
    }
}

// =========================================================================
// 进度跟踪
// =========================================================================

struct ExclusiveProgress {
    samples_played: AtomicU64,
    sample_rate: AtomicU32,
    channels: AtomicU32,
    /// 源总时长（毫秒），供 Flutter 侧在 DSP 管线播放时更新进度条。
    duration_ms: AtomicU64,
}

impl ExclusiveProgress {
    fn new() -> Self {
        Self {
            samples_played: AtomicU64::new(0),
            sample_rate: AtomicU32::new(0),
            channels: AtomicU32::new(0),
            duration_ms: AtomicU64::new(0),
        }
    }
}

// =========================================================================
// 运行时命令
// =========================================================================

enum ExclusiveCommand {
    Seek { time_secs: f64, is_playing: bool },
    Stop,
    Pause,
    Resume,
    SetVolume(f32),
    SetEqualizer(EqualizerSettings),
    SetSoundEffect(SoundEffectSettings),
}

// =========================================================================
// 独占播放控制器
// =========================================================================

struct AndroidExclusivePlayback {
    tx: Sender<ExclusiveCommand>,
    join_handle: Option<thread::JoinHandle<()>>,
    progress: Arc<ExclusiveProgress>,
    device_name: String,
    /// 工作线程是否仍在运行（true=在播放循环内；false=播放结束或异常退出，
    /// 供 Flutter 侧检测断流并自动回退）。
    running: Arc<AtomicBool>,
    /// 工作线程退出原因（供 Flutter 侧日志诊断；空=正常 Stop 或曲终 EOF）。
    last_error: Arc<Mutex<Option<String>>>,
}

impl Drop for AndroidExclusivePlayback {
    fn drop(&mut self) {
        let _ = self.tx.send(ExclusiveCommand::Stop);
        if let Some(handle) = self.join_handle.take() {
            let _ = handle.join();
        }
    }
}

// =========================================================================
// 全局实例
// =========================================================================

static INSTANCE: OnceLock<Mutex<Option<AndroidExclusivePlayback>>> = OnceLock::new();

fn instance() -> &'static Mutex<Option<AndroidExclusivePlayback>> {
    INSTANCE.get_or_init(|| Mutex::new(None))
}

// =========================================================================
// 公共 API
// =========================================================================

pub fn start_exclusive_playback(
    request: super::ExclusivePlayRequest,
) -> Result<String, String> {
    // 先停止已有实例
    stop_exclusive_playback();

    let progress = Arc::new(ExclusiveProgress::new());
    let (tx, rx) = mpsc::channel::<ExclusiveCommand>();
    let (init_tx, init_rx) = mpsc::sync_channel::<Result<(String, u32, u16), String>>(1);
    let progress_clone = progress.clone();
    let running = Arc::new(AtomicBool::new(true));
    let running_clone = running.clone();
    let last_error: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let last_error_clone = last_error.clone();

    // 共享模式标记先取出：request 即将整体 move 进播放线程。
    let shared_mode = request.shared_mode;
    // 流缓存直读路径：播放线程需等最小缓冲 + 探测 + 初始 seek 追下载进度，
    // 放宽初始化等待窗口；超时仍由调用方回退 ExoPlayer。
    let stream_cache = request.stream_cache_url.is_some();

    let handle = thread::Builder::new()
        .name("xy-aaudio-exclusive".to_string())
        .spawn(move || {
            run_exclusive_playback(
                request,
                rx,
                init_tx,
                progress_clone,
                running_clone,
                last_error_clone,
            );
        })
        .map_err(|e| e.to_string())?;

    // 等待初始化结果。流缓存直读路径（在线直读）含最小缓冲等待与初始
    // seek 追下载，放宽到 15s；共享模式（本地文件）6s；独占模式 3s；
    // 超时由调用方回退 ExoPlayer。
    let init_wait = if stream_cache {
        Duration::from_secs(15)
    } else if shared_mode {
        Duration::from_secs(6)
    } else {
        Duration::from_secs(3)
    };
    let device_name = match init_rx.recv_timeout(init_wait) {
        Ok(Ok((name, sr, ch))) => {
            progress.sample_rate.store(sr, Ordering::Relaxed);
            progress.channels.store(ch as u32, Ordering::Relaxed);
            name
        }
        Ok(Err(e)) => {
            let _ = handle.join();
            return Err(e);
        }
        Err(_) => {
            let _ = handle.join();
            return Err("AAudio 管线初始化超时".to_string());
        }
    };

    let playback = AndroidExclusivePlayback {
        tx,
        join_handle: Some(handle),
        progress,
        device_name: device_name.clone(),
        running,
        last_error,
    };

    let mut guard = instance().lock().map_err(|e| e.to_string())?;
    *guard = Some(playback);

    Ok(device_name)
}

pub fn stop_exclusive_playback() {
    if let Ok(mut guard) = instance().lock() {
        if let Some(mut playback) = guard.take() {
            let _ = playback.tx.send(ExclusiveCommand::Stop);
            // join_handle 是 Option<JoinHandle>，用 take() 取出避免从
            // 实现了 Drop 的 AndroidExclusivePlayback 中部分 move 字段。
            if let Some(handle) = playback.join_handle.take() {
                let _ = handle.join();
            }
        }
    }
}

pub fn seek_exclusive(time_secs: f64, is_playing: bool) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::Seek {
                time_secs,
                is_playing,
            });
        }
    }
}

pub fn set_exclusive_volume(volume: f32) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::SetVolume(volume));
        }
    }
}

pub fn set_exclusive_equalizer(settings_json: &str) -> Result<(), String> {
    let settings: EqualizerSettings = if settings_json.is_empty() {
        EqualizerSettings::default()
    } else {
        serde_json::from_str(settings_json).map_err(|e| e.to_string())?
    };
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::SetEqualizer(settings));
        }
    }
    Ok(())
}

pub fn set_exclusive_sound_effect(settings_json: &str) -> Result<(), String> {
    let settings: SoundEffectSettings = if settings_json.is_empty() {
        SoundEffectSettings::default()
    } else {
        serde_json::from_str(settings_json).map_err(|e| e.to_string())?
    };
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::SetSoundEffect(settings));
        }
    }
    Ok(())
}

pub fn is_exclusive_active() -> bool {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            // 反映工作线程真实运行态：USB DAC 拔出、播放结束或异常退出后为
            // false，供 Flutter 检测断流并自动回退普通播放。
            return playback.running.load(Ordering::Relaxed);
        }
    }
    false
}

/// 暂停独占播放（保持进度，等待 resume 恢复）。
pub fn pause_exclusive() {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::Pause);
        }
    }
}

/// 从暂停恢复独占播放。
pub fn resume_exclusive() {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::Resume);
        }
    }
}

/// 查询当前独占播放输出设备/格式信息（JSON），用于前端展示与进度驱动。
/// `active` 反映工作线程真实运行态；`durationSecs` 供 Flutter 侧更新进度条。
pub fn get_exclusive_device_info() -> String {
    let (active, device_name, sample_rate, channels, duration_ms, last_error) =
        if let Ok(guard) = instance().lock() {
            if let Some(playback) = guard.as_ref() {
                (
                    playback.running.load(Ordering::Relaxed),
                    playback.device_name.clone(),
                    playback.progress.sample_rate.load(Ordering::Relaxed),
                    playback.progress.channels.load(Ordering::Relaxed) as u16,
                    playback.progress.duration_ms.load(Ordering::Relaxed),
                    playback
                        .last_error
                        .lock()
                        .ok()
                        .and_then(|e| e.clone())
                        .unwrap_or_default(),
                )
            } else {
                (false, String::new(), 0, 0, 0, String::new())
            }
        } else {
            (false, String::new(), 0, 0, 0, String::new())
        };
    serde_json::json!({
        "active": active,
        "deviceName": device_name,
        "sampleRate": sample_rate,
        "channels": channels,
        "durationSecs": duration_ms as f64 / 1000.0,
        "lastError": last_error,
    })
    .to_string()
}

pub fn get_exclusive_position_secs() -> f64 {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let samples = playback.progress.samples_played.load(Ordering::Relaxed);
            let rate = playback.progress.sample_rate.load(Ordering::Relaxed);
            let channels = playback.progress.channels.load(Ordering::Relaxed).max(1);
            if rate > 0 {
                return samples as f64 / (rate as f64 * channels as f64);
            }
        }
    }
    0.0
}

pub fn get_exclusive_sample_rate() -> u32 {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            return playback.progress.sample_rate.load(Ordering::Relaxed);
        }
    }
    0
}

pub fn get_exclusive_channels() -> u16 {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            return playback.progress.channels.load(Ordering::Relaxed) as u16;
        }
    }
    0
}

// =========================================================================
// 工作线程
// =========================================================================

fn run_exclusive_playback(
    request: super::ExclusivePlayRequest,
    cmd_rx: Receiver<ExclusiveCommand>,
    init_tx: SyncSender<Result<(String, u32, u16), String>>,
    progress: Arc<ExclusiveProgress>,
    running: Arc<AtomicBool>,
    last_error: Arc<Mutex<Option<String>>>,
) {
    // 1. 加载 AAudio 库
    let lib = match AAudioLib::load() {
        Some(l) => l,
        None => {
            let _ = init_tx.send(Err(
                "无法加载 libaaudio.so（需要 Android API 26+）".to_string()
            ));
            return;
        }
    };

    // 1.5 流缓存直读（在线歌曲）：复用/启动 start_streaming_download 下载线程
    //（与 Dart 侧预热按 URL 命中同一条目，维持单上游连接），等最小缓冲就绪
    // 后交解码器探测；超时/失败交上层回退 ExoPlayer。
    let mut cache_state: Option<crate::player::stream_cache::StreamingTempFileState> = None;
    let stream_reader: Option<Box<dyn crate::player::stream_cache::ReadSeek + Send + Sync>> =
        match request.stream_cache_url.as_deref() {
            None => None,
            Some(url) => {
                let state = match crate::player::stream_cache::start_streaming_download(
                    url,
                    request.stream_cache_headers.as_ref(),
                    None,
                    None,
                ) {
                    Ok(s) => s,
                    Err(e) => {
                        let _ = init_tx.send(Err(format!("流缓存启动失败: {e}")));
                        return;
                    }
                };
                cache_state = Some(state.clone());
                // 等待最小缓冲就绪；预热命中时近乎立即通过。
                let deadline = std::time::Instant::now() + Duration::from_secs(8);
                while !crate::player::stream_cache::is_buffer_ready(&state) {
                    if let Some(err) = state.download_error() {
                        let _ = init_tx.send(Err(format!("流缓存下载失败: {err}")));
                        return;
                    }
                    if !running.load(Ordering::Relaxed) || std::time::Instant::now() >= deadline {
                        let _ = init_tx.send(Err("流缓存缓冲超时".to_string()));
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(20));
                }
                match state.new_reader_with_decryption() {
                    Ok(r) => Some(r),
                    Err(e) => {
                        let _ = init_tx.send(Err(format!("流缓存读取失败: {e}")));
                        return;
                    }
                }
            }
        };

    // 2. 打开 symphonia 解码器（流缓存 Reader / 本地文件）
    let decoder = match SymphoniaDecoder::open(
        request.stream_cache_url.as_deref().unwrap_or(&request.path),
        stream_reader,
        cache_state.as_ref(),
    ) {
        Ok(d) => d,
        Err(e) => {
            let _ = init_tx.send(Err(format!("打开音频文件失败: {e}")));
            return;
        }
    };

    let source_sample_rate = decoder.sample_rate;
    let source_channels = decoder.channels;
    let total_duration = decoder.total_duration;

    // 共享模式走系统混音器：DSP 链固定按立体声处理。>2 声道流（伪 6ch 全景声）
    // 混音器不做声道映射会直接破音需下混（ITU BS.775）；单声道流若按 1ch 请求
    // 共享流，系统混音器会重协商成 2ch 导致建流失败，故统一上混为立体声。
    // 独占模式仍按源声道直出。
    let playback_channels: u16 = if request.shared_mode {
        2
    } else {
        source_channels
    };
    let downmix_active = playback_channels != source_channels;

    // 3. 创建 BufferedSource（后台预读取）
    let mut buffered =
        BufferedSource::new(decoder, source_sample_rate, source_channels, total_duration);

    // 4. 跳到起始位置
    if request.start_time_secs > 0.0 {
        if let Err(e) = buffered.try_seek(Duration::from_secs_f64(request.start_time_secs)) {
            let _ = init_tx.send(Err(format!("跳转失败: {e}")));
            return;
        }
    }

    // 5. 装配 DSP 链（downmix 后按输出声道数处理）
    let (mut normalizer, _normalizer_handle) = VolumeNormalizer::new(
        request.volume_balance_gain,
        source_sample_rate,
        playback_channels,
        100,
    );

    let eq_settings: EqualizerSettings = if request.equalizer_settings_json.is_empty() {
        EqualizerSettings::default()
    } else {
        serde_json::from_str(&request.equalizer_settings_json).unwrap_or_default()
    };
    let eq_handle = Arc::new(EqualizerHandle::new(eq_settings));
    let mut equalizer = Equalizer::new(source_sample_rate, playback_channels, eq_handle.clone());

    let mut sound_effect = SoundEffectBlockProcessor::new(source_sample_rate, playback_channels);
    if !request.sound_effect_settings_json.is_empty() {
        if let Ok(se_settings) =
            serde_json::from_str::<SoundEffectSettings>(&request.sound_effect_settings_json)
        {
            sound_effect.set_settings(se_settings);
        }
    }

    let user_volume = Arc::new(AtomicU32::new(request.volume.to_bits()));
    let is_paused = Arc::new(AtomicBool::new(!request.is_playing));

    // 6. 创建 AAudio 流。共享模式：SHARED 共享流走系统混音器（全效果链生效），
    // 输出到系统默认设备（device_id 被忽略）；独占模式照旧按源声道协商。
    let (stream, device_format, stream_sample_rate, stream_channels) = match create_aaudio_stream(
        &lib,
        if request.shared_mode {
            -1
        } else {
            request.device_id
        },
        source_sample_rate,
        playback_channels,
        request.shared_mode,
    ) {
        Ok(result) => result,
        Err(e) => {
            let _ = init_tx.send(Err(e));
            return;
        }
    };

    // 流实际采样率被系统重协商时（共享流常见：混音器原生率 48000），在写出
    // 前做一次重采样对齐，否则整段音频会变速走调。进度仍按重采样前的样本数
    // 在源采样率域累计（见下方 samples_played），seek/曲终判定不受影响。
    let mut resampler = if stream_sample_rate != source_sample_rate {
        Some(LinearResampler::new(
            playback_channels as usize,
            source_sample_rate as f64 / stream_sample_rate as f64,
        ))
    } else {
        None
    };

    // 共享流声道数被系统重协商（如请求 2ch 实得 1/6ch）时，写出前做声道
    // 映射，使数据布局与流声道数一致；不再因失配丢流回退。
    let channel_remap_active = stream_channels != playback_channels;

    let effective_rate = sound_effect.effective_sample_rate();
    progress
        .sample_rate
        .store(effective_rate, Ordering::Relaxed);
    progress
        .channels
        .store(stream_channels as u32, Ordering::Relaxed);
    progress.duration_ms.store(
        total_duration.map(|d| d.as_millis() as u64).unwrap_or(0),
        Ordering::Relaxed,
    );
    progress.samples_played.store(
        (request.start_time_secs * source_sample_rate as f64 * playback_channels as f64) as u64,
        Ordering::Relaxed,
    );

    let visualizer = global_visualizer();
    visualizer.reset();

    // 7. 启动流
    let start_result = unsafe { (lib.stream_request_start)(stream) };
    if start_result != AAUDIO_OK {
        let msg = unsafe { lib.result_text(start_result) };
        let _ = init_tx.send(Err(format!("AAudio 启动失败: {msg}")));
        unsafe { (lib.stream_close)(stream) };
        return;
    }

    // 8. 通知初始化成功
    let device_name = if request.shared_mode {
        format!(
            "系统混音器 ({}Hz, {}ch shared){}",
            stream_sample_rate,
            stream_channels,
            if downmix_active {
                format!(" {}ch→2ch 下混", source_channels)
            } else {
                String::new()
            }
        )
    } else {
        format!(
            "USB DAC ({}Hz, {}ch, {}bit exclusive)",
            stream_sample_rate,
            stream_channels,
            match device_format {
                DeviceFormat::Float32 => 32,
                DeviceFormat::Int16 => 16,
            }
        )
    };
    let _ = init_tx.send(Ok((device_name, stream_sample_rate, stream_channels)));

    // 9. 轮询循环
    let timeout_ns: i64 = 20_000_000; // 20ms
    let bytes_per_sample = device_format.bytes_per_sample();

    loop {
        // 检查命令。播放中非阻塞轮询；暂停中阻塞等待命令到达（最长 500ms
        // 醒一次检查断流）。替代暂停期固定 10ms sleep 轮询——后者在长时间
        // 暂停（车机/睡眠场景）下以 100 次/秒的频率唤醒线程，阻止系统
        // 深度休眠，是持续耗电发热的来源之一。
        let pending_cmd = if is_paused.load(Ordering::Relaxed) {
            // 暂停期间流被系统断开（车机蓝牙回收/USB 拔出）时尽早退出
            // 线程并释放流，避免恢复播放时才第一次触碰死流。
            if stream_disconnected(&lib, stream) {
                note_disconnect(&last_error, "paused");
                break;
            }
            match cmd_rx.recv_timeout(Duration::from_millis(500)) {
                Ok(cmd) => Some(cmd),
                Err(mpsc::RecvTimeoutError::Timeout) => None,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        } else {
            match cmd_rx.try_recv() {
                Ok(cmd) => Some(cmd),
                Err(mpsc::TryRecvError::Empty) => None,
                Err(mpsc::TryRecvError::Disconnected) => break,
            }
        };

        match pending_cmd {
            Some(ExclusiveCommand::Stop) => break,
            None => {}
            Some(ExclusiveCommand::Seek {
                time_secs,
                is_playing,
            }) => {
                if stream_disconnected(&lib, stream) {
                    note_disconnect(&last_error, "seek");
                    break;
                }
                let _ = unsafe { (lib.stream_request_pause)(stream) };
                if let Err(e) = buffered.try_seek(Duration::from_secs_f64(time_secs)) {
                    let _ = e;
                }
                normalizer.reset();
                equalizer.reset();
                sound_effect.reset();
                progress.samples_played.store(
                    (time_secs * source_sample_rate as f64 * playback_channels as f64) as u64,
                    Ordering::Relaxed,
                );
                visualizer.reset();
                is_paused.store(!is_playing, Ordering::Relaxed);
                if is_playing {
                    let _ = unsafe { (lib.stream_request_start)(stream) };
                }
            }
            Some(ExclusiveCommand::Pause) => {
                if stream_disconnected(&lib, stream) {
                    note_disconnect(&last_error, "pause");
                    break;
                }
                let _ = unsafe { (lib.stream_request_pause)(stream) };
                is_paused.store(true, Ordering::Relaxed);
            }
            Some(ExclusiveCommand::Resume) => {
                // 车机/蓝牙在流暂停期间可能已将其断开（DISCONNECTED）。
                // 对已断开的流调用 requestStart，部分车机 ROM 的音频
                // HAL 会直接 native crash（表现为暂停后重新播放闪退）。
                // 断流时不碰死流，直接退出线程，由 Dart 看门狗按当前
                // 进度重建管线（新建流）。
                if stream_disconnected(&lib, stream) {
                    note_disconnect(&last_error, "resume");
                    break;
                }
                is_paused.store(false, Ordering::Relaxed);
                let _ = unsafe { (lib.stream_request_start)(stream) };
            }
            Some(ExclusiveCommand::SetVolume(vol)) => {
                user_volume.store(vol.to_bits(), Ordering::Relaxed);
            }
            Some(ExclusiveCommand::SetEqualizer(settings)) => {
                eq_handle.set_settings(settings);
            }
            Some(ExclusiveCommand::SetSoundEffect(settings)) => {
                sound_effect.set_settings(settings);
            }
        }

        // 暂停中不写入数据，回到循环顶部阻塞等待命令（断流检测见顶部）。
        if is_paused.load(Ordering::Relaxed) {
            continue;
        }

        // 检查可写空间
        let available = unsafe { (lib.stream_get_available_frames)(stream) };
        if available <= 0 {
            // 负值是错误码：流可能已被系统断开，退出等待重建，
            // 避免对死流继续写入。
            if available < 0 && stream_disconnected(&lib, stream) {
                note_disconnect(&last_error, "write");
                break;
            }
            thread::sleep(Duration::from_millis(5));
            continue;
        }

        // 读取一块样本；共享模式多声道先在样本层下混为立体声
        let raw_block = match buffered.next_block() {
            Some(block) => block,
            None => {
                // EOF
                break;
            }
        };
        let block = if downmix_active {
            crate::player::channel_downmix::downmix_block(&raw_block, source_channels)
        } else {
            raw_block
        };

        // DSP 链处理
        let normalized = normalizer.process_block(&block);
        let eq_applied = equalizer.process_block(&normalized);
        let effected = sound_effect.process_block(eq_applied);
        // 进度/曲终按源采样率域的样本数累计，重采样只改变写入的字节数。
        let produced = effected.len() as u64;
        let effected = match resampler.as_mut() {
            Some(rs) => rs.process(&effected),
            None => effected,
        };
        let effected = if channel_remap_active {
            map_channels(&effected, playback_channels, stream_channels)
        } else {
            effected
        };
        if effected.is_empty() {
            continue;
        }

        // 应用用户音量 + clip guard + 格式转换
        let vol = f32::from_bits(user_volume.load(Ordering::Relaxed));
        let mut byte_buf: Vec<u8> = Vec::with_capacity(effected.len() * bytes_per_sample);

        let mut chan_sum = 0.0f32;
        let mut chan_count = 0u32;

        for &sample in &effected {
            let amplified = sample * vol;
            push_sample_bytes(&mut byte_buf, amplified, device_format);

            chan_sum += amplified;
            chan_count += 1;
            if chan_count >= stream_channels as u32 {
                visualizer.push_sample(chan_sum / chan_count as f32);
                chan_sum = 0.0;
                chan_count = 0;
            }
        }

        progress
            .samples_played
            .fetch_add(produced, Ordering::Relaxed);

        // 写入 AAudio
        let frames_written = unsafe {
            (lib.stream_write)(
                stream,
                byte_buf.as_ptr() as *const std::os::raw::c_void,
                (effected.len() / stream_channels as usize) as i32,
                timeout_ns,
            )
        };

        if frames_written < 0 {
            // 写入错误，可能是设备断开
            if let Ok(mut e) = last_error.lock() {
                *e = Some(format!(
                    "stream_write错误({} 已播{}样本)",
                    unsafe { lib.result_text(frames_written as i32) },
                    progress.samples_played.load(Ordering::Relaxed)
                ));
            }
            break;
        }

        // 如果写入的帧数少于请求的帧数，等待一下
        if frames_written < (effected.len() / stream_channels as usize) as i64 {
            thread::sleep(Duration::from_millis(5));
        }
    }

    // 10. 清理。running=false 供 Flutter 检测断流（设备断开/曲终）自动回退；
    // 仅在工作线程真正退出时置位。已断开的流跳过 requestStop（部分
    // 车机 ROM 对死流的请求操作有崩溃风险），close 始终执行以释放资源。
    running.store(false, Ordering::Relaxed);
    unsafe {
        if !stream_disconnected(&lib, stream) {
            (lib.stream_request_stop)(stream);
        }
        (lib.stream_close)(stream);
    }
}

/// 查询流是否已被系统断开。仅读状态、不触碰流的其他接口，
/// 对健康流无副作用；对已断开的流，调用方应立即停止一切操作。
fn stream_disconnected(lib: &AAudioLib, stream: *mut AAudioStream) -> bool {
    unsafe { (lib.stream_get_state)(stream) == AAUDIO_STREAM_STATE_DISCONNECTED }
}

/// 记录断流原因到 last_error（供设备信息上报与问题排查）。
fn note_disconnect(
    last_error: &Arc<Mutex<Option<String>>>,
    stage: &str,
) {
    if let Ok(mut e) = last_error.lock() {
        *e = Some(format!("流已断开({stage})，等待重建"));
    }
}

/// 把交错样本块从 `from` 声道映射到 `to` 声道（用于共享流声道数被系统
/// 重协商后仍能正确写出，避免丢流回退）。规则：降到 1ch 取各声道均值；
/// 升到多声道时，单声道复制到每一路，其余按取模补足。
fn map_channels(samples: &[f32], from: u16, to: u16) -> Vec<f32> {
    let fch = from as usize;
    let tch = to as usize;
    if fch == 0 || tch == 0 || fch == tch {
        return samples.to_vec();
    }
    let frames = samples.len() / fch;
    let mut out = Vec::with_capacity(frames * tch);
    for frame in samples.chunks(fch).take(frames) {
        if tch == 1 {
            let sum: f32 = frame.iter().sum();
            out.push(sum / fch as f32);
        } else if fch == 1 {
            let s = frame[0];
            for _ in 0..tch {
                out.push(s);
            }
        } else {
            for i in 0..tch {
                out.push(frame[i % fch]);
            }
        }
    }
    out
}

/// 采样率对齐用的线性插值重采样器（交错多声道，跨块保持相位连续）。
///
/// AAudio 文档明确共享流的实际采样率可能与请求值不同（由系统混音器决定，
/// 常见为 48000）。本管线按源采样率产出样本，若直接写入会整体变速走调；
/// 用 `in_rate / out_rate` 的帧步进做线性插值，把样本转换到流采样率域。
/// 线性插值与管线内变调处理器一致，不引入额外依赖。
struct LinearResampler {
    channels: usize,
    /// 每个输出帧在输入域推进的帧数 = in_rate / out_rate。
    step: f64,
    /// 下一个输出帧在输入域中的位置（帧为单位，含小数）。
    pos: f64,
    /// 尚未消费完的输入样本（交错），用于跨块插值。
    buf: Vec<f32>,
}

impl LinearResampler {
    fn new(channels: usize, step: f64) -> Self {
        Self {
            channels: channels.max(1),
            step: step.max(1e-6),
            pos: 0.0,
            buf: Vec::new(),
        }
    }

    /// 追加一块输入并产出尽可能多的输出帧；不足两帧的尾巴留到下一块。
    fn process(&mut self, input: &[f32]) -> Vec<f32> {
        let ch = self.channels;
        self.buf.extend_from_slice(input);
        let frames = self.buf.len() / ch;
        if frames < 2 {
            return Vec::new();
        }
        let mut out = Vec::with_capacity((((frames as f64 - 1.0) / self.step) as usize + 1) * ch);
        loop {
            let i0 = self.pos.floor() as usize;
            // 插值需要第 i0 与第 i0+1 帧同时存在。
            if i0 + 1 >= frames {
                break;
            }
            let frac = (self.pos - i0 as f64) as f32;
            let a = i0 * ch;
            let b = a + ch;
            for c in 0..ch {
                out.push(self.buf[a + c] * (1.0 - frac) + self.buf[b + c] * frac);
            }
            self.pos += self.step;
        }
        // 已完全消费的帧回收，pos 回退到剩余缓冲的起点。
        let consumed = self.pos.floor() as usize;
        if consumed > 0 {
            self.buf.drain(0..consumed * ch);
            self.pos -= consumed as f64;
        }
        out
    }
}

/// 协商创建 AAudio 流。独占模式先试 Float32 再试 Int16；
/// 共享模式走系统混音器（SHARED），系统可能重协商格式，按实际格式回读。
fn create_aaudio_stream(
    lib: &AAudioLib,
    device_id: i32,
    sample_rate: u32,
    channels: u16,
    shared: bool,
) -> Result<(*mut AAudioStream, DeviceFormat, u32, u16), String> {
    let formats = [DeviceFormat::Float32, DeviceFormat::Int16];

    for &fmt in &formats {
        let stream =
            unsafe { try_open_stream(lib, device_id, sample_rate, channels, fmt, shared) };
        match stream {
            Ok(s) => {
                let actual_rate = unsafe { (lib.stream_get_sample_rate)(s) } as u32;
                let actual_channels = unsafe { (lib.stream_get_channel_count)(s) } as u16;
                // 共享模式下系统可能重协商格式，按实际格式回读供字节转换使用。
                let actual_fmt = if shared {
                    device_format_of(unsafe { (lib.stream_get_format)(s) })
                } else {
                    Some(fmt)
                };
                let actual_fmt = match actual_fmt {
                    Some(f) => f,
                    None => {
                        unsafe { (lib.stream_close)(s) };
                        continue;
                    }
                };
                // 共享流的采样率与声道数都可能被系统混音器重协商（原生率
                // 常见 48000、声道常见 2）。二者都不再放弃流：采样率交由
                // 调用方按实际流率重采样对齐（LinearResampler），声道数交由
                // 调用方按实际流声道数做上/下混映射（map_channels）。若在此
                // 因一次失配就关闭流重试，全部格式失败后会回退普通输出，
                // 整个高级音效链被静默禁用（"无法创建 AAudio 共享流"）。
                return Ok((s, actual_fmt, actual_rate, actual_channels));
            }
            Err(_e) => continue,
        }
    }

    Err(if shared {
        "无法创建 AAudio 共享流（需要 Android API 26+，或重协商后的声道数与请求不符）".to_string()
    } else {
        "无法创建 AAudio 独占流（设备不支持独占模式或已被占用）".to_string()
    })
}

unsafe fn try_open_stream(
    lib: &AAudioLib,
    device_id: i32,
    sample_rate: u32,
    channels: u16,
    fmt: DeviceFormat,
    shared: bool,
) -> Result<*mut AAudioStream, String> {
    let mut builder: *mut AAudioStreamBuilder = std::ptr::null_mut();
    let result = (lib.create_stream_builder)(&mut builder);
    if result != AAUDIO_OK || builder.is_null() {
        return Err(lib.result_text(result));
    }

    (lib.builder_set_direction)(builder, AAUDIO_DIRECTION_OUTPUT);
    if device_id >= 0 {
        (lib.builder_set_device_id)(builder, device_id);
    }
    (lib.builder_set_sample_rate)(builder, sample_rate as i32);
    (lib.builder_set_channel_count)(builder, channels as i32);
    (lib.builder_set_format)(builder, fmt.aaudio_format());
    if shared {
        // 共享模式走系统混音器：不设性能档（默认 NONE，省电）。
        (lib.builder_set_sharing_mode)(builder, AAUDIO_SHARING_MODE_SHARED);
    } else {
        (lib.builder_set_sharing_mode)(builder, AAUDIO_SHARING_MODE_EXCLUSIVE);
        (lib.builder_set_performance_mode)(builder, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
    }
    (lib.builder_set_buffer_capacity)(builder, 4096);

    let mut stream: *mut AAudioStream = std::ptr::null_mut();
    let result = (lib.builder_open_stream)(builder, &mut stream);
    (lib.builder_delete)(builder);

    if result != AAUDIO_OK || stream.is_null() {
        return Err(lib.result_text(result));
    }

    // 验证实际格式（共享模式允许系统重协商，由调用方按实际格式回读）
    let actual_format = (lib.stream_get_format)(stream);
    if !shared && actual_format != fmt.aaudio_format() {
        (lib.stream_close)(stream);
        return Err("设备拒绝了请求的格式".to_string());
    }

    Ok(stream)
}

/// AAudio 格式常量 → 管线字节转换格式；未知格式返回 None。
fn device_format_of(format: i32) -> Option<DeviceFormat> {
    match format {
        AAUDIO_FORMAT_PCM_FLOAT => Some(DeviceFormat::Float32),
        AAUDIO_FORMAT_PCM_I16 => Some(DeviceFormat::Int16),
        _ => None,
    }
}

// =========================================================================
// 测试
// =========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_sample_bytes_float32_roundtrip() {
        let mut buf = Vec::new();
        push_sample_bytes(&mut buf, 0.5, DeviceFormat::Float32);
        assert_eq!(buf.len(), 4);
        let val = f32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]);
        assert!((val - 0.5).abs() < 1e-6);
    }

    #[test]
    fn push_sample_bytes_int16_range() {
        let mut buf = Vec::new();
        push_sample_bytes(&mut buf, 1.0, DeviceFormat::Int16);
        let val = i16::from_le_bytes([buf[0], buf[1]]);
        assert_eq!(val, 32767);

        let mut buf = Vec::new();
        push_sample_bytes(&mut buf, -1.0, DeviceFormat::Int16);
        let val = i16::from_le_bytes([buf[0], buf[1]]);
        assert_eq!(val, -32767);
    }

    #[test]
    fn push_sample_bytes_clamps_overflow() {
        let mut buf = Vec::new();
        push_sample_bytes(&mut buf, 2.0, DeviceFormat::Float32);
        let val = f32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]);
        assert!((val - 1.0).abs() < 1e-6);
    }

    #[test]
    fn device_format_bytes_per_sample() {
        assert_eq!(DeviceFormat::Float32.bytes_per_sample(), 4);
        assert_eq!(DeviceFormat::Int16.bytes_per_sample(), 2);
    }

    #[test]
    fn resampler_44100_to_48000_frame_ratio() {
        // 44100Hz 源 → 48000Hz 流：输出帧数应为输入的 48000/44100 倍。
        let mut rs = LinearResampler::new(2, 44100.0 / 48000.0);
        let input = vec![0.25f32; 2 * 44100];
        let out = rs.process(&input);
        let frames = out.len() / 2;
        assert!(
            frames.abs_diff(48000) <= 2,
            "帧数不符: got {frames}, expect ~48000"
        );
    }

    #[test]
    fn resampler_is_continuous_across_blocks() {
        // 直流信号跨多块重采样后应保持常量，说明块边界插值状态连续。
        let mut rs = LinearResampler::new(2, 44100.0 / 48000.0);
        let block = vec![0.5f32; 2 * 512];
        let mut out = Vec::new();
        for _ in 0..10 {
            out.extend_from_slice(&rs.process(&block));
        }
        assert!(!out.is_empty());
        for (i, s) in out.iter().enumerate() {
            assert!((s - 0.5).abs() < 1e-4, "样本 {i} 失真: {s}");
        }
    }
}
