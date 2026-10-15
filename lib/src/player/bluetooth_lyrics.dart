import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// 蓝牙歌词桥接层。
///
/// 参考移植自弦予项目 `lib/src/watch_link/`：
/// - 帧协议与弦予完全一致（magic [0x58,0x59,0x57,0x31] / ver 2 / 14 字节头 /
///   CRC16-CCITT-FALSE / 4KB payload / 0x30 chunk 分片），服务 UUID 一致
///   （f7a24b6c-9d3e-4f8a-b1c2-2e5d8a7f6b3a，见原生 BluetoothLyricsLink.kt），
///   因此弦予手表端/既有接收端无需改动即可接收 XY 推送的歌词帧。
/// - 职责边界一致：本类只做帧编解码与协议语义，字节管道（SPP accept/写）
///   由原生 Kotlin 完成。
///
/// 消息类型与弦予 LinkMsgType 对齐：
///  0x10 state（播放态）、0x11 nowPlaying（切歌元数据）、0x12 position（进度）、
///  0x13 lyric（整首 LRC）、0x02 bye（关闭）。
class BluetoothLyricsBridge {
  static const MethodChannel _channel =
      MethodChannel('com.xymusic.mobile/bluetooth_lyrics');

  // ---- 帧协议常量（与弦予 protocol.dart 严格一致）----
  static final Uint8List _kFrameMagic = Uint8List.fromList([0x58, 0x59, 0x57, 0x31]);
  static const int _kProtocolVersion = 2;
  static const int _kFrameHeaderBytes = 14;
  static const int _kMaxPayloadBytes = 4 * 1024;
  static const int _kMaxChunkPayloadBytes = _kMaxPayloadBytes - 512;

  // ---- 消息类型（与弦予 LinkMsgType 对齐）----
  static const int _kMsgBye = 0x02;
  static const int _kMsgState = 0x10;
  static const int _kMsgNowPlaying = 0x11;
  static const int _kMsgPosition = 0x12;
  static const int _kMsgLyric = 0x13;
  static const int _kMsgChunk = 0x30;

  // ---- 内部状态 ----
  static bool _started = false;
  static bool _connected = true; // 由 onConnection 回调更新；原生 send 对无连接快速空回调
  static String _lastMetaKey = '';
  static String _lastLyricKey = '';
  static bool _lastIsPlaying = false;
  static Timer? _timer;
  static bool _pending = false;
  static bool _inFlight = false;
  static int _seq = 0;

  static bool get isStarted => _started;
  static bool get isConnected => _connected;

  /// 设置页开启时调用：请求权限并启动 SPP 服务端。返回是否已成功启动。
  static Future<bool> setEnabled(bool enabled) async {
    if (enabled) {
      final hasPermission = await _hasPermission();
      if (!hasPermission) {
        final granted = await _requestPermissionAndWait();
        if (!granted) return false;
      }
      await _channel.invokeMethod('start');
      _started = true;
      return true;
    } else {
      await _channel.invokeMethod('stop');
      _started = false;
      _lastMetaKey = '';
      return true;
    }
  }

  /// 播放器进度流调用：按需推送 state / nowPlaying+lyric / position。
  static Future<void> sync({
    required bool enabled,
    required String title,
    required String artist,
    required String lyrics,
    required double position,
    required bool isPlaying,
    required double duration,
  }) async {
    if (!enabled) {
      if (_started) {
        _lastMetaKey = '';
        await _sendMessage(_kMsgBye, const {});
        await _channel.invokeMethod('stop');
        _started = false;
      }
      return;
    }
    if (!_started) return; // 设置页未开启时静默忽略

    final metaKey = '$title\u0000$artist';
    final posMs = (position * 1000).round();
    final durationMs = (duration * 1000).round();
    final isPlayingChanged = _lastIsPlaying != isPlaying;

    // 切歌：推送元数据 + 整首 LRC（参考弦予 _maybePushLyric 推整首 payload）。
    // 异步歌词加载完成后 lyric 内容变化：即使 metaKey 相同也补推一次整首 LRC，
    // 避免蓝牙端一直停留在占位文本/「暂无歌词」。
    if (metaKey != _lastMetaKey || lyrics != _lastLyricKey) {
      _lastMetaKey = metaKey;
      _lastLyricKey = lyrics;
      _lastIsPlaying = isPlaying;
      final id = title.isEmpty ? '' : '$title|$artist';
      await _sendMessage(
        _kMsgNowPlaying,
        {
          'id': id,
          'title': title,
          'artist': artist,
          'album': '',
          'duration': durationMs / 1000.0,
        },
      );
      await _sendMessage(_kMsgLyric, {
        'lyric': {'id': id, 'payload': lyrics},
      });
      if (!isPlaying) {
        await _sendMessage(
          _kMsgState,
          {'isPlaying': false, 'playMode': 'order', 'liked': false},
        );
      }
      return;
    }

    // 播放态变化：推送 state
    if (isPlayingChanged) {
      _lastIsPlaying = isPlaying;
      await _sendMessage(
        _kMsgState,
        {'isPlaying': isPlaying, 'playMode': 'order', 'liked': false},
      );
      return;
    }

    // 进度同步：500ms 节流，且位置变化超过阈值才推（避免空转）
    _pending = true;
    _pendingPosMs = posMs;
    _pendingDurationMs = durationMs;
    if (_inFlight || _timer != null) return;
    final elapsed = DateTime.now().millisecondsSinceEpoch - _lastPosSendAt;
    final delay = elapsed >= 500
        ? Duration.zero
        : Duration(milliseconds: 500 - elapsed);
    _timer = Timer(delay, () {
      _timer = null;
      if (_pending && !_inFlight) _flushPosition();
    });
  }

