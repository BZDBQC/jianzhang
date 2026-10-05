import 'dart:convert';
import 'unicode_case.dart';
export 'unicode_case.dart' show unicodeLower;

const maxMoney = 99999999999;
const localTransactionLimit = 100000;
const cloudTransactionLimit = 20000;
const cloudByteLimit = 8000000;

enum EntryType { expense, income, transfer }

enum ExportFormat { json, csv, xlsx }

class LedgerException implements Exception {
  const LedgerException(this.message);
  final String message;
  @override
  String toString() => message;
}

class LedgerConflict extends LedgerException {
  const LedgerConflict() : super('账本已更新，输入仍保留，请重新读取后核对并保存。');
}

class LedgerBackupCleanupFailure extends LedgerException {
  const LedgerBackupCleanupFailure(
    this.cause, {
    required this.committed,
    this.ledgerChanged = true,
  }) : super(
         committed
             ? (ledgerChanged
                   ? '账本已保存，但旧备份清理失败。请关闭占用文件后重启重试。'
                   : '备份已保存，但旧备份清理失败；账本未更改。请关闭占用文件后重试原操作。')
             : '账本数据仍保留，但残留备份清理失败。请关闭占用文件后重启重试。',
       );
  final Object cause;
  final bool committed;
  final bool ledgerChanged;
  @override
  String toString() => '$message ($cause)';
}

Map<String, Object?> jsonObject(Object? value) {
  if (value is! Map) throw const LedgerException('备份格式不正确');
  return Map<String, Object?>.from(value);
}

String jsonString(Map<String, Object?> m, String key) {
  final value = m[key];
  if (value is! String) throw LedgerException('$key 格式无效');
  return value;
}

int jsonInt(Map<String, Object?> m, String key) {
  final value = m[key];
  if (value is! num ||
      !value.isFinite ||
      value != value.toInt() ||
      value.abs() > 9007199254740991) {
    throw LedgerException('$key 必须是安全整数');
  }
  return value.toInt();
}

bool jsonBool(Map<String, Object?> m, String key) {
  if (m[key] case final bool value) return value;
  throw LedgerException('$key 格式无效');
}

EntryType jsonType(Map<String, Object?> m) {
  return switch (m['type']) {
    'expense' => EntryType.expense,
    'income' => EntryType.income,
    'transfer' => EntryType.transfer,
    _ => throw const LedgerException('账单类型无效'),
  };
}

int parseMoney(String value, {bool allowZero = false}) {
  final text = value.trim();
  if (!RegExp(r'^\d{1,9}(\.\d{1,2})?$').hasMatch(text)) {
    throw const LedgerException('请输入有效金额，最多两位小数');
  }
  final parts = text.split('.');
  final cents =
      int.parse(parts[0]) * 100 +
      int.parse(parts.length == 1 ? '00' : parts[1].padRight(2, '0'));
  if (!allowZero && cents == 0) throw const LedgerException('金额必须大于零');
  return cents;
}

String formatMoney(int cents) {
  final absolute = cents.abs();
  final whole = (absolute ~/ 100).toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return '${cents < 0 ? '-' : ''}$whole.${(absolute % 100).toString().padLeft(2, '0')}';
}

String decimalMoney(int cents) =>
    '${cents < 0 ? '-' : ''}${cents.abs() ~/ 100}.${(cents.abs() % 100).toString().padLeft(2, '0')}';
String localDateTime([DateTime? value]) {
  final d = value ?? DateTime.now();
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}T${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

bool validDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$').hasMatch(value)) return false;
  final p = value.split(RegExp(r'[-T:]')).map(int.parse).toList();
  final d = DateTime.utc(p[0], p[1], p[2], p[3], p[4]);
  return d.year == p[0] &&
      d.month == p[1] &&
      d.day == p[2] &&
      d.hour == p[3] &&
      d.minute == p[4];
}

void validateId(String id) {
  if (id.isEmpty || id.length > 100) throw const LedgerException('数据 ID 缺失或过长');
}

void validateName(String name) {
  if (name.trim().isEmpty || name.length > 60) {
    throw const LedgerException('名称不能为空且不能超过60字');
  }
}

