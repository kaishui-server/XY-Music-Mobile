// 复现用户报告的「baka 音源逐字歌词全平台失效」：
// 用 linglan 订阅的真实 BakaMusic 契约插件（wy/kg），在 app 的 QuickJS
// 运行时里调用 getLyric，检查返回的歌词是否包含逐字时间轴。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';

const _wyBakaPath = String.fromEnvironment(
  'WY_BAKA_PATH',
  defaultValue: r'C:\Users\35803\AppData\Local\Temp\wy_baka.js',
);

const _kgBakaPath = String.fromEnvironment(
  'KG_BAKA_PATH',
  defaultValue: r'C:\Users\35803\AppData\Local\Temp\kg_baka.js',
);

/// 逐字时间轴特征：QRC `[起,久]` 行 + `字(起,久)` 词标签。
final _wordTimingPattern = RegExp(r'\[\d+,\d+\]');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 后台 isolate 不受主 isolate 的假 HttpClient 影响，无需覆盖。

  test('wy_baka getLyric 逐字歌词（泡沫）', () async {
    final pluginFile = File(_wyBakaPath);
    expect(
      pluginFile.existsSync(),
      isTrue,
      reason: '找不到插件文件 $_wyBakaPath，请先下载订阅插件',
    );

    final service = PluginRuntimeService();
    addTearDown(() => service.dispose());

    final plugin = EnabledMusicPlugin(
      id: 'wy_baka',
      name: 'BakaMusic-网易云',
      path: _wyBakaPath,
    );

    // 先搜索拿真实歌曲（含正确 id），模拟应用真实路径
    final results = await service.search(plugin, '泡沫 邓紫棋');
    expect(results, isNotEmpty);
    print('搜索第一首: ${results.first.title} | ${results.first.artist} | '
        'id=${results.first.rawData['id']}');
    final lyrics = await service.getLyrics(
      plugin,
      Map<String, dynamic>.from(results.first.rawData),
    );
    print('=== wy 歌词长度: ${lyrics.length} ===');
    print(lyrics.length > 600 ? lyrics.substring(0, 600) : lyrics);
    print('=== 逐字特征: ${_wordTimingPattern.hasMatch(lyrics)} ===');
    expect(lyrics, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('kg_baka getLyric 逐字歌词（泡沫）', () async {
    final pluginFile = File(_kgBakaPath);
    expect(
      pluginFile.existsSync(),
      isTrue,
      reason: '找不到插件文件 $_kgBakaPath，请先下载订阅插件',
    );

    final service = PluginRuntimeService();
    addTearDown(() => service.dispose());

    final plugin = EnabledMusicPlugin(
      id: 'kg_baka',
      name: 'BakaMusic-酷狗',
      path: _kgBakaPath,
    );

    // 之前 curl 实测：泡沫 FileHash=8574D02543B5F902469FB4E27E3A350D
    final lyrics = await service.getLyrics(plugin, {
      'hash': '8574D02543B5F902469FB4E27E3A350D',
      'title': '泡沫',
      'artist': 'G.E.M. 邓紫棋',
      'duration': 252,
    });
    print('=== kg 歌词长度: ${lyrics.length} ===');
    print(lyrics.length > 600 ? lyrics.substring(0, 600) : lyrics);
    print('=== 逐字特征: ${_wordTimingPattern.hasMatch(lyrics)} ===');
    expect(lyrics, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
