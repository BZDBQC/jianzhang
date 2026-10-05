import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/app/controller.dart';
import 'package:jianzhang/ui/ledger_pages.dart';
import 'package:jianzhang/ui/shell.dart';
import 'package:jianzhang/app/theme.dart';

import 'app_flow_test.dart' show UiFixture, ioWidgetTest, settleUi;

void main() {
  for (final inset in const [
    EdgeInsets.only(right: 48),
    EdgeInsets.only(left: 48),
  ]) {
    ioWidgetTest('landscape body avoids system navigation inset $inset', (
      tester,
    ) async {
      final fixture = await UiFixture.open();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(fixture.close);
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 400);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWith((ref) => fixture.repository),
          ],
          child: MaterialApp(
            theme: buildAppTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(padding: inset, viewPadding: inset),
              child: child!,
            ),
            home: const LedgerShell(),
          ),
        ),
      );
      await settleUi(tester);
      final content = tester.getRect(find.byType(HomePage));
      expect(content.left, greaterThanOrEqualTo(inset.left));
      expect(content.right, lessThanOrEqualTo(800 - inset.right));
      final add = tester.getRect(find.byKey(const Key('add-entry')));
      expect(add.left, greaterThanOrEqualTo(inset.left));
      expect(add.right, lessThanOrEqualTo(800 - inset.right));
      expect(tester.takeException(), isNull);
    });
  }
}
