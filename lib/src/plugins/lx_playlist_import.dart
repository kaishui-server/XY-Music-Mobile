import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 洛雪音源 ID 列表（与 lx-music-mobile 一致）。
const kLxSourceIds = ['kw', 'kg', 'tx', 'wy', 'mg'];

/// 洛雪音源 ID → 展示名。
String lxSourceLabel(String source) => switch (source) {
  'kw' => '酷我',
  'kg' => '酷狗',
  'tx' => 'QQ音乐',
  'wy' => '网易云',
  'mg' => '咪咕',
  _ => source.toUpperCase(),
};

class LxPlaylistImportResult {
  const LxPlaylistImportResult({
    required this.name,
    required this.coverUrl,
    required this.songs,
  });

  final String name;
  final String coverUrl;
  final List<Map<String, dynamic>> songs;
}

/// 从用户输入的链接域名识别洛雪音源；纯 ID 返回 null。
String? detectLxSourceFromInput(String input) {
  final lower = input.toLowerCase();
  if (lower.contains('y.qq.com')) return 'tx';
  if (lower.contains('163.com')) return 'wy';
  if (lower.contains('kuwo.cn')) return 'kw';
  if (lower.contains('kugou.com')) return 'kg';
  if (lower.contains('migu.cn')) return 'mg';
  return null;
}

/// 洛雪歌单网络导入。
///
/// 参考 lx-music-mobile 的 songList 设计，直连五个平台的公开歌单详情
/// 接口，不经过 QuickJS 插件运行时。歌曲归一化为与洛雪搜索一致的
/// raw 结构（含 `lx` 元数据和 `lx://` 虚拟路径），播放、歌词与音质
/// 解析继续走现有洛雪管线。
///
/// [source] 是下拉框选中的音源；当 [idOrUrl] 是分享链接且域名指向
/// 其他平台时自动切换到链接对应的音源（对齐 lx-music 的链接识别）。
Future<LxPlaylistImportResult> importLxPlaylist({
  required String source,
  required String idOrUrl,
  http.Client? client,
}) async {
  final input = idOrUrl.trim();
  if (input.isEmpty) throw Exception('请输入歌单 ID');
  if (!kLxSourceIds.contains(source)) throw Exception('不支持的洛雪音源：$source');
  final detected = detectLxSourceFromInput(input);
  final effectiveSource = detected ?? source;
  final ownsClient = client == null;
  final httpClient = client ?? http.Client();
  try {
    return switch (effectiveSource) {
      'kw' => await _importKw(httpClient, input),
      'kg' => await _importKg(httpClient, input),
      'tx' => await _importTx(httpClient, input),
      'wy' => await _importWy(httpClient, input),
      'mg' => await _importMg(httpClient, input),
      _ => throw Exception('不支持的洛雪音源：$effectiveSource'),
    };
  } finally {
    if (ownsClient) httpClient.close();
  }
}

const _timeout = Duration(seconds: 20);

/// 单个歌单最多导入的歌曲数，防止异常响应导致无限分页。
const _maxImportSongs = 20000;

const _browserHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
};

const _phoneHeaders = {
  'User-Agent':
      'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 '
      'Safari/604.1',
};

dynamic _decodeBody(http.Response response) {
  var body = utf8.decode(response.bodyBytes, allowMalformed: true);
  // 与 PluginRuntimeService._decodeResponseBody 一致：后台 isolate 注入的
  // HTTP 客户端会把响应体包装为 Base64，解析前剥离包装。
  const prefix = '__XY_HTTP_BODY_BASE64__';
  if (body.startsWith(prefix)) {
    try {
      body = utf8.decode(
        base64Decode(body.substring(prefix.length)),
        allowMalformed: true,
      );
    } catch (_) {}
  }
  return jsonDecode(body);
}

Future<dynamic> _getJson(
  http.Client client,
  Uri uri, {
  Map<String, String> headers = _browserHeaders,
}) async {
  final response = await client.get(uri, headers: headers).timeout(_timeout);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception('接口返回 HTTP ${response.statusCode}');
  }
  return _decodeBody(response);
}

