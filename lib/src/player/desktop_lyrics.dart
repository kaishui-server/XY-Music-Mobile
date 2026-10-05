import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/custom_font.dart';
import '../rust/api.dart';

/// Android 悬浮桌面歌词桥接。桌面歌词默认关闭，只有用户主动开启并授予
/// 悬浮窗权限后才会创建系统级浮窗。
class DesktopLyricsBridge {
  DesktopLyricsBridge._();

  static const _channel = MethodChannel('com.xymusic.mobile/desktop_lyrics');

  /// 原生手动拖动浮窗后回传的纵向位置（百分制）：0 = 屏幕最顶端、
  /// 50 = 屏幕正中、100 = 屏幕最底端。设置页滑块据此跟随实际位置，避免
  /// 下一次更新用旧滑块值把浮窗拉回（拖动后被复位）。未注册时忽略该回调。
  static void Function(double percent)? onPositionChanged;

  /// 原生浮窗关闭按钮被点击后的回调：播放层据此把「桌面歌词」开关同步为
  /// 关闭（浮窗本身已由原生移除）。未注册时忽略该回调。
  static void Function()? onCloseRequested;

  static bool _handlerInstalled = false;

  /// 安装原生 → Dart 的回调监听（只装一次）。原生浮窗拖动结束后会把纵向
  /// 位置（百分制）经 `onPositionChanged` 回传，这里转交给
  /// [onPositionChanged] 由播放层写回设置，使滑块与实际位置保持一致。
  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPositionChanged') {
        final value = (call.arguments as num?)?.toDouble();
        if (value != null) onPositionChanged?.call(value);
      } else if (call.method == 'onCloseRequested') {
        onCloseRequested?.call();
      }
      return null;
    });
  }

  static bool? _lastEnabled;
  static String? _lastContentSignature;
  static bool? _lastIsPlayingSent;
  static double _lastSentPosition = -1e9;
  static DateTime _lastSendTime = DateTime.fromMillisecondsSinceEpoch(0);
  static String? _lyricsCacheKey;
  static Future<List<_DesktopLyricLine>>? _lyricsCacheFuture;
  static int _syncGeneration = 0;

  /// 上次 trim/解析所用的原始歌词字符串实例。整首歌期间
  /// [QueueItem.lyricsRaw] 恒为同一 String 实例（歌词只在换歌/换词时才
  /// 更新），据此可跳过 10Hz 热循环里对整首歌词的重复 trim。
  static String? _rawSourceRef;

  static void _resetSendState() {
    _lastContentSignature = null;
    _lastIsPlayingSent = null;
    _lastSentPosition = -1e9;
    _lastSendTime = DateTime.fromMillisecondsSinceEpoch(0);
  }

  static Future<String>? _customFontPathFuture;

  /// 自定义字体文件绝对路径（供原生悬浮窗 Typeface.createFromFile 加载）。
  /// 路径固定，仅缓存路径解析；文件是否存在每次实时判断，未启用或文件
  /// 缺失时返回空串，原生回退系统默认字体。
  static Future<String> resolveCustomFontPath() async {
    try {
      final path = await (_customFontPathFuture ??= customFontFilePath());
      return File(path).existsSync() ? path : '';
    } catch (_) {
      return '';
    }
  }

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
        if (!enabled) _resetSendState();
      }
      return accepted;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 原生侧用 Choreographer 按墙钟时间前推播放位置并逐帧渲染渐进填充，
  /// 因此 Dart 只需在「内容变化」（歌词行/翻译/样式/逐字数据/锁定）时
  /// 立即推送，播放位置本身低频（500ms）校正一次漂移即可；暂停/恢复与
  /// 大幅跳转（>0.35s，如 seek）立即推送。此前每 100~250ms 全量推送是
  /// 桌面歌词卡顿的主因之一（每次都触发原生全量重建 + 基准回跳）。
  static Future<void> sync({
    required bool enabled,
    required bool locked,
    required String title,
    required String artist,
    required String lyrics,
    required double position,
    required bool isPlaying,
    required bool noBackground,
    required int lyricColor,
    required int translationColor,
    required double lyricFontSize,
    required double translationFontSize,
    required int backgroundColor,
    required double backgroundOpacity,
    required int wordEffectMode,
    required double verticalPercent,
    required String lyricFontPath,
  }) async {
    if (!Platform.isAndroid) return;
    _ensureHandler();
    final generation = ++_syncGeneration;
    if (_lastEnabled != enabled) {
      final accepted = await setEnabled(enabled);
      if (generation != _syncGeneration || !accepted || !enabled) return;
    }
    if (!enabled) {
      _resetSendState();
      return;
    }
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
    // 内容签名：除播放位置与播放态外的全部字段。签名不变说明只是进度
    // 漂移，走低频校正；变化（换行/换样式/换锁定）立即推送。
    final contentSignature = <Object?>[
      title,
      artist,
      lyric,
      current.translation,
      wordsJson,
      noBackground,
      lyricColor,
      translationColor,
      lyricFontSize,
      translationFontSize,
      backgroundColor,
      backgroundOpacity,
      wordEffectMode,
      locked,
      verticalPercent,
      lyricFontPath,
    ].join('\u0000');
    final now = DateTime.now();
    final positionDelta = (position - _lastSentPosition).abs();
    final shouldSend =
        contentSignature != _lastContentSignature ||
        isPlaying != _lastIsPlayingSent ||
        positionDelta > 0.35 ||
        (now.difference(_lastSendTime) >= const Duration(milliseconds: 500) &&
            positionDelta > 0.01);
    if (!shouldSend) return;
    _lastContentSignature = contentSignature;
    _lastIsPlayingSent = isPlaying;
    _lastSentPosition = position;
    _lastSendTime = now;
    try {
      await _channel.invokeMethod<void>('update', <String, dynamic>{
        'title': title,
        'artist': artist,
        'lyric': lyric,
        'translation': current.translation,
        'wordsJson': wordsJson,
        'position': position,
        'isPlaying': isPlaying,
        'wordEffectMode': wordEffectMode,
        'locked': locked,
        'noBackground': noBackground,
        'lyricColor': lyricColor,
        'translationColor': translationColor,
        'lyricFontSize': lyricFontSize,
        'translationFontSize': translationFontSize,
        'backgroundColor': backgroundColor,
        'backgroundOpacity': backgroundOpacity,
        'verticalPercent': verticalPercent,
        'lyricFontPath': lyricFontPath,
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
    // 桌面歌词同步在后台以 10Hz 热循环运行；整首歌期间 [raw] 都是同一个
    // String 实例（歌词只在换歌/换词时更新）。按实例判断可把「整首歌词
    // trim + 解析」从每 tick 一次收敛为每首歌一次：原始 LRC/QRC 常带首尾
    // 空白，trim() 会整份复制歌词，10Hz 反复分配是后台 other 堆持续增长
    // (~1MB/s) 的主要来源。
    if (!identical(raw, _rawSourceRef)) {
      _rawSourceRef = raw;
      final source = raw.trim();
      _lyricsCacheKey = source;
      _lyricsCacheFuture = source.isEmpty ? null : _parseLyrics(source);
    }
    final source = _lyricsCacheKey ?? '';
    if (source.isEmpty) return const DesktopLyric(text: '暂无歌词');
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
            // 副行显示翻译；无翻译时回退显示罗马音/音译。
            // 两者都缺（纯原文歌曲）时副行为空，原生侧将隐藏第二行。
            final translationText = _cleanDesktopLyricText(
              line['translation']?.toString() ?? '',
            );
            final romajiText = _cleanDesktopLyricText(
              line['romaji']?.toString() ?? '',
            );
            return _DesktopLyricLine(
              time: (line['time'] as num?)?.toDouble() ?? 0,
              text: _cleanDesktopLyricText(line['text']?.toString() ?? ''),
              translation: translationText.isNotEmpty
                  ? translationText
                  : romajiText,
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
      final text = _cleanDesktopLyricText(
        line.replaceAll(tagPattern, '').trim(),
      );
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
          .map(
            (line) =>
                _cleanDesktopLyricText(line.replaceAll(tagPattern, '').trim()),
          )
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

/// 个别插件的逐字歌词会把内部 token（十六进制数字/大写字母串）误放
/// 到展示文本中。桌面歌词不应把这种 token 直接画出来，发现时返回空值，
/// 让解析器回退到原始 LRC 文本。
String _cleanDesktopLyricText(String value) {
  final text = value.replaceAll(RegExp(r'[\u0000-\u001F]'), '').trim();
  if (text.length >= 8 &&
      RegExp(r'^[A-Z0-9]+$').hasMatch(text) &&
      RegExp(r'[A-Z]').hasMatch(text) &&
      RegExp(r'\d').hasMatch(text)) {
    return '';
  }
  return text;
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
