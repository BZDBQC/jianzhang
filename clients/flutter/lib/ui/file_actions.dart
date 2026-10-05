import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../app/controller.dart';
import '../app/services.dart';
import '../data/ledger_repository.dart';
import '../services/file_service.dart';
import 'common.dart';

void showFileFailure(
  BuildContext context,
  String action,
  Object failure,
  StackTrace stack, {
  required String fallback,
}) {
  debugPrint('简账文件操作失败（$action）：$failure');
  debugPrintStack(stackTrace: stack, maxFrames: 8);
  final message = switch (failure) {
    LedgerException() => failure.message,
    PlatformException(code: 'FILE_CANCELLED') => '文件操作已取消，请重新打开应用后再试。',
    PlatformException(code: 'FILE_BUSY') => '文件正在处理中，请稍候再试。',
    _ => fallback,
  };
  if (context.mounted) showNotice(context, '$action：$message', error: true);
}

Future<void> exportBook(
  BuildContext context,
  WidgetRef ref,
  ExportFormat format, {
  LedgerFilter filter = const LedgerFilter(),
  WorkspaceMeta? expectedScope,
}) async {
  final scope = expectedScope ?? ref.read(ledgerProvider).asData?.value.meta;
  if (scope == null) {
    showNotice(context, '账本尚未打开，请稍后重试。', error: true);
    return;
  }
  File? temporary;
  try {
    final directory = await getTemporaryDirectory();
    final extension = format.name;
    temporary = File(
      p.join(directory.path, 'jianzhang-${const Uuid().v4()}.$extension'),
    );
    final repository = await ref.read(repositoryProvider.future);
    await repository.exportFile(
      temporary.path,
      format: format,
      filter: filter,
      expectedWorkspace: scope.key,
      expectedSequence: scope.sequence,
    );
    final saved = await ref
        .read(fileServiceProvider)
        .save(
          temporary.path,
          name: '简账-${dayKey(DateTime.now())}.$extension',
          mime: switch (format) {
            ExportFormat.json => 'application/json',
            ExportFormat.csv => 'text/csv',
            ExportFormat.xlsx =>
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          },
        );
    if (context.mounted) showNotice(context, saved ? '文件已导出' : '已取消导出，账本不受影响');
  } catch (error, stack) {
    if (context.mounted) {
      showFileFailure(
        context,
        '导出未完成',
        error,
        stack,
        fallback: '文件未能保存，请检查可用空间或换一个保存位置。',
      );
    }
  } finally {
    if (temporary != null && await temporary.exists()) {
      try {
        await temporary.delete();
      } catch (error, stack) {
        if (context.mounted) {
          showFileFailure(
            context,
            '导出临时文件清理失败',
            error,
            stack,
            fallback: '临时文件未能清理，请关闭后重新打开应用再试。',
          );
        }
      }
    }
  }
}

Future<void> importBook(BuildContext context, WidgetRef ref) async {
  final scope = ref.read(ledgerProvider).asData?.value.meta;
  if (scope == null) {
    showNotice(context, '账本尚未打开，请稍后重试。', error: true);
    return;
  }
  final files = ref.read(fileServiceProvider);
  PickedJson? picked;
  ImportPreview? preview;
  LedgerRepository? repository;
  try {
    picked = await files.pickJson();
    if (picked == null) return;
    final opened = await ref.read(repositoryProvider.future);
    repository = opened;
    preview = await opened.previewImport(
      picked.path,
      expectedWorkspace: scope.key,
      expectedSequence: scope.sequence,
    );
    if (!context.mounted) return;
    final accepted = await confirmAction(
      context,
      title: '确认恢复备份？',
      message:
          '已校验：${preview.accountCount} 个账户、${preview.categoryCount} 个分类、'
          '${preview.transactionCount} 笔账单、${preview.budgetCount} 个预算。\n\n'
          '恢复将替换当前工作区；现有账本会先自动备份。其他工作区保留。',
      accept: '备份并恢复',
    );
    if (!accepted) return;
    final captured = preview;
    final saved = await ref
        .read(ledgerProvider.notifier)
        .perform(
          (repo) => repo.importAtomic(
            captured,
            expectedWorkspace: scope.key,
            expectedSequence: scope.sequence,
          ),
          expectedScope: scope,
        );
    if (context.mounted) {
      showNotice(
        context,
        saved
            ? '备份已恢复'
            : ref.read(ledgerProvider).asData?.value.error ?? '恢复失败，本机账本已保留',
        error: !saved,
      );
    }
  } catch (error, stack) {
    if (context.mounted) {
      showFileFailure(
        context,
        '导入未完成',
        error,
        stack,
        fallback: '文件未完整读取，请重试或换用本机 JSON 备份。',
      );
    }
  } finally {
    if (preview != null && repository != null) {
      try {
        await repository.discardImport(preview);
      } catch (error, stack) {
        if (context.mounted) {
          showFileFailure(
            context,
            '导入临时数据清理失败',
            error,
            stack,
            fallback: '临时数据未能清理，请关闭后重新打开应用再试。',
          );
        }
      }
    }
    if (picked != null) {
      try {
        await files.releasePickedJson(picked);
      } catch (error, stack) {
        if (context.mounted) {
          showFileFailure(
            context,
            '导入缓存清理失败',
            error,
            stack,
            fallback: '临时文件未能清理，请关闭后重新打开应用再试。',
          );
        }
      }
    }
  }
}
