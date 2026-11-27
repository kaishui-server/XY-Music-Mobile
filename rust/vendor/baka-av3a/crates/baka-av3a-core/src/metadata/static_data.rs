//! Static definitions retain quantized values and explicit optional-field presence.
use crate::{BitReader, Error};
mod values;
mod vr;
pub use values::{DynamicsValues, GainValue};
pub use vr::*;
#[cfg(test)]
mod tests;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Screen {
    pub cartesian: bool,
    pub aspect_ratio: u8,
    pub position: [u8; 3],
    pub width: u8,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Programme {
    pub language: Option<u8>,
    pub ducking_depth: Option<u8>,
    pub loudness: Option<[Option<u8>; 6]>,
    pub screen: Option<Screen>,
    pub contents: Vec<u8>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Content {
    pub index: u8,
    pub language: Option<u8>,
    pub loudness: Option<[Option<u8>; 6]>,
    pub dialogue: Option<[u8; 2]>,
    pub complementary_objects: Vec<Vec<u8>>,
    pub objects: Vec<u8>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EncodedGain {
    pub decibels: bool,
    pub upper: bool,
    pub index: u8,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GainInteraction {
    pub decibels: bool,
    pub range: [u8; 2],
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PositionInteraction {
    pub cartesian: bool,
    /// Per-axis min/max, raw offset-binary or unsigned polar indices.
    pub ranges: [[u8; 2]; 3],
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Interaction {
    pub name: [u8; 24],
    pub on_off: bool,
    pub gain: Option<GainInteraction>,
    pub position: Option<PositionInteraction>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StaticObject {
    pub index: u8,
    pub language: Option<u8>,
    pub dialogue: Option<[u8; 2]>,
    pub importance: Option<u8>,
    pub disable_ducking: bool,
    pub interaction: Option<Interaction>,
    pub gain: Option<EncodedGain>,
    pub head_locked: bool,
    pub muted: bool,
    pub packs: Vec<u8>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpeakerPosition {
    pub coordinates: [u8; 3],
    pub screen_edge_lock: u8,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HoaPack {
    pub normalization: u8,
    pub nfc_distance: u8,
    pub screen_reference: bool,
    pub order: u8,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AudioPack {
    pub index: u8,
    pub importance: Option<u8>,
    pub type_label: u8,
    pub absolute_distance: u8,
    pub hoa: Option<HoaPack>,
    pub format_id: Option<u8>,
    pub matrix_outputs: Vec<SpeakerPosition>,
    pub start_index: Option<u8>,
    /// Channel definition index and optional reused transport reference.
    pub channels: Vec<(u8, Option<u8>)>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StaticChannel {
    pub index: u8,
    pub gain: Option<EncodedGain>,
    pub speaker: Option<SpeakerPosition>,
    pub matrix_coefficients: Vec<u8>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StaticMetadata {
    pub basic_level: u8,
    pub programme: Programme,
    pub contents: Vec<Content>,
    pub objects: Vec<StaticObject>,
    pub packs: Vec<AudioPack>,
    pub channels: Vec<StaticChannel>,
    pub vr: Option<VrExtension>,
}

pub(super) fn read(reader: &mut BitReader<'_>, width: u8) -> Result<u8, Error> {
    let value = reader.read(width)? as u8;
    #[cfg(test)]
    tests::record(width, value);
    Ok(value)
}
pub(super) fn flag(reader: &mut BitReader<'_>) -> Result<bool, Error> {
    Ok(read(reader, 1)? != 0)
}
pub(super) fn flags<const N: usize>(reader: &mut BitReader<'_>) -> Result<[bool; N], Error> {
    let mut result = [false; N];
    for value in &mut result {
        *value = flag(reader)?;
    }
    Ok(result)
}
fn optional(reader: &mut BitReader<'_>, present: bool, width: u8) -> Result<Option<u8>, Error> {
    if present {
        Ok(Some(read(reader, width)?))
    } else {
        Ok(None)
    }
}
fn references(
    reader: &mut BitReader<'_>,
    count_width: u8,
    index_width: u8,
) -> Result<Vec<u8>, Error> {
    let count = usize::from(read(reader, count_width)?) + 1;
    (0..count).map(|_| read(reader, index_width)).collect()
}
fn loudness(reader: &mut BitReader<'_>) -> Result<[Option<u8>; 6], Error> {
    let present = flags::<6>(reader)?;
    let mut values = [None; 6];
    for (value, &present) in values.iter_mut().zip(&present) {
        *value = optional(reader, present, 5)?;
    }
    Ok(values)
}
fn position(reader: &mut BitReader<'_>) -> Result<[u8; 3], Error> {
    Ok([read(reader, 8)?, read(reader, 6)?, read(reader, 4)?])
}
fn dialogue(reader: &mut BitReader<'_>) -> Result<[u8; 2], Error> {
    Ok([read(reader, 2)?, read(reader, 3)?])
}
fn speaker(reader: &mut BitReader<'_>) -> Result<SpeakerPosition, Error> {
    Ok(SpeakerPosition {
        coordinates: position(reader)?,
        screen_edge_lock: read(reader, 2)?,
    })
}
fn gain(reader: &mut BitReader<'_>) -> Result<EncodedGain, Error> {
    Ok(EncodedGain {
        decibels: flag(reader)?,
        upper: flag(reader)?,
        index: read(reader, 6)?,
    })
}
fn programme(reader: &mut BitReader<'_>) -> Result<Programme, Error> {
    let [language, ducking, has_loudness, has_screen] = flags(reader)?;
    let language = optional(reader, language, 4)?;
    let ducking_depth = optional(reader, ducking, 5)?;
    let loudness = if has_loudness {
        Some(loudness(reader)?)
    } else {
        None
    };
    let screen = if has_screen {
        Some(Screen {
            cartesian: flag(reader)?,
            aspect_ratio: read(reader, 3)?,
            position: position(reader)?,
            width: read(reader, 7)?,
        })
    } else {
        None
    };
    Ok(Programme {
        language,
        ducking_depth,
        loudness,
        screen,
        contents: references(reader, 2, 2)?,
    })
}
fn content(reader: &mut BitReader<'_>) -> Result<Content, Error> {
    let index = read(reader, 2)?;
    let [language, has_loudness, has_dialogue, complementary] = flags(reader)?;
    let language = optional(reader, language, 4)?;
    let loudness = if has_loudness {
        Some(loudness(reader)?)
    } else {
        None
    };
    let dialogue = if has_dialogue {
        Some(dialogue(reader)?)
    } else {
        None
    };
    let mut complementary_objects = Vec::new();
    if complementary {
        for _ in 0..=read(reader, 2)? {
            complementary_objects.push(references(reader, 3, 3)?);
        }
    }
    Ok(Content {
        index,
        language,
        loudness,
        dialogue,
        complementary_objects,
        objects: references(reader, 3, 3)?,
    })
}
fn interaction(reader: &mut BitReader<'_>) -> Result<Interaction, Error> {
    let mut name = [0; 24];
    for byte in &mut name {
        *byte = read(reader, 8)?;
    }
    let [on_off, has_gain, has_position] = flags(reader)?;
    let gain = if has_gain {
        Some(GainInteraction {
            decibels: flag(reader)?,
            range: [read(reader, 7)?, read(reader, 7)?],
        })
    } else {
        None
    };
    let position = if has_position {
        Some(PositionInteraction {
            cartesian: flag(reader)?,
            ranges: [
                [read(reader, 8)?, read(reader, 8)?],
                [read(reader, 6)?, read(reader, 6)?],
                [read(reader, 4)?, read(reader, 4)?],
            ],
        })
    } else {
        None
    };
    Ok(Interaction {
        name,
        on_off,
        gain,
        position,
    })
}
fn object(reader: &mut BitReader<'_>) -> Result<StaticObject, Error> {
    let index = read(reader, 3)?;
    let [
        language,
        has_dialogue,
        importance,
        disable_ducking,
        has_interaction,
        has_gain,
        head_locked,
        muted,
    ] = flags(reader)?;
    let language = optional(reader, language, 4)?;
    let dialogue = if has_dialogue {
        Some(dialogue(reader)?)
    } else {
        None
    };
    let importance = optional(reader, importance, 4)?.map(|v| v.min(10));
    let interaction = if has_interaction {
        Some(interaction(reader)?)
    } else {
        None
    };
    let gain = if has_gain { Some(gain(reader)?) } else { None };
    Ok(StaticObject {
        index,
        language,
        dialogue,
        importance,
        disable_ducking,
        interaction,
        gain,
        head_locked,
        muted,
        packs: references(reader, 3, 3)?,
    })
}
fn pack(reader: &mut BitReader<'_>) -> Result<AudioPack, Error> {
    let index = read(reader, 3)?;
    let [importance, reuse] = flags(reader)?;
    let importance = optional(reader, importance, 4)?.map(|v| v.min(10));
    let type_label = read(reader, 3)?.clamp(1, 5);
    let absolute_distance = read(reader, 5)?;
    let hoa = if type_label == 4 {
        Some(HoaPack {
            normalization: read(reader, 2)?,
            nfc_distance: read(reader, 4)?,
            screen_reference: flag(reader)?,
            order: read(reader, 3)?,
        })
    } else {
        None
    };
    let format_id = optional(reader, matches!(type_label, 1 | 2), 6)?;
    let mut matrix_outputs = Vec::new();
    if type_label == 2 {
        for _ in 0..=read(reader, 5)? {
            matrix_outputs.push(speaker(reader)?);
        }
    }
    let start_index = optional(reader, !reuse, 5)?;
    let count = read(reader, 5)?;
    let mut channels = Vec::new();
    for _ in 0..=count {
        channels.push((read(reader, 5)?, optional(reader, reuse, 5)?));
    }
    Ok(AudioPack {
        index,
        importance,
        type_label,
        absolute_distance,
        hoa,
        format_id,
        matrix_outputs,
        start_index,
        channels,
    })
}
impl StaticMetadata {
    /// Parse after the static-presence flag. All wire counts have fixed small bounds.
    pub fn parse(reader: &mut BitReader<'_>) -> Result<Self, Error> {
        let mut next = reader.clone();
        let has_vr = flag(&mut next)?;
        let basic_level = read(&mut next, 3)?.min(1);
        let programme = programme(&mut next)?;
        let mut contents = Vec::new();
        for _ in 0..=read(&mut next, 2)? {
            contents.push(content(&mut next)?);
        }
        let mut objects = Vec::new();
        for _ in 0..=read(&mut next, 3)? {
            objects.push(object(&mut next)?);
        }
        let mut packs = Vec::new();
        let mut mapping = [None; 32];
        for _ in 0..=read(&mut next, 3)? {
            let pack = pack(&mut next)?;
            for &(channel, _) in &pack.channels {
                mapping[usize::from(channel)] =
                    Some((pack.type_label, pack.format_id, pack.matrix_outputs.len()));
            }
            packs.push(pack);
        }
        let mut channels = Vec::new();
        for _ in 0..=read(&mut next, 5)? {
            let index = read(&mut next, 5)?;
            let gain = if flag(&mut next)? {
                Some(gain(&mut next)?)
            } else {
                None
            };
            let (label, format, matrix_count) = mapping[usize::from(index)]
                .ok_or(Error::Invalid("static channel pack reference"))?;
            let speaker = if label == 1 && format == Some(63) {
                Some(speaker(&mut next)?)
            } else {
                None
            };
            let mut matrix_coefficients = Vec::new();
            if label == 2 {
                for _ in 0..matrix_count {
                    matrix_coefficients.push(read(&mut next, 8)?);
                }
            }
            channels.push(StaticChannel {
                index,
                gain,
                speaker,
                matrix_coefficients,
            });
        }
        let vr = if has_vr {
            if read(&mut next, 3)? != 0 {
                return Err(Error::Unsupported("VR metadata level"));
            }
            Some(VrExtension::parse(&mut next)?)
        } else {
            None
        };
        *reader = next;
        Ok(Self {
            basic_level,
            programme,
            contents,
            objects,
            packs,
            channels,
            vr,
        })
    }
}
