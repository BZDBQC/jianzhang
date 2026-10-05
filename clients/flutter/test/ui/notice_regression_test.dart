import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/ui/common.dart';
import 'package:jianzhang/ui/entry_form.dart';

import 'app_flow_test.dart' show UiFixture, appWith, ioWidgetTest, settleUi;

void main() {
  for (final width in [1000.0, 1440.0]) {
    ioWidgetTest('desktop notice leaves add entry accessible at $width', (
      tester,
    ) async {
      final fixture = await UiFixture.open();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(fixture.close);
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 780);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(appWith(fixture.repository));
      await settleUi(tester);
      final add = find.byKey(const Key('add-entry'));
      expect(add, findsOneWidget);
      showNotice(tester.element(add), '账单已保存到本机');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        tester.getRect(add).overlaps(tester.getRect(find.byType(SnackBar))),
        isFalse,
      );
      await tester.tap(add);
      await settleUi(tester);
      expect(find.byType(EntryForm), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
