use baka_ac4_cli::mp4::read_ac4_track;
use std::process::Command;

const FIXTURE: &[u8] = include_bytes!("fixtures/mp4_probe.mp4");

#[test]
fn all_accepted_samples_are_inside_the_input() {
    // The embedded file is itself a deliberately truncated fuzz seed.
    assert!(read_ac4_track(FIXTURE).is_err());
    let mut complete = FIXTURE.to_vec();
    complete.resize(9_000_000, 0);
    let track = read_ac4_track(&complete).unwrap();
    assert_eq!(track.timescale, 48_000);
    assert!(!track.samples.is_empty());
    for (offset, size) in track.samples {
        assert!(offset + size as u64 <= complete.len() as u64);
    }
    for length in (0..FIXTURE.len()).step_by(997) {
        if let Ok(track) = read_ac4_track(&FIXTURE[..length]) {
            assert!(!track.samples.is_empty());
            for (offset, size) in track.samples {
                assert!(size > 0);
                assert!(offset.checked_add(size as u64).unwrap() <= length as u64);
            }
        }
    }
}

#[test]
fn hostile_table_counts_fail_before_allocation() {
    for tag in [b"stsz", b"stsc", b"stco", b"co64"] {
        if let Some(pos) = FIXTURE.windows(4).position(|s| s == tag) {
            let mut data = FIXTURE.to_vec();
            let count = pos + if tag == b"stsz" { 12 } else { 8 };
            data[count..count + 4].copy_from_slice(&u32::MAX.to_be_bytes());
            assert!(read_ac4_track(&data).is_err());
        }
    }
}

#[test]
fn truncated_file_is_a_cli_error_for_every_command() {
    let path = std::env::temp_dir().join(format!("baka-ac4-truncated-{}.mp4", std::process::id()));
    std::fs::write(&path, &FIXTURE[..FIXTURE.len() - 1]).unwrap();
    let output = path.with_extension("wav");
    for command in ["toc", "bench", "decode"] {
        let mut process = Command::new(env!("CARGO_BIN_EXE_baka-ac4"));
        process.arg(command).arg(&path);
        if command == "decode" {
            process.arg(&output);
        }
        if command == "bench" {
            process.arg("1");
        }
        let result = process.output().unwrap();
        assert!(!result.status.success());
        let stderr = String::from_utf8_lossy(&result.stderr);
        assert!(
            stderr.contains("sample extends beyond MP4 input"),
            "{command}: {stderr}"
        );
        assert!(!stderr.contains("panicked"));
    }
    std::fs::remove_file(path).unwrap();
    assert!(!output.exists());
}

#[test]
fn extended_size_boxes_advance_to_the_next_box() {
    let mut data = FIXTURE.to_vec();
    data.resize(9_000_000, 0);
    let original = read_ac4_track(&data).unwrap();
    let size = u32::from_be_bytes(data[..4].try_into().unwrap()) as u64;
    assert!(size >= 16);
    data[..4].copy_from_slice(&1u32.to_be_bytes());
    data[8..16].copy_from_slice(&size.to_be_bytes());
    assert_eq!(read_ac4_track(&data).unwrap().samples, original.samples);
    data[8..16].copy_from_slice(&8u64.to_be_bytes());
    assert!(read_ac4_track(&data).is_err());
}
