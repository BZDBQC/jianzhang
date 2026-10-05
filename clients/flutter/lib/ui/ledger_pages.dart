import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/controller.dart';
import '../app/theme.dart';
import '../data/ledger_repository.dart';
import 'common.dart';
import 'entry_form.dart';
import 'file_actions.dart';
import 'search_form.dart';

class MonthPicker extends ConsumerWidget {
  const MonthPicker({super.key, required this.view});
  final LedgerView view;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: '上个月',
        onPressed: view.busy
            ? null
            : () => ref
                  .read(ledgerProvider.notifier)
                  .changeMonth(DateTime(view.month.year, view.month.month - 1)),
        icon: const Icon(Icons.chevron_left),
      ),
      Text(
        monthKey(view.month),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      IconButton(
        tooltip: '下个月',
        onPressed: view.busy
            ? null
            : () => ref
                  .read(ledgerProvider.notifier)
                  .changeMonth(DateTime(view.month.year, view.month.month + 1)),
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );
}

class MoneyOverview extends StatelessWidget {
  const MoneyOverview({super.key, required this.summary});
  final LedgerSummary summary;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final width = box.maxWidth;
      final columns = width >= 850
          ? 3
          : width >= 580
          ? 2
          : 1;
      return Wrap(
        spacing: 16,
        runSpacing: 16,
        children:
            [
                  ('收入', summary.income, AppColors.primary),
                  ('支出', summary.expense, AppColors.expense),
                  ('结余', summary.balance, AppColors.ink),
                ]
                .map(
                  (value) => SizedBox(
                    width: (width - (columns - 1) * 16) / columns,
                    child: SoftCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            value.$1,
                            style: const TextStyle(color: AppColors.muted),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '¥ ${formatMoney(value.$2)}',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w600,
                              color: value.$3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
                .toList(),
      );
    },
  );
}

class TransactionRow extends ConsumerWidget {
  const TransactionRow({super.key, required this.entry, required this.view});
  final LedgerTransaction entry;
  final LedgerView view;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: LayoutBuilder(
      builder: (context, box) {
        final actions = PopupMenuButton<String>(
          tooltip: '账单操作',
          enabled: !view.busy,
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('编辑')),
            PopupMenuItem(value: 'copy', child: Text('复制为新账单')),
            PopupMenuItem(value: 'delete', child: Text('删除')),
          ],
          onSelected: (value) async {
            if (value == 'edit' || value == 'copy') {
              await showEntry(
                context,
                entry: entry,
                duplicate: value == 'copy',
              );
            } else if (await confirmAction(
              context,
              title: '删除这笔账单？',
              message:
                  '${entry.date.replaceFirst('T', ' ')} · ¥${formatMoney(entry.amount)}\n${entry.note}',
              accept: '删除',
            )) {
              final saved = await ref
                  .read(ledgerProvider.notifier)
                  .perform(
                    (repo) => repo.deleteTransaction(
                      entry.id,
                      expectedWorkspace: view.meta.key,
                      expectedSequence: view.meta.sequence,
                    ),
                    expectedScope: view.meta,
                  );
              if (context.mounted) {
                showNotice(
                  context,
                  saved
                      ? '账单已删除'
                      : ref.read(ledgerProvider).asData?.value.error ?? '删除失败',
                  error: !saved,
                );
              }
            }
          },
        );
        final amount = Text(
          '${entry.type == EntryType.expense
              ? '−'
              : entry.type == EntryType.income
              ? '+'
              : ''}¥${formatMoney(entry.amount)}',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: entry.type == EntryType.expense
                ? AppColors.expense
                : entry.type == EntryType.income
                ? AppColors.primary
                : AppColors.ink,
          ),
        );
        if (box.maxWidth >= 950) {
          return Row(
            children: [
              Expanded(flex: 2, child: Text(entry.date.replaceFirst('T', ' '))),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(view.categoryName(entry)),
                    if (entry.note.isNotEmpty)
                      Text(
                        entry.note,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.muted),
                      ),
                  ],
                ),
              ),
              Expanded(flex: 2, child: Text(view.accountName(entry))),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    amount,
                    if (entry.fee > 0)
                      Text(
                        '手续费 ¥${formatMoney(entry.fee)}',
                        style: const TextStyle(color: AppColors.muted),
                      ),
                  ],
                ),
              ),
              actions,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    view.categoryName(entry),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                actions,
              ],
            ),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                amount,
                if (entry.fee > 0) Text('手续费 ¥${formatMoney(entry.fee)}'),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${entry.date.replaceFirst('T', ' ')} · ${view.accountName(entry)}',
              style: const TextStyle(color: AppColors.muted),
            ),
            if (entry.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(entry.note),
              ),
          ],
        );
      },
    ),
  );
}

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.view, required this.onBills});
  final LedgerView view;
  final VoidCallback onBills;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      SectionHeading(
        title: '收支概览',
        caption: '本机已保存 · ${view.meta.transactionCount} 笔账单',
        action: MonthPicker(view: view),
      ),
      const SizedBox(height: 24),
      MoneyOverview(summary: view.summary),
      if (view.alerts.isNotEmpty) ...[
        const SizedBox(height: 16),
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: view.alerts
                .map(
                  (text) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text('预算提醒：$text'),
                  ),
                )
                .toList(),
          ),
        ),
      ],
      const SizedBox(height: 28),
      SoftCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeading(
              title: '最近账单',
              action: TextButton(onPressed: onBills, child: const Text('查看全部')),
            ),
            if (view.recent.items.isEmpty)
              EmptyNotice(
                title: '从第一笔开始',
                message: '支出、收入和转账，都可以在这里记下来。',
                action: FilledButton.icon(
                  onPressed: () => showEntry(context),
                  icon: const Icon(Icons.add),
                  label: const Text('记一笔'),
                ),
              )
            else
              ...view.recent.items.map(
                (entry) => Column(
                  children: [
                    TransactionRow(entry: entry, view: view),
                    const Divider(height: 1),
                  ],
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      const Text(
        '账单先保存到这台设备。只有使用云端保存时，才需要登录。',
        style: TextStyle(color: AppColors.muted),
      ),
      const SizedBox(height: 20),
    ],
  );
}

