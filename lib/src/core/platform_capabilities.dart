import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Android 12 (API 31) 才提供系统 Material You 动态取色。
///
/// 通过现有设备信息通道读取 SDK 版本，避免引入一个仅为判断系统版本的
/// 原生依赖。iOS、桌面端和旧版 Android 会返回 false，设置页据此置灰开关。
final dynamicColorSupportedProvider = FutureProvider<bool>((ref) async {
  if (kIsWeb || !Platform.isAndroid) return false;
  try {
    final info = await const MethodChannel(
      'com.xymusic.mobile/device_info',
    ).invokeMapMethod<String, dynamic>('getDeviceInfo');
    final rawSdk = info?['sdkInt'];
    final sdk = rawSdk is int ? rawSdk : int.tryParse('$rawSdk');
    return (sdk ?? 0) >= 31;
  } catch (_) {
    // 旧宿主或测试环境没有通道时按不支持处理，避免误导用户开启无效选项。
    return false;
  }
});
