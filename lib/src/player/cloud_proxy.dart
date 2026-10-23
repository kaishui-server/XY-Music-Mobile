// 网盘直链本地播放代理（127.0.0.1 回环 HTTP 转发）。
//
// 背景：部分网盘 CDN（百度 d.pcs / 123 自建 CDN）对 ExoPlayer 的
// Conscrypt TLS 栈存在握手/特征兼容性问题——同一直链 URL 用 Dart
// HttpClient Range 探测成功、ExoPlayer 播放报 (0) Source error。
// 本代理让播放器只连回环地址，真实 CDN 请求由 Dart HttpClient（已
// 验证可用的网络栈）发起并流式转发，同时把转发层异常打进播放链路
// 日志（此前 Source error 底层原因不可见）。
//
// 协议：播放器请求 /ct/<token>；token 由 register() 登记真实直链与
// 请求头。Range 请求原样透传（seek = 新 Range 请求），响应状态与
// content-range/length/type 原样回传，音频流零缓冲 pipe（内存安全）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'playback_chain_log.dart';

class _ProxyTask {
  _ProxyTask(this.url, this.headers, this.label);
  final String url;
  final Map<String, String> headers;
  final String label;
  DateTime lastUsed = DateTime.now();
}

class CloudPlaybackProxy {
  CloudPlaybackProxy._();
  static final CloudPlaybackProxy instance = CloudPlaybackProxy._();

  HttpServer? _server;
  int _port = 0;
  final Map<String, _ProxyTask> _tasks = {};
  int _seq = 0;
  static const int _maxTasks = 8;

  HttpClient? _client;

  HttpClient get _http => _client ??= HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..autoUncompress = false;

  /// 登记直链并返回本地代理 URL（播放器用它替代真实直链）。
  Future<String> register(
    String url,
    Map<String, String> headers,
    String label,
  ) async {
    final server = await _ensureServer();
    // LRU 淘汰：只保留最近使用的少量直链，防队列长播累积泄漏。
    while (_tasks.length >= _maxTasks) {
      String? oldestKey;
      var oldest = DateTime.now();
      for (final e in _tasks.entries) {
        if (e.value.lastUsed.isBefore(oldest)) {
          oldest = e.value.lastUsed;
          oldestKey = e.key;
        }
      }
      if (oldestKey == null) break;
      _tasks.remove(oldestKey);
    }
    final token = 't${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
    _tasks[token] = _ProxyTask(url, headers, label);
    playbackChainLog(
      '[播放链路] 代理登记 $label token=…${token.substring(token.length - 4)} '
      'host=${Uri.tryParse(url)?.host ?? '解析失败'} '
      'headers=[${headers.keys.join(',')}]',
    );
    return 'http://127.0.0.1:$server/ct/$token';
  }

  Future<int> _ensureServer() async {
    final existing = _server;
    if (existing != null) return _port;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = server.port;
    _server = server;
    server.listen(_handle, onError: (Object e) {
      // 监听流异常必须进日志库：此前只 debugPrint（不落盘），若 listen
      // 流意外断掉，后续所有播放请求都会「未达代理」且无从排查。
      playbackChainLog('[播放链路] 本地代理监听异常: $e');
    });
    playbackChainLog('[播放链路] 本地代理已启动 127.0.0.1:$_port');
    return _port;
  }

