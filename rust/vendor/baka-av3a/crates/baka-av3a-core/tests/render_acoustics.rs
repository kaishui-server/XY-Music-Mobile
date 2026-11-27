use baka_av3a_core::{
    metadata::{AcousticEnvironment, Surface},
    render::{
        AcousticMaterial, AcousticRoom, AcousticSurface, BinauralRenderer, HeadOrientation,
        HrirBank, ListenerPose, PropagationRenderer, PropagationTarget,
    },
};

fn material() -> AcousticMaterial {
    AcousticMaterial::new([[0.36, 0.25]; 8]).unwrap()
}
fn wall(x: f64, y: f64, z: f64) -> AcousticSurface {
    AcousticSurface::new(
        &[[x, -y, -z], [x, y, -z], [x, y, z], [x, -y, z]],
        material(),
    )
    .unwrap()
}
fn close(a: f64, b: f64, tolerance: f64) {
    assert!((a - b).abs() < tolerance, "{a} != {b}");
}
fn point(a: [f64; 3], b: [f64; 3]) {
    for i in 0..3 {
        close(a[i], b[i], 2e-10);
    }
}

#[test]
fn analytic_mirror_distance_direction_and_energy_conservation() {
    let room = AcousticRoom::new(vec![wall(0., 5., 5.)]).unwrap();
    let paths = room.paths([2., 1., 1.], [3., -1., 1.]).unwrap();
    let direct = paths[0].unwrap();
    let reflection = paths[1].unwrap();
    point(reflection.image_position(), [-2., 1., 1.]);
    point(reflection.reflection_point().unwrap(), [0., 0.2, 1.]);
    close(direct.distance_metres(), 5f64.sqrt(), 1e-12);
    close(reflection.distance_metres(), 29f64.sqrt(), 1e-12);
    close(
        reflection.delay_samples(48000, 340.).unwrap(),
        29f64.sqrt() * 48000. / 340.,
        1e-10,
    );
    assert_eq!(reflection.surface_index(), Some(0));
    let specular = material().specular_pressure();
    let scattered = material().scattered_energy();
    for i in 0..8 {
        close(specular[i] * specular[i] + scattered[i] + 0.36, 1., 1e-14);
    }
    let gains = reflection.pressure_gains(1., 0.1).unwrap();
    for gain in gains {
        close(gain, (0.64f64 * 0.75).sqrt() / 29f64.sqrt(), 1e-12);
    }
    let listener = ListenerPose::new([3., -1., 1.], HeadOrientation::default()).unwrap();
    let source = reflection.binaural_direction(listener).unwrap();
    close(source.azimuth, 5f64.atan2(2.).to_degrees(), 1e-12);
    close(source.elevation, 0., 1e-12);
    assert!(
        reflection
            .binaural_direction(ListenerPose::default())
            .is_err()
    );
    let yaw = ListenerPose::new(
        listener.position(),
        HeadOrientation::from_yaw_pitch_roll(90., 0., 0.).unwrap(),
    )
    .unwrap();
    close(
        reflection.binaural_direction(yaw).unwrap().azimuth,
        source.azimuth - 90.,
        1e-12,
    );
    let same = AcousticRoom::new(vec![])
        .unwrap()
        .paths([0.; 3], [0.; 3])
        .unwrap()[0]
        .unwrap();
    close(same.pressure_gains(1., 0.1).unwrap()[0], 10., 1e-12);
    assert_eq!(same.delay_samples(48000, 340.).unwrap(), 0.);
    assert_eq!(
        same.binaural_direction(ListenerPose::default())
            .unwrap()
            .azimuth,
        0.
    );
}

