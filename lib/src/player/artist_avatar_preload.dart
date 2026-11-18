import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../plugins/artist_avatar_resolver.dart';
import '../plugins/plugin_runtime.dart';
import '../widgets/cover_disk_cache.dart';
import '../widgets/cover_image.dart';
import 'player_provider.dart';

/// 歌曲信息面板的作者条目：平台原始歌手对象 + 提取后的展示字段。
class SongArtistInfo {
  const SongArtistInfo({
    required this.name,
    required this.artistId,
    required this.artistMid,
    required this.raw,
    this.avatar = '',
  });

  final String name;
  final String artistId;
  final String artistMid;

  /// 平台头像地址；部分平台（如 QQ/网易歌手条目）不提供，为空时回退占位图标。
  final String avatar;

  /// 平台原始歌手 map（含 name/id/mid 等），作为 getArtistWorks 的
  /// rawData 直传插件。
  final Map<String, dynamic> raw;
}

String firstTextOf(Map<dynamic, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is num) return value.toString();
  }
  return '';
}

/// 从歌手对象提取头像地址。兼容字符串与 `{url: ...}` / `{urlTemplate: ...}`
/// 形式的嵌套值；顶层找不到时再查 user_info/author_info/user 等嵌套对象
/// （汽水等平台的歌手信息包裹在 user_info 里）。
String _artistAvatarOf(Map<String, dynamic> map) {
  const keys = [
    'avatar',
    'avatarUrl',
    'avatar_url',
    'avatarImgUrlStr',
    'headImg',
    'headPic',
    'headUrl',
    'head_url',
    'singerPic',
    'singerImg',
    'artistPic',
    'artistImg',
    'pic',
    'picUrl',
    'pic_url',
    'img',
    'imgUrl',
    'img_url',
    'img1v1Url',
    'img1v1',
    'image',
    'photo',
    'upic',
    'face',
    'userFace',
    'user_face',
    'cover',
    'coverUrl',
    'cover_url',
  ];
  String readFrom(Map<dynamic, dynamic> source) {
    for (final key in keys) {
      final value = source[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is Map) {
        final nested = value['url'] ?? value['urlTemplate'] ?? value['src'];
        if (nested is String && nested.trim().isNotEmpty) {
          return nested.trim();
        }
      }
    }
    return '';
  }

  final direct = readFrom(map);
  if (direct.isNotEmpty) return direct;
  for (final nestedKey in const [
    'user_info',
    'author_info',
    'user',
    'artist',
  ]) {
    final nested = map[nestedKey];
    if (nested is Map) {
      final found = readFrom(nested);
      if (found.isNotEmpty) return found;
    }
  }
  return '';
}

/// 是否为 QQ 音乐曲目：封面/artwork 指向 y.gtimg.cn（其他平台不会命中）。
bool _isQqSong(QueueItem item) {
  final data = item.pluginData;
  final urls = <String?>[
    item.coverUrl,
    data?['artwork']?.toString(),
    data?['cover']?.toString(),
    data?['coverUrl']?.toString(),
  ];
  return urls.any((url) => (url ?? '').contains('gtimg.cn'));
}

/// QQ 音乐歌手头像约定地址（与桌面端 LxMusicSdk、Rust lx_search 一致）：
/// 歌手条目只带 mid，无头像字段，需按 T001 规则拼接。
String _qqSingerAvatarUrl(String mid) => mid.isEmpty
    ? ''
    : 'https://y.gtimg.cn/music/photo_new/T001R500x500M000$mid.jpg';