void validateMoney(
  int cents, {
  bool positive = false,
  bool nonnegative = false,
}) {
  if (cents.abs() > maxMoney ||
      (positive && cents <= 0) ||
      (nonnegative && cents < 0)) {
    throw const LedgerException('金额无效或超出支持范围');
  }
}

class Account {
  const Account({
    required this.id,
    required this.name,
    this.kind = 'bank',
    this.openingBalance = 0,
    this.archived = false,
  });
  final String id, name, kind;
  final int openingBalance;
  final bool archived;
  factory Account.fromJson(Object? value) {
    final m = jsonObject(value);
    return Account(
      id: jsonString(m, 'id'),
      name: jsonString(m, 'name'),
      kind: jsonString(m, 'kind'),
      openingBalance: jsonInt(m, 'openingBalance'),
      archived: jsonBool(m, 'archived'),
    );
  }
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'openingBalance': openingBalance,
    'archived': archived,
  };
  Account copyWith({
    String? name,
    String? kind,
    int? openingBalance,
    bool? archived,
  }) => Account(
    id: id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    openingBalance: openingBalance ?? this.openingBalance,
    archived: archived ?? this.archived,
  );
  void validate() {
    validateId(id);
    validateName(name);
    validateMoney(openingBalance);
  }
}

class Category {
  const Category({
    required this.id,
    required this.name,
    required this.type,
    this.parentId,
    this.icon = 'Tags',
    this.color = '#397665',
  });
  final String id, name, icon, color;
  final EntryType type;
  final String? parentId;
  factory Category.fromJson(Object? value) {
    final m = jsonObject(value);
    final parent = m['parentId'];
    if (!m.containsKey('parentId') || (parent != null && parent is! String)) {
      throw const LedgerException('分类父级无效');
    }
    return Category(
      id: jsonString(m, 'id'),
      name: jsonString(m, 'name'),
      type: jsonType(m),
      parentId: parent as String?,
      icon: jsonString(m, 'icon'),
      color: jsonString(m, 'color'),
    );
  }
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'type': type.name,
    'parentId': parentId,
    'icon': icon,
    'color': color,
  };
  Category copyWith({String? name, String? icon, String? color}) => Category(
    id: id,
    name: name ?? this.name,
    type: type,
    parentId: parentId,
    icon: icon ?? this.icon,
    color: color ?? this.color,
  );
  void validate() {
    validateId(id);
    validateName(name);
    if (type == EntryType.transfer ||
        !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color)) {
      throw const LedgerException('分类数据无效');
    }
  }
}

class LedgerTransaction {
  const LedgerTransaction({
    required this.id,
    required this.type,
    required this.amount,
    required this.date,
    required this.accountId,
    required this.createdAt,
    this.fee = 0,
    this.toAccountId = '',
    this.categoryId = '',
    this.note = '',
  });
  final String id, date, accountId, toAccountId, categoryId, note, createdAt;
  final EntryType type;
  final int amount, fee;
  factory LedgerTransaction.fromJson(Object? value) {
    final m = jsonObject(value);
    return LedgerTransaction(
      id: jsonString(m, 'id'),
      type: jsonType(m),
      amount: jsonInt(m, 'amount'),
      fee: jsonInt(m, 'fee'),
      date: jsonString(m, 'date'),
      accountId: jsonString(m, 'accountId'),
      toAccountId: jsonString(m, 'toAccountId'),
      categoryId: jsonString(m, 'categoryId'),
      note: jsonString(m, 'note'),
      createdAt: jsonString(m, 'createdAt'),
    );
  }
  Map<String, Object?> toJson() => {
    'id': id,
    'type': type.name,
    'amount': amount,
    'fee': fee,
    'date': date,
    'accountId': accountId,
    'toAccountId': toAccountId,
    'categoryId': categoryId,
    'note': note,
    'createdAt': createdAt,
  };
  LedgerTransaction copyWith({
    EntryType? type,
    int? amount,
    int? fee,
    String? date,
    String? accountId,
    String? toAccountId,
    String? categoryId,
    String? note,
  }) => LedgerTransaction(
    id: id,
    type: type ?? this.type,
    amount: amount ?? this.amount,
    fee: fee ?? this.fee,
    date: date ?? this.date,
    accountId: accountId ?? this.accountId,
    toAccountId: toAccountId ?? this.toAccountId,
    categoryId: categoryId ?? this.categoryId,
    note: note ?? this.note,
    createdAt: createdAt,
  );
  void validate() {
    validateId(id);
    validateMoney(amount, positive: true);
    validateMoney(fee, nonnegative: true);
    if (!validDate(date) || !validDate(createdAt) || note.length > 2000) {
      throw const LedgerException('账单日期或备注无效');
    }
    if (type != EntryType.transfer && (fee != 0 || toAccountId.isNotEmpty)) {
      throw const LedgerException('普通收支不能设置转入账户或手续费');
    }
    if (type == EntryType.transfer &&
        (accountId == toAccountId ||
            toAccountId.isEmpty ||
            (fee == 0 && categoryId.isNotEmpty))) {
      throw const LedgerException('转账账户或手续费分类无效');
    }
  }
}

