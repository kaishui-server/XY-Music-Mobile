//! Bounded static scene selection and physical transport reference resolution.
use super::{AudioPack, EncodedGain, GainValue, StaticMetadata};
use crate::Error;

/// One selected object/pack/channel path. Shared physical channels remain
/// separate paths because their object gains and playback states may differ.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResolvedChannel {
    pub object_index: u8,
    pub pack_index: u8,
    pub channel_index: u8,
    pub transport_channel: u8,
    pub type_label: u8,
    /// Product of static object and channel linear gains; zero when muted.
    pub gain: f64,
    pub head_locked: bool,
}

/// Static references resolved without applying loudness, ducking, interaction,
/// head tracking or spatial DSP. This is a scene plan, not rendered audio.
#[derive(Clone, Debug, PartialEq)]
pub struct ResolvedScene {
    physical_channels: u16,
    selected_objects: Vec<u8>,
    channels: Vec<ResolvedChannel>,
}

impl ResolvedScene {
    pub fn physical_channels(&self) -> u16 {
        self.physical_channels
    }
    pub fn selected_objects(&self) -> &[u8] {
        &self.selected_objects
    }
    pub fn channels(&self) -> &[ResolvedChannel] {
        &self.channels
    }
}

impl AudioPack {
    /// Physical transport references in pack channel order. A non-reused pack
    /// is contiguous from `start_index`; a reused pack supplies every reference.
    /// Definition IDs and physical channel IDs are independent namespaces.
    pub fn transport_channels(&self) -> Result<Vec<u8>, Error> {
        if self.channels.is_empty() || self.channels.len() > 32 {
            return Err(Error::Invalid("pack channel count"));
        }
        let mut seen = 0u32;
        let mut result = Vec::with_capacity(self.channels.len());
        for (offset, &(channel, reference)) in self.channels.iter().enumerate() {
            if channel >= 32 || seen & (1 << channel) != 0 {
                return Err(Error::Invalid("pack channel definition reference"));
            }
            seen |= 1 << channel;
            let physical = match (self.start_index, reference) {
                (Some(start), None) => usize::from(start) + offset,
                (None, Some(reference)) => usize::from(reference),
                _ => return Err(Error::Invalid("pack transport mapping mode")),
            };
            if physical >= 32 {
                return Err(Error::Invalid("pack transport reference"));
            }
            result.push(physical as u8);
        }
        Ok(result)
    }
}

fn definitions<T, const N: usize>(
    values: &[T],
    key: impl Fn(&T) -> u8,
) -> Result<[Option<&T>; N], Error> {
    if values.is_empty() || values.len() > N {
        return Err(Error::Invalid("scene definition count"));
    }
    let mut result = [None; N];
    for value in values {
        let slot = result
            .get_mut(usize::from(key(value)))
            .ok_or(Error::Invalid("scene definition index"))?;
        if slot.is_some() {
            return Err(Error::Invalid("duplicate scene definition index"));
        }
        *slot = Some(value);
    }
    Ok(result)
}

fn references<T, const N: usize>(ids: &[u8], table: &[Option<&T>; N]) -> Result<u32, Error> {
    if ids.is_empty() || ids.len() > N {
        return Err(Error::Invalid("scene reference count"));
    }
    let mut mask = 0u32;
    for &id in ids {
        if table.get(usize::from(id)).is_none_or(|v| v.is_none()) {
            return Err(Error::Invalid("missing scene definition"));
        }
        if mask & (1 << id) != 0 {
            return Err(Error::Invalid("duplicate scene reference"));
        }
        mask |= 1 << id;
    }
    Ok(mask)
}

fn linear(gain: Option<&EncodedGain>) -> Result<f64, Error> {
    let Some(gain) = gain else {
        return Ok(1.0);
    };
    if gain.index > 63 {
        return Err(Error::Invalid("static gain index"));
    }
    Ok(match gain.value() {
        GainValue::Linear(v) => f64::from(v),
        GainValue::Decibels(v) => 10.0f64.powf(f64::from(v) / 20.0),
    })
}

