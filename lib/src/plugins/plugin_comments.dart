// 歌曲评论服务。
//
// 数据来源两级（对齐桌面端 CommentPanel / XianYu-Music-Mobile 实现）：
// 1. MusicFree 插件的 getMusicComments(musicItem, page)——部分插件自带；
// 2. 平台直连公开评论接口兜底（wy/tx/kg/kw/mg/qishui）。
// LX（落雪）自定义源协议只提供 musicUrl/lyric/pic，脚本不实现评论，
// 因此 LX 歌曲同样按歌曲平台走直连；直连所需的平台专有 id 由
// _commentMusicInfo 从 LX 音乐信息里映射（wy/kw 的 id 存在 songmid）。
//
// 约定：返回 null 表示当前歌曲无法取得评论（平台不受支持或缺少歌曲
// id），调用方据此展示「不支持」；网络/上游故障抛
// _CommentNetworkException，调用方展示可重试的错误态。
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'plugin_runtime.dart';

const _pageSize = 20;

/// 评论条目（对齐桌面端 normalizeComment 规范化）。
class CommentItem {
  const CommentItem({
    required this.id,
    required this.nickName,
    this.avatar,
    required this.comment,
    this.like,
    this.createAt,
    this.location,
    this.replies = const [],
  });

  final String id;
  final String nickName;
  final String? avatar;
  final String comment;
  final int? like;
  final int? createAt;
  final String? location;
  final List<CommentItem> replies;

  static CommentItem normalize(dynamic raw) {
    if (raw is! Map) return const CommentItem(id: '', nickName: '', comment: '');
    final m = raw.cast<String, dynamic>();
    int? like;
    final likeRaw = m['like'] ?? m['likeCount'] ?? m['likes'] ?? m['like_count'];
    if (likeRaw is num) like = likeRaw.toInt();
    int? createAt;
    final timeRaw = m['createAt'] ?? m['createdAt'] ?? m['timestamp'] ?? m['time'];
    if (timeRaw is num) createAt = timeRaw.toInt();

    // 兼容多种二级评论字段名（与桌面端一致）。
    List<CommentItem> replies = const [];
    for (final field in [
      'replies',
      'replyList',
      'subComments',
      'children',
      'replys',
      'sub_comment',
      'reply_list',
    ]) {
      final v = m[field];
      if (v is List && v.isNotEmpty) {
        replies = v.map(CommentItem.normalize).toList();
        break;
      }
    }

    return CommentItem(
      id: (m['id'] ?? m['commentId'] ?? m['comment_id'] ?? '').toString(),
      nickName: ((m['nickName'] ?? m['nickname'] ?? m['userName'] ?? m['name'])
              as String?) ??
          '',
      avatar: (m['avatar'] ?? m['userAvatar'] ?? m['headPic']) as String?,
      comment: ((m['comment'] ?? m['content'] ?? m['text']) as String?) ?? '',
      like: like,
      createAt: createAt,
      location: (m['location'] ?? m['address']) as String?,
      replies: replies,
    );
  }
}

/// 评论分页结果。
class CommentPage {
  const CommentPage({required this.items, required this.isEnd});
  final List<CommentItem> items;
  final bool isEnd;
}

/// 拉取一页评论。
///
/// pluginData 为播放队列项携带的插件数据：LX 歌曲是 {'lx': songInfo}，
/// MusicFree 歌曲是原始条目 rawData。返回 null 表示无法取得评论。
Future<CommentPage?> fetchSongComments({
  required EnabledMusicPlugin plugin,
  required Map<String, dynamic> pluginData,
  required PluginRuntimeService runtime,
  int page = 1,
}) async {
  final lxInfo = pluginData['lx'];
  final isLx = plugin.isLx || lxInfo is Map;
  final musicItem = lxInfo is Map
      ? _commentMusicInfo(lxInfo)
      : _normalizeMusicItem(plugin, pluginData);

  // MusicFree 插件优先：插件明确返回（即便为空）即不再走兜底。
  if (!isLx) {
    try {
      final result = await runtime
          .getMusicComments(plugin, musicItem, page)
          .timeout(const Duration(seconds: 15));
      final parsed = _parsePluginResult(result);
      if (parsed != null &&
          (parsed.items.isNotEmpty || parsed.isEnd)) {
        return parsed;
      }
    } catch (_) {
      // 插件未声明 getMusicComments 或调用失败 → 落到平台直连。
    }
  }

  final platform = detectCommentPlatform(
    pluginName: plugin.name,
    musicInfo: musicItem,
  );
  if (platform == null) {
    // 平台识别失败（聚合音源常见）：惜梦 v2/v3 插件按后端地址兜底。
    return _fetchAnimemusicComments(
      plugin: plugin,
      pluginData: pluginData,
      lxInfo: lxInfo,
      runtime: runtime,
      page: page,
    );
  }
  Object? directError;
  try {
    final direct = await fetchPlatformComments(
      platform: platform,
      musicInfo: musicItem,
      page: page,
    );
    if (direct != null && direct.items.isNotEmpty) return direct;
    // 平台直连成功但空结果：惜梦系插件继续走后端兜底（baka 版无
    // getMusicComments，wy 等直连接口失效时返回空页面不抛异常，
    // animemusic 后端 music/comment 仍可能返回评论）；普通插件维持
    // 直连结果，避免把「暂无评论」误报成加载失败。
    if (plugin.animemusicApi.trim().isEmpty) return direct;
  } catch (error) {
    // 平台直连失败（接口失效/需签名/网络故障）：先记录，惜梦 v2/v3
    // 插件继续按后端地址兜底；兜底也失败时把错误抛给 UI 展示重试。
    directError = error;
  }
  final fallback = await _fetchAnimemusicComments(
    plugin: plugin,
    pluginData: pluginData,
    lxInfo: lxInfo,
    runtime: runtime,
    page: page,
  );
  if (fallback != null) return fallback;
  if (directError != null) throw directError;
  return null;
}

