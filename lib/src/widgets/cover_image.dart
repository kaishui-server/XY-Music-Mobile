import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../rust/api.dart';

/// 封面加载组件：经 Rust 缩略图接口取本地缓存封面，无封面/失败时回退渐变占位。
class CoverImage extends ConsumerStatefulWidget {
  const CoverImage({
    super.key,
    required this.songPath,
    this.imageUrl,
    this.width = 48,
    this.height = 48,
    this.radius = 12,
    this.cacheWidth,
    this.highQuality = false,
    this.gradient = const [Color(0xFFEC4141), Color(0xFFFF8A5C)],
    this.icon = Icons.music_note,
  });

  final String songPath;
  final String? imageUrl;
  final double width;
  final double height;
  final double radius;

  /// 图片解码宽度（物理像素）。只供明确需要低分辨率纹理的页面使用；
  /// 普通封面不强制 ResizeImage，避免影响所有列表和播放底栏。
  final int? cacheWidth;

  /// 本地歌曲的大尺寸封面使用高清缓存，避免将列表缩略图放大后模糊。
  /// 网络封面仍由网络图片本身负责分辨率，不受此开关影响。
  final bool highQuality;
  final List<Color> gradient;
  final IconData icon;

  @override
  ConsumerState<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends ConsumerState<CoverImage> {
  // 按歌曲路径缓存缩略图路径，避免重复触发 Rust 提取。
  static final Map<String, String> _cache = {};
  static final LinkedHashMap<String, Uint8List> _proxyCache = LinkedHashMap();
  static final Map<String, Future<Uint8List?>> _proxyTasks = {};
  static const _proxyCacheLimit = 64;
  String? _path;
  Uint8List? _proxyBytes;
  bool _proxyLoading = false;
  bool _proxyFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songPath != widget.songPath ||
        oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.highQuality != widget.highQuality) {
      _path = null;
      _proxyBytes = null;
      _proxyLoading = false;
      _proxyFailed = false;
      _load();
    }
  }

  Future<void> _load() async {
    final imageUrl = normalizeCoverImageUrl(widget.imageUrl);
    if (imageUrl.isNotEmpty) return;
    final cached = _cache[_cacheKey];
    if (cached != null) {
      if (mounted) setState(() => _path = cached.isEmpty ? null : cached);
      return;
    }
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final cacheRoot = await ref.read(appDataDirProvider.future);
      final p = await (widget.highQuality
          ? getSongCover(
              dbPath: dbPath,
              cacheRoot: cacheRoot,
              path: widget.songPath,
            )
          : getSongCoverThumbnail(
              dbPath: dbPath,
              cacheRoot: cacheRoot,
              path: widget.songPath,
            ));
      _cache[_cacheKey] = p;
      if (mounted) setState(() => _path = p.isEmpty ? null : p);
    } catch (_) {
      _cache[_cacheKey] = '';
      if (mounted) setState(() => _path = null);
    }
  }

  String get _cacheKey =>
      '${widget.highQuality ? 'full' : 'thumb'}:${widget.songPath}';

  Future<void> _loadProxiedImage(String imageUrl) async {
    if (_proxyLoading || _proxyFailed) return;
    _proxyLoading = true;
    final cached = _proxyCache.remove(imageUrl);
    if (cached != null) {
      _proxyCache[imageUrl] = cached;
      if (mounted && imageUrl == normalizeCoverImageUrl(widget.imageUrl)) {
        setState(() {
          _proxyBytes = cached;
          _proxyLoading = false;
        });
      }
      return;
    }
    try {
      final bytes = await _proxyTasks.putIfAbsent(imageUrl, () async {
        try {
          final dataUrl = await proxyImage(
            url: imageUrl,
            referer: 'https://music.163.com/',
          );
          final comma = dataUrl.indexOf(',');
          if (comma <= 0 || !dataUrl.substring(0, comma).contains(';base64')) {
            return null;
          }
          final decoded = base64Decode(dataUrl.substring(comma + 1));
          if (decoded.isEmpty) return null;
          _proxyCache[imageUrl] = decoded;
          while (_proxyCache.length > _proxyCacheLimit) {
            _proxyCache.remove(_proxyCache.keys.first);
          }
          return decoded;
        } finally {
          _proxyTasks.remove(imageUrl);
        }
      });
      if (!mounted || imageUrl != normalizeCoverImageUrl(widget.imageUrl)) {
        return;
      }
      setState(() {
        _proxyBytes = bytes;
        _proxyLoading = false;
        _proxyFailed = bytes == null;
      });
    } catch (_) {
      if (mounted && imageUrl == normalizeCoverImageUrl(widget.imageUrl)) {
        setState(() {
          _proxyLoading = false;
          _proxyFailed = true;
        });
      }
    }
  }

  Widget _networkError(String imageUrl) {
    if (needsCoverImageProxy(imageUrl) && !_proxyLoading && !_proxyFailed) {
      // errorBuilder 可能处于当前 build 阶段，延后到本帧结束后
      // 再回写状态，避免 build scope 异常。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && imageUrl == normalizeCoverImageUrl(widget.imageUrl)) {
          _loadProxiedImage(imageUrl);
        }
      });
    }
    return _placeholder();
  }

  @override
  Widget build(BuildContext context) {
    final path = _path;
    final imageUrl = normalizeCoverImageUrl(widget.imageUrl);
    final decodeWidth = widget.cacheWidth?.clamp(1, 2048);
    final proxyBytes = _proxyBytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: proxyBytes != null
            ? Image.memory(
                proxyBytes,
                cacheWidth: decodeWidth,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _placeholder(),
              )
            : imageUrl.isNotEmpty && !_proxyLoading && !_proxyFailed
            ? Image.network(
                imageUrl,
                headers: _networkImageHeaders(imageUrl),
                cacheWidth: decodeWidth,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _networkError(imageUrl),
              )
            : (path != null)
            ? Image.file(
                File(path),
                cacheWidth: decodeWidth,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _placeholder(),
              )
            : _placeholder(),
      ),
    );
  }

  Widget _placeholder() {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: widget.gradient,
        ),
      ),
      child: Center(
        child: Icon(
          widget.icon,
          color: Colors.white.withValues(alpha: 0.85),
          size: widget.width.clamp(0, 200) * 0.4,
        ),
      ),
    );
  }
}

