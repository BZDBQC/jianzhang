import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:jianzhang/data/safe_files.dart';

void main() {
  late Directory dir;
  late LedgerRepository repo;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jianzhang-test-');
    repo = await LedgerRepository.open(path: '${dir.path}/ledger.db');
  });
  tearDown(() async {
    await repo.close();
    await deleteOwnedScratchDirectory(dir, 'jianzhang-test-');
  });
  test('new book has defaults and no sample bills', () async {
    expect((await repo.search(const LedgerFilter())).total, 0);
    expect((await repo.listAccounts()).length, 3);
  });
  test(
    'atomic import, SQL filters, export and rollback retain web contract',
    () async {
      final fixture = jsonObject(
        jsonDecode(
          await File(
            '../../tests/fixtures/native-domain-v1.json',
          ).readAsString(),
        ),
      );
      final preview = await repo.previewImport(
        '../../tests/fixtures/native-ledger-v1.json',
      );
      await repo.importAtomic(preview);
      expect((await repo.summary()).toJson(), fixture['summary']);
      expect(await repo.balances(), fixture['balances']);
      for (final row in fixture['filters'] as List) {
        final filter = jsonObject(row);
        final page = await repo.search(
          LedgerFilter.fromJson(jsonObject(filter['filter'])),
        );
        expect(
          page.items.map((t) => t.id).toList()..sort(),
          (filter['ids'] as List).cast<String>()..sort(),
        );
      }
      final before = (await repo.meta()).sequence;
      await expectLater(
        repo.previewJson('{"version":1}'),
        throwsA(isA<LedgerException>()),
      );
      expect((await repo.meta()).sequence, before);
      expect((await repo.search(const LedgerFilter())).total, 6);
      expect((await repo.listBackups()).length, 1);
      final output = '${dir.path}/roundtrip.json';
      await repo.exportFile(output);
      final parsed = jsonObject(jsonDecode(await File(output).readAsString()));
      expect((parsed['transactions'] as List).length, 6);
    },
  );
  test('local CAS rejects a stale edit without creating a record', () async {
    final m = await repo.meta();
    final t = LedgerTransaction(
      id: 'one',
      type: EntryType.expense,
      amount: 10,
      date: '2026-10-04T12:30',
      createdAt: '2026-10-04T12:30',
      accountId: 'bank',
      categoryId: 'food-lunch',
    );
    await repo.saveTransaction(t, create: true, expectedSequence: m.sequence);
    await expectLater(
      repo.saveTransaction(
        t.copyWith(amount: 20),
        expectedSequence: m.sequence,
      ),
      throwsA(isA<LedgerConflict>()),
    );
    expect((await repo.summary()).expense, 10);
  });
}
