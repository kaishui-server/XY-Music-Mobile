import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/db_path.dart';

/// 自动清理阈值：缓存总量达到该值（256MB）时触发自动清理。
const int kAutoCleanThresholdBytes = 256 * 1024 * 1024;

/// 两次自动检查之间的最小间隔，避免频繁扫描目录影响性能。
const Duration kAutoCleanMinInterval = Duration(minutes: 1);

/// 周期性兜底检查间隔（长时间前台使用时也能触发）。
const Duration kAutoCleanPeriodicInterval = Duration(minutes: 30);

/// 清理时跳过最近修改的文件（保护正在写入/下载中的缓存）。
const Duration kAutoCleanSkipRecent = Duration(seconds: 60);

/// 下载中转残留文件超过该时长才清理（正在下载的任务时间较新，不受影响）。
const Duration kStagingResidueMinAge = Duration(hours: 24);

/// 缓存占用统计（字节）。
class CacheUsage {
  const CacheUsage({
    required this.coverBytes,
    required this.streamCacheBytes,
    required this.stagingBytes,
    required this.tempBytes,
  });

  final int coverBytes;
  final int streamCacheBytes;
  final int stagingBytes;
  final int tempBytes;

  /// 纳入自动清理判断的可再生缓存（封面 + 播放流缓存 + 下载中转残留 +
  /// 临时文件）。临时文件（WebView/引擎缓存、更新残留等）全部可再生，
  /// 不纳入的话设置页显示的总量会永远高于阈值却永不触发自动清理。
  int get autoCleanBytes =>
      coverBytes + streamCacheBytes + stagingBytes + tempBytes;

  /// 展示用总占用（含临时文件）。
  int get totalBytes =>
      coverBytes + streamCacheBytes + stagingBytes + tempBytes;
}

/// 一次自动清理的结果。
class AutoCleanResult {
  const AutoCleanResult({required this.freedBytes, required this.usageAfter});

  final int freedBytes;
  final CacheUsage usageAfter;

  bool get cleaned => freedBytes > 0;
}

/// 缓存自动清理服务（单例）。
///
/// 统计范围：封面缓存（{dataDir}/covers）、播放流缓存
/// （%APPDATA%/com.xymusic.desktop/stream_cache）、下载中转残留
/// （{supportDir}/download_staging，仅超过 24h 的残留文件）、临时目录
/// （WebView/引擎缓存、更新残留等，全部可再生）。
///
/// 清理策略：缓存总量达到 256MB 时**自动清理全部缓存**——封面、播放
/// 流、临时目录（含子目录结构，递归收集）按 LRU 从最旧开始删除直到
/// 清空，下载中转只清超过 24 小时的残留；全部跳过最近 60 秒修改的
/// 文件（正在写入/下载中）。不会触碰歌单、收藏、插件、设置与用户
/// 下载的歌曲文件。
class CacheAutoCleanService {
  CacheAutoCleanService._();

  static final CacheAutoCleanService instance = CacheAutoCleanService._();

  DateTime? _lastCheckAt;
  bool _running = false;
  Timer? _periodicTimer;

  /// 最近一次自动清理信息（供 UI 展示）。
  DateTime? lastCleanAt;
  int lastFreedBytes = 0;

  /// 启动周期兜底检查。可在启动流程末尾调用一次（幂等）。
  void startPeriodicCheck() {
    _periodicTimer ??= Timer.periodic(
      kAutoCleanPeriodicInterval,
      (_) => unawaited(checkAndCleanIfNeeded()),
    );
  }

  /// 统计当前缓存占用。
  Future<CacheUsage> computeUsage() async {
    final dataDir = await resolveAppDataDir();
    final supportDir = await getApplicationSupportDirectory();
    final tempDir = await getTemporaryDirectory();
    final streamCacheDir = _streamCacheDir();
    final results = await Future.wait([
      _dirSize(p.join(dataDir, 'covers')),
      streamCacheDir == null
          ? Future.value(0)
          : _dirSize(streamCacheDir),
      _dirSize(p.join(supportDir.path, 'download_staging')),
      _dirSize(tempDir.path),
    ]);
    return CacheUsage(
      coverBytes: results[0],
      streamCacheBytes: results[1],
      stagingBytes: results[2],
      tempBytes: results[3],
    );
  }

  /// 检查缓存总量，达到阈值则自动清理。
  ///
  /// 带节流与并发保护：间隔不足 [kAutoCleanMinInterval] 或上次清理仍在
  /// 执行时直接跳过；扫描与删除均为异步目录操作，不阻塞 UI。
  Future<AutoCleanResult?> checkAndCleanIfNeeded() async {
    if (_running) return null;
    final now = DateTime.now();
    if (_lastCheckAt != null &&
        now.difference(_lastCheckAt!) < kAutoCleanMinInterval) {
      return null;
    }
    _lastCheckAt = now;
    _running = true;
    try {
      final usage = await computeUsage();
      if (usage.autoCleanBytes < kAutoCleanThresholdBytes) {
        return AutoCleanResult(freedBytes: 0, usageAfter: usage);
      }
      final freed = await _cleanToTarget(usage);
      final usageAfter = await computeUsage();
      final result = AutoCleanResult(freedBytes: freed, usageAfter: usageAfter);
      if (freed > 0) {
        lastCleanAt = DateTime.now();
        lastFreedBytes = freed;
      }
      return result;
    } finally {
      _running = false;
    }
  }

