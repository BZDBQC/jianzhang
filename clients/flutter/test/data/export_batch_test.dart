import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:jianzhang/data/safe_files.dart';
import 'package:jianzhang/data/sqlite_ledger_repository.dart';

const _goldenDirectory = 'test/fixtures/export_batch';

List<LedgerTransaction> _entries(int count) => List.generate(count, (i) {
  final type = EntryType.values[i % EntryType.values.length];
  return LedgerTransaction(
    id: 'row-${i.toString().padLeft(4, '0')}',
    type: type,
    amount: 1234 + i,
    fee: type == EntryType.transfer ? 37 : 0,
    date: '2026-10-${(i % 7 + 1).toString().padLeft(2, '0')}T12:30',
    createdAt: '2026-10-04T12:30',
    accountId: 'bank',
    toAccountId: type == EntryType.transfer ? 'cash' : '',
    categoryId: switch (type) {
      EntryType.expense => 'food-lunch',
      EntryType.income => 'salary-main',
      EntryType.transfer => 'other-fee',
    },
    note: ' =1+1,保留中文🙂𞤀\n"引号" <>& \r\t\u0001 行$i',
  );
});

List<LedgerTransaction> _dateOrder(List<LedgerTransaction> entries) {
  final positions = {for (var i = 0; i < entries.length; i++) entries[i].id: i};
  return [...entries]..sort((a, b) {
    final dates = b.date.compareTo(a.date);
    return dates != 0 ? dates : positions[a.id]!.compareTo(positions[b.id]!);
  });
}

Future<List<int>> _golden(String name) async =>
    gzip.decode(await File('$_goldenDirectory/$name.gz').readAsBytes());