  static int _lastPosSendAt = 0;
  static int _pendingPosMs = -1;
  static int _pendingDurationMs = 0;

  static Future<void> _flushPosition() async {
    _pending = false;
    _inFlight = true;
    _lastPosSendAt = DateTime.now().millisecondsSinceEpoch;
    await _channel.invokeMethod('isConnected').then((v) {
      _connected = v == true;
    }).catchError((_) {});
    if (!_connected) {
      _inFlight = false;
      return;
    }
    await _sendMessage(
      _kMsgPosition,
      {'pos': _pendingPosMs / 1000.0, 'duration': _pendingDurationMs / 1000.0},
    );
    _inFlight = false;
    if (_pending) _schedulePosition();
  }

  static void _schedulePosition() {
    if (_timer != null || _inFlight) return;
    _timer = Timer(const Duration(milliseconds: 500), () {
      _timer = null;
      if (_pending && !_inFlight) _flushPosition();
    });
  }

  // ---- 帧编码（与弦予 protocol.dart 同一实现）----

  static List<Uint8List> _encodeFrames(int type, Map<String, dynamic> payload) {
    final jsonBytes = utf8.encode(jsonEncode(payload));
    if (jsonBytes.length <= _kMaxPayloadBytes) {
      return [_encodeOne(type, _nextSeq(), jsonBytes)];
    }
    var chunkSize = _kMaxChunkPayloadBytes;
    var chunks = _splitUtf8Safe(jsonBytes, chunkSize);
    final cid = DateTime.now().microsecondsSinceEpoch & 0xFFFFFFFF;
    final frames = <Uint8List>[];
    final seqBase = _nextSeq();
    for (var i = 0; i < chunks.length; i++) {
      frames.add(_encodeOne(
        _kMsgChunk,
        (seqBase + i) & 0xFFFF,
        utf8.encode(jsonEncode({
          'cid': cid,
          'total': chunks.length,
          'idx': i,
          'type': type,
          'data': utf8.decode(chunks[i], allowMalformed: false),
        })),
      ));
    }
    return frames;
  }

  static Uint8List _encodeOne(int type, int seq, List<int> jsonBytes) {
    final frame = Uint8List(_kFrameHeaderBytes + jsonBytes.length);
    frame.setRange(0, 4, _kFrameMagic);
    frame[4] = _kProtocolVersion;
    frame[5] = type;
    frame[6] = (seq >> 8) & 0xFF;
    frame[7] = seq & 0xFF;
    frame[8] = (jsonBytes.length >> 24) & 0xFF;
    frame[9] = (jsonBytes.length >> 16) & 0xFF;
    frame[10] = (jsonBytes.length >> 8) & 0xFF;
    frame[11] = jsonBytes.length & 0xFF;
    frame.setRange(_kFrameHeaderBytes, frame.length, jsonBytes);
    final crcInput = frame.sublist(4);
    final crc = _crc16CcittFalse(crcInput);
    frame[12] = (crc >> 8) & 0xFF;
    frame[13] = crc & 0xFF;
    return frame;
  }

  static List<Uint8List> _splitUtf8Safe(Uint8List bytes, int maxChunk) {
    final out = <Uint8List>[];
    var start = 0;
    while (start < bytes.length) {
      var end = start + maxChunk < bytes.length ? start + maxChunk : bytes.length;
      if (end < bytes.length) {
        while (end > start && (bytes[end] & 0xC0) == 0x80) {
          end--;
        }
      }
      out.add(Uint8List.sublistView(bytes, start, end));
      start = end;
    }
    return out;
  }

  static int _crc16CcittFalse(List<int> bytes) {
    var crc = 0xFFFF;
    for (final b in bytes) {
      crc ^= b << 8;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
      }
    }
    return crc;
  }

  static int _nextSeq() {
    _seq = (_seq + 1) & 0xFFFF;
    return _seq;
  }

  static Future<void> _sendMessage(int type, Map<String, dynamic> payload) async {
    if (!_connected) return;
    final frames = _encodeFrames(type, payload);
    for (final frame in frames) {
      // 逐帧 await = 背压（原生写完回调才发下一帧）
      try {
        await _channel.invokeMethod('send', {'bytes': frame});
      } catch (_) {
        return;
      }
    }
  }

  static Future<bool> _hasPermission() async {
    try {
      final v = await _channel.invokeMethod<bool>('hasPermission');
      return v == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _requestPermissionAndWait() async {
    final completer = Completer<bool>();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPermission') {
        final granted = call.arguments == true;
        if (!completer.isCompleted) completer.complete(granted);
      }
    });
    try {
      await _channel.invokeMethod('requestPermission');
    } catch (_) {
      _channel.setMethodCallHandler(null);
      return false;
    }
    final granted = await completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => false,
    );
    _channel.setMethodCallHandler(null);
    return granted;
  }
}
