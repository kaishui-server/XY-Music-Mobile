//! Shared object rendering controls, ETSI TS 103 190-2 clauses 6.2.8.1/9
//! and 6.3.9.2/10. Transport only; these controls are not applied by the preview.

use super::Reader;
use crate::bitreader::BitReader;
use crate::error::{Result, invalid};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum TrimMode {
    #[default]
    Default,
    Disabled,
    Custom,
    Reserved,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum WarpMode {
    #[default]
    None,
    DoubleY,
    Reserved(u8),
}

/// Reserved surround/height codes remain distinguishable from actual gains.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum TrimGain {
    Db(f32),
    Reserved(u8),
}

/// A configuration in bitstream order (nine configurations). Absent fields
/// remain None: renderer-defined default trim is not an explicit zero gain.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TrimConfiguration {
    pub mode: TrimMode,
    pub centre: Option<TrimGain>,
    pub surround: Option<TrimGain>,
    pub height: Option<TrimGain>,
    /// Signed front/back balance for the top and bottom planes, in [-1, 1].
    pub balance_top_bottom: Option<f32>,
    /// Signed front/back balance for the listener plane, in [-1, 1].
    pub balance_listener: Option<f32>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct TrimMetadata {
    pub warp: WarpMode,
    pub global_mode: TrimMode,
    pub configurations: [TrimConfiguration; 9],
}

#[derive(Clone, Debug, PartialEq)]
pub struct CommonData {
    pub master_screen_ratio: f32,
    pub bed_channel_distribution: bool,
    /// None means b_trim_present was false (or no additional data).
    pub trim: Option<TrimMetadata>,
    /// Bed-render syntax and future additional data, packed MSB first, without
    /// the decoded trim prefix. Only additional_bits bits are meaningful.
    /// Retaining these bits does not claim bed rendering support.
    pub additional_data: Vec<u8>,
    pub additional_bits: usize,
}

impl Default for CommonData {
    fn default() -> Self {
        Self {
            master_screen_ratio: 1.0,
            bed_channel_distribution: false,
            trim: None,
            additional_data: Vec::new(),
            additional_bits: 0,
        }
    }
}

pub(crate) fn parse(gb: &mut BitReader<'_>, end: usize) -> Result<CommonData> {
    if end
        > gb.bits_count()
            .saturating_add(gb.bits_left().max(0) as usize)
    {
        return Err(invalid("truncated OAMD common data"));
    }
    Reader { gb, end }.common()
}

impl Reader<'_, '_> {
    fn trim_gain(&mut self, centre: bool) -> Result<TrimGain> {
        const DB: [f32; 16] = [
            6.0, 3.0, 1.5, 0.75, -0.75, -1.5, -3.0, -4.5, -6.0, -7.5, -9.0, -10.5, -12.0, -13.5,
            -16.0, -36.0,
        ];
        let code = self.get(4)? as usize;
        Ok(if !centre && code < 4 {
            TrimGain::Reserved(code as u8)
        } else {
            TrimGain::Db(DB[code])
        })
    }

    fn balance(&mut self) -> Result<f32> {
        let sign = if self.flag()? { 1.0 } else { -1.0 };
        Ok(sign * (self.get(4)? + 1) as f32 / 16.0)
    }

    fn trim(&mut self) -> Result<Option<TrimMetadata>> {
        if !self.flag()? {
            return Ok(None);
        }
        let warp = match self.get(2)? {
            0 => WarpMode::None,
            1 => WarpMode::DoubleY,
            code => WarpMode::Reserved(code as u8),
        };
        self.get(2)?; // reserved
        let global_mode = match self.get(2)? {
            0 => TrimMode::Default,
            1 => TrimMode::Disabled,
            2 => TrimMode::Custom,
            _ => TrimMode::Reserved,
        };
        let mut result = TrimMetadata {
            warp,
            global_mode,
            configurations: [TrimConfiguration {
                mode: global_mode,
                ..Default::default()
            }; 9],
        };
        if global_mode == TrimMode::Custom {
            for configuration in &mut result.configurations {
                if self.flag()? {
                    configuration.mode = TrimMode::Default;
                } else if self.flag()? {
                    configuration.mode = TrimMode::Disabled;
                } else {
                    let presence = self.get(5)?;
                    if presence & 16 != 0 {
                        configuration.centre = Some(self.trim_gain(true)?);
                    }
                    if presence & 8 != 0 {
                        configuration.surround = Some(self.trim_gain(false)?);
                    }
                    if presence & 4 != 0 {
                        configuration.height = Some(self.trim_gain(false)?);
                    }
                    if presence & 2 != 0 {
                        configuration.balance_top_bottom = Some(self.balance()?);
                    }
                    if presence & 1 != 0 {
                        configuration.balance_listener = Some(self.balance()?);
                    }
                }
            }
        }
        Ok(Some(result))
    }

    pub(super) fn common(&mut self) -> Result<CommonData> {
        let mut result = CommonData::default();
        if !self.flag()? {
            result.master_screen_ratio = (self.get(5)? + 1) as f32 / 33.0;
        }
        result.bed_channel_distribution = self.flag()?;
        if self.flag()? {
            let mut bytes = self.get(1)? as usize + 1;
            if bytes == 2 {
                bytes = bytes
                    .checked_add(self.variable(2)?)
                    .ok_or_else(|| invalid("OAMD common extension length overflow"))?;
            }
            let bits = bytes
                .checked_mul(8)
                .ok_or_else(|| invalid("OAMD common extension length overflow"))?;
            if bits > self.end.saturating_sub(self.gb.bits_count()) {
                return Err(invalid("truncated OAMD common extension"));
            }
            let outer = self.end;
            self.end = self.gb.bits_count() + bits;
            result.trim = self.trim()?;
            result.additional_bits = self.end - self.gb.bits_count();
            result.additional_data = vec![0; result.additional_bits.div_ceil(8)];
            for i in 0..result.additional_bits {
                result.additional_data[i / 8] |= (self.get(1)? as u8) << (7 - i % 8);
            }
            self.end = outer;
        }
        Ok(result)
    }
}

#[cfg(test)]
mod tests;
