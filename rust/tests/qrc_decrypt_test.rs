use xymusic_core::music::lyrics::build_structured_lyrics_payload;

/// 端到端复现「沧浪歌」bug：QQ音乐[L1]插件 getLyric 返回 crypt:1 加密
/// hex 密文，该歌 qrc:0（无逐字歌词），解密产物是普通 LRC。修复前
/// 密文只喂 parse_qrc（逐字 XML 解析器）→ 解析为空 → 整首歌无歌词；
/// 修复后解密文本进入完整解析管线，行级 LRC 也能出词。
#[test]
fn canglangge_encrypted_lrc_yields_lyric_lines() {
    let hex = std::fs::read_to_string("tests/canglangge_lyric.hex")
        .expect("missing tests/canglangge_lyric.hex");
    let hex = hex.trim();

    let payload = build_structured_lyrics_payload(hex.to_string());
    assert!(
        !payload.display_lines.is_empty(),
        "加密 LRC（qrc:0）应解析出展示行，实际 0 行"
    );
    // 行级歌词文本在 text 字段（words 仅逐字格式携带）。
    let joined = payload
        .display_lines
        .iter()
        .map(|line| line.text.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    assert!(
        joined.contains("作词"),
        "歌词文本应包含元数据行，实际: {}",
        &joined.chars().take(120).collect::<String>()
    );
    println!(
        "解析出 {} 行，首行: {:?}",
        payload.display_lines.len(),
        payload.display_lines.first().map(|l| l.text.clone())
    );
}

/// 多段密文拼接（主歌词 + 翻译，Dart _extractLyricsWithTranslation 透传
/// 格式）：整串解密在段边界会损坏 zlib 流，须逐行解密后拼接解析。
#[test]
fn multiline_encrypted_lrc_with_translation_yields_lines() {
    let hex = std::fs::read_to_string("tests/canglangge_lyric.hex")
        .expect("missing tests/canglangge_lyric.hex");
    let hex = hex.trim();
    let combined = format!("{hex}\n{hex}");

    let payload = build_structured_lyrics_payload(combined);
    assert!(
        !payload.display_lines.is_empty(),
        "多段密文拼接应逐行解密出展示行，实际 0 行"
    );
    println!("多段密文解析出 {} 行", payload.display_lines.len());
}

/// 逐字 QRC 密文（qrc:1）不回归：解密产物是 QRC XML，词级时间轴保留。
#[test]
fn encrypted_qrc_word_timing_not_regressed() {
    // 桌面端验证过的 BakaMusic 样本（baby.qrc）
    let hex = "28feb85c1e5b0aee52751548debf8cec52f70ac1da86688e31bcd4d2a45cb2c8160f5c250523e901f07ebf7fe6d77f6faa0f5043b807fcc537f7187d35c7679b37036be3184b3105526561110e1753714a7e6d1d7f17b0b2a10fe8c072d2e43ef5ec7d25bc331953a9ca7bf72bc291aa1c86176920dd579407719661fa2779178156cd4d9c435d39b7d92fad21e1e16de1096ea95d514b6e9d649c010e4f4003d763cf03ee9144d0ee69b070891a4636";
    let payload = build_structured_lyrics_payload(hex.to_string());
    let word_timed = payload
        .display_lines
        .iter()
        .filter(|line| line.words.as_ref().is_some_and(|w| w.len() > 1))
        .count();
    assert!(
        word_timed > 0,
        "QRC 逐字密文应保留词级时间轴，实际词级行 0"
    );
    println!("QRC 密文解析出 {} 行（{} 行词级）", payload.display_lines.len(), word_timed);
}
