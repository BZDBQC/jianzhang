import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../app/controller.dart';
import '../data/ledger_repository.dart';
import 'common.dart';

String typeLabel(EntryType type) => switch (type) {
  EntryType.expense => '支出',
  EntryType.income => '收入',
  EntryType.transfer => '转账',
};

Future<void> showEntry(
  BuildContext context, {
  LedgerTransaction? entry,
  bool duplicate = false,
}) {
  final openedView = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(ledgerProvider).asData?.value;
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.maybePop(dialogContext),
      },
      child: EntryForm(
        entry: entry,
        duplicate: duplicate,
        openedView: openedView,
      ),
    ),
  );
}

class EntryForm extends ConsumerStatefulWidget {
  const EntryForm({
    super.key,
    this.entry,
    this.duplicate = false,
    this.openedView,
  });
  final LedgerTransaction? entry;
  final bool duplicate;
  final LedgerView? openedView;
  @override
  ConsumerState<EntryForm> createState() => _EntryFormState();
}

class _EntryFormState extends ConsumerState<EntryForm> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _fee;
  late final TextEditingController _date;
  late final TextEditingController _note;
  late EntryType _type;
  late String _account;
  String _to = '', _category = '', _parent = '';
  WorkspaceMeta? _scope;
  LedgerView? _openedView;
  LedgerTransaction? _currentEntry;
  bool _missing = false;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    _currentEntry = entry;
    final view = widget.openedView ?? ref.read(ledgerProvider).asData?.value;
    _type = entry?.type ?? EntryType.expense;
    _amount = TextEditingController(
      text: entry == null ? '' : decimalMoney(entry.amount),
    );
    _fee = TextEditingController(text: decimalMoney(entry?.fee ?? 0));
    _date = TextEditingController(
      text: widget.duplicate || entry == null ? localDateTime() : entry.date,
    );
    _note = TextEditingController(text: entry?.note ?? '');
    _account = entry?.accountId ?? view?.settings.defaultAccount ?? '';
    _to = entry?.toAccountId ?? '';
    _category = entry?.categoryId ?? '';
    _parent = view?.category(_category)?.parentId ?? '';
    _scope = view?.meta;
    _openedView = view;
  }

  @override
  void dispose() {
    _amount.dispose();
    _fee.dispose();
    _date.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || _missing || !(_form.currentState?.validate() ?? false)) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final scope = _scope;
      if (scope == null) throw const LedgerException('账本尚未打开，输入已保留。');
      final fee = _type == EntryType.transfer
          ? parseMoney(_fee.text, allowZero: true)
          : 0;
      final old = _currentEntry;
      final transaction = LedgerTransaction(
        id: old == null || widget.duplicate ? const Uuid().v4() : old.id,
        createdAt: old == null || widget.duplicate
            ? localDateTime()
            : old.createdAt,
        type: _type,
        amount: parseMoney(_amount.text),
        fee: fee,
        date: _date.text.trim(),
        accountId: _account,
        toAccountId: _type == EntryType.transfer ? _to : '',
        categoryId: _type == EntryType.transfer && fee == 0 ? '' : _category,
        note: _note.text.trim(),
      );
      final saved = await ref
          .read(ledgerProvider.notifier)
          .perform(
            (repository) => repository.saveTransaction(
              transaction,
              create: old == null || widget.duplicate,
              expectedWorkspace: scope.key,
              expectedSequence: scope.sequence,
            ),
            expectedScope: scope,
          );
      if (!mounted) return;
      if (saved) {
        Navigator.pop(context);
        showNotice(context, '账单已保存到本机');
      } else {
        setState(() {
          _error =
              ref.read(ledgerProvider).asData?.value.error ?? '未保存，请重试。输入仍保留。';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _recheck() async {
    try {
      final scope = _scope;
      if (scope == null) throw const LedgerException('账本尚未打开。输入已保留。');
      await ref.read(ledgerProvider.notifier).refresh();
      if (!mounted) return;
      final latest = ref.read(ledgerProvider).asData?.value;
      if (latest == null ||
          latest.meta.key != scope.key ||
          latest.error != null) {
        throw const LedgerException('账本已切换或读取未完成。请切回原账本后再核对，输入已保留。');
      }
      LedgerTransaction? currentEntry = _currentEntry;
      if (widget.entry != null && !widget.duplicate) {
        final repository = await ref.read(repositoryProvider.future);
        currentEntry = await repository.transactionById(
          widget.entry!.id,
          expectedWorkspace: latest.meta.key,
          expectedSequence: latest.meta.sequence,
        );
      }
      if (!mounted) return;
      setState(() {
        _scope = latest.meta;
        _openedView = latest;
        _currentEntry = currentEntry;
        _missing =
            widget.entry != null && !widget.duplicate && currentEntry == null;
        if (latest.account(_account) == null) _account = '';
        if (latest.account(_to) == null) _to = '';
        final selected = latest.category(_category);
        final type = _type == EntryType.transfer ? EntryType.expense : _type;
        if (selected == null ||
            selected.parentId == null ||
            selected.type != type) {
          _category = '';
        } else {
          _parent = selected.parentId!;
        }
        if (!latest.categories.any(
          (c) => c.id == _parent && c.parentId == null && c.type == type,
        )) {
          _parent = '';
        }
        _error = _missing ? '该账单已删除，不能继续编辑或重新创建。金额和备注草稿仍保留。' : null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _pickDate() async {
    final initial = DateTime.tryParse(_date.text) ?? DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (!mounted) return;
    _date.text = localDateTime(
      DateTime(
        day.year,
        day.month,
        day.day,
        time?.hour ?? initial.hour,
        time?.minute ?? initial.minute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(ledgerProvider).asData?.value;
    final view = _openedView ?? current;
    if (view == null) {
      return const Dialog(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      );
    }
    final accounts = view.accounts
        .where((a) => !a.archived || a.id == _account || a.id == _to)
        .toList();
    final categoryType = _type == EntryType.transfer
        ? EntryType.expense
        : _type;
    final parents = view.categories
        .where((c) => c.type == categoryType && c.parentId == null)
        .toList();
    final leaves = view.categories
        .where(
          (c) =>
              c.type == categoryType &&
              c.parentId != null &&
              (_parent.isEmpty || c.parentId == _parent),
        )
        .toList();
    return PopScope(
      canPop: !_saving,
      child: FormDialog(
        title: widget.entry == null
            ? '记一笔'
            : widget.duplicate
            ? '复制账单'
            : '编辑账单',
        subtitle: '保存后即写入本机，无需联网或登录。',
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('entry-save'),
            onPressed: _saving || _missing ? null : _save,
            child: Text(_saving ? '正在保存…' : '保存账单'),
          ),
        ],
        children: [
          Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: EntryType.values
                      .map(
                        (type) => ChoiceChip(
                          label: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(typeLabel(type)),
                          ),
                          selected: _type == type,
                          onSelected: _saving
                              ? null
                              : (_) => setState(() {
                                  _type = type;
                                  _category = '';
                                  _parent = '';
                                }),
                        ),
                      )
                      .toList(),
                ),
                const FieldSpace(),
                TextFormField(
                  key: const Key('entry-amount'),
                  controller: _amount,
                  autofocus: widget.entry == null,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: '金额',
                    prefixText: '¥ ',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  validator: (value) {
                    try {
                      parseMoney(value ?? '');
                      return null;
                    } catch (e) {
                      return e.toString();
                    }
                  },
                ),
                const FieldSpace(),
                DropdownButtonFormField<String>(
                  key: ValueKey('account-$_account-${accounts.length}'),
                  initialValue: accounts.any((a) => a.id == _account)
                      ? _account
                      : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: _type == EntryType.transfer ? '转出账户' : '账户',
                  ),
                  items: accounts
                      .map(
                        (a) => DropdownMenuItem(
                          value: a.id,
                          child: Text(
                            '${a.name}${a.archived ? '（已停用）' : ''}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _saving
                      ? null
                      : (value) => setState(() {
                          _account = value ?? '';
                        }),
                  validator: (_) => _account.isEmpty ? '请选择账户' : null,
                ),
                if (_type == EntryType.transfer) ...[
                  const FieldSpace(),
                  DropdownButtonFormField<String>(
                    key: ValueKey('to-$_to-${accounts.length}'),
                    initialValue: accounts.any((a) => a.id == _to) ? _to : null,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '转入账户'),
                    items: accounts
                        .map(
                          (a) => DropdownMenuItem(
                            value: a.id,
                            child: Text(
                              '${a.name}${a.archived ? '（已停用）' : ''}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _saving
                        ? null
                        : (value) => setState(() {
                            _to = value ?? '';
                          }),
                    validator: (_) =>
                        _to.isEmpty || _to == _account ? '请选择不同的转入账户' : null,
                  ),
                  const FieldSpace(),
                  TextFormField(
                    controller: _fee,
                    enabled: !_saving,
                    decoration: const InputDecoration(
                      labelText: '手续费',
                      prefixText: '¥ ',
                      helperText: '为 0 时无需分类；手续费计入支出。',
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) => setState(() {}),
                    validator: (value) {
                      try {
                        parseMoney(value ?? '', allowZero: true);
                        return null;
                      } catch (e) {
                        return e.toString();
                      }
                    },
                  ),
                ],
                if (_type != EntryType.transfer ||
                    (double.tryParse(_fee.text) ?? 0) > 0) ...[
                  const FieldSpace(),
                  DropdownButtonFormField<String>(
                    key: ValueKey('parent-$_parent-$_type'),
                    initialValue: parents.any((c) => c.id == _parent)
                        ? _parent
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '大类'),
                    items: parents
                        .map(
                          (c) => DropdownMenuItem(
                            value: c.id,
                            child: Text(
                              c.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _saving
                        ? null
                        : (value) => setState(() {
                            _parent = value ?? '';
                            _category = '';
                          }),
                  ),
                  const FieldSpace(),
                  DropdownButtonFormField<String>(
                    key: ValueKey('category-$_category-$_parent-$_type'),
                    initialValue: leaves.any((c) => c.id == _category)
                        ? _category
                        : null,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: _type == EntryType.transfer ? '手续费小类' : '小类',
                    ),
                    items: leaves
                        .map(
                          (c) => DropdownMenuItem(
                            value: c.id,
                            child: Text(
                              c.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _saving
                        ? null
                        : (value) => setState(() {
                            _category = value ?? '';
                            _parent = view.category(_category)?.parentId ?? '';
                          }),
                    validator: (_) => _category.isEmpty ? '请选择小类' : null,
                  ),
                ],
                const FieldSpace(),
                TextFormField(
                  controller: _date,
                  enabled: !_saving,
                  decoration: InputDecoration(
                    labelText: '日期和时间',
                    helperText: 'YYYY-MM-DDTHH:mm',
                    suffixIcon: IconButton(
                      onPressed: _saving ? null : _pickDate,
                      tooltip: '选择日期',
                      icon: const Icon(Icons.calendar_today_outlined),
                    ),
                  ),
                  validator: (value) =>
                      validDate(value ?? '') ? null : '日期和时间无效',
                ),
                const FieldSpace(),
                TextFormField(
                  key: const Key('entry-note'),
                  controller: _note,
                  enabled: !_saving,
                  minLines: 2,
                  maxLines: 4,
                  maxLength: 2000,
                  decoration: const InputDecoration(
                    labelText: '备注',
                    hintText: '记下用途、地点或心情，可留空',
                  ),
                ),
                if (_error case final error?) ...[
                  Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  TextButton(
                    onPressed: _saving ? null : _recheck,
                    child: const Text('重新读取并核对后再保存'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
