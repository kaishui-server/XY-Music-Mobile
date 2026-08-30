import 'dart:convert';

import 'package:http/http.dart' as http;

import '../library/library_provider.dart';

class NetworkPlaylistSource {
  const NetworkPlaylistSource(this.id, this.name);

  final String id;
  final String name;
}

const builtinPlaylistSources = <NetworkPlaylistSource>[
  NetworkPlaylistSource('wy', '网易云音乐'),
  NetworkPlaylistSource('tx', 'QQ音乐'),
  NetworkPlaylistSource('kw', '酷我音乐'),
  NetworkPlaylistSource('kg', '酷狗音乐'),
];

class NetworkPlaylistImportResult {
  const NetworkPlaylistImportResult({
    required this.name,
    required this.coverUrl,
    required this.songs,
  });

  final String name;
  final String coverUrl;
  final List<Song> songs;
}

class NetworkPlaylistImportService {
  NetworkPlaylistImportService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  Future<NetworkPlaylistImportResult> importPlaylist(
    String source,
    String idOrUrl,
  ) async {
    final input = idOrUrl.trim();
    if (input.isEmpty) throw Exception('请输入歌单 ID');
    final detectedSource = _sourceFromUrl(input);
    switch (detectedSource ?? source) {
      case 'wy':
        return _importNetease(input);
      case 'tx':
        return _importQq(input);
      case 'kw':
        return _importKuwo(input);
      case 'kg':
        return _importKugou(input);
      default:
        throw Exception('不支持的歌单来源');
    }
  }

  Future<NetworkPlaylistImportResult> _importNetease(String input) async {
    final id = _extractId(input, const [
      r'[?&]id=(\d+)',
      r'/playlist/(\d+)',
      r'^(\d+)$',
    ]);
    if (id == null) throw Exception('无法识别网易云歌单 ID');
    final uri = Uri.https('music.163.com', '/api/v6/playlist/detail', {
      'id': id,
      'n': '100000',
      's': '8',
    });
    final body = await _getJson(uri, referer: 'https://music.163.com/');
    if (body['code'] != 200 || body['playlist'] is! Map) {
      throw Exception('网易云歌单获取失败（${body['code'] ?? '未知状态'}）');
    }
    final playlist = Map<String, dynamic>.from(body['playlist'] as Map);
    final tracks = <Map<String, dynamic>>[
      for (final value in (playlist['tracks'] as List? ?? const []))
        if (value is Map) Map<String, dynamic>.from(value),
    ];
    final existingIds = tracks.map((item) => item['id'].toString()).toSet();
    final missingIds = <String>[
      for (final value in (playlist['trackIds'] as List? ?? const []))
        if (value is Map &&
            value['id'] != null &&
            !existingIds.contains(value['id'].toString()))
          value['id'].toString(),
    ];
    for (var offset = 0; offset < missingIds.length; offset += 200) {
      final end = offset + 200 < missingIds.length
          ? offset + 200
          : missingIds.length;
      final ids = missingIds.sublist(offset, end);
      final detail = await _getJson(
        Uri.https('music.163.com', '/api/song/detail/', {
          'ids': jsonEncode(ids.map(int.parse).toList()),
        }),
        referer: 'https://music.163.com/',
      );
      for (final value in (detail['songs'] as List? ?? const [])) {
        if (value is Map) tracks.add(Map<String, dynamic>.from(value));
      }
    }
    final songs = tracks.map(_neteaseSong).whereType<Song>().toList();
    if (songs.isEmpty) throw Exception('网易云歌单为空，或歌单不是公开歌单');
    return NetworkPlaylistImportResult(
      name: _cleanText(playlist['name']?.toString() ?? '网易云歌单'),
      coverUrl: _httpsUrl(playlist['coverImgUrl']?.toString() ?? ''),
      songs: songs,
    );
  }

