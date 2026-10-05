import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

typedef _WinMove = Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _WinError = Uint32 Function();
typedef _WinOpen =
    IntPtr Function(
      Pointer<Utf16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      IntPtr,
    );
typedef _WinHandleCall = Int32 Function(IntPtr);
typedef _PosixRename = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _PosixOpen = Int32 Function(Pointer<Utf8>, Int32);
typedef _PosixFdCall = Int32 Function(Int32);
typedef _Errno = Pointer<Int32> Function();

/// Commit a closed, same-directory staging file without first removing the target.
/// Flush before the single OS rename; a rejected replace leaves the old file intact.
Future<void> atomicReplaceFile(String stagingPath, String targetPath) async {
  final staging = File(stagingPath).absolute;
  final target = File(targetPath).absolute;
  if (p.equals(staging.path, target.path)) {
    throw const FileSystemException(
      'Staging and destination must be different',
    );
  }
  final sourceParent = await staging.parent.resolveSymbolicLinks();
  final targetParent = await target.parent.resolveSymbolicLinks();
  if (!p.equals(sourceParent, targetParent)) {
    throw const FileSystemException(
      'Atomic replacement requires the same directory',
    );
  }
  if (await FileSystemEntity.type(staging.path, followLinks: false) !=
          FileSystemEntityType.file ||
      (await staging.length()) == 0) {
    throw FileSystemException(
      'Export staging file is missing, empty or not a regular file',
      staging.path,
    );
  }
  await Isolate.run(() => _replace(staging.path, target.path));
}

void _replace(String source, String target) {
  if (Platform.isWindows) {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final move = kernel
        .lookupFunction<
          _WinMove,
          int Function(Pointer<Utf16>, Pointer<Utf16>, int)
        >('MoveFileExW');
    final lastError = kernel.lookupFunction<_WinError, int Function()>(
      'GetLastError',
    );
    final oldPath = source.toNativeUtf16();
    final newPath = target.toNativeUtf16();
    try {
      _flushWindowsExisting(kernel, oldPath, source, lastError);
      // REPLACE_EXISTING | WRITE_THROUGH. Never allow cross-volume copy/delete.
      if (move(oldPath, newPath, 1 | 8) == 0) {
        final error = lastError();
        throw FileSystemException(
          'Unable to commit exported file',
          target,
          OSError('MoveFileExW failed', error),
        );
      }
    } finally {
      calloc.free(oldPath);
      calloc.free(newPath);
    }
    return;
  }
  final libc = Platform.isAndroid
      ? DynamicLibrary.open('libc.so')
      : DynamicLibrary.process();
  final rename = libc
      .lookupFunction<_PosixRename, int Function(Pointer<Utf8>, Pointer<Utf8>)>(
        'rename',
      );
  final errnoSymbol = Platform.isAndroid
      ? '__errno'
      : (Platform.isMacOS || Platform.isIOS ? '__error' : '__errno_location');
  final errno = libc.lookupFunction<_Errno, Pointer<Int32> Function()>(
    errnoSymbol,
  );
  final oldPath = source.toNativeUtf8();
  final newPath = target.toNativeUtf8();
  try {
    _flushPosixExisting(libc, oldPath, source, errno);
    if (rename(oldPath, newPath) != 0) {
      final error = errno().value;
      throw FileSystemException(
        'Unable to commit exported file',
        target,
        OSError('rename failed', error),
      );
    }
  } finally {
    calloc.free(oldPath);
    calloc.free(newPath);
  }
}

void _flushWindowsExisting(
  DynamicLibrary kernel,
  Pointer<Utf16> path,
  String source,
  int Function() lastError,
) {
  final open = kernel
      .lookupFunction<
        _WinOpen,
        int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
      >('CreateFileW');
  final flush = kernel.lookupFunction<_WinHandleCall, int Function(int)>(
    'FlushFileBuffers',
  );
  final close = kernel.lookupFunction<_WinHandleCall, int Function(int)>(
    'CloseHandle',
  );
  // OPEN_EXISTING never recreates a vanished staging file as an empty export.
  final handle = open(path, 0x40000000, 7, nullptr, 3, 0x80, 0);
  if (handle == -1) {
    throw FileSystemException(
      'Unable to open staged export',
      source,
      OSError('CreateFileW failed', lastError()),
    );
  }
  try {
    if (flush(handle) == 0) {
      throw FileSystemException(
        'Unable to flush staged export',
        source,
        OSError('FlushFileBuffers failed', lastError()),
      );
    }
  } finally {
    close(handle);
  }
}

void _flushPosixExisting(
  DynamicLibrary libc,
  Pointer<Utf8> path,
  String source,
  Pointer<Int32> Function() errno,
) {
  final open = libc
      .lookupFunction<_PosixOpen, int Function(Pointer<Utf8>, int)>('open');
  final flush = libc.lookupFunction<_PosixFdCall, int Function(int)>('fsync');
  final close = libc.lookupFunction<_PosixFdCall, int Function(int)>('close');
  final closeOnExec = Platform.isMacOS || Platform.isIOS ? 0x1000000 : 0x80000;
  final fd = open(path, 1 | closeOnExec); // O_WRONLY, without O_CREAT.
  if (fd < 0) {
    throw FileSystemException(
      'Unable to open staged export',
      source,
      OSError('open failed', errno().value),
    );
  }
  try {
    while (flush(fd) != 0) {
      final error = errno().value;
      if (error == 4) continue; // EINTR: no side effects, retry the flush.
      throw FileSystemException(
        'Unable to flush staged export',
        source,
        OSError('fsync failed', error),
      );
    }
  } finally {
    close(fd);
  }
}
