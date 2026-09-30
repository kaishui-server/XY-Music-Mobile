import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/plugins/qrc_decrypt.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('诊断：与 Rust 解密原始字节对比', () {
    final hex = File('rust/tests/canglangge_lyric.hex').readAsStringSync().trim();
    final raw = decryptQrcCipherRawHex(hex);
    // Rust: 789c9d55cb72e25610ddfb2bf405173d1042dece3ade645699d22e55a954a52a
    // ignore: avoid_print
    print('dart_raw_head_32 = ${raw.substring(0, 64)}');
    // ignore: avoid_print
    print('dart_raw_len = ${raw.length ~/ 2}');
    // Rust trace: s0=0dd1292f s1=8951ce04 f0=aa4a14d2
    //             k0_0=f03a0018caa2 k1_0=30a04440a0c9 k2_0=d02c0400ca82
    // ignore: avoid_print
    print('dart_trace = ${debugDesTrace(hex.substring(0, 16))}');
  });

  test('沧浪歌真实密文（普通 LRC）解密出歌词行', () {
    final hex = File('rust/tests/canglangge_lyric.hex').readAsStringSync().trim();
    final plain = decryptQrcCipher(hex);
    expect(plain, isNotNull);
    expect(plain!, contains('[00:01.71]作词：非欢'));
    expect(plain, contains('[02:58.62]终归有你与我 踏破沧浪'));
  });

  test('逐字 QRC 密文解密保留词级时间轴', () {
    const hex = '28feb85c1e5b0aee52751548debf8cec52f70ac1da86688e31bcd4d2a45cb2c8160f5c250523e901f07ebf7fe6d77f6faa0f5043b807fcc537f7187d35c7679b37036be3184b3105526561110e1753714a7e6d1d7f17b0b2a10fe8c072d2e43ef5ec7d25bc331953a9ca7bf72bc291aa1c86176920dd579407719661fa2779178156cd4d9c435d39b7d92fad21e1e16de1096ea95d514b6e9d649c010e4f4003d763cf03ee9144d0ee69b070891a4636';
    final plain = decryptQrcCipher(hex);
    expect(plain, isNotNull);
    // 该样本解密产物是 ESLRC 词级时间轴格式：[start,dur]行 (start,dur)词
    expect(plain!, contains(RegExp(r'\[\d+,\d+\].+\(\d+,\d+\)')));
  });

  test('多段密文按行独立解密拼接（主歌词 + 翻译）', () {
    final hex = File('rust/tests/canglangge_lyric.hex').readAsStringSync().trim();
    final combined = '$hex\n$hex';
    final plain = decryptQrcLyrics(combined);
    expect(plain, isNotNull);
    expect(plain!.split('[00:01.71]作词：非欢').length, 3);
  });

  test('假密文解密失败返回 null', () {
    final fake = List.filled(8, '8e1f2a3b4c5d6e7f').join();
    expect(decryptQrcCipher(fake), isNull);
    expect(decryptQrcLyrics(fake), isNull);
  });

  test('明文歌词原样返回（非密文输入）', () {
    const plain = '[00:01.71]作词：非欢\n[00:02.96]作曲：白金明';
    final result = decryptQrcLyrics(plain);
    // 全明文：无密文行被解出 → null（调用方维持原样）
    expect(result, isNull);
  });
}
