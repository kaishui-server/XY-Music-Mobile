// 真实集成测试：用 app 的 QuickJS 运行时加载订阅里的网易云插件，
// 搜索《一生一世》并检查 OST 歌曲的封面是否在 app 层完整保留。
// 用于复现用户报告的「OST 歌曲封面不显示」问题。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';

const _wyPluginPath = String.fromEnvironment(
  'WY_PLUGIN_PATH',
  defaultValue: r'C:\Users\35803\AppData\Local\Temp\xy_mf_plugins\wy.js',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('真实网易云插件搜索《一生一世》OST 歌曲封面检查', () async {
    final pluginFile = File(_wyPluginPath);
    expect(
      pluginFile.existsSync(),
      isTrue,
      reason: '找不到插件文件 $_wyPluginPath，请先下载订阅插件',
    );

    final service = PluginRuntimeService();
    addTearDown(() => service.dispose());

    final plugin = EnabledMusicPlugin(
      id: 'wy',
      name: '网易云音乐',
      path: _wyPluginPath,
    );

    final results = await service.search(plugin, '一生一世 影视原声带');
    print('搜索返回 ${results.length} 首');

    expect(results, isNotEmpty);

    var missing = <String>[];
    for (final song in results.take(12)) {
      final status = song.coverUrl.isEmpty ? 'MISSING' : 'HAS';
      print(
        '[$status] ${song.title} | ${song.artist} | cover='
        '${song.coverUrl.isEmpty ? "(empty)" : song.coverUrl.substring(0, song.coverUrl.length > 60 ? 60 : song.coverUrl.length)}',
      );
      if (song.coverUrl.isEmpty) missing.add(song.title);
    }

    print('前 12 首中缺封面数量: ${missing.length}');
    if (missing.isNotEmpty) {
      print('缺封面歌曲: $missing');
      // 打印第一首缺封面歌曲的 rawData 帮助定位
      final first = results.firstWhere((s) => s.coverUrl.isEmpty);
      print('rawData: ${first.rawData}');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
