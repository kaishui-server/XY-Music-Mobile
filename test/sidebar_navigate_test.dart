import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:xy_music/src/navigation/sidebar_controller.dart';

/// 回归：侧边栏条目点击后必须收起抽屉并完成路由切换。
///
/// 旧实现以 Scaffold 自身的 context 调用 Scaffold.of() 查祖先
/// ScaffoldState，必然抛异常，导致条目点击无任何反应（抽屉不关、
/// 页面不切）；且用 Navigator.pop 关闭抽屉实际弹掉的是当前页面路由。
///
/// 结构与真实 app 一致：带 key 的 Scaffold（AppShell）常驻于 router
/// 之上，路由页面在 body 内切换，key 的 currentState 不会因导航卸载。
void main() {
  Widget buildApp(GlobalKey<ScaffoldState> scaffoldKey) {
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        ShellRoute(
          builder: (context, state, child) => Scaffold(
            key: scaffoldKey,
            appBar: AppBar(title: const Text('首页')),
            drawer: Drawer(
              child: ListView(
                children: [
                  ListTile(
                    leading: const Icon(Icons.settings_outlined),
                    title: const Text('设置'),
                    onTap: () =>
                        navigateFromSidebar(context, scaffoldKey, '/settings'),
                  ),
                ],
              ),
            ),
            body: child,
          ),
          routes: [
            GoRoute(
              path: '/home',
              builder: (_, _) => const Center(child: Text('home-page')),
            ),
            GoRoute(
              path: '/settings',
              builder: (_, _) => const Center(child: Text('settings-page')),
            ),
          ],
        ),
      ],
    );
    return MaterialApp.router(routerConfig: router);
  }

  testWidgets('抽屉打开时点击条目：收起抽屉并完成导航', (tester) async {
    final scaffoldKey = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(buildApp(scaffoldKey));
    await tester.pumpAndSettle();

    scaffoldKey.currentState!.openDrawer();
    await tester.pumpAndSettle();
    expect(scaffoldKey.currentState!.isDrawerOpen, isTrue);

    await tester.tap(find.text('设置'));
    // 抽屉关闭动画（246ms）+ 导航延迟 260ms + 页面切换动画。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(scaffoldKey.currentState!.isDrawerOpen, isFalse);
    expect(find.text('settings-page'), findsOneWidget);
    expect(find.text('home-page'), findsNothing);
  });

  testWidgets('抽屉未打开时直接导航', (tester) async {
    final scaffoldKey = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(buildApp(scaffoldKey));
    await tester.pumpAndSettle();

    final BuildContext context = tester.element(find.text('home-page'));
    navigateFromSidebar(context, scaffoldKey, '/settings');
    await tester.pumpAndSettle();

    expect(scaffoldKey.currentState!.isDrawerOpen, isFalse);
    expect(find.text('settings-page'), findsOneWidget);
  });
}
