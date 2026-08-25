import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../rust/api.dart';

/// Android 悬浮桌面歌词桥接。桌面歌词默认关闭，只有用户主动开启并授予
/// 悬浮窗权限后才会创建系统级浮窗。
class DesktopLyricsBridge {
  DesktopLyricsBridge._();

  static const _channel = MethodChannel('com.xymusic.mobile/desktop_lyrics');
  static bool? _lastEnabled;
  static String? _lastPayload;
  static String? _lyricsCacheKey;
  static Future<List<_DesktopLyricLine>>? _lyricsCacheFuture;
  static int _syncGeneration = 0;

  static Future<bool> setEnabled(bool enabled) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>(
        'setEnabled',
        <String, dynamic>{'enabled': enabled},
      );
      final accepted = result == true;
      if (accepted) {
        _lastEnabled = enabled;
        if (!enabled) _lastPayload = null;
      }
      return accepted;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 只在歌曲、当前歌词或样式真正变化时向原生浮窗发送文本，避免每个进度
  /// 采样都跨一次 MethodChannel。歌词解析结果会缓存，支持播放详情页同款
  /// displayLines/words 逐字数据。
  static Future<void> sync({
    required bool enabled,
    required bool locked,
    required String title,
    required String artist,
    required String lyrics,
    required double position,
    required bool noBackground,
    required int lyricColor,
    required int translationColor,
    required double lyricFontSize,
    required double translationFontSize,
    required int backgroundColor,
    required double backgroundOpacity,
    required int wordEffectMode,
  }) async {
    if (!Platform.isAndroid) return;
    final generation = ++_syncGeneration;
    if (_lastEnabled != enabled) {
      final accepted = await setEnabled(enabled);
      if (generation != _syncGeneration || !accepted || !enabled) return;
    }
    if (!enabled) return;
    final current = await _resolveCurrentLyric(lyrics, position);
    // 解析歌词和 MethodChannel 都是异步的。高频进度更新时，较旧任务可能
    // 晚于新任务完成；必须丢弃它，否则刚切到下一句又会被上一句覆盖。
    if (generation != _syncGeneration) return;
    final lyric = current.text;
    final wordsJson = jsonEncode(
      current.words
          .map(
            (word) => {'text': word.text, 'start': word.start, 'end': word.end},
          )
          .toList(),
    );
    final payload =
        '$title\n$artist\n$lyric\n${current.translation}\n$wordsJson\n'
        '$noBackground\n$lyricColor\n$translationColor\n'
        '$lyricFontSize\n$translationFontSize\n'
        '$backgroundColor\n$backgroundOpacity\n$position\n$wordEffectMode\n$locked';
    if (_lastPayload == payload) return;
    _lastPayload = payload;
    try {
      await _channel.invokeMethod<void>('update', <String, dynamic>{
        'title': title,
        'artist': artist,
        'lyric': lyric,
        'translation': current.translation,
        'wordsJson': wordsJson,
        'position': position,
        'wordEffectMode': wordEffectMode,
        'locked': locked,
        'noBackground': noBackground,
        'lyricColor': lyricColor,
        'translationColor': translationColor,
        'lyricFontSize': lyricFontSize,
        'translationFontSize': translationFontSize,
        'backgroundColor': backgroundColor,
        'backgroundOpacity': backgroundOpacity,
      });
    } on PlatformException {
      // 浮窗属于附加能力，权限或系统回收时不影响正常播放。
    } on MissingPluginException {
      // 非 Android 构建没有对应原生实现。
    }
  }

  static Future<DesktopLyric> _resolveCurrentLyric(
    String raw,
    double position,
  ) async {
    final source = raw.trim();
    if (source.isEmpty) return const DesktopLyric(text: '暂无歌词');
    if (_lyricsCacheKey != source) {
      _lyricsCacheKey = source;
      _lyricsCacheFuture = _parseLyrics(source);
    }
    final lines = await (_lyricsCacheFuture ?? _parseLyrics(source));
    if (lines.isEmpty) return _fallbackCurrentLyric(source, position);
    var active = lines.lastIndexWhere((line) => line.time <= position);
    if (active < 0) active = 0;
    final line = lines[active];
    return DesktopLyric(
      text: line.text,
      translation: line.translation,
      words: line.words,
    );
  }

  static Future<List<_DesktopLyricLine>> _parseLyrics(String source) async {
    try {
      final parsed = await parseLyrics(rawLyrics: source);
      final payload = jsonDecode(parsed);
      if (payload is! Map) return const [];
      return (payload['displayLines'] as List? ?? const [])
          .whereType<Map>()
          .map((raw) {
            final line = Map<String, dynamic>.from(raw);
            final words = (line['words'] as List? ?? const [])
                .whereType<Map>()
                .map(
                  (word) => DesktopLyricWord(
                    text: word['text']?.toString() ?? '',
                    start: (word['start'] as num?)?.toDouble() ?? 0,
                    end: (word['end'] as num?)?.toDouble() ?? 0,
                  ),
                )
                .where((word) => word.text.isNotEmpty)
                .toList();
            return _DesktopLyricLine(
              time: (line['time'] as num?)?.toDouble() ?? 0,
              text: line['text']?.toString() ?? '',
              translation: line['translation']?.toString() ?? '',
              words: words,
            );
          })
          .where((line) => line.text.trim().isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static DesktopLyric _fallbackCurrentLyric(String source, double position) {
    final lines = <_DesktopLyricLine>[];
    final tagPattern = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
    for (final line in source.split(RegExp(r'\r?\n'))) {
      final tags = tagPattern.allMatches(line).toList();
      if (tags.isEmpty) continue;
      final text = line.replaceAll(tagPattern, '').trim();
      if (text.isEmpty) continue;
      for (final tag in tags) {
        final minute = int.tryParse(tag.group(1) ?? '') ?? 0;
        final second = int.tryParse(tag.group(2) ?? '') ?? 0;
        final fractionText = tag.group(3) ?? '';
        final fraction = fractionText.isEmpty
            ? 0.0
            : (int.tryParse(fractionText) ?? 0) /
                  (fractionText.length == 1
                      ? 10
                      : fractionText.length == 2
                      ? 100
                      : 1000);
        lines.add(
          _DesktopLyricLine(time: minute * 60 + second + fraction, text: text),
        );
      }
    }
    if (lines.isEmpty) {
      final first = source
          .split(RegExp(r'\r?\n'))
          .map((line) => line.replaceAll(tagPattern, '').trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => '暂无歌词');
      return DesktopLyric(text: first);
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    var current = lines.first;
    for (final line in lines) {
      if (line.time > position) break;
      current = line;
    }
    return DesktopLyric(text: current.text);
  }
}

class DesktopLyric {
  const DesktopLyric({
    required this.text,
    this.translation = '',
    this.words = const [],
  });

  final String text;
  final String translation;
  final List<DesktopLyricWord> words;
}

class DesktopLyricWord {
  const DesktopLyricWord({
    required this.text,
    required this.start,
    required this.end,
  });

  final String text;
  final double start;
  final double end;
}

class _DesktopLyricLine {
  const _DesktopLyricLine({
    required this.time,
    required this.text,
    this.translation = '',
    this.words = const [],
  });

  final double time;
  final String text;
  final String translation;
  final List<DesktopLyricWord> words;
}
