import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../src/cloud/cloud_credentials_store.dart';
import '../../src/cloud/cloud_provider.dart';
import '../../src/cloud/cloud_registry.dart';
import '../../src/cloud/cloud_types.dart';
import '../../src/cloud/providers/webview_login_support.dart';
import '../../src/cloud/cloud_ui.dart';

/// WebView 网盘登录页（webviewCookie / webviewToken 范式）。
///
/// 页面只做装配：WebViewController + CloudWebviewCaptureSession；
/// Cookie/Token 捕获节奏由 provider 声明的 [CloudCaptureRule] 决定。
class CloudWebviewLoginPage extends StatefulWidget {
  const CloudWebviewLoginPage({super.key, required this.providerId});

  final String providerId;

  @override
  State<CloudWebviewLoginPage> createState() => _CloudWebviewLoginPageState();
}

class _CloudWebviewLoginPageState extends State<CloudWebviewLoginPage> {
  late final CloudProvider _provider;
  InAppWebViewController? _controller;
  late final CloudWebviewCaptureSession _session;

  /// 文档开始注入的用户脚本（provider 声明时才有）：用于安装必须先于
  /// 页面脚本运行的前提钩子（如采集页面真实请求头）。
  UnmodifiableListView<UserScript>? _userScripts;

  /// 登录页 User-Agent 覆盖（provider 声明时才有）：部分网盘按 UA 判定
  /// 平台，移动 UA 打开登录页会被重定向回首页营销页（无登录入口），必须
  /// 用桌面 UA 才会停留在登录页并内嵌官方登录 iframe。
  InAppWebViewSettings? _settings;
  bool _finishing = false;
  bool _pageLoaded = false;

  @override
  void initState() {
    super.initState();
    _provider = cloudProviderById(widget.providerId)!;
    // autoComplete=false：登录一律由用户点「我已登录完成」收口。
    // 解绑后二次登录时 WebView 仍残留上一次会话（Cookie / localStorage），
    // 自动采集会把**旧账号**立刻当成新登录结果绑回去（表现为没让用户
    // 重新登录就直接返回）。手动收口与百度网盘行为一致。
    _session = CloudWebviewCaptureSession(
      _provider.captureRule ?? const CloudCaptureRule(),
      autoComplete: false,
    );
    final us = _provider.captureRule?.userScript;
    _userScripts = (us == null || us.trim().isEmpty)
        ? null
        : UnmodifiableListView<UserScript>([
            UserScript(
              source: us,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
            ),
          ]);
    final ua = _provider.webviewLoginUserAgent.trim();
    _settings = ua.isEmpty ? null : InAppWebViewSettings(userAgent: ua);
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  /// 页面加载 / URL 变化时触发一次采集：仅刷新当前凭据与最后 URL，
  /// **不**自动收口（收口由用户点「我已登录完成」触发）。
  Future<void> _onUrl(String url) async {
    try {
      final c = _controller;
      if (c == null) return;
      await _session.onPageEvent(c, url);
    } catch (_) {
      // 单次采集异常不打断登录流程，等下一次页面事件。
    }
  }

  Future<void> _finishLogin() async {
    if (_finishing || !mounted) return;
    _finishing = true;
    if (mounted) setState(() {});
    try {
      final account = await _provider.completeLogin(_session.result());
      await CloudCredentialsStore.instance.saveAccount(account);
      if (!mounted) return;
      showXianYuToast(context, cloudT('绑定成功'));
      context.pop();
    } catch (e) {
      AppLog.warn('cloud', '${_provider.id} 登录捕获失败: $e');
      // 落库失败（多为会话二次校验未通过——捕获到的是登录前残留的游客
      // 凭据）重置捕获会话：清空已采到的 Cookie/Token，用户重新登录后
      // 再次点「我已登录完成」可重新采集。
      final c = _controller;
      if (c != null) _session.restart(c);
      if (!mounted) return;
      showXianYuToast(
        context,
        e is CloudException ? e.message : cloudT('登录信息捕获失败，请重试'),
      );
      setState(() => _finishing = false);
    }
  }

  Future<void> _forceCapture() async {
    if (_finishing) return;
    final c = _controller;
    if (c == null) return;
    final done = await _session.forceCapture(c);
    if (done) {
      _finishLogin();
    } else if (mounted) {
      showXianYuToast(context, cloudT('未捕获到登录信息，请先完成登录'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          GlassTopBar(
            leading: const BackButton(),
            title: Text(_provider.displayName),
            actions: [
              PressableScale(
                pressScale: 0.92,
                child: TextButton(
                  onPressed: _finishing ? null : _forceCapture,
                  child: Text(cloudT('我已登录完成')),
                ),
              ),
            ],
          ),
          Expanded(
            child: Stack(
              children: [
                InAppWebView(
                  initialUrlRequest: URLRequest(
                    url: WebUri(_provider.webviewLoginUrl),
                  ),
                  initialUserScripts: _userScripts,
                  initialSettings: _settings,
                  onWebViewCreated: (c) => _controller = c,
                  onLoadStop: (c, uri) {
                    if (mounted) setState(() => _pageLoaded = true);
                    // 页面加载后注入辅助 JS（勾选协议/启用按钮等，best-effort）。
                    unawaited(_session.maybeInjectJs(c));
                    if (uri != null) _onUrl(uri.toString());
                  },
                  // 各网盘登录页基本都是 SPA：路由变化不触发 onLoadStop，
                  // 只有 onUpdateVisitedHistory 能感知。此回调用于同步最后
                  // URL 并按需启动 Token 轮询，让手动收口时取到的是最新凭据。
                  onUpdateVisitedHistory: (c, uri, isReload) {
                    if (uri != null) _onUrl(uri.toString());
                  },
                  onReceivedError: (c, req, err) {},
                ),
                if (!_pageLoaded)
                  const Center(child: CircularProgressIndicator()),
                if (_finishing)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.35),
                      child: const Center(
                        child: CircularProgressIndicator(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
