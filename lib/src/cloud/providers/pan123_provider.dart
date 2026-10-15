// 123 云盘 provider（qrCode 主通道 + 账密兜底；分享免转存直链
// directPlayable=true）。
//
// DownloadUrl 字段实测可能是 JSON 串（{url:...}）或纯 URL，统一防御解析。

import 'dart:convert';

import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_types.dart';
import '../share_link_parser.dart';
import 'http_login_support.dart';

class Pan123Provider extends CloudProvider {
  const Pan123Provider();

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  // 123 云盘生产业务网关：api.123278.com/b/api/（取自前端域名配置
  // prod.interface + "/b/api/"）。旧域名 www.123pan.com 已于 2026-10
  // 全面 404，此前账密登录的 validate 指向该域名，必然恒失败。
  static const _apiBase = 'https://api.123278.com/b/api';

  Map<String, String> _h(String token) => {
        'User-Agent': _ua,
        'Referer': 'https://www.123pan.com/',
        'Platform': 'web',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

  @override
  String get id => 'pan123';

  @override
  String get displayName => '123云盘';

  @override
  String get rootPath => '0';

  // 扫码通道实测已不可用（轮询接口不再给出可用 token），主通道改为网页端
  // 登录：WebView 打开 123 官网，捕获 localStorage.authorToken。
  @override
  CloudLoginKind get loginKind => CloudLoginKind.webviewToken;

  @override
  Duration get directLinkTtl => const Duration(hours: 1);

  @override
  String get webviewLoginUrl => 'https://www.123pan.com/';

  @override
  CloudCaptureRule? get captureRule => const CloudCaptureRule(
        // 123 前端把登录态写入 localStorage.authorToken（前端常量
        // `const o = "authorToken"`，并以 window storage 事件监听其变化），
        // 业务接口统一用 `Authorization: Bearer <authorToken>` 鉴权。
        //
        // 注意：前端存储层 `c.save` 对**非特殊键**走
        // `localStorage.setItem(key, JSON.stringify(v))`（特殊键仅
        // userin/username/userPwd/Mail/LoginUuid），authorToken 属非特殊键，
        // 落盘值是带引号的 JSON 串。原样当凭据会让请求头变成
        // `Authorization: Bearer "eyJ..."`（字面双引号），服务端判未登录，
        // 即「登录状态校验失败」。此处先 JSON.parse 还原裸串。
        pollScript: '''
(() => {
  try {
    var raw = window.localStorage.getItem('authorToken');
    if (raw == null) return '';
    var s = String(raw);
    try {
      var v = JSON.parse(s);
      if (typeof v === 'string') return v;
    } catch (e) {}
    return s;
  } catch (e) { return ''; }
})()''',
        pollIntervalMs: 500,
      );

  @override
  List<CloudLoginField> get loginFields => const [
        CloudLoginField(key: 'passport', label: '手机号 / 邮箱'),
        CloudLoginField(key: 'password', label: '密码', obscure: true),
      ];

  // ── 登录 ──────────────────────────────────────────────

  /// 网页端登录：WebView 捕获 authorToken 后直接作为 Bearer 凭据，
  /// 并用业务接口二次校验（未登录返回 code 20101，成功 code 为 0）。
  @override
  Future<CloudAccount> completeLogin(CloudCaptureResult captured) async {
    final token = (captured.token ?? '').trim();
    if (token.isEmpty) {
      throw const CloudException('未捕获到登录凭据，请确认已成功登录后重试');
    }
    final cred = <String, String>{'token': token};
    CloudHttpResponse probe;
    try {
      probe = await _sessionProbe(cred);
    } on CloudException catch (e) {
      throw CloudException('登录状态校验失败（${e.message}），请确认已成功登录后重试');
    }
    if (!_codeOk(probe)) {
      throw CloudException(
          '登录状态校验失败（${respErrorDetail(probe)}），请确认已成功登录后重试');
    }
    return CloudAccount(
      provider: id,
      accountId: md5Hex(token).substring(0, 12),
      nickname: displayName,
      cred: cred,
      boundAt: DateTime.now(),
    );
  }

  // 以下扫码 / 账密通道保留为备用（loginKind 已切到网页端，不再从绑定页
  // 路由进入）。
  @override
  Future<CloudQrLoginSession> createQrLogin() async {
    final resp = await cloudGet(
      'https://login.123pan.com/api/user/qr-code/generate',
      headers: {'User-Agent': _ua},
    );
    if (!resp.isOk) throw const CloudException('二维码获取失败');
    final data = resp.json['data'];
    if (data is! Map<String, dynamic>) throw const CloudException('二维码获取失败');
    // 实测 2026-10 接口返回 data.url（二维码内容，扫码跳转确认）+ data.uniID；
    // 兼容旧字段 data.qr。
    final qr = (data['url'] ?? data['qr'] ?? '').toString();
    final uniId = (data['uniID'] ?? data['uniId'] ?? '').toString();
    if (qr.isEmpty || uniId.isEmpty) throw const CloudException('二维码获取失败');
    return CloudQrLoginSession(qrContent: qr, state: uniId);
  }

  @override
  Future<CloudAccount?> pollQrLogin(CloudQrLoginSession session) async {
    final resp = await cloudGet(
      'https://login.123pan.com/api/user/qr-code/result'
      '?uniID=${Uri.encodeQueryComponent(session.state)}',
      headers: {'User-Agent': _ua},
    );
    if (!resp.isOk) return null;
    final data = resp.json['data'];
    if (data is! Map<String, dynamic>) return null;
    // 实测 2026-10 该接口返回 data.loginStatus（0 未扫 / 2 已确认），
    // 没有 data.status 字段；旧写法读 status 恒为 0，轮询永远不会推进。
    final status =
        int.tryParse('${data['loginStatus'] ?? data['status'] ?? 0}') ?? 0;
    if (status != 2) return null; // 未确认。
    // token 字段兼容多种返回形态（新旧字段 / 嵌套 data）。
    dynamic tokenSrc = data['token'] ??
        data['accessToken'] ??
        data['access_token'] ??
        (data['data'] is Map<String, dynamic>
            ? (data['data'] as Map<String, dynamic>)['token']
            : null) ??
        (data['data'] is Map<String, dynamic>
            ? (data['data'] as Map<String, dynamic>)['access_token']
            : null);
    final token = tokenSrc?.toString() ?? '';
    if (token.isEmpty) throw const CloudException('二维码已过期，请刷新');
    final user = data['user'];
    final uid = user is Map<String, dynamic>
        ? (user['id'] ?? '').toString()
        : '';
    final nick = user is Map<String, dynamic>
        ? ((user['nickname'] ?? user['Passport'] ?? '').toString())
        : '';
    final account = CloudAccount(
      provider: id,
      accountId: uid.isEmpty ? md5Hex(token).substring(0, 12) : uid,
      nickname: nick.isEmpty ? '123云盘' : nick,
      cred: {'token': token},
      boundAt: DateTime.now(),
    );
    // 会话有效性二次校验：扫码确认后仍须确认 token 真实可用。
    if (!await validate(account.cred)) {
      throw const CloudException('登录状态校验失败，请重试');
    }
    return account;
  }

  @override
  Future<CloudAccount> loginWithFields(Map<String, String> fields) async {
    final passport = (fields['passport'] ?? '').trim();
    final password = fields['password'] ?? '';
    if (passport.isEmpty || password.isEmpty) {
      throw const CloudException('请填写账号和密码');
    }
    HttpLoginGate.instance.ensureAllowed(id);
    HttpLoginGate.instance.recordAttempt(id);
    try {
      final resp = await cloudPostJson(
        'https://user.123pan.cn/api/user/sign_in',
        body: {
          'passport': passport,
          'password': password,
          'remember': true,
        },
        headers: {'User-Agent': _ua, 'Content-Type': 'application/json'},
      );
      final code = (resp.json['code'] as num?)?.toInt() ?? -1;
      if (code != 200) {
        HttpLoginGate.instance.recordFailure(id);
        throw CloudException((resp.json['message'] ?? '账号或密码错误').toString());
      }
      final token =
          ((resp.json['data'] as Map<String, dynamic>)['token'] ?? '')
              .toString();
      if (token.isEmpty) {
        HttpLoginGate.instance.recordFailure(id);
        throw const CloudException('登录失败');
      }
      HttpLoginGate.instance.recordSuccess(id);
      final account = CloudAccount(
        provider: id,
        accountId: md5Hex(token).substring(0, 12),
        nickname: passport,
        cred: {'token': token},
        boundAt: DateTime.now(),
      );
      // 会话有效性二次校验：避免拿到过期/伪 token 仍判定登录成功。
      if (!await validate(account.cred)) {
        HttpLoginGate.instance.recordFailure(id);
        throw const CloudException('登录状态校验失败，请重试');
      }
      return account;
    } on CloudException {
      rethrow;
    } catch (_) {
      HttpLoginGate.instance.recordFailure(id);
      throw const CloudException('登录失败，请稍后再试');
    }
  }

  /// 会话校验探针：打业务列表接口（未登录返回 code 20101，成功为 0）。
  ///
  /// 参数名对齐 123 生产前端（app.js 里 list/new 的请求体）：driveId 必传
  /// （个人空间固定 0），分页字段名是 `Page`、异常文件开关是
  /// `OnlyAbnormalFile`；缺 driveId 时服务端返回 HTTP 200 / code 400
  /// 「driveId is required」，即使凭据合法也会被判「校验失败」。
  Future<CloudHttpResponse> _sessionProbe(Map<String, String> cred) => cloudGet(
        '$_apiBase/file/list/new'
        '?driveId=0&limit=1&Page=1'
        '&orderBy=update_time&orderDirection=desc'
        '&parentFileId=0&trashed=false&OnlyAbnormalFile=false',
        headers: _h(cred['token'] ?? ''),
      );

  /// 容错取整：接口可能把数值字段序列化成字符串，直接 `as num?` 会抛类型
  /// 转换异常，导致整个目录列表加载失败。
  static int _asInt(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  static bool _codeOk(CloudHttpResponse r) {
    if (!r.isOk) return false;
    try {
      final code = (r.json['code'] as num?)?.toInt() ?? -1;
      return code == 0 || code == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> validate(Map<String, String> cred) async {
    if ((cred['token'] ?? '').isEmpty) return false;
    try {
      return _codeOk(await _sessionProbe(cred));
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
    final resp = await cloudGet(
      '$_apiBase/file/list/new'
      '?driveId=0&limit=100&Page=$page'
      '&orderBy=update_time&orderDirection=desc'
      '&parentFileId=${Uri.encodeQueryComponent(path)}'
      '&trashed=false&OnlyAbnormalFile=false',
      headers: _h(cred['token'] ?? ''),
    );
    if (!_codeOk(resp)) {
      throw CloudException('目录列表请求失败（${respErrorDetail(resp)}）');
    }
    final data = resp.json['data'];
    final list = data is Map<String, dynamic>
        ? (data['InfoList'] as List?) ?? const []
        : const [];
    final files = <CloudFile>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        // 字段名对齐 123 生产前端 app.js 对 `data.InfoList` 的访问：一律
        // PascalCase（FileId / FileName / Type / Size / ParentFileId，
        // Type==1 为目录）。此前用的小写名全部读空，目录页只剩一排
        // 没有标题的图标，也无法进入子目录。
        id: (e['FileId'] ?? e['fileId'] ?? '').toString(),
        name: (e['FileName'] ?? e['filename'] ?? '').toString(),
        isDir: _asInt(e['Type'] ?? e['type']) == 1,
        size: _asInt(e['Size'] ?? e['size']),
        parentId: (e['ParentFileId'] ?? path).toString(),
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
    final shareKey = info?.shareId ?? url;
    final resp = await cloudGet(
      '$_apiBase/share/get'
      '?shareKey=${Uri.encodeQueryComponent(shareKey)}'
      '&PassCode=${Uri.encodeQueryComponent(pwd ?? '')}'
      '&orderBy=file_id&orderDirection=asc',
      headers: {'User-Agent': _ua},
    );
    if (!resp.isOk) throw const CloudException('分享链接解析失败');
    final code = (resp.json['code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      throw CloudException(
          (resp.json['message'] ?? (pwd?.isNotEmpty ?? false ? '提取码错误' : '分享已失效'))
              .toString());
    }
    final data = resp.json['data'];
    final list = data is Map<String, dynamic>
        ? (data['InfoList'] as List?) ?? const []
        : const [];
    final files = <CloudFile>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      files.add(CloudFile(
        id: (e['FileId'] ?? e['fileId'] ?? '').toString(),
        name: (e['FileName'] ?? e['filename'] ?? '').toString(),
        isDir: _asInt(e['Type']) == 1,
        size: _asInt(e['Size']),
      ));
    }
    return CloudShareParse(
      providerId: id,
      files: files,
      shareId: shareKey,
      // 123 分享直链需复用提取码，shareToken 暂存 pwd。
      shareToken: pwd,
      passcode: pwd,
      directPlayable: true,
    );
  }

  /// 123 分享直链批量接口；失败/返回非零 code 时返回 null（供上层降级）。
  /// 该路由只接受 POST（旧实现用 GET，网关直接 404）。
  Future<dynamic> _shareDownloadInfo(
    String shareKey,
    String pwd,
    String fileId,
  ) async {
    final resp = await cloudPostJson(
      '$_apiBase/share/download/info',
      body: {
        'shareKey': shareKey,
        'PassCode': pwd,
        'fileIds': [
          {'FileId': fileId}
        ],
      },
      headers: {'User-Agent': _ua},
    );
    if (!resp.isOk) return null;
    final code = (resp.json['code'] as num?)?.toInt() ?? -1;
    if (code != 0) return null;
    return resp.json['data'];
  }

  /// 分享免转存直链（download/info 批量接口取单个文件）。
  @override
  Future<CloudDirectLink> getShareDirectLink(
    Map<String, String>? cred,
    CloudShareParse share,
    CloudFile file,
  ) async {
    final pwd = share.passcode ?? share.shareToken ?? '';
    final shareKey = share.shareId ?? '';
    final resp = await _shareDownloadInfo(shareKey, pwd, file.id);
    if (resp == null) throw const CloudException('分享直链获取失败');
    final url = _extractDownloadUrl(resp);
    if (url.isEmpty) throw const CloudException('分享直链获取失败');
    return CloudDirectLink(
      url: url,
      headers: {'User-Agent': _ua},
      fileName: file.name,
      size: file.size,
      expireAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }

  // directPlayable=true，不支持转存。
  @override
  Future<List<CloudFile>> transferShareFiles(
    Map<String, String> cred,
    CloudShareParse share,
  ) {
    throw UnsupportedError('该盘分享不支持转存');
  }

  // ── 直链 ──────────────────────────────────────────────

  @override
  Future<CloudDirectLink> getDirectLink(
      Map<String, String> cred, CloudFile file) async {
    final resp = await cloudPostJson(
      '$_apiBase/file/download_info',
      body: {'driveId': 0, 'fileId': file.id},
      headers: _h(cred['token'] ?? ''),
    );
    if (!resp.isOk) throw const CloudException('直链获取失败');
    final code = (resp.json['code'] as num?)?.toInt() ?? -1;
    if (code != 0) throw const CloudException('直链获取失败');
    final url = _extractDownloadUrl(resp.json['data']);
    if (url.isEmpty) throw const CloudException('直链获取失败');
    return CloudDirectLink(
      url: url,
      headers: {'User-Agent': _ua},
      fileName: file.name,
      size: file.size,
      expireAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }

  /// DownloadUrl 可能是纯 URL、JSON 串或嵌套 data，统一防御解析。
  String _extractDownloadUrl(dynamic data) {
    if (data is String) {
      final s = data;
      if (s.startsWith('http')) return s;
      try {
        return _extractDownloadUrl(jsonDecode(s));
      } catch (_) {
        return '';
      }
    }
    if (data is Map<String, dynamic>) {
      for (final key in ['DownloadUrl', 'downloadUrl', 'download_url']) {
        final v = data[key];
        if (v is String && v.startsWith('http')) return v;
        if (v is String && v.isNotEmpty) {
          final inner = _extractDownloadUrl(v);
          if (inner.isNotEmpty) return inner;
        }
      }
      final backup = data['backup_download_url'] ?? data['BackupDownloadUrl'];
      if (backup is String && backup.startsWith('http')) {
        return backup;
      }
    }
    return '';
  }
}
