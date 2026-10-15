// 移动云盘（139）provider（webviewCookie：登录页捕获 authorization Cookie）。
//
// 2024 年底 139 迁移「新个人云」：旧 orchestration 接口已失效，个人盘
// 列表/直链走 personal-kd-njs.yun.139.com 新网关，需 calSign 签名 +
// Authorization 头（与 AList 139 driver 同源）。分享仍走 share-kd-njs
// 外链接口，免转存直链（directPlayable=true）。

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_types.dart';
import '../share_link_parser.dart';
import 'http_login_support.dart';

class Mobile139Provider extends CloudProvider {
  const Mobile139Provider();

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static const _mcloudVersion = '7.14.0';

  /// JS encodeURIComponent 等价实现（Dart Uri.encodeComponent 转义集与
  /// 浏览器不一致，签名必须逐字节对齐浏览器行为）。
  static String _encUri(String s) {
    const safe =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()";
    final sb = StringBuffer();
    final bytes = utf8.encode(s);
    for (final b in bytes) {
      final c = String.fromCharCode(b);
      if (safe.contains(c)) {
        sb.write(c);
      } else {
        sb.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return sb.toString();
  }

  /// 139 calSign：encodeURIComponent(body) 逐字符排序 → base64 →
  /// MD5(base64) + MD5('ts:rand') → MD5 合并结果（大写）。
  /// 签名头：mcloud-sign = `ts,rand,sign`（与 AList 139 driver 一致）。
  static String _calSign(String body, String ts, String randStr) {
    final enc = _encUri(body);
    final chars = enc.split('')..sort();
    final sorted = chars.join();
    final b64 = base64Encode(utf8.encode(sorted));
    final md5A = md5.convert(utf8.encode(b64)).toString();
    final md5B = md5.convert(utf8.encode('$ts:$randStr')).toString();
    return md5.convert(utf8.encode(md5A + md5B)).toString().toUpperCase();
  }

  /// 本地时区 'YYYY-MM-DD HH:mm:ss'（签名与服务器时间戳对齐）。
  static String _tsNow() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  /// 随机串 16 位（与 AList personalRequest random.String(16) 对齐）。
  static String _randStr() {
    final rnd = Random();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final sb = StringBuffer();
    for (var i = 0; i < 16; i++) {
      sb.write(chars[rnd.nextInt(chars.length)]);
    }
    return sb.toString();
  }

  /// 从 cookie 提取 authorization 值并补 Basic 前缀。
  static String _authValue(String cookie) {
    final m = RegExp(r'(?:^|;\s*)authorization=([^;]+)', caseSensitive: false)
        .firstMatch(cookie);
    if (m == null) return '';
    var v = m.group(1)!.trim();
    if (v.isNotEmpty && !v.toLowerCase().startsWith('basic')) {
      v = 'Basic $v';
    }
    return v;
  }

  /// 个人云网关请求头：sign=true 时附加 calSign 签名与 mcloud/X-Yun 头族
  /// （对齐 AList 139 driver personalRequest），并透传 authorization 作为
  /// Authorization（share 外链域 sign=false）。
  Map<String, String> _h(String cookie, String body, {bool sign = true}) {
    final headers = <String, String>{
      'User-Agent': _ua,
      'Referer': 'https://yun.139.com/w/',
      'Accept': 'application/json, text/plain, */*',
      'Origin': 'https://yun.139.com',
      if (cookie.isNotEmpty) 'Cookie': cookie,
      'Content-Type': 'application/json;charset=UTF-8',
    };
    final auth = _authValue(cookie);
    if (auth.isNotEmpty) headers['Authorization'] = auth;
    if (sign) {
      final ts = _tsNow();
      final rand = _randStr();
      headers['mcloud-sign'] = '$ts,$rand,${_calSign(body, ts, rand)}';
      headers['mcloud-version'] = _mcloudVersion;
      headers['mcloud-channel'] = '1000101';
      headers['mcloud-client'] = '10701';
      headers['Caller'] = 'web';
      headers['Mcloud-Route'] = '001';
      headers['x-SvcType'] = '1';
      headers['CMS-DEVICE'] = 'default';
      headers['x-DeviceInfo'] =
          '||9|7.14.0|chrome|120.0.0.0|||windows 10||zh-CN|||';
      headers['x-huawei-channelSrc'] = '10000034';
      headers['x-inner-ntwk'] = '2';
      headers['x-m4c-caller'] = 'PC';
      headers['x-m4c-src'] = '10002';
      headers['X-Yun-Api-Version'] = 'v1';
      headers['X-Yun-App-Channel'] = '10000034';
      headers['X-Yun-Channel-Source'] = '10000034';
      headers['X-Yun-Client-Info'] =
          '||13|7.14.0|chrome|120.0.0.0|||windows 10||zh-CN|||dW5kZWZpbmVk||';
      headers['X-Yun-Module-Type'] = '100';
      headers['X-Yun-Svc-Type'] = '1';
    }
    return headers;
  }

  @override
  String get id => 'mobile139';

  @override
  String get displayName => '移动云盘';

  @override
  String get rootPath => 'root';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewCookie;

  @override
  String get webviewLoginUrl => 'https://yun.139.com/login';

  @override
  CloudCaptureRule? get captureRule => CloudCaptureRule(
        // 只认 authorization 会话凭据（未登录首页也会种匿名 cookie，
        // 全收会在首屏即误判登录成功），完成后再由 validate 二次校验。
        cookieNames: ['authorization'],
        doneUrlPattern: RegExp(r'yun\.139\.com'),
        pollIntervalMs: 500,
        // 短信登录页初始「获取验证码/登录」按钮常被 disabled（需先勾选
        // 协议）。注入 JS：①自动勾选 checkbox 并解除按钮 disabled；②补齐/
        // 改写 meta viewport 与放开 html/body 横向溢出，消除「页面无法右移、
        // 按钮被右侧遮挡」；③内容宽度明显大于视口时按比例缩小 initial-scale，
        // 让最右侧「获取验证码/登录」按钮进入可视区（best-effort）。
        injectJs: r'''
(() => {
  try {
    var checkAll = function () {
      document.querySelectorAll('input[type="checkbox"]').forEach(function (cb) {
        if (cb && !cb.checked) {
          try {
            var proto = Object.getPrototypeOf(cb);
            var desc = Object.getOwnPropertyDescriptor(proto, 'checked');
            if (desc && desc.set) { desc.set.call(cb, true); }
          } catch (_) {}
          cb.click();
          cb.dispatchEvent(new Event('change', { bubbles: true }));
        }
      });
    };
    checkAll();
    document.querySelectorAll('button[disabled], input[disabled], a[disabled]').forEach(function (el) {
      if (el && el.disabled) { el.disabled = false; }
    });

    // 补齐/改写 viewport：缺少或写死会限制布局视口，导致右侧按钮溢出不可见。
    var setViewport = function (scale) {
      var content = 'width=device-width, initial-scale=' + (scale || '1.0') +
        ', maximum-scale=5.0, viewport-fit=cover';
      var vp = document.querySelector('meta[name="viewport"]');
      if (vp) {
        vp.setAttribute('content', content);
      } else {
        var m = document.createElement('meta');
        m.name = 'viewport';
        m.content = content;
        document.head.appendChild(m);
      }
    };
    setViewport();

    // 放开 html/body 及常见框架容器的横向溢出限制，允许向右滚动。
    var fixOverflow = function () {
      ['html', 'body'].forEach(function (sel) {
        var el = document.querySelector(sel);
        if (el) {
          el.style.overflowX = 'auto';
          el.style.overflowY = 'auto';
          el.style.width = 'auto';
        }
      });
      document.querySelectorAll('#app, .app, .page, .container, .content, .wrap, .main').forEach(function (el) {
        if (el) {
          el.style.overflowX = 'auto';
          el.style.maxWidth = 'none';
        }
      });
    };
    fixOverflow();

    // 内容明显宽于视口时，按比例缩小 initial-scale，让最右侧按钮进入可视区。
    var fitScale = function () {
      var doc = document.documentElement;
      var vw = window.innerWidth || doc.clientWidth || 0;
      var sw = doc.scrollWidth || (document.body ? document.body.scrollWidth : 0) || 0;
      if (vw > 0 && sw > vw + 20) {
        var zoom = Math.max(0.5, Math.min(1, vw / sw));
        setViewport(zoom.toFixed(3));
      }
    };
    fitScale();
    var tries = 0;
    var iv = setInterval(function () {
      tries += 1;
      fitScale();
      if (tries >= 10) clearInterval(iv);
    }, 500);
  } catch (_) {}
})()
''',
      );

  // ── 登录 ──────────────────────────────────────────────

  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) async {
    final cookie = cookieHeader(captured.cookies);
    if (cookie.isEmpty) {
      throw const CloudException('未捕获到登录凭据，请重新登录');
    }
    // 会话有效性二次校验：捕获到 authorization Cookie 并不代表会话
    // 有效（可能过期/伪凭据）。校验失败则拒绝绑定，停留在登录页，
    // 确保「实际登录成功（Cookie/会话可验证）后才跳转持久化」。
    if (!await validate({'cookie': cookie})) {
      throw const CloudException('登录态校验失败，请确认已完成登录后重试');
    }
    return CloudAccount(
      provider: id,
      accountId: md5Hex(cookie).substring(0, 12),
      nickname: '移动云盘',
      cred: {'cookie': cookie},
      boundAt: DateTime.now(),
    );
  }

  @override
  Future<bool> validate(Map<String, String> cred) async {
    try {
      final body = _listBody('/');
      final resp = await cloudPostJson(
        'https://personal-kd-njs.yun.139.com/hcy/file/list',
        body: body,
        headers: _h(cred['cookie'] ?? '', jsonEncode(body)),
      );
      if (!resp.isOk) return false;
      return resp.json['success'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 新个人云列表请求体（parentFileId：根目录 '/'，子目录用父 fileId）。
  Map<String, dynamic> _listBody(String parentFileId) => {
        'imageThumbnailStyleList': ['Small', 'Large'],
        'orderBy': 'updated_at',
        'orderDirection': 'DESC',
        'pageInfo': {'pageCursor': '', 'pageSize': 100},
        'parentFileId': parentFileId,
      };

  // ── 目录 ──────────────────────────────────────────────

  @override
  Future<CloudListResult> listDir(
    Map<String, String> cred,
    String path, {
    String? cursor,
  }) async {
    final parent = path == 'root' || path.isEmpty ? '/' : path;
    final body = _listBody(parent);
    final resp = await cloudPostJson(
      'https://personal-kd-njs.yun.139.com/hcy/file/list',
      body: body,
      headers: _h(cred['cookie'] ?? '', jsonEncode(body)),
    );
    if (!resp.isOk) throw const CloudException('目录列表请求失败');
    final data = resp.json['data'];
    final list = data is Map<String, dynamic>
        ? (data['items'] as List?) ??
            (data['fileList'] as List?) ??
            const []
        : const [];
    final nextCursor = data is Map<String, dynamic>
        ? (data['nextPageCursor'] ?? '').toString()
        : '';
    final files = <CloudFile>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      final rawType = (e['fileType'] ?? e['type'] ?? e['category'] ?? '')
          .toString()
          .toLowerCase();
      final isCatalog = e['isCatalog'] == true ||
          (e['isCatalog'] is num && (e['isCatalog'] as num) == 1);
      files.add(CloudFile(
        id: (e['fileId'] ?? e['contentId'] ?? '').toString(),
        name: (e['name'] ?? e['contentName'] ?? '').toString(),
        isDir: isCatalog || rawType == 'folder' || rawType == 'dir',
        size: num.tryParse((e['size'] ?? e['contentSize'] ?? '').toString())
                ?.toInt() ??
            0,
        parentId: (e['parentFileId'] ?? path).toString(),
      ));
    }
    final hasNext = nextCursor.isNotEmpty && files.isNotEmpty;
    return CloudListResult(
      files: files,
      nextCursor: hasNext ? nextCursor : null,
    );
  }

  // ── 分享 ──────────────────────────────────────────────

  @override
  Future<CloudShareParse> parseShareLink(String url, String? pwd) async {
    final info = parseUrlToProvider(url);
    final guid = info?.shareId ?? url;
    final resp = await cloudPostJson(
      'https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/'
      'IOutLink/getOutLinkInfoV6',
      body: {
        'outLinkGUID': guid,
        'passcode': pwd ?? '',
      },
      headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
    );
    if (!resp.isOk) throw const CloudException('分享链接解析失败');
    final data = resp.json['data'];
    final outLink = data is Map<String, dynamic>
        ? data['outLinkInfo'] as Map<String, dynamic>?
        : null;
    final list =
        (outLink?['fileList'] as List?) ?? const [];
    if (list.isEmpty) throw const CloudException('分享已失效');
    final files = <CloudFile>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['contentId'] ?? '').toString(),
        name: (e['contentName'] ?? '').toString(),
        isDir: (e['isCatalog'] as num?)?.toInt() == 1,
        size: (e['contentSize'] as num?)?.toInt() ?? 0,
      ));
    }
    return CloudShareParse(
      providerId: id,
      files: files,
      shareId: guid,
      passcode: pwd,
      directPlayable: true,
    );
  }

  /// 分享免转存直链（dlFromOutLinkV3）。
  @override
  Future<CloudDirectLink> getShareDirectLink(
    Map<String, String>? cred,
    CloudShareParse share,
    CloudFile file,
  ) async {
    final resp = await cloudPostJson(
      'https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/'
      'IOutLink/dlFromOutLinkV3',
      body: {
        'outLinkGUID': share.shareId,
        'passcode': share.passcode ?? '',
        'fileIds': [file.id],
      },
      headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
    );
    if (!resp.isOk) throw const CloudException('分享直链获取失败');
    final data = resp.json['data'];
    final fileList = data is Map<String, dynamic>
        ? (data['fileList'] as List?) ?? const []
        : const [];
    if (fileList.isEmpty) throw const CloudException('分享直链获取失败');
    final url = ((fileList.first as Map<String, dynamic>)['downloadUrl'] ?? '')
        .toString();
    if (url.isEmpty) throw const CloudException('分享直链获取失败');
    return CloudDirectLink(
      url: url,
      headers: {'User-Agent': _ua},
      fileName: file.name,
      size: file.size,
      expireAt: DateTime.now().add(const Duration(minutes: 30)),
    );
  }

  /// best-effort 转存（139 分享本可直链，转存作为留档兜底）。
  @override
  Future<List<CloudFile>> transferShareFiles(
    Map<String, String> cred,
    CloudShareParse share,
  ) async {
    try {
      await cloudPostJson(
        'https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/'
        'IBatchOprTask/createOuterLinkBatchOprTask',
        body: {
          'outLinkGUID': share.shareId,
          'passcode': share.passcode ?? '',
          'taskType': 2,
          'fileIds': share.files.map((f) => f.id).toList(),
        },
        headers: _h(cred['cookie'] ?? '', '', sign: false),
      );
    } catch (_) {}
    return share.files;
  }

  // ── 直链 ──────────────────────────────────────────────

  @override
  Future<CloudDirectLink> getDirectLink(
      Map<String, String> cred, CloudFile file) async {
    final body = {'fileId': file.id};
    final resp = await cloudPostJson(
      'https://personal-kd-njs.yun.139.com/hcy/file/getDownloadUrl',
      body: body,
      headers: _h(cred['cookie'] ?? '', jsonEncode(body)),
    );
    if (!resp.isOk) throw const CloudException('直链获取失败');
    final data = resp.json['data'];
    final url = data is Map<String, dynamic>
        ? ((data['cdnUrl'] ?? data['url'] ?? data['downloadUrl'] ?? '')
                .toString())
        : '';
    if (url.isEmpty) throw const CloudException('直链获取失败');
    return CloudDirectLink(
      url: url,
      headers: {'User-Agent': _ua},
      fileName: file.name,
      size: file.size,
      expireAt: DateTime.now().add(const Duration(minutes: 30)),
    );
  }
}
