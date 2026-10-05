import 'ledger_models.dart';

const defaultAccounts = [
  Account(id: 'cash', name: '现金', kind: 'cash'),
  Account(id: 'bank', name: '银行卡'),
  Account(id: 'wechat', name: '微信钱包', kind: 'wallet'),
];
List<Category> defaultCategories() {
  const colors = [
    '#397665',
    '#7d94b5',
    '#c59868',
    '#9d88a9',
    '#6d9a99',
    '#b5a36e',
    '#a27d7d',
    '#779184',
  ];
  const groups = [
    ('food', '餐饮', 'Utensils', ['早餐', '午餐', '晚餐', '饮品', '聚餐']),
    ('transport', '交通', 'TramFront', ['公共交通', '打车', '燃油', '停车', '长途出行']),
    ('shopping', '购物', 'ShoppingBag', ['日用品', '服饰', '数码', '家居']),
    ('home', '居住', 'House', ['房租', '房贷', '水电燃气', '物业', '维修']),
    ('fun', '休闲娱乐', 'Headphones', ['影音', '游戏', '运动', '旅行']),
    ('health', '医疗健康', 'HeartPulse', ['门诊', '药品', '体检']),
    ('study', '学习成长', 'BookOpen', ['书籍', '课程', '考试']),
    ('social', '人情往来', 'Gift', ['礼物', '红包', '请客']),
    ('other', '其他支出', 'Ellipsis', ['手续费', '未分类']),
  ];
  const childIds = {
    'food': ['breakfast', 'lunch', 'dinner', 'drink', 'gather'],
    'shopping': ['daily', 'clothes', 'digital', 'furniture'],
    'other': ['fee', 'uncategorized'],
  };
  final rows = <Category>[];
  for (var i = 0; i < groups.length; i++) {
    final g = groups[i];
    rows.add(
      Category(
        id: g.$1,
        name: g.$2,
        type: EntryType.expense,
        icon: g.$3,
        color: colors[i % colors.length],
      ),
    );
    for (var j = 0; j < g.$4.length; j++) {
      rows.add(
        Category(
          id: '${g.$1}-${childIds[g.$1]?[j] ?? j}',
          name: g.$4[j],
          type: EntryType.expense,
          parentId: g.$1,
          icon: g.$3,
          color: colors[i % colors.length],
        ),
      );
    }
  }
  const incomes = [
    ('salary', '工作收入', ['工资', '奖金', '补贴']),
    ('side', '副业收入', ['接单', '兼职', '稿费']),
    ('invest', '投资收益', ['利息', '分红', '投资盈利']),
    ('income-other', '其他收入', ['礼金', '补助', '未分类']),
  ];
  for (var i = 0; i < incomes.length; i++) {
    final g = incomes[i];
    rows.add(
      Category(
        id: g.$1,
        name: g.$2,
        type: EntryType.income,
        icon: 'Wallet',
        color: colors[i],
      ),
    );
    for (var j = 0; j < g.$3.length; j++) {
      rows.add(
        Category(
          id: '${g.$1}-${j == 0 && g.$1 == 'salary' ? 'main' : j}',
          name: g.$3[j],
          type: EntryType.income,
          parentId: g.$1,
          icon: 'Wallet',
          color: colors[i],
        ),
      );
    }
  }
  return rows;
}

void validateMetadata(
  List<Account> accounts,
  List<Category> categories,
  List<Budget> budgets,
  LedgerSettings settings,
) {
  if (accounts.length > 100 ||
      categories.length > 1000 ||
      budgets.length > 1000) {
    throw const LedgerException('数据超过支持的数量');
  }
  final aIds = <String>{}, cIds = <String>{};
  for (final a in accounts) {
    a.validate();
    if (!aIds.add(a.id)) throw const LedgerException('账户 ID 重复');
  }
  final byId = {for (final c in categories) c.id: c};
  for (final c in categories) {
    c.validate();
    if (!cIds.add(c.id)) throw const LedgerException('分类 ID 重复');
    if (c.parentId != null) {
      final parent = byId[c.parentId];
      if (parent == null ||
          parent.parentId != null ||
          parent.type != c.type ||
          parent.id == c.id) {
        throw const LedgerException('分类必须是两级结构');
      }
    }
  }
  final keys = <String>{};
  for (final b in budgets) {
    b.validate();
    final c = byId[b.categoryId];
    if (!keys.add('${b.month}:${b.categoryId}') ||
        (b.categoryId.isNotEmpty &&
            (c == null || c.parentId != null || c.type != EntryType.expense))) {
      throw const LedgerException('预算分类无效或重复');
    }
  }
  if (!aIds.contains(settings.defaultAccount) ||
      settings.notified.length > 2000 ||
      settings.notified.any((n) => n.length > 180)) {
    throw const LedgerException('设置数据无效');
  }
}

void validateReferences(
  LedgerTransaction t,
  Set<String> accountIds,
  Map<String, Category> categories,
) {
  t.validate();
  if (!accountIds.contains(t.accountId)) throw const LedgerException('记账账户不存在');
  final c = categories[t.categoryId];
  if (t.type == EntryType.transfer) {
    if (!accountIds.contains(t.toAccountId)) {
      throw const LedgerException('转入账户不存在');
    }
    if (t.fee > 0 &&
        (c == null || c.parentId == null || c.type != EntryType.expense)) {
      throw const LedgerException('手续费必须选择支出小类');
    }
  } else if (c == null || c.parentId == null || c.type != t.type) {
    throw const LedgerException('账单必须选择对应类型的小类');
  }
}
