import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
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
// 酷狗：对齐 lx-music-mobile kg/songList.js（master 版）。老式
// special/single HTML 页接口已失效，改用 v5 接口族：
//   纯数字 ID/酷狗码 → t.kugou.com/command 解码
//   gcid_ 链接       → t.kugou.com/v1/songlist/batch_decode 解码
//   chain=/分享页     → m.kugou.com/schain/transfer
//   歌单详情         → mobiles.kugou.com/api/v5/special/info_v2 + song_v2
//   歌曲信息         → gateway 批量接口补全
// ---------------------------------------------------------------------------

const _kgWebSignKey = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';
const _kgAndroidSignKey = 'OIlwieks28dk2k092lksi2UIkp';

/// 酷狗接口签名：query 参数按 & 拆分排序拼接，前后加平台密钥，
/// 请求体参与拼接（仅 batch_decode 使用），整体取 MD5。
String _kgSignature(
  String params, {
  String platform = 'web',
  String body = '',
}) {
  final key = platform == 'web' ? _kgWebSignKey : _kgAndroidSignKey;
  final parts = params.split('&')..sort();
  return md5.convert(utf8.encode('$key${parts.join()}$body$key')).toString();
}

Map<String, String> _kgV5Headers(String clienttime) => {
  'User-Agent':
      'Mozilla/5.0 (iPhone; CPU iPhone OS 11_0 like Mac OS X) '
      'AppleWebKit/604.1.38 (KHTML, like Gecko) Version/11.0 '
      'Mobile/15A372 Safari/604.1',
  'Referer': 'https://m3ws.kugou.com/share/index.php',
  'mid': clienttime,
  'dfid': '-',
  'clienttime': clienttime,
};

const _kgCommandHeaders = {
  'KG-RC': '1',
  'KG-THash': 'network_super_call.cpp:3676261689:379',
  'User-Agent': '',
};

Future<LxPlaylistImportResult> _importKg(http.Client client, String input) async {
  final trimmed = input.trim();
  // 纯数字：酷狗码或歌单 ID，经 t.kugou.com/command 解码。
  if (RegExp(r'^\d+$').hasMatch(trimmed)) {
    return _kgByCode(client, trimmed);
  }
  // 裸 global_collection_id 直接进 v5 歌单详情。
  if (RegExp(r'^collection_\w+$').hasMatch(trimmed)) {
    return _kgDetail2(client, trimmed);
  }
  // lx-music 的 id_ 前缀 specialid。
  final idPrefixed = RegExp(r'^id_(\d+)$').firstMatch(trimmed);
  if (idPrefixed != null) {
    final converted = await _kgSpecialIdToGlobal(client, idPrefixed.group(1)!);
    if (converted != null) return _kgDetail2(client, converted);
    throw Exception('酷狗歌单不存在或已失效，请检查歌单 ID');
  }
  return _kgByLink(client, trimmed);
}

