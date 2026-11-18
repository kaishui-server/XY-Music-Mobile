import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'bluetooth_lyrics.dart';

/// 写入「蓝牙歌词」开关的共用逻辑。
///
/// 开启前先走原生权限申请（[BluetoothLyricsBridge.setEnabled] 内部完成
/// 权限请求与 SPP 服务端启动），未授权或启动失败时提示并**不写入**设置，
/// 避免开关显示为已开但实际无链路。设置页「个性化 › 歌词」页使用本实现。
Future<void> applyBluetoothLyricsEnabled(
  BuildContext context,
  WidgetRef ref,
  bool enabled,
) async {
  if (enabled) {
    final started = await BluetoothLyricsBridge.setEnabled(true);
    if (!started) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请授予蓝牙权限后再开启蓝牙歌词')),
        );
      }
      return;
    }
  } else {
    await BluetoothLyricsBridge.setEnabled(false);
  }
  await ref.read(settingsProvider.notifier).setBluetoothLyricsEnabled(enabled);
}
