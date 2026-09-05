//! Alist / OpenList REST API 驱动：网盘挂载的统一访问层。
//!
//! TVBox 接口里的网盘站点与用户直填的 Alist/OpenList 服务器都走这套
//! REST 接口（`/api/auth/login`、`/api/fs/list`、`/api/fs/get`）。
//! 挂载后递归扫描音频文件入库，播放时解析 `raw_url` 直链或 `/p` 代理流。

use super::types::RemoteSourceCredentials;
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, CONTENT_TYPE, RANGE};
use reqwest::{Client, StatusCode};
use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use tokio::io::AsyncWriteExt;

pub(crate) fn shared_client() -> &'static Client {
    static CLIENT: OnceLock<Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(300))
            .pool_max_idle_per_host(4)
            .build()
            .expect("build alist http client")
    })
}

// ---------------------------------------------------------------------------
// 路径处理：remote_path 相对 root_path，与旧 WebDAV 驱动语义一致。
// ---------------------------------------------------------------------------

fn normalize_remote_path(path: &str) -> String {
    let normalized = path.replace('\\', "/");
    let trimmed = normalized.trim();
    if trimmed.is_empty() || trimmed == "/" {
        "/".to_string()
    } else if trimmed.starts_with('/') {
        trimmed.trim_end_matches('/').to_string()
    } else {
        format!("/{}", trimmed.trim_end_matches('/'))
    }
}

fn path_for_request(source: &RemoteSourceCredentials, path: &str) -> String {
    let normalized = normalize_remote_path(path);
    let root = normalize_remote_path(&source.root_path);
    if root == "/" || normalized == root || normalized.starts_with(&format!("{}/", root)) {
        normalized
    } else if normalized == "/" {
        root
    } else {
        format!(
            "{}/{}",
            root.trim_end_matches('/'),
            normalized.trim_start_matches('/')
        )
    }
}

/// REST API 根地址。旧 WebDAV 源的地址可能以 `/dav` 结尾（WebDAV 路径），
/// REST 接口挂在站点根上，需剥掉该后缀。
fn api_origin(source: &RemoteSourceCredentials) -> String {
    let base = source.base_url.trim().trim_end_matches('/');
    base.strip_suffix("/dav").unwrap_or(base).to_string()
}

fn encode_path(path: &str) -> String {
    path.split('/')
        .filter(|segment| !segment.is_empty())
        .map(urlencoding::encode)
        .collect::<Vec<_>>()
        .join("/")
}

fn join_remote_path(base: &str, name: &str) -> String {
    let base = normalize_remote_path(base);
    if base == "/" {
        format!("/{}", name)
    } else {
        format!("{}/{}", base, name)
    }
}

fn supported_audio_extension(path: &str) -> bool {
    matches!(
        path.rsplit('.').next().map(|value| value.to_ascii_lowercase()),
        Some(ext)
            if matches!(
                ext.as_str(),
                "mp3" | "flac" | "wav" | "m4a" | "aac" | "ogg" | "opus" | "aiff" | "aif" | "wma"
                    | "ape"
            )
    )
}

// ---------------------------------------------------------------------------
// 登录与 token 缓存
// ---------------------------------------------------------------------------

type TokenCache = HashMap<String, (String, i64)>;
static TOKEN_CACHE: OnceLock<Mutex<TokenCache>> = OnceLock::new();

fn token_cache() -> &'static Mutex<TokenCache> {
    TOKEN_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

const TOKEN_TTL_SECONDS: i64 = 12 * 3600;

#[derive(serde::Deserialize)]
// serde 派生会给 `#[serde(default)]` 的泛型字段附加 `T: Default` 约束，
// 这里显式声明反序列化 bound 以解除该限制。
#[serde(bound(deserialize = "T: serde::de::DeserializeOwned"))]
struct AlistResp<T> {
    pub code: i64,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub data: Option<T>,
}

fn api_error_message(code: i64, message: Option<String>) -> String {
    let detail = message
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_default();
    match code {
        401 if detail.is_empty() => {
            "需要登录（401）：请填写 Alist/OpenList 账号密码，或检查凭据是否正确".to_string()
        }
        401 => format!("账号或密码错误（401）：{detail}"),
        403 if detail.is_empty() => "没有访问权限（403）".to_string(),
        403 => format!("没有访问权限（403）：{detail}"),
        _ if !detail.is_empty() => format!("接口错误（{code}）：{detail}"),
        _ => format!("接口错误（{code}）"),
    }
}

