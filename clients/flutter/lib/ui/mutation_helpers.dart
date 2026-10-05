import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/controller.dart';
import '../data/ledger_repository.dart';
import 'common.dart';

Future<bool> mutate(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function(LedgerRepository) action,
  String success, {
  WorkspaceMeta? scope,
}) async {
  final ok = await ref
      .read(ledgerProvider.notifier)
      .perform(action, expectedScope: scope);
  if (context.mounted) {
    showNotice(
      context,
      ok
          ? success
          : ref.read(ledgerProvider).asData?.value.error ?? '操作未完成，请重试',
      error: !ok,
    );
  }
  return ok;
}
