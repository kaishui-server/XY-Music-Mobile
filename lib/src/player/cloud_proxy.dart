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

import '../logging/app_log_store.dart';
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

  /// 已解析的真实 CDN 直链（跟随 302 后的最终 URL）及解析时刻。
  ///
  /// 播放器息屏/后台后 AudioSink 失活重建会重新请求代理（无 Range 全量），
  /// 接力续传也会频繁开新连接——若每次都从原始 dlink 重新跟随 302，百度
  /// PCS 的重定向应答 + CDN 边缘建连在非会员限速时段要额外等 1~3s，叠加
  /// 首字节排队就是「无声几秒」。缓存最终 URL（TTL 5 分钟，保守低于
  /// dlink 签名有效期；任何 4xx/5xx/超时立即失效）后，重建/接力直接连
  /// CDN 边缘，显著缩短无声期。
  String? resolvedUrl;
  DateTime? resolvedAt;

  bool get resolvedFresh {
    final at = resolvedAt;
    return resolvedUrl != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 5);
  }

  void invalidateResolved() {
    resolvedUrl = null;
    resolvedAt = null;
  }
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

  /// 转发异常日志去重：断网/网络切换瞬间，同一代理任务的多条并发转发
  /// 连接会各自抛出相同异常（荣耀 AAP-AN00 实测 10ms 内 7 条 Connection
  /// closed），逐条落盘只会刷屏。2s 窗口内相同文本只记 1 条，窗口关闭
  /// 时补一条抑制计数。
  final Map<String, ({DateTime at, int suppressed})> _recentProxyErrors = {};

  void _logProxyError(String message) {
    final now = DateTime.now();
    final recent = _recentProxyErrors[message];
    if (recent != null &&
        now.difference(recent.at) < const Duration(seconds: 2)) {
      _recentProxyErrors[message] = (at: recent.at, suppressed: recent.suppressed + 1);
      return;
    }
    final suppressed = recent?.suppressed ?? 0;
    _recentProxyErrors[message] = (at: now, suppressed: 0);
    // 防表无限增长：文本种类异常多时清掉早已过窗口的旧键。
    if (_recentProxyErrors.length > 16) {
      _recentProxyErrors.removeWhere(
        (_, v) => now.difference(v.at) >= const Duration(seconds: 10),
      );
    }
    playbackChainLog(
      suppressed > 0 ? '$message（此前抑制 $suppressed 条重复）' : message,
    );
  }

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
    // 文件名必须单段编码：音乐文件名常含空格、#、?、%、& 等字符，
    // 直接拼进 URL 会截断 path（# 起 fragment），播放器请求落到未知
    // token 被代理 404，表现即 ExoPlayer「(0) Source error」。
    return 'http://127.0.0.1:$server/ct/$token/'
        '${Uri.encodeComponent(filename)}';
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

      // 日志打点⑧：ExoPlayer 在 AudioSink 失活或内部 reset 后会重新发起
      // 一次不带 Range 的全量请求（实测两次失活后各出现一次，且均紧跟
      // 191s / 188s 的后台窗口）。这条请求本身无害，但它是「音频链路已被
      // 播放器内部重置」的可靠信号，升级为 warning 便于事后与停播时刻对时。
      if (req.headers.value(HttpHeaders.rangeHeader) == null) {
        AppLogStore.instance.add(
          '[播放链路] 播放中收到全量 Range=无 请求（疑似 ExoPlayer reset）'
          'path=${req.uri.path}',
          level: AppLogLevel.warning,
        );
      }

      // 百度 d.pcs 等 CDN 对无 Range 的请求直接 403（防盗链策略：web 播放
      // 器场景恒带 Range）。无 Range 一律补 bytes=0-（HTTP 语义等价全量
      // 文件，206 响应播放器照收）。
      final range = req.headers.value(HttpHeaders.rangeHeader) ?? 'bytes=0-';
      final (resp, errBody) = await _openUpstream(
        task,
        req.method,
        range,
        firstByteTimeout: const Duration(seconds: 20),
      );

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
      final complete = await _relayResponse(req, task, resp, start);
      if (!complete) {
        // 已声明的段长没能写完就收尾，播放器会把这条响应当成「正常结束的
        // 短文件」——ExoPlayer 侧表现为读越界/源解析失败，随后整曲重载、
        // 进度条回到开头。这里主动断开连接，让播放器按「网络中断」重试
        // 当前 Range，位置得以保住（这是「卡顿几秒 + 进度复位」循环的
        // 第二个成因，第一个在播放器侧的断流恢复）。
        try {
          final socket = await req.response.detachSocket(writeHeaders: false);
          socket.destroy();
          playbackChainLog(
            '[播放链路] 代理接力未完成，主动断开连接交由播放器按 Range 重试',
          );
          return;
        } catch (_) {
          // detach 失败（响应已提交/已分离）：退回正常关闭。
        }
      }
      await req.response.close();
    } catch (e) {
      // 转发层异常（TLS 握手/连接重置/上游中断）在此处对 Dart 完全可见
      // ——这是定位网盘播放失败根因的关键日志通道。断网瞬间多条并发
      // 连接抛相同异常，经去重节流后落盘。
      _logProxyError('[播放链路] 代理转发异常: $e');
      // 与接力失败同源的处理：只要响应头已按上游声明的 Content-Length
      // 交给播放器，就不能用 close() 草草收尾——播放器会把「长度不足的
      // 正常结束」当成完整响应，随后源解析失败重载（进度条复位）。中断
      // 连接可让播放器以网络错误重试当前 Range。
      try {
        final socket = await req.response.detachSocket(writeHeaders: false);
        socket.destroy();
      } catch (_) {
        try {
          await req.response.close();
        } catch (_) {}
      }
    }
  }

  /// 单响应接力转发：把上游数据逐块搬运给播放器。
  ///
  /// 上游中途断流（Connection closed while receiving data）时，按已转发
  /// 的绝对偏移重新发起 Range 请求续传（每次重连是一条新 TCP 连接，
  /// CDN 掐的是连接而非 URL），直到本段声明的长度转发完整或重试耗尽。
  /// QMC 流逐块解密（绝对偏移定位密钥流）。逐块 flush 提供背压，防止
  /// 播放器消费慢时响应缓冲无限堆积。
  ///
  /// 返回值：本段是否已完整转发（true 表示可以正常收尾；false 表示还有
  /// 已声明的字节没发出，调用方必须中断连接而不是静默结束）。
  Future<bool> _relayResponse(
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
      if (writeBroken) return true;
      // 完成判断：累计绝对偏移（offset 跨接力段推进，consumed 每段重置）
      // 达到首个响应声明的段尾即完整——断流发生在段尾属正常收尾。
      final totalDone = offset + consumed;
      if (declared >= 0 && totalDone >= startOffset + declared) {
        return true;
      }
      if (!broken && declared < 0) {
        // chunked（无长度声明）正常 EOF：直接结束。
        return true;
      }
      // 段未转发完（上游提前 EOF 或断流）：接力续传。
      attempts++;
      if (attempts > 10) {
        playbackChainLog(
          '[播放链路] 代理接力失败：重试达上限（$attempts 次）'
          'offset=$totalDone/'
          '${declared < 0 ? '?' : startOffset + declared}',
        );
        return false;
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
        // 续传等待预算不能沿用「接力 5s」的老值：百度 PCS 在非会员时段
        // 首字节迟到 5s 以上属常态，5s 超时会让一次普通的慢响应直接
        // 变成断流，播放器随即重载（卡顿 + 进度复位）。
        firstByteTimeout: const Duration(seconds: 12),
      );
      if (errBody != null) {
        playbackChainLog(
          '[播放链路] 代理接力终止：上游续传失败 HTTP '
          '${next.statusCode} offset=$resumeAt',
        );
        return false;
      }
      // 续传响应必须真的从 resumeAt 开始。CDN 忽略 Range 返回 200 全量
      // 时若继续按 offset=resumeAt 写，播放器收到的是从头开始的字节，
      // 整段错位后解码出垃圾并报错重载——这正是「周期性卡顿 + 进度条
      // 复位」最难查的一种形态，宁可直接放弃这一次接力。
      if (next.statusCode != HttpStatus.partialContent) {
        playbackChainLog(
          '[播放链路] 代理接力终止：续传响应非 206（HTTP ${next.statusCode}）'
          'offset=$resumeAt，放弃本次接力交播放器重试',
        );
        try {
          await next.drain<void>();
        } catch (_) {}
        return false;
      }
      final nextRange = next.headers.value(HttpHeaders.contentRangeHeader);
      final nextMatch =
          RegExp(r'bytes\s+(\d+)-').firstMatch(nextRange ?? '');
      final nextStart = nextMatch != null ? int.parse(nextMatch.group(1)!) : -1;
      if (nextStart != resumeAt) {
        playbackChainLog(
          '[播放链路] 代理接力终止：续传起点不符（期望 $resumeAt，'
          '实际 ${nextStart < 0 ? '无 Content-Range' : nextStart}），'
          '放弃本次接力交播放器重试',
        );
        try {
          await next.drain<void>();
        } catch (_) {}
        return false;
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
    String range, {
    // 首包等待预算（等响应头，不含 TCP 建连）：首跳 20s、接力续传 5s。
    // 百度 PCS 在非会员时段由限速边缘（chunlei/ant）应答，首字节迟到
    // 5s 以上属常态；旧值统一 5s 会把「慢」误判成「失败」，代理当场
    // 抛超时，ExoPlayer 侧只能表现为 (0) Source error / 起播超时。
    Duration firstByteTimeout = const Duration(seconds: 5),
  }) async {
    // 复用已解析的 CDN 直链：省掉 302 跳转与重复建连（详见 _ProxyTask
    // resolvedUrl 注释）。首次请求/缓存过期/上次失败时从原始 dlink 起跳。
    var current =
        (task.resolvedFresh ? Uri.parse(task.resolvedUrl!) : Uri.parse(task.url));
    if (task.resolvedFresh) {
      playbackChainLog(
        '[播放链路] 代理复用已解析CDN直链 host=${current.host} '
        '（免302重定向）Range=$range',
      );
    }
    var degraded = false;
    HttpClientResponse resp;
    for (var hop = 0;; hop++) {
      final rq = await _http.openUrl(method, current);
      // 先注入上游业务头（UA/Referer/Cookie），再设置 Range：顺序反了的话
      // task.headers 里若带 Range（部分音源下发的头会透传原始 Range），
      // 会覆盖掉本次接力/seek 需要的区间，续传从错误偏移取数，播放器收到
      // 错位字节后解码失败重载，表现为周期性卡顿 + 进度条复位。
      task.headers.forEach(rq.headers.set);
      rq.headers.set(HttpHeaders.rangeHeader, range);
      try {
        resp = await rq.close().timeout(firstByteTimeout);
      } on TimeoutException {
        // 百度 CDN 只认真实 https 通道：降级 http 只会换回 403，
        // 把「慢」变成「死」，因此不对 pan.baidu.com / baidupcs 系域名降级。
        final isBaidu = current.host.contains('baidu');
        // 超时说明缓存的直链可能已被边缘节点下线：失效缓存，下次重走 302。
        task.invalidateResolved();
        if (current.scheme == 'https' && !degraded && !isBaidu) {
          degraded = true;
          playbackChainLog(
            '[播放链路] 代理转发 ${task.label} 上游 '
            '${firstByteTimeout.inSeconds}s 无响应，降级 http 重试 '
            'host=${current.host}',
          );
          current = current.replace(scheme: 'http');
          continue;
        }
        playbackChainLog(
          '[播放链路] 代理转发 ${task.label} 上游连接超时'
          '(${firstByteTimeout.inSeconds}s) host=${current.host} '
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
          // 直链可能已过期/被风控：失效缓存，下次重走 302 换新签名链。
          task.invalidateResolved();
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
        // 成功（200/206）：记下最终 CDN URL 供后续请求免 302 复用。
        task.resolvedUrl = current.toString();
        task.resolvedAt = DateTime.now();
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
