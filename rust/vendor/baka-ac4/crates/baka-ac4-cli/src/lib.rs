//! Library face of the CLI: demuxers shared by the binary and its tests.

pub mod mp4;
pub mod raw;
// XY Music 最小修改：wav 模块原只挂在 main.rs 下，这里导出以便宿主工程
// 复用 WavWriter 把 AC-4 解码结果写成 WAV（上游该行不存在，勿同步回上游）。
pub mod wav;