/// 从歌曲插件数据提取作者列表：优先归一化后的 singerList（QQ/汽水/
/// 网易等），兼容 artists/singers/singer/ar 等原始字段；都没有时按
/// item.artist 文本按常见分隔符拆分（无 ID，仅展示）。
List<SongArtistInfo> songArtistsOf(QueueItem item) {
  final data = item.pluginData;
  List<dynamic> entries = const [];
  if (data != null) {
    final list =
        data['singerList'] ??
        data['singers'] ??
        data['artists'] ??
        data['artistList'];
    if (list is List) {
      entries = list;
    } else {
      final single = data['singer'] ?? data['ar'] ?? data['author_info'];
      if (single is List) {
        entries = single;
      } else if (single is Map) {
        entries = [single];
      }
    }
  }
  final artists = <SongArtistInfo>[];
  // QQ 歌手条目无头像字段，按 mid 拼 T001 头像地址兜底。
  final qqSong = _isQqSong(item);
  for (final entry in entries) {
    if (entry is Map) {
      final map = Map<String, dynamic>.from(entry);
      final name = firstTextOf(map, const [
        'name',
        'title',
        'artist',
        'singer',
        'author',
      ]);
      final id = firstTextOf(map, const [
        'id',
        'artistId',
        'artist_id',
        'singerId',
      ]);
      final mid = firstTextOf(map, const [
        'mid',
        'artistMid',
        'artist_mid',
        'singerMid',
      ]);
      if (name.isNotEmpty || id.isNotEmpty) {
        final avatar = _artistAvatarOf(map);
        artists.add(
          SongArtistInfo(
            name: name,
            artistId: id,
            artistMid: mid,
            avatar: avatar.isNotEmpty
                ? avatar
                : (qqSong ? _qqSingerAvatarUrl(mid) : ''),
            raw: map,
          ),
        );
      }
    } else if (entry is String && entry.trim().isNotEmpty) {
      artists.add(
        SongArtistInfo(
          name: entry.trim(),
          artistId: '',
          artistMid: '',
          raw: {'name': entry.trim()},
        ),
      );
    }
  }
  if (artists.isEmpty && item.artist.trim().isNotEmpty) {
    for (final name in item.artist.split(RegExp(r'[/、,，&]'))) {
      final trimmed = name.trim();
      if (trimmed.isNotEmpty) {
        artists.add(
          SongArtistInfo(
            name: trimmed,
            artistId: '',
            artistMid: '',
            raw: {'name': trimmed},
          ),
        );
      }
    }
  }
  return artists;
}

/// 全局歌手头像解析器：预取与面板内兜底共用（LRU 缓存 + 并发合并），
/// 同名歌手不重复打插件歌手搜索接口。
final artistAvatarResolverProvider = Provider<ArtistAvatarResolver>((ref) {
  return ArtistAvatarResolver(
    fetchAvatar: (pluginId, artistName) async {
      final plugins = await ref.read(enabledMusicPluginsProvider.future);
      EnabledMusicPlugin? plugin;
      for (final candidate in plugins) {
        if (candidate.id == pluginId) {
          plugin = candidate;
          break;
        }
      }
      if (plugin == null) return '';
      // 闭包捕获会丢失可变局部的空安全提升，先落到 final 局部。
      final matched = plugin;
      final runtime = ref.read(pluginRuntimeProvider);
      return resolveArtistAvatar(
        isLx: matched.isLx,
        artistName: artistName,
        searchPluginArtists: () => runtime.searchArtists(matched, artistName),
        resolvePublicAvatar: () =>
            runtime.resolveArtistAvatarByName(artistName),
      );
    },
  );
});

/// 正在播放歌曲的作者头像预取结果：曲目路径 + 歌手名 → 头像 URL。
///
/// 【为什么要放在 provider 层】预取此前挂在播放页 build 里：播放页没有
/// 被打开过就永远不会执行，「点进歌曲信息才开始加载」照旧。上移到全局
/// 后跟播放切换走——切歌即开始解析头像 URL 并落封面磁盘缓存，与播放页
/// 是否挂载无关；播放页只负责最后一环（预解码进 ImageCache）。
final currentArtistAvatarsProvider = NotifierProvider<
  _ArtistAvatarPreloadNotifier,
  ({String path, Map<String, String> avatars})
