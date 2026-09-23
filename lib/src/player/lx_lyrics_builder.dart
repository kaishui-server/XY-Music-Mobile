/// 将 LX/落雪插件返回的逐字歌词统一转换成 Enhanced LRC。
///
/// LX 的 `lxlyric` 常见格式是 `<相对偏移,持续时间>文字`，而移动端的
/// Rust 歌词解析器识别的是 `<绝对时间>文字`。如果不做这一步，歌词仍能
/// 显示，但会丢失 words 时间轴，逐字动效也就无法工作。

library;

final _lineTimestamp = RegExp(r'^\[(\d+:\d{2}(?:\.\d+)?)\](.*)$');
final _wordMarker = RegExp(r'<(-?\d+),(-?\d+)(?:,-?\d+)?>');
final _enhancedMarker = RegExp(r'<\d+:\d{2}(?:\.\d+)?>');
final _kuwoTag = RegExp(r'^\[kuwo:\s*(\S+)\s*\]', caseSensitive: false);

class _WordEntry {
  _WordEntry({
    required this.index,
    required this.endIndex,
    required this.startMs,
    required this.endMs,
  });

  final int index;
  final int endIndex;

  /// 逐字时间轴按 LX 官方 lrcTools 的 prevWord 规则允许向后收缩：
  /// 当前词提前开始时缩短前词的结束时间。
  int startMs;
  int endMs;
}

int? _timestampMs(String value) {
  final match = RegExp(
    r'^(\d+):(\d{2})(?:\.(\d{1,4}))?$',
  ).firstMatch(value.trim());
  if (match == null) return null;
  final minutes = int.tryParse(match.group(1)!);
  final seconds = int.tryParse(match.group(2)!);
  if (minutes == null || seconds == null || seconds >= 60) return null;
  final fraction = (match.group(3) ?? '').padRight(3, '0');
  final millis =
      int.tryParse(
        fraction.substring(0, fraction.length > 3 ? 3 : fraction.length),
      ) ??
      0;
  return minutes * 60000 + seconds * 1000 + millis;
}

String _formatTimestamp(int value) {
  final safe = value < 0 ? 0 : value;
  final totalSeconds = safe ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  final millis = safe % 1000;
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}';
}

List<_WordEntry> _entriesForLine({
  required List<RegExpMatch> markers,
  required int? lineStartMs,
  required bool kuwo,
  required int kuwoOffset,
  required int kuwoOffset2,
}) {
  if (markers.isEmpty) return const [];
  final entries = <_WordEntry>[];
  for (final marker in markers) {
    final first = int.tryParse(marker.group(1) ?? '');
    final second = int.tryParse(marker.group(2) ?? '');
    if (first == null || second == null) continue;
    int start;
    int end;
    if (kuwo && kuwoOffset > 0 && kuwoOffset2 > 0) {
      // 与 LX 官方 kw/util.js lrcTools.getWordInfo 完全对齐：
      // 词开始 = |a + b| / (tagValue/10 * 2)，时长 = |a - b| / (tagValue%10 * 2)。
      // 绝对值要先于取整取，负数先 floor 再 abs 会得到方向相反的偏移。
      // 实测（晴天等曲目）解出的时间是相对行首的偏移：每行首词 a=-b
      // 解码为 0，各行词时长恰好衔接到下一行行首。之前漏加行首时间，
      // 导致除首行（行时间为 0）外所有词都叠在歌曲开头——表现为
      // “只有歌名逐字”。
      start =
          (lineStartMs ?? 0) + ((first + second).abs() / (kuwoOffset * 2)).floor();
      end = start + ((first - second).abs() / (kuwoOffset2 * 2)).floor();
    } else {
      start = (lineStartMs ?? 0) + first;
      end = start + second;
    }
    if (start < 0) start = 0;
    // 官方 prevWord 规则：当前词比前词结束更早开始时缩短前词，
    // 而不是推迟当前词——推迟会把整行词的时间越推越晚。
    if (entries.isNotEmpty && start < entries.last.endMs) {
      final previous = entries.last;
      previous.endMs = start;
      if (previous.startMs > previous.endMs) {
        previous.startMs = previous.endMs;
      }
    }
    end = end < start ? start : end;
    entries.add(
      _WordEntry(
        index: marker.start,
        endIndex: marker.end,
        startMs: start,
        endMs: end,
      ),
    );
  }
  return entries;
}

