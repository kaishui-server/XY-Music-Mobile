//! Panner coordinates from TS 103 448 Annex A, in WAVE speaker-mask order.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpeakerLayout {
    Stereo,
    Surround51,
    Surround71,
    Surround514,
    Surround714,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Zone {
    Front,
    Centre,
    Side,
    Back,
    Wide,
    BackCentre,
    Height,
    Bottom,
}

#[derive(Clone, Copy)]
pub(super) struct Speaker {
    pub position: [f64; 3],
    pub zone: Zone,
    pub channel: usize,
}

impl SpeakerLayout {
    pub fn channel_mask(self) -> u64 {
        match self {
            Self::Stereo => 3,
            Self::Surround51 => 0x60f,
            Self::Surround71 => 0x63f,
            Self::Surround514 => 0x2d60f,
            Self::Surround714 => 0x2d63f,
        }
    }
    pub fn channels(self) -> usize {
        self.channel_mask().count_ones() as usize
    }
    pub(super) fn counts(self) -> (usize, usize) {
        match self {
            Self::Stereo => (0, 0),
            Self::Surround51 => (2, 0),
            Self::Surround71 => (4, 0),
            Self::Surround514 => (2, 4),
            Self::Surround714 => (4, 4),
        }
    }
    pub(super) fn speakers(self) -> Vec<Speaker> {
        use Zone::*;
        let mut speakers = vec![s([0., 0., 0.], Front, 0), s([1., 0., 0.], Front, 1)];
        if self == Self::Stereo {
            return speakers;
        }
        speakers.push(s([0.5, 0., 0.], Centre, 2));
        let (mid, top) = self.counts();
        if mid == 4 {
            speakers.extend([
                s([0., 1., 0.], Back, 4),
                s([1., 1., 0.], Back, 5),
                s([0., 0.5, 0.], Side, 6),
                s([1., 0.5, 0.], Side, 7),
            ]);
        } else {
            speakers.extend([s([0., 0.5, 0.], Side, 4), s([1., 0.5, 0.], Side, 5)]);
        }
        if top == 4 {
            let first = if mid == 4 { 8 } else { 6 };
            speakers.extend([
                s([0.25, 0.25, 1.], Height, first),
                s([0.75, 0.25, 1.], Height, first + 1),
                s([0.25, 0.75, 1.], Height, first + 2),
                s([0.75, 0.75, 1.], Height, first + 3),
            ]);
        }
        speakers
    }
}

fn s(position: [f64; 3], zone: Zone, channel: usize) -> Speaker {
    Speaker {
        position,
        zone,
        channel,
    }
}

pub(super) fn excluded(zone: Zone, mask: u8, elevation: bool, extended: bool, mid: usize) -> bool {
    use Zone::*;
    if !elevation && matches!(zone, Height | Bottom) {
        return true;
    }
    match mask {
        1 => matches!(zone, Back | BackCentre),
        2 => zone == Side || (extended && zone == Wide),
        3 => zone == Front || (mid >= 4 && zone == Side) || (extended && zone == Wide),
        4 => matches!(zone, Side | Back | BackCentre) || (extended && zone == Wide),
        5 => matches!(zone, Front | Centre) || (extended && zone == Wide),
        _ => false,
    }
}

pub(super) fn snap_targets(mask: u8, elevation: bool) -> Vec<Speaker> {
    use Zone::*;
    let mut targets = SpeakerLayout::Surround714.speakers();
    targets.extend([
        s([0.25, 0.5, 1.], Height, 0),
        s([0.75, 0.5, 1.], Height, 0),
        s([0.5, 0.25, 1.], Height, 0),
        s([0.5, 0.75, 1.], Height, 0),
        s([0.5, 0.5, 1.], Height, 0),
        s([0., 0., -1.], Bottom, 0),
        s([1., 0., -1.], Bottom, 0),
        s([0.5, 0., -1.], Bottom, 0),
        s([0.5, 1., 0.], BackCentre, 0),
        s([0., 0.2929, 0.], Wide, 0),
        s([1., 0.2929, 0.], Wide, 0),
    ]);
    targets.retain(|s| !excluded(s.zone, mask, elevation, true, 7));
    fn priority(p: [f64; 3]) -> usize {
        if p == [0.5, 0., 0.] {
            0
        } else if p == [0.5, 0., 1.] {
            1
        } else if p == [0.5, 0., -1.] {
            2
        } else {
            3
        }
    }
    targets.sort_by(|a, b| {
        priority(a.position)
            .cmp(&priority(b.position))
            .then_with(|| b.position[2].total_cmp(&a.position[2]))
            .then_with(|| b.position[1].total_cmp(&a.position[1]))
            .then_with(|| a.position[0].total_cmp(&b.position[0]))
    });
    targets
}
