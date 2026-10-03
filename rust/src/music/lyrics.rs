use amll_lyric::{
    eqrc::decrypt_qrc_hex, eslrc::parse_eslrc, lys::parse_lys, qrc::parse_qrc, yrc::parse_yrc,
    LyricLine as AmlLyricLine,
};
use regex::Regex;
use serde::Serialize;
use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::fmt::Write;
use std::sync::OnceLock;

const MAX_GROUP_TOLERANCE_MS: u32 = 50;

/// 主歌词与翻译来自不同接口时，时间戳常有几百毫秒漂移（如网易
/// tlyric 与 lyric 各自维护时间轴）。同语言行沿用 50ms 严格容差
/// 防止吞并快节奏相邻行；跨语言行对（主词+翻译）放宽到 600ms，
/// 否则翻译行永远无法与主词聚成一组，表现为翻译丢失、行序错乱。
const CROSS_LANGUAGE_GROUP_TOLERANCE_MS: u32 = 600;

// ==================== Regex caches (module-level, compiled once) ====================
static XML_TAG_RE: OnceLock<Regex> = OnceLock::new();
static TTML_PARAGRAPH_RE: OnceLock<Regex> = OnceLock::new();
static TTML_BEGIN_RE: OnceLock<Regex> = OnceLock::new();
static TTML_END_RE: OnceLock<Regex> = OnceLock::new();
static TTML_SPAN_RE: OnceLock<Regex> = OnceLock::new();
static TTML_ROLE_RE: OnceLock<Regex> = OnceLock::new();
static CONTRACTION_RE: OnceLock<Regex> = OnceLock::new();
static ENGLISH_DIGRAPH_RE: OnceLock<Regex> = OnceLock::new();
static ENGLISH_CONSONANT_RE: OnceLock<Regex> = OnceLock::new();
static ROMANIZATION_RE: OnceLock<Regex> = OnceLock::new();
static KRC_FULL_LINE_RE: OnceLock<Regex> = OnceLock::new();
static KRC_TAG_RE: OnceLock<Regex> = OnceLock::new();
const MAX_GROUP_SIZE: usize = 3;
const ALIGNMENT_HIGH_WINDOW_MS: u32 = 300;
const ALIGNMENT_MEDIUM_WINDOW_MS: u32 = 800;
const ALIGNMENT_LOW_WINDOW_MS: u32 = 1500;
const MIN_TRACK_MATCH_SCORE: f64 = 2.6;

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ParsedLineSourceFormat {
    Lrc,
    EnhancedLrc,
    Eslrc,
    Yrc,
    Qrc,
    Lys,
    Ttml,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum ExplicitLineRole {
    Translation,
    Roman,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum ClassificationConfidence {
    Explicit,
    ParserNative,
    Heuristic,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum DominantScript {
    Latin,
    Han,
    Kana,
    Hangul,
    Mixed,
    Other,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
#[allow(dead_code)]
pub enum LyricTrackRole {
    Main,
    Translation,
    Romanization,
    Secondary,
    AlternateMain,
    Background,
    Metadata,
    Unknown,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
#[allow(dead_code)]
pub enum LyricTimingMode {
    Line,
    Word,
    Syllable,
    None,
}

#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LyricTrackSourceFormat {
    Mixed,
    Lrc,
    EnhancedLrc,
    Eslrc,
    Yrc,
    Qrc,
    Lys,
    Ttml,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ParsedWord {
    pub text: String,
    pub start_ms: u32,
    pub end_ms: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub roman_text: Option<String>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ParsedLine {
    pub start_ms: u32,
    pub end_ms: u32,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub words: Option<Vec<ParsedWord>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub translated_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub roman_text: Option<String>,
    pub source_format: ParsedLineSourceFormat,
    pub source_index: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub explicit_role: Option<ExplicitLineRole>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LineScriptProfile {
    pub latin_count: u32,
    pub han_count: u32,
    pub kana_count: u32,
    pub hangul_count: u32,
    pub dominant_script: DominantScript,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LyricTrackLine {
    pub id: String,
    pub start_ms: u32,
    pub end_ms: u32,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub words: Option<Vec<ParsedWord>>,
    pub source_index: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub explicit_role: Option<ExplicitLineRole>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role_source: Option<ClassificationConfidence>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cluster_index: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub slot_index: Option<usize>,
    pub source_format: ParsedLineSourceFormat,
    pub script_profile: LineScriptProfile,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LyricTrackAttachment {
    pub track_id: String,
    pub role: LyricTrackRole,
    pub confidence: f64,
    pub line_match_ratio: f64,
}

#[derive(Serialize, Clone, Debug)]
pub struct LyricTrackScores {
    pub main: f64,
    pub translation: f64,
    pub romanization: f64,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LyricTrack {
    pub id: String,
    pub role: LyricTrackRole,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lang: Option<String>,
    pub timing_mode: LyricTimingMode,
    pub source_format: LyricTrackSourceFormat,
    pub confidence: f64,
    pub dominant_script: DominantScript,
    pub lines: Vec<LyricTrackLine>,
    pub attachments: Vec<LyricTrackAttachment>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scores: Option<LyricTrackScores>,
}

#[derive(Serialize, Clone, Debug)]
pub struct LyricIssue {
    pub code: String,
    pub message: String,
    pub severity: String,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LyricDocumentMetadata {
    pub total_lines: usize,
    pub source_formats: Vec<ParsedLineSourceFormat>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LyricDocument {
    pub metadata: LyricDocumentMetadata,
    pub tracks: Vec<LyricTrack>,
    pub issues: Vec<LyricIssue>,
    pub confidence: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_track_id: Option<String>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct SemanticLine {
    pub start_ms: u32,
    pub end_ms: u32,
    pub main_text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub main_words: Option<Vec<ParsedWord>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub translation_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub roman_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub roman_words: Option<Vec<ParsedWord>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub secondary_texts: Option<Vec<String>>,
    pub confidence: ClassificationConfidence,
}

#[derive(Serialize, Clone, Debug)]
pub struct LyricWordPayload {
    pub text: String,
    pub start: f64,
    pub end: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub romaji: Option<String>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LyricLinePayload {
    pub time: f64,
    pub end_time: f64,
    pub text: String,
    pub translation: String,
    pub romaji: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub words: Option<Vec<LyricWordPayload>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub romaji_words: Option<Vec<LyricWordPayload>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub secondary: Option<Vec<String>>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct StructuredLyricsPayload {
    pub raw_lyrics: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub document: Option<LyricDocument>,
    pub semantic_lines: Vec<SemanticLine>,
    pub display_lines: Vec<LyricLinePayload>,
}

#[derive(Clone, Debug)]
struct TrackAlignmentPair {
    main_index: usize,
    aux_index: usize,
    drift_ms: i64,
    quality: f64,
}

#[derive(Clone, Debug, Default)]
struct TrackAlignment {
    pairs: Vec<TrackAlignmentPair>,
    main_coverage: f64,
    aux_coverage: f64,
    weighted_score: f64,
}

#[derive(Clone, Debug, Default)]
struct TrackRoleScores {
    main: f64,
    translation: f64,
    romanization: f64,
}

#[derive(Clone, Debug)]
struct ParserCandidate {
    source: ParsedLineSourceFormat,
    lines: Vec<ParsedLine>,
}

#[derive(Clone, Debug)]
struct LayoutTemplateResolution {
    display_track_index: usize,
    track_roles: Vec<Option<LyricTrackRole>>,
}

fn clamp01(value: f64) -> f64 {
    value.clamp(0.0, 1.0)
}

fn average(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    values.iter().sum::<f64>() / values.len() as f64
}

fn track_word_coverage(track: &LyricTrack) -> f64 {
    track
        .lines
        .iter()
        .filter(|line| {
            line.words
                .as_ref()
                .map(|words| !words.is_empty())
                .unwrap_or(false)
        })
        .count() as f64
        / track.lines.len().max(1) as f64
}

fn sanitize_line_text(text: &str) -> String {
    text.replace('\u{200b}', "").trim().to_string()
}

fn sanitize_word_text(text: &str) -> String {
    text.replace(['\u{200b}', '\u{2063}'], "")
}

fn consume_square_timestamp_block(source: &str) -> Option<(usize, String)> {
    if !source.starts_with('[') {
        return None;
    }

    let end = source.find(']')?;
    let block = &source[..=end];
    parse_timestamp_to_ms(&source[1..end])?;
    Some((end + 1, block.to_string()))
}

fn normalize_eslrc_source(source: &str) -> String {
    source
        .lines()
        .map(|line| {
            let mut normalized = String::with_capacity(line.len());
            let mut index = 0usize;

            while index < line.len() {
                let slice = &line[index..];
                if slice.starts_with('[') {
                    let mut cursor = index;
                    let mut blocks = Vec::new();

                    while cursor < line.len() {
                        let Some((consumed, block)) =
                            consume_square_timestamp_block(&line[cursor..])
                        else {
                            break;
                        };
                        blocks.push(block);
                        cursor += consumed;
                    }

                    if blocks.len() > 1 {
                        let next_char = line[cursor..].chars().next();
                        if matches!(next_char, Some(ch) if ch != '[' && ch != ']') {
                            for (block_index, block) in blocks.iter().enumerate() {
                                normalized.push_str(block);
                                if block_index + 1 != blocks.len() {
                                    normalized.push('\u{2063}');
                                }
                            }
                            index = cursor;
                            continue;
                        }
                    }
                }

                if let Some(ch) = slice.chars().next() {
                    normalized.push(ch);
                    index += ch.len_utf8();
                } else {
                    break;
                }
            }

            normalized
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn parse_timestamp_to_ms(raw: &str) -> Option<u32> {
    let trimmed = raw.trim();
    let mut parts = trimmed.split(':');
    let minutes = parts.next()?.parse::<u32>().ok()?;
    let seconds_part = parts.next()?;
    if parts.next().is_some() {
        return None;
    }

    let mut second_parts = seconds_part.split('.');
    let seconds = second_parts.next()?.parse::<u32>().ok()?;
    if seconds >= 60 {
        return None;
    }

    let milliseconds = second_parts
        .next()
        .map(|fraction| {
            let mut padded = fraction.to_string();
            while padded.len() < 3 {
                padded.push('0');
            }
            padded
                .chars()
                .take(3)
                .collect::<String>()
                .parse::<u32>()
                .ok()
        })
        .flatten()
        .unwrap_or(0);

    Some(minutes * 60_000 + seconds * 1_000 + milliseconds)
}

fn parse_ttml_clock_to_ms(raw: &str) -> Option<u32> {
    if let Some(milliseconds) = raw.strip_suffix("ms") {
        return milliseconds.trim().parse::<u32>().ok();
    }

    if let Some(seconds) = raw.strip_suffix('s') {
        let parsed = seconds.trim().parse::<f64>().ok()?;
        return Some((parsed * 1000.0).round().max(0.0) as u32);
    }

    if raw.contains(':') {
        return parse_timestamp_to_ms(raw);
    }

    None
}

fn is_latin_char(ch: char) -> bool {
    ch.is_ascii_alphabetic()
        || matches!(
            ch as u32,
            0x00C0..=0x00FF | 0x0100..=0x017F | 0x0180..=0x024F | 0x1E00..=0x1EFF
        )
}

fn is_kana_char(ch: char) -> bool {
    matches!(ch as u32, 0x3040..=0x30FF | 0x31F0..=0x31FF | 0xFF66..=0xFF9F)
}

fn is_hangul_char(ch: char) -> bool {
    matches!(ch as u32, 0xAC00..=0xD7AF | 0x1100..=0x11FF | 0x3130..=0x318F)
}

fn is_han_char(ch: char) -> bool {
    matches!(ch as u32, 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF)
}

fn resolve_dominant_script(
    latin_count: u32,
    han_count: u32,
    kana_count: u32,
    hangul_count: u32,
) -> DominantScript {
    let total = latin_count + han_count + kana_count + hangul_count;
    if total == 0 {
        return DominantScript::Other;
    }

    let mut counts = vec![
        (DominantScript::Latin, latin_count),
        (DominantScript::Han, han_count),
        (DominantScript::Kana, kana_count),
        (DominantScript::Hangul, hangul_count),
    ];
    counts.sort_by(|left, right| right.1.cmp(&left.1));

    let dominant = counts[0].0.clone();
    let dominant_count = counts[0].1;
    let secondary_count = counts.get(1).map(|item| item.1).unwrap_or(0);

    if secondary_count > 0 && (dominant_count as f64 / total as f64) < 0.7 {
        return DominantScript::Mixed;
    }

    dominant
}

fn get_line_script_profile(text: &str) -> LineScriptProfile {
    let mut latin_count = 0;
    let mut han_count = 0;
    let mut kana_count = 0;
    let mut hangul_count = 0;

    for ch in text.chars() {
        if is_latin_char(ch) {
            latin_count += 1;
        } else if is_kana_char(ch) {
            kana_count += 1;
        } else if is_hangul_char(ch) {
            hangul_count += 1;
        } else if is_han_char(ch) {
            han_count += 1;
        }
    }

    let dominant_script = resolve_dominant_script(latin_count, han_count, kana_count, hangul_count);

    LineScriptProfile {
        latin_count,
        han_count,
        kana_count,
        hangul_count,
        dominant_script,
    }
}

fn is_japanese_like(profile: &LineScriptProfile) -> bool {
    profile.kana_count > 0 && profile.hangul_count == 0
}

/// 比 DominantScript 更粗粒度的语言归类：日文假名的存在与否是区分
/// 「日文主词 / 中文翻译」最可靠的信号（两者 DominantScript 都可能是
/// Han 或 Mixed）。用于判断相邻两行是否属于跨语言的主词+翻译对。
fn line_language_class(profile: &LineScriptProfile) -> u8 {
    if is_japanese_like(profile) {
        1 // Japanese-like
    } else if profile.hangul_count > 0 {
        2 // Hangul-like
    } else if profile.han_count > 0 {
        3 // Han (Chinese) like
    } else if profile.latin_count > 0 {
        4 // Latin-like
    } else {
        0 // Other
    }
}

fn is_cross_language_pair(group: &[LyricTrackLine], candidate: &LyricTrackLine) -> bool {
    let candidate_class = line_language_class(&candidate.script_profile);
    if candidate_class == 0 {
        return false;
    }
    group.iter().all(|line| {
        line.explicit_role.is_none()
            && candidate.explicit_role.is_none()
            && line_language_class(&line.script_profile) != candidate_class
    })
}

fn same_script_family(left: &DominantScript, right: &DominantScript) -> bool {
    let family = |script: &DominantScript| match script {
        DominantScript::Latin => "latin",
        DominantScript::Han | DominantScript::Kana | DominantScript::Mixed => "cjk",
        DominantScript::Hangul => "hangul",
        DominantScript::Other => "other",
    };

    family(left) == family(right)
}

fn track_has_japanese_like_lines(track: &LyricTrack) -> bool {
    track
        .lines
        .iter()
        .any(|line| is_japanese_like(&line.script_profile))
}

fn map_track_source_format(source_format: &ParsedLineSourceFormat) -> LyricTrackSourceFormat {
    match source_format {
        ParsedLineSourceFormat::Lrc => LyricTrackSourceFormat::Lrc,
        ParsedLineSourceFormat::EnhancedLrc => LyricTrackSourceFormat::EnhancedLrc,
        ParsedLineSourceFormat::Eslrc => LyricTrackSourceFormat::Eslrc,
        ParsedLineSourceFormat::Yrc => LyricTrackSourceFormat::Yrc,
        ParsedLineSourceFormat::Qrc => LyricTrackSourceFormat::Qrc,
        ParsedLineSourceFormat::Lys => LyricTrackSourceFormat::Lys,
        ParsedLineSourceFormat::Ttml => LyricTrackSourceFormat::Ttml,
    }
}

fn compare_source_index(left: f64, right: f64) -> Ordering {
    left.partial_cmp(&right).unwrap_or(Ordering::Equal)
}

fn sort_parsed_lines(lines: &mut [ParsedLine]) {
    lines.sort_by(|left, right| {
        left.start_ms
            .cmp(&right.start_ms)
            .then_with(|| compare_source_index(left.source_index, right.source_index))
            .then_with(|| left.end_ms.cmp(&right.end_ms))
    });
}

fn normalize_end_times(lines: &mut [ParsedLine]) {
    sort_parsed_lines(lines);

    for index in 0..lines.len() {
        let current_start = lines[index].start_ms;
        let next_start = lines.get(index + 1).map(|line| line.start_ms);
        let fallback_end = next_start.unwrap_or(current_start.saturating_add(5000));
        lines[index].end_ms = lines[index].end_ms.max(current_start.max(fallback_end));
    }
}

fn parser_priority(source_format: &ParsedLineSourceFormat) -> i32 {
    match source_format {
        ParsedLineSourceFormat::EnhancedLrc => 6,
        ParsedLineSourceFormat::Ttml => 5,
        ParsedLineSourceFormat::Yrc => 4,
        ParsedLineSourceFormat::Qrc => 3,
        ParsedLineSourceFormat::Lys => 2,
        ParsedLineSourceFormat::Eslrc => 1,
        ParsedLineSourceFormat::Lrc => 0,
    }
}

fn score_prepared_lines(lines: &[ParsedLine]) -> i32 {
    lines.iter().fold(0, |score, line| {
        score
            + if line
                .words
                .as_ref()
                .map(|words| !words.is_empty())
                .unwrap_or(false)
            {
                2
            } else {
                0
            }
            + if line
                .translated_text
                .as_ref()
                .map(|text| !text.is_empty())
                .unwrap_or(false)
            {
                1
            } else {
                0
            }
            + if line
                .roman_text
                .as_ref()
                .map(|text| !text.is_empty())
                .unwrap_or(false)
            {
                1
            } else {
                0
            }
    })
}

fn compare_parser_candidates(left: &ParserCandidate, right: &ParserCandidate) -> Ordering {
    score_prepared_lines(&right.lines)
        .cmp(&score_prepared_lines(&left.lines))
        .then_with(|| right.lines.len().cmp(&left.lines.len()))
        .then_with(|| parser_priority(&right.source).cmp(&parser_priority(&left.source)))
}

fn detect_explicit_role(text: &str) -> (Option<ExplicitLineRole>, String) {
    let trimmed = sanitize_line_text(text);
    if trimmed.is_empty() {
        return (None, trimmed);
    }

    let lowered = trimmed.to_lowercase();
    let translation_prefixes = [
        "[tr]",
        "[trans]",
        "[translation]",
        "翻译:",
        "翻译：",
        "译文:",
        "译文：",
        "【翻译】",
        "【译文】",
    ];
    for prefix in translation_prefixes {
        if lowered.starts_with(&prefix.to_lowercase()) {
            let normalized = sanitize_line_text(&trimmed[prefix.len()..]);
            return (Some(ExplicitLineRole::Translation), normalized);
        }
    }

    let roman_prefixes = [
        "[roma]",
        "[romaji]",
        "[roman]",
        "罗马音:",
        "罗马音：",
        "罗马字:",
        "罗马字：",
        "音译:",
        "音译：",
        "【罗马音】",
        "【罗马字】",
        "【音译】",
    ];
    for prefix in roman_prefixes {
        if lowered.starts_with(&prefix.to_lowercase()) {
            let normalized = sanitize_line_text(&trimmed[prefix.len()..]);
            return (Some(ExplicitLineRole::Roman), normalized);
        }
    }

    (None, trimmed)
}

fn to_safe_ms(value: u64, fallback: u32) -> u32 {
    value
        .try_into()
        .ok()
        .filter(|value| *value <= 60_039_999)
        .unwrap_or(fallback)
}

fn prepare_amll_line(
    line: &AmlLyricLine<'_>,
    source_format: ParsedLineSourceFormat,
    source_index: usize,
) -> Option<ParsedLine> {
    let fallback_start_ms = to_safe_ms(line.start_time, 0);
    let fallback_end_ms = to_safe_ms(
        line.end_time,
        fallback_start_ms
            .saturating_add(500)
            .max(fallback_start_ms + 80),
    )
    .max(fallback_start_ms);

    let mut words = line
        .words
        .iter()
        .filter_map(|word| {
            let text = sanitize_word_text(word.word.as_ref());
            if text.is_empty() {
                return None;
            }

            let start_ms = to_safe_ms(word.start_time, fallback_start_ms);
            let end_ms = to_safe_ms(word.end_time, fallback_end_ms).max(start_ms);

            Some(ParsedWord {
                text,
                start_ms,
                end_ms,
                roman_text: None,
            })
        })
        .collect::<Vec<_>>();
    words.sort_by(|left, right| left.start_ms.cmp(&right.start_ms));

    let raw_text = if !line.words.is_empty() {
        sanitize_line_text(
            &line
                .words
                .iter()
                .map(|word| word.word.as_ref())
                .collect::<String>(),
        )
    } else {
        sanitize_line_text(
            &words
                .iter()
                .map(|word| word.text.clone())
                .collect::<String>(),
        )
    };
    let (explicit_role, text) = detect_explicit_role(&raw_text);
    let translated_text = sanitize_line_text(line.translated_lyric.as_ref());
    let roman_text = sanitize_line_text(line.roman_lyric.as_ref());

    if text.is_empty() && translated_text.is_empty() && roman_text.is_empty() && words.is_empty() {
        return None;
    }

    let first_word_start_ms = words
        .first()
        .map(|word| word.start_ms)
        .unwrap_or(fallback_start_ms);
    let last_word_end_ms = words
        .last()
        .map(|word| word.end_ms)
        .unwrap_or(fallback_end_ms);

    Some(ParsedLine {
        start_ms: to_safe_ms(line.start_time, first_word_start_ms),
        end_ms: to_safe_ms(line.end_time, last_word_end_ms)
            .max(first_word_start_ms)
            .max(last_word_end_ms),
        text,
        words: if words.is_empty() { None } else { Some(words) },
        translated_text: if translated_text.is_empty() {
            None
        } else {
            Some(translated_text)
        },
        roman_text: if roman_text.is_empty() {
            None
        } else {
            Some(roman_text)
        },
        source_format,
        source_index: source_index as f64,
        explicit_role,
    })
}

fn collect_markers(text: &str, open: char, close: char) -> Vec<(usize, usize, u32)> {
    let mut result = Vec::new();
    let mut index = 0usize;

    while index < text.len() {
        if text[index..].starts_with(open) {
            if let Some(relative_end) = text[index + open.len_utf8()..].find(close) {
                let end = index + open.len_utf8() + relative_end;
                let raw = &text[index + open.len_utf8()..end];
                if let Some(timestamp) = parse_timestamp_to_ms(raw) {
                    result.push((index, end + close.len_utf8(), timestamp));
                    index = end + close.len_utf8();
                    continue;
                }
            }
        }

        if let Some(ch) = text[index..].chars().next() {
            index += ch.len_utf8();
        } else {
            break;
        }
    }

    result
}

fn parse_inline_square_timed_line(line: &str, source_index: usize) -> Option<ParsedLine> {
    let markers = collect_markers(line, '[', ']');
    if markers.len() < 2 {
        return None;
    }

    let words = markers
        .windows(2)
        .filter_map(|window| {
            let (_, current_end, current_start_ms) = window[0];
            let (next_start, _, next_start_ms) = window[1];
            let segment = &line[current_end..next_start];
            if segment.is_empty() {
                return None;
            }

            let text = sanitize_word_text(segment);
            if text.is_empty() {
                return None;
            }

            Some(ParsedWord {
                text,
                start_ms: current_start_ms,
                end_ms: next_start_ms.max(current_start_ms),
                roman_text: None,
            })
        })
        .collect::<Vec<_>>();

    if words.is_empty() {
        return None;
    }

    let text = sanitize_line_text(
        &words
            .iter()
            .map(|word| word.text.clone())
            .collect::<String>(),
    );
    if text.is_empty() {
        return None;
    }

    let (explicit_role, normalized_text) = detect_explicit_role(&text);
    let first_start = words.first()?.start_ms;
    let last_end = markers.last().map(|marker| marker.2).unwrap_or(first_start);

    Some(ParsedLine {
        start_ms: first_start,
        end_ms: last_end.max(first_start),
        text: normalized_text,
        words: Some(words),
        translated_text: None,
        roman_text: None,
        source_format: ParsedLineSourceFormat::Eslrc,
        source_index: source_index as f64,
        explicit_role,
    })
}

fn parse_enhanced_lrc_line(line: &str, source_index: usize) -> Option<ParsedLine> {
    let leading = collect_markers(line, '[', ']');
    let (_, body_start, line_start_ms) = *leading.first()?;
    let body = &line[body_start..];
    let markers = collect_markers(body, '<', '>');
    if markers.len() < 2 {
        return None;
    }

    if !body[..markers[0].0].trim().is_empty() {
        return None;
    }

    let mut words = Vec::new();
    for window in markers.windows(2) {
        let (_, current_end, current_start_ms) = window[0];
        let (next_start, _, next_start_ms) = window[1];
        let segment = &body[current_end..next_start];
        if segment.is_empty() {
            continue;
        }

        let text = sanitize_word_text(segment);
        if text.is_empty() {
            continue;
        }

        words.push(ParsedWord {
            text,
            start_ms: current_start_ms,
            end_ms: next_start_ms.max(current_start_ms),
            roman_text: None,
        });
    }

    if words.is_empty() {
        return None;
    }

    let text = sanitize_line_text(
        &words
            .iter()
            .map(|word| word.text.clone())
            .collect::<String>(),
    );
    let (explicit_role, normalized_text) = detect_explicit_role(&text);
    let end_ms = markers
        .last()
        .map(|marker| marker.2)
        .unwrap_or(line_start_ms);

    Some(ParsedLine {
        start_ms: line_start_ms,
        end_ms: end_ms.max(line_start_ms),
        text: normalized_text,
        words: Some(words),
        translated_text: None,
        roman_text: None,
        source_format: ParsedLineSourceFormat::EnhancedLrc,
        source_index: source_index as f64,
        explicit_role,
    })
}

fn parse_plain_lrc_line(line: &str, source_index: usize) -> Vec<ParsedLine> {
    let markers = collect_markers(line, '[', ']');
    if markers.is_empty() {
        return Vec::new();
    }

    let mut leading = Vec::new();
    let mut current_expected = 0usize;
    for marker in &markers {
        if marker.0 != current_expected {
            break;
        }
        leading.push(*marker);
        current_expected = marker.1;
    }

    if leading.is_empty() {
        return Vec::new();
    }

    let body = &line[current_expected..];
    if body.contains('<') && body.contains('>') {
        if let Some(parsed) = parse_enhanced_lrc_line(line, source_index) {
            return vec![parsed];
        }
    }

    if body.contains('[') && body.contains(']') {
        if let Some(parsed) = parse_inline_square_timed_line(line, source_index) {
            return vec![parsed];
        }
    }

    let (explicit_role, normalized_text) = detect_explicit_role(body);
    if normalized_text.is_empty() {
        return Vec::new();
    }

    leading
        .into_iter()
        .enumerate()
        .map(|(offset, (_, _, start_ms))| ParsedLine {
            start_ms,
            end_ms: start_ms.saturating_add(5000),
            text: normalized_text.clone(),
            words: None,
            translated_text: None,
            roman_text: None,
            source_format: ParsedLineSourceFormat::Lrc,
            source_index: source_index as f64 + (offset as f64 * 0.001),
            explicit_role: explicit_role.clone(),
        })
        .collect()
}

fn strip_xml_tags(raw: &str) -> String {
    let re = XML_TAG_RE.get_or_init(|| Regex::new(r"(?s)<[^>]+>").unwrap());
    sanitize_line_text(&re.replace_all(raw, "").to_string())
}

fn parse_ttml(raw: &str) -> Vec<ParsedLine> {
    let paragraph_re =
        TTML_PARAGRAPH_RE.get_or_init(|| Regex::new(r#"(?s)<p\b([^>]*)>(.*?)</p>"#).unwrap());
    let begin_re = TTML_BEGIN_RE.get_or_init(|| Regex::new(r#"(?i)\bbegin="([^"]+)""#).unwrap());
    let end_re = TTML_END_RE.get_or_init(|| Regex::new(r#"(?i)\bend="([^"]+)""#).unwrap());
    let span_re =
        TTML_SPAN_RE.get_or_init(|| Regex::new(r#"(?s)<span\b([^>]*)>(.*?)</span>"#).unwrap());
    let role_re = TTML_ROLE_RE.get_or_init(|| Regex::new(r#"(?i)\bttm:role="([^"]+)""#).unwrap());

    let mut lines = Vec::new();

    for (index, captures) in paragraph_re.captures_iter(raw).enumerate() {
        let attrs = captures
            .get(1)
            .map(|value| value.as_str())
            .unwrap_or_default();
        let body = captures
            .get(2)
            .map(|value| value.as_str())
            .unwrap_or_default();
        let begin = begin_re
            .captures(attrs)
            .and_then(|caps| caps.get(1).map(|value| value.as_str().to_string()))
            .and_then(|value| parse_ttml_clock_to_ms(&value));
        let Some(start_ms) = begin else {
            continue;
        };
        let end_ms = end_re
            .captures(attrs)
            .and_then(|caps| caps.get(1).map(|value| value.as_str().to_string()))
            .and_then(|value| parse_ttml_clock_to_ms(&value))
            .unwrap_or(start_ms.saturating_add(5000));

        let mut translation_text = None;
        let mut roman_text = None;
        for span in span_re.captures_iter(body) {
            let span_attrs = span.get(1).map(|value| value.as_str()).unwrap_or_default();
            let span_body = span.get(2).map(|value| value.as_str()).unwrap_or_default();
            let role = role_re
                .captures(span_attrs)
                .and_then(|caps| caps.get(1).map(|value| value.as_str().to_lowercase()));
            let content = strip_xml_tags(span_body);

            match role.as_deref() {
                Some("x-translation") | Some("translation") => {
                    if !content.is_empty() {
                        translation_text = Some(content);
                    }
                }
                Some("x-roman")
                | Some("roman")
                | Some("romanization")
                | Some("transliteration") => {
                    if !content.is_empty() {
                        roman_text = Some(content);
                    }
                }
                _ => {}
            }
        }

        let mut main_body = body.to_string();
        for span in span_re.captures_iter(body) {
            if let Some(full) = span.get(0) {
                let replacement = match role_re
                    .captures(span.get(1).map(|value| value.as_str()).unwrap_or_default())
                    .and_then(|caps| caps.get(1).map(|value| value.as_str().to_lowercase()))
                    .as_deref()
                {
                    Some("x-translation")
                    | Some("translation")
                    | Some("x-roman")
                    | Some("roman")
                    | Some("romanization")
                    | Some("transliteration") => String::new(),
                    _ => {
                        strip_xml_tags(span.get(2).map(|value| value.as_str()).unwrap_or_default())
                    }
                };
                main_body = main_body.replacen(full.as_str(), &replacement, 1);
            }
        }

        let (explicit_role, text) = detect_explicit_role(&strip_xml_tags(&main_body));
        if text.is_empty() && translation_text.is_none() && roman_text.is_none() {
            continue;
        }

        lines.push(ParsedLine {
            start_ms,
            end_ms,
            text,
            words: None,
            translated_text: translation_text,
            roman_text,
            source_format: ParsedLineSourceFormat::Ttml,
            source_index: index as f64,
            explicit_role,
        });
    }

    lines
}

fn parse_manual_lrc_like(raw: &str) -> Vec<ParsedLine> {
    let mut lines = Vec::new();
    for (index, line) in raw.lines().enumerate() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        if let Some(parsed) = parse_enhanced_lrc_line(trimmed, index) {
            lines.push(parsed);
            continue;
        }

        lines.extend(parse_plain_lrc_line(trimmed, index));
    }

    lines
}

fn collect_candidate(
    candidates: &mut Vec<ParserCandidate>,
    source: ParsedLineSourceFormat,
    mut lines: Vec<ParsedLine>,
) {
    if lines.is_empty() {
        return;
    }

    normalize_end_times(&mut lines);
    let candidate_source = if lines
        .iter()
        .any(|line| line.source_format == ParsedLineSourceFormat::EnhancedLrc)
    {
        // parse_manual_lrc_like 可以同时解析普通 LRC 与 LX 构建出的 Enhanced LRC。
        // 只要其中包含逐字 Enhanced LRC 行，候选排序就应按 EnhancedLrc 优先级参与竞争，
        // 否则可能被 amll 的 eslrc/lrc 候选抢走，导致前端拿不到稳定的 words。
        ParsedLineSourceFormat::EnhancedLrc
    } else {
        source
    };
    candidates.push(ParserCandidate {
        source: candidate_source,
        lines,
    });
}

/// KRC 词标签行 `[start,dur]<offset,dur,flag>文字` 转成 QRC
/// `[start,dur]文字(start+offset,dur)`。
///
/// 汽水/BakaMusic 等插件的翻译轨道是 KRC 原文，而 QRC/YRC 解析器只认
/// `word(start,dur)`，无词时间的行会被整行丢弃——英文主歌词配中文翻译
/// 时表现为翻译全部消失。
fn normalize_krc_word_tags(raw: &str) -> String {
    let full_line_re = KRC_FULL_LINE_RE.get_or_init(|| {
        Regex::new(r"^\[(\d+),(\d+)\]((?:<\d+,\d+,\d+>[^<]*)+)$").unwrap()
    });
    let tag_re = KRC_TAG_RE.get_or_init(|| Regex::new(r"<(\d+),(\d+),\d+>([^<]*)").unwrap());

    raw.lines()
        .map(|line| {
            let Some(caps) = full_line_re.captures(line) else {
                return line.to_string();
            };
            let start_ms: u64 = caps[1].parse().unwrap_or(0);
            let line_duration = &caps[2];
            let mut converted = String::new();
            for tag in tag_re.captures_iter(&caps[3]) {
                let offset_ms: u64 = tag[1].parse().unwrap_or(0);
                let duration_ms: u64 = tag[2].parse().unwrap_or(0);
                let text = tag[3].trim();
                if text.is_empty() {
                    continue;
                }
                converted.push_str(&text.replace('(', "（").replace(')', "）"));
                let _ = write!(converted, "({},{})", start_ms + offset_ms, duration_ms);
            }
            if converted.is_empty() {
                return line.to_string();
            }
            format!("[{start_ms},{line_duration}]{converted}")
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// 多段密文按行解密：Dart 侧把主歌词/翻译/罗马音的 hex 密文用换行拼接
/// 透传，整串解密会在段边界损坏 zlib 流——逐行独立解密，收集成功段落
/// 再拼接；无任何可解段时返回空串（调用方维持原候选流程）。
fn decrypt_multiline_hex(normalized: &str) -> String {
    let mut parts = Vec::new();
    for line in normalized.lines() {
        let line = line.trim();
        if line.len() <= 64 || line.len() % 2 != 0 {
            continue;
        }
        if !line.chars().all(|ch| ch.is_ascii_hexdigit()) {
            continue;
        }
        if let Ok(text) = crate::music::lyric_fetcher::qrc_decrypt(line) {
            if !text.trim().is_empty() {
                parts.push(text);
            }
        }
    }
    parts.join("\n")
}

/// 抽取 QQ 音乐 QRC 容器 XML 的歌词正文。
///
/// QRC 容器的正文放在 `LyricContent="…"` 属性的值里，多段歌词
/// （`Lyric_1` 主词、`Lyric_2` 翻译等）依次排列。逐行解析器只认
/// `[start,duration]` 正文行，直接喂整段容器会一行都解析不出。这里把所有
/// LyricContent 值按出现顺序取出、反转义 XML 实体后按换行拼接，交回常规
/// 解析管线（多段由时间轴合并）。不含 `LyricContent=` 时原样返回。
fn strip_qrc_container(raw: &str) -> String {
    if !raw.contains("LyricContent=") {
        return raw.to_string();
    }
    let mut parts = Vec::new();
    let mut rest = raw;
    while let Some(idx) = rest.find("LyricContent=") {
        let after = &rest[idx + "LyricContent=".len()..];
        let Some(quote) = after.chars().next() else {
            break;
        };
        if quote != '"' && quote != '\'' {
            // 不是属性赋值（如正文里出现的普通词），跳过继续找。
            rest = after;
            continue;
        }
        let body = &after[quote.len_utf8()..];
        let Some(end) = body.find(quote) else {
            break;
        };
        parts.push(unescape_xml_entities(&body[..end]));
        rest = &body[end + quote.len_utf8()..];
    }
    if parts.is_empty() {
        return raw.to_string();
    }
    parts.join("\n")
}

/// 反转义 QRC 容器属性里的 XML 实体（`&amp;` 必须最后处理，避免二次反转义）。
fn unescape_xml_entities(input: &str) -> String {
    if !input.contains('&') {
        return input.to_string();
    }
    input
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&#10;", "\n")
        .replace("&#13;", "")
        .replace("&amp;", "&")
}

fn parse_raw_lyrics(raw: &str) -> Vec<ParsedLine> {
    let normalized = normalize_krc_word_tags(
        &raw
            .replace('\u{FEFF}', "")
            .replace("\r\n", "\n")
            .replace('\r', "\n"),
    );
    // QQ 音乐 QRC 容器包装（`<QrcInfos>…<Lyric_1 LyricContent="…"/>`）：
    // 逐行解析器只认 `[start,duration]` 正文行，会把整段容器判成无歌词。
    // 先抽取 LyricContent（含 XML 实体反转义）再走常规格式分派。
    let normalized = strip_qrc_container(&normalized);

    let mut candidates = Vec::new();

    if normalized.contains("<tt") {
        collect_candidate(
            &mut candidates,
            ParsedLineSourceFormat::Ttml,
            parse_ttml(&normalized),
        );
    }

    let compact_hex = normalized.split_whitespace().collect::<String>();
    if compact_hex.len() > 64
        && compact_hex.len() % 2 == 0
        && compact_hex.chars().all(|ch| ch.is_ascii_hexdigit())
    {
        // QQ 密文（crypt:1）解密产物有两种形态：QRC XML（qrc:1 逐字）与
        // 普通 LRC（qrc:0，如《沧浪歌》）。只喂 parse_qrc 会让后者解析为
        // 空——整首歌无歌词。这里把解密文本重新送入完整解析管线（对齐
        // 桌面端 decrypt_plugin_lyric → parseLyrics 链路）。
        // 输入可能是多段密文按行拼接（主歌词 + 翻译 + 罗马音，Dart 侧
        // _extractLyricsWithTranslation 透传）：整串解密失败时逐行解密
        // 再拼接，翻译行随主词一起进解析管线合并。
        let decrypted = crate::music::lyric_fetcher::qrc_decrypt(&compact_hex)
            .ok()
            .filter(|text| !text.trim().is_empty())
            .unwrap_or_else(|| decrypt_multiline_hex(&normalized));
        // 防再入：解密产物理论上必是明文歌词，仍呈长 hex 形态时说明是
        // 不可解的伪密文，跳过递归避免死循环。
        let compact_plain = decrypted.split_whitespace().collect::<String>();
        let plain_is_hex = compact_plain.len() > 64
            && compact_plain.len() % 2 == 0
            && compact_plain.chars().all(|ch| ch.is_ascii_hexdigit());
        if !decrypted.trim().is_empty() && !plain_is_hex {
            let nested = parse_raw_lyrics(&decrypted);
            if !nested.is_empty() {
                return nested;
            }
        }
        collect_candidate(
            &mut candidates,
            ParsedLineSourceFormat::Qrc,
            parse_qrc(&decrypt_qrc_hex(&compact_hex))
                .iter()
                .enumerate()
                .filter_map(|(index, line)| {
                    prepare_amll_line(line, ParsedLineSourceFormat::Qrc, index)
                })
                .collect(),
        );
    }

    collect_candidate(
        &mut candidates,
        ParsedLineSourceFormat::Yrc,
        parse_yrc(&normalized)
            .iter()
            .enumerate()
            .filter_map(|(index, line)| prepare_amll_line(line, ParsedLineSourceFormat::Yrc, index))
            .collect(),
    );

    collect_candidate(
        &mut candidates,
        ParsedLineSourceFormat::Qrc,
        parse_qrc(&normalized)
            .iter()
            .enumerate()
            .filter_map(|(index, line)| prepare_amll_line(line, ParsedLineSourceFormat::Qrc, index))
            .collect(),
    );

    collect_candidate(
        &mut candidates,
        ParsedLineSourceFormat::Lys,
        parse_lys(&normalized)
            .iter()
            .enumerate()
            .filter_map(|(index, line)| prepare_amll_line(line, ParsedLineSourceFormat::Lys, index))
            .collect(),
    );

    collect_candidate(
        &mut candidates,
        ParsedLineSourceFormat::Eslrc,
        parse_eslrc(&normalize_eslrc_source(&normalized))
            .iter()
            .enumerate()
            .filter_map(|(index, line)| {
                prepare_amll_line(line, ParsedLineSourceFormat::Eslrc, index)
            })
            .collect(),
    );

    collect_candidate(
        &mut candidates,
        ParsedLineSourceFormat::Lrc,
        parse_manual_lrc_like(&normalized),
    );

    candidates.sort_by(compare_parser_candidates);
    candidates
        .into_iter()
        .next()
        .map(|candidate| candidate.lines)
        .unwrap_or_default()
}

fn track_source_format(lines: &[LyricTrackLine]) -> LyricTrackSourceFormat {
    let mut formats = lines
        .iter()
        .map(|line| map_track_source_format(&line.source_format))
        .collect::<Vec<_>>();
    formats.dedup();

    if formats.len() == 1 {
        formats[0].clone()
    } else {
        LyricTrackSourceFormat::Mixed
    }
}

fn track_timing_mode(lines: &[LyricTrackLine]) -> LyricTimingMode {
    if lines.iter().any(|line| {
        line.words
            .as_ref()
            .map(|words| !words.is_empty())
            .unwrap_or(false)
    }) {
        return LyricTimingMode::Word;
    }
    if !lines.is_empty() {
        return LyricTimingMode::Line;
    }
    LyricTimingMode::None
}

fn track_dominant_script(lines: &[LyricTrackLine]) -> DominantScript {
    let latin_count = lines
        .iter()
        .map(|line| line.script_profile.latin_count)
        .sum::<u32>();
    let han_count = lines
        .iter()
        .map(|line| line.script_profile.han_count)
        .sum::<u32>();
    let kana_count = lines
        .iter()
        .map(|line| line.script_profile.kana_count)
        .sum::<u32>();
    let hangul_count = lines
        .iter()
        .map(|line| line.script_profile.hangul_count)
        .sum::<u32>();
    resolve_dominant_script(latin_count, han_count, kana_count, hangul_count)
}

fn build_candidate_lines(lines: &[ParsedLine]) -> Vec<LyricTrackLine> {
    let mut candidates = Vec::new();

    for (index, line) in lines.iter().enumerate() {
        if !line.text.is_empty() {
            candidates.push(LyricTrackLine {
                id: format!("parsed:{index}:main"),
                start_ms: line.start_ms,
                end_ms: line.end_ms.max(line.start_ms),
                text: line.text.clone(),
                words: line.words.clone(),
                source_index: line.source_index,
                explicit_role: line.explicit_role.clone(),
                role_source: Some(if line.explicit_role.is_some() {
                    ClassificationConfidence::Explicit
                } else {
                    ClassificationConfidence::Heuristic
                }),
                cluster_index: None,
                slot_index: None,
                source_format: line.source_format.clone(),
                script_profile: get_line_script_profile(&line.text),
            });
        }

        if let Some(translation) = line
            .translated_text
            .as_ref()
            .filter(|text| !text.trim().is_empty())
        {
            candidates.push(LyricTrackLine {
                id: format!("parsed:{index}:translation"),
                start_ms: line.start_ms,
                end_ms: line.end_ms.max(line.start_ms),
                text: sanitize_line_text(translation),
                words: None,
                source_index: line.source_index + 0.1,
                explicit_role: Some(ExplicitLineRole::Translation),
                role_source: Some(ClassificationConfidence::ParserNative),
                cluster_index: None,
                slot_index: None,
                source_format: line.source_format.clone(),
                script_profile: get_line_script_profile(translation),
            });
        }

        let roman_from_words = line.words.as_ref().and_then(|words| {
            let roman_words = words
                .iter()
                .filter_map(|word| {
                    word.roman_text
                        .as_ref()
                        .filter(|text| !text.trim().is_empty())
                        .map(|text| ParsedWord {
                            text: text.clone(),
                            start_ms: word.start_ms,
                            end_ms: word.end_ms,
                            roman_text: None,
                        })
                })
                .collect::<Vec<_>>();
            if roman_words.is_empty() {
                None
            } else {
                Some(roman_words)
            }
        });

        let roman_text = line
            .roman_text
            .clone()
            .filter(|text| !text.trim().is_empty())
            .or_else(|| {
                roman_from_words.as_ref().map(|words| {
                    words
                        .iter()
                        .map(|word| word.text.clone())
                        .collect::<String>()
                })
            });

        if let Some(roman_text) = roman_text.filter(|text| !text.trim().is_empty()) {
            candidates.push(LyricTrackLine {
                id: format!("parsed:{index}:roman"),
                start_ms: line.start_ms,
                end_ms: line.end_ms.max(line.start_ms),
                text: sanitize_line_text(&roman_text),
                words: roman_from_words.clone(),
                source_index: line.source_index + 0.2,
                explicit_role: Some(ExplicitLineRole::Roman),
                role_source: Some(ClassificationConfidence::ParserNative),
                cluster_index: None,
                slot_index: None,
                source_format: line.source_format.clone(),
                script_profile: get_line_script_profile(&roman_text),
            });
        }
    }

    candidates.sort_by(|left, right| {
        left.start_ms
            .cmp(&right.start_ms)
            .then_with(|| compare_source_index(left.source_index, right.source_index))
            .then_with(|| left.end_ms.cmp(&right.end_ms))
    });

    candidates
}

fn get_effective_tolerance(
    current_start_ms: u32,
    prev_start_ms: Option<u32>,
    next_start_ms: Option<u32>,
) -> u32 {
    let prev_gap = prev_start_ms
        .map(|start| current_start_ms.abs_diff(start))
        .unwrap_or(u32::MAX);
    let next_gap = next_start_ms
        .map(|start| current_start_ms.abs_diff(start))
        .unwrap_or(u32::MAX);

    MAX_GROUP_TOLERANCE_MS.min(prev_gap / 4).min(next_gap / 4)
}

fn find_context_start(
    lines: &[LyricTrackLine],
    origin_index: usize,
    direction: isize,
) -> Option<u32> {
    let origin_start_ms = lines[origin_index].start_ms;
    let mut index = origin_index as isize + direction;

    while index >= 0 && index < lines.len() as isize {
        let candidate = &lines[index as usize];
        if candidate.start_ms.abs_diff(origin_start_ms) > MAX_GROUP_TOLERANCE_MS {
            return Some(candidate.start_ms);
        }
        index += direction;
    }

    None
}

fn should_keep_separate_for_script_similarity(
    group: &[LyricTrackLine],
    candidate: &LyricTrackLine,
) -> bool {
    if candidate.start_ms
        == group
            .first()
            .map(|line| line.start_ms)
            .unwrap_or(candidate.start_ms)
    {
        return false;
    }
    if group.iter().any(|line| line.explicit_role.is_some()) || candidate.explicit_role.is_some() {
        return false;
    }

    if is_japanese_like(&candidate.script_profile) {
        return group
            .iter()
            .any(|line| is_japanese_like(&line.script_profile));
    }

    if matches!(
        candidate.script_profile.dominant_script,
        DominantScript::Mixed | DominantScript::Other
    ) {
        return false;
    }

    group
        .iter()
        .any(|line| line.script_profile.dominant_script == candidate.script_profile.dominant_script)
}

fn group_candidate_lines(lines: &[LyricTrackLine]) -> Vec<Vec<LyricTrackLine>> {
    if lines.is_empty() {
        return Vec::new();
    }

    let mut groups: Vec<Vec<LyricTrackLine>> = Vec::new();
    let mut group_start_index = 0usize;

    for (index, line) in lines.iter().enumerate() {
        if groups.is_empty() {
            groups.push(vec![line.clone()]);
            group_start_index = index;
            continue;
        }

        let current_group = match groups.last_mut() {
            Some(g) => g,
            None => {
                groups.push(vec![line.clone()]);
                group_start_index = index;
                continue;
            }
        };
        if current_group.len() >= MAX_GROUP_SIZE {
            groups.push(vec![line.clone()]);
            group_start_index = index;
            continue;
        }

        let tolerance = get_effective_tolerance(
            lines[group_start_index].start_ms,
            find_context_start(lines, group_start_index, -1),
            find_context_start(lines, group_start_index, 1),
        );
        let drift = line.start_ms.abs_diff(current_group[0].start_ms);
        let cross_language = is_cross_language_pair(current_group, line);
        let within_tolerance = if cross_language {
            drift <= CROSS_LANGUAGE_GROUP_TOLERANCE_MS
        } else {
            drift <= tolerance
        };

        if within_tolerance
            && (cross_language
                || !should_keep_separate_for_script_similarity(current_group, line))
        {
            current_group.push(line.clone());
            continue;
        }

        groups.push(vec![line.clone()]);
        group_start_index = index;
    }

    groups
}

fn track_role_hint(track: &LyricTrack) -> Option<LyricTrackRole> {
    let translation_count = track
        .lines
        .iter()
        .filter(|line| line.explicit_role == Some(ExplicitLineRole::Translation))
        .count();
    let romanization_count = track
        .lines
        .iter()
        .filter(|line| line.explicit_role == Some(ExplicitLineRole::Roman))
        .count();

    if translation_count == 0 && romanization_count == 0 {
        return None;
    }

    if translation_count >= romanization_count {
        Some(LyricTrackRole::Translation)
    } else {
        Some(LyricTrackRole::Romanization)
    }
}

fn score_script_compatibility(track: &LyricTrack, candidate: &LyricTrackLine) -> f64 {
    if track.dominant_script == candidate.script_profile.dominant_script {
        return 4.0;
    }
    if track.dominant_script == DominantScript::Han
        && has_han_translation_content(&candidate.script_profile)
    {
        return 2.8;
    }
    if matches!(
        track.dominant_script,
        DominantScript::Mixed | DominantScript::Other
    ) || matches!(
        candidate.script_profile.dominant_script,
        DominantScript::Mixed | DominantScript::Other
    ) {
        return 1.2;
    }

    let family = |script: &DominantScript| match script {
        DominantScript::Latin => "latin",
        DominantScript::Han | DominantScript::Kana | DominantScript::Mixed => "cjk",
        DominantScript::Hangul => "hangul",
        DominantScript::Other => "other",
    };

    if family(&track.dominant_script) == family(&candidate.script_profile.dominant_script) {
        return 0.8;
    }

    -2.2
}

fn score_track_match(
    track: &LyricTrack,
    candidate: &LyricTrackLine,
    cluster_index: usize,
    slot_index: usize,
) -> f64 {
    let Some(last_line) = track.lines.last() else {
        return 0.0;
    };

    if last_line.cluster_index == Some(cluster_index) || candidate.start_ms <= last_line.start_ms {
        return f64::NEG_INFINITY;
    }

    let track_role_hint = track_role_hint(track);
    let candidate_role_hint = match candidate.explicit_role {
        Some(ExplicitLineRole::Translation) => Some(LyricTrackRole::Translation),
        Some(ExplicitLineRole::Roman) => Some(LyricTrackRole::Romanization),
        None => None,
    };
    if track_role_hint.is_some()
        && candidate_role_hint.is_some()
        && track_role_hint != candidate_role_hint
    {
        return f64::NEG_INFINITY;
    }

    let mut score = 0.0;
    if track_role_hint.is_some() && track_role_hint == candidate_role_hint {
        score += 6.0;
    }
    if track_role_hint.is_none() && candidate_role_hint.is_some() {
        score += 1.2;
    }

    score += score_script_compatibility(track, candidate);

    let average_slot = average(
        &track
            .lines
            .iter()
            .map(|line| line.slot_index.unwrap_or(0) as f64)
            .collect::<Vec<_>>(),
    );
    score += (-1.8f64).max(2.2 - ((average_slot - slot_index as f64).abs() * 1.35));

    let average_source_index = average(
        &track
            .lines
            .iter()
            .map(|line| line.source_index)
            .collect::<Vec<_>>(),
    );
    score += (-1.0f64).max(1.4 - ((average_source_index - candidate.source_index).abs() * 0.35));

    let cluster_gap =
        cluster_index.saturating_sub(last_line.cluster_index.unwrap_or(cluster_index));
    score += if cluster_gap == 1 { 1.2 } else { 0.4 };

    let time_gap = candidate.start_ms.saturating_sub(last_line.start_ms);
    if time_gap < 120
        && track.dominant_script == candidate.script_profile.dominant_script
        && candidate.explicit_role.is_none()
    {
        score -= 1.4;
    }

    score
}

fn build_tracks(groups: Vec<Vec<LyricTrackLine>>) -> Vec<LyricTrack> {
    let mut tracks: Vec<LyricTrack> = Vec::new();

    for (cluster_index, group) in groups.into_iter().enumerate() {
        let mut used_track_ids: Vec<String> = Vec::new();

        for (slot_index, candidate) in group.into_iter().enumerate() {
            let mut best_track_index = None;
            let mut best_score = f64::NEG_INFINITY;

            for (track_index, track) in tracks.iter().enumerate() {
                if used_track_ids.iter().any(|id| id == &track.id) {
                    continue;
                }

                let score = score_track_match(track, &candidate, cluster_index, slot_index);
                if score > best_score {
                    best_score = score;
                    best_track_index = Some(track_index);
                }
            }

            if best_track_index.is_none() || best_score < MIN_TRACK_MATCH_SCORE {
                let mut line = candidate.clone();
                line.cluster_index = Some(cluster_index);
                line.slot_index = Some(slot_index);

                let track = LyricTrack {
                    id: format!("track:{}", tracks.len()),
                    role: LyricTrackRole::Unknown,
                    lang: None,
                    timing_mode: track_timing_mode(&[line.clone()]),
                    source_format: map_track_source_format(&line.source_format),
                    confidence: 0.0,
                    dominant_script: line.script_profile.dominant_script.clone(),
                    lines: vec![line],
                    attachments: Vec::new(),
                    scores: None,
                };

                used_track_ids.push(track.id.clone());
                tracks.push(track);
                continue;
            }

            let track = match best_track_index.and_then(|idx| tracks.get_mut(idx)) {
                Some(t) => t,
                None => continue,
            };
            let mut line = candidate.clone();
            line.cluster_index = Some(cluster_index);
            line.slot_index = Some(slot_index);
            track.lines.push(line);
            track.dominant_script = track_dominant_script(&track.lines);
            track.source_format = track_source_format(&track.lines);
            track.timing_mode = track_timing_mode(&track.lines);
            used_track_ids.push(track.id.clone());
        }
    }

    tracks
}

fn score_pair_alignment(drift_ms: i64) -> f64 {
    let abs_drift = drift_ms.unsigned_abs() as u32;
    if abs_drift <= ALIGNMENT_HIGH_WINDOW_MS {
        1.0
    } else if abs_drift <= ALIGNMENT_MEDIUM_WINDOW_MS {
        0.72
    } else if abs_drift <= ALIGNMENT_LOW_WINDOW_MS {
        0.42
    } else {
        0.0
    }
}

fn compute_track_alignment(main_track: &LyricTrack, aux_track: &LyricTrack) -> TrackAlignment {
    let main_lines = &main_track.lines;
    let aux_lines = &aux_track.lines;
    let mut pairs = Vec::new();
    let mut main_index = 0usize;
    let mut aux_index = 0usize;

    while main_index < main_lines.len() && aux_index < aux_lines.len() {
        let main_line = &main_lines[main_index];
        let mut best_aux_index = None;
        let mut best_drift = i64::MAX;

        for index in aux_index..aux_lines.len() {
            let drift = aux_lines[index].start_ms as i64 - main_line.start_ms as i64;
            if drift.unsigned_abs() as u32 > ALIGNMENT_LOW_WINDOW_MS
                && aux_lines[index].start_ms > main_line.start_ms
            {
                break;
            }
            if drift.unsigned_abs() as u32 > ALIGNMENT_LOW_WINDOW_MS {
                continue;
            }
            if drift.abs() < best_drift.abs() {
                best_drift = drift;
                best_aux_index = Some(index);
            }
        }

        if let Some(found_index) = best_aux_index {
            pairs.push(TrackAlignmentPair {
                main_index,
                aux_index: found_index,
                drift_ms: best_drift,
                quality: score_pair_alignment(best_drift),
            });
            main_index += 1;
            aux_index = found_index + 1;
            continue;
        }

        if aux_lines[aux_index].start_ms + ALIGNMENT_LOW_WINDOW_MS < main_line.start_ms {
            aux_index += 1;
        } else {
            main_index += 1;
        }
    }

    let main_coverage = pairs.len() as f64 / main_lines.len().max(1) as f64;
    let aux_coverage = pairs.len() as f64 / aux_lines.len().max(1) as f64;
    let weighted_score = average(&pairs.iter().map(|pair| pair.quality).collect::<Vec<_>>())
        * main_coverage.min(aux_coverage);

    TrackAlignment {
        pairs,
        main_coverage,
        aux_coverage,
        weighted_score,
    }
}

fn tokenize_latin_words(text: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();

    for ch in text.chars().flat_map(|ch| ch.to_lowercase()) {
        if ch.is_ascii_alphabetic() || (ch == '\'' && !current.is_empty()) {
            current.push(ch);
        } else if !current.is_empty() {
            tokens.push(current.clone());
            current.clear();
        }
    }

    if !current.is_empty() {
        tokens.push(current);
    }

    tokens
}

fn looks_like_english_phrase(text: &str) -> bool {
    let tokens = tokenize_latin_words(text);
    if tokens.len() < 4 {
        return false;
    }

    let average_token_length =
        tokens.iter().map(|token| token.len() as f64).sum::<f64>() / tokens.len() as f64;
    let english_phrase_words = [
        "can", "give", "hey", "i", "kiss", "last", "love", "me", "more", "one", "than", "you",
        "your",
    ];
    let keyword_hits = tokens
        .iter()
        .filter(|token| english_phrase_words.contains(&token.as_str()))
        .count();

    average_token_length >= 3.0 && keyword_hits >= 2 && score_romanized_latin_text(text) < 0.42
}

fn looks_like_non_romaji_english_latin_text(text: &str) -> bool {
    let profile = get_line_script_profile(text);
    if profile.dominant_script != DominantScript::Latin {
        return false;
    }

    let tokens = tokenize_latin_words(text);
    if tokens.is_empty() {
        return false;
    }

    let lower = text.to_lowercase();
    let romanization = score_romanized_latin_text(text);
    let englishness = score_englishness(text);
    let english_hint_words = [
        "be", "believe", "but", "dream", "dreamt", "i", "leave", "need", "needing", "so", "still",
        "wait", "you", "yet",
    ];
    let hint_matches = tokens
        .iter()
        .filter(|token| english_hint_words.contains(&token.as_str()))
        .count();

    if CONTRACTION_RE
        .get_or_init(|| Regex::new(r"(?i)\b(i'm|you're|we're|it's|i'll|don't|can't)\b").unwrap())
        .is_match(text)
    {
        return true;
    }

    if tokens.iter().any(|token| token.contains('v')) {
        return true;
    }

    if ENGLISH_DIGRAPH_RE
        .get_or_init(|| Regex::new(r"(th|gh|ph|wh|ck|ee|oo)").unwrap())
        .is_match(&lower)
    {
        return romanization < 0.52 || hint_matches > 0;
    }

    if ENGLISH_CONSONANT_RE
        .get_or_init(|| Regex::new(r"(str|scr|dr|st|mp?t)").unwrap())
        .is_match(&lower)
    {
        return romanization < 0.52 || hint_matches > 0;
    }

    let has_english_word_ending = tokens.iter().any(|token| {
        token.len() > 1
            && token
                .chars()
                .last()
                .map(|last| {
                    matches!(
                        last,
                        'd' | 't' | 'l' | 'p' | 'm' | 'k' | 'g' | 'f' | 's' | 'z' | 'r'
                    )
                })
                .unwrap_or(false)
    });

    has_english_word_ending && (hint_matches >= 2 || englishness >= romanization + 0.12)
}

fn score_englishness(text: &str) -> f64 {
    let tokens = tokenize_latin_words(text);
    if tokens.is_empty() {
        return 0.0;
    }

    let english_hint_words = [
        "a", "all", "am", "and", "are", "be", "care", "do", "for", "had", "have", "hello", "i",
        "in", "is", "it", "know", "love", "me", "my", "not", "of", "on", "that", "the", "there",
        "to", "want", "we", "with", "you", "your",
    ];
    let hint_matches = tokens
        .iter()
        .filter(|token| english_hint_words.contains(&token.as_str()))
        .count() as f64;
    let contraction_bonus = if CONTRACTION_RE
        .get_or_init(|| Regex::new(r"(?i)\b(i'm|you're|we're|it's|i'll|don't|can't)\b").unwrap())
        .is_match(text)
    {
        0.15
    } else {
        0.0
    };

    clamp01((hint_matches / tokens.len() as f64) * 0.85 + contraction_bonus)
}

fn score_romanized_latin_text(text: &str) -> f64 {
    let profile = get_line_script_profile(text);
    if profile.dominant_script != DominantScript::Latin {
        return 0.0;
    }

    let tokens = tokenize_latin_words(text);
    if tokens.is_empty() {
        return 0.0;
    }

    let roman_re = ROMANIZATION_RE.get_or_init(|| Regex::new(
        r"(?i)(shi|chi|tsu?|kyo|ryo|ryu|nya|hya|gya|sha|sya|jya|ja|yeo|gye|sarang|geudae|uri|nani|kimo|kimi|watashi|boku|anata|kara|made|desu|xiang|zh|ch|sh|ang|eng|ing|ong|iao|ian|uan|uang|yuan|yin|ying|xin|meng)",
    ).unwrap());
    let roman_pattern_ratio = tokens
        .iter()
        .filter(|token| roman_re.is_match(token))
        .count() as f64
        / tokens.len() as f64;
    let short_token_ratio =
        tokens.iter().filter(|token| token.len() <= 4).count() as f64 / tokens.len() as f64;
    let syllable_ending_ratio = tokens
        .iter()
        .filter(|token| {
            token.ends_with(['a', 'e', 'i', 'o', 'u'])
                || token.ends_with('n')
                || token.ends_with("ng")
        })
        .count() as f64
        / tokens.len() as f64;
    let vowel_ratio = average(
        &tokens
            .iter()
            .map(|token| {
                let vowels = token
                    .chars()
                    .filter(|ch| matches!(ch, 'a' | 'e' | 'i' | 'o' | 'u'))
                    .count() as f64;
                if token.is_empty() {
                    0.0
                } else {
                    vowels / token.len() as f64
                }
            })
            .collect::<Vec<_>>(),
    );
    let token_count_penalty = if tokens.len() == 1 {
        0.25
    } else if tokens.len() == 2 {
        0.1
    } else {
        0.0
    };
    let englishness = score_englishness(text);

    clamp01(
        (roman_pattern_ratio * 0.45)
            + (short_token_ratio * 0.2)
            + (syllable_ending_ratio * if tokens.len() >= 3 { 0.14 } else { 0.06 })
            + (vowel_ratio * 0.22)
            + if tokens.iter().any(|token| token.len() == 1) {
                0.08
            } else {
                0.0
            }
            - token_count_penalty
            - (englishness * 0.62),
    )
}

fn score_track_englishness(track: &LyricTrack) -> f64 {
    average(
        &track
            .lines
            .iter()
            .map(|line| score_englishness(&line.text))
            .collect::<Vec<_>>(),
    )
}

fn score_track_romanization(track: &LyricTrack) -> f64 {
    average(
        &track
            .lines
            .iter()
            .map(|line| score_romanized_latin_text(&line.text))
            .collect::<Vec<_>>(),
    )
}

fn score_track_roles(
    main_track: &LyricTrack,
    candidate_track: &LyricTrack,
    alignment: &TrackAlignment,
) -> TrackRoleScores {
    let role_hint = track_role_hint(candidate_track);
    let englishness = score_track_englishness(candidate_track);
    let romanization = score_track_romanization(candidate_track);

    let mut translation = alignment.weighted_score * 0.6;
    let mut roman = alignment.weighted_score * 0.6;

    if candidate_track.dominant_script != main_track.dominant_script {
        translation += 0.16;
    }
    if candidate_track.dominant_script == DominantScript::Han
        && main_track.dominant_script != DominantScript::Han
    {
        translation += 0.18;
    }
    if candidate_track.dominant_script == DominantScript::Latin && englishness > 0.28 {
        translation += 0.18;
    }
    translation += englishness * 0.22;
    translation -= romanization * 0.3;
    if candidate_track.dominant_script == main_track.dominant_script {
        translation -= 0.18;
    }

    if main_track.dominant_script != DominantScript::Latin
        && candidate_track.dominant_script == DominantScript::Latin
    {
        roman += 0.32;
    } else if main_track.dominant_script == DominantScript::Latin {
        roman -= 0.55;
    } else {
        roman -= 0.15;
    }
    roman += romanization * 0.38;
    roman -= englishness * 0.38;
    if candidate_track.dominant_script != DominantScript::Latin {
        roman -= 0.28;
    }

    if role_hint == Some(LyricTrackRole::Translation) {
        translation += 0.85;
    }
    if role_hint == Some(LyricTrackRole::Romanization) {
        roman += 0.85;
    }

    let has_direct_grouped_pair = alignment.pairs.iter().any(|pair| {
        main_track.lines[pair.main_index].cluster_index.is_some()
            && main_track.lines[pair.main_index].cluster_index
                == candidate_track.lines[pair.aux_index].cluster_index
    });
    if alignment.pairs.len() == 1 && !has_direct_grouped_pair && role_hint.is_none() {
        translation *= 0.5;
        roman *= 0.4;
    }

    TrackRoleScores {
        main: 0.0,
        translation: clamp01(translation),
        romanization: clamp01(roman),
    }
}

fn shared_source_origin_match_ratio(
    main_track: &LyricTrack,
    aux_track: &LyricTrack,
    alignment: &TrackAlignment,
    role_source: Option<ClassificationConfidence>,
) -> f64 {
    if alignment.pairs.is_empty() {
        return 0.0;
    }

    let matched_pairs = alignment
        .pairs
        .iter()
        .filter(|pair| {
            let main_line = &main_track.lines[pair.main_index];
            let aux_line = &aux_track.lines[pair.aux_index];
            if role_source.is_some() && aux_line.role_source != role_source {
                return false;
            }

            main_line.source_index.floor() as i64 == aux_line.source_index.floor() as i64
        })
        .count();

    matched_pairs as f64 / alignment.pairs.len() as f64
}

fn score_main_track(
    candidate_track: &LyricTrack,
    tracks: &[LyricTrack],
    alignments: &[Vec<TrackAlignment>],
    track_index: usize,
) -> f64 {
    let max_line_count = tracks
        .iter()
        .map(|track| track.lines.len())
        .max()
        .unwrap_or(1) as f64;
    let max_slot = tracks
        .iter()
        .flat_map(|track| track.lines.iter().map(|line| line.slot_index.unwrap_or(0)))
        .max()
        .unwrap_or(0) as f64;
    let role_hint = track_role_hint(candidate_track);
    let average_slot = average(
        &candidate_track
            .lines
            .iter()
            .map(|line| line.slot_index.unwrap_or(0) as f64)
            .collect::<Vec<_>>(),
    );
    let average_source_index = average(
        &candidate_track
            .lines
            .iter()
            .map(|line| line.source_index)
            .collect::<Vec<_>>(),
    );
    let word_coverage = candidate_track
        .lines
        .iter()
        .filter(|line| {
            line.words
                .as_ref()
                .map(|words| !words.is_empty())
                .unwrap_or(false)
        })
        .count() as f64
        / candidate_track.lines.len().max(1) as f64;

    let mut score = 0.0;
    score += (candidate_track.lines.len() as f64 / max_line_count) * 3.0;
    score += word_coverage * 1.4;
    score += if max_slot > 0.0 {
        (1.0 - (average_slot / max_slot)) * 1.2
    } else {
        1.0
    };

    if matches!(
        role_hint,
        Some(LyricTrackRole::Translation | LyricTrackRole::Romanization)
    ) {
        score -= 4.0;
    }

    let has_romanized_latin_sibling = tracks.iter().enumerate().any(|(other_index, track)| {
        if other_index == track_index {
            return false;
        }
        let alignment = &alignments[track_index][other_index];
        alignment.weighted_score >= 0.35
            && track.dominant_script == DominantScript::Latin
            && score_track_romanization(track) >= 0.35
    });
    let has_japanese_like_sibling = tracks.iter().enumerate().any(|(other_index, track)| {
        other_index != track_index
            && alignments[track_index][other_index].weighted_score >= 0.35
            && track_has_japanese_like_lines(track)
    });
    let has_any_romanized_latin_track = tracks.iter().any(|track| {
        track.dominant_script == DominantScript::Latin && score_track_romanization(track) >= 0.35
    });
    let has_any_japanese_like_track = tracks
        .iter()
        .any(|track| track_has_japanese_like_lines(track));

    let mut attachment_support = 0.0;
    for (other_index, track) in tracks.iter().enumerate() {
        if other_index == track_index {
            continue;
        }
        let alignment = &alignments[track_index][other_index];
        if alignment.weighted_score < 0.28 {
            continue;
        }
        let role_scores = score_track_roles(candidate_track, track, alignment);
        attachment_support += role_scores.translation.max(role_scores.romanization);
    }
    score += attachment_support.min(3.0);

    score += tracks
        .iter()
        .enumerate()
        .filter(|(other_index, _)| *other_index != track_index)
        .map(|(other_index, track)| {
            let alignment = &alignments[track_index][other_index];
            if alignment.weighted_score < 0.28 {
                0.0
            } else {
                shared_source_origin_match_ratio(
                    candidate_track,
                    track,
                    alignment,
                    Some(ClassificationConfidence::ParserNative),
                ) * 3.2
            }
        })
        .sum::<f64>()
        .min(2.0);

    if candidate_track.dominant_script != DominantScript::Latin && has_romanized_latin_sibling {
        score += 3.2;
    }

    if (has_japanese_like_sibling && has_romanized_latin_sibling)
        || (has_any_japanese_like_track && has_any_romanized_latin_track)
    {
        score += (1.2 - average_slot) * 1.8;
        if track_has_japanese_like_lines(candidate_track) {
            score += 4.8;
        } else if candidate_track.dominant_script == DominantScript::Han {
            score -= 5.2;
            if average_source_index > 1.15 {
                score -= 1.2;
            }
        }
    }

    if candidate_track.dominant_script == DominantScript::Latin
        && score_track_englishness(candidate_track) < 0.28
        && score_track_romanization(candidate_track) >= 0.28
        && tracks.iter().enumerate().any(|(other_index, track)| {
            other_index != track_index
                && alignments[track_index][other_index].weighted_score >= 0.45
                && track.dominant_script != DominantScript::Latin
        })
    {
        score -= 4.2;
    }

    score
}

fn track_confidence(role: &LyricTrackRole, scores: &TrackRoleScores) -> f64 {
    match role {
        LyricTrackRole::Main => clamp01(scores.main / 6.0),
        LyricTrackRole::Translation => scores.translation,
        LyricTrackRole::Romanization => scores.romanization,
        LyricTrackRole::Secondary => scores.translation.max(scores.romanization) * 0.7,
        LyricTrackRole::AlternateMain => clamp01(scores.main / 6.0),
        _ => 0.25,
    }
}

fn is_han_translation_track(track: &LyricTrack) -> bool {
    track.dominant_script == DominantScript::Han && !track_has_japanese_like_lines(track)
}

fn has_han_translation_content(profile: &LineScriptProfile) -> bool {
    profile.han_count > 0 && profile.kana_count == 0 && profile.hangul_count == 0
}

fn looks_like_romanization_track(track: &LyricTrack) -> bool {
    track.dominant_script == DominantScript::Latin
        && score_track_romanization(track) >= (score_track_englishness(track) + 0.05).max(0.34)
}

fn detect_japanese_with_romaji_translation_template(
    tracks: &[LyricTrack],
    alignments: &[Vec<TrackAlignment>],
) -> Option<LayoutTemplateResolution> {
    let japanese_candidates = tracks
        .iter()
        .enumerate()
        .filter(|(_, track)| track_has_japanese_like_lines(track))
        .map(|(index, _)| index)
        .collect::<Vec<_>>();
    let han_candidates = tracks
        .iter()
        .enumerate()
        .filter(|(_, track)| is_han_translation_track(track))
        .map(|(index, _)| index)
        .collect::<Vec<_>>();
    let latin_candidates = tracks
        .iter()
        .enumerate()
        .filter(|(_, track)| looks_like_romanization_track(track))
        .map(|(index, _)| index)
        .collect::<Vec<_>>();

    let mut best_resolution = None;
    let mut best_score = f64::NEG_INFINITY;

    for japanese_index in japanese_candidates {
        for han_index in &han_candidates {
            if *han_index == japanese_index {
                continue;
            }
            let translation_alignment = &alignments[japanese_index][*han_index];
            if translation_alignment.weighted_score < 0.42 {
                continue;
            }

            for latin_index in &latin_candidates {
                if *latin_index == japanese_index || *latin_index == *han_index {
                    continue;
                }
                let roman_alignment = &alignments[japanese_index][*latin_index];
                if roman_alignment.weighted_score < 0.42 {
                    continue;
                }

                let latin_track = &tracks[*latin_index];
                let score = translation_alignment.weighted_score
                    + roman_alignment.weighted_score
                    + (tracks[japanese_index].lines.len() as f64
                        / latin_track.lines.len().max(1) as f64)
                        .min(1.0)
                    + track_word_coverage(&tracks[japanese_index]) * 0.4
                    + if track_role_hint(latin_track) == Some(LyricTrackRole::Romanization) {
                        0.35
                    } else {
                        0.0
                    };

                if score > best_score {
                    let mut track_roles = vec![None; tracks.len()];
                    track_roles[japanese_index] = Some(LyricTrackRole::Main);
                    track_roles[*han_index] = Some(LyricTrackRole::Translation);
                    track_roles[*latin_index] = Some(LyricTrackRole::Romanization);
                    best_score = score;
                    best_resolution = Some(LayoutTemplateResolution {
                        display_track_index: japanese_index,
                        track_roles,
                    });
                }
            }
        }
    }

    best_resolution
}

fn detect_main_with_translation_template(
    tracks: &[LyricTrack],
    alignments: &[Vec<TrackAlignment>],
) -> Option<LayoutTemplateResolution> {
    let translation_candidates = tracks
        .iter()
        .enumerate()
        .filter(|(_, track)| is_han_translation_track(track))
        .map(|(index, _)| index)
        .collect::<Vec<_>>();

    let mut best_resolution = None;
    let mut best_score = f64::NEG_INFINITY;

    for (main_index, main_track) in tracks.iter().enumerate() {
        let has_japanese_like_sibling = tracks.iter().enumerate().any(|(other_index, track)| {
            other_index != main_index
                && alignments[main_index][other_index].weighted_score >= 0.4
                && track_has_japanese_like_lines(track)
        });

        if is_han_translation_track(main_track)
            || (has_japanese_like_sibling && looks_like_romanization_track(main_track))
        {
            continue;
        }

        for translation_index in &translation_candidates {
            if *translation_index == main_index {
                continue;
            }
            let alignment = &alignments[main_index][*translation_index];
            if alignment.weighted_score < 0.42 {
                continue;
            }

            let score = alignment.weighted_score
                + (main_track.lines.len() as f64
                    / tracks[*translation_index].lines.len().max(1) as f64)
                    .min(1.0)
                + track_word_coverage(main_track) * 0.35
                + if track_role_hint(&tracks[*translation_index])
                    == Some(LyricTrackRole::Translation)
                {
                    0.2
                } else {
                    0.0
                };

            if score > best_score {
                let mut track_roles = vec![None; tracks.len()];
                track_roles[main_index] = Some(LyricTrackRole::Main);
                track_roles[*translation_index] = Some(LyricTrackRole::Translation);
                best_score = score;
                best_resolution = Some(LayoutTemplateResolution {
                    display_track_index: main_index,
                    track_roles,
                });
            }
        }
    }

    best_resolution
}

fn detect_layout_template(
    tracks: &[LyricTrack],
    alignments: &[Vec<TrackAlignment>],
) -> Option<LayoutTemplateResolution> {
    if tracks.is_empty() {
        return None;
    }

    if tracks.len() == 1 {
        return Some(LayoutTemplateResolution {
            display_track_index: 0,
            track_roles: vec![Some(LyricTrackRole::Main)],
        });
    }

    detect_japanese_with_romaji_translation_template(tracks, alignments)
        .or_else(|| detect_main_with_translation_template(tracks, alignments))
}

fn resolve_semantic_confidence(lines: &[Option<&LyricTrackLine>]) -> ClassificationConfidence {
    if lines.iter().any(|line| {
        line.and_then(|value| value.role_source.clone()) == Some(ClassificationConfidence::Explicit)
    }) {
        ClassificationConfidence::Explicit
    } else if lines.iter().any(|line| {
        line.and_then(|value| value.role_source.clone())
            == Some(ClassificationConfidence::ParserNative)
    }) {
        ClassificationConfidence::ParserNative
    } else {
        ClassificationConfidence::Heuristic
    }
}

fn should_attach_aligned_pair(
    main_track: &LyricTrack,
    aux_track: &LyricTrack,
    alignment: &TrackAlignment,
    pair: &TrackAlignmentPair,
) -> bool {
    let main_line = &main_track.lines[pair.main_index];
    let aux_line = &aux_track.lines[pair.aux_index];

    if pair.drift_ms.unsigned_abs() as u32 <= MAX_GROUP_TOLERANCE_MS {
        return true;
    }
    if main_line.cluster_index.is_some() && main_line.cluster_index == aux_line.cluster_index {
        return true;
    }
    if matches!(
        aux_line.role_source,
        Some(ClassificationConfidence::Explicit | ClassificationConfidence::ParserNative)
    ) {
        return true;
    }

    alignment.main_coverage >= 0.75
        && alignment.aux_coverage >= 0.75
        && pair.drift_ms.unsigned_abs() as u32 <= ALIGNMENT_HIGH_WINDOW_MS
}

fn build_aligned_roman_words(
    main_line: &LyricTrackLine,
    roman_line: Option<&LyricTrackLine>,
) -> Option<Vec<ParsedWord>> {
    if let Some(main_words) = &main_line.words {
        if main_words.iter().any(|word| {
            word.roman_text
                .as_ref()
                .map(|text| !text.is_empty())
                .unwrap_or(false)
        }) {
            let roman_words = main_words
                .iter()
                .filter_map(|word| {
                    word.roman_text
                        .as_ref()
                        .filter(|text| !text.is_empty())
                        .map(|text| ParsedWord {
                            text: text.clone(),
                            start_ms: word.start_ms,
                            end_ms: word.end_ms,
                            roman_text: None,
                        })
                })
                .collect::<Vec<_>>();
            if !roman_words.is_empty() {
                return Some(roman_words);
            }
        }
    }

    let main_words = main_line.words.as_ref()?;
    let roman_words = roman_line?.words.as_ref()?;
    if main_words.len() != roman_words.len() {
        return Some(roman_words.clone());
    }

    let aligned = main_words
        .iter()
        .zip(roman_words.iter())
        .all(|(main_word, roman_word)| {
            main_word.start_ms.abs_diff(roman_word.start_ms) <= 120
                && main_word.end_ms.abs_diff(roman_word.end_ms) <= 120
        });

    if aligned {
        Some(roman_words.clone())
    } else {
        Some(roman_words.clone())
    }
}

fn push_secondary_text(secondary_texts: &mut Option<Vec<String>>, text: String) {
    if text.is_empty() {
        return;
    }
    let values = secondary_texts.get_or_insert_with(Vec::new);
    if !values.iter().any(|value| value == &text) {
        values.push(text);
    }
}

fn should_use_line_as_romaji(
    main_line: &LyricTrackLine,
    candidate_track: &LyricTrack,
    candidate_line: &LyricTrackLine,
) -> bool {
    if matches!(
        candidate_track.role,
        LyricTrackRole::Romanization | LyricTrackRole::Secondary
    ) && candidate_line.explicit_role == Some(ExplicitLineRole::Roman)
    {
        return true;
    }
    if candidate_track.role == LyricTrackRole::Romanization {
        return true;
    }
    if candidate_line.script_profile.dominant_script != DominantScript::Latin {
        return false;
    }
    if main_line.script_profile.dominant_script == DominantScript::Latin
        && !is_japanese_like(&main_line.script_profile)
    {
        return false;
    }

    let englishness = score_englishness(&candidate_line.text);
    let romanization = score_romanized_latin_text(&candidate_line.text);

    romanization >= englishness
        || (candidate_line.source_index < main_line.source_index
            && romanization + 0.08 >= englishness)
}

fn is_auxiliary_role_repair_track(track: &LyricTrack) -> bool {
    matches!(
        track.role,
        LyricTrackRole::Unknown | LyricTrackRole::Secondary | LyricTrackRole::AlternateMain
    )
}

fn should_use_line_as_translation(
    main_line: &LyricTrackLine,
    candidate_track: &LyricTrack,
    candidate_line: &LyricTrackLine,
) -> bool {
    if matches!(
        candidate_track.role,
        LyricTrackRole::Translation | LyricTrackRole::Secondary
    ) && candidate_line.explicit_role == Some(ExplicitLineRole::Translation)
    {
        return true;
    }
    if candidate_track.role == LyricTrackRole::Translation {
        return true;
    }
    if main_line.script_profile.dominant_script == DominantScript::Latin {
        return candidate_line.script_profile.dominant_script != DominantScript::Latin
            || (candidate_line.source_index > main_line.source_index
                && has_han_translation_content(&candidate_line.script_profile));
    }
    if candidate_line.script_profile.dominant_script == DominantScript::Latin {
        return false;
    }
    if candidate_line.source_index > main_line.source_index {
        return true;
    }

    candidate_line.script_profile.dominant_script == DominantScript::Han
        && is_japanese_like(&main_line.script_profile)
}

fn should_promote_japanese_auxiliary_as_main(
    current_main_line: &LyricTrackLine,
    candidate_line: &LyricTrackLine,
) -> bool {
    current_main_line.script_profile.dominant_script == DominantScript::Latin
        && is_japanese_like(&candidate_line.script_profile)
        && current_main_line.cluster_index.is_some()
        && current_main_line.cluster_index == candidate_line.cluster_index
}

fn merge_auxiliary_line_into_semantic(
    semantic_line: &mut SemanticLine,
    main_line: &LyricTrackLine,
    candidate_track: &LyricTrack,
    candidate_line: &LyricTrackLine,
) {
    if candidate_line.text == semantic_line.main_text {
        return;
    }

    if semantic_line.roman_text.is_none()
        && should_use_line_as_romaji(main_line, candidate_track, candidate_line)
    {
        semantic_line.roman_text = Some(candidate_line.text.clone());
        semantic_line.roman_words = build_aligned_roman_words(main_line, Some(candidate_line));
        return;
    }

    if semantic_line.translation_text.is_none()
        && should_use_line_as_translation(main_line, candidate_track, candidate_line)
    {
        semantic_line.translation_text = Some(candidate_line.text.clone());
        return;
    }

    push_secondary_text(
        &mut semantic_line.secondary_texts,
        candidate_line.text.clone(),
    );
}

fn score_cluster_main_candidate(
    document: &LyricDocument,
    main_track: &LyricTrack,
    candidate_track: &LyricTrack,
    candidate_line: &LyricTrackLine,
    group: &[(usize, usize, LyricTrackLine)],
) -> f64 {
    let mut sorted_source_indexes = group
        .iter()
        .map(|(_, _, line)| line.source_index)
        .collect::<Vec<_>>();
    sorted_source_indexes.sort_by(|left, right| compare_source_index(*left, *right));
    let median_source_index = sorted_source_indexes[sorted_source_indexes.len() / 2];

    let englishness = score_englishness(&candidate_line.text);
    let romanization = score_romanized_latin_text(&candidate_line.text);
    let has_japanese_like_peer = group
        .iter()
        .any(|(_, _, line)| is_japanese_like(&line.script_profile));
    let has_latin_peer = group
        .iter()
        .any(|(_, _, line)| line.script_profile.dominant_script == DominantScript::Latin);
    let has_han_peer = group
        .iter()
        .any(|(_, _, line)| line.script_profile.dominant_script == DominantScript::Han);
    let has_non_romaji_english_latin_peer = group.iter().any(|(_, _, line)| {
        line.script_profile.dominant_script == DominantScript::Latin
            && looks_like_non_romaji_english_latin_text(&line.text)
    });
    let first_non_latin_source_index = group
        .iter()
        .filter(|(_, _, line)| line.script_profile.dominant_script != DominantScript::Latin)
        .map(|(_, _, line)| line.source_index)
        .min_by(|left, right| compare_source_index(*left, *right));

    let mut score = 0.0;
    score += (2.8 - ((candidate_line.source_index - median_source_index).abs() * 2.2)).max(-1.4);
    score += if candidate_line.explicit_role.is_none() {
        1.0
    } else {
        -1.0
    };
    score += if candidate_line
        .words
        .as_ref()
        .map(|words| !words.is_empty())
        .unwrap_or(false)
    {
        0.8
    } else {
        0.0
    };
    score += if same_script_family(
        &candidate_line.script_profile.dominant_script,
        &main_track.dominant_script,
    ) {
        0.9
    } else {
        0.0
    };

    match candidate_track.role {
        LyricTrackRole::Main | LyricTrackRole::AlternateMain => score += 1.2,
        LyricTrackRole::Unknown | LyricTrackRole::Secondary => score += 0.4,
        LyricTrackRole::Translation | LyricTrackRole::Romanization => score -= 0.6,
        LyricTrackRole::Background | LyricTrackRole::Metadata => score -= 2.4,
    }

    if track_has_japanese_like_lines(main_track) && is_japanese_like(&candidate_line.script_profile)
    {
        score += 2.2;
    }
    if has_japanese_like_peer {
        if is_japanese_like(&candidate_line.script_profile) {
            score += 2.2;
        } else if candidate_line.script_profile.dominant_script == DominantScript::Han {
            score -= 2.2;
        }
    }
    if candidate_line.script_profile.dominant_script == DominantScript::Latin {
        if englishness >= romanization + 0.12 {
            score += 1.8;
        } else if romanization >= englishness + 0.08 {
            score -= 1.4;
        }
        if has_han_peer && looks_like_english_phrase(&candidate_line.text) {
            score += 3.2;
        }
        if has_han_peer
            && !has_japanese_like_peer
            && looks_like_non_romaji_english_latin_text(&candidate_line.text)
        {
            score += 4.2;
        }
    } else if has_latin_peer {
        if let Some(first_non_latin_source_index) = first_non_latin_source_index {
            if (candidate_line.source_index - first_non_latin_source_index).abs() < 0.01 {
                score += 2.4;
            } else {
                score -= 1.4;
            }
        }
        if candidate_line.script_profile.dominant_script == DominantScript::Han
            && !has_japanese_like_peer
            && has_non_romaji_english_latin_peer
        {
            score -= 2.4;
        }
    }
    if candidate_line.script_profile.dominant_script == DominantScript::Han
        && track_has_japanese_like_lines(main_track)
        && has_japanese_like_peer
    {
        score -= 0.8;
    }
    if document
        .display_track_id
        .as_ref()
        .map(|track_id| track_id == &candidate_track.id)
        .unwrap_or(false)
    {
        score += 0.8;
    }

    score
}

fn build_semantic_line_from_orphan_group(
    document: &LyricDocument,
    main_track: &LyricTrack,
    group: &[(usize, usize, LyricTrackLine)],
) -> SemanticLine {
    let main_candidate = group
        .iter()
        .max_by(|left, right| {
            score_cluster_main_candidate(
                document,
                main_track,
                &document.tracks[left.0],
                &left.2,
                group,
            )
            .partial_cmp(&score_cluster_main_candidate(
                document,
                main_track,
                &document.tracks[right.0],
                &right.2,
                group,
            ))
            .unwrap_or(Ordering::Equal)
        })
        .cloned();

    let (main_track_index, _main_line_index, main_line) = match main_candidate {
        Some(v) => v,
        None => {
            return SemanticLine {
                start_ms: 0,
                end_ms: 0,
                main_text: String::new(),
                main_words: None,
                translation_text: None,
                roman_text: None,
                roman_words: None,
                secondary_texts: None,
                confidence: ClassificationConfidence::Heuristic,
            }
        }
    };

    let mut semantic_line = SemanticLine {
        start_ms: main_line.start_ms,
        end_ms: main_line.end_ms,
        main_text: main_line.text.clone(),
        main_words: main_line.words.clone(),
        translation_text: None,
        roman_text: None,
        roman_words: None,
        secondary_texts: None,
        confidence: resolve_semantic_confidence(&[Some(&main_line)]),
    };

    for (track_index, _line_index, candidate_line) in group.iter() {
        if *track_index == main_track_index && candidate_line.id == main_line.id {
            continue;
        }
        merge_auxiliary_line_into_semantic(
            &mut semantic_line,
            &main_line,
            &document.tracks[*track_index],
            candidate_line,
        );
    }

    semantic_line.confidence = resolve_semantic_confidence(
        &group
            .iter()
            .map(|(_, _, line)| Some(line))
            .collect::<Vec<_>>(),
    );
    semantic_line
}

fn resolve_display_line_roles<'a>(
    main_line: &'a LyricTrackLine,
    translation_line: Option<&'a LyricTrackLine>,
    roman_line: Option<&'a LyricTrackLine>,
) -> (
    &'a LyricTrackLine,
    Option<&'a LyricTrackLine>,
    Option<&'a LyricTrackLine>,
) {
    if let Some(translation_line) = translation_line {
        if translation_line.script_profile.dominant_script == DominantScript::Latin
            && main_line.script_profile.dominant_script != DominantScript::Latin
            && looks_like_english_phrase(&translation_line.text)
        {
            return (translation_line, Some(main_line), None);
        }
    }

    if let Some(roman_line) = roman_line {
        if roman_line.script_profile.dominant_script == DominantScript::Latin
            && main_line.script_profile.dominant_script != DominantScript::Latin
            && looks_like_english_phrase(&roman_line.text)
        {
            return (roman_line, Some(main_line), None);
        }
    }

    if main_line.script_profile.dominant_script == DominantScript::Han {
        if let Some(translation_line) = translation_line {
            if is_japanese_like(&translation_line.script_profile) {
                return (translation_line, Some(main_line), roman_line);
            }
        }
    }

    (main_line, translation_line, roman_line)
}

fn normalize_semantic_line_display_roles(mut line: SemanticLine) -> SemanticLine {
    let main_is_latin =
        get_line_script_profile(&line.main_text).dominant_script == DominantScript::Latin;
    let translation_is_missing = line
        .translation_text
        .as_ref()
        .map(|text| text.trim().is_empty())
        .unwrap_or(true);
    let romaji_is_english_phrase = line
        .roman_text
        .as_ref()
        .map(|text| looks_like_english_phrase(text))
        .unwrap_or(false);

    if !main_is_latin && translation_is_missing && romaji_is_english_phrase {
        if let Some(english_text) = line.roman_text.take() {
            line.translation_text = Some(line.main_text.clone());
            line.main_text = english_text;
            line.main_words = line.roman_words.take();
        }
    }

    line
}

fn is_han_only_line(line: &LyricTrackLine) -> bool {
    line.script_profile.han_count > 0
        && line.script_profile.latin_count == 0
        && line.script_profile.kana_count == 0
        && line.script_profile.hangul_count == 0
}

fn is_han_latin_mixed_line(line: &LyricTrackLine) -> bool {
    line.script_profile.han_count > 0
        && line.script_profile.latin_count > 0
        && line.script_profile.kana_count == 0
        && line.script_profile.hangul_count == 0
}

fn is_latin_only_line(line: &LyricTrackLine) -> bool {
    line.script_profile.latin_count > 0
        && line.script_profile.han_count == 0
        && line.script_profile.kana_count == 0
        && line.script_profile.hangul_count == 0
}

fn build_hard_role_semantic_line(
    main_line: &LyricTrackLine,
    translation_line: Option<&LyricTrackLine>,
    roman_line: Option<&LyricTrackLine>,
) -> SemanticLine {
    SemanticLine {
        start_ms: main_line.start_ms,
        end_ms: main_line.end_ms,
        main_text: main_line.text.clone(),
        main_words: main_line.words.clone(),
        translation_text: translation_line.map(|line| line.text.clone()),
        roman_text: roman_line.map(|line| line.text.clone()),
        roman_words: build_aligned_roman_words(main_line, roman_line),
        secondary_texts: None,
        confidence: resolve_semantic_confidence(&[Some(main_line), translation_line, roman_line]),
    }
}

fn build_hard_role_semantic_line_from_cluster(
    group: &[(usize, usize, LyricTrackLine)],
) -> Option<SemanticLine> {
    let mut lines = group
        .iter()
        .map(|(_, _, line)| line)
        .collect::<Vec<&LyricTrackLine>>();
    lines.sort_by(|left, right| {
        left.slot_index
            .unwrap_or(usize::MAX)
            .cmp(&right.slot_index.unwrap_or(usize::MAX))
            .then_with(|| compare_source_index(left.source_index, right.source_index))
            .then_with(|| left.start_ms.cmp(&right.start_ms))
    });

    match lines.as_slice() {
        [main_line] => Some(build_hard_role_semantic_line(main_line, None, None)),
        [first_line, second_line] => {
            let (main_line, translation_line) =
                if is_han_only_line(first_line) && !is_han_only_line(second_line) {
                    (*second_line, *first_line)
                } else if is_han_only_line(second_line) && !is_han_only_line(first_line) {
                    (*first_line, *second_line)
                } else if is_han_latin_mixed_line(first_line) && is_latin_only_line(second_line) {
                    (*second_line, *first_line)
                } else if is_han_latin_mixed_line(second_line) && is_latin_only_line(first_line) {
                    (*first_line, *second_line)
                } else if is_japanese_like(&first_line.script_profile)
                    && !is_japanese_like(&second_line.script_profile)
                {
                    // 日文主词 + 中文翻译（含时间戳漂移导致中文行排在前面时），
                    // 假名的存在表明日文行是原词，中文行是翻译。
                    (*first_line, *second_line)
                } else if is_japanese_like(&second_line.script_profile)
                    && !is_japanese_like(&first_line.script_profile)
                {
                    (*second_line, *first_line)
                } else {
                    (*first_line, *second_line)
                };

            // [修复] 落雪歌词中 lyric 与 tlyric 可能内容完全相同（如源未提供翻译，
            // tlyric 复用了 lyric），此时不应把同一句再当翻译显示，避免主副词重复。
            if sanitize_line_text(&main_line.text) == sanitize_line_text(&translation_line.text) {
                Some(build_hard_role_semantic_line(main_line, None, None))
            } else {
                Some(build_hard_role_semantic_line(
                    main_line,
                    Some(translation_line),
                    None,
                ))
            }
        }
        [roman_line, main_line, translation_line] => {
            // [修复] 同理：若主词与翻译文本完全相同，则丢弃重复翻译，仅保留主词+罗马音
            let translation = if sanitize_line_text(&main_line.text)
                == sanitize_line_text(&translation_line.text)
            {
                None
            } else {
                Some(*translation_line)
            };
            Some(build_hard_role_semantic_line(
                main_line,
                translation,
                Some(roman_line),
            ))
        }
        _ => None,
    }
}

fn try_build_hard_role_semantic_lines(document: &LyricDocument) -> Option<Vec<SemanticLine>> {
    let mut grouped_lines = BTreeMap::<usize, Vec<(usize, usize, LyricTrackLine)>>::new();
    let mut clustered_line_count = 0usize;
    let total_line_count = document
        .tracks
        .iter()
        .map(|track| track.lines.len())
        .sum::<usize>();

    for (track_index, track) in document.tracks.iter().enumerate() {
        for (line_index, line) in track.lines.iter().enumerate() {
            let Some(cluster_index) = line.cluster_index else {
                continue;
            };
            clustered_line_count += 1;
            grouped_lines.entry(cluster_index).or_default().push((
                track_index,
                line_index,
                line.clone(),
            ));
        }
    }

    if grouped_lines.is_empty()
        || clustered_line_count != total_line_count
        || !grouped_lines
            .values()
            .any(|group| matches!(group.len(), 2 | 3))
        || grouped_lines.values().any(|group| group.len() > 3)
    {
        return None;
    }

    let mut semantic_lines = grouped_lines
        .values()
        .map(|group| build_hard_role_semantic_line_from_cluster(group))
        .collect::<Option<Vec<_>>>()?;

    semantic_lines.sort_by(|left, right| {
        left.start_ms
            .cmp(&right.start_ms)
            .then_with(|| left.end_ms.cmp(&right.end_ms))
    });
    Some(semantic_lines)
}

pub fn build_lyric_document(parsed_lines: &[ParsedLine]) -> Option<LyricDocument> {
    let candidate_lines = build_candidate_lines(parsed_lines);
    if candidate_lines.is_empty() {
        return None;
    }

    let groups = group_candidate_lines(&candidate_lines);
    let mut tracks = build_tracks(groups);
    if tracks.is_empty() {
        return None;
    }

    let alignments = (0..tracks.len())
        .map(|main_index| {
            (0..tracks.len())
                .map(|aux_index| {
                    if main_index == aux_index {
                        TrackAlignment::default()
                    } else {
                        compute_track_alignment(&tracks[main_index], &tracks[aux_index])
                    }
                })
                .collect::<Vec<_>>()
        })
        .collect::<Vec<_>>();

    let template_resolution = detect_layout_template(&tracks, &alignments);
    let display_track_index = template_resolution
        .as_ref()
        .map(|resolution| resolution.display_track_index)
        .unwrap_or_else(|| {
            let mut best_track_index = 0usize;
            let mut best_track_score = f64::NEG_INFINITY;

            for (track_index, track) in tracks.iter().enumerate() {
                let score = score_main_track(track, &tracks, &alignments, track_index);
                if score > best_track_score {
                    best_track_score = score;
                    best_track_index = track_index;
                }
            }

            best_track_index
        });

    for track_index in 0..tracks.len() {
        let main_score = score_main_track(&tracks[track_index], &tracks, &alignments, track_index);
        let template_role = template_resolution
            .as_ref()
            .and_then(|resolution| resolution.track_roles[track_index].clone());
        if track_index == display_track_index {
            let scores = TrackRoleScores {
                main: main_score,
                translation: 0.0,
                romanization: 0.0,
            };
            tracks[track_index].role = LyricTrackRole::Main;
            tracks[track_index].confidence = track_confidence(&LyricTrackRole::Main, &scores);
            tracks[track_index].scores = Some(LyricTrackScores {
                main: scores.main,
                translation: scores.translation,
                romanization: scores.romanization,
            });
            continue;
        }

        let alignment = &alignments[display_track_index][track_index];
        let mut scores = score_track_roles(
            &tracks[display_track_index],
            &tracks[track_index],
            alignment,
        );
        scores.main = main_score;

        let role = if let Some(role) = template_role {
            role
        } else if alignment.weighted_score < 0.25 {
            if tracks[track_index].lines.len() as f64
                >= tracks[display_track_index].lines.len() as f64 * 0.6
                && tracks[track_index].dominant_script
                    == tracks[display_track_index].dominant_script
            {
                LyricTrackRole::AlternateMain
            } else {
                LyricTrackRole::Unknown
            }
        } else if scores.translation >= 0.58 || scores.romanization >= 0.58 {
            if scores.translation >= scores.romanization {
                LyricTrackRole::Translation
            } else {
                LyricTrackRole::Romanization
            }
        } else {
            LyricTrackRole::Secondary
        };

        tracks[track_index].role = role.clone();
        tracks[track_index].confidence = track_confidence(&role, &scores);
        tracks[track_index].scores = Some(LyricTrackScores {
            main: scores.main,
            translation: scores.translation,
            romanization: scores.romanization,
        });
    }

    let display_track_id = tracks[display_track_index].id.clone();
    let attachments = tracks
        .iter()
        .enumerate()
        .filter(|(track_index, track)| {
            *track_index != display_track_index
                && matches!(
                    track.role,
                    LyricTrackRole::Translation
                        | LyricTrackRole::Romanization
                        | LyricTrackRole::Secondary
                )
        })
        .map(|(track_index, track)| LyricTrackAttachment {
            track_id: track.id.clone(),
            role: track.role.clone(),
            confidence: track.confidence,
            line_match_ratio: alignments[display_track_index][track_index].main_coverage,
        })
        .collect::<Vec<_>>();

    tracks[display_track_index].attachments = attachments.clone();

    let issues = if tracks.len() > 1 && attachments.is_empty() {
        vec![LyricIssue {
            code: "lyrics.unattached_tracks".to_string(),
            message: "Detected multiple lyric tracks but could not confidently attach any secondary track to the display main track.".to_string(),
            severity: "warning".to_string(),
        }]
    } else {
        Vec::new()
    };

    let mut source_formats = candidate_lines
        .iter()
        .map(|line| line.source_format.clone())
        .collect::<Vec<_>>();
    source_formats.sort_by(|left, right| format!("{left:?}").cmp(&format!("{right:?}")));
    source_formats.dedup();

    let document_confidence = average(
        &tracks
            .iter()
            .map(|track| track.confidence)
            .collect::<Vec<_>>(),
    );

    Some(LyricDocument {
        metadata: LyricDocumentMetadata {
            total_lines: candidate_lines.len(),
            source_formats,
        },
        tracks,
        issues,
        confidence: document_confidence,
        display_track_id: Some(display_track_id),
    })
}

pub fn lyric_document_to_semantic_lines(document: &LyricDocument) -> Vec<SemanticLine> {
    if let Some(semantic_lines) = try_build_hard_role_semantic_lines(document) {
        return semantic_lines;
    }

    let Some(main_track) = document
        .tracks
        .iter()
        .find(|track| track.id == document.display_track_id.clone().unwrap_or_default())
        .or_else(|| {
            document
                .tracks
                .iter()
                .find(|track| track.role == LyricTrackRole::Main)
        })
    else {
        return Vec::new();
    };

    let alignments = document
        .tracks
        .iter()
        .map(|track| compute_track_alignment(main_track, track))
        .collect::<Vec<_>>();

    let translation_tracks = document
        .tracks
        .iter()
        .enumerate()
        .filter(|(_, track)| track.role == LyricTrackRole::Translation)
        .collect::<Vec<_>>();
    let roman_tracks = document
        .tracks
        .iter()
        .enumerate()
        .filter(|(_, track)| track.role == LyricTrackRole::Romanization)
        .collect::<Vec<_>>();
    let secondary_tracks = document
        .tracks
        .iter()
        .enumerate()
        .filter(|(_, track)| is_auxiliary_role_repair_track(track))
        .collect::<Vec<_>>();

    let mut attached_line_keys: Vec<(usize, usize)> = Vec::new();
    let mut semantic_lines = Vec::new();
    let mut semantic_line_clusters = Vec::new();

    for (main_index, main_line) in main_track.lines.iter().enumerate() {
        let translation_entry = translation_tracks.iter().find_map(|(track_index, track)| {
            alignments[*track_index]
                .pairs
                .iter()
                .find(|pair| {
                    pair.main_index == main_index
                        && should_attach_aligned_pair(
                            main_track,
                            track,
                            &alignments[*track_index],
                            pair,
                        )
                })
                .map(|pair| (*track_index, pair.aux_index))
        });
        let roman_entry = roman_tracks.iter().find_map(|(track_index, track)| {
            alignments[*track_index]
                .pairs
                .iter()
                .find(|pair| {
                    pair.main_index == main_index
                        && should_attach_aligned_pair(
                            main_track,
                            track,
                            &alignments[*track_index],
                            pair,
                        )
                })
                .map(|pair| (*track_index, pair.aux_index))
        });

        let translation_line = translation_entry.and_then(|(track_index, aux_index)| {
            attached_line_keys.push((track_index, aux_index));
            document.tracks[track_index].lines.get(aux_index)
        });
        let roman_line = roman_entry.and_then(|(track_index, aux_index)| {
            attached_line_keys.push((track_index, aux_index));
            document.tracks[track_index].lines.get(aux_index)
        });
        let (mut display_main_line, display_translation_line, mut display_roman_line) =
            resolve_display_line_roles(main_line, translation_line, roman_line);

        let mut fallback_translation_line: Option<&LyricTrackLine> = None;
        let mut secondary_texts = Vec::new();
        for (track_index, track) in &secondary_tracks {
            let Some(pair) = alignments[*track_index].pairs.iter().find(|pair| {
                pair.main_index == main_index
                    && should_attach_aligned_pair(
                        main_track,
                        track,
                        &alignments[*track_index],
                        pair,
                    )
            }) else {
                continue;
            };
            attached_line_keys.push((*track_index, pair.aux_index));

            let Some(line) = track.lines.get(pair.aux_index) else {
                continue;
            };

            if display_translation_line.is_none()
                && fallback_translation_line.is_none()
                && line.script_profile.dominant_script == DominantScript::Han
                && should_use_line_as_translation(display_main_line, track, line)
            {
                fallback_translation_line = Some(line);
            } else if should_promote_japanese_auxiliary_as_main(display_main_line, line) {
                display_roman_line = Some(display_main_line);
                display_main_line = line;
            } else if display_roman_line.is_none()
                && should_use_line_as_romaji(display_main_line, track, line)
            {
                display_roman_line = Some(line);
            } else {
                secondary_texts.push(line.text.clone());
            }
        }
        let resolved_translation_line = display_translation_line.or(fallback_translation_line);

        semantic_lines.push(normalize_semantic_line_display_roles(SemanticLine {
            start_ms: display_main_line.start_ms,
            end_ms: display_main_line.end_ms,
            main_text: display_main_line.text.clone(),
            main_words: display_main_line.words.clone(),
            translation_text: resolved_translation_line.map(|line| line.text.clone()),
            roman_text: display_roman_line.map(|line| line.text.clone()),
            roman_words: build_aligned_roman_words(display_main_line, display_roman_line),
            secondary_texts: if secondary_texts.is_empty() {
                None
            } else {
                Some(secondary_texts)
            },
            confidence: resolve_semantic_confidence(&[
                Some(display_main_line),
                resolved_translation_line,
                display_roman_line,
            ]),
        }));
        semantic_line_clusters.push(main_line.cluster_index);
    }

    let mut orphan_groups = BTreeMap::<Option<usize>, Vec<(usize, usize, LyricTrackLine)>>::new();
    for (track_index, track) in document.tracks.iter().enumerate() {
        if track.id == main_track.id {
            continue;
        }

        for (line_index, line) in track.lines.iter().enumerate() {
            if attached_line_keys.contains(&(track_index, line_index)) {
                continue;
            }

            orphan_groups.entry(line.cluster_index).or_default().push((
                track_index,
                line_index,
                line.clone(),
            ));
        }
    }

    for (cluster_index, group) in orphan_groups {
        if let Some(existing_index) = cluster_index.and_then(|cluster| {
            semantic_line_clusters
                .iter()
                .position(|value| *value == Some(cluster))
        }) {
            let existing_main_text = semantic_lines[existing_index].main_text.clone();
            let existing_main_line = document
                .tracks
                .iter()
                .flat_map(|track| track.lines.iter())
                .find(|line| line.cluster_index == cluster_index && line.text == existing_main_text)
                .cloned();

            if let Some(existing_main_line) = existing_main_line {
                for (track_index, _line_index, line) in group {
                    merge_auxiliary_line_into_semantic(
                        &mut semantic_lines[existing_index],
                        &existing_main_line,
                        &document.tracks[track_index],
                        &line,
                    );
                }
                continue;
            }
        }

        semantic_lines.push(normalize_semantic_line_display_roles(
            build_semantic_line_from_orphan_group(document, main_track, &group),
        ));
    }

    semantic_lines.sort_by(|left, right| {
        left.start_ms
            .cmp(&right.start_ms)
            .then_with(|| left.end_ms.cmp(&right.end_ms))
    });
    semantic_lines
        .into_iter()
        .fold(Vec::<SemanticLine>::new(), |mut acc, line| {
            let is_duplicate = acc
                .last()
                .map(|previous| {
                    previous.start_ms == line.start_ms
                        && previous.end_ms == line.end_ms
                        && previous.main_text == line.main_text
                })
                .unwrap_or(false);
            if !is_duplicate {
                acc.push(line);
            }
            acc
        })
}

fn build_romaji_text(line: &SemanticLine) -> String {
    if let Some(text) = line.roman_text.as_ref() {
        return text.clone();
    }
    line.roman_words
        .as_ref()
        .map(|words| {
            words
                .iter()
                .map(|word| word.text.clone())
                .collect::<String>()
        })
        .unwrap_or_default()
}

pub fn semantic_line_to_lyric_line(line: &SemanticLine) -> LyricLinePayload {
    let words = line
        .main_words
        .as_ref()
        .map(|main_words| {
            main_words
                .iter()
                .map(|word| {
                    let timed_romaji = line.roman_words.as_ref().and_then(|roman_words| {
                        roman_words.iter().find(|roman_word| {
                            roman_word.start_ms == word.start_ms && roman_word.end_ms == word.end_ms
                        })
                    });

                    LyricWordPayload {
                        text: word.text.clone(),
                        start: word.start_ms as f64 / 1000.0,
                        end: word.end_ms as f64 / 1000.0,
                        romaji: timed_romaji
                            .map(|roman_word| roman_word.text.clone())
                            .or_else(|| word.roman_text.clone())
                            .filter(|text| !text.is_empty()),
                    }
                })
                .collect::<Vec<_>>()
        })
        .filter(|words| !words.is_empty());

    LyricLinePayload {
        time: line.start_ms as f64 / 1000.0,
        end_time: line.end_ms as f64 / 1000.0,
        text: line.main_text.clone(),
        translation: line.translation_text.clone().unwrap_or_default(),
        romaji: build_romaji_text(line),
        words,
        romaji_words: line
            .roman_words
            .as_ref()
            .map(|roman_words| {
                roman_words
                    .iter()
                    .map(|word| LyricWordPayload {
                        text: word.text.clone(),
                        start: word.start_ms as f64 / 1000.0,
                        end: word.end_ms as f64 / 1000.0,
                        romaji: None,
                    })
                    .collect::<Vec<_>>()
            })
            .filter(|words| !words.is_empty()),
        secondary: line.secondary_texts.clone(),
    }
}

pub fn build_structured_lyrics_payload(raw_lyrics: String) -> StructuredLyricsPayload {
    let parsed_lines = parse_raw_lyrics(&raw_lyrics);
    let document = build_lyric_document(&parsed_lines);
    let semantic_lines = document
        .as_ref()
        .map(lyric_document_to_semantic_lines)
        .unwrap_or_default();
    let display_lines = semantic_lines
        .iter()
        .map(semantic_line_to_lyric_line)
        .collect::<Vec<_>>();

    StructuredLyricsPayload {
        raw_lyrics,
        document,
        semantic_lines,
        display_lines,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        build_structured_lyrics_payload, parse_raw_lyrics, score_romanized_latin_text,
        ParsedLineSourceFormat,
    };

    /// 端到端：泡沫（QQ QRC）样本经 Dart convertLxLyricToEnhancedLrc 落盘的
    /// 增强 LRC，喂给 build_structured_lyrics_payload（App 真实解析路径），
    /// 断言所有展示行都带词级时间（用户反馈“正文只有第一行逐字”）。
    /// 样本由 test/lx_convert_check.dart（LX_SAMPLE=tx_paomo.json）生成；
    /// 不存在时跳过。
    #[test]
    fn parses_paomo_enhanced_lrc_all_lines_word_timed() {
        assert_enhanced_lrc_all_lines_word_timed("target/lx_samples/tx_paomo_enhanced.lrc");
    }

    /// 端到端：酷我《晴天》kly 样本（修复酷我公式漏加行首时间后）经
    /// Dart 转换落盘的增强 LRC。样本由 lx_convert_check.dart
    /// （LX_SAMPLE=kw_qingtian.json）生成；不存在时跳过。
    #[test]
    fn parses_kw_qingtian_enhanced_lrc_all_lines_word_timed() {
        assert_enhanced_lrc_all_lines_word_timed("target/lx_samples/kw_qingtian_enhanced.lrc");
    }

    /// 端到端：咪咕《泡沫》MRC 样本经 Dart 转换落盘的增强 LRC。
    /// 样本由 lx_convert_check.dart（LX_SAMPLE=mg_paomo.json）生成；
    /// 不存在时跳过。
    #[test]
    fn parses_mg_paomo_enhanced_lrc_all_lines_word_timed() {
        assert_enhanced_lrc_all_lines_word_timed("target/lx_samples/mg_paomo_enhanced.lrc");
    }

    fn assert_enhanced_lrc_all_lines_word_timed(path: &str) {
        let Ok(raw) = std::fs::read_to_string(path) else {
            println!("{path} 样本不存在，跳过");
            return;
        };
        let payload = build_structured_lyrics_payload(raw);
        let total = payload.display_lines.len();
        let word_timed = payload
            .display_lines
            .iter()
            .filter(|l| l.words.as_ref().is_some_and(|w| !w.is_empty()))
            .count();
        for (i, line) in payload.display_lines.iter().take(4).enumerate() {
            let word_count = line.words.as_ref().map(|w| w.len()).unwrap_or(0);
            println!("[{i}] {} 词级={word_count} {}", line.time, line.text);
        }
        println!("display_lines: {total}, word_timed: {word_timed}");
        assert!(total > 5, "行数过少: {total}");
        assert_eq!(
            word_timed, total,
            "应所有行都有词级时间，实际 {word_timed}/{total}"
        );
    }

    /// QQ 音乐 QRC 容器 XML（`<QrcInfos>…<Lyric_1 LyricContent="…"/>`）此前
    /// 被逐行解析器当普通文本，正文行全部解析失败 → 无歌词。且下载链路会把这
    /// 段原始 XML 直接写进 .lrc / 音频标签，第三方播放器（光锥、椒盐）打开就
    /// 显示整段 XML。该用例断言容器能被抽出并解析出展示行（含词级时间）。
    #[test]
    fn parses_qrc_container_xml_into_display_lines() {
        let container = concat!(
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n",
            "<QrcInfos>\n",
            "<QrcHeadInfo SaveTime=\"200\" Version=\"100\"/>\n",
            "<LyricInfo LyricCount=\"1\">\n",
            "<Lyric_1 LyricType=\"1\" LyricContent=\"[ti:花寂寥]\n",
            "[0,2000]花(0,700)寂(700,700)寥(1400,600)\n",
            "[2000,1500]夜色(2000,800)渐浓(2800,700)\"/>\n",
            "</LyricInfo>\n",
            "</QrcInfos>\n",
        );
        let payload = build_structured_lyrics_payload(container.to_string());
        assert!(
            !payload.display_lines.is_empty(),
            "QRC 容器应解析出展示行，实际 0 行"
        );
        let joined = payload
            .display_lines
            .iter()
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>()
            .join("|");
        assert!(joined.contains("花寂寥"), "正文缺失: {joined}");
        assert!(joined.contains("夜色渐浓"), "正文缺失: {joined}");
        assert!(
            payload
                .display_lines
                .iter()
                .any(|line| line.words.as_ref().is_some_and(|w| !w.is_empty())),
            "应保留词级时间"
        );
    }

    #[test]
    fn parses_inline_timestamp_lrc_into_word_timed_lines() {
        let parsed = parse_raw_lyrics(
            "[00:00.000]如[00:00.375]果[00:00.750]当[00:01.125]时[00:01.500] [00:01.875]-[00:02.250] [00:02.625]许[00:03.000]嵩[00:03.375]",
        );

        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].text, "如果当时 - 许嵩");
    }

    #[test]
    fn hard_role_rules_keep_single_line_as_main() {
        let payload = build_structured_lyrics_payload("[00:01.000]Hello darling".to_string());

        assert_eq!(payload.display_lines.len(), 1);
        assert_eq!(payload.display_lines[0].text, "Hello darling");
        assert_eq!(payload.display_lines[0].translation, "");
        assert_eq!(payload.display_lines[0].romaji, "");
    }

    #[test]
    fn hard_role_rules_treat_han_only_line_as_translation_for_two_lines() {
        let payload = build_structured_lyrics_payload(
            ["[00:01.000]你知道你爱我", "[00:01.000]You know you love me"].join("\n"),
        );

        assert_eq!(payload.display_lines.len(), 1);
        assert_eq!(payload.display_lines[0].text, "You know you love me");
        assert_eq!(payload.display_lines[0].translation, "你知道你爱我");
        assert_eq!(payload.display_lines[0].romaji, "");
    }

    #[test]
    fn hard_role_rules_treat_mixed_han_latin_as_translation_for_two_lines() {
        let payload = build_structured_lyrics_payload(
            ["[00:01.000]你好 darling", "[00:01.000]hello darling"].join("\n"),
        );

        assert_eq!(payload.display_lines.len(), 1);
        assert_eq!(payload.display_lines[0].text, "hello darling");
        assert_eq!(payload.display_lines[0].translation, "你好 darling");
        assert_eq!(payload.display_lines[0].romaji, "");
    }

    #[test]
    fn hard_role_rules_fall_back_to_first_main_second_translation_for_two_lines() {
        let payload = build_structured_lyrics_payload(
            [
                "[00:01.000]first latin line",
                "[00:01.000]second latin line",
            ]
            .join("\n"),
        );

        assert_eq!(payload.display_lines.len(), 1);
        assert_eq!(payload.display_lines[0].text, "first latin line");
        assert_eq!(payload.display_lines[0].translation, "second latin line");
        assert_eq!(payload.display_lines[0].romaji, "");
    }

    #[test]
    fn hard_role_rules_use_fixed_roman_main_translation_order_for_three_lines() {
        let payload = build_structured_lyrics_payload(
            [
                "[00:01.000]wa su re ta ku na i ko to",
                "[00:01.000]忘れたくないこと",
                "[00:01.000]我不愿遗忘",
            ]
            .join("\n"),
        );

        assert_eq!(payload.display_lines.len(), 1);
        assert_eq!(payload.display_lines[0].text, "忘れたくないこと");
        assert_eq!(payload.display_lines[0].translation, "我不愿遗忘");
        assert_eq!(payload.display_lines[0].romaji, "wa su re ta ku na i ko to");
    }

    #[test]
    fn keeps_japanese_main_when_romaji_comes_first() {
        let payload = build_structured_lyrics_payload(
            [
                "[01:01.072]<01:01.072>wa <01:01.336>su <01:01.633>re <01:01.863>ta <01:02.103>ku <01:02.352>na <01:02.577>i <01:02.823>ko <01:03.159>to <01:03.553>",
                "[01:01.072]<01:01.072>忘<01:01.633>れ<01:01.863>た<01:02.103>く<01:02.352>な<01:02.577>い<01:02.823>こ<01:03.159>と<01:03.553>",
                "[01:01.072]<01:01.072>我不愿遗忘<01:03.790>",
            ]
            .join("\n"),
        );

        assert_eq!(payload.display_lines.len(), 1);
        assert_eq!(payload.display_lines[0].text, "忘れたくないこと");
        assert_eq!(payload.display_lines[0].translation, "我不愿遗忘");
        assert_eq!(payload.display_lines[0].romaji, "wa su re ta ku na i ko to");
    }

    #[test]
    fn prefers_lx_converted_enhanced_lrc_as_word_timed_source() {
        let parsed = parse_raw_lyrics(
            [
                "[00:10.000]<00:10.000>其<00:10.300>实<00:10.600>",
                "[00:12.000]<00:12.000>天<00:12.400>外<00:12.800>",
            ]
            .join("\n")
            .as_str(),
        );

        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].source_format, ParsedLineSourceFormat::EnhancedLrc);
        assert_eq!(parsed[0].text, "其实");
        assert_eq!(
            parsed[0]
                .words
                .as_ref()
                .map(|words| words
                    .iter()
                    .map(|word| word.text.as_str())
                    .collect::<Vec<_>>())
                .unwrap_or_default(),
            vec!["其", "实"]
        );
    }

    #[test]
    fn structured_payload_keeps_words_for_lx_converted_enhanced_lrc() {
        let payload = build_structured_lyrics_payload(
            [
                "[00:10.000]<00:10.000>其<00:10.300>实<00:10.600>",
                "[00:12.000]<00:12.000>天<00:12.400>外<00:12.800>",
            ]
            .join("\n"),
        );

        assert_eq!(payload.display_lines.len(), 2);
        assert_eq!(payload.display_lines[0].text, "其实");
        assert_eq!(
            payload.display_lines[0]
                .words
                .as_ref()
                .map(|words| words
                    .iter()
                    .map(|word| word.text.as_str())
                    .collect::<Vec<_>>())
                .unwrap_or_default(),
            vec!["其", "实"]
        );
    }

    #[test]
    fn parses_yrc_fixture_into_word_timed_lines() {
        let parsed = parse_raw_lyrics(include_str!("fixtures/lyrics/if_back_then.yrc"));

        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].source_format, ParsedLineSourceFormat::Yrc);
        assert_eq!(parsed[0].text, "如果当时 - 许嵩");
        assert_eq!(
            parsed[0]
                .words
                .as_ref()
                .map(|words| words
                    .iter()
                    .map(|word| word.text.as_str())
                    .collect::<Vec<_>>())
                .unwrap_or_default(),
            vec!["如", "果", "当", "时", " ", "-", " ", "许", "嵩"]
        );
        assert_eq!(parsed[1].text, "词：许嵩");
    }

    #[test]
    fn parses_qrc_fixture_into_word_timed_lines() {
        let parsed = parse_raw_lyrics(include_str!("fixtures/lyrics/baby.qrc"));

        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].source_format, ParsedLineSourceFormat::Qrc);
        assert_eq!(parsed[0].text, "You know you love me I know you care");
        assert_eq!(
            parsed[0]
                .words
                .as_ref()
                .map(|words| words
                    .iter()
                    .map(|word| word.text.as_str())
                    .collect::<Vec<_>>())
                .unwrap_or_default(),
            vec!["You ", "know ", "you ", "love ", "me", " I ", "know ", "you ", "care",]
        );
        assert_eq!(parsed[1].text, "你知道你爱我 我知道你在意");
    }

    #[test]
    fn parses_lys_fixture_into_word_timed_lines() {
        let parsed = parse_raw_lyrics(include_str!("fixtures/lyrics/from_that_day.lys"));

        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].source_format, ParsedLineSourceFormat::Lys);
        assert_eq!(parsed[0].text, "その日から何もかも");
        assert_eq!(
            parsed[0]
                .words
                .as_ref()
                .map(|words| words
                    .iter()
                    .map(|word| word.text.as_str())
                    .collect::<Vec<_>>())
                .unwrap_or_default(),
            vec!["そ", "の日から", "何もかも"]
        );
        assert_eq!(parsed[1].text, "忘れたくないこと");
    }

    #[test]
    fn romaji_scoring_prefers_vowel_ending_token_sequences() {
        let spaced_romaji = "ha ji me te no ru bu ru wa";
        let compressed_latin = "hajimetenoruburuwa";

        assert!(
            score_romanized_latin_text(spaced_romaji)
                > score_romanized_latin_text(compressed_latin)
        );
    }

    #[test]
    fn realistic_english_song_with_chinese_translation() {
        let main = [
            "[ti:Shape of You]",
            "[ar:Ed Sheeran]",
            "[al:Divide]",
            "[00:00.00]The club isn't the best place to find a lover",
            "[00:04.00]So the bar is where I go",
            "[00:08.00]Me and my friends at the table doing shots",
            "[00:12.00]Drinking fast and then we talk slow",
            "[00:16.00]And you come over and start up a conversation with just me",
            "[00:20.00]And trust me I'll give it a chance now",
            "[00:24.00]Take my hand, stop, put Van the Man on the jukebox",
            "[00:28.00]And then we start to dance, and now I'm singing like",
            "[00:32.00]Girl, you know I want your love",
            "[00:36.00]Your love was handmade for somebody like me",
            "[00:40.00]Come on now, follow my lead",
            "[00:44.00]I'm in love with the shape of you",
        ];
        let translation = [
            "[00:00.00]俱乐部不是寻找爱人的最佳地点",
            "[00:04.00]所以我去了酒吧",
            "[00:08.00]我和朋友们坐在桌边喝酒",
            "[00:12.00]喝得很快然后慢慢聊天",
            "[00:16.00]你走了过来 开始和我搭话",
            "[00:20.00]相信我 我会给你一个机会",
            "[00:24.00]牵起我的手 点一首Van的歌",
            "[00:28.00]然后我们开始跳舞 我唱着",
            "[00:32.00]女孩 你知道我想要你的爱",
            "[00:36.00]你的爱为我这样的人量身定做",
            "[00:40.00]来吧 跟着我的节奏",
            "[00:44.00]我爱上你的模样",
        ];
        let payload = build_structured_lyrics_payload(
            [main.join("\n"), translation.join("\n")].join("\n"),
        );

        let with_translation = payload
            .display_lines
            .iter()
            .filter(|line| !line.translation.is_empty())
            .count();
        assert!(
            with_translation > 0,
            "expected translations, got lines: {:?}",
            payload
                .display_lines
                .iter()
                .map(|line| (line.text.clone(), line.translation.clone()))
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn realistic_english_song_yrc_with_chinese_translation() {
        let main = [
            "[ti:Shape of You]",
            "[ar:Ed Sheeran]",
            "[00:00.00]<00:00.000>The <00:00.200>club <00:00.400>isn't <00:00.600>the <00:00.800>best <00:01.000>place <00:01.200>to <00:01.400>find <00:01.600>a <00:01.800>lover<00:02.000>",
            "[00:04.00]<00:04.000>So <00:04.200>the <00:04.400>bar <00:04.600>is <00:04.800>where <00:05.000>I <00:05.200>go<00:05.400>",
            "[00:08.00]<00:08.000>Me <00:08.200>and <00:08.400>my <00:08.600>friends <00:08.800>at <00:09.000>the <00:09.200>table <00:09.400>doing <00:09.600>shots<00:09.800>",
            "[00:12.00]<00:12.000>Drinking <00:12.200>fast <00:12.400>and <00:12.600>then <00:12.800>we <00:13.000>talk <00:13.200>slow<00:13.400>",
        ];
        let translation = [
            "[00:00.00]俱乐部不是寻找爱人的最佳地点",
            "[00:04.00]所以我去了酒吧",
            "[00:08.00]我和朋友们坐在桌边喝酒",
            "[00:12.00]喝得很快然后慢慢聊天",
        ];
        let payload = build_structured_lyrics_payload(
            [main.join("\n"), translation.join("\n")].join("\n"),
        );

        let with_translation = payload
            .display_lines
            .iter()
            .filter(|line| !line.translation.is_empty())
            .count();
        assert!(
            with_translation > 0,
            "expected translations, got lines: {:?}",
            payload
                .display_lines
                .iter()
                .map(|line| (line.text.clone(), line.translation.clone()))
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn realistic_english_song_qrc_with_krc_chinese_translation() {
        // 汽水/BakaMusic 插件 getLyric 返回：rawLrc 为 QRC
        // `[start,dur]word(start,dur)`，translation 为 KRC
        // `[start,dur]<offset,dur,0>文字`，Flutter 侧拼接后交给 Rust。
        let main = [
            "[3938,4988]The(3938,200) club(4138,300) isn't(4438,400) the(4838,200) best(5038,300) place(5338,400) to(5738,200) find(5938,300) a(6238,100) lover(6338,2500)",
            "[8926,4100]So(8926,150) the(9076,200) bar(9276,300) is(9576,200) where(9776,400) I(10176,100) go(10276,2000)",
            "[13026,5400]Me(13026,150) and(13176,250) my(13426,200) friends(13626,500) at(14126,200) the(14326,200) table(14526,600) doing(15126,500) shots(15626,900)",
            "[18426,4600]Drinking(18426,600) fast(19026,300) and(19326,200) then(19526,300) we(19826,150) talk(19976,1200) slow(21176,800)",
        ];
        let translation = [
            "[3938,4988]<0,4988,0>俱乐部不是寻找爱人的最佳地点",
            "[8926,4100]<0,4100,0>所以我去了酒吧",
            "[13026,5400]<0,5400,0>我和朋友们坐在桌边喝酒",
            "[18426,4600]<0,4600,0>喝得很快然后慢慢聊天",
        ];
        let payload = build_structured_lyrics_payload(
            [main.join("\n"), translation.join("\n")].join("\n"),
        );

        let with_translation = payload
            .display_lines
            .iter()
            .filter(|line| !line.translation.is_empty())
            .count();
        assert!(
            with_translation >= 3,
            "expected translations on most lines, got {}/{}; lines: {:?}",
            with_translation,
            payload.display_lines.len(),
            payload
                .display_lines
                .iter()
                .map(|line| (line.text.clone(), line.translation.clone()))
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn realistic_japanese_ost_song_with_chinese_translation() {
        // 网易 wy 插件日语歌曲：rawLrc 为日文，translation 为中文，
        // 翻译仅覆盖人声行，且部分行时间戳与主歌词有轻微漂移。
        let main = [
            "[00:00.000]作詞 : Ayase",
            "[00:00.000]作曲 : Ayase",
            "[00:26.920]沈んだ目をした born loser",
            "[00:31.260]夜に馳せる願いは",
            "[00:35.600]誰にも言えないままで",
            "[00:40.140]落ちていくのは",
            "[00:44.980]悲しみだけ",
            "[00:49.380]それでも君を抱きしめた",
            "[00:54.120]離さないと誓った",
            "[00:58.860]あの日のことを忘れない",
        ];
        let translation = [
            "[00:26.920]眼神黯淡的 born loser",
            "[00:31.260]向夜晚许下的愿望",
            "[00:35.600]依然无法对任何人说起",
            "[00:40.140]不断坠落的",
            "[00:44.980]唯有悲伤",
            "[00:49.380]即便如此我仍拥抱着你",
            "[00:54.120]发誓绝不放手",
            "[00:58.860]那一天的一切我不会忘记",
        ];
        let payload = build_structured_lyrics_payload(
            [main.join("\n"), translation.join("\n")].join("\n"),
        );

        let with_translation = payload
            .display_lines
            .iter()
            .filter(|line| !line.translation.is_empty())
            .count();
        assert!(
            with_translation >= 6,
            "expected translations on most lines, got {}/{}; lines: {:?}",
            with_translation,
            payload.display_lines.len(),
            payload
                .display_lines
                .iter()
                .map(|line| (line.text.clone(), line.translation.clone()))
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn realistic_japanese_song_translation_with_timestamp_drift() {
        let main = [
            "[00:26.920]沈んだ目をした born loser",
            "[00:31.260]夜に馳せる願いは",
            "[00:35.600]誰にも言えないままで",
            "[00:40.140]落ちていくのは",
            "[00:44.980]悲しみだけ",
        ];
        let translation = [
            "[00:26.459]眼神黯淡的 born loser",
            "[00:30.911]向夜晚许下的愿望",
            "[00:35.376]依然无法对任何人说起",
            "[00:39.842]不断坠落的",
            "[00:44.307]唯有悲伤",
        ];
        let payload = build_structured_lyrics_payload(
            [main.join("\n"), translation.join("\n")].join("\n"),
        );

        let with_translation = payload
            .display_lines
            .iter()
            .filter(|line| !line.translation.is_empty())
            .count();
        assert!(
            with_translation >= 4,
            "expected translations despite drift, got {}/{}; lines: {:?}",
            with_translation,
            payload.display_lines.len(),
            payload
                .display_lines
                .iter()
                .map(|line| (line.text.clone(), line.translation.clone()))
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn romaji_scoring_supports_n_and_ng_endings() {
        let n_ending_romaji = "shi n ji te i ru n da";
        let ng_ending_pinyin = "xiang xin ni reng zai zhe li";

        assert!(score_romanized_latin_text(n_ending_romaji) > 0.45);
        assert!(score_romanized_latin_text(ng_ending_pinyin) > 0.35);
    }

    #[test]
    fn romaji_scoring_keeps_english_phrases_below_romaji_lines() {
        let english_phrase = "Can you give me one last kiss";
        let romaji_line = "mo u to kku ni de a't te ta ka ra";

        assert!(score_romanized_latin_text(english_phrase) < 0.35);
        assert!(
            score_romanized_latin_text(romaji_line) > score_romanized_latin_text(english_phrase)
        );
    }

    #[test]
    fn hard_role_rules_deduplicate_identical_main_and_translation() {
        // 模拟落雪歌词 lyric 与 tlyric 内容完全相同（源未提供真实翻译）
        let payload = build_structured_lyrics_payload(
            ["[00:01.000]相同歌词", "[00:01.000]相同歌词"].join("\n"),
        );

        assert_eq!(payload.display_lines.len(), 1);
        assert_eq!(payload.display_lines[0].text, "相同歌词");
        assert_eq!(payload.display_lines[0].translation, "");
        assert_eq!(payload.display_lines[0].romaji, "");
    }

    #[test]
    fn hard_role_rules_keep_different_main_and_translation() {
        // 真实翻译场景：lyric 与 tlyric 不同，应保留翻译
        let payload =
            build_structured_lyrics_payload(["[00:01.000]Hello", "[00:01.000]你好"].join("\n"));

        assert_eq!(payload.display_lines.len(), 1);
        assert_eq!(payload.display_lines[0].text, "Hello");
        assert_eq!(payload.display_lines[0].translation, "你好");
    }
}
