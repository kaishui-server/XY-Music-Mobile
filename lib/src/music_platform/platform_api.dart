import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'platform_crypto.dart';
import 'platform_session.dart';

/// 第三方平台在线歌单条目。
class OnlinePlaylist {
  const OnlinePlaylist({
    required this.id,
    required this.name,
    this.coverUrl = '',
    this.songCount = 0,
    this.isFavorite = false,
  });

  /// 平台侧歌单标识：网易歌单 id / QQ disstid / 酷狗 global_collection_id，
  /// 可直接传给 importLxPlaylist 拉取详情。
  final String id;
  final String name;
  final String coverUrl;
  final int songCount;
  final bool isFavorite;
}

class PlatformApiException implements Exception {
  const PlatformApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

String _text(dynamic value) => value?.toString().trim() ?? '';

int _toInt(dynamic value, [int fallback = 0]) =>
    value is num ? value.toInt() : int.tryParse('${value ?? ''}') ?? fallback;

const _browserHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
};

/// 把 Set-Cookie 串（可能多条逗号拼接）解析成 key=value 映射。
Map<String, String> _parseCookies(List<String> setCookies) {
  final result = <String, String>{};
  for (final header in setCookies) {
    for (final part in header.split(RegExp(r',(?=[^;]+=)'))) {
      final pair = part.split(';').first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      result[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
    }
  }
  return result;
}

Map<String, String> _cookiesFromResponse(http.Response response) {
  // http 包把多个 Set-Cookie 合并进小写 'set-cookie' 头。
  final raw = response.headers['set-cookie'];
  if (raw == null || raw.isEmpty) return {};
  return _parseCookies([raw]);
}

// ---------------------------------------------------------------------------
// 网易云音乐（weapi）
// ---------------------------------------------------------------------------

const _wyBase = 'music.163.com';

/// 网易云盾对 PC 浏览器 UA 的接口风控（-462 / weapi 空响应），
/// 伪装安卓客户端 UA 调明文 /api/ 接口可正常返回。
const _wyAndroidUa =
    'NeteaseMusic/8.10.05.160321151325(900105);Dalvik/2.1.0 '
    '(Linux; U; Android 13; Pixel 7)';

class NeteaseApi {
  NeteaseApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  void close() => _client.close();

  /// 明文 /api/ GET 请求（安卓客户端身份）。
  Future<({Map<String, dynamic> body, Map<String, String> cookies})> _apiGet(
    String path, {
    Map<String, String> query = const {},
    Map<String, String> cookie = const {},
  }) async {
    final response = await _client
        .get(
          Uri.https(_wyBase, path, query),
          headers: {
            'User-Agent': _wyAndroidUa,
            'Referer': 'https://music.163.com/',
            'Cookie': [
              'os=android',
              'appver=8.10.05',
              for (final entry in cookie.entries) '${entry.key}=${entry.value}',
            ].join('; '),
          },
        )
        .timeout(const Duration(seconds: 20));
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map) {
      throw const PlatformApiException('网易接口返回异常，请稍后重试');
    }
    var cookies = _cookiesFromResponse(response);
    final bodyCookie = _text(body['cookie']);
    if (bodyCookie.isNotEmpty) {
      cookies = {
        ..._parseCookies([bodyCookie]),
        ...cookies,
      };
    }
    return (body: Map<String, dynamic>.from(body), cookies: cookies);
  }

  /// 生成二维码登录 key；二维码内容为
  /// `https://music.163.com/login?codekey=<key>`。
  Future<String> createQrKey() async {
    final result = await _apiGet(
      '/api/login/qrcode/unikey',
      query: {'type': '1'},
    );
    final unikey = _text(result.body['unikey']);
    if (_toInt(result.body['code']) != 200 || unikey.isEmpty) {
      throw const PlatformApiException('获取登录二维码失败，请稍后重试');
    }
    return unikey;
  }

  /// 二维码状态：801 等待扫码、802 已扫码待确认、803 登录成功。
  /// 成功时返回登录后的 cookie（含 MUSIC_U）。
  Future<({int code, Map<String, String> cookies})> checkQrLogin(
    String key,
  ) async {
    final result = await _apiGet(
      '/api/login/qrcode/client/login',
      query: {'key': key, 'type': '1'},
    );
    return (code: _toInt(result.body['code']), cookies: result.cookies);
  }

  /// 手机号 + 密码登录（密码 MD5，明文接口）。
  Future<({Map<String, String> cookies, Map<String, dynamic> profile})>
  loginByPhone(String phone, String password) async {
    final result = await _apiGet(
      '/api/login/cellphone',
      query: {
        'phone': phone,
        'countrycode': '86',
        'md5_password': md5.convert(utf8.encode(password)).toString(),
        'rememberLogin': 'true',
      },
    );
    final code = _toInt(result.body['code']);
    if (code != 200) {
      final message = _text(result.body['message']).isNotEmpty
          ? _text(result.body['message'])
          : _text(result.body['msg']);
      final hint = message.contains('密码')
          ? '账号或密码错误'
          : message.contains('频率')
          ? '操作过于频繁，请稍后再试'
          : '登录失败（${message.isEmpty ? '请改用扫码登录' : message}）';
      throw PlatformApiException(hint);
    }
    return (cookies: result.cookies, profile: result.body);
  }

  /// 拉取当前登录用户信息（uid/昵称/头像）。
  Future<MusicPlatformAccount> fetchAccount(Map<String, String> cookie) async {
    final result = await _apiGet(
      '/api/nuser/account/get',
      cookie: {if (cookie['MUSIC_U'] != null) 'MUSIC_U': cookie['MUSIC_U']!},
    );
    final profile = result.body['profile'];
    final account = result.body['account'];
    final uid = _toInt(
      profile is Map
          ? profile['userId']
          : account is Map
          ? account['id']
          : null,
    );
    if (uid <= 0) throw const PlatformApiException('登录状态已失效，请重新登录');
    final profileMap = profile is Map
        ? Map<String, dynamic>.from(profile)
        : const <String, dynamic>{};
    return MusicPlatformAccount(
      platform: MusicPlatform.netease,
      userId: uid.toString(),
      nickname: _text(profileMap['nickname']).isEmpty
          ? uid.toString()
          : _text(profileMap['nickname']),
      avatarUrl: _text(profileMap['avatarUrl']),
      credentials: cookie,
    );
  }

  /// 拉取用户歌单列表（包含「我喜欢的音乐」与收藏的歌单）。
  Future<List<OnlinePlaylist>> fetchUserPlaylists(
    MusicPlatformAccount account,
  ) async {
    final playlists = <OnlinePlaylist>[];
    var offset = 0;
    const limit = 100;
    while (true) {
      final result = await _apiGet(
        '/api/user/playlist',
        query: {
          'uid': account.userId,
          'limit': limit.toString(),
          'offset': offset.toString(),
        },
        cookie: {
          if (account.credentials['MUSIC_U'] != null)
            'MUSIC_U': account.credentials['MUSIC_U']!,
        },
      );
      final list = result.body['playlist'] is List
          ? result.body['playlist'] as List
          : const [];
      if (list.isEmpty) break;
      for (final value in list.whereType<Map>()) {
        final item = Map<String, dynamic>.from(value);
        final id = _text(item['id']);
        final name = _text(item['name']);
        if (id.isEmpty || name.isEmpty) continue;
        final creator = item['creator'] is Map
            ? Map<String, dynamic>.from(item['creator'] as Map)
            : const <String, dynamic>{};
        final isMine =
            _toInt(creator['userId']) == (int.tryParse(account.userId) ?? -1);
        // ordered=true 是收藏的歌单；自建的（含我喜欢的音乐）为 false。
        playlists.add(
          OnlinePlaylist(
            id: id,
            name: name,
            coverUrl: _text(item['coverImgUrl']),
            songCount: _toInt(item['trackCount']),
            isFavorite: isMine && item['ordered'] == true,
          ),
        );
      }
      if (list.length < limit) break;
      offset += limit;
      if (offset > 2000) break;
    }
    return playlists;
  }
}

