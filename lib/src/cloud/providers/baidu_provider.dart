// 百度网盘 provider（webviewCookie：BDUSS/STOKEN）。
//
// 注意：分享列表/转存接口必须带登录态（BDUSS），故 parseShareLink 内
// 直接读本地绑定凭据；转存的 sekey 是 verify 换来的 randsk（BDCLND），
// 不是提取码本身。

import 'dart:convert';

import '../cloud_credentials_store.dart';
import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_types.dart';
import '../share_link_parser.dart';
import 'http_login_support.dart';

class BaiduProvider extends CloudProvider {
  const BaiduProvider();

  static const _appId = '250528';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  Map<String, String> _h(Map<String, String> cred) => {
        'User-Agent': _ua,
        'Referer': 'https://pan.baidu.com/disk/main',
        'Cookie': cookieHeader(cred),
      };

  @override
  String get id => 'baidu';

  @override
  String get displayName => '百度网盘';

  @override
  String get rootPath => '/';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewCookie;

  @override
  Duration get directLinkTtl => const Duration(hours: 8);

  @override
  String get webviewLoginUrl => 'https://pan.baidu.com/';

  @override
  CloudCaptureRule? get captureRule => CloudCaptureRule(
        cookieNames: const ['BDUSS', 'STOKEN'],
        cookieDomains: const ['pan.baidu.com'],
        doneUrlPattern: RegExp(r'pan\.baidu\.com/(disk|main|share)'),
        pollIntervalMs: 500,
      );

