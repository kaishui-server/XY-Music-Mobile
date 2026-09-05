//! TVBox 接口订阅解析：拉取 TVBox JSON 配置，识别其中可挂载的
//! Alist/OpenList 网盘站点。
//!
//! TVBox 配置的 `sites` 数组大多是视频 CMS/spider 站点（无法当网盘挂载），
//! 这里通过 api 地址特征与站点名启发式标记疑似 Alist 的站点，由上层
//! 调 `alist_test_connection` 实测后入库；同时探测配置地址本身是否就是
//! 一个 Alist/OpenList 服务器（用户直接粘贴网盘地址的场景）。

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TvboxSite {
    pub key: String,
    pub name: String,
    pub site_type: i64,
    pub api: String,
    /// 疑似 Alist/OpenList 站点（api 含 /api/fs/ 或站名含关键字）
    pub likely_alist: bool,
    /// api URL 的站点根（作为挂载 baseUrl 候选），非 URL 型 api 为空
    pub base_url: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TvboxSubscription {
    pub sites: Vec<TvboxSite>,
    /// 配置地址本身是 Alist/OpenList 服务器（直接粘贴网盘地址场景）
    pub root_is_alist: bool,
    pub root_url: String,
}

#[derive(Deserialize)]
struct TvboxConfig {
    #[serde(default)]
    sites: Vec<TvboxConfigSite>,
}

#[derive(Deserialize)]
struct TvboxConfigSite {
    #[serde(default)]
    key: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    r#type: i64,
    #[serde(default)]
    api: String,
}

fn http_origin(url: &str) -> Option<String> {
    let parsed = reqwest::Url::parse(url).ok()?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return None;
    }
    Some(parsed.origin().ascii_serialization())
}

fn looks_like_alist(api: &str, name: &str) -> bool {
    if api.contains("/api/fs/") || api.contains("/api/public") {
        return true;
    }
    let lower = name.to_lowercase();
    lower.contains("alist") || lower.contains("openlist") || lower.contains("网盘")
}

/// GET 一个 URL 文本（带浏览器 UA，TVBox 配置源常见 UA 校验）。
async fn fetch_text(client: &reqwest::Client, url: &str) -> Result<String, String> {
    let response = client
        .get(url)
        .header("User-Agent", "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36")
        .timeout(std::time::Duration::from_secs(15))
        .send()
        .await
        .map_err(|error| format!("接口地址无法访问：{error}"))?;
    if !response.status().is_success() {
        return Err(format!("接口地址返回状态码 {}", response.status()));
    }
    response
        .text()
        .await
        .map_err(|error| format!("接口内容读取失败：{error}"))
}

/// 探测地址是否为 Alist/OpenList 服务器（公开设置接口无需登录）。
async fn probe_alist(client: &reqwest::Client, base_url: &str) -> bool {
    #[derive(Deserialize)]
    struct SettingsResp {
        code: i64,
    }
    let Ok(response) = client
        .get(format!("{}/api/public/settings", base_url.trim_end_matches('/')))
        .timeout(std::time::Duration::from_secs(6))
        .send()
        .await
    else {
        return false;
    };
    match response.json::<SettingsResp>().await {
        Ok(resp) => resp.code == 200,
        Err(_) => false,
    }
}

fn normalize_config_url(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return trimmed.to_string();
    }
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        trimmed.to_string()
    } else {
        format!("https://{trimmed}")
    }
}

/// 拉取并解析 TVBox 接口配置。
///
/// - 配置含 `sites`：返回全部站点（标记疑似 Alist 的可挂载项）；
/// - 配置地址本身是 Alist/OpenList：`rootIsAlist=true`，可直接挂载；
/// - 两者都不是：报错提示。
pub(crate) async fn fetch_subscription(config_url: &str) -> Result<TvboxSubscription, String> {
    let url = normalize_config_url(config_url);
    if url.is_empty() {
        return Err("请填写 TVBox 接口或 Alist/OpenList 地址".to_string());
    }
    let client = super::alist::shared_client().clone();
    let text = fetch_text(&client, &url).await?;

    let mut sites: Vec<TvboxSite> = Vec::new();
    if let Ok(config) = serde_json::from_str::<TvboxConfig>(&text) {
        for site in config.sites {
            let api = site.api.trim().to_string();
            let name = site.name.trim().to_string();
            if api.is_empty() && name.is_empty() {
                continue;
            }
            let base_url = http_origin(&api).unwrap_or_default();
            sites.push(TvboxSite {
                key: site.key,
                likely_alist: looks_like_alist(&api, &name),
                name,
                site_type: site.r#type,
                base_url,
                api,
            });
        }
    }

    // 探测配置地址本身是否为 Alist/OpenList 服务器（直接粘贴网盘地址）。
    let probe_base = http_origin(&url).unwrap_or_else(|| url.trim_end_matches('/').to_string());
    let root_is_alist = probe_alist(&client, &probe_base).await;

    if sites.is_empty() && !root_is_alist {
        return Err(
            "该地址不是 TVBox 接口（未找到 sites 站点列表），也不是 Alist/OpenList 服务器".to_string(),
        );
    }

    Ok(TvboxSubscription {
        sites,
        root_is_alist,
        root_url: probe_base,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn looks_like_alist_detects_fs_api_and_names() {
        assert!(looks_like_alist(
            "https://x.example.com/api/fs/list",
            "随便"
        ));
        assert!(looks_like_alist("csp_Site", "OpenList 资源"));
        assert!(looks_like_alist("csp_Site", "夸克网盘"));
        assert!(!looks_like_alist("csp_Kuaikan", "快看影视"));
    }

    #[test]
    fn http_origin_extracts_site_root() {
        assert_eq!(
            http_origin("https://a.example.com/api/fs/list"),
            Some("https://a.example.com".to_string())
        );
        assert_eq!(http_origin("csp_Site"), None);
    }

    #[test]
    fn normalize_config_url_adds_scheme() {
        assert_eq!(
            normalize_config_url("alist.example.com"),
            "https://alist.example.com"
        );
        assert_eq!(
            normalize_config_url("http://a.b.com/config.json"),
            "http://a.b.com/config.json"
        );
    }

    #[test]
    fn parses_tvbox_sites_json() {
        let config: TvboxConfig = serde_json::from_str(
            r#"{"sites":[
                {"key":"csp_1","name":"快看","type":3,"api":"csp_Kuaikan"},
                {"key":"al","name":"Alist","type":0,"api":"https://pan.example.com/api/fs/list"}
            ]}"#,
        )
        .expect("parse config");
        assert_eq!(config.sites.len(), 2);
        assert_eq!(config.sites[1].api, "https://pan.example.com/api/fs/list");
    }
}
