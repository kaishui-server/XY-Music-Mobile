// lx_catalog.rs - LX 音源目录搜索（歌单）+ QQ 专辑搜索（Rust 实现）
//
// 移植自桌面端 XianYu-Music-Mobile 的 rust/src/music/lx_catalog.rs
// （searchLxPlaylists / normalizeLxPlaylistResults，支持 kw/kg/tx/wy/mg）
// 与 rust/src/music/lx_search/tx.rs 的 tx_search_albums（签名 Desktop 接口
// search_type=2）。移动端原本缺失该模块：搜索页歌单/专辑标签对洛雪系插件
// 直接短路返回空，这里是通用修复的 Rust 侧支撑。
//
// 歌单搜索返回归一化条目（id/title/cover/artist/计数 + 原始 raw），
// 供 Dart 侧 PluginRuntimeService.searchPlaylists 的 LX 分支消费；
// 专辑搜索返回原始专辑条目数组，供 Dart 侧 searchAlbums 的 LX 分支消费。

use crate::music::lx_search::{
    decode_name, http_client, http_get_json, http_post_json, mg_create_signature, zzc_sign,
};
use serde::Serialize;
use serde_json::Value;
use std::time::{SystemTime, UNIX_EPOCH};

/// 归一化歌单条目（对应桌面 LxPlaylistSearchResult）。
#[derive(Serialize, Clone, Debug)]
pub struct LxPlaylistItem {
    /// `{source}:playlist:{id}` 复合 ID
    pub id: String,
    /// 平台原生歌单 ID（拉取曲目用）
    pub playlist_id: String,
    pub title: String,
    pub cover_url: Option<String>,
    pub artist: String,
    pub track_count: Option<u64>,
    pub play_count: Option<u64>,
    /// 原始 API 响应条目
    pub raw: Value,
}

const PLAYLIST_ID_KEYS: &[&str] = &[
    "id", "ID", "playlistId", "playlistid", "specialid", "dissid", "disstid",
    "songListId", "songlistId", "musicListId", "rid",
];
const PLAYLIST_TITLE_KEYS: &[&str] = &[
    "title", "name", "playlistName", "specialname", "dissname",
    "songListName", "songlistName", "NAME",
];
const PLAYLIST_ARTIST_KEYS: &[&str] = &[
    "artist", "author", "nickname", "uname", "UNAME", "userName",
];
const PLAYLIST_COVER_KEYS: &[&str] = &[
    "coverUrl", "coverImgUrl", "img", "imgurl", "pic", "picUrl", "pic_url",
    "PIC", "album_pic_url", "hts_pic", "musicListPicUrl",
];
const PLAYLIST_TRACK_COUNT_KEYS: &[&str] = &[
    "trackCount", "trackcount", "songCount", "song_count", "songnum", "SONGNUM", "musicNum",
];
const PLAYLIST_PLAY_COUNT_KEYS: &[&str] = &[
    "playCount", "playcount", "play_count", "playcnt", "listennum", "LISTENNUM", "playNum",
];

/// 顺序取多个候选键里的首个非 null/非空串值（对齐桌面 firstValue）。
fn first_value<'a>(item: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    for key in keys {
        if let Some(v) = item.get(*key) {
            let empty_str = v.as_str().map(|s| s.is_empty()).unwrap_or(false);
            if !v.is_null() && !empty_str {
                return Some(v);
            }
        }
    }
    None
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// 归一化封面 URL：协议相对补 https、http 升级 https。
fn normalize_cover(v: &Value) -> Option<String> {
    let s = v.as_str()?;
    if s.is_empty() {
        return None;
    }
    let url = if let Some(rest) = s.strip_prefix("//") {
        format!("https://{}", rest)
    } else {
        s.replace("http://", "https://")
    };
    Some(url)
}

/// 扁平化两层嵌套数组（对齐桌面 rawItems.flat(2)），过滤非对象项。
fn flatten_items(raw: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    let mut push_value = |v: &Value| {
        if v.is_object() {
            out.push(v.clone());
        }
    };
    match raw {
        Value::Array(top) => {
            for item in top {
                if item.is_array() {
                    if let Some(inner) = item.as_array() {
                        for v in inner {
                            push_value(v);
                        }
                    }
                } else {
                    push_value(item);
                }
            }
        }
        v => push_value(v),
    }
    out
}