/// 惜梦聚合插件（v2 洛雪版 / v3 MusicFree 版）评论兜底：插件本体不含
/// 评论方法，由宿主直连 animemusic 后端 music/comment。LX 歌曲的 lx
/// 元数据包一层再交给 runtime，保持与 _animemusicSongRef 的解析约定。
Future<CommentPage?> _fetchAnimemusicComments({
  required EnabledMusicPlugin plugin,
  required Map<String, dynamic> pluginData,
  required dynamic lxInfo,
  required PluginRuntimeService runtime,
  required int page,
}) async {
  if (plugin.animemusicApi.trim().isEmpty) return null;
  try {
    final musicItem = lxInfo is Map
        ? <String, dynamic>{...pluginData, 'lx': Map<String, dynamic>.from(lxInfo)}
        : pluginData;
    final result = await runtime
        .getAnimemusicComments(plugin, musicItem, page)
        .timeout(const Duration(seconds: 15));
    final parsed = _parsePluginResult(result);
    if (parsed != null && (parsed.items.isNotEmpty || parsed.isEnd)) {
      return parsed;
    }
  } catch (_) {
    // 后端不可用或该平台暂无评论接口，返回 null 由 UI 提示。
  }
  return null;
}

/// 规范化传给插件的 musicItem：补充 platform 与常见字段别名
/// （与 XianYu 的 getMusicFreeUrl 透传逻辑同构）。
Map<String, dynamic> _normalizeMusicItem(
  EnabledMusicPlugin plugin,
  Map<String, dynamic> songInfo,
) {
  final musicItem = Map<String, dynamic>.from(songInfo);
  if (musicItem['platform'] == null) {
    musicItem['platform'] = plugin.name;
  }
  if (!musicItem.containsKey('id') &&
      (musicItem['id'] == null || musicItem['id'].toString().isEmpty) &&
      songInfo.containsKey('songmid')) {
    musicItem['id'] = songInfo['songmid'];
  }
  if (!musicItem.containsKey('songmid') && songInfo.containsKey('songmid')) {
    musicItem['songmid'] = songInfo['songmid'];
  }
  return musicItem;
}

/// LX 歌曲的评论元数据：LX 自定义源只提供 musicUrl，评论由宿主按平台
/// 直连，因此要把 LX 音乐信息里的平台专有 id 映射成评论接口要求的字段。
/// LX 搜索结果的 wy/kw 数字 id 统一放在 songmid，直连接口却读 id，
/// 不补齐会被误判为「不支持评论」。
Map<String, dynamic> _commentMusicInfo(Map<dynamic, dynamic> lxInfo) {
  final info = Map<String, dynamic>.from(lxInfo);
  final source = (info['source'] ?? '').toString();
  final songmid = _textOf(info['songmid']);
  if (source == 'wy' || source == 'kw') {
    // 网易云：评论按数字歌曲 id；酷我：评论按 rid。
    info['id'] ??= songmid;
    if (source == 'kw') info['rid'] ??= songmid;
  } else if (source == 'kg') {
    // 酷狗：评论要先按 hash 换 mixsongid，hash 缺失时用 songmid 兜底。
    info['hash'] ??= songmid;
  } else if (source == 'tx') {
    // QQ：评论优先用数字 songId，缺失时由 songmid（mid）换取。
    info['songId'] ??= songmid;
  } else if (source == 'qs') {
    // 汽水：评论接口按 group_id（= track id）取，LX 搜索结果的 track id
    // 存在 songmid 里，补齐到 id 供 _fetchQishui 读取。
    info['id'] ??= songmid;
    info['track_id'] ??= songmid;
  } else if (source == 'jo') {
    // JOOX：评论接口只认数字 songid 或 base64 歌曲 ID，Z 开头的 mid 不被
    // 接受。宿主搜索结果把数字 songid 放在 songId，songmid 存的是取流用
    // mid，因此必须优先取 songId，再回退 songmid（仅当它是数字时）。
    final numericId = _textOf(info['songId'] ?? info['song_id']) ??
        _textOf(info['songmid']);
    if (numericId != null) {
      info['id'] ??= numericId;
      info['songId'] ??= numericId;
    }
  }
  // 咪咕的评论 targetId 是 copyrightId，已在 LX 信息里，保持不变。
  return info;
}

