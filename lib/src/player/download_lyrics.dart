import 'dart:convert';

import '../rust/api.dart';

/// 有些插件会把 QRC/KRC 等歌词的密文直接放进播放结果。播放页解析器
/// 可以识别其中一部分格式，但如果原样写入下载的 `.lrc` 文件，用户看到的
/// 就会是长串数字和大写字母。仅对明显不像歌词正文的编码串做转换，普通
/// 英文歌词不会被误判。
bool looksLikeEncodedLyrics(String raw) {
  final text = raw.trim();
  if (text.length < 80 || text.contains('[') || text.contains('<')) {
    return false;
  }
  final compact = text.replaceAll(RegExp(r'\s+'), '');
  if (compact.length < 80 ||
      !RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(compact)) {
    return false;
  }
  final upperOrDigit = RegExp(r'[A-Z0-9]').allMatches(compact).length;
  return upperOrDigit / compact.length >= .82;
}

/// 是否为 QQ 音乐 QRC 容器 XML（外层带 `QrcInfos` / `Lyric_1` / `LyricContent=`
/// 等标记，正文放在 LyricContent 属性里）。该类文本含尖括号，不会被
/// [looksLikeEncodedLyrics] 判成密文，但同样不能直接写入 `.lrc`——第三方
/// 播放器（光锥、椒盐等）会把整段 XML 当成歌词正文显示。需要先经 Rust
/// 解析器抽出 LyricContent 再转成标准 LRC。
bool looksLikeQrcContainerXml(String raw) {
  final text = raw.trim();
  if (text.isEmpty || !text.contains('LyricContent=')) return false;
  return text.contains('<QrcInfos') ||
      text.contains('<Lyric_1') ||
      text.contains('<LyricInfo');
}

/// 是否为「带词级时间但不是标准增强 LRC」的歌词：QQ/汽水/酷狗的 QRC、KRC、
/// YRC 行头是裸毫秒 `[起始,时长]`（词标签为 `字(起始,时长)` 或
/// `<偏移,时长,标志>字`）。它不是标准 LRC 的 `[mm:ss.xxx]`，第三方播放器
/// 识别不了，轻则不显示逐字、重则整行当作非法时间标签丢弃；必须先经 Rust
/// 解析器转成标准增强 LRC 再落盘。
bool hasNonStandardWordTiming(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return false;
  // 行头是起始与时长都为不含冒号的裸毫秒整数。
  return RegExp(r'^\[\d+,\d+\]', multiLine: true).hasMatch(text);
}

/// 直接落盘会产生乱码、必须转换成功的歌词（hex 密文、QRC 容器 XML）。
/// QRC/KRC 等非标准词级格式与普通 LRC 都是可读文本，解析失败时宁可原样
/// 保留，也不该整段丢弃。
bool isUnreadableLyrics(String raw) =>
    looksLikeEncodedLyrics(raw) || looksLikeQrcContainerXml(raw);

/// 下载落盘前是否需要先经 Rust 歌词解析器转换：QRC/KRC 密文、QRC 容器 XML，
/// 或带非标准词级时间轴（QRC/KRC/YRC）的歌词。
bool needsLyricNormalization(String raw) =>
    isUnreadableLyrics(raw) || hasNonStandardWordTiming(raw);

/// 秒 → LRC 时钟串 `mm:ss.xxx`（不含方括号）。
String _formatLrcClock(double seconds) {
  final milliseconds = (seconds.isFinite && seconds > 0 ? seconds * 1000 : 0)
      .round();
  final minutes = milliseconds ~/ 60000;
  final remainder = milliseconds % 60000;
  final wholeSeconds = remainder ~/ 1000;
  final millis = remainder % 1000;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${wholeSeconds.toString().padLeft(2, '0')}.'
      '${millis.toString().padLeft(3, '0')}';
}

String _formatLrcTime(double seconds) => '[${_formatLrcClock(seconds)}]';