// ---------------------------------------------------------------------------
// QQ 音乐（微信扫码登录 + 网页公开接口）
// ---------------------------------------------------------------------------

class QqMusicApi {
  QqMusicApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  void close() => _client.close();

  /// QQ 音乐网页登录页（ptlogin 官方登录框：QQ 扫码 / 账号密码）。
  /// 登录成功后重定向链最终落到
  /// y.qq.com/portal/redirect.html?loginType=2&code=xxx，由 WebView
  /// 捕获 code 后调 [loginByQqCode] 换取凭据（与网页版自身流程一致）。
  static const qqLoginSUrl = 'https://y.qq.com/portal/redirect.html?loginType=2';

  /// QQ 互联登录完成页。ptlogin 的 s_url/u1 必须指向它：登录完成后
  /// 经 check_sig 跳到该页，graph.qq.com 再用登录态完成 OAuth 授权，
  /// 最终带着 code 返回 redirect.html。
  /// 注意：u1 若直接指向 y.qq.com 域，ptqrlogin 会直接返回 403
  /// （实测 2026-09）。
  static const qqLoginJumpUrl = 'https://graph.qq.com/oauth2.0/login_jump';

  /// QQ 互联授权端点。ptlogin 登录成功但登录后跳转链断开
  /// （y.qq.com 的 uin/qm_keyst 未落盘）时，导航到该端点可触发
  /// 静默授权 → redirect.html?code=xxx → 页面 JS 换票种 cookie。
  static String get qqAuthorizeUrl => Uri.https(
    'graph.qq.com',
    '/oauth2.0/authorize',
    {
      'client_id': '100497308',
      'response_type': 'code',
      'redirect_uri': qqLoginSUrl,
      'display': 'pc',
      'state': 'xy',
    },
  ).toString();

  /// 用 QQ 网页登录回调的 OAuth code 换取 QQ 音乐凭据
  /// （与 QQ 扫码确认后的 check_sig 链路等价）。
  Future<MusicPlatformAccount> loginByQqCode(String code) =>
      _codeLogin(code, '100497308', '2');

  /// 由 WebView 登录后 y.qq.com 域的 cookie 构造账号
  /// （code 捕获失败时的兜底路径）。
  MusicPlatformAccount? accountFromWebCookie(Map<String, String> cookies) {
    final rawUin = cookies['uin'] ?? '';
    final musickey = cookies['qm_keyst'] ?? '';
    if (rawUin.isEmpty || musickey.isEmpty) return null;
    // cookie 里 uin 形如 o123456789，去掉 o 前缀。
    final uin = rawUin.startsWith('o') ? rawUin.substring(1) : rawUin;
    if (uin.isEmpty) return null;
    return MusicPlatformAccount(
      platform: MusicPlatform.qq,
      userId: uin,
      nickname: uin,
      credentials: {'qm_keyst': musickey},
    );
  }