String? _textOf(Object? value) {
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty ? null : text;
}

/// 部分平台接口把数字字段序列化成字符串（如酷我的 like_num/time），
/// 统一转换，避免 `as num?` 抛异常导致整页评论被丢弃。
int? _asInt(Object? value) {
  if (value is num) return value.toInt();
  if (value == null) return null;
  return int.tryParse(value.toString());
}

/// 评论链路网络/上游故障：让 UI 展示可重试的错误态，而不是误报「暂无评论」。
class _CommentNetworkException implements Exception {
  const _CommentNetworkException(this.message);
  final String message;

  @override
  String toString() => message;
}

CommentPage? _parsePluginResult(dynamic result) {
  if (result is List) {
    // 个别插件直接返回数组。
    final items = result.map(CommentItem.normalize).toList();
    return CommentPage(items: items, isEnd: items.isEmpty);
  }
  if (result is Map) {
    final m = result.cast<String, dynamic>();
    final raw = m['data'];
    final items =
        raw is List ? raw.map(CommentItem.normalize).toList() : <CommentItem>[];
    final isEnd = m['isEnd'] is bool
        ? m['isEnd'] as bool
        : (m['more'] is bool ? !(m['more'] as bool) : items.isEmpty);
    return CommentPage(items: items, isEnd: isEnd);
  }
  return null;
}

/// 识别歌曲所属评论平台（按 lx 源 key / 平台字段 / 插件名正则）。
String? detectCommentPlatform({
  String? pluginName,
  Map<String, dynamic>? musicInfo,
}) {
  if (musicInfo == null && (pluginName == null || pluginName.isEmpty)) {
    return null;
  }

  // LX 源 key 即平台码。qs（汽水）在宿主侧没有独立的评论直连实现名，
  // 复用汽水官方评论接口的 'qishui' 平台码。
  const lxCodes = {
    'wy': 'wy',
    'tx': 'tx',
    'kg': 'kg',
    'kw': 'kw',
    'mg': 'mg',
    'qs': 'qishui',
    'jo': 'jo',
  };
  final sourceKey = musicInfo?['source'];
  if (sourceKey is String && lxCodes.containsKey(sourceKey)) {
    return lxCodes[sourceKey];
  }

  // 星海聚合插件（v4）的歌曲带 _src/_source 来源标记，baka 版歌曲带
  // animeSrc 来源标记，值均为平台码。
  final starSrc =
      musicInfo?['_src'] ??
      musicInfo?['_source'] ??
      musicInfo?['animeSrc'];
  if (starSrc is String && lxCodes.containsKey(starSrc)) {
    return lxCodes[starSrc];
  }

  var haystack = pluginName ?? '';
  void append(Object? v) {
    if (v is String && v.isNotEmpty) haystack = '$haystack|$v';
  }

  append(musicInfo?['platform']);
  append(musicInfo?['source']);
  final raw = musicInfo?['rawData'];
  if (raw is Map) {
    append(raw['platform']);
    append(raw['source']);
  }

  final patterns = <(String, RegExp)>[
    ('wy', RegExp(r'网易|netease|\bwy\b', caseSensitive: false)),
    ('tx', RegExp(r'qq', caseSensitive: false)),
    ('kg', RegExp(r'酷狗|kugou|\bkg\b', caseSensitive: false)),
    ('kw', RegExp(r'酷我|kuwo|\bkw\b', caseSensitive: false)),
    ('mg', RegExp(r'咪咕|migu|\bmg\b', caseSensitive: false)),
    ('qishui', RegExp(r'汽水|qishui', caseSensitive: false)),
    ('jo', RegExp(r'joox', caseSensitive: false)),
  ];
  for (final (platform, pattern) in patterns) {
    if (pattern.hasMatch(haystack)) return platform;
  }
  return null;
}

// ==================== 网络 ====================

