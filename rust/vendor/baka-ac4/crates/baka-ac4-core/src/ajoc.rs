//! A-JOC side-information transport (ETSI TS 103 190-2, clauses 6.2.5/6.2.8).
//! These parameters describe reconstruction; parsing them does not render audio.

use crate::ajoc_tables::*;
use crate::bitreader::BitReader;
use crate::error::{Result, invalid};
use crate::vlc::Vlc;
use std::sync::OnceLock;

pub mod common;
pub mod decorrelation;
pub mod oamd;
pub mod reconstruction;
pub mod render;
pub(crate) mod signals;
pub mod stereo;

/// One reconstruction parameter update, in QMF slots.
#[derive(Clone, Debug)]
pub struct DataPoint {
    pub start: u8,
    pub ramp: u8,
}

/// Huffman-decoded parameters for one input-to-object matrix element.
#[derive(Clone, Debug)]
pub struct MatrixElement {
    /// Time deltas reference the previous data point, including across frames.
    pub time_delta: bool,
    /// F0 followed by modulo-frequency deltas, or signed time deltas.
    pub values: Vec<i16>,
    /// Differentially reconstructed and uniformly dequantized band gains.
    pub gains: Vec<f32>,
}

/// Matrix data points for one reconstructed fullband object.
#[derive(Clone, Debug, Default)]
pub struct ObjectMatrix {
    pub present: bool,
    pub bands: usize,
    pub coarse: bool,
    /// [data point][input]; None means a zero coefficient, not reuse.
    pub dry: Vec<Vec<Option<MatrixElement>>>,
    pub wet: Vec<Vec<Option<MatrixElement>>>,
}

/// A complete A-JOC reconstruction payload. LFE is separate from the matrices.
#[derive(Clone, Debug, Default)]
pub struct AjocMetadata {
    /// Last shared rendering controls for the selected substream group.
    pub common: Option<common::CommonData>,
    pub decorrelators: Vec<bool>,
    pub points: Vec<DataPoint>,
    pub objects: Vec<ObjectMatrix>,
    /// Downmix/upmix metadata block counts, including LFE when present.
    pub downmix_blocks: usize,
    pub upmix_blocks: usize,
    /// Object-major timed property updates, LFE first when present.
    pub downmix_metadata: Vec<Vec<oamd::ObjectUpdate>>,
    pub upmix_metadata: Vec<Vec<oamd::ObjectUpdate>>,
    /// Exact number of side-information bits consumed, excluding byte padding.
    pub bits: usize,
    /// Bits left inside audio_size after the side-information syntax.
    pub padding_bits: usize,
}

#[derive(Clone, Default)]
pub(crate) struct History {
    pub common: Option<common::CommonData>,
    dialogue: usize,
    matrices: Vec<PreviousMatrix>,
    common_oamd: Vec<oamd::ObjectTiming>,
    downmix_oamd: Vec<oamd::ObjectState>,
    upmix_oamd: Vec<oamd::ObjectState>,
}

pub(crate) fn common_timing(
    gb: &mut BitReader<'_>,
    end: usize,
    history: &mut History,
) -> Result<()> {
    if end
        > gb.bits_count()
            .saturating_add(gb.bits_left().max(0) as usize)
    {
        return Err(invalid("truncated shared A-JOC metadata"));
    }
    let mut r = Reader { gb, end };
    let common = if r.flag()? { Some(r.common()?) } else { None };
    let timing = if r.flag()? { r.timing()? } else { Vec::new() };
    if let Some(common) = common {
        history.common = Some(common);
    }
    history.common_oamd = timing;
    Ok(())
}

#[derive(Clone, Default)]
struct PreviousMatrix {
    bands: usize,
    coarse: bool,
    dry: Vec<Vec<i16>>,
    wet: Vec<Vec<i16>>,
}

