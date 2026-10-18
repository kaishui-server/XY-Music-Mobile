// 网盘引擎统一 HTTP 出口。
//
// 全部走 [appRequest] 收口（逐跳 SSRF 校验 + 手动重定向），在其上封装
// 网盘 API 最常用的三种形态：GET/POST-JSON/POST-FORM，附统一超时与
// CloudException 错误转换。响应头由调用方自行取用。

import 'dart:async';
import 'dart:convert';

import '../core/app_http.dart';
import '../logging/app_log_store.dart';
import 'cloud_types.dart';

class CloudHttpResponse {
  CloudHttpResponse._(
      this.status, this.headers, this.body, this.setCookies, this.finalUrl);

  final int status;
  final Map<String, String> headers;
  final String body;

  /// 原始 Set-Cookie 列表（dart:io HttpHeaders.forEach 保证逐条分开）。
  final List<String> setCookies;

  /// 重定向链终点 URL（无重定向时等于请求 URL；123 直链 302 探测要用）。
  final String finalUrl;

  bool get isOk => status >= 200 && status < 300;

  /// Set-Cookie 解析成 name → value（取分号前的首段，忽略 Path/Expires 等
  /// 属性；同名后写覆盖前写，贴合浏览器语义）。
  Map<String, String> get setCookiePairs {
    final pairs = <String, String>{};
    for (final raw in setCookies) {
      final head = raw.split(';').first;
      final eq = head.indexOf('=');
      if (eq <= 0) continue;
      pairs[head.substring(0, eq).trim()] = head.substring(eq + 1).trim();
    }
    return pairs;
  }

  /// 懒解析 JSON；解析失败抛 CloudException。
  Map<String, dynamic> get json {
    try {
      final v = jsonDecode(body);
      if (v is Map<String, dynamic>) return v;
      throw const CloudException('接口返回格式异常');
    } on CloudException {
      rethrow;
    } catch (_) {
      throw const CloudException('接口返回格式异常');
    }
  }
}

/// 统一请求入口。body 优先级：json > form > raw。
Future<CloudHttpResponse> cloudRequest(
  String method,
  String url, {
  Map<String, String>? headers,
  Map<String, dynamic>? jsonBody,
  Map<String, String>? form,
  String? rawBody,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final h = <String, String>{...?headers};
  String? bodyStr;
  if (jsonBody != null) {
    h.putIfAbsent('Content-Type', () => 'application/json');
    bodyStr = jsonEncode(jsonBody);
  } else if (form != null) {
    h.putIfAbsent(
        'Content-Type', () => 'application/x-www-form-urlencoded');
    bodyStr = form.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}='
            '${Uri.encodeQueryComponent(e.value)}')
        .join('&');
  } else if (rawBody != null) {
    bodyStr = rawBody;
  }
  try {
    final resp = await appRequest(
      method,
      Uri.parse(url),
      headers: h,
      body: bodyStr,
    ).timeout(timeout);
    final setCookies = <String>[];
    final headerMap = <String, String>{};
    resp.headers.forEach((name, values) {
      if (name.toLowerCase() == 'set-cookie') {
        setCookies.addAll(values);
      } else {
        headerMap[name] = values.join(', ');
      }
    });
    final respBody = await utf8.decodeStream(resp);
    // appRequest 手动跟随重定向，resp.redirects 记录每跳 Location（可能
    // 是相对地址），逐跳 resolve 得到最终落点。
    var finalUri = Uri.parse(url);
    for (final r in resp.redirects) {
      finalUri = finalUri.resolve(r.location.toString());
    }
    return CloudHttpResponse._(
        resp.statusCode, headerMap, respBody, setCookies, finalUri.toString());
  } on CloudException {
    rethrow;
  } on TimeoutException {
    throw const CloudException('请求超时');
  } catch (e) {
    throw CloudException('网络请求失败: $e');
  }
}

Future<CloudHttpResponse> cloudGet(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 15),
}) =>
    cloudRequest('GET', url, headers: headers, timeout: timeout);

Future<CloudHttpResponse> cloudPostJson(
  String url, {
  Map<String, dynamic>? body,
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 15),
}) =>
    cloudRequest('POST', url,
        jsonBody: body, headers: headers, timeout: timeout);

Future<CloudHttpResponse> cloudPostForm(
  String url,
  Map<String, String> form, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 15),
}) =>
    cloudRequest('POST', url, form: form, headers: headers, timeout: timeout);

/// 组合 query 参数（跳过 null/空值）。
String joinQuery(Map<String, String?> params) {
  final q = <String>[];
  params.forEach((k, v) {
    if (v != null && v.isNotEmpty) {
      q.add('${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent(v)}');
    }
  });
  return q.isEmpty ? '' : '?${q.join('&')}';
}

/// 凭据 Cookie 键值拼请求头（各盘 cred 存 'cookie' 单键整串时用另一形态）。
String cookieHeader(Map<String, String> pairs) =>
    pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');

/// 从接口响应里提炼可读的错误摘要（HTTP 状态 + 业务 code/message）。
///
/// 登录/会话校验失败时把服务端真实返回透出到 toast，便于定位「捕获到
/// 凭据但校验不过」这类问题（如 UC 的 31001 require login）。
String respErrorDetail(CloudHttpResponse resp) {
  final parts = <String>['HTTP ${resp.status}'];
  try {
    final v = jsonDecode(resp.body);
    if (v is Map) {
      final code = v['code'] ?? v['errorCode'] ?? v['errno'] ?? v['error'];
      final msg = v['message'] ??
          v['msg'] ??
          v['error_description'] ??
          v['errorMessage'] ??
          v['error_msg'];
      if (code != null) parts.add('code=$code');
      if (msg != null && '$msg'.trim().isNotEmpty) parts.add('$msg'.trim());
    }
  } catch (_) {
    // 非 JSON 响应体：只透出 HTTP 状态。
  }
  return parts.join(' ');
}

/// 跟随重定向归一到最终 URL（直链注册代理前用；只读 redirects，
/// 不消费响应体）。失败原样返回并留痕——此前静默吞错，导致「探测成功」
/// 从未被日志佐证，直链 403 时无法判断探测环节是否可用。
Future<String> resolveFinalUrl(String url, {Map<String, String>? headers}) async {
  final host = Uri.tryParse(url)?.host ?? '?';
  try {
    final resp = await appRequest(
      'GET',
      Uri.parse(url),
      // Range 限 1 字节：终点响应若直接是文件体（下发的已是最终地址），
      // 不带 Range 会把整个文件拖进内存再丢弃。
      headers: {...?headers, 'Range': 'bytes=0-1'},
      body: '',
    );
    final redirects = resp.redirects;
    await resp.drain<void>();
    if (redirects.isEmpty) {
      AppLogStore.instance.add(
        '[直链探测] $host 无重定向 status=${resp.statusCode}（直连落地）',
      );
      return url;
    }
    var finalUri = Uri.parse(url);
    for (final r in redirects) {
      finalUri = finalUri.resolve(r.location.toString());
    }
    AppLogStore.instance.add(
      '[直链探测] $host ${resp.statusCode} 重定向${redirects.length}跳 '
      '→ ${finalUri.host}',
    );
    return finalUri.toString();
  } catch (e) {
    // 失败原样返回（调用方仍会拿原 URL 注册播放），但必须留痕：
    // 探测失败 = 「Dart 栈可访问该直链」的假设不成立，是播放 403/
    // Source error 排查的关键线索。
    AppLogStore.instance.add('[直链探测] $host 失败: $e（回退原URL）');
    return url;
  }
}
