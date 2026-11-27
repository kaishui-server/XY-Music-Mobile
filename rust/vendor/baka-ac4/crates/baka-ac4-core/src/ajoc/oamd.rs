//! Dynamic object properties and sample timing, ETSI TS 103 190-2 5.9/6.3.9.

use super::Reader;
use crate::error::{Result, invalid};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ObjectTiming {
    /// Offset from the first PCM sample of this codec frame.
    pub sample: u16,
    pub ramp: u16,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Divergence {
    #[default]
    Default,
    Table(u8),
    Code(u8),
    Reserved(u8),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OtherProperties {
    pub width: [f32; 3],
    pub screen_factor: f32,
    pub depth_code: u8,
    /// None means at infinity; 1 means no out-of-room distance scaling.
    pub distance: Option<f32>,
    pub divergence: Divergence,
}

impl Default for OtherProperties {
    fn default() -> Self {
        Self {
            width: [0.0; 3],
            screen_factor: 0.0,
            depth_code: 0,
            distance: Some(1.0),
            divergence: Divergence::Default,
        }
    }
}

/// Resolved properties after reuse/differential decoding of one object block.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ObjectProperties {
    pub active: bool,
    /// None denotes minus infinity (muted), not a missing gain update.
    pub gain_db: Option<i16>,
    pub priority: f32,
    /// Normalized room coordinates: X left/right, Y front/back, Z elevation.
    pub position: [f32; 3],
    pub zone_mask: u8,
    pub elevation: bool,
    pub snap: bool,
    pub other: OtherProperties,
    pub trim_disabled: bool,
}

impl Default for ObjectProperties {
    fn default() -> Self {
        Self {
            active: false,
            gain_db: None,
            priority: 0.0,
            position: [0.5, 0.5, 0.0],
            zone_mask: 0,
            elevation: false,
            snap: false,
            other: OtherProperties::default(),
            trim_disabled: false,
        }
    }
}

impl ObjectProperties {
    pub fn linear_gain(&self) -> f32 {
        if self.active {
            self.gain_db
                .map_or(0.0, |db| 10.0f32.powf(db as f32 / 20.0))
        } else {
            0.0
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ObjectUpdate {
    pub timing: ObjectTiming,
    pub properties: ObjectProperties,
}

#[derive(Clone)]
pub(super) struct ObjectState {
    pub properties: ObjectProperties,
    base: [i16; 3],
}

impl Default for ObjectState {
    fn default() -> Self {
        Self {
            properties: ObjectProperties::default(),
            base: [31, 31, 0],
        }
    }
}

impl Reader<'_, '_> {
    pub(super) fn timing(&mut self) -> Result<Vec<ObjectTiming>> {
        let offset = match self.prefix()? {
            2 => match self.prefix()? {
                0 => 16,
                2 => 8,
                _ => 24,
            },
            3 => self.get(5)? as u16,
            _ => 0,
        };
        let blocks = self.get(3)? as usize;
        let mut result = Vec::with_capacity(blocks);
        for _ in 0..blocks {
            let sample = offset + 32 * self.get(6)? as u16;
            let ramp = match self.get(2)? {
                0 => 0,
                1 => 512,
                2 => 1536,
                _ => {
                    if self.flag()? {
                        [
                            32, 64, 128, 256, 320, 480, 1000, 1001, 1024, 1600, 1601, 1602, 1920,
                            2000, 2002, 2048,
                        ][self.get(4)? as usize]
                    } else {
                        self.get(11)? as u16
                    }
                }
            };
            result.push(ObjectTiming { sample, ramp });
        }
        Ok(result)
    }

    fn basic(&mut self, state: &mut ObjectState, previous_gain: Option<Option<i16>>) -> Result<()> {
        state.properties.gain_db = Some(0);
        state.properties.priority = 1.0;
        if self.flag()? {
            return Ok(());
        }
        let fields = self.prefix()?;
        if fields != 3 {
            state.properties.gain_db = match self.prefix()? {
                0 => {
                    let code = self.get(6)? as i16;
                    Some(if code < 15 { 15 - code } else { 14 - code })
                }
                2 => None,
                _ => previous_gain
                    .ok_or_else(|| invalid("OAMD gain refers to missing previous object"))?,
            };
        }
        if fields != 0 {
            state.properties.priority = self.get(5)? as f32 / 31.0;
        }
        Ok(())
    }

    fn position(&mut self, state: &mut ObjectState, iframe: bool) -> Result<()> {
        if !iframe && self.flag()? {
            for coordinate in &mut state.base {
                let code = self.get(3)? as i16;
                let delta = if code & 4 != 0 { code - 8 } else { code };
                *coordinate = coordinate
                    .checked_add(delta)
                    .ok_or_else(|| invalid("OAMD position delta overflow"))?;
            }
        } else {
            state.base[0] = self.get(6)? as i16;
            state.base[1] = self.get(6)? as i16;
            let sign = if self.flag()? { 1 } else { -1 };
            state.base[2] = sign * self.get(4)? as i16;
        }
        Ok(())
    }

    fn zone(&mut self, state: &mut ObjectState) -> Result<()> {
        state.properties.zone_mask = 0;
        state.properties.elevation = true;
        state.properties.snap = false;
        if !self.flag()? {
            let mask = self.get(3)?;
            if mask & 1 != 0 {
                state.properties.zone_mask = self.get(3)? as u8;
            }
            state.properties.elevation = mask & 2 == 0;
            state.properties.snap = mask & 4 != 0;
        }
        Ok(())
    }

    fn other(&mut self, state: &mut ObjectState) -> Result<()> {
        let mut other = OtherProperties::default();
        if !self.flag()? {
            let mask = self.get(4)?;
            if mask & 1 != 0 {
                other.width = if self.flag()? {
                    [
                        self.get(5)? as f32 / 31.0,
                        self.get(5)? as f32 / 31.0,
                        self.get(5)? as f32 / 31.0,
                    ]
                } else {
                    [self.get(5)? as f32 / 31.0; 3]
                };
            }
            if mask & 2 != 0 {
                other.screen_factor = (self.get(3)? + 1) as f32 / 8.0;
                other.depth_code = self.get(2)? as u8;
            }
            if mask & 4 != 0 {
                other.distance = if self.flag()? {
                    None
                } else {
                    Some(
                        [
                            1.1, 1.3, 1.6, 2.0, 2.5, 3.2, 4.0, 5.0, 6.3, 7.9, 10.0, 12.6, 15.8,
                            20.0, 25.1, 50.1,
                        ][self.get(4)? as usize],
                    )
                };
            }
            if mask & 8 != 0 {
                other.divergence = match self.get(2)? {
                    0 => Divergence::Table(self.get(2)? as u8),
                    1 => state.properties.other.divergence,
                    // Keep reserved values distinguishable from supported values.
                    2 => Divergence::Code(self.get(6)? as u8),
                    _ => Divergence::Reserved(self.get(6)? as u8),
                };
            }
        }
        state.properties.other = other;
        Ok(())
    }

    fn extension(&mut self, state: &mut ObjectState, dynamic: bool) -> Result<[i16; 3]> {
        let mut precision = [0; 3];
        state.properties.trim_disabled = false;
        if self.flag()? {
            let bytes = self.get(4)? as usize + 1;
            let end = self.gb.bits_count() + bytes * 8;
            let outer = self.end;
            if end > outer {
                return Err(invalid("truncated OAMD object extension"));
            }
            self.end = end;
            state.properties.trim_disabled = self.flag()?;
            if state.properties.active && dynamic && self.flag()? {
                let mask = self.get(3)?;
                for (axis, value) in precision.iter_mut().enumerate() {
                    if mask & (1 << (2 - axis)) != 0 {
                        *value = [1, 2, -1, -2][self.get(2)? as usize];
                    }
                }
            }
            self.skip(end - self.gb.bits_count())?;
            self.end = outer;
        }
        Ok(precision)
    }

    fn object_block(
        &mut self,
        iframe: bool,
        dynamic: bool,
        state: &mut ObjectState,
        previous_gain: Option<Option<i16>>,
    ) -> Result<ObjectProperties> {
        let active = !self.flag()?;
        if !active {
            *state = ObjectState::default();
        } else {
            state.properties.active = true;
            if iframe || !self.flag()? {
                self.basic(state, previous_gain)?;
            }
            if dynamic {
                if iframe || !self.flag()? {
                    let partial = !iframe && self.flag()?;
                    let (other, zone, position) = if partial {
                        (self.flag()?, self.flag()?, self.flag()?)
                    } else {
                        (true, true, true)
                    };
                    if position {
                        self.position(state, iframe)?;
                    }
                    if zone {
                        self.zone(state)?;
                    }
                    if other {
                        self.other(state)?;
                    }
                }
            } else {
                state.base = [31, 31, 0];
                state.properties.zone_mask = 0;
                state.properties.elevation = false;
                state.properties.snap = false;
                state.properties.other = OtherProperties::default();
            }
        }
        let precision = self.extension(state, dynamic)?;
        state.properties.position = std::array::from_fn(|axis| {
            (state.base[axis] as f32 + precision[axis] as f32 / 5.0)
                / if axis == 2 { 15.0 } else { 62.0 }
        });
        Ok(state.properties)
    }

    pub(super) fn objects(
        &mut self,
        fullband: usize,
        lfe: bool,
        timing: &[ObjectTiming],
        iframe: bool,
        history: &mut Vec<ObjectState>,
    ) -> Result<Vec<Vec<ObjectUpdate>>> {
        let count = fullband + usize::from(lfe);
        history.resize_with(count, ObjectState::default);
        let mut result: Vec<Vec<ObjectUpdate>> = Vec::with_capacity(count);
        for (index, state) in history.iter_mut().enumerate() {
            let mut updates = Vec::with_capacity(timing.len());
            for (block, &timing) in timing.iter().enumerate() {
                let previous_gain = result
                    .last()
                    .and_then(|previous| previous.get(block))
                    .map(|update| update.properties.gain_db);
                let properties = self.object_block(
                    iframe && block == 0,
                    !(lfe && index == 0),
                    state,
                    previous_gain,
                )?;
                updates.push(ObjectUpdate { timing, properties });
            }
            result.push(updates);
        }
        Ok(result)
    }
}

#[cfg(test)]
mod tests;
