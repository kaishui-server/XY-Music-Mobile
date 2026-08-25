import axios from 'axios';
import * as cheerioModule from 'cheerio';
import CryptoJS from 'crypto-js';
import dayjs from 'dayjs';
import he from 'he';
import qs from 'qs';
import bigInteger from 'big-integer';
import * as pakoModule from 'pako';
import { Buffer } from 'buffer';

const nativeBodyMarker = '__XY_HTTP_BODY_BASE64__';
const decodeNativeBody = (value) => {
  const text = String(value || '');
  if (!text.startsWith(nativeBodyMarker)) return text;
  return Buffer.from(text.slice(nativeBodyMarker.length), 'base64').toString('utf8');
};

// quickjs_engine 0.1.3 的内置 fetch 资源路径仍指向旧包名，因此这里基于
// 已由 Dart 注入的 XMLHttpRequest 提供等价的轻量 fetch。
globalThis.fetch = (url, options = {}) => new Promise((resolve, reject) => {
  const request = new XMLHttpRequest();
  request.open(options.method || 'GET', url, true);
  request.onload = () => {
    const responseText = decodeNativeBody(request.responseText);
    const headerMap = {};
    const headerRows = [];
    const keys = [];
    String(request.getAllResponseHeaders() || '').replace(
      /^(.*?):[^\S\n]*([\s\S]*?)$/gm,
      (_match, key, value) => {
        const normalized = key.toLowerCase();
        keys.push(normalized);
        headerRows.push([normalized, value]);
        headerMap[normalized] = value;
        return '';
      },
    );
    const response = {
      ok: request.status >= 200 && request.status < 300,
      status: request.status,
      statusText: request.statusText,
      url: request.responseURL || url,
      text: () => Promise.resolve(responseText),
      json: () => {
        try { return Promise.resolve(JSON.parse(responseText)); }
        catch (_) { return Promise.reject(new Error('响应不是有效 JSON')); }
      },
      headers: {
        keys: () => keys,
        entries: () => headerRows,
        get: (name) => headerMap[String(name).toLowerCase()] || null,
        has: (name) => String(name).toLowerCase() in headerMap,
      },
    };
    resolve(response);
  };
  request.onerror = () => reject(new Error(`网络请求失败: ${url}`));
  request.ontimeout = () => reject(new Error(`网络请求超时: ${url}`));
  if (options.headers) {
    for (const [key, value] of Object.entries(options.headers)) {
      request.setRequestHeader(key, String(value));
    }
  }
  request.send(options.body == null ? null : options.body);
});

