//! OpenSL ES 独占播放后端（Android API 21+ 降级路径）。
//!
//! 当 AAudio 无法加载（API < 26 / 库损坏）时，由 android_aaudio 工作线程
//! 降级到本模块，继续走同一条 DSP 共享管线（响度归一化 → EQ → 空间音效 →
//! anime 音效引擎），让低版本设备也能听到实际音效而不是回退到无效果的原生输出。
//!
//! 实现方式：
//! - 通过 `libc::dlopen("libOpenSLES.so")` 动态加载 Android NDK 系统库
//!   （OpenSL ES 1.1，API 9+ 即存在，本项目 minSdk≥21 满足）；
//! - 手写 SLES/OpenSLES.h 与 OpenSLES_Android.h 的函数表/常量绑定，
//!   不引入新的 C 构建依赖（build.rs / CMake 无需改动）；
//! - 播放路径：`SL_ANDROID_BUFFERQUEUE` 双缓冲回调 + OutputMix 直出
//!   系统默认输出设备；PCM16 交错、源采样率（协商失败回退 48k/44.1k）；
//! - 命令通道（Seek/Pause/Resume/Stop/音量/EQ/音效）与错误上报
//!   （init_tx）与 android_aaudio 保持一致，Dart 侧 FFI 无感知。

#![allow(dead_code)]

use crate::player::buffered_source::{BlockProducer, BufferedSource};
use crate::player::equalizer::{Equalizer, EqualizerHandle, EqualizerSettings};
use crate::player::loudness::VolumeNormalizer;
use crate::player::sound_effect::{SoundEffectBlockProcessor, SoundEffectSettings};
use crate::player::types::{global_visualizer, SharedVisualizer};
use std::collections::VecDeque;
use std::os::raw::c_void;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use super::android_aaudio::{
    push_sample_bytes, AnimeFxEngine, DeviceFormat, ExclusiveCommand, ExclusiveProgress,
    LinearResampler, SymphoniaDecoder,
};

// =========================================================================
// OpenSL ES 常量（SLES/OpenSLES.h、OpenSLES_Android.h）
// =========================================================================

const SL_BOOLEAN_FALSE: u32 = 0;
const SL_BOOLEAN_TRUE: u32 = 1;
const SL_RESULT_SUCCESS: u32 = 0;
const SL_OBJECT_STATE_REALIZED: u32 = 0x02;
const SL_PLAYSTATE_STOPPED: u32 = 0x01;
const SL_PLAYSTATE_PAUSED: u32 = 0x02;
const SL_PLAYSTATE_PLAYING: u32 = 0x03;
const SL_DATALOCATOR_ANDROIDBUFFERQUEUE: u32 = 0x800007BE;
const SL_DATALOCATOR_OUTPUTMIX: u32 = 0x04;
const SL_DATAFORMAT_PCM: u32 = 0x02;
const SL_PCMSAMPLEFORMAT_FIXED_16: u32 = 2;
const SL_BYTEORDER_LITTLEENDIAN: u32 = 0;
const SL_SPEAKER_FRONT_LEFT: u32 = 0x00000001;
const SL_SPEAKER_FRONT_RIGHT: u32 = 0x00000002;
const SL_SPEAKER_FRONT_CENTER: u32 = 0x00000004;

/// 单缓冲帧数（约 512/48000 ≈ 10.7ms，兼顾延迟与回调频率）。
const BUFFER_FRAMES: u32 = 512;
/// 双缓冲预填数量。
const PRIME_BUFFERS: usize = 2;
/// 待入队缓冲上限（防止 DSP 产速 > 回调消费速导致无界积压）。
const MAX_READY: usize = 8;

// =========================================================================
// OpenSL ES FFI 类型（句柄 = 指向 vtbl 指针的指针，与 C 头文件一致）
// =========================================================================

type SlObject = *mut *const SlObjectVtbl;
type SlEngine = *mut *const SlEngineVtbl;
type SlPlay = *mut *const SlPlayVtbl;
type SlBufferQueue = *mut *const SlBufferQueueVtbl;
type SlVolume = *mut *const SlVolumeVtbl;

type FnRealize = unsafe extern "C" fn(*mut c_void, u32) -> u32;
type FnGetState = unsafe extern "C" fn(*mut c_void, *mut u32) -> u32;
type FnGetInterface = unsafe extern "C" fn(*mut c_void, *const c_void, *mut *mut c_void) -> u32;
type FnDestroy = unsafe extern "C" fn(*mut c_void);

