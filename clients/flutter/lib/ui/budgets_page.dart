import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/controller.dart';
import '../app/theme.dart';
import '../data/ledger_repository.dart';
import 'common.dart';
import 'ledger_pages.dart';

import 'mutation_helpers.dart';

class BudgetsPage extends ConsumerWidget {
  const BudgetsPage({super.key, required this.view});
  final LedgerView view;
  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      SectionHeading(
        title: '预算',
        caption: '总预算与大类预算独立计算，同一阈值每月只提醒一次。',
        action: MonthPicker(view: view),
      ),
      const SizedBox(height: 16),
      Wrap(
        children: [
          FilledButton.icon(
            onPressed: view.busy
                ? null
                : () => showDialog<void>(
                    context: context,
                    builder: (_) => BudgetEditor(view: view),
                  ),
            icon: const Icon(Icons.add),
            label: const Text('设置预算'),
          ),
        ],
      ),
      const SizedBox(height: 20),
      if (view.budgets.isEmpty)
        const EmptyNotice(
          title: '给这个月定一个小目标',
          message: '设置月度总预算或分类预算，留出想要的生活。',
        ),
      ...view.budgets.map(
        (status) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  status.budget.categoryId.isEmpty
                      ? '月度总预算'
                      : view.category(status.budget.categoryId)?.name ?? '分类预算',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  '已用 ¥${formatMoney(status.spent)} / ¥${formatMoney(status.budget.amount)}',
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: (status.percent / 100).clamp(0, 1).toDouble(),
                  minHeight: 8,
                  color: status.percent >= 100
                      ? AppColors.expense
                      : AppColors.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  '${status.remaining < 0 ? '超出' : '剩余'} ¥${formatMoney(status.remaining.abs())} · ${status.budget.threshold}% 时提醒',
                ),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: view.busy
                          ? null
                          : () => showDialog<void>(
                              context: context,
                              builder: (_) => BudgetEditor(
                                view: view,
                                budget: status.budget,
                              ),
                            ),
                      child: const Text('编辑'),
                    ),
                    TextButton(
                      onPressed: view.busy
                          ? null
                          : () async {
                              if (await confirmAction(
                                context,
                                title: '删除预算？',
                                message: '历史账单不受影响。',
                              )) {
                                if (context.mounted) {
                                  await mutate(
                                    context,
                                    ref,
                                    (repo) => repo.deleteBudget(
                                      status.budget.month,
                                      status.budget.categoryId,
                                      expectedWorkspace: view.meta.key,
                                      expectedSequence: view.meta.sequence,
                                    ),
                                    '预算已删除',
                                    scope: view.meta,
                                  );
                                }
                              }
                            },
                      child: const Text('删除'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

class BudgetEditor extends ConsumerStatefulWidget {
  const BudgetEditor({super.key, required this.view, this.budget});
  final LedgerView view;
  final Budget? budget;
  @override
  ConsumerState<BudgetEditor> createState() => _BudgetEditorState();
}

class _BudgetEditorState extends ConsumerState<BudgetEditor> {
  late final TextEditingController _amount;
  String? _category;
  late int _threshold;
  bool _busy = false;
  late WorkspaceMeta _scope;
  late LedgerView _view;
  late String _month;
  bool _missing = false;
  @override
  void initState() {
    super.initState();
    _scope = widget.view.meta;
    _view = widget.view;
    _month = widget.budget?.month ?? monthKey(widget.view.month);
    _amount = TextEditingController(
      text: widget.budget == null ? '' : decimalMoney(widget.budget!.amount),
    );
    _category = widget.budget?.categoryId ?? '';
    _threshold = widget.budget?.threshold ?? 80;
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _recheck(LedgerView view) async {
    final repository = await ref.read(repositoryProvider.future);
    final snapshot = await repository.readViewData(
      month: _month,
      expectedWorkspace: view.meta.key,
      expectedSequence: view.meta.sequence,
    );
    if (!mounted) return;
    final original = widget.budget;
    final missing =
        original != null &&
        !snapshot.budgets.any(
          (row) =>
              row.budget.month == original.month &&
              row.budget.categoryId == original.categoryId,
        );
    setState(() {
      _scope = snapshot.meta;
      _view = LedgerView.fromSnapshot(
        snapshot,
        month: DateTime.parse('$_month-01'),
      );
      _missing = missing;
      if (_category != '' &&
          !snapshot.categories.any(
            (c) =>
                c.id == _category &&
                c.type == EntryType.expense &&
                c.parentId == null,
          )) {
        _category = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) => FormDialog(
    title: '$_month 预算',
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy || _missing
            ? null
            : () async {
                try {
                  final category = _category;
                  if (category == null) {
                    throw const LedgerException('原预算分类已删除，请重新选择预算范围。');
                  }
                  final amount = parseMoney(_amount.text);
                  setState(() => _busy = true);
                  final saved = await mutate(
                    context,
                    ref,
                    (repo) => repo.upsertBudget(
                      Budget(
                        month: _month,
                        categoryId: category,
                        amount: amount,
                        threshold: _threshold,
                      ),
                      expectedWorkspace: _scope.key,
                      expectedSequence: _scope.sequence,
                    ),
                    '预算已保存',
                    scope: _scope,
                  );
                  if (context.mounted) {
                    if (saved) {
                      Navigator.pop(context);
                    } else {
                      setState(() => _busy = false);
                    }
                  }
                } catch (e) {
                  if (context.mounted) {
                    setState(() => _busy = false);
                    showNotice(context, e.toString(), error: true);
                  }
                }
              },
        child: Text(_busy ? '正在保存…' : '保存预算'),
      ),
    ],
    children: [
      if (_missing) const Text('该预算已删除，不能继续编辑。金额草稿仍保留，请关闭后重新添加预算。'),
      DropdownButtonFormField<String>(
        key: ValueKey('budget-category-${_scope.sequence}-$_category'),
        initialValue: _category,
        isExpanded: true,
        decoration: const InputDecoration(labelText: '预算范围'),
        items: [
          const DropdownMenuItem(value: '', child: Text('月度总预算')),
          ..._view.categories
              .where((c) => c.type == EntryType.expense && c.parentId == null)
              .map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))),
        ],
        onChanged: widget.budget == null ? (value) => _category = value : null,
      ),
      DraftScopeNotice(scope: _scope, onRechecked: _recheck),
      const FieldSpace(),
      TextField(
        controller: _amount,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: '预算金额', prefixText: '¥ '),
      ),
      const FieldSpace(),
      DropdownButtonFormField<int>(
        initialValue: _threshold,
        decoration: const InputDecoration(labelText: '提醒阈值'),
        items: [
          50,
          80,
          90,
          100,
        ].map((n) => DropdownMenuItem(value: n, child: Text('$n%'))).toList(),
        onChanged: (value) => _threshold = value ?? 80,
      ),
    ],
  );
}