class BillsPage extends ConsumerStatefulWidget {
  const BillsPage({super.key, required this.view, this.initialFilter});
  final LedgerView view;
  final LedgerFilter? initialFilter;
  @override
  ConsumerState<BillsPage> createState() => _BillsPageState();
}

class _BillsPageState extends ConsumerState<BillsPage> {
  late LedgerFilter _filter;
  Future<TransactionPage>? _page;
  int _offset = 0;
  int _queryGeneration = 0;
  @override
  void initState() {
    super.initState();
    _filter = widget.initialFilter ?? const LedgerFilter();
    _query();
  }

  @override
  void didUpdateWidget(covariant BillsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialFilter != widget.initialFilter &&
        widget.initialFilter != null) {
      _filter = widget.initialFilter!;
      _offset = 0;
    }
    if (oldWidget.view.meta.sequence != widget.view.meta.sequence ||
        oldWidget.view.meta.key != widget.view.meta.key ||
        oldWidget.initialFilter != widget.initialFilter) {
      if (oldWidget.view.meta.key != widget.view.meta.key) _offset = 0;
      _query();
    }
  }

  void _query() {
    final generation = ++_queryGeneration;
    final scope = widget.view.meta;
    final filter = _filter;
    final offset = _offset;
    _page = ref.read(repositoryProvider.future).then((repo) async {
      final page = await repo.search(
        filter,
        offset: offset,
        expectedWorkspace: scope.key,
        expectedSequence: scope.sequence,
      );
      if (page.total > 0 &&
          _offset >= page.total &&
          mounted &&
          generation == _queryGeneration) {
        _offset = ((page.total - 1) ~/ page.limit) * page.limit;
        return repo.search(
          filter,
          offset: _offset,
          expectedWorkspace: scope.key,
          expectedSequence: scope.sequence,
        );
      }
      if (page.total == 0 && generation == _queryGeneration) _offset = 0;
      return page;
    });
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeading(
          title: '账单',
          caption: '组合条件精确查询，支持备注多关键词。',
          action: Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final next = await showDialog<LedgerFilter>(
                    context: context,
                    builder: (_) =>
                        SearchForm(view: widget.view, filter: _filter),
                  );
                  if (next != null && mounted) {
                    setState(() {
                      _filter = next;
                      _offset = 0;
                      _query();
                    });
                  }
                },
                icon: const Icon(Icons.tune),
                label: const Text('筛选账单'),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _filter = const LedgerFilter();
                  _offset = 0;
                  _query();
                }),
                child: const Text('清除条件'),
              ),
              PopupMenuButton<ExportFormat>(
                tooltip: '导出查询结果',
                enabled: !widget.view.busy,
                onSelected: (format) => exportBook(
                  context,
                  ref,
                  format,
                  filter: _filter,
                  expectedScope: widget.view.meta,
                ),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: ExportFormat.csv,
                    child: Text('导出结果为 CSV'),
                  ),
                  PopupMenuItem(
                    value: ExportFormat.xlsx,
                    child: Text('导出结果为 Excel'),
                  ),
                  PopupMenuItem(
                    value: ExportFormat.json,
                    child: Text('导出结果为 JSON'),
                  ),
                ],
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.download_outlined),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: FutureBuilder<TransactionPage>(
            future: _page,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return EmptyNotice(
                  title: '查询未完成',
                  message: snapshot.error.toString(),
                  icon: Icons.error_outline,
                  action: OutlinedButton(
                    onPressed: () => setState(_query),
                    child: const Text('重试'),
                  ),
                );
              }
              final page = snapshot.data;
              if (page == null || page.items.isEmpty) {
                return const EmptyNotice(
                  title: '没有匹配账单',
                  message: '调整金额、时间、分类或备注关键词后再试。',
                );
              }
              return Column(
                children: [
                  Expanded(
                    child: ListView.separated(
                      itemCount: page.items.length,
                      separatorBuilder: (_, index) => const Divider(height: 1),
                      itemBuilder: (_, index) => TransactionRow(
                        entry: page.items[index],
                        view: widget.view,
                      ),
                    ),
                  ),
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    children: [
                      IconButton(
                        tooltip: '上一页',
                        onPressed: _offset == 0
                            ? null
                            : () => setState(() {
                                _offset -= page.limit;
                                _query();
                              }),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text(
                        '第 ${_offset + 1}–${_offset + page.items.length} 笔，共 ${page.total} 笔',
                      ),
                      IconButton(
                        tooltip: '下一页',
                        onPressed: _offset + page.items.length >= page.total
                            ? null
                            : () => setState(() {
                                _offset += page.limit;
                                _query();
                              }),
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}

class ReportsPage extends ConsumerStatefulWidget {
  const ReportsPage({super.key, required this.view, required this.onDrill});
  final LedgerView view;
  final ValueChanged<LedgerFilter> onDrill;
  @override
  ConsumerState<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends ConsumerState<ReportsPage> {
  EntryType _type = EntryType.expense;
  bool _yearly = false;
  LedgerFilter get _period => _yearly
      ? LedgerFilter(
          start: dayKey(DateTime(widget.view.month.year)),
          end: dayKey(DateTime(widget.view.month.year, 12, 31)),
        )
      : widget.view.monthFilter;
  Future<LedgerStatistics>? _statistics;
  @override
  void initState() {
    super.initState();
    _query();
  }

  @override
  void didUpdateWidget(covariant ReportsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.view.meta.sequence != widget.view.meta.sequence ||
        oldWidget.view.meta.key != widget.view.meta.key ||
        oldWidget.view.month != widget.view.month) {
      _query();
    }
  }

  void _query() {
    final scope = widget.view.meta;
    final period = _period;
    final type = _type;
    final yearly = _yearly;
    _statistics = ref
        .read(repositoryProvider.future)
        .then(
          (repo) => repo.statistics(
            start: period.start,
            end: period.end,
            type: type,
            monthly: yearly,
            expectedWorkspace: scope.key,
            expectedSequence: scope.sequence,
          ),
        );
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      SectionHeading(
        title: '统计报表',
        caption: '转账本金不计收入或支出，手续费计入支出。',
        action: MonthPicker(view: widget.view),
      ),
      const SizedBox(height: 20),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ChoiceChip(
            label: const Text('按月'),
            selected: !_yearly,
            onSelected: (_) => setState(() {
              _yearly = false;
              _query();
            }),
          ),
          ChoiceChip(
            label: Text('${widget.view.month.year} 全年'),
            selected: _yearly,
            onSelected: (_) => setState(() {
              _yearly = true;
              _query();
            }),
          ),
          ...[EntryType.expense, EntryType.income].map(
            (type) => ChoiceChip(
              label: Text('${typeLabel(type)}分布'),
              selected: _type == type,
              onSelected: (_) => setState(() {
                _type = type;
                _query();
              }),
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      FutureBuilder<LedgerStatistics>(
        future: _statistics,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return EmptyNotice(
              title: '报表读取失败',
              message: snapshot.error.toString(),
              action: TextButton(
                onPressed: () => setState(_query),
                child: const Text('重试'),
              ),
            );
          }
          final stats = snapshot.data;
          if (stats == null) {
            return const EmptyNotice(
              title: '所选期间还没有收支记录',
              message: '记下账单后，分类和趋势会在这里呈现。',
            );
          }
          final total = stats.categories.fold<int>(
            0,
            (sum, row) => sum + row.amount,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MoneyOverview(summary: stats.summary),
              const SizedBox(height: 20),
              if (stats.categories.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text('所选期间没有该类型账单。'),
                ),
              SoftCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('大类分布', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 12),
                    ...stats.categories.map(
                      (row) => _categoryBar(context, row, total, false),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SoftCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('小类明细', style: Theme.of(context).textTheme.titleLarge),
                    ...stats.subcategories.map(
                      (row) => _categoryBar(context, row, total, true),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SoftCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _yearly ? '月度趋势 · 点击查看当月账单' : '收支趋势 · 点击查看当日账单',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    ...stats.trend.map(
                      (day) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(day.start),
                        subtitle: Text(
                          '收入 ¥${formatMoney(day.income)} · 支出 ¥${formatMoney(day.expense)}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => widget.onDrill(
                          LedgerFilter(start: day.start, end: day.end),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ],
  );
  Widget _categoryBar(
    BuildContext context,
    CategoryTotal row,
    int total,
    bool leaf,
  ) => InkWell(
    onTap: () => widget.onDrill(
      _period.copyWith(
        types: [_type],
        includeFees: _type == EntryType.expense,
        categoryIds: leaf ? const [] : [row.category.id],
        subIds: leaf ? [row.category.id] : const [],
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(row.category.name),
              Text(
                '¥${formatMoney(row.amount)} · ${(total == 0 ? 0 : row.amount / total * 100).toStringAsFixed(1)}%',
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: total == 0 ? 0 : (row.amount / total).clamp(0, 1).toDouble(),
            borderRadius: BorderRadius.circular(8),
            minHeight: 6,
          ),
        ],
      ),
    ),
  );
}