/// SLObjectItf_ 方法表（字段顺序必须与 OpenSLES.h 完全一致）。
#[repr(C)]
struct SlObjectVtbl {
    realize: FnRealize,
    resume: FnRealize,
    get_state: FnGetState,
    get_interface: FnGetInterface,
    register_callback: unsafe extern "C" fn(*mut c_void, *mut c_void, u32, u32),
    abort_async: unsafe extern "C" fn(*mut c_void),
    destroy: FnDestroy,
    set_priority: unsafe extern "C" fn(*mut c_void, i32, u32),
    get_priority: unsafe extern "C" fn(*mut c_void, *mut i32, *mut u32),
    set_loss_of_control_interfaces:
        unsafe extern "C" fn(*mut c_void, u32, *const *const c_void, u32),
}

type FnCreateAudioPlayer = unsafe extern "C" fn(
    *mut c_void,
    *mut *mut c_void,
    *const SlDataSource,
    *const SlDataSink,
    u32,
    *const *const c_void,
    *const u32,
) -> u32;
type FnCreateOutputMix = unsafe extern "C" fn(
    *mut c_void,
    *mut *mut c_void,
    u32,
    *const *const c_void,
    *const u32,
) -> u32;

/// SLEngineItf_ 方法表（CreateAudioPlayer / CreateOutputMix 位于第 3、5 位）。
#[repr(C)]
struct SlEngineVtbl {
    create_led_device: *mut c_void,
    create_vibra_device: *mut c_void,
    create_audio_player: FnCreateAudioPlayer,
    create_audio_recorder: *mut c_void,
    create_output_mix: FnCreateOutputMix,
    create_metadata_extractor: *mut c_void,
    create_extension_object: *mut c_void,
    query_num_supported_interfaces: *mut c_void,
    query_supported_interfaces: *mut c_void,
    query_num_supported_extensions: *mut c_void,
    query_supported_extension: *mut c_void,
    is_extension_supported: *mut c_void,
}

type FnSetPlayState = unsafe extern "C" fn(*mut c_void, u32) -> u32;

/// SLPlayItf_ 方法表。
#[repr(C)]
struct SlPlayVtbl {
    set_play_state: FnSetPlayState,
    get_play_state: unsafe extern "C" fn(*mut c_void, *mut u32) -> u32,
    get_duration: *mut c_void,
    get_position: *mut c_void,
    register_callback: *mut c_void,
    set_callback_events_mask: *mut c_void,
    get_callback_events_mask: *mut c_void,
    set_marker_position: *mut c_void,
    clear_marker_position: *mut c_void,
    get_marker_position: *mut c_void,
    set_position_update_period: *mut c_void,
    get_position_update_period: *mut c_void,
}

type FnBqEnqueue = unsafe extern "C" fn(*mut c_void, *const c_void, u32) -> u32;
type FnBqClear = unsafe extern "C" fn(*mut c_void) -> u32;
type FnBqGetState = unsafe extern "C" fn(*mut c_void, *mut SlBufferQueueState) -> u32;
type FnBqRegisterCallback = unsafe extern "C" fn(*mut c_void, SlBqCallback, *mut c_void) -> u32;
type SlBqCallback = extern "C" fn(*mut c_void, *mut c_void);

/// SLAndroidSimpleBufferQueueItf_ 方法表（4 个方法全量）。
#[repr(C)]
struct SlBufferQueueVtbl {
    enqueue: FnBqEnqueue,
    clear: FnBqClear,
    get_state: FnBqGetState,
    register_callback: FnBqRegisterCallback,
}

#[repr(C)]
struct SlBufferQueueState {
    count: u32,
    index: u32,
}

/// SLVolumeItf_ 方法表。
#[repr(C)]
struct SlVolumeVtbl {
    set_volume_level: unsafe extern "C" fn(*mut c_void, i16) -> u32,
    get_volume_level: *mut c_void,
    get_max_volume_level: *mut c_void,
    set_mute: *mut c_void,
    get_mute: *mut c_void,
    enable_stereo_position: *mut c_void,
    set_stereo_position: *mut c_void,
    get_stereo_position: *mut c_void,
}

// =========================================================================
// 数据结构（与 OpenSLES.h 布局一致）
// =========================================================================

#[repr(C)]
struct SlDataLocator_AndroidSimpleBufferQueue {
    locator_type: u32,
    num_buffers: u32,
}

#[repr(C)]
struct SlDataLocator_OutputMix {
    locator_type: u32,
    output_mix: *mut c_void,
}

#[repr(C)]
struct SlDataFormat_Pcm {
    format_type: u32,
    num_channels: u32,
    samples_per_sec: u32,
    bits_per_sample: u32,
    container_size: u32,
    channel_mask: u32,
    endianness: u32,
}

#[repr(C)]
struct SlDataSource {
    p_locator: *mut c_void,
    p_format: *mut c_void,
}

#[repr(C)]
struct SlDataSink {
    p_locator: *mut c_void,
    p_format: *mut c_void,
}

type FnSlCreateEngine = unsafe extern "C" fn(
    *mut *mut c_void,
    u32,
    *const c_void,
    u32,
    *const *const c_void,
    *const u32,
) -> u32;

