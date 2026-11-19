// 极简 WebDAV 客户端：只覆盖备份/恢复需要的 5 个动作——确保目录、
// 上传、下载、列目录、删除。基于项目已依赖的 http 包实现（不引入
// 新的第三方库），鉴权仅支持 Basic（坚果云等主流网盘均适用）。
//
// 错误统一抛出 [WebdavException]，文案已本地化到用户可读级别：
// 401/403 → 账号或密码错误，404 → 服务器上不存在该路径，其余非 2xx
// 带原始状态码，便于用户区分是配置问题还是服务端问题。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// WebDAV 操作失败（网络、鉴权、服务端状态码等），message 可直接展示。
///
/// [statusCode] 为服务端原始状态码（网络类异常时为 null），供调用方按
/// 状态码分流，避免依赖本地化后的文案做字符串比较。
class WebdavException implements Exception {
  const WebdavException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// 远端目录下的一个文件条目。
class WebdavEntry {
  const WebdavEntry({
    required this.name,
    required this.path,
    required this.size,
    this.modified,
    this.isDirectory = false,
  });

  /// 文件名（已 URL 解码）。
  final String name;

  /// 相对服务器地址的路径，形如 `XYMusic/xxx.json`。
  final String path;

  /// 文件字节数（服务端未提供时为 0）。
  final int size;

  /// 最后修改时间（服务端未提供时为 null）。
  final DateTime? modified;

  final bool isDirectory;
}

class WebdavClient {
  WebdavClient({
    required String serverUrl,
    required this.username,
    required this.password,
    http.Client? httpClient,
  }) : baseUrl = _normalizeBaseUrl(serverUrl),
       _http = httpClient ?? http.Client();

  /// 归一化后的服务器地址（必定以 `/` 结尾）。
  final String baseUrl;
  final String username;
  final String password;
  final http.Client _http;

  static const Duration _timeout = Duration(seconds: 30);

  /// 只取目录/条目自身的属性，Depth 由调用方指定。
  static const String _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:">'
      '<d:prop>'
      '<d:getlastmodified/>'
      '<d:getcontentlength/>'
      '<d:resourcetype/>'
      '</d:prop>'
      '</d:propfind>';

  /// 缺协议时补 https，缺结尾斜杠时补上，并收敛路径中的重复斜杠，
  /// 避免拼接出 `…/dav//` 这类服务器不认的地址。
  static String _normalizeBaseUrl(String value) {
    var url = value.trim();
    if (url.isEmpty) return '';
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    // 用户常见粘贴错误：`https://host/dav//`。坚果云实测 `/dav/` 返回
    // 207，`/dav//` 返回 404，故在入口把路径里的连续斜杠压成一个，
    // 协议后的 `//` 保持不变。
    final schemeEnd = url.indexOf('://');
    final head = schemeEnd >= 0 ? url.substring(0, schemeEnd + 3) : '';
    final rest = (schemeEnd >= 0 ? url.substring(schemeEnd + 3) : url)
        .replaceAll(RegExp(r'/{2,}'), '/');
    url = '$head$rest';
    if (!url.endsWith('/')) url = '$url/';
    return url;
  }

  /// 地址与账号是否已填写（密码允许为空，部分服务器匿名可写）。
  bool get isConfigured => baseUrl.isNotEmpty && username.isNotEmpty;

  Map<String, String> get _authHeaders => {
    'Authorization':
        'Basic ${base64Encode(utf8.encode('$username:$password'))}',
  };

  /// 相对路径 → 完整 Uri（按路径段编码，保留目录层级）。
  ///
  /// 根路径必须原样返回 [baseUrl]：baseUrl 自身已以单个 `/` 结尾，
  /// 若再补一个 `/` 会拼出 `…/dav//`，坚果云这类服务器会直接返回 404
  /// （实测 `/dav/` 207、`/dav//` 404），导致「保存配置」误报
  /// 「服务器上不存在该路径」。
  Uri _uri(String relativePath) {
    final hasTrailingSlash = relativePath.endsWith('/');
    final segments = relativePath
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    if (segments.isEmpty) return Uri.parse(baseUrl);
    final suffix = hasTrailingSlash ? '/' : '';
    return Uri.parse('$baseUrl$segments$suffix');
  }

