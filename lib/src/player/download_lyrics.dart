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

String _formatLrcTime(double seconds) {
  final milliseconds = (seconds.isFinite && seconds > 0 ? seconds * 1000 : 0)
      .round();
  final minutes = milliseconds ~/ 60000;
  final remainder = milliseconds % 60000;
  final wholeSeconds = remainder ~/ 1000;
  final millis = remainder % 1000;
  return '[${minutes.toString().padLeft(2, '0')}:${wholeSeconds.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}]';
}

/// 将解析器输出的展示行还原为可保存的标准 LRC。这样下载文件中不会保留
/// QRC 等密文，同时翻译行仍会按同一时间戳写入。
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
    output.add('$stamp$text');
    final translation = value['translation']?.toString().trim() ?? '';
    if (translation.isNotEmpty && translation != text) {
      output.add('$stamp$translation');
    }
  }
  return output.join('\n');
}

/// 把下载拿到的歌词原文规范成可保存的 LRC：QRC/KRC 密文先用 Rust
/// 解析器解码为标准 LRC；无法可靠解码的密文返回空串，避免把乱码
/// 写进 .lrc 文件。普通歌词原样返回。
Future<String> normalizeLyricsForDownload(String raw) async {
  final text = raw.trim();
  if (text.isEmpty || !looksLikeEncodedLyrics(text)) return text;
  try {
    final parsed = jsonDecode(await parseLyrics(rawLyrics: text));
    final decoded = displayLinesToLrc(parsed);
    if (decoded.isNotEmpty) return decoded;
  } catch (_) {
    // 密文格式不完整时按无法解码处理。
  }
  return '';
}