// =========================================================================
// 动态加载的 OpenSL ES 库
// =========================================================================

struct OpenSlLib {
    _handle: *mut c_void,
    engine_iid: *const c_void,
    play_iid: *const c_void,
    bq_iid: *const c_void,
    volume_iid: *const c_void,
    create_engine: FnSlCreateEngine,
}

// 句柄/函数指针仅在本文件音频线程内使用（回调线程只经共享状态访问）。
unsafe impl Send for OpenSlLib {}

impl OpenSlLib {
    /// 动态加载 libOpenSLES.so 并解析接口 GUID 与入口。失败返回 None。
    fn load() -> Option<Self> {
        unsafe {
            let name = b"libOpenSLES.so\0".as_ptr();
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
                    std::mem::transmute::<*mut c_void, $type>(ptr)
                }};
            }

            // SLInterfaceID 是导出全局变量：dlsym 返回其地址，解引用得到
            // 指向 16 字节 GUID 的指针（OpenSL 接口要求传 GUID 指针）。
            macro_rules! iid {
                ($name:expr) => {{
                    let sym_name = concat!($name, "\0").as_ptr();
                    let ptr = libc::dlsym(handle, sym_name as *const _);
                    if ptr.is_null() {
                        libc::dlclose(handle);
                        return None;
                    }
                    *(ptr as *const *const c_void)
                }};
            }

            let lib = Self {
                _handle: handle,
                engine_iid: iid!("SL_IID_ENGINE"),
                play_iid: iid!("SL_IID_PLAY"),
                bq_iid: iid!("SL_IID_ANDROIDSIMPLEBUFFERQUEUE"),
                volume_iid: iid!("SL_IID_VOLUME"),
                create_engine: sym!("slCreateEngine", FnSlCreateEngine),
            };
            Some(lib)
        }
    }
}

// =========================================================================
// vtbl 方法封装（unsafe 但集中一处，调用方只传句柄）
// =========================================================================

unsafe fn obj_realize(obj: SlObject) -> u32 {
    let vtbl = &**obj;
    (vtbl.realize)(obj as *mut c_void, SL_BOOLEAN_FALSE)
}

unsafe fn obj_get_interface(obj: SlObject, iid: *const c_void) -> *mut c_void {
    let vtbl = &**obj;
    let mut p: *mut c_void = std::ptr::null_mut();
    let r = (vtbl.get_interface)(obj as *mut c_void, iid, &mut p);
    if r == SL_RESULT_SUCCESS {
        p
    } else {
        std::ptr::null_mut()
    }
}

unsafe fn obj_destroy(obj: SlObject) {
    let vtbl = &**obj;
    (vtbl.destroy)(obj as *mut c_void);
}

unsafe fn engine_create_audio_player(
    eng: SlEngine,
    src: *const SlDataSource,
    sink: *const SlDataSink,
    iids: &[*const c_void],
    required: &[u32],
) -> Result<SlObject, u32> {
    let vtbl = &**eng;
    let mut player: *mut c_void = std::ptr::null_mut();
    let r = (vtbl.create_audio_player)(
        eng as *mut c_void,
        &mut player,
        src,
        sink,
        iids.len() as u32,
        iids.as_ptr(),
        required.as_ptr(),
    );
    if r == SL_RESULT_SUCCESS && !player.is_null() {
        Ok(player as SlObject)
    } else {
        Err(r)
    }
}

unsafe fn engine_create_output_mix(eng: SlEngine) -> Result<SlObject, u32> {
    let vtbl = &**eng;
    let mut mix: *mut c_void = std::ptr::null_mut();
    let r = (vtbl.create_output_mix)(
        eng as *mut c_void,
        &mut mix,
        0,
        std::ptr::null(),
        std::ptr::null(),
    );
    if r == SL_RESULT_SUCCESS && !mix.is_null() {
        Ok(mix as SlObject)
    } else {
        Err(r)
    }
}

unsafe fn play_set_state(play: SlPlay, state: u32) -> u32 {
    let vtbl = &**play;
    (vtbl.set_play_state)(play as *mut c_void, state)
}

unsafe fn bq_enqueue(bq: SlBufferQueue, ptr: *const c_void, len: u32) -> u32 {
    let vtbl = &**bq;
    (vtbl.enqueue)(bq as *mut c_void, ptr, len)
}

unsafe fn bq_clear(bq: SlBufferQueue) -> u32 {
    let vtbl = &**bq;
    (vtbl.clear)(bq as *mut c_void)
}

// =========================================================================
// OpenSL 会话（engine + output mix + audio player 及各接口）
// =========================================================================

struct OpenSlSession {
    engine_obj: SlObject,
    mix_obj: SlObject,
    player_obj: SlObject,
    engine: SlEngine,
    play: SlPlay,
    bq: SlBufferQueue,
    volume: Option<SlVolume>,
    sample_rate: u32,
    channels: u32,
}