#[test]
fn finite_polygons_occlusion_grazing_and_wall_winding() {
    let room = AcousticRoom::new(vec![wall(0., 1., 1.)]).unwrap();
    assert!(room.paths([-1., 0., 0.], [1., 0., 0.]).unwrap()[0].is_none());
    assert!(room.paths([-1., 2., 0.], [1., 2., 0.]).unwrap()[0].is_some());
    assert!(room.paths([1., 2., 0.], [2., 2., 0.]).unwrap()[1].is_none());
    assert!(room.paths([1., 0., 0.], [2., 0., 0.]).unwrap()[1].is_some());
    assert!(room.paths([0., 0., 0.], [1., 0., 0.]).is_err());
    assert!(room.paths([0., 2., 0.], [0., 3., 0.]).unwrap()[0].is_some());
    assert!(room.paths([0., -2., 0.], [0., 2., 0.]).unwrap()[0].is_none());
    let mut reverse = room.surfaces()[0].vertices().to_vec();
    reverse.reverse();
    let reversed =
        AcousticRoom::new(vec![AcousticSurface::new(&reverse, material()).unwrap()]).unwrap();
    let a = room.paths([2., 0.2, 0.3], [3., -0.1, 0.4]).unwrap();
    let b = reversed.paths([2., 0.2, 0.3], [3., -0.1, 0.4]).unwrap();
    point(
        a[1].unwrap().image_position(),
        b[1].unwrap().image_position(),
    );
    close(
        a[1].unwrap().distance_metres(),
        b[1].unwrap().distance_metres(),
        1e-12,
    );
    close(room.surfaces()[0].area_square_metres(), 4., 1e-12);
    // An intervening finite panel blocks both direct and reflected segments.
    let room = AcousticRoom::new(vec![
        wall(0., 5., 5.),
        AcousticSurface::new(
            &[[0.5, 0., -2.], [3., 0., -2.], [3., 0., 2.], [0.5, 0., 2.]],
            material(),
        )
        .unwrap(),
    ])
    .unwrap();
    let paths = room.paths([2., 1., 0.], [2., -1., 0.]).unwrap();
    assert!(paths[0].is_none());
    // The mirror path goes around the finite panel rather than through it.
    assert!(paths[1].is_some());
    let mut surfaces = room.surfaces().to_vec();
    surfaces.push(wall(1., 5., 5.));
    let blocked = AcousticRoom::new(surfaces)
        .unwrap()
        .paths([2., 1., 0.], [2., -1., 0.])
        .unwrap();
    assert!(blocked[1].is_none());
}

#[test]
fn geometric_and_quantized_material_inputs_are_bounded() {
    let good = [[0., -1., -1.], [0., 1., -1.], [0., 1., 1.], [0., -1., 1.]];
    for vertices in [
        vec![],
        good[..2].to_vec(),
        vec![good[0]; 4],
        vec![good[0], good[2], good[1], good[3]],
        vec![good[0], good[1], [0., 0., 0.], good[2], good[3]],
        vec![good[0], good[1], [0.1, 1., 1.], good[3]],
        vec![[f64::NAN, 0., 0.], good[1], good[2]],
        vec![[1000.1, 0., 0.], good[1], good[2]],
    ] {
        assert!(AcousticSurface::new(&vertices, material()).is_err());
    }
    assert!(AcousticRoom::new(vec![wall(0., 1., 1.); 9]).is_err());
    let mut coefficients = [[0., 0.]; 8];
    coefficients[2][1] = 1.01;
    assert!(AcousticMaterial::new(coefficients).is_err());
    coefficients[2][1] = f64::INFINITY;
    assert!(AcousticMaterial::new(coefficients).is_err());
    let room = AcousticRoom::new(vec![]).unwrap();
    assert!(room.paths([f64::NAN, 0., 0.], [0.; 3]).is_err());
    assert!(room.paths([0.; 3], [0., 1000.1, 0.]).is_err());
    let path = room.paths([1., 0., 0.], [0.; 3]).unwrap()[0].unwrap();
    for (rate, speed) in [(7999, 340.), (48000, 249.), (48000, f64::NAN)] {
        assert!(path.delay_samples(rate, speed).is_err());
    }
    assert!(path.pressure_gains(0., 1.).is_err());
    let mut surface = Surface {
        material: 31,
        material_coefficients: Some([[32, 64]; 8]),
        vertices: vec![[64, 63, 63], [64, 65, 63], [64, 65, 65], [64, 63, 65]],
    };
    let missing = [None; 31];
    let decoded = AcousticSurface::from_metadata(&surface, &missing).unwrap();
    close(decoded.material().bands()[0][0], 32. / 127., 1e-15);
    close(decoded.vertices()[0][1], -200. / 127., 1e-15);
    surface.material = 2;
    surface.material_coefficients = None;
    assert!(AcousticSurface::from_metadata(&surface, &missing).is_err());
    let mut presets = missing;
    presets[2] = Some(material());
    assert!(AcousticSurface::from_metadata(&surface, &presets).is_ok());
    surface.vertices[0][0] = 128;
    assert!(AcousticSurface::from_metadata(&surface, &presets).is_err());
    surface.vertices[0][0] = 64;
    let environment = AcousticEnvironment {
        early_gain: None,
        late_gain: None,
        reverb_type: 0,
        low_frequency_processing: false,
        convolution_type: None,
        surfaces: vec![surface],
    };
    let room = AcousticRoom::from_environment(&environment, &presets).unwrap();
    assert_eq!(room.surfaces().len(), 1);
    assert!(AcousticRoom::from_environment(&environment, &missing).is_err());
}

