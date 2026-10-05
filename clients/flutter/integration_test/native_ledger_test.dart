import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jianzhang/app/controller.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:jianzhang/main.dart';
import 'package:jianzhang/ui/entry_form.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native offline expense income transfer and restart', (
    tester,
  ) async {
    final temporary = await getTemporaryDirectory();
    final root = Directory(p.join(temporary.path, 'jianzhang-native-qa'));
    await root.create(recursive: true);
    final intendedRoot = await root.resolveSymbolicLinks();
    final fixture = await root.createTemp('ledger-');
    final database = p.join(fixture.path, 'ledger.sqlite');
    var repository = await LedgerRepository.open(path: database);
    final capture = GlobalKey();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await repository.close();
      final actual = await fixture.resolveSymbolicLinks();
      if (!p.isWithin(intendedRoot, actual)) {
        throw StateError('Native QA fixture escaped its directory');
      }
      await Directory(actual).delete(recursive: true);
    });
    Future<void> mount() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [repositoryProvider.overrideWith((ref) => repository)],
          child: RepaintBoundary(key: capture, child: const JianzhangApp()),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> screenshot(String name) async {
      await tester.pumpAndSettle();
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final raster = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await raster.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) throw StateError('Screenshot encoding failed');
        final artifacts = Directory(p.join(root.path, 'artifacts'));
        await artifacts.create(recursive: true);
        final file = File(
          p.join(artifacts.path, '${Platform.operatingSystem}-$name.png'),
        );
        await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
        debugPrint('jianzhang.screenshot=${file.path}');
      } finally {
        raster.dispose();
      }
    }

    await mount();
    expect(find.text('收支概览'), findsOneWidget);
    expect(find.byKey(const Key('add-entry')), findsOneWidget);
    await screenshot('empty-home');
    final account = (await repository.listAccounts()).first;
    final second = Account(id: 'integration-savings', name: '储蓄账户');
    await repository.upsertAccount(second);
    await tester.pumpAndSettle();
    final categories = await repository.listCategories();
    for (final type in EntryType.values) {
      final leaf = categories.firstWhere(
        (c) =>
            c.type == (type == EntryType.transfer ? EntryType.expense : type) &&
            c.parentId != null,
      );
      final row = LedgerTransaction(
        id: 'template-${type.name}',
        type: type,
        amount: type == EntryType.income ? 500000 : 1234,
        fee: type == EntryType.transfer ? 25 : 0,
        date: localDateTime(),
        createdAt: localDateTime(),
        accountId: account.id,
        toAccountId: type == EntryType.transfer ? second.id : '',
        categoryId: leaf.id,
        note: '原生端验证：${type.name}',
      );
      final context = tester.element(find.byType(Scaffold).first);
      unawaited(showEntry(context, entry: row, duplicate: true));
      await tester.pumpAndSettle();
      await screenshot('entry-${type.name}');
      await tester.ensureVisible(find.byKey(const Key('entry-save')));
      await tester.tap(find.byKey(const Key('entry-save')));
      await tester.pumpAndSettle();
      expect(find.byType(EntryForm), findsNothing);
      expect(tester.takeException(), isNull);
    }
    final summary = await repository.summary();
    expect(summary.income, 500000);
    expect(summary.expense, 1259);
    expect((await repository.balances())[second.id], 1234);
    await screenshot('populated-home');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await repository.close();
    repository = await LedgerRepository.open(path: database);
    await mount();
    expect((await repository.meta()).transactionCount, 3);
    expect(find.text('收支概览'), findsOneWidget);
    await screenshot('restart-home');
  });
}