Future<Object?> _httpJson(
  String method,
  String url, {
  Map<String, String>? headers,
  String? body,
}) async {
  final client = http.Client();
  try {
    final uri = Uri.parse(url);
    final http.Response resp;
    if (method == 'POST') {
      resp = await client
          .post(uri, headers: headers, body: body)
          .timeout(const Duration(seconds: 18));
    } else {
      resp = await client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 18));
    }
    if (resp.statusCode < 200 || resp.statusCode >= 400) {
      // 5xx 视为上游暂时故障（可重试）；4xx 是业务拒绝，按空结果处理。
      if (resp.statusCode >= 500) {
        throw _CommentNetworkException(
          '评论服务暂时不可用（HTTP ${resp.statusCode}），请稍后重试',
        );
      }
      return null;
    }
    return jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
  } on _CommentNetworkException {
    rethrow;
  } catch (_) {
    throw const _CommentNetworkException('评论接口连接失败，请检查网络后重试');
  } finally {
    client.close();
  }
}

const _uaChrome =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// 获取平台评论。平台不支持或缺少歌曲 id 时返回 null。
Future<CommentPage?> fetchPlatformComments({
  required String platform,
  required Map<String, dynamic> musicInfo,
  int page = 1,
}) async {
  try {
    return switch (platform) {
      'wy' => await _fetchWy(musicInfo, page),
      'tx' => await _fetchTx(musicInfo, page),
      'kg' => await _fetchKg(musicInfo, page),
      'kw' => await _fetchKw(musicInfo, page),
      'mg' => await _fetchMg(musicInfo, page),
      'qishui' => await _fetchQishui(musicInfo, page),
      'jo' => await _fetchJo(musicInfo, page),
      _ => null,
    };
  } on _CommentNetworkException {
    rethrow;
  } catch (_) {
    return const CommentPage(items: [], isEnd: true);
  }
}

// ==================== 网易云 ====================

CommentItem _mapWy(Object? raw) {
  final m = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
  String? id;
  final cid = m['commentId'];
  if (cid != null) id = cid.toString();
  String? avatar;
  final au = m['user'];
  if (au is Map) {
    avatar = (au['avatarUrl'] as String?) ?? (au['avatarImgUrlStr'] as String?);
  }
  final user = au is Map
      ? (au.cast<String, dynamic>()['nickname'] as String?) ?? ''
      : '';
  final ip = m['ipLocation'];
  String? location;
  if (ip is Map) location = ip['location'] as String?;
  return CommentItem(
    id: id ?? '',
    nickName: user,
    avatar: avatar,
    comment: (m['content'] as String?) ?? '',
    like: (m['likedCount'] as num?)?.toInt() ?? 0,
    createAt: (m['time'] as num?)?.toInt(),
    location: location,
    replies: [
      for (final r in (m['beReplied'] as List?) ?? const []) _mapWyReply(r),
    ],
  );
}

CommentItem _mapWyReply(Object? raw) {
  final m = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
  final u = m['user'];
  final user = u is Map
      ? (u.cast<String, dynamic>()['nickname'] as String?) ?? ''
      : '';
  final ip = m['ipLocation'];
  String? location;
  if (ip is Map) location = ip['location'] as String?;
  return CommentItem(
    id: (m['beRepliedCommentId'] as num?)?.toString() ?? '',
    nickName: user,
    comment: (m['content'] as String?) ?? '',
    createAt: (m['time'] as num?)?.toInt(),
    location: location,
  );
}

Future<CommentPage?> _fetchWy(Map<String, dynamic> musicInfo, int page) async {
  final empty = const CommentPage(items: [], isEnd: true);
  final id = _id(musicInfo, ['id']);
  if (id == null) return null;
  final offset = (page - 1) * _pageSize;
  final data = await _httpJson(
    'GET',
    'https://music.163.com/api/v1/resource/comments/R_SO_4_$id'
        '?rid=R_SO_4_$id&limit=$_pageSize&offset=$offset',
    headers: {'Referer': 'https://music.163.com/', 'User-Agent': _uaChrome},
  );
  final m = data is Map ? data.cast<String, dynamic>() : null;
  if (m == null || m['code'] != 200) return empty;

  final list = <CommentItem>[];
  final hot = m['hotComments'];
  if (page == 1 && hot is List) {
    for (final c in hot) {
      list.add(_mapWy(c));
    }
  }
  if (m['comments'] is List) {
    final seen = <String>{};
    for (final c in (m['comments'] as List)) {
      final item = _mapWy(c);
      if (item.id.isNotEmpty && seen.contains(item.id)) continue;
      if (item.id.isNotEmpty) seen.add(item.id);
      list.add(item);
    }
  }
  return CommentPage(items: list, isEnd: m['more'] != true);
}

// ==================== QQ 音乐 ====================

