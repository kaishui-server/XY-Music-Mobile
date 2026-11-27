//! External LSF codebooks and inverse frequency-domain envelope shaping.
use crate::{Error, dsp::FftPlan};

// Entry count and vector width, high-rate books followed by low-rate books.
const BOOKS: [(usize, usize); 12] = [
    (256, 9),
    (256, 7),
    (128, 3),
    (128, 3),
    (64, 3),
    (32, 3),
    (32, 4),
    (256, 9),
    (256, 7),
    (128, 5),
    (128, 4),
    (64, 7),
];
const BANDS: [usize; 50] = [
    0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 88, 96, 108, 120, 132, 144, 160,
    176, 196, 216, 240, 264, 292, 320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704,
    736, 768, 800, 832, 864, 896, 928, 1024,
];

#[derive(Clone, Debug)]
pub struct LsfCodebooks {
    mean: [f32; 16],
    books: Vec<Vec<f32>>,
    fft: FftPlan,
}
impl LsfCodebooks {
    /// Exact AV3LSF01 asset: `mean[16]`, then twelve fixed-shape f32 LE tables.
    /// Codebooks are supplied by the caller and are not embedded in the crate.
    pub fn parse(bytes: &[u8]) -> Result<Self, Error> {
        let count = 16 + BOOKS.iter().map(|&(n, w)| n * w).sum::<usize>();
        if bytes.len() != 8 + count * 4 {
            return Err(Error::Invalid("LSF asset length"));
        }
        if &bytes[..8] != b"AV3LSF01" {
            return Err(Error::Invalid("LSF asset magic"));
        }
        let values: Vec<f32> = bytes[8..]
            .as_chunks::<4>()
            .0
            .iter()
            .map(|v| f32::from_le_bytes(*v))
            .collect();
        if values.iter().any(|v| !v.is_finite() || v.abs() > 48000.0) {
            return Err(Error::Invalid("LSF asset value"));
        }
        let mean: [f32; 16] = values[..16].try_into().unwrap();
        if mean.iter().any(|&v| !(0.0..24000.0).contains(&v))
            || mean.windows(2).any(|w| w[0] >= w[1])
        {
            return Err(Error::Invalid("LSF mean"));
        }
        let mut position = 16;
        let mut books = Vec::new();
        for (n, w) in BOOKS {
            books.push(values[position..position + n * w].to_vec());
            position += n * w;
        }
        Ok(Self {
            mean,
            books,
            fft: FftPlan::new(512),
        })
    }

    pub fn frequencies(&self, indices: &[u8]) -> Result<[f32; 16], Error> {
        let (base, widths): (usize, &[usize]) = match indices.len() {
            7 => (0, &[3, 3, 3, 3, 4]),
            5 => (7, &[5, 4, 7]),
            _ => return Err(Error::Invalid("LSF index count")),
        };
        let mut frequencies = [0.0; 16];
        for (book, offset) in [(base, 0), (base + 1, 9)] {
            let width = BOOKS[book].1;
            let index = usize::from(indices[book - base]);
            if index >= BOOKS[book].0 {
                return Err(Error::Invalid("LSF codebook index"));
            }
            frequencies[offset..offset + width]
                .copy_from_slice(&self.books[book][index * width..(index + 1) * width]);
        }
        let mut offset = 0;
        for (i, &width) in widths.iter().enumerate() {
            let book = base + 2 + i;
            let index = usize::from(indices[i + 2]);
            if index >= BOOKS[book].0 {
                return Err(Error::Invalid("LSF codebook index"));
            }
            for j in 0..width {
                frequencies[offset + j] += self.books[book][index * width + j];
            }
            offset += width;
        }
        let mut lower = 50.0;
        for (value, &mean) in frequencies.iter_mut().zip(&self.mean) {
            *value = (*value + mean).max(lower);
            lower = *value + 50.0;
        }
        let mut upper = 23950.0;
        for value in frequencies.iter_mut().rev() {
            *value = value.min(upper);
            upper = *value - 50.0;
        }
        Ok(frequencies)
    }

    pub fn gains(&self, indices: &[u8]) -> Result<[f32; 1024], Error> {
        let frequencies = self.frequencies(indices)?;
        let mut lsp = [0.0; 16];
        for (out, &hz) in lsp.iter_mut().zip(&frequencies) {
            *out = f64::from(hz * std::f32::consts::PI / 24000.0).cos() as f32;
        }
        let lpc = lsp_polynomial(&lsp);
        let (mut real, mut imag) = ([0.0; 512], [0.0; 512]);
        let mut weight = 1.0;
        for i in 0..17 {
            let angle = f64::from(i as f32 * std::f32::consts::PI / 512.0);
            let value = lpc[i] * weight;
            real[i] = (f64::from(value) * angle.cos()) as f32;
            imag[i] = (-f64::from(value) * angle.sin()) as f32;
            weight *= 0.94;
        }
        self.fft.run(&mut real, &mut imag, false);
        let mut raw = [0.0; 257];
        for i in 0..257 {
            let norm = real[i] * real[i] + imag[i] * imag[i];
            raw[i] = (1.0 / f64::from(norm).sqrt()) as f32;
        }
        let mut interpolated = [0.0; 1024];
        for i in 0..256 {
            let step = (raw[i + 1] - raw[i]) / 4.0;
            for j in 0..4 {
                interpolated[i * 4 + j] = raw[i] + j as f32 * step;
            }
        }
        let mut gains = [0.0; 1024];
        for band in BANDS.windows(2) {
            let mut sum = 0.0;
            for &v in &interpolated[band[0]..band[1]] {
                sum += v;
            }
            let gain = sum / (band[1] - band[0]) as f32;
            gains[band[0]..band[1]].fill(gain);
        }
        if gains.iter().any(|v| !v.is_finite() || *v <= 0.0) {
            return Err(Error::Invalid("LSF shaping gain"));
        }
        Ok(gains)
    }

    pub fn apply(&self, spectrum: &mut [f32; 1024], indices: &[u8]) -> Result<(), Error> {
        let gains = self.gains(indices)?;
        let mut result = [0.0; 1024];
        for i in 0..1024 {
            result[i] = spectrum[i] * gains[i];
        }
        if result.iter().any(|v| !v.is_finite()) {
            return Err(Error::Invalid("shaped spectrum"));
        }
        *spectrum = result;
        Ok(())
    }
}

fn lsp_polynomial(lsp: &[f32; 16]) -> [f32; 17] {
    let mut polynomials = [[0.0f32; 9]; 2];
    for (parity, poly) in polynomials.iter_mut().enumerate() {
        poly[0] = 1.0;
        poly[1] = -2.0 * lsp[parity];
        for order in 2..=8 {
            let coefficient = -2.0 * lsp[(order - 1) * 2 + parity];
            poly[order] = coefficient * poly[order - 1] + 2.0 * poly[order - 2];
            for j in (2..order).rev() {
                poly[j] += coefficient * poly[j - 1] + poly[j - 2];
            }
            poly[1] += coefficient;
        }
        for j in (1..=8).rev() {
            if parity == 0 {
                poly[j] += poly[j - 1];
            } else {
                poly[j] -= poly[j - 1];
            }
        }
    }
    let mut lpc = [0.0; 17];
    lpc[0] = 1.0;
    for i in 1..=8 {
        lpc[i] = 0.5 * (polynomials[0][i] + polynomials[1][i]);
        lpc[17 - i] = 0.5 * (polynomials[0][i] - polynomials[1][i]);
    }
    lpc
}
