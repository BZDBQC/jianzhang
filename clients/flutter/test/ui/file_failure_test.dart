import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianzhang/app/controller.dart';
import 'package:jianzhang/app/services.dart';
import 'package:jianzhang/data/ledger_repository.dart';
import 'package:jianzhang/services/file_service.dart';
import 'package:jianzhang/ui/file_actions.dart';

import 'app_flow_test.dart' show UiFixture, ioWidgetTest, settleUi;

class FailingPicker extends FileService {
  FailingPicker(this.failure);
  final Object failure;

  @override
  Future<PickedJson?> pickJson() async => throw failure;
}

void main() {
  final failures = <String, (Object, String)>{
    'reliable provider error': (
      PlatformException(code: 'FILE_IO', message: 'QA_RELIABLE_PIPE_FAILED'),
      '文件未完整读取，请重试或换用本机 JSON 备份。',
    ),
    'cancelled operation': (
      PlatformException(code: 'FILE_CANCELLED', message: 'activity destroyed'),
      '文件操作已取消，请重新打开应用后再试。',
    ),
    'busy picker': (
      PlatformException(code: 'FILE_BUSY', message: 'native pending request'),
      '文件正在处理中，请稍候再试。',
    ),
    'unreadable local file': (
      const FileSystemException('Access denied', 'C:/private/ledger.json'),
      '文件未完整读取，请重试或换用本机 JSON 备份。',
    ),
    'invalid JSON': (
      const FormatException('Unexpected token at offset 74'),
      '文件未完整读取，请重试或换用本机 JSON 备份。',
    ),
    'domain validation': (
      const LedgerException('备份账单包含无效账户或分类'),
      '备份账单包含无效账户或分类',
    ),
  };
  for (final entry in failures.entries) {
    ioWidgetTest('${entry.key} explains recovery and preserves the ledger', (
      tester,
    ) async {
      final fixture = await UiFixture.open();
      try {
        await fixture.seed();
        final before = await fixture.repository.meta();
        final balances = await fixture.repository.balances();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              repositoryProvider.overrideWith((ref) => fixture.repository),
              fileServiceProvider.overrideWithValue(
                FailingPicker(entry.value.$1),
              ),
            ],
            child: MaterialApp(
              home: Consumer(
                builder: (context, ref, child) {
                  final ready = ref.watch(ledgerProvider).asData != null;
                  return Scaffold(
                    body: TextButton(
                      onPressed: ready ? () => importBook(context, ref) : null,
                      child: const Text('恢复备份'),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        for (var frame = 0; frame < 400; frame++) {
          await tester.pump(const Duration(milliseconds: 20));
          await Future<void>.delayed(const Duration(milliseconds: 5));
          if (tester.widget<TextButton>(find.byType(TextButton)).onPressed !=
              null) {
            break;
          }
        }
        expect(
          tester.widget<TextButton>(find.byType(TextButton)).onPressed,
          isNotNull,
        );
        await tester.tap(find.text('恢复备份'));
        await settleUi(tester);
        expect(find.text('导入未完成：${entry.value.$2}'), findsOneWidget);
        expect(find.textContaining('PlatformException'), findsNothing);
        expect(find.textContaining('QA_RELIABLE_PIPE_FAILED'), findsNothing);
        expect(find.textContaining('C:/private'), findsNothing);
        expect(find.text('确认恢复备份？'), findsNothing);
        final after = await fixture.repository.meta();
        expect(after.sequence, before.sequence);
        expect(after.transactionCount, before.transactionCount);
        expect(await fixture.repository.balances(), balances);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.close();
      }
    });
  }
}
