// 端到端验证 QQ 歌单整单导入（baka 插件路径 + 官方接口增量补齐）。
//
// 背景：baka 系 QQ 插件 importMusicSheet 固定 song_num=1000，QQ 接口
// 单次约 999 首封顶，大歌单会截断；App 侧在 importMusicSheet 之后按
// song_begin 偏移补齐剩余曲目。本脚本复现该流程：
//   1) 模拟插件整单导入（song_begin=0, song_num=1000）
//   2) 模拟 App 增量补齐（song_begin=已导入数, song_num=2000，翻页）
//   3) 按 songmid 去重合并，校验总数与 worksNum 一致
//
// 运行：dart run tool/qq_import_check.dart [disstid|链接]
// 默认验证用户分享的歌单 2784566436（约 1916 首）。

import 'dart:convert';
import 'dart:io';

Future<Map<String, dynamic>> fetchDiss(String disstid, int begin, int num) async {
  final response = await HttpClient()
      .postUrl(Uri.https('u.y.qq.com', '/cgi-bin/musicu.fcg'))
      .then((request) {
        request.headers.set('User-Agent',
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
        request.headers.set('Referer', 'https://y.qq.com/');
        request.headers.set('Origin', 'https://y.qq.com');
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode({
          'comm': {'ct': 24, 'cv': 4747474, 'uin': 0},
          'req': {
            'module': 'music.srfDissInfo.aiDissInfo',
            'method': 'uniform_get_Dissinfo',
            'param': {
              'disstid': int.parse(disstid),
              'userinfo': 1,
              'tag': 1,
              'orderlist': 1,
              'song_begin': begin,
              'song_num': num,
              'onlysonglist': 0,
              'enc_host_uin': '',
            },
          },
        }));
        return request.close();
      })
      .timeout(const Duration(seconds: 20));
  final body = await response.transform(utf8.decoder).join();
  final decoded = jsonDecode(body);
  final req = decoded is Map ? decoded['req'] : null;
  final data = req is Map ? req['data'] : null;
  if (data is! Map) {
    throw Exception('接口返回异常：${body.length > 300 ? body.substring(0, 300) : body}');
  }
  return Map<String, dynamic>.from(data);
}

String? extractDisstid(String input) {
  final patterns = [
    RegExp(r'[?&]id=(\d+)'),
    RegExp(r'/playlist/(\d+)'),
    RegExp(r'^(\d+)$'),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(input);
    if (match != null) return match.group(1);
  }
  return null;
}

/// 与 plugin_runtime.dart _normalizeQqDissSong 相同的归一化（验证字段）。
Map<String, dynamic> normalizeSong(Map raw) {
  final album = raw['album'] is Map
      ? Map<String, dynamic>.from(raw['album'] as Map)
      : const <String, dynamic>{};
  final singers = (raw['singer'] is List ? raw['singer'] as List : const [])
      .whereType<Map>()
      .map((s) => s['name']?.toString() ?? '')
      .where((name) => name.isNotEmpty)
      .join(', ');
  final file = raw['file'] is Map
      ? Map<String, dynamic>.from(raw['file'] as Map)
      : const <String, dynamic>{};
  final qualities = <String>[];
  void addQ(String q, dynamic size) {
    final bytes = size is num ? size.toInt() : int.tryParse('$size') ?? 0;
    if (bytes > 0) qualities.add(q);
  }

  addQ('128k', file['size_128mp3']);
  addQ('320k', file['size_320mp3']);
  addQ('flac', file['size_flac']);
  addQ('hires', file['size_hires']);
  addQ('dolby', file['size_dolby']);
  final sizeNew = file['size_new'];
  if (sizeNew is List) {
    int sizeAt(int i) =>
        i < sizeNew.length && sizeNew[i] is num ? (sizeNew[i] as num).toInt() : 0;
    if (sizeAt(0) > 0) qualities.add('master');
    if (sizeAt(1) > 0) qualities.add('atmos');
    if (sizeAt(2) > 0) qualities.add('atmos_plus');
    if (sizeAt(4) > 0) qualities.add('vinyl');
  }
  return {
    'id': raw['id'],
    'songmid': raw['mid']?.toString() ?? '',
    'title': raw['title'] ?? raw['name'] ?? '',
    'artist': singers,
    'album': album['title'] ?? album['name'] ?? '',
    'duration': raw['interval'] ?? 0,
    'qualities': qualities,
  };
}