/// 登录获取 token（带缓存）。未配置用户名时返回 None（游客直连）。
async fn auth_token(client: &Client, source: &RemoteSourceCredentials) -> Result<Option<String>, String> {
    let username = source
        .username
        .as_deref()
        .map(str::trim)
        .unwrap_or_default();
    if username.is_empty() {
        return Ok(None);
    }

    let now = super::now_seconds();
    if let Ok(cache) = token_cache().lock() {
        if let Some((token, expires)) = cache.get(&source.id) {
            if *expires > now && !token.is_empty() {
                return Ok(Some(token.clone()));
            }
        }
    }

    #[derive(serde::Serialize)]
    struct LoginBody<'a> {
        username: &'a str,
        password: &'a str,
    }
    #[derive(serde::Deserialize)]
    struct LoginData {
        #[serde(default)]
        token: String,
    }

    let body = serde_json::to_string(&LoginBody {
        username,
        password: source.password.as_deref().unwrap_or(""),
    })
    .map_err(|error| error.to_string())?;
    let origin = api_origin(source);
    let resp: AlistResp<LoginData> = client
        .post(format!("{origin}/api/auth/login"))
        .header(CONTENT_TYPE, "application/json")
        .body(body)
        .send()
        .await
        .map_err(|error| format!("无法连接服务器：{error}"))?
        .json()
        .await
        .map_err(|_| "服务器响应不是 Alist/OpenList 格式，请检查地址".to_string())?;
    if resp.code != 200 {
        return Err(api_error_message(resp.code, resp.message));
    }
    let token = resp.data.map(|data| data.token).unwrap_or_default();
    if token.is_empty() {
        return Err("登录失败：服务器未返回令牌".to_string());
    }
    if let Ok(mut cache) = token_cache().lock() {
        cache.insert(source.id.clone(), (token.clone(), now + TOKEN_TTL_SECONDS));
    }
    Ok(Some(token))
}

/// 带认证的 `/api/fs/*` POST 请求。401 时清 token 重登重试一次。
async fn fs_post<T: serde::de::DeserializeOwned>(
    client: &Client,
    source: &RemoteSourceCredentials,
    endpoint: &str,
    body: &serde_json::Value,
) -> Result<T, String> {
    let payload = serde_json::to_string(body).map_err(|error| error.to_string())?;
    let url = format!("{}/api/fs/{endpoint}", api_origin(source));
    let mut refreshed = false;
    loop {
        let token = auth_token(client, source).await?;
        let mut request = client
            .post(&url)
            .header(CONTENT_TYPE, "application/json")
            .body(payload.clone());
        if let Some(token) = token.as_deref() {
            request = request.header(AUTHORIZATION, token);
        }
        let resp: AlistResp<T> = request
            .send()
            .await
            .map_err(|error| format!("无法连接服务器：{error}"))?
            .json()
            .await
            .map_err(|_| "服务器响应不是 Alist/OpenList 格式，请检查地址".to_string())?;
        if resp.code == 200 {
            return resp.data.ok_or_else(|| "服务器未返回数据".to_string());
        }
        // token 过期时重登一次再试
        if resp.code == 401 && !refreshed {
            let has_credentials = source
                .username
                .as_deref()
                .map(|value| !value.trim().is_empty())
                .unwrap_or(false);
            if has_credentials {
                refreshed = true;
                if let Ok(mut cache) = token_cache().lock() {
                    cache.remove(&source.id);
                }
                continue;
            }
        }
        return Err(api_error_message(resp.code, resp.message));
    }
}

// ---------------------------------------------------------------------------
// fs/list：目录浏览
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, serde::Deserialize)]
struct AlistEntry {
    name: String,
    #[serde(default)]
    size: u64,
    #[serde(default)]
    is_dir: bool,
    #[serde(default)]
    modified: Option<String>,
}

#[derive(serde::Deserialize)]
struct ListData {
    #[serde(default)]
    content: Option<Vec<AlistEntry>>,
    #[serde(default)]
    total: i64,
}

const LIST_PAGE_SIZE: i64 = 100;

