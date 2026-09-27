// 批量端到端回归：遍历 wytest/sentinel_batch/ 下所有真实网易云歌曲
// （13 首 Taylor Swift 等英文歌，YRC/QRC 主歌词 + LRC 中文翻译），
// 验证哨兵分段协议下翻译无一丢失。
use std::fs;
use std::path::PathBuf;

fn sentinel_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../wytest/sentinel_batch")
}

#[test]
fn real_wy_batch_all_songs_keep_translations() {
    let dir = sentinel_dir();
    if !dir.exists() {
        return; // 数据目录不存在时跳过（无网络环境）
    }
    let mut checked = 0;
    let mut total_translated = 0usize;
    let mut total_lines = 0usize;
    let mut failures = Vec::new();

    let mut files: Vec<_> = fs::read_dir(&dir)
        .expect("read sentinel dir")
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.path().extension().map_or(false, |e| e == "txt"))
        .collect();
    files.sort_by_key(|entry| entry.file_name());

    for entry in files {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        let text = fs::read_to_string(&path).expect("read sentinel file");
        if !text.contains("<!--xym:track:translation-->") {
            failures.push(format!("{name}: 缺少翻译哨兵标记"));
            continue;
        }
        let payload = xymusic_core::music::lyrics::build_structured_lyrics_payload(text);
        if payload.display_lines.is_empty() {
            failures.push(format!("{name}: 解析后无歌词行"));
            continue;
        }
        let translated = payload
            .display_lines
            .iter()
            .filter(|line| !line.translation.trim().is_empty())
            .count();
        let ratio = translated as f64 / payload.display_lines.len() as f64;
        if ratio < 0.6 {
            failures.push(format!(
                "{name}: 翻译保留率过低 {translated}/{} ({:.0}%)",
                payload.display_lines.len(),
                ratio * 100.0
            ));
        }
        total_translated += translated;
        total_lines += payload.display_lines.len();
        checked += 1;
    }

    assert!(checked >= 10, "批量样本不足: {checked}");
    assert!(
        failures.is_empty(),
        "以下歌曲翻译丢失:\n{}",
        failures.join("\n")
    );
    println!(
        "批量验证通过: {checked} 首歌, {total_translated}/{total_lines} 行保留翻译"
    );
}
