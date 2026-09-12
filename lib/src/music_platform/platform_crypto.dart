import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// 第三方音乐平台登录/接口所需的加密与签名工具。
///
/// - 网易云音乐：weapi（AES-CBC 双层加密 + RSA NoPadding 包裹密钥）
/// - QQ 音乐：musics.fcg 的 zzc 签名
/// - 酷狗：AES-CBC（随机密钥经 MD5 派生）+ RSA 零填充加密 + 安卓接口 MD5 签名

final _random = Random.secure();

String _randomDigits(int length) {
  final sb = StringBuffer();
  for (var i = 0; i < length; i++) {
    sb.write(_random.nextInt(10));
  }
  return sb.toString();
}

String _randomChars(int length) {
  const chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  final sb = StringBuffer();
  for (var i = 0; i < length; i++) {
    sb.write(chars[_random.nextInt(chars.length)]);
  }
  return sb.toString();
}

Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text));

// ---------------------------------------------------------------------------
// 通用 AES-CBC-PKCS7
// ---------------------------------------------------------------------------

Uint8List _aesCbcEncrypt(List<int> key, List<int> iv, List<int> data) {
  final cipher = CBCBlockCipher(AESEngine())
    ..init(
      true,
      ParametersWithIV<KeyParameter>(
        KeyParameter(Uint8List.fromList(key)),
        Uint8List.fromList(iv),
      ),
    );
  final input = _pkcs7Pad(data);
  final output = Uint8List(input.length);
  var offset = 0;
  while (offset < input.length) {
    offset += cipher.processBlock(input, offset, output, offset);
  }
  return output;
}

Uint8List _aesCbcDecrypt(List<int> key, List<int> iv, List<int> data) {
  final cipher = CBCBlockCipher(AESEngine())
    ..init(
      false,
      ParametersWithIV<KeyParameter>(
        KeyParameter(Uint8List.fromList(key)),
        Uint8List.fromList(iv),
      ),
    );
  final input = Uint8List.fromList(data);
  if (input.length % cipher.blockSize != 0) {
    throw const FormatException('密文长度不是块的整数倍');
  }
  final output = Uint8List(input.length);
  var offset = 0;
  while (offset < input.length) {
    offset += cipher.processBlock(input, offset, output, offset);
  }
  if (output.isNotEmpty) {
    final pad = output.last;
    if (pad > 0 && pad <= cipher.blockSize) {
      return output.sublist(0, output.length - pad);
    }
  }
  return output;
}

Uint8List _pkcs7Pad(List<int> data) {
  final pad = 16 - (data.length % 16);
  return Uint8List.fromList([...data, ...List.filled(pad, pad)]);
}

// ---------------------------------------------------------------------------
// RSA（零填充，modPow 直接计算）
// ---------------------------------------------------------------------------

/// 从 PEM 提取 RSA 公钥 (modulus, exponent)。仅解析 DER 中的最后两个
/// INTEGER（1024 位公钥的 n 与 e），兼容网易/酷狗的公钥格式。
({BigInt n, BigInt e})? _parsePublicKeyPem(String pem) {
  final base64Body = pem
      .replaceAll(RegExp(r'-----[A-Z ]+-----'), '')
      .replaceAll(RegExp(r'\s'), '');
  final bytes = base64Decode(base64Body);
  final integers = <List<int>>[];
  for (var index = 0; index < bytes.length - 1; index++) {
    if (bytes[index] != 0x02) continue;
    var length = bytes[index + 1];
    var headerSize = 2;
    if (length & 0x80 != 0) {
      final lengthBytes = length & 0x7f;
      if (lengthBytes == 0 || index + 2 + lengthBytes > bytes.length) continue;
      length = 0;
      for (var i = 0; i < lengthBytes; i++) {
        length = (length << 8) | bytes[index + 2 + i];
      }
      headerSize = 2 + lengthBytes;
    }
    if (length > 0 && index + headerSize + length <= bytes.length) {
      integers.add(bytes.sublist(index + headerSize, index + headerSize + length));
    }
  }
  if (integers.length < 2) return null;
  BigInt toBigInt(List<int> list) {
    var value = BigInt.zero;
    for (final byte in list) {
      value = (value << 8) | BigInt.from(byte);
    }
    return value;
  }

  var modulus = integers[integers.length - 2];
  if (modulus.first == 0) modulus = modulus.sublist(1);
  var exponent = integers[integers.length - 1];
  if (exponent.first == 0) exponent = exponent.sublist(1);
  return (n: toBigInt(modulus), e: toBigInt(exponent));
}

