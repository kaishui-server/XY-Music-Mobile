import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/settings.dart';
import '../../src/music_platform/platform_api.dart';
import '../../src/music_platform/platform_session.dart';
import '../../src/ui/xy_surface.dart';
import '../../src/widgets/top_notice.dart';

/// 通用第三方平台网页登录页（仿 lx-lxwalnut-music-mobile 的
/// WebLoginModal：WebView 打开平台登录页，登录成功后经原生
/// CookieManager 提取 httpOnly Cookie 构造账号）。
///
/// - 网易：music.163.com/m/login，登录后跳回站内页，提取 MUSIC_U
///   经 /api/nuser/account/get 验证并取昵称头像。
/// - QQ：QQ音乐官方网页登录页（桌面 UA），登录由官方页面自身驱动，
///   成功后 uin/qm_keyst 直接落在 y.qq.com 域，轮询提取即可
///   （对齐 lx-lxwalnut 的 QQWebLoginModal：打开
///   y.qq.com/n/ryqq/login + 桌面 Chrome UA，不构造 ptlogin 链）。
/// - 酷狗：www.kugou.com 网页登录（桌面 UA，右上角登录弹窗），登录为
///   AJAX 弹窗、无页面跳转，靠周期性 cookie 探测捕获
///   KugouID/KugouToken（新版为 userid/token）。
///
/// 探测策略：导航事件 + 2 秒周期轮询双保险，覆盖重定向链与 SPA 弹窗
/// 两种登录形态。
class WebLoginPage extends ConsumerStatefulWidget {
  const WebLoginPage({super.key, required this.platform});

  final MusicPlatform platform;

  @override
  ConsumerState<WebLoginPage> createState() => _WebLoginPageState();
}

class _WebLoginPageState extends ConsumerState<WebLoginPage> {
  bool _finishing = false;
  String? _error;
  Timer? _probeTimer;
  InAppWebViewController? _webController;

  // 登录入口 URL 按平台区分。
  String get _loginUrl => switch (widget.platform) {
    MusicPlatform.netease => 'https://music.163.com/m/login',
    // QQ 音乐官方网页登录页（扫码/账密均可）。不能自构造 ptlogin
    // xlogin 链：那条链登录后的换票跳转依赖浏览器环境，极易断
    // （「换票跳转后网页加载失败」）；官方页面自身驱动登录，
    // 凭据稳定落在 y.qq.com 域。
    MusicPlatform.qq => 'https://y.qq.com/n/ryqq/login',
    // 酷狗网页播放器：右上角入口打开登录弹窗（扫码/手机验证码）。
    MusicPlatform.kugou => 'https://www.kugou.com',
  };

  /// 按平台定 UA：
  /// - 网易：不覆写，用系统 WebView 默认 UA。硬编码旧版 UA 会与
  ///   实际内核特征不符，触发网易风控「检测到当前设备环境异常」。
  /// - QQ：桌面 UA（对齐 lx-lxwalnut，其已在真机验证可用）。
  ///   移动 UA 会被 y.qq.com 重定向到移动版页面，登录形态不可控。
  /// - 酷狗：桌面 UA，避免 www.kugou.com 被重定向到移动版、
  ///   登录 cookie 落到其他域导致探测失败。
  String? get _userAgent => switch (widget.platform) {
    MusicPlatform.netease => null,
    MusicPlatform.qq =>
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/120.0.0.0 Safari/537.36',
    MusicPlatform.kugou =>
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/133.0.0.0 Safari/537.36',
  };

  @override
  void initState() {
    super.initState();
    // 网易：进入登录页前清除本域旧 cookie，避免残留的风控状态
    // （如安全拦截标记）导致再次登录直接被拦。
    if (widget.platform == MusicPlatform.netease) {
      CookieManager.instance().deleteCookies(
        url: WebUri('https://music.163.com'),
      );
    }
    // 酷狗登录是 AJAX 弹窗，登录完成后没有页面导航事件；
    // 轮询原生 cookie 以捕获登录态（对网易/QQ 也无害）。
    _probeTimer = Timer.periodic(const Duration(seconds: 2), (_) => _probe());
  }