impl OpenSlSession {
    /// 销毁顺序与创建相反：player → mix → engine。
    unsafe fn destroy(self) {
        unsafe {
            if !self.player_obj.is_null() {
                obj_destroy(self.player_obj);
            }
            if !self.mix_obj.is_null() {
                obj_destroy(self.mix_obj);
            }
            if !self.engine_obj.is_null() {
                obj_destroy(self.engine_obj);
            }
        }
    }
}

// =========================================================================
// 缓冲队列共享状态（回调线程 + 工作线程并发访问）
// =========================================================================

struct OpenSlShared {
    bq: *mut c_void,
    enqueue: FnBqEnqueue,
    /// 待回调取走入队的缓冲（Box 泄漏指针）。
    ready: Mutex<VecDeque<*mut Vec<u8>>>,
    /// 已 Enqueue、等待消费完成后释放的缓冲。
    consumed: Mutex<Vec<*mut Vec<u8>>>,
    /// 队列为空时补入的静音缓冲（静态泄漏，进程生命周期内有效）。
    silent: &'static [u8],
}

// 回调线程经裸指针访问；字段只读/锁保护，不涉及所有权迁移。
unsafe impl Send for OpenSlShared {}

/// OpenSL 缓冲队列回调（播放线程触发）：取一个已填充缓冲入队；
/// 队列空时入队静音缓冲避免下溢爆音。上一轮入队的缓冲在本轮触发时
/// 已消费完毕，此时释放其内存（保证 Enqueue 缓冲在消费期间存活）。
extern "C" fn bq_callback(caller: *mut c_void, ctx: *mut c_void) {
    let shared = unsafe { &*(ctx as *const OpenSlShared) };

    if let Ok(mut c) = shared.consumed.lock() {
        if let Some(p) = c.pop() {
            drop(unsafe { Box::from_raw(p) });
        }
    }

    let buf_ptr = {
        let mut q = match shared.ready.lock() {
            Ok(q) => q,
            Err(e) => e.into_inner(),
        };
        q.pop_front()
    };

    let (ptr, len) = match buf_ptr {
        Some(p) => {
            let len = unsafe { (*p).len() };
            if let Ok(mut c) = shared.consumed.lock() {
                c.push(p);
            }
            (unsafe { (*p).as_ptr() as *const c_void }, len as u32)
        }
        None => (
            shared.silent.as_ptr() as *const c_void,
            shared.silent.len() as u32,
        ),
    };
    unsafe {
        (shared.enqueue)(caller, ptr, len);
    }
}

/// 释放 ready / consumed 中所有泄漏缓冲。**必须在回调停止后调用**
/// （SetPlayState(STOPPED) 之后），否则可能与回调线程竞争。
unsafe fn flush_buffers(shared: &OpenSlShared) {
    unsafe {
        if let Ok(mut q) = shared.ready.lock() {
            while let Some(p) = q.pop_front() {
                drop(Box::from_raw(p));
            }
        }
        if let Ok(mut c) = shared.consumed.lock() {
            while let Some(p) = c.pop() {
                drop(Box::from_raw(p));
            }
        }
    }
}

// =========================================================================
// DSP 产块 → i16 字节 → 入队（供初始化预填与主循环共用）
// =========================================================================

#[allow(clippy::too_many_arguments)]
fn produce_and_enqueue<P: BlockProducer + Send + 'static>(
    buffered: &mut BufferedSource<P>,
    normalizer: &mut VolumeNormalizer,
    equalizer: &mut Equalizer,
    sound_effect: &mut SoundEffectBlockProcessor,
    anime_fx: &mut AnimeFxEngine,
    resampler: Option<&mut LinearResampler>,
    user_volume: &Arc<AtomicU32>,
    progress: &Arc<ExclusiveProgress>,
    visualizer: &'static SharedVisualizer,
    shared: &OpenSlShared,
    source_channels: u16,
    stream_channels: u16,
    downmix_active: bool,
) -> bool {
    let raw_block = match buffered.next_block() {
        Some(block) => block,
        None => return false, // EOF
    };
    let block = if downmix_active {
        crate::player::channel_downmix::downmix_block(&raw_block, source_channels)
    } else {
        raw_block
    };

    // DSP 链与 android_aaudio 完全一致
    let normalized = normalizer.process_block(&block);
    let eq_applied = equalizer.process_block(&normalized);
    let effected = sound_effect.process_block(eq_applied);
    let effected = anime_fx.process_block(effected);
    // 进度/曲终按源采样率域的样本数累计，重采样只改变写入的字节数。
    let produced = effected.len() as u64;
    let effected = match resampler {
        Some(rs) => rs.process(&effected),
        None => effected,
    };
    if effected.is_empty() {
        // 重采样器攒块中：本次没有输出帧，但数据已消费，继续取下一块。
        return true;
    }

    let vol = f32::from_bits(user_volume.load(Ordering::Relaxed));
    let mut byte_buf: Vec<u8> = Vec::with_capacity(effected.len() * 2);
    let mut chan_sum = 0.0f32;
    let mut chan_count = 0u32;
    for &sample in &effected {
        let amplified = sample * vol;
        push_sample_bytes(&mut byte_buf, amplified, DeviceFormat::Int16);
        chan_sum += amplified;
        chan_count += 1;
        if chan_count >= stream_channels as u32 {
            visualizer.push_sample(chan_sum / chan_count as f32);
            chan_sum = 0.0;
            chan_count = 0;
        }
    }
    progress.samples_played.fetch_add(produced, Ordering::Relaxed);

    let boxed = Box::into_raw(Box::new(byte_buf));
    shared
        .ready
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .push_back(boxed);
    true
}