Future<void> main(List<String> args) async {
  final input = args.isNotEmpty
      ? args.join(' ')
      : 'https://i2.y.qq.com/n3/other/pages/details/playlist.html'
          '?platform=11&appshare=android_qq&appversion=20070508'
          '&hosteuin=owosoKSkNKvA7z**&id=2784566436&ADTAG=wxfshare';
  final disstid = extractDisstid(input);
  if (disstid == null) {
    stderr.writeln('无法从输入中提取歌单 ID：$input');
    exitCode = 1;
    return;
  }
  stdout.writeln('==> disstid=$disstid');

  // 1) 模拟插件整单导入（song_num=1000）。
  final first = await fetchDiss(disstid, 0, 1000);
  final dirinfo = first['dirinfo'] is Map
      ? Map<String, dynamic>.from(first['dirinfo'] as Map)
      : const <String, dynamic>{};
  final rawList = (first['songlist'] as List? ?? []).whereType<Map>().toList();
  final worksNum = int.tryParse('${dirinfo['songnum'] ?? 0}') ?? 0;
  stdout.writeln('    歌单：${dirinfo['dissname']} 声称总数=$worksNum');
  stdout.writeln('    插件整单返回：${rawList.length} 首（song_num=1000 时约 999 封顶）');

  final songs = <String, Map<String, dynamic>>{};
  for (final raw in rawList) {
    final song = normalizeSong(Map<String, dynamic>.from(raw));
    if (song['songmid'].toString().isNotEmpty) {
      songs[song['songmid'].toString()] = song;
    }
  }
  stdout.writeln('    去重后插件曲目：${songs.length} 首');

  // 2) 模拟 App 增量补齐（song_begin=已导入数，song_num=2000，翻页）。
  var begin = rawList.length;
  var pages = 0;
  while (begin < worksNum && begin < 10000) {
    final page = await fetchDiss(disstid, begin, 2000);
    final list = (page['songlist'] as List? ?? []).whereType<Map>().toList();
    if (list.isEmpty) break;
    var added = 0;
    for (final raw in list) {
      final song = normalizeSong(Map<String, dynamic>.from(raw));
      final key = song['songmid'].toString();
      if (key.isEmpty || songs.containsKey(key)) continue;
      songs[key] = song;
      added++;
    }
    pages++;
    stdout.writeln('    补齐第 $pages 页：begin=$begin 取回 ${list.length} 首，'
        '新增 $added 首');
    if (added == 0) break;
    begin += list.length;
  }

  // 3) 校验。
  final all = songs.values.toList();
  stdout.writeln('==> 最终合并：${all.length} 首 / 声称 $worksNum 首');
  final withQuality =
      all.where((s) => (s['qualities'] as List).isNotEmpty).length;
  final withMaster = all
      .where((s) => (s['qualities'] as List).contains('master'))
      .length;
  stdout.writeln('    含音质信息：$withQuality 首，含 master：$withMaster 首');
  stdout.writeln('    首 3 首：');
  for (final song in all.take(3)) {
    stdout.writeln('      《${song['title']}》- ${song['artist']} '
        '${song['duration']}s 音质:${song['qualities']}');
  }
  stdout.writeln('    末 2 首：');
  for (final song in all.skip(all.length - 2)) {
    stdout.writeln('      《${song['title']}》- ${song['artist']} '
        '${song['duration']}s 音质:${song['qualities']}');
  }
  final ok = all.length >= (worksNum - 15) && all.isNotEmpty;
  stdout.writeln(ok ? '==> 验证通过：导入完整' : '==> 验证失败：导入不完整');
  exitCode = ok ? 0 : 1;
}
