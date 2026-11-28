import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/plugins/plugin_runtime.dart';

/// 订阅源平台声明解析回归测试。
///
/// 背景：ikun 声明了 git（Gitcode 备用源）、lx-cit 声明了 qs（汽水）与
/// jo（JOOX），但搜索页此前只显示五平台——根因是 `_detectLxSources` 把
/// 声明列表与「宿主可搜索五平台」取交集，且只认 `sources: { ... }` 字面量，
/// 识别不到 `MUSIC_QUALITY` 这种「平台→音质数组」声明形态。
void main() {
  test('只声明 MUSIC_QUALITY 的订阅源：平台全量识别（ikun 的 git）', () {
    const source = '''
const MUSIC_QUALITY = JSON.parse('{"git":["128k","320k","flac"],"kw":["128k","320k","flac"],"kg":["128k","320k","flac"],"tx":["128k","320k","flac"],"wy":["128k","320k","flac"]}')
const MUSIC_SOURCE = JSON.parse('{"git":{"gitcode":"x"},"kw":{"kw":"y"}}')
const qualitys = ["128k", "320k", "flac"]
const default_quality = ["128k", "320k"]
const actions = ["musicUrl"]
lx.send(lx.EVENT_NAMES.inited, { status: true, name: item, sources: musicSources })
''';
    final sources = debugDetectLxSources(source);
    expect(sources, ['kw', 'kg', 'tx', 'wy', 'git']);
  });

  test('lx-cit 形态：汽水（qs）与 JOOX（jo）不被丢弃', () {
    const source = '''
const MUSIC_QUALITY = JSON.parse('{"kg":["128k","320k"],"kw":["128k","320k"],"tx":["128k"],"wy":["128k"],"mg":["128k"],"qs":["128k","320k"],"jo":["128k","320k"]}')
''';
    final sources = debugDetectLxSources(source);
    // qs 与 jo 都已是宿主可搜平台，按宿主固定顺序排列
    expect(sources, ['kw', 'kg', 'tx', 'wy', 'mg', 'qs', 'jo']);
    expect(sources.contains('qs'), isTrue);
    expect(sources.contains('jo'), isTrue);
  });

  test('lx-cit 的 bili 是宿主可搜索平台，bd 仍不可搜', () {
    const source = '''
const MUSIC_QUALITY = JSON.parse('{"kw":["128k","320k"],"bili":["128k","320k","flac"],"bd":["128k"]}')
''';
    final sources = debugDetectLxSources(source);
    expect(sources.contains('bili'), isTrue);
    // 宿主已由 Rust `search_bili` 实现 B 站搜索，`search_qs` 实现汽水搜索
    expect(kHostLxSearchSources.contains('bili'), isTrue);
    expect(kHostLxSearchSources.contains('qs'), isTrue);
    // 百度（bd）没有宿主搜索实现，搜索页下拉不能展示
    expect(kHostLxSearchSources.contains('bd'), isFalse);
  });

  test('音质数组常量不被误判为平台', () {
    const source = '''
const extra_qualitys = ["128k", "320k"]
const actions = ["musicUrl"]
''';
    final sources = debugDetectLxSources(source);
    expect(sources, ['kw', 'kg', 'tx', 'wy', 'mg', 'qs', 'jo', 'bili']);
  });

  test('宿主可搜平台清单覆盖汽水与哔哩哔哩', () {
    expect(kHostLxSearchSources, ['kw', 'kg', 'tx', 'wy', 'mg', 'qs', 'jo', 'bili']);
    // 歌单导入侧汽水没有接口，不能混进歌单平台表
    expect(kHostLxPlaylistSources.contains('qs'), isFalse);
    expect(kHostLxPlaylistSources.contains('bili'), isFalse);
  });

  test('sources 字面量声明优先且保留扩展平台', () {
    const source = '''
lx.send(lx.EVENT_NAMES.inited, { status: true, sources: { kw: {}, jo: {}, qq: {} } })
''';
    final sources = debugDetectLxSources(source);
    expect(sources.contains('kw'), isTrue);
    expect(sources.contains('jo'), isTrue);
  });
}