/// 连续产出 `count` 块并（由回调）入队。返回是否仍有数据（false = EOF）。
#[allow(clippy::too_many_arguments)]
fn fill_initial<P: BlockProducer + Send + 'static>(
    buffered: &mut BufferedSource<P>,
    normalizer: &mut VolumeNormalizer,
    equalizer: &mut Equalizer,
    sound_effect: &mut SoundEffectBlockProcessor,
    anime_fx: &mut AnimeFxEngine,
    mut resampler: Option<&mut LinearResampler>,
    user_volume: &Arc<AtomicU32>,
    progress: &Arc<ExclusiveProgress>,
    visualizer: &'static SharedVisualizer,
    shared: &OpenSlShared,
    source_channels: u16,
    stream_channels: u16,
    downmix_active: bool,
    count: usize,
) -> bool {
    let mut any = false;
    for _ in 0..count {
        if !produce_and_enqueue(
            buffered,
            normalizer,
            equalizer,
            sound_effect,
            anime_fx,
            resampler.as_deref_mut(),
            user_volume,
            progress,
            visualizer,
            shared,
            source_channels,
            stream_channels,
            downmix_active,
        ) {
            break;
        }
        any = true;
    }
    any
}

// =========================================================================
// 创建 OpenSL 会话（含采样率协商）
// =========================================================================

unsafe fn create_audio_player_for_rate(
    lib: &OpenSlLib,
    engine: SlEngine,
    mix: SlObject,
    sample_rate: u32,
    channels: u32,
) -> Result<(SlObject, SlPlay, SlBufferQueue, Option<SlVolume>), String> {
    let loc_bq = SlDataLocator_AndroidSimpleBufferQueue {
        locator_type: SL_DATALOCATOR_ANDROIDBUFFERQUEUE,
        num_buffers: MAX_READY as u32 + PRIME_BUFFERS as u32,
    };
    let loc_mix = SlDataLocator_OutputMix {
        locator_type: SL_DATALOCATOR_OUTPUTMIX,
        output_mix: mix as *mut c_void,
    };
    let format = SlDataFormat_Pcm {
        format_type: SL_DATAFORMAT_PCM,
        num_channels: channels,
        samples_per_sec: sample_rate * 1000, // 毫赫兹
        bits_per_sample: 16,
        container_size: 16,
        channel_mask: if channels == 1 {
            SL_SPEAKER_FRONT_CENTER
        } else {
            SL_SPEAKER_FRONT_LEFT | SL_SPEAKER_FRONT_RIGHT
        },
        endianness: SL_BYTEORDER_LITTLEENDIAN,
    };
    let src = SlDataSource {
        p_locator: (&loc_bq as *const _) as *mut c_void,
        p_format: (&format as *const _) as *mut c_void,
    };
    let sink = SlDataSink {
        p_locator: (&loc_mix as *const _) as *mut c_void,
        p_format: std::ptr::null_mut(),
    };
    let iids = [lib.play_iid, lib.bq_iid, lib.volume_iid];
    let required = [SL_BOOLEAN_TRUE, SL_BOOLEAN_TRUE, SL_BOOLEAN_FALSE];

    let player = match engine_create_audio_player(engine, &src, &sink, &iids, &required) {
        Ok(p) => p,
        Err(r) => return Err(format!("OpenSL CreateAudioPlayer 失败({sample_rate}Hz, res={r})")),
    };
    let r = obj_realize(player);
    if r != SL_RESULT_SUCCESS {
        obj_destroy(player);
        return Err(format!("OpenSL 音频播放器 realize 失败({sample_rate}Hz, res={r})"));
    }
    let play = obj_get_interface(player, lib.play_iid) as SlPlay;
    let bq = obj_get_interface(player, lib.bq_iid) as SlBufferQueue;
    let volume = obj_get_interface(player, lib.volume_iid) as SlVolume;
    if play.is_null() || bq.is_null() {
        obj_destroy(player);
        return Err("OpenSL 播放器缺少必要接口(PLAY/BUFFERQUEUE)".to_string());
    }
    let volume = if volume.is_null() { None } else { Some(volume) };
    Ok((player, play, bq, volume))
}

