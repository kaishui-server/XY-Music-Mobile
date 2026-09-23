import 'dart:io';

import 'package:flutter/services.dart';

/// Bridges downloads into Android's Storage Access Framework (SAF).
///
/// `getDirectoryPath` returns a `content://` tree URI on Android.  It is not a
/// normal filesystem path, so the Rust downloader cannot create files there
/// directly.  MainActivity copies a completed file into that authorized tree.
class AndroidStorage {
  static const _channel = MethodChannel('com.xymusic.mobile/storage');

  static bool isTreeUri(String value) =>
      Platform.isAndroid && value.trim().toLowerCase().startsWith('content://');

  /// Converts an Android SAF tree URI into the path users selected in the
  /// system picker. The URI itself is still retained for actual writes.
  static String displayPath(String value) {
    final raw = value.trim();
    if (!raw.toLowerCase().startsWith('content://')) return raw;
    try {
      final uri = Uri.parse(raw);
      final treeIndex = uri.pathSegments.indexOf('tree');
      if (treeIndex >= 0 && treeIndex + 1 < uri.pathSegments.length) {
        final documentId = uri.pathSegments[treeIndex + 1];
        final separator = documentId.indexOf(':');
        if (separator >= 0) {
          final volume = documentId.substring(0, separator);
          final relative = documentId.substring(separator + 1);
          final root = volume.toLowerCase() == 'primary'
              ? '/storage/emulated/0'
              : '/storage/$volume';
          return relative.isEmpty ? root : '$root/$relative';
        }
        if (documentId.isNotEmpty) return documentId;
      }
    } catch (_) {}
    return raw;
  }

  static Future<String?> pickDirectory() async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<String>('pickDirectory');
  }

  /// 检查本进程是否仍持有该 SAF 目录的持久化写授权。
  /// 重装应用、恢复备份或系统回收都会让授权丢失，此时继续写入会触发
  /// `MANAGE_DOCUMENTS` 权限拒绝，调用方应引导用户重新选择目录。
  static Future<bool> hasDirectoryGrant(String directoryUri) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('hasDirectoryGrant', {
            'directoryUri': directoryUri,
          }) ==
          true;
    } catch (_) {
      return false;
    }
  }

  static Future<String> copyFileToDirectory({
    required String directoryUri,
    required String sourcePath,
    required String fileName,
    String mimeType = 'application/octet-stream',
  }) async {
    final result = await _channel.invokeMethod<String>('copyFileToDirectory', {
      'directoryUri': directoryUri,
      'sourcePath': sourcePath,
      'fileName': fileName,
      'mimeType': mimeType,
    });
    if (result == null || result.trim().isEmpty) {
      throw StateError('系统未返回目标文件地址');
    }
    return result;
  }

  /// 删除 SAF 树里的一个文件（content:// 文档 URI）。
  static Future<bool> deleteFileInDirectory(String uri) async {
    if (!Platform.isAndroid) return false;
    final result = await _channel.invokeMethod<bool>('deleteFile', {
      'uri': uri,
    });
    return result == true;
  }
}
