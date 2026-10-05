import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../app/controller.dart';
import '../data/ledger_repository.dart';
import 'common.dart';
import 'entry_form.dart';

import 'mutation_helpers.dart';

class CategoriesPage extends ConsumerWidget {
  const CategoriesPage({super.key, required this.view});
  final LedgerView view;
  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      SectionHeading(
        title: '二级分类',
        caption: '大类统筹，小类记录；使用中的分类可以迁移后删除。',
        action: FilledButton.icon(
          onPressed: view.busy
              ? null
              : () => showDialog<void>(
                  context: context,
                  builder: (_) => CategoryEditor(view: view),
                ),
          icon: const Icon(Icons.add),
          label: const Text('添加大类'),
        ),
      ),
      const SizedBox(height: 24),
      ...[EntryType.expense, EntryType.income].expand(
        (type) => [
          Text(typeLabel(type), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          ...view.categories
              .where((c) => c.type == type && c.parentId == null)
              .map(
                (parent) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SoftCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          spacing: 8,
                          children: [
                            Text(
                              parent.name,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            _actions(context, ref, parent),
                          ],
                        ),
                        ...view.categories
                            .where((c) => c.parentId == parent.id)
                            .map(
                              (leaf) => Row(
                                children: [
                                  Expanded(child: Text('  ${leaf.name}')),
                                  _actions(context, ref, leaf),
                                ],
                              ),
                            ),
                        TextButton.icon(
                          onPressed: view.busy
                              ? null
                              : () => showDialog<void>(
                                  context: context,
                                  builder: (_) => CategoryEditor(
                                    view: view,
                                    parent: parent,
                                  ),
                                ),
                          icon: const Icon(Icons.add),
                          label: const Text('添加小类'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          const SizedBox(height: 20),
        ],
      ),
    ],
  );
  Widget _actions(BuildContext context, WidgetRef ref, Category category) =>
      PopupMenuButton<String>(
        tooltip: '分类操作',
        enabled: !view.busy,
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('编辑')),
          PopupMenuItem(value: 'delete', child: Text('删除或迁移')),
        ],
        onSelected: (value) async {
          if (value == 'edit') {
            await showDialog<void>(
              context: context,
              builder: (_) => CategoryEditor(view: view, category: category),
            );
          } else {
            await showDialog<void>(
              context: context,
              builder: (_) => CategoryDelete(view: view, category: category),
            );
          }
        },
      );
}

class CategoryEditor extends ConsumerStatefulWidget {
  const CategoryEditor({
    super.key,
    required this.view,
    this.category,
    this.parent,
  });
  final LedgerView view;
  final Category? category, parent;
  @override
  ConsumerState<CategoryEditor> createState() => _CategoryEditorState();
}

