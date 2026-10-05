import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/app/controller.dart';
import 'package:jianzhang/app/services.dart';
import 'package:jianzhang/app/theme.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:jianzhang/main.dart';
import 'package:jianzhang/services/cloud_service.dart';
import 'package:jianzhang/ui/entry_form.dart';
import 'package:jianzhang/ui/ledger_pages.dart';
import 'package:jianzhang/ui/manage_pages.dart';
import 'package:jianzhang/ui/search_form.dart';
import 'package:jianzhang/ui/settings_page.dart';
import 'package:jianzhang/ui/shell.dart';
import 'package:path/path.dart' as p;

class UiFixture {
  UiFixture(this.directory, this.repository, this.root);
  final Directory directory;
  final LedgerRepository repository;
  final String root;
  static Future<UiFixture> open() async {
    final root = Directory(p.join(Directory.current.path, '.qa', 'ui'));
    await root.create(recursive: true);
    final directory = await root.createTemp('fixture-');
    final repository = await LedgerRepository.open(
      path: p.join(directory.path, 'ledger.sqlite'),
    );
    return UiFixture(directory, repository, await root.resolveSymbolicLinks());
  }

  Future<void> close() async {
    await repository.close();
    final actual = await directory.resolveSymbolicLinks();
    if (!p.isWithin(root, actual)) {
      throw StateError('UI fixture escaped its test directory');
    }
    await Directory(actual).delete(recursive: true);
  }

  Future<void> seed() async {
    final accounts = await repository.listAccounts();
    final leaf = (await repository.listCategories(
      type: EntryType.expense,
    )).firstWhere((c) => c.parentId != null);
    await repository.saveTransaction(
      LedgerTransaction(
        id: 'layout-sample',
        type: EntryType.expense,
        amount: 123456789,
        date: localDateTime(),
        createdAt: localDateTime(),
        accountId: accounts.first.id,
        categoryId: leaf.id,
        note: '一条较长的备注，用来核对窄屏与大字体的显示，包含中文、账户说明和金额。',
      ),
      create: true,
    );
    await repository.upsertBudget(
      Budget(month: monthKey(DateTime.now()), amount: 100000, threshold: 80),
    );
  }
}

class TestCloud extends CloudService {
  int calls = 0;
  int uploads = 0;
  @override
  Future<CloudSession?> session() async {
    calls++;
    return null;
  }

  @override
  Future<SmsChallenge> sendCode(String phone) async {
    calls++;
    throw const CloudFailure('短信服务未配置，请继续本机记账。', 503, 'SMS_NOT_CONFIGURED');
  }

  @override
  Future<int> upload(
    Map<String, dynamic> ledger, {
    required int revision,
    required String expectedUserId,
  }) async {
    uploads++;
    throw StateError('Unexpected upload');
  }
}

class ConflictCloud extends CloudService {
  ConflictCloud(this.snapshot, this.status);
  final Map<String, dynamic> snapshot;
  final int status;
  int downloads = 0;
  int uploads = 0;
  int sessionReads = 0;
  @override
  Future<CloudSession?> session() async {
    sessionReads++;
    return const CloudSession(
      user: CloudUser(userId: 'test-user', name: '138****8000', kind: 'phone'),
      expires: 9999999999999,
    );
  }

  @override
  Future<CloudSnapshot> download() async {
    downloads++;
    return CloudSnapshot(
      ledger: snapshot,
      revision: downloads,
      user: const CloudUser(
        userId: 'test-user',
        name: '138****8000',
        kind: 'phone',
      ),
    );
  }

  @override
  Future<int> upload(
    Map<String, dynamic> ledger, {
    required int revision,
    required String expectedUserId,
  }) async {
    uploads++;
    throw CloudFailure(
      status == 409 ? '云端已有更新' : '登录已过期',
      status,
      status == 409 ? 'REVISION' : 'SESSION',
    );
  }
}

