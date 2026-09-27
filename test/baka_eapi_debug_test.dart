// 调试：捕获 QuickJS 插件发出的所有 HTTP 请求/响应，定位 wy_baka
// eapi 逐字歌词失败的具体环节。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:quickjs_engine/javascript_runtime.dart';
import 'package:quickjs_engine/quickjs_engine.dart' as qjs;
import 'package:xy_music/src/plugins/plugin_runtime.dart';

const _wyBakaPath = String.fromEnvironment(
  'WY_BAKA_PATH',
  defaultValue: r'C:\Users\35803\AppData\Local\Temp\wy_baka.js',
);

class _DebugHttpClient extends http.BaseClient {
  final http.Client _client = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bodyBytes = await request.finalize().toBytes();
    debugPrint('>> [${request.method}] ${request.url}');
    debugPrint('>> headers: ${request.headers}');
    final bodyText = utf8.decode(bodyBytes, allowMalformed: true);
    debugPrint(
      '>> body(${bodyBytes.length}B): '
      '${bodyText.length > 300 ? '${bodyText.substring(0, 300)}...' : bodyText}',
    );
    final ioRequest = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = bodyBytes;
    final response = await _client.send(ioRequest);
    final respBytes = await response.stream.toBytes();
    final respText = utf8.decode(respBytes, allowMalformed: true);
    debugPrint('<< status: ${response.statusCode} (${respBytes.length}B)');
    debugPrint(
      '<< body: ${respText.length > 400 ? '${respText.substring(0, 400)}...' : respText}',
    );
    return http.StreamedResponse(
      Stream.value(utf8.encode(_wrap(respText))),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

String _wrap(String body) =>
    '__XY_HTTP_BODY_BASE64__${base64Encode(utf8.encode(body))}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test 默认注入返回 400 的假 HttpClient，必须移除才能
  // 观察真实网络行为。
  HttpOverrides.global = null;

  test('wy_baka eapi 调试', () async {
    final bootstrap = File('assets/plugin_runtime.js').readAsStringSync();
    final lxBootstrap = File('assets/lx_plugin_runtime.js').readAsStringSync();
    final pluginSource = File(_wyBakaPath).readAsStringSync();

    final service = PluginRuntimeService(
      httpClient: _DebugHttpClient(),
      runtimeBootstrap: bootstrap,
      runtimeLxBootstrap: lxBootstrap,
      pluginSources: {'wy_baka': pluginSource},
    );
    addTearDown(service.dispose);

    final plugin = EnabledMusicPlugin(
      id: 'wy_baka',
      name: 'BakaMusic-网易云',
      path: _wyBakaPath,
    );

    // 先用插件搜索拿真实歌曲数据（含正确 id），再取歌词
    final results = await service.search(plugin, '泡沫 邓紫棋');
    debugPrint('=== 搜索返回 ${results.length} 首 ===');
    expect(results, isNotEmpty);
    for (final song in results.take(5)) {
      debugPrint('  ${song.title} | ${song.artist} | id=${song.rawData['id']}');
    }
    final song = results.first;
    final rawData = Map<String, dynamic>.from(song.rawData);

    final lyrics = await service.getLyrics(plugin, rawData);
    debugPrint('=== 最终歌词长度: ${lyrics.length} ===');
    debugPrint(lyrics.length > 300 ? lyrics.substring(0, 300) : lyrics);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
