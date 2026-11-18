// 歌曲评论服务。
//
// 数据来源两级：
// 1. MusicFree 插件的 getMusicComments(musicItem, page)——插件自带评论优先；
// 2. 惜梦洛雪源平台评论接口（宿主直连，其余场景统一走这里）：
//    GET https://anime.xisb.cn/anime/yuan/comment
//        ?platform=<平台>&id=<歌曲 id>&page=<页码>&limit=<每页条数>[&sort=hot|new|recommend]
//
// 接口平台边界（实测 2026-11）：
// - 支持 kg / kw / tx / wy / bili；qs / jo / mg 上游没有公开评论接口，
//   固定返回 code=4001（宿主据此判定「不支持评论」而非加载失败）。
// - sort=recommend 是酷狗专用推荐池排序，其余平台取值会被回落成 new。
// - 楼层回复走同一接口，追加 rid=<主评论 id>；酷狗还必须带 cid
//   （评论池 ID，取自主评论响应的 cid 字段），否则返回 code=4003。
// - 网易云不需要单独调楼层，主评论的 replies 字段就是前若干条回复。
// - 翻页加速：可追加 last_score=<上一页最后一条的 rank_score>，跳过
//   服务端的循环翻页（该字段并非所有响应都下发，故按可空处理）。
//
// 酷狗评论接口认 album_audio_id（数字 mixsongid），而洛雪音源给出的
// songmid 是 hash，必须先换算；QQ 音乐认数字 songId，洛雪源通常已带
// songId，缺失时按 mid 换。这些换算属于「参数准备」，不是评论兜底。
//
// 约定：返回 null 表示当前歌曲无法取得评论（平台不支持或缺少歌曲 id），
// 调用方据此展示「不支持」；网络/上游故障抛 _CommentNetworkException，
// 调用方展示可重试的错误态。
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'plugin_runtime.dart';

const _pageSize = 20;

/// 惜梦洛雪源评论接口。
const commentApiBase = 'https://anime.xisb.cn/anime/yuan/comment';

/// 评论排序：接口认 hot / new / recommend（recommend 为酷狗推荐池专用，
/// 其余平台会被回落成 new，UI 只在酷狗歌曲上暴露该档位）。
enum CommentSort { hot, latest, recommended }

/// 接口当前支持评论的平台；qs/jo/mg 上游无公开评论接口。
const _supportedPlatforms = {'kg', 'kw', 'tx', 'wy', 'bili'};

/// 平台是否有可用的评论接口。
bool supportsCommentPlatform(String platform) =>
    _supportedPlatforms.contains(platform);

/// 评论条目。
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
    this.cid,
    this.replyCount = 0,
    this.platform,
    this.songId,
    this.rankScore,
  });

  final String id;
  final String nickName;
  final String? avatar;
  final String comment;
  final int? like;
  final int? createAt;
  final String? location;

  /// 主评论随响应下发的少量二级评论（网易云/ B 站会带）。
  final List<CommentItem> replies;

  /// 酷狗评论池 ID，拉取楼层回复时必须回传。
  final String? cid;

  /// 楼层回复总数（接口 reply_num）。
  final int replyCount;

  /// 所属评论平台（主评论才有，楼层请求据此回传）。
  final String? platform;

  /// 评论接口使用的歌曲 ID（主评论才有，楼层请求据此回传）。
  final String? songId;

  /// 接口翻页游标（部分平台下发），用于 last_score 加速翻页。
  final int? rankScore;

  /// 插件结果（getMusicComments）规范化：兼容多种字段别名。
  static CommentItem normalize(dynamic raw) {
    if (raw is! Map) return const CommentItem(id: '', nickName: '', comment: '');
    final m = raw.cast<String, dynamic>();
    int? like;
    final likeRaw = m['like'] ?? m['likeCount'] ?? m['likes'] ?? m['like_count'];
    if (likeRaw is num) like = likeRaw.toInt();
    int? createAt;
    final timeRaw = m['createAt'] ?? m['createdAt'] ?? m['timestamp'] ?? m['time'];
    if (timeRaw is num) {
      createAt = timeRaw.toInt();
    } else if (timeRaw is String && timeRaw.isNotEmpty) {
      createAt = _parseTime(timeRaw);
    }

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
      cid: m['cid']?.toString(),
      replyCount: _asInt(m['reply_num'] ?? m['replyCount']) ?? replies.length,
    );
  }

  CommentItem copyWith({List<CommentItem>? replies}) => CommentItem(
        id: id,
        nickName: nickName,
        avatar: avatar,
        comment: comment,
        like: like,
        createAt: createAt,
        location: location,
        replies: replies ?? this.replies,
        cid: cid,
        replyCount: replyCount,
        platform: platform,
        songId: songId,
        rankScore: rankScore,
      );
}