/// 酷狗码 / 歌单 ID：command 接口返回歌单元信息；解码失败时回退
/// 按老式 specialid 换算（纯数字歌单 ID 不是酷狗码）。
Future<LxPlaylistImportResult> _kgByCode(http.Client client, String id) async {
  Map<String, dynamic> info = const <String, dynamic>{};
  dynamic rawList;
  try {
    final body = await _postJson(
      client,
      Uri.parse('http://t.kugou.com/command/'),
      {
        'appid': 1001,
        'clientver': 9020,
        'mid': '21511157a05844bd085308bc76ef3343',
        'clienttime': 640612895,
        'key': '36164c4015e704673c588ee202b9ecb8',
        'data': id,
      },
      headers: _kgCommandHeaders,
    );
    if (body is Map) {
      final errcode = _toInt(
        body['error_code'] ?? body['errcode'] ?? body['err_code'],
        -1,
      );
      if (errcode == 0) {
        // command 响应形态：{status, err_code, data: {info, list}}。
        final data = body['data'];
        if (data is Map && data['info'] is Map) {
          info = Map<String, dynamic>.from(data['info'] as Map);
          rawList = data['list'];
        } else if (body['info'] is Map) {
          info = Map<String, dynamic>.from(body['info'] as Map);
          rawList = body['list'];
        }
      }
    }
  } catch (_) {
    // command 解码失败时走 specialid 回退。
  }

  if (info.isNotEmpty) {
    var cover = _text(info['img_size']);
    if (cover.contains('{size}')) cover = cover.replaceAll('{size}', '240');
    if (cover.isEmpty) cover = _text(info['img']);
    final meta = (name: _text(info['name']), cover: _normalizeCover(cover));

    final gcid = _text(info['global_collection_id']);
    if (gcid.isNotEmpty) return _kgDetail2(client, gcid);

    // 无 gcid：先尝试 specialid → global_specialid 换算。
    final specialId = _text(info['id']);
    if (specialId.isNotEmpty) {
      final converted = await _kgSpecialIdToGlobal(client, specialId);
      if (converted != null) return _kgDetail2(client, converted);
    }

    // 用户收藏歌单：kucodeAndShare 接口直接返回歌曲列表。
    final userid = _text(info['userid']);
    if (userid.isNotEmpty) {
      final listBody = await _postJson(
        client,
        Uri.parse('http://www2.kugou.kugou.com/apps/kucodeAndShare/app/'),
        {
          'appid': 1001,
          'clientver': 9020,
          'mid': '21511157a05844bd085308bc76ef3343',
          'clienttime': 640612895,
          'key': '36164c4015e704673c588ee202b9ecb8',
          'data': {
            'id': specialId,
            'type': 3,
            'userid': userid,
            'collect_type': 0,
            'page': 1,
            'pagesize': _toInt(info['count'], 300),
          },
        },
        headers: _kgCommandHeaders,
      );
      final hashes = _kgHashesFromList(
        listBody is Map ? listBody['info'] : null,
      );
      if (hashes.isNotEmpty) {
        return _kgSongsFromHashes(
          client,
          name: meta.name,
          cover: meta.cover,
          hashes: hashes,
        );
      }
    }

    // command 响应自带歌曲列表（如别人的播放队列）。
    final hashes = _kgHashesFromList(rawList);
    if (hashes.isNotEmpty) {
      return _kgSongsFromHashes(
        client,
        name: meta.name,
        cover: meta.cover,
        hashes: hashes,
      );
    }
  }

  // 酷狗码无效：把输入当老式 specialid 尝试换算。
  final converted = await _kgSpecialIdToGlobal(client, id);
  if (converted != null) return _kgDetail2(client, converted);
  throw Exception('酷狗歌单不存在或已失效，请检查 ID / 酷狗码 / 链接');
}

Future<LxPlaylistImportResult> _kgByLink(http.Client client, String link) async {
  final url = link.trim().replaceFirst(RegExp(r'#.*$'), '');
  final resolved = await _kgResolveLink(client, url);
  if (resolved != null) return resolved;
  throw Exception('无法从链接解析酷狗歌单，请检查链接是否有效');
}

/// 依次尝试各种链接形态；短链通过重定向展开后再试。
Future<LxPlaylistImportResult?> _kgResolveLink(
  http.Client client,
  String url,
) async {
  final gcidParam = RegExp(r'global_collection_id=(\w+)').firstMatch(url);
  if (gcidParam != null) return _kgDetail2(client, gcidParam.group(1)!);

  final gcidToken = RegExp(r'gcid_(\w+)').firstMatch(url);
  if (gcidToken != null) {
    final decoded = await _kgDecodeGcid(client, 'gcid_${gcidToken.group(1)}');
    if (decoded != null) return _kgDetail2(client, decoded);
    // 解码失败时把 gcid 串当 chain 再试（对齐 WalnutBai decodeGcid 兜底）。
    return _kgByChain(client, gcidToken.group(1)!);
  }

  final chain = RegExp(r'[?&]chain=(\w+)').firstMatch(url);
  if (chain != null) return _kgByChain(client, chain.group(1)!);

  final special = RegExp(r'special/single/(\d+)').firstMatch(url);
  if (special != null) {
    final converted = await _kgSpecialIdToGlobal(client, special.group(1)!);
    if (converted != null) return _kgDetail2(client, converted);
  }

  // xxx.html 分享页（song.html 除外）：文件名即 chain。
  if (url.contains('.html') && !url.contains('song.html')) {
    final page = RegExp(r'/(\w+)\.html').firstMatch(url);
    if (page != null && page.group(1)!.length > 4) {
      return _kgByChain(client, page.group(1)!);
    }
  }

  return _kgByShortLink(client, url);
}

