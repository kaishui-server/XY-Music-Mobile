// 复测：baka 插件（QQ L1/L2）getLyric 返回 crypt:1 hex 密文，
// 蓝牙/通知栏链路修复后应先经 Rust parseLyrics 解密并重组为明文 LRC，
// 对端才能正常解析显示；明文歌词应原样透传。
//
// 同时验证 player_provider._isBridgeLyricsCipher 的判定规则与
// _decryptBridgeLyrics 重组逻辑（与生产实现同规则复刻）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xy_music/src/rust/frb_generated.dart' show RustLib;
import 'package:xy_music/src/rust/lib.dart';

/// 生产实现同规则：长串 hex、无时间标签视为密文。
bool isBridgeLyricsCipher(String lyrics) {
  final text = lyrics.trim();
  if (text.length < 64) return false;
  if (RegExp(r'\[\d{1,3}:\d{1,2}(?:[.:]\d+)?\]').hasMatch(text) ||
      RegExp(r'^\[\d+,\d+\]', multiLine: true).hasMatch(text)) {
    return false;
  }
  return RegExp(r'^[0-9a-fA-F\s]+$').hasMatch(text);
}

/// 生产实现同规则：displayLines 重组为明文 LRC。
String rebuildLrcFromPayload(Map<String, dynamic> decoded) {
  final lines = decoded['displayLines'];
  if (lines is! List || lines.isEmpty) return '';
  final sb = StringBuffer();
  for (final line in lines) {
    if (line is! Map) continue;
    final time = (line['time'] as num?)?.toDouble() ?? 0;
    var text = (line['text'] as String?)?.trim() ?? '';
    if (text.isEmpty) {
      text = (line['translation'] as String?)?.trim() ?? '';
    }
    if (text.isEmpty) continue;
    final mm = time ~/ 60;
    final ss = (time % 60).floor();
    final frac = ((time - time.floor()) * 100).round();
    sb.writeln(
        '[${mm.toString().padLeft(2, '0')}:${ss.toString().padLeft(2, '0')}.${frac.toString().padLeft(2, '0')}]$text');
  }
  return sb.toString().trim();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dllPath = p.join(
    Directory.current.path,
    'rust',
    'target',
    'debug',
    'xymusic_core.dll',
  );
  if (!File(dllPath).existsSync()) {
    test('需要预先编译的 xymusic_core.dll', () {}, skip: '请先 cargo build');
    return;
  }

  setUpAll(() async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(dllPath));
  });

  test('QQ crypt:1 密文 → parseLyrics 解密 → 重组为明文 LRC', () async {
    // 真实 QQ 密文样本（沧浪歌，普通 LRC 密文）
    final hex = File('rust/tests/canglangge_lyric.hex').readAsStringSync().trim();
    expect(isBridgeLyricsCipher(hex), isTrue, reason: 'QQ 密文应判为密文');

    final jsonStr = await parseLyrics(rawLyrics: hex);
    final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
    final rebuilt = rebuildLrcFromPayload(decoded);

    expect(rebuilt, isNotEmpty, reason: '解密后应重组出歌词行');
    expect(rebuilt, contains('[00:01.71]作词：非欢'));
    expect(rebuilt, contains('[02:58.62]终归有你与我 踏破沧浪'));
    expect(
      RegExp(r'\[\d{2}:\d{2}\.\d{2}\]').hasMatch(rebuilt),
      isTrue,
      reason: '重组结果必须带 LRC 时间标签，蓝牙端才能解析',
    );
    // 关键断言：推送内容不再是 hex 密文
    expect(isBridgeLyricsCipher(rebuilt), isFalse, reason: '重组结果不应再是密文');
    // ignore: avoid_print
    print('重组明文前 300 字:\n${rebuilt.length > 300 ? rebuilt.substring(0, 300) : rebuilt}');
  });

  test('明文 LRC 原样透传（不判为密文、不触发解密）', () async {
    const plain = '[00:01.71]作词：非欢\n[00:02.96]作曲：白金明\n[00:12.44]迷雾之中 寻一束微光';
    expect(isBridgeLyricsCipher(plain), isFalse, reason: '明文 LRC 不应判为密文');

    final jsonStr = await parseLyrics(rawLyrics: plain);
    final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
    final rebuilt = rebuildLrcFromPayload(decoded);
    expect(rebuilt, contains('作词：非欢'));
    expect(rebuilt, contains('寻一束微光'));
  });

  test('逐字 QRC 密文同样解密重组（baka 逐字源场景）', () async {
    const hex =
        '28feb85c1e5b0aee52751548debf8cec52f70ac1da86688e31bcd4d2a45cb2c8160f5c250523e901f07ebf7fe6d77f6faa0f5043b807fcc537f7187d35c7679b37036be3184b3105526561110e1753714a7e6d1d7f17b0b2a10fe8c072d2e43ef5ec7d25bc331953a9ca7bf72bc291aa1c86176920dd579407719661fa2779178156cd4d9c435d39b7d92fad21e1e16de1096ea95d514b6e9d649c010e4f4003d763cf03ee9144d0ee69b070891a4636';
    expect(isBridgeLyricsCipher(hex), isTrue);

    final jsonStr = await parseLyrics(rawLyrics: hex);
    final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
    final rebuilt = rebuildLrcFromPayload(decoded);
    expect(rebuilt, isNotEmpty, reason: '逐字 QRC 解密后应重组出展示行');
    expect(isBridgeLyricsCipher(rebuilt), isFalse);
    // ignore: avoid_print
    print('逐字密文重组前 200 字: ${rebuilt.length > 200 ? rebuilt.substring(0, 200) : rebuilt}');
  });
}
