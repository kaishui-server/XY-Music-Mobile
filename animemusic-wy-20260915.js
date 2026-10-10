"use strict";
/*!
 * animemusic 插件 · 自有格式 animemusic/1
 * 能力：搜索歌曲 / 播放链接 / 逐行歌词 / 逐字歌词 / MV 搜索 / MV 直链
 * 规范见 /animemusic/FORMAT.md —— 宿主只需调用 plugin.call(action, params)
 * 本文件由分发端点实时生成；零第三方依赖（仅用 Node 内置模块）
 */

const http = require("http");
const https = require("https");
const zlib = require("zlib");

const META = {"format":"animemusic/1","name":"animemusic·网易","platform":"wy","platforms":["wy"],"label":"网易","version":"1.0.0","author":"animemusic","date":"2026-09-15","api":"http://198.44.179.129/v1/index.php","update":"http://198.44.179.129/animemusic/wy/index.php","capabilities":["info","search","musicUrl","lyric","lyricWord","lyricBoth","mvSearch","mvUrl"],"qualities":["128k","192k","320k","flac","flac24bit"],"videoQualities":["240p","360p","480p","720p","1080p"],"lyricBridge":[],"lyricNative":true,"notes":""};
const MV_QUALITY = {"kg":{},"kw":{"1080p":"MP4BD","720p":"MP4UL","480p":"MP4HV","360p":"MV700","240p":"MP4L"},"wy":{"1080p":"1080","720p":"720","480p":"480","240p":"240"},"tx":{"1080p":"1080","720p":"720","480p":"480"},"mg":{},"bilibili":{"1080p":"80","720p":"64","480p":"32","360p":"16","240p":"16"}};
const VERSION = "1.0.0";
const UPDATE_URL = "http://198.44.179.129/animemusic/wy/index.php";

const DEFAULTS = {
  api: "http://198.44.179.129/v1/index.php",        // 接口地址（可被 configure 覆盖）
  timeout: 12000,           // 单次请求超时（毫秒）
  quality: "320k",          // 默认音质
  videoQuality: "1080p",    // 默认画质
  lyricFallback: true,      // 逐字歌词失败时自动回退逐行
  crossPlatformLyric: true, // 无歌词平台（如B站）允许跨平台取词
};

let cfg = Object.assign({}, DEFAULTS);
let routeStyle = ""; // 自适应路由记忆：""=未探测  "path"=PATH_INFO  "query"=?route=

/* ============================================================
 * ① 基础：错误 / 请求 / 路由自适应
 * ========================================================== */

function amError(code, message, detail) {
  const e = new Error(message);
  e.code = code;
  if (detail !== undefined) e.detail = detail;
  return e;
}

function apiBase() {
  let s = String(cfg.api || DEFAULTS.api).trim();
  s = s.replace(/\/index\.php(\?.*)?$/i, "").replace(/\/+$/, "");
  return s;
}

function qs(params) {
  const parts = [];
  Object.keys(params || {}).forEach(function (k) {
    const v = params[k];
    if (v === undefined || v === null || v === "") return;
    parts.push(encodeURIComponent(k) + "=" + encodeURIComponent(String(v)));
  });
  return parts.length ? "?" + parts.join("&") : "";
}