fn reconstruct(
    rows: &mut [Vec<Option<MatrixElement>>],
    previous: &mut Vec<Vec<i16>>,
    bands: usize,
    coarse: bool,
    wet: bool,
    compatible: bool,
) -> Result<()> {
    let nquant: i16 = match (wet, coarse) {
        (false, false) => 101,
        (false, true) => 51,
        (true, false) => 41,
        (true, true) => 21,
    };
    let center = (nquant - 1) / 2;
    let step = if coarse {
        205.0 / 1024.0
    } else {
        205.0 / 2048.0
    };
    for (dp, row) in rows.iter_mut().enumerate() {
        let mut next = Vec::with_capacity(row.len());
        for (input, element) in row.iter_mut().enumerate() {
            let mut quantized = vec![center; bands];
            if let Some(element) = element {
                if element.time_delta {
                    let old = previous
                        .get(input)
                        .filter(|q| q.len() == bands && (compatible || dp > 0))
                        .ok_or_else(|| invalid("A-JOC time delta without compatible history"))?;
                    for ((q, &old), &delta) in quantized.iter_mut().zip(old).zip(&element.values) {
                        *q = old + delta;
                    }
                } else {
                    let mut value = 0;
                    for (q, &delta) in quantized.iter_mut().zip(&element.values) {
                        value = (value + delta).rem_euclid(nquant);
                        *q = value;
                    }
                }
                if quantized.iter().any(|&q| q < 0 || q >= nquant) {
                    return Err(invalid("A-JOC time delta outside quantizer range"));
                }
                element.gains = quantized
                    .iter()
                    .map(|&q| (q - center) as f32 * step)
                    .collect();
            }
            next.push(quantized);
        }
        *previous = next;
    }
    Ok(())
}

struct Reader<'a, 'b> {
    gb: &'b mut BitReader<'a>,
    end: usize,
}

impl Reader<'_, '_> {
    fn get(&mut self, n: u32) -> Result<u32> {
        if self.gb.bits_count().saturating_add(n as usize) > self.end {
            return Err(invalid("truncated A-JOC metadata"));
        }
        Ok(self.gb.get_bits(n))
    }

    fn flag(&mut self) -> Result<bool> {
        Ok(self.get(1)? != 0)
    }

    fn skip(&mut self, n: usize) -> Result<()> {
        if n > self.end.saturating_sub(self.gb.bits_count()) {
            return Err(invalid("truncated A-JOC extension"));
        }
        self.gb.skip_bits_long(n as i64);
        Ok(())
    }

    fn prefix(&mut self) -> Result<u32> {
        if self.flag()? {
            Ok(2 + self.get(1)?)
        } else {
            Ok(0)
        }
    }

    fn variable(&mut self, n: u32) -> Result<usize> {
        let mut value = 0usize;
        for _ in 0..8 {
            value = value
                .checked_add(self.get(n)? as usize)
                .ok_or_else(|| invalid("A-JOC extension length overflow"))?;
            if !self.flag()? {
                return Ok(value);
            }
            value = value
                .checked_add(1)
                .and_then(|v| v.checked_shl(n))
                .ok_or_else(|| invalid("A-JOC extension length overflow"))?;
        }
        Err(invalid("A-JOC extension length overflow"))
    }

    fn matrix(
        &mut self,
        wet: bool,
        coarse: bool,
        bands: usize,
        df_only: bool,
    ) -> Result<MatrixElement> {
        let dt = !df_only && self.flag()?;
        let books = &codebooks()[usize::from(wet) * 2 + usize::from(coarse)];
        let offset = if wet {
            if coarse { 20 } else { 40 }
        } else if coarse {
            50
        } else {
            100
        };
        let mut values = Vec::with_capacity(bands);
        for band in 0..bands {
            let book = if dt { 2 } else { usize::from(band != 0) };
            let symbol = books[book].decode(self.gb)?;
            if self.gb.bits_count() > self.end {
                return Err(invalid("truncated A-JOC coefficient"));
            }
            values.push((symbol - if dt { offset } else { 0 }) as i16);
        }
        Ok(MatrixElement {
            time_delta: dt,
            values,
            gains: Vec::new(),
        })
    }
}

