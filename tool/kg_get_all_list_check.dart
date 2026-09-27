// 诊断：直接调用酷狗 get_all_list，观察服务端错误码。
//
// 目的：区分「签名被服务端拒绝」与「仅 token 失效」。
//   - 签名错误（如 error_code 20009 / HTTP 403）→ 服务端升级了校验
//   - token 错误（如 error_code 20004 之类）→ 签名没问题，设备端重登即可
//
// 运行：dart run tool/kg_get_all_list_check.dart [token] [userid]
// 不带参数时用假 token。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'package:xy_music/src/music_platform/platform_crypto.dart';

const _kgAppid = 1005;
const _kgClientver = 20489;
final _kgMid = BigInt.parse(
  md5.convert(utf8.encode('xy-music-mobile-kugou-device')).toString(),
  radix: 16,
).toString();

Future<void> main(List<String> args) async {
  final token = args.isNotEmpty ? args[0] : 'dummy-token-for-diagnosis';
  final userid = args.length > 1 ? args[1] : '123456789';
  final client = http.Client();
  try {
    final clienttime =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final params = <String, String>{
      'dfid': '-',
      'mid': _kgMid,
      'uuid': '-',
      'appid': '$_kgAppid',
      'clientver': '$_kgClientver',
      'clienttime': clienttime,
      'plat': '1',
      'userid': userid,
      'token': token,
    };
    final bodyJson = jsonEncode({
      'userid': userid,
      'token': token,
      'total_ver': 979,
      'type': 2,
      'page': 1,
      'pagesize': 30,
    });
    params['signature'] = kgAndroidSignature(params, body: bodyJson);
    final response = await client
        .post(
          Uri.https('gateway.kugou.com', '/v7/get_all_list', params),
          headers: {
            'User-Agent':
                'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi',
            'Content-Type': 'application/json',
            'x-router': 'cloudlist.service.kugou.com',
            'dfid': '-',
            'mid': _kgMid,
            'clienttime': clienttime,
            'kg-rc': '1',
            'kg-thash': '5d816a0',
            'kg-rec': '1',
            'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
          },
          body: bodyJson,
        )
        .timeout(const Duration(seconds: 20));
    stdout
      ..writeln('HTTP ${response.statusCode}')
      ..writeln('mid=$_kgMid')
      ..writeln(utf8.decode(response.bodyBytes));
  } finally {
    client.close();
  }
}