  Song? _neteaseSong(Map<String, dynamic> track) {
    final id = track['id']?.toString() ?? '';
    if (id.isEmpty || id == '0') return null;
    final artists = track['ar'] ?? track['artists'];
    final artist = _joinNames(artists);
    final albumValue = track['al'] ?? track['album'];
    final album = albumValue is Map
        ? Map<String, dynamic>.from(albumValue)
        : const <String, dynamic>{};
    final title = _cleanText(track['name']?.toString() ?? '');
    final durationMs = _number(track['dt'] ?? track['duration']);
    final raw = <String, dynamic>{
      'songmid': id,
      'source': 'wy',
      'name': title,
      'singer': artist,
      'albumName': _cleanText(album['name']?.toString() ?? ''),
      'albumId': album['id'],
    };
    return _lxSong(
      source: 'wy',
      id: id,
      title: title,
      artist: artist,
      album: raw['albumName'].toString(),
      durationMs: durationMs,
      coverUrl: _httpsUrl(album['picUrl']?.toString() ?? ''),
      raw: raw,
    );
  }

  Future<NetworkPlaylistImportResult> _importQq(String input) async {
    final id = _extractId(input, const [
      r'/playlist/(\d+)',
      r'/playsquare/(\d+)',
      r'[?&](?:id|disstid)=(\d+)',
      r'^(\d+)$',
    ]);
    if (id == null) throw Exception('无法识别 QQ音乐歌单 ID');
    final body = await _getJson(
      Uri.https('c.y.qq.com', '/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg', {
        'type': '1',
        'json': '1',
        'utf8': '1',
        'onlysong': '0',
        'new_format': '1',
        'disstid': id,
        'loginUin': '0',
        'hostUin': '0',
        'format': 'json',
        'inCharset': 'utf8',
        'outCharset': 'utf-8',
        'notice': '0',
        'platform': 'yqq.json',
        'needNewCode': '0',
      }),
      referer: 'https://y.qq.com/n/ryqq/playlist/$id',
      origin: 'https://y.qq.com',
    );
    final lists = body['cdlist'];
    if (body['code'] != 0 ||
        lists is! List ||
        lists.isEmpty ||
        lists.first is! Map) {
      throw Exception('QQ音乐歌单获取失败（${body['code'] ?? '未知状态'}）');
    }
    final playlist = Map<String, dynamic>.from(lists.first as Map);
    final songs = <Song>[];
    for (final value in (playlist['songlist'] as List? ?? const [])) {
      if (value is! Map) continue;
      final song = _qqSong(Map<String, dynamic>.from(value));
      if (song != null) songs.add(song);
    }
    if (songs.isEmpty) throw Exception('QQ音乐歌单为空，或歌单不是公开歌单');
    return NetworkPlaylistImportResult(
      name: _cleanText(playlist['dissname']?.toString() ?? 'QQ音乐歌单'),
      coverUrl: _httpsUrl(playlist['logo']?.toString() ?? ''),
      songs: songs,
    );
  }

  Song? _qqSong(Map<String, dynamic> item) {
    final songMid = item['mid']?.toString() ?? '';
    final songId = item['id']?.toString() ?? '';
    if (songMid.isEmpty && songId.isEmpty) return null;
    final singers = item['singer'];
    final artist = _joinNames(singers);
    final albumValue = item['album'];
    final album = albumValue is Map
        ? Map<String, dynamic>.from(albumValue)
        : const <String, dynamic>{};
    final fileValue = item['file'];
    final file = fileValue is Map
        ? Map<String, dynamic>.from(fileValue)
        : const <String, dynamic>{};
    final title = _cleanText(item['title']?.toString() ?? '');
    final albumName = _cleanText(album['name']?.toString() ?? '');
    final albumMid = album['mid']?.toString() ?? '';
    final id = songMid.isEmpty ? songId : songMid;
    final raw = <String, dynamic>{
      'songmid': id,
      'songId': songId,
      'source': 'tx',
      'name': title,
      'singer': artist,
      'albumName': albumName,
      'albumId': album['id'],
      'albumMid': albumMid,
      'strMediaMid': file['media_mid']?.toString() ?? '',
    };
    final coverUrl = albumMid.isEmpty
        ? ''
        : 'https://y.gtimg.cn/music/photo_new/T002R500x500M000$albumMid.jpg';
    return _lxSong(
      source: 'tx',
      id: id,
      title: title,
      artist: artist,
      album: albumName,
      durationMs: _number(item['interval']) * 1000,
      coverUrl: coverUrl,
      raw: raw,
    );
  }

