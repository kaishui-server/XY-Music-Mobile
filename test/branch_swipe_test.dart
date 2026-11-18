import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/navigation/animated_branch_container.dart';

Widget _page(String label, Color color) =>
    ColoredBox(color: color, child: Center(child: Text(label)));

/// 横滑跟手切页：拖动时两页跟手可见，松手按进度/速度决定提交或回弹。
void main() {
  _swipeOrderTests();

  tearDown(() {
    updateBranchSwipe(enabled: false, order: const <int>[]);
  });

  Future<_HarnessState> pumpHarness(
    WidgetTester tester, {
    required List<int> selected,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _Harness(selected: selected, children: const [
          _BranchPage('A', Colors.red),
          _BranchPage('B', Colors.green),
          _BranchPage('C', Colors.blue),
        ]),
      ),
    );
    return tester.state<_HarnessState>(find.byType(_Harness));
  }

  testWidgets('向左拖过半页松手：提交下一个分支，目标页在位且不二次滑动', (tester) async {
    updateBranchSwipe(enabled: true, order: const <int>[0, 1, 2]);
    final selected = <int>[];
    final state = await pumpHarness(tester, selected: selected);

    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsNothing);

    final gesture = await tester.startGesture(const Offset(400, 300));
    await tester.pump();
    for (var step = 0; step < 9; step++) {
      await gesture.moveBy(const Offset(-50, 0));
      await tester.pump();
    }

    // 跟手阶段：目标页已进入视野，且尚未提交分支切换。
    expect(find.text('B'), findsOneWidget);
    expect(selected, isEmpty);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(selected, <int>[1]);
    expect(state.index, 1);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('A'), findsNothing);
  });

  testWidgets('小幅拖动松手：回弹到原页，不触发切换', (tester) async {
    updateBranchSwipe(enabled: true, order: const <int>[0, 1, 2]);
    final selected = <int>[];
    final state = await pumpHarness(tester, selected: selected);

    final gesture = await tester.startGesture(const Offset(400, 300));
    await tester.pump();
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(selected, isEmpty);
    expect(state.index, 0);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsNothing);
  });

  testWidgets('向右拖（无上一页）不触发切换', (tester) async {
    updateBranchSwipe(enabled: true, order: const <int>[0, 1, 2]);
    final selected = <int>[];
    final state = await pumpHarness(tester, selected: selected);

    final gesture = await tester.startGesture(const Offset(400, 300));
    await tester.pump();
    for (var step = 0; step < 9; step++) {
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(selected, isEmpty);
    expect(state.index, 0);
  });

  testWidgets('横向切页关闭时不接管手势', (tester) async {
    updateBranchSwipe(enabled: false, order: const <int>[0, 1, 2]);
    final selected = <int>[];
    final state = await pumpHarness(tester, selected: selected);

    final gesture = await tester.startGesture(const Offset(400, 300));
    await tester.pump();
    for (var step = 0; step < 9; step++) {
      await gesture.moveBy(const Offset(-50, 0));
      await tester.pump();
    }
    expect(find.text('B'), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(selected, isEmpty);
    expect(state.index, 0);
  });
}

class _BranchPage extends StatelessWidget {
  const _BranchPage(this.label, this.color);

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => _page(label, color);
}

class _Harness extends StatefulWidget {
  const _Harness({required this.selected, required this.children});

  final List<int> selected;
  final List<Widget> children;

  @override
  State<_Harness> createState() => _HarnessState();
}

/// 可见目的地 → 分支下标序列的映射（底栏自定义后横滑能否生效的关键）。
void _swipeOrderTests() {
  const branchPaths = <String?>[
    '/home',
    '/music-library',
    '/sound-effects',
    '/settings',
  ];

  test('底栏含分支子路由（探索/插件管理）时按最长前缀归属，不再整条丢弃', () {
    final order = branchSwipeOrderFromPaths(
      visiblePaths: const [
        '/home/explore',
        '/settings/plugins',
        '/account',
      ],
      branchPaths: branchPaths,
      currentIndex: 0,
    );
    // /account 不属于任何分支，跳过；当前分支补在最前。
    expect(order, <int>[0, 3]);
  });

  test('当前分支不在可见目的地里（底栏没放首页）时补到最前，仍可滑动', () {
    final order = branchSwipeOrderFromPaths(
      visiblePaths: const ['/music-library', '/settings'],
      branchPaths: branchPaths,
      currentIndex: 0,
    );
    expect(order, <int>[0, 1, 3]);
  });

  test('可见目的地全在分支内时保持底栏顺序', () {
    final order = branchSwipeOrderFromPaths(
      visiblePaths: const ['/settings', '/home', '/music-library'],
      branchPaths: branchPaths,
      currentIndex: 1,
    );
    expect(order, <int>[3, 0, 1]);
  });
}

class _HarnessState extends State<_Harness> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    return AnimatedBranchContainer(
      currentIndex: index,
      children: widget.children,
      onBranchSelected: (target) {
        widget.selected.add(target);
        setState(() => index = target);
      },
    );
  }
}
