import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart'
    show
        visibleForTesting,
        compute,
        FlutterError,
        FlutterErrorDetails,
        ErrorDescription;

import '../domain/ledger_defaults.dart';
import 'json_stream.dart';
import 'ledger_exports.dart';
import 'ledger_repository.dart';
import 'safe_files.dart';

part 'sqlite_queries.dart';
part 'sqlite_mutations.dart';
part 'sqlite_snapshots.dart';
part 'sqlite_backups.dart';

class _Database extends GeneratedDatabase {
  _Database(super.executor);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      for (final statement in _schema) {
        await customStatement(statement);
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys=ON');
      await customStatement('PRAGMA busy_timeout=5000');
      await customStatement('PRAGMA journal_mode=WAL');
      await customStatement('PRAGMA synchronous=FULL');
    },
  );
}

const _schema = [
  'CREATE TABLE app_meta (key TEXT PRIMARY KEY,value TEXT NOT NULL)',
  'CREATE TABLE workspaces (key TEXT PRIMARY KEY, sequence INTEGER NOT NULL DEFAULT 0, cloud_revision INTEGER, dirty INTEGER NOT NULL DEFAULT 0, started INTEGER NOT NULL DEFAULT 1, settings TEXT NOT NULL)',
  'CREATE TABLE accounts (ws TEXT NOT NULL,id TEXT NOT NULL,name TEXT NOT NULL,kind TEXT NOT NULL,opening_balance INTEGER NOT NULL,archived INTEGER NOT NULL,position INTEGER NOT NULL,PRIMARY KEY(ws,id),FOREIGN KEY(ws) REFERENCES workspaces(key) ON DELETE CASCADE)',
  'CREATE TABLE categories (ws TEXT NOT NULL,id TEXT NOT NULL,name TEXT NOT NULL,type TEXT NOT NULL,parent_id TEXT,icon TEXT NOT NULL,color TEXT NOT NULL,position INTEGER NOT NULL,PRIMARY KEY(ws,id),FOREIGN KEY(ws) REFERENCES workspaces(key) ON DELETE CASCADE)',
  'CREATE TABLE entries (ws TEXT NOT NULL,id TEXT NOT NULL,type TEXT NOT NULL,amount INTEGER NOT NULL CHECK(amount>0 AND amount<=99999999999),fee INTEGER NOT NULL CHECK(fee>=0 AND fee<=99999999999),date TEXT NOT NULL,account_id TEXT NOT NULL,to_account_id TEXT NOT NULL,category_id TEXT NOT NULL,note TEXT NOT NULL,note_fold TEXT NOT NULL,created_at TEXT NOT NULL,position INTEGER NOT NULL,PRIMARY KEY(ws,id),FOREIGN KEY(ws,account_id) REFERENCES accounts(ws,id) DEFERRABLE INITIALLY DEFERRED)',
  'CREATE INDEX entries_date ON entries(ws,date DESC,position)',
  'CREATE INDEX entries_position ON entries(ws,position)',
  'CREATE INDEX entries_category ON entries(ws,category_id,date)',
  'CREATE INDEX entries_account ON entries(ws,account_id,date)',
  'CREATE INDEX entries_incoming ON entries(ws,to_account_id,date)',
  'CREATE TABLE budgets (ws TEXT NOT NULL,month TEXT NOT NULL,category_id TEXT NOT NULL,amount INTEGER NOT NULL,threshold INTEGER NOT NULL,position INTEGER NOT NULL,PRIMARY KEY(ws,month,category_id),FOREIGN KEY(ws) REFERENCES workspaces(key) ON DELETE CASCADE)',
  'CREATE TABLE imports (token TEXT PRIMARY KEY,ws TEXT NOT NULL,sequence INTEGER NOT NULL,metadata TEXT NOT NULL,count INTEGER NOT NULL,created TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)',
  'CREATE TABLE staged_entries (token TEXT NOT NULL,id TEXT NOT NULL,type TEXT NOT NULL,amount INTEGER NOT NULL,fee INTEGER NOT NULL,date TEXT NOT NULL,account_id TEXT NOT NULL,to_account_id TEXT NOT NULL,category_id TEXT NOT NULL,note TEXT NOT NULL,note_fold TEXT NOT NULL,created_at TEXT NOT NULL,position INTEGER NOT NULL,PRIMARY KEY(token,id))',
  'CREATE TABLE backups (id TEXT PRIMARY KEY,label TEXT NOT NULL,date TEXT NOT NULL,path TEXT NOT NULL,count INTEGER NOT NULL)',
];