struct Graph<'a> {
    contents: [Option<&'a super::Content>; 4],
    objects: [Option<&'a super::StaticObject>; 8],
    packs: [Option<&'a AudioPack>; 8],
    channels: [Option<&'a super::StaticChannel>; 32],
    transport: [Vec<u8>; 8],
}

impl<'a> Graph<'a> {
    fn new(metadata: &'a StaticMetadata, physical_channels: u16) -> Result<Self, Error> {
        if !(1..=32).contains(&physical_channels) || metadata.basic_level > 1 {
            return Err(Error::Invalid("static scene configuration"));
        }
        let mut graph = Self {
            contents: definitions(&metadata.contents, |v| v.index)?,
            objects: definitions(&metadata.objects, |v| v.index)?,
            packs: definitions(&metadata.packs, |v| v.index)?,
            channels: definitions(&metadata.channels, |v| v.index)?,
            transport: std::array::from_fn(|_| Vec::new()),
        };
        references(&metadata.programme.contents, &graph.contents)?;
        for content in &metadata.contents {
            references(&content.objects, &graph.objects)?;
            if content.complementary_objects.len() > 4 {
                return Err(Error::Invalid("complementary group count"));
            }
            for group in &content.complementary_objects {
                references(group, &graph.objects)?;
            }
        }
        for object in &metadata.objects {
            references(&object.packs, &graph.packs)?;
            linear(object.gain.as_ref())?;
        }
        for pack in &metadata.packs {
            if !(1..=5).contains(&pack.type_label) {
                return Err(Error::Invalid("pack type label"));
            }
            let transport = pack.transport_channels()?;
            for (&(channel, _), &physical) in pack.channels.iter().zip(&transport) {
                if graph.channels[usize::from(channel)].is_none()
                    || u16::from(physical) >= physical_channels
                {
                    return Err(Error::Invalid("scene channel reference"));
                }
            }
            graph.transport[usize::from(pack.index)] = transport;
        }
        for channel in &metadata.channels {
            linear(channel.gain.as_ref())?;
        }
        Ok(graph)
    }

    fn selection(&self, metadata: &StaticMetadata, requested: Option<&[u8]>) -> Result<u32, Error> {
        let mut defaults = 0u32;
        let mut grouped = 0u32;
        let mut preferred = 0u32;
        for &index in &metadata.programme.contents {
            let content = self.contents[usize::from(index)].unwrap();
            defaults |= references(&content.objects, &self.objects)?;
            for group in &content.complementary_objects {
                let mask = references(group, &self.objects)?;
                grouped |= mask;
                preferred |= 1 << group[0];
            }
        }
        let reachable = defaults | grouped;
        let selected = if let Some(ids) = requested {
            let selected = if ids.is_empty() {
                0
            } else {
                references(ids, &self.objects)?
            };
            if selected & !reachable != 0 {
                return Err(Error::Invalid("object outside programme"));
            }
            selected
        } else {
            (defaults & !grouped) | preferred
        };
        for &index in &metadata.programme.contents {
            for group in &self.contents[usize::from(index)]
                .unwrap()
                .complementary_objects
            {
                if (references(group, &self.objects)? & selected).count_ones() > 1 {
                    return Err(Error::Invalid("conflicting complementary selection"));
                }
            }
        }
        Ok(selected)
    }
}

impl StaticMetadata {
    /// Resolve programme → content → object → pack → channel references.
    ///
    /// By default all programme objects are selected, taking the first member
    /// of each complementary group. `Some(ids)` specifies the exact active set,
    /// including an empty set to mute everything. Select at most one member per
    /// complementary group. Output is ordered by object ID, then pack/channel
    /// reference order. Referenced definitions are looked up by ID, never offset.
    /// All definition IDs, references and gains, including inactive ones, are
    /// validated before selection. Other spatial fields remain uninterpreted.
    pub fn resolve_scene(
        &self,
        physical_channels: u16,
        selected_objects: Option<&[u8]>,
    ) -> Result<ResolvedScene, Error> {
        let graph = Graph::new(self, physical_channels)?;
        let selected = graph.selection(self, selected_objects)?;
        let mut result = ResolvedScene {
            physical_channels,
            selected_objects: Vec::new(),
            channels: Vec::new(),
        };
        for (index, object) in graph.objects.iter().enumerate() {
            if selected & (1 << index) == 0 {
                continue;
            }
            let object = object.unwrap();
            result.selected_objects.push(index as u8);
            let gain = linear(object.gain.as_ref())?;
            for &pack_id in &object.packs {
                let pack = graph.packs[usize::from(pack_id)].unwrap();
                for (&(channel, _), &physical) in pack
                    .channels
                    .iter()
                    .zip(&graph.transport[usize::from(pack_id)])
                {
                    let channel_gain =
                        linear(graph.channels[usize::from(channel)].unwrap().gain.as_ref())?;
                    result.channels.push(ResolvedChannel {
                        object_index: index as u8,
                        pack_index: pack_id,
                        channel_index: channel,
                        transport_channel: physical,
                        type_label: pack.type_label,
                        gain: if object.muted {
                            0.0
                        } else {
                            gain * channel_gain
                        },
                        head_locked: object.head_locked,
                    });
                }
            }
        }
        Ok(result)
    }
}
