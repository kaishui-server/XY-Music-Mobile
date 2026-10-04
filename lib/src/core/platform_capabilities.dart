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

/// 是否已被系统豁免电池优化（后台保活状态）。
///
/// 国内 ROM（华为 EMUI/HarmonyOS、小米 HyperOS 等）默认的省电策略会限制
/// 甚至在锁屏后强杀正在播放的前台服务，表现为后台播放突然中断、进程被杀。
/// 设置页据此展示「后台播放保活」引导入口；非 Android 或通道不可用时返回
/// true（视为无需引导），避免在不支持的平台误报。
final batteryOptimizationIgnoredProvider = FutureProvider<bool>((ref) async {
  if (kIsWeb || !Platform.isAndroid) return true;
  try {
    final ignored = await const MethodChannel(
      'com.xymusic.mobile/device_info',
    ).invokeMethod<bool>('isIgnoringBatteryOptimizations');
    return ignored ?? false;
  } catch (_) {
    // 通道不可用（旧宿主/测试环境）：不展示引导。
    return true;
  }
});

/// 请求系统豁免本应用的电池优化（拉起系统授权弹窗）。
///
/// 调用后用户可能立即授权，也可能跳去系统设置手动开启；调用方应在返回后
/// 重新读取 [batteryOptimizationIgnoredProvider] 刷新状态。
Future<void> requestIgnoreBatteryOptimizations() async {
  if (kIsWeb || !Platform.isAndroid) return;
  try {
    await const MethodChannel(
      'com.xymusic.mobile/device_info',
    ).invokeMethod<bool>('requestIgnoreBatteryOptimizations');
  } catch (_) {
    // 部分 ROM 无该弹窗：静默失败，用户仍可照弹窗内的路径手动设置。
  }
}