/// 短链：手动跟随重定向，在 location 与落地页中找歌单标识。
Future<LxPlaylistImportResult?> _kgByShortLink(
  http.Client client,
  String url,
) async {
  var current = url;
  for (var hop = 0; hop < 5; hop++) {
    final request = http.Request('GET', Uri.parse(current))
      ..followRedirects = false
      ..headers.addAll(_phoneHeaders);
    final response = await client.send(request).timeout(_timeout);
    if (response.isRedirect) {
      final location = response.headers['location'];
      await response.stream.drain<void>();
      if (location == null || location.isEmpty) return null;
      current = Uri.parse(current).resolve(location).toString();
      final gcid = RegExp(r'global_collection_id=(\w+)').firstMatch(current);
      if (gcid != null) return _kgDetail2(client, gcid.group(1)!);
      final gcidToken = RegExp(r'gcid_(\w+)').firstMatch(current);
      if (gcidToken != null) {
        final decoded = await _kgDecodeGcid(
          client,
          'gcid_${gcidToken.group(1)}',
        );
        if (decoded != null) return _kgDetail2(client, decoded);
      }
      final chain = RegExp(r'[?&]chain=(\w+)').firstMatch(current);
      if (chain != null) return _kgByChain(client, chain.group(1)!);
      // xxx.html 分享页（song.html 除外）：文件名即 chain。
      if (current.contains('.html') && !current.contains('song.html')) {
        final page = RegExp(r'/(\w+)\.html').firstMatch(current);
        if (page != null && page.group(1)!.length > 4) {
          return _kgByChain(client, page.group(1)!);
        }
      }
      continue;
    }
    final page = await response.stream.bytesToString();
    final gcid = RegExp(r'"global_collection_id"\s*:\s*"(\w+)"')
            .firstMatch(page) ??
        RegExp(r'global_collection_id=(\w+)').firstMatch(page);
    if (gcid != null) return _kgDetail2(client, gcid.group(1)!);
    final gcidToken = RegExp(r'gcid_(\w+)').firstMatch(page);
    if (gcidToken != null) {
      final decoded = await _kgDecodeGcid(
        client,
        'gcid_${gcidToken.group(1)}',
      );
      if (decoded != null) return _kgDetail2(client, decoded);
    }
    return null;
  }
  return null;
}

/// chain 分享链接：schain/transfer 接口返回歌单或重定向标识。
Future<LxPlaylistImportResult> _kgByChain(
  http.Client client,
  String chain,
) async {
  final body = await _getJson(
    client,
    Uri.parse(
      'http://m.kugou.com/schain/transfer?pagesize=10000'
      '&chain=${Uri.encodeComponent(chain)}&su=1&page=1&n=0.7928855356604456',
    ),
    headers: _phoneHeaders,
  );
  if (body is! Map) throw Exception('酷狗歌单加载失败');
  final gcid = _text(body['global_collection_id']);
  if (gcid.isNotEmpty) return _kgDetail2(client, gcid);
  final info = body['info'] is Map
      ? Map<String, dynamic>.from(body['info'] as Map)
      : const <String, dynamic>{};
  final hashes = _kgHashesFromList(body['list']);
  if (hashes.isEmpty) {
    // schain/transfer 无列表时回退 PC 分享页解析（对齐 WalnutBai
    // getUserListDetail5：m 分享页取元信息 + www 分享页取歌曲）。
    return _kgByPcShare(client, chain);
  }
  return _kgSongsFromHashes(
    client,
    name: _text(info['name']),
    cover: _normalizeCover(_text(info['img'])),
    hashes: hashes,
  );
}

/// PC 分享页回退：m.kugou.com/share 内嵌 phpParam 提供歌单元信息，
/// www.kugou.com/share/{chain}.html 内嵌 dataFromSmarty 提供歌曲列表。
Future<LxPlaylistImportResult> _kgByPcShare(
  http.Client client,
  String chain,
) async {
  var name = '';
  var cover = '';
  try {
    final page = await _kgGetPage(
      client,
      'https://m.kugou.com/share/?chain=$chain&id=$chain',
    );
    final match = RegExp(r'var\s+phpParam\s*=\s*(\{.+?\});').firstMatch(page);
    if (match != null) {
      final param = jsonDecode(match.group(1)!);
      if (param is Map) {
        name = _text(param['specialname']);
        cover = _normalizeCover(
          _text(param['imgurl']).replaceAll('{size}', '240'),
        );
      }
    }
  } catch (_) {
    // 元信息解析失败不阻断歌曲列表获取。
  }

  final hashes = <String>[];
  try {
    final page = await _kgGetPage(
      client,
      'https://www.kugou.com/share/$chain.html',
    );
    final match = RegExp(
      r'var\s+dataFromSmarty\s*=\s*(\[.+?\]);',
    ).firstMatch(page);
    if (match != null) {
      final data = jsonDecode(match.group(1)!);
      hashes.addAll(_kgHashesFromList(data));
    }
  } catch (_) {
    // 歌曲列表解析失败走统一报错。
  }
  if (hashes.isEmpty) throw Exception('酷狗歌单不存在或已失效');
  return _kgSongsFromHashes(
    client,
    name: name,
    cover: cover,
    hashes: hashes,
  );
}

