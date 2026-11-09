import 'dart:collection';

import 'plugin_runtime.dart';

/// 歌手头像解析器：按歌手名获取歌手头像，并负责缓存与并发合并。
///
/// 万象等聚合插件的歌曲条目只带歌手名，歌手搜索接口（
/// `action=search&type=artist`）才返回 `avatar` 字段；洛雪（LX）音源
/// 没有头像字段，由 [resolveArtistAvatar] 内部改用公开歌手搜索兜底。
///
/// - 按「插件 ID + 歌手名」缓存，切歌/重复打开信息面板不重复打接口；
/// - 同一歌手的并发请求合并成一个；
/// - 任何异常静默返回空串或保留原值，由调用方回退占位。
class ArtistAvatarResolver {
  ArtistAvatarResolver({required this.fetchAvatar});

  /// 按插件 ID、歌手名获取头像；异常由本类吞掉。
  final Future<String> Function(String pluginId, String artistName) fetchAvatar;

  /// 命中结果（含空结果）缓存；空结果也缓存，避免同名歌手反复搜索。
  final LinkedHashMap<String, String> _cache = LinkedHashMap();
  final Map<String, Future<String>> _inflight = {};
  static const int _cacheLimit = 300;

  Future<String> resolve(String pluginId, String artistName) {
    final name = artistName.trim();
    if (pluginId.isEmpty || name.isEmpty) return Future.value('');
    final key = '$pluginId\u0001$name';
    final hit = _cache.remove(key);
    if (hit != null) {
      // 重新插入到尾部，维持 LRU 顺序。
      _cache[key] = hit;
      return Future.value(hit);
    }
    return _inflight.putIfAbsent(key, () async {
      try {
        final avatar = (await fetchAvatar(pluginId, name)).trim();
        _putCache(key, avatar);
        return avatar;
      } catch (_) {
        // 接口不可用/无密钥/网络失败：静默回退占位，不缓存失败结果，
        // 后续仍可重试。
        return '';
      } finally {
        _inflight.remove(key);
      }
    });
  }

  void _putCache(String key, String value) {
    _cache.remove(key);
    _cache[key] = value;
    while (_cache.length > _cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
  }
}

/// 按歌手名解析头像：LX 源走公开搜索兜底，其余源走插件自己的歌手搜索
/// 并只取同名结果。任何失败都返回空串（界面回退占位）。
Future<String> resolveArtistAvatar({
  required bool isLx,
  required String artistName,
  required Future<List<PluginCatalogResult>> Function() searchPluginArtists,
  required Future<String> Function() resolvePublicAvatar,
}) async {
  final name = artistName.trim();
  if (name.isEmpty) return '';
  try {
    if (isLx) return (await resolvePublicAvatar()).trim();
    return pickSameNameArtistAvatar(await searchPluginArtists(), name);
  } catch (_) {
    return '';
  }
}

/// 从插件歌手搜索结果中挑同名歌手的头像。
///
/// 先精确匹配归一化后的名字，再在唯一包含候选时放宽（部分平台会在歌手
/// 名后附加别名/英文名）。候选多于一个时宁可不显示，避免错配头像。
String pickSameNameArtistAvatar(
  List<PluginCatalogResult> results,
  String artistName,
) {
  final target = _normalizeArtistName(artistName);
  if (target.isEmpty) return '';
  final candidates = <String>[];
  for (final item in results) {
    if (item.coverUrl.isEmpty) continue;
    final title = _normalizeArtistName(item.title);
    if (title.isEmpty) continue;
    if (title == target) return item.coverUrl;
    if (title.contains(target) || target.contains(title)) {
      candidates.add(item.coverUrl);
    }
  }
  return candidates.length == 1 ? candidates.single : '';
}

/// 需要补查头像的歌手名（按输入顺序去重）。
///
/// 规则：只补缺，不覆盖——平台已带头像的歌手绝不进入补查队列。
List<String> missingArtistAvatarNames(
  Iterable<({String name, String avatar})> artists,
) {
  final names = <String>[];
  for (final artist in artists) {
    final name = artist.name.trim();
    if (name.isEmpty || artist.avatar.trim().isNotEmpty) continue;
    if (!names.contains(name)) names.add(name);
  }
  return names;
}

/// 展示用头像：平台头像优先；平台缺失时才采用补查结果；都为空返回空串
/// （由界面回退人形占位）。补查结果永远不会覆盖平台头像。
String effectiveArtistAvatar(String platformAvatar, String? resolvedAvatar) {
  final platform = platformAvatar.trim();
  if (platform.isNotEmpty) return platform;
  return (resolvedAvatar ?? '').trim();
}

/// 打开歌曲信息面板时执行：仅为缺头像的歌手补查，平台已带头像的条目
/// 不会触发任何请求，也不会被补查结果覆盖。
Future<Map<String, String>> resolveMissingArtistAvatars(
  Iterable<({String name, String avatar})> artists,
  Future<String> Function(String artistName) resolve,
) async {
  final missing = missingArtistAvatarNames(artists);
  if (missing.isEmpty) return const {};
  final avatars = await Future.wait([
    for (final name in missing) resolve(name),
  ]);
  return {
    for (var i = 0; i < missing.length; i++) missing[i]: avatars[i].trim(),
  };
}

/// 归一化歌手名：忽略大小写、空白与常见分隔/标点，只保留文字与数字。
String _normalizeArtistName(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fa5]+'), '');
