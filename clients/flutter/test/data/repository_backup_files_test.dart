import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails;
import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:jianzhang/data/safe_files.dart';
import 'package:jianzhang/data/sqlite_ledger_repository.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'repository_regression_test.dart' show entry, fixture;

void main() {
  late Directory dir;
  late LedgerRepository repo;
  String getPath() => p.join(dir.path, 'ledger.db');
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jianzhang-backup-');
    repo = await LedgerRepository.open(path: getPath());
    await repo.saveTransaction(entry('original'), create: true);
  });
  tearDown(() async {
    await repo.close();
    await deleteOwnedScratchDirectory(dir, 'jianzhang-backup-');
  });
  String key(String path) {
    final value = p.normalize(File(path).absolute.path);
    return Platform.isWindows ? value.toLowerCase() : value;
  }

  Future<Set<String>> files() async {
    final directory = Directory(p.join(dir.path, 'backups'));
    if (!await directory.exists()) return {};
    final result = <String>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File &&
          RegExp(
            r'^[0-9a-f-]{36}\.json$',
            caseSensitive: false,
          ).hasMatch(p.basename(entity.path))) {
        result.add(key(entity.path));
      }
    }
    return result;
  }

  Future<void> assertPhysicalMatchesMetadata() async {
    final metadata = (await repo.listBackups()).map((b) => key(b.path)).toSet();
    expect(await files(), metadata);
  }

  Future<void> seedTen() async {
    final cloud = await fixture();
    for (var i = 0; i < 10; i++) {
      await repo.backupSnapshot(cloud, label: 'cloud-$i');
    }
    await assertPhysicalMatchesMetadata();
  }

  test(
    'repeated failed imports remove only their files; success retains ten physical backups',
    () async {
      await seedTen();
      final before = await files(), beforeMeta = await repo.meta();
      await repo.close();
      var fail = true;
      repo = await SqliteLedgerRepository.connect(
        path: getPath(),
        beforeCommit: (phase) async {
          if (fail && phase == 'import') {
            throw const LedgerException('Injected storage failure');
          }
        },
      );
      final preview = await repo.previewJson(jsonEncode(await fixture()));
      for (var i = 0; i < 12; i++) {
        await expectLater(
          repo.importAtomic(preview),
          throwsA(isA<LedgerException>()),
        );
        expect(await files(), before);
        await assertPhysicalMatchesMetadata();
        expect((await repo.meta()).sequence, beforeMeta.sequence);
      }
      fail = false;
      await repo.importAtomic(preview);
      expect((await repo.summary()).count, 6);
      expect((await files()).length, 10);
      await assertPhysicalMatchesMetadata();
    },
  );

  test(
    'failed source/target replace removes both new files and preserves all previous backups',
    () async {
      await seedTen();
      await repo.switchWorkspace('user:target');
      await repo.saveTransaction(entry('target'), create: true);
      final target = await repo.meta();
      await repo.switchWorkspace('guest');
      final source = await repo.meta(), before = await files();
      await repo.close();
      repo = await SqliteLedgerRepository.connect(
        path: getPath(),
        beforeCommit: (phase) async {
          if (phase == 'replace') {
            throw const LedgerException('Injected storage failure');
          }
        },
      );
      for (var i = 0; i < 3; i++) {
        await expectLater(
          repo.replaceSnapshot(
            await fixture(),
            workspace: target.key,
            expectedSourceWorkspace: source.key,
            expectedSequence: source.sequence,
            expectedTargetSequence: target.sequence,
          ),
          throwsA(isA<LedgerException>()),
        );
        expect(await files(), before);
        expect((await repo.meta()).key, source.key);
        expect((await repo.workspaceMeta(target.key)).transactionCount, 1);
        await assertPhysicalMatchesMetadata();
      }
      // The source file already exists when this target CAS guard rejects.
      await expectLater(
        repo.replaceSnapshot(
          await fixture(),
          workspace: target.key,
          expectedSourceWorkspace: source.key,
          expectedSequence: source.sequence,
          expectedTargetSequence: 0,
        ),
        throwsA(isA<LedgerConflict>()),
      );
      expect(await files(), before);
    },
  );

  test(
    'external snapshot transaction failure deletes its own file and preserves the primary error',
    () async {
      final original = FileSystemException(
        'Injected storage failure',
        dir.path,
      );
      await repo.close();
      repo = await SqliteLedgerRepository.connect(
        path: getPath(),
        beforeCommit: (phase) async {
          if (phase == 'backup') throw original;
        },
      );
      await expectLater(
        repo.backupSnapshot(await fixture()),
        throwsA(same(original)),
      );
      expect(await files(), isEmpty);
      expect(await repo.listBackups(), isEmpty);
      expect((await repo.summary()).count, 1);
    },
  );

  test(
    'rollback cleanup failure reports its secondary cause but rethrows original storage error',
    () async {
      await seedTen();
      final before = await files();
      final original = FileSystemException(
            'Original storage failure',
            dir.path,
          ),
          secondary = FileSystemException('Delete denied', dir.path);
      await repo.close();
      repo = await SqliteLedgerRepository.connect(
        path: getPath(),
        beforeCommit: (phase) async {
          if (phase == 'import') throw original;
        },
        beforeBackupDelete: (path) async {
          throw secondary;
        },
      );
      final reports = <FlutterErrorDetails>[],
          oldHandler = FlutterError.onError;
      FlutterError.onError = reports.add;
      try {
        final preview = await repo.previewJson(jsonEncode(await fixture()));
        await expectLater(repo.importAtomic(preview), throwsA(same(original)));
        expect(reports.single.exception, same(secondary));
        expect(
          (await repo.readViewData(month: '2026-10')).storageWarning,
          contains('Delete denied'),
        );
        expect((await files()).length, 11);
        expect((await repo.summary()).count, 1);
      } finally {
        FlutterError.onError = oldHandler;
      }
      await repo.close();
      repo = await LedgerRepository.open(path: getPath());
      expect(await files(), before);
      expect(
        (await repo.readViewData(month: '2026-10')).storageWarning,
        isNull,
      );
      await assertPhysicalMatchesMetadata();
    },
  );

  test(
    'postcommit prune failure retains new backup and exposes committed ledger state',
    () async {
      await seedTen();
      await repo.close();
      repo = await SqliteLedgerRepository.connect(
        path: getPath(),
        beforeBackupDelete: (path) async {
          throw FileSystemException('Delete denied', path);
        },
      );
      final before = await repo.meta(), events = <int>[];
      final subscription = repo.changes.listen(events.add);
      await expectLater(
        repo.importAtomic(await repo.previewJson(jsonEncode(await fixture()))),
        throwsA(
          isA<LedgerBackupCleanupFailure>()
              .having((e) => e.committed, 'committed', true)
              .having((e) => e.ledgerChanged, 'ledgerChanged', true),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, [before.sequence + 1]);
      await subscription.cancel();
      expect((await repo.summary()).count, 6);
      expect((await repo.listBackups()).length, 10);
      expect((await files()).length, 11);
      expect(
        (await repo.readViewData(month: '2026-10')).storageWarning,
        contains('账本已保存'),
      );
      for (final backup in await repo.listBackups()) {
        expect(await File(backup.path).exists(), true);
      }
      await repo.close();
      repo = await LedgerRepository.open(path: getPath());
      expect((await files()).length, 10);
      await assertPhysicalMatchesMetadata();
    },
  );

  test(
    'backup-only postcommit failure cannot claim the cloud workflow or ledger changed',
    () async {
      await seedTen();
      final before = await repo.meta();
      await repo.close();
      repo = await SqliteLedgerRepository.connect(
        path: getPath(),
        beforeBackupDelete: (path) async {
          throw FileSystemException('Delete denied', path);
        },
      );
      await expectLater(
        repo.backupSnapshot(await fixture()),
        throwsA(
          isA<LedgerBackupCleanupFailure>()
              .having((e) => e.committed, 'committed', true)
              .having((e) => e.ledgerChanged, 'ledgerChanged', false),
        ),
      );
      expect((await repo.meta()).sequence, before.sequence);
      expect((await repo.summary()).count, 1);
      expect(
        (await repo.readViewData(month: '2026-10')).storageWarning,
        contains('账本未更改'),
      );
      for (final backup in await repo.listBackups()) {
        expect(await File(backup.path).exists(), true);
      }
    },
  );

  test(
    'opening another connection waits for an uncommitted backup and preserves it',
    () async {
      await repo.close();
      final reached = Completer<void>(), release = Completer<void>();
      repo = await SqliteLedgerRepository.connect(
        path: getPath(),
        beforeCommit: (phase) async {
          if (phase == 'backup') {
            reached.complete();
            await release.future;
          }
        },
      );
      final write = repo.backupSnapshot(await fixture());
      await reached.future;
      expect((await files()).length, 1);
      var opened = false;
      final otherFuture = LedgerRepository.open(path: getPath()).then((value) {
        opened = true;
        return value;
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(opened, false);
      expect((await files()).length, 1);
      release.complete();
      final backup = await write, other = await otherFuture;
      try {
        expect(await File(backup.path).exists(), true);
        expect((await other.listBackups()).single.id, backup.id);
        await assertPhysicalMatchesMetadata();
      } finally {
        await other.close();
      }
    },
  );

  test(
    'startup after an actual killed writer removes only unreferenced managed UUID files',
    () async {
      await seedTen();
      final before = await files(),
          backupDir = Directory(p.join(dir.path, 'backups'));
      final keep = File(p.join(backupDir.path, 'notes.json'));
      await keep.writeAsString('user supplied file');
      final directoryWithUuid = Directory(
        p.join(backupDir.path, '${const Uuid().v4()}.json'),
      );
      await directoryWithUuid.create();
      await repo.close();
      final id = const Uuid().v4(),
          orphan = File(p.join(backupDir.path, '$id.json'));
      final script = '''
import sqlite3, sys, json, os
db = sqlite3.connect(sys.argv[1])
db.execute('PRAGMA busy_timeout=5000')
db.execute('BEGIN IMMEDIATE')
with open(sys.argv[2], 'x', encoding='utf-8') as handle:
    handle.write(sys.argv[4])
    handle.flush()
    os.fsync(handle.fileno())
db.execute('INSERT INTO backups(id,label,date,path,count) VALUES(?,?,?,?,?)', (sys.argv[3], 'interrupted', '2026-10-05T00:00:00Z', sys.argv[2], 6))
print('READY', flush=True)
sys.stdin.read()
''';
      final child = await Process.start('python', [
        '-u',
        '-c',
        script,
        getPath(),
        orphan.path,
        id,
        jsonEncode(await fixture()),
      ]);
      final errors = child.stderr.transform(utf8.decoder).join();
      try {
        await child.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .firstWhere((line) => line == 'READY')
            .timeout(const Duration(seconds: 10));
        expect(child.kill(), true);
        await child.exitCode.timeout(const Duration(seconds: 5));
        expect(await errors, isEmpty);
        expect(await orphan.exists(), true);
      } finally {
        child.kill();
        await child.stdin.close();
      }
      repo = await LedgerRepository.open(path: getPath());
      expect(await files(), before);
      expect(await orphan.exists(), false);
      expect(await keep.readAsString(), 'user supplied file');
      expect(await directoryWithUuid.exists(), true);
      expect((await repo.summary()).count, 1);
      await assertPhysicalMatchesMetadata();
    },
  );

  test(
    'Windows read-only orphan warns but opens healthy ledger and permits new saves',
    () async {
      await seedTen();
      final orphan = File(
        p.join(dir.path, 'backups', '${const Uuid().v4()}.json'),
      );
      await orphan.writeAsString('interrupted file');
      expect((await Process.run('attrib', ['+R', orphan.path])).exitCode, 0);
      try {
        await repo.close();
        repo = await LedgerRepository.open(path: getPath());
        expect(
          (await repo.readViewData(month: '2026-10')).storageWarning,
          isNotNull,
        );
        expect(await orphan.exists(), true);
        expect((await repo.listBackups()).length, 10);
        await repo.saveTransaction(entry('after-warning'), create: true);
        expect((await repo.summary()).count, 2);
      } finally {
        await Process.run('attrib', ['-R', orphan.path]);
      }
      await repo.close();
      repo = await LedgerRepository.open(path: getPath());
      expect(await orphan.exists(), false);
      expect(
        (await repo.readViewData(month: '2026-10')).storageWarning,
        isNull,
      );
      await assertPhysicalMatchesMetadata();
    },
    skip: !Platform.isWindows,
  );
}