Future<dynamic> _postForm(
  http.Client client,
  Uri uri,
  Map<String, String> fields, {
  Map<String, String> headers = _browserHeaders,
}) async {
  final response = await client
      .post(uri, headers: headers, body: fields)
      .timeout(_timeout);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception('接口返回 HTTP ${response.statusCode}');
  }
  return _decodeBody(response);
}

Future<dynamic> _postJson(
  http.Client client,
  Uri uri,
  Map<String, dynamic> body, {
  Map<String, String> headers = _browserHeaders,
}) async {
  final response = await client
      .post(
        uri,
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      )
      .timeout(_timeout);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception('接口返回 HTTP ${response.statusCode}');
  }
  return _decodeBody(response);
}

/// 输入是纯 ID 时直接返回；否则依次尝试链接正则提取歌单 ID。
String _playlistIdFromInput(String input, List<RegExp> patterns) {
  final trimmed = input.trim();
  if (!RegExp(r'[?&:/]').hasMatch(trimmed)) return trimmed;
  for (final pattern in patterns) {
    final match = pattern.firstMatch(trimmed);
    if (match?.group(1) != null) return match!.group(1)!;
  }
  throw Exception('无法从链接中解析歌单 ID');
}

String _text(dynamic value) => value?.toString().trim() ?? '';

int _toInt(dynamic value, [int fallback = 0]) {
  if (value is num) return value.toInt();
  return int.tryParse(_text(value)) ?? fallback;
}