class _CategoryEditorState extends ConsumerState<CategoryEditor> {
  late final TextEditingController _name;
  late EntryType _type;
  String? _parent;
  bool _busy = false;
  late WorkspaceMeta _scope;
  late LedgerView _view;
  Category? _currentCategory;
  late bool _isChild;
  bool _missing = false;
  @override
  void initState() {
    super.initState();
    _scope = widget.view.meta;
    _view = widget.view;
    _currentCategory = widget.category;
    _isChild = widget.category?.parentId != null || widget.parent != null;
    _name = TextEditingController(text: widget.category?.name ?? '');
    _type = widget.category?.type ?? widget.parent?.type ?? EntryType.expense;
    _parent = widget.category?.parentId ?? widget.parent?.id;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _recheck(LedgerView view) {
    final latest = widget.category == null
        ? null
        : view.category(widget.category!.id);
    setState(() {
      _scope = view.meta;
      _view = view;
      _currentCategory = latest;
      _missing = widget.category != null && latest == null;
      if (latest != null) {
        _type = latest.type;
        _isChild = latest.parentId != null;
      }
      if (!_isChild ||
          !view.categories.any(
            (c) => c.id == _parent && c.type == _type && c.parentId == null,
          )) {
        _parent = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) => FormDialog(
    title: widget.category == null ? (!_isChild ? '添加大类' : '添加小类') : '编辑分类',
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy || _missing
            ? null
            : () async {
                if (_name.text.trim().isEmpty) {
                  showNotice(context, '分类名称不能为空', error: true);
                  return;
                }
                if (_isChild && _parent == null) {
                  showNotice(context, '原大类已删除，请重新选择所属大类。', error: true);
                  return;
                }
                setState(() => _busy = true);
                final category = Category(
                  id: widget.category?.id ?? const Uuid().v4(),
                  name: _name.text.trim(),
                  type: _type,
                  parentId: _parent,
                  icon: _currentCategory?.icon ?? 'Tags',
                  color: _currentCategory?.color ?? '#397665',
                );
                final saved = await mutate(
                  context,
                  ref,
                  (repo) => repo.upsertCategory(
                    category,
                    expectedWorkspace: _scope.key,
                    expectedSequence: _scope.sequence,
                  ),
                  '分类已保存',
                  scope: _scope,
                );
                if (context.mounted) {
                  if (saved) {
                    Navigator.pop(context);
                  } else {
                    setState(() => _busy = false);
                  }
                }
              },
        child: Text(_busy ? '正在保存…' : '保存分类'),
      ),
    ],
    children: [
      if (_missing) const Text('该分类已删除，不能继续编辑或重新创建。名称草稿仍保留。'),
      TextField(
        controller: _name,
        maxLength: 60,
        decoration: const InputDecoration(labelText: '分类名称'),
      ),
      DraftScopeNotice(scope: _scope, onRechecked: _recheck),
      if (!_isChild) ...[
        const FieldSpace(),
        Wrap(
          spacing: 8,
          children: [EntryType.expense, EntryType.income]
              .map(
                (type) => ChoiceChip(
                  label: Text(typeLabel(type)),
                  selected: _type == type,
                  onSelected: widget.category != null
                      ? null
                      : (_) => setState(() => _type = type),
                ),
              )
              .toList(),
        ),
      ],
      if (_isChild) ...[
        const FieldSpace(),
        DropdownButtonFormField<String>(
          key: ValueKey('category-parent-${_scope.sequence}-$_parent'),
          initialValue: _parent,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '所属大类'),
          items: _view.categories
              .where((c) => c.type == _type && c.parentId == null)
              .map((c) => DropdownMenuItem(value: c.id, child: Text(c.name)))
              .toList(),
          onChanged: (value) => _parent = value,
        ),
      ],
    ],
  );
}

class CategoryDelete extends ConsumerStatefulWidget {
  const CategoryDelete({super.key, required this.view, required this.category});
  final LedgerView view;
  final Category category;
  @override
  ConsumerState<CategoryDelete> createState() => _CategoryDeleteState();
}

class _CategoryDeleteState extends ConsumerState<CategoryDelete> {
  String? _target;
  bool _busy = false;
  late WorkspaceMeta _scope;
  late LedgerView _view;
  Category? _currentCategory;
  @override
  void initState() {
    super.initState();
    _scope = widget.view.meta;
    _view = widget.view;
    _currentCategory = widget.category;
  }

  bool _eligible(Category candidate, Category source) =>
      candidate.id != source.id &&
      candidate.type == source.type &&
      candidate.parentId != null &&
      candidate.parentId != source.id;
  void _recheck(LedgerView view) {
    final latest = view.category(widget.category.id);
    setState(() {
      _scope = view.meta;
      _view = view;
      _currentCategory = latest;
      if (latest == null ||
          !view.categories.any(
            (c) => c.id == _target && _eligible(c, latest),
          )) {
        _target = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final category = _currentCategory ?? widget.category;
    final targets = _view.categories
        .where((c) => _eligible(c, category))
        .toList();
    return FormDialog(
      title: '删除「${category.name}」',
      subtitle: '直接删除只适用于未使用的分类；有历史记录时先选择其他小类作为迁移目标。删除大类会一并删除其小类和关联预算。',
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy || _currentCategory == null
              ? null
              : () async {
                  setState(() => _busy = true);
                  final saved = await mutate(
                    context,
                    ref,
                    (repo) => repo.deleteCategory(
                      category.id,
                      reassignTo: _target,
                      expectedWorkspace: _scope.key,
                      expectedSequence: _scope.sequence,
                    ),
                    '分类已删除',
                    scope: _scope,
                  );
                  if (context.mounted) {
                    if (saved) {
                      Navigator.pop(context);
                    } else {
                      setState(() => _busy = false);
                    }
                  }
                },
          child: Text(
            _busy
                ? '正在处理…'
                : _target == null
                ? '删除未使用分类'
                : '迁移并删除',
          ),
        ),
      ],
      children: [
        if (_currentCategory == null) const Text('该分类已删除，不能再次删除或迁移。'),
        DropdownButtonFormField<String>(
          key: ValueKey('category-target-${_scope.sequence}-$_target'),
          isExpanded: true,
          initialValue: _target,
          decoration: const InputDecoration(labelText: '迁移目标（可不选）'),
          items: targets
              .map((c) => DropdownMenuItem(value: c.id, child: Text(c.name)))
              .toList(),
          onChanged: (value) => _target = value,
        ),
        DraftScopeNotice(scope: _scope, onRechecked: _recheck),
        const FieldSpace(),
        const Text('迁移及删除由本机数据库一次提交，账单不会丢失。'),
      ],
    );
  }
}
