import 'dart:async';

import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ledger_repository.dart';

final repositoryProvider = FutureProvider<LedgerRepository>((ref) async {
  LedgerRepository? repository;
  var disposed = false;
  ref.onDispose(() {
    disposed = true;
    final opened = repository;
    if (opened != null) {
      unawaited(
        opened.close().catchError((Object error, StackTrace stack) {
          FlutterError.reportError(
            FlutterErrorDetails(exception: error, stack: stack),
          );
        }),
      );
    }
  });
  final opened = await LedgerRepository.open();
  repository = opened;
  if (disposed) await opened.close();
  return opened;
}, retry: (_, _) => null);

final ledgerProvider = AsyncNotifierProvider<LedgerController, LedgerView>(
  LedgerController.new,
  retry: (_, _) => null,
);

String monthKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';
String dayKey(DateTime date) => localDateTime(date).substring(0, 10);

class LedgerView {
  factory LedgerView.fromSnapshot(
    LedgerReadViewData snapshot, {
    required DateTime month,
    List<String> alerts = const [],
  }) => LedgerView(
    meta: snapshot.meta,
    accounts: snapshot.accounts,
    categories: snapshot.categories,
    budgets: snapshot.budgets,
    balances: snapshot.balances,
    settings: snapshot.settings,
    summary: snapshot.summary,
    recent: snapshot.recent,
    month: month,
    alerts: alerts,
    storageWarning: snapshot.storageWarning,
  );
  const LedgerView({
    required this.meta,
    required this.accounts,
    required this.categories,
    required this.budgets,
    required this.balances,
    required this.settings,
    required this.summary,
    required this.recent,
    required this.month,
    this.busy = false,
    this.error,
    this.storageWarning,
    this.alerts = const [],
  });
  final WorkspaceMeta meta;
  final List<Account> accounts;
  final List<Category> categories;
  final List<BudgetStatus> budgets;
  final Map<String, int> balances;
  final LedgerSettings settings;
  final LedgerSummary summary;
  final TransactionPage recent;
  final DateTime month;
  final bool busy;
  final String? error;
  final String? storageWarning;
  final List<String> alerts;

  List<Account> get activeAccounts =>
      accounts.where((a) => !a.archived).toList();
  LedgerFilter get monthFilter => LedgerFilter(
    start: dayKey(DateTime(month.year, month.month)),
    end: dayKey(DateTime(month.year, month.month + 1, 0)),
  );
  Account? account(String id) {
    for (final row in accounts) {
      if (row.id == id) return row;
    }
    return null;
  }

  Category? category(String id) {
    for (final row in categories) {
      if (row.id == id) return row;
    }
    return null;
  }

  String categoryName(LedgerTransaction row) {
    if (row.type == EntryType.transfer) return '转账';
    final leaf = category(row.categoryId);
    return leaf == null
        ? '未分类'
        : '${category(leaf.parentId ?? '')?.name ?? ''} / ${leaf.name}';
  }

  String accountName(LedgerTransaction row) => row.type == EntryType.transfer
      ? '${account(row.accountId)?.name ?? '账户'} → ${account(row.toAccountId)?.name ?? '账户'}'
      : account(row.accountId)?.name ?? '账户';
  LedgerView copyWith({
    bool? busy,
    String? error,
    String? storageWarning,
    List<String>? alerts,
  }) => LedgerView(
    meta: meta,
    accounts: accounts,
    categories: categories,
    budgets: budgets,
    balances: balances,
    settings: settings,
    summary: summary,
    recent: recent,
    month: month,
    busy: busy ?? this.busy,
    error: error,
    storageWarning: storageWarning ?? this.storageWarning,
    alerts: alerts ?? this.alerts,
  );
}

class LedgerController extends AsyncNotifier<LedgerView> {
  LedgerRepository? _repository;
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  int _generation = 0;
  int _lifecycle = 0;
  bool _disposed = false;
  bool _mutating = false;
  bool _initializing = false;
  final List<String> _pendingAlerts = [];

