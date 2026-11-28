// BakaMusic provider apiVersion 2 适配层（严格契约版）。
//
// v2 契约（对齐 mc.vsaa.cn 订阅源 2026-11 系列插件）：
//   module.exports = { manifest, handlers }
//   handlers 树（全部为 (request, sdk) => Promise<result>）：
//     search / entities.get / collections.{get,members}
//     discovery.{charts,chartTags,playlistTags,playlists,hotSearch,daily,...}
//     media.{resolve,video} / lyrics.get / comments.list / links.{resolve,share}
//   request 字段：{ query, kind, entity, tag, context, sort, limit, cursor, url, quality }
//   列表结果：{ items, nextCursor?, total?, entity? }；nextCursor 为
//   JSON({key,offset})，key 由 sdk.crypto.hash 对请求语义摘要算出，翻页时
//   必须带着上次返回的 cursor 且请求语义（query/kind/entity/limit/变量）
//   完全一致，否则插件抛「Cursor does not match request」。
//
//   sdk 桥：
//     http.request({url,method,headers,body,bodyHex,timeoutMs,responseType})
//       → { status, body, headers }；responseType 'json'|'text'|'bytes'，
//       'bytes' 时 body 为响应字节的 hex 字符串；bodyHex 为请求字节 hex。
//     bytes.encode(v,'utf8'|'base64') → hex；bytes.decode(hex,'utf8'|'base64') → 字符串；
//     bytes.decompress(hex,'zlib') → hex。
//     text.decodeHtml(str)；crypto.hash('md5'|'sha1'|'sha256', hexIn) → hex；
//     crypto.hmacSha256(keyHex, dataHex) → hex；
//     crypto.aesEncrypt|aesDecrypt({mode:'ecb'|'cbc',keyHex,ivHex?,dataHex,padding}) → hex；
//     crypto.randomBytes(n) → hex；settings.userVariables；storage.get/set（异步）。
//
// 门面：按 manifest.capabilities 生成 MusicFree 形状对象并注册进
// __xyLoadMusicFreePlugin 注册表，宿主既有调用链（搜索/详情/榜单/播放/歌词/
// 评论/MV/每日30首/歌单导入）无需感知 v2 契约。分页由本层维护游标链：
// 宿主按页码调用时回放缓存游标，缓存缺失（运行时重建）时逐页重放补齐。

