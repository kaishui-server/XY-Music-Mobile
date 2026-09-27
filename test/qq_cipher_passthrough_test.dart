import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';

/// 复现：订阅 QQ 插件（linglan qq.js v1.1.4）getLyric 走 musicu.fcg
/// GetPlayLyricInfo（crypt:1），返回 hex 密文 rawLrc。验证：
/// 1. axios POST（对象 body）经 QuickJS XHR 桥能正确发出；
/// 2. 响应 JSON 被正确解析；
/// 3. rawLrc hex 密文完整透传回 Dart（供 Rust 解密为逐字 QRC）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final pluginPath = Platform.environment['XY_QQ_PLUGIN_PATH'];
  test('订阅 QQ 插件 getLyric 密文透传', () async {
    final source = File(pluginPath!).readAsStringSync();

    // 伪装的 crypt:1 密文响应（真实场景为 QRC 的 3DES hex 密文）。
    final cipherLyric = 'e5a3b1c8d0c6d2ec9ca4d3ec8bfa' * 8;
    final cipherTrans = 'c8ede3d5e6a2b5e7' * 8;
    final requestBodies = <String>[];

    final client = MockClient((request) async {
      if (request.url.host == 'u.y.qq.com') {
        requestBodies.add(request.body);
        return http.Response(
          encodePluginHttpBody(
            jsonEncode({
              'code': 0,
              'req': {
                'code': 0,
                'data': {
                  'lyric': cipherLyric,
                  'trans': cipherTrans,
                  'roma': cipherTrans,
                },
              },
            }),
          ),
          200,
        );
      }
      return http.Response('', 404);
    });

    final service = PluginRuntimeService(
      httpClient: client,
      pluginSources: {'qq-sub': source},
    );
    addTearDown(() {
      service.dispose();
      client.close();
    });

    final lyrics = await service.getLyrics(
      const EnabledMusicPlugin(
        id: 'qq-sub',
        name: 'QQ音乐',
        path: '',
      ),
      {
        'id': 97773,
        'songmid': '0039MnYb0qxYhV',
        'title': '晴天',
        'artist': '周杰伦',
      },
    );

    // 插件的 axios POST 必须真的发出（body 含 GetPlayLyricInfo）。
    expect(
      requestBodies,
      isNotEmpty,
      reason: '插件未发出 musicu.fcg 请求，getLyric 静默降级了',
    );
    expect(
      requestBodies.first,
      contains('GetPlayLyricInfo'),
      reason: 'musicu.fcg 请求体异常：${requestBodies.first}',
    );
    // 密文必须原样透传，不能被丢弃或替换为平台兜底的普通 LRC。
    expect(lyrics.trim(), cipherLyric);
  });

  test('QQ 插件静默降级普通 LRC 时逐字兜底失败须维持原歌词', () async {
    final source = File(pluginPath!).readAsStringSync();

    // 模拟插件内部 musicu.fcg（crypt:1）失败：返回 500，
    // 插件会静默降级走 c.y.qq.com 老接口拿普通 LRC。
    const plainLrc = '[00:01.00]晴天\n[00:05.00]故事的小黄花';
    final legacyBody = jsonEncode({
      'retcode': 0,
      'lyric': base64Encode(utf8.encode(plainLrc)),
      'trans': '',
    });

    final client = MockClient((request) async {
      if (request.url.host == 'u.y.qq.com') {
        return http.Response('server error', 500);
      }
      if (request.url.host == 'c.y.qq.com') {
        return http.Response(legacyBody, 200);
      }
      return http.Response('', 404);
    });

    final service = PluginRuntimeService(
      httpClient: client,
      pluginSources: {'qq-sub': source},
    );
    addTearDown(() {
      service.dispose();
      client.close();
    });

    // 单测环境没有 RustLib：逐字直连兜底（fetchLyricFromSource）必然
    // 失败，此时必须维持插件返回的普通 LRC，而不是抛错或返回空。
    final lyrics = await service.getLyrics(
      const EnabledMusicPlugin(
        id: 'qq-sub',
        name: 'QQ音乐',
        path: '',
      ),
      {
        'id': 97773,
        'songmid': '0039MnYb0qxYhV',
        'title': '晴天',
        'artist': '周杰伦',
      },
    );

    expect(lyrics, contains('晴天'));
    expect(lyrics, contains('[00:01.00]'));
  });
}
