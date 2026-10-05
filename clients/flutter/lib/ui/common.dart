import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/controller.dart';
import '../app/theme.dart';
import '../data/ledger_repository.dart';

class SoftCard extends StatelessWidget {
  const SoftCard({super.key, required this.child, this.padding = 20});
  final Widget child;
  final double padding;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: AppColors.line),
    ),
    child: Padding(padding: EdgeInsets.all(padding), child: child),
  );
}

class SectionHeading extends StatelessWidget {
  const SectionHeading({
    super.key,
    required this.title,
    this.caption,
    this.action,
  });
  final String title;
  final String? caption;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        if (caption case final text?) ...[
          const SizedBox(height: 6),
          Text(text, style: const TextStyle(color: AppColors.muted)),
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 600 || action == null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [heading, ?action],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: heading),
            const SizedBox(width: 16),
            action!,
          ],
        );
      },
    );
  }
}

class EmptyNotice extends StatelessWidget {
  const EmptyNotice({
    super.key,
    required this.title,
    required this.message,
    this.icon = Icons.receipt_long_outlined,
    this.action,
  });
  final String title;
  final String message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 36, color: AppColors.primary),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.muted),
        ),
        if (action case final widget?) ...[const SizedBox(height: 16), widget],
      ],
    ),
  );
}

class FormDialog extends StatelessWidget {
  const FormDialog({
    super.key,
    required this.title,
    required this.children,
    required this.actions,
    this.subtitle,
  });
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 640,
        maxHeight: MediaQuery.sizeOf(context).height * .88,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            if (subtitle case final text?) ...[
              const SizedBox(height: 8),
              Text(text, style: const TextStyle(color: AppColors.muted)),
            ],
            const SizedBox(height: 24),
            ...children,
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: actions,
            ),
          ],
        ),
      ),
    ),
  );
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String accept = '确定',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => FormDialog(
        title: title,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(accept),
          ),
        ],
        children: [Text(message)],
      ),
    ) ??
    false;

void showNotice(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? AppColors.expense : AppColors.ink,
      behavior: SnackBarBehavior.floating,
      width: MediaQuery.sizeOf(context).width >= 1000 ? 520 : null,
    ),
  );
}

class FieldSpace extends StatelessWidget {
  const FieldSpace({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox(height: 16);
}

class DraftScopeNotice extends ConsumerWidget {
  const DraftScopeNotice({
    super.key,
    required this.scope,
    required this.onRechecked,
  });
  final WorkspaceMeta scope;
  final FutureOr<void> Function(LedgerView) onRechecked;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(ledgerProvider).asData?.value;
    if (view == null ||
        (view.meta.key == scope.key &&
            view.meta.sequence == scope.sequence &&
            view.error == null)) {
      return const SizedBox.shrink();
    }
    final original = view.meta.key == scope.key;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            original
                ? '账本已变化，输入已保留。重新读取后，请核对内容再保存。'
                : '账本已切换，输入已保留。请先切回打开表单的账本。',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          TextButton(
            onPressed: !original || view.busy
                ? null
                : () async {
                    try {
                      await ref.read(ledgerProvider.notifier).refresh();
                      if (!context.mounted) return;
                      final latest = ref.read(ledgerProvider).asData?.value;
                      if (latest != null &&
                          latest.meta.key == scope.key &&
                          latest.error == null) {
                        await onRechecked(latest);
                      }
                    } catch (error) {
                      if (context.mounted) {
                        showNotice(context, '核对未完成：$error，输入已保留。', error: true);
                      }
                    }
                  },
            child: const Text('重新读取并核对'),
          ),
        ],
      ),
    );
  }
}
