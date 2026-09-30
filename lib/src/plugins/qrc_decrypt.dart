import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:meta/meta.dart';

/// QQ 音乐 QRC/LRC 密文解密（crypt:1）。
///
/// 算法与 Rust 侧 lyric_fetcher::qrc_decrypt 逐行对齐：固定密钥
/// 3DES-ECB（lx-music-desktop 移植的位操作 DES 变体）+ 多格式解压
/// 兜底。宿主在把歌词交给下载/备份链路前先解成明文，解密失败交由
/// 调用方走平台老接口兜底，避免密文落盘成乱码。
const _kQrcKey = '!@#)(*\$%123ZXC!@!@#)(NHL';

const List<List<int>> _kSbox = [
  [
    14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, //
    0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, //
    4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, //
    15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13, //
  ],
  [
    15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, //
    3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5, //
    0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, //
    13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9, //
  ],
  [
    10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, //
    13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, //
    13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, //
    1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12, //
  ],
  [
    7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, //
    13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, //
    10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, //
    3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14, //
  ],
  [
    2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, //
    14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, //
    4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, //
    11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3, //
  ],
  [
    12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, //
    10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, //
    9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, //
    4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13, //
  ],
  [
    4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, //
    13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, //
    1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, //
    6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12, //
  ],
  [
    13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, //
    1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, //
    7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, //
    2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11, //
  ],
];

int _bitnum(Uint8List a, int b, int c) {
  final index = (b ~/ 32) * 4 + 3 - (b % 32) ~/ 8;
  final shift = 7 - (b % 8);
  return ((a[index] >> shift) & 1) << c;
}

int _bitnumIntr(int a, int b, int c) => ((a >> (31 - b)) & 1) << c;

int _bitnumIntl(int a, int b, int c) => ((a << b) & 0x80000000) >> c;

int _sboxBit(int a) => (a & 32) | ((a & 31) >> 1) | ((a & 1) << 4);

(int, int) _initialPermutation(Uint8List input) {
  final s0 = _bitnum(input, 57, 31) |
      _bitnum(input, 49, 30) |
      _bitnum(input, 41, 29) |
      _bitnum(input, 33, 28) |
      _bitnum(input, 25, 27) |
      _bitnum(input, 17, 26) |
      _bitnum(input, 9, 25) |
      _bitnum(input, 1, 24) |
      _bitnum(input, 59, 23) |
      _bitnum(input, 51, 22) |
      _bitnum(input, 43, 21) |
      _bitnum(input, 35, 20) |
      _bitnum(input, 27, 19) |
      _bitnum(input, 19, 18) |
      _bitnum(input, 11, 17) |
      _bitnum(input, 3, 16) |
      _bitnum(input, 61, 15) |
      _bitnum(input, 53, 14) |
      _bitnum(input, 45, 13) |
      _bitnum(input, 37, 12) |
      _bitnum(input, 29, 11) |
      _bitnum(input, 21, 10) |
      _bitnum(input, 13, 9) |
      _bitnum(input, 5, 8) |
      _bitnum(input, 63, 7) |
      _bitnum(input, 55, 6) |
      _bitnum(input, 47, 5) |
      _bitnum(input, 39, 4) |
      _bitnum(input, 31, 3) |
      _bitnum(input, 23, 2) |
      _bitnum(input, 15, 1) |
      _bitnum(input, 7, 0);

  final s1 = _bitnum(input, 56, 31) |
      _bitnum(input, 48, 30) |
      _bitnum(input, 40, 29) |
      _bitnum(input, 32, 28) |
      _bitnum(input, 24, 27) |
      _bitnum(input, 16, 26) |
      _bitnum(input, 8, 25) |
      _bitnum(input, 0, 24) |
      _bitnum(input, 58, 23) |
      _bitnum(input, 50, 22) |
      _bitnum(input, 42, 21) |
      _bitnum(input, 34, 20) |
      _bitnum(input, 26, 19) |
      _bitnum(input, 18, 18) |
      _bitnum(input, 10, 17) |
      _bitnum(input, 2, 16) |
      _bitnum(input, 60, 15) |
      _bitnum(input, 52, 14) |
      _bitnum(input, 44, 13) |
      _bitnum(input, 36, 12) |
      _bitnum(input, 28, 11) |
      _bitnum(input, 20, 10) |
      _bitnum(input, 12, 9) |
      _bitnum(input, 4, 8) |
      _bitnum(input, 62, 7) |
      _bitnum(input, 54, 6) |
      _bitnum(input, 46, 5) |
      _bitnum(input, 38, 4) |
      _bitnum(input, 30, 3) |
      _bitnum(input, 22, 2) |
      _bitnum(input, 14, 1) |
      _bitnum(input, 6, 0);

  return (s0, s1);
}