class Budget {
  const Budget({
    required this.month,
    required this.amount,
    this.categoryId = '',
    this.threshold = 80,
  });
  final String month, categoryId;
  final int amount, threshold;
  factory Budget.fromJson(Object? value) {
    final m = jsonObject(value);
    return Budget(
      month: jsonString(m, 'month'),
      categoryId: jsonString(m, 'categoryId'),
      amount: jsonInt(m, 'amount'),
      threshold: jsonInt(m, 'threshold'),
    );
  }
  Map<String, Object?> toJson() => {
    'month': month,
    'categoryId': categoryId,
    'amount': amount,
    'threshold': threshold,
  };
  void validate() {
    validateMoney(amount, positive: true);
    if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(month) ||
        ![50, 80, 90, 100].contains(threshold)) {
      throw const LedgerException('预算数据无效');
    }
  }
}

class LedgerSettings {
  const LedgerSettings({
    required this.defaultAccount,
    this.notifications = true,
    this.notified = const [],
  });
  final String defaultAccount;
  final bool notifications;
  final List<String> notified;
  factory LedgerSettings.fromJson(Object? value) {
    final m = jsonObject(value);
    final rows = m['notified'];
    if (rows is! List ||
        rows.length > 2000 ||
        rows.any((r) => r is! String || (r).length > 180)) {
      throw const LedgerException('提醒设置无效');
    }
    return LedgerSettings(
      defaultAccount: jsonString(m, 'defaultAccount'),
      notifications: jsonBool(m, 'notifications'),
      notified: List<String>.unmodifiable(rows.cast<String>()),
    );
  }
  Map<String, Object?> toJson() => {
    'defaultAccount': defaultAccount,
    'notifications': notifications,
    'notified': notified,
  };
  LedgerSettings copyWith({
    String? defaultAccount,
    bool? notifications,
    List<String>? notified,
  }) => LedgerSettings(
    defaultAccount: defaultAccount ?? this.defaultAccount,
    notifications: notifications ?? this.notifications,
    notified: List.unmodifiable(notified ?? this.notified),
  );
}