  Future<void> _handle(HttpRequest req) async {
    // 入口留痕：123 CDN 曾出现播放秒失败且代理层零转发日志——若连本条
    // 都没有，说明 ExoPlayer 的请求根本没到达 HttpServer（连接层问题），
    // 而非转发层问题。播放请求频率低（每首 1~2 次 + seek），不刷屏。
    playbackChainLog(
      '[播放链路] 代理请求 ${req.method} …${req.uri.pathSegments.last} '
      'Range=${req.headers.value(HttpHeaders.rangeHeader) ?? '无'}',
    );
    try {
      final segs = req.uri.pathSegments;
      final token = segs.isNotEmpty ? segs.last : '';
      final task = _tasks[token];
      if (task == null) {
        // 本地 404 必须留痕：123 CDN 曾出现播放秒失败且代理层零日志，
        // 唯一不经转发层的路径就是 token 查不到（404 原本静默）。
        playbackChainLog(
          '[播放链路] 代理收到未知 token（本地404）path=${req.uri.path} '
          '已登记数=${_tasks.length}',
        );
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      task.lastUsed = DateTime.now();

      // 百度 d.pcs 等 CDN 对无 Range 的请求直接 403（防盗链策略：web 播放
      // 器场景恒带 Range）。无 Range 一律补 bytes=0-（HTTP 语义等价全量
      // 文件，206 响应播放器照收）。
      final range = req.headers.value(HttpHeaders.rangeHeader) ?? 'bytes=0-';
      final (resp, errBody) = await _openUpstream(task, req.method, range);

      req.response.statusCode = resp.statusCode;
      // QQ 音乐等 CDN 会对明文流返回撒谎的 Content-Type：L1 直链是
      // .flac/.mp3 内容却带 audio/x-ogg，ExoPlayer 按 Content-Type 选
      // Ogg 提取器解析非 Ogg 数据直接 (0) Source error（低品质 .mp3 +
      // audio/mpeg 正常、L2 卡密上游 Content-Type 正常，故仅部分档位
      // 复现）。改写为 application/octet-stream 让播放器按内容嗅探格式。
      final contentType = resp.headers.value(HttpHeaders.contentTypeHeader);
      if (contentType != null) {
        final path = Uri.tryParse(task.url)?.path.toLowerCase() ?? '';
        final lyingOgg = contentType.toLowerCase().contains('ogg') &&
            !path.endsWith('.ogg') &&
            !path.endsWith('.oga') &&
            !path.endsWith('.opus');
        if (lyingOgg) {
          playbackChainLog(
            '[播放链路] 代理改写撒谎Content-Type：$contentType → '
            'application/octet-stream host='
            '${Uri.tryParse(task.url)?.host ?? '未知'} 扩展名='
            '${path.isEmpty ? '无' : path.split('.').last}',
          );
        }
        req.response.headers.set(
          HttpHeaders.contentTypeHeader,
          lyingOgg ? 'application/octet-stream' : contentType,
        );
      }
      for (final name in const [
        HttpHeaders.contentLengthHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
      ]) {
        final v = resp.headers.value(name);
        if (v != null) req.response.headers.set(name, v);
      }
      req.response.bufferOutput = false;

      if (req.method == 'HEAD') {
        await resp.drain<void>();
        await req.response.close();
        return;
      }
      if (errBody != null) {
        // 4xx/5xx：响应体已被读出打日志（errno 在 body 里），改为回放
        // 该文本——播放器在此场景本就注定失败，重要的是日志留痕。
        req.response.headers.set(HttpHeaders.contentTypeHeader, 'text/plain');
        req.response.add(utf8.encode(errBody));
        await req.response.close();
        return;
      }
      // 零缓冲流式转发：CDN → Dart → 播放器逐块搬运，不整段落内存。
      await req.response.addStream(resp);
      await req.response.close();
    } catch (e) {
      // 转发层异常（TLS 握手/连接重置/上游中断）在此处对 Dart 完全可见
      // ——这是定位网盘播放失败根因的关键日志通道。
      playbackChainLog('[播放链路] 代理转发异常: $e');
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  /// 发起上游请求并跟随 3xx 重定向到底（最多 5 跳），返回最终响应。
  ///
  /// 连接超时 5s：123 CDN 实测对 Dart 网络栈的 TLS 握手会卡死无响应
  /// （connectionTimeout 只管 TCP 建连，管不到握手），而 ExoPlayer 几百
  /// ms 就放弃——代理必须更快失败并留痕。https 卡死时自动降级 http
  /// 重试一次（部分 CDN 两条通道并存）。4xx/5xx 时读出响应体打日志后
  /// 随 record 返回，此时调用方不可再消费该响应流。
  Future<(HttpClientResponse, String?)> _openUpstream(
    _ProxyTask task,
    String method,
    String range,
  ) async {
    var current = Uri.parse(task.url);
    var degraded = false;
    HttpClientResponse resp;
    for (var hop = 0;; hop++) {
      final rq = await _http.openUrl(method, current);
      rq.headers.set(HttpHeaders.rangeHeader, range);
      task.headers.forEach(rq.headers.set);
      try {
        resp = await rq.close().timeout(const Duration(seconds: 5));
      } on TimeoutException {
        if (current.scheme == 'https' && !degraded) {
          degraded = true;
          playbackChainLog(
            '[播放链路] 代理转发 ${task.label} 上游 5s 无响应，降级 http 重试 '
            'host=${current.host}',
          );
          current = current.replace(scheme: 'http');
          continue;
        }
        playbackChainLog(
          '[播放链路] 代理转发 ${task.label} 上游连接超时(5s) host=${current.host} '
          'scheme=${current.scheme}',
        );
        rethrow;
      }

      // 3xx 必须由 Dart 侧跟随：Location 多指向真实 CDN，若把重定向透传
      // 给播放器，播放器会绕开代理直连 CDN，回到 ExoPlayer TLS 兼容性
      // 问题（123 CDN 秒失败且代理层无日志的真凶）。
      if (resp.statusCode < 300 || resp.statusCode >= 400) {
        // 上游异常状态：读 body 留痕并透传（403 防盗链 / 404 过期 / 5xx）。
        if (resp.statusCode >= 400) {
          var body = '';
          try {
            body = await utf8.decodeStream(resp.cast<List<int>>());
          } catch (_) {}
          final snippet =
              body.length > 200 ? '${body.substring(0, 200)}…' : body;
          playbackChainLog(
            '[播放链路] 代理转发 ${task.label} 上游 HTTP ${resp.statusCode} '
            'host=${current.host} (Range=$range) body=$snippet',
          );
          return (resp, snippet.isEmpty ? '' : snippet);
        }
        return (resp, null);
      }
      final loc = resp.headers.value(HttpHeaders.locationHeader);
      playbackChainLog(
        '[播放链路] 代理转发 ${task.label} 上游 ${resp.statusCode} → '
        '${loc ?? '无Location'} (Range=$range)',
      );
      try {
        await resp.drain<void>();
      } catch (_) {}
      // 无 Location 或跳数耗尽：原样透传（异常场景，日志已留痕）。
      if (loc == null || loc.isEmpty || hop >= 5) return (resp, null);
      current = current.resolve(loc);
    }
  }
}