/// 尝试 [源采样率, 48000, 44100] 建流；全部失败返回 Err。
unsafe fn create_session(
    lib: &OpenSlLib,
    source_sample_rate: u32,
    channels: u32,
) -> Result<OpenSlSession, String> {
    // 1. engine
    let mut engine_obj_raw: *mut c_void = std::ptr::null_mut();
    let r = (lib.create_engine)(
        &mut engine_obj_raw,
        0,
        std::ptr::null(),
        1,
        &lib.engine_iid,
        [SL_BOOLEAN_TRUE].as_ptr(),
    );
    if r != SL_RESULT_SUCCESS || engine_obj_raw.is_null() {
        return Err(format!("slCreateEngine 失败(res={r})"));
    }
    let engine_obj = engine_obj_raw as SlObject;
    let r = obj_realize(engine_obj);
    if r != SL_RESULT_SUCCESS {
        obj_destroy(engine_obj);
        return Err(format!("OpenSL engine realize 失败(res={r})"));
    }
    let engine = obj_get_interface(engine_obj, lib.engine_iid) as SlEngine;
    if engine.is_null() {
        obj_destroy(engine_obj);
        return Err("OpenSL engine 缺少 ENGINE 接口".to_string());
    }

    // 2. output mix
    let mix = match engine_create_output_mix(engine) {
        Ok(m) => m,
        Err(r) => {
            obj_destroy(engine_obj);
            return Err(format!("OpenSL CreateOutputMix 失败(res={r})"));
        }
    };
    let r = obj_realize(mix);
    if r != SL_RESULT_SUCCESS {
        obj_destroy(mix);
        obj_destroy(engine_obj);
        return Err(format!("OpenSL output mix realize 失败(res={r})"));
    }

    // 3. audio player：源率 → 48k → 44.1k 逐级协商
    let mut candidates = vec![source_sample_rate, 48000, 44100];
    candidates.dedup();
    let mut last_err = String::new();
    let mut player = None;
    let mut play = std::ptr::null_mut();
    let mut bq = std::ptr::null_mut();
    let mut volume = None;
    for rate in candidates {
        match create_audio_player_for_rate(lib, engine, mix, rate, channels) {
            Ok((p, pl, b, v)) => {
                player = Some(p);
                play = pl;
                bq = b;
                volume = v;
                return Ok(OpenSlSession {
                    engine_obj,
                    mix_obj: mix,
                    player_obj: p,
                    engine,
                    play,
                    bq,
                    volume,
                    sample_rate: rate,
                    channels,
                });
            }
            Err(e) => {
                last_err = e;
            }
        }
    }
    let _ = (player, play, bq, volume);
    obj_destroy(mix);
    obj_destroy(engine_obj);
    Err(format!("OpenSL 建流失败：{last_err}"))
}

// =========================================================================
// 主工作线程（由 android_aaudio::run_exclusive_playback 在 AAudio
// 加载失败时调用；命令通道 / 进度 / 断流语义与 AAudio 后端一致）
// =========================================================================

