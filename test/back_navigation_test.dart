import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// 回归：软件内返回行为。
///
/// 要求：侧边栏一级页面（设置/本地音乐/云端音乐/账号等，所在分支已
/// 无返回栈）按系统返回键应回到首页，而不是直接退出软件；已在首页时
/// 按返回才退出。分支内子页（如 /settings/plugins → /settings）与
/// 全屏覆盖页（/player）的返回不受拦截影响。
///
/// 结构镜像 lib/src/navigation/shell.dart 的 AppShell：在
/// StatefulShellRoute 之上包一层 PopScope(canPop: false)。「能否被
/// 拦截」由 go_router 委托与 Navigator.maybePop 保证：分支有返回栈→
/// 分支 maybePop；根导航有覆盖页→覆盖页 maybePop；两者皆无→落到
/// PopScope 回调。系统返回键用 binding.handlePopRoute() 模拟。
void main() {
  late GoRouter router;
  late List<String> platformCalls;

  setUp(() {
    platformCalls = [];
    router = GoRouter(
      initialLocation: '/home',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => _FakeAppShell(
            navigationShell: shell,
            currentPath: state.uri.path,
          ),
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/home',
                  builder: (_, _) => const _Page('home-page'),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/settings',
                  builder: (_, _) => const _Page('settings-page'),
                  routes: [
                    GoRoute(
                      path: 'plugins',
                      builder: (_, _) => const _Page('plugins-page'),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        GoRoute(
          path: '/player',
          builder: (_, _) => const _Page('player-page'),
        ),
      ],
    );
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platformCalls.add(call.method);
        return null;
      },
    );
  }

  Future<void> pressBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  String location() => router.routeInformationProvider.value.uri.path;

  testWidgets('侧边栏页面按返回：回到首页而不是退出', (tester) async {
    await pumpApp(tester);
    tester.element(find.text('home-page')).go('/settings');
    await tester.pumpAndSettle();
    expect(location(), '/settings');

    await pressBack(tester);

    expect(location(), '/home');
    expect(platformCalls, isNot(contains('SystemNavigator.pop')));
  });

  testWidgets('分支子页按返回：先弹回分支根，再回首页，首页再按才退出', (tester) async {
    await pumpApp(tester);
    tester.element(find.text('home-page')).go('/settings/plugins');
    await tester.pumpAndSettle();
    expect(location(), '/settings/plugins');

    await pressBack(tester);
    // 分支内弹出优先：插件管理先回设置页，而不是直接跳首页。
    expect(location(), '/settings');

    await pressBack(tester);
    expect(location(), '/home');

    await pressBack(tester);
    expect(platformCalls, contains('SystemNavigator.pop'));
  });

  testWidgets('首页按返回：退出软件', (tester) async {
    await pumpApp(tester);
    expect(location(), '/home');

    await pressBack(tester);

    expect(location(), '/home');
    expect(platformCalls, contains('SystemNavigator.pop'));
  });

  testWidgets('全屏覆盖页按返回：正常弹回，不受拦截影响', (tester) async {
    await pumpApp(tester);
    // 注意：push 返回的 Future 要等页面被弹出才完成，这里不能 await，
    // 否则会死锁在「等弹出」上；且命令式 push 不反映到 route
    // information，故用页面是否存在断言。
    final pushed =
        tester.element(find.text('home-page')).push<Object?>('/player');
    await tester.pumpAndSettle();
    expect(find.text('player-page'), findsOneWidget);

    await pressBack(tester);
    await pushed;

    expect(find.text('player-page'), findsNothing);
    expect(find.text('home-page'), findsOneWidget);
    expect(platformCalls, isNot(contains('SystemNavigator.pop')));
  });
}

/// 与 AppShell 相同的返回拦截逻辑（保持与生产代码同步维护）。
class _FakeAppShell extends StatelessWidget {
  const _FakeAppShell({required this.navigationShell, required this.currentPath});

  final StatefulNavigationShell navigationShell;
  final String currentPath;

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(body: navigationShell);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (currentPath == '/home') {
          SystemNavigator.pop();
        } else {
          context.go('/home');
        }
      },
      child: scaffold,
    );
  }
}

class _Page extends StatelessWidget {
  const _Page(this.label);

  final String label;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text(label)));
}