String _formatPlayTime(int seconds) {
  if (seconds <= 0) return '00:00';
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

String _sizeFormate(dynamic bytes) {
  final value = bytes is num
      ? bytes.toDouble()
      : double.tryParse(_text(bytes)) ?? 0;
  if (value <= 0) return '';
  const mb = 1024 * 1024;
  if (value >= 1024 * mb) return '${(value / (1024 * mb)).toStringAsFixed(2)}G';
  if (value >= mb) return '${(value / mb).toStringAsFixed(2)}M';
  if (value >= 1024) return '${(value / 1024).toStringAsFixed(2)}KB';
  return value.toInt().toString();
}

String _normalizeCover(String value) {
  var cover = value.trim();
  if (cover.startsWith('//')) cover = 'https:$cover';
  if (cover.startsWith('/')) return '';
  return cover.startsWith('http') ? cover : '';
}

/// 构造与洛雪搜索结果一致的 raw 歌曲结构。
Map<String, dynamic> _lxSong({
  required String source,
  required String songmid,
  required String name,
  required String singer,
  required String album,
  required int durationSec,
  dynamic albumId,
  dynamic hash,
  dynamic strMediaMid,
  dynamic songId,
  dynamic albumMid,
  dynamic copyrightId,
  String img = '',
  Map<String, dynamic>? types,
}) {
  final interval = _formatPlayTime(durationSec);
  return {
    'id': songmid,
    'title': name,
    'artist': singer,
    'album': album,
    if (durationSec > 0) 'duration': durationSec,
    if (img.isNotEmpty) 'artwork': img,
    'lx': <String, dynamic>{
      'songmid': songmid,
      'source': source,
      if (hash != null && _text(hash).isNotEmpty) 'hash': hash,
      'name': name,
      'singer': singer,
      'albumName': album,
      'albumId': albumId,
      if (strMediaMid != null && _text(strMediaMid).isNotEmpty)
        'strMediaMid': strMediaMid,
      'songId': songId,
      if (albumMid != null && _text(albumMid).isNotEmpty) 'albumMid': albumMid,
      if (copyrightId != null && _text(copyrightId).isNotEmpty)
        'copyrightId': copyrightId,
      'interval': interval,
      if (durationSec > 0) '_interval': durationSec * 1000,
      if (types != null && types.isNotEmpty) '_types': types,
    },
    '_sourcePath': 'lx://$source/${Uri.encodeComponent(songmid)}',
  };
}

// ---------------------------------------------------------------------------
// 酷我：nplserver 歌单接口分页返回，N_MINFO 描述音质。
// http://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=..&pn=0&rn=1000&...
// ---------------------------------------------------------------------------

Future<LxPlaylistImportResult> _importKw(http.Client client, String input) async {
  final id = _playlistIdFromInput(input, [
    RegExp(r'/playlist(?:_detail)?/(\d+)'),
    RegExp(r'[?&]pid=(\d+)'),
  ]);
  const rn = 1000;
  final songs = <Map<String, dynamic>>[];
  final seen = <String>{};
  var name = '';
  var cover = '';
  for (var page = 0; page < 50; page++) {
    final body = await _getJson(
      client,
      Uri.parse(
        'http://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=$id'
        '&pn=$page&rn=$rn&encode=utf8&keyset=pl2012&identity=kuwo'
        '&pcmp4=1&vipver=MUSIC_9.0.5.0_W1&newver=1',
      ),
    );
    if (body is! Map || body['result'] != 'ok') {
      throw Exception('酷我歌单加载失败，请检查歌单 ID 或链接');
    }
    if (name.isEmpty) name = _text(body['title']);
    if (cover.isEmpty) cover = _normalizeCover(_text(body['pic']));
    final musiclist = body['musiclist'];
    if (musiclist is! List) break;
    var added = 0;
    for (final value in musiclist.whereType<Map>()) {
      final item = Map<String, dynamic>.from(value);
      final songmid = _text(item['id']);
      final title = _text(item['name']);
      if (songmid.isEmpty || title.isEmpty) continue;
      if (!seen.add('kw/$songmid')) continue;
      final durationSec = _toInt(item['duration']);
      songs.add(
        _lxSong(
          source: 'kw',
          songmid: songmid,
          name: title,
          singer: _text(item['artist']),
          album: _text(item['album']),
          albumId: _text(item['albumid']),
          durationSec: durationSec,
          types: _kwTypes(_text(item['N_MINFO'])),
        ),
      );
      added++;
    }
    if (songs.length >= _maxImportSongs) break;
    if (added < rn) break;
  }
  if (songs.isEmpty) throw Exception('酷我歌单为空或歌单不存在');
  return LxPlaylistImportResult(
    name: name.isEmpty ? '酷我歌单' : name,
    coverUrl: cover,
    songs: songs,
  );
}

/// `level:p,bitrate:300,format:ogg,size:7.72Mb;...` → {320k: {size}}。
Map<String, dynamic> _kwTypes(String mInfo) {
  if (mInfo.isEmpty) return const {};
  final types = <String, dynamic>{};
  final pattern = RegExp(r'level:(\w+),bitrate:(\d+),format:(\w+),size:([\w.]+)');
  for (final entry in mInfo.split(';')) {
    final match = pattern.firstMatch(entry);
    if (match == null) continue;
    final bitrate = match.group(2)!;
    final size = (match.group(4) ?? '').toUpperCase();
    final key = switch (bitrate) {
      '4000' => 'flac24bit',
      '2000' => 'flac',
      '320' => '320k',
      '192' => '192k',
      '128' => '128k',
      _ => null,
    };
    if (key != null) types[key] = {'size': size};
  }
  return types;
}

// ---------------------------------------------------------------------------
// 酷狗：歌单详情是 HTML 内嵌 global.data（hash 列表），歌曲信息通过
// gateway 批量接口补全（对齐 lx-music-mobile kg/songList.js）。
// ---------------------------------------------------------------------------

Future<LxPlaylistImportResult> _importKg(http.Client client, String input) async {
  final id = _playlistIdFromInput(input, [RegExp(r'/(\d+)\.html')]);
  final response = await client
      .get(
        Uri.parse(
          'http://www2.kugou.kugou.com/yueku/v9/special/single/$id-5-9999.html',
        ),
        headers: _browserHeaders,
      )
      .timeout(_timeout);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception('酷狗歌单页加载失败，请检查歌单 ID 或链接');
  }
  final html = utf8.decode(response.bodyBytes, allowMalformed: true);
  final dataMatch = RegExp(r'global\.data = (\[.+?\]);').firstMatch(html);
  if (dataMatch == null) {
    throw Exception('酷狗歌单不存在或已失效');
  }
  final List<dynamic> hashItems;
  try {
    hashItems = jsonDecode(dataMatch.group(1)!) as List<dynamic>;
  } catch (_) {
    throw Exception('酷狗歌单数据解析失败');
  }
  var name = '';
  var cover = '';
  final infoMatch = RegExp(
    r'global = \{[\s\S]+?name: "(.+?)"[\s\S]+?pic: "(.+?)"[\s\S]+?\};',
  ).firstMatch(html);
  if (infoMatch != null) {
    name = _decodeJsName(infoMatch.group(1) ?? '');
    cover = _normalizeCover(infoMatch.group(2) ?? '');
  }

  // 去重后的 hash 列表。
  final hashes = <String>[];
  final seenHash = <String>{};
  for (final value in hashItems.whereType<Map>()) {
    final hash = _text(value['hash']).toUpperCase();
    if (hash.isNotEmpty && seenHash.add(hash)) hashes.add(hash);
  }
  if (hashes.isEmpty) throw Exception('酷狗歌单为空');

  final songs = <Map<String, dynamic>>[];
  for (var index = 0; index < hashes.length; index += 100) {
    final batch = hashes.skip(index).take(100).toList();
    final body = await _postJson(
      client,
      Uri.parse('http://gateway.kugou.com/v2/album_audio/audio'),
      {
        'area_code': '1',
        'show_privilege': 1,
        'show_album_info': '1',
        'is_publish': '',
        'appid': 1005,
        'clientver': 11451,
        'mid': '1',
        'dfid': '-',
        'clienttime': DateTime.now().millisecondsSinceEpoch,
        'key': 'OIlwieks28dk2k092lksi2UIkp',
        'fields': 'album_info,author_name,audio_info,ori_audio_name,base,songname',
        'data': [for (final hash in batch) {'hash': hash}],
      },
      headers: const {
        'KG-THash': '13a3164',
        'KG-RC': '1',
        'KG-Fake': '0',
        'KG-RF': '00869891',
        'User-Agent':
            'Android712-AndroidPhone-11451-376-0-FeeCacheUpdate-wifi',
        'x-router': 'kmr.service.kugou.com',
      },
    );
    if (body is! Map ||
        _toInt(body['error_code'], -1) != 0 ||
        body['data'] is! List) {
      continue; // 单批失败不阻断整个歌单。
    }
    for (final value in (body['data'] as List).whereType<List>()) {
      if (value.isEmpty || value.first is! Map) continue;
      final item = Map<String, dynamic>.from(value.first as Map);
      final audio = item['audio_info'] is Map
          ? Map<String, dynamic>.from(item['audioInfo'] ?? item['audio_info'] as Map)
          : const <String, dynamic>{};
      final albumInfo = item['album_info'] is Map
          ? Map<String, dynamic>.from(item['album_info'] as Map)
          : const <String, dynamic>{};
      final hash = _text(audio['hash']).toUpperCase();
      final title = _decodeJsName(_text(item['songname']));
      if (hash.isEmpty || title.isEmpty) continue;
      final durationSec = (_toInt(audio['timelength']) / 1000).round();
      final transParam = audio['trans_param'] is Map
          ? Map<String, dynamic>.from(audio['trans_param'] as Map)
          : const <String, dynamic>{};
      final cover = _normalizeCover(
        _text(transParam['union_cover']).replaceAll('{size}', '400'),
      );
      songs.add(
        _lxSong(
          source: 'kg',
          songmid: hash,
          hash: hash,
          name: title,
          singer: _decodeJsName(_text(item['author_name'])),
          album: _decodeJsName(_text(albumInfo['album_name'])),
          albumId: _text(albumInfo['album_id']),
          durationSec: durationSec,
          img: cover,
          types: _kgTypes(audio),
        ),
      );
      if (songs.length >= _maxImportSongs) break;
    }
    if (songs.length >= _maxImportSongs) break;
  }
  if (songs.isEmpty) throw Exception('酷狗歌单歌曲信息获取失败');
  return LxPlaylistImportResult(
    name: name.isEmpty ? '酷狗歌单' : name,
    coverUrl: cover,
    songs: songs,
  );
}