/// 归一化歌单搜索结果（对齐桌面 normalizeLxPlaylistResults）。
fn normalize_playlists(source: &str, raw_items: &Value) -> Vec<LxPlaylistItem> {
    let mut results = Vec::new();
    let mut seen = std::collections::HashSet::new();

    for raw in flatten_items(raw_items) {
        let id_value = match first_value(&raw, PLAYLIST_ID_KEYS) {
            Some(v) => v,
            None => continue,
        };
        let title_value = match first_value(&raw, PLAYLIST_TITLE_KEYS) {
            Some(v) => v,
            None => continue,
        };
        let playlist_id = match id_value {
            Value::Number(n) => n.to_string(),
            Value::String(s) => s.clone(),
            _ => continue,
        };
        let dedupe_key = format!("{}:{}", source, playlist_id);
        if !seen.insert(dedupe_key) {
            continue;
        }

        let title_text = title_value.as_str().unwrap_or("");
        let title = decode_name(&strip_html_tags(title_text));
        let cover_url = first_value(&raw, PLAYLIST_COVER_KEYS).and_then(normalize_cover);
        let artist = first_value(&raw, PLAYLIST_ARTIST_KEYS)
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .or_else(|| {
                raw.get("creator").and_then(|c| {
                    c.get("name")
                        .or_else(|| c.get("nickname"))
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                })
            })
            .unwrap_or_default();
        let track_count = first_value(&raw, PLAYLIST_TRACK_COUNT_KEYS)
            .and_then(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse().ok())));
        let play_count = first_value(&raw, PLAYLIST_PLAY_COUNT_KEYS)
            .and_then(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse().ok())));

        results.push(LxPlaylistItem {
            id: format!("{}:playlist:{}", source, playlist_id),
            playlist_id,
            title,
            cover_url,
            artist,
            track_count,
            play_count,
            raw,
        });
    }
    results
}

fn strip_html_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for ch in s.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            c if !in_tag => out.push(c),
            _ => {}
        }
    }
    out
}

/// 酷我旧搜索接口（search.kuwo.cn/r.s）返回 Python 风格单引号 JSON，
/// 标准解析必然失败。状态机转换（对齐桌面 parseLooseJson）：
/// 字符串定界符 ' → "，字符串内的 " 转义，保留原有反斜杠转义。
fn parse_loose_json(text: &str) -> Result<Value, String> {
    let mut out = String::with_capacity(text.len());
    let mut in_str = false;
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let ch = chars[i];
        if !in_str {
            if ch == '\'' {
                in_str = true;
                out.push('"');
            } else {
                out.push(ch);
            }
        } else if ch == '\\' {
            out.push(ch);
            if i + 1 < chars.len() {
                out.push(chars[i + 1]);
                i += 1;
            }
        } else if ch == '\'' {
            in_str = false;
            out.push('"');
        } else {
            if ch == '"' {
                out.push('\\');
            }
            out.push(ch);
        }
        i += 1;
    }
    serde_json::from_str(&out).map_err(|e| format!("loose JSON: {}", e))
}

/// 宽松 GET：标准 JSON 失败时尝试单引号状态机转换（对齐桌面 httpGetLooseJson）。
async fn http_get_loose_json(
    url: &str,
    headers: &[(&str, &str)],
) -> Result<Value, String> {
    match http_get_json(url, headers).await {
        Ok(v) => Ok(v),
        Err(e) if e.starts_with("Invalid JSON") => {
            let body = http_get_text(url, headers).await?;
            parse_loose_json(&body).map_err(|_| e)
        }
        Err(e) => Err(e),
    }
}

/// GET 原始文本（仅宽松解析兜底用）。
async fn http_get_text(url: &str, headers: &[(&str, &str)]) -> Result<String, String> {
    let client = http_client().as_ref().map_err(|e| e.clone())?;
    let mut req = client.get(url);
    for (k, v) in headers {
        req = req.header(*k, *v);
    }
    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    let body = resp.text().await.map_err(|e| e.to_string())?;
    if status != 200 {
        return Err(format!("HTTP {} for {}", status, url));
    }
    Ok(body)
}

fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

