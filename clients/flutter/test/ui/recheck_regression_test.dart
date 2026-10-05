import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/app/controller.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:jianzhang/ui/entry_form.dart';
import 'package:jianzhang/ui/manage_pages.dart';

import 'app_flow_test.dart' show appWith, ioWidgetTest, settleUi;
import 'scope_regression_test.dart' show container, fixtureFor, sample;

Future<void> openEditor(WidgetTester tester, Widget editor) async {
  unawaited(
    showDialog<void>(
      context: tester.element(find.byType(Scaffold).first),
      builder: (_) => editor,
    ),
  );
  await settleUi(tester);
}

Future<void> click(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label).last);
  await settleUi(tester);
  await tester.tap(find.text(label).last);
  await settleUi(tester);
}

void main() {
  ioWidgetTest(
    'rechecked account rename preserves concurrent archive and visible draft',
    (tester) async {
      final fixture = await fixtureFor(tester);
      await tester.pumpWidget(appWith(fixture.repository));
      await settleUi(tester);
      final view = container(tester).read(ledgerProvider).requireValue;
      final account = view.accounts.first;
      await openEditor(
        tester,
        AccountEditor(account: account, scope: view.meta),
      );
      await tester.enterText(find.byType(TextFormField).first, '改名草稿');
      await fixture.repository.archiveAccount(account.id, true);
      await settleUi(tester);
      await click(tester, '保存账户');
      expect(find.byType(AccountEditor), findsOneWidget);
      await click(tester, '重新读取并核对');
      expect(find.text('当前账户已归档，保存名称和余额会保留归档状态。'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        '改名草稿',
      );
      await click(tester, '保存账户');
      final saved = (await fixture.repository.listAccounts()).firstWhere(
        (row) => row.id == account.id,
      );
      expect(saved.name, '改名草稿');
      expect(saved.archived, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  ioWidgetTest(
    'category recheck refreshes hidden icon color while retaining rename',
    (tester) async {
      final fixture = await fixtureFor(tester);
      await tester.pumpWidget(appWith(fixture.repository));
      await settleUi(tester);
      final view = container(tester).read(ledgerProvider).requireValue;
      final leaf = view.categories.firstWhere((row) => row.parentId != null);
      await openEditor(tester, CategoryEditor(view: view, category: leaf));
      await tester.enterText(find.byType(TextField).first, '分类改名草稿');
      await fixture.repository.upsertCategory(
        leaf.copyWith(icon: 'Home', color: '#123456'),
      );
      await settleUi(tester);
      await click(tester, '保存分类');
      await click(tester, '重新读取并核对');
      await click(tester, '保存分类');
      final saved = (await fixture.repository.listCategories()).firstWhere(
        (row) => row.id == leaf.id,
      );
      expect(saved.name, '分类改名草稿');
      expect(saved.icon, 'Home');
      expect(saved.color, '#123456');
      expect(tester.takeException(), isNull);
    },
  );

  for (final deleting in [false, true]) {
    ioWidgetTest(
      '${deleting ? 'delete' : 'edit'} category recheck refuses already deleted object',
      (tester) async {
        final fixture = await fixtureFor(tester);
        await tester.pumpWidget(appWith(fixture.repository));
        await settleUi(tester);
        final view = container(tester).read(ledgerProvider).requireValue;
        final leaf = view.categories.firstWhere((row) => row.parentId != null);
        await openEditor(
          tester,
          deleting
              ? CategoryDelete(view: view, category: leaf)
              : CategoryEditor(view: view, category: leaf),
        );
        if (!deleting) {
          await tester.enterText(find.byType(TextField).first, '删除后保留草稿');
        }
        await fixture.repository.deleteCategory(leaf.id);
        await settleUi(tester);
        await click(tester, '重新读取并核对');
        final label = deleting ? '删除未使用分类' : '保存分类';
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, label))
              .onPressed,
          isNull,
        );
        if (!deleting) {
          expect(
            tester
                .widget<TextField>(find.byType(TextField).first)
                .controller!
                .text,
            '删除后保留草稿',
          );
        }
        expect(
          (await fixture.repository.listCategories()).any(
            (row) => row.id == leaf.id,
          ),
          isFalse,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  ioWidgetTest(
    'new subcategory recheck exposes added parent options and keeps name',
    (tester) async {
      final fixture = await fixtureFor(tester);
      await tester.pumpWidget(appWith(fixture.repository));
      await settleUi(tester);
      final view = container(tester).read(ledgerProvider).requireValue;
      final parent = view.categories.firstWhere(
        (row) => row.type == EntryType.expense && row.parentId == null,
      );
      await openEditor(tester, CategoryEditor(view: view, parent: parent));
      await tester.enterText(find.byType(TextField).first, '新增小类草稿');
      const added = Category(
        id: 'added-parent',
        name: '并发新增大类',
        type: EntryType.expense,
      );
      await fixture.repository.upsertCategory(added);
      await settleUi(tester);
      await click(tester, '重新读取并核对');
      final dropdown = tester.widget<DropdownButton<String>>(
        find.byType(DropdownButton<String>),
      );
      expect(dropdown.items!.any((item) => item.value == added.id), isTrue);
      await tester.tap(find.text('所属大类'));
      await settleUi(tester);
      await tester.tap(find.text(added.name).last);
      await settleUi(tester);
      await click(tester, '保存分类');
      final saved = (await fixture.repository.listCategories()).firstWhere(
        (row) => row.name == '新增小类草稿',
      );
      expect(saved.parentId, added.id);
      expect(tester.takeException(), isNull);
    },
  );

  ioWidgetTest('budget recheck refuses deleted budget without recreating it', (
    tester,
  ) async {
    final fixture = await fixtureFor(tester);
    final budget = Budget(month: monthKey(DateTime.now()), amount: 10000);
    await fixture.repository.upsertBudget(budget);
    await tester.pumpWidget(appWith(fixture.repository));
    await settleUi(tester);
    final view = container(tester).read(ledgerProvider).requireValue;
    await openEditor(tester, BudgetEditor(view: view, budget: budget));
    await tester.enterText(find.byType(TextField).first, '333.00');
    await fixture.repository.deleteBudget(budget.month, budget.categoryId);
    await settleUi(tester);
    await click(tester, '重新读取并核对');
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存预算'))
          .onPressed,
      isNull,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '333.00',
    );
    expect(await fixture.repository.listBudgets(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  ioWidgetTest(
    'entry recheck uses ID outside recent page and refuses concurrent deletion',
    (tester) async {
      final fixture = await fixtureFor(tester);
      final old = (await sample(fixture.repository, 'old-entry')).copyWith(
        date: localDateTime(DateTime.now().subtract(const Duration(days: 1))),
      );
      await fixture.repository.saveTransaction(old, create: true);
      for (var i = 0; i < 13; i++) {
        await fixture.repository.saveTransaction(
          await sample(fixture.repository, 'recent-$i'),
          create: true,
        );
      }
      await tester.pumpWidget(appWith(fixture.repository));
      await settleUi(tester);
      final view = container(tester).read(ledgerProvider).requireValue;
      expect(view.recent.items.any((row) => row.id == old.id), isFalse);
      unawaited(
        showEntry(tester.element(find.byType(Scaffold).first), entry: old),
      );
      await settleUi(tester);
      await tester.enterText(find.byKey(const Key('entry-note')), '删除后仍保留备注');
      await fixture.repository.deleteTransaction(old.id);
      await settleUi(tester);
      await click(tester, '保存账单');
      await click(tester, '重新读取并核对后再保存');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('entry-save')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('entry-note')))
            .controller!
            .text,
        '删除后仍保留备注',
      );
      expect(await fixture.repository.transactionById(old.id), isNull);
      expect((await fixture.repository.meta()).transactionCount, 13);
      expect(tester.takeException(), isNull);
    },
  );

  ioWidgetTest('entry recheck refreshes new accounts and small categories', (
    tester,
  ) async {
    final fixture = await fixtureFor(tester);
    final row = await sample(fixture.repository, 'template');
    await tester.pumpWidget(appWith(fixture.repository));
    await settleUi(tester);
    final view = container(tester).read(ledgerProvider).requireValue;
    final parentId = view.category(row.categoryId)!.parentId!;
    unawaited(
      showEntry(
        tester.element(find.byType(Scaffold).first),
        entry: row,
        duplicate: true,
      ),
    );
    await settleUi(tester);
    const account = Account(id: 'added-account', name: '并发新增账户');
    final category = Category(
      id: 'added-child',
      name: '并发新增小类',
      type: EntryType.expense,
      parentId: parentId,
    );
    await fixture.repository.upsertAccount(account);
    await fixture.repository.upsertCategory(category);
    await settleUi(tester);
    await click(tester, '保存账单');
    await click(tester, '重新读取并核对后再保存');
    final fields = tester.widgetList<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(
      fields.any(
        (field) => field.items!.any((item) => item.value == account.id),
      ),
      isTrue,
    );
    expect(
      fields.any(
        (field) => field.items!.any((item) => item.value == category.id),
      ),
      isTrue,
    );
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('entry-amount')))
          .controller!
          .text,
      '12.34',
    );
    expect(tester.takeException(), isNull);
  });
}