/// JS 字符串字面量中的 \\uXXXX 与 \x 转义解码。
String _decodeJsName(String value) {
  if (!value.contains(r'\\')) return value;
  return value
      .replaceAllMapped(RegExp(r'\\u([0-9a-fA-F]{4})'), (match) {
        final code = int.tryParse(match.group(1)!, radix: 16);
        return code == null ? match.group(0)! : String.fromCharCode(code);
      })
      .replaceAll(r'\\', r'\');
}

Map<String, dynamic> _kgTypes(Map<String, dynamic> audio) {
  final types = <String, dynamic>{};
  void add(String key, String hashKey, String sizeKey) {
    final hash = _text(audio[hashKey]);
    if (hash.isEmpty) return;
    types[key] = {'size': _sizeFormate(audio[sizeKey]), 'hash': hash};
  }

  add('128k', 'hash_128', 'filesize_128');
  add('320k', 'hash_320', 'filesize_320');
  add('flac', 'hash_flac', 'filesize_flac');
  return types;
}

// ---------------------------------------------------------------------------
// QQ音乐：fcg 接口一次返回全部歌曲（对齐 lx-music-mobile tx/songList.js）。
// ---------------------------------------------------------------------------

Future<LxPlaylistImportResult> _importTx(http.Client client, String input) async {
  final id = _playlistIdFromInput(input, [
    RegExp(r'/playlist/(\d+)'),
    RegExp(r'[?&]id=(\d+)'),
    RegExp(r'dissid=(\d+)'),
  ]);
  final body = await _getJson(
    client,
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
      'outCharset': 'utf8',
      'notice': '0',
      'platform': 'yqq.json',
      'needNewCode': '0',
    }),
    headers: {
      ..._browserHeaders,
      'Origin': 'https://y.qq.com',
      'Referer': 'https://y.qq.com/n/yqq/playsquare/$id.html',
    },
  );
  if (body is! Map || _toInt(body['code'], -1) != 0 || body['cdlist'] is! List) {
    throw Exception('QQ音乐歌单加载失败，请检查歌单 ID 或链接');
  }
  final cdlist = body['cdlist'] as List;
  if (cdlist.isEmpty || cdlist.first is! Map) {
    throw Exception('QQ音乐歌单不存在');
  }
  final cd = Map<String, dynamic>.from(cdlist.first as Map);
  final songlist = cd['songlist'];
  final songs = <Map<String, dynamic>>[];
  final seen = <String>{};
  if (songlist is List) {
    for (final value in songlist.whereType<Map>()) {
      final item = Map<String, dynamic>.from(value);
      final songmid = _text(item['mid']);
      final title = _text(item['title']);
      if (songmid.isEmpty || title.isEmpty) continue;
      if (!seen.add('tx/$songmid')) continue;
      final singers = (item['singer'] is List ? item['singer'] as List : const [])
          .whereType<Map>()
          .map((singer) => _text(singer['name']))
          .where((name) => name.isNotEmpty)
          .join('、');
      final album = item['album'] is Map
          ? Map<String, dynamic>.from(item['album'] as Map)
          : const <String, dynamic>{};
      final albumMid = _text(album['mid']);
      final artwork = albumMid.isNotEmpty
          ? 'https://y.gtimg.cn/music/photo_new/T002R500x500M000$albumMid.jpg'
          : '';
      final file = item['file'] is Map
          ? Map<String, dynamic>.from(item['file'] as Map)
          : const <String, dynamic>{};
      songs.add(
        _lxSong(
          source: 'tx',
          songmid: songmid,
          name: title,
          singer: singers,
          album: _text(album['name']),
          albumId: albumMid,
          strMediaMid: _text(file['media_mid']),
          songId: item['id'],
          albumMid: albumMid,
          durationSec: _toInt(item['interval']),
          img: artwork,
          types: _txTypes(file),
        ),
      );
    }
  }
  if (songs.isEmpty) throw Exception('QQ音乐歌单为空或歌单不存在');
  return LxPlaylistImportResult(
    name: _text(cd['dissname']),
    coverUrl: _normalizeCover(_text(cd['logo'])),
    songs: songs,
  );
}