fn codebooks() -> &'static [[Vlc; 3]; 4] {
    static BOOKS: OnceLock<[[Vlc; 3]; 4]> = OnceLock::new();
    BOOKS.get_or_init(|| {
        macro_rules! books {
            ($l0:ident,$c0:ident,$lf:ident,$cf:ident,$lt:ident,$ct:ident) => {
                [
                    Vlc::new(&$l0, &$c0).expect("normative A-JOC F0"),
                    Vlc::new(&$lf, &$cf).expect("normative A-JOC DF"),
                    Vlc::new(&$lt, &$ct).expect("normative A-JOC DT"),
                ]
            };
        }
        [
            books!(
                AJOC_HCB_DRY_FINE_F0_LEN,
                AJOC_HCB_DRY_FINE_F0_CW,
                AJOC_HCB_DRY_FINE_DF_LEN,
                AJOC_HCB_DRY_FINE_DF_CW,
                AJOC_HCB_DRY_FINE_DT_LEN,
                AJOC_HCB_DRY_FINE_DT_CW
            ),
            books!(
                AJOC_HCB_DRY_COARSE_F0_LEN,
                AJOC_HCB_DRY_COARSE_F0_CW,
                AJOC_HCB_DRY_COARSE_DF_LEN,
                AJOC_HCB_DRY_COARSE_DF_CW,
                AJOC_HCB_DRY_COARSE_DT_LEN,
                AJOC_HCB_DRY_COARSE_DT_CW
            ),
            books!(
                AJOC_HCB_WET_FINE_F0_LEN,
                AJOC_HCB_WET_FINE_F0_CW,
                AJOC_HCB_WET_FINE_DF_LEN,
                AJOC_HCB_WET_FINE_DF_CW,
                AJOC_HCB_WET_FINE_DT_LEN,
                AJOC_HCB_WET_FINE_DT_CW
            ),
            books!(
                AJOC_HCB_WET_COARSE_F0_LEN,
                AJOC_HCB_WET_COARSE_F0_CW,
                AJOC_HCB_WET_COARSE_DF_LEN,
                AJOC_HCB_WET_COARSE_DF_CW,
                AJOC_HCB_WET_COARSE_DT_LEN,
                AJOC_HCB_WET_COARSE_DT_CW
            ),
        ]
    })
}

pub(crate) fn parse(
    gb: &mut BitReader<'_>,
    end: usize,
    downmix: usize,
    upmix: usize,
    lfe: bool,
    iframe: bool,
    history: &mut History,
) -> Result<AjocMetadata> {
    // A damaged payload must not leave partially updated dialogue/matrix state.
    let mut pending = history.clone();
    let result = parse_inner(gb, end, downmix, upmix, lfe, iframe, &mut pending)?;
    *history = pending;
    Ok(result)
}

