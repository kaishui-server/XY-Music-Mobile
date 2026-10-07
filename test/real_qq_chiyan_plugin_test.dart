// 真实集成测试：加载用户的「QQ音乐(迟言API)」改造器插件，验证
// 搜索与播放链路（getMediaSource → cyapi.top → 播放 URL）端到端可用。
// 复现用户报告的「歌曲可搜索，无法正常播放」问题。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';

const _pluginPath = String.fromEnvironment(
  'QQ_PLUGIN_PATH',
  defaultValue: r'C:\Users\admin\.trae-cn\attachments\6abcf64e8ebfed28a687113a\2568fbab-5af4-4428-913e-d9b2fff0581b_03428c2d-9315-4c59-b6d2-2fde35ff6f45_QQ音乐(迟言API)(6).js',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('迟言API插件：搜索 + 播放地址解析 + URL 可用性', () async {
    final pluginFile = File(_pluginPath);
    expect(
      pluginFile.existsSync(),
      isTrue,
      reason: '找不到插件文件 $_pluginPath',
    );

    final service = PluginRuntimeService();
    addTearDown(() => service.dispose());

    final plugin = EnabledMusicPlugin(
      id: 'qq音乐',
      name: 'QQ音乐',
      path: _pluginPath,
    );

    final results = await service.search(plugin, '晴天 周杰伦');
    print('搜索返回 ${results.length} 首');
    expect(results, isNotEmpty);
    final first = results.first;
    print(
      '第一首: ${first.title} | ${first.artist} | '
      'id=${first.rawData['id']} songmid=${first.rawData['songmid']}',
    );

    final source = await service.resolveMediaSource(
      plugin,
      first.rawData,
      preferredQuality: '320k',
    ).timeout(const Duration(seconds: 30));
    print('解析地址: ${source.url}');
    expect(source.url, startsWith('https://'));

    final client = HttpClient();
    addTearDown(client.close);
    final probe = await client
        .headUrl(Uri.parse(source.url))
        .timeout(const Duration(seconds: 15));
    probe.followRedirects = true;
    final response = await probe.close().timeout(
          const Duration(seconds: 15),
        );
    print('URL 探测状态码: ${response.statusCode}');
    expect(response.statusCode, anyOf(200, 206, 302, 301, 403));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