String _buildEnhancedBody(String body, List<_WordEntry> entries) {
  if (entries.isEmpty) return '';
  final beforeFirst = body.substring(0, entries.first.index).trim().isNotEmpty;
  final buffer = StringBuffer();
  if (beforeFirst) {
    var lastEnd = 0;
    for (final entry in entries) {
      final text = body.substring(lastEnd, entry.index);
      if (text.isNotEmpty) {
        buffer.write('<${_formatTimestamp(entry.startMs)}>$text');
      }
      lastEnd = entry.endIndex;
    }
    if (lastEnd < body.length) buffer.write(body.substring(lastEnd));
  } else {
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final textStart = entry.endIndex;
      final textEnd = i + 1 < entries.length
          ? entries[i + 1].index
          : body.length;
      if (textEnd > textStart) {
        buffer.write(
          '<${_formatTimestamp(entry.startMs)}>${body.substring(textStart, textEnd)}',
        );
      }
    }
  }
  buffer.write('<${_formatTimestamp(entries.last.endMs)}>');
  return buffer.toString();
}

/// Converts LX/KG/KW word markers to the enhanced LRC format understood by Rust.
String convertLxLyricToEnhancedLrc(String source) {
  final lines = source.split(RegExp(r'\r?\n'));
  var kuwoOffset = 1;
  var kuwoOffset2 = 1;
  var hasKuwoTag = false;
  for (final raw in lines) {
    final match = _kuwoTag.firstMatch(raw.trim());
    if (match == null) continue;
    hasKuwoTag = true;
    final value =
        int.tryParse((match.group(1) ?? '').split('][').first, radix: 8) ?? 0;
    kuwoOffset = value ~/ 10;
    kuwoOffset2 = value % 10;
    if (kuwoOffset <= 0) kuwoOffset = 1;
    if (kuwoOffset2 <= 0) kuwoOffset2 = 1;
  }
  final hasNegativeMarker = lines.any(
    (line) => _wordMarker.allMatches(line).any((m) {
      final a = int.tryParse(m.group(1) ?? '') ?? 0;
      final b = int.tryParse(m.group(2) ?? '') ?? 0;
      return a < -500 || b < -500;
    }),
  );
  final useKuwo = hasKuwoTag || hasNegativeMarker;
  final result = <String>[];
  var converted = 0;
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty || _kuwoTag.hasMatch(line)) continue;
    final markers = _wordMarker.allMatches(line).toList();
    if (markers.isEmpty) {
      if (_enhancedMarker.hasMatch(line)) {
        result.add(line);
        converted++;
      } else if (_lineTimestamp.hasMatch(line)) {
        result.add(line);
      }
      continue;
    }
    final lineMatch = _lineTimestamp.firstMatch(line);
    final lineStart = lineMatch == null
        ? null
        : _timestampMs(lineMatch.group(1)!);
    final body = lineMatch?.group(2) ?? line;
    final bodyMarkers = _wordMarker.allMatches(body).toList();
    final entries = _entriesForLine(
      markers: bodyMarkers,
      lineStartMs: lineStart,
      kuwo: useKuwo,
      kuwoOffset: kuwoOffset,
      kuwoOffset2: kuwoOffset2,
    );
    if (entries.isEmpty) continue;
    final bodyResult = _buildEnhancedBody(body, entries);
    if (bodyResult.isEmpty) continue;
    final lineTimestamp = lineStart ?? entries.first.startMs;
    result.add('[${_formatTimestamp(lineTimestamp)}]$bodyResult');
    converted++;
  }
  return converted == 0 ? '' : result.join('\n');
}

bool _containsWordMarkers(String text) => _wordMarker.hasMatch(text);

/// Selects the highest fidelity lyric payload returned by fetchLyricFromSource.
String buildLxLyricsRaw(Map<String, dynamic> payload) {
  String text(dynamic value) => value is String ? value.trim() : '';
  final yrc = text(payload['yrc']);
  final qrc = text(payload['qrc']);
  final eslrc = text(payload['eslrc']);
  final lxlyric = text(payload['lxlyric']);
  var result = '';
  if (yrc.isNotEmpty) {
    result = yrc;
  } else if (qrc.isNotEmpty) {
    result = qrc;
  } else if (eslrc.isNotEmpty) {
    result = eslrc;
  } else if (lxlyric.isNotEmpty) {
    result = convertLxLyricToEnhancedLrc(lxlyric);
    if (result.isEmpty) result = lxlyric;
  } else {
    final lyric = text(payload['lyric']);
    result = _containsWordMarkers(lyric)
        ? convertLxLyricToEnhancedLrc(lyric)
        : (lyric.isEmpty ? '' : lyric);
  }
  final translation = text(payload['tlyric']);
  final romanization = text(payload['rlyric']);
  return [
    result,
    translation,
    romanization,
  ].where((item) => item.isNotEmpty).join('\n');
}