pub(crate) fn run_opensl_exclusive_playback(
    request: super::ExclusivePlayRequest,
    cmd_rx: Receiver<ExclusiveCommand>,
    init_tx: SyncSender<Result<(String, u32, u16), String>>,
    progress: Arc<ExclusiveProgress>,
    running: Arc<AtomicBool>,
    last_error: Arc<Mutex<Option<String>>>,
) {
    // 1. 加载 OpenSL ES 库
    let lib = match OpenSlLib::load() {
        Some(l) => l,
        None => {
            let _ = init_tx.send(Err(
                "无法加载 libOpenSLES.so（需要 Android API 9+）".to_string()
            ));
            return;
        }
    };

    // 1.5 流缓存直读（在线歌曲）：与 android_aaudio 相同，复用下载线程
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

    // 2. 打开解码器
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

    // 声道策略与 AAudio 后端一致：共享模式固定立体声；独占模式按源声道。
    // OpenSL 缓冲队列仅支持 1/2 声道，>2 声道源先下混为立体声。
    let mut playback_channels: u16 = if request.shared_mode {
        2
    } else {
        source_channels.min(2)
    };
    if source_channels > 2 {
        playback_channels = 2;
    }
    let downmix_active = playback_channels != source_channels;

    // 3. 缓冲源 + 起始跳转
    let mut buffered =
        BufferedSource::new(decoder, source_sample_rate, source_channels, total_duration);
    if request.start_time_secs > 0.0 {
        if let Err(e) = buffered.try_seek(Duration::from_secs_f64(request.start_time_secs)) {
            let _ = init_tx.send(Err(format!("跳转失败: {e}")));
            return;
        }
    }

    // 4. DSP 链装配（与 android_aaudio 相同）
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
    let mut anime_fx = AnimeFxEngine::new(source_sample_rate, playback_channels);
    if !request.sound_effect_settings_json.is_empty() {
        if let Ok(se_settings) =
            serde_json::from_str::<SoundEffectSettings>(&request.sound_effect_settings_json)
        {
            anime_fx.set_params_json(se_settings.anime_params.as_deref());
            sound_effect.set_settings(se_settings);
        }
    }

    let user_volume = Arc::new(AtomicU32::new(request.volume.to_bits()));
    let is_paused = Arc::new(AtomicBool::new(!request.is_playing));

    // 5. 创建 OpenSL 会话（含采样率协商）
    let mut session = match unsafe {
        create_session(&lib, source_sample_rate, playback_channels as u32)
    } {
        Ok(s) => s,
        Err(e) => {
            let _ = init_tx.send(Err(e));
            return;
        }
    };
    let stream_sample_rate = session.sample_rate;
    let stream_channels = session.channels as u16;

    // 流实际采样率被协商降级（源率不受支持时回退 48k/44.1k），写出前做
    // 一次重采样对齐，否则整段音频会变速走调。进度仍按重采样前的样本数
    // 在源采样率域累计（见 samples_played），seek/曲终判定不受影响。
    let mut resampler = if stream_sample_rate != source_sample_rate {
        Some(LinearResampler::new(
            playback_channels as usize,
            source_sample_rate as f64 / stream_sample_rate as f64,
        ))
    } else {
        None
    };

    // 进度信息：采样率按音效引擎有效率记录（与 AAudio 一致）
    let effective_rate = sound_effect.effective_sample_rate();
    progress.sample_rate.store(effective_rate, Ordering::Relaxed);
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

    // 6. 共享回调状态（静音缓冲静态泄漏；其余缓冲由回调负责释放）
    let silent: &'static [u8] = Box::leak(
        vec![0u8; (BUFFER_FRAMES as usize) * stream_channels as usize * 2].into_boxed_slice(),
    );
    let shared_box = Box::new(OpenSlShared {
        bq: session.bq as *mut c_void,
        enqueue: unsafe { (**session.bq).enqueue },
        ready: Mutex::new(VecDeque::new()),
        consumed: Mutex::new(Vec::new()),
        silent,
    });
    let shared_ptr = Box::into_raw(shared_box);

    unsafe {
        let vtbl = &**session.bq;
        let r = (vtbl.register_callback)(
            session.bq as *mut c_void,
            bq_callback,
            shared_ptr as *mut c_void,
        );
        if r != SL_RESULT_SUCCESS {
            drop(Box::from_raw(shared_ptr));
            let _ = init_tx.send(Err(format!("OpenSL 注册缓冲回调失败(res={r})")));
            unsafe { session.destroy() };
            return;
        }
    }

    // 7. 预填缓冲并进入播放
    if !fill_initial(
        &mut buffered,
        &mut normalizer,
        &mut equalizer,
        &mut sound_effect,
        &mut anime_fx,
        resampler.as_mut(),
        &user_volume,
        &progress,
        visualizer,
        unsafe { &*shared_ptr },
        source_channels,
        stream_channels,
        downmix_active,
        PRIME_BUFFERS,
    ) {
        // 源文件极短/空：直接结束，不启动播放
        unsafe { drop(Box::from_raw(shared_ptr)) };
        unsafe { session.destroy() };
        running.store(false, Ordering::Relaxed);
        return;
    }
    unsafe { prime_enqueue(unsafe { &*shared_ptr }, session.bq) };
    let _ = unsafe { play_set_state(session.play, SL_PLAYSTATE_PLAYING) };

    // 8. 通知初始化成功
    let device_name = if request.shared_mode {
        format!(
            "OpenSL ES 系统混音器 ({}Hz, {}ch, 16bit shared){}",
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
            "OpenSL ES 独占 ({}Hz, {}ch, 16bit){}",
            stream_sample_rate,
            stream_channels,
            if downmix_active {
                format!(" {}ch→2ch 下混", source_channels)
            } else {
                String::new()
            }
        )
    };
    let _ = init_tx.send(Ok((device_name, stream_sample_rate, stream_channels)));

    // 9. 命令 + 产块循环（语义与 AAudio 后端一致）
    let mut eof = false;
    'outer: loop {
        let pending_cmd = if is_paused.load(Ordering::Relaxed) {
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
                unsafe {
                    let _ = play_set_state(session.play, SL_PLAYSTATE_STOPPED);
                    let _ = bq_clear(session.bq);
                }
                unsafe { flush_buffers(unsafe { &*shared_ptr }) };
                let _ = buffered.try_seek(Duration::from_secs_f64(time_secs));
                normalizer.reset();
                equalizer.reset();
                sound_effect.reset();
                anime_fx.reset();
                progress.samples_played.store(
                    (time_secs * source_sample_rate as f64 * playback_channels as f64) as u64,
                    Ordering::Relaxed,
                );
                visualizer.reset();
                is_paused.store(!is_playing, Ordering::Relaxed);
                let has_data = fill_initial(
                    &mut buffered,
                    &mut normalizer,
                    &mut equalizer,
                    &mut sound_effect,
                    &mut anime_fx,
                    resampler.as_mut(),
                    &user_volume,
                    &progress,
                    visualizer,
                    unsafe { &*shared_ptr },
                    source_channels,
                    stream_channels,
                    downmix_active,
                    PRIME_BUFFERS,
                );
                if has_data {
                    unsafe { prime_enqueue(unsafe { &*shared_ptr }, session.bq) };
                }
                unsafe {
                    let _ = play_set_state(
                        session.play,
                        if is_playing && has_data {
                            SL_PLAYSTATE_PLAYING
                        } else {
                            SL_PLAYSTATE_PAUSED
                        },
                    );
                }
                if !has_data {
                    eof = true;
                    break;
                }
            }
            Some(ExclusiveCommand::Pause) => {
                unsafe {
                    let _ = play_set_state(session.play, SL_PLAYSTATE_PAUSED);
                }
                is_paused.store(true, Ordering::Relaxed);
            }
            Some(ExclusiveCommand::Resume) => {
                is_paused.store(false, Ordering::Relaxed);
                unsafe {
                    let _ = play_set_state(session.play, SL_PLAYSTATE_PLAYING);
                }
            }
            Some(ExclusiveCommand::SetVolume(vol)) => {
                user_volume.store(vol.to_bits(), Ordering::Relaxed);
            }
            Some(ExclusiveCommand::SetEqualizer(settings)) => {
                eq_handle.set_settings(settings);
            }
            Some(ExclusiveCommand::SetSoundEffect(settings)) => {
                anime_fx.set_params_json(settings.anime_params.as_deref());
                sound_effect.set_settings(settings);
            }
        }

        if is_paused.load(Ordering::Relaxed) {
            continue;
        }

        // 限速：待入队缓冲达到上限时等待回调消费
        loop {
            let len = shared_ready_len(unsafe { &*shared_ptr });
            if len < MAX_READY {
                break;
            }
            thread::sleep(Duration::from_millis(1));
            if !running.load(Ordering::Relaxed) {
                break 'outer;
            }
        }
        if !running.load(Ordering::Relaxed) {
            break;
        }

        if !produce_and_enqueue(
            &mut buffered,
            &mut normalizer,
            &mut equalizer,
            &mut sound_effect,
            &mut anime_fx,
            resampler.as_mut(),
            &user_volume,
            &progress,
            visualizer,
            unsafe { &*shared_ptr },
            source_channels,
            stream_channels,
            downmix_active,
        ) {
            eof = true;
            break;
        }
    }

    // 10. 清理：停止回调后释放全部缓冲，销毁会话
    unsafe {
        let _ = play_set_state(session.play, SL_PLAYSTATE_STOPPED);
        let _ = bq_clear(session.bq);
    }
    unsafe { flush_buffers(unsafe { &*shared_ptr }) };
    unsafe {
        drop(Box::from_raw(shared_ptr));
        session.destroy();
    }
    running.store(false, Ordering::Relaxed);
    if eof {
        // 曲终/seek 后无数据：与 AAudio 后端一致仅置 running=false，
        // 不额外上报错误（Dart 侧看门狗按进度回退）。
        let _ = last_error;
    }
}

