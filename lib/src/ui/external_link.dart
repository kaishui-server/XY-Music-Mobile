import 'package:flutter/services.dart';

/// 系统级外部链接能力：Android 侧通过 MethodChannel 调起 ACTION_VIEW，
/// 交给系统浏览器 / 已注册应用打开。其余平台（或调起失败）返回 false，
/// 由调用方兜底（通常是复制链接到剪贴板）。
const MethodChannel _externalLinkChannel = MethodChannel(
  'com.xymusic.mobile/external_link',
);

Future<bool> openExternalUrl(String url) async {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return false;
  try {
    final opened = await _externalLinkChannel.invokeMethod<bool>('openUrl', {
      'url': trimmed,
    });
    return opened ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}