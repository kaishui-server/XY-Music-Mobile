// 网盘曲目播放接入（XY 移植版，对齐弦予 cloud 播放链路）。
//
// QueueItem.path = cloud://<provider>/<accountId>/<urlEncodedFileJson>，
// 是唯一标识兼直链缓存键；cloudInfoJson 为结构化上下文
// （CloudPlayContext），会话恢复/跨页传递优先使用，path 反解作兜底。
// 直链失效（起播超时/内容不符）清缓存重取一次，重试仍失败按普通播放
// 失败处理，不触发插件换源。

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../cloud/cloud_types.dart';
import 'player_provider.dart' show QueueItem;

/// 网盘播放上下文：QueueItem.cloudInfoJson 的载荷。
class CloudPlayContext {
  const CloudPlayContext({
    required this.provider,
    required this.accountId,
    required this.file,
    this.share,
  });

  /// 网盘注册 id（cloud_registry）。
  final String provider;

  /// 绑定账号 id；分享免登录直链（无需凭据的盘）传 '_'。
  final String accountId;

  final CloudFile file;

  /// 分享上下文：免转存直链（directPlayable）播放时携带。
  final CloudShareParse? share;

  /// 播放标识：`cloud://<provider>/<accountId>/<urlEncodedFileJson>`。
  String get path =>
      'cloud://$provider/$accountId/${Uri.encodeComponent(jsonEncode(file.toJson()))}';

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'accountId': accountId,
        'file': file.toJson(),
        if (share != null)
          'share': {
            'providerId': share!.providerId,
            'shareId': share!.shareId,
            'shareToken': share!.shareToken,
            'passcode': share!.passcode,
            'directPlayable': share!.directPlayable,
            'files': share!.files.map((f) => f.toJson()).toList(),
          },
      };

  static CloudPlayContext? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final shareJson = j['share'];
      return CloudPlayContext(
        provider: (j['provider'] ?? '').toString(),
        accountId: (j['accountId'] ?? '').toString(),
        file: CloudFile.fromJson(
          (j['file'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
        ),
        share: shareJson is Map<String, dynamic>
            ? CloudShareParse(
                providerId: (shareJson['providerId'] ?? '').toString(),
                shareId: shareJson['shareId']?.toString(),
                shareToken: shareJson['shareToken']?.toString(),
                passcode: shareJson['passcode']?.toString(),
                directPlayable: shareJson['directPlayable'] == true,
                files: (shareJson['files'] as List?)
                        ?.whereType<Map<String, dynamic>>()
                        .map(CloudFile.fromJson)
                        .toList() ??
                    const <CloudFile>[],
              )
            : null,
      );
    } catch (e) {
      debugPrint('[cloud] 网盘播放上下文解析失败: $e');
      return null;
    }
  }

  /// 从 cloud:// path 反解上下文（无 cloudInfoJson 时兜底）。
  static CloudPlayContext? tryParsePath(String path) {
    if (!path.startsWith('cloud://')) return null;
    final rest = path.substring('cloud://'.length);
    final idx1 = rest.indexOf('/');
    if (idx1 <= 0) return null;
    final provider = rest.substring(0, idx1);
    final rest2 = rest.substring(idx1 + 1);
    final idx2 = rest2.indexOf('/');
    if (idx2 <= 0) return null;
    final accountId = rest2.substring(0, idx2);
    final encoded = rest2.substring(idx2 + 1);
    try {
      final fileJson =
          jsonDecode(Uri.decodeComponent(encoded)) as Map<String, dynamic>?;
      if (fileJson == null) return null;
      return CloudPlayContext(
        provider: provider,
        accountId: accountId,
        file: CloudFile.fromJson(fileJson),
      );
    } catch (e) {
      debugPrint('[cloud] 网盘播放上下文 path 反解失败: $e');
      return null;
    }
  }
}

/// 网盘浏览页/链接导入页构造可播放队列条目（时长由播放器实测回填）。
QueueItem cloudPlayQueueItem(
  CloudPlayContext ctx, {
  String? title,
  String? artist,
  String? coverUrl,
}) =>
    QueueItem(
      path: ctx.path,
      title: title ?? ctx.file.name,
      artist: artist ?? '',
      album: '',
      coverUrl: coverUrl,
      source: 'cloud:${ctx.provider}',
      cloudInfoJson: jsonEncode(ctx.toJson()),
    );