Uint8List _inversePermutation(int s0, int s1) {
  final data = Uint8List(8);
  data[3] = _bitnumIntr(s1, 7, 7) |
      _bitnumIntr(s0, 7, 6) |
      _bitnumIntr(s1, 15, 5) |
      _bitnumIntr(s0, 15, 4) |
      _bitnumIntr(s1, 23, 3) |
      _bitnumIntr(s0, 23, 2) |
      _bitnumIntr(s1, 31, 1) |
      _bitnumIntr(s0, 31, 0);
  data[2] = _bitnumIntr(s1, 6, 7) |
      _bitnumIntr(s0, 6, 6) |
      _bitnumIntr(s1, 14, 5) |
      _bitnumIntr(s0, 14, 4) |
      _bitnumIntr(s1, 22, 3) |
      _bitnumIntr(s0, 22, 2) |
      _bitnumIntr(s1, 30, 1) |
      _bitnumIntr(s0, 30, 0);
  data[1] = _bitnumIntr(s1, 5, 7) |
      _bitnumIntr(s0, 5, 6) |
      _bitnumIntr(s1, 13, 5) |
      _bitnumIntr(s0, 13, 4) |
      _bitnumIntr(s1, 21, 3) |
      _bitnumIntr(s0, 21, 2) |
      _bitnumIntr(s1, 29, 1) |
      _bitnumIntr(s0, 29, 0);
  data[0] = _bitnumIntr(s1, 4, 7) |
      _bitnumIntr(s0, 4, 6) |
      _bitnumIntr(s1, 12, 5) |
      _bitnumIntr(s0, 12, 4) |
      _bitnumIntr(s1, 20, 3) |
      _bitnumIntr(s0, 20, 2) |
      _bitnumIntr(s1, 28, 1) |
      _bitnumIntr(s0, 28, 0);
  data[7] = _bitnumIntr(s1, 3, 7) |
      _bitnumIntr(s0, 3, 6) |
      _bitnumIntr(s1, 11, 5) |
      _bitnumIntr(s0, 11, 4) |
      _bitnumIntr(s1, 19, 3) |
      _bitnumIntr(s0, 19, 2) |
      _bitnumIntr(s1, 27, 1) |
      _bitnumIntr(s0, 27, 0);
  data[6] = _bitnumIntr(s1, 2, 7) |
      _bitnumIntr(s0, 2, 6) |
      _bitnumIntr(s1, 10, 5) |
      _bitnumIntr(s0, 10, 4) |
      _bitnumIntr(s1, 18, 3) |
      _bitnumIntr(s0, 18, 2) |
      _bitnumIntr(s1, 26, 1) |
      _bitnumIntr(s0, 26, 0);
  data[5] = _bitnumIntr(s1, 1, 7) |
      _bitnumIntr(s0, 1, 6) |
      _bitnumIntr(s1, 9, 5) |
      _bitnumIntr(s0, 9, 4) |
      _bitnumIntr(s1, 17, 3) |
      _bitnumIntr(s0, 17, 2) |
      _bitnumIntr(s1, 25, 1) |
      _bitnumIntr(s0, 25, 0);
  data[4] = _bitnumIntr(s1, 0, 7) |
      _bitnumIntr(s0, 0, 6) |
      _bitnumIntr(s1, 8, 5) |
      _bitnumIntr(s0, 8, 4) |
      _bitnumIntr(s1, 16, 3) |
      _bitnumIntr(s0, 16, 2) |
      _bitnumIntr(s1, 24, 1) |
      _bitnumIntr(s0, 24, 0);
  return data;
}

