// @baka-provider 2
"use strict";
/**
 * JOOX 音源（baka V2 provider）
 * - 搜索：openjoox v2 公开接口（明文 JSON，无鉴权），首屏不可翻页
 * - 曲目详情：openjoox2 v1（MD5(salt+query) 签名，盐 Jo0x@t3Nc3nT），
 *   换取 songmid 与音质元数据（has_hq → 320k，has_hifi → flac）
 * - 取流：惜梦 CIT 网关 jo 通道（HMAC-SHA256 签名，与 lx-cit 脚本一致）
 * - 歌词：开放接口不提供，宿主按无歌词降级
 */
const JOOX_HOST = "https://cache.api.joox.com";
const JOOX_SALT = "Jo0x@t3Nc3nT";
const JOOX_COUNTRY = "hk";
const JOOX_LANG = "zh_cn";
const JOOX_UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36";

// 取流通道（与 lx-cit 1.5.4 脚本同一鉴权体系，密钥为用户自有）
const CIT_URL = "https://anime.xisb.cn/anime/cit/index.php/music/url";
const CIT_KEY = "cit_kWrYpvJfeHd5Mgdpb57u4rq9v";
const CIT_SECRET =
  "c4fdbe2e720d284ed9b0c1095eaeb80f74f85019a266fee0099287c90b3a902c";
const CIT_VER = "1.5.4";

const DETAIL_CACHE_MAX = 800;
const detailCache = new Map(); // trackId -> { songmid, hasHq, hasHifi }

function num(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback || 0;
}

/** UTF-8 字符串 → hex（sdk.crypto 系列接口均以 hex 入参） */
function utf8Hex(text) {
  const s = String(text == null ? "" : text);
  const out = [];
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 0x80) {
      out.push(c);
    } else if (c < 0x800) {
      out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    } else {
      out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
  }
  return out.map(function (b) {
    return (b < 16 ? "0" : "") + b.toString(16);
  }).join("");
}

