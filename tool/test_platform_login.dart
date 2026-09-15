// 协议验证脚本：QQ 原生扫码（xlogin → ptqrshow → ptqrlogin 轮询）
// 与酷狗原生扫码（v2/qrcode 创建 → v2/get_userinfo_qrcode 轮询）。
// 运行：dart run tool/test_platform_login.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show md5;

import '../lib/src/music_platform/platform_crypto.dart';

const browserUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

const kgUa = 'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi';
// mid 必须是十进制大整数字符串（MD5 hex 转 BigInt），十六进制会被
// gateway 业务接口拒收。
final kgMid = BigInt.parse(
  md5.convert(utf8.encode('xy-music-mobile-kugou-device')).toString(),
  radix: 16,
).toString();

Map<String, String> parseCookies(HttpClientResponse resp) {
  final result = <String, String>{};
  for (final header in resp.headers[HttpHeaders.setCookieHeader] ?? const []) {
    final pair = header.split(';').first.trim();
    final eq = pair.indexOf('=');
    if (eq <= 0) continue;
    result[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
  }
  return result;
}

int ptqrtoken(String qrsig) {
  var hash = 0;
  for (var i = 0; i < qrsig.length; i++) {
    hash += (hash << 5) + qrsig.codeUnitAt(i);
    hash &= 0x7FFFFFFF;
  }
  return hash;
}

Future<void> testQqQr() async {
  final client = HttpClient();
  const sUrl = 'https://y.qq.com/portal/redirect.html?loginType=2';

  final xloginUri = Uri.https('xui.ptlogin2.qq.com', '/cgi-bin/xlogin', {
    'appid': '716027609',
    'daid': '383',
    'style': '40',
    'low_login': '1',
    'hln_alias': '0',
    'no_verifyimg': '1',
    's_url': sUrl,
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
  });
  final xloginReq = await client.getUrl(xloginUri)
    ..headers.set(HttpHeaders.userAgentHeader, browserUa);
  final xloginResp = await xloginReq.close();
  await utf8.decoder.bind(xloginResp).join();
  final xloginCookies = parseCookies(xloginResp);
  final loginSig = xloginCookies['pt_login_sig'] ?? '';
  print('[QQ] xlogin status=${xloginResp.statusCode}');
  print('[QQ] xlogin cookies=$xloginCookies');

  final qrUri = Uri.https('ssl.ptlogin2.qq.com', '/ptqrshow', {
    'appid': '716027609',
    'e': '2',
    'l': 'M',
    's': '3',
    'd': '72',
    'v': '4',
    't': Random().nextDouble().toString(),
    'daid': '383',
    'pt_3rd_aid': '100497308',
  });
  final qrReq = await client.getUrl(qrUri)
    ..headers.set(HttpHeaders.userAgentHeader, browserUa);
  final qrResp = await qrReq.close();
  final qrBytes = Uint8List.fromList(
    await qrResp.fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    ),
  );
  final qrsig = parseCookies(qrResp)['qrsig'] ?? '';
  print(
    '[QQ] ptqrshow status=${qrResp.statusCode} qrsig=$qrsig '
    'imageBytes=${qrBytes.length}',
  );

  Future<void> poll(String label, Map<String, String> extra,
      {String referer = 'https://y.qq.com/'}) async {
    final base = <String, String>{
      'u1': sUrl,
      'ptqrtoken': '${ptqrtoken(qrsig)}',
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
      ...extra,
    };
    final req = await client.getUrl(
      Uri.https('ssl.ptlogin2.qq.com', '/ptqrlogin', base),
    )
      ..headers.set(HttpHeaders.userAgentHeader, browserUa)
      ..headers.set(HttpHeaders.refererHeader, referer)
      ..headers.set(
        HttpHeaders.cookieHeader,
        'qrsig=$qrsig; pt_login_sig=$loginSig',
      );
    final resp = await req.close();
    final body = await utf8.decoder.bind(resp).join();
    print('[QQ] $label status=${resp.statusCode} body=$body');
  }

  // 变体 A：当前实现的参数
  await poll('A 原参数', {'pt_3rd_aid': '100497308'});
  // 变体 B：u1 指向 graph 登录跳转页（ChillPatcher 风格）
  await poll('B u1=login_jump', {
    'u1': 'https://graph.qq.com/oauth2.0/login_jump',
    'pt_3rd_aid': '100497308',
  });
  // 变体 C：去掉 pt_3rd_aid
  await poll('C 无 pt_3rd_aid', {});
  // 变体 D：带 has_onekey
  await poll('D has_onekey', {
    'pt_3rd_aid': '100497308',
    'has_onekey': '1',
  });
  // 变体 E：Referer 换成 xlogin 页
  await poll(
    'E referer=xlogin',
    {'pt_3rd_aid': '100497308'},
    referer: xloginUri.toString(),
  );
  client.close();
}