>(_ArtistAvatarPreloadNotifier.new);

class _ArtistAvatarPreloadNotifier
    extends Notifier<({String path, Map<String, String> avatars})> {
  /// 世代号：切歌（build 重跑）后旧一代的异步结果全部作废，避免慢请求
  /// 把上一首歌的头像写进当前结果。
  int _generation = 0;

  @override
  ({String path, Map<String, String> avatars}) build() {
    final current = ref.watch(playerProvider.select((s) => s.current));
    final path = current?.path ?? '';
    _generation++;
    if (current != null) {
      final generation = _generation;
      unawaited(_runPreload(current, generation));
    }
    return (path: path, avatars: const {});
  }

  Future<void> _runPreload(QueueItem item, int generation) async {
    final artists = songArtistsOf(item);
    if (artists.isEmpty) return;
    final resolver = ref.read(artistAvatarResolverProvider);
    final urls = <String>{};
    final avatars = <String, String>{};
    String? pluginId;
    for (final artist in artists) {
      final platformAvatar = artist.avatar.trim();
      if (platformAvatar.isNotEmpty) {
        // 平台条目自带头像：不需要补查，但图片本身仍要预热。
        urls.add(platformAvatar);
        continue;
      }
      if (artist.name.trim().isEmpty) continue;
      pluginId ??= await _resolvePluginId(item);
      if (generation != _generation) return;
      if (pluginId == null || pluginId.isEmpty) continue;
      final resolved = await resolver.resolve(pluginId, artist.name);
      if (generation != _generation) return;
      if (resolved.isEmpty) continue;
      avatars[artist.name] = resolved;
      urls.add(resolved);
    }
    if (generation != _generation) return;
    // 先把 URL 结果写进 state（面板/播放页可立即取 URL），磁盘与代理
    // 预热随后进行——CoverDiskCache 内部单飞，页面的预解码与其并发合并。
    state = (path: item.path, avatars: Map<String, String>.from(avatars));
    if (urls.isEmpty) return;
    await _warmImages(urls, generation);
  }

  Future<String?> _resolvePluginId(QueueItem item) async {
    final plugins = await ref.read(enabledMusicPluginsProvider.future);
    return recognizedPluginIdForDisplay(item, plugins);
  }

  /// 头像图片落盘预热：先落封面磁盘缓存（与 CoverImage 同一份索引与
  /// 请求头），网易云 CDN 403 的再走 Rust 代理链路把字节写进共享代理
  /// 缓存。预解码（precacheImage）需要 BuildContext，由播放页补齐。
  Future<void> _warmImages(Set<String> urls, int generation) async {
    final cacheRoot = await ref.read(appDataDirProvider.future);
    if (generation != _generation) return;
    final decodeWidth = coverDecodeWidthFor(
      38,
      devicePixelRatio: _devicePixelRatio(),
    );
    for (final raw in urls) {
      final url = normalizeCoverImageUrl(raw);
      if (url.isEmpty) continue;
      await CoverDiskCache.resolve(
        url,
        headers: coverImageNetworkHeaders(url),
        cacheRoot: cacheRoot,
      );
      if (generation != _generation) return;
      if (needsCoverImageProxy(url)) {
        try {
          await coverPrewarmProxiedImage(url, decodeWidth: decodeWidth);
        } catch (_) {
          // 预热失败无副作用：面板仍可自行加载并回退占位。
        }
        if (generation != _generation) return;
      }
    }
  }

  /// 面板头像为 38dp 圆形；provider 层拿不到 MediaQuery，直接读视图的
  /// devicePixelRatio（与页面实际值一致），异常时取常见 3.0。
  double _devicePixelRatio() {
    try {
      final views = PlatformDispatcher.instance.views;
      if (views.isNotEmpty) return views.first.devicePixelRatio;
    } catch (_) {}
    return 3.0;
  }
}