int _desF(int state, Uint8List key) {
  final t1 = _bitnumIntl(state, 31, 0) |
      ((state & 0xf0000000) >> 1) |
      _bitnumIntl(state, 4, 5) |
      _bitnumIntl(state, 3, 6) |
      ((state & 0x0f000000) >> 3) |
      _bitnumIntl(state, 8, 11) |
      _bitnumIntl(state, 7, 12) |
      ((state & 0x00f00000) >> 5) |
      _bitnumIntl(state, 12, 17) |
      _bitnumIntl(state, 11, 18) |
      ((state & 0x000f0000) >> 7) |
      _bitnumIntl(state, 16, 23);

  final t2 = _bitnumIntl(state, 15, 0) |
      ((state & 0x0000f000) << 15) |
      _bitnumIntl(state, 20, 5) |
      _bitnumIntl(state, 19, 6) |
      ((state & 0x00000f00) << 13) |
      _bitnumIntl(state, 24, 11) |
      _bitnumIntl(state, 23, 12) |
      ((state & 0x000000f0) << 11) |
      _bitnumIntl(state, 28, 17) |
      _bitnumIntl(state, 27, 18) |
      ((state & 0x0000000f) << 9) |
      _bitnumIntl(state, 0, 23);

  final lrgstate = [
    (t1 >> 24) & 0xff,
    (t1 >> 16) & 0xff,
    (t1 >> 8) & 0xff,
    (t2 >> 24) & 0xff,
    (t2 >> 16) & 0xff,
    (t2 >> 8) & 0xff,
  ];
  final xorState = [
    lrgstate[0] ^ key[0],
    lrgstate[1] ^ key[1],
    lrgstate[2] ^ key[2],
    lrgstate[3] ^ key[3],
    lrgstate[4] ^ key[4],
    lrgstate[5] ^ key[5],
  ];

  final outputState = (_kSbox[0][_sboxBit(xorState[0] >> 2)] & 0xffffffff) << 28 |
      (_kSbox[1][_sboxBit(((xorState[0] & 0x03) << 4) | (xorState[1] >> 4))] & 0xffffffff) << 24 |
      (_kSbox[2][_sboxBit(((xorState[1] & 0x0f) << 2) | (xorState[2] >> 6))] & 0xffffffff) << 20 |
      (_kSbox[3][_sboxBit(xorState[2] & 0x3f)] & 0xffffffff) << 16 |
      (_kSbox[4][_sboxBit(xorState[3] >> 2)] & 0xffffffff) << 12 |
      (_kSbox[5][_sboxBit(((xorState[3] & 0x03) << 4) | (xorState[4] >> 4))] & 0xffffffff) << 8 |
      (_kSbox[6][_sboxBit(((xorState[4] & 0x0f) << 2) | (xorState[5] >> 6))] & 0xffffffff) << 4 |
      (_kSbox[7][_sboxBit(xorState[5] & 0x3f)] & 0xffffffff);

  return _bitnumIntl(outputState, 15, 0) |
      _bitnumIntl(outputState, 6, 1) |
      _bitnumIntl(outputState, 19, 2) |
      _bitnumIntl(outputState, 20, 3) |
      _bitnumIntl(outputState, 28, 4) |
      _bitnumIntl(outputState, 11, 5) |
      _bitnumIntl(outputState, 27, 6) |
      _bitnumIntl(outputState, 16, 7) |
      _bitnumIntl(outputState, 0, 8) |
      _bitnumIntl(outputState, 14, 9) |
      _bitnumIntl(outputState, 22, 10) |
      _bitnumIntl(outputState, 25, 11) |
      _bitnumIntl(outputState, 4, 12) |
      _bitnumIntl(outputState, 17, 13) |
      _bitnumIntl(outputState, 30, 14) |
      _bitnumIntl(outputState, 9, 15) |
      _bitnumIntl(outputState, 1, 16) |
      _bitnumIntl(outputState, 7, 17) |
      _bitnumIntl(outputState, 23, 18) |
      _bitnumIntl(outputState, 13, 19) |
      _bitnumIntl(outputState, 31, 20) |
      _bitnumIntl(outputState, 26, 21) |
      _bitnumIntl(outputState, 2, 22) |
      _bitnumIntl(outputState, 8, 23) |
      _bitnumIntl(outputState, 18, 24) |
      _bitnumIntl(outputState, 12, 25) |
      _bitnumIntl(outputState, 29, 26) |
      _bitnumIntl(outputState, 5, 27) |
      _bitnumIntl(outputState, 21, 28) |
      _bitnumIntl(outputState, 10, 29) |
      _bitnumIntl(outputState, 3, 30) |
      _bitnumIntl(outputState, 24, 31);
}

