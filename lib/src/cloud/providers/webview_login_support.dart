// WebView 登录捕获支撑（XY 移植版：基于 flutter_inappwebview 6.x）。
//
// Cookie 采集优先走原生 CookieManager 通道（可读 httpOnly），失败回退
// JS `document.cookie`；Token 范式（阿里等）走 pollScript 注入轮询：
// 定时执行 JS 片段，返回非空字符串即视为 token 出现。

import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../cloud_types.dart';

class CloudWebviewCaptureSession {
  CloudWebviewCaptureSession(this.rule);

  final CloudCaptureRule rule;

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
    // 未声明时 Cookie 齐了即算完成。
    if (_cookiesReady && (doneHit || rule.doneUrlPattern == null)) {
      _completed = true;
    }
    return _completed;
  }

  /// 用户手动点「我已登录」强制采集一次（doneUrlPattern 未命中时的兜底）。
  Future<bool> forceCapture(InAppWebViewController controller) async {
    if (_completed) return true;
    if (rule.pollScript != null) {
      await _pollToken(controller);
    } else {
      await _readCookies(controller);
    }
    if (_cookiesReady) _completed = true;
    return _completed;
  }

  void startPolling(InAppWebViewController controller) {
    _timer ??= Timer.periodic(
      Duration(milliseconds: rule.pollIntervalMs),
      (_) => _pollToken(controller),
    );
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  bool get _cookiesReady =>
      rule.cookieNames.isEmpty
          ? _cookies.isNotEmpty
          : rule.cookieNames
              .every((n) => (_cookies[n]?.isNotEmpty ?? false));

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
      _completed = true;
      dispose();
    }
  }

  Future<void> _readCookies(InAppWebViewController controller) async {
    // 优先原生 Cookie 通道（可读 httpOnly）。
    final uri = Uri.tryParse(_finalUrl ?? '');
    if (uri != null && uri.host.isNotEmpty) {
      try {
        final native = await CookieManager.instance().getCookies(
          url: WebUri(uri.toString()),
        );
        if (native.isNotEmpty) {
          for (final cookie in native) {
            final k = cookie.name.trim();
            final v = cookie.value ?? '';
            if (v.isNotEmpty &&
                (rule.cookieNames.isEmpty || rule.cookieNames.contains(k))) {
              _cookies[k] = v;
            }
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
      if (v.isNotEmpty &&
          (rule.cookieNames.isEmpty || rule.cookieNames.contains(k))) {
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