Map<String, dynamic> _txTypes(Map<String, dynamic> file) {
  final types = <String, dynamic>{};
  void add(String key, String sizeKey) {
    final size = _toInt(file[sizeKey]);
    if (size <= 0) return;
    types[key] = {'size': _sizeFormate(size)};
  }

  add('128k', 'size_128mp3');
  add('320k', 'size_320mp3');
  add('flac', 'size_flac');
  add('flac24bit', 'size_hires');
  return types;
}

// ---------------------------------------------------------------------------
// 网易云：/api/v3/playlist/detail 明文表单请求；超大歌单通过
// /api/v3/song/detail 批量补全缺失曲目。
// ---------------------------------------------------------------------------

Future<LxPlaylistImportResult> _importWy(http.Client client, String input) async {
  final id = _playlistIdFromInput(input, [
    RegExp(r'[?&]id=(\d+)'),
    RegExp(r'/playlist/(\d+)'),
  ]);
  final body = await _postForm(
    client,
    Uri.https('music.163.com', '/api/v3/playlist/detail'),
    {'id': id, 'n': '10000', 's': '0'},
    headers: {
      ..._browserHeaders,
      'Referer': 'https://music.163.com/',
      'Cookie': 'os=pc',
    },
  );
  if (body is! Map || _toInt(body['code'], -1) != 200 || body['playlist'] is! Map) {
    throw Exception('网易云歌单加载失败，请检查歌单 ID 或链接');
  }
  final playlist = Map<String, dynamic>.from(body['playlist'] as Map);
  final tracks = playlist['tracks'] is List ? playlist['tracks'] as List : const [];
  final trackIds = playlist['trackIds'] is List
      ? (playlist['trackIds'] as List)
            .whereType<Map>()
            .map((item) => _text(item['id']))
            .where((value) => value.isNotEmpty)
            .toList()
      : const <String>[];

  final songs = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final value in tracks.whereType<Map>()) {
    final song = _wySong(Map<String, dynamic>.from(value));
    if (song == null) continue;
    if (seen.add(song['id'].toString())) songs.add(song);
    if (songs.length >= _maxImportSongs) break;
  }

  // tracks 数量少于 trackIds 时（超大歌单），用歌曲详情接口补齐。
  if (trackIds.length > songs.length && songs.length < _maxImportSongs) {
    final known = songs.map((song) => song['id'].toString()).toSet();
    final missing = trackIds
        .where((trackId) => !known.contains(trackId))
        .take(_maxImportSongs - songs.length)
        .toList();
    for (var index = 0; index < missing.length; index += 100) {
      final batch = missing.skip(index).take(100).toList();
      try {
        final detail = await _getJson(
          client,
          Uri.https('music.163.com', '/api/v3/song/detail', {
            'c': jsonEncode([for (final trackId in batch) {'id': trackId}]),
          }),
          headers: {
            ..._browserHeaders,
            'Referer': 'https://music.163.com/',
            'Cookie': 'os=pc',
          },
        );
        final detailSongs = detail is Map ? detail['songs'] : null;
        if (detailSongs is! List) continue;
        for (final value in detailSongs.whereType<Map>()) {
          final song = _wySong(Map<String, dynamic>.from(value));
          if (song == null) continue;
          if (seen.add(song['id'].toString())) songs.add(song);
        }
      } catch (_) {
        // 补齐失败时保留已获取的部分。
      }
    }
  }

  if (songs.isEmpty) throw Exception('网易云歌单为空或歌单不存在');
  final cover = _normalizeCover(_text(playlist['coverImgUrl']));
  return LxPlaylistImportResult(
    name: _text(playlist['name']),
    coverUrl: cover,
    songs: songs,
  );
}