  /// QQ 扫码登录会话：二维码与轮询所需的票据。
  ({String qrsig, String loginSig, Uint8List qrImage}) _qqQrSession(
    String qrsig,
    String loginSig,
    Uint8List qrImage,
  ) => (qrsig: qrsig, loginSig: loginSig, qrImage: qrImage);

  /// QQ 扫码登录第一步：xlogin 获取 pt_login_sig，
  /// 再请求 ptqrshow 获取二维码图片与 qrsig。
  Future<({String qrsig, String loginSig, Uint8List qrImage})>
  createQqQr() async {
    final xlogin = await _client
        .get(
          Uri.https('xui.ptlogin2.qq.com', '/cgi-bin/xlogin', {
            'appid': '716027609',
            'daid': '383',
            'style': '40',
            'low_login': '1',
            'hln_alias': '0',
            'no_verifyimg': '1',
            's_url': qqLoginJumpUrl,
            'pt_feedback_param': '1',
            'hide_border': '0',
            'hide_title_bar': '0',
            'loading': '0',
            'hide_flash_icon': '0',
            'include_mine': '0',
            'include_self': '0',
            'need_level': '0',
            'level': '0',
            'pt_qzone_sig': '1',
            'pt_3rd_aid': '100497308',
          }),
          headers: _browserHeaders,
        )
        .timeout(const Duration(seconds: 20));
    final loginSig = _cookiesFromResponse(xlogin)['pt_login_sig'] ?? '';
    final response = await _client
        .get(
          Uri.https('ssl.ptlogin2.qq.com', '/ptqrshow', {
            'appid': '716027609',
            'e': '2',
            'l': 'M',
            's': '3',
            'd': '72',
            'v': '4',
            't': Random().nextDouble().toString(),
            'daid': '383',
            'pt_3rd_aid': '100497308',
          }),
          headers: _browserHeaders,
        )
        .timeout(const Duration(seconds: 20));
    final qrsig = _cookiesFromResponse(response)['qrsig'];
    if (qrsig == null || qrsig.isEmpty || response.bodyBytes.isEmpty) {
      throw const PlatformApiException('获取QQ音乐登录二维码失败，请稍后重试');
    }
    return _qqQrSession(qrsig, loginSig, response.bodyBytes);
  }

  /// 由 qrsig 计算 ptqrtoken（ptlogin 官方 hash33：每轮截断到 31 位）。
  int _ptqrtoken(String qrsig) {
    var hash = 0;
    for (var i = 0; i < qrsig.length; i++) {
      hash += (hash << 5) + qrsig.codeUnitAt(i);
      hash &= 0x7FFFFFFF;
    }
    return hash;
  }

  /// QQ 扫码状态轮询。
  ///
  /// [status]：66 等待扫码、67 已扫码待确认、68 已过期、
  /// 0 成功（[checkSigUrl] 有值，用于换取 QQ 音乐凭据）。
  ///
  /// u1 必须指向 graph.qq.com 的 login_jump（QQ 互联登录完成页），
  /// 指向 y.qq.com 会被 ptlogin2 以 403 拒绝。
  Future<({int status, String nickname, String checkSigUrl})> checkQqLogin(
    String qrsig,
    String loginSig,
  ) async {
    final response = await _client
        .get(
          Uri.https('ssl.ptlogin2.qq.com', '/ptqrlogin', {
            'u1': qqLoginJumpUrl,
            'ptqrtoken': _ptqrtoken(qrsig).toString(),
            'ptredirect': '0',
            'h': '1',
            't': '1',
            'g': '1',
            'from_ui': '1',
            'ptlang': '2052',
            'action': '0-0-${DateTime.now().millisecondsSinceEpoch}',
            'js_ver': '10291',
            'js_type': '1',
            'login_sig': loginSig,
            'pt_uistyle': '40',
            'aid': '716027609',
            'daid': '383',
            'pt_3rd_aid': '100497308',
          }),
          headers: {
            ..._browserHeaders,
            'Referer': 'https://y.qq.com/',
            'Cookie': 'qrsig=$qrsig; pt_login_sig=$loginSig',
          },
        )
        .timeout(const Duration(seconds: 20));
    // 响应形如 ptuiCB('0','0','https://...check_sig?...','0','昵称', '')
    final match = RegExp(
      r"ptuiCB\('(\d+)','\d*','([^']*)','[^']*','([^']*)'",
    ).firstMatch(response.body);
    if (match == null) {
      throw const PlatformApiException('QQ登录状态查询失败');
    }
    return (
      status: int.tryParse(match.group(1) ?? '') ?? -1,
      nickname: match.group(3) ?? '',
      checkSigUrl: match.group(2) ?? '',
    );
  }

