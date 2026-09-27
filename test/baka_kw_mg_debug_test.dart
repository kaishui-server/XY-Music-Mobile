// 调试：捕获 kw_baka / mg_baka 插件的 HTTP 流量，定位
// 「酷我无歌词」「咪咕无逐字」的失败环节。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:xy_music/src/plugins/plugin_runtime.dart';

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
    final response = await _client.send(ioRequest);
    final respBytes = await response.stream.toBytes();
    final respText = utf8.decode(respBytes, allowMalformed: true);
    debugPrint('<< status: ${response.statusCode} (${respBytes.length}B)');
    debugPrint(
      '<< body: ${respText.length > 500 ? '${respText.substring(0, 500)}...' : respText}',
    );
    return http.StreamedResponse(
      Stream.value(utf8.encode(_wrapBytes(respBytes))),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

String _wrapBytes(List<int> bytes) =>
    '__XY_HTTP_BODY_BASE64__${base64Encode(bytes)}';

Future<void> _runPlugin(
  String label,
  String pluginPath,
  String query,
) async {
  final bootstrap = File('assets/plugin_runtime.js').readAsStringSync();
  final lxBootstrap = File('assets/lx_plugin_runtime.js').readAsStringSync();
  final pluginSource = File(pluginPath).readAsStringSync();

  final service = PluginRuntimeService(
    httpClient: _DebugHttpClient(),
    runtimeBootstrap: bootstrap,
    runtimeLxBootstrap: lxBootstrap,
    pluginSources: {label: pluginSource},
  );

  final plugin = EnabledMusicPlugin(
    id: label,
    name: 'BakaMusic-$label',
    path: pluginPath,
  );

  final results = await service.search(plugin, query);
  debugPrint('=== [$label] 搜索返回 ${results.length} 首 ===');
  for (final song in results.take(3)) {
    debugPrint(
      '  ${song.title} | ${song.artist} | id=${song.rawData['id']} | '
      'duration=${song.rawData['duration']} | '
      'keys=${song.rawData.keys.toList()}',
    );
  }
  if (results.isEmpty) return;
  final rawData = Map<String, dynamic>.from(results.first.rawData);

  final lyrics = await service.getLyrics(plugin, rawData);
  debugPrint('=== [$label] 最终歌词长度: ${lyrics.length} ===');
  debugPrint(lyrics.length > 400 ? lyrics.substring(0, 400) : lyrics);
  service.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('kw_baka 歌词调试', () async {
    await _runPlugin('kw_baka', r'C:\Users\35803\AppData\Local\Temp\kw_baka.js', '泡沫 邓紫棋');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('mg_baka 歌词调试', () async {
    await _runPlugin('mg_baka', r'C:\Users\35803\AppData\Local\Temp\mg_baka.js', '泡沫 邓紫棋');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