Map<String, dynamic>? _wySong(Map<String, dynamic> item) {
  final songmid = _text(item['id']);
  final title = _text(item['name']);
  if (songmid.isEmpty || title.isEmpty) return null;
  final artists = (item['ar'] is List ? item['ar'] as List : const [])
      .whereType<Map>()
      .map((artist) => _text(artist['name']))
      .where((name) => name.isNotEmpty)
      .join('、');
  final album = item['al'] is Map
      ? Map<String, dynamic>.from(item['al'] as Map)
      : const <String, dynamic>{};
  final durationSec = (_toInt(item['dt']) / 1000).round();
  return _lxSong(
    source: 'wy',
    songmid: songmid,
    name: title,
    singer: artists,
    album: _text(album['name']),
    albumId: album['id'],
    durationSec: durationSec,
    img: _normalizeCover(_text(album['picUrl'])),
    types: _wyTypes(item),
  );
}

Map<String, dynamic> _wyTypes(Map<String, dynamic> item) {
  final types = <String, dynamic>{};
  void add(String key, String field) {
    final node = item[field];
    if (node is Map) {
      final size = _toInt(node['size']);
      if (size > 0) types[key] = {'size': _sizeFormate(size)};
    }
  }

  add('128k', 'l');
  add('192k', 'm');
  add('320k', 'h');
  add('flac', 'sq');
  add('flac24bit', 'hr');
  return types;
}