String _rsaEncryptFixedHex({
  required String pem,
  required List<int> data,
  required int keyLength,
  bool frontPad = false,
}) {
  final key = _parsePublicKeyPem(pem);
  if (key == null) throw const FormatException('公钥解析失败');
  var padded = Uint8List.fromList(data);
  if (padded.length > keyLength) throw const FormatException('RSA 输入超过密钥长度');
  if (padded.length < keyLength) {
    final buf = Uint8List(keyLength);
    if (frontPad) {
      // 数据在缓冲区头部（KuGouMusicApi 风格）：m = data * 256^pad。
      buf.setRange(0, padded.length, padded);
    } else {
      // 数据在缓冲区尾部（网易 weapi 风格）：m = data。
      buf.setRange(keyLength - padded.length, keyLength, padded);
    }
    padded = buf;
  }
  var m = BigInt.zero;
  for (final byte in padded) {
    m = (m << 8) | BigInt.from(byte);
  }
  final result = m.modPow(key.e, key.n);
  var hex = result.toRadixString(16);
  if (hex.length % 2 == 1) hex = '0$hex';
  return hex.padLeft(keyLength * 2, '0');
}

// ---------------------------------------------------------------------------
// 网易云音乐 weapi
// ---------------------------------------------------------------------------

const _wyPresetKey = '0CoJUm6Qyw8W8jud';
const _wyIv = '0102030405060708';
const _wyPublicKeyPem = '''
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ3
7BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvakl
V8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44o
ncaTWz7OBGLbCiK45wIDAQAB
-----END PUBLIC KEY-----''';

/// 网易 weapi 请求加密：返回表单字段 `params` 与 `encSecKey`。
Map<String, String> wyWeapi(Object object) {
  final text = object is String ? object : jsonEncode(object);
  final secretKey = _randomDigits(16);
  final first = _aesCbcEncrypt(
    _utf8(_wyPresetKey),
    _utf8(_wyIv),
    _utf8(base64Encode(_utf8(text))),
  );
  final second = _aesCbcEncrypt(
    _utf8(secretKey),
    _utf8(_wyIv),
    _utf8(base64Encode(first)),
  );
  final encSecKey = _rsaEncryptFixedHex(
    pem: _wyPublicKeyPem,
    data: utf8.encode(secretKey).reversed.toList(),
    keyLength: 128,
  );
  return {
    'params': base64Encode(second),
    'encSecKey': encSecKey,
  };
}

// ---------------------------------------------------------------------------
// QQ 音乐 zzc 签名（musics.fcg）
// ---------------------------------------------------------------------------

const _zzcPart1Indexes = [23, 14, 6, 36, 16, 40, 7, 19];
const _zzcPart2Indexes = [16, 1, 32, 12, 19, 27, 8, 5];
const _zzcScrambleValues = [
  89, 39, 179, 150, 218, 82, 58, 252, 177, 52, 186, 123, 120, 64, 242, 133,
  143, 161, 121, 179,
];

/// QQ 音乐 musics.fcg 接口签名（zzc 版本）。
String qqZzcSign(String payload) {
  final hash = sha1.convert(utf8.encode(payload)).toString().toUpperCase();
  final part1 = _zzcPart1Indexes.where((i) => i < 40).map((i) => hash[i]).join();
  final part2 = _zzcPart2Indexes.map((i) => hash[i]).join();
  final part3 = Uint8List(20);
  for (var i = 0; i < 20; i++) {
    final byte = int.parse(hash.substring(i * 2, i * 2 + 2), radix: 16);
    part3[i] = byte ^ _zzcScrambleValues[i];
  }
  final b64 = base64Encode(part3).replaceAll(RegExp(r'[\/+=]'), '');
  return 'zzc$part1$b64$part2'.toLowerCase();
}

// ---------------------------------------------------------------------------
// 酷狗加密
// ---------------------------------------------------------------------------