/** UTF-8 表单编码（与安卓 URLEncoder 对齐：空格→+） */
function formEncode(text) {
  return encodeURIComponent(String(text == null ? "" : text))
    .replace(/%20/g, "+")
    .replace(/!/g, "%21")
    .replace(/'/g, "%27")
    .replace(/\(/g, "%28")
    .replace(/\)/g, "%29")
    .replace(/~/g, "%7E");
}

function jooxHeaders() {
  return {
    "User-Agent": JOOX_UA,
    Accept: "application/json, text/plain, */*",
    Origin: "https://www.joox.com",
    Referer: "https://www.joox.com/",
  };
}

/** tracks 数组可能嵌套一层，展开一层保留对象与原始顺序 */
function flattenRows(rows) {
  const out = [];
  const arr = Array.isArray(rows) ? rows : [];
  for (const node of arr) {
    if (Array.isArray(node)) {
      for (const item of node) if (item && typeof item === "object") out.push(item);
    } else if (node && typeof node === "object") {
      out.push(node);
    }
  }
  return out;
}

/** 取分辨率最高的有效封面 */
function bestImage(images) {
  let best = "";
  let bestW = -1;
  for (const img of Array.isArray(images) ? images : []) {
    const url = String(img && img.url || "");
    const w = num(img && img.width, 0);
    if (url && w >= bestW) {
      best = url;
      bestW = w;
    }
  }
  return best;
}

async function fetchTrackDetail(sdk, trackId) {
  if (!trackId) return null;
  const cached = detailCache.get(trackId);
  if (cached) return cached;
  const query =
    `country=${JOOX_COUNTRY}&lang=${JOOX_LANG}&lyric=0&fs=0&im=1&id=` +
    formEncode(trackId);
  // crypto-js MD5：签名为 MD5(salt + query) 小写十六进制，摘要不含
  // 路径、问号与 secret 本身（sdk.crypto.hash 以 hex 入参）
  const secret = sdk.crypto.hash("md5", utf8Hex(JOOX_SALT + query));
  const url =
    `${JOOX_HOST}/openjoox2/v1/track/${trackId}?${query}&secret=${secret}`;
  const response = await sdk.http.request({
    url: url,
    method: "GET",
    headers: jooxHeaders(),
    timeoutMs: 20000,
    responseType: "json",
  });
  const body = response && response.body;
  // error_code 9009002（不可播放）仍可能携带有效元数据，只看 songmid
  if (!body || typeof body !== "object" || !body.songmid) return null;
  const detail = {
    songmid: String(body.songmid),
    hasHq: num(body.has_hq, 0) === 1,
    hasHifi: num(body.has_hifi, 0) === 1,
  };
  if (detailCache.size >= DETAIL_CACHE_MAX) {
    detailCache.delete(detailCache.keys().next().value);
  }
  detailCache.set(trackId, detail);
  return detail;
}

function toMusic(track, detail) {
  const songId = (detail && detail.songmid) || String(track.id || "");
  const qualities = ["128k"];
  if (detail && detail.hasHq) qualities.push("320k");
  if (detail && detail.hasHifi) qualities.push("flac");
  const artist = (Array.isArray(track.artist_list) ? track.artist_list : [])
    .filter(function (a) { return a && a.name; })
    .map(function (a) { return String(a.name); })
    .join("/");
  return {
    id: songId,
    type: "music",
    title: String(track.name || ""),
    name: String(track.name || ""),
    artist: artist,
    album: String(track.album_name || ""),
    artwork: bestImage(track.images),
    duration: num(track.play_duration, 0),
    source: "jo",
    platform: "jo",
    qualities: qualities,
  };
}

/** 分批并发补查详情（每批 8 个，避免上游限流） */
async function resolveDetails(sdk, tracks, limit) {
  const picked = tracks.slice(0, Math.min(100, Math.max(1, limit)));
  const out = [];
  for (let i = 0; i < picked.length; i += 8) {
    const batch = picked.slice(i, i + 8);
    const details = await Promise.all(
      batch.map(function (t) {
        return fetchTrackDetail(sdk, String(t.id || "")).catch(function () {
          return null;
        });
      }),
    );
    for (let j = 0; j < batch.length; j++) {
      // 过滤空 ID / 空歌名；详情失败保留列表条目（id 退回搜索令牌）
      if (batch[j] && batch[j].id && batch[j].name) {
        out.push(toMusic(batch[j], details[j]));
      }
    }
  }
  // 按最终 ID 去重（songmid 转换后可能撞车），保留首次出现
  const seen = new Set();
  return out.filter(function (item) {
    if (seen.has(item.id)) return false;
    seen.add(item.id);
    return true;
  });
}

const handlers = {
  // JOOX 首屏不可翻页（上游 page/offset 重叠且顺序不稳），恒 nextCursor:null
  async search(request, sdk) {
    const q = String((request && request.query) || "").trim();
    if (!q) return { items: [], nextCursor: null };
    const limit = Math.min(100, Math.max(1, num(request && request.limit, 30)));
    const response = await sdk.http.request({
      url:
        `${JOOX_HOST}/openjoox/v2/search_type?country=${JOOX_COUNTRY}` +
        `&lang=${JOOX_LANG}&key=${formEncode(q)}&type=0`,
      method: "GET",
      headers: jooxHeaders(),
      timeoutMs: 20000,
      responseType: "json",
    });
    const body = response && response.body;
    if (!body || typeof body !== "object" || num(body.error_code, 0) !== 0) {
      return { items: [], nextCursor: null };
    }
    const tracks = flattenRows(body.tracks).filter(function (t) {
      return t && t.id && t.name;
    });
    const items = await resolveDetails(sdk, tracks, limit);
    return { items: items.slice(0, limit), nextCursor: null };
  },

  async "media.resolve"(request, sdk) {
    const e = (request && request.entity) || {};
    if (!e.id) return null;
    const q = String((request && request.quality) || "128k");
    const songId = String(e.id);
    const ts = String(Math.floor(Date.now() / 1000));
    const nonce = sdk.crypto.randomBytes(8); // 16 hex chars，与 lx-cit 一致
    const sign = sdk.crypto.hmacSha256(
      CIT_SECRET,
      utf8Hex(`${ts}|${nonce}|${songId}|${q}`),
    );
    const url =
      `${CIT_URL}?key=${formEncode(CIT_KEY)}&ver=${formEncode(CIT_VER)}` +
      `&ts=${ts}&nonce=${nonce}&sign=${sign}`;
    const response = await sdk.http.request({
      url: url,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "User-Agent": "lx-music-mobile/1.0.0",
        "X-Api-Key": CIT_KEY,
      },
      body: JSON.stringify({
        source: "jo",
        musicId: songId,
        quality: q,
        name: String(e.title || e.name || ""),
        singer: String(e.artist || ""),
      }),
      timeoutMs: 20000,
      responseType: "json",
    });
    const body = response && response.body;
    if (!body || isNaN(Number(body.code))) return null;
    if (Number(body.code) !== 200 || !body.url) return null;
    const u = String(body.url);
    const mimeType = /\.(flac)$/i.test(u) ? "audio/flac"
      : /\.(m4a|aac)$/i.test(u) ? "audio/mp4"
      : /\.(ogg)$/i.test(u) ? "audio/ogg"
      : "audio/mpeg";
    return { url: u, quality: String(body.quality || q), mimeType: mimeType };
  },
};

module.exports = {
  manifest: {
    apiVersion: 2,
    kind: "provider",
    id: "cn.xymusic.joox",
    sourceId: "joox.open",
    name: "JOOX 音源",
    author: "XY Music",
    version: "1.0.0",
    description: "JOOX 曲库搜索与取流（openjoox 开放接口 + CIT 取流通道）",
    capabilities: ["search", "media.resolve"],
    supportedSearchType: ["music"],
    supportedQualities: ["128k", "320k", "flac"],
  },
  handlers: handlers,
};