(function () {
  'use strict';

  var ADAPTER_VERSION = '2.0.0';
  var LIST_PAGE_SIZE = 30; // 列表类（搜索/榜单详情/歌单/评论）统一页大小
  var SMALL_PAGE_SIZE = 100; // 全量小列表（榜单目录）单页大小
  var MAX_REPLAY_PAGES = 50; // 游标缓存丢失时的重放上限
  var MAX_IMPORT_PAGES = 50; // importMusicSheet 整单导入页数上限

  var states = new Map(); // pluginId -> state

  // ---------------------------------------------------------------------------
  // URL / URLSearchParams 最小 polyfill：QuickJS 不带 WHATWG URL，部分
  // v2 插件（如惜梦 CIT v2）用 `new URL(api)` + `url.search = qs` 组装
  // 请求。仅覆盖绝对 URL 解析与 search/searchParams 读写，与插件常规
  // 用法对齐；宿主原生环境（fetch/XHR 桥）不受影响。
  // ---------------------------------------------------------------------------
  // 变动通知钩子绑定：URL 实例把 searchParams 的修改写回自身 search
  //（注意保留 WHATWG search 的 '?' 前缀）。声明在 ensureUrlPolyfills
  // 顶层（strict 模式下块内函数声明是块级作用域，SimpleURL 块引用不到）。
  function bindParamsToUrl(params, url) {
    params._onChange = function () {
      var text = this.toString();
      url._search = text ? '?' + text : '';
    };
  }

  function ensureUrlPolyfills() {
    if (typeof globalThis.URLSearchParams !== 'function') {
      function decodeParam(value) {
        try {
          return decodeURIComponent(String(value).replace(/\+/g, ' '));
        } catch (_) {
          return value;
        }
      }
      function URLSearchParams(init) {
        this._pairs = [];
        if (typeof init === 'string') {
          var clean = init.replace(/^\?/, '');
          var parts = clean ? clean.split('&') : [];
          for (var i = 0; i < parts.length; i++) {
            if (!parts[i]) continue;
            var kv = parts[i].split('=');
            this._pairs.push([
              decodeParam(kv[0]),
              decodeParam(kv.slice(1).join('=')),
            ]);
          }
        }
      }
      URLSearchParams.prototype.append = function (key, value) {
        this._pairs.push([String(key), String(value)]);
        this._notify();
      };
      URLSearchParams.prototype.set = function (key, value) {
        key = String(key);
        value = String(value);
        for (var i = 0; i < this._pairs.length; i++) {
          if (this._pairs[i][0] === key) {
            this._pairs[i][1] = value;
            this._notify();
            return;
          }
        }
        this._pairs.push([key, value]);
        this._notify();
      };
      URLSearchParams.prototype.get = function (key) {
        key = String(key);
        for (var i = 0; i < this._pairs.length; i++) {
          if (this._pairs[i][0] === key) return this._pairs[i][1];
        }
        return null;
      };
      URLSearchParams.prototype.has = function (key) {
        return this.get(key) !== null;
      };
      URLSearchParams.prototype.delete = function (key) {
        key = String(key);
        var kept = [];
        for (var i = 0; i < this._pairs.length; i++) {
          if (this._pairs[i][0] !== key) kept.push(this._pairs[i]);
        }
        this._pairs = kept;
        this._notify();
      };
      URLSearchParams.prototype.forEach = function (fn, thisArg) {
        for (var i = 0; i < this._pairs.length; i++) {
          fn.call(thisArg || null, this._pairs[i][1], this._pairs[i][0], this);
        }
      };
      URLSearchParams.prototype.toString = function () {
        var out = [];
        for (var i = 0; i < this._pairs.length; i++) {
          out.push(
            encodeURIComponent(this._pairs[i][0]).replace(/%20/g, '+') +
              '=' +
              encodeURIComponent(this._pairs[i][1]).replace(/%20/g, '+'),
          );
        }
        return out.join('&');
      };
      // 变动通知钩子：URL 实例把 searchParams 的修改写回自身 search。
      URLSearchParams.prototype._notify = function () {
        if (typeof this._onChange === 'function') this._onChange();
      };
      globalThis.URLSearchParams = URLSearchParams;
    }
    if (typeof globalThis.URL !== 'function') {
      var URL_RE = /^([a-zA-Z][a-zA-Z0-9+.-]*:)\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/;
      function SimpleURL(input) {
        var match = URL_RE.exec(String(input));
        if (!match) throw new Error('Invalid URL: ' + input);
        this.protocol = match[1];
        var host = match[2];
        var atIndex = host.lastIndexOf('@');
        if (atIndex >= 0) host = host.slice(atIndex + 1);
        var portMatch = /:(\d+)$/.exec(host);
        this.hostname = portMatch
          ? host.slice(0, -portMatch[0].length)
          : host;
        this.port = portMatch ? portMatch[1] : '';
        this.host = host;
        this.pathname = match[3] || '/';
        this.hash = match[5] || '';
        var self = this;
        this.searchParams = new globalThis.URLSearchParams(match[4] || '');
        bindParamsToUrl(this.searchParams, this);
        this._search = match[4] || '';
      }
      Object.defineProperty(SimpleURL.prototype, 'search', {
        get: function () {
          return this._search;
        },
        set: function (value) {
          var text = String(value == null ? '' : value);
          this._search = text ? (text.charAt(0) === '?' ? text : '?' + text) : '';
          this.searchParams = new globalThis.URLSearchParams(
            this._search.replace(/^\?/, ''),
          );
          bindParamsToUrl(this.searchParams, this);
        },
      });
      Object.defineProperty(SimpleURL.prototype, 'href', {
        get: function () {
          return (
            this.protocol + '//' + this.host + this.pathname + this._search + this.hash
          );
        },
      });
      Object.defineProperty(SimpleURL.prototype, 'origin', {
        get: function () {
          return this.protocol + '//' + this.host;
        },
      });
      // 规范接口：宿主运行时（Node/undici 等）会按 WHATWG 语义调用
      // toString / toStringTag，缺失时请求 URL 会被降级成坏串。
      SimpleURL.prototype.toString = function () {
        return this.href;
      };
      SimpleURL.prototype.toJSON = function () {
        return this.href;
      };
      try {
        Object.defineProperty(SimpleURL.prototype, Symbol.toStringTag, {
          value: 'URL',
          configurable: true,
        });
        Object.defineProperty(
          globalThis.URLSearchParams.prototype,
          Symbol.toStringTag,
          { value: 'URLSearchParams', configurable: true },
        );
      } catch (_) {
        /* 老运行时无 Symbol 时忽略 */
      }
      globalThis.URL = SimpleURL;
    }
  }
  ensureUrlPolyfills();

  // ---------------------------------------------------------------------------
  // 内置依赖：宿主 MusicFree 运行时的 require 表里有 crypto-js / he / pako，
  // 通过加载一个一次性假插件把三者取到 globalThis 上，供 sdk 桥使用。
  // ---------------------------------------------------------------------------
  function ensureDeps() {
    var deps = globalThis.__xyV2Deps;
    if (deps && deps.cryptoJs) return deps;
    deps = { cryptoJs: null, he: null, pako: null };
    try {
      globalThis.__xyLoadMusicFreePlugin(
        '__xy-v2-deps',
        "globalThis.__xyV2Deps={cryptoJs:require('crypto-js')," +
          "he:require('he'),pako:require('pako')};" +
          'module.exports={search:function(){}};',
        '{}',
      );
    } catch (_) {
      /* 老运行时缺依赖时逐项为 null，对应能力调用时显式报错 */
    }
    deps = globalThis.__xyV2Deps || deps;
    globalThis.__xyV2Deps = deps;
    if (deps.pako && typeof globalThis.pako === 'undefined') {
      globalThis.pako = deps.pako; // joox 直接引用裸全局 pako
    }
    return deps;
  }

  // ---------------------------------------------------------------------------
  // 字节 / 编码工具（QuickJS 无 Buffer，全部手写）
  // ---------------------------------------------------------------------------

  function utf8Encode(str) {
    var out = [];
    var s = String(str);
    for (var i = 0; i < s.length; i++) {
      var code = s.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < s.length) {
        var lo = s.charCodeAt(i + 1);
        if (lo >= 0xdc00 && lo <= 0xdfff) {
          code = (code - 0xd800) * 0x400 + (lo - 0xdc00) + 0x10000;
          i++;
        }
      }
      if (code < 0x80) out.push(code);
      else if (code < 0x800) {
        out.push(0xc0 | (code >> 6), 0x80 | (code & 63));
      } else if (code < 0x10000) {
        out.push(
          0xe0 | (code >> 12),
          0x80 | ((code >> 6) & 63),
          0x80 | (code & 63),
        );
      } else {
        out.push(
          0xf0 | (code >> 18),
          0x80 | ((code >> 12) & 63),
          0x80 | ((code >> 6) & 63),
          0x80 | (code & 63),
        );
      }
    }
    return out;
  }

  function bytesToHex(bytes) {
    var hex = '';
    for (var i = 0; i < bytes.length; i++) {
      hex += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
    }
    return hex;
  }

  function hexToBytes(hex) {
    var clean = String(hex || '');
    if (clean.length % 2) clean = '0' + clean;
    var out = new Array(clean.length >> 1);
    for (var i = 0; i < out.length; i++) {
      out[i] = parseInt(clean.substr(i * 2, 2), 16) || 0;
    }
    return out;
  }

  function bytesToBase64(bytes) {
    var chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    var out = '';
    for (var i = 0; i < bytes.length; i += 3) {
      var b0 = bytes[i];
      var b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
      var b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      out +=
        chars[b0 >> 2] +
        chars[((b0 & 3) << 4) | (b1 >> 4)] +
        (i + 1 < bytes.length ? chars[((b1 & 15) << 2) | (b2 >> 6)] : '=') +
        (i + 2 < bytes.length ? chars[b2 & 63] : '=');
    }
    return out;
  }

  function base64ToBytes(str) {
    var clean = String(str || '').replace(/[^A-Za-z0-9+/]/g, '');
    while (clean.length % 4) clean += '=';
    var table = base64Table();
    var out = [];
    for (var i = 0; i < clean.length; i += 4) {
      var a = table[clean[i]] || 0;
      var b = table[clean[i + 1]] || 0;
      var c = clean[i + 2] === '=' ? 0 : table[clean[i + 2]] || 0;
      var d = clean[i + 3] === '=' ? 0 : table[clean[i + 3]] || 0;
      out.push((a << 2) | (b >> 4));
      if (clean[i + 2] !== '=') out.push(((b & 15) << 4) | (c >> 2));
      if (clean[i + 3] !== '=') out.push(((c & 3) << 6) | d);
    }
    return out;
  }

  var _b64Table = null;
  function base64Table() {
    if (_b64Table) return _b64Table;
    var chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    var table = {};
    for (var i = 0; i < chars.length; i++) table[chars[i]] = i;
    _b64Table = table;
    return table;
  }

  function bytesToUtf8(bytes) {
    var out = '';
    var i = 0;
    while (i < bytes.length) {
      var code = bytes[i];
      var extra;
      if (code < 0x80) {
        out += String.fromCharCode(code);
        i++;
        continue;
      } else if (code < 0xe0) {
        code = code & 31;
        extra = 1;
      } else if (code < 0xf0) {
        code = code & 15;
        extra = 2;
      } else {
        code = code & 7;
        extra = 3;
      }
      for (var k = 1; k <= extra && i + k < bytes.length; k++) {
        code = (code << 6) | (bytes[i + k] & 63);
      }
      i += extra + 1;
      if (code >= 0x10000) {
        code -= 0x10000;
        out += String.fromCharCode(
          0xd800 + (code >> 10),
          0xdc00 + (code & 0x3ff),
        );
      } else {
        out += String.fromCharCode(code);
      }
    }
    return out;
  }

  var BASIC_HTML_ENTITIES = {
    amp: '&',
    lt: '<',
    gt: '>',
    quot: '"',
    apos: "'",
    nbsp: ' ',
  };

  function decodeHtmlEntities(str) {
    var text = String(str == null ? '' : str);
    if (text.indexOf('&') < 0) return text;
    return text.replace(/&#x([0-9a-f]+);|&#(\d+);|&([a-z]+);/gi, function (
      all,
      hexNum,
      decNum,
      name,
    ) {
      try {
        if (hexNum) return String.fromCodePoint(parseInt(hexNum, 16));
        if (decNum) return String.fromCodePoint(parseInt(decNum, 10));
        var lower = name.toLowerCase();
        if (lower in BASIC_HTML_ENTITIES) {
          return BASIC_HTML_ENTITIES[lower];
        }
      } catch (_) {
        /* 非法实体原样保留 */
      }
      return all;
    });
  }

  // ---------------------------------------------------------------------------
  // sdk 桥
  // ---------------------------------------------------------------------------

  var BODY_BASE64_PREFIX = '__XY_HTTP_BODY_BASE64__';

  // 插件侧 HTTP 串行队列：部分网关（如惜梦 CIT v2）对并发突发直接回
  // nginx 404（插件内 Promise.all 5 平台并行搜索全部失败），串行化既
  // 不改变插件逻辑又对全部 v2 插件生效。请求间隔 120ms 抖动，兼顾
  // 上游限流（「N 秒后再试」类）。
  var _httpQueue = Promise.resolve();

  function enqueueHttp(task) {
    var run = _httpQueue.then(function () {
      return task();
    });
    // 队列链永远向前：失败不阻断后续请求。
    _httpQueue = run.then(
      function () {
        return new Promise(function (resolve) {
          setTimeout(resolve, 120);
        });
      },
      function () {
        return new Promise(function (resolve) {
          setTimeout(resolve, 120);
        });
      },
    );
    return run;
  }

  function createHttpBridge() {
    return function httpRequest(options) {
      var opts = options || {};
      var url = String(opts.url || '');
      var method = String(opts.method || 'GET').toUpperCase();
      var headers = {};
      Object.keys(opts.headers || {}).forEach(function (key) {
        headers[key] = String(opts.headers[key]);
      });
      var body;
      if (opts.bodyHex != null && opts.bodyHex !== '') {
        // 二进制请求体：走宿主约定的 base64 标记通道（XHR 链路只能安全
        // 传输 ASCII 文本，Dart/Rust 侧识别该标记后还原字节）。
        body = BODY_BASE64_PREFIX + bytesToBase64(hexToBytes(opts.bodyHex));
      } else if (opts.body != null) {
        body = typeof opts.body === 'string' ? opts.body : String(opts.body);
      }
      var responseType = String(opts.responseType || 'json').toLowerCase();
      var timeoutMs = Number(opts.timeoutMs) || 20000;
      return enqueueHttp(function () {
        return Promise.resolve()
          .then(function () {
            var init = { method: method, headers: headers };
            if (body != null && method !== 'GET' && method !== 'HEAD') {
              init.body = body;
            }
            if (typeof globalThis.fetch !== 'function') {
              throw new Error('插件运行时未提供 fetch');
            }
            return timeoutCall(globalThis.fetch(url, init), timeoutMs);
          })
          .then(function (response) {
            return decodeResponse(response, responseType);
          });
      });
    };
  }

  function timeoutCall(promise, timeoutMs) {
    if (!timeoutMs || timeoutMs <= 0) return Promise.resolve(promise);
    return new Promise(function (resolve, reject) {
      var settled = false;
      var timer = setTimeout(function () {
        if (!settled) {
          settled = true;
          reject(new Error('HTTP request timeout (' + timeoutMs + 'ms)'));
        }
      }, timeoutMs);
      Promise.resolve(promise).then(
        function (value) {
          if (!settled) {
            settled = true;
            clearTimeout(timer);
            resolve(value);
          }
        },
        function (error) {
          if (!settled) {
            settled = true;
            clearTimeout(timer);
            reject(error);
          }
        },
      );
    });
  }

  // 按ResponseType 归一化响应：'bytes' → hex 字符串（kw/joox 消费方约定），
  // 'text' → 原文，其余 → 尽力 JSON 解析（失败保持原文）。
  function decodeResponse(response, responseType) {
    var status = response.status;
    var headers = response.headers || {};
    if (responseType === 'bytes') {
      return response
        .arrayBuffer()
        .catch(function () {
          return response.text().then(function (text) {
            return utf8Encode(text);
          });
        })
        .then(function (buffer) {
          return {
            status: status,
            body: bytesToHex(new Uint8Array(buffer)),
            headers: headers,
          };
        });
    }
    return response.text().then(function (text) {
      var body = text;
      if (responseType !== 'text') {
        try {
          body = JSON.parse(text);
        } catch (_) {
          body = text;
        }
      }
      return { status: status, body: body, headers: headers };
    });
  }

  function createCryptoBridge(cryptoJs) {
    function digest(algo, hexInput) {
      if (!cryptoJs) throw new Error('sdk.crypto 不可用：crypto-js 依赖缺失');
      var input = cryptoJs.enc.Hex.parse(String(hexInput || ''));
      var algoKey = String(algo || 'sha256').toLowerCase().replace('-', '');
      var fn =
        algoKey === 'md5'
          ? cryptoJs.MD5
          : algoKey === 'sha1'
            ? cryptoJs.SHA1
            : algoKey === 'sha256'
              ? cryptoJs.SHA256
              : null;
      if (!fn) throw new Error('crypto.hash 不支持的算法: ' + algo);
      return fn(input).toString(cryptoJs.enc.Hex);
    }

    function aesRun(desc, args) {
      if (!cryptoJs) throw new Error('sdk.crypto 不可用：crypto-js 依赖缺失');
      var a = args || {};
      var key = cryptoJs.enc.Hex.parse(String(a.keyHex || ''));
      var data = cryptoJs.enc.Hex.parse(String(a.dataHex || ''));
      var cfg = {
        mode:
          String(a.mode || 'ecb').toLowerCase() === 'cbc'
            ? cryptoJs.mode.CBC
            : cryptoJs.mode.ECB,
        padding:
          String(a.padding || 'pkcs7').toLowerCase() === 'none'
            ? cryptoJs.pad.NoPadding
            : cryptoJs.pad.Pkcs7,
      };
      if (cfg.mode === cryptoJs.mode.CBC) {
        cfg.iv = a.ivHex
          ? cryptoJs.enc.Hex.parse(String(a.ivHex))
          : key; // 未给 IV 的 CBC 用 key 兼容（与上游默认一致）
      }
      if (desc === 'encrypt') {
        var encrypted = cryptoJs.AES.encrypt(data, key, cfg);
        return encrypted.ciphertext.toString(cryptoJs.enc.Hex);
      }
      var decrypted = cryptoJs.AES.decrypt(
        cryptoJs.lib.CipherParams.create({ ciphertext: data }),
        key,
        cfg,
      );
      return decrypted.toString(cryptoJs.enc.Hex);
    }

    function randomBytesHex(n) {
      var size = Math.max(0, Math.min(65536, Number(n) | 0));
      var bytes = new Array(size);
      for (var i = 0; i < size; i++) {
        bytes[i] = Math.floor(Math.random() * 256) & 255;
      }
      return bytesToHex(bytes);
    }

    return {
      hash: function (algo, hexInput) {
        return digest(algo, hexInput);
      },
      hmacSha256: function (keyHex, dataHex) {
        if (!cryptoJs) throw new Error('sdk.crypto 不可用：crypto-js 依赖缺失');
        return cryptoJs
          .HmacSHA256(
            cryptoJs.enc.Hex.parse(String(dataHex || '')),
            cryptoJs.enc.Hex.parse(String(keyHex || '')),
          )
          .toString(cryptoJs.enc.Hex);
      },
      aesEncrypt: function (args) {
        return aesRun('encrypt', args);
      },
      aesDecrypt: function (args) {
        return aesRun('decrypt', args);
      },
      randomBytes: function (n) {
        return randomBytesHex(n);
      },
    };
  }

  function createSdk(userVariables) {
    var vars = {};
    Object.keys(userVariables || {}).forEach(function (key) {
      var value = userVariables[key];
      vars[key] = value == null ? '' : value;
    });
    var deps = ensureDeps();
    var storage = new Map();
    var httpBridge = createHttpBridge();
    var cryptoBridge = createCryptoBridge(deps.cryptoJs);
    var logFn = function () {
      try {
        console.log.apply(console, arguments);
      } catch (_) {}
    };
    logFn.info = logFn;
    logFn.warn = logFn;
    logFn.error = logFn;
    logFn.debug = logFn;
    var sdk = {
      http: { request: httpBridge },
      bytes: {
        encode: function (value, encoding) {
          var enc = String(encoding || 'utf8').toLowerCase();
          if (enc === 'utf8' || enc === 'utf-8') {
            return bytesToHex(utf8Encode(String(value)));
          }
          if (enc === 'base64') {
            return bytesToHex(base64ToBytes(String(value)));
          }
          if (enc === 'hex') {
            return String(value);
          }
          throw new Error('bytes.encode 不支持的编码: ' + encoding);
        },
        decode: function (hexInput, encoding) {
          var bytes = hexToBytes(hexInput);
          var enc = String(encoding || 'utf8').toLowerCase();
          if (enc === 'utf8' || enc === 'utf-8') {
            return bytesToUtf8(bytes);
          }
          if (enc === 'base64') {
            return bytesToBase64(bytes);
          }
          if (enc === 'hex') {
            return bytesToHex(bytes);
          }
          // GBK 系编码（酷我/咪咕歌词等中文二进制接口）：交由宿主 bootstrap
          // （plugin_runtime.js）注入的 TextDecoder polyfill 解码，其内置
          // XY_GBK 码表。注意失败必须抛错，让插件按自身回退链处理；按
          // utf-8 强解 GBK 字节只会产出乱码。
          if (
            enc === 'gb18030' ||
            enc === 'gbk' ||
            enc === 'gb2312' ||
            enc === 'cp936' ||
            enc === 'chs'
          ) {
            var Decoder =
              typeof globalThis.TextDecoder === 'function'
                ? globalThis.TextDecoder
                : null;
            if (!Decoder) {
              throw new Error('bytes.decode 不支持的编码: ' + encoding);
            }
            // hexToBytes 产出普通数组，原生 TextDecoder 只接受
            // TypedArray，这里统一转 Uint8Array（宿主 polyfill 两者兼容）。
            return new Decoder('gb18030').decode(new Uint8Array(bytes));
          }
          throw new Error('bytes.decode 不支持的编码: ' + encoding);
        },
        decompress: function (hexInput, algo) {
          var method = String(algo || 'zlib').toLowerCase();
          if (method !== 'zlib' && method !== 'gzip' && method !== 'deflate') {
            throw new Error('bytes.decompress 不支持的算法: ' + algo);
          }
          var pako = ensureDeps().pako;
          if (!pako) throw new Error('bytes.decompress 不可用：pako 依赖缺失');
          var input = hexToBytes(hexInput);
          var inflated =
            method === 'gzip'
              ? pako.ungzip(input)
              : method === 'deflate'
                ? pako.inflateRaw(input)
                : pako.inflate(input);
          return bytesToHex(inflated);
        },
      },
      text: {
        decodeHtml: function (value) {
          var he = ensureDeps().he;
          if (he && typeof he.decode === 'function') {
            try {
              return he.decode(String(value == null ? '' : value));
            } catch (_) {
              /* 回退内置实体表 */
            }
          }
          return decodeHtmlEntities(value);
        },
      },
      crypto: cryptoBridge,
      log: logFn,
      settings: { userVariables: vars },
      storage: {
        get: function (key) {
          return Promise.resolve(storage.has(String(key))
            ? storage.get(String(key))
            : null);
        },
        set: function (key, value) {
          storage.set(String(key), value == null ? null : value);
          return Promise.resolve(true);
        },
        remove: function (key) {
          storage.delete(String(key));
          return Promise.resolve(true);
        },
      },
    };
    return sdk;
  }

  // ---------------------------------------------------------------------------
  // 模块求值
  // ---------------------------------------------------------------------------

  function evaluateModule(source, pluginId, pakoDep) {
    var module = { exports: {} };
    var requireShim = function (name) {
      if (name === 'pako' && pakoDep) return pakoDep;
      throw new Error('v2 插件依赖暂不支持: ' + String(name));
    };
    var factory = new Function(
      'require',
      'module',
      'exports',
      'pako',
      "'use strict';\n" +
        String(source) +
        '\n//# sourceURL=baka_v2_' +
        pluginId +
        '.js',
    );
    factory(requireShim, module, module.exports, pakoDep);
    return module.exports;
  }

  function digHandler(table, path) {
    if (table == null || typeof table !== 'object') return null;
    // 两种合法声明风格：扁平 dotted key（如 CIT v2 的
    // handlers["media.resolve"]）优先；再回退嵌套树（如 vsaa 的
    // handlers.media.resolve）。
    var direct = table[String(path)];
    if (typeof direct === 'function') return direct;
    var current = table;
    var parts = String(path).split('.');
    for (var i = 0; i < parts.length; i++) {
      if (current == null || typeof current !== 'object') return null;
      current = current[parts[i]];
    }
    return typeof current === 'function' ? current : null;
  }

  // ---------------------------------------------------------------------------
  // 游标链管理：宿主按页码调用，插件按 cursor 翻页。
  // 缓存命中直接取；缺失（运行时重建/首次跳页）时从第 1 页逐页重放补齐。
  // scope key 覆盖参与 binding 摘要的全部请求语义字段。
  // ---------------------------------------------------------------------------

  function scopeKeyOf(request) {
    return JSON.stringify([
      request.query == null ? null : String(request.query),
      request.kind == null ? null : String(request.kind),
      request.entity === undefined ? null : request.entity,
      request.tag === undefined ? null : request.tag,
      request.context === undefined ? null : request.context,
      request.sort === undefined ? null : request.sort,
      request.limit == null ? null : Number(request.limit),
    ]);
  }

  function fetchPage(state, handlerPath, request) {
    var handler = digHandler(state.handlers, handlerPath);
    if (!handler) {
      throw new Error(
        '插件未实现 ' + handlerPath + '（capabilities: ' +
          state.capabilities.join(', ') +
          '）',
      );
    }
    return Promise.resolve().then(function () {
      return handler(request, state.sdk);
    });
  }

  // 取第 page 页（1 起始）。返回插件原始结果 {items,nextCursor,...}。
  // cursors[i] 存「第 i+1 页的 nextCursor」：null 表示该页已声明无更多数据
  // （EOF），undefined 表示该页尚未取过（跳页时需重放补齐）。
  function pagedCall(state, handlerPath, request, page) {
    var scopeKey = scopeKeyOf(request);
    var chain = state.cursorChains.get(scopeKey);
    if (!chain) {
      chain = { cursors: [undefined], latest: null };
      state.cursorChains.set(scopeKey, chain);
    }
    var cursor = null;
    if (page > 1) {
      var index = page - 1;
      if (index >= chain.cursors.length || chain.cursors[index] === undefined) {
        // 重放补齐：从第 1 页顺序取到目标页。
        return replayToPage(state, handlerPath, request, page, chain);
      }
      cursor = chain.cursors[index];
      if (cursor == null) {
        // 上一页已声明没有更多数据。
        return Promise.resolve({ items: [], nextCursor: null, xyEof: true });
      }
    }
    var req = Object.assign({}, request, cursor ? { cursor: cursor } : {});
    return fetchPage(state, handlerPath, req).then(function (result) {
      chain.cursors[page] = result && result.nextCursor ? result.nextCursor : null;
      chain.latest = result;
      return result;
    });
  }

  function replayToPage(state, handlerPath, request, page, chain) {
    var step = function (current) {
      if (current >= page) {
        return pagedCall(state, handlerPath, request, page);
      }
      var cached = chain.cursors[current - 1];
      if (cached === null) {
        // 已走到数据末尾：目标页为空。
        return Promise.resolve({ items: [], nextCursor: null, xyEof: true });
      }
      // 第 1 页无需 cursor，直接重放；后续页则带上游标取。
      return pagedCall(state, handlerPath, request, current).then(function () {
        return step(current + 1);
      });
    };
    return step(1);
  }

  // ---------------------------------------------------------------------------
  // 结果整形
  // ---------------------------------------------------------------------------

  function listOf(result) {
    if (result == null) return [];
    if (Array.isArray(result.items)) return result.items;
    if (Array.isArray(result.data)) return result.data;
    if (Array.isArray(result.musicList)) return result.musicList;
    return [];
  }

  function pageResult(result) {
    var items = listOf(result);
    return {
      data: items,
      isEnd: !(result && result.nextCursor),
      total: result && typeof result.total === 'number' ? result.total : undefined,
    };
  }

  function normalizeVideoQuality(quality) {
    var text = String(quality == null ? '' : quality).trim().toLowerCase();
    // 宿主侧档位写法是 720P/1080P/4K，v2 契约为小写 360p~4k。
    if (text === '4k') return '4k';
    if (/^360p$|^480p$|^720p$|^1080p$/.test(text)) return text;
    if (text === '2160p') return '4k';
    if (text === '1080p60') return '1080p';
    return text || '1080p';
  }

  var SEARCH_KINDS = {
    music: 'music',
    album: 'album',
    artist: 'artist',
    singer: 'artist',
    sheet: 'sheet',
    playlist: 'sheet',
    lyric: 'lyric',
    lyrics: 'lyric',
  };

  // ---------------------------------------------------------------------------
  // 门面
  // ---------------------------------------------------------------------------

  // 门面方法 → [v2 handler 路径, 所需 capability]
  var FACADE_MAP = {
    getTopLists: ['discovery.charts', 'discovery.charts'],
    getTopListDetail: ['collections.members', 'collections.members'],
    getMusicSheetInfo: ['collections.members', 'collections.members'],
    getAlbumInfo: ['collections.members', 'collections.members'],
    getArtistWorks: ['collections.members', 'collections.members'],
    getMusicInfo: ['entities.get', 'entities.get'],
    getMediaSource: ['media.resolve', 'media.resolve'],
    getMvSource: ['media.video', 'media.video'],
    getDailyRecommendations: ['discovery.daily', 'discovery.daily'],
    getMusicComments: ['comments.list', 'comments.list'],
    getLyric: ['lyrics.get', 'lyrics.get'],
    importMusicSheet: ['links.resolve', 'links.resolve'],
  };

  var LYRIC_ALIASES = ['getLyrics', 'getLrc', 'getSongLyric', 'getMusicLyric'];

  function buildFacade(state) {
    var facade = {};
    var methods = [];
    var has = function (capability) {
      return (
        !state.capabilities.length ||
        state.capabilities.indexOf(capability) >= 0
      );
    };

    if (has('search')) {
      facade.search = function (keyword, page, type) {
        var kind = SEARCH_KINDS[String(type || 'music').toLowerCase()] || 'music';
        return pagedCall(state, 'search', {
          query: String(keyword == null ? '' : keyword),
          kind: kind,
          limit: LIST_PAGE_SIZE,
        }, Math.max(1, Number(page) || 1)).then(function (result) {
          return {
            data: listOf(result),
            total: result && typeof result.total === 'number' ? result.total : undefined,
          };
        });
      };
      methods.push('search');
    }

    if (has('entities.get')) {
      facade.getMusicInfo = function (musicItem) {
        return Promise.resolve()
          .then(function () {
            return digHandler(state.handlers, 'entities.get')(
              { entity: musicItem },
              state.sdk,
            );
          })
          .then(function (result) {
            return result == null ? null : result;
          });
      };
      methods.push('getMusicInfo');
    }

    if (has('collections.members')) {
      // 榜单详情：v2 members 按 entity.type 分发，宿主传入的榜单对象来自
      // charts（已带 type:'chart'），这里兜底强制。
      facade.getTopListDetail = function (chartItem, page) {
        var entity = Object.assign({}, chartItem, { type: 'chart' });
        return pagedCall(
          state,
          'collections.members',
          { entity: entity, kind: 'music', limit: LIST_PAGE_SIZE },
          Math.max(1, Number(page) || 1),
        ).then(pageResult);
      };
      facade.getMusicSheetInfo = function (sheetItem, page) {
        var entity = Object.assign({}, sheetItem, { type: 'sheet' });
        return pagedCall(
          state,
          'collections.members',
          { entity: entity, kind: 'music', limit: LIST_PAGE_SIZE },
          Math.max(1, Number(page) || 1),
        ).then(function (result) {
          var shaped = pageResult(result);
          if (result && result.entity) shaped.sheetItem = result.entity;
          return shaped;
        });
      };
      facade.getAlbumInfo = function (albumItem, page) {
        var entity = Object.assign({}, albumItem, { type: 'album' });
        return pagedCall(
          state,
          'collections.members',
          { entity: entity, kind: 'music', limit: LIST_PAGE_SIZE },
          Math.max(1, Number(page) || 1),
        ).then(function (result) {
          var shaped = pageResult(result);
          if (result && result.entity) shaped.album = result.entity;
          return shaped;
        });
      };
      facade.getArtistWorks = function (artistItem, page, type) {
        var entity = Object.assign({}, artistItem, { type: 'artist' });
        var kind = String(type || 'music').toLowerCase() === 'album' ? 'album' : 'music';
        return pagedCall(
          state,
          'collections.members',
          { entity: entity, kind: kind, limit: LIST_PAGE_SIZE },
          Math.max(1, Number(page) || 1),
        ).then(function (result) {
          var shaped = pageResult(result);
          if (result && result.entity) shaped.artist = result.entity;
          return shaped;
        });
      };
      methods.push('getTopListDetail', 'getMusicSheetInfo', 'getAlbumInfo', 'getArtistWorks');
    }

    if (has('discovery.charts')) {
      // 榜单目录：v2 charts 返回拍平的 {…chart, type:'chart', group}，
      // 按 group 重建 MusicFree 契约的 [{title, data:[...]}] 分组结构。
      facade.getTopLists = function () {
        var collected = [];
        var fetchRecursively = function (page) {
          // 榜单目录是发现页的点缀能力：部分插件（如 CIT v2）声明了
          // capability 但实现有缺陷（toplist 不支持聚合平台），失败时
          // 优雅降级为空列表，不让整页报错。
          return pagedCall(state, 'discovery.charts', {
            limit: SMALL_PAGE_SIZE,
          }, page).then(function (result) {
            collected.push.apply(collected, listOf(result));
            if (result && result.nextCursor && page < MAX_REPLAY_PAGES) {
              return fetchRecursively(page + 1);
            }
            return null;
          }).catch(function (error) {
            try {
              console.log('[baka_v2] 榜单目录拉取失败，降级为空：' + errorMessage(error));
            } catch (_) {}
            return null;
          });
        };
        return fetchRecursively(1).then(function () {
          var groups = [];
          var byTitle = {};
          for (var i = 0; i < collected.length; i++) {
            var item = collected[i];
            var title = (item && (item.group || item.title)) || '';
            var group = byTitle[title];
            if (!group) {
              group = { title: title, data: [] };
              byTitle[title] = group;
              groups.push(group);
            }
            var entry = Object.assign({}, item);
            delete entry.group;
            group.data.push(entry);
          }
          return groups;
        });
      };
      methods.push('getTopLists');
    }

    if (has('media.resolve')) {
      facade.getMediaSource = function (musicItem, quality) {
        return Promise.resolve()
          .then(function () {
            return digHandler(state.handlers, 'media.resolve')(
              {
                entity: musicItem,
                quality: String(quality || '320k'),
              },
              state.sdk,
            );
          })
          .then(function (result) {
            // resolve 返回 {url, ekey?} 或 null（音质不支持/上游无结果），
            // null 交由宿主按降档候选继续尝试。
            return result == null ? null : result;
          });
      };
      methods.push('getMediaSource');
    }

    if (has('media.video')) {
      facade.getMvSource = function (musicItem, videoQuality) {
        return Promise.resolve()
          .then(function () {
            return digHandler(state.handlers, 'media.video')(
              {
                entity: musicItem,
                quality: normalizeVideoQuality(videoQuality),
              },
              state.sdk,
            );
          })
          .then(function (result) {
            return result == null ? null : result;
          });
      };
      methods.push('getMvSource');
    }

    if (has('discovery.daily')) {
      // 每日 30 首：v2 返回 {state,title,accountName,connectUrl,date,
      // refreshAt,sheetItem,items}，宿主按字段直读，整体透传即可。
      facade.getDailyRecommendations = function () {
        return Promise.resolve()
          .then(function () {
            return digHandler(state.handlers, 'discovery.daily')(
              { limit: 1 },
              state.sdk,
            );
          })
          .then(function (result) {
            return result == null ? { state: 'error' } : result;
          });
      };
      methods.push('getDailyRecommendations');
    }

    if (has('comments.list')) {
      facade.getMusicComments = function (musicItem, page) {
        return pagedCall(
          state,
          'comments.list',
          { entity: musicItem, limit: LIST_PAGE_SIZE },
          Math.max(1, Number(page) || 1),
        ).then(pageResult);
      };
      methods.push('getMusicComments');
    }

    if (has('lyrics.get')) {
      var lyricFn = function (musicItem) {
        return Promise.resolve()
          .then(function () {
            return digHandler(state.handlers, 'lyrics.get')(
              { entity: musicItem },
              state.sdk,
            );
          })
          .then(function (result) {
            return result == null ? null : result;
          });
      };
      facade.getLyric = lyricFn;
      for (var i = 0; i < LYRIC_ALIASES.length; i++) {
        facade[LYRIC_ALIASES[i]] = lyricFn;
      }
      methods.push('getLyric');
    }

    if (has('links.resolve')) {
      // 歌单导入：v2 links.resolve 只把链接解析成 sheet entity，
      // 这里接着翻页拉全曲目，组装宿主导入流程期望的整单结构。
      facade.importMusicSheet = function (input) {
        return Promise.resolve()
          .then(function () {
            return digHandler(state.handlers, 'links.resolve')(
              { url: String(input == null ? '' : input) },
              state.sdk,
            );
          })
          .then(function (entity) {
            if (!entity || typeof entity !== 'object') {
              throw new Error('歌单链接解析失败');
            }
            var sheetEntity = Object.assign({}, entity, { type: 'sheet' });
            var songs = [];
            var sheetItem = sheetEntity;
            var fetchRecursively = function (page) {
              return pagedCall(
                state,
                'collections.members',
                { entity: sheetEntity, kind: 'music', limit: LIST_PAGE_SIZE },
                page,
              ).then(function (result) {
                songs.push.apply(songs, listOf(result));
                if (result && result.entity) sheetItem = result.entity;
                if (result && result.nextCursor && page < MAX_IMPORT_PAGES) {
                  return fetchRecursively(page + 1);
                }
                return null;
              });
            };
            return fetchRecursively(1).then(function () {
              if (!songs.length) {
                throw new Error('歌单内没有可导入的歌曲');
              }
              return {
                title:
                  (sheetItem && (sheetItem.title || sheetItem.name)) || '歌单',
                coverUrl: (sheetItem && sheetItem.artwork) || '',
                artwork: (sheetItem && sheetItem.artwork) || '',
                musicList: songs,
              };
            });
          });
      };
      methods.push('importMusicSheet');
    }

    // MusicFree 注册表要求导出对象带 search；能力未声明时挂一个明确报错
    // 的实现，避免插件在注册阶段被判为「非 MusicFree 插件」整体失效。
    if (typeof facade.search !== 'function') {
      facade.search = function () {
        throw new Error('插件未声明 search 能力，无法搜索');
      };
    }
    facade.platform = state.manifest.platform || state.manifest.name || '';
    facade.version = state.manifest.version || '';
    facade.__xyContract = 'bakaV2';
    facade.__xyCapabilities = state.capabilities.slice();
    state.methods = methods;
    return facade;
  }

  // ---------------------------------------------------------------------------
  // 对外入口
  // ---------------------------------------------------------------------------

  function safeJson(value) {
    try {
      return JSON.stringify(value);
    } catch (error) {
      return JSON.stringify({ ok: false, error: String(error) });
    }
  }

  function errorMessage(error) {
    if (error == null) return '未知错误';
    if (typeof error === 'string') return error;
    if (error && error.message) return String(error.message);
    return String(error);
  }

  globalThis.__xyLoadV2Plugin = function (id, source, userVariablesJson) {
    var key = String(id);
    var existing = states.get(key);
    if (existing) {
      return safeJson({
        ok: true,
        cached: true,
        adapter: ADAPTER_VERSION,
        pluginId: key,
        apiVersion: Number(existing.manifest.apiVersion) || 2,
        name: existing.manifest.name || existing.manifest.platform || '',
        version: existing.manifest.version || '',
        providerId: existing.manifest.id || '',
        capabilities: existing.capabilities,
        methods: existing.methods,
      });
    }
    var userVariables = {};
    try {
      var parsed = userVariablesJson;
      // 宿主传的是 jsonEncode(jsonEncode(userVariables)) 双编码字符串；
      // 兼容对象 / 单编码 / 双编码三种形态。
      for (var depth = 0; depth < 2 && typeof parsed === 'string'; depth++) {
        parsed = JSON.parse(parsed);
      }
      if (parsed && typeof parsed === 'object') {
        Object.keys(parsed).forEach(function (name) {
          userVariables[name] = parsed[name] == null ? '' : parsed[name];
        });
      }
    } catch (_) {
      userVariables = {};
    }
    try {
      var deps = ensureDeps();
      var moduleExports = evaluateModule(source, key, deps.pako);
      var manifest =
        moduleExports && moduleExports.manifest
          ? moduleExports.manifest
          : {};
      var capabilities = Array.isArray(manifest.capabilities)
        ? manifest.capabilities.map(function (item) {
            return String(item);
          })
        : [];
      var state = {
        id: key,
        manifest: manifest,
        capabilities: capabilities,
        handlers:
          moduleExports && moduleExports.handlers
            ? moduleExports.handlers
            : {},
        sdk: createSdk(userVariables),
        userVariables: userVariables,
        cursorChains: new Map(),
        methods: [],
      };
      var facade = buildFacade(state);
      state.facade = facade;
      states.set(key, state);
      // 注册进 MusicFree 注册表：一个只回吐门面的薄壳模块。
      var loader = globalThis.__xyLoadMusicFreePlugin;
      if (typeof loader !== 'function') {
        throw new Error('MusicFree 运行时未就绪，v2 适配层无法注册插件');
      }
      var raw = loader(
        key,
        'module.exports = globalThis.__xyV2Facade(' +
          JSON.stringify(key) +
          ');',
        '{}',
      );
      var info = null;
      try {
        info = JSON.parse(raw);
      } catch (_) {
        info = null;
      }
      if (info && info.ok === false) {
        throw new Error(errorMessage(info.error));
      }
      return safeJson({
        ok: true,
        adapter: ADAPTER_VERSION,
        pluginId: key,
        apiVersion: Number(manifest.apiVersion) || 2,
        name: manifest.name || manifest.platform || '',
        version: manifest.version || '',
        providerId: manifest.id || '',
        platform: manifest.platform || '',
        capabilities: capabilities,
        methods: state.methods,
      });
    } catch (error) {
      states.delete(key);
      return safeJson({
        ok: false,
        pluginId: key,
        error: errorMessage(error),
      });
    }
  };

  globalThis.__xyV2Facade = function (id) {
    var state = states.get(String(id));
    if (!state || !state.facade) {
      throw new Error('v2 插件尚未加载: ' + id);
    }
    return state.facade;
  };

  // 诊断入口：不经 MusicFree 门面直接调 handler（自测/排查用）。
  globalThis.__xyCallV2Plugin = function (id, handlerPath, requestJson) {
    var state = states.get(String(id));
    if (!state) throw new Error('v2 插件尚未加载');
    var request;
    try {
      request = JSON.parse(requestJson || '{}') || {};
    } catch (_) {
      request = {};
    }
    return Promise.resolve()
      .then(function () {
        return digHandler(state.handlers, handlerPath)(request, state.sdk);
      })
      .then(function (result) {
        return safeJson({ ok: true, data: result == null ? null : result });
      })
      .catch(function (error) {
        return safeJson({ ok: false, error: errorMessage(error) });
      });
  };

  globalThis.__xyV2PluginInfo = function (id) {
    var state = states.get(String(id));
    if (!state) return safeJson({ ok: false, error: 'v2 插件尚未加载' });
    return safeJson({
      ok: true,
      adapter: ADAPTER_VERSION,
      pluginId: state.id,
      apiVersion: Number(state.manifest.apiVersion) || 2,
      capabilities: state.capabilities,
      methods: state.methods,
      pages: Array.from(state.cursorChains.keys()).length,
    });
  };
})();
