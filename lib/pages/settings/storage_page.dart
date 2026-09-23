import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../src/core/db_path.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/top_notice.dart';

/// 各类缓存的占用统计（字节）。
class _StorageUsage {
  const _StorageUsage({
    required this.coverBytes,
    required this.remoteBytes,
    required this.stagingBytes,
    required this.tempBytes,
  });

  final int coverBytes;
  final int remoteBytes;
  final int stagingBytes;
  final int tempBytes;

  int get totalBytes =>
      coverBytes + remoteBytes + stagingBytes + tempBytes;
}

/// 递归统计目录占用（目录不存在按 0 处理）。
Future<int> _dirSize(String path) async {
  try {
    final dir = Directory(path);
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
    return total;
  } catch (_) {
    return 0;
  }
}

/// 删除目录下的全部内容（保留目录本身）。
Future<void> _clearDirectory(String path) async {
  try {
    final dir = Directory(path);
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      try {
        if (entity is Directory) {
          await entity.delete(recursive: true);
        } else if (entity is File) {
          await entity.delete();
        }
      } catch (_) {}
    }
  } catch (_) {}
}

final _storageUsageProvider =
    FutureProvider.autoDispose<_StorageUsage>((ref) async {
      final dataDir = await ref.watch(appDataDirProvider.future);
      final supportDir = await getApplicationSupportDirectory();
      final tempDir = await getTemporaryDirectory();
      final results = await Future.wait([
        _dirSize(p.join(dataDir, 'covers')),
        _dirSize(p.join(dataDir, 'remote-cache')),
        _dirSize(p.join(supportDir.path, 'download_staging')),
        _dirSize(tempDir.path),
      ]);
      return _StorageUsage(
        coverBytes: results[0],
        remoteBytes: results[1],
        stagingBytes: results[2],
        tempBytes: results[3],
      );
    });

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value >= 100 || unit == 0
      ? value.round().toString()
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