final Object _workspaceZone = Object();
final Object _lockZone = Object();
final Object _transactionZone = Object();
final Object _readZone = Object();
const _entryColumns =
    'ws,id,type,amount,fee,date,account_id,to_account_id,category_id,note,note_fold,created_at,position';
const _marks = '?,?,?,?,?,?,?,?,?,?,?,?,?';

abstract class _RepositoryCore extends LedgerRepository {
  _RepositoryCore._(this._db, this._directory, this._activeWorkspace);
  final _Database _db;
  final Directory _directory;
  String _activeWorkspace;
  String get _workspace =>
      Zone.current[_workspaceZone] as String? ?? _activeWorkspace;
  set _workspace(String value) => _activeWorkspace = value;
  final _events = StreamController<int>.broadcast();
  final _budgetEvents = StreamController<String>.broadcast();
  Future<void> _tail = Future.value();
  Future<void> Function(String phase)? _commitHook;
  Future<void> Function(String sql)? _readHook;
  Future<void> Function(String path)? _backupDeleteHook;
  String? _storageWarning;
  bool _closed = false;
  Future<T> _exclusive<T>(Future<T> Function() action) {
    if (Zone.current[_lockZone] == this) return action();
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return () async {
      await previous;
      try {
        if (_closed) throw const LedgerException('账本已经关闭');
        return await runZoned(action, zoneValues: {_lockZone: this});
      } finally {
        done.complete();
      }
    }();
  }

  Future<T> _transaction<T>(Future<T> Function() action) {
    if (Zone.current[_transactionZone] == this) return action();
    return _db.transaction(
      () => runZoned(action, zoneValues: {_transactionZone: this}),
    );
  }

