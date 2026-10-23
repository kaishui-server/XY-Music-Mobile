import 'dart:convert';

import 'package:http/http.dart' as http;

/// QQ 音乐 Source API 通道（与 MusicFree L1/L2 插件同一解析服务）。
///
/// 洛雪音源脚本对 QQ（tx）歌曲的解析在 L1/L2 音源更新后全档失效；
/// Source API 走服务端 vkey 直链，实测 encrypted=0 返回明文 URL
/// （.flac/.mp3，无 ekey），支持母带/全景声/全景声2.0/杜比等全部档位。
/// 播放侧无需任何特殊请求头（Range 探测 206 直连可用）。
class QqSourceApiResult {
  final String url;
  final String filename;
  final String qualityName;

  /// 服务端返回的实际文件码率（kbps），仅供诊断。
  final int? bitrate;

  /// encrypted=1 时服务端下发解密密钥；本通道固定 encrypted=0 明文，
  /// 该字段仅作透传保留。
  final String ekey;

  const QqSourceApiResult({
    required this.url,
    required this.filename,
    required this.qualityName,
    required this.bitrate,
    required this.ekey,
  });

  bool get isEncrypted => ekey.trim().isNotEmpty;
}

/// Source API 调用失败（网络异常或业务 code 非 0）。
/// 携带 HTTP 状态与业务 message，便于在错误提示中透出根因。
class QqSourceApiException implements Exception {
  final String message;
  QqSourceApiException(this.message);

  @override
  String toString() => 'QQ音乐Source API：$message';
}

class QqSourceApi {
  /// 与 L1/L2 插件一致的默认接口地址。
  static const String defaultApiUrl = 'https://qm.xww.ccwu.cc/api/source/song';

  /// 本项目音质 token → Source API quality ID。
  /// 对齐 L1/L2 插件 qualityToSourceApi 映射；flac24bit/hires 同为
  /// QQ Hi-Res 档，atmos/atmos_plus 对应服务端 galaxy/galaxy51。
  static String? mapQuality(String quality) {
    final lower = quality.trim().toLowerCase();
    switch (lower) {
      case '96k':
      case 'low':
        return 'ogg96';
      case '128k':
      case 'standard':
        return 'mp3128';
      case '192k':
        return 'aac192';
      case '320k':
      case 'high':
        return 'mp3320';
      case 'flac':
      case 'lossless':
      case 'sq':
      case 'super':
        return 'flac';
      case 'flac24bit':
      case 'hires':
      case 'hi-res':
        return 'hires';
      case 'vinyl':
        return 'vinyl';
      case 'dolby':
        return 'dolby';
      case 'atmos':
        return 'galaxy';
      case 'atmos_plus':
        return 'galaxy51';
      default:
        if (lower.contains('master')) return 'master';
        return null;
    }
  }

  /// 解析 QQ 歌曲指定音质的明文直链。
  ///
  /// [songId] 传 songmid（含字母）或纯数字 songid，服务端自动识别。
  /// 成功返回 [QqSourceApiResult]；业务失败（该档无货 code!=0、url 为空）
  /// 或网络失败抛 [QqSourceApiException]，由调用方决定是否回退下一通道。
  static Future<QqSourceApiResult> resolve({
    required String songId,
    required String quality,
    required String apiKey,
    String? apiUrl,
    http.Client? client,
  }) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw QqSourceApiException('未配置卡密（X-API-KEY）');
    }
    final mapped = mapQuality(quality);
    if (mapped == null) {
      throw QqSourceApiException('音质 $quality 无 Source API 映射');
    }
    final id = songId.trim();
    if (id.isEmpty) {
      throw QqSourceApiException('缺少歌曲标识（songmid/songid）');
    }
    final base = (apiUrl?.trim().isNotEmpty == true ? apiUrl! : defaultApiUrl)
        .trim();
    final uri = Uri.parse(base).replace(
      queryParameters: <String, String>{
        'id': id,
        'quality': mapped,
        'encrypted': '0',
      },
    );

    final http.Client owned = client ?? http.Client();
    try {
      final response = await owned
          .get(uri, headers: <String, String>{'X-API-KEY': key})
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw QqSourceApiException(
          'HTTP ${response.statusCode} ${response.reasonPhrase ?? ''}',
        );
      }
      final Map<String, dynamic> body;
      try {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! Map) {
          throw const FormatException('响应不是 JSON 对象');
        }
        body = Map<String, dynamic>.from(decoded);
      } catch (_) {
        throw QqSourceApiException('响应解析失败：${response.body.length}B 非JSON');
      }
      final code = body['code'];
      final message = body['message']?.toString() ?? '';
      if (code is! num || code != 0) {
        throw QqSourceApiException(
          'code=$code${message.isEmpty ? '' : ' $message'}',
        );
      }
      final data = body['data'];
      if (data is! Map) {
        throw QqSourceApiException('响应缺少 data（$message）');
      }
      final url = data['url']?.toString().trim() ?? '';
      if (url.isEmpty) {
        throw QqSourceApiException('直链为空（$message）');
      }
      return QqSourceApiResult(
        url: url,
        filename: data['filename']?.toString() ?? '',
        qualityName: data['quality_name']?.toString() ?? mapped,
        bitrate: data['bitrate'] is num ? (data['bitrate'] as num).toInt() : null,
        ekey: data['ekey']?.toString() ?? '',
      );
    } on QqSourceApiException {
      rethrow;
    } catch (error) {
      throw QqSourceApiException(error.toString());
    } finally {
      if (client == null) owned.close();
    }
  }

  /// 探测该歌曲+音质是否可经 Source API 解析出有效直链。
  static Future<bool> probe({
    required String songId,
    required String quality,
    required String apiKey,
    String? apiUrl,
  }) async {
    try {
      final result = await resolve(
        songId: songId,
        quality: quality,
        apiKey: apiKey,
        apiUrl: apiUrl,
      );
      return result.url.startsWith('http://') ||
          result.url.startsWith('https://');
    } catch (_) {
      return false;
    }
  }
}