#[test]
fn independent_rotated_room_vectors() {
    let fixture = include_bytes!("fixtures/acoustic_paths.bin");
    assert_eq!(&fixture[..8], b"ACPATH01");
    let count = u32::from_le_bytes(fixture[8..12].try_into().unwrap()) as usize;
    let mut values = fixture[12..]
        .as_chunks::<8>()
        .0
        .iter()
        .map(|v| f64::from_le_bytes(*v));
    for case in 0..count {
        let matrix: [[f64; 3]; 3] =
            std::array::from_fn(|_| std::array::from_fn(|_| values.next().unwrap()));
        let center: [f64; 3] = std::array::from_fn(|_| values.next().unwrap());
        let half: [f64; 3] = std::array::from_fn(|_| values.next().unwrap());
        let source = std::array::from_fn(|_| values.next().unwrap());
        let receiver = std::array::from_fn(|_| values.next().unwrap());
        let transform = |local: [f64; 3]| {
            std::array::from_fn(|i| {
                center[i] + (0..3).map(|j| matrix[i][j] * local[j]).sum::<f64>()
            })
        };
        let mut surfaces = vec![];
        for axis in 0..3 {
            for sign in [-1., 1.] {
                let b = (axis + 1) % 3;
                let c = (axis + 2) % 3;
                let vertices: Vec<_> = [[-1., -1.], [1., -1.], [1., 1.], [-1., 1.]]
                    .map(|corner| {
                        let mut local = [0.; 3];
                        local[axis] = sign * half[axis];
                        local[b] = corner[0] * half[b];
                        local[c] = corner[1] * half[c];
                        transform(local)
                    })
                    .to_vec();
                surfaces.push(AcousticSurface::new(&vertices, material()).unwrap());
            }
        }
        let room = AcousticRoom::new(surfaces).unwrap();
        let paths = room.paths(source, receiver).unwrap();
        for (index, path) in paths[..7].iter().enumerate() {
            let image = std::array::from_fn(|_| values.next().unwrap());
            let bounce = std::array::from_fn(|_| values.next().unwrap());
            let distance = values.next().unwrap();
            let path = path.unwrap_or_else(|| panic!("missing case{case} path{index}"));
            point(path.image_position(), image);
            if index > 0 {
                point(path.reflection_point().unwrap(), bounce);
            }
            close(path.distance_metres(), distance, 2e-10);
        }
    }
    assert!(values.next().is_none());
    assert_eq!(count, 128);
}

