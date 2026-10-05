import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/controller.dart';
import '../app/theme.dart';
import '../data/ledger_repository.dart';
import 'common.dart';
import 'entry_form.dart';
import 'ledger_pages.dart';
import 'manage_pages.dart';
import 'search_form.dart';
import 'settings_page.dart';

class NewEntryIntent extends Intent {
  const NewEntryIntent();
}

class SearchIntent extends Intent {
  const SearchIntent();
}

class RefreshIntent extends Intent {
  const RefreshIntent();
}

class LedgerShell extends ConsumerStatefulWidget {
  const LedgerShell({super.key});
  @override
  ConsumerState<LedgerShell> createState() => _LedgerShellState();
}

class _LedgerShellState extends ConsumerState<LedgerShell> {
  int _page = 0;
  LedgerFilter? _filter;
  bool _reportedReady = false;
  final _readyWatch = Stopwatch()..start();
  static const _pages = [
    ('首页', Icons.home_outlined),
    ('账单', Icons.receipt_long_outlined),
    ('报表', Icons.bar_chart_outlined),
    ('更多', Icons.grid_view_outlined),
    ('账户', Icons.account_balance_wallet_outlined),
    ('分类', Icons.category_outlined),
    ('预算', Icons.savings_outlined),
    ('数据与设置', Icons.settings_outlined),
  ];
  void _reportReady() {
    if (_reportedReady) return;
    _reportedReady = true;
    unawaited(_reportNativeReady());
  }

