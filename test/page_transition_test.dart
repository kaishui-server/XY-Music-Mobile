import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xy_music/src/core/settings.dart';
import 'package:xy_music/src/navigation/animated_page_route.dart';

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
  }
}