/// 评论分页结果。
class CommentPage {
  const CommentPage({required this.items, required this.isEnd});
  final List<CommentItem> items;
  final bool isEnd;
}

/// 拉取一页主评论。
///
/// pluginData 为播放队列项携带的插件数据：LX 歌曲是 {'lx': songInfo}，
/// MusicFree 歌曲是原始条目 rawData。返回 null 表示无法取得评论。
Future<CommentPage?> fetchSongComments({
  required EnabledMusicPlugin plugin,
  required Map<String, dynamic> pluginData,
  PluginRuntimeService? runtime,
  int page = 1,
  CommentSort sort = CommentSort.hot,
}) async {
  final lxInfo = pluginData['lx'];
  final isLx = plugin.isLx || lxInfo is Map;
  final musicItem = lxInfo is Map
      ? _commentMusicInfo(lxInfo)
      : _normalizeMusicItem(plugin, pluginData);

  // 1) MusicFree 插件自带评论优先：插件明确返回（即便为空）即不再走平台接口。
  //    惜梦聚合插件本体不含评论方法，直接走平台接口。
  if (!isLx && !plugin.isAnimemusic && runtime != null) {
    try {
      final result = await runtime
          .getMusicComments(plugin, musicItem, page)
          .timeout(const Duration(seconds: 15));
      final parsed = _parsePluginResult(result);
      if (parsed != null && (parsed.items.isNotEmpty || parsed.isEnd)) {
        return parsed;
      }
    } catch (_) {
      // 插件未声明 getMusicComments 或调用失败 → 落到平台评论接口。
    }
  }

  // 2) 惜梦洛雪源平台评论接口。
  final platform = detectCommentPlatform(
    pluginName: plugin.name,
    musicInfo: musicItem,
  );
  if (platform == null || !supportsCommentPlatform(platform)) return null;
  final songId = await resolveCommentSongId(
    platform: platform,
    musicInfo: musicItem,
  );
  if (songId == null) return null;
  return _fetchPlatformPage(
    platform: platform,
    songId: songId,
    page: page,
    sort: sort,
  );
}

/// 拉取某条主评论的楼层回复。
///
/// 返回 null 表示该评论没有可用的楼层接口（平台不支持 / 酷狗缺 cid），
/// 调用方可回退展示主评论自带的 replies。
Future<CommentPage?> fetchCommentReplies(
  CommentItem comment, {
  int page = 1,
  int? cursor,
}) async {
  final platform = comment.platform;
  final songId = comment.songId;
  if (platform == null || songId == null) return null;
  if (!supportsCommentPlatform(platform)) return null;
  if (comment.id.isEmpty) return null;
  // 网易云主评论每条的 replies 就是回复，不需要单独调楼层。
  if (platform == 'wy') {
    return CommentPage(items: comment.replies, isEnd: true);
  }
  final params = <String, String>{
    'platform': platform,
    'id': songId,
    'rid': comment.id,
    'page': '$page',
    'limit': '$_pageSize',
  };
  if (platform == 'kg') {
    final cid = comment.cid;
    // 酷狗楼层接口必须带评论池 ID，缺失时上游直接返回 4003。
    if (cid == null || cid.isEmpty) return null;
    params['cid'] = cid;
  }
  // 翻页加速：带上页面游标（部分平台在条目里下发 rank_score），
  // 服务端可直接跳过循环扫描；没有游标时退回普通 page 翻页。
  if (page > 1 && cursor != null) params['last_score'] = '$cursor';

  final data = await _requestComment(params);
  if (data == null) return null;
  final items = _mapCommentList(
    data['comments'],
    platform: platform,
    songId: songId,
  );
  final hasMore = _asInt(data['has_more']) ?? 0;
  return CommentPage(items: items, isEnd: hasMore == 0 || items.isEmpty);
}

