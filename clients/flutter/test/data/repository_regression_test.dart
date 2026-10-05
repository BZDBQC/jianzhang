import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:jianzhang/data/sqlite_ledger_repository.dart';
import 'package:jianzhang/data/safe_files.dart';

LedgerTransaction entry(String id, {int amount = 10, String note = ''}) =>
    LedgerTransaction(
      id: id,
      type: EntryType.expense,
      amount: amount,
      date: '2026-10-04T12:30',
      createdAt: '2026-10-04T12:30',
      accountId: 'bank',
      categoryId: 'food-lunch',
      note: note,
    );
Future<Map<String, Object?>> fixture() => File(
  '../../tests/fixtures/native-ledger-v1.json',
).readAsString().then((s) => jsonObject(jsonDecode(s)));
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
  test(
    'invalid and duplicate imports leave book, revision and backups untouched',
    () async {
      await repo.saveTransaction(entry('original'), create: true);
      final before = await repo.meta(), sum = (await repo.summary()).toJson();
      for (final mode in [
        'reference',
        'duplicate',
        'missingParent',
        'fee',
        'date',
      ]) {
        final data = await fixture();
        final rows = data['transactions'] as List;
        switch (mode) {
          case 'reference':
            (rows.first as Map)['accountId'] = 'missing';
          case 'duplicate':
            rows.add(rows.first);
          case 'missingParent':
            (data['categories'] as List).first.remove('parentId');
          case 'fee':
            (rows[2] as Map)['categoryId'] = '';
          case 'date':
            (rows.first as Map)['date'] = '2026-02-30T12:30';
        }
        await expectLater(
          repo.previewJson(jsonEncode(data)),
          throwsA(isA<LedgerException>()),
        );
        expect((await repo.meta()).sequence, before.sequence);
        expect((await repo.summary()).toJson(), sum);
        expect(await repo.listBackups(), isEmpty);
      }
    },
  );
  test(
    'Unicode folding and percent/underscore are literal search terms',
    () async {
      await repo.saveTransaction(
        entry('unicode', note: 'ÉCOLE Σ 中文 % _'),
        create: true,
      );
      for (final term in ['école', 'σ', '%', '_']) {
        expect((await repo.search(LedgerFilter(note: term))).total, 1);
      }
      expect((await repo.search(const LedgerFilter(note: '%不存在'))).total, 0);
    },
  );
  test(
    'fees participate in budgets and category rankings, migration retains fee',
    () async {
      await repo.importAtomic(
        await repo.previewImport('../../tests/fixtures/native-ledger-v1.json'),
      );
      final budgets = await repo.budgetStatuses('2026-10');
      expect(budgets.map((s) => s.spent), [4878, 234]);
      final stats = await repo.statistics(
        start: '2026-10-01',
        end: '2026-10-31',
      );
      expect(stats.categories.fold<int>(0, (n, c) => n + c.amount), 4878);
      expect(
        stats.subcategories
            .firstWhere((c) => c.category.id == 'other-fee')
            .amount,
        234,
      );
      await repo.deleteCategory('other', reassignTo: 'shopping-daily');
      expect(
        (await repo.search(
          const LedgerFilter(
            types: [EntryType.expense],
            includeFees: true,
            amountOp: 'eq',
            amountMin: '2.34',
          ),
        )).total,
        1,
      );
      expect((await repo.listBudgets()).length, 1);
    },
  );
  test(
    'workspace restart and late upload acknowledgement preserve newer edits',
    () async {
      await repo.switchWorkspace('user:alice');
      final initial = await repo.meta();
      await repo.saveTransaction(entry('local-new'), create: true);
      await repo.switchWorkspace('guest');
      await repo.setCloudRevision(
        4,
        workspace: 'user:alice',
        expectedSequence: initial.sequence,
      );
      expect((await repo.workspaceMeta('user:alice')).dirty, true);
      expect((await repo.meta()).key, 'guest');
      await repo.switchWorkspace('user:alice');
      await repo.close();
      repo = await LedgerRepository.open(path: '${dir.path}/ledger.db');
      expect((await repo.meta()).key, 'user:alice');
      expect((await repo.search(const LedgerFilter())).total, 1);
      expect((await repo.workspaceMeta('guest')).transactionCount, 0);
    },
  );
  test(
    'post-write failure rolls back saved bill and complete import',
    () async {
      await repo.close();
      String? failPhase;
      repo = await SqliteLedgerRepository.connect(
        path: '${dir.path}/ledger.db',
        beforeCommit: (phase) async {
          if (phase == failPhase) throw const LedgerException('模拟磁盘写入失败');
        },
      );
      final events = <int>[];
      final subscription = repo.changes.listen(events.add);
      failPhase = 'save';
      await expectLater(
        repo.saveTransaction(entry('failed'), create: true),
        throwsA(isA<LedgerException>()),
      );
      expect((await repo.meta()).sequence, 0);
      expect((await repo.search(const LedgerFilter())).total, 0);
      expect(events, isEmpty);
      failPhase = 'import';
      final preview = await repo.previewImport(
        '../../tests/fixtures/native-ledger-v1.json',
      );
      await expectLater(
        repo.importAtomic(preview),
        throwsA(isA<LedgerException>()),
      );
      expect((await repo.meta()).sequence, 0);
      expect((await repo.search(const LedgerFilter())).total, 0);
      expect(await repo.listBackups(), isEmpty);
      expect(events, isEmpty);
      await subscription.cancel();
    },
  );
  test(
    'cross-workspace failure keeps active pointer and database after reopening',
    () async {
      await repo.close();
      repo = await SqliteLedgerRepository.connect(
        path: '${dir.path}/ledger.db',
        beforeCommit: (phase) async {
          if (phase == 'replace') throw const LedgerException('模拟提交前中断');
        },
      );
      final events = <int>[];
      final subscription = repo.changes.listen(events.add);
      await expectLater(
        repo.replaceSnapshot(
          await fixture(),
          workspace: 'user:new',
          cloudRevision: 3,
          expectedSequence: 0,
        ),
        throwsA(isA<LedgerException>()),
      );
      expect((await repo.meta()).key, 'guest');
      expect((await repo.listWorkspaces()).map((m) => m.key), ['guest']);
      expect(events, isEmpty);
      expect(await repo.listBackups(), isEmpty);
      await subscription.cancel();
      await repo.close();
      repo = await LedgerRepository.open(path: '${dir.path}/ledger.db');
      expect((await repo.meta()).key, 'guest');
      expect((await repo.summary()).count, 0);
    },
  );
  test(
    'SQLite actual page quota failure rolls back partial transaction',
    () async {
      final sql = repo as SqliteLedgerRepository;
      final pages = await sql.pageCountForTesting();
      await sql.setPageLimitForTesting(pages);
      await expectLater(
        repo.saveTransaction(
          entry('full', note: List.filled(2000, '汉').join()),
          create: true,
        ),
        throwsA(anything),
      );
      expect((await repo.search(const LedgerFilter())).total, 0);
      expect((await repo.meta()).sequence, 0);
      await sql.setPageLimitForTesting(1000000);
      await repo.saveTransaction(entry('retry'), create: true);
      expect((await repo.search(const LedgerFilter())).total, 1);
    },
  );
  test(
    'CSV formula safety and XLSX numeric cells preserve original Unicode remarks',
    () async {
      await repo.saveTransaction(
        entry('export', amount: 1234, note: '=1+1,中文🙂\n"引号"'),
        create: true,
      );
      final csv = File('${dir.path}/ledger.csv'),
          xlsx = File('${dir.path}/ledger.xlsx');
      await repo.exportFile(csv.path, format: ExportFormat.csv);
      expect(await csv.readAsString(), contains("'=1+1"));
      await repo.exportFile(xlsx.path, format: ExportFormat.xlsx);
      final archive = ZipDecoder().decodeBytes(await xlsx.readAsBytes());
      final sheet = archive.findFile('xl/worksheets/sheet1.xml');
      expect(sheet, isNotNull);
      final xml = utf8.decode(sheet!.content as List<int>);
      expect(xml, contains('<v>12.34</v>'));
      expect(xml, contains('=1+1,中文🙂'));
      expect(xml, isNot(contains("'=1+1")));
    },
  );
  test(
    'external cloud backups do not change local bills and retain last ten',
    () async {
      await repo.saveTransaction(entry('mine'), create: true);
      final before = await repo.meta();
      for (var i = 0; i < 12; i++) {
        await repo.backupSnapshot(await fixture(), label: '云端 $i');
      }
      expect((await repo.meta()).sequence, before.sequence);
      expect((await repo.summary()).count, 1);
      expect((await repo.listBackups()).length, 10);
    },
  );
  test(
    '100k restore and streaming exports retain int64 totals without blocking event loop',
    () async {
      final data = await fixture();
      data['budgets'] = [];
      (data['settings'] as Map)['notifications'] = false;
      data.remove('transactions');
      final base = jsonEncode(data);
      final input = File('${dir.path}/100k.json'), sink = input.openWrite();
      sink.write('${base.substring(0, base.length - 1)},"transactions":[');
      for (var i = 0; i < 100000; i++) {
        if (i > 0) sink.write(',');
        sink.write(
          jsonEncode(
            entry(
              'row-${i.toString().padLeft(6, '0')}',
              amount: maxMoney,
              note: '中文🙂 % _',
            ).toJson(),
          ),
        );
        if (i % 500 == 0) await sink.flush();
      }
      sink.write(']}');
      await sink.close();
      var ticks = 0, last = DateTime.now().millisecondsSinceEpoch, maxGap = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final gap = now - last;
        if (gap > maxGap) maxGap = gap;
        last = now;
        ticks++;
      });
      final clock = Stopwatch()..start();
      try {
        final preview = await repo.previewImport(input.path);
        expect(preview.transactionCount, 100000);
        await repo.importAtomic(preview);
        expect((await repo.summary()).expense, maxMoney * 100000);
        final saveMs = <int>[], queryMs = <int>[];
        for (var i = 0; i < 20; i++) {
          final save = Stopwatch()..start();
          await repo.saveTransaction(
            entry('row-000000', amount: maxMoney, note: '修改 $i'),
          );
          saveMs.add(save.elapsedMilliseconds);
          final query = Stopwatch()..start();
          expect(
            (await repo.search(const LedgerFilter(note: '中文'))).items.length,
            50,
          );
          queryMs.add(query.elapsedMilliseconds);
        }
        saveMs.sort();
        queryMs.sort();
        final json = File('${dir.path}/export.json'),
            csv = File('${dir.path}/export.csv'),
            xlsx = File('${dir.path}/export.xlsx');
        await repo.exportFile(json.path);
        await repo.exportFile(csv.path, format: ExportFormat.csv);
        await repo.exportFile(xlsx.path, format: ExportFormat.xlsx);
        expect(await xlsx.length(), greaterThan(10000000));
        await repo.close();
        repo = await LedgerRepository.open(path: '${dir.path}/ledger.db');
        expect((await repo.meta()).transactionCount, 100000);
        await repo.importAtomic(await repo.previewImport(json.path));
        expect((await repo.summary()).expense, maxMoney * 100000);
        await expectLater(
          repo.cloudSnapshot(),
          throwsA(isA<LedgerException>()),
        );
        expect(ticks, greaterThan(100));
        expect(maxGap, lessThan(1000));
        stdout.writeln(
          '100k: totalMs=${clock.elapsedMilliseconds} saveP95Ms=${saveMs[18]} queryP95Ms=${queryMs[18]} maxTimerGapMs=$maxGap ticks=$ticks',
        );
      } finally {
        timer.cancel();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
