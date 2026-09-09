import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:xy_music/src/core/settings.dart';
import 'package:xy_music/src/navigation/animated_page_route.dart';

/// 与 routes.dart 的 _instantPage 完全一致的页面构造方式。
Page<void> _transitionPage(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      transitionDuration: xyPageTransitionDuration,
      reverseTransitionDuration: xyPageReverseTransitionDuration,
      transitionsBuilder: xyPageTransition,
      child: child,
    );

void main() {
  for (final mode in PageTransitionMode.values) {
    testWidgets('$mode 模式动画落定后按钮仍可点击', (tester) async {
      xyPageTransitionMode = mode;
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Navigator(
            onGenerateRoute: (_) => XyAnimatedPageRoute<void>(
              builder: (_) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => taps++,
                    child: const Text('按钮'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('按钮').hitTestable(), findsOneWidget);
      await tester.tap(find.text('按钮'));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('$mode 模式真实路由结构下滚动/点击/入栈/返回均正常', (tester) async {
      xyPageTransitionMode = mode;
      var taps = 0;
      final scroll = ScrollController();
      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(
            path: '/home',
            pageBuilder: (context, state) => _transitionPage(
              state,
              Scaffold(
                appBar: AppBar(
                  actions: [
                    IconButton(
                      tooltip: '计数',
                      onPressed: () => taps++,
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                body: ListView(
                  controller: scroll,
                  children: [
                    for (var i = 0; i < 40; i++)
                      ListTile(title: Text('条目$i'), onTap: () {}),
                  ],
                ),
                floatingActionButton: FloatingActionButton(
                  tooltip: '入栈',
                  onPressed: () => context.push('/home/sub'),
                  child: const Icon(Icons.arrow_forward),
                ),
              ),
            ),
            routes: [
              GoRoute(
                path: 'sub',
                pageBuilder: (context, state) => _transitionPage(
                  state,
                  Scaffold(
                    appBar: AppBar(
                      leading: BackButton(onPressed: () => context.pop()),
                    ),
                    body: Center(
                      child: ElevatedButton(
                        onPressed: () => taps++,
                        child: const Text('子页按钮'),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      // 首页 AppBar 按钮可点击。
      await tester.tap(find.byTooltip('计数'));
      await tester.pump();
      expect(taps, 1);

      // 列表可滚动。
      await tester.drag(find.text('条目5'), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));

      // 入栈子页后子页按钮可点击。
      await tester.tap(find.byTooltip('入栈'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('子页按钮'));
      await tester.pump();
      expect(taps, 2);

      // 返回后首页按钮仍可点击。
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('计数'));
      await tester.pump();
      expect(taps, 3);
    });
  }
}
