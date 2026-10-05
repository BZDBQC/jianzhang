import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/controller.dart';
import '../app/services.dart';
import '../app/theme.dart';
import '../data/ledger_repository.dart';
import 'common.dart';
import 'file_actions.dart';
import 'mutation_helpers.dart';

class WorkspacePanel extends ConsumerStatefulWidget {
  const WorkspacePanel({super.key, required this.view});
  final LedgerView view;
  @override
  ConsumerState<WorkspacePanel> createState() => _WorkspacePanelState();
}

class _WorkspacePanelState extends ConsumerState<WorkspacePanel> {
  Future<List<WorkspaceMeta>>? _workspaces;
  @override
  void initState() {
    super.initState();
    _query();
  }

  @override
  void didUpdateWidget(covariant WorkspacePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.view.meta.key != widget.view.meta.key ||
        oldWidget.view.meta.sequence != widget.view.meta.sequence) {
      _query();
    }
  }

  void _query() => _workspaces = ref
      .read(repositoryProvider.future)
      .then((repo) => repo.listWorkspaces());
  @override
  Widget build(BuildContext context) => SoftCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('本机工作区', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('不同账号的本机账本分别保留。切换工作区不会上传或删除账单。'),
        FutureBuilder<List<WorkspaceMeta>>(
          future: _workspaces,
          builder: (context, snapshot) {
            if (snapshot.hasError) return Text('读取工作区失败：${snapshot.error}');
            final rows = snapshot.data;
            if (rows == null) return const LinearProgressIndicator();
            return Column(
              children: rows.indexed.map((pair) {
                final workspace = pair.$2;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    workspace.key == 'guest' ? '本机账本' : '账号本机账本 ${pair.$1}',
                  ),
                  subtitle: Text(
                    '${workspace.transactionCount} 笔账单${workspace.dirty ? ' · 有待同步更改' : ''}',
                  ),
                  trailing: workspace.key == widget.view.meta.key
                      ? const Icon(Icons.check_circle, color: AppColors.primary)
                      : IconButton(
                          tooltip: '打开此工作区',
                          onPressed: widget.view.busy
                              ? null
                              : () => mutate(
                                  context,
                                  ref,
                                  (repo) => repo.switchWorkspace(
                                    workspace.key,
                                    expectedWorkspace: widget.view.meta.key,
                                    expectedSequence: widget.view.meta.sequence,
                                  ),
                                  '工作区已切换',
                                ),
                          icon: const Icon(Icons.chevron_right),
                        ),
                );
              }).toList(),
            );
          },
        ),
      ],
    ),
  );
}

class BackupPanel extends ConsumerStatefulWidget {
  const BackupPanel({super.key, required this.view});
  final LedgerView view;
  @override
  ConsumerState<BackupPanel> createState() => _BackupPanelState();
}

class _BackupPanelState extends ConsumerState<BackupPanel> {
  Future<List<BackupInfo>>? _backups;
  @override
  void initState() {
    super.initState();
    _query();
  }

  @override
  void didUpdateWidget(covariant BackupPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.view.meta.key != widget.view.meta.key ||
        oldWidget.view.meta.sequence != widget.view.meta.sequence) {
      _query();
    }
  }

  void _query() => _backups = ref
      .read(repositoryProvider.future)
      .then((repo) => repo.listBackups());
  @override
  Widget build(BuildContext context) => SoftCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeading(
          title: '自动备份',
          caption: '导入与同步替换前保存完整账本。',
          action: TextButton(
            onPressed: () => setState(_query),
            child: const Text('重新读取'),
          ),
        ),
        FutureBuilder<List<BackupInfo>>(
          future: _backups,
          builder: (context, snapshot) {
            if (snapshot.hasError) return Text('备份读取失败：${snapshot.error}');
            final rows = snapshot.data;
            if (rows == null) return const LinearProgressIndicator();
            if (rows.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('暂时没有自动备份。你随时可以导出 JSON 保存账本。'),
              );
            }
            return Column(
              children: rows
                  .map(
                    (backup) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(backup.label),
                          Text(
                            '${backup.date.replaceFirst('T', ' ')} · ${backup.transactionCount} 笔账单',
                            style: const TextStyle(color: AppColors.muted),
                          ),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton(
                                onPressed: () async {
                                  try {
                                    final saved = await ref
                                        .read(fileServiceProvider)
                                        .save(
                                          backup.path,
                                          name: '简账备份-${backup.id}.json',
                                          mime: 'application/json',
                                        );
                                    if (context.mounted) {
                                      showNotice(
                                        context,
                                        saved ? '备份已导出' : '已取消导出',
                                      );
                                    }
                                  } catch (error, stack) {
                                    if (context.mounted) {
                                      showFileFailure(
                                        context,
                                        '导出失败',
                                        error,
                                        stack,
                                        fallback: '文件未能保存，请检查可用空间或换一个保存位置。',
                                      );
                                    }
                                  }
                                },
                                child: const Text('导出'),
                              ),
                              TextButton(
                                onPressed: widget.view.busy
                                    ? null
                                    : () async {
                                        final scope = widget.view.meta;
                                        if (await confirmAction(
                                          context,
                                          title: '恢复此备份？',
                                          message: '当前工作区会先自动备份，再恢复所选账本。',
                                        )) {
                                          if (context.mounted) {
                                            await mutate(
                                              context,
                                              ref,
                                              (repo) => repo.restoreBackup(
                                                backup,
                                                expectedWorkspace: scope.key,
                                                expectedSequence:
                                                    scope.sequence,
                                              ),
                                              '备份已恢复',
                                              scope: scope,
                                            );
                                          }
                                        }
                                      },
                                child: const Text('恢复'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            );
          },
        ),
      ],
    ),
  );
}