  /// 执行全量缓存清理，返回释放的字节数。
  ///
  /// 达到 256MB 阈值后清理**所有**可再生的缓存类目（封面、播放流、
  /// 临时目录），每类都从最旧开始删到清空；下载中转只清 24h 残留。
  Future<int> _cleanToTarget(CacheUsage usage) async {
    final dataDir = await resolveAppDataDir();
    final supportDir = await getApplicationSupportDirectory();
    final streamCacheDir = _streamCacheDir();
    final tempDir = await getTemporaryDirectory();

    var freed = 0;
    // 播放流缓存：LRU 清空（.dat 分片）。
    if (streamCacheDir != null) {
      freed += await _lruEvictDir(
        streamCacheDir,
        targetBytes: 0,
        extensions: const ['.dat'],
      );
    }
    // 封面缓存：LRU 清空。
    freed += await _lruEvictDir(
      p.join(dataDir, 'covers'),
      targetBytes: 0,
    );
    // 临时文件：LRU 清空。必须递归收集——临时目录的占用大头（WebView
    // 缓存等）在子目录结构里，仅清顶层文件清不到，316MB 永不下降的
    // 旧问题正是此处漏清。
    freed += await _lruEvictDir(tempDir.path, targetBytes: 0, recursive: true);

    // 下载中转残留：清理超过 24 小时的旧文件（不影响正在下载的任务）。
    final stagingDir = p.join(supportDir.path, 'download_staging');
    freed += await _cleanStagingResidue(stagingDir);

    return freed;
  }

  /// 对目录内文件按最后修改时间做 LRU 淘汰：从最旧开始删除，直到目录
  /// 占用不超过 [targetBytes]（0 = 全清）。最近 [kAutoCleanSkipRecent]
  /// 内修改的文件跳过（保护正在写入/下载中的缓存）。[recursive] 时递归
  /// 收集子目录中的文件（临时目录的 WebView 缓存等占用在子目录结构里）。
  /// 返回释放的字节数。
  Future<int> _lruEvictDir(
    String dirPath, {
    required int targetBytes,
    List<String> extensions = const [],
    bool recursive = false,
  }) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return 0;
      final now = DateTime.now();
      final files = <({File file, int size, DateTime modified})>[];
      var total = 0;
      await for (final entity in dir.list(
        recursive: recursive,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        if (extensions.isNotEmpty &&
            !extensions.any((e) => entity.path.toLowerCase().endsWith(e))) {
          continue;
        }
        try {
          final size = await entity.length();
          final modified = await entity.lastModified();
          files.add((file: entity, size: size, modified: modified));
          total += size;
        } catch (_) {}
      }
      if (total <= targetBytes) return 0;

      files.sort((a, b) => a.modified.compareTo(b.modified));
      var freed = 0;
      for (final item in files) {
        if (total - freed <= targetBytes) break;
        if (now.difference(item.modified) < kAutoCleanSkipRecent) continue;
        try {
          await item.file.delete();
          freed += item.size;
        } catch (_) {
          // 删除失败（Windows 上文件被占用等），跳过该文件继续。
        }
      }
      return freed;
    } catch (_) {
      return 0;
    }
  }

  /// 删除下载中转目录中超过 [kStagingResidueMinAge] 的残留文件。
  Future<int> _cleanStagingResidue(String dirPath) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return 0;
      final now = DateTime.now();
      var freed = 0;
      await for (final entity in dir.list(followLinks: false)) {
        try {
          final isOld = switch (entity) {
            File f => now.difference(await f.lastModified()) >
                kStagingResidueMinAge,
            Directory d => now.difference(await d.stat().then((s) => s.modified)) >
                kStagingResidueMinAge,
            _ => false,
          };
          if (!isOld) continue;
          if (entity is File) {
            final size = await entity.length();
            await entity.delete();
            freed += size;
          } else if (entity is Directory) {
            await entity.delete(recursive: true);
            freed += 1;
          }
        } catch (_) {}
      }
      return freed;
    } catch (_) {
      return 0;
    }
  }

  /// 播放流缓存目录（Windows: %APPDATA%/com.xymusic.desktop/stream_cache）。
  /// 其他平台返回 null（由 Rust 侧统一管理）。
  String? _streamCacheDir() {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return p.join(appData, 'com.xymusic.desktop', 'stream_cache');
      }
    }
    return null;
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
}
