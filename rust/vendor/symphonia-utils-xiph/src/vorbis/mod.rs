// Symphonia
// Copyright (c) 2019-2022 The Project Symphonia Developers.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

use symphonia_core::audio::Channels;

/// Get the mapping 0 channel listing for the given number of channels.
pub fn vorbis_channels_to_channels(num_channels: u8) -> Option<Channels> {
    let channels = match num_channels {
        1 => Channels::FRONT_LEFT,
        2 => Channels::FRONT_LEFT | Channels::FRONT_RIGHT,
        3 => Channels::FRONT_LEFT | Channels::FRONT_CENTRE | Channels::FRONT_RIGHT,
        4 => {
            Channels::FRONT_LEFT
                | Channels::FRONT_RIGHT
                | Channels::REAR_LEFT
                | Channels::REAR_RIGHT
        }
        5 => {
            Channels::FRONT_LEFT
                | Channels::FRONT_CENTRE
                | Channels::FRONT_RIGHT
                | Channels::REAR_LEFT
                | Channels::REAR_RIGHT
        }
        6 => {
            Channels::FRONT_LEFT
                | Channels::FRONT_CENTRE
                | Channels::FRONT_RIGHT
                | Channels::REAR_LEFT
                | Channels::REAR_RIGHT
                | Channels::LFE1
        }
        7 => {
            Channels::FRONT_LEFT
                | Channels::FRONT_CENTRE
                | Channels::FRONT_RIGHT
                | Channels::SIDE_LEFT
                | Channels::SIDE_RIGHT
                | Channels::REAR_CENTRE
                | Channels::LFE1
        }
        8 => {
            Channels::FRONT_LEFT
                | Channels::FRONT_CENTRE
                | Channels::FRONT_RIGHT
                | Channels::SIDE_LEFT
                | Channels::SIDE_RIGHT
                | Channels::REAR_LEFT
                | Channels::REAR_RIGHT
                | Channels::LFE1
        }
        // XY 导出扩展：Vorbis I 规范只定义到 8 声道布局（section 4.3.9），
        // >8 声道没有标准布局（QQ 音乐空间音质 galaxy714/916 用 12/16ch，
        // 声道语义由编码端自定义）。这里按固定顺序把前 N 个声位填给声道
        // 计数，只为让 AudioBuffer 能承载全部声道——解码与耦合运算不依赖
        // 声位语义，XY 播放链路会按奇偶序泛化下混立体声。>16 声道的流当前
        // 曲库不产生，保守拒绝。
        9 => vorbis_multichannel(9)?,
        10 => vorbis_multichannel(10)?,
        11 => vorbis_multichannel(11)?,
        12 => vorbis_multichannel(12)?,
        13 => vorbis_multichannel(13)?,
        14 => vorbis_multichannel(14)?,
        15 => vorbis_multichannel(15)?,
        16 => vorbis_multichannel(16)?,
        _ => return None,
    };

    Some(channels)
}

/// >8 声道的占位声位序列（与 symphonia-core Channels 定义的去重位置一一对应），
/// 顺序近似 9.1.6 布局：L R C LFE SL SR RL RR TFL TFR TRL TRR TFC TC FLW FRW。
fn vorbis_multichannel(n: u8) -> Option<Channels> {
    const POSITIONS: [Channels; 16] = [
        Channels::FRONT_LEFT,
        Channels::FRONT_RIGHT,
        Channels::FRONT_CENTRE,
        Channels::LFE1,
        Channels::SIDE_LEFT,
        Channels::SIDE_RIGHT,
        Channels::REAR_LEFT,
        Channels::REAR_RIGHT,
        Channels::TOP_FRONT_LEFT,
        Channels::TOP_FRONT_RIGHT,
        Channels::TOP_REAR_LEFT,
        Channels::TOP_REAR_RIGHT,
        Channels::TOP_FRONT_CENTRE,
        Channels::TOP_CENTRE,
        Channels::FRONT_LEFT_WIDE,
        Channels::FRONT_RIGHT_WIDE,
    ];
    if n == 0 || n as usize > POSITIONS.len() {
        return None;
    }
    Some(POSITIONS[..usize::from(n)].iter().copied().fold(Channels::empty(), |acc, ch| acc | ch))
}