Future<void> testKgQr() async {
  final client = HttpClient();
  final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  final params = <String, String>{
    'dfid': '-',
    'mid': kgMid,
    'uuid': '-',
    'appid': '1001',
    'clientver': '20489',
    'clienttime': '$clienttime',
    'type': '1',
    'plat': '4',
    'qrcode_txt':
        'https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=1005&',
    'srcappid': '2919',
  };
  params['signature'] = kgWebSignature(params);
  final req = await client
      .getUrl(Uri.https('login-user.kugou.com', '/v2/qrcode', params))
    ..headers.set(HttpHeaders.userAgentHeader, kgUa)
    ..headers.set('dfid', '-')
    ..headers.set('clienttime', '$clienttime')
    ..headers.set('mid', kgMid)
    ..headers.set('kg-rc', '1')
    ..headers.set('kg-thash', '5d816a0')
    ..headers.set('kg-rec', '1')
    ..headers.set('kg-rf', 'B9EDA08A64250DEFFBCADDEE00F8F25F');
  final resp = await req.close();
  final body = await utf8.decoder.bind(resp).join();
  print('[KG] qrcode status=${resp.statusCode}');
  print('[KG] qrcode body=${body.length > 200 ? '${body.substring(0, 200)}…' : body}');

  final key = RegExp(r'"qrcode":"([^"]+)"').firstMatch(body)?.group(1) ?? '';
  if (key.isEmpty) {
    print('[KG] 无 qrcode key，终止');
    client.close();
    return;
  }

  final clienttime2 = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final pollParams = <String, String>{
    'dfid': '-',
    'mid': kgMid,
    'uuid': '-',
    'appid': '1005',
    'clientver': '20489',
    'clienttime': '$clienttime2',
    'plat': '4',
    'srcappid': '2919',
    'qrcode': key,
  };
  pollParams['signature'] = kgWebSignature(pollParams);
  final pollReq = await client.getUrl(
    Uri.https('login-user.kugou.com', '/v2/get_userinfo_qrcode', pollParams),
  )
    ..headers.set(HttpHeaders.userAgentHeader, kgUa)
    ..headers.set('dfid', '-')
    ..headers.set('clienttime', '$clienttime2')
    ..headers.set('mid', kgMid)
    ..headers.set('kg-rc', '1')
    ..headers.set('kg-thash', '5d816a0')
    ..headers.set('kg-rec', '1')
    ..headers.set('kg-rf', 'B9EDA08A64250DEFFBCADDEE00F8F25F');
  final pollResp = await pollReq.close();
  final pollBody = await utf8.decoder.bind(pollResp).join();
  print('[KG] poll status=${pollResp.statusCode}');
  print('[KG] poll body=$pollBody');
  client.close();
}

Future<void> testKgSms() async {
  final client = HttpClient();
  final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final body = jsonEncode({
    'businessid': 5,
    'mobile': '10000000000',
    'plat': 3,
  });
  final params = <String, String>{
    'dfid': '-',
    'mid': kgMid,
    'uuid': '-',
    'appid': '1005',
    'clientver': '20489',
    'clienttime': '$clienttime',
  };
  // 安卓签名：参数串 + body 前后加盐
  const salt = 'OIlwieks28dk2k092lksi2UIkp';
  final sorted = (params.keys.toList()..sort())
      .map((k) => '$k=${params[k]}')
      .join();
  final signature = md5
      .convert(utf8.encode('$salt$sorted$body$salt'))
      .toString();
  params['signature'] = signature;

  final req = await client.postUrl(
    Uri.http('login.user.kugou.com', '/v7/send_mobile_code', params),
  )
    ..headers.contentType = ContentType.json
    ..headers.set(HttpHeaders.userAgentHeader, kgUa)
    ..headers.set('dfid', '-')
    ..headers.set('clienttime', '$clienttime')
    ..headers.set('mid', kgMid)
    ..headers.set('kg-rc', '1')
    ..headers.set('kg-thash', '5d816a0')
    ..headers.set('kg-rec', '1')
    ..headers.set('kg-rf', 'B9EDA08A64250DEFFBCADDEE00F8F25F');
  req.write(body);
  final resp = await req.close();
  final respBody = await utf8.decoder.bind(resp).join();
  print('[KG-SMS] send_mobile_code status=${resp.statusCode} body=$respBody');
  client.close();
}

