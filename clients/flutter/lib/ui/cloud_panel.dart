import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/controller.dart';
import '../app/services.dart';
import '../data/ledger_repository.dart';
import '../services/cloud_service.dart';
import 'common.dart';

class CloudPanel extends ConsumerStatefulWidget {
  const CloudPanel({super.key, required this.view});
  final LedgerView view;
  @override
  ConsumerState<CloudPanel> createState() => _CloudPanelState();
}

class _CloudPanelState extends ConsumerState<CloudPanel> {
  CloudSession? _session;
  bool _busy = false;
  String? _message;

  Future<CloudSession?> _identity() async {
    final session = await ref.read(cloudServiceProvider).session();
    if (mounted) {
      setState(() {
        _session = session;
      });
    }
    return session;
  }

  Future<void> _login() async {
    final result = await showDialog<CloudSession>(
      context: context,
      builder: (_) => const PhoneLoginDialog(),
    );
    if (result != null && mounted) {
      setState(() {
        _session = result;
        _message = '已登录。只有点击同步并选择账本来源后，才会上传数据。';
      });
    }
  }

  Future<void> _sync() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final service = ref.read(cloudServiceProvider);
    final current = widget.view.meta;
    try {
      final session = _session ?? await _identity();
      if (session == null) {
        if (mounted) await _login();
        return;
      }
      final cloud = await service.download();
      if (cloud.user.userId != session.user.userId) {
        throw const CloudFailure('账号已变化，请重新登录。未修改本机账本。', 409, 'IDENTITY');
      }
      final repository = await ref.read(repositoryProvider.future);
      final source = await repository.meta();
      if (source.key != current.key || source.sequence != current.sequence) {
        throw const LedgerConflict();
      }
      final workspace = 'user:${session.user.userId}';
      final knownWorkspaces = await repository.listWorkspaces();
      final target = knownWorkspaces
          .where((item) => item.key == workspace)
          .firstOrNull;
      final remoteCount = (cloud.ledger['transactions'] as List?)?.length ?? 0;
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => FormDialog(
          title: '选择账本来源',
          subtitle: '不会自动合并。替换前保存备份，另一工作区仍保留。',
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(context, 'download'),
              child: const Text('使用云端账本'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'upload'),
              child: const Text('保存本机到云端'),
            ),
          ],
          children: [
            Text(
              '本机：${current.transactionCount} 笔账单\n云端：$remoteCount 笔账单，版本 ${cloud.revision}',
            ),
            const FieldSpace(),
            Text('云端账号：${session.user.name}'),
            if (current.key != workspace && target != null) ...[
              const FieldSpace(),
              Text(
                '该账号已有本机账本：${target.transactionCount} 笔。继续同步会先备份，再替换该账号本机账本。',
              ),
            ],
            const FieldSpace(),
            const Text('“保存本机”会替换该账号云端账本；“使用云端”会在该账号本机工作区恢复云端账本。'),
          ],
        ),
      );
      if (choice == null) return;
      final latest = await repository.meta();
      if (latest.key != current.key || latest.sequence != current.sequence) {
        throw const LedgerConflict();
      }
      if (choice == 'download') {
        final saved = await ref
            .read(ledgerProvider.notifier)
            .perform(
              (repo) => repo.replaceSnapshot(
                Map<String, Object?>.from(cloud.ledger),
                workspace: workspace,
                cloudRevision: cloud.revision,
                expectedSequence: current.sequence,
                expectedSourceWorkspace: current.key,
                expectedTargetSequence: target?.sequence ?? 0,
              ),
              expectedScope: current,
            );
        if (!saved) {
          throw LedgerException(
            ref.read(ledgerProvider).asData?.value.error ?? '恢复未完成',
          );
        }
      } else {
        final local = await repository.cloudSnapshot(
          expectedWorkspace: current.key,
          expectedSequence: current.sequence,
        );
        final snapshotMeta = await repository.meta();
        if (snapshotMeta.key != current.key ||
            snapshotMeta.sequence != current.sequence) {
          throw const LedgerConflict();
        }
        await repository.backupSnapshot(
          Map<String, Object?>.from(cloud.ledger),
          label: '上传前云端备份',
        );
        final beforeUpload = await repository.meta();
        if (beforeUpload.key != current.key ||
            beforeUpload.sequence != current.sequence) {
          throw const LedgerConflict();
        }
        final revision = await service.upload(
          Map<String, dynamic>.from(local),
          revision: cloud.revision,
          expectedUserId: session.user.userId,
        );
        final after = await repository.meta();
        if (after.key != current.key || after.sequence != current.sequence) {
          if (current.key == workspace) {
            await repository.setCloudRevision(
              revision,
              expectedSequence: current.sequence,
              workspace: current.key,
            );
          }
          if (mounted) {
            setState(() {
              _message = '云端已保存同步开始时的账本。期间新增的本机账单仍保留，请再次同步。';
            });
          }
          await ref.read(ledgerProvider.notifier).refresh();
          return;
        }
        final saved = await ref
            .read(ledgerProvider.notifier)
            .perform(
              (repo) => repo.replaceSnapshot(
                local,
                workspace: workspace,
                cloudRevision: revision,
                expectedSequence: current.sequence,
                expectedSourceWorkspace: current.key,
                expectedTargetSequence: target?.sequence ?? 0,
              ),
              expectedScope: current,
            );
        if (!saved) {
          throw LedgerException(
            '云端已保存，本机账本保留：${ref.read(ledgerProvider).asData?.value.error}',
          );
        }
      }
      if (mounted) {
        setState(() {
          _message = '同步完成。本机和云端都有可恢复的账本。';
        });
      }
    } on CloudFailure catch (error) {
      if (error.status == 409) {
        try {
          final remote = await service.download();
          final repository = await ref.read(repositoryProvider.future);
          await repository.backupSnapshot(
            Map<String, Object?>.from(remote.ledger),
            label: '同步冲突云端备份',
          );
          await ref.read(ledgerProvider.notifier).refresh();
          if (mounted) {
            setState(() {
              _message = '云端出现新账单。本机未覆盖，云端账本已另存备份。请重新同步并选择来源。';
            });
          }
        } catch (backupError) {
          if (mounted) {
            setState(() {
              _message = '同步冲突。本机与云端均未被覆盖；云端副本读取失败：$backupError';
            });
          }
        }
      } else {
        if (mounted) {
          setState(() {
            if (error.status == 401) _session = null;
            _message = error.message;
          });
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = error.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SoftCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('可选云端保存', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('日常记账无需账号。云端使用手机号验证码登录；短信服务未配置时会明确提示，本机功能照常使用。'),
        if (_session case final session?)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text('已登录：${session.user.name}'),
          ),
        if (widget.view.meta.dirty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('本机有尚未同步的更改。'),
          ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (_session == null)
              OutlinedButton(
                onPressed: _busy ? null : _login,
                child: const Text('手机号登录'),
              ),
            FilledButton.icon(
              onPressed: _busy || widget.view.busy ? null : _sync,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: Text(_busy ? '正在连接…' : '同步并选择账本'),
            ),
            if (_session != null)
              TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        final scope = widget.view.meta;
                        setState(() {
                          _busy = true;
                        });
                        String? message;
                        try {
                          await ref.read(cloudServiceProvider).logout();
                        } catch (error) {
                          message = '本机登录已退出，云端注销未完成：$error';
                        }
                        final saved = await ref
                            .read(ledgerProvider.notifier)
                            .perform(
                              (repo) => repo.switchWorkspace(
                                'guest',
                                expectedWorkspace: scope.key,
                                expectedSequence: scope.sequence,
                              ),
                              expectedScope: scope,
                            );
                        if (mounted) {
                          setState(() {
                            _session = null;
                            _busy = false;
                            _message =
                                message ??
                                (saved
                                    ? '已退出云端，打开本机账本。账号工作区仍保留在此设备。'
                                    : '已退出，工作区切换失败，请重试。');
                          });
                        }
                      },
                child: const Text('退出云端账号'),
              ),
          ],
        ),
        if (_busy) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
        if (_message case final message?)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(message),
          ),
      ],
    ),
  );
}

