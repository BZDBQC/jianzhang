import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jianzhang/app/controller.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:jianzhang/main.dart';
import 'package:jianzhang/ui/ledger_pages.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const roundId = String.fromEnvironment(
  'JIANZHANG_QA_ROUND',
  defaultValue: 'manual',
);
const buildId = String.fromEnvironment(
  'JIANZHANG_QA_BUILD',
  defaultValue: 'unassigned',
);
const configurationSha256 = String.fromEnvironment(
  'JIANZHANG_QA_CONFIGURATION_SHA256',
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('native 100k profile measurements and responsive exports', (
    tester,
  ) async {
    expect(
      kProfileMode || kReleaseMode,
      isTrue,
      reason: 'Debug timings are not acceptance evidence',
    );
    expect(buildId, isNot('unassigned'));
    expect(RegExp(r'^[a-f0-9]{64}$').hasMatch(configurationSha256), isTrue);
    final temporary = await getTemporaryDirectory();
    final parent = await Directory(
      p.join(temporary.path, 'jianzhang-native-performance'),
    ).create(recursive: true);
    final fixture = await parent.createTemp('run-');
    final dbPath = p.join(fixture.path, 'ledger.sqlite');
    final repository = await LedgerRepository.open(path: dbPath);
    final capture = GlobalKey();
    final ioActive = ValueNotifier(false);
    final responsiveness = <String, Object?>{};
    final artifacts = await Directory(
      p.join(parent.path, 'evidence', roundId),
    ).create(recursive: true);
    final mode = kProfileMode ? 'profile' : 'release';
    var ticks = 0;
    var lastTick = Stopwatch()..start();
    var maxGapMs = 0.0;
    final ticker = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final gap = lastTick.elapsedMicroseconds / 1000;
      if (gap > maxGapMs) maxGapMs = gap;
      lastTick = Stopwatch()..start();
      ticks++;
    });
    addTearDown(() async {
      ticker.cancel();
      await tester.pumpWidget(const SizedBox.shrink());
      ioActive.dispose();
      await repository.close();
      final resolvedParent = await parent.resolveSymbolicLinks();
      final resolvedFixture = await fixture.resolveSymbolicLinks();
      if (!p.isWithin(resolvedParent, resolvedFixture) ||
          !p.basename(resolvedFixture).startsWith('run-')) {
        throw StateError('Unsafe benchmark fixture cleanup');
      }
      await Directory(resolvedFixture).delete(recursive: true);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [repositoryProvider.overrideWith((ref) => repository)],
        child: RepaintBoundary(
          key: capture,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(
              children: [
                const JianzhangApp(),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: ioActive,
                    builder: (_, active, _) => active
                        ? const LinearProgressIndicator(
                            minHeight: 2,
                            color: Color(0xff397665),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(JianzhangApp)),
    );
    Future<void> waitForCurrentView({bool bills = false}) async {
      final meta = await repository.meta();
      final deadline = Stopwatch()..start();
      while (deadline.elapsed < const Duration(seconds: 10)) {
        await tester.pump(const Duration(milliseconds: 16));
        final current = container.read(ledgerProvider).asData?.value.meta;
        final scrollables = find.descendant(
          of: find.byType(BillsPage),
          matching: find.byType(Scrollable),
        );
        if (current?.key == meta.key &&
            current?.sequence == meta.sequence &&
            current?.transactionCount == meta.transactionCount &&
            (!bills || scrollables.evaluate().isNotEmpty)) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      throw TestFailure(
        'Current ledger view or bills did not load before measurement',
      );
    }

    await waitForCurrentView();

    Future<void> responsiveIO(
      String name,
      Future<void> Function() action,
    ) async {
      debugPrint('jianzhang.performance_stage=$name started');
      await tester.tap(find.text('账单').last);
      await tester.pumpAndSettle();
      ioActive.value = true;
      maxGapMs = 0;
      lastTick = Stopwatch()..start();
      final beforeTicks = ticks;
      final frames = <double>[];
      void received(List<ui.FrameTiming> values) => frames.addAll(
        values.map((value) => value.totalSpan.inMicroseconds / 1000),
      );
      SchedulerBinding.instance.addTimingsCallback(received);
      Object? failure;
      StackTrace? failureStack;
      final operation = action().then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          failure = error;
          failureStack = stack;
        },
      );
      try {
        await tester.pump(const Duration(milliseconds: 100));
        final navigation = Stopwatch()..start();
        await tester.tap(find.text('首页').last);
        await tester.pump();
        expect(
          find.byType(HomePage),
          findsOneWidget,
          reason: '$name must allow navigation while running',
        );
        final navigationMs = navigation.elapsedMicroseconds / 1000;
        expect(navigationMs, lessThanOrEqualTo(150));
        await operation;
        if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(ticks - beforeTicks, greaterThan(10));
        expect(
          frames.length,
          greaterThanOrEqualTo(20),
          reason: '$name must continue rendering',
        );
        expect(
          maxGapMs,
          lessThanOrEqualTo(150),
          reason: '$name must not stall the UI event loop',
        );
        responsiveness[name] = {
          'frames': frames,
          'maxEventLoopGapMs': maxGapMs,
          'navigationMs': navigationMs,
          'ticks': ticks - beforeTicks,
        };
        debugPrint('jianzhang.performance_stage=$name completed');
      } finally {
        ioActive.value = false;
        SchedulerBinding.instance.removeTimingsCallback(received);
        await operation;
      }
    }

    final accounts = await repository.listAccounts();
    final categories = await repository.listCategories();
    final expense = categories.firstWhere(
      (c) => c.type == EntryType.expense && c.parentId != null,
    );
    final income = categories.firstWhere(
      (c) => c.type == EntryType.income && c.parentId != null,
    );
    LedgerTransaction row(int index, {String? note}) {
      final type = index % 20 == 0
          ? EntryType.income
          : index % 20 == 1
          ? EntryType.transfer
          : EntryType.expense;
      final date = DateTime(
        2025,
        1,
        1,
      ).add(Duration(days: index % 730, minutes: index % 1440));
      return LedgerTransaction(
        id: 'benchmark-${index.toString().padLeft(6, '0')}',
        type: type,
        amount: 100 + index % 1000000,
        fee: type == EntryType.transfer ? 25 : 0,
        date: localDateTime(date),
        createdAt: localDateTime(date),
        accountId: accounts.first.id,
        toAccountId: type == EntryType.transfer ? accounts[1].id : '',
        categoryId: type == EntryType.income ? income.id : expense.id,
        note: note ?? '中文账单 $index · Café ΟΣ İ 🙂 % _',
      );
    }

    final metadata = await repository.cloudSnapshot();
    metadata.remove('transactions');
    final encoded = jsonEncode(metadata);
    final input = File(p.join(fixture.path, '100k.json'));
    final sink = input.openWrite();
    sink.write('${encoded.substring(0, encoded.length - 1)},"transactions":[');
    var chunk = StringBuffer();
    for (var index = 0; index < localTransactionLimit; index++) {
      if (index > 0) chunk.write(',');
      chunk.write(jsonEncode(row(index).toJson()));
      if ((index + 1) % 400 == 0) {
        sink.write(chunk.toString());
        chunk = StringBuffer();
        await sink.flush();
      }
    }
    if (chunk.isNotEmpty) sink.write(chunk.toString());
    sink.write(']}');
    await sink.close();
    debugPrint('jianzhang.performance_stage=fixture completed');
    final restoreTicks = ticks;
    await responsiveIO('initial-restore', () async {
      await repository.importAtomic(await repository.previewImport(input.path));
    });
    expect((await repository.meta()).transactionCount, localTransactionLimit);
    await waitForCurrentView();
    expect(
      ticks - restoreTicks,
      greaterThan(10),
      reason: 'Restore must yield to the UI event loop',
    );
    final saveMs = <double>[], queryMs = <double>[];
    for (var sample = 0; sample < 30; sample++) {
      final clock = Stopwatch()..start();
      await repository.saveTransaction(
        row(sample * 997, note: '编辑 $sample 中文'),
      );
      saveMs.add(clock.elapsedMicroseconds / 1000);
      clock.reset();
      final filter = sample.isEven
          ? const LedgerFilter(note: '中文')
          : LedgerFilter(
              amountOp: 'range',
              amountMin: '1',
              amountMax: '9000',
              categoryIds: [expense.parentId!],
              subIds: [expense.id],
              accountIds: [accounts.first.id],
              note: '中文',
              start: '2025-01-01',
              end: '2026-12-31',
            );
      expect((await repository.search(filter)).items, isNotEmpty);
      queryMs.add(clock.elapsedMicroseconds / 1000);
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('账单').last);
    await tester.pumpAndSettle();
    await waitForCurrentView(bills: true);
    final frameMs = <double>[];
    final scrollable = find
        .descendant(
          of: find.byType(BillsPage),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0));
    var movedFlings = 0;
    void timings(List<ui.FrameTiming> values) {
      frameMs.addAll(
        values.map((value) => value.totalSpan.inMicroseconds / 1000),
      );
    }

    SchedulerBinding.instance.addTimingsCallback(timings);
    try {
      for (var index = 0; index < 12; index++) {
        final before = position.pixels;
        await tester.fling(
          scrollable,
          Offset(0, index.isEven ? -600 : 600),
          1600,
        );
        await tester.pumpAndSettle();
        if ((position.pixels - before).abs() > 1) movedFlings++;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } finally {
      SchedulerBinding.instance.removeTimingsCallback(timings);
    }
    expect(frameMs.length, greaterThanOrEqualTo(20));
    expect(
      movedFlings,
      greaterThanOrEqualTo(6),
      reason: 'Measured flings must actually scroll the bills',
    );
    Future<void> writeMetric(String metric, List<double> samples) =>
        File(
          p.join(artifacts.path, '${Platform.operatingSystem}-$metric.json'),
        ).writeAsString(
          jsonEncode({
            'metric': metric,
            'roundId': roundId,
            'buildId': buildId,
            'mode': mode,
            'configurationSha256': configurationSha256,
            'samples': samples,
          }),
          flush: true,
        );
    final platform = Platform.operatingSystem;
    await writeMetric('${platform}Save100kP95Ms', saveMs);
    await writeMetric('${platform}Query100kP95Ms', queryMs);
    await writeMetric('${platform}ScrollFramesOver50msRatio', frameMs);
    debugPrint('jianzhang.performance_stage=measurements persisted');
    final exports = <String, Object?>{};
    for (final format in ExportFormat.values) {
      final before = ticks;
      final clock = Stopwatch()..start();
      final file = File(p.join(fixture.path, 'export.${format.name}'));
      await responsiveIO(
        'export-${format.name}',
        () => repository.exportFile(file.path, format: format),
      );
      expect(await file.length(), greaterThan(0));
      expect(
        ticks - before,
        greaterThan(10),
        reason: '${format.name} export must yield to the UI',
      );
      exports[format.name] = {
        'elapsedMs': clock.elapsedMilliseconds,
        'ticks': ticks - before,
        'bytes': await file.length(),
      };
    }
    await responsiveIO('exported-restore', () async {
      await repository.importAtomic(
        await repository.previewImport(p.join(fixture.path, 'export.json')),
      );
    });
    expect((await repository.meta()).transactionCount, localTransactionLimit);
    await waitForCurrentView();
    await tester.pumpAndSettle();
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final raster = await boundary.toImage(pixelRatio: 1);
    try {
      final image = await raster.toByteData(format: ui.ImageByteFormat.png);
      expect(image, isNotNull);
      await File(
        p.join(artifacts.path, '${Platform.operatingSystem}-100k.png'),
      ).writeAsBytes(image!.buffer.asUint8List(), flush: true);
    } finally {
      raster.dispose();
    }
    await File(
      p.join(artifacts.path, '${Platform.operatingSystem}-operations.json'),
    ).writeAsString(
      jsonEncode({
        'roundId': roundId,
        'buildId': buildId,
        'mode': mode,
        'configurationSha256': configurationSha256,
        'exports': exports,
        'responsiveness': responsiveness,
        'movedFlings': movedFlings,
        'maxEventLoopGapMs': maxGapMs,
        'eventLoopTicks': ticks,
        'restoredCount': localTransactionLimit,
      }),
      flush: true,
    );
    debugPrint('jianzhang.native_evidence=${artifacts.path}');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