/** 原始 HTTP 请求（自带 gzip/deflate 解压、重定向跟随、超时保护） */
function requestRaw(url, options) {
  options = options || {};
  const depth = Number(options._redirect) || 0;
  return new Promise(function (resolve, reject) {
    let u;
    try { u = new URL(url); } catch (e) { return reject(amError("E_URL", "接口地址无效：" + url)); }
    const mod = u.protocol === "https:" ? https : http;
    const req = mod.request({
      protocol: u.protocol,
      hostname: u.hostname,
      port: u.port || (u.protocol === "https:" ? 443 : 80),
      path: u.pathname + (u.search || ""),
      method: (options.method || "GET").toUpperCase(),
      headers: Object.assign({
        "Accept": "application/json, text/plain, */*",
        "Accept-Encoding": "gzip",
        "User-Agent": "animemusic-plugin/" + VERSION,
      }, options.headers || {}),
    }, function (res) {
      let stream = res;
      const enc = String(res.headers["content-encoding"] || "").toLowerCase();
      if (enc.indexOf("gzip") !== -1) stream = res.pipe(zlib.createGunzip());
      const chunks = [];
      stream.on("data", function (c) { chunks.push(Buffer.isBuffer(c) ? c : Buffer.from(String(c))); });
      stream.on("error", reject);
      stream.on("end", function () {
        const status = res.statusCode || 0;
        if (status >= 300 && status < 400 && res.headers.location && depth < 5) {
          let next;
          try { next = new URL(res.headers.location, url).toString(); }
          catch (e) { next = res.headers.location; }
          resolve(requestRaw(next, Object.assign({}, options, { _redirect: depth + 1 })));
          return;
        }
        resolve({ status: status, body: Buffer.concat(chunks).toString("utf8") });
      });
    });
    const ms = Number(cfg.timeout) || DEFAULTS.timeout;
    req.setTimeout(ms, function () { req.destroy(amError("E_TIMEOUT", "请求超时（" + ms + "ms）")); });
    req.on("error", function (e) {
      reject(e && e.code && e.message ? e : amError("E_NET", "网络错误：" + (e && e.message ? e.message : e)));
    });
    if (options.body) req.write(options.body);
    req.end();
  });
}

async function fetchJson(url, options) {
  const r = await requestRaw(url, options);
  const txt = String(r.body || "").trim();
  let body = null;
  try { body = txt ? JSON.parse(txt) : null; } catch (e) { body = null; }
  if (!body || typeof body !== "object") {
    throw amError("E_BADRESP", "接口返回异常（HTTP " + r.status + "）", txt.slice(0, 160));
  }
  return body;
}

/**
 * 调用后端接口：自动适配两种路由风格并记住可用者
 *   ① PATH_INFO : {api}/music/search?...
 *   ② 查询串参数 : {api}/index.php?route=music/search&...
 * （不同服务器环境二选一，插件首次调用自动探测，避免部署差异导致不可用）
 */
async function apiCall(path, params) {
  const p = String(path).replace(/^\/+/, "");
  const tries = routeStyle === "query" ? ["query", "path"] : ["path", "query"];
  let lastErr = null;
  for (let i = 0; i < tries.length; i++) {
    const style = tries[i];
    const url = style === "path"
      ? apiBase() + "/" + p + qs(params)
      : apiBase() + "/index.php" + qs(Object.assign({ route: p }, params || {}));
    try {
      const body = await fetchJson(url);
      if (Number(body.code) !== 200) {
        const e = amError("E_API_" + (body.code || 0), body.message || "接口返回失败");
        if (Number(body.code) === 404) { lastErr = e; continue; } // 路由风格不对 → 换另一种重试
        throw e;
      }
      routeStyle = style;
      return body;
    } catch (e) {
      // 已确认过可用风格 / 超时 → 不再换风格重试，直接抛出（避免业务失败被重复请求）
      if (e && e.code === "E_TIMEOUT") throw e;
      if (routeStyle !== "") throw e;
      lastErr = e;
    }
  }
  throw lastErr || amError("E_UNKNOWN", "接口调用失败");
}

/* ============================================================
 * ② 参数与文本工具
 * ========================================================== */

const ALIAS = {
  kugou: "kg", kuwo: "kw", netease: "wy", qq: "tx", qqmusic: "tx",
  migu: "mg", bili: "bilibili", "b站": "bilibili", 网易: "wy", 酷狗: "kg",
  "酷我": "kw", "咪咕": "mg", 聚合: "all",
};

function resolvePlatform(input) {
  const s = String(input === undefined || input === null ? "" : input).toLowerCase().trim();
  if (!s) return META.platform;
  return ALIAS[s] || s;
}

function needPlatform(input) {
  const pf = resolvePlatform(input);
  if (!pf || pf === "all") {
    throw amError("E_PLATFORM", "请指定 platform 参数（可选：" + (META.platforms || []).join("/") + "）");
  }
  return pf;
}

function normalizeQuality(q) {
  const s = String(q || "").toLowerCase().trim();
  if (!s) return cfg.quality || DEFAULTS.quality;
  if (["hires", "master", "atmos", "24bit", "hifi", "flac24bit"].indexOf(s) !== -1) return "flac24bit";
  return META.qualities.indexOf(s) !== -1 ? s : "320k";
}