class LedgerFilter {
  const LedgerFilter({
    this.types = const [],
    this.includeFees = false,
    this.amountOp = '',
    this.amountMin = '',
    this.amountMax = '',
    this.categoryIds = const [],
    this.subIds = const [],
    this.note = '',
    this.noteMode = 'all',
    this.start = '',
    this.end = '',
    this.accountIds = const [],
    this.accountMode = 'any',
  });
  final List<EntryType> types;
  final bool includeFees;
  final String amountOp,
      amountMin,
      amountMax,
      note,
      noteMode,
      start,
      end,
      accountMode;
  final List<String> categoryIds, subIds, accountIds;
  factory LedgerFilter.fromJson(Map<String, Object?> m) => LedgerFilter(
    types: (m['types'] as List? ?? const [])
        .map((v) => EntryType.values.byName(v as String))
        .toList(),
    includeFees: m['includeFees'] == true,
    amountOp: m['amountOp'] as String? ?? '',
    amountMin: m['amountMin'] as String? ?? '',
    amountMax: m['amountMax'] as String? ?? '',
    categoryIds: (m['categoryIds'] as List? ?? const []).cast<String>(),
    subIds: (m['subIds'] as List? ?? const []).cast<String>(),
    note: m['note'] as String? ?? '',
    noteMode: m['noteMode'] as String? ?? 'all',
    start: m['start'] as String? ?? '',
    end: m['end'] as String? ?? '',
    accountIds: (m['accountIds'] as List? ?? const []).cast<String>(),
    accountMode: m['accountMode'] as String? ?? 'any',
  );
  Map<String, Object?> toJson() => {
    'types': types.map((t) => t.name).toList(),
    'includeFees': includeFees,
    'amountOp': amountOp,
    'amountMin': amountMin,
    'amountMax': amountMax,
    'categoryIds': categoryIds,
    'subIds': subIds,
    'note': note,
    'noteMode': noteMode,
    'start': start,
    'end': end,
    'accountIds': accountIds,
    'accountMode': accountMode,
  };
  LedgerFilter copyWith({
    List<EntryType>? types,
    bool? includeFees,
    String? amountOp,
    String? amountMin,
    String? amountMax,
    List<String>? categoryIds,
    List<String>? subIds,
    String? note,
    String? noteMode,
    String? start,
    String? end,
    List<String>? accountIds,
    String? accountMode,
  }) => LedgerFilter(
    types: types ?? this.types,
    includeFees: includeFees ?? this.includeFees,
    amountOp: amountOp ?? this.amountOp,
    amountMin: amountMin ?? this.amountMin,
    amountMax: amountMax ?? this.amountMax,
    categoryIds: categoryIds ?? this.categoryIds,
    subIds: subIds ?? this.subIds,
    note: note ?? this.note,
    noteMode: noteMode ?? this.noteMode,
    start: start ?? this.start,
    end: end ?? this.end,
    accountIds: accountIds ?? this.accountIds,
    accountMode: accountMode ?? this.accountMode,
  );
}

class LedgerSummary {
  const LedgerSummary({this.income = 0, this.expense = 0, this.count = 0});
  final int income, expense, count;
  int get balance => income - expense;
  Map<String, int> toJson() => {
    'income': income,
    'expense': expense,
    'balance': balance,
    'count': count,
  };
}

class TransactionPage {
  const TransactionPage({
    required this.items,
    required this.total,
    required this.offset,
    required this.limit,
  });
  final List<LedgerTransaction> items;
  final int total, offset, limit;
}

class WorkspaceMeta {
  const WorkspaceMeta({
    required this.key,
    required this.sequence,
    required this.transactionCount,
    this.cloudRevision,
    this.dirty = false,
  });
  final String key;
  final int sequence, transactionCount;
  final int? cloudRevision;
  final bool dirty;
}

class LedgerReadViewData {
  const LedgerReadViewData({
    required this.meta,
    required this.accounts,
    required this.categories,
    required this.budgets,
    required this.balances,
    required this.settings,
    required this.summary,
    required this.recent,
    this.storageWarning,
  });
  final WorkspaceMeta meta;
  final List<Account> accounts;
  final List<Category> categories;
  final List<BudgetStatus> budgets;
  final Map<String, int> balances;
  final LedgerSettings settings;
  final LedgerSummary summary;
  final TransactionPage recent;
  final String? storageWarning;
}

class CategoryTotal {
  const CategoryTotal({required this.category, required this.amount});
  final Category category;
  final int amount;
}

class TrendBucket {
  const TrendBucket({
    required this.start,
    required this.end,
    required this.income,
    required this.expense,
  });
  final String start, end;
  final int income, expense;
}

class LedgerStatistics {
  const LedgerStatistics({
    required this.summary,
    required this.categories,
    required this.subcategories,
    required this.trend,
  });
  final LedgerSummary summary;
  final List<CategoryTotal> categories, subcategories;
  final List<TrendBucket> trend;
}

class BudgetStatus {
  const BudgetStatus({required this.budget, required this.spent});
  final Budget budget;
  final int spent;
  int get remaining => budget.amount - spent;
  double get percent => spent / budget.amount * 100;
}