class StoragePage extends ConsumerWidget {
  const StoragePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final usage = ref.watch(_storageUsageProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('存储与缓存'),
        actions: [
          IconButton(
            tooltip: '重新统计',
            onPressed: () => ref.invalidate(_storageUsageProvider),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: usage.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('缓存统计失败：$error'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => ref.invalidate(_storageUsageProvider),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
        data: (usageData) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
          children: [
            // 总览卡片：总占用 + 一键清理。
            Card(
              elevation: 0,
              color: scheme.surfaceContainerHighest.withValues(alpha: .5),
              margin: const EdgeInsets.only(bottom: 18),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '缓存总占用',
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _formatBytes(usageData.totalBytes),
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '含封面、云音乐播放缓存、下载中转与临时文件',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: usageData.totalBytes > 0
                          ? () => _clearAll(context, ref, usageData)
                          : null,
                      icon: const Icon(Icons.cleaning_services_rounded),
                      label: const Text('一键清理'),
                    ),
                  ],
                ),
              ),
            ),
            _CacheTile(
              icon: Icons.image_outlined,
              title: '封面缓存',
              description: '在线歌曲与专辑的封面图片',
              bytes: usageData.coverBytes,
              onClear: (context, ref) =>
                  _clearCovers(context, ref),
            ),
            _CacheTile(
              icon: Icons.cloud_outlined,
              title: '云音乐播放缓存',
              description: '网盘歌曲播放时缓存的音频数据',
              bytes: usageData.remoteBytes,
              onClear: (context, ref) => _clearRemote(context, ref),
            ),
            _CacheTile(
              icon: Icons.download_outlined,
              title: '下载中转文件',
              description: '下载失败或取消时残留的中转文件',
              bytes: usageData.stagingBytes,
              onClear: (context, ref) => _clearStaging(context, ref),
            ),
            _CacheTile(
              icon: Icons.folder_open_outlined,
              title: '临时文件',
              description: '更新安装包等系统临时文件',
              bytes: usageData.tempBytes,
              onClear: (context, ref) => _clearTemp(context, ref),
            ),
            _CacheTile(
              icon: Icons.memory_outlined,
              title: '内存缓存',
              description: '搜索结果与播放流缓冲，清理后重新加载',
              bytes: null,
              onClear: (context, ref) => _clearMemory(context, ref),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                '清理缓存不会影响歌单、收藏、插件与设置；'
                '已下载的歌曲保存在下载目录中，也不会被清理。',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel = '清理',
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(_storageUsageProvider);
    await ref.read(_storageUsageProvider.future);
  }

  Future<void> _clearCovers(BuildContext context, WidgetRef ref) async {
    if (!await _confirm(
      context,
      title: '清理封面缓存？',
      message: '已缓存的封面将被删除，再次播放对应歌曲时会重新下载。',
    )) {
      return;
    }
    try {
      final dataDir = await ref.read(appDataDirProvider.future);
      await clearCoverCache(cacheRoot: dataDir);
      if (context.mounted) {
        XyNotice.show(context, message: '封面缓存已清理');
      }
    } catch (error) {
      if (context.mounted) {
        XyNotice.show(
          context,
          message: '清理失败：$error',
          type: XyNoticeType.error,
        );
      }
    }
    await _refresh(ref);
  }

  Future<void> _clearRemote(BuildContext context, WidgetRef ref) async {
    if (!await _confirm(
      context,
      title: '清理播放缓存？',
      message: '网盘歌曲的本地缓存将被删除，再次播放时会重新从网盘加载。',
    )) {
      return;
    }
    try {
      final dataDir = await ref.read(appDataDirProvider.future);
      await clearRemoteCache(cacheRoot: p.join(dataDir, 'remote-cache'));
      if (context.mounted) {
        XyNotice.show(context, message: '播放缓存已清理');
      }
    } catch (error) {
      if (context.mounted) {
        XyNotice.show(
          context,
          message: '清理失败：$error',
          type: XyNoticeType.error,
        );
      }
    }
    await _refresh(ref);
  }

  Future<void> _clearStaging(BuildContext context, WidgetRef ref) async {
    if (!await _confirm(
      context,
      title: '清理下载中转文件？',
      message: '仅删除下载失败或取消时的残留文件，正在下载的任务不受影响。',
    )) {
      return;
    }
    final supportDir = await getApplicationSupportDirectory();
    await _clearDirectory(p.join(supportDir.path, 'download_staging'));
    if (context.mounted) {
      XyNotice.show(context, message: '下载中转文件已清理');
    }
    await _refresh(ref);
  }

  Future<void> _clearTemp(BuildContext context, WidgetRef ref) async {
    if (!await _confirm(
      context,
      title: '清理临时文件？',
      message: '将清空应用临时目录，正在进行的更新下载等任务会受影响。',
    )) {
      return;
    }
    final tempDir = await getTemporaryDirectory();
    await _clearDirectory(tempDir.path);
    if (context.mounted) {
      XyNotice.show(context, message: '临时文件已清理');
    }
    await _refresh(ref);
  }

  Future<void> _clearMemory(BuildContext context, WidgetRef ref) async {
    try {
      await lxClearCache();
      await clearStreamCache();
      if (context.mounted) {
        XyNotice.show(context, message: '内存缓存已释放');
      }
    } catch (error) {
      if (context.mounted) {
        XyNotice.show(
          context,
          message: '清理失败：$error',
          type: XyNoticeType.error,
        );
      }
    }
  }

  Future<void> _clearAll(
    BuildContext context,
    WidgetRef ref,
    _StorageUsage usage,
  ) async {
    if (!await _confirm(
      context,
      title: '一键清理全部缓存？',
      message: '将清理封面、播放缓存、下载中转、临时文件与内存缓存，'
          '不影响歌单、收藏、插件与已下载的歌曲。',
      confirmLabel: '全部清理',
    )) {
      return;
    }
    try {
      final dataDir = await ref.read(appDataDirProvider.future);
      final supportDir = await getApplicationSupportDirectory();
      final tempDir = await getTemporaryDirectory();
      var cleared = 0;
      try {
        await clearCoverCache(cacheRoot: dataDir);
        cleared += usage.coverBytes;
      } catch (_) {}
      try {
        await clearRemoteCache(
          cacheRoot: p.join(dataDir, 'remote-cache'),
        );
        cleared += usage.remoteBytes;
      } catch (_) {}
      await _clearDirectory(
        p.join(supportDir.path, 'download_staging'),
      );
      cleared += usage.stagingBytes;
      await _clearDirectory(tempDir.path);
      cleared += usage.tempBytes;
      try {
        await lxClearCache();
        await clearStreamCache();
      } catch (_) {}
      if (context.mounted) {
        XyNotice.show(
          context,
          message: '已释放 ${_formatBytes(cleared)} 缓存空间',
          type: XyNoticeType.success,
        );
      }
    } catch (error) {
      if (context.mounted) {
        XyNotice.show(
          context,
          message: '清理失败：$error',
          type: XyNoticeType.error,
        );
      }
    }
    await _refresh(ref);
  }
}

/// 单条缓存条目：图标 + 名称 + 说明 + 占用 + 清理入口。
class _CacheTile extends ConsumerWidget {
  const _CacheTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.bytes,
    required this.onClear,
  });

  final IconData icon;
  final String title;
  final String description;
  final int? bytes;
  final Future<void> Function(BuildContext, WidgetRef) onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final sizeText = bytes == null ? '—' : _formatBytes(bytes!);
    final canClear = bytes == null || bytes! > 0;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: .5),
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Icon(icon, color: scheme.primary),
        title: Text(title),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(description, style: const TextStyle(fontSize: 12)),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              sizeText,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: canClear ? () => onClear(context, ref) : null,
              child: Text(canClear ? '清理' : '已清理'),
            ),
          ],
        ),
      ),
    );
  }
}