  Future<NetworkPlaylistImportResult> _importKuwo(String input) async {
    final id = _extractId(input, const [
      r'/playlists?(?:_detail)?/(\d+)',
      r'[?&]playlistId=(\d+)',
      r'^(\d+)$',
    ]);
    if (id == null) throw Exception('无法识别酷我歌单 ID');
    final body = await _getJson(
      Uri.https('nplserver.kuwo.cn', '/pl.svc', {
        'op': 'getlistinfo',
        'pid': id,
        'pn': '0',
        'rn': '1000',
        'encode': 'utf8',
        'keyset': 'pl2012',
        'identity': 'kuwo',
        'pcmp4': '1',
        'vipver': 'MUSIC_9.0.5.0_W1',
        'newver': '1',
      }),
    );
    if (body['result'] != 'ok') throw Exception('酷我歌单获取失败');
    final songs = <Song>[];
    for (final value in (body['musiclist'] as List? ?? const [])) {
      if (value is! Map) continue;
      final item = Map<String, dynamic>.from(value);
      final songId = item['id']?.toString() ?? '';
      if (songId.isEmpty) continue;
      final title = _cleanText(item['name']?.toString() ?? '');
      final artist = _cleanText(item['artist']?.toString() ?? '');
      final album = _cleanText(item['album']?.toString() ?? '');
      // 歌曲封面：pic 可能是完整 URL 也可能是短路径，统一走酷我归一化；
      // web_albumpic_short 一定是短路径（/120/xxx.jpg）。
      final songCover = _kuwoCoverUrl(
        item['pic']?.toString() ??
            item['web_albumpic_short']?.toString() ??
            item['albumpic_short']?.toString() ??
            '',
      );
      songs.add(
        _lxSong(
          source: 'kw',
          id: songId,
          title: title,
          artist: artist,
          album: album,
          durationMs: _number(item['duration']) * 1000,
          coverUrl: songCover,
          raw: {
            'songmid': songId,
            'source': 'kw',
            'name': title,
            'singer': artist,
            'albumName': album,
            'albumId': item['albumid'],
            'web_albumpic_short': item['web_albumpic_short'] ??
                item['albumpic_short'],
          },
        ),
      );
    }
    if (songs.isEmpty) throw Exception('酷我歌单为空，或歌单不是公开歌单');
    return NetworkPlaylistImportResult(
      name: _cleanText(body['title']?.toString() ?? '酷我歌单'),
      coverUrl: _kuwoCoverUrl(body['pic']?.toString() ?? ''),
      songs: songs,
    );
  }

  Future<NetworkPlaylistImportResult> _importKugou(String input) async {
    // 酷狗码：App/PC 分享出的数字码（如“酷狗码：8291145”，24 小时有效），
    // 通过 t.kugou.com 分享码服务解析。
    final kugouCode = RegExp(
      r'酷狗码[：:\s]*(\d{4,10})',
    ).firstMatch(input)?.group(1);
    if (kugouCode != null) {
      final id = await _resolveKugouShareCode(kugouCode);
      if (id == null) {
        throw Exception('酷狗码无效或已过期（酷狗码 24 小时内有效）');
      }
      return _fetchKugouSpecial(id);
    }

    // t.kugou.com / t1.kugou.com 短链
    final shortUrl = RegExp(
      r'https?://t\d?\.kugou\.com/[0-9a-zA-Z_-]+',
      caseSensitive: false,
    ).firstMatch(input)?.group(0);
    if (shortUrl != null) {
      final id = await _resolveKugouShareCode(shortUrl);
      if (id == null) {
        throw Exception('无法从酷狗短链解析歌单 ID');
      }
      return _fetchKugouSpecial(id);
    }

    var id = _extractId(input, const [
      r'/special/(?:single/)?(\d+)',
      r'/(\d+)\.html',
    ]);
    // App 分享的移动端链接形如 m.kugou.com/songlist/gcid_xxx，
    // 页面内嵌的 window.$output JSON 携带数字 specialid，取到后走通用导入。
    if (id == null) {
      final gcid = RegExp(
        r'gcid_([0-9a-zA-Z]+)',
        caseSensitive: false,
      ).firstMatch(input)?.group(1);
      if (gcid != null) {
        id = await _resolveKugouGcidSpecialId(gcid);
        if (id == null) {
          throw Exception('无法从酷狗分享链接解析歌单 ID');
        }
      }
    }
    final pureNumber = RegExp(r'^\d{4,10}$').hasMatch(input);
    if (id == null && pureNumber) id = input;
    if (id == null) throw Exception('无法识别酷狗歌单 ID');
    try {
      return await _fetchKugouSpecial(id);
    } catch (e) {
      // 纯数字输入也可能是酷狗码而非歌单 ID，按歌单 ID 获取失败时按码重试
      if (pureNumber) {
        final codeId = await _resolveKugouShareCode(input);
        if (codeId != null && codeId != id) {
          return _fetchKugouSpecial(codeId);
        }
      }
      rethrow;
    }
  }