class PhoneLoginDialog extends ConsumerStatefulWidget {
  const PhoneLoginDialog({super.key});
  @override
  ConsumerState<PhoneLoginDialog> createState() => _PhoneLoginDialogState();
}

class _PhoneLoginDialogState extends ConsumerState<PhoneLoginDialog> {
  final _phone = TextEditingController(), _code = TextEditingController();
  SmsChallenge? _challenge;
  Timer? _timer;
  int _seconds = 0;
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!RegExp(r'^1[3-9]\d{9}$').hasMatch(_phone.text.trim())) {
      setState(() {
        _error = '请输入 11 位中国大陆手机号';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final challenge = await ref
          .read(cloudServiceProvider)
          .sendCode(_phone.text.trim());
      if (!mounted) return;
      setState(() {
        _challenge = challenge;
        _seconds = challenge.retryAfter;
      });
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || _seconds <= 1) {
          timer.cancel();
          if (mounted) {
            setState(() {
              _seconds = 0;
            });
          }
        } else {
          setState(() {
            _seconds--;
          });
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _verify() async {
    final challenge = _challenge;
    if (challenge == null || !RegExp(r'^\d{6}$').hasMatch(_code.text.trim())) {
      setState(() {
        _error = '请先接收验证码，再输入 6 位验证码';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await ref
          .read(cloudServiceProvider)
          .verify(challenge.challengeId, _code.text.trim());
      if (mounted) Navigator.pop(context, session);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: FormDialog(
      title: '登录云端账号',
      subtitle: '只用于云端保存，不影响本机账本。登录不会自动上传。',
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('继续本机使用'),
        ),
        FilledButton(
          onPressed: _busy || _challenge == null ? null : _verify,
          child: Text(_busy ? '请稍候…' : '登录云端'),
        ),
      ],
      children: [
        TextField(
          controller: _phone,
          enabled: !_busy,
          keyboardType: TextInputType.phone,
          maxLength: 11,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          autofillHints: const [AutofillHints.telephoneNumberNational],
          decoration: const InputDecoration(
            labelText: '手机号',
            prefixText: '+86 ',
          ),
          onChanged: (_) {
            if (_challenge != null) {
              setState(() {
                _challenge = null;
                _code.clear();
              });
            }
          },
        ),
        const FieldSpace(),
        OutlinedButton(
          onPressed: _busy || _seconds > 0 ? null : _send,
          child: Text(_seconds > 0 ? '$_seconds 秒后重新发送' : '接收短信验证码'),
        ),
        const FieldSpace(),
        TextField(
          controller: _code,
          enabled: !_busy && _challenge != null,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          autofillHints: const [AutofillHints.oneTimeCode],
          decoration: const InputDecoration(labelText: '短信验证码'),
        ),
        if (_challenge case final challenge?)
          Text('验证码 ${challenge.expiresIn ~/ 60} 分钟内有效。'),
        if (_error case final error?)
          Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
  );
}
