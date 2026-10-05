import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:jianzhang/data/safe_files.dart';
import 'package:jianzhang/data/sqlite_ledger_repository.dart';
import 'package:sqlite3/sqlite3.dart';

import 'repository_regression_test.dart' show entry;

void main() {
  late Directory directory;
  late SqliteLedgerRepository repository;
  late Database audit;
  final reads = <String>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('jianzhang-sql-cost-');
    final path = '${directory.path}/ledger.db';
    repository = await SqliteLedgerRepository.connect(
      path: path,
      afterRead: (sql) async => reads.add(sql),
    );
    audit = sqlite3.open(path);
    audit.execute('CREATE TABLE qa_settings_updates(n INTEGER NOT NULL)');
    audit.execute('INSERT INTO qa_settings_updates VALUES(0)');
    // afterRead observes returned rows. This fixture-owned trigger also observes
    // no-op settings UPDATEs, and its counter rolls back with the mutation.
    audit.execute('''
      CREATE TRIGGER qa_settings_update AFTER UPDATE OF settings ON workspaces
      WHEN NEW.key='guest'
      BEGIN UPDATE qa_settings_updates SET n=n+1; END
    ''');
    reads.clear();
  });

  tearDown(() async {
    audit.close();
    await repository.close();
    await deleteOwnedScratchDirectory(directory, 'jianzhang-sql-cost-');
  });

  int settingsUpdates() =>
      audit.select('SELECT n FROM qa_settings_updates').single['n'] as int;

  void seedSettings(LedgerSettings settings) {
    audit.execute('UPDATE workspaces SET settings=? WHERE key=?', [
      jsonEncode(settings.toJson()),
      'guest',
    ]);
    audit.execute('UPDATE qa_settings_updates SET n=0');
    reads.clear();
  }

  Iterable<String> metadataCounts() => reads.where(
    (sql) => sql.contains('SELECT COUNT(*) FROM entries e WHERE e.ws=w.key'),
  );

  test(
    'revision increment returns its value without another SQL read',
    () async {
      await repository.saveTransaction(entry('returning'), create: true);
      expect(
        reads.where((sql) => sql.endsWith('RETURNING sequence')),
        hasLength(1),
      );
      expect(
        reads.where(
          (sql) => sql == 'SELECT sequence FROM workspaces WHERE key=?',
        ),
        isEmpty,
      );
      expect((await repository.meta()).sequence, 1);
    },
  );

  test(
    'save acknowledgement does not read after the database commit',
    () async {
      final before = await repository.meta();
      await repository.close();
      repository = await SqliteLedgerRepository.connect(
        path: '${directory.path}/ledger.db',
        afterRead: (sql) async {
          if (sql.endsWith('RETURNING sequence') &&
              (audit
                          .select(
                            "SELECT sequence FROM workspaces WHERE key='guest'",
                          )
                          .single['sequence']
                      as int) >
                  before.sequence) {
            throw StateError('Injected read failure after committed save');
          }
        },
      );
      await repository.saveTransaction(entry('acknowledged'), create: true);
      expect(
        audit.select("SELECT id FROM entries WHERE id='acknowledged'"),
        hasLength(1),
      );
    },
  );

  test('revision read failure rolls back the bill and sequence', () async {
    final before = await repository.meta();
    await repository.close();
    repository = await SqliteLedgerRepository.connect(
      path: '${directory.path}/ledger.db',
      afterRead: (sql) async {
        if (sql.endsWith('RETURNING sequence')) {
          throw StateError('Injected revision read failure');
        }
      },
    );
    final revisions = <int>[];
    final subscription = repository.changes.listen(revisions.add);
    await expectLater(
      repository.saveTransaction(entry('rolled-back'), create: true),
      throwsStateError,
    );
    expect(
      audit.select("SELECT id FROM entries WHERE id='rolled-back'"),
      isEmpty,
    );
    expect(
      audit
          .select("SELECT sequence FROM workspaces WHERE key='guest'")
          .single['sequence'],
      before.sequence,
    );
    await Future<void>.delayed(Duration.zero);
    expect(revisions, isEmpty);
    await subscription.cancel();
  });

  test(
    'CAS edit reads only sequence and emits its committed revision',
    () async {
      await repository.saveTransaction(entry('one'), create: true);
      final before = await repository.meta();
      final revisions = <int>[];
      final subscription = repository.changes.listen(revisions.add);
      reads.clear();
      await repository.saveTransaction(
        entry('one', amount: 25),
        expectedWorkspace: before.key,
        expectedSequence: before.sequence,
      );
      await Future<void>.delayed(Duration.zero);
      expect(metadataCounts(), isEmpty);
      expect(
        reads.where(
          (sql) => sql == 'SELECT sequence FROM workspaces WHERE key=?',
        ),
        hasLength(1),
      );
      expect(revisions, [before.sequence + 1]);
      expect(settingsUpdates(), 0);
      expect((await repository.meta()).transactionCount, 1);
      expect((await repository.transactionById('one'))?.amount, 25);
      await subscription.cancel();
    },
  );

  test(
    'create retains its count guard and rejects the 100001st bill',
    () async {
      await repository.saveTransaction(entry('one'), create: true);
      expect(metadataCounts(), hasLength(1));
      audit.execute('''
      WITH RECURSIVE numbers(n) AS (
        SELECT 1 UNION ALL SELECT n+1 FROM numbers WHERE n<99999
      )
      INSERT INTO entries(
        ws,id,type,amount,fee,date,account_id,to_account_id,category_id,
        note,note_fold,created_at,position
      )
      SELECT 'guest','seed-'||n,'expense',10,0,'2026-10-04T12:30',
        'bank','','food-lunch','','','2026-10-04T12:30',n FROM numbers
    ''');
      final before = await repository.meta();
      expect(before.transactionCount, localTransactionLimit);
      reads.clear();
      await expectLater(
        repository.saveTransaction(
          entry('overflow'),
          create: true,
          expectedWorkspace: before.key,
          expectedSequence: before.sequence,
        ),
        throwsA(isA<LedgerException>()),
      );
      expect(metadataCounts(), hasLength(1));
      expect((await repository.meta()).sequence, before.sequence);
      expect((await repository.meta()).transactionCount, localTransactionLimit);
      expect(await repository.transactionById('overflow'), isNull);
    },
  );

  test(
    'search and summary retain shared filters with only required joins',
    () async {
      final golden = jsonObject(
        jsonDecode(
          await File(
            '../../tests/fixtures/native-domain-v1.json',
          ).readAsString(),
        ),
      );
      await repository.importAtomic(
        await repository.previewImport(
          '../../tests/fixtures/native-ledger-v1.json',
        ),
      );
      final ledger = jsonObject(golden['ledger']);
      final entries = (ledger['transactions'] as List)
          .map(LedgerTransaction.fromJson)
          .toList();
      final cases = [
        ...(golden['filters'] as List).map(jsonObject),
        {
          'filter': {
            'subIds': ['other-fee'],
          },
          'ids': ['transfer'],
        },
        {
          'filter': {
            'categoryIds': ['food'],
          },
          'ids': ['expense', 'edge'],
        },
      ];
      for (final sample in cases) {
        final filter = LedgerFilter.fromJson(jsonObject(sample['filter']));
        final expectedIds = (sample['ids'] as List).cast<String>();
        reads.clear();
        final page = await repository.search(filter);
        final summary = await repository.summary(filter: filter);
        expect(page.items.map((row) => row.id), unorderedEquals(expectedIds));
        expect(page.total, expectedIds.length);
        final selected = entries.where((row) => expectedIds.contains(row.id));
        expect(summary.count, expectedIds.length);
        expect(
          summary.income,
          selected
              .where((row) => row.type == EntryType.income)
              .fold<int>(0, (sum, row) => sum + row.amount),
        );
        expect(
          summary.expense,
          selected.fold<int>(
            0,
            (sum, row) =>
                sum +
                switch (row.type) {
                  EntryType.expense => row.amount,
                  EntryType.transfer => row.fee,
                  EntryType.income => 0,
                },
          ),
        );
        final entryQueries = reads.where(
          (sql) => sql.contains('FROM entries t'),
        );
        expect(entryQueries, hasLength(3));
        for (final sql in entryQueries) {
          expect(
            sql.contains('JOIN categories'),
            filter.categoryIds.isNotEmpty,
            reason: 'Only parent-category filters require categories: $filter',
          );
        }
      }
    },
  );

  test(
    'no current budget skips category names and unchanged settings writes',
    () async {
      final nextMonth = DateTime.now();
      await repository.upsertBudget(
        Budget(
          month: localDateTime(
            DateTime(nextMonth.year, nextMonth.month + 1),
          ).substring(0, 7),
          amount: 100,
        ),
      );
      audit.execute('UPDATE qa_settings_updates SET n=0');
      reads.clear();
      await repository.saveTransaction(entry('one'), create: true);
      expect(
        reads.where(
          (sql) => sql.startsWith('SELECT * FROM categories WHERE ws='),
        ),
        hasLength(1), // Required reference validation remains.
      );
      expect(
        reads.where((sql) => sql.startsWith('SELECT COALESCE(SUM(')),
        isEmpty,
      );
      expect(settingsUpdates(), 0);
    },
  );

  test(
    'no current budget still normalizes duplicate old notification keys',
    () async {
      final settings = await repository.settings();
      seedSettings(settings.copyWith(notified: ['old', 'old', 'later']));
      await repository.saveTransaction(entry('one'), create: true);
      expect(settingsUpdates(), 1);
      expect((await repository.settings()).notified, ['old', 'later']);
      audit.execute('UPDATE qa_settings_updates SET n=0');
      await repository.saveTransaction(entry('one', amount: 20));
      expect(settingsUpdates(), 0);
    },
  );

  test(
    'current budget without a new threshold does not rewrite settings',
    () async {
      final month = localDateTime().substring(0, 7);
      await repository.upsertBudget(
        Budget(month: month, amount: 100, threshold: 100),
      );
      final notices = <String>[];
      final subscription = repository.budgetNotifications.listen(notices.add);
      await repository.saveTransaction(
        entry('one', amount: 100).copyWith(date: localDateTime()),
        create: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(notices, hasLength(1)); // threshold=100 must emit once.
      expect((await repository.settings()).notified, ['$month::100:100']);
      audit.execute('UPDATE qa_settings_updates SET n=0');
      await repository.saveTransaction(
        entry('one', amount: 110).copyWith(date: localDateTime()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(settingsUpdates(), 0);
      expect(notices, hasLength(1));
      await subscription.cancel();
    },
  );

  test('new threshold keys trim the oldest flags to the last 2000', () async {
    final month = localDateTime().substring(0, 7);
    await repository.upsertBudget(
      Budget(month: month, amount: 100, threshold: 80),
    );
    final oldFlags = List.generate(2000, (index) => 'legacy-$index');
    seedSettings((await repository.settings()).copyWith(notified: oldFlags));
    await repository.saveTransaction(
      entry('one', amount: 100).copyWith(date: localDateTime()),
      create: true,
    );
    expect(settingsUpdates(), 1);
    expect((await repository.settings()).notified, [
      ...oldFlags.skip(2),
      '$month::100:80',
      '$month::100:100',
    ]);
  });

  test('disabled notifications preserve flags and skip budget work', () async {
    seedSettings(
      (await repository.settings()).copyWith(
        notifications: false,
        notified: ['old', 'old'],
      ),
    );
    await repository.saveTransaction(entry('one'), create: true);
    expect(settingsUpdates(), 0);
    expect(
      reads.where((sql) => sql.startsWith('SELECT * FROM budgets WHERE ws=')),
      isEmpty,
    );
    expect((await repository.settings()).notified, ['old', 'old']);
  });
}
