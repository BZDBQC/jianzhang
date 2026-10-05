import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/services/file_service.dart';
import 'package:jianzhang/services/atomic_file.dart';
import 'package:path/path.dart' as p;

Future<void> removeTestDirectory(Directory directory) async {
  if (!p.isWithin(
        Directory.systemTemp.absolute.path,
        directory.absolute.path,
      ) ||
      !p.basename(directory.path).startsWith('jianzhang-export-')) {
    throw StateError(
      'Test cleanup target is outside its owned temporary directory',
    );
  }
  await directory.delete(recursive: true);
}

void main() {
  test('missing or empty staging never replaces an existing backup', () async {
    final directory = await Directory.systemTemp.createTemp(
      'jianzhang-export-',
    );
    try {
      final target = await File(
        p.join(directory.path, 'backup.json'),
      ).writeAsString('only good backup');
      final staging = File(p.join(directory.path, 'missing.tmp'));
      await expectLater(
        atomicReplaceFile(staging.path, target.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(await staging.exists(), false);
      expect(await target.readAsString(), 'only good backup');
      await staging.writeAsString('');
      await expectLater(
        atomicReplaceFile(staging.path, target.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(await target.readAsString(), 'only good backup');
    } finally {
      await removeTestDirectory(directory);
    }
  });
  test(
    'OS replacement rejects a read-only destination and preserves the old backup',
    () async {
      if (!Platform.isWindows) return;
      final directory = await Directory.systemTemp.createTemp(
        'jianzhang-export-',
      );
      final source = File(p.join(directory.path, 'source.json'));
      final target = File(p.join(directory.path, 'locked.json'));
      try {
        await source.writeAsString('new backup');
        await target.writeAsString('irreplaceable old backup');
        final readOnly = await Process.run('attrib.exe', ['+R', target.path]);
        expect(readOnly.exitCode, 0);
        await expectLater(
          FileService.copyExportAtomic(source.path, target.path),
          throwsA(isA<FileSystemException>()),
        );
        expect(await target.readAsString(), 'irreplaceable old backup');
        expect(await source.readAsString(), 'new backup');
        expect(await directory.list().length, 2);
      } finally {
        await Process.run('attrib.exe', ['-R', target.path]);
        await removeTestDirectory(directory);
      }
    },
  );
  test(
    'atomic commit rejects different directories and cannot replace a directory',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'jianzhang-export-',
      );
      try {
        final folder = await Directory(
          p.join(directory.path, 'occupied'),
        ).create();
        final staging = await File(
          p.join(directory.path, 'staging.tmp'),
        ).writeAsString('new');
        await expectLater(
          atomicReplaceFile(staging.path, folder.path),
          throwsA(isA<FileSystemException>()),
        );
        expect(await folder.exists(), true);
        expect(await staging.readAsString(), 'new');
        await expectLater(
          atomicReplaceFile(staging.path, p.join(folder.path, 'out.json')),
          throwsA(isA<FileSystemException>()),
        );
        expect(await staging.readAsString(), 'new');
      } finally {
        await removeTestDirectory(directory);
      }
    },
  );
  test(
    'atomic export handles Chinese and spaces, replaces a prior file, and preserves source',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'jianzhang-export-',
      );
      try {
        final source = File('${directory.path}/账本 来源.json');
        final target = File('${directory.path}/我的 备份.json');
        await source.writeAsString('新账本😀');
        await target.writeAsString('旧备份');
        await FileService.copyExportAtomic(source.path, target.path);
        expect(await source.readAsString(), '新账本😀');
        expect(await target.readAsString(), '新账本😀');
        expect(await directory.list().length, 2);
        await FileService.copyExportAtomic(source.path, source.path);
        expect(await source.readAsString(), '新账本😀');
      } finally {
        await removeTestDirectory(directory);
      }
    },
  );
  test('failed export never truncates the previous backup', () async {
    final directory = await Directory.systemTemp.createTemp(
      'jianzhang-export-',
    );
    try {
      final target = File('${directory.path}/既有账本.json');
      await target.writeAsString('唯一旧账本');
      await expectLater(
        FileService.copyExportAtomic(
          '${directory.path}/missing.json',
          target.path,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await target.readAsString(), '唯一旧账本');
      expect(await directory.list().length, 1);
    } finally {
      await removeTestDirectory(directory);
    }
  });
}
