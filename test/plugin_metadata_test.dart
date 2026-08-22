import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/plugins/plugin_metadata.dart';

void main() {
  test('MusicFree 名称读取最终 module.exports 而不是歌曲字段', () {
    const script = r'''
const VERSION = "7";
const IS_PAID = "(赞助版)[永久]";
function formatSong(item) {
  return { id: "错误ID", name: "错误歌曲名", version: "9108" };
}
module.exports = {
  platform: "网易云音乐" + (IS_PAID ? IS_PAID : ""),
  author: "测试作者",
  version: VERSION,
  search: async () => ({ data: [] }),
};
''';

    final metadata = PluginMetadata.parse(script);
    expect(metadata.id, isNull);
    expect(metadata.name, '网易云音乐(赞助版)[永久]');
    expect(metadata.version, '7');
    expect(metadata.author, '测试作者');
  });

  test('LX 注释头优先作为插件元数据', () {
    const script = r'''
/**
 * @id lx-demo
 * @name 测试 LX 音源
 * @version 1.2.3
 * @author 测试作者
 */
const source = {};
''';

    final metadata = PluginMetadata.parse(script);
    expect(metadata.id, 'lx-demo');
    expect(metadata.name, '测试 LX 音源');
    expect(metadata.version, '1.2.3');
    expect(metadata.author, '测试作者');
  });
}
