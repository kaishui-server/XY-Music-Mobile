// 歌曲分享服务（移动端）。
//
// - 调用服务端 `create_share` 生成分享链接（落地页 /s/{shareId} 不做网页播放，仅拉起客户端）。
// - 播放时预加载分享链接：同一首歌只生成一次并缓存，避免用户点分享时才等网络。
// - 签名请求在 Rust 侧完成，这里通过 requestBackendAction 转发给服务端。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_provider.dart';
import '../core/db_path.dart';
import '../player/player_provider.dart';
import '../rust/api.dart' show getSongCoverThumbnail;

/// 分享链接有效时长（分钟）。
const _shareLinkValidityMinutes = 120;

/// 面向 UI 的分享服务实例（预加载 + 取缓存 + 生成分享链接）。
final shareServiceProvider = Provider<ShareService>((ref) => ShareService(ref));

class ShareService {
  ShareService(this._ref);

  final Ref _ref;

  /// path -> 已生成的分享链接
  final Map<String, String> _cache = {};
  /// path -> 正在生成中的 future（避免并发重复请求）
  final Map<String, Future<String>> _pending = {};

  /// 当前缓存中是否已有该歌曲的分享链接。
  bool hasCached(QueueItem? song) {
    if (song == null) return false;
    final url = _cache[song.path];
    return url != null && url.isNotEmpty;
  }

  /// 取已生成好的分享链接；没有则返回 null。
  String? cached(QueueItem? song) {
    if (song == null) return null;
    return _cache[song.path];
  }

  /// 获取（必要时创建）指定歌曲的分享链接；已缓存或已在生成中则复用。
  Future<String> create(QueueItem song) async {
    final key = song.path;
    final cachedUrl = _cache[key];
    if (cachedUrl != null && cachedUrl.isNotEmpty) return cachedUrl;
    final pending = _pending[key];
    if (pending != null) return pending;

    final future = resolveCover(song)
        .then((cover) => _ref
            .read(authProvider.notifier)
            .requestBackendAction('create_share', _buildBody(song, cover),
                fetchTimeoutMs: 15000))
        .then((data) {
      final url = (data['share_url'] ?? '').toString();
      _cache[key] = url;
      _pending.remove(key);
      return url;
    }).catchError((Object e) {
      _pending.remove(key);
      throw e;
    });

    _pending[key] = future;
    return future;
  }

  /// 解析分享封面 URL：在线封面（http(s)）直接用；
  /// 本地封面读取本地文件上传到服务端，返回可被落地页访问的 HTTPS URL。
  /// 失败静默返回空串（分享仍可进行，仅无封面）。
  /// 供分享链接生成与 QQ 分享共用（QQ 分享只需 http(s) 封面缩略图）。
  Future<String> resolveCover(QueueItem song) async {
    final coverUrl = song.coverUrl ?? '';
    if (coverUrl.isNotEmpty && _isRemoteHttp(coverUrl)) return coverUrl;
    try {
      final path = await _localCoverFile(song);
      if (path == null || path.isEmpty) return '';
      final file = File(path);
      if (!await file.exists()) return '';
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) return '';
      final dataUrl = 'data:${_mimeFromPath(path)};base64,${base64Encode(bytes)}';
      final data = await _ref
          .read(authProvider.notifier)
          .requestBackendAction('upload_cover', {'image_data': dataUrl},
              fetchTimeoutMs: 20000);
      return (data['cover_url'] ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  /// 取本地封面文件路径：优先 coverUrl 指向的本地文件（file:// 或绝对路径），
  /// 否则现场提取内嵌封面缩略图（与系统媒体封面兜底同逻辑）。
  /// 拿不到返回 null。
  Future<String?> _localCoverFile(QueueItem song) async {
    final text = song.coverUrl?.trim() ?? '';
    if (text.isNotEmpty &&
        !text.startsWith('content://') &&
        !_isRemoteHttp(text)) {
      final path = _stripFileScheme(
          text.startsWith('//') ? text : normalizeLocalAudioPath(text));
      try {
        final f = File(path);
        if (await f.exists()) return path;
      } catch (_) {}
    }

    if (playbackSourceTypeFor(song) != PlaybackSourceType.localFile) {
      return null;
    }
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final cacheRoot = await _ref.read(appDataDirProvider.future);
      final thumbnail = await getSongCoverThumbnail(
        dbPath: dbPath,
        cacheRoot: cacheRoot,
        path: normalizeLocalAudioPath(song.path),
      );
      if (thumbnail.trim().isNotEmpty && File(thumbnail).existsSync()) {
        return thumbnail;
      }
    } catch (_) {}
    return null;
  }

  static String _stripFileScheme(String path) {
    if (path.startsWith('file://')) return path.substring('file://'.length);
    return path;
  }

  static String _mimeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  /// 预加载当前歌曲分享链接（fire-and-forget，失败静默，勿阻塞播放）。
  void preload(QueueItem? song) {
    if (song == null) return;
    final key = song.path;
    if (_cache.containsKey(key) || _pending.containsKey(key)) return;
    create(song).catchError((Object _) => '');
  }

  /// 构造 create_share 请求体。
  ///
  /// song_id 为来源 path 的稳定标识；source 按播放协议提取——
  /// lx://<source>/<songmid> → 音源 key（kw/wy/kg/tx/mg），
  /// pluginId → 插件 id，本地歌曲标记为 local。
  /// 服务端透传进深链，客户端据此显示来源并选择播放路径。
  Map<String, dynamic> _buildBody(QueueItem song, String cover) {
    String source = 'local';
    if (song.path.startsWith('lx://')) {
      source = song.path.substring('lx://'.length).split('/').first;
    } else if (song.pluginId?.trim().isNotEmpty == true) {
      source = 'plugin:${song.pluginId}';
    } else if (song.path.startsWith('http://') ||
        song.path.startsWith('https://')) {
      source = 'url';
    }

    return <String, dynamic>{
      'song_name': song.title,
      'singer': song.artist,
      'cover_url': cover,
      'song_id': song.path,
      'duration_ms': song.durationMs,
      'source': source,
      'expire_minutes': _shareLinkValidityMinutes,
    };
  }

  /// 是否可被外部访问的远程封面：http(s) 且排除本地/回环/asset 地址，
  /// 避免本地封面被误判为在线封面而跳过上传。
  static bool _isRemoteHttp(String s) {
    if (!(s.startsWith('http://') || s.startsWith('https://'))) return false;
    final lower = s.toLowerCase();
    return !(lower.contains('asset.localhost') ||
        lower.contains('localhost') ||
        lower.contains('127.0.0.1'));
  }
}
