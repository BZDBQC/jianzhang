import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/app/controller.dart';
import 'package:jianzhang/app/startup_configuration.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class _Fixture {
  _Fixture() {
    qa = p.normalize(p.absolute('../../.qa'));
    runId = const Uuid().v4().replaceAll('-', '');
    root = Directory(p.join(qa, 'startup-$runId'))..createSync(recursive: true);
    executable = File(p.join(root.path, 'payload 空格', 'jianzhang.exe'));
    executable.parent.createSync();
    executable.writeAsStringSync('not executed: startup configuration fixture');
    directory = Directory(p.join(root.path, 'sample-00'))..createSync();
    database = p.join(directory.path, 'jianzhang.sqlite');
    marker = File(p.join(directory.path, StartupConfiguration.markerName));
    writeMarker();
  }
  late final String qa;
  late final String runId;
  late final Directory root;
  late final File executable;
  late final Directory directory;
  late final String database;
  late final File marker;

  void writeMarker([Map<String, Object?> overrides = const {}]) =>
      marker.writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'purpose': 'jianzhang-windows-cold-start',
          'runId': runId,
          'sample': 0,
          'databasePath': database,
          'executablePath': executable.path,
          'initialTransactions': 0,
          'initialDatabaseExists': false,
          ...overrides,
        }),
      );

  StartupConfiguration resolve([String? path]) => StartupConfiguration.resolve([
    '${StartupConfiguration.argumentPrefix}${path ?? database}',
  ], executablePath: executable.path);

  Future<void> dispose() async {
    final actual = await root.resolveSymbolicLinks();
    if (!p.isWithin(qa.toLowerCase(), actual.toLowerCase()) ||
        p.basename(actual) != 'startup-$runId' ||
        actual.toLowerCase() != root.path.toLowerCase()) {
      throw StateError('Refusing to remove an unowned startup fixture');
    }
    await root.delete(recursive: true);
  }
}