Future<String> _kgGetPage(http.Client client, String url) async {
  final response = await client
      .get(Uri.parse(url), headers: _browserHeaders)
      .timeout(_timeout);
  return utf8.decode(response.bodyBytes, allowMalformed: true);
}

/// gcid_ 分享标识 → global_collection_id。
Future<String?> _kgDecodeGcid(http.Client client, String gcid) async {
  final params =
      'dfid=-&appid=1005&mid=0&clientver=20109&clienttime=640612895&uuid=-';
  final body = {
    'ret_info': 1,
    'data': [
      {'id': gcid, 'id_type': 2},
    ],
  };
  final result = await _postJson(
    client,
    Uri.parse(
      'https://t.kugou.com/v1/songlist/batch_decode?$params'
      '&signature=${_kgSignature(params, platform: 'android', body: jsonEncode(body))}',
    ),
    body,
    headers: const {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 10; HUAWEI HMA-AL00) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.106 '
          'Mobile Safari/537.36',
      'Referer': 'https://m.kugou.com/',
    },
  );
  final data = result is Map ? result['data'] : null;
  // 兼容 list 位于 data.list 或顶层 list 两种响应形态。
  final list = data is Map
      ? data['list']
      : (result is Map ? result['list'] : null);
  if (list is List && list.isNotEmpty && list.first is Map) {
    final id = _text((list.first as Map)['global_collection_id']);
    if (id.isNotEmpty) return id;
  }
  return null;
}

/// 老式 specialid → global_specialid 换算。
Future<String?> _kgSpecialIdToGlobal(
  http.Client client,
  String specialId,
) async {
  try {
    final body = await _getJson(
      client,
      Uri.parse(
        'http://mobilecdnbj.kugou.com/api/v5/special/info?specialid=$specialId',
      ),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 10; HLK-AL00) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/104.0.5112.102 '
            'Mobile Safari/537.36 EdgA/104.0.1293.70',
      },
    );
    final data = body is Map && body['data'] is Map
        ? Map<String, dynamic>.from(body['data'] as Map)
        : const <String, dynamic>{};
    final global = _text(data['global_specialid']);
    return global.isEmpty ? null : global;
  } catch (_) {
    return null;
  }
}

/// v5 歌单详情：info_v2 拿基本信息，song_v2 分页拿 hash 列表。
Future<LxPlaylistImportResult> _kgDetail2(
  http.Client client,
  String globalCollectionId,
) async {
  final infoParams =
      'appid=1058&specialid=0&global_specialid=$globalCollectionId&format=jsonp'
      '&srcappid=2919&clientver=20000&clienttime=1586163242519&mid=1586163242519'
      '&uuid=1586163242519&dfid=-';
  final infoBody = await _getJson(
    client,
    Uri.parse(
      'https://mobiles.kugou.com/api/v5/special/info_v2?$infoParams'
      '&signature=${_kgSignature(infoParams)}',
    ),
    headers: _kgV5Headers('1586163242519'),
  );
  final info = infoBody is Map && infoBody['data'] is Map
      ? Map<String, dynamic>.from(infoBody['data'] as Map)
      : const <String, dynamic>{};
  final total = _toInt(info['songcount']);

  final hashes = <String>[];
  final seen = <String>{};
  var page = 1;
  var remaining = total > 0 ? total : 300;
  while (remaining > 0 && hashes.length < _maxImportSongs) {
    final limit = remaining > 300 ? 300 : remaining;
    final params =
        'appid=1058&global_specialid=$globalCollectionId&specialid=0&plat=0'
        '&version=8000&page=$page&pagesize=$limit&srcappid=2919&clientver=20000'
        '&clienttime=1586163263991&mid=1586163263991&uuid=1586163263991&dfid=-';
    final body = await _getJson(
      client,
      Uri.parse(
        'https://mobiles.kugou.com/api/v5/special/song_v2?$params'
        '&signature=${_kgSignature(params)}',
      ),
      headers: _kgV5Headers('1586163263991'),
    );
    final data = body is Map && body['data'] is Map
        ? Map<String, dynamic>.from(body['data'] as Map)
        : const <String, dynamic>{};
    var added = 0;
    for (final hash in _kgHashesFromList(data['info'])) {
      if (seen.add(hash)) {
        hashes.add(hash);
        added++;
      }
    }
    if (added == 0) break; // 接口返回空页时终止分页。
    remaining -= limit;
    page++;
  }
  if (hashes.isEmpty) throw Exception('酷狗歌单为空或歌单不存在');
  var cover = _text(info['imgurl']);
  if (cover.contains('{size}')) cover = cover.replaceAll('{size}', '240');
  return _kgSongsFromHashes(
    client,
    name: _text(info['specialname']),
    cover: _normalizeCover(cover),
    hashes: hashes,
  );
}