  Future<T> _readSnapshot<T>(
    Future<T> Function() action, {
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _exclusive(() async {
    if (Zone.current[_readZone] == this) {
      await _checkScope(expectedWorkspace, expectedSequence);
      return action();
    }
    final workspace = _workspace;
    Future<T> read() => runZoned(
      () async {
        await _checkScope(expectedWorkspace, expectedSequence);
        return action();
      },
      zoneValues: {
        _readZone: this,
        _workspaceZone: workspace,
        _transactionZone: this,
      },
    );
    if (Zone.current[_transactionZone] == this) return read();
    // Drift's native transaction uses BEGIN IMMEDIATE. Pure reads instead hold
    // only this executor and a deferred SQLite snapshot, allowing WAL writers.
    return _db.exclusively(() async {
      await _db.customStatement('BEGIN DEFERRED');
      try {
        final result = await read();
        await _db.customStatement('COMMIT');
        return result;
      } catch (error, stack) {
        try {
          await _db.customStatement('ROLLBACK');
        } catch (rollback) {
          throw LedgerException('读取失败: $error；回滚失败: $rollback');
        }
        Error.throwWithStackTrace(error, stack);
      }
    });
  });

  List<Variable> _variables(List<Object> args) => args
      .map(
        (v) =>
            v is int ? Variable.withInt(v) : Variable.withString(v as String),
      )
      .toList();
  Future<List<QueryRow>> _rows(
    String sql, [
    List<Object> args = const [],
  ]) async {
    final rows = await _db.customSelect(sql, variables: _variables(args)).get();
    await _readHook?.call(sql);
    return rows;
  }

  Future<QueryRow> _one(String sql, [List<Object> args = const []]) async {
    final rows = await _rows(sql, args);
    if (rows.isEmpty) throw const LedgerException('账本数据不存在');
    return rows.first;
  }

  Future<void> _ensureWorkspace(String key) async {
    if (key != 'guest' &&
        (!key.startsWith('user:') || key.length <= 5 || key.length > 250)) {
      throw const LedgerException('工作区无效');
    }
    await _transaction(() async {
      await _db.customStatement(
        'INSERT OR IGNORE INTO workspaces(key,settings) VALUES(?,?)',
        [
          key,
          jsonEncode(const LedgerSettings(defaultAccount: 'bank').toJson()),
        ],
      );
      final row = await _one('SELECT COUNT(*) AS n FROM accounts WHERE ws=?', [
        key,
      ]);
      if (row.read<int>('n') == 0) {
        await _putMetadata(key, defaultAccounts, defaultCategories(), const []);
      }
    });
  }

  @override
  Stream<int> get changes => _events.stream;
  @override
  Stream<String> get budgetNotifications => _budgetEvents.stream;
  @override
  Future<void> close() async {
    await _tail;
    if (_closed) return;
    _closed = true;
    await _events.close();
    await _budgetEvents.close();
    await _db.close();
  }

  @override
  Future<void> switchWorkspace(
    String workspace, {
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _exclusive(() async {
    await _transaction(() async {
      await _checkScope(expectedWorkspace, expectedSequence);
      await _ensureWorkspace(workspace);
      await _db.customStatement(
        "UPDATE app_meta SET value=? WHERE key='active'",
        [workspace],
      );
    });
    _workspace = workspace;
    _events.add((await meta()).sequence);
  });
  @override
  Future<WorkspaceMeta> meta() => workspaceMeta(_workspace);
  @override
  Future<WorkspaceMeta> workspaceMeta(String workspace) async {
    final row = await _one(
      'SELECT w.*, (SELECT COUNT(*) FROM entries e WHERE e.ws=w.key) AS n FROM workspaces w WHERE key=?',
      [workspace],
    );
    return WorkspaceMeta(
      key: workspace,
      sequence: row.read<int>('sequence'),
      transactionCount: row.read<int>('n'),
      cloudRevision: row.readNullable<int>('cloud_revision'),
      dirty: row.read<int>('dirty') != 0,
    );
  }

  @override
  Future<List<WorkspaceMeta>> listWorkspaces() => _readSnapshot(() async {
    final rows = await _rows('SELECT key FROM workspaces ORDER BY key');
    return Future.wait(rows.map((r) => workspaceMeta(r.read<String>('key'))));
  });

  Account _account(QueryRow r) => Account(
    id: r.read<String>('id'),
    name: r.read<String>('name'),
    kind: r.read<String>('kind'),
    openingBalance: r.read<int>('opening_balance'),
    archived: r.read<int>('archived') != 0,
  );
  Category _category(QueryRow r) => Category(
    id: r.read<String>('id'),
    name: r.read<String>('name'),
    type: EntryType.values.byName(r.read<String>('type')),
    parentId: r.readNullable<String>('parent_id'),
    icon: r.read<String>('icon'),
    color: r.read<String>('color'),
  );
  LedgerTransaction _entry(QueryRow r) => LedgerTransaction(
    id: r.read<String>('id'),
    type: EntryType.values.byName(r.read<String>('type')),
    amount: r.read<int>('amount'),
    fee: r.read<int>('fee'),
    date: r.read<String>('date'),
    accountId: r.read<String>('account_id'),
    toAccountId: r.read<String>('to_account_id'),
    categoryId: r.read<String>('category_id'),
    note: r.read<String>('note'),
    createdAt: r.read<String>('created_at'),
  );
  @override
  Future<List<Account>> listAccounts({
    bool includeArchived = true,
  }) async => (await _rows(
    'SELECT * FROM accounts WHERE ws=? ${includeArchived ? '' : 'AND archived=0'} ORDER BY position',
    [_workspace],
  )).map(_account).toList();
  @override
  Future<List<Category>> listCategories({
    EntryType? type,
  }) async => (await _rows(
    'SELECT * FROM categories WHERE ws=? ${type == null ? '' : 'AND type=?'} ORDER BY position',
    [_workspace, if (type != null) type.name],
  )).map(_category).toList();
  @override
  Future<List<Budget>> listBudgets({String? month}) async =>
      (await _rows(
            'SELECT * FROM budgets WHERE ws=? ${month == null ? '' : 'AND month=?'} ORDER BY position',
            [_workspace, ?month],
          ))
          .map(
            (r) => Budget(
              month: r.read<String>('month'),
              categoryId: r.read<String>('category_id'),
              amount: r.read<int>('amount'),
              threshold: r.read<int>('threshold'),
            ),
          )
          .toList();
  @override
  Future<LedgerSettings> settings() async => LedgerSettings.fromJson(
    jsonDecode(
      (await _one('SELECT settings FROM workspaces WHERE key=?', [
        _workspace,
      ])).read<String>('settings'),
    ),
  );
  Future<void> _checkScope(
    String? expectedWorkspace,
    int? expectedSequence,
  ) async {
    if (expectedWorkspace != null && _workspace != expectedWorkspace) {
      throw const LedgerConflict();
    }
    if (expectedSequence != null &&
        (await meta()).sequence != expectedSequence) {
      throw const LedgerConflict();
    }
  }

  Future<T> _mutate<T>(
    Future<T> Function() action, {
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _exclusive(() async {
    var notices = <String>[];
    final result = await _transaction(() async {
      await _checkScope(expectedWorkspace, expectedSequence);
      final result = await action();
      notices = await _notifyBudgets();
      await _db.customStatement(
        'UPDATE workspaces SET sequence=sequence+1,dirty=? WHERE key=?',
        [_workspace == 'guest' ? 0 : 1, _workspace],
      );
      await _commitHook?.call('save');
      return result;
    });
    _events.add((await meta()).sequence);
    for (final notice in notices) {
      _budgetEvents.add(notice);
    }
    return result;
  });
  Future<List<String>> _notifyBudgets() async {
    final preferences = await settings();
    if (!preferences.notifications) return [];
    final notified = preferences.notified.toSet();
    final notices = <String>[];
    final names = {for (final c in await listCategories()) c.id: c.name};
    for (final status in await budgetStatuses(
      localDateTime().substring(0, 7),
    )) {
      final b = status.budget;
      for (final threshold in {b.threshold, 100}) {
        if (status.spent * 100 >= b.amount * threshold &&
            notified.add('${b.month}:${b.categoryId}:${b.amount}:$threshold')) {
          notices.add(
            '${b.categoryId.isEmpty ? '月度总预算' : names[b.categoryId] ?? '分类预算'}已使用 ${status.percent.round()}%',
          );
        }
      }
    }
    final list = notified.toList();
    if (list.length > 2000) list.removeRange(0, list.length - 2000);
    await _db.customStatement('UPDATE workspaces SET settings=? WHERE key=?', [
      jsonEncode(preferences.copyWith(notified: list).toJson()),
      _workspace,
    ]);
    return notices;
  }

  List<Object?> _entryValues(
    String workspace,
    LedgerTransaction t,
    int position,
  ) => [
    workspace,
    t.id,
    t.type.name,
    t.amount,
    t.fee,
    t.date,
    t.accountId,
    t.toAccountId,
    t.categoryId,
    t.note,
    unicodeLower(t.note),
    t.createdAt,
    position,
  ];
  Future<void> _putMetadata(
    String workspace,
    List<Account> accounts,
    List<Category> categories,
    List<Budget> budgets,
  ) async {
    await _db.batch((batch) {
      for (var i = 0; i < accounts.length; i++) {
        final a = accounts[i];
        batch.customStatement(
          'INSERT INTO accounts(ws,id,name,kind,opening_balance,archived,position) VALUES(?,?,?,?,?,?,?)',
          [
            workspace,
            a.id,
            a.name,
            a.kind,
            a.openingBalance,
            a.archived ? 1 : 0,
            i,
          ],
        );
      }
      for (var i = 0; i < categories.length; i++) {
        final c = categories[i];
        batch.customStatement(
          'INSERT INTO categories(ws,id,name,type,parent_id,icon,color,position) VALUES(?,?,?,?,?,?,?,?)',
          [
            workspace,
            c.id,
            c.name,
            c.type.name,
            c.parentId,
            c.icon,
            c.color,
            i,
          ],
        );
      }
      for (var i = 0; i < budgets.length; i++) {
        final b = budgets[i];
        batch.customStatement(
          'INSERT INTO budgets(ws,month,category_id,amount,threshold,position) VALUES(?,?,?,?,?,?)',
          [workspace, b.month, b.categoryId, b.amount, b.threshold, i],
        );
      }
    });
  }

  @visibleForTesting
  Future<int> pageCountForTesting() async =>
      (await _one('PRAGMA page_count')).read<int>('page_count');
  @visibleForTesting
  Future<void> setPageLimitForTesting(int pages) async {
    if (pages < 1) throw ArgumentError.value(pages);
    await _db.customStatement('PRAGMA max_page_count=$pages');
  }

  Future<({String sql, List<Object> args})> _where(LedgerFilter filter);
  String get _join;
  Future<void> _backup(String label, List<String> created);
  Future<void> _finishBackupCleanup(
    List<String> paths, {
    bool ledgerChanged = true,
  });
  Future<Directory> _ownedBackupDirectory({bool create = false});
  Future<Never> _rethrowAfterBackupCleanup(
    List<String> created,
    Object original,
    StackTrace stack, {
    Future<void> Function()? extraCleanup,
  });
  Future<List<String>> _trimBackupMetadata();
  Future<void> _writeJson(File file);
}

class SqliteLedgerRepository extends _RepositoryCore
    with
        _RepositoryQueries,
        _RepositoryMutations,
        _RepositoryBackups,
        _RepositorySnapshots {
  SqliteLedgerRepository._(super.db, super.directory, super.activeWorkspace)
    : super._();
  static Future<SqliteLedgerRepository> connect({
    String? path,
    String? workspace,
    Future<void> Function(String phase)? beforeCommit,
    Future<void> Function(String sql)? afterRead,
    Future<void> Function(String path)? beforeBackupDelete,
  }) async {
    final file = File(
      path ??
          p.join(
            (await getApplicationSupportDirectory()).path,
            'jianzhang.sqlite',
          ),
    );
    await file.parent.create(recursive: true);
    final db = _Database(NativeDatabase.createInBackground(file));
    final repo = SqliteLedgerRepository._(
      db,
      file.parent,
      workspace ?? 'guest',
    );
    repo._commitHook = beforeCommit;
    repo._readHook = afterRead;
    repo._backupDeleteHook = beforeBackupDelete;
    try {
      final active = await repo._rows(
        "SELECT value FROM app_meta WHERE key='active'",
      );
      repo._workspace =
          workspace ??
          (active.isEmpty ? 'guest' : active.first.read<String>('value'));
      await repo._ensureWorkspace(repo._workspace);
      await db.customStatement(
        "INSERT INTO app_meta(key,value) VALUES('active',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        [repo._workspace],
      );
      await db.customStatement(
        "DELETE FROM staged_entries WHERE token IN (SELECT token FROM imports WHERE created<datetime('now','-1 day'))",
      );
      await db.customStatement(
        "DELETE FROM imports WHERE created<datetime('now','-1 day')",
      );
      await repo._cleanupOrphanBackups();
      return repo;
    } catch (_) {
      await db.close();
      rethrow;
    }
  }
}

String _encodeSnapshot(Map<String, Object?> snapshot) => jsonEncode(snapshot);
Future<Map<String, Object?>> _decodeSnapshotFile(String path) async =>
    jsonObject(jsonDecode(await File(path).readAsString()));
