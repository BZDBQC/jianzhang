import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/app/controller.dart';
import 'package:jianzhang/app/services.dart';
import 'package:jianzhang/app/theme.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:jianzhang/services/file_service.dart';
import 'package:jianzhang/ui/entry_form.dart';
import 'package:jianzhang/ui/file_actions.dart';
import 'package:jianzhang/ui/ledger_pages.dart';
import 'package:jianzhang/ui/manage_pages.dart';
import 'package:path/path.dart' as p;

import 'app_flow_test.dart'
    show UiFixture, appWith, ioWidgetTest, settleUi, waitForUi;

Future<UiFixture> fixtureFor(WidgetTester tester) async {
  final fixture = await UiFixture.open();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(fixture.close);
  });
  return fixture;
}

Future<LedgerTransaction> sample(
  LedgerRepository repository,
  String id, {
  int amount = 1234,
  String note = '原账本草稿',
}) async {
  final account = (await repository.listAccounts()).first;
  final category = (await repository.listCategories(
    type: EntryType.expense,
  )).firstWhere((c) => c.parentId != null);
  return LedgerTransaction(
    id: id,
    type: EntryType.expense,
    amount: amount,
    date: localDateTime(),
    createdAt: localDateTime(),
    accountId: account.id,
    categoryId: category.id,
    note: note,
  );
}

ProviderContainer container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));

Future<void> mountPage(
  WidgetTester tester,
  LedgerRepository repository,
  Widget Function(LedgerView) page,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [repositoryProvider.overrideWith((ref) => repository)],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: Consumer(
          builder: (_, ref, _) => Scaffold(
            body: ref
                .watch(ledgerProvider)
                .when(
                  data: page,
                  loading: () => const CircularProgressIndicator(),
                  error: (error, _) => Text(error.toString()),
                ),
          ),
        ),
      ),
    ),
  );
  await settleUi(tester);
}

class OwnedPicker extends FileService {
  OwnedPicker(this.result);
  final Future<PickedJson?> result;
  int released = 0;
  @override
  Future<PickedJson?> pickJson() => result;
  @override
  Future<void> releasePickedJson(PickedJson picked) async {
    released++;
    if (picked.ownedTemporary) await File(picked.path).delete();
  }
}

