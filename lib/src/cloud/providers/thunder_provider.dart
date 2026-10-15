// 迅雷云盘 provider（webviewToken：WebView 打开 pan.xunlei.com 官方登录页，
// 捕获 web 端 OAuth 凭据）。
//
// 为什么不再走 HTTP 账密：纯 HTTP 打 xluser 的 v3/login + signin/token，
// 即使 appkey/devicesign 全对，服务端仍会要求「拉取验证页」（滑块/风控），
// 表现为提示「Pull verification page」，无浏览器参与的链路无法完成。
// 改由 WebView 内跑官方登录流程，验证码/滑块都在页面里交互完成。
//
// 凭据落盘位置：web 端用 @xbase/sdk 的 OAuth2Client，把凭据写进
// localStorage 的 `credentials_<clientId>`（值为 JSON，含
// access_token/refresh_token/sub）。refresh 复用 /v1/auth/token，
// 但必须带 web 端 client 凭据（Android 端 client 与 web token 不配套）。
//
// 验证码令牌（关键）：api-pan 网关要求每个业务请求带 `x-captcha-token`
// （服务端错误码字面量 CAPTCHA_REQUIRED），缺失时报
// 「HTTP 400 code=captcha_required 请求参数缺失」；另外 files 接口还要求
// `x-device-id`。这些头由页面自己算（@xbase/captcha +
// device-sign-utility，算法在 WASM 里，Dart 侧无法复刻），因此在
// WebView 文档开始处注入钩子，把页面真实请求里的这些头存进
// localStorage，登录时随凭据一起取回并在 Dart 请求里原样回放。
// XCloud 架构（与 PikPak 同构）：files/share/restore 接口形状一致。

import 'dart:convert';
import 'dart:math';

import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_types.dart';
import '../share_link_parser.dart';
import 'http_login_support.dart';

class ThunderProvider extends CloudProvider {
  const ThunderProvider();

  // 请求伪装常量（沿用 AList thunder 驱动，见 xl_driver.go / xl_types.go）。
  static const _ua =
      'ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G '
      'appid/40 deviceName/Xiaomi_M2004j7ac deviceModel/M2004J7AC '
      'OSVersion/12 protocolVersion/301 platformVersion/10 sdkVersion/512000 '
      'Oauth2Client/0.9 (Linux 4_14_186-perf-gddfs8vbb238b) (JAVA 0)';
  // Android 端 OAuth 凭据：仅作为**存量账号**（此前经账密通道绑定、cred
  // 里没记 clientId/clientSecret）刷新时的兜底。
  static const _clientId = 'Xp6vsxz_7IYVw2BB';
  static const _clientSecret = 'Xp6vsy4tN9toTVdMSpomVdXpRmES';
  // web 端 OAuth client_secret（取自 pan.xunlei.com 前端 grantToken 调用）；
  // client_id 由捕获到的 localStorage 键名 `credentials_<clientId>` 反推。
  static const _webClientSecret = 'Xqp0kC5LIQcyGSdKPYSzshgLKHxo';
  static const _clientVersion = '8.31.0.9726';
  // xluser 网关的令牌接口挂在 /v1 下（AList 常量 XLUSER_API_URL =
  // XLUSER_API_BASE_URL + "/v1"）。
  static const _authBase = 'https://xluser-ssl.xunlei.com/v1';

