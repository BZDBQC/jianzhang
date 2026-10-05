part of 'sqlite_ledger_repository.dart';

mixin _RepositoryMutations on _RepositoryCore {
  @override
  Future<void> saveTransaction(
    LedgerTransaction entry, {
    bool create = false,
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _mutate(
    () async {
      validateReferences(
        entry,
        (await listAccounts()).map((a) => a.id).toSet(),
        {for (final c in await listCategories()) c.id: c},
      );
      final old = await _rows(
        'SELECT position FROM entries WHERE ws=? AND id=?',
        [_workspace, entry.id],
      );
      if (create && old.isNotEmpty) throw const LedgerException('账单 ID 已存在');
      if (!create && old.isEmpty) {
        throw const LedgerException('此账单已删除，请保留输入并重新记一笔');
      }
      if (create && (await meta()).transactionCount >= localTransactionLimit) {
        throw const LedgerException('本机最多支持十万笔账单');
      }
      final position = old.isEmpty
          ? (await _one(
              'SELECT COALESCE(MAX(position),-1)+1 AS n FROM entries WHERE ws=?',
              [_workspace],
            )).read<int>('n')
          : old.first.read<int>('position');
      await _db.customStatement(
        'INSERT INTO entries($_entryColumns) VALUES($_marks) ON CONFLICT(ws,id) DO UPDATE SET type=excluded.type,amount=excluded.amount,fee=excluded.fee,date=excluded.date,account_id=excluded.account_id,to_account_id=excluded.to_account_id,category_id=excluded.category_id,note=excluded.note,note_fold=excluded.note_fold,created_at=excluded.created_at',
        _entryValues(_workspace, entry, position),
      );
    },
    expectedWorkspace: expectedWorkspace,
    expectedSequence: expectedSequence,
  );
  @override
  Future<void> deleteTransaction(
    String id, {
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _mutate(
    () async {
      final exists = await _rows('SELECT id FROM entries WHERE ws=? AND id=?', [
        _workspace,
        id,
      ]);
      if (exists.isEmpty) throw const LedgerException('账单已经删除');
      await _db.customStatement('DELETE FROM entries WHERE ws=? AND id=?', [
        _workspace,
        id,
      ]);
    },
    expectedWorkspace: expectedWorkspace,
    expectedSequence: expectedSequence,
  );
  @override
  Future<void> upsertAccount(
    Account account, {
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _mutate(
    () => _saveAccount(account),
    expectedWorkspace: expectedWorkspace,
    expectedSequence: expectedSequence,
  );
  Future<void> _saveAccount(Account account) async {
    account.validate();
    final existing = await listAccounts();
    if (existing.any(
      (a) => a.id != account.id && a.name == account.name.trim(),
    )) {
      throw const LedgerException('账户名称已存在');
    }
    if (existing.every((a) => a.id != account.id) && existing.length >= 100) {
      throw const LedgerException('账户数量已达上限');
    }
    if (account.archived &&
        !existing.any((a) => a.id != account.id && !a.archived)) {
      throw const LedgerException('请至少保留一个可用账户');
    }
    await _db.customStatement(
      'INSERT INTO accounts(ws,id,name,kind,opening_balance,archived,position) VALUES(?,?,?,?,?,?,?) ON CONFLICT(ws,id) DO UPDATE SET name=excluded.name,kind=excluded.kind,opening_balance=excluded.opening_balance,archived=excluded.archived',
      [
        _workspace,
        account.id,
        account.name.trim(),
        account.kind,
        account.openingBalance,
        account.archived ? 1 : 0,
        existing.length,
      ],
    );
    if (account.archived && (await settings()).defaultAccount == account.id) {
      final next = existing.firstWhere(
        (a) => a.id != account.id && !a.archived,
      );
      await _db
          .customStatement('UPDATE workspaces SET settings=? WHERE key=?', [
            jsonEncode(
              (await settings()).copyWith(defaultAccount: next.id).toJson(),
            ),
            _workspace,
          ]);
    }
  }

  @override
  Future<void> archiveAccount(
    String id,
    bool archived, {
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _mutate(
    () async {
      final accounts = await listAccounts();
      final matches = accounts.where((a) => a.id == id);
      if (matches.isEmpty) throw const LedgerException('账户不存在');
      await _saveAccount(matches.first.copyWith(archived: archived));
    },
    expectedWorkspace: expectedWorkspace,
    expectedSequence: expectedSequence,
  );

  @override
  Future<void> upsertCategory(
    Category category, {
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _mutate(
    () async {
      category.validate();
      final categories = await listCategories();
      final old = categories.where((c) => c.id == category.id);
      if (old.isNotEmpty &&
          (old.first.type != category.type ||
              old.first.parentId != category.parentId)) {
        throw const LedgerException('已有分类不能更改层级或收支类型');
      }
      if (categories.any(
        (c) =>
            c.id != category.id &&
            c.type == category.type &&
            c.parentId == category.parentId &&
            c.name == category.name.trim(),
      )) {
        throw const LedgerException('此层级已有同名分类');
      }
      if (old.isEmpty && categories.length >= 1000) {
        throw const LedgerException('分类数量已达上限');
      }
      validateMetadata(
        await listAccounts(),
        [...categories.where((c) => c.id != category.id), category],
        await listBudgets(),
        await settings(),
      );
      await _db.customStatement(
        'INSERT INTO categories(ws,id,name,type,parent_id,icon,color,position) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(ws,id) DO UPDATE SET name=excluded.name,icon=excluded.icon,color=excluded.color',
        [
          _workspace,
          category.id,
          category.name.trim(),
          category.type.name,
          category.parentId,
          category.icon,
          category.color,
          categories.length,
        ],
      );
      if (category.parentId == null) {
        await _db.customStatement(
          'UPDATE categories SET color=? WHERE ws=? AND parent_id=?',
          [category.color, _workspace, category.id],
        );
      }
    },
    expectedWorkspace: expectedWorkspace,
    expectedSequence: expectedSequence,
  );
  @override
  Future<void> deleteCategory(
    String id, {
    String? reassignTo,
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _mutate(
    () async {
      final categories = await listCategories(),
          found = categories.where((c) => c.id == id);
      if (found.isEmpty) throw const LedgerException('分类不存在');
      final removed = found.first,
          ids = [
            id,
            ...categories.where((c) => c.parentId == id).map((c) => c.id),
          ];
      final marks = List.filled(ids.length, '?').join(',');
      final used = (await _one(
        'SELECT COUNT(*) AS n FROM entries WHERE ws=? AND category_id IN ($marks)',
        [_workspace, ...ids],
      )).read<int>('n');
      if (used > 0) {
        final targets = categories.where(
          (c) =>
              c.id == reassignTo &&
              c.parentId != null &&
              c.type == removed.type &&
              !ids.contains(c.id),
        );
        if (targets.isEmpty) throw const LedgerException('请选择同类型的其他小类迁移历史账单');
        await _db.customStatement(
          'UPDATE entries SET category_id=? WHERE ws=? AND category_id IN ($marks)',
          [reassignTo, _workspace, ...ids],
        );
      }
      await _db.customStatement(
        'DELETE FROM budgets WHERE ws=? AND category_id IN ($marks)',
        [_workspace, ...ids],
      );
      await _db.customStatement(
        'DELETE FROM categories WHERE ws=? AND id IN ($marks)',
        [_workspace, ...ids],
      );
    },
    expectedWorkspace: expectedWorkspace,
    expectedSequence: expectedSequence,
  );
  @override
  Future<void> upsertBudget(
    Budget budget, {
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _mutate(
    () async {
      budget.validate();
      final budgets = await listBudgets();
      final next = [
        ...budgets.where(
          (b) => b.month != budget.month || b.categoryId != budget.categoryId,
        ),
        budget,
      ];
      validateMetadata(
        await listAccounts(),
        await listCategories(),
        next,
        await settings(),
      );
      await _db.customStatement(
        'INSERT INTO budgets(ws,month,category_id,amount,threshold,position) VALUES(?,?,?,?,?,?) ON CONFLICT(ws,month,category_id) DO UPDATE SET amount=excluded.amount,threshold=excluded.threshold',
        [
          _workspace,
          budget.month,
          budget.categoryId,
          budget.amount,
          budget.threshold,
          budgets.length,
        ],
      );
    },
    expectedWorkspace: expectedWorkspace,
    expectedSequence: expectedSequence,
  );
  @override
  Future<void> deleteBudget(
    String month,
    String categoryId, {
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _mutate(
    () => _db.customStatement(
      'DELETE FROM budgets WHERE ws=? AND month=? AND category_id=?',
      [_workspace, month, categoryId],
    ),
    expectedWorkspace: expectedWorkspace,
    expectedSequence: expectedSequence,
  );
  @override
  Future<void> updateSettings(
    LedgerSettings preferences, {
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _mutate(
    () async {
      validateMetadata(
        await listAccounts(),
        await listCategories(),
        await listBudgets(),
        preferences,
      );
      await _db.customStatement(
        'UPDATE workspaces SET settings=? WHERE key=?',
        [jsonEncode(preferences.toJson()), _workspace],
      );
    },
    expectedWorkspace: expectedWorkspace,
    expectedSequence: expectedSequence,
  );
}
