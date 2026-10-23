// QQ L1 端到端复现测试（真实插件 JS + 真实 Source API）：
// ① 用真机同款 l1.js 跑 resolveMediaSource(master)；
// ② 断言返回的 PluginMediaSource.ekey 非空（真机 5545 日志实锤：
//    代理拿到 .mflac 却无解密日志 = ekey 在 worker isolate 回传时
//    被 _executePluginOperation 序列化丢弃）；
// ③ register 回环代理（带 ekey）断言登记成功且路径保留 .mflac 扩展名。
//    注：测试内不发起真实 GET——TestWidgetsFlutterBinding 会全局拦截
//    HttpClient（恒 400），真实解密链路由 tool/qmc_probe.dart 全档验证。
// 运行：flutter test test/qq_l1_e2e_test.dart --concurrency=1

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/player/cloud_proxy.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';

const kL1PluginPath =
    r'''c:\Users\35803\.trae-cn\attachments\74577a7a-fb61-4d58-9b17-f5c91679bab0_67ee391f-d4b9-432e-ad41-0676e13060e3_qq - l1 (1).js''';
const kApiKey =
    '3ccntJ6g64iGRo5_Qsvp6JxTpkPuErQDfmXu7LttMjDcKHycAfbrJrst-nCGzu2ClPKN-SjZG050IpEKmdMgmw';

void log(String s) => stdout.writeln('[l1-e2e] $s');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('L1 master 端到端：ekey 透传 + 代理解密', () async {
    final pluginSource = await File(kL1PluginPath).readAsString();
    final service = PluginRuntimeService(
      pluginSources: {'qq--l1': pluginSource},
    );
    addTearDown(service.dispose);

    const plugin = EnabledMusicPlugin(
      id: 'qq--l1',
      name: 'qq - l1',
      path: '',
      userVariables: {'SOURCE_API_KEY': kApiKey},
    );
    const rawData = {
      'id': '001IAqkK0p2b7s',
      'songmid': '001IAqkK0p2b7s',
      'title': 'A Little Love',
      'artist': '冯曦妤',
    };

    final source = await service.resolveMediaSource(
      plugin,
      rawData,
      preferredQuality: 'master',
    );
    log('url=${source.url}');
    log('ekey=${source.ekey == null ? "<null!>" : "${source.ekey!.length}字符"}');
    expect(source.url, isNotEmpty);
    // 真机断链复现断言：Source API 高档位返回 .mflac 时 ekey 必须存活。
    expect(
      source.ekey,
      isNotNull,
      reason: 'resolveMediaSource 返回的 ekey 丢失（真机 5545 日志同症状）',
    );

    // ② 回环代理登记：带 ekey 登记（真机 setUrl 同路径），断言代理 URL
    //    保留 .mflac 扩展名（ExoPlayer 按 URI 扩展名选提取器的前提）。
    final proxy = CloudPlaybackProxy.instance;
    final proxyUrl = await proxy.register(
      source.url,
      source.headers,
      'l1-e2e',
      ekey: source.ekey,
    );
    log('proxyUrl=$proxyUrl');
    expect(proxyUrl, endsWith('/AIM0000JtSSO3MO7bX.mflac'));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
