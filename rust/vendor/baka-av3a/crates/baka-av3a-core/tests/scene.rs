use baka_av3a_core::metadata::{
    AudioPack, Content, EncodedGain, GainValue, Programme, StaticChannel, StaticMetadata,
    StaticObject,
};

fn gain(decibels: bool, upper: bool, index: u8) -> EncodedGain {
    EncodedGain {
        decibels,
        upper,
        index,
    }
}
fn object(index: u8, pack: u8) -> StaticObject {
    StaticObject {
        index,
        language: None,
        dialogue: None,
        importance: None,
        disable_ducking: false,
        interaction: None,
        gain: None,
        head_locked: false,
        muted: false,
        packs: vec![pack],
    }
}
fn pack(index: u8, channels: &[(u8, Option<u8>)], start_index: Option<u8>) -> AudioPack {
    AudioPack {
        index,
        importance: None,
        type_label: 3,
        absolute_distance: 0,
        hoa: None,
        format_id: None,
        matrix_outputs: vec![],
        start_index,
        channels: channels.to_vec(),
    }
}
fn content(index: u8, objects: Vec<u8>) -> Content {
    Content {
        index,
        language: None,
        loudness: None,
        dialogue: None,
        complementary_objects: vec![],
        objects,
    }
}
fn scene() -> StaticMetadata {
    let mut alternatives = content(2, vec![7, 1]);
    alternatives.complementary_objects = vec![vec![1, 7]];
    let mut chosen = object(1, 2);
    chosen.gain = Some(gain(false, true, 63)); // 16
    StaticMetadata {
        basic_level: 0,
        programme: Programme {
            language: None,
            ducking_depth: None,
            loudness: None,
            screen: None,
            contents: vec![2],
        },
        contents: vec![alternatives, content(0, vec![4])],
        objects: vec![object(7, 6), chosen, object(4, 6)],
        packs: vec![
            pack(6, &[(31, Some(3)), (2, Some(1))], None),
            pack(2, &[(9, None), (11, None)], Some(0)),
        ],
        channels: vec![
            StaticChannel {
                index: 31,
                gain: None,
                speaker: None,
                matrix_coefficients: vec![],
            },
            StaticChannel {
                index: 9,
                gain: Some(gain(true, false, 63)),
                speaker: None,
                matrix_coefficients: vec![],
            },
            StaticChannel {
                index: 11,
                gain: Some(gain(false, true, 63)),
                speaker: None,
                matrix_coefficients: vec![],
            },
            StaticChannel {
                index: 2,
                gain: None,
                speaker: None,
                matrix_coefficients: vec![],
            },
        ],
        vr: None,
    }
}

#[test]
fn sparse_definition_ids_resolve_contiguous_and_reused_physical_channels() {
    let data = scene();
    let resolved = data.resolve_scene(4, None).unwrap();
    assert_eq!(resolved.physical_channels(), 4);
    assert_eq!(resolved.selected_objects(), &[1]);
    let channels = resolved.channels();
    assert_eq!(channels.len(), 2);
    assert_eq!(
        (
            channels[0].object_index,
            channels[0].pack_index,
            channels[0].channel_index,
            channels[0].transport_channel
        ),
        (1, 2, 9, 0)
    );
    assert!((channels[0].gain - 0.0016).abs() < 1e-12);
    assert_eq!(
        (
            channels[1].channel_index,
            channels[1].transport_channel,
            channels[1].gain
        ),
        (11, 1, 256.0)
    );
    let reused = data.resolve_scene(4, Some(&[7])).unwrap();
    assert_eq!(
        reused
            .channels()
            .iter()
            .map(|v| (v.channel_index, v.transport_channel))
            .collect::<Vec<_>>(),
        vec![(31, 3), (2, 1)]
    );
    assert_eq!(data.resolve_scene(4, Some(&[])).unwrap().channels(), []);
    assert!(data.resolve_scene(4, Some(&[1, 7])).is_err());
    assert!(data.resolve_scene(4, Some(&[4])).is_err()); // known but outside programme
    assert!(data.resolve_scene(4, Some(&[6])).is_err()); // undefined
    assert!(data.resolve_scene(4, Some(&[1, 1])).is_err());
}

#[test]
fn shared_audio_paths_remain_distinct_and_muting_is_object_local() {
    let mut data = scene();
    data.contents[0].complementary_objects.clear();
    data.objects[1].packs = vec![6];
    data.objects[1].muted = true;
    data.objects[1].head_locked = true;
    // Same physical audio is intentionally referenced by two independent objects.
    let resolved = data.resolve_scene(4, None).unwrap();
    assert_eq!(resolved.selected_objects(), &[1, 7]);
    assert_eq!(resolved.channels().len(), 4);
    assert!(
        resolved.channels()[..2]
            .iter()
            .all(|v| v.gain == 0.0 && v.head_locked)
    );
    assert!(
        resolved.channels()[2..]
            .iter()
            .all(|v| v.gain == 1.0 && !v.head_locked)
    );
    assert_eq!(
        resolved.channels()[0].transport_channel,
        resolved.channels()[2].transport_channel
    );
    // Repeating an object through another content does not render it twice.
    data.programme.contents.push(0);
    data.contents[1].objects = vec![7];
    assert_eq!(data.resolve_scene(4, None).unwrap().channels().len(), 4);
}