  /// 用 QQ 扫码确认后的 check_sig 地址换取 QQ 音乐凭据。
  ///
  /// 流程：check_sig（ptlogin 域，回设 graph.qq.com 的 p_skey 等）
  /// → graph.qq.com/login_jump → authorize 颁发 OAuth code →
  /// y.qq.com redirect.html。链路可能终止在 login_jump（页面型跳转），
  /// 此时主动请求 authorize 端点完成静默授权，从重定向 Location
  /// 里取 code。
  Future<MusicPlatformAccount> qqQrLogin(String checkSigUrl) async {
    final cookies = <String, String>{};
    var code = await _followForCode(checkSigUrl, cookies, 8);
    code ??= await _followForCode(qqAuthorizeUrl, cookies, 4);
    if (code == null) {
      throw const PlatformApiException('QQ登录授权失败，请重试');
    }
    return _codeLogin(code, '100497308', '2');
  }

  /// 手动跟随重定向链（携带各跳回设的 cookie），
  /// 返回第一个带 code 参数的跳转地址中的 code。
  Future<String?> _followForCode(
    String startUrl,
    Map<String, String> cookies,
    int maxHops,
  ) async {
    var url = startUrl;
    for (var hop = 0; hop < maxHops; hop++) {
      final request = http.Request('GET', Uri.parse(url))
        ..headers.addAll({
          ..._browserHeaders,
          'Referer': 'https://y.qq.com/',
          if (cookies.isNotEmpty)
            'Cookie': cookies.entries
                .map((entry) => '${entry.key}=${entry.value}')
                .join('; '),
        })
        ..followRedirects = false;
      final response = await http.Response.fromStream(
        await _client.send(request),
      ).timeout(const Duration(seconds: 20));
      cookies.addAll(_cookiesFromResponse(response));
      final nextUrl = response.headers['location'];
      if (nextUrl == null || nextUrl.isEmpty) return null;
      final code = Uri.tryParse(nextUrl)?.queryParameters['code'] ?? '';
      if (code.isNotEmpty) return code;
      url = nextUrl;
    }
    return null;
  }

  /// 微信扫码登录第一步：请求 qrconnect 页面提取 uuid，
  /// 并下载二维码图片字节（jpg）。
  Future<({String uuid, Uint8List qrImage})> createWxQr() async {
    final page = await _client
        .get(
          Uri.https('open.weixin.qq.com', '/connect/qrconnect', {
            'appid': 'wx48db31d50e334801',
            'redirect_uri':
                'https://y.qq.com/portal/wx_redirect.html?login_type=2'
                '&surl=https://y.qq.com/',
            'response_type': 'code',
            'scope': 'snsapi_login',
            'state': 'STATE',
            'href':
                'https://y.qq.com/mediastyle/music_v17/src/css/popup_wechat.css'
                '#wechat_redirect',
          }),
          headers: _browserHeaders,
        )
        .timeout(const Duration(seconds: 20));
    final match = RegExp(r'uuid=(.+?)"').firstMatch(page.body);
    if (match == null) {
      throw const PlatformApiException('获取QQ音乐登录二维码失败，请稍后重试');
    }
    final uuid = match.group(1)!;
    final qr = await _client
        .get(
          Uri.https('open.weixin.qq.com', '/connect/qrcode/$uuid'),
          headers: {
            ..._browserHeaders,
            'Referer': 'https://open.weixin.qq.com/connect/qrconnect',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (qr.bodyBytes.isEmpty) {
      throw const PlatformApiException('下载QQ音乐二维码失败');
    }
    return (uuid: uuid, qrImage: qr.bodyBytes);
  }

  /// 微信扫码状态轮询。
  ///
  /// [status]：405 已确认（code 有值）、404 已扫码待确认、
  /// 408 等待扫码、403 用户拒绝。
  Future<({int status, String code})> checkWxLogin(String uuid) async {
    final response = await _client
        .get(
          Uri.https('lp.open.weixin.qq.com', '/connect/l/qrconnect', {
            'uuid': uuid,
            '_': DateTime.now().millisecondsSinceEpoch.toString(),
          }),
          headers: {
            ..._browserHeaders,
            'Referer': 'https://open.weixin.qq.com/',
          },
        )
        .timeout(const Duration(seconds: 35));
    final errcode = RegExp(
      r'window\.wx_errcode=(\d+);',
    ).firstMatch(response.body)?.group(1);
    final code = RegExp(
      r"window\.wx_code='([^']*)';",
    ).firstMatch(response.body)?.group(1);
    return (status: int.tryParse(errcode ?? '') ?? 0, code: code ?? '');
  }

  /// 用微信扫码返回的 code 换取 QQ 音乐凭据（musicid + musickey）。
  Future<MusicPlatformAccount> wxLogin(String code) =>
      _codeLogin(code, 'wx48db31d50e334801', '1');

  /// 用扫码授权 code 换取 QQ 音乐凭据。
  ///
  /// [loginType]：1 微信、2 QQ；[appid] 为对应扫码平台的 appid。
  Future<MusicPlatformAccount> _codeLogin(
    String code,
    String appid,
    String loginType,
  ) async {
    final response = await _client
        .post(
          Uri.https('u.y.qq.com', '/cgi-bin/musicu.fcg'),
          headers: {
            ..._browserHeaders,
            'Referer': 'https://y.qq.com/',
            'Origin': 'https://y.qq.com',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'comm': {
              'cv': 13020508,
              'v': 13020508,
              'ct': '11',
              'tmeAppID': 'qqmusic',
              'format': 'json',
              'inCharset': 'utf-8',
              'outCharset': 'utf-8',
              'uid': '0',
              'tmeLoginType': loginType,
            },
            'music.login.LoginServer.Login': {
              'module': 'music.login.LoginServer',
              'method': 'Login',
              'param': {'code': code, 'strAppid': appid},
            },
          }),
        )
        .timeout(const Duration(seconds: 20));
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map) throw const PlatformApiException('QQ登录失败');
    final login = body['music.login.LoginServer.Login'];
    final data = login is Map && login['data'] is Map
        ? Map<String, dynamic>.from(login['data'] as Map)
        : const <String, dynamic>{};
    final musicid = _text(
      data['str_musicid'] ?? data['musicid'] ?? data['uin'],
    );
    final musickey = _text(data['musickey'] ?? data['music_key']);
    if (musicid.isEmpty || musickey.isEmpty) {
      final message = _text(login is Map ? login['msg'] : '');
      throw PlatformApiException(
        message.isEmpty ? 'QQ登录失败，请重试' : 'QQ登录失败：$message',
      );
    }
    final nickname = _text(data['nick'] ?? data['nickname']);
    return MusicPlatformAccount(
      platform: MusicPlatform.qq,
      userId: musicid,
      nickname: nickname.isEmpty ? musicid : nickname,
      avatarUrl: _text(data['headurl'] ?? data['avatar']),
      credentials: {'qm_keyst': musickey},
    );
  }