  Future<void> _reportNativeReady() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _readyWatch.stop();
    debugPrint('jianzhang.local_load_ms=${_readyWatch.elapsedMilliseconds}');
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.windows)) {
      return;
    }
    try {
      final result = await const MethodChannel(
        'jianzhang/performance',
      ).invokeMapMethod<String, dynamic>('reportFullyDrawn');
      final readyMs = result?['readyMs'];
      if (readyMs is! int || readyMs < 0) {
        throw PlatformException(
          code: 'PERFORMANCE_INVALID',
          message: '原生启动计时返回无效数据',
        );
      }
      debugPrint('jianzhang.native_ready_ms=$readyMs');
    } on MissingPluginException {
      /* Widget tests do not load platform plugins. */
    } on PlatformException catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    }
  }

  Future<void> _search(LedgerView view) async {
    final filter = await showDialog<LedgerFilter>(
      context: context,
      builder: (_) =>
          SearchForm(view: view, filter: _filter ?? const LedgerFilter()),
    );
    if (filter != null && mounted) {
      setState(() {
        _page = 1;
        _filter = filter;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(ledgerProvider, (previous, next) {
      final oldAlerts = previous?.asData?.value.alerts ?? const <String>[];
      final alerts = next.asData?.value.alerts ?? const <String>[];
      for (final message in alerts.where((item) => !oldAlerts.contains(item))) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) showNotice(this.context, message);
        });
      }
    });
    final ledger = ref.watch(ledgerProvider);
    return ledger.when(
      loading: () => const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 20),
              Text('正在打开本机账本…'),
            ],
          ),
        ),
      ),
      error: (error, stack) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: EmptyNotice(
              title: '本机账本暂时无法打开',
              message: '$error\n已有账本不会被清空。',
              icon: Icons.error_outline,
              action: OutlinedButton(
                onPressed: () {
                  ref.invalidate(repositoryProvider);
                  ref.invalidate(ledgerProvider);
                },
                child: const Text('重新打开'),
              ),
            ),
          ),
        ),
      ),
      data: (view) {
        _reportReady();
        final wide = MediaQuery.sizeOf(context).width >= 1000;
        return Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.keyN, control: true):
                NewEntryIntent(),
            SingleActivator(LogicalKeyboardKey.keyF, control: true):
                SearchIntent(),
            SingleActivator(LogicalKeyboardKey.keyR, control: true):
                RefreshIntent(),
          },
          child: Actions(
            actions: {
              NewEntryIntent: CallbackAction<NewEntryIntent>(
                onInvoke: (_) {
                  if (!view.busy) showEntry(context);
                  return null;
                },
              ),
              SearchIntent: CallbackAction<SearchIntent>(
                onInvoke: (_) {
                  _search(view);
                  return null;
                },
              ),
              RefreshIntent: CallbackAction<RefreshIntent>(
                onInvoke: (_) {
                  ref.read(ledgerProvider.notifier).refresh();
                  return null;
                },
              ),
            },
            child: Focus(
              autofocus: true,
              child: Scaffold(
                appBar: AppBar(
                  leading: !wide && _page > 3
                      ? IconButton(
                          tooltip: '返回更多',
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () => setState(() {
                            _page = 3;
                          }),
                        )
                      : null,
                  title: Text(_page <= 3 || wide ? '简账' : _pages[_page].$1),
                  actions: [
                    if (wide)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Center(
                          child: Text(
                            'Ctrl+N 记账 · Ctrl+F 搜索',
                            style: TextStyle(color: AppColors.muted),
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: '组合查询',
                      onPressed: () => _search(view),
                      icon: const Icon(Icons.search),
                    ),
                  ],
                ),
                body: SafeArea(
                  top: false,
                  bottom: false,
                  child: Row(
                    children: [
                      if (wide)
                        SizedBox(
                          width: 220,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: ListView(
                                    children: [
                                      ...[0, 1, 2, 4, 5, 6, 7].map(
                                        (index) => Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 4,
                                          ),
                                          child: ListTile(
                                            selected: _page == index,
                                            selectedTileColor: const Color(
                                              0xFFE4EFE7,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            leading: Icon(_pages[index].$2),
                                            title: Text(_pages[index].$1),
                                            onTap: () => setState(() {
                                              _page = index;
                                            }),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  view.meta.key == 'guest' ? '本机账本' : '账号本机账本',
                                  style: const TextStyle(
                                    color: AppColors.muted,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  view.busy ? '正在保存…' : '本机已保存',
                                  style: const TextStyle(
                                    color: AppColors.primary,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                FilledButton.icon(
                                  key: const Key('add-entry'),
                                  onPressed: view.busy
                                      ? null
                                      : () => showEntry(context),
                                  icon: const Icon(Icons.add),
                                  label: const Text('记一笔'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Expanded(
                        child: Column(
                          children: [
                            if (view.busy) const LinearProgressIndicator(),
                            if (view.storageWarning case final warning?)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 8,
                                ),
                                child: Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    warning,
                                    key: const Key('storage-warning'),
                                    style: const TextStyle(
                                      color: AppColors.muted,
                                    ),
                                  ),
                                ),
                              ),
                            if (view.error case final error?)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 8,
                                ),
                                child: Text(
                                  error,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ),
                            Expanded(
                              child: switch (_page) {
                                0 => HomePage(
                                  view: view,
                                  onBills: () => setState(() {
                                    _page = 1;
                                    _filter = null;
                                  }),
                                ),
                                1 => BillsPage(
                                  view: view,
                                  initialFilter: _filter,
                                ),
                                2 => ReportsPage(
                                  view: view,
                                  onDrill: (filter) => setState(() {
                                    _page = 1;
                                    _filter = filter;
                                  }),
                                ),
                                4 => AccountsPage(view: view),
                                5 => CategoriesPage(view: view),
                                6 => BudgetsPage(view: view),
                                7 => SettingsPage(view: view),
                                _ => ListView(
                                  padding: const EdgeInsets.all(24),
                                  children: [
                                    const SectionHeading(
                                      title: '管理账本',
                                      caption: '账户、分类、预算与数据都在这里。',
                                    ),
                                    const SizedBox(height: 20),
                                    ...[4, 5, 6, 7].map(
                                      (index) => Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 12,
                                        ),
                                        child: SoftCard(
                                          padding: 4,
                                          child: ListTile(
                                            minVerticalPadding: 16,
                                            leading: Icon(_pages[index].$2),
                                            title: Text(_pages[index].$1),
                                            trailing: const Icon(
                                              Icons.chevron_right,
                                            ),
                                            onTap: () => setState(() {
                                              _page = index;
                                            }),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                bottomNavigationBar: wide
                    ? null
                    : SafeArea(
                        top: false,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              child: SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  key: const Key('add-entry'),
                                  onPressed: view.busy
                                      ? null
                                      : () => showEntry(context),
                                  icon: const Icon(Icons.add),
                                  label: const Text('记一笔'),
                                ),
                              ),
                            ),
                            NavigationBar(
                              selectedIndex: _page >= 3 ? 3 : _page,
                              onDestinationSelected: (index) => setState(() {
                                _page = index;
                              }),
                              destinations: _pages
                                  .take(4)
                                  .map(
                                    (page) => NavigationDestination(
                                      icon: Icon(page.$2),
                                      label: page.$1,
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}