  @override
  Future<LedgerView> build() async {
    final lifecycle = ++_lifecycle;
    _disposed = false;
    _mutating = false;
    _initializing = true;
    _pendingAlerts.clear();
    ref.onDispose(() {
      _disposed = true;
      ++_lifecycle;
      _repository = null;
    });
    final repository = await ref.watch(repositoryProvider.future);
    if (_disposed || lifecycle != _lifecycle) throw StateError('账本读取已取消');
    _repository = repository;
    final subscription = repository.changes.listen(
      (_) {
        if (!_mutating && !_disposed && lifecycle == _lifecycle) {
          if (_initializing) {
            ++_generation;
          } else {
            unawaited(refresh());
          }
        }
      },
      onError: (Object error) {
        final current = state.asData?.value;
        if (current != null && !_disposed && lifecycle == _lifecycle) {
          state = AsyncData(current.copyWith(error: error.toString()));
        }
      },
    );
    ref.onDispose(() => unawaited(subscription.cancel()));
    final notifications = repository.budgetNotifications.listen(
      (message) {
        if (_disposed || lifecycle != _lifecycle) return;
        _pendingAlerts.add(message);
        if (_pendingAlerts.length > 6) _pendingAlerts.removeAt(0);
        final current = state.asData?.value;
        if (!_mutating && current != null) {
          state = AsyncData(current.copyWith(alerts: List.of(_pendingAlerts)));
        }
      },
      onError: (Object error) {
        final current = state.asData?.value;
        if (!_disposed && lifecycle == _lifecycle && current != null) {
          state = AsyncData(current.copyWith(error: '预算提醒读取失败：$error'));
        }
      },
    );
    ref.onDispose(() => unawaited(notifications.cancel()));
    try {
      while (true) {
        final generation = _generation;
        final next = await _load(repository);
        if (_disposed || lifecycle != _lifecycle) throw StateError('账本读取已取消');
        if (generation == _generation) return next;
      }
    } finally {
      if (lifecycle == _lifecycle) _initializing = false;
    }
  }

  Future<LedgerView> _load(LedgerRepository repository) async {
    final month = _month;
    final filter = LedgerFilter(
      start: dayKey(DateTime(month.year, month.month)),
      end: dayKey(DateTime(month.year, month.month + 1, 0)),
    );
    final snapshot = await repository.readViewData(
      month: monthKey(month),
      filter: filter,
      recentLimit: 12,
    );
    return LedgerView.fromSnapshot(
      snapshot,
      month: month,
      alerts: List.of(_pendingAlerts),
    );
  }

  Future<void> refresh() async {
    final repository = _repository;
    if (repository == null || _disposed || _mutating) return;
    final generation = ++_generation;
    final lifecycle = _lifecycle;
    try {
      final next = await _load(repository);
      if (!_disposed && lifecycle == _lifecycle && generation == _generation) {
        state = AsyncData(next);
        _pendingAlerts.clear();
      }
    } catch (error, stack) {
      if (_disposed || lifecycle != _lifecycle || generation != _generation) {
        return;
      }
      final current = state.asData?.value;
      state = current == null
          ? AsyncError(error, stack)
          : AsyncData(current.copyWith(error: '读取失败：$error'));
    }
  }

  Future<void> changeMonth(DateTime month) async {
    if (_mutating) return;
    _month = DateTime(month.year, month.month);
    await refresh();
  }

  Future<bool> perform(
    Future<void> Function(LedgerRepository repository) action, {
    WorkspaceMeta? expectedScope,
  }) async {
    final current = state.asData?.value;
    final repository = _repository;
    if (current == null || repository == null || _mutating) return false;
    if (expectedScope != null &&
        (current.meta.key != expectedScope.key ||
            current.meta.sequence != expectedScope.sequence)) {
      state = AsyncData(
        current.copyWith(error: '账本已变化，输入已保留。请切回打开表单的账本，重新读取并核对后保存。'),
      );
      return false;
    }
    _mutating = true;
    final lifecycle = _lifecycle;
    ++_generation;
    state = AsyncData(current.copyWith(busy: true));
    var committed = false;
    try {
      await action(repository);
      committed = true;
      final next = await _load(repository);
      if (!_disposed && lifecycle == _lifecycle) {
        state = AsyncData(next);
        _pendingAlerts.clear();
      }
      return true;
    } catch (error) {
      var message = error.toString();
      if (error is LedgerBackupCleanupFailure &&
          error.committed &&
          error.ledgerChanged) {
        committed = true;
        try {
          final next = await _load(repository);
          if (!_disposed && lifecycle == _lifecycle) {
            state = AsyncData(next.copyWith(storageWarning: message));
            _pendingAlerts.clear();
          }
          return true;
        } catch (refreshError) {
          message = '$message\n刷新失败，请重新读取：$refreshError';
        }
      } else if (committed) {
        message = '已保存。刷新失败，请重新读取：$error';
      }
      if (!_disposed && lifecycle == _lifecycle) {
        state = AsyncData(current.copyWith(error: message));
      }
      return committed;
    } finally {
      if (lifecycle == _lifecycle) _mutating = false;
    }
  }
}
