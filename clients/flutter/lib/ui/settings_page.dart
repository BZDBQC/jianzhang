import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/controller.dart';
import '../app/theme.dart';
import '../data/ledger_repository.dart';
import 'common.dart';
import 'file_actions.dart';
import 'mutation_helpers.dart';

import 'cloud_panel.dart';
import 'data_management.dart';
export 'cloud_panel.dart';
export 'data_management.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, required this.view});
  final LedgerView view;
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _fileBusy = false;
  Future<void> _fileAction(Future<void> Function() action) async {
    if (_fileBusy) return;
    setState(() {
      _fileBusy = true;
    });
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() {
          _fileBusy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const SectionHeading(title: '数据与设置', caption: '本机优先，云端保存由你决定。'),
      const SizedBox(height: 24),
      SoftCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('导入与导出', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('JSON 保存完整账本；CSV 和 Excel 适合查看与分析。恢复前自动备份，取消文件选择不会更改数据。'),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ...ExportFormat.values.map(
                  (format) => OutlinedButton.icon(
                    onPressed: _fileBusy
                        ? null
                        : () => _fileAction(
                            () => exportBook(
                              context,
                              ref,
                              format,
                              expectedScope: widget.view.meta,
                            ),
                          ),
                    icon: const Icon(Icons.download_outlined),
                    label: Text(
                      '导出 ${format == ExportFormat.xlsx ? 'Excel' : format.name.toUpperCase()}',
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _fileBusy || widget.view.busy
                      ? null
                      : () => _fileAction(() => importBook(context, ref)),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('恢复 JSON 备份'),
                ),
              ],
            ),
            if (_fileBusy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const Text('正在处理文件，请稍候…'),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
      CloudPanel(view: widget.view),
      const SizedBox(height: 16),
      WorkspacePanel(view: widget.view),
      const SizedBox(height: 16),
      BackupPanel(view: widget.view),
      const SizedBox(height: 16),
      SoftCard(
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('预算提醒'),
          subtitle: const Text('达到设置阈值时在应用内提醒，同一阈值不重复提示。'),
          value: widget.view.settings.notifications,
          onChanged: widget.view.busy
              ? null
              : (value) => mutate(
                  context,
                  ref,
                  (repo) => repo.updateSettings(
                    widget.view.settings.copyWith(notifications: value),
                    expectedWorkspace: widget.view.meta.key,
                    expectedSequence: widget.view.meta.sequence,
                  ),
                  '提醒设置已保存',
                  scope: widget.view.meta,
                ),
        ),
      ),
      const SizedBox(height: 20),
      const Text(
        '本机账本保存在应用私有目录，首次启动就能离线使用。卸载应用或清理应用数据前，请导出备份。云端上传有 2 万笔 / 8 MB 上限，本机支持最多 10 万笔。',
        style: TextStyle(color: AppColors.muted),
      ),
      const SizedBox(height: 24),
    ],
  );
}