function clampLimit(v, def) {
  const n = Number(v) || def;
  return Math.min(30, Math.max(1, n));
}

/** 归一化文本用于相似度比较 */
function normText(s) {
  return String(s || "").toLowerCase().replace(/[\s\-_·、，,。.！!？?（）()\[\]【】"'’“”：:;；~—]+/g, "");
}

/** 标题相似度 0~1（用于跨平台取词时挑最像的一条） */
function titleScore(a, b) {
  const x = normText(a), y = normText(b);
  if (!x || !y) return 0;
  if (x === y) return 1;
  if (x.indexOf(y) !== -1 || y.indexOf(x) !== -1) return 0.85;
  const set = {};
  for (let i = 0; i < y.length; i++) set[y[i]] = 1;
  let hit = 0;
  for (let i = 0; i < x.length; i++) if (set[x[i]]) hit++;
  return (hit / Math.max(x.length, 1)) * 0.7;
}

function mapSong(it, platform) {
  return {
    id: String(it && it.id !== undefined && it.id !== null ? it.id : ""),
    title: String((it && it.title) || ""),
    artist: String((it && it.artist) || ""),
    album: String((it && it.album) || ""),
    artwork: String((it && it.artwork) || ""),
    duration: Number((it && it.duration) || 0),
    platform: platform,
    extra: {
      albumAudioId: String((it && it.album_audio_id) || ""),
      songId: String((it && it.songId) || ""),
    },
  };
}

function mapMv(it, platform) {
  return {
    id: String((it && it.id) || ""),
    title: String((it && it.title) || ""),
    artist: String((it && it.artist) || ""),
    artwork: String((it && it.artwork) || ""),
    duration: Number((it && it.duration) || 0),
    playCount: Number((it && it.playCount) || 0),
    platform: platform,
  };
}

function okEnvelope(action, platform, extra) {
  return Object.assign({ ok: true, action: action, platform: platform }, extra || {});
}

/** 统一异常包裹：任何动作都只返回信封，不向外抛错 */
function guard(action, fn) {
  return async function () {
    const args = Array.prototype.slice.call(arguments);
    try {
      return await fn.apply(null, args);
    } catch (e) {
      return {
        ok: false,
        action: action,
        error: {
          code: (e && e.code) || "E_UNKNOWN",
          message: (e && e.message) || String(e),
          detail: (e && e.detail) || undefined,
        },
      };
    }
  };
}

/* ============================================================
 * ③ 能力实现
 * ========================================================== */

/** 逐行歌词（原始，失败抛错） */
async function lyricRaw(platform, musicId, options) {
  const o = options || {};
  const body = await apiCall("/music/lyric", {
    platform: platform,
    musicId: musicId,
    name: o.title || o.name || "",
    interval: o.interval || 200,
  });
  return {
    platform: platform,
    id: String(musicId),
    format: body.format || "lrc",
    lrc: body.lyric || "",
    translation: body.tlyric || "",
    romanization: body.rlyric || "",
    word: false,
    fallback: false,
  };
}

/** 逐字歌词（原始，失败抛错）；平台无逐字源时返回逐行并标记 fallback */
async function lyricWordRaw(platform, musicId, options) {
  const o = options || {};
  const body = await apiCall("/music/lyric/word", {
    platform: platform,
    musicId: musicId,
    name: o.title || o.name || "",
    interval: o.interval || 200,
  });
  const format = body.format || "lrc";
  return {
    platform: platform,
    id: String(musicId),
    format: format,
    lrc: body.lyric || "",
    translation: body.tlyric || "",
    romanization: body.rlyric || "",
    word: format === "lrc-a2",
    fallback: format !== "lrc-a2",
  };
}

/** 跨平台取词：本平台没有歌词源时，去桥接平台搜同名曲目再取词 */
async function bridgeLyric(options, wantWord) {
  const o = options || {};
  const targets = (META.lyricBridge && META.lyricBridge.length) ? META.lyricBridge : ["kw", "wy"];
  const title = o.title || o.name || "";
  const artist = o.artist || "";
  const keyword = String(o.keyword || [title, artist].filter(Boolean).join(" ")).trim();
  if (!keyword) throw amError("E_PARAM", "跨平台取词需要提供 title / artist / keyword");

  let best = null;
  for (let i = 0; i < targets.length; i++) {
    const pf = targets[i];
    let body;
    try {
      body = await apiCall("/music/search", { platform: pf, keyword: keyword, page: 1, limit: 10 });
    } catch (e) { continue; }
    const list = Array.isArray(body.data) ? body.data : [];
    for (let j = 0; j < list.length; j++) {
      const score = titleScore(title, list[j].title);
      if (!best || score > best.score) best = { score: score, item: list[j], platform: pf };
    }
    if (best && best.score >= 0.95) break;
  }
  if (!best || best.score < 0.5) throw amError("E_LYRIC", "未找到可用的跨平台歌词源");

  const sub = { platform: best.platform, musicId: String(best.item.id), name: best.item.title };
  const r = wantWord
    ? await lyricWordRaw(sub.platform, sub.musicId, sub)
    : await lyricRaw(sub.platform, sub.musicId, sub);
  return Object.assign(r, {
    bridged: true,
    from: best.platform,
    matched: {
      id: String(best.item.id),
      title: best.item.title || "",
      artist: best.item.artist || "",
      score: Number(best.score.toFixed(2)),
    },
  });
}

/* ---------------- 搜索 ---------------- */

async function searchOne(keyword, options) {
  const o = options || {};
  const platform = needPlatform(o.platform);
  const kw = String(keyword || "").trim();
  const page = Math.max(1, Number(o.page) || 1);
  const limit = clampLimit(o.limit, 30);
  if (!kw) return okEnvelope("search", platform, { keyword: "", page: page, list: [], hasMore: false });
  const body = await apiCall("/music/search", { platform: platform, keyword: kw, page: page, limit: limit });
  const list = (Array.isArray(body.data) ? body.data : []).map(function (it) { return mapSong(it, platform); });
  return okEnvelope("search", platform, {
    keyword: kw, page: page, limit: limit, list: list, hasMore: list.length >= limit && !body.isEnd,
  });
}

/** 全平台并发搜索：结果按平台交错合并（聚合插件用） */
async function searchAll(keyword, options) {
  const o = options || {};
  const kw = String(keyword || "").trim();
  const page = Math.max(1, Number(o.page) || 1);
  const limit = clampLimit(o.limit, 10);
  const platforms = META.platforms || [];
  if (!kw) return okEnvelope("searchAll", "all", { keyword: "", page: page, groups: [], list: [], hasMore: false });

  const settled = await Promise.all(platforms.map(function (pf) {
    return searchOne(kw, { platform: pf, page: page, limit: limit })
      .then(function (r) { return { platform: pf, list: (r && r.list) || [], ok: !!(r && r.ok) }; })
      .catch(function () { return { platform: pf, list: [], ok: false }; });
  }));

  const groups = settled.map(function (g) { return { platform: g.platform, count: g.list.length, list: g.list }; });
  // 交错合并：每个平台轮流取一条，避免单一平台霸屏
  const merged = [];
  const seen = {};
  let idx = 0, added = true;
  while (added) {
    added = false;
    for (let i = 0; i < settled.length; i++) {
      const item = settled[i].list[idx];
      if (!item) continue;
      added = true;
      const key = item.platform + "|" + item.id;
      if (!seen[key]) { seen[key] = 1; merged.push(item); }
    }
    idx++;
  }
  return okEnvelope("searchAll", "all", {
    keyword: kw, page: page, groups: groups, list: merged,
    hasMore: settled.some(function (g) { return g.list.length >= limit; }),
  });
}

/* ---------------- 歌词 ---------------- */

async function lyricInner(id, options) {
  const o = options || {};
  const platform = resolvePlatform(o.platform);
  const musicId = String(id === undefined || id === null ? (o.id || "") : id).trim();
  if (!musicId) return { ok: false, action: "lyric", error: { code: "E_PARAM", message: "缺少歌曲 id" } };

  if (platform === "all") return { ok: false, action: "lyric", error: { code: "E_PLATFORM", message: "聚合模式请指定 platform" } };
  if (!META.lyricNative && cfg.crossPlatformLyric !== false) {
    const r = await bridgeLyric(Object.assign({}, o, { id: musicId }), false);
    return okEnvelope("lyric", platform, r);
  }
  const r = await lyricRaw(platform, musicId, o);
  return okEnvelope("lyric", platform, r);
}

async function lyricWordInner(id, options) {
  const o = options || {};
  const platform = resolvePlatform(o.platform);
  const musicId = String(id === undefined || id === null ? (o.id || "") : id).trim();
  if (!musicId) return { ok: false, action: "lyricWord", error: { code: "E_PARAM", message: "缺少歌曲 id" } };

  if (platform === "all") return { ok: false, action: "lyricWord", error: { code: "E_PLATFORM", message: "聚合模式请指定 platform" } };
  if (!META.lyricNative && cfg.crossPlatformLyric !== false) {
    const r = await bridgeLyric(Object.assign({}, o, { id: musicId }), true);
    return okEnvelope("lyricWord", platform, r);
  }
  if (cfg.lyricFallback === false) {
    const r = await lyricWordRaw(platform, musicId, o);
    return okEnvelope("lyricWord", platform, r);
  }
  // 逐字失败（含平台无逐字源）→ 自动回退逐行
  try {
    const w = await lyricWordRaw(platform, musicId, o);
    if (w.lrc) return okEnvelope("lyricWord", platform, w);
    throw amError("E_LYRIC", "逐字歌词为空");
  } catch (e) {
    const l = await lyricRaw(platform, musicId, o);
    l.fallback = true;
    l.fallbackReason = (e && e.message) || "逐字歌词不可用";
    return okEnvelope("lyricWord", platform, l);
  }
}

/** 一次拿齐：逐行 + 逐字（宿主需要双份时用，内部并发） */
async function lyricBothInner(id, options) {
  const o = options || {};
  const platform = resolvePlatform(o.platform);
  if (platform === "all") return { ok: false, action: "lyricBoth", error: { code: "E_PLATFORM", message: "聚合模式请指定 platform" } };
  const [line, word] = await Promise.all([
    lyricInner(id, o),
    lyricWordInner(id, o),
  ]);
  return okEnvelope("lyricBoth", platform, {
    id: String(id === undefined || id === null ? (o.id || "") : id),
    line: line,
    word: word,
  });
}

/* ---------------- 播放链接 ---------------- */

async function musicUrlInner(id, options) {
  const o = options || {};
  const platform = needPlatform(o.platform);
  const musicId = String(id === undefined || id === null ? (o.id || "") : id).trim();
  if (!musicId) return { ok: false, action: "musicUrl", error: { code: "E_PARAM", message: "缺少歌曲 id" } };
  const quality = normalizeQuality(o.quality);
  const body = await apiCall("/music/url", { source: platform, musicId: musicId, quality: quality });
  return okEnvelope("musicUrl", platform, {
    id: musicId,
    quality: quality,
    url: String(body.url || ""),
    videoUrl: String(body.video_url || ""),   // B站等平台可能同时给视频轨
  });
}

/* ---------------- MV ---------------- */

async function mvSearchInner(keyword, options) {
  const o = options || {};
  const platform = needPlatform(o.platform);
  const kw = String(keyword || "").trim();
  const page = Math.max(1, Number(o.page) || 1);
  const limit = clampLimit(o.limit, 20);
  if (!kw) return okEnvelope("mvSearch", platform, { keyword: "", page: page, list: [], hasMore: false });
  const body = await apiCall("/music/mv/search", { platform: platform, keyword: kw, page: page, limit: limit });
  const list = (Array.isArray(body.data) ? body.data : []).map(function (it) { return mapMv(it, platform); });
  return okEnvelope("mvSearch", platform, {
    keyword: kw, page: page, limit: limit, list: list, hasMore: !body.isEnd,
  });
}

async function mvUrlInner(id, options) {
  const o = options || {};
  const platform = needPlatform(o.platform);
  const mvId = String(id === undefined || id === null ? (o.id || "") : id).trim();
  if (!mvId) return { ok: false, action: "mvUrl", error: { code: "E_PARAM", message: "缺少 MV id" } };
  const want = String(o.videoQuality || o.quality || cfg.videoQuality || DEFAULTS.videoQuality);
  const map = MV_QUALITY[platform] || {};
  const upstreamQ = map[want] !== undefined ? map[want] : "";
  const body = await apiCall("/music/mv/url", { platform: platform, id: mvId, quality: upstreamQ });
  return okEnvelope("mvUrl", platform, {
    id: mvId,
    videoQuality: want,
    quality: body.quality || upstreamQ || "",
    bitrate: Number(body.bitrate || 0),
    url: String(body.url || ""),
  });
}

/* ============================================================
 * ④ 插件对象（对外唯一契约）
 * ========================================================== */

const plugin = {
  format: META.format,
  meta: META,
  defaults: DEFAULTS,

  /** 运行时配置：plugin.configure({ api: "http://x/v1/index.php", quality: "flac" }) */
  configure: function (options) {
    if (options && typeof options === "object") {
      Object.keys(options).forEach(function (k) {
        if (options[k] !== undefined && options[k] !== null) cfg[k] = options[k];
      });
      routeStyle = ""; // 地址变了，重新探测路由
    }
    return plugin;
  },

  /** 当前生效配置（不含内部字段） */
  config: function () { return Object.assign({}, cfg); },

  search: guard("search", function (keyword, options) {
    const o = options || {};
    const platform = resolvePlatform(o.platform);
    if (platform === "all") return searchAll(keyword, o);
    return searchOne(keyword, Object.assign({}, o, { platform: platform }));
  }),

  searchAll: guard("searchAll", searchAll),
  musicUrl: guard("musicUrl", musicUrlInner),
  lyric: guard("lyric", lyricInner),
  lyricWord: guard("lyricWord", lyricWordInner),
  lyricBoth: guard("lyricBoth", lyricBothInner),
  mvSearch: guard("mvSearch", function (keyword, options) {
    const o = options || {};
    const platform = resolvePlatform(o.platform);
    if (platform === "all") {
      const kw = String(keyword || "").trim();
      const limit = clampLimit(o.limit, 10);
      return Promise.all((META.platforms || []).map(function (pf) {
        return mvSearchInner(kw, Object.assign({}, o, { platform: pf, limit: limit }))
          .then(function (r) { return { platform: pf, list: (r && r.list) || [] }; })
          .catch(function () { return { platform: pf, list: [] }; });
      })).then(function (groups) {
        const merged = [], seen = {};
        let idx = 0, added = true;
        while (added) {
          added = false;
          for (let i = 0; i < groups.length; i++) {
            const item = groups[i].list[idx];
            if (!item) continue;
            added = true;
            const key = item.platform + "|" + item.id;
            if (!seen[key]) { seen[key] = 1; merged.push(item); }
          }
          idx++;
        }
        return okEnvelope("mvSearch", "all", { keyword: kw, groups: groups, list: merged, hasMore: false });
      });
    }
    return mvSearchInner(keyword, Object.assign({}, o, { platform: platform }));
  }),
  mvUrl: guard("mvUrl", mvUrlInner),

  /** 元信息 / 能力自述 */
  info: guard("info", async function () {
    return okEnvelope("info", META.platform, {
      meta: META,
      defaults: Object.assign({}, DEFAULTS),
      config: Object.assign({}, cfg),
      routeStyle: routeStyle || "(未探测)",
      update: UPDATE_URL,
    });
  }),

  /** 统一入口：宿主只需实现这一个 */
  call: async function (action, params) {
    const a = String(action || "").trim();
    const p = params || {};
    switch (a) {
      case "info":       return plugin.info();
      case "search":     return plugin.search(p.keyword, p);
      case "searchAll":  return plugin.searchAll(p.keyword, p);
      case "musicUrl":   return plugin.musicUrl(p.id, p);
      case "lyric":      return plugin.lyric(p.id, p);
      case "lyricWord":  return plugin.lyricWord(p.id, p);
      case "lyricBoth":  return plugin.lyricBoth(p.id, p);
      case "mvSearch":   return plugin.mvSearch(p.keyword, p);
      case "mvUrl":      return plugin.mvUrl(p.id, p);
      default:
        return { ok: false, action: a, error: { code: "E_ACTION", message: "不支持的动作：" + a, supported: META.capabilities } };
    }
  },
};

module.exports = plugin;
module.exports.default = plugin;
module.exports.animemusic = plugin;