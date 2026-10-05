part of 'sqlite_ledger_repository.dart';

mixin _RepositoryQueries on _RepositoryCore {
  @override
  Future<LedgerTransaction?> transactionById(
    String id, {
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _readSnapshot(
    () async {
      final rows = await _rows('SELECT * FROM entries WHERE ws=? AND id=?', [
        _workspace,
        id,
      ]);
      return rows.isEmpty ? null : _entry(rows.single);
    },
    expectedWorkspace: expectedWorkspace,
    expectedSequence: expectedSequence,
  );

  @override
  Future<LedgerReadViewData> readViewData({
    required String month,
    LedgerFilter filter = const LedgerFilter(),
    int recentLimit = 12,
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _readSnapshot(
    () async {
      final current = await meta();
      final accounts = await listAccounts();
      final categories = await listCategories();
      final budgets = await budgetStatuses(month);
      final accountBalances = await balances();
      final preferences = await settings();
      final totals = await summary(filter: filter);
      final recent = await search(filter, limit: recentLimit);
      return LedgerReadViewData(
        meta: current,
        accounts: List.unmodifiable(accounts),
        categories: List.unmodifiable(categories),
        budgets: List.unmodifiable(budgets),
        balances: Map.unmodifiable(accountBalances),
        settings: preferences,
        summary: totals,
        recent: recent,
        storageWarning: _storageWarning,
      );
    },
    expectedWorkspace: expectedWorkspace,
    expectedSequence: expectedSequence,
  );

  @override
  Future<({String sql, List<Object> args})> _where(LedgerFilter f) async {
    final terms = <String>['t.ws=?'], args = <Object>[_workspace];
    String inside(List<Object> values) {
      args.addAll(values);
      return List.filled(values.length, '?').join(',');
    }

    final includeFee =
        f.includeFees &&
        f.types.contains(EntryType.expense) &&
        !f.types.contains(EntryType.transfer);
    final feeOnly = includeFee ? "(t.type='transfer' AND t.fee>0)" : '0';
    if (f.types.isNotEmpty) {
      terms.add(
        '(t.type IN (${inside(f.types.map((t) => t.name).toList())})${includeFee ? ' OR $feeOnly' : ''})',
      );
    }
    if (f.start.isNotEmpty) {
      if (!validDate('${f.start}T00:00')) throw const LedgerException('开始日期无效');
      terms.add('t.date>=?');
      args.add('${f.start}T00:00');
    }
    if (f.end.isNotEmpty) {
      if (!validDate('${f.end}T23:59')) throw const LedgerException('结束日期无效');
      terms.add('t.date<=?');
      args.add('${f.end}T23:59');
    }
    if (f.start.isNotEmpty &&
        f.end.isNotEmpty &&
        f.start.compareTo(f.end) > 0) {
      throw const LedgerException('开始日期不能晚于结束日期');
    }
    if (f.categoryIds.isNotEmpty) {
      terms.add('c.parent_id IN (${inside(f.categoryIds)})');
    }
    if (f.subIds.isNotEmpty) {
      if (f.categoryIds.isEmpty) {
        terms.add('t.category_id IN (${inside(f.subIds)})');
      } else {
        final categories = await listCategories();
        final parents = categories
            .where((c) => f.subIds.contains(c.id) && c.parentId != null)
            .map((c) => c.parentId!)
            .toSet()
            .toList();
        if (parents.isNotEmpty) {
          terms.add(
            '(c.parent_id IS NULL OR c.parent_id NOT IN (${inside(parents)}) OR t.category_id IN (${inside(f.subIds)}))',
          );
        }
      }
    }
    if (f.accountIds.isNotEmpty) {
      if (f.accountMode == 'in') {
        terms.add(
          "(t.type='transfer' AND NOT $feeOnly AND t.to_account_id IN (${inside(f.accountIds)}))",
        );
      } else {
        final out = 't.account_id IN (${inside(f.accountIds)})';
        if (f.accountMode == 'out') {
          terms.add(out);
        } else {
          terms.add(
            "($out OR (t.type='transfer' AND NOT $feeOnly AND t.to_account_id IN (${inside(f.accountIds)})))",
          );
        }
      }
    }
    if (f.note.trim().isNotEmpty) {
      final words = unicodeLower(f.note).trim().split(RegExp(r'\s+'));
      terms.add(
        '(${words.map((word) {
          args.add(word);
          return 'instr(t.note_fold,?)>0';
        }).join(f.noteMode == 'any' ? ' OR ' : ' AND ')})',
      );
    }
    if (f.amountOp.isNotEmpty && f.amountOp != 'none') {
      if (f.amountMin.isEmpty) throw const LedgerException('请填写金额条件');
      final min = parseMoney(f.amountMin, allowZero: true);
      final amount = 'CASE WHEN $feeOnly THEN t.fee ELSE t.amount END';
      switch (f.amountOp) {
        case 'eq':
          terms.add('($amount)=?');
          args.add(min);
        case 'gt':
          terms.add('($amount)>?');
          args.add(min);
        case 'lt':
          terms.add('($amount)<?');
          args.add(min);
        case 'range':
          final max = parseMoney(f.amountMax, allowZero: true);
          if (max < min) throw const LedgerException('金额区间无效');
          terms.add('($amount) BETWEEN ? AND ?');
          args.addAll([min, max]);
        default:
          throw const LedgerException('金额条件无效');
      }
    }
    return (sql: terms.join(' AND '), args: args);
  }

  @override
  String get _join =>
      'FROM entries t LEFT JOIN categories c ON c.ws=t.ws AND c.id=t.category_id';
  @override
  Future<TransactionPage> search(
    LedgerFilter filter, {
    int offset = 0,
    int limit = 50,
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _readSnapshot(
    () async {
      if (offset < 0 || limit < 1 || limit > 500) {
        throw const LedgerException('分页参数无效');
      }
      final w = await _where(filter);
      final total = (await _one(
        'SELECT COUNT(*) AS n $_join WHERE ${w.sql}',
        w.args,
      )).read<int>('n');
      final rows = await _rows(
        'SELECT t.* $_join WHERE ${w.sql} ORDER BY t.date DESC,t.position ASC,t.id ASC LIMIT ? OFFSET ?',
        [...w.args, limit, offset],
      );
      return TransactionPage(
        items: rows.map(_entry).toList(),
        total: total,
        offset: offset,
        limit: limit,
      );
    },
    expectedWorkspace: expectedWorkspace,
    expectedSequence: expectedSequence,
  );

  @override
  Future<LedgerSummary> summary({
    LedgerFilter filter = const LedgerFilter(),
  }) => _readSnapshot(() async {
    final w = await _where(filter);
    final r = await _one(
      "SELECT COALESCE(SUM(CASE WHEN t.type='income' THEN t.amount ELSE 0 END),0) AS income,COALESCE(SUM(CASE WHEN t.type='expense' THEN t.amount WHEN t.type='transfer' THEN t.fee ELSE 0 END),0) AS expense,COUNT(*) AS n $_join WHERE ${w.sql}",
      w.args,
    );
    return LedgerSummary(
      income: r.read<int>('income'),
      expense: r.read<int>('expense'),
      count: r.read<int>('n'),
    );
  });

  @override
  Future<Map<String, int>> balances() => _readSnapshot(() async {
    final rows = await _rows(
      "SELECT a.id,a.opening_balance+COALESCE((SELECT SUM(CASE WHEN t.type='income' THEN t.amount ELSE -t.amount-CASE WHEN t.type='transfer' THEN t.fee ELSE 0 END END) FROM entries t WHERE t.ws=a.ws AND t.account_id=a.id),0)+COALESCE((SELECT SUM(t.amount) FROM entries t WHERE t.ws=a.ws AND t.type='transfer' AND t.to_account_id=a.id),0) AS balance FROM accounts a WHERE a.ws=?",
      [_workspace],
    );
    return {
      for (final row in rows) row.read<String>('id'): row.read<int>('balance'),
    };
  });

  Future<List<CategoryTotal>> _totals(
    String start,
    String end,
    EntryType type, {
    bool children = false,
  }) async {
    final parent = children ? 'c' : 'p';
    final rows = await _rows(
      "SELECT $parent.*,SUM(CASE WHEN t.type='transfer' THEN t.fee ELSE t.amount END) AS total FROM entries t JOIN categories c ON c.ws=t.ws AND c.id=t.category_id JOIN categories p ON p.ws=c.ws AND p.id=c.parent_id WHERE t.ws=? AND t.date>=? AND t.date<=? AND (t.type=? ${type == EntryType.expense ? "OR (t.type='transfer' AND t.fee>0)" : ''}) GROUP BY $parent.id HAVING total>0 ORDER BY total DESC,$parent.position",
      [_workspace, '${start}T00:00', '${end}T23:59', type.name],
    );
    return rows
        .map(
          (r) => CategoryTotal(
            category: _category(r),
            amount: r.read<int>('total'),
          ),
        )
        .toList();
  }

  @override
  Future<LedgerStatistics> statistics({
    required String start,
    required String end,
    EntryType type = EntryType.expense,
    bool monthly = false,
    String? expectedWorkspace,
    int? expectedSequence,
  }) => _readSnapshot(
    () async {
      final sum = await summary(
        filter: LedgerFilter(start: start, end: end),
      );
      final categories = await _totals(start, end, type),
          children = await _totals(start, end, type, children: true);
      final first = DateTime.parse('${start}T12:00:00'),
          last = DateTime.parse('${end}T12:00:00');
      final days = (last.difference(first).inHours / 24).round() + 1;
      final group = (days / 60).ceil().clamp(1, 100000);
      final trend = <TrendBucket>[];
      if (monthly) {
        var cursor = DateTime(first.year, first.month, 1);
        while (!cursor.isAfter(last)) {
          final monthEnd = DateTime(cursor.year, cursor.month + 1, 0, 12);
          final from = localDateTime(
                cursor.isBefore(first) ? first : cursor,
              ).substring(0, 10),
              to = localDateTime(
                monthEnd.isAfter(last) ? last : monthEnd,
              ).substring(0, 10);
          final total = await summary(
            filter: LedgerFilter(start: from, end: to),
          );
          trend.add(
            TrendBucket(
              start: from,
              end: to,
              income: total.income,
              expense: total.expense,
            ),
          );
          cursor = DateTime(cursor.year, cursor.month + 1, 1);
        }
      } else {
        for (var i = 0; i < days; i += group) {
          final a = first.add(Duration(days: i)),
              b = first.add(Duration(days: (i + group - 1).clamp(0, days - 1)));
          final from = localDateTime(a).substring(0, 10),
              to = localDateTime(b).substring(0, 10);
          final total = await summary(
            filter: LedgerFilter(start: from, end: to),
          );
          trend.add(
            TrendBucket(
              start: from,
              end: to,
              income: total.income,
              expense: total.expense,
            ),
          );
        }
      }
      return LedgerStatistics(
        summary: sum,
        categories: categories,
        subcategories: children,
        trend: trend,
      );
    },
    expectedWorkspace: expectedWorkspace,
    expectedSequence: expectedSequence,
  );

  @override
  Future<List<BudgetStatus>> budgetStatuses(String month) =>
      _readSnapshot(() async {
        final budgets = await listBudgets(month: month);
        if (budgets.isEmpty) return [];
        final start = '$month-01';
        final parts = month.split('-').map(int.parse).toList();
        final end = localDateTime(
          DateTime(parts[0], parts[1] + 1, 0),
        ).substring(0, 10);
        final expense = (await summary(
          filter: LedgerFilter(start: start, end: end),
        )).expense;
        final categories = {
          for (final total in await _totals(start, end, EntryType.expense))
            total.category.id: total.amount,
        };
        return budgets
            .map(
              (b) => BudgetStatus(
                budget: b,
                spent: b.categoryId.isEmpty
                    ? expense
                    : categories[b.categoryId] ?? 0,
              ),
            )
            .toList();
      });
}
