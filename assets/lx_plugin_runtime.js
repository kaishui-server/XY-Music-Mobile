// Minimal LX (落雪) compatibility layer.
//
// LX plugins register a request handler through globalThis.lx rather than the
// MusicFree getMediaSource API.  The mobile client used to skip that handler
// and consequently tried the public fallback URL resolver, which cannot work
// for private/custom sources.  This bridge keeps the plugin in the same
// QuickJS runtime as MusicFree and adapts lx.request to the runtime fetch.
(function () {
  const states = globalThis.__xyLxPlugins || (globalThis.__xyLxPlugins = new Map());

  function makeRequest() {
    return function request(url, options, callback) {
      const opts = { ...(options || {}) };
      const headers = { ...(opts.headers || {}) };
      let body = opts.body;
      if (body != null && typeof body !== 'string') {
        body = JSON.stringify(body);
        if (!Object.keys(headers).some((key) => key.toLowerCase() === 'content-type')) {
          headers['Content-Type'] = 'application/json';
        }
      }
      delete opts.follow_max;
      opts.headers = headers;
      opts.body = body;
      Promise.resolve()
        .then(() => globalThis.fetch(url, opts))
        .then(async (response) => {
          const text = await response.text();
          let parsed = text;
          try { parsed = JSON.parse(text); } catch (_) {}
          callback(null, {
            body: parsed,
            status: response.status,
            statusCode: response.status,
            headers: response.headers,
          });
        })
        .catch((error) => {
          // LX scripts often fire background update checks without awaiting
          // them. Returning a synthetic response keeps that optional request
          // from becoming an unhandled Promise rejection.
          callback(null, {
            body: { code: 599, message: String(error && error.message || error) },
            status: 599,
            statusCode: 599,
            headers: { keys: () => [], entries: () => [], get: () => null, has: () => false },
          });
        });
    };
  }

  function makeApi() {
    const EVENT_NAMES = {
      request: 'request',
      inited: 'inited',
      updateAlert: 'updateAlert',
    };
    let requestHandler = null;
    const api = {
      EVENT_NAMES,
      request: makeRequest(),
      on(event, handler) {
        if (event === EVENT_NAMES.request) requestHandler = handler;
      },
      send() {},
      env: 'mobile',
      version: '1.0.0',
      utils: {
        versionCompare(a, b) {
          const left = String(a || '').split('.').map((v) => Number(v) || 0);
          const right = String(b || '').split('.').map((v) => Number(v) || 0);
          for (let i = 0; i < Math.max(left.length, right.length); i++) {
            if ((left[i] || 0) !== (right[i] || 0)) return (left[i] || 0) - (right[i] || 0);
          }
          return 0;
        },
      },
    };
    return { api, getHandler: () => requestHandler };
  }

  globalThis.__xyLoadLxPlugin = function (id, source) {
    const key = String(id);
    if (states.has(key)) return JSON.stringify({ ok: true });
    const built = makeApi();
    const previous = globalThis.lx;
    globalThis.lx = built.api;
    try {
      // new Function avoids leaking plugin const/let declarations into this
      // bridge while still exposing globalThis.lx as required by LX scripts.
      (new Function(String(source)))();
      states.set(key, { api: built.api, getHandler: built.getHandler });
      // Keep an LX object available for asynchronous update checks performed by
      // plugins immediately after initialization.
      globalThis.lx = built.api;
      return JSON.stringify({ ok: true });
    } catch (error) {
      globalThis.lx = previous;
      throw error;
    }
  };

  globalThis.__xyCallLxPlugin = function (id, request) {
    const state = states.get(String(id));
    if (!state) throw new Error('LX 插件尚未初始化');
    const handler = state.getHandler();
    if (typeof handler !== 'function') throw new Error('LX 插件未注册请求处理器');
    const previous = globalThis.lx;
    globalThis.lx = state.api;
    return Promise.resolve(handler(request)).finally(() => {
      globalThis.lx = previous || state.api;
    });
  };
})();
