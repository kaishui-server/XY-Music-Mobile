import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// QQ 音乐 QMC 解密（对齐 MusicFree 桌面 Mp3UtilModule.kt 的 Kotlin 实现，
/// 纯 Dart 数学移植）：
/// ① [decryptEKey]：ekey（base64）V1/V2 → TEA 解密还原 raw key；
/// ② [QmcDecoder]：MapL（key≤300B）/RC4（key>300B）两种模式的流式分块
///    解密，支持任意起始偏移（Range/seek 场景按全局 offset 定位）。
/// 用途：MusicFree 插件（QQ L1/L2）返回 *.mflac 加密流 + ekey，XY 插件
/// 引擎原本丢弃 ekey 导致无法播放；现由回环代理在转发流时边拉边解。

const int _kRounds = 16;
const int _kDelta = 0x9E3779B9;
const int _kMask32 = 0xFFFFFFFF;

// EKEY_V2_PREFIX = base64("QQMusic EncV2,Key:")
const String _kEkeyV2Prefix = 'UVFNdXNpYyBFbmNWMixLZXk6';

final Uint8List _kEkeyV2Key1 = Uint8List.fromList(<int>[
  0x33, 0x38, 0x36, 0x5a, 0x4a, 0x59, 0x21, 0x40,
  0x23, 0x2a, 0x24, 0x25, 0x5e, 0x26, 0x29, 0x28,
]);
final Uint8List _kEkeyV2Key2 = Uint8List.fromList(<int>[
  0x2a, 0x2a, 0x23, 0x21, 0x28, 0x23, 0x24, 0x25,
  0x26, 0x5e, 0x61, 0x31, 0x63, 0x5a, 0x2c, 0x54,
]);

int _readU32BE(Uint8List b, int off) =>
    ((b[off] & 0xFF) << 24) |
    ((b[off + 1] & 0xFF) << 16) |
    ((b[off + 2] & 0xFF) << 8) |
    (b[off + 3] & 0xFF);

void _writeU32BE(Uint8List b, int off, int v) {
  b[off] = (v >>> 24) & 0xFF;
  b[off + 1] = (v >>> 16) & 0xFF;
  b[off + 2] = (v >>> 8) & 0xFF;
  b[off + 3] = v & 0xFF;
}

int _ecbSingleRound(int value, int sum, int key1, int key2) {
  final left = ((value << 4) & _kMask32) + key1;
  final right = ((value >>> 5) & _kMask32) + key2;
  final mid = (sum + value) & _kMask32;
  return (left ^ mid ^ right) & _kMask32;
}

(int, int) _decryptBlock(int blockHi, int blockLo, List<int> keyWords) {
  var y = blockHi & _kMask32;
  var z = blockLo & _kMask32;
  var sum = (_kDelta * _kRounds) & _kMask32;
  for (var round = 0; round < _kRounds; round++) {
    final tmp1 = _ecbSingleRound(y, sum, keyWords[2], keyWords[3]);
    z = (z - tmp1) & _kMask32;
    final tmp0 = _ecbSingleRound(z, sum, keyWords[0], keyWords[1]);
    y = (y - tmp0) & _kMask32;
    sum = (sum - _kDelta) & _kMask32;
  }
  return (y, z);
}

/// TC-TEA CBC 解密（16 轮）。返回去掉 padding/salt 的明文段。
Uint8List _tcTeaDecrypt(Uint8List cipher, Uint8List key) {
  final keyWords = <int>[
    _readU32BE(key, 0),
    _readU32BE(key, 4),
    _readU32BE(key, 8),
    _readU32BE(key, 12),
  ];
  assert(cipher.length % 8 == 0 && cipher.length >= 10,
      'Invalid cipher length');
  final plain = Uint8List(cipher.length);
  var iv1Hi = 0, iv1Lo = 0, iv2Hi = 0, iv2Lo = 0;
  var off = 0;
  while (off < cipher.length) {
    final cHi = _readU32BE(cipher, off);
    final cLo = _readU32BE(cipher, off + 4);
    final xHi = (cHi ^ iv2Hi) & _kMask32;
    final xLo = (cLo ^ iv2Lo) & _kMask32;
    final (dHi, dLo) = _decryptBlock(xHi, xLo, keyWords);
    final pHi = (dHi ^ iv1Hi) & _kMask32;
    final pLo = (dLo ^ iv1Lo) & _kMask32;
    _writeU32BE(plain, off, pHi);
    _writeU32BE(plain, off + 4, pLo);
    iv1Hi = cHi;
    iv1Lo = cLo;
    iv2Hi = dHi;
    iv2Lo = dLo;
    off += 8;
  }
  final padSize = plain[0] & 0x7;
  const saltLen = 2, zeroLen = 7;
  final start = 1 + padSize + saltLen;
  final end = cipher.length - zeroLen;
  for (var i = end; i < plain.length; i++) {
    if (plain[i] != 0) throw const FormatException('Invalid TEA padding');
  }
  return Uint8List.sublistView(plain, start, end);
}

