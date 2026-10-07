import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/plugins/plugin_metadata.dart';

void main() {
  test('真实插件（QQ音乐迟言API）元数据解析', () {
    final path = Platform.environment['XY_PLUGIN_FILE'];
    expect(path, isNotNull, reason: '需要 XY_PLUGIN_FILE 环境变量指向插件文件');
    final script = File(path!).readAsStringSync();

    final metadata = PluginMetadata.parse(script);
    // ignore: avoid_print
    print('id=${metadata.id}');
    // ignore: avoid_print
    print('name=${metadata.name}');
    // ignore: avoid_print
    print('version=${metadata.version}');
    // ignore: avoid_print
    print('author=${metadata.author}');
    // ignore: avoid_print
    print('remark=${metadata.remark}');
    // ignore: avoid_print
    print('userVariables=${metadata.userVariables.map((v) => '${v.key}/${v.displayName}')}');

    expect(metadata.name, isNotNull);
    expect(metadata.name, isNot(contains('e9-9f')));
    expect(metadata.name, anyOf(contains('QQ'), contains('qq'), contains('音乐')));

    final id = PluginMetadata.resolvePluginId(script, path);
    // ignore: avoid_print
    print('resolvedId=$id');
    expect(id, isNot(contains('e9-9f')));
    expect(id, isNotEmpty);
  });
}
