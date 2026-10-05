import 'dart:io';

import 'package:path/path.dart' as p;

export '../services/atomic_file.dart' show atomicReplaceFile;

Future<void> deleteOwnedScratchDirectory(
  Directory directory,
  String prefix,
) async {
  if (!await directory.exists()) return;
  final root = await Directory.systemTemp.resolveSymbolicLinks();
  final target = await directory.resolveSymbolicLinks();
  final normalizedRoot = Platform.isWindows ? root.toLowerCase() : root;
  final normalizedTarget = Platform.isWindows ? target.toLowerCase() : target;
  if (!p.isWithin(normalizedRoot, normalizedTarget) ||
      !p.basename(target).startsWith(prefix)) {
    throw FileSystemException(
      'Refusing to remove a directory outside the owned temporary area',
      target,
    );
  }
  await Directory(target).delete(recursive: true);
}