  @override
  void dispose() {
    _probeTimer?.cancel();
    super.dispose();
  }

  /// 从原生 CookieManager 提取相关域的全部 cookie（含 httpOnly）。
  Future<Map<String, String>> _extractCookies() async {
    final result = <String, String>{};
    // 登录 cookie 可能落在多个域，逐个尝试。
    final urls = switch (widget.platform) {
      MusicPlatform.netease => ['https://music.163.com'],
      MusicPlatform.qq => [
        'https://y.qq.com',
        'https://graph.qq.com',
        'https://ptlogin2.qq.com',
      ],
      MusicPlatform.kugou => [
        'https://www.kugou.com',
        'https://login-user.kugou.com',
        'https://login.user.kugou.com',
        'https://userservice.kugou.com',
        'https://m.kugou.com',
      ],
    };
    for (final url in urls) {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri(url),
      );
      for (final cookie in cookies) {
        final name = cookie.name;
        final value = cookie.value;
        if (name.isEmpty || value.isEmpty) continue;
        // 后提取的域覆盖同名（更具体的登录域优先级靠后放置）。
        result[name] = value;
      }
    }
    return result;
  }

  bool _hasCredentials(Map<String, String> cookies) =>
      switch (widget.platform) {
        MusicPlatform.netease => (cookies['MUSIC_U'] ?? '').isNotEmpty,
        MusicPlatform.qq =>
          (cookies['uin'] ?? '').isNotEmpty &&
              (cookies['qm_keyst'] ?? '').isNotEmpty,
        MusicPlatform.kugou =>
          (cookies['KugouID'] ?? cookies['userid'] ?? '').isNotEmpty &&
              (cookies['KugouToken'] ?? cookies['token'] ?? '').isNotEmpty,
      };

  /// 周期探测：cookie 齐备即完成登录。
  Future<void> _probe() async {
    if (_finishing) return;
    final cookies = await _extractCookies();
    if (!mounted || _finishing) return;
    if (!_hasCredentials(cookies)) return;
    await _finishWithCookies(cookies);
  }

  /// 手动保存：网页端登录已成功、但自动探测未捕获时的兜底。
  ///
  /// 强制提取一次 cookie 并保存；QQ 额外尝试从当前页 URL 提取授权
  /// code。失败时给出具体缺失项与已检测到的 cookie 名，便于诊断。
  Future<void> _manualSave() async {
    if (_finishing) return;
    final cookies = await _extractCookies();
    if (!mounted) return;
    if (_hasCredentials(cookies)) {
      await _finishWithCookies(cookies);
      return;
    }
    // QQ：授权终点页 URL 可能仍带着 code，尝试直接换取凭据。
    if (widget.platform == MusicPlatform.qq) {
      final url = await _webController?.getUrl();
      final code = url == null
          ? ''
          : Uri.tryParse(url.toString())?.queryParameters['code'] ?? '';
      if (code.isNotEmpty) {
        await _finishWithAccount(() => QqMusicApi().loginByQqCode(code));
        return;
      }
    }
    setState(() => _error = _missingHint(cookies));
  }

  /// 构造“缺少关键 Cookie”的诊断提示。
  String _missingHint(Map<String, String> cookies) {
    final required = switch (widget.platform) {
      MusicPlatform.netease => 'MUSIC_U',
      MusicPlatform.qq => 'uin / qm_keyst',
      MusicPlatform.kugou => 'KugouID / KugouToken（或 userid / token）',
    };
    final names = cookies.keys.toList()..sort();
    final found = names.isEmpty ? '（无）' : names.take(12).join(', ');
    return '未检测到登录 Cookie（需要 $required），请先在上方页面完成登录'
        '再点保存。当前检测到：$found';
  }
  /// 导航事件：QQ 优先捕获授权 code；其余靠 cookie 判定。
  Future<void> _onNavigation(String url) async {
    if (_finishing) return;
    // QQ 授权链终点：redirect.html?loginType=2&code=xxx。
    // 用 code 走 musicu.fcg 换取凭据，比等 cookie 落盘更可靠。
    if (widget.platform == MusicPlatform.qq &&
        url.contains('y.qq.com/portal/redirect')) {
      final code = Uri.tryParse(url)?.queryParameters['code'] ?? '';
      if (code.isNotEmpty) {
        await _finishWithAccount(() => QqMusicApi().loginByQqCode(code));
        return;
      }
    }
    await _probe();
  }

  Future<void> _finishWithCookies(Map<String, String> cookies) async {
    await _finishWithAccount(
      () => switch (widget.platform) {
        // MUSIC_U 换取 uid/昵称/头像；顺带验证 cookie 有效性。
        MusicPlatform.netease => NeteaseApi().fetchAccount(cookies),
        MusicPlatform.qq => Future.value(
          QqMusicApi().accountFromWebCookie(cookies),
        ),
        MusicPlatform.kugou => Future.value(
          KugouApi().accountFromWebCookie(cookies),
        ),
      },
    );
  }

  Future<void> _finishWithAccount(
    Future<MusicPlatformAccount?> Function() build,
  ) async {
    if (_finishing) return;
    _finishing = true;
    if (mounted) setState(() {});
    MusicPlatformAccount? account;
    Object? error;
    try {
      account = await build();
    } on Exception catch (e) {
      error = e;
    }
    if (!mounted) return;
    if (account == null) {
      _finishing = false;
      setState(() {
        _error = error is PlatformApiException
            ? '登录信息提取失败：${error.message}'
            : '登录信息提取失败，请重试';
      });
      return;
    }
    await ref
        .read(musicPlatformSessionsProvider.notifier)
        .saveAccount(account);
    if (!mounted) return;
    Navigator.of(context).pop(account);
    XyNotice.show(
      context,
      message: '${widget.platform.label}登录成功：${account.nickname}',
      type: XyNoticeType.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final backgroundSettings = ref.watch(
      settingsProvider.select(
        (value) => (
          path: value.valueOrNull?.customBackgroundPath ?? '',
          blur: value.valueOrNull?.customBackgroundBlur ?? 18.0,
          fade: value.valueOrNull?.customBackgroundFade ?? 0.0,
        ),
      ),
    );
    return XyAppBackground(
      // 覆盖路由自带不透明背景：转场期间完全遮挡下层页面，
      // 避免透明 Scaffold 造成“两页叠加”。
      imagePath: backgroundSettings.path,
      blur: backgroundSettings.blur,
      fade: backgroundSettings.fade,
      child: Scaffold(
        appBar: AppBar(
          leading: const BackButton(),
          title: Text('登录${widget.platform.label}'),
          centerTitle: true,
        ),
        body: Column(
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: scheme.error, fontSize: 13),
                ),
              ),
            Expanded(
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(_loginUrl)),
                initialSettings: InAppWebViewSettings(
                  // UA 按平台区分：网易用系统默认（防风控），
                  // QQ/酷狗桌面版，详见 [_userAgent]。
                  userAgent: _userAgent,
                  // QQ/网易的登录框是跨域 iframe（xui.ptlogin2 等），
                  // iframe 内种登录 cookie 依赖第三方 cookie 放行。
                  thirdPartyCookiesEnabled: true,
                  // 登录页为 HTTPS，但 QQ/酷狗的静态资源与登录接口
                  // 大量走 HTTP（imgcache.qq.com、login.user.kugou.com），
                  // WebView 默认拦截混合内容会导致二维码失效、
                  // 登录接口失败、换票链路中断，必须放行。
                  mixedContentMode:
                      MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                  supportZoom: false,
                  transparentBackground: true,
                ),
                onWebViewCreated: (controller) =>
                    _webController = controller,
                onLoadStop: (controller, url) {
                  if (url == null) return;
                  _onNavigation(url.toString());
                },
              ),
            ),
            // 手动保存兜底：自动探测未触发时，用户登录完成后点击保存。
            SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              top: false,
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _finishing ? null : _manualSave,
                  icon: _finishing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_rounded),
                  label: Text(_finishing ? '正在保存…' : '已完成登录，保存登录信息'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
