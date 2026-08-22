import 'dart:async';

import 'package:flutter/services.dart';

class SystemAudioCapture {
  const SystemAudioCapture();

  static const _methods = MethodChannel(
    'com.xymusic.mobile/system_audio_capture',
  );
  static const _events = EventChannel(
    'com.xymusic.mobile/system_audio_capture/events',
  );

  Future<bool> isSupported() async {
    try {
      return await _methods.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Stream<Uint8List> get audioStream => _events.receiveBroadcastStream().map(
    (event) => event is Uint8List ? event : Uint8List.fromList(event),
  );

  Future<bool> start() async {
    return await _methods.invokeMethod<bool>('start') ?? false;
  }

  Future<void> stop() => _methods.invokeMethod<void>('stop');
}
