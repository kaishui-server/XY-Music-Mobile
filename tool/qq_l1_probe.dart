// QQ L1 播放链路端到端诊断（纯 Dart VM，无 flutter binding 拦截）。
// 复刻 XY Music CloudPlaybackProxy 的转发逻辑（含 5542 Content-Type
// 改写），Source API → 本地回环代理 → 模拟播放器请求，逐环节打印。
// 运行：dart run tool/qq_l1_probe.dart

import 'dart:convert';
import 'dart:io';

const kSourceApiUrl = 'https://qm.xww.ccwu.cc/api/source/song';
const kSourceApiKey =
    '3ccntJ6g64iGRo5_Qsvp6JxTpkPuErQDfmXu7LttMjDcKHycAfbrJrst-nCGzu2ClPKN-SjZG050IpEKmdMgmw';
// A Little Love - 冯曦妤（QQ songmid）
const kSongMid = '001IAqkK0p2b7s';

HttpClient client = HttpClient()
  ..connectionTimeout = const Duration(seconds: 15)
  ..autoUncompress = false;
// Source API 的 client 用默认 autoUncompress=true（服务端可能强制 gzip）
HttpClient apiClient = HttpClient()
  ..connectionTimeout = const Duration(seconds: 15);

String magic(List<int> bytes) => bytes
    .take(4)
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join(' ');

void log(String s) => stdout.writeln('[probe] $s');

Future<void> main() async {
  // ① Source API（XY 的 encrypted=0 明文路径）
  final apiReq = await apiClient.getUrl(
    Uri.parse('$kSourceApiUrl?id=$kSongMid&quality=flac&encrypted=0'),
  );
  apiReq.headers.set('X-API-KEY', kSourceApiKey);
  final apiResp = await apiReq.close();
  final body = await apiResp.transform(utf8.decoder).join();
  final json = jsonDecode(body) as Map<String, dynamic>;
  final data = json['data'] as Map<String, dynamic>?;
  log('source-api code=${json['code']} message=${json['message']} '
      'filename=${data?['filename']} '
      'ekeyLen=${(data?['ekey'] as String?)?.length ?? 0}');
  if (json['code'] != 0 || data == null) {
    log('Source API 失败，终止');
    exit(1);
  }
  final target = data['url'] as String;
  log('source-api url=$target');

  // ② 直连对照（预期 206 + audio/x-ogg 撒谎 CT + fLaC magic）
  {
    final req = await client.getUrl(Uri.parse(target));
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
    final resp = await req.close();
    final first = await resp.first;
    log('direct status=${resp.statusCode} '
        'CT=${resp.headers.value(HttpHeaders.contentTypeHeader)} '
        'contentLength=${resp.contentLength ?? '?'} magic=${magic(first)}');
  }

  // ③ 本地代理（复刻 XY 转发逻辑 + CT 改写）
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  final tasks = <String, String>{'tProbe': target};
  server.listen((req) async {
    final segs = req.uri.pathSegments;
    final token = segs.isNotEmpty ? segs.last : '';
    final url = tasks[token];
    log('proxy-req ${req.method} token=$token '
        'Range=${req.headers.value(HttpHeaders.rangeHeader) ?? '无'}');
    if (url == null) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    final upReq = await client.openUrl(req.method, Uri.parse(url));
    final range = req.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      upReq.headers.set(HttpHeaders.rangeHeader, range);
    }
    final upResp = await upReq.close().timeout(const Duration(seconds: 20));
    log('proxy-upstream status=${upResp.statusCode} '
        'CT=${upResp.headers.value(HttpHeaders.contentTypeHeader)}');
    req.response.statusCode = upResp.statusCode;
    // CT 改写：ogg 类型与扩展名矛盾 → octet-stream（5542 逻辑）
    final ct = upResp.headers.value(HttpHeaders.contentTypeHeader);
    if (ct != null) {
      final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
      final lyingOgg = ct.toLowerCase().contains('ogg') &&
          !path.endsWith('.ogg') &&
          !path.endsWith('.oga') &&
          !path.endsWith('.opus');
      if (lyingOgg) log('proxy-rewrite CT $ct → application/octet-stream');
      req.response.headers.set(
        HttpHeaders.contentTypeHeader,
        lyingOgg ? 'application/octet-stream' : ct,
      );
    }
    final clen = upResp.headers.value(HttpHeaders.contentLengthHeader);
    if (clen != null) {
      req.response.headers.set(HttpHeaders.contentLengthHeader, clen);
    }
    final crange = upResp.headers.value(HttpHeaders.contentRangeHeader);
    if (crange != null) {
      req.response.headers.set(HttpHeaders.contentRangeHeader, crange);
    }
    req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    await upResp.pipe(req.response);
    log('proxy-done status=${upResp.statusCode}');
  });
  log('proxy listening 127.0.0.1:$port');
  final proxyUrl = 'http://127.0.0.1:$port/ct/tProbe';

  // ④ 模拟播放器：起播/seek/全量
  for (final (tag, range) in [
    ('first', 'bytes=0-1023'),
    ('seek', 'bytes=2000000-2004095'),
    ('full', ''),
  ]) {
    final req = await client.getUrl(Uri.parse(proxyUrl));
    if (range.isNotEmpty) {
      req.headers.set(HttpHeaders.rangeHeader, range);
    }
    final sw = Stopwatch()..start();
    final resp = await req.close();
    final first = await resp.first.timeout(const Duration(seconds: 25));
    sw.stop();
    log('player-$tag status=${resp.statusCode} '
        'CT=${resp.headers.value(HttpHeaders.contentTypeHeader)} '
        'contentRange=${resp.headers.value(HttpHeaders.contentRangeHeader)} '
        'acceptRanges=${resp.headers.value(HttpHeaders.acceptRangesHeader)} '
        'firstChunk=${first.length}B ttfb=${sw.elapsedMilliseconds}ms '
        'magic=${magic(first)}');
  }
  exit(0);
}
