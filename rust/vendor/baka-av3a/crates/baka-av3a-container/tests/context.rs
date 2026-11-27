use baka_av3a_container::Track;
use baka_av3a_core::{model::HyperModel, side::ChannelBedFrame};

#[test]
#[ignore = "requires local samples, decoded model and context oracle records"]
fn local_context_coefficients() {
    let model_bytes = std::fs::read(std::env::var_os("BAKA_AV3A_MODEL_PATH").unwrap()).unwrap();
    let model = HyperModel::parse(&model_bytes).unwrap();
    let samples = std::env::var_os("BAKA_AV3A_SAMPLE_DIR").unwrap();
    let oracle = std::env::var_os("BAKA_AV3A_ORACLE_DIR").unwrap();
    let mut frames = 0;
    let mut coefficients = 0;
    for id in [
        "3383921500",
        "3397415408",
        "3438952240",
        "3440171245",
        "139774",
        "347230",
    ] {
        let bytes =
            std::fs::read(std::path::Path::new(&samples).join(format!("{id}.mp4"))).unwrap();
        let track = Track::parse(&bytes).unwrap();
        track.validate_frames().unwrap();
        let records = std::fs::read_to_string(
            std::path::Path::new(&oracle).join(format!("{id}-context.txt")),
        )
        .unwrap();
        assert_eq!(track.packet_count(), records.lines().count());
        for (packet, record) in track.packets().zip(records.lines()) {
            let mut fields = record.split_whitespace();
            assert_eq!(
                fields.next().unwrap().parse::<usize>().unwrap(),
                packet.index
            );
            let expected = fields.next().unwrap();
            let frame = ChannelBedFrame::parse(packet.bytes).unwrap();
            let mut hash = 14695981039346656037u64;
            for q in &frame.quantized {
                let decoded = model.decode_context(&q.context).unwrap();
                assert_eq!(decoded.values.len(), 256);
                let features = model.context_features(&decoded.values).unwrap();
                assert!(features.iter().all(|f| f.is_finite()));
                for &value in &decoded.values {
                    for byte in value.to_le_bytes() {
                        hash = (hash ^ u64::from(byte)).wrapping_mul(1099511628211);
                    }
                }
                coefficients += decoded.values.len();
            }
            assert_eq!(
                format!("{hash:016x}"),
                expected,
                "{id} packet {}",
                packet.index
            );
            frames += 1;
        }
    }
    println!("{frames} frames, {coefficients} context integers matched");
}
