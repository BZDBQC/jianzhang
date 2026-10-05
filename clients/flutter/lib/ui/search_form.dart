import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../data/ledger_repository.dart';
import 'common.dart';
import 'entry_form.dart';

class SearchForm extends StatefulWidget {
  const SearchForm({super.key, required this.view, required this.filter});
  final LedgerView view;
  final LedgerFilter filter;
  @override
  State<SearchForm> createState() => _SearchFormState();
}

class _SearchFormState extends State<SearchForm> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _min, _max, _note, _start, _end;
  late String _op, _noteMode, _accountMode;
  late Set<EntryType> _types;
  late Set<String> _parents, _leaves, _accounts;
  late bool _fees;
  @override
  void initState() {
    super.initState();
    final f = widget.filter;
    _min = TextEditingController(text: f.amountMin);
    _max = TextEditingController(text: f.amountMax);
    _note = TextEditingController(text: f.note);
    _start = TextEditingController(text: f.start);
    _end = TextEditingController(text: f.end);
    _op = f.amountOp;
    _noteMode = f.noteMode;
    _accountMode = f.accountMode;
    _types = f.types.toSet();
    _parents = f.categoryIds.toSet();
    _leaves = f.subIds.toSet();
    _accounts = f.accountIds.toSet();
    _fees = f.includeFees;
  }

  @override
  void dispose() {
    for (final c in [_min, _max, _note, _start, _end]) {
      c.dispose();
    }
    super.dispose();
  }

  void _toggle<T>(Set<T> set, T value) => setState(() {
    set.contains(value) ? set.remove(value) : set.add(value);
  });
  String? _money(String? value) {
    if (_op.isEmpty) return null;
    try {
      parseMoney(value ?? '', allowZero: true);
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  String? _day(String? value) =>
      value == null || value.isEmpty || validDate('${value}T00:00')
      ? null
      : '请输入有效日期 YYYY-MM-DD';
  void _apply() {
    if (!(_form.currentState?.validate() ?? false)) return;
    if (_start.text.isNotEmpty &&
        _end.text.isNotEmpty &&
        _start.text.compareTo(_end.text) > 0) {
      showNotice(context, '开始日期不能晚于结束日期', error: true);
      return;
    }
    if (_op == 'range' &&
        parseMoney(_min.text, allowZero: true) >
            parseMoney(_max.text, allowZero: true)) {
      showNotice(context, '金额下限不能大于上限', error: true);
      return;
    }
    Navigator.pop(
      context,
      LedgerFilter(
        types: _types.toList(),
        includeFees: _fees,
        amountOp: _op,
        amountMin: _op.isEmpty ? '' : _min.text,
        amountMax: _op == 'range' ? _max.text : '',
        categoryIds: _parents.toList(),
        subIds: _leaves.toList(),
        accountIds: _accounts.toList(),
        accountMode: _accountMode,
        note: _note.text.trim(),
        noteMode: _noteMode,
        start: _start.text,
        end: _end.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final parents = widget.view.categories
        .where((c) => c.parentId == null)
        .toList();
    final leaves = widget.view.categories
        .where(
          (c) =>
              c.parentId != null &&
              (_parents.isEmpty || _parents.contains(c.parentId)),
        )
        .toList();
    return FormDialog(
      title: '组合查询',
      subtitle: '条件之间同时满足；未选择的项目表示不限。',
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _apply, child: const Text('查询账单')),
      ],
      children: [
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('账单类型'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: EntryType.values
                    .map(
                      (type) => FilterChip(
                        label: Text(typeLabel(type)),
                        selected: _types.contains(type),
                        onSelected: (_) => _toggle(_types, type),
                      ),
                    )
                    .toList(),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('支出查询包含转账手续费'),
                value: _fees,
                onChanged: (value) => setState(() {
                  _fees = value ?? false;
                }),
              ),
              const FieldSpace(),
              DropdownButtonFormField<String>(
                initialValue: _op,
                decoration: const InputDecoration(labelText: '金额条件'),
                items: const [
                  DropdownMenuItem(value: '', child: Text('不限金额')),
                  DropdownMenuItem(value: 'eq', child: Text('等于')),
                  DropdownMenuItem(value: 'gt', child: Text('大于')),
                  DropdownMenuItem(value: 'lt', child: Text('小于')),
                  DropdownMenuItem(value: 'range', child: Text('区间（含边界）')),
                ],
                onChanged: (value) => setState(() {
                  _op = value ?? '';
                }),
              ),
              if (_op.isNotEmpty) ...[
                const FieldSpace(),
                TextFormField(
                  controller: _min,
                  decoration: InputDecoration(
                    labelText: _op == 'range' ? '金额下限' : '金额',
                    prefixText: '¥ ',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: _money,
                ),
                if (_op == 'range') ...[
                  const FieldSpace(),
                  TextFormField(
                    controller: _max,
                    decoration: const InputDecoration(
                      labelText: '金额上限',
                      prefixText: '¥ ',
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: _money,
                  ),
                ],
              ],
              const FieldSpace(),
              TextFormField(
                controller: _start,
                decoration: const InputDecoration(
                  labelText: '开始日期',
                  hintText: 'YYYY-MM-DD',
                ),
                validator: _day,
              ),
              const FieldSpace(),
              TextFormField(
                controller: _end,
                decoration: const InputDecoration(
                  labelText: '结束日期（含当天）',
                  hintText: 'YYYY-MM-DD',
                ),
                validator: _day,
              ),
              const FieldSpace(),
              TextFormField(
                controller: _note,
                maxLength: 2000,
                decoration: const InputDecoration(
                  labelText: '备注关键词',
                  hintText: '多个词用空格隔开，不区分英文大小写',
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: _noteMode,
                decoration: const InputDecoration(labelText: '关键词匹配'),
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('全部关键词')),
                  DropdownMenuItem(value: 'any', child: Text('任意关键词')),
                ],
                onChanged: (value) => setState(() {
                  _noteMode = value ?? 'all';
                }),
              ),
              const FieldSpace(),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('大类与小类'),
                initiallyExpanded: _parents.isNotEmpty || _leaves.isNotEmpty,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: parents
                        .map(
                          (c) => FilterChip(
                            label: Text('${typeLabel(c.type)} · ${c.name}'),
                            selected: _parents.contains(c.id),
                            onSelected: (_) {
                              _toggle(_parents, c.id);
                              setState(() {
                                _leaves.removeWhere(
                                  (id) =>
                                      _parents.isNotEmpty &&
                                      !_parents.contains(
                                        widget.view.category(id)?.parentId,
                                      ),
                                );
                              });
                            },
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: leaves
                        .map(
                          (c) => FilterChip(
                            label: Text(
                              '${widget.view.category(c.parentId ?? '')?.name ?? ''} / ${c.name}',
                            ),
                            selected: _leaves.contains(c.id),
                            onSelected: (_) => _toggle(_leaves, c.id),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('账户'),
                initiallyExpanded: _accounts.isNotEmpty,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: widget.view.accounts
                        .map(
                          (a) => FilterChip(
                            label: Text(a.name),
                            selected: _accounts.contains(a.id),
                            onSelected: (_) => _toggle(_accounts, a.id),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _accountMode,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '账户位置'),
                    items: const [
                      DropdownMenuItem(value: 'any', child: Text('记账或任一转账账户')),
                      DropdownMenuItem(value: 'out', child: Text('记账 / 转出账户')),
                      DropdownMenuItem(value: 'in', child: Text('仅转账的转入账户')),
                    ],
                    onChanged: (value) => setState(() {
                      _accountMode = value ?? 'any';
                    }),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
