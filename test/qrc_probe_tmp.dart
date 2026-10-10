// 验证 pointycastle 3DES-ECB 解密 QQ QRC 密文（与 Rust qrc_decrypt 对齐）
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

const qrcKey = '!@#)(*\$%123ZXC!@!@#)(NHL';

Uint8List hexToBytes(String hex) {
  final out = BytesBuilder();
  for (var i = 0; i + 1 < hex.length; i += 2) {
    out.addByte(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return out.toBytes();
}

Uint8List desedeEcb(Uint8List data, bool forEncryption) {
  final engine = DESedeEngine();
  engine.init(forEncryption, DESedeParameters(Uint8List.fromList(qrcKey.codeUnits)));
  final out = BytesBuilder();
  for (var i = 0; i + 8 <= data.length; i += 8) {
    final block = Uint8List(8)..setRange(0, 8, data.sublist(i, i + 8));
    final processed = engine.processBlock(block, 0, block, 0);
    // processBlock 返回输出偏移字节数，结果写在 block 里
    out.add(block.sublist(0, processed));
  }
  if (data.length % 8 != 0) out.add(data.sublist(data.length - data.length % 8));
  return out.toBytes();
}

List<int>? tryZlib(List<int> bytes) {
  try {
    return ZLibDecoder().convert(bytes);
  } catch (_) {
    return null;
  }
}

List<int>? tryDeflateRaw(List<int> bytes) {
  try {
    return ZLibDecoder(raw: true).convert(bytes);
  } catch (_) {
    return null;
  }
}

List<int>? tryZlibSkipHeader(List<int> bytes) {
  if (bytes.length < 2) return null;
  try {
    return ZLibDecoder().convert(bytes.sublist(2));
  } catch (_) {
    return null;
  }
}

String decompressAny(Uint8List bytes) {
  for (final attempt in [
    tryZlib(bytes),
    tryDeflateRaw(bytes),
    tryZlibSkipHeader(bytes),
  ]) {
    if (attempt != null && attempt.isNotEmpty) {
      var list = attempt;
      if (list.length >= 3 &&
          list[0] == 0xEF && list[1] == 0xBB && list[2] == 0xBF) {
        list = list.sublist(3);
      }
      return utf8.decode(list, allowMalformed: true);
    }
  }
  return '';
}

void probe(String name, String hex) {
  final cipher = hexToBytes(hex.trim());
  final keyNormal = Uint8List.fromList(qrcKey.codeUnits);
  final keyReversed = Uint8List.fromList([
    ...qrcKey.codeUnits.sublist(16, 24),
    ...qrcKey.codeUnits.sublist(8, 16),
    ...qrcKey.codeUnits.sublist(0, 8),
  ]);
  for (final entry in [
    ['normal-key', keyNormal],
    ['reversed-key', keyReversed],
  ]) {
    for (final dir in [false, true]) {
      final engine = DESedeEngine();
      engine.init(dir, DESedeParameters(entry[1] as Uint8List));
      final first = Uint8List(8)..setRange(0, 8, cipher.sublist(0, 8));
      engine.processBlock(first, 0, first, 0);
      final head = first
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      print('[$name] ${entry[0]} enc=$dir first8=0x$head');
    }
  }
  final dec = desedeEcb(cipher, false);
  var plain = decompressAny(dec);
  print('[$name] decrypt(false) -> ${plain.isEmpty ? "FAIL" : "OK"}');
  if (plain.isNotEmpty) {
    print('  head: ${plain.substring(0, plain.length > 120 ? 120 : plain.length)}');
  } else {
    final enc = desedeEcb(cipher, true);
    plain = decompressAny(enc);
    print('[$name] decrypt(true) -> ${plain.isEmpty ? "FAIL" : "OK"}');
    if (plain.isNotEmpty) {
      print('  head: ${plain.substring(0, plain.length > 120 ? 120 : plain.length)}');
    }
  }
}

void main() {
  final canglang = File('rust/tests/canglangge_lyric.hex').readAsStringSync();
  probe('canglangge-LRC', canglang);
  probe(
    'qrc-word',
    '28feb85c1e5b0aee52751548debf8cec52f70ac1da86688e31bcd4d2a45cb2c8160f5c250523e901f07ebf7fe6d77f6faa0f5043b807fcc537f7187d35c7679b37036be3184b3105526561110e1753714a7e6d1d7f17b0b2a10fe8c072d2e43ef5ec7d25bc331953a9ca7bf72bc291aa1c86176920dd579407719661fa2779178156cd4d9c435d39b7d92fad21e1e16de1096ea95d514b6e9d649c010e4f4003d763cf03ee9144d0ee69b070891a4636',
  );
  // 假密文（测试场景）：解密/解压都应失败
  probe('fake-cipher', '8e1f2a3b4c5d6e7f' * 8);
}