/// 分页拉取目录全部条目（Alist fs/list，per_page 上限分页循环）。
async fn fs_list_entries(
    client: &Client,
    source: &RemoteSourceCredentials,
    full_path: &str,
) -> Result<Vec<AlistEntry>, String> {
    let mut entries = Vec::new();
    let mut page = 1i64;
    loop {
        let body = serde_json::json!({
            "path": full_path,
            "page": page,
            "per_page": LIST_PAGE_SIZE,
            "refresh": false,
        });
        let data: ListData = fs_post(client, source, "list", &body).await?;
        let content = data.content.unwrap_or_default();
        let fetched = content.len() as i64;
        entries.extend(content);
        let total = data.total;
        if fetched == 0 || fetched < LIST_PAGE_SIZE || (total > 0 && entries.len() as i64 >= total)
        {
            break;
        }
        page += 1;
        if page > 1000 {
            break; // 防御：异常响应导致无限翻页
        }
    }
    Ok(entries)
}

use super::types::RemoteFileEntry;

/// 列出远程目录（path 相对 root_path），返回子项。
pub(crate) async fn list_directory(
    client: &Client,
    source: &RemoteSourceCredentials,
    path: &str,
) -> Result<Vec<RemoteFileEntry>, String> {
    let base = normalize_remote_path(path);
    let full = path_for_request(source, path);
    let entries = fs_list_entries(client, source, &full).await?;
    Ok(entries
        .into_iter()
        .map(|entry| RemoteFileEntry {
            remote_path: join_remote_path(&base, &entry.name),
            name: entry.name,
            size: entry.size,
            etag: None,
            modified_at: entry.modified,
            is_dir: entry.is_dir,
        })
        .collect())
}

/// 递归收集全部音频文件（BFS）。
pub(crate) async fn collect_audio_files(
    source: &RemoteSourceCredentials,
) -> Result<Vec<RemoteFileEntry>, String> {
    let client = shared_client();
    let mut queue = VecDeque::from(["/".to_string()]);
    let mut files = Vec::new();
    while let Some(path) = queue.pop_front() {
        for entry in list_directory(&client, source, &path).await? {
            if entry.is_dir {
                queue.push_back(entry.remote_path);
            } else if supported_audio_extension(&entry.remote_path) {
                files.push(entry);
            }
        }
    }
    Ok(files)
}

/// 测试连接：浏览根目录。
pub(crate) async fn test_connection(source: &RemoteSourceCredentials) -> Result<(), String> {
    let client = shared_client();
    list_directory(&client, source, "/").await?;
    Ok(())
}

// ---------------------------------------------------------------------------
// fs/get：文件直链解析
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, serde::Deserialize)]
struct FsGetData {
    #[serde(default)]
    raw_url: Option<String>,
    #[serde(default)]
    sign: Option<String>,
    /// 访问 raw_url 需要的额外请求头（JSON 字符串，如 UA/Referer 防盗链）
    #[serde(default)]
    header: Option<String>,
}

#[derive(Clone, Debug)]
struct FsGetInfo {
    raw_url: Option<String>,
    proxy_url: String,
    headers: Option<HashMap<String, String>>,
}

fn parse_header_field(raw: &Option<String>) -> Option<HashMap<String, String>> {
    let raw = raw.as_deref()?.trim();
    if raw.is_empty() {
        return None;
    }
    let parsed: HashMap<String, String> = serde_json::from_str(raw).ok()?;
    if parsed.is_empty() {
        None
    } else {
        Some(parsed)
    }
}

/// 解析文件信息：raw_url 直链 + /p 代理直链（全驱动兼容的兜底）。
async fn fs_get(
    client: &Client,
    source: &RemoteSourceCredentials,
    full_path: &str,
) -> Result<FsGetInfo, String> {
    let body = serde_json::json!({ "path": full_path, "password": "" });
    let data: FsGetData = fs_post(client, source, "get", &body).await?;
    let origin = api_origin(source);
    let mut proxy_url = format!("{}/p/{}", origin, encode_path(full_path));
    if let Some(sign) = data.sign.as_deref() {
        if !sign.is_empty() {
            proxy_url = format!("{proxy_url}?sign={sign}");
        }
    }
    Ok(FsGetInfo {
        raw_url: data
            .raw_url
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty()),
        proxy_url,
        headers: parse_header_field(&data.header),
    })
}

