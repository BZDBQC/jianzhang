import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:jianzhang/data/safe_files.dart';
import 'package:jianzhang/data/sqlite_ledger_repository.dart';

import 'repository_regression_test.dart' show entry;

class _ReadBarrier {
  String? prefix;
  final reached = Completer<void>();
  final release = Completer<void>();
  Future<void> call(String sql) async {
    final marker = prefix;
    if (marker == null || !sql.startsWith(marker)) return;
    prefix = null;
    reached.complete();
    await release.future;
  }
}

void main() {
  late Directory dir;
  late LedgerRepository repo;
  late _ReadBarrier barrier;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jianzhang-read-');
    barrier = _ReadBarrier();
    repo = await SqliteLedgerRepository.connect(
      path: '${dir.path}/ledger.db',
      afterRead: barrier.call,
    );
  });
  tearDown(() async {
    if (barrier.reached.isCompleted && !barrier.release.isCompleted) {
      barrier.release.complete();
    }
    await repo.close();
    await deleteOwnedScratchDirectory(dir, 'jianzhang-read-');
  });
  Future<void> populate(String label, int amount) async {
    await repo.upsertAccount(
      Account(id: 'bank', name: label, openingBalance: 1000),
    );
    final category = (await repo.listCategories()).firstWhere(
      (c) => c.id == 'food-lunch',
    );
    await repo.upsertCategory(category.copyWith(name: label));
    await repo.updateSettings(
      (await repo.settings()).copyWith(
        defaultAccount: label == 'old' ? 'cash' : 'bank',
      ),
    );
    await repo.saveTransaction(
      entry('same', amount: amount, note: label),
      create: true,
    );
    await repo.upsertBudget(const Budget(month: '2026-10', amount: 1000));
  }

  Future<void> populateTwo() async {
    await populate('old', 100);
    await repo.switchWorkspace('user:other');
    await populate('new', 900);
    expect(
      (await repo.meta()).sequence,
      (await repo.workspaceMeta('guest')).sequence,
    );
    await repo.switchWorkspace('guest');
  }

  test(
    'queued page queries reject old scope after an equal-sequence switch',
    () async {
      await populateTwo();
      final old = await repo.meta();
      barrier.prefix = 'SELECT * FROM accounts WHERE ws=';
      final read = repo.readViewData(month: '2026-10');
      await barrier.reached.future;
      final change = repo.switchWorkspace('user:other');
      final assertions = Future.wait([
        expectLater(
          repo.search(
            const LedgerFilter(),
            expectedWorkspace: old.key,
            expectedSequence: old.sequence,
          ),
          throwsA(isA<LedgerConflict>()),
        ),
        expectLater(
          repo.statistics(
            start: '2026-10-01',
            end: '2026-10-31',
            expectedWorkspace: old.key,
            expectedSequence: old.sequence,
          ),
          throwsA(isA<LedgerConflict>()),
        ),
      ]);
      barrier.release.complete();
      expect((await read).meta.key, 'guest');
      await change;
      await assertions;
      final target = await repo.meta();
      final page = await repo.search(
        const LedgerFilter(),
        expectedWorkspace: target.key,
        expectedSequence: target.sequence,
      );
      expect(page.items.single.note, 'new');
      await expectLater(
        repo.statistics(
          start: '2026-10-01',
          end: '2026-10-31',
          expectedWorkspace: target.key,
          expectedSequence: target.sequence - 1,
        ),
        throwsA(isA<LedgerConflict>()),
      );
    },
  );

  test(
    'readViewData pins initial metadata and every field across equal-sequence switch',
    () async {
      await populateTwo();
      final old = await repo.meta();
      barrier.prefix = 'SELECT * FROM accounts WHERE ws=';
      final read = repo.readViewData(month: '2026-10');
      await barrier.reached.future;
      var switched = false;
      final change = repo.switchWorkspace('user:other').then((_) {
        switched = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(switched, false);
      barrier.release.complete();
      final view = await read;
      await change;
      expect(view.meta.key, old.key);
      expect(view.meta.sequence, old.sequence);
      expect(view.accounts.firstWhere((a) => a.id == 'bank').name, 'old');
      expect(
        view.categories.firstWhere((c) => c.id == 'food-lunch').name,
        'old',
      );
      expect(view.budgets.single.spent, 100);
      expect(view.balances['bank'], 900);
      expect(view.settings.defaultAccount, 'cash');
      expect(view.summary.expense, 100);
      expect(view.recent.total, 1);
      expect(view.recent.items.single.note, 'old');
      final current = await repo.readViewData(month: '2026-10');
      expect(current.meta.key, 'user:other');
      expect(current.summary.expense, 900);
      expect(
        current.categories.firstWhere((c) => c.id == 'food-lunch').name,
        'new',
      );
    },
  );

  test(
    'statistics summary, category totals and all buckets remain in the old workspace',
    () async {
      await populateTwo();
      barrier.prefix = 'SELECT COALESCE(SUM(';
      final read = repo.statistics(start: '2026-10-01', end: '2026-10-31');
      await barrier.reached.future;
      final change = repo.switchWorkspace('user:other');
      barrier.release.complete();
      final stats = await read;
      await change;
      expect(stats.summary.expense, 100);
      expect(stats.categories.single.amount, 100);
      expect(stats.subcategories.single.category.name, 'old');
      expect(stats.subcategories.single.amount, 100);
      expect(stats.trend.fold<int>(0, (sum, b) => sum + b.expense), 100);
    },
  );

  test(
    'search COUNT and items stay in one SQLite snapshot during external commit',
    () async {
      await populate('old', 100);
      final other = await LedgerRepository.open(path: '${dir.path}/ledger.db');
      try {
        barrier.prefix = 'SELECT COUNT(*) AS n FROM entries t';
        final read = repo.search(const LedgerFilter());
        await barrier.reached.future;
        // A distinct connection can commit in WAL mode while this read is paused.
        await other.saveTransaction(
          entry('external', amount: 900),
          create: true,
        );
        barrier.release.complete();
        final page = await read;
        expect(page.total, 1);
        expect(page.items.map((t) => t.id), ['same']);
        expect((await repo.search(const LedgerFilter())).total, 2);
      } finally {
        await other.close();
      }
    },
  );

  test(
    'view metadata and summary stay in one revision during external write',
    () async {
      await populate('old', 100);
      final before = await repo.meta();
      final other = await LedgerRepository.open(path: '${dir.path}/ledger.db');
      try {
        barrier.prefix = 'SELECT * FROM accounts WHERE ws=';
        final read = repo.readViewData(month: '2026-10');
        await barrier.reached.future;
        await other.saveTransaction(
          entry('external', amount: 900),
          create: true,
        );
        barrier.release.complete();
        final view = await read;
        expect(view.meta.sequence, before.sequence);
        expect(view.meta.transactionCount, 1);
        expect(view.summary.expense, 100);
        expect(view.budgets.single.spent, 100);
        expect(view.recent.total, 1);
        expect(view.recent.items.length, 1);
        expect(view.balances['bank'], 900);
        final after = await repo.readViewData(month: '2026-10');
        expect(after.meta.sequence, before.sequence + 1);
        expect(after.summary.expense, 1000);
        expect(after.recent.items.length, 2);
      } finally {
        await other.close();
      }
    },
  );

  test(
    'budget configuration and spending share a snapshot across external commit',
    () async {
      await populate('old', 100);
      final other = await LedgerRepository.open(path: '${dir.path}/ledger.db');
      try {
        barrier.prefix = 'SELECT * FROM budgets WHERE ws=';
        final read = repo.budgetStatuses('2026-10');
        await barrier.reached.future;
        await other.saveTransaction(
          entry('external', amount: 900),
          create: true,
        );
        barrier.release.complete();
        expect((await read).single.spent, 100);
        expect((await repo.budgetStatuses('2026-10')).single.spent, 1000);
      } finally {
        await other.close();
      }
    },
  );

  test(
    'snapshot scope validation rejects drift and nested budget reads do not deadlock',
    () async {
      await repo.upsertBudget(
        Budget(month: localDateTime().substring(0, 7), amount: 100),
      );
      final scope = await repo.meta();
      await repo
          .saveTransaction(
            entry('new', amount: 90).copyWith(date: localDateTime()),
            create: true,
            expectedWorkspace: scope.key,
            expectedSequence: scope.sequence,
          )
          .timeout(const Duration(seconds: 5));
      final fresh = await repo.meta();
      expect(
        (await repo.transactionById(
          'new',
          expectedWorkspace: fresh.key,
          expectedSequence: fresh.sequence,
        ))?.amount,
        90,
      );
      expect(await repo.transactionById('missing'), isNull);
      await expectLater(
        repo.readViewData(
          month: '2026-10',
          expectedWorkspace: scope.key,
          expectedSequence: scope.sequence,
        ),
        throwsA(isA<LedgerConflict>()),
      );
      await repo.switchWorkspace('user:other');
      await expectLater(
        repo.readViewData(month: '2026-10', expectedWorkspace: 'guest'),
        throwsA(isA<LedgerConflict>()),
      );
    },
  );
}