  /// 拉取用户创建的歌单列表（含「我喜欢」）。
  /// 走 musicu.fcg 的 GetPlaylistByUin（歌单为公开数据，无需登录态），
  /// uin 既支持 QQ 号也支持微信登录的 musicid——旧接口
  /// fcg_user_created_diss 只认 QQ 号，微信登录后取不到歌单。
  Future<List<OnlinePlaylist>> fetchUserPlaylists(String uin) async {
    final response = await _client
        .post(
          Uri.https('u.y.qq.com', '/cgi-bin/musicu.fcg'),
          headers: {
            ..._browserHeaders,
            'Referer': 'https://y.qq.com/',
            'Origin': 'https://y.qq.com',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'comm': {'ct': 19, 'cv': 1859, 'uin': 0},
            'music.musicasset.PlaylistBaseRead': {
              'method': 'GetPlaylistByUin',
              'module': 'music.musicasset.PlaylistBaseRead',
              'param': {'uin': uin},
            },
          }),
        )
        .timeout(const Duration(seconds: 20));
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map) throw const PlatformApiException('QQ歌单加载失败');
    final result = body['music.musicasset.PlaylistBaseRead'];
    final data = result is Map && result['data'] is Map
        ? Map<String, dynamic>.from(result['data'] as Map)
        : const <String, dynamic>{};
    final list = data['v_playlist'] is List
        ? data['v_playlist'] as List
        : const [];
    if (_toInt(result is Map ? result['code'] : null, -1) != 0 &&
        list.isEmpty) {
      throw const PlatformApiException('QQ歌单加载失败');
    }
    final playlists = <OnlinePlaylist>[];
    for (final value in list.whereType<Map>()) {
      final item = Map<String, dynamic>.from(value);
      final tid = _text(item['tid']);
      final name = _text(item['dirName']);
      // tid=0 或 dirShow=0 的项是占位（如 QZone 背景音乐），跳过。
      if (tid.isEmpty || tid == '0' || name.isEmpty) continue;
      if (_toInt(item['dirShow'], 1) == 0) continue;
      var cover = _text(item['bigpicUrl'] ?? item['picUrl']);
      if (cover.startsWith('//')) cover = 'https:$cover';
      playlists.add(
        OnlinePlaylist(
          id: tid,
          name: name,
          coverUrl: cover,
          songCount: _toInt(item['songNum']),
          isFavorite: false,
        ),
      );
    }
    return playlists;
  }
}

// ---------------------------------------------------------------------------
// 酷狗音乐（安卓网关 + 签名）
// ---------------------------------------------------------------------------

const _kgAppid = 1005;
const _kgClientver = 20489;
/// 酷狗设备 mid：必须是 MD5 十六进制按大整数转成的**十进制字符串**
/// （对齐 KuGouMusicApi 的 calculateMid）。登录域接口不校验格式，
/// 但 gateway 业务接口（如 get_all_list）严格校验——传十六进制格式
/// 会被判为无效设备，返回 error_code 20010，表现为“登录成功但拉不到
/// 歌单”。
final _kgMid = BigInt.parse(
  md5.convert(utf8.encode('xy-music-mobile-kugou-device')).toString(),
  radix: 16,
).toString();

const _kgLoginT1 =
    '562a6f12a6e803453647d16a08f5f0c2ff7eee692cba2ab74cc4c8ab47fc467561a7c6b'
    '586ce7dc46a63613b246737c03a1dc8f8d162d8ce1d2c71893d19f1d4b797685a4c6d3d8'
    '1341cbde65e488c4829a9b4d42ef2df470eb102979fa5adcdd9b4eecfea8b909ff7599ab'
    'eb49867640f10c3c70fc444effca9d15db44a9a6c907731e2bb0f22cd9b35363801699956'
    '93e5f0e2424e3378097d3813186e3fe96bbe7023808a0981b4e2b6135a76faac';
