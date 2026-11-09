import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// 网络封面的磁盘缓存。
///
/// Flutter 的 `Image.network`（[NetworkImage]）只做进程内解码缓存，**不落盘**：
/// 每次冷启动、每次 `PaintingBinding.instance.imageCache.clear()` 之后，歌单里
/// 所有在线封面都要重新走一遍网络请求——这是「歌单封面加载慢」的主要来源。
///
/// 这里把封面字节落到 `{cacheRoot}/cover_http_cache/`，之后直接按本地文件
/// 解码（`FileImage`）。命中一次之后就不再触网，冷启动也是纯本地 IO。
///
/// 特性：
/// * 单飞：同一 URL 的并发请求合并成一个，避免列表里同一封面重复下载；
/// * 并发闸门：最多 6 个 HTTP 请求同时在跑，防止一屏 30 个封面同时打满连接池；
/// * 失败记忆：失败后 20s 内不再重试，避免弱网下反复打同一个坏 URL；
/// * 磁盘二次确认：进程重启后内存索引为空，仍会先探测磁盘再决定是否下载；
/// * 容量回收：文件数超过阈值时按修改时间淘汰最旧的一批。
class CoverDiskCache {
  CoverDiskCache._();

  static const int _maxConcurrent = 6;
  static const int _pathIndexLimit = 600;
  static const int _maxFiles = 800;
  static const int _pruneToFiles = 600;
  static const Duration _retryAfter = Duration(seconds: 20);
  static const Duration _timeout = Duration(seconds: 12);
  static const List<String> _knownExts = <String>['jpg', 'png', 'webp', 'gif'];

  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// url -> 本地文件路径。热路径同步命中，避免每次 build 都等一次异步探盘。
  static final LinkedHashMap<String, String> _index = LinkedHashMap();

  static final Map<String, Future<String?>> _inflight = {};
  static final Map<String, DateTime> _failedAt = {};
  static final http.Client _client = http.Client();

  static Directory? _dir;
  static int _active = 0;
  static final List<Completer<void>> _waiters = <Completer<void>>[];
  static bool _pruning = false;

  /// 同步查内存索引；命中时把条目移到队尾维持 LRU 顺序。
  static String? peek(String url) {
    final hit = _index.remove(url);
    if (hit == null) return null;
    _index[url] = hit;
    return hit;
  }

  /// 丢弃某条索引（文件被清理或解码失败时调用）。
  static void forget(String url) => _index.remove(url);

  /// 取封面本地文件路径；失败返回 null（调用方回落到占位/代理）。
  static Future<String?> resolve(
    String url, {
    Map<String, String>? headers,
    required String cacheRoot,
  }) {
    final hit = peek(url);
    if (hit != null) {
      // 文件可能被系统清理过，这里只做一次轻量探测，不存在就重新下载。
      if (File(hit).existsSync()) return Future<String?>.value(hit);
      _index.remove(url);
    }
    final failed = _failedAt[url];
    if (failed != null && DateTime.now().difference(failed) < _retryAfter) {
      return Future<String?>.value(null);
    }
    return _inflight.putIfAbsent(url, () async {
      try {
        final path = await _download(url, headers: headers, cacheRoot: cacheRoot);
        if (path == null) {
          _failedAt[url] = DateTime.now();
          return null;
        }
        _remember(url, path);
        _failedAt.remove(url);
        return path;
      } catch (_) {
        _failedAt[url] = DateTime.now();
        return null;
      } finally {
        _inflight.remove(url);
      }
    });
  }

  /// 预热一批 URL（列表滚动前调用，命中后列表首帧直接出图）。
  static void prewarm(
    Iterable<String> urls, {
    required String cacheRoot,
    int limit = 24,
  }) {
    var count = 0;
    for (final url in urls) {
      if (count >= limit) break;
      if (url.isEmpty) continue;
      if (peek(url) != null) continue;
      count++;
      unawaited(resolve(url, cacheRoot: cacheRoot));
    }
  }

  static void clear() {
    _index.clear();
    _failedAt.clear();
  }

  static void _remember(String url, String path) {
    _index.remove(url);
    _index[url] = path;
    while (_index.length > _pathIndexLimit) {
      _index.remove(_index.keys.first);
    }
  }

  static Future<Directory> _ensureDir(String cacheRoot) async {
    final cached = _dir;
    if (cached != null && cached.existsSync()) return cached;
    final dir = Directory('$cacheRoot${Platform.pathSeparator}cover_http_cache');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    _dir = dir;
    return dir;
  }

  static Future<String?> _download(
    String url, {
    Map<String, String>? headers,
    required String cacheRoot,
  }) async {
    final dir = await _ensureDir(cacheRoot);
    final key = sha256.convert(utf8.encode(url)).toString();

    // 进程重启后内存索引是空的：先探盘，命中就不用下载。
    for (final ext in _knownExts) {
      final candidate = File('${dir.path}${Platform.pathSeparator}$key.$ext');
      if (candidate.existsSync() && candidate.lengthSync() > 0) {
        return candidate.path;
      }
    }

    await _acquire();
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme) return null;
      final requestHeaders = <String, String>{
        if (headers != null) ...headers,
      };
      requestHeaders.putIfAbsent('User-Agent', () => _userAgent);

      final resp = await _client
          .get(uri, headers: requestHeaders)
          .timeout(_timeout);
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return null;

      final bytes = resp.bodyBytes;
      // 太小的多半是错误页/1x1 占位，直接当作失败，避免把垃圾写进缓存。
      if (bytes.length < 256) return null;

      final ext = _extFor(bytes, resp.headers['content-type']);
      final target = File('${dir.path}${Platform.pathSeparator}$key.$ext');
      await target.writeAsBytes(bytes, flush: false);
      unawaited(_maybePrune(dir));
      return target.path;
    } finally {
      _release();
    }
  }

  static String _extFor(List<int> bytes, String? contentType) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'jpg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return 'gif';
    }
    final ct = contentType ?? '';
    if (ct.contains('png')) return 'png';
    if (ct.contains('webp')) return 'webp';
    if (ct.contains('gif')) return 'gif';
    return 'jpg';
  }

  static Future<void> _maybePrune(Directory dir) async {
    if (_pruning) return;
    _pruning = true;
    try {
      final entries = <MapEntry<File, DateTime>>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        try {
          entries.add(MapEntry(entity, entity.lastModifiedSync()));
        } catch (_) {
          continue;
        }
      }
      if (entries.length <= _maxFiles) return;
      entries.sort((a, b) => a.value.compareTo(b.value));
      final removeCount = entries.length - _pruneToFiles;
      for (var i = 0; i < removeCount; i++) {
        try {
          await entries[i].key.delete();
        } catch (_) {
          // 清理失败不影响主流程。
        }
      }
    } catch (_) {
      // 忽略：缓存回收是尽力而为。
    } finally {
      _pruning = false;
    }
  }

  static Future<void> _acquire() async {
    if (_active < _maxConcurrent) {
      _active++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
  }

  static void _release() {
    if (_waiters.isNotEmpty) {
      // 直接把名额转交等待者，_active 不变。
      _waiters.removeAt(0).complete();
      return;
    }
    if (_active > 0) _active--;
  }
}