/// 生成一个类似 Date.now().toString().slice(2) 的随机 ID（对齐桌面 tx.rs）。
fn chrono_like_random() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let mut val = now.as_millis() as u64;
    val = val.wrapping_mul(1000) + (val % 900);
    val
}

/// Desktop 接口随机 guid：32 位大写 hex（对齐桌面 tx.rs）。
fn random_tx_guid() -> String {
    let mut state = chrono_like_random();
    let mut s = String::with_capacity(32);
    for _ in 0..32 {
        s.push(
            char::from_digit((state % 16) as u32, 16)
                .unwrap()
                .to_ascii_uppercase(),
        );
        state = state
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
    }
    s
}

/// Desktop 接口随机 wid：19 位数字（首位非零，对齐桌面 tx.rs）。
fn random_tx_wid() -> String {
    let mut state = chrono_like_random().wrapping_mul(76263).wrapping_add(17);
    let mut s = String::with_capacity(19);
    s.push(char::from_digit(1 + (state % 9) as u32, 10).unwrap());
    while s.len() < 19 {
        state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
        s.push(char::from_digit((state % 10) as u32, 10).unwrap());
    }
    s
}

/// Desktop 接口随机 searchid 尾号：5 位数字（对齐桌面 tx.rs）。
fn random_5_digits() -> u64 {
    chrono_like_random().wrapping_mul(7919).wrapping_add(104729) % 100000
}

// ==================== 歌单搜索 ====================