#[allow(clippy::too_many_arguments)]
fn parse_inner(
    gb: &mut BitReader<'_>,
    end: usize,
    downmix: usize,
    upmix: usize,
    lfe: bool,
    iframe: bool,
    history: &mut History,
) -> Result<AjocMetadata> {
    if !(1..=16).contains(&downmix)
        || !(1..=64).contains(&upmix)
        || end
            > gb.bits_count()
                .saturating_add(gb.bits_left().max(0) as usize)
        || gb.bits_count() > end
    {
        return Err(invalid("A-JOC metadata dimensions or boundary"));
    }
    let start = gb.bits_count();
    let mut r = Reader { gb, end };
    let dmx_blocks = if r.flag()? {
        r.timing()?
    } else {
        history.common_oamd.clone()
    };
    if iframe && dmx_blocks.is_empty() {
        return Err(invalid("missing A-JOC iframe object timing"));
    }
    let downmix_metadata =
        r.objects(downmix, lfe, &dmx_blocks, iframe, &mut history.downmix_oamd)?;
    if r.flag()? {
        let bytes = r.variable(3)? + 1;
        r.skip(bytes * 8)?;
    }
    let ndecorr = r.get(3)? as usize;
    let decorrelators = (0..ndecorr).map(|_| r.flag()).collect::<Result<Vec<_>>>()?;
    let mut objects = (0..upmix)
        .map(|_| {
            Ok(ObjectMatrix {
                present: r.flag()?,
                ..Default::default()
            })
        })
        .collect::<Result<Vec<_>>>()?;
    let npoints = r.get(2)? as usize;
    if npoints > 2 {
        return Err(invalid("reserved A-JOC data point count"));
    }
    let points = (0..npoints)
        .map(|_| {
            Ok(DataPoint {
                start: r.get(5)? as u8,
                ramp: r.get(6)? as u8 + 1,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    let mut masks = Vec::with_capacity(upmix);
    for object in &mut objects {
        let mut dry = vec![false; downmix];
        let mut wet = vec![false; ndecorr];
        if object.present && npoints != 0 {
            object.bands = [23, 15, 12, 9, 7, 5, 3, 1][r.get(3)? as usize];
            object.coarse = r.flag()?;
            let sparse = r.flag()?;
            for present in &mut dry {
                *present = !sparse || r.flag()?;
            }
            for (present, &enabled) in wet.iter_mut().zip(&decorrelators) {
                // Dense coding transmits every decorrelator, including disabled ones.
                *present = !sparse || (enabled && r.flag()?);
            }
        }
        masks.push((dry, wet));
    }
    let nodt = r.flag()?;
    for (object, (dry, wet)) in objects.iter_mut().zip(masks) {
        if !object.present {
            continue;
        }
        for dp in 0..npoints {
            let mut read = |mask: &[bool], is_wet| {
                mask.iter()
                    .map(|&present| {
                        if present {
                            r.matrix(is_wet, object.coarse, object.bands, dp == 0 && nodt)
                                .map(Some)
                        } else {
                            Ok(None)
                        }
                    })
                    .collect::<Result<Vec<_>>>()
            };
            object.dry.push(read(&dry, false)?);
            object.wet.push(read(&wet, true)?);
        }
    }
    // Parse dialogue enhancement coefficients even when enhancement is off.
    let cfg = r.flag()?;
    let keep = r.flag()?;
    if cfg {
        r.get(2)?;
        history.dialogue = 0;
        for _ in 0..upmix {
            history.dialogue += usize::from(r.flag()?);
        }
    }
    if !keep {
        for _ in 0..history.dialogue * downmix {
            if r.flag()? && r.get(3)? != 7 {
                r.get(1)?;
            }
        }
    }
    let umx_blocks = if r.flag()? {
        r.timing()?
    } else {
        if r.flag()? {
            dmx_blocks.clone()
        } else {
            history.common_oamd.clone()
        }
    };
    if iframe && umx_blocks.is_empty() {
        return Err(invalid("missing A-JOC iframe upmix timing"));
    }
    let upmix_metadata = r.objects(upmix, lfe, &umx_blocks, iframe, &mut history.upmix_oamd)?;
    history.matrices.resize_with(upmix, PreviousMatrix::default);
    for (object, previous) in objects.iter_mut().zip(&mut history.matrices) {
        if !object.present || npoints == 0 {
            continue;
        }
        let compatible = previous.bands == object.bands && previous.coarse == object.coarse;
        reconstruct(
            &mut object.dry,
            &mut previous.dry,
            object.bands,
            object.coarse,
            false,
            compatible,
        )?;
        reconstruct(
            &mut object.wet,
            &mut previous.wet,
            object.bands,
            object.coarse,
            true,
            compatible,
        )?;
        previous.bands = object.bands;
        previous.coarse = object.coarse;
    }
    Ok(AjocMetadata {
        common: history.common.clone(),
        decorrelators,
        points,
        objects,
        downmix_blocks: dmx_blocks.len(),
        upmix_blocks: umx_blocks.len(),
        downmix_metadata,
        upmix_metadata,
        bits: r.gb.bits_count() - start,
        padding_bits: end - r.gb.bits_count(),
    })
}

#[cfg(test)]
mod tests;
