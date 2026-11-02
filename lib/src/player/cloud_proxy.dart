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
import 'qmc_crypto.dart';

class _ProxyTask {
  _ProxyTask(this.url, this.headers, this.label, this.ekey);
  final String url;
  final Map<String, String> headers;
  final String label;

  /// QQ 音乐 QMC ekey（base64）：非空时转发流逐块解密（qmc_crypto）。
  final String? ekey;
  Uint8List? _rawKeyCache;

  /// ekey → raw key（TEA 解密），每任务只算一次。
  Uint8List resolveRawKey() {
    return _rawKeyCache ??= decryptEKey(ekey!);
  }

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
  ///
  /// [ekey] 非空时（QQ QMC 加密流）转发时逐块解密。
  Future<String> register(
    String url,
    Map<String, String> headers,
    String label, {
    String? ekey,
  }) async {
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
    _tasks[token] = _ProxyTask(url, headers, label, ekey);
    playbackChainLog(
      '[播放链路] 代理登记 $label token=…${token.substring(token.length - 4)} '
      'host=${Uri.tryParse(url)?.host ?? '解析失败'} '
      'headers=[${headers.keys.join(',')}]'
      '${ekey != null ? ' QMC加密流' : ''}',
    );
    // 代理路径携带真实文件名（含扩展名）：ExoPlayer 优先按 URI 扩展名
    // 选择提取器（flac/mp3/ogg...），即使 CDN 对明文流返回撒谎的
    // Content-Type（如 QQ L1 直链 fLaC 内容带 audio/x-ogg）也能正确
    // 解码，不依赖响应头与嗅探。
    final segments = Uri.tryParse(url)?.pathSegments ?? const <String>[];
    final filename =
        segments.isNotEmpty ? segments.last : 'audio';
    return 'http://127.0.0.1:$server/ct/$token/$filename';
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
      // 路径形态 /ct/<token>/<filename>（新版带文件名供播放器按扩展名
      // 选提取器），兼容旧形态 /ct/<token>：token 在文件名前一位。
      final token =
          segs.length > 2 ? segs[segs.length - 2] : (segs.isNotEmpty ? segs.last : '');
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
      // 零缓冲流式转发 + 断流接力：CDN → Dart → 播放器逐块搬运，不整段
      // 落内存。QQ ws.stream 等 CDN 会中途掐断 Dart 网络栈的连接（实测
      // ~10s 掐一次：Connection closed while receiving data），单次转发
      // 会把提前 EOF 透传给播放器，表现为「播到某节点突然无声卡死」。
      // 改为逐块接力：上游断流后按已转发偏移发起新 Range 请求续传，
      // 直到本段内容完整或重试耗尽。QMC 加密流（QQ *.mflac）逐块原位
      // 解密，解密起点 = Content-Range bytes N-M/T 的 N（200 全量则 0），
      // RC4/MapL 按全局 offset 定位密钥流，续传/seek 的 Range 同样正确。
      var start = 0;
      final cr = resp.headers.value(HttpHeaders.contentRangeHeader);
      final m = RegExp(r'bytes\s+(\d+)-').firstMatch(cr ?? '');
      if (m != null) start = int.parse(m.group(1)!);
      await _relayResponse(req, task, resp, start);
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

  /// 单响应接力转发：把上游数据逐块搬运给播放器。
  ///
  /// 上游中途断流（Connection closed while receiving data）时，按已转发
  /// 的绝对偏移重新发起 Range 请求续传（每次重连是一条新 TCP 连接，
  /// CDN 掐的是连接而非 URL），直到本段声明的长度转发完整或重试耗尽。
  /// QMC 流逐块解密（绝对偏移定位密钥流）。逐块 flush 提供背压，防止
  /// 播放器消费慢时响应缓冲无限堆积。
  Future<void> _relayResponse(
    HttpRequest req,
    _ProxyTask task,
    HttpClientResponse first,
    int startOffset,
  ) async {
    final decoder = task.ekey != null
        ? QmcDecoder.fromRawKey(task.resolveRawKey())
        : null;
    if (decoder != null) {
      playbackChainLog(
        '[播放链路] QMC 解密启动 offset=$startOffset '
        'keyLen=${task.resolveRawKey().length}',
      );
    }
    // 本段目标长度：首个响应声明的 Content-Length（206 时为剩余段长，
    // 200 为全量；chunked 为 -1，仅靠正常 EOF 判断）。
    final declared = first.contentLength;
    var resp = first;
    var offset = startOffset; // 本段起点在完整文件中的绝对偏移
    var consumed = 0; // 当前接力段已转发字节
    var attempts = 0;
    while (true) {
      var broken = false;
      var writeBroken = false;
      try {
        await for (final chunk in resp) {
          var buf = Uint8List.fromList(chunk);
          if (decoder != null) {
            decoder.decryptChunk(buf, offset + consumed);
          }
          consumed += buf.length;
          req.response.add(buf);
          try {
            await req.response.flush();
          } catch (_) {
            // 播放器侧断开（切歌/seek abort）：立即停止搬运，不接力。
            writeBroken = true;
            break;
          }
        }
      } catch (e) {
        broken = true;
      }
      if (writeBroken) return;
      // 完成判断：累计绝对偏移（offset 跨接力段推进，consumed 每段重置）
      // 达到首个响应声明的段尾即完整——断流发生在段尾属正常收尾。
      final totalDone = offset + consumed;
      if (declared >= 0 && totalDone >= startOffset + declared) {
        return;
      }
      if (!broken && declared < 0) {
        // chunked（无长度声明）正常 EOF：直接结束。
        return;
      }
      // 段未转发完（上游提前 EOF 或断流）：接力续传。
      attempts++;
      if (attempts > 10) {
        playbackChainLog(
          '[播放链路] 代理接力失败：重试达上限（$attempts 次）'
          'offset=$totalDone/'
          '${declared < 0 ? '?' : startOffset + declared}',
        );
        return;
      }
      final resumeAt = totalDone;
      playbackChainLog(
        '[播放链路] 上游断流，接力续传 #$attempts '
        'offset=$resumeAt/段长=${declared < 0 ? '?' : declared} '
        'host=${Uri.tryParse(task.url)?.host ?? '未知'}'
        '${broken ? '' : '（提前EOF）'}',
      );
      final (next, errBody) = await _openUpstream(
        task,
        req.method,
        'bytes=$resumeAt-',
      );
      if (errBody != null) {
        playbackChainLog(
          '[播放链路] 代理接力终止：上游续传失败 HTTP '
          '${next.statusCode} offset=$resumeAt',
        );
        return;
      }
      resp = next;
      consumed = 0;
      offset = resumeAt;
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