/// 从接口返回的歌曲列表中提取去重后的 hash。
List<String> _kgHashesFromList(dynamic list) {
  if (list is! List) return const [];
  final hashes = <String>[];
  final seen = <String>{};
  for (final value in list.whereType<Map>()) {
    final hash = _text(value['hash']).toUpperCase();
    if (hash.isNotEmpty && seen.add(hash)) hashes.add(hash);
  }
  return hashes;
}

/// gateway 批量接口把 hash 补全为歌曲信息（对齐 lx-music createTask），
/// 再经 get_res_privilege 批量补全音质详情（对齐 WalnutBai
/// quality_detail.js 的 filterData/getBatchMusicQualityInfo，支持
/// hires / master / atmos）。
Future<LxPlaylistImportResult> _kgSongsFromHashes(
  http.Client client, {
  required String name,
  required String cover,
  required List<String> hashes,
}) async {
  // 第一阶段：gateway 批量补全歌曲信息，按 audio_id 去重（同一首歌
  // 不同音质 hash 只保留一份，对齐 WalnutBai filterData 的 removeDuplicates）。
  final items = <Map<String, dynamic>>[];
  final seenAudioIds = <String>{};
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
      final audio = _kgAudioInfo(item);
      final hash = _text(audio['hash']).toUpperCase();
      if (hash.isEmpty) continue;
      final audioId = _text(audio['audio_id']);
      if (audioId.isNotEmpty && !seenAudioIds.add(audioId)) continue;
      items.add(item);
      if (items.length >= _maxImportSongs) break;
    }
    if (items.length >= _maxImportSongs) break;
  }
  if (items.isEmpty) throw Exception('酷狗歌单歌曲信息获取失败');

  // 第二阶段：get_res_privilege 批量查询音质详情；失败时回退 gateway
  // 自带的 hash_128/hash_320/hash_flac 音质。
  final qualityInfo = await _kgQualityInfo(
    client,
    [for (final item in items) _text(_kgAudioInfo(item)['hash']).toUpperCase()],
  );

  final songs = <Map<String, dynamic>>[];
  for (final item in items) {
    final audio = _kgAudioInfo(item);
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
    var songCover = _normalizeCover(
      _text(albumInfo['sizable_cover']).replaceAll('{size}', '480'),
    );
    if (songCover.isEmpty) {
      songCover = _normalizeCover(
        _text(transParam['union_cover']).replaceAll('{size}', '400'),
      );
    }
    final types = qualityInfo[hash] ?? _kgTypes(audio);
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
        img: songCover,
        types: types,
      ),
    );
  }
  if (songs.isEmpty) throw Exception('酷狗歌单歌曲信息获取失败');
  return LxPlaylistImportResult(
    name: name.isEmpty ? '酷狗歌单' : name,
    coverUrl: cover,
    songs: songs,
  );
}

Map<String, dynamic> _kgAudioInfo(Map<String, dynamic> item) {
  if (item['audio_info'] is Map) {
    return Map<String, dynamic>.from(item['audio_info'] as Map);
  }
  if (item['audioInfo'] is Map) {
    return Map<String, dynamic>.from(item['audioInfo'] as Map);
  }
  return const <String, dynamic>{};
}