// QuickJS 自带的 XMLHttpRequest 只实现了最小子集，axios 的默认 XHR
// adapter 在部分接口（Bilibili 搜索最明显）会把 JSON 响应留成字符串。
// 与电脑端一致，显式通过 fetch/Rust HTTP 桥发请求并解析响应。
const pluginAxiosAdapter = async (config) => {
  const method = String(config.method || 'GET').toUpperCase();
  let url = String(config.url || '');
  if (config.baseURL && !/^https?:\/\//i.test(url)) {
    url = String(config.baseURL) + url;
  }
  if (config.params) {
    const cleanParams = {};
    for (const [key, value] of Object.entries(config.params)) {
      cleanParams[key] = Array.isArray(value) ? value[0] : value;
    }
    const query = qs.stringify(cleanParams);
    if (query) url += `${url.includes('?') ? '&' : '?'}${query}`;
  }
  if (!/^https?:\/\//i.test(url)) throw new Error(`无效的插件请求地址: ${url}`);

  const headers = {};
  for (const [key, value] of Object.entries(config.headers || {})) {
    const lower = key.toLowerCase();
    // 这些请求头由 Rust HTTP 客户端管理，手动透传可能导致解压或连接失败。
    if (value == null || lower === 'accept-encoding' || lower === 'connection' || lower === 'content-length') {
      continue;
    }
    headers[key] = String(value);
  }

  let body;
  if (config.data !== undefined && config.data !== null) {
    body = typeof config.data === 'string' ? config.data : JSON.stringify(config.data);
    if (!Object.keys(headers).some((key) => key.toLowerCase() === 'content-type')) {
      headers['Content-Type'] = 'application/json';
    }
  }

  const response = await globalThis.fetch(url, { method, headers, body });
  const responseText = await response.text();
  let data = responseText;
  try { data = JSON.parse(responseText); } catch (_) {}

  const responseHeaders = {};
  for (const [key, value] of response.headers.entries()) responseHeaders[key] = value;
  const axiosResponse = {
    data,
    status: response.status,
    statusText: response.statusText,
    headers: responseHeaders,
    config,
    request: null,
  };
  const validateStatus = config.validateStatus || ((status) => status >= 200 && status < 300);
  if (!validateStatus(response.status)) {
    const error = new Error(`Request failed with status code ${response.status}`);
    error.response = axiosResponse;
    error.config = config;
    throw error;
  }
  return axiosResponse;
};

const pluginAxios = axios.create({ adapter: pluginAxiosAdapter, timeout: 15000 });
const createPluginAxios = pluginAxios.create.bind(pluginAxios);
pluginAxios.create = (config = {}) => {
  const instance = createPluginAxios({ ...config, adapter: pluginAxiosAdapter, timeout: config.timeout || 15000 });
  instance.create = pluginAxios.create;
  return instance;
};

const unwrap = (value, marker) => {
  if (!value) return value;
  if (marker && value[marker]) return value;
  if (value.default && value.default !== value) return value.default;
  return value;
};

const packages = {
  axios: pluginAxios,
  cheerio: unwrap(cheerioModule, 'load'),
  'crypto-js': CryptoJS,
  dayjs,
  he,
  qs,
  'big-integer': bigInteger,
  // 酷狗等插件使用 pako 解压接口返回的压缩数据，保持与桌面端
  // require('pako') 的对象形态一致（包含 inflate/ungzip 等方法）。
  pako: unwrap(pakoModule, 'inflate'),
  buffer: { Buffer },
};

const instances = new Map();

const safeStringify = (value) => JSON.stringify(
  value,
  (_key, item) => typeof item === 'bigint' ? item.toString() : item,
);

globalThis.__xyLoadMusicFreePlugin = (pluginId, source, userVariablesJson) => {
  const userVariables = JSON.parse(userVariablesJson || '{}');
  const module = { exports: {} };
  const require = (name) => {
    const dependency = packages[name];
    if (!dependency) throw new Error(`插件依赖暂不支持: ${name}`);
    try { dependency.default = dependency; } catch (_) {}
    return dependency;
  };
  const envBase = {
    getUserVariables: () => userVariables,
    userVariables,
    os: 'android',
    appVersion: '1.0.0',
    lang: 'zh-CN',
  };
  const env = new Proxy(envBase, {
    get(target, property, receiver) {
      if (Reflect.has(target, property)) return Reflect.get(target, property, receiver);
      return userVariables[property];
    },
  });
  const process = {
    platform: 'android',
    version: '1.0.0',
    env,
    ensurePluginInitialized: Promise.resolve(),
    nextTick: (callback, ...args) => Promise.resolve().then(() => callback(...args)),
  };

  // CommonJS 插件必须在独立函数作用域运行，避免不同插件间变量冲突。
  const execute = new Function(
    'require',
    'module',
    'exports',
    'env',
    'process',
    'fetch',
    'console',
    `'use strict';\n${source}\n`,
  );
  execute(require, module, module.exports, env, process, globalThis.fetch, console);
  const instance = module.exports && module.exports.default
    ? module.exports.default
    : module.exports;
  if (!instance || typeof instance.search !== 'function') {
    throw new Error('插件未提供 search() 方法');
  }
  instances.set(pluginId, instance);
  return safeStringify({
    platform: instance.platform || '',
    version: instance.version || '',
    methods: ['search', 'getMediaSource', 'getMusicInfo']
      .filter((name) => typeof instance[name] === 'function'),
  });
};

globalThis.__xyCallMusicFreePlugin = async (pluginId, method, argsJson) => {
  try {
    const instance = instances.get(pluginId);
    if (!instance) throw new Error('插件尚未加载');
    const fn = instance[method];
    if (typeof fn !== 'function') throw new Error(`插件未提供 ${method}() 方法`);
    const args = JSON.parse(argsJson || '[]');
    const data = await fn.apply(instance, args);
    return safeStringify({ ok: true, data });
  } catch (error) {
    return safeStringify({
      ok: false,
      error: error && error.message ? error.message : String(error),
    });
  }
};