Uint8List _desCrypt(Uint8List input, List<Uint8List> key) {
  var (s0, s1) = _initialPermutation(input);
  for (var idx = 0; idx < 15; idx++) {
    final prevS1 = s1;
    s1 = _desF(s1, key[idx]) ^ s0;
    s0 = prevS1;
  }
  s0 = _desF(s1, key[15]) ^ s0;
  return _inversePermutation(s0, s1);
}

List<Uint8List> _desKeySchedule(Uint8List key, int mode) {
  final schedule = [
    for (var i = 0; i < 16; i++) Uint8List(6),
  ];
  const keyRndShift = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];
  const keyPermC = [
    56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, //
    58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, //
  ];
  const keyPermD = [
    62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, //
    60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3, //
  ];
  const keyCompression = [
    13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, //
    26, 19, 12, 1, 40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47, 43, 48, //
    38, 55, 33, 52, 45, 41, 49, 35, 28, 31, //
  ];

  var c = 0;
  for (var i = 0; i < 28; i++) {
    c |= _bitnum(key, keyPermC[i], 31 - i);
  }
  var d = 0;
  for (var i = 0; i < 28; i++) {
    d |= _bitnum(key, keyPermD[i], 31 - i);
  }

  for (var i = 0; i < 16; i++) {
    final shift = keyRndShift[i];
    // 28 位半密钥存储在 bit 31..4（_bitnum(..., 31 - i) 布局），循环
    // 左移后用 0xfffffff0 保留高 28 位（对齐 Rust 侧修复注释）。
    c = ((c << shift) | (c >> (28 - shift))) & 0xfffffff0;
    d = ((d << shift) | (d >> (28 - shift))) & 0xfffffff0;
    final togen = mode == 0 ? 15 - i : i;
    for (var j = 0; j < 24; j++) {
      schedule[togen][j ~/ 8] |= _bitnumIntr(c, keyCompression[j], 7 - (j % 8));
    }
    for (var j = 24; j < 48; j++) {
      schedule[togen][j ~/ 8] |=
          _bitnumIntr(d, keyCompression[j] - 27, 7 - (j % 8));
    }
  }
  return schedule;
}

List<List<Uint8List>> _tripleDesKeySetup(Uint8List key, int mode) {
  final key0 = Uint8List.sublistView(key, 0, 8);
  final key8 = Uint8List.sublistView(key, 8, 16);
  final key16 = Uint8List.sublistView(key, 16, 24);
  if (mode == 1) {
    return [
      _desKeySchedule(key0, 1),
      _desKeySchedule(key8, 0),
      _desKeySchedule(key16, 1),
    ];
  }
  return [
    _desKeySchedule(key16, 0),
    _desKeySchedule(key8, 1),
    _desKeySchedule(key0, 0),
  ];
}

Uint8List _tripleDesCrypt(Uint8List data, List<List<Uint8List>> schedules) {
  var temp = Uint8List.fromList(data.sublist(0, 8));
  for (var i = 0; i < 3; i++) {
    temp = _desCrypt(temp, schedules[i]);
  }
  return temp;
}

Uint8List _hexToBytes(String hex) {
  final trimmed = hex.trim();
  final out = BytesBuilder();
  for (var i = 0; i + 1 < trimmed.length; i += 2) {
    final value = int.tryParse(trimmed.substring(i, i + 2), radix: 16);
    if (value != null) out.addByte(value);
  }
  return out.toBytes();
}

List<int>? _tryDecompress(List<int> Function() decoder) {
  try {
    final result = decoder();
    return result.isEmpty ? null : result;
  } catch (_) {
    return null;
  }
}