/// get_res_privilege 批量查询音质详情（对齐 WalnutBai
/// quality_detail.js 的 getBatchMusicQualityInfo）。
/// 返回 hash → 音质档位（128k/320k/flac/hires/master/atmos/dolby 各含
/// size 与对应 hash），查询失败时返回空表由调用方回退 gateway 音质。
Future<Map<String, Map<String, dynamic>>> _kgQualityInfo(
  http.Client client,
  List<String> hashes,
) async {
  final result = <String, Map<String, dynamic>>{};
  for (var index = 0; index < hashes.length; index += 100) {
    final batch = hashes.skip(index).take(100).toList();
    try {
      final body = await _postJson(
        client,
        Uri.parse(
          'https://gateway.kugou.com/goodsmstore/v1/get_res_privilege'
          '?appid=1005&clientver=20049&clienttime='
          '${DateTime.now().millisecondsSinceEpoch}&mid=NeZha',
        ),
        {
          'behavior': 'play',
          'clientver': '20049',
          'resource': [
            for (final hash in batch) {'id': 0, 'type': 'audio', 'hash': hash},
          ],
          'area_code': '1',
          'quality': '128',
          'qualities': const [
            '128',
            '320',
            'flac',
            'high',
            'dolby',
            'viper_atmos',
            'viper_tape',
            'viper_clear',
          ],
        },
      );
      if (body is! Map ||
          _toInt(body['error_code'], -1) != 0 ||
          body['data'] is! List) {
        continue; // 单批失败不阻断导入。
      }
      for (final value in (body['data'] as List).whereType<Map>()) {
        final item = Map<String, dynamic>.from(value);
        final hash = _text(item['hash']).toUpperCase();
        final goods = item['relate_goods'];
        if (hash.isEmpty || goods is! List) continue;
        final types = <String, dynamic>{};
        for (final goodValue in goods.whereType<Map>()) {
          final good = Map<String, dynamic>.from(goodValue);
          final key = switch (_text(good['quality'])) {
            '128' => '128k',
            '320' => '320k',
            'flac' => 'flac',
            'high' => 'hires',
            'viper_clear' => 'master',
            'viper_atmos' => 'atmos',
            'dolby' => 'dolby',
            _ => null,
          };
          final goodHash = _text(good['hash']).toUpperCase();
          if (key == null || goodHash.isEmpty) continue;
          final info = good['info'] is Map
              ? Map<String, dynamic>.from(good['info'] as Map)
              : const <String, dynamic>{};
          // 同档位重复出现时取最后一条（接口会在末尾附上请求的原始
          // hash，作为播放兜底更可靠）。
          types[key] = {
            'size': _sizeFormate(info['filesize']),
            'hash': goodHash,
          };
        }
        if (types.isNotEmpty) result[hash] = types;
      }
    } catch (_) {
      // 音质详情获取失败时回退 gateway 自带音质。
    }
  }
  return result;
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
// 支持三种结构：
//   1. 单个歌单导出：{ "info": {...}, "list": [song, ...] }
//   2. 全部列表备份（v1）：{ "list": [{ "info": {...}, "list": [...] }, ...],
//      "defaultList": {...}, "loveList": {...} }
//   3. 全量备份（v2）：{ "version": "2", "data": {
//      "defaultList": [song, ...], "loveList": [song, ...],
//      "userList": [{ "name": "...", "list": [song, ...] }, ...] } }
//      defaultList/loveList 直接是歌曲数组，用户歌单名称在顶层 name；
//      歌曲条目为 v2 扁平结构（name/singer/source/interval 在顶层，
//      songId/albumName/picUrl/_qualitys 等在 meta 嵌套，id 形如
//      "tx_001dEI9i3VqAHc" 即 source_songmid）。
// 歌曲条目统一归一化为与洛雪搜索一致的 raw 结构（含 `lx` 元数据与
// `lx://` 虚拟路径）。
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

  // 洛雪 v2 全量备份：歌单都在 data 节点下。
  final data = decoded['data'];
  if (data is Map) {
    final v2Playlists = _parseLxV2Backup(Map<String, dynamic>.from(data));
    if (v2Playlists.isNotEmpty) return v2Playlists;
  }

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
    _addLxPlaylist(playlists, name, rawSongs);
  }
  return playlists;
}

