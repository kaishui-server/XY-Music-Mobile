use baka_av3a_core::{
    BitReader,
    metadata::{EncodedGain, GainValue, StaticMetadata},
};

fn gain(v: &EncodedGain) -> f32 {
    match v.value() {
        GainValue::Linear(v) | GainValue::Decibels(v) => v,
    }
}
fn physical(v: &StaticMetadata) -> Vec<f32> {
    let mut values = Vec::new();
    values.extend(v.programme.ducking_decibels());
    if let Some(loudness) = v.programme.loudness_values() {
        values.extend(loudness.into_iter().flatten());
    }
    if let Some(screen) = &v.programme.screen {
        values.extend(screen.coordinates());
        values.push(screen.width_value());
    }
    for content in &v.contents {
        if let Some(loudness) = content.loudness_values() {
            values.extend(loudness.into_iter().flatten());
        }
    }
    for object in &v.objects {
        if let Some(i) = &object.interaction {
            if let Some(gain) = &i.gain {
                values.extend(gain.values());
            }
            if let Some(position) = &i.position {
                values.extend(position.values().into_iter().flatten());
            }
        }
        if let Some(v) = &object.gain {
            values.push(gain(v));
        }
    }
    for pack in &v.packs {
        values.push(pack.absolute_distance_value());
        if let Some(hoa) = &pack.hoa {
            values.push(hoa.nfc_reference_distance());
        }
        for speaker in &pack.matrix_outputs {
            values.extend(speaker.polar_coordinates());
        }
    }
    for channel in &v.channels {
        if let Some(v) = &channel.gain {
            values.push(gain(v));
        }
        if let Some(speaker) = &channel.speaker {
            values.extend(speaker.polar_coordinates());
        }
        values.extend(channel.matrix_values());
    }
    if let Some(vr) = &v.vr {
        if let Some(env) = &vr.environment {
            values.extend(env.early_reflection_gain());
            values.extend(env.late_reverb_gain());
            for surface in &env.surfaces {
                if let Some(material) = surface.material_values() {
                    values.extend(material.into_iter().flatten());
                }
                values.extend(surface.vertex_values().into_iter().flatten());
            }
        }
        if let Some(render) = &vr.render {
            for eq in &render.effects.eq {
                values.extend([eq.frequency_hz(), eq.q_value(), eq.gain_decibels()]);
            }
            if let Some(d) = render.effects.dynamics_values() {
                values.extend([
                    d.attack_ms,
                    d.release_ms,
                    d.threshold_db,
                    d.pre_gain_db,
                    d.post_gain_db,
                    d.ratio,
                ]);
            }
            values.extend(render.effects.gain_decibels());
        }
    }
    values
}

#[test]
fn independent_static_physical_values() {
    let fixture = include_bytes!("fixtures/static_values.bin");
    let integer = |p| u32::from_le_bytes(fixture[p..p + 4].try_into().unwrap()) as usize;
    assert_eq!(&fixture[..8], b"MVAL0001");
    assert_eq!(integer(8), 258);
    let (mut position, mut count) = (12, 0);
    for case in 0..258 {
        let bits = integer(position);
        position += 4;
        let data = &fixture[position..position + bits.div_ceil(8)];
        position += data.len();
        let size = integer(position);
        position += 4;
        let expected = &fixture[position..position + size];
        position += size;
        let parsed =
            StaticMetadata::parse(&mut BitReader::with_bit_len(data, bits).unwrap()).unwrap();
        let actual = physical(&parsed);
        assert_eq!(actual.len() * 4, expected.len(), "case {case} shape");
        for (index, (&actual, expected)) in
            actual.iter().zip(expected.as_chunks::<4>().0).enumerate()
        {
            let expected = f32::from_le_bytes(*expected);
            assert_eq!(actual, expected, "case {case} value {index}");
        }
        count += actual.len();
    }
    assert_eq!(position, fixture.len());
    println!("258 static blocks, {count} exact physical values");
}

#[test]
fn all_gain_and_eq_quantizer_indices() {
    use baka_av3a_core::metadata::{EqBand, GainInteraction};
    let fixture = include_bytes!("fixtures/static_grid.bin");
    assert_eq!(&fixture[..8], b"MGRID001");
    assert_eq!(fixture.len(), 8 + 256 * 12 * 4);
    for i in 0..256usize {
        let mut values = Vec::new();
        for decibels in [false, true] {
            for upper in [false, true] {
                values.push(gain(&EncodedGain {
                    decibels,
                    upper,
                    index: (i % 64) as u8,
                }));
            }
        }
        for decibels in [false, true] {
            values.extend(
                GainInteraction {
                    decibels,
                    range: [(i % 128) as u8, ((255 - i) % 128) as u8],
                }
                .values(),
            );
        }
        let mut eq = EqBand {
            kind: 0,
            frequency: (i % 128) as u8,
            upper_q: false,
            q: (i % 64) as u8,
            gain: (i % 128) as u8,
        };
        values.push(eq.frequency_hz());
        values.push(eq.q_value());
        eq.upper_q = true;
        values.push(eq.q_value());
        values.push(eq.gain_decibels());
        for (field, &value) in values.iter().enumerate() {
            let offset = 8 + (i * 12 + field) * 4;
            assert_eq!(
                value,
                f32::from_le_bytes(fixture[offset..offset + 4].try_into().unwrap()),
                "index {i} field {field}"
            );
        }
    }
}