#[test]
fn source_time_fractional_propagation_matches_independent_scatter_and_preserves_old_tails() {
    let stages = [
        [
            PropagationTarget {
                delay_samples: 0.,
                gain: 1.,
            },
            PropagationTarget {
                delay_samples: 1500.25,
                gain: 0.5,
            },
            PropagationTarget {
                delay_samples: 2400.75,
                gain: 0.8,
            },
        ],
        [
            PropagationTarget {
                delay_samples: 1700.5,
                gain: 0.7,
            },
            PropagationTarget {
                delay_samples: 21.75,
                gain: 1.,
            },
            PropagationTarget {
                delay_samples: 3400.,
                gain: 0.2,
            },
        ],
        [
            PropagationTarget {
                delay_samples: 0.25,
                gain: 0.4,
            },
            PropagationTarget {
                delay_samples: 4000.,
                gain: 0.,
            },
            PropagationTarget {
                delay_samples: 2500.5,
                gain: 0.8,
            },
        ],
    ];
    let mut renderer = PropagationRenderer::new(8000, 0.5, &stages[0]).unwrap();
    let mut actual = vec![0.; 8 * 1024 * 3];
    let mut expected = vec![0f64; actual.len()];
    for block in 0..8 {
        let stage = stages[block.min(2)];
        let old = stages[block.saturating_sub(1).min(2)];
        let jumps = [block == 2, false, block == 1];
        renderer.set_targets(&stage, &jumps).unwrap();
        let input: Vec<_> = (0..1024)
            .map(|i| {
                if block < 3 {
                    ((i * 37 + block * 11) % 101) as f32 * 0.001 - 0.05
                } else {
                    0.
                }
            })
            .collect();
        for (sample, &value) in input.iter().enumerate() {
            for path in 0..3 {
                let t = sample as f64 / 1024.;
                for (target, weight) in if jumps[path] || old[path] == stage[path] {
                    [(stage[path], 1.), (stage[path], 0.)]
                } else {
                    [(old[path], 1. - t), (stage[path], t)]
                } {
                    let arrival = block * 1024 + sample + target.delay_samples.floor() as usize;
                    let fraction = target.delay_samples.fract();
                    for (offset, w) in [(0, 1. - fraction), (1, fraction)] {
                        if let Some(output) = expected.get_mut((arrival + offset) * 3 + path) {
                            *output += f64::from(value) * f64::from(target.gain) * weight * w;
                        }
                    }
                }
            }
        }
        renderer
            .process(&input, &mut actual[block * 3072..(block + 1) * 3072])
            .unwrap();
    }
    for (actual, expected) in actual.iter().zip(expected) {
        close(f64::from(*actual), expected, 3e-8);
    }
    assert!(actual[7 * 3072..].iter().all(|v| *v == 0.));
    assert_eq!(renderer.tail_samples(), 4000);
}

#[test]
fn propagation_errors_clone_reset_and_maximum_delay_are_bounded() {
    let targets = [PropagationTarget {
        delay_samples: 12.5,
        gain: 1.,
    }; 9];
    let mut renderer = PropagationRenderer::new(8000, 0.5, &targets).unwrap();
    let new = [PropagationTarget {
        delay_samples: 4000.,
        gain: 16.,
    }; 9];
    renderer.set_targets(&new, &[true; 9]).unwrap();
    let mut reference = renderer.clone();
    let mut a = vec![123.; 9216];
    let mut b = a.clone();
    assert!(renderer.process(&[f32::NAN; 1024], &mut a).is_err());
    assert!(renderer.process(&[257.; 1024], &mut a).is_err());
    assert!(renderer.process(&[0.; 1023], &mut a).is_err());
    assert!(renderer.process(&[0.; 1024], &mut a[..9215]).is_err());
    for target in [
        PropagationTarget {
            delay_samples: 4000.01,
            gain: 1.,
        },
        PropagationTarget {
            delay_samples: -1.,
            gain: 1.,
        },
        PropagationTarget {
            delay_samples: f64::INFINITY,
            gain: 1.,
        },
        PropagationTarget {
            delay_samples: 1.,
            gain: f32::NAN,
        },
    ] {
        assert!(renderer.set_targets(&[target; 9], &[true; 9]).is_err());
    }
    assert!(a.iter().all(|v| *v == 123.));
    assert_eq!(renderer.targets(), new);
    for _ in 0..6 {
        renderer.process(&[0.125; 1024], &mut a).unwrap();
        reference.process(&[0.125; 1024], &mut b).unwrap();
        assert_eq!(a, b);
    }
    renderer.reset();
    let mut fresh = PropagationRenderer::new(8000, 0.5, &new).unwrap();
    for _ in 0..6 {
        renderer.process(&[0.125; 1024], &mut a).unwrap();
        fresh.process(&[0.125; 1024], &mut b).unwrap();
        assert_eq!(a, b);
    }
    for _ in 0..5 {
        renderer.process_silence(&mut a).unwrap();
    }
    assert!(a.iter().all(|v| *v == 0.));
    assert!(PropagationRenderer::new(48000, 2.01, &targets).is_err());
    assert!(PropagationRenderer::new(48000, 0., &targets).is_err());
    assert!(PropagationRenderer::new(192001, 1., &targets).is_err());
    assert!(PropagationRenderer::new(48000, 1., &[]).is_err());
    assert!(PropagationRenderer::new(48000, 1., &[targets[0]; 10]).is_err());
}

