// 聆澜订阅源（BakaMusic 索引 → wy.js?source=linglan）网易云端到端复现：
// ① 用真机同款 wy.js 搜「临安初雨」（音乐是岸）；
// ② 全档位 resolveMediaSource，记录 url/headers；
// ③ 直链用引擎内 axios（XHR 桥，测试环境可真实联网）带 Range 探测，
//    回传 status/CT/长度/魔数。测试环境 Dart HttpClient 被 HttpOverrides
//    拦截，故不走 Dart 直连。
// 运行：flutter test test/linglan_wy_e2e_test.dart --concurrency=1

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';

const kWyPluginPath = r'''C:\Users\35803\AppData\Local\Temp\linglan_wy.js''';

void log(String s) => stdout.writeln('[wy-e2e] $s');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('聆澜网易云：搜索临安初雨 + 全档解析 + 直链探测', () async {
    final pluginSource = await File(kWyPluginPath).readAsString();
    final service = PluginRuntimeService(
      pluginSources: {
        'wy--linglan': pluginSource,
        // 引擎内探测插件：借 axios（XHR 桥）对直链发 Range 请求。
        'probe': '''
          const axios = require('axios');
          module.exports = {
            platform: 'probe',
            search: async () => ({ isEnd: true, data: [] }),
            getMediaSource: async (item) => {
              try {
                const res = await axios.get(item.target, {
                  headers: Object.assign({ Range: 'bytes=0-63' }, item.headers || {}),
                  responseType: 'arraybuffer',
                  timeout: 10000,
                });
                const bytes = new Uint8Array(res.data);
                let head = '';
                for (let i = 0; i < 12 && i < bytes.length; i++) {
                  head += bytes[i].toString(16).padStart(2, '0');
                }
                const diag = 'status=' + res.status +
                  ';ct=' + (res.headers['content-type'] || '无') +
                  ';len=' + bytes.length + ';magic=' + head;
                // 诊断信息编码进假 URL 带出（resolveMediaSource 会校验
                // url 形态，纯文本会被当作无效结果丢弃）。
                return { url: 'https://probe.local/' + encodeURIComponent(diag) };
              } catch (e) {
                const detail = e && e.response
                  ? 'http-status=' + e.response.status
                  : (e && e.message ? e.message : String(e));
                return { url: 'https://probe.local/' + encodeURIComponent('probe-error=' + detail) };
              }
            },
          };
        ''',
      },
    );
    addTearDown(service.dispose);

    const plugin = EnabledMusicPlugin(
      id: 'wy--linglan',
      name: '网易云音乐',
      path: '',
    );
    const probe = EnabledMusicPlugin(id: 'probe', name: 'probe', path: '');

    final results = await service.search(plugin, '临安初雨');
    log('搜索结果 ${results.length} 条:');
    for (final r in results.take(8)) {
      final qs = (r.rawData['qualities'] as Map?)?.keys.toList();
      log('  ${r.title} - ${r.artist} | id=${r.rawData['id']} qualities=$qs');
    }
    final hit = results.firstWhere(
      (r) => r.artist.contains('音乐是岸'),
      orElse: () => throw Exception('未搜到「临安初雨 - 音乐是岸」'),
    );
    log('命中: ${hit.title} - ${hit.artist} id=${hit.rawData['id']}');

    for (final q in const ['atmos', 'master', 'hires', 'flac', '320k', '128k']) {
      try {
        final source = await service.resolveMediaSource(
          plugin,
          hit.rawData,
          preferredQuality: q,
        );
        log('[$q] url=${source.url}');
        log('[$q] headers=${source.headers}');
        final probed = await service.resolveMediaSource(
          probe,
          {'target': source.url, 'headers': source.headers},
        );
        log('[$q] probe-raw=${probed.url}');
        final seg = Uri.tryParse(probed.url)?.pathSegments.last ?? probed.url;
        try {
          log('[$q] 探测 ${Uri.decodeComponent(seg)}');
        } catch (_) {
          log('[$q] 探测(原样) $seg');
        }
      } catch (e) {
        log('[$q] 失败: $e');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
