// 端到端回归：真实网易云《Love Story》(19292984) 歌词数据
// （QRC 主歌词 61 行 + LRC 中文翻译 61 行）经哨兵分段协议解析后
// 翻译必须保留。数据由 wytest/eapi_lyric.mjs + build_sentinel.mjs 生成。
use std::fs;

#[test]
fn real_wy_love_story_qrc_main_keeps_lrc_translation() {
    let sentinel_path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../wytest/love_story_sentinel.txt"
    );
    let text = match fs::read_to_string(sentinel_path) {
        Ok(value) => value,
        Err(_) => return, // 数据文件不存在时跳过（沙盒环境）
    };
    let payload = xymusic_core::music::lyrics::build_structured_lyrics_payload(text);

    assert!(
        payload.display_lines.len() >= 50,
        "主歌词行数不足: {}",
        payload.display_lines.len()
    );

    let translated = payload
        .display_lines
        .iter()
        .filter(|line| !line.translation.trim().is_empty())
        .count();
    assert!(
        translated >= 45,
        "带翻译的行数不足: {}/{}",
        translated,
        payload.display_lines.len()
    );

    // 抽查首句：主歌词是英文、翻译是中文。
    let first = payload
        .display_lines
        .iter()
        .find(|line| !line.translation.trim().is_empty())
        .expect("至少一行有翻译");
    assert!(first.text.contains("young"), "主歌词异常: {}", first.text);
    assert!(
        first.translation.contains("年轻"),
        "翻译异常: {}",
        first.translation
    );
}

#[test]
fn real_wy_love_story_plain_join_loses_translation_before_fix() {
    // 旧行为对照：无哨兵直接 \n 拼接（修复前 Dart 侧曾这样传），QRC 候选
    // 胜出后 LRC 翻译行被整体丢弃。此断言固化该根因，防止回退。
    let sentinel_path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../wytest/love_story_sentinel.txt"
    );
    let text = match fs::read_to_string(sentinel_path) {
        Ok(value) => value,
        Err(_) => return,
    };
    let plain = text
        .lines()
        .filter(|line| {
            let t = line.trim();
            t != "<!--xym:track:translation-->" && t != "<!--xym:track:romanization-->"
        })
        .collect::<Vec<_>>()
        .join("\n");

    let payload = xymusic_core::music::lyrics::build_structured_lyrics_payload(plain);
    let translated = payload
        .display_lines
        .iter()
        .filter(|line| !line.translation.trim().is_empty())
        .count();
    // 主歌词 61 行 QRC 胜出，翻译不应有任何一行进入 translation 字段。
    assert_eq!(
        translated, 0,
        "无哨兵拼接时 QRC 主歌词不应产生 translation 字段，实际 {} 行",
        translated
    );
}
