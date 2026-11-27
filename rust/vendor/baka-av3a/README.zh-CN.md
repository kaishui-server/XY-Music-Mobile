# baka-av3a

**纯 Rust AV3A 音频解码器。**

[English](README.md) · [简体中文](README.zh-CN.md)

将 AV3A 压缩包解码为交错多声道 `f32` PCM，提供 MP4 解封装、增量输入、Range 播放与命令行工具。
运行时无第三方 crate 依赖，不调用原生解码器 FFI 或外部解码进程。
需要 **Rust 1.100.0**、edition 2024。

## 快速开始

```sh
cargo install baka-av3a-cli --version 0.1.2 --locked
baka-av3a inspect input.mp4
baka-av3a decode input.mp4 output.wav MODEL.bin LSF.bin
```

**模型和外部码本不随软件分发。** 请自行提供有权使用的兼容资产，格式见[资产说明](docs/assets.md)。
CLI 输出交错 signed 16-bit PCM WAV，拒绝覆盖已有文件，保留解码通道，不自动下混或施加空间效果。
CLI 会将受大小限制的完整输入文件读入内存；边收边播请使用库的增量或 Range 接口。

从源码运行：

```sh
cargo run --release -p baka-av3a-cli -- inspect input.mp4
cargo run --release -p baka-av3a-cli -- decode input.mp4 output.wav MODEL.bin LSF.bin
```

## Rust 接口

```toml
[dependencies]
baka-av3a-core = "0.1.2"
baka-av3a-container = "0.1.2" # 按需添加 MP4 支持
```

```rust,no_run
use std::{error::Error, sync::Arc};
use baka_av3a_core::{decoder::Decoder, model::HyperModel, shaping::LsfCodebooks};
use baka_av3a_container::Track;

fn main() -> Result<(), Box<dyn Error>> {
    let model = Arc::new(HyperModel::parse(&std::fs::read("MODEL.bin")?)?);
    let lsf = Arc::new(LsfCodebooks::parse(&std::fs::read("LSF.bin")?)?);
    let mut decoder = Decoder::new(model, lsf);
    let bytes = std::fs::read("input.mp4")?;
    let track = Track::parse(&bytes)?;
    for packet in track.packets() {
        let pcm = decoder.decode(packet.bytes)?;
        // samples 为交错 f32；sample_rate 和 channels 描述当前输出块。
        // 将 PCM 送入播放器，或调用 to_i16() 进行舍入和饱和转换。
        let _ = pcm;
    }
    Ok(())
}
```

不可变模型只解析一次，通过 `Arc` 共享；每路音频使用独立的 `Decoder` 状态。
每个压缩包输出每通道 1,024 个采样。浮点 PCM 保留余量，转整数时按 `floor(x + 0.5)` 舍入并饱和。
无效包不提交解码状态，配置变化需在流边界显式调用 `reset()`。

## 支持范围

| 功能 | 支持与边界 |
|---|---|
| PCM 解码 | 单声道、立体声、多声道声床、纯对象与声床/对象混合传输；main 与 LC 路径 |
| 低码率立体声 | MCR 模式需要额外提供 MCR 码本 |
| HOA | 一至三阶；降传输三阶配置需要外部基系数资产 |
| 元数据 | PCM 携带静态与动态元数据；解析不代表自动执行对应音效 |
| MP4 | 普通与分片 MP4、顺序增量输入、稀疏 Range 读取 |
| 跳转 | 按媒体时间定位、历史重放、预滚、PCM 裁剪与跳转取消 |
| 校验 | CRC、输入上限、截断、音轨歧义和不支持配置检查 |
| 时间 | 支持媒体时间戳；尚未实现 MP4 edit-list 展示时间映射 |

对象流输出传输通道，HOA 流输出 HOA 分量，不自动映射到物理扬声器。
调用方负责下混、设备输出、HTTP/TLS、重试和播放生命周期。
WAV 导出不裁除解码延迟、不追加合成的解码尾帧。
支持范围以实际配置与错误返回为准，不表示覆盖所有 AV3A 码流。

## 流式播放接入

| 接口 | 用途 |
|---|---|
| `core::stream::ElementaryDecoder` | 裸 AV3A 流增量输入 |
| `container::progressive::Mp4Decoder` | MP4 分块输入，下载完成前输出 PCM |
| `container::range::RangeProbe` | 有界稀疏索引，支持尾置 `moov` |
| `container::range::HttpRangeSession` | 校验 HTTP Range 响应信息 |
| `container::range::playback::RangeDecoder` | 请求音频区间、解码与可取消的跳转重放 |

表中 `core::` 和 `container::` 是对应 crate 名称的简写。
在适合播放器的工作线程中送入数据、执行解码；接口返回自有 PCM，并分配工作缓冲，不承诺音频回调内零分配。
首帧可用时间不等于网络缓冲时间或设备出声时间，详见[架构与接入边界](DESIGN.md)。

[可选空间处理](docs/spatial-rendering.md) 独立于直接解码路径。
多声道解码不需要房间几何、HRIR 数据集或头部跟踪。

## 命令行

```sh
baka-av3a inspect input.mp4
baka-av3a inspect-payload input.mp4
baka-av3a extract input.mp4 output.av3a
baka-av3a inspect-es output.av3a
baka-av3a decode input.mp4 output.wav MODEL.bin LSF.bin [MCR.bin] [HOA.bin]
```

检查命令不重建 PCM。JSON 中的 `pcm_decode` 和 `crc_verified` 表示实际执行的校验。
可选 MCR/HOA 参数通过文件魔数识别，可单独或同时传入，顺序不限。

## 开发

```sh
cargo fmt --all --check
cargo check --all-targets
cargo test --all-targets
cargo clippy --all-targets --all-features -- -D warnings
cargo doc --workspace --no-deps
```

默认测试使用合成夹具；标为 ignored 的测试需要自行提供外部资产或媒体，不属于默认测试执行范围。
性能示例须使用 `--release`，本地文件计时不包含 HTTP 或设备播放延迟。

## 许可证

[GPL-3.0-or-later](LICENSE)，分发边界见 [NOTICE](NOTICE)。