// ---------------------------------------------------------------------------
// 咪咕：MIGUM3.0 歌单歌曲接口分页返回（对齐 lx-music-mobile mg/songList.js，
// 2025-11 #913 修复后的接口）。
// ---------------------------------------------------------------------------

Future<LxPlaylistImportResult> _importMg(http.Client client, String input) async {
  final id = _playlistIdFromInput(input, [
    RegExp(r'(?:playlistId|id)=(\d+)'),
    RegExp(r'/playlist/(\d+)'),
  ]);
  const pageSize = 30;
  final songs = <Map<String, dynamic>>[];
  final seen = <String>{};
  var total = 0;
  for (var page = 1; page <= 400; page++) {
    final body = await _getJson(
      client,
      Uri.parse(
        'https://app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0'
        '?pageNo=$page&pageSize=$pageSize&playlistId=$id',
      ),
      headers: {..._phoneHeaders, 'Referer': 'https://music.migu.cn/v3/music/player'},
    );
    if (body is! Map || _text(body['code']) != '000000') {
      throw Exception('咪咕歌单加载失败，请检查歌单 ID 或链接');
    }
    final data = body['data'] is Map
        ? Map<String, dynamic>.from(body['data'] as Map)
        : const <String, dynamic>{};
    if (total <= 0) total = _toInt(data['totalCount']);
    final songList = data['songList'] is List ? data['songList'] as List : const [];
    if (songList.isEmpty) break;
    for (final value in songList.whereType<Map>()) {
      final item = Map<String, dynamic>.from(value);
      final songmid = _text(item['songId']);
      final title = _text(item['songName']);
      if (songmid.isEmpty || title.isEmpty) continue;
      if (!seen.add('mg/$songmid')) continue;
      final singers = (item['singerList'] is List
              ? item['singerList'] as List
              : const [])
          .whereType<Map>()
          .map((singer) => _text(singer['name']))
          .where((name) => name.isNotEmpty)
          .join('、');
      songs.add(
        _lxSong(
          source: 'mg',
          songmid: songmid,
          name: title,
          singer: singers,
          album: _text(item['album']),
          albumId: _text(item['albumId']),
          copyrightId: _text(item['copyrightId']),
          durationSec: _toInt(item['duration']),
          types: _mgTypes(item['audioFormats']),
        ),
      );
    }
    if (songs.length >= _maxImportSongs) break;
    if (total > 0 && songs.length >= total) break;
    if (songList.length < pageSize) break;
  }
  if (songs.isEmpty) throw Exception('咪咕歌单为空或歌单不存在');
  return LxPlaylistImportResult(name: '咪咕歌单', coverUrl: '', songs: songs);
}

Map<String, dynamic> _mgTypes(dynamic audioFormats) {
  if (audioFormats is! List) return const {};
  final types = <String, dynamic>{};
  for (final value in audioFormats.whereType<Map>()) {
    final item = Map<String, dynamic>.from(value);
    final key = switch (_text(item['formatType'])) {
      'PQ' => '128k',
      'HQ' => '320k',
      'SQ' => 'flac',
      'ZQ' => 'flac24bit',
      _ => null,
    };
    if (key == null) continue;
    final size = _sizeFormate(item['isize'] ?? item['asize']);
    types[key] = {'size': size};
  }
  return types;
}

// ---------------------------------------------------------------------------
// 洛雪歌单本地文件导入：兼容 lx-music 的 my-list 备份 JSON。
//
// 支持两种结构：
//   1. 单个歌单导出：{ "info": {...}, "list": [song, ...] }
//   2. 全部列表备份：{ "list": [{ "info": {...}, "list": [...] }, ...],
//                      "defaultList": {...}, "loveList": {...} }
// 歌曲条目是洛雪 SongInfo 结构（songmid/source/name/singer/interval...），
// 归一化为与洛雪搜索一致的 raw 结构（含 `lx` 元数据与 `lx://` 虚拟路径）。
// ---------------------------------------------------------------------------

class LxLocalPlaylist {
  const LxLocalPlaylist({required this.name, required this.songs});

  final String name;

  /// 归一化后的 raw 歌曲结构，与 `importLxPlaylist` 返回的一致。
  final List<Map<String, dynamic>> songs;
}