/// 拉取一页主评论并规范化。
Future<CommentPage?> _fetchPlatformPage({
  required String platform,
  required String songId,
  required int page,
  CommentSort sort = CommentSort.hot,
}) async {
  // sort=recommend 仅酷狗识别；其余平台传了也会被服务端回落成 new，
  // 这里直接按 hot 发，保持语义与 UI 档位一致。
  final sortParam = switch (sort) {
    CommentSort.hot => 'hot',
    CommentSort.latest => 'new',
    CommentSort.recommended => platform == 'kg' ? 'recommend' : 'hot',
  };
  final data = await _requestComment({
    'platform': platform,
    'id': songId,
    'page': '$page',
    'limit': '$_pageSize',
    'sort': sortParam,
  });
  if (data == null) return null;
  final items = _mapCommentList(
    data['comments'],
    platform: platform,
    songId: songId,
  );
  // has_more 为 0/1；酷我等平台 total 可能为 0 却仍有数据，
  // 因此只用 has_more 与空列表判断结束，不看 total。
  final hasMore = _asInt(data['has_more']) ?? 0;
  return CommentPage(items: items, isEnd: hasMore == 0 || items.isEmpty);
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

/// LX 歌曲的评论元数据：LX 音源只给取流所需的标识，评论接口要的是
/// 各平台专有的歌曲 ID，这里先把 LX 音乐信息里的已知字段摊平。
/// 真正的 ID 换算在 [resolveCommentSongId] 里做（酷狗 hash → album_audio_id、
/// QQ mid → 数字 songId）。
Map<String, dynamic> _commentMusicInfo(Map<dynamic, dynamic> lxInfo) {
  final info = Map<String, dynamic>.from(lxInfo);
  final songmid = _textOf(info['songmid']);
  if (songmid != null) {
    // 各平台搜索结果统一把主标识放在 songmid，评论侧按平台取用。
    info['id'] ??= songmid;
    info['songmid'] ??= songmid;
  }
  return info;
}

/// 解析当前歌曲的评论平台（与 [fetchSongComments] 的判定同构）。
///
/// 供 UI 判断能力档位（如酷狗的「推荐」排序）而无需发起网络请求。
/// 返回 null 表示无法识别平台。
String? commentPlatformOf({
  required EnabledMusicPlugin plugin,
  required Map<String, dynamic> pluginData,
}) {
  final lxInfo = pluginData['lx'];
  final musicItem = lxInfo is Map
      ? _commentMusicInfo(lxInfo)
      : _normalizeMusicItem(plugin, pluginData);
  return detectCommentPlatform(pluginName: plugin.name, musicInfo: musicItem);
}

/// 解析评论接口需要的歌曲 ID。
/// 返回 null 表示该歌曲缺少可用标识（评论不可取）。
Future<String?> resolveCommentSongId({
  required String platform,
  required Map<String, dynamic> musicInfo,
}) async {
  String? pick(List<String> keys) {
    for (final key in keys) {
      final value = _digits(_textOf(musicInfo[key]));
      if (value != null) return value;
    }
    return null;
  }

  switch (platform) {
    case 'kg':
      // 酷狗评论网关按 album_audio_id（数字 mixsongid）定位歌曲。
      // 注意：audio_id / Audioid 不是评论网关认的 ID（会返回 5000）。
      final direct = pick([
        'albumAudioId',
        'album_audio_id',
        'mixsongid',
        'mixSongId',
      ]);
      if (direct != null) return direct;
      final songmid = _textOf(musicInfo['songmid']);
      if (songmid != null && RegExp(r'^\d+$').hasMatch(songmid)) {
        return songmid;
      }
      final hash = _textOf(musicInfo['hash']) ?? songmid;
      if (hash == null) return null;
      return _kugouAlbumAudioId(hash);
    case 'tx':
      // QQ 音乐评论接口按数字 songId 定位；洛雪源一般已带 songId。
      final direct = pick(['songId', 'song_id', 'songid', 'id']);
      if (direct != null) return direct;
      final mid = _textOf(musicInfo['songmid']) ??
          _textOf(musicInfo['mid']) ??
          _textOf(musicInfo['strMediaMid']);
      if (mid == null) return null;
      return _qqSongIdByMid(mid);
    case 'kw':
      return pick(['id', 'rid', 'songmid', 'musicrid']);
    case 'wy':
      return pick(['id', 'songmid', 'songId']);
    case 'bili':
      // B 站评论按 BV 号定位；也兼容直接给出 av 号。
      final bvid = _textOf(musicInfo['bvid']) ??
          _textOf(musicInfo['bvid2']) ??
          _textOf(musicInfo['songmid']) ??
          _textOf(musicInfo['id']);
      return bvid;
    default:
      return null;
  }
}

/// 酷狗 hash → album_audio_id：评论网关只认后者，公开的 playInfo
/// 接口能给出该字段（无需签名）。
Future<String?> _kugouAlbumAudioId(String hash) async {
  final data = await _httpJson(
    'GET',
    'http://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo'
        '&hash=${Uri.encodeComponent(hash)}',
    headers: {'User-Agent': _uaChrome},
  );
  final m = data is Map ? data.cast<String, dynamic>() : null;
  if (m == null) return null;
  return _digits(_textOf(m['album_audio_id'])) ??
      _digits(_textOf(m['mixsongid']));
}

/// QQ 音乐 mid → 数字 songId（musicu 的 CgiGetTrackInfo 需要登录态，
/// 改用公开的歌曲详情接口）。
Future<String?> _qqSongIdByMid(String mid) async {
  final data = await _httpJson(
    'GET',
    'https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg'
        '?songmid=${Uri.encodeComponent(mid)}&format=json&platform=yqq',
    headers: {'Referer': 'https://y.qq.com/', 'User-Agent': _uaChrome},
  );
  final list = data is Map ? data['data'] : null;
  final first = list is List && list.isNotEmpty ? list.first : null;
  return first is Map ? _digits(_textOf(first['id'])) : null;
}

/// 识别歌曲所属评论平台（按 lx 源 key / 平台字段 / 插件名正则）。
String? detectCommentPlatform({
  String? pluginName,
  Map<String, dynamic>? musicInfo,
}) {
  if (musicInfo == null && (pluginName == null || pluginName.isEmpty)) {
    return null;
  }

  // LX 源 key 即平台码；qs（汽水）/ jo（JOOX）/ mg（咪咕）上游没有
  // 公开评论接口，接口会返回 4001，由调用方判定为「不支持评论」。
  const lxCodes = {
    'wy': 'wy',
    'tx': 'tx',
    'kg': 'kg',
    'kw': 'kw',
    'bili': 'bili',
    'bilibili': 'bili',
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
      musicInfo?['_src'] ?? musicInfo?['_source'] ?? musicInfo?['animeSrc'];
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
    ('bili', RegExp(r'bilibili|b站|\bbili\b', caseSensitive: false)),
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

const _uaChrome =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// 评论链路网络/上游故障：让 UI 展示可重试的错误态，而不是误报「暂无评论」。
class _CommentNetworkException implements Exception {
  const _CommentNetworkException(this.message);
  final String message;

  @override
  String toString() => message;
}

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
    // 酷狗评论网关故障时要等 ~20s 才回 5000，客户端超时必须比它宽，
    // 否则服务端的可重试错误会被吞成泛化的「连接失败」。
    if (method == 'POST') {
      resp = await client
          .post(uri, headers: headers, body: body)
          .timeout(const Duration(seconds: 25));
    } else {
      resp = await client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 25));
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

/// 请求评论接口。
///
/// 参数以字符串拼接下发，不做百分号编码：QQ 音乐的评论 id 含 `!`、`*`
/// 等字符，上游按原样匹配，编码后反而查不到楼层。
/// 返回 null 表示平台不支持评论（code=4001）或参数被业务拒绝（4xx）。
Future<Map<String, dynamic>?> _requestComment(Map<String, String> params) async {
  final query = params.entries
      .map((e) => '${e.key}=${e.value}')
      .join('&');
  final data = await _httpJson(
    'GET',
    '$commentApiBase?$query',
    headers: {'Accept': 'application/json', 'User-Agent': _uaChrome},
  );
  if (data == null) return null;
  if (data is! Map) {
    throw const _CommentNetworkException('评论接口返回格式异常，请稍后重试');
  }
  final m = data.cast<String, dynamic>();
  final code = _asInt(m['code']);
  if (code == 200) return m;
  // 4001：该平台上游没有公开评论接口（qs/jo/mg）。
  if (code == 4001) return null;
  final message = _textOf(m['message']) ?? '';
  throw _CommentNetworkException(
    message.isEmpty ? '评论加载失败（code=$code），请稍后重试' : '评论加载失败：$message',
  );
}

// ==================== 解析 ====================

List<CommentItem> _mapCommentList(
  Object? raw, {
  required String platform,
  required String songId,
}) {
  if (raw is! List) return const [];
  return [
    for (final entry in raw)
      if (entry is Map)
        _mapComment(entry, platform: platform, songId: songId),
  ];
}

CommentItem _mapComment(
  Map raw, {
  required String platform,
  required String songId,
}) {
  final m = raw.cast<String, dynamic>();
  final user = m['user'] is Map
      ? (m['user'] as Map).cast<String, dynamic>()
      : const <String, dynamic>{};
  final repliesRaw = m['replies'];
  final replies = repliesRaw is List
      ? [
          for (final r in repliesRaw)
            if (r is Map)
              _mapComment(r, platform: platform, songId: songId),
        ]
      : const <CommentItem>[];
  return CommentItem(
    id: m['id']?.toString() ?? '',
    nickName: (user['name'] as String?) ?? '',
    avatar: _textOf(user['avatar']),
    comment: (m['content'] as String?) ?? '',
    like: _asInt(m['likes']),
    createAt: _parseTime(m['time']),
    location: _textOf(m['location']),
    replies: replies,
    cid: _textOf(m['cid']),
    replyCount: _asInt(m['reply_num']) ?? replies.length,
    platform: platform,
    songId: songId,
    rankScore: _asInt(m['rank_score']),
  );
}

/// 接口时间形如「2026-11-06 12:04:41」（本地时间），个别平台给时间戳。
int? _parseTime(Object? value) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) return null;
  final parsed = DateTime.tryParse(text.replaceFirst(' ', 'T'));
  if (parsed != null) return parsed.millisecondsSinceEpoch;
  final n = int.tryParse(text);
  if (n == null || n <= 0) return null;
  return n < 100000000000 ? n * 1000 : n;
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

// ==================== 工具 ====================

String? _textOf(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

/// 部分平台把数字字段序列化成字符串，统一转换，避免 `as num?` 抛异常。
int? _asInt(Object? value) {
  if (value is num) return value.toInt();
  if (value == null) return null;
  return int.tryParse(value.toString());
}

/// 只保留纯数字 ID；酷狗/QQ 的评论接口不接受非数字标识。
String? _digits(String? value) {
  if (value == null) return null;
  if (!RegExp(r'^\d+$').hasMatch(value)) return null;
  if (int.tryParse(value) == 0) return null;
  return value;
}
