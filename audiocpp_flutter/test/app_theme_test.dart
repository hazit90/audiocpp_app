import 'package:audiocpp_flutter/src/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Regression: the theme once set `minimumSize: Size.fromHeight(48)`, whose
  /// width is infinity. Inside a Row that fails layout and blanks the entire
  /// surrounding widget, which is how it first showed up — the Models page
  /// rendered as an empty black panel.
  for (final ThemeData theme in <ThemeData>[AppTheme.dark, AppTheme.light]) {
    testWidgets(
      'buttons lay out in an unbounded-width Row (${theme.brightness.name})',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Row(
                children: <Widget>[
                  const Expanded(child: Text('a package name')),
                  FilledButton(onPressed: () {}, child: const Text('Install')),
                  OutlinedButton(onPressed: () {}, child: const Text('Load')),
                ],
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byType(FilledButton)).width,
          lessThan(800),
        );
      },
    );
  }
}