CommentItem _mapTx(Object? raw) {
  final m = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
  int? createAt;
  final t = m['time'];
  if (t is num) {
    createAt = t.toInt() * 1000;
  } else if (t is String) {
    final sec = int.tryParse(t);
    if (sec != null) createAt = sec * 1000;
  }
  final middle = m['middlecommentcontent'] ?? m['SubComments'];
  return CommentItem(
    // 该接口返回的是「根评论 + 楼中楼」，主体作者/内容取 root 字段；
    // commentid/nick 是楼中楼回复者的信息。
    id: (m['rootcommentid'] ?? m['commentid'] ?? m['CmId'])?.toString() ?? '',
    nickName: ((m['rootcommentnick'] ?? m['nick'] ?? m['Nick']) as String?) ?? '',
    avatar: (m['avatarurl'] ?? m['Avatar']) as String?,
    comment: ((m['rootcommentcontent'] ?? m['content'] ?? m['Content'])
            as String?) ??
        '',
    like: ((m['praisenum'] ?? m['PraiseNum']) as num?)?.toInt() ?? 0,
    createAt: createAt,
    replies: [
      for (final r in middle is List ? middle : const []) _mapTxReply(r),
    ],
  );
}

CommentItem _mapTxReply(Object? raw) {
  final m = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
  int? createAt;
  final pt = m['PubTime'];
  if (pt is int) createAt = int.parse('${pt}000');
  return CommentItem(
    id: (m['subcommentid'] ?? m['CmId'])?.toString() ?? '',
    nickName: ((m['replynick'] ?? m['Nick']) as String?) ?? '',
    avatar: (m['reply_identity_pic'] ?? m['Avatar']) as String?,
    comment: ((m['subcommentcontent'] ?? m['Content']) as String?) ?? '',
    like: (m['PraiseNum'] as num?)?.toInt() ?? 0,
    createAt: createAt,
  );
}

Future<String?> _resolveTxSongId(Map<String, dynamic> musicInfo) async {
  final rid = _id(musicInfo, ['songId', 'id']);
  if (rid != null && RegExp(r'^\d+$').hasMatch(rid) && int.tryParse(rid) != 0) {
    return rid;
  }
  final songmid = musicInfo['songmid'] ?? musicInfo['mid'];
  if (songmid == null || songmid.toString().isEmpty) return null;
  // musicu 的 CgiGetTrackInfo 需要登录态（无 cookie 返回 500001），
  // 改用公开的歌曲详情接口按 mid 换数字 id。
  final data = await _httpJson(
    'GET',
    'https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg'
        '?songmid=${Uri.encodeComponent(songmid.toString())}'
        '&format=json&platform=yqq',
    headers: {
      'Referer': 'https://y.qq.com/',
      'User-Agent': _uaChrome,
    },
  );
  final list = data is Map ? data['data'] : null;
  final first = list is List && list.isNotEmpty ? list.first : null;
  return first is Map ? first['id']?.toString() : null;
}

Future<CommentPage?> _fetchTx(Map<String, dynamic> musicInfo, int page) async {
  final empty = const CommentPage(items: [], isEnd: true);
  final songId = await _resolveTxSongId(musicInfo);
  if (songId == null) return empty;
  // musicu 的 CommentRead 同样需要登录态，改用公开的全局评论接口
  // （分页参数 pagenum 从 0 开始）。
  final data = await _httpJson(
    'GET',
    'https://c.y.qq.com/base/fcgi-bin/fcg_global_comment_h5.fcg'
        '?g_tk=5381&uin=0&format=json&jsonpCallback=callback&loginUin=0'
        '&hostUin=0&notice=0&platform=yqq.json&needNewCode=0'
        '&cid=205360772&reqtype=2&biztype=1&topid=${Uri.encodeComponent(songId)}'
        '&cmd=8&needmusiccrit=0&pagenum=${page - 1}&pagesize=$_pageSize',
    headers: {
      'Referer': 'https://y.qq.com/',
      'User-Agent': _uaChrome,
    },
  );
  final m = data is Map ? data['comment'] : null;
  if (m is! Map) return empty;
  final comments = (m['commentlist'] as List?) ?? const [];
  if (comments.isEmpty) return empty;
  final total =
      num.tryParse((m['commenttotal'] ?? '').toString())?.toInt() ?? 0;
  // 同一根评论可能因多条楼中楼回复重复出现，按根评论 id 去重。
  final items = <CommentItem>[];
  final seen = <String>{};
  for (final c in comments) {
    final item = _mapTx(c);
    if (item.id.isNotEmpty && !seen.add(item.id)) continue;
    items.add(item);
  }
  return CommentPage(
    items: items,
    isEnd: total > 0
        ? page * _pageSize >= total
        : comments.length < _pageSize,
  );
}

// ==================== 酷狗 ====================

