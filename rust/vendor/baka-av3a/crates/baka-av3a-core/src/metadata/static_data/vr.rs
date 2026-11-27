use super::{flag, flags, read};
use crate::{BitReader, Error};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EqBand {
    pub kind: u8,
    pub frequency: u8,
    pub upper_q: bool,
    pub q: u8,
    pub gain: u8,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AudioEffects {
    pub chain: Option<u8>,
    pub eq: Vec<EqBand>,
    /// Attack/release/threshold/pre-gain/post-gain/ratio indices.
    pub dynamics: Option<[u8; 6]>,
    pub gain: Option<u8>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RenderInfo {
    pub target_device: bool,
    pub hrtf: u8,
    pub headphone: [u8; 16],
    pub effects: AudioEffects,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Surface {
    pub material: u8,
    /// Eight absorption/scattering pairs for custom material 31.
    pub material_coefficients: Option<[[u8; 2]; 8]>,
    pub vertices: Vec<[u8; 3]>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AcousticEnvironment {
    pub early_gain: Option<u8>,
    pub late_gain: Option<u8>,
    pub reverb_type: u8,
    pub low_frequency_processing: bool,
    pub convolution_type: Option<u8>,
    pub surfaces: Vec<Surface>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VrExtension {
    pub ambisonic_order: u8,
    pub environment: Option<AcousticEnvironment>,
    pub render: Option<RenderInfo>,
}
fn effects(reader: &mut BitReader<'_>) -> Result<AudioEffects, Error> {
    let [has_eq, has_dynamics, has_gain] = flags(reader)?;
    let chain = if has_eq || has_dynamics || has_gain {
        Some(read(reader, 3)?.min(5))
    } else {
        None
    };
    let mut eq = Vec::new();
    if has_eq {
        for _ in 0..=read(reader, 4)?.min(10) {
            eq.push(EqBand {
                kind: read(reader, 3)?,
                frequency: read(reader, 7)?,
                upper_q: flag(reader)?,
                q: read(reader, 6)?,
                gain: read(reader, 7)?,
            });
        }
    }
    let dynamics = if has_dynamics {
        Some([
            read(reader, 4)?,
            read(reader, 4)?,
            read(reader, 7)?,
            read(reader, 7)?,
            read(reader, 7)?,
            read(reader, 7)?,
        ])
    } else {
        None
    };
    let gain = if has_gain {
        Some(read(reader, 7)?)
    } else {
        None
    };
    Ok(AudioEffects {
        chain,
        eq,
        dynamics,
        gain,
    })
}
fn render(reader: &mut BitReader<'_>) -> Result<RenderInfo, Error> {
    let target_device = flag(reader)?;
    let hrtf = read(reader, 4)?;
    let mut headphone = [0; 16];
    for value in &mut headphone {
        *value = read(reader, 7)?;
    }
    Ok(RenderInfo {
        target_device,
        hrtf,
        headphone,
        effects: effects(reader)?,
    })
}
fn environment(reader: &mut BitReader<'_>) -> Result<AcousticEnvironment, Error> {
    let [early, late] = flags(reader)?;
    let reverb_type = read(reader, 2)?;
    let early_gain = if early { Some(read(reader, 7)?) } else { None };
    let late_gain = if late { Some(read(reader, 7)?) } else { None };
    let low_frequency_processing = flag(reader)?;
    let convolution_type = if reverb_type == 2 {
        Some(read(reader, 5)?)
    } else {
        None
    };
    let count = usize::from(read(reader, 3)?) + 1;
    let mut surfaces = Vec::new();
    for _ in 0..count {
        let material = read(reader, 5)?;
        let material_coefficients = if material == 31 {
            let mut values = [[0; 2]; 8];
            for pair in &mut values {
                *pair = [read(reader, 7)?, read(reader, 7)?];
            }
            Some(values)
        } else {
            None
        };
        let vertices_count =
            (usize::from(read(reader, 5)?) + 1).clamp(8usize.div_ceil(count), 36 / count);
        let mut vertices = Vec::new();
        for _ in 0..vertices_count {
            vertices.push([read(reader, 7)?, read(reader, 7)?, read(reader, 7)?]);
        }
        surfaces.push(Surface {
            material,
            material_coefficients,
            vertices,
        });
    }
    Ok(AcousticEnvironment {
        early_gain,
        late_gain,
        reverb_type,
        low_frequency_processing,
        convolution_type,
        surfaces,
    })
}
impl VrExtension {
    pub(super) fn parse(reader: &mut BitReader<'_>) -> Result<Self, Error> {
        let [has_environment, has_render] = flags(reader)?;
        let ambisonic_order = read(reader, 3)?;
        let environment = if has_environment {
            Some(environment(reader)?)
        } else {
            None
        };
        let render = if has_render {
            Some(render(reader)?)
        } else {
            None
        };
        Ok(Self {
            ambisonic_order,
            environment,
            render,
        })
    }
}
