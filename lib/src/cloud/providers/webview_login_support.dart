// WebView 登录捕获支撑（XY 移植版：基于 flutter_inappwebview 6.x）。
//
// Cookie 采集优先走原生 CookieManager 通道（可读 httpOnly），失败回退
// JS `document.cookie`；Token 范式（阿里等）走 pollScript 注入轮询：
// 定时执行 JS 片段，返回非空字符串即视为 token 出现。

import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../cloud_types.dart';

class CloudWebviewCaptureSession {
  CloudWebviewCaptureSession(this.rule, {this.autoComplete = true});

  final CloudCaptureRule rule;

  /// 是否允许自动判定「捕获完成」。
  ///
  /// 登录页统一传 false：解绑后二次登录时，WebView 里仍残留上一次的
  /// 会话（Cookie / localStorage），自动采集会把**旧账号**立刻当成新
  /// 登录结果绑回去；因此登录一律由用户点「我已登录完成」收口
  /// （百度网盘即为该行为）。false 时轮询不置完成标记、持续刷新凭据，
  /// 由 [hasCapture] 判断当前是否已有可用凭据。
  final bool autoComplete;

  final Map<String, String> _cookies = {};
  String? _token;
  String? _finalUrl;
  Timer? _timer;
  bool _completed = false;

  CloudCaptureResult result() => CloudCaptureResult(
        cookies: Map.of(_cookies),
        token: _token,
        finalUrl: _finalUrl,
      );

  bool get isComplete => _completed;

  /// 当前是否已采到可用凭据（不依赖完成标记）：Token 规则看 [pollScript]
  /// 的返回值，Cookie 规则看 Cookie 名单是否齐备。
  bool get hasCapture {
    if (rule.pollScript != null) return _token?.isNotEmpty ?? false;
    return _cookiesReady;
  }

  /// 页面加载完成 / URL 变化时调用（页面回调里两处都调）。返回是否捕获完成。
  Future<bool> onPageEvent(InAppWebViewController controller, String url) async {
    if (_completed) return true;
    _finalUrl = url;
    if (rule.pollScript != null) {
      // Token 范式：轮询定时器负责采集，URL 只用于展示。
      startPolling(controller);
      return false;
    }
    final doneHit = rule.doneUrlPattern?.hasMatch(url) ?? false;
    await _readCookies(controller);
    // 声明 doneUrlPattern 时只在命中页采集完成（登录前落域名页不算）；
    // 未声明时 Cookie 齐了即算完成。登录页传 autoComplete=false 时一律
    // 不自动置位（见 [autoComplete] 注释），改由用户手动收口。
    if (autoComplete && _cookiesReady && (doneHit || rule.doneUrlPattern == null)) {
      _completed = true;
    }
    return _completed;
  }

  /// 用户手动点「我已登录完成」时调用：强制采集一次并收口。
  /// 返回当前是否已有可用凭据，供调用方决定是否进入落库。
  Future<bool> forceCapture(InAppWebViewController controller) async {
    if (_completed) return true;
    if (rule.pollScript != null) {
      await _pollToken(controller);
    } else {
      await _readCookies(controller);
    }
    if (autoComplete && _cookiesReady) _completed = true;
    return _completed || hasCapture;
  }

  void startPolling(InAppWebViewController controller) {
    _timer ??= Timer.periodic(
      Duration(milliseconds: rule.pollIntervalMs),
      (_) => _pollToken(controller),
    );
  }