const _kgLoginT2 =
    '31c4daf4cf480169ccea1cb7d4a209295865a9d2b788510301694db229b87807469ea0d41'
    'b4d4b9173c2151da7294aeebfc9738df154bbdf11a4e117bb5dff6a3af8ce5ce333e681c1'
    'f29a44038f27567d58992eb81283e080778ac77db1400fdf49b7cf7e26be2e5af4da7830'
    'cc3be4';
const _kgLoginT3 = 'MCwwLDAsMCwwLDAsMCwwLDA=';

class KugouApi {
  KugouApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  void close() => _client.close();

  /// 由 WebView 登录后 www.kugou.com 域的 cookie 构造账号。
  ///
  /// 网页版登录成功后 cookie 里会有 `KugouID`（或 `kg_uid`/`userid`）与
  /// `KugouToken`（或 `token`），凭据统一归一化为 `token`/`userid`。
  MusicPlatformAccount? accountFromWebCookie(Map<String, String> cookies) {
    final token = _text(
      cookies['KugouToken'] ?? cookies['token'] ?? cookies['kg_token'],
    );
    final userid = _text(
      cookies['KugouID'] ??
          cookies['userid'] ??
          cookies['kg_uid'] ??
          cookies['uid'],
    );
    if (token.isEmpty || userid.isEmpty) return null;
    final nickname = _text(cookies['KugouNick'] ?? cookies['nickname']);
    return MusicPlatformAccount(
      platform: MusicPlatform.kugou,
      userId: userid,
      nickname: nickname.isEmpty ? userid : nickname,
      credentials: {'token': token, 'userid': userid},
    );
  }

  /// 酷狗安卓协议请求：默认参数 + signature 签名（对齐 KuGouMusicApi）。
  ///
  /// 大部分业务接口走 gateway.kugou.com + x-router 路由头；
  /// 登录相关接口直连各自域名（login.user.kugou.com 仅支持 HTTP，
  /// 其 HTTPS 证书主机名不匹配）。
  Future<Map<String, dynamic>> _androidRequest(
    String path, {
    String host = 'gateway.kugou.com',
    String? xRouter,
    bool useHttp = false,
    Map<String, String> extraParams = const {},
    Object? body,
    Map<String, String> extraHeaders = const {},
  }) async {
    final clienttime = (DateTime.now().millisecondsSinceEpoch ~/ 1000)
        .toString();
    final params = <String, String>{
      'dfid': '-',
      'mid': _kgMid,
      'uuid': '-',
      'appid': '$_kgAppid',
      'clientver': '$_kgClientver',
      'clienttime': clienttime,
      ...extraParams,
    };
    final bodyJson = body == null ? '' : jsonEncode(body);
    params['signature'] = kgAndroidSignature(params, body: bodyJson);
    final response = await _client
        .post(
          useHttp
              ? Uri.http(host, path, params)
              : Uri.https(host, path, params),
          headers: {
            'User-Agent':
                'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi',
            'Content-Type': 'application/json',
            'x-router': ?xRouter,
            'dfid': '-',
            'mid': _kgMid,
            'clienttime': clienttime,
            'kg-rc': '1',
            'kg-thash': '5d816a0',
            'kg-rec': '1',
            'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
            ...extraHeaders,
          },
          body: bodyJson.isEmpty ? null : bodyJson,
        )
        .timeout(const Duration(seconds: 20));
    final bodyText = utf8.decode(response.bodyBytes);
    final decoded = jsonDecode(bodyText);
    if (decoded is! Map) throw const PlatformApiException('酷狗接口返回异常');
    return Map<String, dynamic>.from(decoded);
  }