String? _decompressAny(Uint8List bytes) {
  // 顺序对齐 Rust：zlib → raw deflate → 跳过 zlib 头 → gzip。
  // Dart 标准库没有 flate2 的 sync-flush 逐块模式，跳过该变体；
  // 真实 QQ 密文产物是标准 zlib 流，其余变体由后续格式兜底。
  final attempts = [
    () => ZLibDecoder().convert(bytes),
    () => ZLibDecoder(raw: true).convert(bytes),
    () => bytes.length > 2
        ? ZLibDecoder().convert(bytes.sublist(2))
        : throw const FormatException('too short'),
    () => gzip.decode(bytes),
  ];
  for (final attempt in attempts) {
    final result = _tryDecompress(attempt);
    if (result == null) continue;
    var list = result;
    if (list.length >= 3 &&
        list[0] == 0xEF &&
        list[1] == 0xBB &&
        list[2] == 0xBF) {
      list = list.sublist(3);
    }
    return utf8.decode(list, allowMalformed: true);
  }
  return null;
}

/// 诊断用：单块 3DES 中间值（IP 后 s0/s1、第一轮 f、三个子密钥
/// schedule 首行），与 Rust test_support_des_trace 逐级比对。
@visibleForTesting
String debugDesTrace(String blockHex) {
  final block = _hexToBytes(blockHex.trim());
  final key = Uint8List.fromList(_kQrcKey.codeUnits);
  final schedules = _tripleDesKeySetup(key, 0);
  final (s0, s1) = _initialPermutation(block);
  final f0 = _desF(s1, schedules[0][0]);
  String hex6(Uint8List b) =>
      b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  final k0 = hex6(schedules[0][0]);
  final k1 = hex6(schedules[1][0]);
  final k2 = hex6(schedules[2][0]);
  return 's0=${s0.toRadixString(16).padLeft(8, '0')} '
      's1=${s1.toRadixString(16).padLeft(8, '0')} '
      'f0=${f0.toRadixString(16).padLeft(8, '0')} '
      'k0_0=$k0 k1_0=$k1 k2_0=$k2';
}

/// 解密单段 QQ 密文（十六进制字符串）。失败返回 null。
String? decryptQrcCipher(String encryptedHex) {
  final trimmed = encryptedHex.trim();
  if (trimmed.isEmpty || trimmed.length % 2 != 0) return null;
  final encrypted = _hexToBytes(trimmed);
  if (encrypted.isEmpty) return null;

  final key = Uint8List.fromList(_kQrcKey.codeUnits);
  final schedules = _tripleDesKeySetup(key, 0);

  final decrypted = Uint8List.fromList(encrypted);
  // 只处理完整 8 字节块，尾部不完整块保持原样（对齐 Rust 实现）。
  for (var i = 0; i + 8 <= decrypted.length; i += 8) {
    final block = _tripleDesCrypt(
      Uint8List.sublistView(decrypted, i, i + 8),
      schedules,
    );
    decrypted.setRange(i, i + 8, block);
  }
  return _decompressAny(decrypted);
}

/// 诊断用：返回 3DES 解密后的原始字节（未解压）hex，用于与 Rust 侧
/// test_support_qrc_decrypt_raw 逐字节比对。
@visibleForTesting
String decryptQrcCipherRawHex(String encryptedHex) {
  final encrypted = _hexToBytes(encryptedHex.trim());
  final key = Uint8List.fromList(_kQrcKey.codeUnits);
  final schedules = _tripleDesKeySetup(key, 0);
  final decrypted = Uint8List.fromList(encrypted);
  for (var i = 0; i + 8 <= decrypted.length; i += 8) {
    final block = _tripleDesCrypt(
      Uint8List.sublistView(decrypted, i, i + 8),
      schedules,
    );
    decrypted.setRange(i, i + 8, block);
  }
  return decrypted.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// 解密歌词密文：支持多段密文按行拼接（主歌词 + 翻译，段边界会损坏
/// zlib 流，必须逐行独立解密）；任一行解密成功即保留该行明文，全部
/// 失败返回 null。多行输入中混有明文行时原样保留。
String? decryptQrcLyrics(String input) {
  final lines = input.split('\n');
  var anyDecrypted = false;
  final output = <String>[];
  for (final line in lines) {
    final trimmed = line.trim();
    final isHex = trimmed.isNotEmpty &&
        trimmed.length % 2 == 0 &&
        RegExp(r'^[0-9a-fA-F]+$').hasMatch(trimmed);
    if (!isHex) {
      output.add(line);
      continue;
    }
    final plain = decryptQrcCipher(trimmed);
    if (plain == null) {
      output.add(line);
    } else {
      anyDecrypted = true;
      output.add(plain);
    }
  }
  if (!anyDecrypted) return null;
  return output.join('\n');
}