/// 读取待入队缓冲数（仅用于限速判断）。
fn shared_ready_len(shared: &OpenSlShared) -> usize {
    shared
        .ready
        .lock()
        .map(|q| q.len())
        .unwrap_or(usize::MAX)
}

/// 把 ready 队列中的缓冲实际入队到 OpenSL。**初始预填与 seek 后都必须
/// 调用**：OpenSL 回调仅在缓冲被消费完成时触发，队列从空开始时引擎
/// 不会回调，若不主动喂第一批缓冲将永久静音。入队成功后缓冲指针移交
/// consumed，由回调在下一轮触发时释放（保证消费期间存活）。
unsafe fn prime_enqueue(shared: &OpenSlShared, bq: SlBufferQueue) {
    loop {
        let p = match shared.ready.lock() {
            Ok(mut q) => q.pop_front(),
            Err(e) => e.into_inner().pop_front(),
        };
        let p = match p {
            Some(p) => p,
            None => break,
        };
        let len = (*p).len();
        let r = bq_enqueue(bq, (*p).as_ptr() as *const c_void, len as u32);
        if r == SL_RESULT_SUCCESS {
            if let Ok(mut c) = shared.consumed.lock() {
                c.push(p);
            }
        } else {
            drop(unsafe { Box::from_raw(p) });
        }
    }
}