/// 网易云图片 CDN 会对 Dart 默认 User-Agent 返回 403，必须模拟浏览器请求。
/// 其他平台保持默认请求头，避免错误的 Referer 影响其防盗链规则。
Map<String, String>? coverImageNetworkHeaders(String imageUrl) {
  final host = Uri.tryParse(imageUrl)?.host.toLowerCase() ?? '';
  if (host == 'music.126.net' || host.endsWith('.music.126.net')) {
    return const {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      'Referer': 'https://music.163.com/',
    };
  }
  return null;
}

/// 网易云 CDN 在部分 Android ROM/运营商网络下直连会 403，
/// 与电脑端一致通过 Rust 图片代理加载。
bool needsCoverImageProxy(String imageUrl) {
  final host = Uri.tryParse(imageUrl)?.host.toLowerCase() ?? '';
  return host == 'music.126.net' || host.endsWith('.music.126.net');
}

/// 兼容旧插件和旧播放会话保存的网易云 HTTP / 协议省略封面地址。
/// Android 的网络安全配置只允许本机音频代理使用明文 HTTP，远程封面必须 HTTPS。
String normalizeCoverImageUrl(String? imageUrl) {
  var normalized = imageUrl?.trim() ?? '';
  if (normalized.startsWith('//')) normalized = 'https:$normalized';
  final uri = Uri.tryParse(normalized);
  final host = uri?.host.toLowerCase() ?? '';
  if (normalized.startsWith('http://') &&
      (host == 'music.126.net' || host.endsWith('.music.126.net'))) {
    normalized = 'https://${normalized.substring(7)}';
  }
  return normalized;
}

Map<String, String>? _networkImageHeaders(String imageUrl) =>
    coverImageNetworkHeaders(imageUrl);
