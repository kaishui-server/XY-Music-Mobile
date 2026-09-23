// 临时诊断：用真实样本（tx/kw/mg 等）跑 Dart convertLxLyricToEnhancedLrc，
// 落盘增强 LRC 供 Rust 端 parse_lyrics 端到端诊断。
// 运行：LX_SAMPLE=kw_qingtian.json dart run test/lx_convert_check.dart
import 'dart:convert';
import 'dart:io';

import 'package:xy_music/src/player/lx_lyrics_builder.dart';

void main() {
  final sample = Platform.environment['LX_SAMPLE'] ?? 'tx.json';
  final raw = File('rust/target/lx_samples/$sample').readAsStringSync();
  final payload = jsonDecode(raw) as Map<String, dynamic>;
  final lxlyric = (payload['lxlyric'] as String).trim();
  final enhanced = convertLxLyricToEnhancedLrc(lxlyric);
  final lines = enhanced.split('\n');
  stdout.writeln('Dart 转换输出总行数: ${lines.length}');
  for (final i in [0, 1, 6, 16, 30]) {
    if (i < lines.length) {
      stdout.writeln('[$i] ${lines[i].length > 160 ? lines[i].substring(0, 160) : lines[i]}');
    }
  }
  // 词级行统计：含 <mm:ss.mmm> 词标记的行数。
  final wordLines = lines
      .where((l) => RegExp(r'<\d+:\d{2}\.\d{3}>').hasMatch(l))
      .length;
  stdout.writeln('含词级时间标记的行数: $wordLines / ${lines.length}');
  final built = buildLxLyricsRaw(Map<String, dynamic>.from(payload));
  final builtLines = built.split('\n');
  stdout.writeln('buildLxLyricsRaw 总行数: ${builtLines.length}');
  stdout.writeln('--- 转换失败回退检查: enhanced 为空? ${enhanced.isEmpty} ---');
  final outName = sample.replaceAll('.json', '_enhanced.lrc');
  File('rust/target/lx_samples/$outName').writeAsStringSync(enhanced);
  stdout.writeln('已落盘 rust/target/lx_samples/$outName');
}