  /// login-user.kugou.com H5 接口（扫码登录）请求：web 签名 + GET。
  Future<Map<String, dynamic>> _h5Get(
    String path,
    Map<String, String> params,
  ) async {
    final clienttime = params['clienttime']!;
    final response = await _client
        .get(
          Uri.https('login-user.kugou.com', path, params),
          headers: {
            'User-Agent':
                'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi',
            'dfid': '-',
            'clienttime': clienttime,
            'mid': _kgMid,
            'kg-rc': '1',
            'kg-thash': '5d816a0',
            'kg-rec': '1',
            'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
          },
        )
        .timeout(const Duration(seconds: 20));
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) throw const PlatformApiException('酷狗接口返回异常');
    return Map<String, dynamic>.from(decoded);
  }

  /// 解析登录响应 data：secu_params 是 AES 加密的 token 包裹
  /// （用登录请求的 rawKey 解密），优先取解密后的值。
  ({String token, String userid, String nickname, String pic})
  _parseLoginData(Map<String, dynamic> data, String rawKey) {
    var token = _text(data['token']);
    var userid = _text(data['userid']);
    final secuParams = _text(data['secu_params']);
    if (secuParams.isNotEmpty) {
      try {
        final decrypted = kgAesDecrypt(secuParams, rawKey);
        final decoded = jsonDecode(decrypted);
        if (decoded is Map) {
          final map = Map<String, dynamic>.from(decoded);
          if (_text(map['token']).isNotEmpty) token = _text(map['token']);
          if (_text(map['userid']).isNotEmpty) userid = _text(map['userid']);
        } else {
          final text = _text(decoded);
          if (text.isNotEmpty) token = text;
        }
      } catch (_) {
        // 解密失败时保留明文 token。
      }
    }
    return (
      token: token,
      userid: userid,
      nickname: _text(data['nickname']),
      pic: _text(data['pic']),
    );
  }

  /// 扫码登录第一步：创建二维码会话（login-user.kugou.com H5 协议）。
  /// 返回二维码 key 与服务端生成的二维码图片（PNG 字节，可能为空）。
  Future<({String key, Uint8List? qrImage})> createQr() async {
    final params = <String, String>{
      'dfid': '-',
      'mid': _kgMid,
      'uuid': '-',
      'appid': '1001',
      'clientver': '$_kgClientver',
      'clienttime':
          (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
      'type': '1',
      'plat': '4',
      'qrcode_txt':
          'https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=$_kgAppid&',
      'srcappid': '2919',
    };
    params['signature'] = kgWebSignature(params);
    final body = await _h5Get('/v2/qrcode', params);
    final data = body['data'] is Map
        ? Map<String, dynamic>.from(body['data'] as Map)
        : const <String, dynamic>{};
    final key = _text(data['qrcode']);
    if (key.isEmpty) {
      final message = _text(body['data']);
      throw PlatformApiException(
        message.isEmpty ? '获取酷狗登录二维码失败，请稍后重试' : '获取酷狗二维码失败：$message',
      );
    }
    Uint8List? qrImage;
    final img = _text(data['qrcode_img']);
    if (img.contains(',')) {
      try {
        qrImage = base64Decode(img.substring(img.indexOf(',') + 1));
      } on FormatException {
        // 图片解码失败时由 UI 用 key 自行渲染。
      }
    }
    return (key: key, qrImage: qrImage);
  }

  /// 扫码状态轮询。
  ///
  /// [status]：0 已过期、1 等待扫码、2 已扫码待确认、
  /// 4 授权成功（此时返回 [account]）。
  Future<({int status, MusicPlatformAccount? account})> checkQrLogin(
    String key,
  ) async {
    final params = <String, String>{
      'dfid': '-',
      'mid': _kgMid,
      'uuid': '-',
      'appid': '$_kgAppid',
      'clientver': '$_kgClientver',
      'clienttime':
          (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
      'plat': '4',
      'srcappid': '2919',
      'qrcode': key,
    };
    params['signature'] = kgWebSignature(params);
    final body = await _h5Get('/v2/get_userinfo_qrcode', params);
    final data = body['data'] is Map
        ? Map<String, dynamic>.from(body['data'] as Map)
        : const <String, dynamic>{};
    final status = _toInt(data['status'], -1);
    if (status != 4) return (status: status, account: null);
    final token = _text(data['token']);
    final userid = _text(data['userid']);
    if (token.isEmpty || userid.isEmpty) return (status: status, account: null);
    final nickname = _text(data['nickname']);
    return (
      status: status,
      account: MusicPlatformAccount(
        platform: MusicPlatform.kugou,
        userId: userid,
        nickname: nickname.isEmpty ? userid : nickname,
        avatarUrl: _text(data['pic']),
        credentials: {'token': token},
      ),
    );
  }

  /// 发送短信验证码（login.user.kugou.com，仅 HTTP）。
  Future<void> sendSmsCode(String mobile) async {
    final body = await _androidRequest(
      '/v7/send_mobile_code',
      host: 'login.user.kugou.com',
      useHttp: true,
      body: {'businessid': 5, 'mobile': mobile, 'plat': 3},
    );
    if (_toInt(body['status']) != 1) {
      final message = _text(body['data']);
      throw PlatformApiException(
        message.isEmpty
            ? '验证码发送失败（${_toInt(body['error_code'], -1)}）'
            : message,
      );
    }
  }

  /// 短信验证码登录（AES + RSA 加密，对齐 KuGouMusicApi login_cellphone.js）。
  Future<MusicPlatformAccount> loginBySmsCode(
    String mobile,
    String code,
  ) async {
    final clienttimeMs = DateTime.now().millisecondsSinceEpoch;
    final aes = kgAesEncrypt({'mobile': mobile, 'code': code});
    final body = await _androidRequest(
      '/v7/login_by_verifycode',
      host: 'loginserviceretry.kugou.com',
      extraHeaders: {
        'User-Agent': 'Android16-1070-11440-130-0-LOGIN-wifi',
        'support-calm': '1',
      },
      body: {
        'plat': 1,
        'support_multi': 1,
        't1': 0,
        't2': 0,
        'clienttime_ms': clienttimeMs,
        // 服务端只回显打码手机号，格式：前 2 位 + ***** + 末 1 位。
        'mobile':
            '${mobile.substring(0, 2)}*****${mobile.substring(mobile.length - 1)}',
        'key': kgSignParamsKey(
          '$clienttimeMs',
          appid: '$_kgAppid',
          clientver: '$_kgClientver',
        ),
        'pk': kgRsaEncrypt({
          'clienttime_ms': clienttimeMs,
          'key': aes.rawKey,
        }).toUpperCase(),
        'params': aes.hex,
        't3': _kgLoginT3,
      },
    );
    final status = _toInt(body['status']);
    final data = body['data'] is Map
        ? Map<String, dynamic>.from(body['data'] as Map)
        : const <String, dynamic>{};
    final parsed = _parseLoginData(data, aes.rawKey);
    if (status != 1 || parsed.token.isEmpty || parsed.userid.isEmpty) {
      final errorCode = _toInt(body['error_code'], -1);
      final message = _text(body['data']);
      throw PlatformApiException(
        message.isNotEmpty
            ? message
            : errorCode == 20014
            ? '验证码错误或已过期'
            : '酷狗登录失败（$errorCode）',
      );
    }
    return MusicPlatformAccount(
      platform: MusicPlatform.kugou,
      userId: parsed.userid,
      nickname: parsed.nickname.isEmpty ? mobile : parsed.nickname,
      avatarUrl: parsed.pic,
      credentials: {'token': parsed.token},
    );
  }

  /// 账号密码登录（AES + RSA 加密，对齐 KuGouMusicApi login.js）。
  Future<MusicPlatformAccount> loginByPassword(
    String username,
    String password,
  ) async {
    final clienttimeMs = DateTime.now().millisecondsSinceEpoch;
    final aes = kgAesEncrypt({
      'pwd': password,
      'code': '',
      'clienttime_ms': clienttimeMs,
    });
    final body = await _androidRequest(
      '/v9/login_by_pwd',
      xRouter: 'login.user.kugou.com',
      body: {
        'plat': 1,
        'support_multi': 1,
        'clienttime_ms': clienttimeMs,
        't1': _kgLoginT1,
        't2': _kgLoginT2,
        't3': _kgLoginT3,
        'username': username,
        'params': aes.hex,
        'pk': kgRsaEncrypt({
          'clienttime_ms': clienttimeMs,
          'key': aes.rawKey,
        }).toUpperCase(),
      },
    );
    final status = _toInt(body['status']);
    final data = body['data'] is Map
        ? Map<String, dynamic>.from(body['data'] as Map)
        : const <String, dynamic>{};
    final parsed = _parseLoginData(data, aes.rawKey);
    if (status != 1 || parsed.token.isEmpty || parsed.userid.isEmpty) {
      final errorCode = _toInt(body['error_code'], -1);
      final message = _text(body['data']);
      throw PlatformApiException(
        message.isNotEmpty
            ? message
            : errorCode == 20014
            ? '账号或密码错误'
            : errorCode == 20028
            ? '本次登录需要安全验证，请改用扫码或网页登录'
            : '酷狗登录失败（$errorCode）',
      );
    }
    return MusicPlatformAccount(
      platform: MusicPlatform.kugou,
      userId: parsed.userid,
      nickname: parsed.nickname.isEmpty
          ? username
          : parsed.nickname,
      avatarUrl: parsed.pic,
      credentials: {'token': parsed.token},
    );
  }

  /// 拉取用户歌单列表（创建 + 收藏，分页）。
  Future<List<OnlinePlaylist>> fetchUserPlaylists(
    MusicPlatformAccount account,
  ) async {
    final token = account.credentials['token'] ?? '';
    final userid = account.userId;
    final playlists = <OnlinePlaylist>[];
    for (var page = 1; page <= 20; page++) {
      final body = await _androidRequest(
        '/v7/get_all_list',
        xRouter: 'cloudlist.service.kugou.com',
        extraParams: {'plat': '1', 'userid': userid, 'token': token},
        body: {
          'userid': userid,
          'token': token,
          'total_ver': 979,
          'type': 2,
          'page': page,
          'pagesize': 30,
        },
      );
      if (_toInt(body['status']) != 1) {
        if (playlists.isEmpty) {
          final errorCode = _toInt(body['error_code'], -1);
          final message = _text(body['data']);
          throw PlatformApiException(
            message.isNotEmpty
                ? '酷狗歌单加载失败：$message（$errorCode）'
                : '酷狗歌单加载失败（$errorCode），请重新登录',
          );
        }
        break;
      }
      final data = body['data'] is Map ? body['data'] as Map : const {};
      // get_all_list 的歌单数组在 data.info（"我喜欢"也是普通条目，
      // 带 global_collection_id）；不同版本偶用 list/special_list，
      // 按参考实现（KuGouMusicApi 及 teamspeak-music-bot）做兜底链。
      final List list = switch (data['info'] ?? data['special_list'] ?? data['list'] ?? data['special']) {
        final List value => value,
        _ => const [],
      };
      if (list.isEmpty) break;
      for (final value in list.whereType<Map>()) {
        final item = Map<String, dynamic>.from(value);
        final gcid = _text(
          item['global_collection_id'] ?? item['gcid'] ?? item['gid'],
        );
        final name = _text(item['name'] ?? item['special_name']);
        // 收藏歌单直接用 gcid；自建歌单（含我喜欢的）通常没有 gcid，
        // 用 id_<specialid> 形式让导入层经 specialid→global 换算。
        final specialId = _text(item['specialid']);
        final id = gcid.isNotEmpty
            ? gcid
            : specialId.isNotEmpty && specialId != '0'
            ? 'id_$specialId'
            : '';
        if (id.isEmpty || name.isEmpty) continue;
        var cover = _text(item['img'] ?? item['pic']);
        if (cover.contains('{size}')) {
          cover = cover.replaceAll('{size}', '240');
        }
        playlists.add(
          OnlinePlaylist(
            id: id,
            name: name,
            coverUrl: cover,
            songCount: _toInt(item['total'] ?? item['count']),
            // source=favorite 表示收藏的歌单。
            isFavorite: _text(item['source']) == 'favorite',
          ),
        );
      }
      if (list.length < 30) break;
    }
    return playlists;
  }
}
