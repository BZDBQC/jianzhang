import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:jianzhang/data/safe_files.dart';

import 'repository_regression_test.dart' show entry;

typedef _OpenNative =
    IntPtr Function(
      Pointer<Utf16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      IntPtr,
    );
typedef _CloseNative = Int32 Function(IntPtr);
typedef _AttributesNative = Int32 Function(Pointer<Utf16>, Uint32);

void main() {
  late Directory dir;
  late LedgerRepository repo;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jianzhang-atomic-');
    repo = await LedgerRepository.open(path: '${dir.path}/ledger.db');
    await repo.saveTransaction(entry('one'), create: true);
  });
  tearDown(() async {
    await repo.close();
    await deleteOwnedScratchDirectory(dir, 'jianzhang-atomic-');
  });
  test(
    'replaces an existing export without deleting the original first',
    () async {
      final file = File('${dir.path}/existing.json');
      await file.writeAsString('old export');
      await repo.exportFile(file.path);
      expect(await file.readAsString(), contains('"id":"one"'));
    },
  );
  test(
    'Windows read-only destination preserves prior bytes and removes staging',
    () async {
      final file = File('${dir.path}/readonly.json');
      await file.writeAsString('previous valid backup');
      final kernel = DynamicLibrary.open('kernel32.dll');
      final attributes = kernel
          .lookupFunction<_AttributesNative, int Function(Pointer<Utf16>, int)>(
            'SetFileAttributesW',
          );
      final path = file.path.toNativeUtf16();
      try {
        expect(attributes(path, 1), 1);
        await expectLater(
          repo.exportFile(file.path),
          throwsA(isA<FileSystemException>()),
        );
        expect(await file.readAsString(), 'previous valid backup');
        expect(
          await dir.list().where((f) => f.path.endsWith('.tmp')).length,
          0,
        );
      } finally {
        attributes(path, 128);
        calloc.free(path);
      }
    },
    skip: !Platform.isWindows,
  );
  test(
    'Windows exclusively locked destination preserves prior bytes and allows retry',
    () async {
      final file = File('${dir.path}/locked.json');
      await file.writeAsString('previous valid backup');
      final kernel = DynamicLibrary.open('kernel32.dll');
      final open = kernel
          .lookupFunction<
            _OpenNative,
            int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
          >('CreateFileW');
      final close = kernel.lookupFunction<_CloseNative, int Function(int)>(
        'CloseHandle',
      );
      final path = file.path.toNativeUtf16();
      final handle = open(path, 0x80000000, 0, nullptr, 3, 128, 0);
      calloc.free(path);
      expect(handle, isNot(-1));
      try {
        await expectLater(
          repo.exportFile(file.path),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          await dir.list().where((f) => f.path.endsWith('.tmp')).length,
          0,
        );
      } finally {
        expect(close(handle), 1);
      }
      expect(await file.readAsString(), 'previous valid backup');
      await repo.exportFile(file.path);
      expect(await file.readAsString(), contains('"id":"one"'));
    },
    skip: !Platform.isWindows,
  );
}