void main() {
  test('ordinary Windows and Android startup retains the default path', () {
    for (final windows in [true, false]) {
      for (final args in <List<String>>[
        [],
        ['unrelated-argument'],
      ]) {
        expect(
          StartupConfiguration.resolve(args, isWindows: windows).databasePath,
          isNull,
        );
      }
    }
    final container = ProviderContainer();
    try {
      expect(container.read(initialDatabasePathProvider), isNull);
    } finally {
      container.dispose();
    }
  });

  test('Android rejects an explicitly requested Windows QA database', () {
    expect(
      () => StartupConfiguration.resolve([
        r'--jianzhang-qa-database=C:\.qa\startup-x\jianzhang.sqlite',
      ], isWindows: false),
      throwsFormatException,
    );
  });

  test('unknown, repeated and malformed QA arguments fail closed', () {
    for (final args in <List<String>>[
      ['--jianzhang-qa-unknown=1'],
      ['--JIANZHANG-QA-DATABASE=x'],
      ['--jianzhang-qa-database'],
      ['--jianzhang-qa-database='],
      ['--jianzhang-qa-database=relative.sqlite'],
      [r'--jianzhang-qa-database=C:/tmp/file.sqlite'],
      [r'--jianzhang-qa-database=C:\tmp\..\file.sqlite'],
      [r'--jianzhang-qa-database=\\server\share\file.sqlite'],
      [r'--jianzhang-qa-database=\\?\C:\file.sqlite'],
      ['--jianzhang-qa-database=x', '--jianzhang-qa-database=x'],
      ['--jianzhang-qa-database=x', 'extra'],
    ]) {
      expect(
        () => StartupConfiguration.resolve(args, isWindows: true),
        throwsFormatException,
        reason: '$args',
      );
    }
  });

  group('Windows-owned fixtures', () {
    late _Fixture fixture;
    setUp(() => fixture = _Fixture());
    tearDown(() async => fixture.dispose());

    test(
      'valid fixture is selected without opening or creating its database',
      () {
        final configuration = fixture.resolve();
        expect(configuration.databasePath, fixture.database);
        expect(configuration.runId, fixture.runId);
        expect(configuration.sample, 0);
        expect(File(fixture.database).existsSync(), false);
      },
    );

    test(
      'wrong .qa root, outside executable and malformed fixture paths fail',
      () {
        expect(
          () => StartupConfiguration.resolve([
            '${StartupConfiguration.argumentPrefix}${fixture.database}',
          ], executablePath: p.join(p.dirname(fixture.qa), 'jianzhang.exe')),
          throwsFormatException,
        );
        for (final path in [
          p.join(
            p.dirname(fixture.qa),
            '.qa-other',
            'startup-${fixture.runId}',
            'sample-00',
            'jianzhang.sqlite',
          ),
          p.join(fixture.root.path, 'sample-00', 'personal.sqlite'),
          p.join(fixture.root.path, 'sample-100', 'jianzhang.sqlite'),
          p.join(fixture.root.path, 'jianzhang.sqlite'),
        ]) {
          expect(() => fixture.resolve(path), throwsFormatException);
        }
      },
    );

    test('missing and corrupt marker fail without a database', () {
      fixture.marker.deleteSync();
      expect(() => fixture.resolve(), throwsFormatException);
      fixture.marker.writeAsStringSync('{invalid');
      expect(() => fixture.resolve(), throwsFormatException);
      expect(File(fixture.database).existsSync(), false);
    });

    test('all marker identity and fresh-state mismatches are rejected', () {
      for (final change in <Map<String, Object?>>[
        {'schemaVersion': 2},
        {'purpose': 'other'},
        {'runId': 'different'},
        {'sample': 1},
        {'databasePath': p.join(fixture.directory.path, 'other.sqlite')},
        {'executablePath': p.join(fixture.root.path, 'other.exe')},
        {'initialTransactions': 1},
        {'initialDatabaseExists': true},
      ]) {
        fixture.writeMarker(change);
        expect(
          () => fixture.resolve(),
          throwsFormatException,
          reason: '$change',
        );
      }
      expect(File(fixture.database).existsSync(), false);
    });

    test('preexisting database, journal or backup makes a sample unusable', () {
      for (final name in [
        'jianzhang.sqlite',
        'jianzhang.sqlite-wal',
        'backup.json',
      ]) {
        final file = File(p.join(fixture.directory.path, name))
          ..writeAsStringSync('retained');
        expect(() => fixture.resolve(), throwsFormatException);
        expect(file.readAsStringSync(), 'retained');
        file.deleteSync();
      }
    });

    test(
      'directory junction is rejected by native reparse attribute check',
      () async {
        final actual = Directory(p.join(fixture.root.path, 'original'));
        fixture.directory.renameSync(actual.path);
        final creation = await Process.run('cmd.exe', [
          '/d',
          '/c',
          'mklink',
          '/J',
          fixture.directory.path,
          actual.path,
        ]);
        if (creation.exitCode != 0) {
          throw StateError(
            'Could not create owned junction: ${creation.stderr}',
          );
        }
        try {
          expect(() => fixture.resolve(), throwsFormatException);
          expect(
            File(
              p.join(actual.path, StartupConfiguration.markerName),
            ).existsSync(),
            true,
          );
        } finally {
          // Remove only the junction itself, then restore the owned directory.
          await fixture.directory.delete();
          actual.renameSync(fixture.directory.path);
        }
      },
    );

    test(
      'repository provider creates an empty ledger at the selected QA path',
      () async {
        final configuration = fixture.resolve();
        final container = ProviderContainer(
          overrides: [
            initialDatabasePathProvider.overrideWithValue(
              configuration.databasePath,
            ),
          ],
        );
        try {
          final repository = await container.read(repositoryProvider.future);
          expect((await repository.search(const LedgerFilter())).total, 0);
          expect((await repository.meta()).key, 'guest');
          expect(File(fixture.database).existsSync(), true);
        } finally {
          container.dispose();
          // Disposal closes the background database asynchronously.
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      },
    );
  }, skip: !Platform.isWindows);
}