class ImportPreview {
  const ImportPreview({
    required this.token,
    required this.accountCount,
    required this.categoryCount,
    required this.transactionCount,
    required this.budgetCount,
    required this.expectedSequence,
    required this.workspace,
  });
  final String token, workspace;
  final int accountCount,
      categoryCount,
      transactionCount,
      budgetCount,
      expectedSequence;
}

class BackupInfo {
  const BackupInfo({
    required this.id,
    required this.label,
    required this.date,
    required this.path,
    required this.transactionCount,
  });
  final String id, label, date, path;
  final int transactionCount;
}

LedgerSummary summarize(Iterable<LedgerTransaction> rows) {
  var income = 0, expense = 0, count = 0;
  for (final t in rows) {
    count++;
    if (t.type == EntryType.income) {
      income += t.amount;
    } else if (t.type == EntryType.expense) {
      expense += t.amount;
    } else {
      expense += t.fee;
    }
  }
  return LedgerSummary(income: income, expense: expense, count: count);
}

int accountBalance(Account a, Iterable<LedgerTransaction> rows) {
  var balance = a.openingBalance;
  for (final t in rows) {
    if (t.accountId == a.id) {
      balance += t.type == EntryType.income
          ? t.amount
          : -t.amount - (t.type == EntryType.transfer ? t.fee : 0);
    }
    if (t.type == EntryType.transfer && t.toAccountId == a.id) {
      balance += t.amount;
    }
  }
  return balance;
}

bool matches(LedgerTransaction t, LedgerFilter f, List<Category> categories) {
  final byId = {for (final c in categories) c.id: c};
  final category = byId[t.categoryId];
  final feeOnly =
      f.includeFees &&
      t.type == EntryType.transfer &&
      t.fee > 0 &&
      f.types.contains(EntryType.expense) &&
      !f.types.contains(EntryType.transfer);
  if (f.types.isNotEmpty && !f.types.contains(t.type) && !feeOnly) return false;
  final day = t.date.substring(0, 10);
  if ((f.start.isNotEmpty && day.compareTo(f.start) < 0) ||
      (f.end.isNotEmpty && day.compareTo(f.end) > 0)) {
    return false;
  }
  if (f.categoryIds.isNotEmpty &&
      !f.categoryIds.contains(category?.parentId ?? '')) {
    return false;
  }
  if (f.subIds.isNotEmpty) {
    final parents = f.subIds.map((id) => byId[id]?.parentId).toSet();
    if (parents.contains(category?.parentId) &&
        !f.subIds.contains(t.categoryId)) {
      return false;
    }
    if (f.categoryIds.isEmpty && !f.subIds.contains(t.categoryId)) return false;
  }
  if (f.accountIds.isNotEmpty) {
    final out = f.accountIds.contains(t.accountId),
        incoming =
            !feeOnly &&
            t.type == EntryType.transfer &&
            f.accountIds.contains(t.toAccountId);
    if (f.accountMode == 'out'
        ? !out
        : f.accountMode == 'in'
        ? !incoming
        : !out && !incoming) {
      return false;
    }
  }
  if (f.note.trim().isNotEmpty) {
    final words = unicodeLower(f.note).trim().split(RegExp(r'\s+'));
    final note = unicodeLower(t.note);
    if (f.noteMode == 'any'
        ? !words.any(note.contains)
        : !words.every(note.contains)) {
      return false;
    }
  }
  if (f.amountOp.isNotEmpty && f.amountMin.trim().isNotEmpty) {
    final min = parseMoney(f.amountMin, allowZero: true),
        amount = feeOnly ? t.fee : t.amount;
    switch (f.amountOp) {
      case 'eq':
        if (amount != min) return false;
      case 'gt':
        if (amount <= min) return false;
      case 'lt':
        if (amount >= min) return false;
      case 'range':
        if (amount < min ||
            (f.amountMax.trim().isNotEmpty &&
                amount > parseMoney(f.amountMax, allowZero: true))) {
          return false;
        }
    }
  }
  return true;
}

String encodeJson(Object? value) => jsonEncode(value);