  /// 文档开始注入的钩子：记录页面发往业务网关的真实请求头
  /// （x-captcha-token / x-device-id / x-device-sign / x-client-id /
  /// x-client-version），写进 localStorage 供 pollScript 取回。
  /// 必须在页面脚本之前装上，否则首页加载时的首批请求会漏采。
  static const _headerHookJs = '''
(function () {
  try {
    if (window.__xyHdr) return;
    window.__xyHdr = 1;
    var KEY = {
      'x-captcha-token': '__xy_cap',
      'x-device-id': '__xy_dev',
      'x-device-sign': '__xy_dsg',
      'x-client-id': '__xy_cid',
      'x-client-version': '__xy_cv'
    };
    var put = function (k, v) {
      try {
        var key = KEY[String(k).toLowerCase()];
        if (key && v) window.localStorage.setItem(key, String(v));
      } catch (e) {}
    };
    var scan = function (h) {
      try {
        if (!h) return;
        if (typeof h.forEach === 'function' && !Array.isArray(h)) {
          h.forEach(function (v, k) { put(k, v); });
        } else if (Array.isArray(h)) {
          for (var i = 0; i < h.length; i++) put(h[i][0], h[i][1]);
        } else {
          for (var k in h) put(k, h[k]);
        }
      } catch (e) {}
    };
    var XHR = window.XMLHttpRequest && window.XMLHttpRequest.prototype;
    if (XHR && XHR.setRequestHeader) {
      var orig = XHR.setRequestHeader;
      XHR.setRequestHeader = function (k, v) {
        put(k, v);
        return orig.apply(this, arguments);
      };
    }
    if (window.fetch) {
      var of = window.fetch;
      window.fetch = function (a, b) {
        try {
          if (b && b.headers) scan(b.headers);
          else if (a && a.headers) scan(a.headers);
        } catch (e) {}
        return of.apply(this, arguments);
      };
    }
  } catch (e) {}
})();
''';