  Future<NetworkPlaylistImportResult> _fetchKugouSpecial(String id) async {
    final response = await _client
        .get(
          Uri.parse(
            'http://www2.kugou.kugou.com/yueku/v9/special/single/$id-5-9999.html',
          ),
          headers: const {'User-Agent': _userAgent},
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('酷狗歌单获取失败（HTTP ${response.statusCode}）');
    }
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    final match = RegExp(
      r'global\.data\s*=\s*(\[.*?\]);',
      dotAll: true,
    ).firstMatch(text);
    if (match == null) throw Exception('酷狗歌单为空，或歌单不是公开歌单');
    // 页面内嵌 var global = {...} 携带歌单名称与封面
    final name = _cleanText(
      RegExp(
        r'name:\s*"([^"]*)"[^"\n]*//\s*精选集名字',
      ).firstMatch(text)?.group(1) ??
          '',
    );
    var coverUrl = RegExp(
      r'pic:\s*"(http[^"]*)"[^"\n]*//\s*歌单图片',
    ).firstMatch(text)?.group(1) ??
        '';
    // 240 为缩略图，替换为 480 高清尺寸
    if (coverUrl.contains('/240/')) {
      coverUrl = coverUrl.replaceFirst('/240/', '/480/');
    }
    final decoded = jsonDecode(match.group(1)!);
    final songs = <Song>[];
    if (decoded is List) {
      for (final value in decoded.whereType<Map>()) {
        final item = Map<String, dynamic>.from(value);
        final hash = item['hash']?.toString() ?? '';
        final audioId = item['audio_id']?.toString() ?? '';
        if (hash.isEmpty && audioId.isEmpty) continue;
        final songId = audioId.isEmpty ? hash : audioId;
        final title = _cleanText(item['songname']?.toString() ?? '');
        final artist = _cleanText(item['singername']?.toString() ?? '');
        final album = _cleanText(item['album_name']?.toString() ?? '');
        // 封面位于 trans_param.union_cover，{size} 占位符替换为 480
        final transParam = item['trans_param'];
        final rawCover = transParam is Map
            ? transParam['union_cover']?.toString() ?? ''
            : '';
        final songCover = rawCover.contains('{size}')
            ? rawCover.replaceFirst('{size}', '480')
            : rawCover;
        songs.add(
          _lxSong(
            source: 'kg',
            id: songId,
            title: title,
            artist: artist,
            album: album,
            durationMs: _number(item['duration']),
            coverUrl: songCover,
            raw: {
              'songmid': songId,
              'source': 'kg',
              'hash': hash,
              'name': title,
              'singer': artist,
              'albumName': album,
              'albumId': item['album_id'],
            },
          ),
        );
      }
    }
    if (songs.isEmpty) throw Exception('酷狗歌单为空，或歌单不是公开歌单');
    return NetworkPlaylistImportResult(
      name: name.isNotEmpty ? name : '酷狗歌单 $id',
      coverUrl: coverUrl,
      songs: songs,
    );
  }

