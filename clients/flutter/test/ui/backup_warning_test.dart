import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/app/controller.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:jianzhang/main.dart';
import 'package:jianzhang/ui/entry_form.dart';
import 'package:jianzhang/ui/manage_pages.dart';
import 'package:path/path.dart' as p;

import 'app_flow_test.dart' show UiFixture, appWith, ioWidgetTest, settleUi;
import 'recheck_regression_test.dart' show click, openEditor;

void main() {
  if (Platform.isWindows) {
    for (final accountEditor in [true, false]) {
      ioWidgetTest(
        'persistent storage warning permits draft recheck: $accountEditor',
        (tester) async {
          final root = await Directory(
            p.join(Directory.current.path, '.qa', 'ui-warning'),
          ).create(recursive: true);
          final fixture = await root.createTemp('readonly-');
          final path = p.join(fixture.path, 'ledger.sqlite');
          var repository = await LedgerRepository.open(path: path);
          var opened = true;
          final orphan = File(
            p.join(
              fixture.path,
              'backups',
              '00000000-0000-4000-8000-000000000001.json',
            ),
          );
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
            await tester.runAsync(() async {
              if (opened) await repository.close();
              if (await orphan.exists()) {
                final result = await Process.run('attrib.exe', [
                  '-R',
                  orphan.path,
                ]);
                if (result.exitCode != 0) {
                  throw TestFailure(
                    'Could not release owned read-only fixture',
                  );
                }
              }
              final resolved = await fixture.resolveSymbolicLinks();
              if (!p.isWithin(await root.resolveSymbolicLinks(), resolved)) {
                throw StateError('Warning fixture escaped its directory');
              }
              await Directory(resolved).delete(recursive: true);
            });
          });
          final account = (await repository.listAccounts()).first;
          final category = (await repository.listCategories(
            type: EntryType.expense,
          )).firstWhere((row) => row.parentId != null);
          final transaction = LedgerTransaction(
            id: 'warning-existing-entry',
            type: EntryType.expense,
            amount: 1234,
            accountId: account.id,
            categoryId: category.id,
            date: localDateTime(),
            createdAt: localDateTime(),
          );
          await repository.saveTransaction(transaction, create: true);
          await orphan.parent.create(recursive: true);
          await orphan.writeAsString('interrupted backup');
          expect(
            (await Process.run('attrib.exe', ['+R', orphan.path])).exitCode,
            0,
          );
          await repository.close();
          opened = false;
          repository = await LedgerRepository.open(path: path);
          opened = true;
          await tester.pumpWidget(appWith(repository));
          await settleUi(tester);
          final container = ProviderScope.containerOf(
            tester.element(find.byType(JianzhangApp)),
          );
          final view = container.read(ledgerProvider).requireValue;
          expect(view.storageWarning, isNotNull);
          expect(view.error, isNull);
          expect(find.byKey(const Key('storage-warning')), findsOneWidget);
          if (accountEditor) {
            await openEditor(
              tester,
              AccountEditor(account: view.accounts.first, scope: view.meta),
            );
            await tester.enterText(
              find.byType(TextFormField).first,
              '警告期间的改名草稿',
            );
          } else {
            unawaited(
              showEntry(
                tester.element(find.byType(Scaffold).first),
                entry: transaction,
              ),
            );
            await settleUi(tester);
            await tester.enterText(
              find.byKey(const Key('entry-amount')),
              '99.88',
            );
            await tester.enterText(
              find.byKey(const Key('entry-note')),
              '警告期间的备注草稿',
            );
          }
          expect(find.textContaining('账本已变化'), findsNothing);
          await repository.upsertAccount(account.copyWith(name: '后台更新名称'));
          await settleUi(tester);
          await click(tester, accountEditor ? '保存账户' : '保存账单');
          expect(
            find.byType(accountEditor ? AccountEditor : EntryForm),
            findsOneWidget,
          );
          await click(tester, accountEditor ? '重新读取并核对' : '重新读取并核对后再保存');
          expect(container.read(ledgerProvider).requireValue.error, isNull);
          expect(
            container.read(ledgerProvider).requireValue.storageWarning,
            isNotNull,
          );
          await click(tester, accountEditor ? '保存账户' : '保存账单');
          expect(
            find.byType(accountEditor ? AccountEditor : EntryForm),
            findsNothing,
          );
          if (accountEditor) {
            expect(
              (await repository.listAccounts())
                  .firstWhere((row) => row.id == account.id)
                  .name,
              '警告期间的改名草稿',
            );
          } else {
            final saved = await repository.transactionById(transaction.id);
            expect(saved!.amount, 9988);
            expect(saved.note, '警告期间的备注草稿');
          }
          expect(await orphan.exists(), isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final ledgerChanged in [true, false]) {
    ioWidgetTest(
      'cleanup failure acknowledges only changed ledger: $ledgerChanged',
      (tester) async {
        final fixture = await UiFixture.open();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await tester.runAsync(fixture.close);
        });
        await tester.pumpWidget(appWith(fixture.repository));
        await settleUi(tester);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(JianzhangApp)),
        );
        final before = container.read(ledgerProvider).requireValue.meta;
        var continuedToCloud = false;
        final result = await container.read(ledgerProvider.notifier).perform((
          repository,
        ) async {
          if (ledgerChanged) {
            final accounts = await repository.listAccounts();
            final category = (await repository.listCategories(
              type: EntryType.expense,
            )).firstWhere((entry) => entry.parentId != null);
            await repository.saveTransaction(
              LedgerTransaction(
                id: 'saved-before-cleanup-failure',
                type: EntryType.expense,
                amount: 1234,
                accountId: accounts.first.id,
                categoryId: category.id,
                date: localDateTime(),
                createdAt: localDateTime(),
              ),
              create: true,
            );
          }
          await Future<void>.error(
            LedgerBackupCleanupFailure(
              StateError('backup file is occupied'),
              committed: true,
              ledgerChanged: ledgerChanged,
            ),
          );
          continuedToCloud = true;
        }, expectedScope: before);
        await settleUi(tester);
        final view = container.read(ledgerProvider).requireValue;
        expect(result, ledgerChanged);
        expect(continuedToCloud, isFalse);
        expect(view.busy, isFalse);
        expect(view.meta.transactionCount, ledgerChanged ? 1 : 0);
        final notice = ledgerChanged ? view.storageWarning : view.error;
        if (ledgerChanged) expect(view.error, isNull);
        expect(notice, contains('备份清理失败'));
        expect(find.text(notice!), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
