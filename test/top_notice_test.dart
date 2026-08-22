import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/widgets/top_notice.dart';

void main() {
  testWidgets('提示条在顶部以圆角滑入，并在超时后动画退出', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => XyNotice.show(
                  context,
                  message: '顶部提示',
                  type: XyNoticeType.warning,
                  duration: const Duration(milliseconds: 600),
                ),
                child: const Text('显示'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('显示'));
    await tester.pump();
    expect(find.text('顶部提示'), findsOneWidget);
    expect(
      tester
          .widget<FadeTransition>(
            find.byKey(const ValueKey('xy-top-notice-fade')),
          )
          .opacity
          .value,
      0,
    );

    await tester.pump(const Duration(milliseconds: 300));
    final notice = find.byKey(const ValueKey('xy-top-notice'));
    expect(tester.getTopLeft(notice).dy, lessThan(100));
    final material = tester.widget<Material>(notice);
    expect(material.borderRadius, BorderRadius.circular(16));
    expect(
      tester
          .widget<FadeTransition>(
            find.byKey(const ValueKey('xy-top-notice-fade')),
          )
          .opacity
          .value,
      1,
    );

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    final exitingOpacity = tester
        .widget<FadeTransition>(
          find.byKey(const ValueKey('xy-top-notice-fade')),
        )
        .opacity
        .value;
    expect(exitingOpacity, greaterThan(0));
    expect(exitingOpacity, lessThan(1));

    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('顶部提示'), findsNothing);
  });
}