const _kgSaltAndroid = 'OIlwieks28dk2k092lksi2UIkp';

String _md5Hex(String input) => md5.convert(utf8.encode(input)).toString();

/// md5(salt + sort(params).join('') + body + salt)
String _kugouSign(String params, {String body = ''}) {
  final list = params.split('&')..sort();
  final input = '$_kgSaltAndroid${list.join()}$body$_kgSaltAndroid';
  return _md5Hex(input);
}

Future<CommentPage?> _fetchKg(Map<String, dynamic> musicInfo, int page) async {
  final empty = const CommentPage(items: [], isEnd: true);
  final hash = musicInfo['hash'] ?? musicInfo['id'];
  if (hash == null || hash.toString().isEmpty) return empty;

  // 评论接口以 extdata=hash 定位歌曲，mixsongid 传 0 即可；
  // 原先走 gateway 的 hash→mixsongid 换 id 接口已要求签名，稳定失败。
  final params = [
    'appid=1005',
    'clienttime=${DateTime.now().millisecondsSinceEpoch}',
    'clienttoken=0',
    'clientver=11409',
    'code=fc4be23b4e972707f36b8a828a93ba8a',
    'dfid=0',
    'extdata=${hash.toString()}',
    'kugouid=0',
    'mid=16249512204336365674023395779019',
    'mixsongid=0',
    'p=$page',
    'pagesize=$_pageSize',
    'uuid=0',
    'ver=10',
  ].join('&');
  final signature = _kugouSign(params);

  final data = await _httpJson(
    'GET',
    'http://m.comment.service.kugou.com/r/v1/rank/newest'
        '?$params&signature=$signature',
    headers: {
      'accept': 'application/json',
      'user-agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 '
          'Edg/107.0.1418.24',
    },
  );
  final m = data is Map ? data.cast<String, dynamic>() : null;
  if (m == null || (m['list'] is! List)) return empty;
  final items = <CommentItem>[];
  for (final item in (m['list'] as List)) {
    final raw = item is Map ? item.cast<String, dynamic>() : const {};
    final like = raw['like'] is Map
        ? ((raw['like'] as Map)['likenum'] as num?)?.toInt()
        : null;
    int? createAt;
    final addtime = raw['addtime'];
    if (addtime is num) {
      createAt = addtime.toInt() * 1000;
    } else if (addtime is String) {
      // 接口返回 "yyyy-MM-dd HH:mm:ss" 本地时间字符串。
      createAt =
          DateTime.tryParse(addtime.replaceFirst(' ', 'T'))?.millisecondsSinceEpoch;
    }
    items.add(CommentItem(
      id: raw['id']?.toString() ?? '',
      nickName: (raw['user_name'] as String?) ?? '',
      avatar: raw['user_pic'] as String?,
      comment: (raw['content'] as String?) ?? '',
      like: like ?? 0,
      createAt: createAt,
      location: raw['location'] as String?,
    ));
  }
  return CommentPage(items: items, isEnd: items.length < _pageSize);
}

// ==================== 酷我 ====================

CommentItem _mapKw(Object? raw) {
  final m = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
  final t = _asInt(m['time']);
  final childComments = m['child_comments'];
  return CommentItem(
    id: m['id']?.toString() ?? '',
    nickName: (m['u_name'] as String?) ?? '',
    avatar: m['u_pic'] as String?,
    comment: (m['msg'] as String?) ?? '',
    like: _asInt(m['like_num']),
    createAt: t == null ? null : t * 1000,
    replies: [
      for (final c in childComments is List ? childComments : const [])
        _mapKw(c),
    ],
  );
}

Future<CommentPage?> _fetchKw(Map<String, dynamic> musicInfo, int page) async {
  final empty = const CommentPage(items: [], isEnd: true);
  final id = _id(musicInfo, ['id', 'rid']);
  if (id == null) return null;
  final start = (page - 1) * _pageSize;
  final data = await _httpJson(
    'GET',
    'http://ncomment.kuwo.cn/com.s?f=web&type=get_comment&aapiver=1'
        '&prod=kwplayer_ar_10.5.2.0&digest=15&sid=${Uri.encodeComponent(id)}'
        '&start=$start&msgflag=1&count=$_pageSize&newver=3&uid=0',
    headers: {'User-Agent': 'Dalvik/2.1.0 (Linux; U; Android 9;)'},
  );
  final m = data is Map ? data.cast<String, dynamic>() : null;
  if (m == null || m['code'] != '200') return empty;
  final total =
      num.tryParse((m['comments_counts'] ?? '').toString())?.toInt() ?? 0;
  final comments = (m['comments'] as List?) ?? const [];
  return CommentPage(
    items: comments.map(_mapKw).toList(),
    isEnd: page * _pageSize >= total || comments.isEmpty,
  );
}

