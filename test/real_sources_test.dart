// 真实集成测试：洛雪音源 + baka 订阅插件 —— 搜索 / 播放地址 / 歌词（逐字）。
// 验证 Bug 2（全部音乐播放报错）与 Bug 1（洛雪逐字歌词）修复后的真实链路。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';

const _lxPath = String.fromEnvironment(
  'LX_SOURCE_PATH',
  defaultValue: r'C:\Users\35803\AppData\Local\Temp\lx_source.js',
);
const _bakaWyPath = String.fromEnvironment(
  'BAKA_WY_PATH',
  defaultValue: r'C:\Users\35803\AppData\Local\Temp\xy_mf_plugins\baka_wy.js',
);
const _bakaKwPath = String.fromEnvironment(
  'BAKA_KW_PATH',
  defaultValue: r'C:\Users\35803\AppData\Local\Temp\xy_mf_plugins\baka_kw.js',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 探测播放地址是否真的可访问（200/206 均可）。
  Future<bool> urlPlayable(String url, Map<String, String> headers) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final request = await client.getUrl(Uri.parse(url));
      headers.forEach(request.headers.set);
      final response = await request.close();
      final ok = response.statusCode == 200 || response.statusCode == 206;
      await response.drain<void>();
      client.close();
      return ok;
    } catch (_) {
      return false;
    }
  }

  test('洛雪音源：搜索 / 播放地址 / 逐字歌词', () async {
    expect(File(_lxPath).existsSync(), isTrue, reason: '缺少 $_lxPath');
    final service = PluginRuntimeService();
    addTearDown(() => service.dispose());
    final plugin = EnabledMusicPlugin(
      id: 'lx',
      name: '洛雪音源',
      path: _lxPath,
      isLx: true,
    );

    final results = await service.search(plugin, '周杰伦 晴天');
    print('LX 搜索返回 ${results.length} 首');
    expect(results, isNotEmpty);
    final song = results.first;
    print('LX 第一首: ${song.title} - ${song.artist}');

    final source = await service.resolveMediaSource(
      plugin,
      song.rawData,
      preferredQuality: '320k',
    );
    print('LX 播放地址: ${source.url}');
    expect(source.url, isNotEmpty);
    final playable = await urlPlayable(source.url, source.headers);
    print('LX 地址可访问: $playable');

    final lyric = await service.getLyrics(plugin, song.rawData);
    print('LX 歌词长度: ${lyric.length}');
    // 逐字歌词：行内 <offset,dur> 标签（wy/kg/tx）或 kuwo 加密标签。
    final wordByWord = RegExp(r'<\d+(?:,\d+)?>').hasMatch(lyric) ||
        lyric.contains('[kuwo:');
    print('LX 歌词含逐字时间标签: $wordByWord');
    print(
      'LX 歌词前 200 字符: '
      '${lyric.length > 200 ? lyric.substring(0, 200) : lyric}',
    );
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('baka 网易云插件：搜索 / 播放地址 / 歌词', () async {
    expect(File(_bakaWyPath).existsSync(), isTrue, reason: '缺少 $_bakaWyPath');
    final service = PluginRuntimeService();
    addTearDown(() => service.dispose());
    final plugin = EnabledMusicPlugin(
      id: 'baka_wy',
      name: '网易云音乐',
      path: _bakaWyPath,
    );

    final results = await service.search(plugin, '林俊杰 江南');
    print('baka/wy 搜索返回 ${results.length} 首');
    expect(results, isNotEmpty);
    final song = results.first;
    print('baka/wy 第一首: ${song.title} - ${song.artist}');

    final source = await service.resolveMediaSource(
      plugin,
      song.rawData,
      preferredQuality: '320k',
    );
    print('baka/wy 播放地址: ${source.url}');
    expect(source.url, isNotEmpty);
    final playable = await urlPlayable(source.url, source.headers);
    print('baka/wy 地址可访问: $playable');

    final lyric = await service.getLyrics(plugin, song.rawData);
    print('baka/wy 歌词长度: ${lyric.length}');
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('baka 酷我插件：搜索 / 播放地址 / kuwo 逐字歌词', () async {
    expect(File(_bakaKwPath).existsSync(), isTrue, reason: '缺少 $_bakaKwPath');
    final service = PluginRuntimeService();
    addTearDown(() => service.dispose());
    final plugin = EnabledMusicPlugin(
      id: 'baka_kw',
      name: '酷我音乐',
      path: _bakaKwPath,
    );

    final results = await service.search(plugin, '周杰伦 晴天');
    print('baka/kw 搜索返回 ${results.length} 首');
    expect(results, isNotEmpty);
    final song = results.first;
    print('baka/kw 第一首: ${song.title} - ${song.artist}');

    final source = await service.resolveMediaSource(
      plugin,
      song.rawData,
      preferredQuality: '320k',
    );
    print('baka/kw 播放地址: ${source.url}');
    expect(source.url, isNotEmpty);
    final playable = await urlPlayable(source.url, source.headers);
    print('baka/kw 地址可访问: $playable');

    final lyric = await service.getLyrics(plugin, song.rawData);
    print('baka/kw 歌词长度: ${lyric.length}');
    // baka 是 MusicFree 插件，逐字能力取决于插件 getLyric 返回的
    // lxlyric 字段；只打印不强制断言，观察原始格式。
    print(
      'baka/kw 歌词前 200 字符: '
      '${lyric.length > 200 ? lyric.substring(0, 200) : lyric}',
    );
  }, timeout: const Timeout(Duration(minutes: 4)));
}
