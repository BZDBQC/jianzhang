import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:jianzhang/data/safe_files.dart';
import 'package:jianzhang/data/sqlite_ledger_repository.dart';

import 'repository_regression_test.dart' show entry, fixture;

void main() {
  late Directory dir;
  late LedgerRepository repo;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jianzhang-scope-');
    repo = await LedgerRepository.open(path: '${dir.path}/ledger.db');
  });
  tearDown(() async {
    await repo.close();
    await deleteOwnedScratchDirectory(dir, 'jianzhang-scope-');
  });
  test(
    'SQLite note and keyword folding retain full Unicode JS casing',
    () async {
      await repo.saveTransaction(
        entry('sigma', note: 'ΟΣ İSTANBUL \u{1e900}'),
        create: true,
      );
      for (final word in [
        'ος',
        'ΟΣ',
        'i\u0307stanbul',
        'İSTANBUL',
        '\u{1e922}',
      ]) {
        expect((await repo.search(LedgerFilter(note: word))).total, 1);
      }
      expect((await repo.search(const LedgerFilter(note: 'οσ'))).total, 0);
      expect(
        (await repo.search(const LedgerFilter(note: 'istanbul'))).total,
        0,
      );
    },
  );

  test(
    'all mutations and delayed reads reject another workspace with equal sequence',
    () async {
      await repo.saveTransaction(entry('shared'), create: true);
      final original = await repo.meta();
      final preview = await repo.previewJson(jsonEncode(await fixture()));
      final backup = await repo.backupSnapshot(await fixture());
      await repo.switchWorkspace('user:other');
      await repo.saveTransaction(entry('shared'), create: true);
      final target = await repo.meta();
      expect(target.sequence, original.sequence);
      final account = (await repo.listAccounts()).first;
      final category = (await repo.listCategories()).firstWhere(
        (c) => c.parentId != null,
      );
      final settings = await repo.settings();
      final cloud = await fixture();
      final operations = <Future<void> Function(String, int)>[
        (w, s) async {
          await repo.saveTransaction(
            entry('shared', amount: 99),
            expectedWorkspace: w,
            expectedSequence: s,
          );
        },
        (w, s) async {
          await repo.saveTransaction(
            entry('new'),
            create: true,
            expectedWorkspace: w,
            expectedSequence: s,
          );
        },
        (w, s) async {
          await repo.deleteTransaction(
            'shared',
            expectedWorkspace: w,
            expectedSequence: s,
          );
        },
        (w, s) async {
          await repo.upsertAccount(
            account.copyWith(name: 'changed'),
            expectedWorkspace: w,
            expectedSequence: s,
          );
        },
        (w, s) async {
          await repo.archiveAccount(
            account.id,
            true,
            expectedWorkspace: w,
            expectedSequence: s,
          );
        },
        (w, s) async {
          await repo.upsertCategory(
            category.copyWith(name: 'changed'),
            expectedWorkspace: w,
            expectedSequence: s,
          );
        },
        (w, s) async {
          await repo.deleteCategory(
            category.id,
            reassignTo: 'food-lunch',
            expectedWorkspace: w,
            expectedSequence: s,
          );
        },
        (w, s) async {
          await repo.upsertBudget(
            const Budget(month: '2026-10', amount: 100),
            expectedWorkspace: w,
            expectedSequence: s,
          );
        },
        (w, s) async {
          await repo.deleteBudget(
            '2026-10',
            '',
            expectedWorkspace: w,
            expectedSequence: s,
          );
        },
        (w, s) async {
          await repo.updateSettings(
            settings.copyWith(notifications: false),
            expectedWorkspace: w,
            expectedSequence: s,
          );
        },
        (w, s) async {
          await repo.importAtomic(
            preview,
            expectedWorkspace: w,
            expectedSequence: s,
          );
        },
        (w, s) async {
          await repo.restoreBackup(
            backup,
            expectedWorkspace: w,
            expectedSequence: s,
          );
        },
        (w, s) async {
          await repo.switchWorkspace(
            'guest',
            expectedWorkspace: w,
            expectedSequence: s,
          );
        },
        (w, s) async {
          await repo.previewJson(
            jsonEncode(cloud),
            expectedWorkspace: w,
            expectedSequence: s,
          );
        },
        (w, s) async {
          await repo.previewImport(
            '../../tests/fixtures/native-ledger-v1.json',
            expectedWorkspace: w,
            expectedSequence: s,
          );
        },
        (w, s) async {
          await repo.writeExport(
            '${dir.path}/out.json',
            ExportFormat.json,
            expectedWorkspace: w,
            expectedSequence: s,
          );
        },
        (w, s) async {
          await repo.cloudSnapshot(expectedWorkspace: w, expectedSequence: s);
        },
        (w, s) async {
          await repo.replaceSnapshot(
            cloud,
            expectedSourceWorkspace: w,
            expectedSequence: s,
          );
        },
        (w, s) async {
          await repo.setCloudRevision(
            9,
            expectedWorkspace: w,
            workspace: w,
            expectedSequence: s,
          );
        },
      ];
      for (final operation in operations) {
        await expectLater(
          operation(original.key, original.sequence),
          throwsA(isA<LedgerConflict>()),
        );
        expect((await repo.meta()).key, target.key);
        expect((await repo.meta()).sequence, target.sequence);
      }
      // A stale sequence in the correct workspace also rejects the write/reads.
      for (final operation in operations.take(18)) {
        await expectLater(
          operation(target.key, 0),
          throwsA(isA<LedgerConflict>()),
        );
      }
      expect((await repo.summary()).count, 1);
      expect((await repo.summary()).expense, 10);
      expect((await repo.listAccounts()).first.name, account.name);
      expect((await repo.listBackups()).map((b) => b.id), [backup.id]);
      expect((await repo.meta()).cloudRevision, isNull);
    },
  );

  test(
    'filtered JSON exports exactly search results and remains restorable',
    () async {
      await repo.importAtomic(
        await repo.previewJson(jsonEncode(await fixture())),
      );
      const filter = LedgerFilter(
        types: [EntryType.expense],
        includeFees: true,
        categoryIds: ['other'],
        amountOp: 'eq',
        amountMin: '2.34',
      );
      final expected = (await repo.search(
        filter,
      )).items.map((t) => t.id).toList();
      expect(expected, isNotEmpty);
      final file = File('${dir.path}/筛选账本.json');
      final scope = await repo.meta();
      await repo.exportFile(
        file.path,
        filter: filter,
        expectedWorkspace: scope.key,
        expectedSequence: scope.sequence,
      );
      final data = jsonObject(jsonDecode(await file.readAsString()));
      expect(
        (data['transactions'] as List).map((t) => (t as Map)['id']),
        expected,
      );
      expect(
        (data['accounts'] as List).length,
        (await repo.listAccounts()).length,
      );
      expect(
        (data['categories'] as List).length,
        (await repo.listCategories()).length,
      );
      final preview = await repo.previewImport(file.path);
      await repo.importAtomic(preview);
      expect(
        (await repo.search(const LedgerFilter())).items.map((t) => t.id),
        expected,
      );
      expect((await repo.summary()).expense, 234);
    },
  );

  test(
    'calendar month buckets and grouped ranges cover the final day',
    () async {
      await repo.importAtomic(
        await repo.previewJson(jsonEncode(await fixture())),
      );
      final annual = await repo.statistics(
        start: '2026-01-01',
        end: '2026-12-31',
        monthly: true,
      );
      expect(annual.trend.length, 12);
      expect(annual.trend.first.start, '2026-01-01');
      expect(annual.trend.last.end, '2026-12-31');
      expect(
        annual.trend.fold<int>(0, (sum, b) => sum + b.expense),
        annual.summary.expense,
      );
      final part = await repo.statistics(
        start: '2026-10-15',
        end: '2026-11-12',
        monthly: true,
      );
      expect(part.trend.map((b) => '${b.start}/${b.end}'), [
        '2026-10-15/2026-10-31',
        '2026-11-01/2026-11-12',
      ]);
      final grouped = await repo.statistics(
        start: '2026-01-01',
        end: '2026-10-31',
      );
      expect(grouped.trend.length, lessThanOrEqualTo(60));
      expect(grouped.trend.last.end, '2026-10-31');
      expect(
        grouped.trend.fold<int>(0, (sum, b) => sum + b.expense),
        grouped.summary.expense,
      );
    },
  );

  test(
    'budget events and dedupe flags persist atomically only after commit',
    () async {
      await repo.close();
      var fail = false;
      repo = await SqliteLedgerRepository.connect(
        path: '${dir.path}/ledger.db',
        beforeCommit: (phase) async {
          if (fail && phase == 'save') {
            throw const LedgerException('Injected failure');
          }
        },
      );
      final month = localDateTime().substring(0, 7);
      await repo.upsertBudget(Budget(month: month, amount: 100, threshold: 80));
      final notices = <String>[];
      final subscription = repo.budgetNotifications.listen(notices.add);
      final current = entry('one', amount: 90).copyWith(date: localDateTime());
      fail = true;
      await expectLater(
        repo.saveTransaction(current, create: true),
        throwsA(isA<LedgerException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(notices, isEmpty);
      expect((await repo.settings()).notified, isEmpty);
      fail = false;
      await repo.saveTransaction(current, create: true);
      await Future<void>.delayed(Duration.zero);
      expect(notices.length, 1);
      expect((await repo.settings()).notified, ['$month::100:80']);
      await repo.updateSettings(
        (await repo.settings()).copyWith(defaultAccount: 'cash'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(notices.length, 1);
      await repo.saveTransaction(
        entry('two', amount: 10).copyWith(date: localDateTime()),
        create: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(notices.length, 2);
      expect((await repo.settings()).notified, [
        '$month::100:80',
        '$month::100:100',
      ]);
      await subscription.cancel();
      await repo.close();
      repo = await LedgerRepository.open(path: '${dir.path}/ledger.db');
      final afterRestart = <String>[];
      final restarted = repo.budgetNotifications.listen(afterRestart.add);
      await repo.deleteTransaction('two');
      await repo.saveTransaction(
        entry('three', amount: 10).copyWith(date: localDateTime()),
        create: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(afterRestart, isEmpty);
      await restarted.cancel();
    },
  );

  test(
    'backup pruning rolls back metadata on failed import and keeps ten valid files',
    () async {
      final cloud = await fixture();
      for (var i = 0; i < 10; i++) {
        await repo.backupSnapshot(cloud, label: 'cloud-$i');
      }
      final before = await repo.listBackups();
      await repo.close();
      var fail = true;
      repo = await SqliteLedgerRepository.connect(
        path: '${dir.path}/ledger.db',
        beforeCommit: (phase) async {
          if (fail && phase == 'import') {
            throw const LedgerException('Injected failure');
          }
        },
      );
      final preview = await repo.previewJson(jsonEncode(cloud));
      await expectLater(
        repo.importAtomic(preview),
        throwsA(isA<LedgerException>()),
      );
      expect(
        (await repo.listBackups()).map((b) => b.id),
        before.map((b) => b.id),
      );
      for (final backup in before) {
        expect(await File(backup.path).exists(), true);
      }
      expect((await repo.summary()).count, 0);
      fail = false;
      await repo.importAtomic(preview);
      final after = await repo.listBackups();
      expect(after.length, 10);
      expect(after.any((b) => b.id == before.last.id), false);
      for (final backup in after) {
        expect(await File(backup.path).exists(), true);
      }
      expect(await File(before.last.path).exists(), false);
    },
  );
}