void main() {
  late Directory dir;
  late LedgerRepository repo;
  late Map<String, Object?> emptySnapshot;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jianzhang-export-batch-');
    repo = await LedgerRepository.open(path: '${dir.path}/ledger.db');
    emptySnapshot = await repo.cloudSnapshot();
  });
  tearDown(() async {
    await repo.close();
    await deleteOwnedScratchDirectory(dir, 'jianzhang-export-batch-');
  });

  Map<String, Object?> snapshot(List<LedgerTransaction> entries) => {
    ...emptySnapshot,
    'transactions': entries.map((entry) => entry.toJson()).toList(),
  };

  Future<void> seed(List<LedgerTransaction> entries) async {
    await repo.importAtomic(
      await repo.previewJson(jsonEncode(snapshot(entries))),
    );
  }

  Future<Map<String, List<int>>> backupBytes() async => {
    for (final backup in await repo.listBackups())
      backup.path: await File(backup.path).readAsBytes(),
  };

  Future<void> checkGolden(String name, List<int> bytes) async {
    expect(bytes, orderedEquals(await _golden(name)), reason: name);
  }

  Future<void> checkFormats(int count, {bool filtered = false}) async {
    final entries = _entries(count);
    await seed(entries);
    final sorted = _dateOrder(entries);
    final filter = filtered
        ? const LedgerFilter(note: '保留')
        : const LedgerFilter();
    for (final format in ExportFormat.values) {
      final file = File('${dir.path}/export.${format.name}');
      await repo.exportFile(file.path, format: format, filter: filter);
      final bytes = await file.readAsBytes();
      await checkGolden(
        '$count-${filtered ? 'filtered-' : ''}${format.name}',
        bytes,
      );
      switch (format) {
        case ExportFormat.json:
          final data = jsonObject(jsonDecode(utf8.decode(bytes)));
          expect(
            (data['transactions'] as List).map((row) => (row as Map)['id']),
            (filtered ? sorted : entries).map((entry) => entry.id),
          );
          expect(
            bytes,
            orderedEquals(
              utf8.encode(jsonEncode(snapshot(filtered ? sorted : entries))),
            ),
          );
          final preview = await repo.previewImport(file.path);
          expect(preview.transactionCount, count);
          await repo.discardImport(preview);
        case ExportFormat.csv:
          final csv = utf8.decode(bytes);
          expect(bytes.take(3), [0xef, 0xbb, 0xbf]);
          expect(csv.endsWith('\r\n'), isFalse);
          if (count > 0) {
            expect(csv, contains('"\' =1+1,保留中文🙂𞤀'));
            expect(csv, contains('""引号""'));
          }
        case ExportFormat.xlsx:
          final archive = ZipDecoder().decodeBytes(bytes);
          final sheet = archive.findFile('xl/worksheets/sheet1.xml')!;
          final xml = utf8.decode(sheet.content as List<int>);
          expect(xml, contains('<autoFilter ref="A1:I${count + 1}"/>'));
          expect(RegExp('<row r=').allMatches(xml).length, count + 1);
          if (count > 0) {
            expect(xml, contains(' =1+1,保留中文🙂𞤀'));
            expect(xml, contains('&quot;引号&quot; &lt;&gt;&amp;'));
            expect(xml, isNot(contains('\u0001')));
            expect(xml, contains('s="1"><v>12.34</v>'));
          }
      }
    }
  }

  for (final count in [0, 1, 499, 500, 501, 1000]) {
    test('all formats retain exact legacy bytes for $count rows', () async {
      await checkFormats(count);
    });
  }
  test(
    'filtered formats retain exact date order across batch boundaries',
    () async {
      await checkFormats(1000, filtered: true);
    },
  );

  for (final format in ExportFormat.values) {
    test(
      '${format.name} second-page failure keeps destination and existing backups',
      () async {
        final entries = _entries(1000);
        await seed(entries);
        await seed(entries);
        final before = await repo.meta(), balances = await repo.balances();
        final backups = await backupBytes();
        await repo.close();
        final error = LedgerException(
          'Injected ${format.name} second-page failure',
        );
        var fail = true, pages = 0;
        repo = await SqliteLedgerRepository.connect(
          path: '${dir.path}/ledger.db',
          afterRead: (sql) async {
            if ((sql.startsWith('SELECT * FROM entries ') ||
                    sql.startsWith('SELECT t.* ')) &&
                fail &&
                ++pages == 2) {
              throw error;
            }
          },
        );
        final file = File('${dir.path}/existing.${format.name}');
        final original = utf8.encode('此前完整文件，不能发布半份导出🙂');
        await file.writeAsBytes(original);
        await expectLater(
          repo.exportFile(file.path, format: format),
          throwsA(same(error)),
        );
        expect(pages, 2);
        expect(await file.readAsBytes(), orderedEquals(original));
        expect(
          await dir.list().where((f) => f.path.endsWith('.tmp')).length,
          0,
        );
        expect((await repo.meta()).sequence, before.sequence);
        expect((await repo.meta()).transactionCount, before.transactionCount);
        expect(await repo.balances(), balances);
        expect(await backupBytes(), backups);
        fail = false;
        await repo.exportFile(file.path, format: format);
        expect(
          await file.readAsBytes(),
          orderedEquals(await _golden('1000-${format.name}')),
        );
      },
    );
  }

  test(
    'failed batched pre-import backup leaves earlier backups intact and retries completely',
    () async {
      final entries = _entries(1000);
      await seed(entries);
      await seed(entries);
      final before = await repo.meta(), balances = await repo.balances();
      final backups = await backupBytes();
      await repo.close();
      final error = LedgerException('Injected second-page backup failure');
      var fail = true, pages = 0;
      repo = await SqliteLedgerRepository.connect(
        path: '${dir.path}/ledger.db',
        afterRead: (sql) async {
          if (sql.startsWith('SELECT * FROM entries ') &&
              fail &&
              ++pages == 2) {
            throw error;
          }
        },
      );
      final preview = await repo.previewJson(jsonEncode(snapshot(_entries(1))));
      await expectLater(
        repo.importAtomic(preview, label: '批次恢复前备份'),
        throwsA(same(error)),
      );
      expect(pages, 2);
      expect((await repo.meta()).sequence, before.sequence);
      expect((await repo.meta()).transactionCount, before.transactionCount);
      expect(await repo.balances(), balances);
      expect(await backupBytes(), backups);
      expect(
        await Directory('${dir.path}/backups').list().length,
        backups.length,
      );
      fail = false;
      await repo.importAtomic(preview, label: '批次恢复前备份');
      final backup = (await repo.listBackups()).singleWhere(
        (backup) => backup.label == '批次恢复前备份',
      );
      expect(
        await File(backup.path).readAsBytes(),
        orderedEquals(await _golden('1000-json')),
      );
      expect((await repo.meta()).transactionCount, 1);
    },
  );
}