  /// 解析酷狗码 / t.kugou.com 短链对应的数字歌单 ID（specialid）。
  ///
  /// 酷狗码通过 POST http://t.kugou.com/command/ 解析（参考 MusicFree 酷狗插件），
  /// 返回 data.info.id 即歌单 specialid；短链则通过 GET 后的重定向/返回内容解析。
  Future<String?> _resolveKugouShareCode(String code) async {
    try {
      if (!code.startsWith('http')) {
        // 纯数字/字母数字酷狗码：走 command 接口
        final response = await _client
            .post(
              Uri.parse('http://t.kugou.com/command/'),
              headers: const {
                'User-Agent': _userAgent,
                'Content-Type': 'application/json',
              },
              body: jsonEncode({
                'appid': 1001,
                'clientver': 9020,
                'mid': '21511157a05844bd085308bc76ef3343',
                'clienttime': 640612895,
                'key': '36164c4015e704673c588ee202b9ecb8',
                'data': code,
              }),
            )
            .timeout(const Duration(seconds: 15));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          return null;
        }
        final decoded = jsonDecode(response.body);
        if (decoded is! Map || decoded['status'] != 1) return null;
        final data = decoded['data'];
        final info = data is Map ? data['info'] : null;
        final id = info is Map ? info['id']?.toString() : null;
        if (id != null && RegExp(r'^[1-9]\d*$').hasMatch(id)) return id;
        // 兜底：在返回内容中递归查找歌单引用
        final ref = _findKugouPlaylistRef(decoded);
        if (ref != null) return await _kugouIdFromRef(ref);
        return null;
      }
      // t.kugou.com / t1.kugou.com 短链：GET 解析
      final response = await _client
          .get(
            Uri.parse(code),
            headers: const {'User-Agent': _userAgent},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final text = response.body.trim();
      dynamic decoded;
      if (text.startsWith('{') || text.startsWith('[')) {
        decoded = jsonDecode(text);
      }
      final ref =
          _findKugouPlaylistRef(decoded) ??
          // 若发生了重定向，最终地址本身可能就是歌单链接
          _findKugouPlaylistRef(response.request?.url.toString());
      if (ref == null) return null;
      return await _kugouIdFromRef(ref);
    } catch (_) {
      return null;
    }
  }