class SaveFailureRepository implements LedgerRepository {
  SaveFailureRepository(this.delegate);
  final LedgerRepository delegate;
  @override
  Future<LedgerReadViewData> readViewData({
    required String month,
    LedgerFilter filter = const LedgerFilter(),
    int recentLimit = 12,
    String? expectedWorkspace,
    int? expectedSequence,
  }) => delegate.readViewData(
    month: month,
    filter: filter,
    recentLimit: recentLimit,
    expectedWorkspace: expectedWorkspace,
    expectedSequence: expectedSequence,
  );
  @override
  Stream<int> get changes => delegate.changes;
  @override
  Stream<String> get budgetNotifications => delegate.budgetNotifications;
  @override
  Future<WorkspaceMeta> meta() => delegate.meta();
  @override
  Future<List<Account>> listAccounts({bool includeArchived = true}) =>
      delegate.listAccounts(includeArchived: includeArchived);
  @override
  Future<List<Category>> listCategories({EntryType? type}) =>
      delegate.listCategories(type: type);
  @override
  Future<List<BudgetStatus>> budgetStatuses(String month) =>
      delegate.budgetStatuses(month);
  @override
  Future<Map<String, int>> balances() => delegate.balances();
  @override
  Future<LedgerSettings> settings() => delegate.settings();
  @override
  Future<LedgerSummary> summary({LedgerFilter filter = const LedgerFilter()}) =>
      delegate.summary(filter: filter);
  @override
  Future<TransactionPage> search(
    LedgerFilter filter, {
    int offset = 0,
    int limit = 50,
    String? expectedWorkspace,
    int? expectedSequence,
  }) => delegate.search(
    filter,
    offset: offset,
    limit: limit,
    expectedWorkspace: expectedWorkspace,
    expectedSequence: expectedSequence,
  );
  @override
  Future<void> saveTransaction(
    LedgerTransaction entry, {
    bool create = false,
    String? expectedWorkspace,
    int? expectedSequence,
  }) => Future.error(const LedgerException('写入失败，输入已保留'));
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

Widget appWith(LedgerRepository repository, {CloudService? cloud}) =>
    ProviderScope(
      overrides: [
        repositoryProvider.overrideWith((ref) => repository),
        if (cloud != null) cloudServiceProvider.overrideWithValue(cloud),
      ],
      child: const JianzhangApp(),
    );

Future<void> selectDropdown(
  WidgetTester tester,
  String label,
  String value,
) async {
  await tester.ensureVisible(find.text(label).last);
  await tester.tap(find.text(label).last);
  await settleUi(tester);
  await tester.tap(find.text(value).last);
  await settleUi(tester);
}

Future<void> settleUi(WidgetTester tester) async {
  var stable = 0;
  for (var frame = 0; frame < 1000; frame++) {
    await tester.pump(const Duration(milliseconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (!tester.binding.hasScheduledFrame) {
      stable++;
      if (stable >= 3) return;
    } else {
      stable = 0;
    }
  }
  throw TestFailure('Native UI did not settle after database I/O');
}

Future<void> waitForUi(WidgetTester tester, Finder finder) async {
  for (var frame = 0; frame < 400; frame++) {
    await tester.pump(const Duration(milliseconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (finder.evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 400));
      return;
    }
  }
  throw TestFailure('Native UI did not display $finder');
}

void ioWidgetTest(
  String description,
  Future<void> Function(WidgetTester) callback,
) {
  testWidgets(description, (tester) async {
    await tester.runAsync(() => callback(tester));
  });
}

void main() {
  for (final status in [401, 409]) {
    ioWidgetTest('cloud $status preserves local ledger and conflict copies', (
      tester,
    ) async {
      final fixture = await UiFixture.open();
      await fixture.seed();
      final original = await fixture.repository.meta();
      final snapshot = Map<String, dynamic>.from(
        await fixture.repository.cloudSnapshot(),
      );
      final cloud = ConflictCloud(snapshot, status);
      addTearDown(cloud.close);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(fixture.close);
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWith((ref) => fixture.repository),
            cloudServiceProvider.overrideWithValue(cloud),
          ],
          child: MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => ref
                    .watch(ledgerProvider)
                    .when(
                      data: (view) =>
                          ListView(children: [CloudPanel(view: view)]),
                      loading: () => const CircularProgressIndicator(),
                      error: (error, _) => Text(error.toString()),
                    ),
              ),
            ),
          ),
        ),
      );
      await settleUi(tester);
      expect(cloud.sessionReads, 0);
      expect(cloud.uploads, 0);
      await tester.tap(find.text('同步并选择账本'));
      await waitForUi(tester, find.text('选择账本来源'));
      expect(find.text('选择账本来源'), findsOneWidget);
      expect(cloud.uploads, 0);
      await tester.ensureVisible(find.text('保存本机到云端'));
      await tester.tap(find.text('保存本机到云端'));
      await settleUi(tester);
      final after = await fixture.repository.meta();
      expect(after.key, original.key);
      expect(after.transactionCount, original.transactionCount);
      expect(after.sequence, original.sequence);
      expect(cloud.uploads, 1);
      expect(
        (await fixture.repository.listBackups()).length,
        status == 409 ? 2 : 1,
      );
      expect(tester.takeException(), isNull);
    });
  }
  ioWidgetTest(
    'first offline launch records locally without calling login or cloud',
    (tester) async {
      final fixture = await UiFixture.open();
      final cloud = TestCloud();
      addTearDown(cloud.close);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(fixture.close);
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(appWith(fixture.repository, cloud: cloud));
      await settleUi(tester);
      expect(find.text('收支概览'), findsOneWidget);
      expect(cloud.calls, 0);
      await tester.tap(find.byKey(const Key('add-entry')));
      await settleUi(tester);
      await tester.enterText(find.byKey(const Key('entry-amount')), '12.34');
      final categories = await fixture.repository.listCategories(
        type: EntryType.expense,
      );
      final parent = categories.firstWhere((c) => c.parentId == null);
      final child = categories.firstWhere((c) => c.parentId == parent.id);
      await selectDropdown(tester, '大类', parent.name);
      await selectDropdown(tester, '小类', child.name);
      await tester.ensureVisible(find.byKey(const Key('entry-note')));
      await tester.enterText(find.byKey(const Key('entry-note')), '公交 去公司');
      await tester.ensureVisible(find.byKey(const Key('entry-save')));
      await tester.tap(find.byKey(const Key('entry-save')));
      await settleUi(tester);
      final page = await fixture.repository.search(const LedgerFilter());
      expect(page.total, 1);
      expect(page.items.single.amount, 1234);
      expect(page.items.single.note, '公交 去公司');
      expect(cloud.calls, 0);
      expect(cloud.uploads, 0);
      expect(tester.takeException(), isNull);
    },
  );

  ioWidgetTest(
    'storage failure retains form and never reports a saved transaction',
    (tester) async {
      final fixture = await UiFixture.open();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(fixture.close);
      });
      await tester.pumpWidget(
        appWith(SaveFailureRepository(fixture.repository)),
      );
      await settleUi(tester);
      final accounts = await fixture.repository.listAccounts();
      final leaf = (await fixture.repository.listCategories(
        type: EntryType.expense,
      )).firstWhere((c) => c.parentId != null);
      final entry = LedgerTransaction(
        id: 'template',
        type: EntryType.expense,
        amount: 1234,
        date: localDateTime(),
        createdAt: localDateTime(),
        accountId: accounts.first.id,
        categoryId: leaf.id,
        note: '不能丢失',
      );

      // Use a descendant of the MaterialApp navigator.
      final shellContext = tester.element(find.byType(Scaffold).first);
      unawaited(showEntry(shellContext, entry: entry, duplicate: true));
      await settleUi(tester);
      await tester.ensureVisible(find.byKey(const Key('entry-save')));
      await tester.tap(find.byKey(const Key('entry-save')));
      await settleUi(tester);
      expect(find.byType(EntryForm), findsOneWidget);
      expect(find.text('写入失败，输入已保留'), findsWidgets);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('entry-note')))
            .controller
            ?.text,
        '不能丢失',
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('entry-amount')))
            .controller
            ?.text,
        '12.34',
      );
      expect((await fixture.repository.meta()).transactionCount, 0);

      expect(tester.takeException(), isNull);
    },
  );

  ioWidgetTest(
    'missing SMS configuration is explicit and local usage remains available',
    (tester) async {
      final fixture = await UiFixture.open();
      final cloud = TestCloud();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(fixture.close);
      });
      addTearDown(cloud.close);
      await tester.pumpWidget(appWith(fixture.repository, cloud: cloud));
      await settleUi(tester);
      final context = tester.element(find.byType(Scaffold).first);
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const PhoneLoginDialog(),
        ),
      );
      await settleUi(tester);
      await tester.enterText(find.byType(TextField).first, '13800138000');
      await tester.tap(find.text('接收短信验证码'));
      await settleUi(tester);
      expect(find.text('短信服务未配置，请继续本机记账。'), findsOneWidget);
      expect(cloud.uploads, 0);
      await tester.ensureVisible(find.text('继续本机使用'));
      await tester.tap(find.text('继续本机使用'));
      await settleUi(tester);
      expect(find.byKey(const Key('add-entry')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  ioWidgetTest('loading and storage error have a recoverable native screen', (
    tester,
  ) async {
    final completer = Completer<LedgerRepository>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWith((ref) => completer.future)],
        child: const JianzhangApp(),
      ),
    );
    await tester.pump();
    expect(find.text('正在打开本机账本…'), findsOneWidget);
    completer.completeError(const LedgerException('磁盘不可用'));
    await settleUi(tester);
    expect(find.text('本机账本暂时无法打开'), findsOneWidget);
    expect(find.text('重新打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  final pageBuilders = <String, Widget Function(LedgerView)>{
    'home': (v) => HomePage(view: v, onBills: () {}),
    'bills': (v) => BillsPage(view: v),
    'reports': (v) => ReportsPage(view: v, onDrill: (_) {}),
    'accounts': (v) => AccountsPage(view: v),
    'categories': (v) => CategoriesPage(view: v),
    'budgets': (v) => BudgetsPage(view: v),
    'settings': (v) => SettingsPage(view: v),
    'entry': (v) => const EntryForm(),
    'search': (v) => SearchForm(view: v, filter: const LedgerFilter()),
  };
  for (final size in const [Size(1280, 600), Size(800, 360)]) {
    ioWidgetTest('shell navigation and add remain usable at $size', (
      tester,
    ) async {
      final fixture = await UiFixture.open();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(fixture.close);
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            repositoryProvider.overrideWith((ref) => fixture.repository),
          ],
          child: MaterialApp(
            theme: buildAppTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.6)),
              child: child!,
            ),
            home: const LedgerShell(),
          ),
        ),
      );
      await settleUi(tester);
      await tester.ensureVisible(find.byKey(const Key('add-entry')));
      await tester.tap(find.byKey(const Key('add-entry')));
      await settleUi(tester);
      expect(find.byType(EntryForm), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  for (final width in [360.0, 390.0, 412.0, 600.0, 1440.0]) {
    for (final entry in pageBuilders.entries) {
      ioWidgetTest('${entry.key} fits $width with large text and keyboard', (
        tester,
      ) async {
        final fixture = await UiFixture.open();
        await fixture.seed();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await tester.runAsync(fixture.close);
        });
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              repositoryProvider.overrideWith((ref) => fixture.repository),
            ],
            child: MaterialApp(
              theme: buildAppTheme(),
              home: Consumer(
                builder: (context, ref, _) {
                  final data = ref.watch(ledgerProvider);
                  return MediaQuery(
                    data: MediaQueryData(
                      size: Size(width, 1000),
                      textScaler: const TextScaler.linear(1.6),
                      viewInsets: const EdgeInsets.only(bottom: 250),
                    ),
                    child: Scaffold(
                      body: data.when(
                        data: entry.value,
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (error, stack) => Text(error.toString()),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await settleUi(tester);
        if (entry.key == 'search') {
          await tester.ensureVisible(find.text('大类与小类'));
          await tester.tap(find.text('大类与小类'));
          await settleUi(tester);
          await tester.ensureVisible(find.text('账户').last);
          await tester.tap(find.text('账户').last);
          await settleUi(tester);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    }
  }
}
