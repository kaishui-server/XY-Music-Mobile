use super::{
    PropagationRenderer, PropagationTarget,
    convolution::{BLOCK, Convolver, Kernel},
};
use crate::Error;
use std::sync::Arc;

const TAPS: usize = 1023;
const CENTRE: usize = TAPS / 2;

/// Explicit seven crossover frequencies separating eight material bands.
/// No metadata preset or band-frequency interpretation is inferred here.
#[derive(Clone, Debug)]
pub struct AcousticBandLayout {
    sample_rate: u32,
    crossovers: [f64; 7],
    low_pass: Arc<[[f64; TAPS]; 7]>,
}
impl AcousticBandLayout {
    /// Prepare complementary windowed-sinc filters outside the callback.
    /// Crossovers are strictly increasing, in `[1, sample_rate/2-1]` Hz.
    pub fn new(sample_rate: u32, crossovers: [f64; 7]) -> Result<Self, Error> {
        if !(8000..=192000).contains(&sample_rate)
            || crossovers
                .iter()
                .any(|f| !f.is_finite() || !(1.0..=f64::from(sample_rate) / 2. - 1.).contains(f))
            || crossovers.windows(2).any(|v| v[0] >= v[1])
        {
            return Err(Error::Invalid("acoustic band crossover configuration"));
        }
        let mut low_pass = Box::new([[0.; TAPS]; 7]);
        for (taps, &frequency) in low_pass.iter_mut().zip(&crossovers) {
            let cutoff = frequency / f64::from(sample_rate);
            for (i, tap) in taps.iter_mut().enumerate() {
                let n = i as f64 - CENTRE as f64;
                let sinc = if i == CENTRE {
                    2. * cutoff
                } else {
                    (std::f64::consts::TAU * cutoff * n).sin() / (std::f64::consts::PI * n)
                };
                let window = 0.5 * (1. + (std::f64::consts::PI * n / CENTRE as f64).cos());
                *tap = sinc * window;
            }
            let dc: f64 = taps.iter().sum();
            if !dc.is_finite() || dc.abs() < 1e-12 {
                return Err(Error::Invalid("acoustic band FIR normalization"));
            }
            for tap in taps {
                *tap /= dc;
            }
        }
        Ok(Self {
            sample_rate,
            crossovers,
            low_pass: Arc::from(low_pass),
        })
    }
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }
    pub fn crossovers_hz(&self) -> [f64; 7] {
        self.crossovers
    }
}

/// Prepared real, symmetric pressure FIR for eight material bands. Each gain
/// is in `[0,1]`. Adjacent low-pass differences form complementary bands; equal
/// gains collapse exactly to a scaled unit impulse at sample511. Finite FIR
/// transition bands and small ringing remain; this is not an ideal brick wall.
#[derive(Clone, Debug)]
pub struct MaterialFir {
    sample_rate: u32,
    pressure: [f64; 8],
    taps: Arc<[f32; TAPS]>,
    kernel: Arc<Kernel>,
}
impl MaterialFir {
    pub const DELAY_SAMPLES: usize = CENTRE;
    pub const FILTER_LENGTH: usize = TAPS;
    pub fn new(layout: &AcousticBandLayout, pressure: [f64; 8]) -> Result<Self, Error> {
        if pressure
            .iter()
            .any(|g| !g.is_finite() || !(0.0..=1.0).contains(g))
        {
            return Err(Error::Invalid("material band pressure gain"));
        }
        let mut taps = [0f32; TAPS];
        for (i, tap) in taps.iter_mut().enumerate() {
            let mut value = if i == CENTRE { pressure[7] } else { 0. };
            for band in 0..7 {
                value += (pressure[band] - pressure[band + 1]) * layout.low_pass[band][i];
            }
            *tap = value as f32;
        }
        if taps.iter().map(|v| v.abs()).sum::<f32>() > 64. {
            return Err(Error::Invalid("material FIR pressure bound"));
        }
        let kernel = Kernel::from_taps(&taps);
        Ok(Self {
            sample_rate: layout.sample_rate,
            pressure,
            taps: Arc::new(taps),
            kernel,
        })
    }
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }
    pub fn pressure_gains(&self) -> [f64; 8] {
        self.pressure
    }
    pub fn coefficients(&self) -> &[f32] {
        self.taps.as_slice()
    }
}