void main() {
  ioWidgetTest(
    'native ready telemetry waits for local first frame and emits once',
    (tester) async {
      final fixture = await fixtureFor(tester);
      var calls = 0;
      const channel = MethodChannel('jianzhang/performance');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'reportFullyDrawn');
        expect(find.text('收支概览'), findsOneWidget);
        expect(find.text('正在打开本机账本…'), findsNothing);
        calls++;
        return {'readyMs': 420};
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(appWith(fixture.repository));
      await settleUi(tester);
      await container(tester).read(ledgerProvider.notifier).refresh();
      await settleUi(tester);
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );
  ioWidgetTest(
    'transaction draft cannot move to equal-sequence workspace and resumes only in origin',
    (tester) async {
      final fixture = await fixtureFor(tester);
      final row = await sample(fixture.repository, 'draft');
      await tester.pumpWidget(appWith(fixture.repository));
      await settleUi(tester);
      unawaited(
        showEntry(
          tester.element(find.byType(Scaffold).first),
          entry: row,
          duplicate: true,
        ),
      );
      await settleUi(tester);
      await fixture.repository.switchWorkspace('user:other');
      await settleUi(tester);
      expect((await fixture.repository.meta()).sequence, 0);
      await tester.ensureVisible(find.byKey(const Key('entry-save')));
      await tester.tap(find.byKey(const Key('entry-save')));
      await settleUi(tester);
      expect(find.byType(EntryForm), findsOneWidget);
      expect((await fixture.repository.meta()).transactionCount, 0);
      await tester.ensureVisible(find.text('重新读取并核对后再保存'));
      await tester.tap(find.text('重新读取并核对后再保存'));
      await settleUi(tester);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('entry-note')))
            .controller!
            .text,
        row.note,
      );
      await fixture.repository.switchWorkspace('guest');
      await settleUi(tester);
      await tester.ensureVisible(find.text('重新读取并核对后再保存'));
      await tester.tap(find.text('重新读取并核对后再保存'));
      await settleUi(tester);
      await tester.ensureVisible(find.byKey(const Key('entry-save')));
      await tester.tap(find.byKey(const Key('entry-save')));
      await settleUi(tester);
      expect(find.byType(EntryForm), findsNothing);
      expect((await fixture.repository.meta()).transactionCount, 1);
      expect(
        (await fixture.repository.workspaceMeta('user:other')).transactionCount,
        0,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final kind in ['account', 'category', 'budget', 'category-delete']) {
    ioWidgetTest('$kind delayed form cannot modify another workspace', (
      tester,
    ) async {
      final fixture = await fixtureFor(tester);
      await tester.pumpWidget(appWith(fixture.repository));
      await settleUi(tester);
      final view = container(tester).read(ledgerProvider).requireValue;
      final leaf = view.categories.firstWhere((c) => c.parentId != null);
      final Widget editor = switch (kind) {
        'account' => AccountEditor(scope: view.meta),
        'category' => CategoryEditor(view: view),
        'budget' => BudgetEditor(view: view),
        _ => CategoryDelete(view: view, category: leaf),
      };
      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(Scaffold).first),
          builder: (_) => editor,
        ),
      );
      await settleUi(tester);
      if (kind == 'account') {
        await tester.enterText(find.byType(TextFormField).first, '不得跨账本账户');
      }
      if (kind == 'category') {
        await tester.enterText(find.byType(TextField).first, '不得跨账本分类');
      }
      if (kind == 'budget') {
        await tester.enterText(find.byType(TextField).first, '100.00');
      }
      await fixture.repository.switchWorkspace('user:other');
      await settleUi(tester);
      final label = switch (kind) {
        'account' => '保存账户',
        'category' => '保存分类',
        'budget' => '保存预算',
        _ => '删除未使用分类',
      };
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await settleUi(tester);
      expect((await fixture.repository.meta()).sequence, 0);
      expect(find.byWidget(editor), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '重新读取并核对'))
            .onPressed,
        isNull,
      );
      expect((await fixture.repository.workspaceMeta('guest')).sequence, 0);
      expect(tester.takeException(), isNull);
    });
  }

  ioWidgetTest(
    'delete confirmation stays bound to original workspace even with shared IDs',
    (tester) async {
      final fixture = await fixtureFor(tester);
      await fixture.repository.saveTransaction(
        await sample(fixture.repository, 'shared'),
        create: true,
      );
      await fixture.repository.switchWorkspace('user:other');
      await fixture.repository.saveTransaction(
        await sample(fixture.repository, 'shared', note: '另一个账本'),
        create: true,
      );
      await fixture.repository.switchWorkspace('guest');
      await tester.pumpWidget(appWith(fixture.repository));
      await settleUi(tester);
      await tester.ensureVisible(find.byTooltip('账单操作').first);
      await settleUi(tester);
      await tester.tap(find.byTooltip('账单操作').first);
      await settleUi(tester);
      await tester.tap(find.text('删除').last);
      await settleUi(tester);
      expect(find.text('删除这笔账单？'), findsOneWidget);
      await fixture.repository.switchWorkspace('user:other');
      await settleUi(tester);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await settleUi(tester);
      expect((await fixture.repository.meta()).transactionCount, 1);
      expect(
        (await fixture.repository.workspaceMeta('guest')).transactionCount,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final report in [false, true]) {
    ioWidgetTest(
      '${report ? 'reports' : 'bills'} reloads on workspace key with equal sequence',
      (tester) async {
        final fixture = await fixtureFor(tester);
        await fixture.repository.saveTransaction(
          await sample(
            fixture.repository,
            'shared',
            amount: 1000,
            note: '原账本账单',
          ),
          create: true,
        );
        await fixture.repository.switchWorkspace('user:other');
        await fixture.repository.saveTransaction(
          await sample(
            fixture.repository,
            'shared',
            amount: 2000,
            note: '新账本账单',
          ),
          create: true,
        );
        await fixture.repository.switchWorkspace('guest');
        await mountPage(
          tester,
          fixture.repository,
          (view) => report
              ? ReportsPage(view: view, onDrill: (_) {})
              : BillsPage(view: view),
        );
        expect(find.text(report ? '¥ 10.00' : '原账本账单'), findsWidgets);
        await fixture.repository.switchWorkspace('user:other');
        await settleUi(tester);
        expect(find.text(report ? '¥ 20.00' : '新账本账单'), findsWidgets);
        expect(find.text(report ? '¥ 10.00' : '原账本账单'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  ioWidgetTest(
    'deleting final page last entry returns to valid previous page',
    (tester) async {
      final fixture = await fixtureFor(tester);
      final template = await sample(fixture.repository, 'template');
      for (var i = 0; i < 51; i++) {
        await fixture.repository.saveTransaction(
          LedgerTransaction(
            id: 'page-$i',
            type: template.type,
            amount: template.amount,
            date: template.date,
            accountId: template.accountId,
            categoryId: template.categoryId,
            createdAt: template.createdAt,
            note: '分页账单 $i',
          ),
          create: true,
        );
      }
      await mountPage(
        tester,
        fixture.repository,
        (view) => BillsPage(view: view),
      );
      await tester.tap(find.byTooltip('下一页'));
      await settleUi(tester);
      expect(find.text('第 51–51 笔，共 51 笔'), findsOneWidget);
      final last = (await fixture.repository.search(
        const LedgerFilter(),
        offset: 50,
      )).items.single;
      await fixture.repository.deleteTransaction(last.id);
      await settleUi(tester);
      expect(find.text('第 1–50 笔，共 50 笔'), findsOneWidget);
      expect(find.text('没有匹配账单'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final invalid in [false, true]) {
    ioWidgetTest(
      'picker cache released after ${invalid ? 'invalid JSON' : 'cancelled preview'}',
      (tester) async {
        final fixture = await fixtureFor(tester);
        final file = File(p.join(fixture.directory.path, 'picked.json'));
        await file.writeAsString(
          invalid
              ? '{broken'
              : jsonEncode(await fixture.repository.cloudSnapshot()),
        );
        final picker = OwnedPicker(
          Future.value(PickedJson(file.path, ownedTemporary: true)),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              repositoryProvider.overrideWith((ref) => fixture.repository),
              fileServiceProvider.overrideWithValue(picker),
            ],
            child: MaterialApp(
              home: Consumer(
                builder: (context, ref, _) => Scaffold(
                  body: ref
                      .watch(ledgerProvider)
                      .when(
                        data: (_) => TextButton(
                          onPressed: () => importBook(context, ref),
                          child: const Text('导入测试'),
                        ),
                        loading: () => const CircularProgressIndicator(),
                        error: (error, _) => Text(error.toString()),
                      ),
                ),
              ),
            ),
          ),
        );
        await settleUi(tester);
        await tester.tap(find.text('导入测试'));
        if (!invalid) {
          await waitForUi(tester, find.text('确认恢复备份？'));
          await tester.tap(find.text('取消'));
        }
        await settleUi(tester);
        expect(picker.released, 1);
        expect(await file.exists(), isFalse);
        expect((await fixture.repository.meta()).transactionCount, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