const _kgPublicKeyPem = '''
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDIAG7QOELSYoIJvTFJhMpe1s/g
bjDJX51HBNnEl5HXqTW6lQ7LC8jr9fWZTwusknp+sVGzwd40MwP6U5yDE27M/X1
+UR4tvOGOqp94TJtQ1EPnWGWXngpeIW5GxoQGao1rmYWAu6oi1z9XkChrsUdC6DJ
E5E221wf/4WLFxwAtRQIDAQAB
-----END PUBLIC KEY-----''';

const kgAndroidSignSalt = 'OIlwieks28dk2k092lksi2UIkp';

/// 酷狗 web/H5 接口签名盐（login-user.kugou.com 扫码登录等）。
const kgWebSignSalt = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';

class KgAesResult {
  const KgAesResult({required this.hex, required this.rawKey});

  /// 加密结果的 hex 字符串（`params` 字段）。
  final String hex;

  /// 派生密钥前的随机密钥（用于 RSA 包裹与回传）。
  final String rawKey;
}

/// 酷狗 AES-CBC 加密（对齐 KuGouMusicApi cryptoAesEncrypt）：
/// 随机 16 位小写密钥 → key = md5(key)[0:32]，iv = key[16:]。
KgAesResult kgAesEncrypt(Object data) {
  final text = data is String ? data : jsonEncode(data);
  final rawKey = _randomChars(16).toLowerCase();
  final md5Key = md5.convert(utf8.encode(rawKey)).toString();
  final key = md5Key.substring(0, 32);
  final iv = key.substring(16);
  final encrypted = _aesCbcEncrypt(_utf8(key), _utf8(iv), _utf8(text));
  return KgAesResult(hex: _bytesToHex(encrypted), rawKey: rawKey);
}

/// 酷狗 AES-CBC 解密（secu_params）。
String kgAesDecrypt(String hex, String rawKey) {
  final md5Key = md5.convert(utf8.encode(rawKey)).toString();
  final key = md5Key.substring(0, 32);
  final iv = key.substring(16);
  final cipher = <int>[];
  for (var i = 0; i + 1 < hex.length; i += 2) {
    cipher.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return utf8.decode(_aesCbcDecrypt(_utf8(key), _utf8(iv), cipher));
}

/// 酷狗 RSA 加密（对齐 cryptoRSAEncrypt）：数据置于缓冲区头部
/// （frontPad），零填充 modPow，大写 hex 输出。
String kgRsaEncrypt(Object data, {bool frontPad = true}) {
  final text = data is String ? data : jsonEncode(data);
  return _rsaEncryptFixedHex(
    pem: _kgPublicKeyPem,
    data: _utf8(text),
    keyLength: 128,
    frontPad: frontPad,
  ).toUpperCase();
}

/// 酷狗安卓接口签名：参数按 key 排序拼成 `key=value`，
/// 前后加盐，请求体 JSON 拼在中间，整体 MD5。
String kgAndroidSignature(Map<String, String> params, {String body = ''}) {
  final sorted = (params.keys.toList()..sort())
      .map((key) => '$key=${params[key]}')
      .join();
  return md5
      .convert(
        utf8.encode('$kgAndroidSignSalt$sorted$body$kgAndroidSignSalt'),
      )
      .toString();
}

/// 酷狗短信登录 `key` 参数签名（对齐 signParamsKey）：
/// MD5(appid + 盐 + clientver + data)。
String kgSignParamsKey(
  String data, {
  required String appid,
  required String clientver,
}) {
  return md5
      .convert(utf8.encode('$appid$kgAndroidSignSalt$clientver$data'))
      .toString();
}

/// 酷狗 web/H5 接口签名（对齐 KuGouMusicApi signatureWebParams）：
/// 参数按 key 排序拼成 `key=value`，前后加盐，整体 MD5。
/// 注意参数值可能含 `&`（如 qrcode_txt），必须按 key 排序而不能切串。
String kgWebSignature(Map<String, String> params) {
  final sorted = (params.keys.toList()..sort())
      .map((key) => '$key=${params[key]}')
      .join();
  return md5
      .convert(utf8.encode('$kgWebSignSalt$sorted$kgWebSignSalt'))
      .toString();
}

String _bytesToHex(List<int> bytes) {
  final sb = StringBuffer();
  for (final byte in bytes) {
    sb.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
