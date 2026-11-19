import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../rust/api.dart';
import 'cover_disk_cache.dart';
import 'cover_fade_in.dart';

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
    this.placeholder,
  });

  final String songPath;
  final String? imageUrl;
  final double width;
  final double height;
  final double radius;

  /// 图片解码宽度（物理像素）。不传时按显示宽度 × 设备像素比自动推导，
  /// 避免列表里的小封面按原图全尺寸解码（一张 2000×2000 的专辑图会占用
  /// 约 16MB 解码纹理，一屏几十张就是内存暴涨的主因）。
  final int? cacheWidth;

  /// 本地歌曲的大尺寸封面使用高清缓存，避免将列表缩略图放大后模糊。
  /// 网络封面仍由网络图片本身负责分辨率，不受此开关影响。
  final bool highQuality;
  final List<Color> gradient;
  final IconData icon;

  /// 自定义占位内容（如歌手头像的人形图标）。不传时使用渐变 + 图标
  /// 占位。图片加载完成前保持该占位，再淡入真实图片，避免直接替换
  /// 占位造成闪烁。
  final Widget? placeholder;

  @override
  ConsumerState<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends ConsumerState<CoverImage>
    with WidgetsBindingObserver {
  // 按歌曲路径缓存缩略图路径，避免重复触发 Rust 提取。走 LRU 上限，
  // 否则长时间播放/浏览大量歌曲后该静态表只增不减，常驻内存持续升高。
  static final LinkedHashMap<String, String> _cache = LinkedHashMap();
  static const _pathCacheLimit = 256;

  /// 「上次确认无封面」的时间戳：空结果只短暂有效。
  ///
  /// Rust 侧提取缩略图要读音频文件本体，应用刚回前台（SD 卡/SAF 挂载还没
  /// 恢复）、系统扫描占着文件锁等瞬时失败都会返回空串。这种空结果若被
  /// 永久缓存，同一首歌的封面就会一直停在默认占位图上，只有重启进程
  /// 才恢复——这正是「进后台再返回，播放栏封面变默认占位」的成因之一。
  static final Map<String, DateTime> _emptyCachedAt = {};
  static const _emptyCoverRetryAfter = Duration(seconds: 15);
  static final LinkedHashMap<String, Uint8List> _proxyCache = LinkedHashMap();
  static final Map<String, Future<Uint8List?>> _proxyTasks = {};
  static const _proxyCacheLimit = 64;

  /// 跨实例的「最近已渲染封面 provider」表（按封面身份，不按解码尺寸）。
  /// 播放栏与详情页是两棵互相独立的 CoverImage 子树，进详情页时新 State
  /// 没有上一帧可复用；有了这份表，只要封面在任一页面画过（磁盘/内存
  /// 缓存已热），新实例首帧即可拿它垫底，不会先闪占位图。
  static final LinkedHashMap<String, ImageProvider> _recentProviders =
      LinkedHashMap();
  static const _recentProviderLimit = 24;

  static ImageProvider? _recentGet(String key) {
    final hit = _recentProviders.remove(key);
    if (hit == null) return null;
    _recentProviders[key] = hit;
    return hit;
  }

  static void _recentPut(String key, ImageProvider provider) {
    _recentProviders.remove(key);
    _recentProviders[key] = provider;
    while (_recentProviders.length > _recentProviderLimit) {
      _recentProviders.remove(_recentProviders.keys.first);
    }
  }

  /// 同步取代理图缓存（命中时维持 LRU 顺序）。
  static Uint8List? _proxyCacheGet(String url) {
    final hit = _proxyCache.remove(url);
    if (hit == null) return null;
    _proxyCache[url] = hit;
    return hit;
  }

  /// 代理图字节预算：只按条数（64）限制时，CDN 返原图会撑到几十 MB，
  /// 这里再叠一层总量上限，超预算按最旧优先淘汰。
  static const _proxyCacheBytesLimit = 24 << 20;
  static int _proxyCacheBytes = 0;

  static void _putProxyCache(String key, Uint8List bytes) {
    final old = _proxyCache.remove(key);
    if (old != null) _proxyCacheBytes -= old.length;
    _proxyCache[key] = bytes;
    _proxyCacheBytes += bytes.length;
    while (_proxyCache.isNotEmpty &&
        (_proxyCache.length > _proxyCacheLimit ||
            _proxyCacheBytes > _proxyCacheBytesLimit)) {
      final evicted = _proxyCache.remove(_proxyCache.keys.first);
      if (evicted == null) break;
      _proxyCacheBytes -= evicted.length;
    }
    if (_proxyCacheBytes < 0) _proxyCacheBytes = 0;
  }

  /// 解码宽度槽位。同一条目在不同页面（列表 44 / 详情 124 / 播放页 300）
  /// 会请求不同宽度，向上取整到固定槽位可以让相邻尺寸复用同一份解码纹理，
  /// 减少 ImageCache 碎片。
  static const List<int> _decodeSlots = <int>[
    32,
    48,
    64,
    96,
    128,
    160,
    192,
    256,
    384,
    512,
    768,
    1024,
  ];

  String? _path;
  Uint8List? _proxyBytes;
  bool _proxyLoading = false;
  bool _proxyFailed = false;

  /// 网络封面的本地磁盘缓存路径。命中后直接按文件解码，不再触网。
  String? _netPath;
  String? _netResolvingUrl;
  String? _cacheRoot;

  /// 本实例上一次真正画出画面的图片 provider：切歌时把它作为新封面的
  /// 垫底层，等新图首帧到达后再交叉淡入，避免中间先闪一帧占位图。
  ImageProvider? _lastRenderedProvider;

  /// 当前垫底画面。优先上一曲已渲染的图，其次跨实例最近渲染的图。
  ImageProvider? _retainedProvider;

  /// 新曲目已确认没有任何可显示封面时置位：此时不能再用旧封面垫底，
  /// 否则切到无封面的歌会一直显示上一首的图。
  bool _noImage = false;

  /// 本地封面提取的连续失败次数（异常计入，用来决定是否缓存空结果）。
  int _loadFailures = 0;

  /// 在线封面确认失败后是否已回落过本地封面，避免两条路径来回打转。
  bool _localFallbackTried = false;

  /// 上次「回前台自愈」的时间：限流，避免切屏抖动时反复向 Rust 提取。
  DateTime? _lastResumeHealAt;

  /// 本地封面解码失败后的自愈次数，防止坏文件导致的无限重试。
  int _decodeHealCount = 0;

  String get _identityKey =>
      '${normalizeCoverImageUrl(widget.imageUrl)}|${widget.songPath}';

  @override
  void initState() {
    super.initState();
    // 监听前台/后台切换：本地封面在后台可能因缓存清理或外置存储短暂
    // 不可读而提取失败，回前台这一刻才有条件重取，否则会一直停在占位图。
    WidgetsBinding.instance.addObserver(this);
    // 详情页/播放栏是彼此独立的实例：进页面前封面已在另一棵子树画过时，
    // 直接用那份 provider 垫底，缓存命中就无需等首帧。
    _retainedProvider = _recentGet(_identityKey);
    _primeSyncCaches();
    _load();
    _loadNetwork();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _healLocalCoverOnResume();
  }

  /// 不等待异步 IO，先用已有的同步缓存把本帧能确定的字段填好：
  /// 磁盘缓存索引命中 / 代理图字节命中 / 本地缩略图路径命中时，首帧
  /// 直接就是真实封面，不再先渲染占位图。
  void _primeSyncCaches() {
    final imageUrl = normalizeCoverImageUrl(widget.imageUrl);
    if (imageUrl.isEmpty) {
      final cached = _cacheGet(_cacheKey);
      if (cached != null) {
        _path = cached.isEmpty ? null : cached;
        _noImage = cached.isEmpty;
      }
    } else if (!imageUrl.startsWith('file://')) {
      _netPath = CoverDiskCache.peek(imageUrl);
      _proxyBytes = _proxyCacheGet(imageUrl);
    }
  }

  @override
  void didUpdateWidget(CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songPath != widget.songPath ||
        oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.highQuality != widget.highQuality) {
      // 先留一帧「上一曲已渲染画面」作为垫底，再清空异步加载状态。
      _retainedProvider = _lastRenderedProvider ?? _recentGet(_identityKey);
      _lastRenderedProvider = null;
      _noImage = false;
      _path = null;
      _proxyBytes = null;
      _proxyLoading = false;
      _proxyFailed = false;
      _netPath = null;
      _netResolvingUrl = null;
      // 换歌即重置本轮的重试/回落状态：新曲目值得完整跑一遍两条路径。
      _loadFailures = 0;
      _localFallbackTried = false;
      _lastResumeHealAt = null;
      _primeSyncCaches();
      _load();
      _loadNetwork();
    }
  }

  Future<void> _load({bool force = false, bool asFallback = false}) async {
    final imageUrl = normalizeCoverImageUrl(widget.imageUrl);
    // 有在线封面时优先走网络/磁盘缓存；`asFallback` 表示网络封面已确认
    // 拿不到，此时必须回来再试一次本地内嵌封面，不能直接停在占位图。
    if (!asFallback && imageUrl.isNotEmpty) return;
    final key = _cacheKey;
    final songPath = widget.songPath;
    if (!force) {
      final cached = _cacheGet(key);
      if (cached != null) {
        if (mounted) {
          setState(() {
            _path = cached.isEmpty ? null : cached;
            _noImage = cached.isEmpty;
          });
        }
        return;
      }
    }
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final cacheRoot = await ref.read(appDataDirProvider.future);
      _cacheRoot = cacheRoot;
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
      if (!mounted || songPath != widget.songPath) return;
      if (p.isEmpty) {
        // Rust 返回空 = 这一次没提取到。空结果带冷却缓存，冷却期过后
        // 允许重试（后台返回瞬间读文件失败属于典型的一次性失败）。
        _cachePut(key, '');
        setState(() {
          _path = null;
          _noImage = true;
        });
        return;
      }
      _cachePut(key, p);
      setState(() {
        _path = p;
        _noImage = false;
      });
    } catch (_) {
      // 异常不写空缓存：异常多半是 db/目录瞬时未就绪，写进去会把封面
      // 永久钉在占位图上。仅连续失败多次后才缓存空结果，避免反复重试。
      _loadFailures++;
      if (_loadFailures >= 2) _cachePut(key, '');
      if (!mounted || songPath != widget.songPath) return;
      setState(() {
        _path = null;
        _noImage = true;
      });
    }
  }

  /// 在线封面确认失败后回落本地内嵌封面。
  Future<void> _loadLocalFallback() async {
    if (_localFallbackTried) return;
    _localFallbackTried = true;
    await _load(asFallback: true);
  }

  /// 本地封面文件解码失败（缓存文件被系统清理、路径失效）时自愈。
  ///
  /// 关键点是「失效路径不能继续被信任」：静态路径缓存命中后不会再去问
  /// Rust，一旦文件没了，封面就会一直停在占位图上直到进程重启。
  void _healLocalCoverOnDecodeError(ImageProvider provider) {
    _cacheDrop(_cacheKey);
    unawaited(provider.evict());
    if (_decodeHealCount >= 2) return;
    _decodeHealCount++;
    // errorBuilder 处在 build 阶段，这里必须延后一拍再 setState 重载。
    Future<void>.microtask(() {
      if (!mounted) return;
      if (normalizeCoverImageUrl(widget.imageUrl).isNotEmpty) return;
      _loadFailures = 0;
      setState(() => _path = null);
      unawaited(_load(force: true));
    });
  }

  /// 回到前台时自愈：本地封面若只剩占位（之前提取失败）或缓存路径指向
  /// 的文件已经不在，重新向 Rust 提取一次。
  ///
  /// 后台期间系统可能清理缓存目录、SD 卡/SAF 也可能短暂不可读，这些都
  /// 只在「回到前台」这一刻才具备条件恢复。
  void _healLocalCoverOnResume() {
    if (!mounted) return;
    if (normalizeCoverImageUrl(widget.imageUrl).isNotEmpty) return;
    final path = _path;
    final pathMissing = path != null && !File(path).existsSync();
    if (!_noImage && !pathMissing) return;
    if (pathMissing) _cacheDrop(_cacheKey);
    final last = _lastResumeHealAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 10)) {
      return;
    }
    _lastResumeHealAt = DateTime.now();
    _loadFailures = 0;
    unawaited(_load(force: true));
  }

  /// 网络封面优先走磁盘缓存：命中后是纯本地文件解码，冷启动也不用重新
  /// 走网络请求。这是「歌单封面加载慢」最直接的解法——原先每次
  /// `ImageCache.clear()`（退后台、系统内存压力）都会让所有在线封面
  /// 重新走一遍 HTTP。
  Future<void> _loadNetwork() async {
    final imageUrl = normalizeCoverImageUrl(widget.imageUrl);
    if (imageUrl.isEmpty) return;
    if (imageUrl.startsWith('file://')) return;
    if (_netResolvingUrl == imageUrl) return;
    _netResolvingUrl = imageUrl;

    final hit = CoverDiskCache.peek(imageUrl);
    if (hit != null) {
      if (mounted && imageUrl == normalizeCoverImageUrl(widget.imageUrl)) {
        setState(() {
          _netPath = hit;
          _noImage = false;
        });
      }
      return;
    }

    try {
      final resolvedRoot =
          _cacheRoot ?? await ref.read(appDataDirProvider.future);
      if (resolvedRoot == null || resolvedRoot.isEmpty) return;
      final cacheRoot = resolvedRoot;
      _cacheRoot = cacheRoot;
      final path = await CoverDiskCache.resolve(
        imageUrl,
        headers: coverImageNetworkHeaders(imageUrl),
        cacheRoot: cacheRoot,
      );
      if (!mounted || imageUrl != normalizeCoverImageUrl(widget.imageUrl)) {
        return;
      }
      if (path == null) {
        // 网易云 CDN 直连 403 时与电脑端一致改走 Rust 图片代理。
        if (needsCoverImageProxy(imageUrl)) {
          unawaited(_loadProxiedImage(imageUrl));
        } else {
          // 在线封面确认拿不到：再试一次本地内嵌封面，两边都没有才
          // 显示占位图（原先直接置占位，本地歌曲回前台网络封面失效后
          // 就永久停在默认封面上了）。
          await _loadLocalFallback();
        }
        return;
      }
      setState(() {
        _netPath = path;
        _noImage = false;
      });
    } catch (_) {
      if (!mounted || imageUrl != normalizeCoverImageUrl(widget.imageUrl)) {
        return;
      }
      await _loadLocalFallback();
    }
  }

  String get _cacheKey =>
      '${widget.highQuality ? 'full' : 'thumb'}:${widget.songPath}';

  static String? _cacheGet(String key) {
    final value = _cache.remove(key);
    if (value == null) return null;
    if (value.isEmpty) {
      final at = _emptyCachedAt[key];
      // 短期内的空结果照旧命中，避免同一帧里反复向 Rust 排队提取；
      // 超过冷却时间就丢弃重试，让瞬时失败过的封面能自己长回来。
      if (at != null &&
          DateTime.now().difference(at) < _emptyCoverRetryAfter) {
        _cache[key] = value;
        return value;
      }
      _emptyCachedAt.remove(key);
      return null;
    }
    // 缓存路径必须校验文件仍在：封面缓存文件被系统清理/淘汰后，旧路径
    // 解码必然失败，如果继续信任它，封面就永久停在占位图上（只有重启
    // 进程才会重新向 Rust 提取）。
    if (!File(value).existsSync()) {
      _emptyCachedAt.remove(key);
      return null;
    }
    _cache[key] = value;
    return value;
  }

  static void _cachePut(String key, String value) {
    _cache.remove(key);
    _cache[key] = value;
    if (value.isEmpty) {
      _emptyCachedAt[key] = DateTime.now();
    } else {
      _emptyCachedAt.remove(key);
    }
    while (_cache.length > _pathCacheLimit) {
      final evicted = _cache.keys.first;
      _cache.remove(evicted);
      _emptyCachedAt.remove(evicted);
    }
  }

  /// 丢弃某首歌的本地封面缓存（文件失效/提取失败时用），下次读取会
  /// 重新向 Rust 请求。
  static void _cacheDrop(String key) {
    _cache.remove(key);
    _emptyCachedAt.remove(key);
  }

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
          _putProxyCache(imageUrl, decoded);
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
      // 代理也没拿到图：最后再回落一次本地内嵌封面，别直接停在占位图。
      if (bytes == null) unawaited(_loadLocalFallback());
    } catch (_) {
      if (mounted && imageUrl == normalizeCoverImageUrl(widget.imageUrl)) {
        setState(() {
          _proxyLoading = false;
          _proxyFailed = true;
        });
        unawaited(_loadLocalFallback());
      }
    }
  }

  /// 解码宽度：显式传入优先；否则按「显示宽 × 设备像素比」推导，
  /// 非高清场景向上取到固定槽位，高清场景取精确值（封顶 2048）。
  int? get _decodeWidth {
    final forced = widget.cacheWidth;
    if (forced != null) return forced.clamp(1, 2048);
    final logical = widget.width;
    if (!logical.isFinite || logical <= 0) return null;
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 3.0;
    final raw = (logical * dpr).round();
    if (raw <= 0) return null;
    if (widget.highQuality) return raw.clamp(1, 2048);
    for (final slot in _decodeSlots) {
      if (raw <= slot) return slot;
    }
    return _decodeSlots.last;
  }

  static ImageProvider _fileProvider(File file, int? cacheWidth) =>
      ResizeImage.resizeIfNeeded(cacheWidth, null, FileImage(file));

  static ImageProvider _memoryProvider(Uint8List bytes, int? cacheWidth) =>
      ResizeImage.resizeIfNeeded(cacheWidth, null, MemoryImage(bytes));

  @override
  Widget build(BuildContext context) {
    final path = _path;
    final imageUrl = normalizeCoverImageUrl(widget.imageUrl);
    final decodeWidth = _decodeWidth;
    final netPath = _netPath;
    final proxyBytes = _proxyBytes;
    final placeholder = _placeholder();
    // `file://` 前缀 = 本地自定义图片（如歌单封面编辑保存的文件），
    // 直接走文件解码，绝不走网络。
    final localFileUri = imageUrl.startsWith('file://')
        ? Uri.tryParse(imageUrl)
        : null;

    // 垫底画面：上一曲（或跨实例最近）已真正画过的封面优先，其次才是
    // 占位图。新图首帧到达前显示它、到达后与它交叉淡入，因此切歌/进
    // 详情页都不会出现「占位图一闪」。
    final retained = _retainedProvider;
    final Widget base = retained != null && !_noImage
        ? Image(
            image: retained,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
            // 垫底图若未在 ImageCache 中（极端情况：刚被系统清理），宁可
            // 显示占位图也不要留一帧透明——透明会透出页面底色（浅色主题
            // 即纯白），依旧是一次闪白。
            frameBuilder: (_, child, frame, _) =>
                frame == null ? placeholder : child,
            errorBuilder: (_, _, _) => placeholder,
          )
        : placeholder;
    final frameBuilder = CoverFadeIn.frameBuilder(placeholder: base);

    ImageProvider? provider;
    Widget? content;
    if (netPath != null) {
      provider = _fileProvider(File(netPath), decodeWidth);
      content = Image(
        image: provider,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        frameBuilder: frameBuilder,
        errorBuilder: (_, _, _) {
          // 缓存文件被系统清理：踢掉索引，回落到占位并允许重新下载。
          CoverDiskCache.forget(imageUrl);
          return placeholder;
        },
      );
    } else if (proxyBytes != null) {
      provider = _memoryProvider(proxyBytes, decodeWidth);
      content = Image(
        image: provider,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        frameBuilder: frameBuilder,
        errorBuilder: (_, _, _) => placeholder,
      );
    } else if (localFileUri != null) {
      provider = _fileProvider(File.fromUri(localFileUri), decodeWidth);
      content = Image(
        image: provider,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        frameBuilder: frameBuilder,
        errorBuilder: (_, _, _) => placeholder,
      );
    } else if (path != null) {
      final localProvider = _fileProvider(File(path), decodeWidth);
      provider = localProvider;
      content = Image(
        image: localProvider,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        frameBuilder: frameBuilder,
        errorBuilder: (_, _, _) {
          // 缓存文件被清理/路径失效：丢掉失效路径并重新提取，而不是
          // 永久停在占位图上。
          _healLocalCoverOnDecodeError(localProvider);
          return placeholder;
        },
      );
    }

    if (provider != null) {
      // 记录本实例/跨实例可复用的真实封面，供下一次切歌或新页面垫底。
      _lastRenderedProvider = provider;
      _recentPut(_identityKey, provider);
    } else {
      _lastRenderedProvider = null;
      // 还没有任何画面：确定无图时用占位图，否则先垫上一张可复用画面。
      content = _noImage ? placeholder : base;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: content,
      ),
    );
  }

  Widget _placeholder() {
    final custom = widget.placeholder;
    if (custom != null) return custom;
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

/// 复现 [CoverImage] 的解码宽度决策（槽位规则），供预加载侧构造与组件
/// 完全一致的 ImageProvider key。
///
/// ImageCache 的 key 是 provider 的相等性，`ResizeImage(cacheWidth: 96)`
/// 与 `ResizeImage(cacheWidth: 128)` 是两份缓存。预加载若用自己估的尺寸
/// 解码，组件首次 build 时 key 对不上，等于把同一张图解码两遍，预热完全
/// 白做——所以这里必须与 `CoverImage._decodeWidth` 保持同一套算法。
int? coverDecodeWidthFor(
  double logicalWidth, {
  int? cacheWidth,
  bool highQuality = false,
  required double devicePixelRatio,
}) {
  final forced = cacheWidth;
  if (forced != null) return forced.clamp(1, 2048);
  if (!logicalWidth.isFinite || logicalWidth <= 0) return null;
  final raw = (logicalWidth * devicePixelRatio).round();
  if (raw <= 0) return null;
  if (highQuality) return raw.clamp(1, 2048);
  for (final slot in _CoverImageState._decodeSlots) {
    if (raw <= slot) return slot;
  }
  return _CoverImageState._decodeSlots.last;
}

/// 与 [CoverImage] 内部完全一致的本地文件 provider（预加载与组件共用同
/// 一个 ImageCache key，预热过的图在组件首帧同步命中，无占位帧）。
ImageProvider coverFileImageProvider(String path, int? decodeWidth) =>
    _CoverImageState._fileProvider(File(path), decodeWidth);

/// 预热必须走 Rust 图片代理的封面/头像（网易云 CDN 直连 403）。
///
/// 与 [CoverImage] 的 `_loadProxiedImage` 共用同一份跨实例代理字节缓存与
/// 并发请求表：预热写进去之后，组件首次 build 能在同步路径上直接取到
/// 字节与同一个 [MemoryImage]（相等性按字节对象身份），既不重复请求也不
/// 重复解码。返回 null 表示代理没拿到图。
Future<ImageProvider?> coverPrewarmProxiedImage(
  String imageUrl, {
  int? decodeWidth,
}) async {
  final url = normalizeCoverImageUrl(imageUrl);
  if (url.isEmpty) return null;
  final cached = _CoverImageState._proxyCache[url];
  if (cached != null) {
    // 命中即刷新 LRU 位置：_putProxyCache 内部会扣掉旧条目字节再重登记，
    // 这里不能先手动 remove（会让字节计数重复累加）。
    _CoverImageState._putProxyCache(url, cached);
    return ResizeImage.resizeIfNeeded(decodeWidth, null, MemoryImage(cached));
  }
  try {
    final bytes = await _CoverImageState._proxyTasks.putIfAbsent(url, () async {
      try {
        final dataUrl = await proxyImage(
          url: url,
          referer: 'https://music.163.com/',
        );
        final comma = dataUrl.indexOf(',');
        if (comma <= 0 || !dataUrl.substring(0, comma).contains(';base64')) {
          return null;
        }
        final decoded = base64Decode(dataUrl.substring(comma + 1));
        if (decoded.isEmpty) return null;
        _CoverImageState._putProxyCache(url, decoded);
        return decoded;
      } finally {
        _CoverImageState._proxyTasks.remove(url);
      }
    });
    if (bytes == null) return null;
    return ResizeImage.resizeIfNeeded(decodeWidth, null, MemoryImage(bytes));
  } catch (_) {
    return null;
  }
}

/// 网易云 CDN 在部分 Android ROM/运营商网络下直连会 403，
/// 与电脑端一致通过 Rust 图片代理加载。
bool needsCoverImageProxy(String imageUrl) {
  final host = Uri.tryParse(imageUrl)?.host.toLowerCase() ?? '';
  return host == 'music.126.net' || host.endsWith('.music.126.net');
}

/// 兼容旧插件和旧播放会话保存的 HTTP / 协议省略封面地址。
/// 主流音乐图床均已支持 HTTPS，http:// 封面统一升级；唯一例外是酷我
/// 图片 CDN（kwcdn.kuwo.cn）：该域不提供可信 HTTPS（TLS 握手直接失败，
/// 官方端也走明文 http 下发），必须保持明文——app 网络安全配置已全局
/// 放行明文流量，可正常加载。此前无差别升级导致酷我来源封面全部显示
/// 占位（接口层 URL 正常、加载层必挂）。与 plugin_runtime 侧归一化
/// 保持同一份放行名单。
String normalizeCoverImageUrl(String? imageUrl) {
  var normalized = imageUrl?.trim() ?? '';
  if (normalized.startsWith('//')) normalized = 'https:$normalized';
  final uri = Uri.tryParse(normalized);
  final host = uri?.host.toLowerCase() ?? '';
  final isLocalHost =
      host == 'localhost' || host == '127.0.0.1' || host == '[::1]';
  const keepPlainHttpHosts = ['kwcdn.kuwo.cn'];
  final keepPlain = keepPlainHttpHosts.any((suffix) => host.endsWith(suffix));
  if (normalized.startsWith('http://') && !isLocalHost && !keepPlain) {
    normalized = 'https://${normalized.substring(7)}';
  }
  return _applyNeteaseCoverScale(_stripBilibiliImageTransform(normalized));
}

/// Bilibili 图床（hdslb.com/biliimg.com）的 /bfs/ 路径常带
/// `@320w_180h_1c.avif` 缩放后缀，AVIF 格式 Flutter 解码器不支持，
/// 会显示占位图；剥离后缀还原成原图（与 plugin_runtime 侧同款逻辑，
/// 双层兜底：旧收藏/歌单数据里已持久化的地址也会在渲染时被还原）。
String _stripBilibiliImageTransform(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return url;
  final host = uri.host.toLowerCase();
  final isBiliCdn =
      host == 'hdslb.com' ||
      host.endsWith('.hdslb.com') ||
      host == 'biliimg.com' ||
      host.endsWith('.biliimg.com');
  if (!isBiliCdn) return url;
  final path = uri.path;
  if (!path.contains('/bfs/')) return url;
  final atIndex = path.lastIndexOf('@');
  if (atIndex <= 0) return url;
  if (path.substring(atIndex + 1).contains('/')) return url;
  return uri.replace(path: path.substring(0, atIndex)).toString();
}

/// 网易云 CDN 的 picUrl 指向原始尺寸图片，部分专辑（如「一生一世 影视
/// 原声带」）原图高达 7MB+：直连加载缓慢，且 Rust 图片代理有 5MB 上限
/// 会直接拒绝，表现为封面永远不显示。统一追加官方缩放参数。
String _applyNeteaseCoverScale(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  final host = uri.host.toLowerCase();
  if (host != 'music.126.net' && !host.endsWith('.music.126.net')) {
    return url;
  }
  final query = uri.queryParameters;
  if (query.containsKey('param')) return url;
  final merged = <String, String>{...query, 'param': '800y800'};
  return uri.replace(queryParameters: merged).toString();
}