  /// 落库失败后重置捕获会话：清空已捕获的 Cookie/Token 与完成标记，
  /// 并重启 Token 轮询。
  ///
  /// 完成标记一旦置位就永久锁死（[onPageEvent]/[forceCapture] 直接返回
  /// true，[forceCapture] 也不再重读），若首次捕获的是登录前首页残留的
  /// 游客凭据（如 UC 的 kps/sign、阿里本地留存的过期 refresh_token），
  /// completeLogin 的会话二次校验会失败并被锁死，用户无论如何操作都
  /// 无法完成绑定。重置后下一次页面事件或「我已登录完成」可重新采集。
  void restart(InAppWebViewController controller) {
    _completed = false;
    _cookies.clear();
    _token = null;
    dispose();
    if (rule.pollScript != null) startPolling(controller);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  bool get _cookiesReady {
    if (rule.cookieNames.isNotEmpty) {
      return rule.cookieNames
          .every((n) => (_cookies[n]?.isNotEmpty ?? false));
    }
    if (rule.cookieNamesAny.isNotEmpty) {
      return rule.cookieNamesAny
          .any((n) => (_cookies[n]?.isNotEmpty ?? false));
    }
    return _cookies.isNotEmpty;
  }

  /// 判断某 Cookie 是否属于本规则捕获范围（全匹配名单优先，
  /// 其次任一候选名单，两者都空则收全部）。
  bool _acceptCookie(String name) {
    if (rule.cookieNames.isNotEmpty) return rule.cookieNames.contains(name);
    if (rule.cookieNamesAny.isNotEmpty) {
      return rule.cookieNamesAny.contains(name);
    }
    return true;
  }

  /// 页面加载完成后注入辅助 JS（每次 onLoadStop 调用，页面重渲染后
  /// 再次辅助；best-effort，任何异常吞掉）。
  Future<void> maybeInjectJs(InAppWebViewController controller) async {
    final js = rule.injectJs;
    if (js == null || js.trim().isEmpty) return;
    await _evalJs(controller, js);
  }

  Future<void> _pollToken(InAppWebViewController controller) async {
    if (_completed) {
      dispose();
      return;
    }
    // Token 范式常伴随 Cookie 会话（如微云 openid + cookie），顺带采集。
    await _readCookies(controller);
    final v = await _evalJs(controller, '''
(() => {
  try {
    var t = (${rule.pollScript});
    return t == null ? "" : String(t);
  } catch (e) { return ""; }
})()''');
    if (v.isNotEmpty) {
      _token = v;
      // 自动收口（autoComplete=true）下捕获到 token 即完成并停轮询；
      // 手动收口（false）下持续刷新凭据，等用户点「我已登录完成」。
      if (autoComplete) {
        _completed = true;
        dispose();
      }
    }
  }

  Future<void> _readCookies(InAppWebViewController controller) async {
    // 优先原生 Cookie 通道（可读 httpOnly）。WebView 按域隔离 Cookie：
    // 按规则声明的域逐域读取，登录页停留在非目标域时也能读到目标域凭据；
    // 未声明域时退回当前页面 URL 的 host。
    final hosts = rule.cookieDomains
        .map((d) => d.trim())
        .where((d) => d.isNotEmpty)
        .toList();
    if (hosts.isEmpty) {
      final uri = Uri.tryParse(_finalUrl ?? '');
      if (uri != null && uri.host.isNotEmpty) hosts.add(uri.host);
    }
    for (final host in hosts) {
      try {
        final native = await CookieManager.instance().getCookies(
          url: WebUri('https://$host/'),
        );
        for (final cookie in native) {
          final k = cookie.name.trim();
          final v = cookie.value ?? '';
          if (v.isNotEmpty && _acceptCookie(k)) {
            _cookies[k] = v;
          }
        }
      } catch (_) {
        // 原生通道不可用：回退 JS document.cookie。
      }
    }
    // JS 通道补充（httpOnly 之外的 key，原生通道未覆盖时）。
    final raw = await _evalJs(controller, 'document.cookie');
    if (raw.isEmpty) return;
    for (final seg in raw.split(';')) {
      final eq = seg.indexOf('=');
      if (eq <= 0) continue;
      final k = seg.substring(0, eq).trim();
      final v = seg.substring(eq + 1).trim();
      if (v.isNotEmpty && _acceptCookie(k)) {
        _cookies[k] = v;
      }
    }
  }

  /// 执行 JS 并取字符串结果；平台可能给字符串加引号，剥掉。
  Future<String> _evalJs(InAppWebViewController controller, String expr) async {
    try {
      final r = await controller.evaluateJavascript(source: expr);
      var s = r?.toString() ?? '';
      if (s.length >= 2 &&
          ((s.startsWith('"') && s.endsWith('"')) ||
              (s.startsWith("'") && s.endsWith("'")))) {
        s = s.substring(1, s.length - 1);
      }
      return s;
    } catch (_) {
      return '';
    }
  }
}