#[test]
fn every_gain_unit_and_endpoint_combines_without_clipping() {
    let mut data = scene();
    for decibels in [false, true] {
        for upper in [false, true] {
            for index in 0..64 {
                let encoded = gain(decibels, upper, index);
                data.objects[1].gain = Some(encoded.clone());
                data.channels[1].gain = Some(encoded.clone());
                let expected = match encoded.value() {
                    GainValue::Linear(v) => f64::from(v),
                    GainValue::Decibels(v) => 10.0f64.powf(f64::from(v) / 20.0),
                };
                let actual = data.resolve_scene(4, None).unwrap().channels()[0].gain;
                assert_eq!(actual, expected * expected);
            }
        }
    }
}

#[test]
fn malformed_graphs_and_inactive_definitions_are_rejected() {
    type Mutation = fn(&mut StaticMetadata);
    let cases: &[Mutation] = &[
        |s| s.contents.push(s.contents[0].clone()),
        |s| s.objects.push(s.objects[0].clone()),
        |s| s.packs.push(s.packs[0].clone()),
        |s| s.channels.push(s.channels[0].clone()),
        |s| s.contents[0].index = 4,
        |s| s.objects[0].index = 8,
        |s| s.packs[0].index = 8,
        |s| s.channels[0].index = 32,
        |s| s.programme.contents = vec![1],
        |s| s.programme.contents = vec![2, 2],
        |s| s.programme.contents.clear(),
        |s| s.contents[0].objects = vec![0],
        |s| s.contents[0].objects = vec![1, 1],
        |s| s.contents[0].complementary_objects = vec![vec![0]],
        |s| s.contents[0].complementary_objects = vec![vec![1, 1]],
        |s| s.contents[0].complementary_objects = vec![vec![]],
        |s| s.objects[0].packs = vec![1],
        |s| s.objects[0].packs = vec![6, 6],
        |s| s.objects[0].packs.clear(),
        |s| s.objects[2].gain = Some(gain(false, false, 64)),
        |s| s.channels[0].gain = Some(gain(true, true, 64)),
        |s| s.packs[0].channels[0].0 = 30,
        |s| s.packs[0].channels[0].1 = Some(4),
        |s| s.packs[0].channels[0].1 = None,
        |s| s.packs[0].start_index = Some(0),
        |s| s.packs[1].start_index = Some(31),
        |s| s.packs[1].start_index = None,
        |s| s.packs[1].channels[0].1 = Some(0),
        |s| {
            let channel = s.packs[1].channels[0];
            s.packs[1].channels.push(channel);
        },
        |s| s.packs[1].channels.clear(),
        |s| s.packs[1].type_label = 0,
        |s| s.basic_level = 2,
    ];
    for (i, mutate) in cases.iter().enumerate() {
        let mut data = scene();
        mutate(&mut data);
        assert!(data.resolve_scene(4, None).is_err(), "mutation {i}");
    }
    for channels in [0, 3, 33, u16::MAX] {
        assert!(scene().resolve_scene(channels, None).is_err());
    }
}

#[test]
fn transport_endpoints_and_ambiguous_default_groups() {
    let p = pack(0, &[(31, None)], Some(31));
    assert_eq!(p.transport_channels().unwrap(), vec![31]);
    let p = pack(0, &[(31, Some(31)), (0, Some(0))], None);
    assert_eq!(p.transport_channels().unwrap(), vec![31, 0]);
    let mut data = scene();
    data.contents[0].complementary_objects.push(vec![7, 1]);
    assert!(data.resolve_scene(4, None).is_err());
    assert!(data.resolve_scene(4, Some(&[7])).is_ok());
}

#[test]
fn packed_static_block_resolves_the_physical_channel_instead_of_definition_id() {
    // One programme/content/object/pack/channel. Sparse IDs: 2/5/6/31;
    // contiguous pack transport starts at physical channel 3. No optional fields.
    let bytes = [0, 34, 1, 69, 0, 24, 97, 128, 96, 248, 62];
    let mut reader = baka_av3a_core::BitReader::with_bit_len(&bytes, 88).unwrap();
    let data = StaticMetadata::parse(&mut reader).unwrap();
    let resolved = data.resolve_scene(4, None).unwrap();
    assert_eq!(resolved.selected_objects(), &[5]);
    let path = resolved.channels()[0];
    assert_eq!(
        (
            path.object_index,
            path.pack_index,
            path.channel_index,
            path.transport_channel
        ),
        (5, 6, 31, 3)
    );
    assert_eq!(path.gain, 1.0);
}

#[test]
fn maximum_graph_size_is_bounded_even_with_shared_paths() {
    let mut data = scene();
    data.programme.contents = vec![0];
    data.contents = vec![content(0, (0..8).collect())];
    data.objects = (0..8)
        .map(|i| {
            let mut value = object(i, 0);
            value.packs = (0..8).collect();
            value
        })
        .collect();
    let channels: Vec<_> = (0..32).map(|i| (i, None)).collect();
    data.packs = (0..8).map(|i| pack(i, &channels, Some(0))).collect();
    data.channels = (0..32)
        .map(|index| StaticChannel {
            index,
            gain: None,
            speaker: None,
            matrix_coefficients: vec![],
        })
        .collect();
    let resolved = data.resolve_scene(32, None).unwrap();
    assert_eq!(resolved.channels().len(), 8 * 8 * 32);
    assert_eq!(resolved.channels().last().unwrap().transport_channel, 31);
    data.objects.push(object(0, 0));
    assert!(data.resolve_scene(32, None).is_err());
}