#[test]
fn image_paths_fractional_propagation_and_hrir_match_scalar_stereo_impulses() {
    let bank = HrirBank::from_bytes(include_bytes!("fixtures/synthetic_hrir.bin")).unwrap();
    stereo_impulse_oracle(bank);
}
fn stereo_impulse_oracle(bank: HrirBank) {
    let rate = bank.sample_rate();
    let room = AcousticRoom::new(vec![wall(0., 5., 5.)]).unwrap();
    let pose = ListenerPose::new([1., 0., 0.], HeadOrientation::default()).unwrap();
    let paths = room.paths([2., 0., 0.], pose.position()).unwrap();
    let paths = [paths[0].unwrap(), paths[1].unwrap()];
    // Material coefficients in this test are identical in all eight bands.
    // Selecting band0 therefore applies no unverified broadband averaging.
    let targets = paths.map(|p| PropagationTarget {
        delay_samples: p.delay_samples(rate, 340.).unwrap(),
        gain: p.pressure_gains(1., 0.1).unwrap()[0] as f32,
    });
    let sources = paths.map(|p| p.binaural_direction(pose).unwrap());
    let mut propagation = PropagationRenderer::new(rate, 0.1, &targets).unwrap();
    let mut renderer = BinauralRenderer::new(bank.clone(), rate, &sources).unwrap();
    renderer.set_sources(&sources, &[true; 2]).unwrap();
    let mut actual = vec![0.; 6 * 2048];
    let mut bus = vec![0.; 2048];
    for block in 0..6 {
        let mut source = [0.; 1024];
        if block == 0 {
            source[13] = 0.01;
            source[1023] = -0.005;
        }
        propagation.process(&source, &mut bus).unwrap();
        renderer
            .process(&bus, &mut actual[block * 2048..(block + 1) * 2048])
            .unwrap();
    }
    let mut expected = vec![0f64; actual.len()];
    for (path, (target, source)) in targets.iter().zip(sources).enumerate() {
        let weights = bank.interpolate(source.azimuth, source.elevation).unwrap();
        for (index, weight) in weights.indices.into_iter().zip(weights.weights) {
            let measured = &bank.measurements()[index];
            for (ear, taps) in [&measured.left, &measured.right].into_iter().enumerate() {
                for (sample, value) in [(13, 0.01f32), (1023, -0.005f32)] {
                    let floor = target.delay_samples.floor() as usize;
                    let fraction = target.delay_samples.fract();
                    for (tap, &coefficient) in taps.iter().enumerate() {
                        for (offset, w) in [(0, 1. - fraction), (1, fraction)] {
                            let frame = sample + floor + tap + offset + 99;
                            expected[frame * 2 + ear] += f64::from(value)
                                * f64::from(target.gain)
                                * f64::from(coefficient)
                                * weight
                                * w;
                        }
                    }
                }
            }
        }
        assert_eq!(
            paths[path].surface_index(),
            if path == 0 { None } else { Some(0) }
        );
    }
    for (&a, b) in actual.iter().zip(expected) {
        close(f64::from(a), b, 3e-9);
    }
    assert!(actual[5 * 2048..].iter().all(|v| *v == 0.));
}

#[test]
#[ignore = "requires private measured HRIR bank through BAKA_AV3A_HRIR_BANK"]
fn measured_paths_propagation_and_hrir_match_scalar_stereo_impulses() {
    let bank = HrirBank::from_bytes(
        &std::fs::read(std::env::var("BAKA_AV3A_HRIR_BANK").unwrap()).unwrap(),
    )
    .unwrap();
    stereo_impulse_oracle(bank);
}
