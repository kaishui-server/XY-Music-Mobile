import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xy_music/pages/settings/plugins_page.dart';
import 'package:xy_music/src/core/db_path.dart';

void main() {
  testWidgets('点击在线安装会打开网址输入弹窗', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDataDirProvider.overrideWith(
            (ref) async => r'Z:\xianyu-plugin-page-test-missing',
          ),
        ],
        child: const MaterialApp(home: PluginsPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('在线安装'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('从网络安装插件'), findsOneWidget);
    expect(find.text('下载并安装'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('下载并安装').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 关闭弹窗，结束 autofocus 光标和弹窗持有的异步 Future。
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
  });
}