Uint8List _makeSimpleKey() {
  final result = Uint8List(8);
  for (var i = 0; i < 8; i++) {
    final tan = math.tan(106.0 + i * 0.1);
    final scaled = tan.abs() * 100.0;
    result[i] = scaled.truncate() & 0xFF;
  }
  return result;
}

/// ekey V1：base64 → header(8B)+cipher → makeSimpleKey+header 组 TEA 密钥
/// → 解密，返回 header + recovered（raw QMC key）。
Uint8List _decryptEKeyV1(String base64Text) {
  final decoded = base64.decode(base64Text);
  if (decoded.length < 12) throw const FormatException('EKey too short');
  final header = Uint8List.sublistView(decoded, 0, 8);
  final cipher = Uint8List.sublistView(decoded, 8);
  final simpleKey = _makeSimpleKey();
  final teaKey = Uint8List(16);
  for (var i = 0; i < 8; i++) {
    teaKey[i * 2] = simpleKey[i];
    teaKey[i * 2 + 1] = header[i];
  }
  final recovered = _tcTeaDecrypt(cipher, teaKey);
  final out = Uint8List(8 + recovered.length)
    ..setRange(0, 8, header)
    ..setRange(8, 8 + recovered.length, recovered);
  return out;
}

/// ekey V2："QQMusic EncV2,Key:" 前缀 → 双层 TEA（KEY1→KEY2）→ 去 0 尾 →
/// 再走 V1。
Uint8List _decryptEKeyV2(String base64Text) {
  var payload = base64Text;
  if (payload.startsWith(_kEkeyV2Prefix)) {
    payload = payload.substring(_kEkeyV2Prefix.length);
  }
  var data = base64.decode(payload);
  data = _tcTeaDecrypt(Uint8List.fromList(data), _kEkeyV2Key1);
  data = _tcTeaDecrypt(data, _kEkeyV2Key2);
  var end = data.length;
  while (end > 0 && data[end - 1] == 0) {
    end--;
  }
  final trimmed = utf8.decode(Uint8List.sublistView(data, 0, end));
  return _decryptEKeyV1(trimmed);
}

/// MusicFree normalizeEkey：超长 ekey 只保留末 704 字符。
String normalizeEkey(String input) {
  final s = input.trim();
  return s.length > 704 ? s.substring(s.length - 704) : s;
}

/// ekey（base64 字符串）→ raw QMC key 字节。
Uint8List decryptEKey(String base64Text) {
  final cleaned = normalizeEkey(base64Text);
  return cleaned.startsWith(_kEkeyV2Prefix)
      ? _decryptEKeyV2(cleaned)
      : _decryptEKeyV1(cleaned);
}

/// QMC 流式解密器（MapL / RC4 双模式），decryptChunk 原位改写 buffer。
class QmcDecoder {
  QmcDecoder._(this._mode, this._compressedKey, this._key, this._hash,
      this._keyStream);

