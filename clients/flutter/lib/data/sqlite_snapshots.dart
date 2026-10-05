part of 'sqlite_ledger_repository.dart';

mixin _RepositorySnapshots on _RepositoryCore {
  @override
  Future<ImportPreview> previewJson(
    String json, {
    int maxTransactions = localTransactionLimit,
    String? expectedWorkspace,
    int? expectedSequence,
  }) async {
    final file = File(
      p.join(_directory.path, 'import-${const Uuid().v4()}.json'),
    );
    try {
      await file.writeAsString(json);
      return await previewImport(
        file.path,
        maxTransactions: maxTransactions,
        expectedWorkspace: expectedWorkspace,
        expectedSequence: expectedSequence,
      );
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  @override
  Future<ImportPreview> previewImport(
    String filePath, {
    int maxTransactions = localTransactionLimit,
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _exclusive(() async {
    if (maxTransactions < 1 || maxTransactions > localTransactionLimit) {
      throw const LedgerException('导入数量限制无效');
    }
    final token = const Uuid().v4(),
        before = await meta(),
        file = File(filePath);
    if (!await file.exists()) throw const LedgerException('备份文件不存在');
    final reader = JsonStreamReader(file.openRead());
    final accounts = <Account>[],
        categories = <Category>[],
        budgets = <Budget>[],
        pending = <LedgerTransaction>[];
    LedgerSettings? preferences;
    var count = 0;
    int? version;
    bool? started;
    Future<void> flush() async {
      if (pending.isEmpty) return;
      final start = count - pending.length;
      await _db.batch((batch) {
        for (var i = 0; i < pending.length; i++) {
          batch.customStatement(
            'INSERT INTO staged_entries(token,id,type,amount,fee,date,account_id,to_account_id,category_id,note,note_fold,created_at,position) VALUES($_marks)',
            _entryValues(token, pending[i], start + i),
          );
        }
      });
      pending.clear();
    }

    try {
      return await _transaction(() async {
        await _checkScope(expectedWorkspace, expectedSequence);
        await reader.root(
          (key, value) async {
            switch (key) {
              case 'version':
                if (value != 1) throw const LedgerException('备份版本不支持');
                version = 1;
              case 'started':
                if (value is! bool) throw const LedgerException('备份状态无效');
                started = value;
              case 'settings':
                preferences = LedgerSettings.fromJson(value);
            }
          },
          (key, value) async {
            switch (key) {
              case 'accounts':
                accounts.add(Account.fromJson(value));
                if (accounts.length > 100) {
                  throw const LedgerException('账户数量过多');
                }
              case 'categories':
                categories.add(Category.fromJson(value));
                if (categories.length > 1000) {
                  throw const LedgerException('分类数量过多');
                }
              case 'budgets':
                budgets.add(Budget.fromJson(value));
                if (budgets.length > 1000) {
                  throw const LedgerException('预算数量过多');
                }
              case 'transactions':
                final t = LedgerTransaction.fromJson(value);
                t.validate();
                pending.add(t);
                count++;
                if (count > maxTransactions) {
                  throw const LedgerException('账单数量超过支持范围');
                }
                if (pending.length >= 100) await flush();
            }
          },
        );
        await flush();
        if (version != 1 || started == null || preferences == null) {
          throw const LedgerException('备份缺少必要字段');
        }
        validateMetadata(accounts, categories, budgets, preferences!);
        final aIds = accounts.map((a) => a.id).toList(),
            expense = categories
                .where((c) => c.parentId != null && c.type == EntryType.expense)
                .map((c) => c.id)
                .toList(),
            income = categories
                .where((c) => c.parentId != null && c.type == EntryType.income)
                .map((c) => c.id)
                .toList();
        String marks(List<String> list) =>
            list.isEmpty ? "''" : List.filled(list.length, '?').join(',');
        final invalid = await _rows(
          "SELECT id FROM staged_entries WHERE token=? AND (account_id NOT IN (${marks(aIds)}) OR (type='transfer' AND (to_account_id NOT IN (${marks(aIds)}) OR (fee>0 AND category_id NOT IN (${marks(expense)})))) OR (type='expense' AND category_id NOT IN (${marks(expense)})) OR (type='income' AND category_id NOT IN (${marks(income)}))) LIMIT 1",
          [token, ...aIds, ...aIds, ...expense, ...expense, ...income],
        );
        if (invalid.isNotEmpty) throw const LedgerException('备份账单包含无效账户或分类');
        final metadata = {
          'version': 1,
          'started': started,
          'accounts': accounts.map((a) => a.toJson()).toList(),
          'categories': categories.map((c) => c.toJson()).toList(),
          'budgets': budgets.map((b) => b.toJson()).toList(),
          'settings': preferences!.toJson(),
        };
        await _db.customStatement(
          'INSERT INTO imports(token,ws,sequence,metadata,count) VALUES(?,?,?,?,?)',
          [token, _workspace, before.sequence, jsonEncode(metadata), count],
        );
        return ImportPreview(
          token: token,
          workspace: _workspace,
          accountCount: accounts.length,
          categoryCount: categories.length,
          transactionCount: count,
          budgetCount: budgets.length,
          expectedSequence: before.sequence,
        );
      });
    } catch (error) {
      if (error is LedgerException) rethrow;
      throw const LedgerException('备份数据无效，可能存在重复 ID 或文件损坏');
    } finally {
      await reader.close();
    }
  });
  @override
  Future<void> discardImport(ImportPreview preview) => _exclusive(
    () => _transaction(() async {
      await _db.customStatement('DELETE FROM staged_entries WHERE token=?', [
        preview.token,
      ]);
      await _db.customStatement('DELETE FROM imports WHERE token=?', [
        preview.token,
      ]);
    }),
  );
  @override
  Future<void> importAtomic(
    ImportPreview preview, {
    String label = '恢复前备份',
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _exclusive(() async {
    var removed = <String>[];
    final created = <String>[];
    try {
      await _transaction(() async {
        await _checkScope(expectedWorkspace, expectedSequence);
        final current = await meta();
        if (preview.workspace != _workspace ||
            current.sequence != preview.expectedSequence) {
          throw const LedgerConflict();
        }
        final row = await _one('SELECT * FROM imports WHERE token=? AND ws=?', [
          preview.token,
          _workspace,
        ]);
        if (row.read<int>('sequence') != current.sequence) {
          throw const LedgerConflict();
        }
        await _backup(label, created);
        await _applyStaged(preview, _workspace);
        removed = await _trimBackupMetadata();
        await _commitHook?.call('import');
      });
    } catch (error, stack) {
      await _rethrowAfterBackupCleanup(created, error, stack);
    }
    _events.add((await meta()).sequence);
    await _finishBackupCleanup(removed);
  });
  Future<void> _applyStaged(
    ImportPreview preview,
    String target, {
    int? cloudRevision,
  }) async {
    final row = await _one(
      'SELECT metadata FROM imports WHERE token=? AND ws=?',
      [preview.token, preview.workspace],
    );
    final document = jsonObject(jsonDecode(row.read<String>('metadata')));
    final accounts = (document['accounts'] as List)
        .map(Account.fromJson)
        .toList();
    final categories = (document['categories'] as List)
        .map(Category.fromJson)
        .toList();
    final budgets = (document['budgets'] as List).map(Budget.fromJson).toList();
    final preferences = LedgerSettings.fromJson(document['settings']);
    for (final table in ['entries', 'budgets', 'categories', 'accounts']) {
      await _db.customStatement('DELETE FROM $table WHERE ws=?', [target]);
    }
    await _putMetadata(target, accounts, categories, budgets);
    await _db.customStatement(
      'INSERT INTO entries($_entryColumns) SELECT ?,id,type,amount,fee,date,account_id,to_account_id,category_id,note,note_fold,created_at,position FROM staged_entries WHERE token=?',
      [target, preview.token],
    );
    await _db.customStatement(
      'UPDATE workspaces SET settings=?,started=1,sequence=sequence+1,dirty=?${cloudRevision == null ? '' : ',cloud_revision=?'} WHERE key=?',
      [
        jsonEncode(preferences.toJson()),
        cloudRevision != null || target == 'guest' ? 0 : 1,
        ?cloudRevision,
        target,
      ],
    );
    await _db.customStatement('DELETE FROM staged_entries WHERE token=?', [
      preview.token,
    ]);
    await _db.customStatement('DELETE FROM imports WHERE token=?', [
      preview.token,
    ]);
  }

  @override
  Future<List<BackupInfo>> listBackups() async =>
      (await _rows('SELECT * FROM backups ORDER BY date DESC,id DESC LIMIT 10'))
          .map(
            (r) => BackupInfo(
              id: r.read<String>('id'),
              label: r.read<String>('label'),
              date: r.read<String>('date'),
              path: r.read<String>('path'),
              transactionCount: r.read<int>('count'),
            ),
          )
          .toList();
  @override
  Future<void> restoreBackup(
    BackupInfo backup, {
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _exclusive(() async {
    final rows = await _rows('SELECT id FROM backups WHERE id=? AND path=?', [
      backup.id,
      backup.path,
    ]);
    if (rows.isEmpty) throw const LedgerException('备份不存在');
    final preview = await previewImport(
      backup.path,
      expectedWorkspace: expectedWorkspace,
      expectedSequence: expectedSequence,
    );
    await importAtomic(
      preview,
      label: '恢复备份前账本',
      expectedWorkspace: expectedWorkspace,
      expectedSequence: expectedSequence,
    );
  });

  Stream<LedgerTransaction> _allEntries() async* {
    var position = -1;
    while (true) {
      final rows = await _rows(
        'SELECT * FROM entries WHERE ws=? AND position>? ORDER BY position LIMIT 500',
        [_workspace, position],
      );
      if (rows.isEmpty) break;
      for (final r in rows) {
        yield _entry(r);
      }
      position = rows.last.read<int>('position');
    }
  }

  Stream<LedgerTransaction> _filteredEntries(LedgerFilter filter) async* {
    final w = await _where(filter);
    var offset = 0;
    while (true) {
      final rows = await _rows(
        'SELECT t.* $_join WHERE ${w.sql} ORDER BY t.date DESC,t.position ASC,t.id ASC LIMIT 500 OFFSET ?',
        [...w.args, offset],
      );
      if (rows.isEmpty) break;
      for (final r in rows) {
        yield _entry(r);
      }
      offset += rows.length;
    }
  }

  @override
  Future<void> _writeJson(File file, {LedgerFilter? filter}) async {
    final accounts = await listAccounts(),
        categories = await listCategories(),
        budgets = await listBudgets(),
        preferences = await settings();
    final unconstrained =
        filter == null ||
        (filter.types.isEmpty &&
            filter.amountOp.isEmpty &&
            filter.categoryIds.isEmpty &&
            filter.subIds.isEmpty &&
            filter.note.trim().isEmpty &&
            filter.start.isEmpty &&
            filter.end.isEmpty &&
            filter.accountIds.isEmpty);
    final out = file.openWrite();
    try {
      out.write(
        '{"version":1,"started":true,"accounts":${jsonEncode(accounts.map((a) => a.toJson()).toList())},"categories":${jsonEncode(categories.map((c) => c.toJson()).toList())},"transactions":[',
      );
      var first = true, count = 0;
      final chunk = StringBuffer();
      await for (final t
          in unconstrained ? _allEntries() : _filteredEntries(filter)) {
        if (!first) chunk.write(',');
        first = false;
        chunk.write(jsonEncode(t.toJson()));
        if (++count % 500 == 0) {
          out.write(chunk.toString());
          chunk.clear();
          await out.flush();
        }
      }
      out.write(chunk.toString());
      out.write(
        '],"budgets":${jsonEncode(budgets.map((b) => b.toJson()).toList())},"settings":${jsonEncode(preferences.toJson())}}',
      );
      await out.flush();
    } finally {
      await out.close();
    }
  }

  @override
  Future<void> exportFile(
    String path, {
    ExportFormat format = ExportFormat.json,
    LedgerFilter filter = const LedgerFilter(),
    bool cloudCompatible = false,
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _exclusive(() async {
    final file = File(path), temp = File('$path.${const Uuid().v4()}.tmp');
    await file.parent.create(recursive: true);
    try {
      await _transaction(() async {
        await _checkScope(expectedWorkspace, expectedSequence);
        if (cloudCompatible &&
            (await meta()).transactionCount > cloudTransactionLimit) {
          throw const LedgerException('云端最多支持两万笔，请先导出本机备份');
        }
        if (format == ExportFormat.json) {
          await _writeJson(temp, filter: filter);
        } else {
          final accounts = {for (final a in await listAccounts()) a.id: a},
              categories = {for (final c in await listCategories()) c.id: c};
          if (format == ExportFormat.csv) {
            await writeCsv(
              temp,
              _filteredEntries(filter),
              accounts,
              categories,
            );
          } else {
            await writeXlsx(
              temp,
              _filteredEntries(filter),
              accounts,
              categories,
            );
          }
        }
        if (cloudCompatible && await temp.length() > cloudByteLimit) {
          throw const LedgerException('云端账本不能超过8MB');
        }
      });
      await atomicReplaceFile(temp.path, path);
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  });
  @override
  Future<Map<String, Object?>> cloudSnapshot({
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _exclusive(() async {
    final file = File(
      p.join(_directory.path, 'cloud-${const Uuid().v4()}.json'),
    );
    try {
      await exportFile(
        file.path,
        cloudCompatible: true,
        expectedWorkspace: expectedWorkspace,
        expectedSequence: expectedSequence,
      );
      return await compute(_decodeSnapshotFile, file.path);
    } finally {
      if (await file.exists()) await file.delete();
    }
  });

  @override
  Future<void> replaceSnapshot(
    Map<String, Object?> snapshot, {
    String? workspace,
    int? cloudRevision,
    String? expectedSourceWorkspace,
    int? expectedSequence,
    int? expectedTargetSequence,
    String label = '同步前备份',
  }) => _exclusive(() async {
    if (expectedSequence != null &&
        (await meta()).sequence != expectedSequence) {
      throw const LedgerConflict();
    }
    final preview = await previewJson(
      await compute(_encodeSnapshot, snapshot),
      maxTransactions: cloudTransactionLimit,
      expectedWorkspace: expectedSourceWorkspace,
      expectedSequence: expectedSequence,
    );
    if (expectedSequence != null &&
        preview.expectedSequence != expectedSequence) {
      await discardImport(preview);
      throw const LedgerConflict();
    }
    final source = _workspace, target = workspace ?? source;
    var removed = <String>[];
    final created = <String>[];
    try {
      await _transaction(() async {
        await _checkScope(expectedSourceWorkspace, expectedSequence);
        final current = await workspaceMeta(source);
        if (current.sequence != preview.expectedSequence) {
          throw const LedgerConflict();
        }
        if (cloudRevision != null && cloudRevision < 0) {
          throw const LedgerException('云端版本无效');
        }
        await _backup(label, created);
        if (target != source) {
          await _ensureWorkspace(target);
          final targetMeta = await workspaceMeta(target);
          if (expectedTargetSequence != null &&
              targetMeta.sequence != expectedTargetSequence) {
            throw const LedgerConflict();
          }
          await runZoned(
            () => _backup('替换前账户账本', created),
            zoneValues: {_workspaceZone: target},
          );
        }
        await _applyStaged(preview, target, cloudRevision: cloudRevision);
        removed = await _trimBackupMetadata();
        await _db.customStatement(
          "UPDATE app_meta SET value=? WHERE key='active'",
          [target],
        );
        await _commitHook?.call('replace');
      });
    } catch (error, stack) {
      await _rethrowAfterBackupCleanup(
        created,
        error,
        stack,
        extraCleanup: () => discardImport(preview),
      );
    }
    _activeWorkspace = target;
    _events.add((await meta()).sequence);
    await _finishBackupCleanup(removed);
  });
  @override
  Future<BackupInfo> backupSnapshot(
    Map<String, Object?> snapshot, {
    String label = '云端账本备份',
  }) => _exclusive(() async {
    final preview = await previewJson(
      await compute(_encodeSnapshot, snapshot),
      maxTransactions: cloudTransactionLimit,
    );
    final id = const Uuid().v4(),
        date = DateTime.now().toUtc().toIso8601String();
    final encoded = await compute(_encodeSnapshot, snapshot);
    final created = <String>[];
    var removed = <String>[];
    late File file;
    var committed = false;
    try {
      await _transaction(() async {
        final directory = await _ownedBackupDirectory(create: true);
        file = File(p.join(directory.path, '$id.json'));
        await file.create(exclusive: true);
        created.add(file.path);
        await file.writeAsString(encoded, flush: true);
        await _db.customStatement(
          'INSERT INTO backups(id,label,date,path,count) VALUES(?,?,?,?,?)',
          [id, label, date, file.path, preview.transactionCount],
        );
        removed = await _trimBackupMetadata();
        await _commitHook?.call('backup');
      });
      committed = true;
      await _finishBackupCleanup(removed, ledgerChanged: false);
      await discardImport(preview);
      return BackupInfo(
        id: id,
        label: label,
        date: date,
        path: file.path,
        transactionCount: preview.transactionCount,
      );
    } catch (error, stack) {
      await _rethrowAfterBackupCleanup(
        committed ? const [] : created,
        error,
        stack,
        extraCleanup: () => discardImport(preview),
      );
    }
  });
  @override
  Future<void> setCloudRevision(
    int revision, {
    bool dirty = false,
    int? expectedSequence,
    String? workspace,
    String? expectedWorkspace,
  }) => _exclusive(() async {
    if (revision < 0) throw const LedgerException('云端版本号无效');
    await _transaction(() async {
      await _checkScope(expectedWorkspace, null);
      final key = workspace ?? _workspace;
      final current = await workspaceMeta(key);
      final clean =
          !dirty &&
          expectedSequence != null &&
          expectedSequence == current.sequence;
      await _db.customStatement(
        'UPDATE workspaces SET cloud_revision=?,dirty=? WHERE key=?',
        [revision, clean ? 0 : 1, key],
      );
    });
    _events.add((await meta()).sequence);
  });
}
