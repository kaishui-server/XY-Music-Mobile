import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../auth/auth_provider.dart';

int compareAppVersions(String left, String right) {
  List<int> parts(String value) => RegExp(r'\d+')
      .allMatches(value)
      .take(4)
      .map((match) => int.tryParse(match.group(0)!) ?? 0)
      .toList();
  final a = parts(left);
  final b = parts(right);
  for (var i = 0; i < (a.length > b.length ? a.length : b.length); i++) {
    final av = i < a.length ? a[i] : 0;
    final bv = i < b.length ? b[i] : 0;
    if (av != bv) return av.compareTo(bv);
  }
  return 0;
}

class DownloadCancelledException implements Exception {
  const DownloadCancelledException();
}

class DownloadCancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class DownloadProgress {
  const DownloadProgress({required this.downloaded, this.total});
  final int downloaded;
  final int? total;
  double? get fraction => total != null && total! > 0
      ? (downloaded / total!).clamp(0, 1).toDouble()
      : null;
}

Future<void> downloadAndInstallRelease(
  BuildContext context,
  BackendRelease release,
) async {
  final url = resolveBackendDownloadUrl(release.downloadUrl);
  if (url.isEmpty) {
    _showUpdateError(context, '后台尚未配置可用的 APK 下载地址');
    return;
  }
  var dialogOpen = true;
  final token = DownloadCancellationToken();
  final progress = ValueNotifier<DownloadProgress>(
    const DownloadProgress(downloaded: 0),
  );
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: ValueListenableBuilder<DownloadProgress>(
        valueListenable: progress,
        builder: (context, value, _) {
          final percent = value.fraction;
          final downloaded = _formatBytes(value.downloaded);
          final total = value.total == null
              ? ''
              : ' / ${_formatBytes(value.total!)}';
          return AlertDialog(
            title: const Text('正在下载更新'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: percent),
                const SizedBox(height: 10),
                Text(
                  percent == null
                      ? '已下载 $downloaded$total'
                      : '${(percent * 100).toStringAsFixed(0)}% · $downloaded$total',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: token.isCancelled
                    ? null
                    : () {
                        token.cancel();
                        progress.value = DownloadProgress(
                          downloaded: value.downloaded,
                          total: value.total,
                        );
                      },
                child: Text(token.isCancelled ? '正在中断…' : '中断下载'),
              ),
            ],
          );
        },
      ),
    ),
  );
  try {
    final file = await downloadReleaseApk(
      Uri.parse(url),
      release.version,
      token: token,
      onProgress: (value) => progress.value = value,
    );
    if (!context.mounted) return;
    if (dialogOpen) {
      Navigator.of(context, rootNavigator: true).pop();
      dialogOpen = false;
    }
    await const MethodChannel(
      'com.xymusic.mobile/app_update',
    ).invokeMethod<bool>('installApk', {'path': file.path});
  } catch (error) {
    if (dialogOpen && context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      dialogOpen = false;
    }
    if (context.mounted && error is! DownloadCancelledException) {
      _showUpdateError(context, '更新失败：$error');
    }
  } finally {
    progress.dispose();
  }
}

/// 下载 APK 时支持断点续传和自动重试，避免移动网络短暂断开导致整包失败。
Future<File> downloadReleaseApk(
  Uri url,
  String version, {
  DownloadCancellationToken? token,
  void Function(DownloadProgress value)? onProgress,
}) async {
  final dir = await getTemporaryDirectory();
  final safeVersion = version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
  final file = File(p.join(dir.path, 'XY-Music-$safeVersion.apk'));
  final client = http.Client();
  Object? lastError;
  try {
    for (var attempt = 0; attempt < 4; attempt++) {
      if (token?.isCancelled == true) throw const DownloadCancelledException();
      final existing = await file.exists() ? await file.length() : 0;
      try {
        final request = http.Request('GET', url);
        if (existing > 0) request.headers['Range'] = 'bytes=$existing-';
        final response = await client
            .send(request)
            .timeout(const Duration(minutes: 5));
        if (token?.isCancelled == true) {
          await response.stream.drain<void>();
          throw const DownloadCancelledException();
        }
        final append = existing > 0 && response.statusCode == 206;
        if (response.statusCode == 416 && existing > 0) {
          await file.delete();
          continue;
        }
        if (response.statusCode != 200 && response.statusCode != 206) {
          throw Exception('下载失败：HTTP ${response.statusCode}');
        }
        final contentLength = response.contentLength;
        final total = response.statusCode == 206 && contentLength != null
            ? existing + contentLength
            : contentLength;
        var downloaded = append ? existing : 0;
        onProgress?.call(
          DownloadProgress(downloaded: downloaded, total: total),
        );
        final sink = file.openWrite(
          mode: append ? FileMode.append : FileMode.write,
        );
        try {
          await for (final chunk in response.stream) {
            if (token?.isCancelled == true) {
              throw const DownloadCancelledException();
            }
            sink.add(chunk);
            downloaded += chunk.length;
            onProgress?.call(
              DownloadProgress(downloaded: downloaded, total: total),
            );
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (await file.exists() && await file.length() > 0) return file;
        throw Exception('下载的安装包为空');
      } catch (error) {
        if (error is DownloadCancelledException) rethrow;
        lastError = error;
        if (attempt == 3) break;
        await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }
  } finally {
    client.close();
  }
  throw Exception('多次下载仍未完成：$lastError');
}

String _formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

void _showUpdateError(BuildContext context, String message) {
  showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('更新失败'),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}