  factory QmcDecoder.fromRawKey(List<int> rawKey) {
    final key = Uint8List.fromList(rawKey);
    if (key.isEmpty) throw const FormatException('Key is empty');
    if (key.length <= 300) {
      return QmcDecoder._(_modeMapL, _keyCompress(key), null, 0, null);
    }
    // RC4 模式：预派生 0x1400+512 的 keystream 缓存。
    final cacheSize = 0x1400 + 512;
    final keyStream = Uint8List(cacheSize);
    final state = Uint8List(key.length);
    for (var i = 0; i < key.length; i++) {
      state[i] = i & 0xFF;
    }
    var ii = 0, jj = 0;
    while (ii < key.length) {
      jj = (jj + state[ii] + key[ii % key.length]) % key.length;
      final tmp = state[ii];
      state[ii] = state[jj];
      state[jj] = tmp;
      ii++;
    }
    var i = 0, j = 0, k = 0;
    while (k < cacheSize) {
      i = (i + 1) % key.length;
      j = (j + state[i]) % key.length;
      final tmp = state[i];
      state[i] = state[j];
      state[j] = tmp;
      keyStream[k++] = state[(state[i] + state[j]) % key.length];
    }
    final hash = _calculateQMCHash(key);
    return QmcDecoder._(_modeRc4, null, key, hash, keyStream);
  }

  static const String _modeMapL = 'MapL';
  static const String _modeRc4 = 'RC4';

  final String _mode;
  final Uint8List? _compressedKey;
  final Uint8List? _key;
  final double _hash;
  final Uint8List? _keyStream;

  static Uint8List _keyCompress(Uint8List longKey) {
    const indexOffset = 71214;
    const v1KeySize = 128;
    final n = longKey.length;
    final result = Uint8List(v1KeySize);
    for (var i = 0; i < v1KeySize; i++) {
      final index = (i * i + indexOffset) % n;
      final keyByte = longKey[index] & 0xFF;
      final shift = (index + 4) % 8;
      result[i] =
          (((keyByte << shift) & 0xFF) | (keyByte >>> shift)) & 0xFF;
    }
    return result;
  }

  static double _calculateQMCHash(Uint8List key) {
    var hash = 1;
    for (final b in key) {
      final v = b & 0xFF;
      if (v == 0) continue;
      final next = (hash * v) & _kMask32;
      if (next == 0 || next <= hash) break;
      hash = next;
    }
    return hash.toDouble();
  }

  static int _getSegmentKey(int id, int seed, double hash) {
    if (seed == 0) return 0;
    final denominator = (id + 1) * seed;
    final result = hash / denominator * 100.0;
    return result.floor();
  }

  /// 原位解密 [buf]，[startOffset] 为该段在完整文件中的绝对偏移。
  void decryptChunk(Uint8List buf, int startOffset) {
    if (_mode == _modeMapL) {
      final ck = _compressedKey!;
      for (var i = 0; i < buf.length; i++) {
        var off = startOffset + i;
        if (off > 0x7FFF) off %= 0x7FFF;
        buf[i] ^= ck[off % ck.length];
      }
      return;
    }
    // RC4 模式。
    const firstSegmentSize = 0x80;
    const otherSegmentSize = 0x1400;
    final k = _key!;
    final ks = _keyStream!;
    final n = k.length;
    final hash = _hash;
    var offset = startOffset;
    var position = 0;

    void processFirst(int off, int len) {
      for (var i = 0; i < len; i++) {
        final current = off + i;
        final seed = k[current % n] & 0xFF;
        final idx = _getSegmentKey(current, seed, hash);
        final keyIdx = idx % n;
        buf[position + i] ^= k[keyIdx] & 0xFF;
      }
    }

    void processOther(int off, int len) {
      final id = off ~/ otherSegmentSize;
      final blockOffset = off % otherSegmentSize;
      final seed = k[id % n] & 0xFF;
      final skip = _getSegmentKey(id, seed, hash) & 0x1FF;
      for (var i = 0; i < len; i++) {
        final streamIdx = skip + blockOffset + i;
        if (streamIdx < ks.length) {
          buf[position + i] ^= ks[streamIdx];
        }
      }
    }

    if (offset < firstSegmentSize) {
      final len = (firstSegmentSize - offset).clamp(0, buf.length - position);
      if (len > 0) {
        processFirst(offset, len);
        position += len;
        offset += len;
      }
    }
    if (offset >= firstSegmentSize &&
        offset % otherSegmentSize != 0 &&
        position < buf.length) {
      final excess = offset % otherSegmentSize;
      final alignment =
          (otherSegmentSize - excess).clamp(0, buf.length - position);
      if (alignment > 0) {
        processOther(offset, alignment);
        position += alignment;
        offset += alignment;
      }
    }
    while (position < buf.length) {
      final segment =
          (buf.length - position).clamp(0, otherSegmentSize);
      processOther(offset, segment);
      position += segment;
      offset += segment;
    }
  }
}
