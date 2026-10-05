import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../app/controller.dart';
import '../app/theme.dart';
import '../data/ledger_repository.dart';
import 'common.dart';

import 'mutation_helpers.dart';

class AccountsPage extends ConsumerWidget {
  const AccountsPage({super.key, required this.view});
  final LedgerView view;
  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      SectionHeading(
        title: '账户',
        caption: '期初余额 + 收入 − 支出，转账按两个账户分别计算。',
        action: FilledButton.icon(
          onPressed: view.busy
              ? null
              : () => showDialog<void>(
                  context: context,
                  builder: (_) => AccountEditor(scope: view.meta),
                ),
          icon: const Icon(Icons.add),
          label: const Text('添加账户'),
        ),
      ),
      const SizedBox(height: 24),
      ...view.accounts.map(
        (account) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    Text(
                      '${account.name}${account.archived ? '（已归档）' : ''}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '¥${formatMoney(view.balances[account.id] ?? account.openingBalance)}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '期初余额 ¥${formatMoney(account.openingBalance)}',
                  style: const TextStyle(color: AppColors.muted),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: view.busy
                          ? null
                          : () => showDialog<void>(
                              context: context,
                              builder: (_) => AccountEditor(
                                account: account,
                                scope: view.meta,
                              ),
                            ),
                      child: const Text('编辑'),
                    ),
                    TextButton(
                      onPressed: view.busy
                          ? null
                          : () => mutate(
                              context,
                              ref,
                              (repo) => repo.archiveAccount(
                                account.id,
                                !account.archived,
                                expectedWorkspace: view.meta.key,
                                expectedSequence: view.meta.sequence,
                              ),
                              account.archived ? '账户已恢复' : '账户已归档，历史账单保留',
                              scope: view.meta,
                            ),
                      child: Text(account.archived ? '恢复' : '归档'),
                    ),
                    if (!account.archived)
                      TextButton(
                        onPressed:
                            view.busy ||
                                view.settings.defaultAccount == account.id
                            ? null
                            : () => mutate(
                                context,
                                ref,
                                (repo) => repo.updateSettings(
                                  view.settings.copyWith(
                                    defaultAccount: account.id,
                                  ),
                                  expectedWorkspace: view.meta.key,
                                  expectedSequence: view.meta.sequence,
                                ),
                                '默认账户已更新',
                                scope: view.meta,
                              ),
                        child: Text(
                          view.settings.defaultAccount == account.id
                              ? '默认账户'
                              : '设为默认',
                        ),
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

class AccountEditor extends ConsumerStatefulWidget {
  const AccountEditor({super.key, this.account, this.scope});
  final Account? account;
  final WorkspaceMeta? scope;
  @override
  ConsumerState<AccountEditor> createState() => _AccountEditorState();
}

class _AccountEditorState extends ConsumerState<AccountEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name, _balance;
  late String _kind;
  late WorkspaceMeta _scope;
  Account? _currentAccount;
  bool _missing = false;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _scope = widget.scope ?? ref.read(ledgerProvider).requireValue.meta;
    _currentAccount = widget.account;
    _name = TextEditingController(text: widget.account?.name ?? '');
    _balance = TextEditingController(
      text: decimalMoney(widget.account?.openingBalance ?? 0),
    );
    _kind = widget.account?.kind ?? 'bank';
  }

  @override
  void dispose() {
    _name.dispose();
    _balance.dispose();
    super.dispose();
  }

  int _parseBalance() =>
      (_balance.text.trim().startsWith('-') ? -1 : 1) *
      parseMoney(
        _balance.text.trim().replaceFirst(RegExp(r'^-'), ''),
        allowZero: true,
      );
  void _recheck(LedgerView view) {
    final latest = widget.account == null
        ? null
        : view.account(widget.account!.id);
    setState(() {
      _scope = view.meta;
      _currentAccount = latest;
      _missing = widget.account != null && latest == null;
    });
  }

  @override
  Widget build(BuildContext context) => FormDialog(
    title: widget.account == null ? '添加账户' : '编辑账户',
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy || _missing
            ? null
            : () async {
                if (!(_form.currentState?.validate() ?? false)) return;
                setState(() => _busy = true);
                final account = Account(
                  id: widget.account?.id ?? const Uuid().v4(),
                  name: _name.text.trim(),
                  kind: _kind,
                  openingBalance: _parseBalance(),
                  archived: _currentAccount?.archived ?? false,
                );
                final saved = await mutate(
                  context,
                  ref,
                  (repo) => repo.upsertAccount(
                    account,
                    expectedWorkspace: _scope.key,
                    expectedSequence: _scope.sequence,
                  ),
                  '账户已保存',
                  scope: _scope,
                );
                if (context.mounted) {
                  if (saved) {
                    Navigator.pop(context);
                  } else {
                    setState(() => _busy = false);
                  }
                }
              },
        child: Text(_busy ? '正在保存…' : '保存账户'),
      ),
    ],
    children: [
      if (_missing) const Text('该账户已删除或被替换，不能继续保存。输入已保留，请关闭后重新添加。'),
      if (_currentAccount?.archived == true)
        const Text('当前账户已归档，保存名称和余额会保留归档状态。'),
      DraftScopeNotice(scope: _scope, onRechecked: _recheck),
      Form(
        key: _form,
        child: Column(
          children: [
            TextFormField(
              controller: _name,
              maxLength: 60,
              decoration: const InputDecoration(labelText: '账户名称'),
              validator: (value) =>
                  (value ?? '').trim().isEmpty ? '请输入名称' : null,
            ),
            const FieldSpace(),
            DropdownButtonFormField<String>(
              initialValue:
                  [
                    'cash',
                    'bank',
                    'wechat',
                    'alipay',
                    'credit',
                    'other',
                  ].contains(_kind)
                  ? _kind
                  : 'other',
              decoration: const InputDecoration(labelText: '账户类型'),
              items: const [
                DropdownMenuItem(value: 'cash', child: Text('现金')),
                DropdownMenuItem(value: 'bank', child: Text('银行卡')),
                DropdownMenuItem(value: 'wechat', child: Text('微信')),
                DropdownMenuItem(value: 'alipay', child: Text('支付宝')),
                DropdownMenuItem(value: 'credit', child: Text('信用卡')),
                DropdownMenuItem(value: 'other', child: Text('其他')),
              ],
              onChanged: (value) => _kind = value ?? 'bank',
            ),
            const FieldSpace(),
            TextFormField(
              controller: _balance,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(
                labelText: '期初余额',
                prefixText: '¥ ',
                helperText: '负债可填写负数；历史收支会在此基础上计算。',
              ),
              validator: (_) {
                try {
                  _parseBalance();
                  return null;
                } catch (e) {
                  return e.toString();
                }
              },
            ),
          ],
        ),
      ),
    ],
  );
}
