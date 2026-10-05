import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// An explicit, disposable Windows QA fixture. Ordinary launches use no override.
class StartupConfiguration {
  const StartupConfiguration._({this.databasePath, this.runId, this.sample});

  final String? databasePath;
  final String? runId;
  final int? sample;

  static const argumentPrefix = '--jianzhang-qa-database=';
  static const markerName = 'startup-fixture.json';

  static StartupConfiguration resolve(
    List<String> arguments, {
    bool? isWindows,
    String? executablePath,
  }) {
    if (!arguments.any(
      (value) => value.toLowerCase().startsWith('--jianzhang-qa'),
    )) {
      return const StartupConfiguration._();
    }
    if (!(isWindows ?? Platform.isWindows) ||
        arguments.length != 1 ||
        !arguments.single.startsWith(argumentPrefix)) {
      throw const FormatException('Invalid Windows QA startup arguments');
    }
    final database = _absolute(
      arguments.single.substring(argumentPrefix.length),
    );
    final executable = _absolute(executablePath ?? Platform.resolvedExecutable);
    final ancestors = p.windows.split(executable);
    final qaIndex = ancestors.lastIndexWhere(
      (part) => part.toLowerCase() == '.qa',
    );
    if (qaIndex < 1 || qaIndex == ancestors.length - 1) {
      throw const FormatException('QA executable must be inside .qa');
    }
    final qaRoot = p.windows.joinAll(ancestors.take(qaIndex + 1));
    if (!p.windows.isWithin(qaRoot.toLowerCase(), database.toLowerCase())) {
      throw const FormatException(
        'QA database must share the executable .qa root',
      );
    }
    final relative = p.windows.split(
      p.windows.relative(database, from: qaRoot),
    );
    if (relative.length != 3 ||
        !RegExp(r'^startup-[a-f0-9]{32}$').hasMatch(relative[0]) ||
        !RegExp(r'^sample-[0-9]{2}$').hasMatch(relative[1]) ||
        relative[2] != 'jianzhang.sqlite') {
      throw const FormatException('Invalid QA fixture path');
    }
    final runId = relative[0].substring('startup-'.length);
    final sample = int.parse(relative[1].substring('sample-'.length));
    final parent = p.windows.dirname(database);
    final marker = p.windows.join(parent, markerName);
    final attributes = _WindowsFileAttributes();
    attributes.assertPath(executable, finalDirectory: false);
    attributes.assertPath(parent, finalDirectory: true);
    attributes.assertPath(marker, finalDirectory: false);
    // Every sample must start without a database or leftover journal/backup.
    final children = Directory(parent).listSync(followLinks: false);
    if (children.length != 1 ||
        children.single.path.toLowerCase() != marker.toLowerCase()) {
      throw const FormatException('QA fixture must contain only its marker');
    }
    if (File(marker).lengthSync() > 8192) {
      throw const FormatException('QA fixture marker is too large');
    }
    final value = jsonDecode(File(marker).readAsStringSync());
    if (value is! Map<String, dynamic> ||
        value['schemaVersion'] != 1 ||
        value['purpose'] != 'jianzhang-windows-cold-start' ||
        value['runId'] != runId ||
        value['sample'] != sample ||
        value['initialTransactions'] != 0 ||
        value['initialDatabaseExists'] != false ||
        value['databasePath'] is! String ||
        value['executablePath'] is! String ||
        _absolute(value['databasePath'] as String).toLowerCase() !=
            database.toLowerCase() ||
        _absolute(value['executablePath'] as String).toLowerCase() !=
            executable.toLowerCase()) {
      throw const FormatException(
        'QA fixture marker does not match this launch',
      );
    }
    return StartupConfiguration._(
      databasePath: database,
      runId: runId,
      sample: sample,
    );
  }

  static String _absolute(String value) {
    // Exclude relative, UNC/device paths and aliases using `..` or `.`.
    if (!RegExp(r'^[a-zA-Z]:\\').hasMatch(value) ||
        value.contains('/') ||
        value.contains('\u0000') ||
        p.windows.normalize(value) != value) {
      throw const FormatException(
        'QA startup paths must be canonical absolute drive paths',
      );
    }
    return value;
  }
}

class _WindowsFileAttributes {
  final _getAttributes = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Uint32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)
      >('GetFileAttributesW');

  void assertPath(String path, {required bool finalDirectory}) {
    final parts = p.windows.split(path);
    for (var index = 0; index < parts.length; index++) {
      final current = p.windows.joinAll(parts.take(index + 1));
      // UTF-16 memory belongs to this call and is always released, including errors.
      final pointer = current.toNativeUtf16();
      late final int attributes;
      try {
        attributes = _getAttributes(pointer);
      } finally {
        calloc.free(pointer);
      }
      if (attributes == 0xffffffff || (attributes & 0x400) != 0) {
        throw const FormatException('Missing or reparse QA startup path');
      }
      final directory = (attributes & 0x10) != 0;
      if (directory != (index < parts.length - 1 || finalDirectory)) {
        throw const FormatException('QA startup path has the wrong file type');
      }
    }
  }
}