// ==================== 咪咕 ====================

CommentItem _mapMg(Object? raw) {
  final m = raw is Map ? raw.cast<String, dynamic>() : const <String, dynamic>{};
  String? avatar;
  final au = m['author'];
  if (au is Map) {
    final av = au.cast<String, dynamic>()['avatar'];
    if (av is String && av.startsWith('//')) avatar = 'http:$av';
  }
  int? createAt;
  final ct = m['createTime'];
  if (ct is String) {
    createAt = DateTime.tryParse(ct)?.millisecondsSinceEpoch;
  }
  return CommentItem(
    id: m['commentId']?.toString() ?? '',
    nickName: au is Map
        ? (au.cast<String, dynamic>()['name'] as String?) ?? ''
        : '',
    avatar: avatar,
    comment: (m['body'] as String?) ?? '',
    like: (m['praiseCount'] as num?)?.toInt(),
    createAt: createAt,
    replies: [
      for (final r in (m['replyCommentList'] as List?) ?? const []) _mapMg(r),
    ],
  );
}

Future<CommentPage?> _fetchMg(Map<String, dynamic> musicInfo, int page) async {
  final empty = const CommentPage(items: [], isEnd: true);
  final id = _id(musicInfo, ['id', 'copyrightId', 'copyright_id']);
  if (id == null) return null;
  final data = await _httpJson(
    'GET',
    'https://music.migu.cn/v3/api/comment/listComments'
        '?targetId=${Uri.encodeComponent(id)}&pageSize=$_pageSize&pageNo=$page',
    headers: {'User-Agent': _uaChrome, 'Referer': 'https://music.migu.cn'},
  );
  final m = data is Map ? data.cast<String, dynamic>() : null;
  if (m == null || m['returnCode'] != '000000') return empty;
  final inner = m['data'] is Map
      ? (m['data'] as Map).cast<String, dynamic>()
      : const <String, dynamic>{};
  final items = (inner['items'] as List?) ?? const [];
  final total = (inner['itemTotal'] as num?)?.toInt() ?? 0;
  return CommentPage(
    items: items.map(_mapMg).toList(),
    isEnd: page * _pageSize >= total || items.isEmpty,
  );
}

// ==================== 汽水 ====================

Future<CommentPage?> _fetchQishui(
  Map<String, dynamic> musicInfo,
  int page,
) async {
  final empty = const CommentPage(items: [], isEnd: true);
  final id = _id(musicInfo, ['id', 'item_id', 'track_id']);
  if (id == null) return null;
  final params = {
    'aid': '386088',
    'app_name': 'luna_pc',
    'region': 'cn',
    'geo_region': 'cn',
    'os_region': 'cn',
    'sim_region': '',
    'device_id': '100000305367703244',
    'cdid': '',
    'iid': '',
    'version_name': '3.2.1',
    'version_code': '30020100',
    'channel': 'official',
    'build_mode': 'master',
    'network_carrier': '',
    'ac': 'wifi',
    'tz_name': 'Asia/Shanghai',
    'resolution': '',
    'device_platform': 'windows',
    'device_type': 'Windows',
    'os_version': 'Windows 11 Home China',
    'fp': '100000305367703244',
    'group_id': id,
    'cursor': '${(page - 1) * _pageSize}',
    'count': '$_pageSize',
    'group_type': '1',
    'image_strategy': '2',
  };
  final query = Uri(queryParameters: params).query;
  final data = await _httpJson(
    'GET',
    'https://api.qishui.com/luna/pc/comments?$query',
    headers: {
      'Accept': '*/*',
      'Content-Type': 'application/json; charset=utf-8',
      'User-Agent': 'LunaPC/3.2.1(343009595)',
      'x-luna-background-type': 'foreground',
      'x-luna-is-background-req': '0',
      'x-luna-is-local-user': '0',
    },
  );
  final m = data is Map ? data.cast<String, dynamic>() : null;
  if (m == null) return empty;
  // 汽水 PC 评论接口成功时可能不下发 status_code（实测仅返回 status_info），
  // 旧写法把它当成失败、直接抛空页，导致汽水歌曲「明明有评论却显示暂无」。
  // 只在明确给出非 0 状态码时判定失败。
  final statusCode = (m['status_code'] as num?)?.toInt();
  if (statusCode != null && statusCode != 0) return empty;
  final comments = (m['comments'] as List?) ?? const [];
  final items = <CommentItem>[];
  for (final raw in comments) {
    final c = raw is Map ? raw.cast<String, dynamic>() : const {};
    final user = c['user'] is Map
        ? (c['user'] as Map).cast<String, dynamic>()
        : null;
    final av = user?['medium_avatar_url'];
    num? rawTime = c['time_created'];
    if (rawTime is! num) rawTime = 0;
    final t = rawTime.toInt();
    final createAt = t > 0 && t < 1000000000000 ? t * 1000 : t;
    items.add(CommentItem(
      id: c['id']?.toString() ?? '',
      nickName: (user?['nickname'] as String?) ?? '',
      avatar: av is String ? av : null,
      comment: (c['content'] as String?) ?? '',
      like: (c['count_digged'] as num?)?.toInt(),
      createAt: createAt > 0 ? createAt : null,
    ));
  }
  return CommentPage(
    items: items,
    isEnd: m['has_more'] == false || items.length < _pageSize,
  );
}

