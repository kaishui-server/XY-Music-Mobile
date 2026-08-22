import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/pages/settings/settings_page.dart';

void main() {
  test('设置搜索严格优先一级，再展示二级和三级结果', () {
    final results = searchSettings('插件');

    expect(results, isNotEmpty);
    expect(results.first.title, '账号与服务');
    expect(results.first.level, 1);
    expect(
      results.map((entry) => entry.level).toList(),
      orderedEquals(results.map((entry) => entry.level).toList()..sort()),
    );
    expect(results.any((entry) => entry.title == '插件管理'), isTrue);
    expect(results.any((entry) => entry.title == '在线安装'), isTrue);
  });

  test('设置搜索支持标题、路径和关键词', () {
    expect(searchSettings('WebDAV').first.title, '音乐库');
    expect(
      searchSettings('不熄屏').any((entry) => entry.title == '保持屏幕常亮'),
      isTrue,
    );
    expect(searchSettings('   '), isEmpty);
  });
}
