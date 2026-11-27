use std::process::Command;

fn bench(rounds: &str) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_baka-ac4"))
        .args(["bench", "tests/fixtures/p83_iframe_plus5.ac4", rounds])
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .output()
        .unwrap()
}

#[test]
fn invalid_rounds_fail_without_panicking() {
    for value in ["0", "-1", "invalid", "10001"] {
        let output = bench(value);
        assert!(!output.status.success());
        assert!(String::from_utf8_lossy(&output.stderr).contains("rounds must be"));
    }
}

#[test]
fn multiple_rounds_retain_peak() {
    let output = bench("2");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("peak=0.2019"));
}

#[test]
fn object_output_rejects_conflicting_modes_before_opening_input() {
    for flags in [
        ["--object-signals", "--core-signals"],
        ["--object-signals", "--fast"],
        ["--stereo-preview", "--core-signals"],
        ["--stereo-preview", "--object-signals"],
        ["--stereo-preview", "--fast"],
        ["--render=7.1.4", "--fast"],
        ["--render=stereo", "--core-signals"],
        ["--render=5.1", "--object-signals"],
        ["--render=7.1", "--stereo-preview"],
        ["--render=stereo", "--render=7.1.4"],
        ["--render=invalid", "--f32"],
        ["--render", "--f32"],
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_baka-ac4"))
            .args(["decode", flags[0], flags[1], "missing.ac4", "unused.wav"])
            .output()
            .unwrap();
        assert!(!output.status.success());
        let message = String::from_utf8_lossy(&output.stderr);
        assert!(message.contains("error:"));
        assert!(!message.contains("cannot read"));
    }
}
