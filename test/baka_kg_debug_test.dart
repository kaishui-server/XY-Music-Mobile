// 调试：捕获 kg_baka 插件的 HTTP 请求/响应，定位酷狗逐字歌词失败环节。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:xy_music/src/plugins/plugin_runtime.dart';

const _kgBakaPath = String.fromEnvironment(
  'KG_BAKA_PATH',
  defaultValue: r'C:\Users\35803\AppData\Local\Temp\kg_baka.js',
);

class _DebugHttpClient extends http.BaseClient {
  final http.Client _client = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bodyBytes = await request.finalize().toBytes();
    debugPrint('>> [${request.method}] ${request.url}');
    debugPrint('>> headers: ${request.headers}');
    final ioRequest = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = bodyBytes;
    late http.StreamedResponse response;
    try {
      response = await _client.send(ioRequest);
    } catch (e) {
      debugPrint('<< 网络异常: $e');
      rethrow;
    }
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
  HttpOverrides.global = null;

  test('kg_baka 逐字歌词调试', () async {
    final bootstrap = File('assets/plugin_runtime.js').readAsStringSync();
    final lxBootstrap = File('assets/lx_plugin_runtime.js').readAsStringSync();
    final pluginSource = File(_kgBakaPath).readAsStringSync();

    final service = PluginRuntimeService(
      httpClient: _DebugHttpClient(),
      runtimeBootstrap: bootstrap,
      runtimeLxBootstrap: lxBootstrap,
      pluginSources: {'kg_baka': pluginSource},
    );
    addTearDown(service.dispose);

    final plugin = EnabledMusicPlugin(
      id: 'kg_baka',
      name: 'BakaMusic-酷狗',
      path: _kgBakaPath,
    );

    final results = await service.search(plugin, '泡沫 邓紫棋');
    debugPrint('=== 搜索返回 ${results.length} 首 ===');
    for (final song in results.take(3)) {
      debugPrint(
        '  ${song.title} | ${song.artist} | id=${song.rawData['id']} '
        '| duration=${song.rawData['duration'] ?? song.rawData['interval']}'
        ' | rawData keys=${song.rawData.keys.toList()}',
      );
    }
    expect(results, isNotEmpty);
    final song = results.first;
    final rawData = Map<String, dynamic>.from(song.rawData);

    final lyrics = await service.getLyrics(plugin, rawData);
    debugPrint('=== 最终歌词长度: ${lyrics.length} ===');
    debugPrint(lyrics.length > 400 ? lyrics.substring(0, 400) : lyrics);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