const kgT1 =
    '562a6f12a6e803453647d16a08f5f0c2ff7eee692cba2ab74cc4c8ab47fc467561a7c6b'
    '586ce7dc46a63613b246737c03a1dc8f8d162d8ce1d2c71893d19f1d4b797685a4c6d3d8'
    '1341cbde65e488c4829a9b4d42ef2df470eb102979fa5adcdd9b4eecfea8b909ff7599ab'
    'eb49867640f10c3c70fc444effca9d15db44a9a6c907731e2bb0f22cd9b35363801699956'
    '93e5f0e2424e3378097d3813186e3fe96bbe7023808a0981b4e2b6135a76faac';
const kgT2 =
    '31c4daf4cf480169ccea1cb7d4a209295865a9d2b788510301694db229b87807469ea0d41'
    'b4d4b9173c2151da7294aeebfc9738df154bbdf11a4e117bb5dff6a3af8ce5ce333e681c1'
    'f29a44038f27567d58992eb81283e080778ac77db1400fdf49b7cf7e26be2e5af4da7830'
    'cc3be4';
const kgT3 = 'MCwwLDAsMCwwLDAsMCwwLDA=';

Future<void> testKgPwd(bool frontPad) async {
  final client = HttpClient();
  final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final clienttimeMs = DateTime.now().millisecondsSinceEpoch;
  final aes = kgAesEncrypt({
    'pwd': 'test123456',
    'code': '',
    'clienttime_ms': clienttimeMs,
  });
  final bodyMap = {
    'plat': 1,
    'support_multi': 1,
    'clienttime_ms': clienttimeMs,
    't1': kgT1,
    't2': kgT2,
    't3': kgT3,
    'username': 'test_not_exists@example.com',
    'params': aes.hex,
    'pk': kgRsaEncrypt(
      {'clienttime_ms': clienttimeMs, 'key': aes.rawKey},
      frontPad: frontPad,
    ),
  };
  final body = jsonEncode(bodyMap);
  final params = <String, String>{
    'dfid': '-',
    'mid': kgMid,
    'uuid': '-',
    'appid': '1005',
    'clientver': '20489',
    'clienttime': '$clienttime',
  };
  params['signature'] = kgAndroidSignature(params, body: body);
  final req = await client.postUrl(
    Uri.https('gateway.kugou.com', '/v9/login_by_pwd', params),
  )
    ..headers.contentType = ContentType.json
    ..headers.set(HttpHeaders.userAgentHeader, kgUa)
    ..headers.set('x-router', 'login.user.kugou.com')
    ..headers.set('dfid', '-')
    ..headers.set('clienttime', '$clienttime')
    ..headers.set('mid', kgMid)
    ..headers.set('kg-rc', '1')
    ..headers.set('kg-thash', '5d816a0')
    ..headers.set('kg-rec', '1')
    ..headers.set('kg-rf', 'B9EDA08A64250DEFFBCADDEE00F8F25F');
  req.write(body);
  final resp = await req.close();
  final respBody = await utf8.decoder.bind(resp).join();
  print('[KG-PWD frontPad=$frontPad] status=${resp.statusCode}');
  print(
    '[KG-PWD frontPad=$frontPad] body=${respBody.length > 300 ? '${respBody.substring(0, 300)}…' : respBody}',
  );
  client.close();
}

void main() async {
  await testQqQr();
  print('---');
  await testKgQr();
  print('---');
  await testKgSms();
  print('---');
  await testKgPwd(true);
  print('---');
  await testKgPwd(false);
  exit(0);
}
