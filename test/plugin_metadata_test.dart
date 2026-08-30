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

  test('解析插件声明的 userVariables', () {
    const script = r'''
const TOKEN_HINT = "用于访问 API 的令牌";
module.exports = {
  platform: "示例音乐",
  userVariables: [
    { key: "token", name: "Access Token", hint: TOKEN_HINT },
    { key: "uid", hint: "用户 ID（可选）" },
  ],
  search: async () => ({ data: [] }),
};
''';

    final metadata = PluginMetadata.parse(script);
    expect(metadata.userVariables.length, 2);
    expect(metadata.userVariables[0].key, 'token');
    expect(metadata.userVariables[0].name, 'Access Token');
    expect(metadata.userVariables[0].hint, '用于访问 API 的令牌');
    expect(metadata.userVariables[0].displayName, 'Access Token');
    expect(metadata.userVariables[1].key, 'uid');
    expect(metadata.userVariables[1].displayName, 'uid');
  });

  test('userVariables 含括号字符串时不破坏解析', () {
    const script = r'''
module.exports = {
  platform: "示例音乐",
  userVariables: [
    { key: "cookie", name: "Cookie [完整]", hint: "形如 a=1; b=[2]" },
  ],
  search: async () => ({ data: [] }),
};
''';

    final metadata = PluginMetadata.parse(script);
    expect(metadata.userVariables.length, 1);
    expect(metadata.userVariables[0].key, 'cookie');
    expect(metadata.userVariables[0].name, 'Cookie [完整]');
  });

  test('未声明 userVariables 时为空列表', () {
    final metadata = PluginMetadata.parse(
      'module.exports = { platform: "x" };',
    );
    expect(metadata.userVariables, isEmpty);
  });
}
