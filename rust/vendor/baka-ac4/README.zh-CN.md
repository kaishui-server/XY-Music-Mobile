<div align="center">

# baka-ac4

**使用纯 Rust 解码 AC-4 音频并渲染 A-JOC 扬声器输出。**

[![Rust](https://img.shields.io/badge/Rust-2024-DEA584?logo=rust&logoColor=white)](Cargo.toml)
[![License](https://img.shields.io/badge/License-GPL--3.0--or--later-blue)](LICENSE)

[English](README.md) · **简体中文**

[快速开始](#快速开始) · [Rust API](#rust-api) · [输出模式](#输出模式) · [播放器集成](#播放器集成)

</div>

`baka-ac4` 提供可嵌入播放器的解码库，以及将 MP4、M4A 和原始 AC-4 文件转换为 WAV 的命令行工具。解码器完全使用 Rust 实现，不依赖 C 解码库。

需要 Rust **1.100.0**，仓库通过 `rust-toolchain.toml` 固定工具链。

## 快速开始

```sh
cargo install baka-ac4-cli --version 0.2.2 --locked

# 将声道编码的 AC-4 转为 WAV
baka-ac4 decode input.mp4 output.wav

# 将 A-JOC 渲染为立体声浮点 PCM
baka-ac4 decode --render=stereo --f32 input.mp4 stereo.wav

# 将 A-JOC 渲染为 7.1.4 扬声器信号
baka-ac4 decode --render=7.1.4 --f32 input.mp4 surround.wav

# 查看逐帧元数据或测量解码性能
baka-ac4 toc --render=stereo input.mp4
baka-ac4 bench --render=stereo input.mp4 10
```

MP4/M4A 输入必须包含 AC-4 音轨。A-JOC 需要显式选择输出模式；双声道播放可使用 `--render=stereo`。默认输出 16 位 PCM，使用 `--f32` 可保留浮点样本及超过 1 的峰值。

## Rust API

```toml
[dependencies]
baka-ac4-core = "0.2"
```

```rust
use baka_ac4_core::{Ac4Decoder, Result};
use baka_ac4_core::ajoc::render::{RenderOptions, SpeakerLayout};

pub fn decode_packets(packets: &[Vec<u8>]) -> Result<()> {
    let mut decoder = Ac4Decoder::new()?;
    // 启用 A-JOC 立体声渲染；声道编码音频保留原布局。
    decoder.set_ajoc_render(Some(RenderOptions::new(SpeakerLayout::Stereo)))?;
    let mut pcm = Vec::new();

    for packet in packets {
        if let Some(frame) = decoder.decode_frame_into(packet, &mut pcm)? {
            // pcm[channel][sample]：在下一次解码前消费当前样本。
            println!("{} Hz, {} channels", frame.sample_rate, pcm.len());
        }
    }
    Ok(())
}
```

输入数据包可以包含 AC-4 同步头。返回 `Ok(None)` 表示正在等待可独立解码的帧。帧信息包含 `audio_kind`、`sample_rate`、`channel_mask`、`nb_samples` 和 `key_frame`。

## 输出模式

| 输出 | Rust 配置 | CLI 选项 |
| --- | --- | --- |
| 声道编码 PCM | 默认 | 无需额外选项 |
| A-JOC 扬声器信号 | `set_ajoc_render(Some(options))` | `--render=stereo`、`--render=5.1`、`--render=7.1`、`--render=5.1.4` 或 `--render=7.1.4` |
| 重建对象信号 | `set_ajoc_object_signals(true)` | `--object-signals` |
| 核心下混信号 | `set_ajoc_core_signals(true)` | `--core-signals` |
| 基础增益与左右声像投影 | `set_ajoc_stereo_preview(true)` | `--stereo-preview` |

播放 A-JOC 时优先使用扬声器渲染。该路径应用三维声像、对象尺寸与散布、屏幕映射、区域和高度限制、吸附、trim 及定时增益更新。立体声将 LFE 以每侧 0.5 混入，环绕布局保留独立 LFE 通道。

对象与核心信号输出用于自定义音频处理。通道掩码为零表示没有扬声器布局，不能根据通道数量推断布局；核心输出在存在明确扬声器分配时保留其掩码。对象输出的掩码为零，在存在 LFE 时将其放在第一路，不应用对象增益或空间渲染。基础立体声预览仅应用增益与左右位置。

一次只能选择一种 A-JOC 输出模式。渲染、对象重建和预览需要完整 QMF 处理，不能与 `--fast` 同用。`--fast` 是声道解码的快捷路径，会改变输出。

扬声器信号按 WAVE 通道掩码的位顺序排列，多声道 WAV 使用 WAVE_FORMAT_EXTENSIBLE。不执行输出限幅或响度归一化。

### 支持范围

- TOC v1/v2 的声道编码 AC-4，包含 ASF/SSF 和 A-SPX 处理。
- 采用纯动态对象分配和非替代呈现的 A-JOC 448/1500 kbit/s 音频。
- 立体声、5.1、7.1、5.1.4 和 7.1.4 扬声器输出。

对象重建与渲染不支持床声道分配、床声道与动态对象混合分配、区域码 6/7 及保留渲染码，ACPL 支持有限。库不提供 HRTF 耳机渲染、低频管理、对白增强或呈现响度处理。距离、Y 轴变换和平衡扩展可作为元数据读取，但不参与渲染。

## 播放器集成

宿主应用负责解封装、时间戳、播放设备和音源访问。核心库接收压缩数据包并返回平面排列的 `f32` PCM，不提供网络请求或 DRM 解密。CLI 将文件载入内存，适合转换和检查。

解码器具有跨帧状态。跳转时应从合适的可独立解码帧开始，丢弃目标时间之前的预滚样本。`flush()` 清除流状态并保留变换计划和输出选项；它会分配新的历史缓冲，应在播放控制路径调用。

修改 A-JOC 渲染选项会重置解码历史，重复设置相同选项则保留历史。请在输入数据包之前配置输出，并在多次解码之间复用 PCM 缓冲。

详见 [核心 API 指南](crates/baka-ac4-core/README.md) 和 [CLI 指南](crates/baka-ac4-cli/README.md)。

## 开发

```sh
cargo build --release --locked
cargo test --release --locked
cargo clippy --release --all-targets --locked -- -D warnings
```

播放和性能测量应使用 release 构建。

## 许可

采用 [GPL-3.0-or-later](LICENSE)，第三方声明见 [NOTICE](NOTICE)。