  /// 在分享码解析结果中递归查找歌单引用（specialid 或歌单链接）。
  static String? _findKugouPlaylistRef(dynamic node) {
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key.toString().toLowerCase();
        final value = entry.value;
        if (value == null) continue;
        if (key == 'specialid' &&
            RegExp(r'^[1-9]\d*$').hasMatch(value.toString())) {
          return value.toString();
        }
        if ((key == 'url' || key == 'link' || key == 'share_url') &&
            value.toString().contains('kugou.com')) {
          return value.toString();
        }
        final nested = _findKugouPlaylistRef(value);
        if (nested != null) return nested;
      }
    } else if (node is List) {
      for (final value in node) {
        final nested = _findKugouPlaylistRef(value);
        if (nested != null) return nested;
      }
    } else if (node is String && node.contains('kugou.com')) {
      return node;
    }
    return null;
  }

  /// 从歌单引用（ID / 链接 / gcid）解析出数字 specialid。
  Future<String?> _kugouIdFromRef(String ref) async {
    final gcid = RegExp(
      r'gcid_([0-9a-zA-Z]+)',
      caseSensitive: false,
    ).firstMatch(ref)?.group(1);
    if (gcid != null) return _resolveKugouGcidSpecialId(gcid);
    return _extractId(ref, const [
      r'/special/(?:single/)?(\d+)',
      r'/(\d+)\.html',
      r'^(\d+)$',
    ]);
  }

  Future<String?> _resolveKugouGcidSpecialId(String gcid) async {
    try {
      final response = await _client
          .get(
            Uri.parse('https://m.kugou.com/songlist/gcid_$gcid/'),
            headers: const {'User-Agent': _userAgent},
          )
          .timeout(const Duration(seconds: 25));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final html = utf8.decode(response.bodyBytes, allowMalformed: true);
      final match = RegExp(
        r'window\.\$output\s*=\s*(\{.*?\})\s*[;<]',
        dotAll: true,
      ).firstMatch(html);
      if (match == null) return null;
      final decoded = jsonDecode(match.group(1)!);
      final info = decoded is Map ? decoded['info'] : null;
      final listinfo = info is Map ? info['listinfo'] : null;
      final specialId = listinfo is Map ? listinfo['specialid'] : null;
      final value = specialId?.toString().trim() ?? '';
      return RegExp(r'^\d+$').hasMatch(value) ? value : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _getJson(
    Uri uri, {
    String? referer,
    String? origin,
  }) async {
    final response = await _client
        .get(
          uri,
          headers: {
            'User-Agent': _userAgent,
            'Referer': ?referer,
            'Origin': ?origin,
          },
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('网络请求失败（HTTP ${response.statusCode}）');
    }
    final value = jsonDecode(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    );
    if (value is! Map) throw Exception('歌单接口返回格式无效');
    return Map<String, dynamic>.from(value);
  }

  static Song _lxSong({
    required String source,
    required String id,
    required String title,
    required String artist,
    required String album,
    required int durationMs,
    required String coverUrl,
    required Map<String, dynamic> raw,
  }) => Song(
    path: 'lx://$source/${Uri.encodeComponent(id)}',
    title: title,
    artist: artist,
    album: album,
    albumKey: album,
    duration: (durationMs / 1000).round(),
    format: '网络',
    coverUrl: coverUrl,
    pluginData: {'lx': raw},
  );

  static String? _extractId(String input, List<String> patterns) {
    for (final pattern in patterns) {
      final match = RegExp(pattern, caseSensitive: false).firstMatch(input);
      if (match != null) return match.group(1);
    }
    return null;
  }

  static String? _sourceFromUrl(String input) {
    final lower = input.toLowerCase();
    if (lower.contains('music.163.com') || lower.contains('163cn.tv')) {
      return 'wy';
    }
    if (lower.contains('y.qq.com') || lower.contains('c.y.qq.com')) {
      return 'tx';
    }
    if (lower.contains('kuwo.cn')) return 'kw';
    if (lower.contains('kugou.com')) return 'kg';
    return null;
  }

  static String _joinNames(dynamic value) {
    if (value is! List) return '';
    return value
        .map((item) => item is Map ? item['name'] : item)
        .where((item) => item != null && item.toString().trim().isNotEmpty)
        .map((item) => _cleanText(item.toString()))
        .join('/');
  }

  static int _number(dynamic value) => value is num
      ? value.toInt()
      : (double.tryParse(value?.toString() ?? '') ?? 0).round();

  static String _cleanText(String value) => value
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .trim();

  static String _httpsUrl(String value) {
    final url = value.trim();
    if (url.startsWith('//')) return 'https:$url';
    if (url.startsWith('http://')) return 'https://${url.substring(7)}';
    return url.startsWith('https://') ? url : '';
  }

  /// 归一化酷我封面地址。
  ///
  /// 酷我接口（pl.svc 歌单详情 / 歌曲条目）返回的封面多为**短路径**
  /// （如 `/120/albumcover/xxx.jpg` 或 `120/xxx.jpg`），不是完整 URL，
  /// 需拼上 `https://img3.kuwo.cn/star/albumcover/` 前缀并把开头的
  /// 尺寸段替换为高清尺寸（与 rust 侧 build_kuwo_cover_url 规则一致）。
  /// 完整 http(s) URL 则直接升级为 https 返回。
  static String _kuwoCoverUrl(String value, {int size = 480}) {
    final url = value.trim();
    if (url.isEmpty) return '';
    if (url.startsWith('//') ||
        url.startsWith('http://') ||
        url.startsWith('https://')) {
      return _httpsUrl(url);
    }
    // 短路径：去掉开头的 /，把尺寸段（如 120/）替换为目标尺寸
    var short = url.startsWith('/') ? url.substring(1) : url;
    short = short.replaceFirst(RegExp(r'^\d+/'), '$size/');
    return 'https://img3.kuwo.cn/star/albumcover/$short';
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