/// 由词级时间拼出增强型 LRC 正文：`<词起>词…<行束>`。
/// 任一词缺少有效时间时返回 null，由调用方退回普通行级 LRC。
String? _enhancedLrcBody(dynamic rawWords, double lineTime) {
  if (rawWords is! List || rawWords.isEmpty) return null;
  final buffer = StringBuffer();
  var lastEnd = lineTime;
  for (final entry in rawWords) {
    if (entry is! Map) return null;
    // 尖括号是增强 LRC 的标记符，正文里出现会破坏解析，直接剔除。
    final wordText = (entry['text']?.toString() ?? '')
        .replaceAll('<', '')
        .replaceAll('>', '');
    if (wordText.isEmpty) return null;
    final start = (entry['start'] as num?)?.toDouble();
    final end = (entry['end'] as num?)?.toDouble();
    if (start == null || !start.isFinite || start < 0) return null;
    buffer.write('<${_formatLrcClock(start)}>$wordText');
    lastEnd = (end != null && end.isFinite && end > start) ? end : start;
  }
  // 收尾标记：解析器用它作为最后一个词的结束时间。
  if (lastEnd <= 0) return null;
  buffer.write('<${_formatLrcClock(lastEnd)}>');
  return buffer.toString();
}

/// 将解析器输出的展示行还原为可保存的 LRC。有词级时间时写成增强型 LRC
/// （`[行]<词起>词…<行束>`），支持逐字/卡拉OK 显示的播放器（含本 App）
/// 都能识别；没有词级时间则退回普通行级 LRC。翻译行按同一时间戳写入。
String displayLinesToLrc(dynamic payload) {
  if (payload is! Map) return '';
  final lines = payload['displayLines'];
  if (lines is! List) return '';
  final output = <String>[];
  for (final value in lines.whereType<Map>()) {
    final text = value['text']?.toString().trim() ?? '';
    if (text.isEmpty) continue;
    final time = (value['time'] as num?)?.toDouble();
    if (time == null || !time.isFinite || time < 0) continue;
    final stamp = _formatLrcTime(time);
    final enhanced = _enhancedLrcBody(value['words'], time);
    output.add(enhanced == null ? '$stamp$text' : '$stamp$enhanced');
    final translation = value['translation']?.toString().trim() ?? '';
    if (translation.isNotEmpty && translation != text) {
      output.add('$stamp$translation');
    }
  }
  return output.join('\n');
}

/// 用 Rust 歌词解析器把原始歌词转成标准增强 LRC（`[行]<词起>词…<词束>`）。
/// 解析不出展示行（格式不完整/不可解）时返回空串，由调用方决定回退策略。
Future<String> convertLyricsToEnhancedLrc(String raw) async {
  try {
    final parsed = jsonDecode(await parseLyrics(rawLyrics: raw));
    return displayLinesToLrc(parsed);
  } catch (_) {
    return '';
  }
}

/// 把下载拿到的歌词原文规范成可保存的标准 LRC：QRC/KRC 密文、QRC 容器 XML
/// 以及 QRC/KRC/YRC/洛雪等非标准词级格式先用 Rust 解析器解码，再把展示行
/// 写成标准增强 LRC，确保第三方播放器也能显示逐字；无词级时间的普通 LRC
/// 原样返回。无法可靠解码的乱码返回空串，避免写进 .lrc 文件。
Future<String> normalizeLyricsForDownload(String raw) async {
  final text = raw.trim();
  if (text.isEmpty || !needsLyricNormalization(text)) return text;
  final decoded = await convertLyricsToEnhancedLrc(text);
  if (decoded.isNotEmpty) return decoded;
  // hex 密文、QRC 容器 XML 解析失败时宁可不保存歌词，也不落盘乱码；
  // QRC/KRC 等可读的词级格式解析失败时保持原文，至少不丢歌词。
  return isUnreadableLyrics(text) ? '' : text;
}
