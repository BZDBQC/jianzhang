part of 'sqlite_ledger_repository.dart';

final _backupName = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.json$',
  caseSensitive: false,
);

String _backupPathKey(String path) {
  final normalized = p.normalize(File(path).absolute.path);
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

mixin _RepositoryBackups on _RepositoryCore {
  @override
  Future<Directory> _ownedBackupDirectory({bool create = false}) async {
    final root = await _directory.resolveSymbolicLinks();
    final directory = Directory(p.join(root, 'backups'));
    var type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      if (!create) return directory;
      await directory.create();
      type = await FileSystemEntity.type(directory.path, followLinks: false);
    }
    if (type != FileSystemEntityType.directory ||
        !p.equals(await directory.resolveSymbolicLinks(), directory.path)) {
      throw FileSystemException('备份目录必须是本机账本目录中的普通文件夹', directory.path);
    }
    return directory;
  }

  @override
  Future<void> _backup(String label, List<String> created) async {
    final id = const Uuid().v4();
    final directory = await _ownedBackupDirectory(create: true);
    final file = File(p.join(directory.path, '$id.json'));
    // Track only a file exclusively created by this operation. The outer
    // transaction owns cleanup on any write, INSERT or COMMIT failure.
    await file.create(exclusive: true);
    created.add(file.path);
    await _writeJson(file);
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.flush();
    } finally {
      await handle.close();
    }
    await _db.customStatement(
      'INSERT INTO backups(id,label,date,path,count) VALUES(?,?,?,?,?)',
      [
        id,
        label,
        DateTime.now().toUtc().toIso8601String(),
        file.path,
        (await meta()).transactionCount,
      ],
    );
  }

  @override
  Future<List<String>> _trimBackupMetadata() async {
    final old = await _rows(
      'SELECT id,path FROM backups ORDER BY date DESC,id DESC LIMIT -1 OFFSET 10',
    );
    for (final row in old) {
      await _db.customStatement('DELETE FROM backups WHERE id=?', [
        row.read<String>('id'),
      ]);
    }
    return old.map((row) => row.read<String>('path')).toList();
  }

  Future<void> _removeBackupFiles(List<String> paths) async {
    if (paths.isEmpty) return;
    final directory = await _ownedBackupDirectory();
    for (final path in paths) {
      final file = File(path).absolute;
      if (!p.equals(p.normalize(file.parent.path), directory.path) ||
          !_backupName.hasMatch(p.basename(file.path))) {
        throw FileSystemException('拒绝删除本机备份目录之外或名称不受管理的文件', path);
      }
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (type != FileSystemEntityType.file) {
        throw FileSystemException('拒绝删除非普通备份文件', path);
      }
      await _backupDeleteHook?.call(file.path);
      try {
        await file.delete();
      } on FileSystemException {
        // Another completed cleanup may already have removed this same orphan.
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          rethrow;
        }
      }
    }
  }

  @override
  Future<Never> _rethrowAfterBackupCleanup(
    List<String> created,
    Object original,
    StackTrace stack, {
    Future<void> Function()? extraCleanup,
  }) async {
    try {
      for (final cleanupAction in <Future<void> Function()>[
        () => _removeBackupFiles(created),
        ?extraCleanup,
      ]) {
        try {
          await cleanupAction();
        } catch (cleanup, cleanupStack) {
          _storageWarning = LedgerBackupCleanupFailure(
            cleanup,
            committed: false,
          ).toString();
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: cleanup,
              stack: cleanupStack,
              library: '简账备份文件恢复',
              context: ErrorDescription('原始操作已失败；清理残留数据时再次失败。原始错误：$original'),
            ),
          );
        }
      }
    } finally {
      // Preserve the primary failure object and stack, including when a custom
      // diagnostic error handler itself throws.
      Error.throwWithStackTrace(original, stack);
    }
  }

  @override
  Future<void> _finishBackupCleanup(
    List<String> paths, {
    bool ledgerChanged = true,
  }) async {
    try {
      await _removeBackupFiles(paths);
    } catch (error, stack) {
      final failure = LedgerBackupCleanupFailure(
        error,
        committed: true,
        ledgerChanged: ledgerChanged,
      );
      _storageWarning = failure.toString();
      Error.throwWithStackTrace(failure, stack);
    }
  }

  Future<void> _cleanupOrphanBackups() => _exclusive(
    () => _transaction(() async {
      // BEGIN IMMEDIATE excludes every backup producer using this database,
      // including other processes. File creation and metadata insertion both
      // happen while that writer lock is held, so uncommitted backups are safe.
      final referenced = (await _rows(
        'SELECT path FROM backups',
      )).map((r) => _backupPathKey(r.read<String>('path'))).toSet();
      try {
        final directory = await _ownedBackupDirectory();
        if (!await directory.exists()) return;
        final orphaned = <String>[];
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is File &&
              _backupName.hasMatch(p.basename(entity.path)) &&
              !referenced.contains(_backupPathKey(entity.path))) {
            orphaned.add(entity.path);
          }
        }
        await _removeBackupFiles(orphaned);
        _storageWarning = null;
      } catch (error) {
        // A locked/read-only orphan must not hide an otherwise healthy ledger.
        // The controller displays this warning from the consistent view snapshot.
        _storageWarning = LedgerBackupCleanupFailure(
          error,
          committed: false,
        ).toString();
      }
    }),
  );
}
