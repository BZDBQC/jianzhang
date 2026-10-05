import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:jianzhang/ui/entry_form.dart';

import 'app_flow_test.dart'
    show
        SaveFailureRepository,
        UiFixture,
        appWith,
        ioWidgetTest,
        selectDropdown,
        settleUi,
        waitForUi;

class DelayedSaveRepository extends SaveFailureRepository {
  DelayedSaveRepository(super.delegate);
  final gate = Completer<void>();
  int calls = 0;

  @override
  Future<void> saveTransaction(
    LedgerTransaction entry, {
    bool create = false,
    String? expectedWorkspace,
    int? expectedSequence,
  }) async {
    calls++;
    await gate.future;
    await delegate.saveTransaction(
      entry,
      create: create,
      expectedWorkspace: expectedWorkspace,
      expectedSequence: expectedSequence,
    );
  }
}

Future<void> escape(WidgetTester tester) => tester.sendKeyEvent(
  LogicalKeyboardKey.escape,
  physicalKey: PhysicalKeyboardKey.escape,
  platform: 'windows',
);

void main() {
  for (final width in [565.0, 1100.0]) {
    ioWidgetTest('Escape cancels an idle draft at width $width', (
      tester,
    ) async {
      final fixture = await UiFixture.open();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      try {
        final before = await fixture.repository.meta();
        await tester.pumpWidget(appWith(fixture.repository));
        await waitForUi(tester, find.text('本机已保存 · 0 笔账单'));
        await tester.tap(find.byKey(const Key('add-entry')));
        await settleUi(tester);
        await tester.enterText(find.byKey(const Key('entry-amount')), '12.34');
        await tester.enterText(find.byKey(const Key('entry-note')), '主动取消的草稿');
        await tester.tapAt(const Offset(1, 1));
        await settleUi(tester);
        expect(find.byType(EntryForm), findsOneWidget);
        await escape(tester);
        await settleUi(tester);
        expect(find.byType(EntryForm), findsNothing);
        final after = await fixture.repository.meta();
        expect(after.sequence, before.sequence);
        expect(after.transactionCount, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await fixture.close();
      }
    });
  }

  ioWidgetTest('Escape cannot close a pending database save', (tester) async {
    final fixture = await UiFixture.open();
    final delayed = DelayedSaveRepository(fixture.repository);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 900);
    try {
      await tester.pumpWidget(appWith(delayed));
      await waitForUi(tester, find.text('本机已保存 · 0 笔账单'));
      await tester.tap(find.byKey(const Key('add-entry')));
      await settleUi(tester);
      final categories = await fixture.repository.listCategories(
        type: EntryType.expense,
      );
      final leaf = categories.firstWhere(
        (category) => category.parentId != null,
      );
      final parent = categories.firstWhere(
        (category) => category.id == leaf.parentId,
      );
      await tester.enterText(find.byKey(const Key('entry-amount')), '12.34');
      await selectDropdown(tester, '大类', parent.name);
      await selectDropdown(tester, '小类', leaf.name);
      await tester.enterText(find.byKey(const Key('entry-note')), '保存中保持输入');
      await tester.ensureVisible(find.byKey(const Key('entry-save')));
      await tester.tap(find.byKey(const Key('entry-save')));
      await waitForUi(tester, find.text('正在保存…'));
      expect(delayed.calls, 1);
      await escape(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(EntryForm), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('entry-note')))
            .controller!
            .text,
        '保存中保持输入',
      );
      expect((await fixture.repository.meta()).transactionCount, 0);
      delayed.gate.complete();
      await waitForUi(tester, find.text('本机已保存 · 1 笔账单'));
      await settleUi(tester);
      expect(find.byType(EntryForm), findsNothing);
      final saved = await fixture.repository.search(const LedgerFilter());
      expect(saved.items, hasLength(1));
      expect(saved.items.single.amount, 1234);
      expect(saved.items.single.note, '保存中保持输入');
      expect(delayed.calls, 1);
      expect(tester.takeException(), isNull);
    } finally {
      if (!delayed.gate.isCompleted) delayed.gate.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await fixture.close();
    }
  });
}
