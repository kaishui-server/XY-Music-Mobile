//! Kaiser-Bessel Derived (KBD) window generation.

/// Modified Bessel function of the first kind of order zero.
/// Minimax rational approximations on intervals, see
/// Blair and Edwards, Chalk River Report AECL-4928, 1974.
pub fn bessel_i0(x: f64) -> f64 {
    const P1: [f64; 15] = [
        -2.233_558_263_947_437_5e15,
        -5.505_036_967_301_842_5e14,
        -3.294_008_762_740_775e13,
        -8.492_510_124_711_416e11,
        -1.191_274_610_498_523_7e10,
        -1.031_306_670_873_798_1e8,
        -5.954_562_601_984_789e5,
        -2.412_519_587_604_19e3,
        -7.093_534_744_921_055,
        -1.545_397_779_178_685e-2,
        -2.517_264_467_068_897_6e-5,
        -3.051_722_645_045_107e-8,
        -2.684_344_857_346_848_4e-11,
        -1.598_222_667_565_318_5e-14,
        -5.248_786_662_794_57e-18,
    ];
    const Q1: [f64; 6] = [
        -2.233_558_263_947_437_5e15,
        7.885_869_256_675_101e12,
        -1.220_706_739_780_897_9e10,
        1.037_708_105_806_216_6e7,
        -4.852_756_017_996_277_5e3,
        1.0,
    ];
    const P2: [f64; 7] = [
        -2.221_026_223_330_657_3e-4,
        1.306_739_203_810_692_4e-2,
        -4.470_080_572_117_445e-1,
        5.567_451_837_124_076,
        -2.351_794_567_923_948e1,
        3.161_132_281_870_113e1,
        -9.609_002_196_865_617,
    ];
    const Q2: [f64; 8] = [
        -5.519_433_023_100_548e-4,
        3.254_769_759_481_962e-2,
        -1.115_175_918_874_131_3,
        1.398_259_535_389_285_1e1,
        -6.022_800_206_674_334e1,
        8.553_956_325_801_293e1,
        -3.144_669_027_513_549e1,
        1.0,
    ];

    fn eval_poly(c: &[f64], x: f64) -> f64 {
        // Horner scheme from the highest-order coefficient down.
        let mut r = c[c.len() - 1];
        for &ci in c[..c.len() - 1].iter().rev() {
            r = r * x + ci;
        }
        r
    }

    if x == 0.0 {
        return 1.0;
    }
    let x = x.abs();
    if x <= 15.0 {
        let y = x * x;
        eval_poly(&P1, y) / eval_poly(&Q1, y)
    } else {
        let y = 1.0 / x - 1.0 / 15.0;
        let r = eval_poly(&P2, y) / eval_poly(&Q2, y);
        let factor = x.exp() / x.sqrt();
        factor * r
    }
}

/// `ff_kbd_window_init(window, alpha, n)` — fills `window[0..n]` with a
/// symmetric KBD window. `n` must be <= 2048.
#[allow(clippy::needless_range_loop)]
pub fn kbd_window_init(window: &mut [f32], alpha: f32, n: usize) {
    assert!(n <= 2048, "FF_KBD_WINDOW_MAX exceeded");
    assert!(window.len() >= n);

    let mut sum = 0.0f64;
    let mut scale = 0.0f64;
    let mut temp = vec![0.0f64; n / 2 + 1];
    let alpha2 = {
        let a = alpha as f64 * std::f64::consts::PI / n as f64;
        4.0 * a * a
    };

    for i in 0..=n / 2 {
        let tmp = (i * (n - i)) as f64 * alpha2;
        temp[i] = bessel_i0(tmp.sqrt());
        scale += temp[i] * if i != 0 && i < n / 2 { 2.0 } else { 1.0 };
    }
    scale = 1.0 / (scale + 1.0);

    let mut i = 0usize;
    while i <= n / 2 {
        sum += temp[i];
        window[i] = (sum * scale).sqrt() as f32;
        i += 1;
    }
    while i < n {
        sum += temp[n - i];
        window[i] = (sum * scale).sqrt() as f32;
        i += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bessel_i0_known_values() {
        // Reference values computed by the power series sum_{k} (x/2)^2k/(k!)^2.
        // The Blair-Edwards minimax approximation carries ~1e-7 relative error.
        assert_eq!(bessel_i0(0.0), 1.0);
        assert!((bessel_i0(1.0) - 1.2660658777520082).abs() < 1e-12);
        assert!((bessel_i0(5.0) - 27.239871823604445).abs() < 1e-9);
        assert!((bessel_i0(15.0) - 339649.3732979139).abs() < 0.1);
        assert!((bessel_i0(30.0) - 781672297823.9775).abs() < 1e5);
        // Even function.
        assert_eq!(bessel_i0(-5.0), bessel_i0(5.0));
    }

    #[test]
    fn kbd_window_properties() {
        // ff_kbd_window_init produces the *rising half window* (kbdwin.h:
        // "n: size of half window"), not a symmetric window.
        for &(alpha, n) in &[(4.0f32, 2048usize), (6.0, 256), (2.0, 128)] {
            let mut w = vec![0.0f32; n];
            kbd_window_init(&mut w, alpha, n);
            assert!(w[0] < 0.05, "start not near zero: {}", w[0]);
            assert!(w[n - 1] > 0.98, "end not near one: {}", w[n - 1]);
            for i in 1..n {
                assert!(w[i] >= w[i - 1] - 1e-7, "not monotonic at {i}");
            }
            // TDAC perfect-reconstruction pair property (exact because
            // temp[0] = I0(0) = 1): w[i]^2 + w[n-1-i]^2 == 1.
            for i in 0..n {
                let s = w[i] * w[i] + w[n - 1 - i] * w[n - 1 - i];
                assert!(
                    (s - 1.0).abs() < 1e-5,
                    "PR pair {s} at {i} (alpha={alpha}, n={n})"
                );
            }
        }
    }
}