/// 流式播放地址：优先 raw_url（直链最快），否则 /p 代理；
/// fs/get 整体失败时退回无签名代理直链（未开启签名的站点仍可播）。
pub(crate) async fn stream_source(
    source: &RemoteSourceCredentials,
    remote_path: &str,
) -> Result<(String, Option<HashMap<String, String>>), String> {
    let client = shared_client();
    let full = path_for_request(source, remote_path);
    match fs_get(&client, source, &full).await {
        Ok(info) => {
            if let Some(raw_url) = &info.raw_url {
                return Ok((raw_url.clone(), info.headers.clone()));
            }
            Ok((info.proxy_url, None))
        }
        Err(_) => {
            let origin = api_origin(source);
            Ok((format!("{}/p/{}", origin, encode_path(&full)), None))
        }
    }
}

// ---------------------------------------------------------------------------
// 文本读取（歌词 .lrc sidecar）与下载
// ---------------------------------------------------------------------------

fn decode_text_bytes(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(text) => text.trim_start_matches('\u{feff}').to_string(),
        Err(_) => {
            let (decoded, _, _) = encoding_rs::GBK.decode(bytes);
            decoded.trim_start_matches('\u{feff}').to_string()
        }
    }
}

/// 读取远程文本文件（歌词）；文件不存在返回 None。
pub(crate) async fn read_text_file(
    source: &RemoteSourceCredentials,
    path: &str,
) -> Result<Option<String>, String> {
    let client = shared_client();
    let full = path_for_request(source, path);
    let info = match fs_get(&client, source, &full).await {
        Ok(info) => info,
        Err(error) => {
            // Alist 对不存在路径多返回 500 "object not found"，视为无歌词。
            if error.contains("not found") || error.contains("不存在") {
                return Ok(None);
            }
            return Err(error);
        }
    };
    let url = info.raw_url.clone().unwrap_or(info.proxy_url);
    let mut request = client.get(&url);
    if let Some(headers) = &info.headers {
        let mut header_map = HeaderMap::new();
        for (key, value) in headers {
            if let (Ok(name), Ok(val)) = (
                reqwest::header::HeaderName::try_from(key.as_str()),
                HeaderValue::from_str(value),
            ) {
                header_map.insert(name, val);
            }
        }
        request = request.headers(header_map);
    }
    let response = request
        .send()
        .await
        .map_err(|error| format!("歌词下载失败：{error}"))?;
    if response.status() == StatusCode::NOT_FOUND {
        return Ok(None);
    }
    if !response.status().is_success() {
        return Err(format!("歌词下载失败（{}）", response.status()));
    }
    let bytes = response
        .bytes()
        .await
        .map_err(|error| error.to_string())?;
    Ok(Some(decode_text_bytes(&bytes)))
}

#[derive(Debug, PartialEq, Eq)]
enum DownloadWriteMode {
    Fresh,
    Append,
}

fn choose_download_write_mode(existing_bytes: u64, status: StatusCode) -> DownloadWriteMode {
    if existing_bytes > 0 && status == StatusCode::PARTIAL_CONTENT {
        DownloadWriteMode::Append
    } else {
        DownloadWriteMode::Fresh
    }
}