/// 洛雪 v2 全量备份的 data 节点 → 歌单列表。
/// defaultList/loveList/tempList 是歌曲数组（应用内固定列表），
/// userList 是用户自建歌单（名称在顶层 name，歌曲在 list）。
List<LxLocalPlaylist> _parseLxV2Backup(Map<String, dynamic> data) {
  final playlists = <LxLocalPlaylist>[];
  for (final entry in const [
    ('defaultList', '试听列表'),
    ('loveList', '我的收藏'),
    ('tempList', '临时列表'),
  ]) {
    final node = data[entry.$1];
    if (node is! List || node.isEmpty) continue;
    _addLxPlaylist(playlists, entry.$2, node);
  }
  final userList = data['userList'];
  if (userList is List) {
    for (final value in userList.whereType<Map>()) {
      final item = Map<String, dynamic>.from(value);
      final rawSongs = item['list'];
      if (rawSongs is! List || rawSongs.isEmpty) continue;
      var name = _text(item['name']);
      if (name.isEmpty) name = '洛雪歌单';
      _addLxPlaylist(playlists, name, rawSongs);
    }
  }
  return playlists;
}

/// 收集一个歌单的歌曲（去重后非空才入列）。
void _addLxPlaylist(
  List<LxLocalPlaylist> playlists,
  String name,
  List<dynamic> rawSongs,
) {
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

/// 洛雪 SongInfo 条目 → raw 歌曲结构（对齐洛雪搜索归一化）。
/// 不是洛雪歌曲结构（缺少 source/name 等）时返回 null。
/// 兼容 v1 扁平导出（songmid/albumName 在顶层）与 v2 全量备份
/// （songId/albumName/picUrl/_qualitys 在 meta 嵌套，id 带 source 前缀）。
Map<String, dynamic>? normalizeLxLocalSong(Map<String, dynamic> item) {
  final source = _text(item['source']).toLowerCase();
  if (source.isEmpty || !kLxSourceIds.contains(source)) return null;
  final meta = item['meta'] is Map
      ? Map<String, dynamic>.from(item['meta'] as Map)
      : const <String, dynamic>{};
  var songmid = _text(item['songmid'] ?? item['song_mid'] ?? meta['songmid']);
  final hash = _text(item['hash'] ?? meta['hash']);
  // 酷狗播放走 hash（与洛雪搜索归一化一致），v2 备份的 hash 在 meta。
  if (songmid.isEmpty && source == 'kg' && hash.isNotEmpty) songmid = hash;
  if (songmid.isEmpty) {
    // v2 备份 id 形如 "tx_001dEI9i3VqAHc"（source_songmid），剥离前缀
    // 得到真正的 songmid；kg 的 id 是 "songId_hash"，取 hash 段；
    // v1 导出的 id 本身就是 songmid。
    final id = _text(item['id']);
    final prefix = '${source}_';
    if (id.startsWith(prefix)) {
      songmid = id.substring(prefix.length);
    } else if (source == 'kg' && id.contains('_')) {
      songmid = id.split('_').last;
    } else {
      songmid = id;
    }
  }
  final name = _text(item['name'] ?? item['title']);
  if (songmid.isEmpty || name.isEmpty) return null;
  final singer = _text(item['singer'] ?? item['artist']);
  final album = _text(
    item['albumName'] ??
        item['album_name'] ??
        item['album'] ??
        meta['albumName'],
  );
  final durationSec = _intervalToSeconds(item['interval'] ?? item['duration']);
  final types =
      item['_types'] ?? item['types'] ?? meta['_qualitys'] ?? item['lx_types'];
  return _lxSong(
    source: source,
    songmid: songmid,
    hash: hash.isNotEmpty ? hash : item['hash'],
    name: name,
    singer: singer,
    album: album,
    albumId: item['albumId'] ?? item['album_id'] ?? meta['albumId'],
    strMediaMid:
        item['strMediaMid'] ?? item['str_media_mid'] ?? meta['strMediaMid'],
    songId: item['songId'] ?? item['song_id'] ?? meta['songId'],
    albumMid: item['albumMid'] ?? item['album_mid'] ?? meta['albumMid'],
    copyrightId: item['copyrightId'] ?? item['copyright_id'],
    durationSec: durationSec,
    img: _normalizeCover(
      _text(item['img'] ?? item['artwork'] ?? meta['picUrl']),
    ),
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