/// LX 歌单搜索（对齐桌面 searchLxPlaylists）。
pub async fn lx_search_playlists(
    source: &str,
    keyword: &str,
    page: u32,
    limit: u32,
) -> Result<Vec<LxPlaylistItem>, String> {
    match source {
        "kw" => {
            // 优先新 API，被风控/空结果时回退旧 r.s 接口（单引号 JSON）。
            let new_url = format!(
                "https://www.kuwo.cn/api/www/search/searchPlayListBykeyWord?key={}&pn={}&rn={}",
                urlencode(keyword),
                page,
                limit
            );
            if let Ok(data) = http_get_json(
                &new_url,
                &[
                    ("csrf", "ABCDEF"),
                    ("Cookie", "kw_token=ABCDEF"),
                    ("Referer", "https://www.kuwo.cn/"),
                ],
            )
            .await
            {
                let list = data
                    .pointer("/data/list")
                    .or_else(|| data.get("data"))
                    .cloned()
                    .unwrap_or(Value::Null);
                if list.as_array().map(|a| !a.is_empty()).unwrap_or(false) {
                    return Ok(normalize_playlists(source, &list));
                }
            }
            let old_url = format!(
                "https://search.kuwo.cn/r.s?client=kt&all={}&pn={}&rn={}&ft=playlist&encoding=utf8&rformat=json",
                urlencode(keyword),
                page - 1,
                limit
            );
            let data = http_get_loose_json(
                &old_url,
                &[("Referer", "https://www.kuwo.cn/")],
            )
            .await?;
            let list = data
                .get("abslist")
                .or_else(|| data.get("data"))
                .cloned()
                .unwrap_or(Value::Array(Vec::new()));
            Ok(normalize_playlists(source, &list))
        }
        "kg" => {
            let url = format!(
                "https://songsearch.kugou.com/special_search?keyword={}&page={}&pagesize={}&userid=-1&clientver=&platform=WebFilter&filter=0&iscorrection=1&privilege_filter=0",
                urlencode(keyword),
                page,
                limit
            );
            let data = http_get_json(&url, &[]).await?;
            let list = data
                .pointer("/data/lists")
                .or_else(|| data.pointer("/data/list"))
                .cloned()
                .unwrap_or(Value::Array(Vec::new()));
            Ok(normalize_playlists(source, &list))
        }
        "wy" => {
            let offset = limit * (page - 1);
            let url = format!(
                "https://music.163.com/api/search/get/web?s={}&type=1000&offset={}&limit={}",
                urlencode(keyword),
                offset,
                limit
            );
            let data = http_get_json(
                &url,
                &[
                    ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"),
                    ("Referer", "https://music.163.com"),
                    ("Cookie", "MUSIC_A=1"),
                ],
            )
            .await?;
            let list = data
                .pointer("/result/playlists")
                .cloned()
                .unwrap_or(Value::Array(Vec::new()));
            Ok(normalize_playlists(source, &list))
        }
        "tx" => {
            // 新签名(Mobile)通道，被风控/降级时回退无签名 Desktop 通道（实测稳定）。
            let request_data = serde_json::json!({
                "comm": {
                    "ct": "24", "cv": "4747474", "v": "4747474",
                    "tmeAppID": "qqmusic", "format": "json",
                    "inCharset": "utf-8", "outCharset": "utf-8",
                    "platform": "yqq.json", "needNewCode": 0,
                    "uin": "0", "guid": "0",
                },
                "req": {
                    "module": "music.search.SearchCgiService",
                    "method": "DoSearchForQQMusicMobile",
                    "param": {
                        "search_type": 3,
                        "searchid": format!("{}{:05}", random_tx_guid(), random_5_digits()),
                        "query": keyword,
                        "page_num": page,
                        "num_per_page": limit,
                        "highlight": 0, "nqc_flag": 0, "multi_zhida": 0,
                        "cat": 2, "grp": 1, "sin": 0, "sem": 0,
                    },
                },
            });
            let request_str = serde_json::to_string(&request_data).map_err(|e| e.to_string())?;
            let mut list: Vec<Value> = Vec::new();
            let sign = zzc_sign(&request_str);
            let url = format!("https://u.y.qq.com/cgi-bin/musics.fcg?sign={}", sign);
            if let Ok(data) = http_post_json(
                &url,
                &request_str,
                &[
                    ("User-Agent", "Mozilla/5.0 (Linux; Android 12; EBG-AN10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.5304.141 Mobile Safari/537.36"),
                    ("Content-Type", "application/json"),
                    ("Referer", "https://y.qq.com/"),
                ],
            )
            .await
            {
                let body = data.pointer("/req/data/body").cloned().unwrap_or(Value::Null);
                let picked = body
                    .pointer("/item_songlist")
                    .or_else(|| body.pointer("/songlist/list"))
                    .cloned()
                    .unwrap_or(Value::Array(Vec::new()));
                if picked.as_array().map(|a| !a.is_empty()).unwrap_or(false) {
                    list = picked.as_array().cloned().unwrap_or_default();
                }
            }
            if list.is_empty() {
                list = tx_sheet_search_desktop_fallback(keyword, page, limit).await?;
            }
            Ok(normalize_playlists(source, &Value::Array(list)))
        }
        "mg" => {
            let time = now_ms().to_string();
            let (sign, device_id) = mg_create_signature(&time, keyword);
            let search_switch = urlencode(
                r#"{"song":0,"album":0,"singer":0,"tagSong":0,"mvSong":0,"bestShow":0,"songlist":1,"lyricSong":0}"#,
            );
            let url = format!(
                "https://jadeite.migu.cn/music_search/v3/search/searchAll?isCorrect=0&isCopyright=1&searchSwitch={}&pageSize={}&text={}&pageNo={}&sort=0&sid=USS",
                search_switch,
                limit,
                urlencode(keyword),
                page
            );
            let data = http_get_json(
                &url,
                &[
                    ("uiVersion", "A_music_3.6.1"),
                    ("deviceId", device_id.as_str()),
                    ("timestamp", time.as_str()),
                    ("sign", sign.as_str()),
                    ("channel", "0146921"),
                    ("User-Agent", "Mozilla/5.0 (Linux; Android 11)"),
                ],
            )
            .await?;
            let result_data = data
                .get("songListResultData")
                .or_else(|| data.get("songlistResultData"))
                .cloned()
                .unwrap_or(Value::Null);
            // 咪咕 V3 歌单数组在 songListResultData.result（resultList/list 不存在，
            // 读错字段会静默返回空——对齐桌面端 lxMusicSdkCatalog 的修复）
            let list = result_data
                .get("result")
                .or_else(|| result_data.get("resultList"))
                .or_else(|| result_data.get("list"))
                .cloned()
                .unwrap_or(Value::Array(Vec::new()));
            Ok(normalize_playlists(source, &list))
        }
        _ => Err(format!("Unknown lx source: {}", source)),
    }
}