/// 断点续传下载远程文件到本地（经 raw_url 直链，附防盗链 headers）。
pub(crate) async fn download_file_to_path(
    source: &RemoteSourceCredentials,
    remote_path: &str,
    target_path: &Path,
    mut on_progress: impl FnMut(u64, Option<u64>) + Send,
) -> Result<(), String> {
    let client = shared_client();
    let (url, headers) = stream_source(source, remote_path).await?;

    let existing_bytes = tokio::fs::metadata(target_path)
        .await
        .map(|metadata| metadata.len())
        .unwrap_or(0);
    let mut request = client.get(&url);
    if existing_bytes > 0 {
        request = request.header(RANGE, format!("bytes={existing_bytes}-"));
    }
    if let Some(headers) = &headers {
        for (key, value) in headers {
            if let (Ok(name), Ok(val)) = (
                reqwest::header::HeaderName::try_from(key.as_str()),
                HeaderValue::from_str(value),
            ) {
                request = request.header(name, val);
            }
        }
    }
    let mut response = request
        .send()
        .await
        .map_err(|error| format!("远程文件下载失败：{error}"))?;
    if !response.status().is_success() {
        return Err(format!("远程文件下载失败（{}）", response.status()));
    }

    let write_mode = choose_download_write_mode(existing_bytes, response.status());
    let content_length = response.content_length();
    let total = match write_mode {
        DownloadWriteMode::Append => content_length.map(|length| existing_bytes + length),
        DownloadWriteMode::Fresh => content_length,
    };
    let mut downloaded = match write_mode {
        DownloadWriteMode::Append => existing_bytes,
        DownloadWriteMode::Fresh => 0,
    };
    on_progress(downloaded, total);

    let mut file = match write_mode {
        DownloadWriteMode::Append => tokio::fs::OpenOptions::new()
            .append(true)
            .open(target_path)
            .await
            .map_err(|error| error.to_string())?,
        DownloadWriteMode::Fresh => tokio::fs::File::create(target_path)
            .await
            .map_err(|error| error.to_string())?,
    };
    while let Some(chunk) = response.chunk().await.map_err(|error| error.to_string())? {
        downloaded = downloaded.saturating_add(chunk.len() as u64);
        file.write_all(&chunk)
            .await
            .map_err(|error| error.to_string())?;
        on_progress(downloaded, total);
    }
    file.flush().await.map_err(|error| error.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn remote_source(base_url: &str, root_path: &str) -> RemoteSourceCredentials {
        RemoteSourceCredentials {
            id: "source".to_string(),
            name: "Source".to_string(),
            provider: "alist".to_string(),
            base_url: base_url.to_string(),
            username: None,
            password: None,
            root_path: root_path.to_string(),
            enabled: true,
            last_sync_at: None,
            last_sync_error: None,
            created_at: 0,
            updated_at: 0,
        }
    }

    #[test]
    fn path_for_request_keeps_root_path_for_root_relative_file() {
        assert_eq!(
            path_for_request(&remote_source("https://a.example.com", "/music"), "/song.wav"),
            "/music/song.wav"
        );
    }

    #[test]
    fn path_for_request_does_not_duplicate_root_path() {
        assert_eq!(
            path_for_request(&remote_source("https://a.example.com", "/music"), "/music/song.wav"),
            "/music/song.wav"
        );
    }

    #[test]
    fn api_origin_strips_webdav_suffix() {
        assert_eq!(
            api_origin(&remote_source("https://a.example.com/dav/", "/")),
            "https://a.example.com"
        );
        assert_eq!(
            api_origin(&remote_source("https://a.example.com", "/")),
            "https://a.example.com"
        );
    }

    #[test]
    fn join_remote_path_handles_root_base() {
        assert_eq!(join_remote_path("/", "a.mp3"), "/a.mp3");
        assert_eq!(join_remote_path("/music", "a.mp3"), "/music/a.mp3");
    }

    #[test]
    fn resumes_when_partial_file_gets_partial_content() {
        assert_eq!(
            choose_download_write_mode(1024, StatusCode::PARTIAL_CONTENT),
            DownloadWriteMode::Append
        );
    }

    #[test]
    fn restarts_when_server_ignores_range_request() {
        assert_eq!(
            choose_download_write_mode(1024, StatusCode::OK),
            DownloadWriteMode::Fresh
        );
    }

    #[test]
    fn decodes_gbk_lyrics_text() {
        let (bytes, _, _) = encoding_rs::GBK.encode("[00:01.00]中文歌词");
        assert_eq!(decode_text_bytes(&bytes), "[00:01.00]中文歌词");
    }

    #[test]
    fn strips_utf8_bom_from_lyrics_text() {
        assert_eq!(
            decode_text_bytes(b"\xef\xbb\xbf[00:01.00]hello"),
            "[00:01.00]hello"
        );
    }

    #[test]
    fn maps_common_api_codes_to_guidance() {
        assert!(api_error_message(401, None).contains("需要登录"));
        assert!(api_error_message(401, Some("wrong password".into())).contains("账号或密码错误"));
        assert!(api_error_message(403, None).contains("403"));
    }

    #[test]
    fn parse_header_field_parses_json_headers() {
        assert!(parse_header_field(&Some("{\"User-Agent\":\"Mozilla\"}".to_string()))
            .is_some());
        assert!(parse_header_field(&Some("{}".to_string())).is_none());
        assert!(parse_header_field(&Some("not json".to_string())).is_none());
        assert!(parse_header_field(&None).is_none());
    }
}