/// 解析洛雪本地歌单导出文件；不是洛雪格式时返回 null。
List<LxLocalPlaylist> tryParseLxLocalPlaylists(String content) {
  final trimmed = content.trim();
  if (!trimmed.startsWith('{')) return const [];
  final Object decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return const [];
  }
  if (decoded is! Map) return const [];

  // 备份多歌单（含默认列表/收藏列表）与单歌单导出统一收集。
  final entries = <Map<String, dynamic>>[];
  final list = decoded['list'];
  if (list is List) {
    for (final value in list) {
      if (value is Map && value['list'] is List) {
        entries.add(Map<String, dynamic>.from(value));
      }
    }
  }
  for (final key in const ['defaultList', 'loveList']) {
    final node = decoded[key];
    if (node is Map && node['list'] is List) {
      entries.add(Map<String, dynamic>.from(node));
    }
  }
  if (entries.isEmpty) {
    if (decoded['info'] is Map && list is List) {
      entries.add(Map<String, dynamic>.from(decoded));
    } else {
      return const [];
    }
  }

  final playlists = <LxLocalPlaylist>[];
  for (final entry in entries) {
    final info = entry['info'] is Map
        ? Map<String, dynamic>.from(entry['info'] as Map)
        : const <String, dynamic>{};
    var name = _text(info['name']);
    if (name.isEmpty) name = '洛雪歌单';
    final rawSongs = entry['list'];
    if (rawSongs is! List) continue;
    final songs = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final value in rawSongs.whereType<Map>()) {
      final raw = normalizeLxLocalSong(Map<String, dynamic>.from(value));
      if (raw == null) continue;
      final path = raw['_sourcePath']?.toString() ?? '';
      if (path.isEmpty || !seen.add(path)) continue;
      songs.add(raw);
    }
    if (songs.isNotEmpty) playlists.add(LxLocalPlaylist(name: name, songs: songs));
  }
  return playlists;
}

/// 洛雪 SongInfo 条目 → raw 歌曲结构（对齐洛雪搜索归一化）。
/// 不是洛雪歌曲结构（缺少 songmid/source/name）时返回 null。
Map<String, dynamic>? normalizeLxLocalSong(Map<String, dynamic> item) {
  final source = _text(item['source']).toLowerCase();
  final songmid = _text(item['songmid'] ?? item['song_mid'] ?? item['id']);
  final name = _text(item['name'] ?? item['title']);
  if (source.isEmpty || !kLxSourceIds.contains(source) ||
      songmid.isEmpty || name.isEmpty) {
    return null;
  }
  final singer = _text(item['singer'] ?? item['artist']);
  final album = _text(item['albumName'] ?? item['album_name'] ?? item['album']);
  final durationSec = _intervalToSeconds(item['interval'] ?? item['duration']);
  final types = item['types'] ?? item['_types'] ?? item['lx_types'];
  return _lxSong(
    source: source,
    songmid: songmid,
    hash: item['hash'],
    name: name,
    singer: singer,
    album: album,
    albumId: item['albumId'] ?? item['album_id'],
    strMediaMid: item['strMediaMid'] ?? item['str_media_mid'],
    songId: item['songId'] ?? item['song_id'],
    albumMid: item['albumMid'] ?? item['album_mid'],
    copyrightId: item['copyrightId'] ?? item['copyright_id'],
    durationSec: durationSec,
    img: _normalizeCover(_text(item['img'] ?? item['artwork'])),
    types: types is Map ? Map<String, dynamic>.from(types) : null,
  )
    // 保留洛雪导出自带的歌词，导入后无需再次请求。
    ..['lrc'] = _text(item['lrc'])
    ..['lxlyric'] = _text(item['lxlyric']);
}

/// 洛雪 interval 字段（"03:45" 或秒数）→ 秒。
int _intervalToSeconds(dynamic value) {
  if (value is num) return value > 0 ? value.toInt() : 0;
  final text = _text(value);
  if (text.contains(':')) {
    final parts = text.split(':').map(int.tryParse).toList();
    if (parts.every((part) => part != null)) {
      var seconds = 0;
      for (final part in parts) {
        seconds = seconds * 60 + part!;
      }
      return seconds;
    }
  }
  return int.tryParse(text) ?? 0;
}