  // ── 登录 ──────────────────────────────────────────────

  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) async {
    final bduss = captured.cookies['BDUSS'];
    if (bduss == null || bduss.isEmpty) {
      throw const CloudException('未捕获到登录凭据，请重新登录');
    }
    return CloudAccount(
      provider: id,
      accountId: md5Hex(bduss).substring(0, 12),
      nickname: '百度账号',
      cred: captured.cookies,
      boundAt: DateTime.now(),
    );
  }

  @override
  Future<bool> validate(Map<String, String> cred) async {
    try {
      final resp = await cloudGet(
        'https://pan.baidu.com/api/quota?checkfree=1&checkexpire=1'
        '&clienttype=0&app_id=$_appId&web=1',
        headers: _h(cred),
      );
      if (!resp.isOk) return false;
      return (resp.json['errno'] as num?)?.toInt() == 0;
    } catch (_) {
      return false;
    }
  }

  // ── 目录 ──────────────────────────────────────────────

  @override
  Future<CloudListResult> listDir(
    Map<String, String> cred,
    String path, {
    String? cursor,
  }) async {
    final page = int.tryParse(cursor ?? '') ?? 1;
    final dir = path == '/' ? '/' : path;
    final resp = await cloudGet(
      'https://pan.baidu.com/api/list?clienttype=0&app_id=$_appId&web=1'
      '&order=name&desc=0&dir=${Uri.encodeQueryComponent(dir)}'
      '&limit=100&page=$page',
      headers: _h(cred),
    );
    if (!resp.isOk) throw const CloudException('目录列表请求失败');
    final errno = (resp.json['errno'] as num?)?.toInt();
    if (errno != 0) throw const CloudException('目录列表请求失败');
    final list = (resp.json['list'] as List?) ?? const [];
    final files = <CloudFile>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['fs_id'] ?? '').toString(),
        name: (e['server_filename'] ?? '').toString(),
        isDir: (e['isdir'] as num?)?.toInt() == 1,
        size: (e['size'] as num?)?.toInt() ?? 0,
        parentId: (e['parent_path'] ?? '').toString(),
        path: (e['path'] ?? '').toString(),
      ));
    }
    final hasNext = files.length >= 100;
    return CloudListResult(
      files: files,
      nextCursor: hasNext ? '${page + 1}' : null,
    );
  }

  // ── 分享 ──────────────────────────────────────────────

  @override
  Future<CloudShareParse> parseShareLink(String url, String? pwd) async {
    final info = parseUrlToProvider(url);
    final surl = info?.shareId ?? url;
    // verify 换 randsk（BDCLND）；无提取码的分享 verify 也走一遍拿空 sekey。
    var randsk = '';
    final verifyResp = await cloudPostForm(
      'https://pan.baidu.com/share/verify?surl=$surl'
      '&t=${DateTime.now().millisecondsSinceEpoch}'
      '&channel=chunlei&clienttype=0&web=1&app_id=$_appId',
      {'pwd': pwd ?? ''},
      headers: _h(await _soleCredOrThrow()),
    );
    if (verifyResp.isOk) {
      final errno = (verifyResp.json['errno'] as num?)?.toInt();
      if (errno == 0) {
        randsk =
            ((verifyResp.json['data'] as Map<String, dynamic>?)?['randsk'] ?? '')
                .toString();
      }
      final fromCookie = verifyResp.setCookiePairs['BDCLND'];
      if (randsk.isEmpty && fromCookie != null && fromCookie.isNotEmpty) {
        randsk = Uri.decodeComponent(fromCookie);
      }
    }
    final cred = await _soleCredOrThrow();
    final cookie = cookieHeader(cred) +
        (randsk.isEmpty ? '' : '; BDCLND=${Uri.encodeQueryComponent(randsk)}');
    final listResp = await cloudGet(
      'https://pan.baidu.com/share/list?clienttype=0&app_id=$_appId&web=1'
      '&shorturl=${Uri.encodeQueryComponent(surl)}&root=1',
      headers: {
        'User-Agent': _ua,
        'Referer': 'https://pan.baidu.com/',
        'Cookie': cookie,
      },
    );
    if (!listResp.isOk) throw const CloudException('分享文件列表获取失败');
    final errno = (listResp.json['errno'] as num?)?.toInt();
    if (errno == -9 || errno == -105) {
      throw const CloudException('需要提取码');
    }
    if (errno != 0) throw const CloudException('分享已失效');
    final list = (listResp.json['list'] as List?) ?? const [];
    final files = <CloudFile>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['fs_id'] ?? '').toString(),
        name: (e['server_filename'] ?? e['filename'] ?? '').toString(),
        isDir: (e['isdir'] as num?)?.toInt() == 1,
        size: (e['size'] as num?)?.toInt() ?? 0,
        path: (e['path'] ?? '').toString(),
        // token 存 `<shareid>:<from>`，转存时用。
        token:
            '${(e['share_id'] ?? '').toString()}:${(e['from'] ?? '').toString()}',
      ));
    }
    return CloudShareParse(
      providerId: id,
      files: files,
      shareId: surl,
      shareToken: randsk,
      passcode: pwd,
      directPlayable: false,
    );
  }

  @override
  Future<List<CloudFile>> transferShareFiles(
    Map<String, String> cred,
    CloudShareParse share,
  ) async {
    // 先确保转存目录存在（目录已存在不报错）。
    await _ensureDir(cred);
    final sekey = share.shareToken ?? '';
    if (sekey.isEmpty) throw const CloudException('请先填写提取码');
    final from = share.files.isNotEmpty
        ? (share.files.first.token ?? ':').split(':').last
        : '';
    final transferResp = await cloudPostForm(
      'https://pan.baidu.com/share/transfer?shareid=&from=${Uri.encodeQueryComponent(from)}'
      '&sekey=${Uri.encodeQueryComponent(sekey)}&ondup=new&async=1'
      '&channel=chunlei&clienttype=0&web=1&app_id=$_appId',
      {
        'path': '/apps/弦予音乐',
        'filelist': jsonEncode(share.files.map((f) => f.id).toList()),
      },
      headers: {
        'User-Agent': _ua,
        'Referer': 'https://pan.baidu.com/',
        'Cookie': cookieHeader(cred),
      },
    );
    if (!transferResp.isOk) throw const CloudException('转存失败');
    final errno = (transferResp.json['errno'] as num?)?.toInt();
    if (errno != 0) throw const CloudException('转存失败：文件可能已存在或超限');
    final infos = (transferResp.json['info'] as List?) ?? const [];
    final out = <CloudFile>[];
    final byFsId = {
      for (final f in share.files) f.id: f,
    };
    for (final e in infos) {
      if (e is! Map<String, dynamic>) continue;
      final newId = (e['to_fs_id'] ?? '').toString();
      final oldId = (e['from_fs_id'] ?? '').toString();
      final src = byFsId[oldId];
      if (newId.isEmpty) continue;
      out.add(CloudFile(
        id: newId,
        name: src?.name ?? '',
        isDir: src?.isDir ?? false,
        size: src?.size ?? 0,
        path: '/apps/弦予音乐/${src?.name ?? ''}',
      ));
    }
    if (out.isEmpty) throw const CloudException('转存失败：文件可能已存在或超限');
    return out;
  }

  /// 取当前会话的 bdstoken（web 接口防 CSRF 令牌）。filemetas 直链接口
  /// 在部分风控策略下缺失 bdstoken 会返回 errno 9019「会话不被认可」，
  /// 必须在查询串上附带；获取失败时降级为空串继续尝试。
  Future<String> _fetchBdstoken(Map<String, String> cred) async {
    final tplResp = await cloudGet(
      'https://pan.baidu.com/api/gettemplatevariable?clienttype=0'
      '&app_id=$_appId&web=1&fields=["bdstoken"]',
      headers: _h(cred),
    );
    if (!tplResp.isOk) return '';
    return ((tplResp.json['result'] as Map<String, dynamic>?)?['bdstoken'] ?? '')
        .toString();
  }

  /// 确保转存目标目录存在并返回 bdstoken。
  Future<String> _ensureDir(Map<String, String> cred) async {
    final bdstoken = await _fetchBdstoken(cred);
    final createResp = await cloudPostForm(
      'https://pan.baidu.com/api/create?a=commit&channel=chunlei&web=1'
      '&app_id=$_appId&clienttype=0',
      {
        'path': '/apps/弦予音乐',
        'isdir': '1',
        'block_list': '[]',
        'bdstoken': bdstoken,
      },
      headers: _h(cred),
    );
    final errno = createResp.isOk
        ? (createResp.json['errno'] as num?)?.toInt()
        : -1;
    if (errno != 0 && errno != 12 && errno != -8) {
      // 12/-8 = 目录已存在，可继续。
      throw const CloudException('创建转存目录失败');
    }
    return bdstoken;
  }

  // ── 直链 ──────────────────────────────────────────────

  @override
  Future<CloudDirectLink> getDirectLink(
      Map<String, String> cred, CloudFile file) async {
    // 多路由降级（对齐惜梦解析与 OpenList 社区实现）：
    // ① web /api/filemetas：cookie 态按 target 路径取 dlink（OpenList
    //    crack 同款参数 web=5&origin=dlna；UA 必须为 netdisk）；
    // ② xpan multimedia filemetas：cookie + bdstoken 按 fsid 取 dlink，
    //    部分账号会被风控拒绝（errno=9019「会话不被认可」）。
    final bdstoken = await _fetchBdstoken(cred);
    final errors = <String>[];
    if ((file.path ?? '').isNotEmpty) {
      try {
        return await _directLinkWebFilemetas(cred, file, bdstoken);
      } on CloudException catch (e) {
        errors.add('web filemetas：${e.message}');
      }
    }
    try {
      return await _directLinkXpanFilemetas(cred, file, bdstoken);
    } on CloudException catch (e) {
      errors.add('xpan filemetas：${e.message}');
    }
    throw CloudException('直链获取失败（${errors.join('；')}）');
  }

  /// 路由①：web 文件元信息接口，响应字段是 info[].dlink（与 xpan 的
  /// list[].dlink 不同）。UA 用 netdisk 时浏览器 UA 会被服务端拒绝。
  Future<CloudDirectLink> _directLinkWebFilemetas(
    Map<String, String> cred,
    CloudFile file,
    String bdstoken,
  ) async {
    final resp = await cloudGet(
      'https://pan.baidu.com/api/filemetas?target='
      '${Uri.encodeQueryComponent(jsonEncode([file.path!]))}'
      '&dlink=1&web=5&origin=dlna&app_id=$_appId'
      '${bdstoken.isEmpty ? '' : '&bdstoken=${Uri.encodeQueryComponent(bdstoken)}'}',
      headers: {'User-Agent': 'netdisk', 'Cookie': cookieHeader(cred)},
    );
    if (!resp.isOk) throw CloudException('HTTP ${resp.status}');
    final errno = (resp.json['errno'] as num?)?.toInt() ?? -1;
    if (errno != 0) {
      throw CloudException('errno=$errno ${respErrorDetail(resp)}');
    }
    final dlink = _dlinkFromMetasResp(resp.json);
    if (dlink.isEmpty) {
      throw CloudException('响应未含 dlink ${respErrorDetail(resp)}');
    }
    return _finishBaiduLink(dlink, file, 'netdisk', cred);
  }

  /// 路由②：xpan multimedia filemetas（fsids 检索）。dlink 下发与下载均
  /// 要求 UA 为 pan.baidu.com（Chrome UA 会被判定会话不被接口认可返回
  /// code=9019 且无 filemetas 列表）；同时附带 bdstoken（web 接口 CSRF
  /// 令牌），部分风控策略缺它也返回 9019。
  Future<CloudDirectLink> _directLinkXpanFilemetas(
    Map<String, String> cred,
    CloudFile file,
    String bdstoken,
  ) async {
    final metaResp = await cloudGet(
      'https://pan.baidu.com/rest/2.0/xpan/multimedia?method=filemetas'
      '&dlink=1&fsids=${Uri.encodeQueryComponent('[${file.id}]')}'
      '&clienttype=0&app_id=$_appId&web=1'
      '${bdstoken.isEmpty ? '' : '&bdstoken=${Uri.encodeQueryComponent(bdstoken)}'}',
      headers: {..._h(cred), 'User-Agent': 'pan.baidu.com'},
    );
    if (!metaResp.isOk) {
      throw CloudException('HTTP ${metaResp.status} ${respErrorDetail(metaResp)}');
    }
    final errno = (metaResp.json['errno'] as num?)?.toInt() ?? -1;
    if (errno != 0) {
      if (errno == 9019) {
        throw CloudException(
            'errno=9019 百度会话不被该接口认可（cookie 态被风控拦截）');
      }
      throw CloudException('errno=$errno ${respErrorDetail(metaResp)}');
    }
    final dlink = _dlinkFromMetasResp(metaResp.json);
    if (dlink.isEmpty) {
      throw CloudException('响应未含 dlink ${respErrorDetail(metaResp)}');
    }
    return _finishBaiduLink(dlink, file, 'pan.baidu.com', cred);
  }

  /// filemetas 响应兼容两种字段形态：web 接口 info[].dlink /
  /// xpan 接口 list[].dlink，取第一个非空 dlink。
  static String _dlinkFromMetasResp(Map<String, dynamic> json) {
    for (final key in const ['info', 'list']) {
      final list = json[key];
      if (list is List && list.isNotEmpty) {
        final v = ((list.first as Map<String, dynamic>)['dlink'] ?? '').toString();
        if (v.isNotEmpty) return v;
      }
    }
    return '';
  }

  /// dlink 归一：跟随 302 确认真实 CDN 域名，命中限速域名黑名单即拒。
  ///
  /// 5508 日志定位：dlink 请求带 Cookie 仍 403 且无重定向——`netdisk`
  /// UA 是 OpenList access_token 流程的下载头，cookie 态下不被 d.pcs
  /// 接受。改为完全模拟网页端下载请求头：浏览器 UA + pan.baidu.com
  /// Referer + 登录 Cookie（探测与播放统一，避免特征不一致）。
  Future<CloudDirectLink> _finishBaiduLink(
    String dlink,
    CloudFile file,
    String ua,
    Map<String, String> cred,
  ) async {
    final headers = {
      'User-Agent': _ua,
      'Referer': 'https://pan.baidu.com/disk/main',
      'Cookie': cookieHeader(cred),
    };
    final resolved = await resolveFinalUrl(dlink, headers: headers);
    final host = Uri.tryParse(resolved)?.host ?? '';
    if (host.contains('d2-ant') || host.contains('speed-limited')) {
      throw const CloudException('该文件被限速，暂无法播放');
    }
    return CloudDirectLink(
      url: resolved,
      headers: headers,
      fileName: file.name,
      size: file.size,
      expireAt: DateTime.now().add(const Duration(hours: 8)),
    );
  }

  /// 分享列表/转存需要登录态；未绑定直接报。
  Future<Map<String, String>> _soleCredOrThrow() async {
    final cred = await CloudCredentialsStore.instance.soleCredFor(id);
    if (cred == null) throw const CloudException('请先绑定百度网盘');
    return cred;
  }
}