// ==================== JOOX ====================

/// JOOX 评论：`openjoox/v1/get_track_comments` 用 last_seq_id 游标翻页，
/// 没有 page/cursor 参数——第 N 页只能从第 1 页起按 last_seq_id 连续取。
/// 因此这里按目标页码串行追链（每页 20 条，最多追 3 页），既保证分页正确，
/// 又不会因用户反复下拉而无限打上游。
Future<CommentPage?> _fetchJo(
  Map<String, dynamic> musicInfo,
  int page,
) async {
  final empty = const CommentPage(items: [], isEnd: true);
  // 接口只接受数字 songid 或 base64 歌曲 ID；Z 开头 mid 会 401/404。
  final id = _id(musicInfo, ['songId', 'song_id', 'id', 'songmid']);
  if (id == null) return null;
  if (page > 3) return empty;

  var lastSeq = '0';
  for (var current = 1; current <= page; current++) {
    final query = Uri(queryParameters: {
      'id': id,
      'country': 'HK',
      'lang': 'en',
      'last_seq_id': lastSeq,
      'num': '$_pageSize',
    }).query;
    final data = await _httpJson(
      'GET',
      'https://cache.api.joox.com/openjoox/v1/get_track_comments?$query',
      headers: {
        'Accept': 'application/json',
        'User-Agent': 'okhttp/4.12.0',
        'Referer': 'https://www.joox.com/',
      },
    );
    final m = data is Map ? data.cast<String, dynamic>() : null;
    // 第 1 页就失败视为网络故障（由上层给可重试错误态）；后续页失败则
    // 认为已到底，不覆盖已取到的上一页结果。
    if (m == null) {
      if (current == 1) return null;
      return empty;
    }
    final comments = (m['comments'] as List?) ?? const [];
    final items = comments
        .whereType<Map>()
        .map((raw) => _mapJo(raw.cast<String, dynamic>()))
        .toList();
    final hasMoreRaw = m['has_more'];
    final hasMore = hasMoreRaw == 1 || hasMoreRaw == true || hasMoreRaw == '1';
    if (current == page) {
      return CommentPage(
        items: items,
        isEnd: !hasMore || items.length < _pageSize,
      );
    }
    if (!hasMore) return empty;
    final next = m['last_seq_id']?.toString();
    if (next == null || next.isEmpty) return empty;
    lastSeq = next;
  }
  return empty;
}

CommentItem _mapJo(Map<String, dynamic> c) {
  // create_time 是秒级时间戳，统一转毫秒，避免 UI 显示成 1970 年。
  final rawTime = _asInt(c['create_time']) ?? 0;
  final createAt = rawTime > 0 && rawTime < 1000000000000
      ? rawTime * 1000
      : rawTime;
  final replies = <CommentItem>[];
  final replayContent = c['replay_content'];
  if (replayContent is String && replayContent.trim().isNotEmpty) {
    replies.add(CommentItem(
      id: '${c['id'] ?? ''}_reply',
      nickName: (c['replay_nickname'] as String?) ?? '',
      comment: replayContent,
      like: 0,
    ));
  }
  final images = c['images'];
  String? avatar;
  if (images is List && images.isNotEmpty) {
    final first = images.first;
    avatar = first is String && first.startsWith('http') ? first : null;
  }
  return CommentItem(
    id: c['id']?.toString() ?? '',
    nickName: (c['nickname'] as String?) ?? '',
    avatar: avatar,
    comment: (c['content'] as String?) ?? '',
    like: _asInt(c['likes']),
    createAt: createAt > 0 ? createAt : null,
    replies: replies,
  );
}

// ==================== 工具 ====================

/// 从 musicInfo 依次取首个非空 id 字段。
String? _id(Map<String, dynamic> musicInfo, List<String> keys) {
  String? pick(Map<String, dynamic> m, String key) {
    final v = m[key];
    if (v == null) return null;
    final s = v.toString();
    return s.isEmpty ? null : s;
  }

  for (final k in keys) {
    final v = pick(musicInfo, k);
    if (v != null) return v;
  }
  return null;
}