/// Independent fixed material filters for 1..9 interleaved propagation paths.
/// Plan/kernels may be shared; each instance owns independent overlap history.
#[derive(Clone, Debug)]
pub struct MaterialFilter {
    filters: Vec<MaterialFir>,
    paths: Vec<PathFilter>,
    input: [f32; BLOCK],
    output: [f32; BLOCK],
}
#[derive(Clone, Debug)]
struct PathFilter {
    convolver: Option<Convolver>,
    delay: Vec<f32>,
    position: usize,
}
impl MaterialFilter {
    pub const DELAY_SAMPLES: usize = CENTRE;
    pub const TAIL_SAMPLES: usize = TAPS - 1;
    pub fn new(filters: &[MaterialFir]) -> Result<Self, Error> {
        if !(1..=9).contains(&filters.len())
            || filters
                .iter()
                .any(|f| f.sample_rate != filters[0].sample_rate)
        {
            return Err(Error::Invalid("material filter path count or rate"));
        }
        Ok(Self {
            filters: filters.to_vec(),
            paths: filters
                .iter()
                .map(|f| {
                    if f.pressure.iter().all(|g| *g == f.pressure[0]) {
                        PathFilter {
                            convolver: None,
                            delay: vec![0.; CENTRE],
                            position: 0,
                        }
                    } else {
                        PathFilter {
                            convolver: Some(Convolver::new(Arc::clone(&f.kernel))),
                            delay: Vec::new(),
                            position: 0,
                        }
                    }
                })
                .collect(),
            input: [0.; BLOCK],
            output: [0.; BLOCK],
        })
    }
    pub fn paths(&self) -> usize {
        self.filters.len()
    }
    pub fn filters(&self) -> &[MaterialFir] {
        &self.filters
    }
    pub fn sample_rate(&self) -> u32 {
        self.filters[0].sample_rate
    }
    fn validate_output(&self, output: &[f32]) -> Result<(), Error> {
        if output.len() != BLOCK * self.paths() {
            return Err(Error::Invalid("material filter output length"));
        }
        Ok(())
    }
    pub fn process(&mut self, input: &[f32], output: &mut [f32]) -> Result<(), Error> {
        self.validate_output(output)?;
        if input.len() != output.len() || input.iter().any(|v| !v.is_finite() || v.abs() > 256.) {
            return Err(Error::Invalid("material filter PCM"));
        }
        self.apply(Some(input), output);
        Ok(())
    }
    pub fn process_silence(&mut self, output: &mut [f32]) -> Result<(), Error> {
        self.validate_output(output)?;
        self.apply(None, output);
        Ok(())
    }
    fn apply(&mut self, input: Option<&[f32]>, output: &mut [f32]) {
        let paths = self.paths();
        for (path, state) in self.paths.iter_mut().enumerate() {
            if state.convolver.is_none() {
                let gain = self.filters[path].pressure[0] as f32;
                for sample in 0..BLOCK {
                    output[sample * paths + path] = state.delay[state.position];
                    state.delay[state.position] =
                        input.map_or(0., |v| v[sample * paths + path]) * gain;
                    state.position = (state.position + 1) % CENTRE;
                }
                continue;
            }
            for (i, target) in self.input.iter_mut().enumerate() {
                *target = input.map_or(0., |v| v[i * paths + path]);
            }
            state
                .convolver
                .as_mut()
                .unwrap()
                .process(&self.input, &mut self.output);
            for (i, &value) in self.output.iter().enumerate() {
                output[i * paths + path] = value;
            }
        }
    }
    pub fn reset(&mut self) {
        for path in &mut self.paths {
            if let Some(convolver) = &mut path.convolver {
                convolver.reset();
            }
            path.delay.fill(0.);
            path.position = 0;
        }
        self.input.fill(0.);
        self.output.fill(0.);
    }
}

/// Mono source propagation followed by each fixed path's spectral material.
/// Source PCM/updates retain PropagationRenderer semantics. Static path slots
/// must keep the same material for the lifetime of this prepared renderer.
#[derive(Clone, Debug)]
pub struct FilteredPropagationRenderer {
    propagation: PropagationRenderer,
    material: MaterialFilter,
    bus: Vec<f32>,
}
impl FilteredPropagationRenderer {
    pub const MATERIAL_DELAY_SAMPLES: usize = CENTRE;
    pub fn new(
        sample_rate: u32,
        maximum_delay_seconds: f64,
        targets: &[PropagationTarget],
        filters: &[MaterialFir],
    ) -> Result<Self, Error> {
        let material = MaterialFilter::new(filters)?;
        if material.sample_rate() != sample_rate || targets.len() != filters.len() {
            return Err(Error::Invalid("filtered propagation path count or rate"));
        }
        let propagation = PropagationRenderer::new(sample_rate, maximum_delay_seconds, targets)?;
        Ok(Self {
            propagation,
            material,
            bus: vec![0.; BLOCK * filters.len()],
        })
    }
    pub fn paths(&self) -> usize {
        self.propagation.paths()
    }
    pub fn targets(&self) -> &[PropagationTarget] {
        self.propagation.targets()
    }
    pub fn filters(&self) -> &[MaterialFir] {
        self.material.filters()
    }
    pub fn tail_samples(&self) -> usize {
        self.propagation.tail_samples() + MaterialFilter::TAIL_SAMPLES
    }
    pub fn set_targets(
        &mut self,
        targets: &[PropagationTarget],
        jumps: &[bool],
    ) -> Result<(), Error> {
        self.propagation.set_targets(targets, jumps)
    }
    pub fn process(&mut self, input: &[f32], output: &mut [f32]) -> Result<(), Error> {
        self.material.validate_output(output)?;
        self.propagation.process(input, &mut self.bus)?;
        // Scheduled contributions can exceed the public source bound. They
        // remain finite: <=384001 emissions, source256, gain16, two branches;
        // the material L1 bound64 keeps the internal filtered result finite.
        self.material.apply(Some(&self.bus), output);
        Ok(())
    }
    pub fn process_silence(&mut self, output: &mut [f32]) -> Result<(), Error> {
        self.material.validate_output(output)?;
        self.propagation.process_silence(&mut self.bus)?;
        self.material.apply(Some(&self.bus), output);
        Ok(())
    }
    pub fn reset(&mut self) {
        self.propagation.reset();
        self.material.reset();
        self.bus.fill(0.);
    }
}