  Future<http.Response> _send(
    String method,
    String relativePath, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    if (!isConfigured) {
      throw const WebdavException('请先填写服务器地址与账号');
    }
    final request = http.Request(method, _uri(relativePath))
      ..headers.addAll(_authHeaders)
      ..headers.addAll(headers);
    if (body != null) request.bodyBytes = utf8.encode(body);
    try {
      final streamed = await _http.send(request).timeout(_timeout);
      return await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw const WebdavException('连接超时，请检查网络或服务器地址');
    } on SocketException {
      throw const WebdavException('无法连接服务器，请检查网络或服务器地址');
    } on HandshakeException {
      throw const WebdavException('HTTPS 握手失败，请检查服务器地址与证书');
    } on http.ClientException catch (error) {
      throw WebdavException('网络请求失败：${error.message}');
    }
  }

  /// 非 2xx 统一映射为用户可读错误。
  void _ensureSuccess(http.Response response, String action) {
    final code = response.statusCode;
    if (code >= 200 && code < 300) return;
    switch (code) {
      case 401:
      case 403:
        throw WebdavException('账号或密码错误', statusCode: code);
      case 404:
        throw WebdavException('服务器上不存在该路径', statusCode: code);
      case 507:
        throw WebdavException('服务器存储空间不足', statusCode: code);
    }
    throw WebdavException('$action失败（HTTP $code）', statusCode: code);
  }

  /// 连通性校验：对服务器根目录做 Depth:0 的 PROPFIND。
  ///
  /// 部分服务端不允许对根目录做 PROPFIND（返回 404/405），此时回退
  /// 到 OPTIONS 判定连通性，避免把「服务器不给列根目录」误报成
  /// 「路径不存在」。
  Future<void> ping() async {
    final response = await _send(
      'PROPFIND',
      '',
      headers: const {
        'Depth': '0',
        'Content-Type': 'application/xml; charset=utf-8',
      },
      body: _propfindBody,
    );
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    if (response.statusCode == 404 || response.statusCode == 405) {
      final fallback = await _send('OPTIONS', '');
      if (fallback.statusCode >= 200 && fallback.statusCode < 300) return;
      _ensureSuccess(fallback, '连接服务器');
    }
    _ensureSuccess(response, '连接服务器');
  }

  /// 确保目录存在：不存在时 MKCOL 创建（已存在返回 405，视为成功）。
  Future<void> ensureDirectory(String directory) async {
    final dir = directory.endsWith('/') ? directory : '$directory/';
    final probe = await _send(
      'PROPFIND',
      dir,
      headers: const {
        'Depth': '0',
        'Content-Type': 'application/xml; charset=utf-8',
      },
      body: _propfindBody,
    );
    if (probe.statusCode >= 200 && probe.statusCode < 300) return;
    if (probe.statusCode == 401 || probe.statusCode == 403) {
      throw WebdavException('账号或密码错误', statusCode: probe.statusCode);
    }
    if (probe.statusCode != 404) {
      throw WebdavException(
        '读取远端目录失败（HTTP ${probe.statusCode}）',
        statusCode: probe.statusCode,
      );
    }
    final created = await _send(
      'MKCOL',
      dir,
      headers: const {'Content-Type': 'application/xml; charset=utf-8'},
    );
    // 405 = 目录已存在（并发或其他客户端刚建好），视为成功。
    if (created.statusCode == 405) return;
    _ensureSuccess(created, '创建远端目录');
  }

  /// 上传文件（UTF-8 JSON 文本）。
  Future<void> uploadFile(
    String remotePath,
    String content, {
    String contentType = 'application/json; charset=utf-8',
  }) async {
    final response = await _send(
      'PUT',
      remotePath,
      headers: {'Content-Type': contentType},
      body: content,
    );
    _ensureSuccess(response, '上传备份');
  }

  /// 下载文件，按 UTF-8 解码返回文本。
  Future<String> downloadFile(String remotePath) async {
    final response = await _send('GET', remotePath);
    _ensureSuccess(response, '下载备份');
    try {
      return utf8.decode(response.bodyBytes);
    } on FormatException {
      throw const WebdavException('远端备份文件编码异常，无法解析');
    }
  }