  Map<String, String> _h(
    String accessToken, {
    String deviceId = '',
    String clientId = '',
    String deviceSign = '',
    String captchaToken = '',
    String clientVersion = '',
  }) =>
      {
        'User-Agent': _ua,
        'Referer': 'https://pan.xunlei.com/',
        if (deviceId.isNotEmpty) 'x-device-id': deviceId,
        if (deviceSign.isNotEmpty) 'x-device-sign': deviceSign,
        // 网关的验证码令牌：缺失即 HTTP 400 captcha_required。
        if (captchaToken.isNotEmpty) 'x-captcha-token': captchaToken,
        'x-client-id': clientId.isEmpty ? _clientId : clientId,
        'x-client-version':
            clientVersion.isEmpty ? _clientVersion : clientVersion,
        if (accessToken.isNotEmpty) 'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };

  /// 稳定设备号：优先用页面捕获值（与页面真实请求一致），缺失时生成一个
  /// 随机值并写回 cred。api-pan 逐请求校验 `x-device-id`，空值直接
  /// 400 invalid_argument device_id is empty。
  String _deviceId(Map<String, String> cred) {
    final existing = cred['deviceId'] ?? '';
    if (existing.isNotEmpty) return existing;
    final rnd = Random.secure();
    final hex = List.generate(16, (_) => rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    cred['deviceId'] = hex;
    return hex;
  }

  /// 容错取整：XCloud 把数值字段序列化成 JSON **字符串**（AList 里
  /// `Size string `json:"size"``，protobuf JSON 对 int64 的默认行为），
  /// 直接 `as num?` 会抛类型转换异常，把整个目录列表拖崩（表现为
  /// 界面只报「目录加载失败」这类兜底文案）。
  static int _asInt(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  /// 申领 / 复用验证码令牌。
  ///
  /// AList 同款链路：POST xluser `/v1/shield/captcha/init`，body 带
  /// action（`方法:/路径`）+ client_id + device_id + meta + redirect_uri。
  /// api-pan 要求业务请求带 `x-captcha-token`，缺失即 400 captcha_required；
  /// 令牌短命，页面捕获到的会过期，故这里按 action 现领并缓存进 cred。
  /// 申领失败（风控要滑块 / 网络异常）不抛错，回退到页面捕获的令牌。
  Future<String> _captchaToken(Map<String, String> cred, String action) async {
    final cached = cred['captchaToken'] ?? '';
    final expireMs = int.tryParse(cred['captchaExpireMs'] ?? '') ?? 0;
    if (cached.isNotEmpty &&
        expireMs > DateTime.now().millisecondsSinceEpoch) {
      return cached;
    }
    final clientId =
        (cred['clientId']?.isNotEmpty ?? false) ? cred['clientId']! : _clientId;
    final clientVersion = (cred['clientVersion']?.isNotEmpty ?? false)
        ? cred['clientVersion']!
        : _clientVersion;
    final deviceId = _deviceId(cred);
    try {
      final resp = await cloudPostJson(
        '$_authBase/shield/captcha/init',
        body: {
          'action': action,
          'captcha_token': cached,
          'client_id': clientId,
          'device_id': deviceId,
          'meta': {
            'client_version': clientVersion,
            'package_name': 'com.xunlei.downloadprovider',
            'user_id': cred['userId'] ?? '',
          },
          'redirect_uri': 'xlaccsdk01://xunlei.com/callback?state=harbor',
        },
        headers: {
          'User-Agent': _ua,
          'accept': 'application/json;charset=UTF-8',
          'x-device-id': deviceId,
          'x-client-id': clientId,
          'x-client-version': clientVersion,
        },
      );
      if (!resp.isOk) return cached;
      final token = (resp.json['captcha_token'] ?? '').toString();
      if (token.isEmpty) return cached;
      final expiresRaw = resp.json['expires_in'];
      final expiresIn = expiresRaw == null ? 600 : _asInt(expiresRaw);
      cred['captchaToken'] = token;
      // 提前 60s 视为失效，避免踩过期边界。
      cred['captchaExpireMs'] =
          '${DateTime.now().millisecondsSinceEpoch + (expiresIn - 60) * 1000}';
      return token;
    } catch (_) {
      return cached;
    }
  }

  /// api-pan 业务请求头：Authorization + 设备号 + 验证码令牌 + client 头。
  Future<Map<String, String>> _panHeaders(
    Map<String, String> cred,
    String at, {
    required String action,
  }) async =>
      _h(
        at,
        deviceId: _deviceId(cred),
        clientId: cred['clientId'] ?? '',
        deviceSign: cred['deviceSign'] ?? '',
        captchaToken: await _captchaToken(cred, action),
        clientVersion: cred['clientVersion'] ?? '',
      );

  @override
  String get id => 'thunder';

  @override
  String get displayName => '迅雷云盘';

  @override
  String get rootPath => '';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewToken;

  @override
  Duration get directLinkTtl => const Duration(minutes: 30);

  // 网页端登录：pan.xunlei.com/login 是迅雷网盘官方登录页（账号密码 /
  // 手机验证码 / 扫码，页面内自带滑块等风控交互）。
  @override
  String get webviewLoginUrl => 'https://pan.xunlei.com/login';

  // 登录页必须用桌面 UA：迅雷前端按 UA 判定平台，移动 UA 打开 /login 会被
  // 直接重定向回首页营销页（只剩「在线云盘更舒心」轮播，没有任何登录入口）；
  // 桌面 UA 才会停留在 /login，并把官方登录 iframe
  // （https://i.xunlei.com/xluser/auth/，内含「账号密码登录 / 短信登录 / 扫码」）
  // 内嵌到 #login-wrap。
  @override
  String get webviewLoginUserAgent =>
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 用户脚本（文档开始注入）+ 轮询脚本。
  ///
  /// 轮询脚本扫 localStorage 的 `credentials_<clientId>` 键（web 端
  /// @xbase/sdk OAuth2Client 的凭据落盘位置），命中含 access_token 的
  /// 凭据即返回其 JSON；键名尾段即 web 端 client_id，一并带回供刷新使用。
  /// 同时把 [_headerHookJs] 采集到的风控请求头（验证码令牌 / 设备号 /
  /// 设备签名 / 页面实际 client 版本）一并返回。
  @override
  CloudCaptureRule? get captureRule => const CloudCaptureRule(
        userScript: _headerHookJs,
        pollScript: '''
(() => {
  try {
    var ls = window.localStorage;
    for (var i = 0; i < ls.length; i++) {
      var k = ls.key(i);
      if (!k || k.indexOf('credentials_') !== 0) continue;
      var raw = ls.getItem(k);
      if (!raw) continue;
      var o = null;
      try { o = JSON.parse(raw); } catch (e) { continue; }
      if (!o || typeof o !== 'object') continue;
      var c = (o.credentials && o.credentials.access_token) ? o.credentials : o;
      if (!c || !c.access_token) continue;
      return JSON.stringify({
        at: String(c.access_token),
        rt: String(c.refresh_token || ''),
        uid: String(c.sub || o.sub || ''),
        cid: k.substring('credentials_'.length).split('@')[0],
        cap: String(ls.getItem('__xy_cap') || ''),
        dev: String(ls.getItem('__xy_dev') || ''),
        dsg: String(ls.getItem('__xy_dsg') || ''),
        wcid: String(ls.getItem('__xy_cid') || ''),
        wcv: String(ls.getItem('__xy_cv') || '')
      });
    }
    return '';
  } catch (e) { return ''; }
})()''',
        pollIntervalMs: 500,
      );

  // ── 登录 ──────────────────────────────────────────────

  /// WebView 捕获 web 端 OAuth 凭据 → 组装账号并用业务接口二次校验。
  ///
  /// 校验只拦「服务端明确判定凭据无效」的情况（HTTP 401 /
  /// error_code 16 / unauthenticated）。captcha_required、参数缺失等
  /// 风控/参数类错误说明凭据本身已被识别，不阻断绑定——否则每次成功
  /// 登录都会被误判为「登录状态校验失败」。
  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) async {
    final raw = captured.token;
    if (raw == null || raw.isEmpty) {
      throw const CloudException('未捕获到登录凭据，请确认已成功登录后重试');
    }
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      throw const CloudException('登录凭据解析失败，请重新登录');
    }
    final accessToken = (parsed['at'] ?? '').toString();
    if (accessToken.isEmpty) {
      throw const CloudException('未捕获到登录凭据，请重新登录');
    }
    final refreshToken = (parsed['rt'] ?? '').toString();
    final userId = (parsed['uid'] ?? '').toString();
    // 优先用页面实际发请求时带的 client_id（网关按它识别客户端），
    // 缺失时回退凭据存储键名反推的 client_id。
    final headerClientId = (parsed['wcid'] ?? '').toString();
    final clientId = headerClientId.isNotEmpty
        ? headerClientId
        : (parsed['cid'] ?? '').toString();
    final headerClientVersion = (parsed['wcv'] ?? '').toString();
    final captchaToken = (parsed['cap'] ?? '').toString();
    final deviceId = (parsed['dev'] ?? '').toString();
    final deviceSign = (parsed['dsg'] ?? '').toString();
    final cred = <String, String>{
      'accessToken': accessToken,
      if (refreshToken.isNotEmpty) 'refreshToken': refreshToken,
      'userId': userId,
      // web 端凭据必须配套 web 端 client 刷新（Android 端 client 会在
      // /v1/auth/token 被拒），clientId 来自凭据存储键名。
      if (clientId.isNotEmpty) 'clientId': clientId,
      'clientSecret': _webClientSecret,
      // 页面真实请求头回放（缺任一项都会让业务接口报错）。
      if (deviceId.isNotEmpty) 'deviceId': deviceId,
      if (deviceSign.isNotEmpty) 'deviceSign': deviceSign,
      if (captchaToken.isNotEmpty) 'captchaToken': captchaToken,
      if (headerClientVersion.isNotEmpty)
        'clientVersion': headerClientVersion,
      // 记录预估过期时间（XCloud 约 2h），便于到点前静默刷新。
      'accessExpireMs':
          '${DateTime.now().millisecondsSinceEpoch + 2 * 3600 * 1000}',
    };
    CloudHttpResponse probe;
    try {
      probe = await _sessionProbe(cred);
    } on CloudException catch (e) {
      throw CloudException('登录状态校验失败（${e.message}），请确认已成功登录后重试');
    }
    final body = probe.body;
    final rejected = probe.status == 401 ||
        body.contains('unauthenticated') ||
        body.contains('"error_code":16') ||
        body.contains('"error_code": 16');
    if (rejected) {
      throw CloudException(
          '登录状态校验失败（${respErrorDetail(probe)}），请确认已成功登录后重试');
    }
    return CloudAccount(
      provider: id,
      accountId:
          userId.isEmpty ? md5Hex(accessToken).substring(0, 12) : userId,
      nickname: displayName,
      cred: cred,
      boundAt: DateTime.now(),
    );
  }

  /// 会话校验探针：打 drive/v1/about（凭据无效时 401 / unauthenticated）。
  /// 是否判定「校验失败」由调用方按 [rejected] 语义决定。
  Future<CloudHttpResponse> _sessionProbe(Map<String, String> cred) async {
    var at = cred['accessToken'] ?? '';
    if (at.isEmpty) at = (await _auth(cred));
    return cloudGet(
      'https://api-pan.xunlei.com/drive/v1/about',
      headers:
          await _panHeaders(cred, at, action: 'GET:/drive/v1/about'),
    );
  }

  /// refresh 换新 access_token（POST /v1/auth/token，grant_type=refresh_token；
  /// best-effort；失败抛过期让用户重绑）。
  Future<String?> _refreshToken(Map<String, String> cred) async {
    final refreshToken = cred['refreshToken'];
    if (refreshToken == null || refreshToken.isEmpty) return null;
    // client 凭据必须与 access_token 同源：web 登录的账号用 web 端
    // clientId/clientSecret，存量账密账号（cred 未记）回退 Android 端。
    final clientId =
        (cred['clientId']?.isNotEmpty ?? false) ? cred['clientId']! : _clientId;
    final clientSecret = (cred['clientSecret']?.isNotEmpty ?? false)
        ? cred['clientSecret']!
        : _clientSecret;
    try {
      final resp = await cloudPostJson(
        '$_authBase/auth/token',
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'client_id': clientId,
          'client_secret': clientSecret,
        },
        headers: {
          'User-Agent': _ua,
          'Content-Type': 'application/json',
          if (cred['deviceId']?.isNotEmpty ?? false)
            'x-device-id': cred['deviceId']!,
          if (cred['deviceSign']?.isNotEmpty ?? false)
            'x-device-sign': cred['deviceSign']!,
          if (cred['captchaToken']?.isNotEmpty ?? false)
            'x-captcha-token': cred['captchaToken']!,
          'x-client-id': clientId,
          'x-client-version':
              (cred['clientVersion']?.isNotEmpty ?? false)
                  ? cred['clientVersion']!
                  : _clientVersion,
        },
      );
      if (!resp.isOk) return null;
      final at = (resp.json['access_token'] ?? '').toString();
      if (at.isEmpty) return null;
      // 服务端可能轮换 refresh_token，轮换则回写持久化。
      final newRt = (resp.json['refresh_token'] ?? '').toString();
      if (newRt.isNotEmpty) cred['refreshToken'] = newRt;
      return at;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> validate(Map<String, String> cred) async {
    try {
      final resp = await _req(cred, (at) async => cloudGet(
            'https://api-pan.xunlei.com/drive/v1/about',
            headers:
                await _panHeaders(cred, at, action: 'GET:/drive/v1/about'),
          ));
      if (resp.isOk) return true;
      // captcha_required 等风控/参数类错误说明凭据已被识别，不代表失效；
      // 只有 401 / unauthenticated 才算登录态真的没了。
      final body = resp.body;
      final rejected = resp.status == 401 ||
          body.contains('unauthenticated') ||
          body.contains('"error_code":16') ||
          body.contains('"error_code": 16');
      return !rejected;
    } catch (_) {
      return false;
    }
  }

  /// 取 access_token：缓存有效期内直接返回；过期先静默刷新，失败用旧值兜底。
  Future<String> _auth(Map<String, String> cred) async {
    final cached = cred['accessToken'] ?? '';
    if (cached.isNotEmpty) {
      final expireMs = int.tryParse(cred['accessExpireMs'] ?? '') ?? 0;
      final expired =
          expireMs > 0 && DateTime.now().millisecondsSinceEpoch >= expireMs;
      if (!expired) return cached;
      final fresh = await _refreshToken(cred);
      if (fresh != null) {
        cred['accessToken'] = fresh;
        return fresh;
      }
      return cached;
    }
    final fresh = await _refreshToken(cred);
    if (fresh == null) throw const CloudException('登录已过期，请重新绑定');
    return fresh;
  }

  /// 带 401 自动刷新的请求包装：access_token 被服务端提前判定失效时
  /// （踢下线/提前过期）刷新一次并重放请求，避免列表/直链反复失败。
  Future<CloudHttpResponse> _req(
    Map<String, String> cred,
    Future<CloudHttpResponse> Function(String at) call,
  ) async {
    var at = await _auth(cred);
    var resp = await call(at);
    if (resp.status == 401) {
      final fresh = await _refreshToken(cred);
      if (fresh != null) {
        cred['accessToken'] = fresh;
        resp = await call(fresh);
      }
    }
    return resp;
  }

  // ── 目录 ──────────────────────────────────────────────

  @override
  Future<CloudListResult> listDir(
    Map<String, String> cred,
    String path, {
    String? cursor,
  }) async {
    // 入参与 AList thunder 驱动的 getFiles 逐项对齐（space / __type / refresh /
    // __sync / with_audit / filters 的 eq 形态）；off 形态的 filters
    // （`{"phase":{"in":[...]}}`）与缺失参数会被网关判参数错误。
    final url = 'https://api-pan.xunlei.com/drive/v1/files'
        '?space=&__type=drive&refresh=true&__sync=true&with_audit=true'
        '&limit=100'
        '&parent_id=${Uri.encodeQueryComponent(path)}'
        '&page_token=${Uri.encodeQueryComponent(cursor ?? '')}'
        '&filters=${Uri.encodeQueryComponent(jsonEncode(const {
              'phase': {'eq': 'PHASE_TYPE_COMPLETE'},
              'trashed': {'eq': false},
            }))}';
    Future<CloudHttpResponse> call(String at) async => cloudGet(
          url,
          headers: await _panHeaders(cred, at, action: 'GET:/drive/v1/files'),
        );
    var resp = await _req(cred, call);
    // 验证码令牌短命：服务端判失效（错误码 9 / captcha_*）时重领一枚重试一次。
    if (resp.status == 400 && resp.body.contains('captcha')) {
      cred.remove('captchaExpireMs');
      resp = await _req(cred, call);
    }
    if (!resp.isOk) {
      throw CloudException('目录列表请求失败（${respErrorDetail(resp)}）');
    }
    final files = <CloudFile>[];
    for (final e in (resp.json['files'] as List?) ?? const []) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['id'] ?? '').toString(),
        name: (e['name'] ?? '').toString(),
        isDir: e['kind'] == 'drive#folder',
        size: _asInt(e['size']),
        parentId: path,
      ));
    }
    final next = (resp.json['next_page_token'] ?? '').toString();
    return CloudListResult(
      files: files,
      nextCursor: next.isEmpty ? null : next,
    );
  }

  // ── 分享 ──────────────────────────────────────────────

  @override
  Future<CloudShareParse> parseShareLink(String url, String? pwd) async {
    final info = parseUrlToProvider(url);
    final shareId = info?.shareId ?? url;
    final resp = await cloudGet(
      'https://api-pan.xunlei.com/drive/v1/share/detail'
      '?share_id=${Uri.encodeQueryComponent(shareId)}'
      '&pass_code=${Uri.encodeQueryComponent(pwd ?? '')}',
      headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
    );
    if (!resp.isOk) throw const CloudException('分享链接解析失败');
    final data = resp.json['share'] is Map<String, dynamic>
        ? resp.json
        : {'share': resp.json};
    final share = (data['share'] as Map<String, dynamic>?) ?? const {};
    final passCodeToken = (share['pass_code_token'] ?? '').toString();
    if (passCodeToken.isEmpty && (pwd?.isNotEmpty ?? false)) {
      throw const CloudException('提取码错误');
    }
    final list =
        ((resp.json['list'] ?? resp.json['files']) as List?) ?? const [];
    final files = <CloudFile>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['file_id'] ?? e['id'] ?? '').toString(),
        name: (e['name'] ?? '').toString(),
        isDir: e['kind'] == 'drive#folder',
        size: _asInt(e['size']),
      ));
    }
    return CloudShareParse(
      providerId: id,
      files: files,
      shareId: shareId,
      shareToken: passCodeToken,
      passcode: pwd,
      directPlayable: false,
    );
  }

  @override
  Future<List<CloudFile>> transferShareFiles(
    Map<String, String> cred,
    CloudShareParse share,
  ) async {
    final token = share.shareToken;
    if (token == null || token.isEmpty) throw const CloudException('请先填写提取码');
    final resp = await _req(cred, (at) async => cloudPostJson(
          'https://api-pan.xunlei.com/drive/v1/share/restore',
          body: {
            'share_id': share.shareId,
            'pass_code_token': token,
            'file_list': share.files
                .map((f) => {'file_id': f.id, 'name': f.name})
                .toList(),
          },
          headers: await _panHeaders(cred, at,
              action: 'POST:/drive/v1/share/restore'),
        ));
    if (!resp.isOk) {
      throw CloudException('转存失败（${respErrorDetail(resp)}）');
    }
    // 转存后 id 变化：按文件名回查根目录。
    final listed = await listDir(cred, '');
    final byName = {for (final f in listed.files) f.name: f};
    final out = <CloudFile>[];
    for (final f in share.files) {
      final hit = byName[f.name];
      if (hit != null) out.add(hit);
    }
    if (out.isEmpty) throw const CloudException('转存失败');
    return out;
  }

  // ── 直链 ──────────────────────────────────────────────

  @override
  Future<CloudDirectLink> getDirectLink(
      Map<String, String> cred, CloudFile file) async {
    final resp = await _req(cred, (at) async => cloudGet(
          'https://api-pan.xunlei.com/drive/v1/files/${Uri.encodeQueryComponent(file.id)}',
          headers: await _panHeaders(cred, at,
              action: 'GET:/drive/v1/files/${file.id}'),
        ));
    if (!resp.isOk) {
      throw CloudException('直链获取失败（${respErrorDetail(resp)}）');
    }
    final url = (resp.json['web_content_link'] ?? '').toString();
    if (url.isEmpty) {
      // 部分文件在 medias[].link.url 兜底。
      final medias = (resp.json['medias'] as List?) ?? const [];
      for (final m in medias) {
        if (m is! Map<String, dynamic>) continue;
        final alt = ((m['link'] as Map<String, dynamic>?)?['url'] ?? '')
            .toString();
        if (alt.isNotEmpty) {
          return CloudDirectLink(
            url: alt,
            headers: {'User-Agent': _ua, 'Referer': 'https://pan.xunlei.com/'},
            fileName: file.name,
            size: file.size,
            expireAt: DateTime.now().add(const Duration(minutes: 30)),
          );
        }
      }
      throw const CloudException('直链获取失败');
    }
    return CloudDirectLink(
      url: url,
      headers: {'User-Agent': _ua, 'Referer': 'https://pan.xunlei.com/'},
      fileName: file.name,
      size: file.size,
      expireAt: DateTime.now().add(const Duration(minutes: 30)),
    );
  }
}
