import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../rust/api.dart';

/// 歌词数据层：播放详情页与首页底栏迷你歌词共用的行结构与解析
/// Provider。原先私有定义在 player_page.dart 内，底栏歌词也需要
/// 同一份数据，故提取到此处保证单一数据源（同参数的 FutureProvider
/// 在两处 watch 会共享缓存，不会重复请求/解析）。

class LyricWord {
  const LyricWord({
    required this.text,
    required this.start,
    required this.end,
  });

  final String text;
  final double start;
  final double end;
}

class LyricLine {
  const LyricLine({
    required this.time,
    required this.endTime,
    required this.text,
    required this.translation,
    required this.romaji,
    this.words = const [],
  });

  final double time;
  final double endTime;
  final String text;
  final String translation;
  final String romaji;
  final List<LyricWord> words;
}

/// 按歌曲路径读取持久化的歌词（本地 sidecar / 记忆歌词 / 关联结果）。
final songLyricsProvider = FutureProvider.autoDispose
    .family<List<LyricLine>, String>((ref, path) async {
      final dbPath = await ref.watch(dbPathProvider.future);
      final raw = await getSongLyricsPayload(dbPath: dbPath, path: path);
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      return decodeLyricLines(payload);
    });

/// 解析播放结果里内嵌的原始歌词（插件返回的 LRC/QRC 等）。
final embeddedLyricsProvider = FutureProvider.autoDispose
    .family<List<LyricLine>, String>((ref, rawLyrics) async {
      final raw = await parseLyrics(rawLyrics: rawLyrics);
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      return decodeLyricLines(payload);
    });

List<LyricLine> decodeLyricLines(Map<String, dynamic> payload) {
  return (payload['displayLines'] as List? ?? const [])
      .whereType<Map>()
      .map((value) {
        final line = Map<String, dynamic>.from(value);
        return LyricLine(
          time: (line['time'] as num?)?.toDouble() ?? 0,
          endTime: (line['endTime'] as num?)?.toDouble() ?? 0,
          text: line['text'] as String? ?? '',
          translation: line['translation'] as String? ?? '',
          romaji: line['romaji'] as String? ?? '',
          words: decodeLyricWords(line['words']),
        );
      })
      .where((line) => line.text.trim().isNotEmpty)
      .toList();
}

List<LyricWord> decodeLyricWords(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((raw) {
        final word = Map<String, dynamic>.from(raw);
        return LyricWord(
          text: word['text']?.toString() ?? '',
          start: (word['start'] as num?)?.toDouble() ?? 0,
          end: (word['end'] as num?)?.toDouble() ?? 0,
        );
      })
      .where((word) => word.text.isNotEmpty)
      .toList();
}

/// 按播放位置定位当前歌词行索引；无匹配时停在首行。
int lyricActiveIndex(List<LyricLine> lines, double position) {
  var active = lines.lastIndexWhere((line) => line.time <= position);
  if (active < 0) active = 0;
  return active;
}