  /// 列出目录下的文件（Depth:1，不含子目录本身）。
  ///
  /// 服务端不支持 PROPFIND 时抛 [WebdavException]。
  Future<List<WebdavEntry>> listFiles(String directory) async {
    final dir = directory.endsWith('/') ? directory : '$directory/';
    final response = await _send(
      'PROPFIND',
      dir,
      headers: const {
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
      },
      body: _propfindBody,
    );
    _ensureSuccess(response, '读取远端备份列表');
    final entries = _parsePropfind(response.bodyBytes, dir);
    return entries.where((entry) => !entry.isDirectory).toList();
  }

  /// 删除远端文件；文件已不存在（404）时静默成功。
  Future<void> deleteFile(String remotePath) async {
    final response = await _send('DELETE', remotePath);
    if (response.statusCode == 404) return;
    _ensureSuccess(response, '删除远端备份');
  }

  static final RegExp _responseTag = RegExp(
    r'<(?:[A-Za-z0-9_.-]+:)?response\b[^>]*>(.*?)</(?:[A-Za-z0-9_.-]+:)?response>',
    dotAll: true,
  );

  static final RegExp _hrefTag = RegExp(
    r'<(?:[A-Za-z0-9_.-]+:)?href\b[^>]*>(.*?)</(?:[A-Za-z0-9_.-]+:)?href>',
    dotAll: true,
  );

  static final RegExp _lastModifiedTag = RegExp(
    r'<(?:[A-Za-z0-9_.-]+:)?getlastmodified\b[^>]*>(.*?)</(?:[A-Za-z0-9_.-]+:)?getlastmodified>',
    dotAll: true,
  );

  static final RegExp _contentLengthTag = RegExp(
    r'<(?:[A-Za-z0-9_.-]+:)?getcontentlength\b[^>]*>(.*?)</(?:[A-Za-z0-9_.-]+:)?getcontentlength>',
    dotAll: true,
  );

  static final RegExp _isCollectionTag = RegExp(
    r'<(?:[A-Za-z0-9_.-]+:)?collection\b',
  );

  /// 解析 PROPFIND 响应：[requestedDir] 用于把 href 换算成相对路径。
  List<WebdavEntry> _parsePropfind(List<int> bodyBytes, String requestedDir) {
    final text = utf8.decode(bodyBytes, allowMalformed: true);
    final entries = <WebdavEntry>[];
    for (final match in _responseTag.allMatches(text)) {
      final block = match.group(1) ?? '';
      final href = _hrefTag.firstMatch(block)?.group(1)?.trim();
      if (href == null || href.isEmpty) continue;
      final isDirectory = href.endsWith('/') || _isCollectionTag.hasMatch(block);
      // href 可能是完整 URL 或绝对路径，统一取 path 部分。
      final uri = Uri.tryParse(href);
      final rawPath = uri?.path ?? href;
      final decodedSegments = rawPath
          .split('/')
          .where((segment) => segment.isNotEmpty)
          .map((segment) {
            try {
              return Uri.decodeComponent(segment);
            } catch (_) {
              return segment;
            }
          })
          .toList();
      if (decodedSegments.isEmpty) continue;
      final name = decodedSegments.last;
      // 目录自身的条目也会出现在 Depth:1 结果里，跳过（同一目录下不会
      // 出现同名子目录，此判断不会误伤备份文件）。
      if (isDirectory && name == _lastSegment(requestedDir)) continue;
      final lengthText = _contentLengthTag.firstMatch(block)?.group(1)?.trim();
      final modifiedText = _lastModifiedTag.firstMatch(block)?.group(1)?.trim();
      entries.add(
        WebdavEntry(
          name: name,
          path: decodedSegments.join('/'),
          size: int.tryParse(lengthText ?? '') ?? 0,
          modified: modifiedText == null
              ? null
              : _parseHttpDate(modifiedText),
          isDirectory: isDirectory,
        ),
      );
    }
    return entries;
  }

  /// HTTP 日期（RFC 1123，如 `Wed, 19 Nov 2026 09:30:00 GMT`）。
  static DateTime? _parseHttpDate(String value) {
    try {
      return HttpDate.parse(value);
    } catch (_) {
      return DateTime.tryParse(value);
    }
  }

  /// 路径的最后一段（空路径返回空串）。
  static String _lastSegment(String path) {
    final segments = path
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    return segments.isEmpty ? '' : segments.last;
  }
}