/// TX 歌单搜索无签名 Desktop 兜底（对齐桌面 txSheetSearchDesktopFallback）：
/// musicu.fcg DoSearchForQQMusicDesktop search_type=3 → body.songlist.list。
async fn tx_sheet_search_desktop_fallback(
    keyword: &str,
    page: u32,
    limit: u32,
) -> Result<Vec<Value>, String> {
    let body = serde_json::json!({
        "comm": { "ct": 19, "cv": 1859, "uin": "0" },
        "req": {
            "module": "music.search.SearchCgiService",
            "method": "DoSearchForQQMusicDesktop",
            "param": {
                "search_type": 3,
                "query": keyword,
                "page_num": page,
                "num_per_page": limit,
            },
        },
    });
    let body_str = serde_json::to_string(&body).map_err(|e| e.to_string())?;
    let data = http_post_json(
        "https://u.y.qq.com/cgi-bin/musicu.fcg",
        &body_str,
        &[
            ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"),
            ("Content-Type", "application/json"),
            ("Referer", "https://y.qq.com/"),
        ],
    )
    .await?;
    let list = data
        .pointer("/req/data/body/songlist/list")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    if list.is_empty() {
        return Err("TX sheet desktop fallback: 无有效歌单".to_string());
    }
    Ok(list)
}

// ==================== QQ 专辑搜索 ====================

/// QQ 专辑搜索（签名 Desktop 接口 search_type=2）内置实现。
///
/// 对齐桌面端 createTxDesktopSearchRequestData，按请求随机 guid/wid 与移动端
/// 搜索分属不同风控池。返回原始专辑条目（albumMID/albumID/albumName/albumPic/
/// publicTime/singerName 等），供 QQ 插件专辑搜索兜底消费。
pub async fn tx_search_albums(
    keyword: &str,
    page: u32,
    limit: u32,
) -> Result<Vec<serde_json::Value>, String> {
    let request_data = serde_json::json!({
        "comm": {
            "_channelid": "0",
            "_os_version": "6.2.9200-2",
            "ct": "19",
            "cv": "2151",
            "guid": random_tx_guid(),
            "patch": "118",
            "psrf_access_token_expiresAt": 0,
            "psrf_qqaccess_token": "",
            "psrf_qqopenid": "",
            "psrf_qqunionid": "",
            "tmeAppID": "qqmusic",
            "tmeLoginType": 0,
            "uin": "0",
            "wid": random_tx_wid(),
        },
        "req": {
            "module": "music.search.SearchCgiService",
            "method": "DoSearchForQQMusicDesktop",
            "param": {
                "grp": 1,
                "num_per_page": limit,
                "page_num": page,
                "query": keyword,
                "remoteplace": "txt.newclient.top",
                "search_type": 2,
                "searchid": format!("{}{:05}", random_tx_guid(), random_5_digits()),
            },
        },
    });
    let request_str = serde_json::to_string(&request_data).map_err(|e| e.to_string())?;
    let sign = zzc_sign(&request_str);
    let url = format!("https://u.y.qq.com/cgi-bin/musics.fcg?sign={}", sign);
    let body = http_post_json(
        &url,
        &request_str,
        &[
            ("User-Agent", "QQMusic 14090508(android 12)"),
            ("Content-Type", "application/json"),
            ("Referer", "https://y.qq.com/"),
        ],
    )
    .await?;
    if body.get("code").and_then(|v| v.as_i64()) != Some(0)
        || body.pointer("/req/code").and_then(|v| v.as_i64()) != Some(0)
    {
        return Err("TX album search: invalid response code".to_string());
    }
    let data = body
        .pointer("/req/data")
        .unwrap_or(&serde_json::Value::Null);
    Ok(tx_pick_album_raw_list(data))
}

/// 提取专辑搜索结果列表：Desktop 响应的专辑在 body.album.list（无签名接口才是
/// item_album），再兜底兼容直接返回数组的形态。
fn tx_pick_album_raw_list(data: &serde_json::Value) -> Vec<serde_json::Value> {
    for path in ["/body/album/list", "/body/item_album/list"] {
        if let Some(arr) = data.pointer(path).and_then(|v| v.as_array()) {
            if !arr.is_empty() {
                return arr.clone();
            }
        }
    }
    if let Some(arr) = data.as_array() {
        return arr.clone();
    }
    Vec::new()
}
