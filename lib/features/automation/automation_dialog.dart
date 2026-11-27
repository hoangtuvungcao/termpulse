import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/automation/command_macro.dart';
import 'package:termpulse/features/terminal/guarded_command.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/automation_provider.dart';

Future<void> showAutomationDialog(BuildContext context, WidgetRef ref) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AutomationDialog(),
    );

/// Public for focused widget testing; callers normally use showAutomationDialog.
class AutomationDialog extends ConsumerStatefulWidget {
  const AutomationDialog({super.key});

  @override
  ConsumerState<AutomationDialog> createState() => _AutomationDialogState();
}

class _AutomationDialogState extends ConsumerState<AutomationDialog> {
  String _query = '';
  String? _error;
  bool _busy = false;
  AutomationRunnerController? _runner;

  @override
  void dispose() {
    _runner?.cancel('Đã dừng macro vì đóng thư viện.');
    super.dispose();
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([CommandMacro? macro]) => _action(
    () => showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MacroEditor(existing: macro),
    ),
  );

  Future<void> _delete(CommandMacro macro) => _action(() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('Xóa command macro?')),
        content: Text(
          context.tr('Xóa “{name}” khỏi thư viện cục bộ?', {
            'name': macro.name,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('Hủy')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.tr('Xóa macro')),
          ),
        ],
      ),
    );
    if (approved == true && mounted) {
      await ref.read(automationLibraryProvider.notifier).delete(macro.id);
    }
  });

  Future<void> _json({required bool importing}) => _action(() async {
    final initial = importing
        ? ''
        : await ref.read(automationLibraryProvider.notifier).exportJson();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MacroJsonDialog(importing: importing, initial: initial),
    );
  });

  Future<void> _run(CommandMacro macro) async {
    _runner = ref.read(automationRunnerProvider.notifier);
    await _runner!.run(
      macro,
      sendGuarded: (command) async {
        if (!mounted) return false;
        return sendGuardedCommand(
          context,
          ref,
          command,
          canSend: () =>
              mounted &&
              ref.read(automationRunnerProvider).running &&
              !ref.read(automationRunnerProvider).cancelRequested,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(automationLibraryProvider);
    final run = ref.watch(automationRunnerProvider);
    _runner = ref.read(automationRunnerProvider.notifier);
    final workspace = ref.watch(sessionManagerProvider);
    final vault = ref.watch(vaultProvider);
    final target = MacroTargetSnapshot.capture(workspace);
    final ready = target != null && vault.unlocked && !vault.loading;
    final locked = _busy || run.running;
    final size = MediaQuery.sizeOf(context);
    final macros = library.asData?.value ?? const <CommandMacro>[];
    final visible = macros
        .where(
          (macro) => macro.name.toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();

    return PopScope(
      canPop: !run.running && !_busy,
      child: Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: SizedBox(
          width: 860,
          height: math.min(740, math.max(260, size.height - 48)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ListView(
              children: [
                Row(
                  children: [
                    Icon(Icons.playlist_play_rounded, color: context.tp.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        context.tr('Command macros'),
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('automationClose'),
                      tooltip: run.running
                          ? context.tr('Dừng macro trước khi đóng')
                          : context.tr('Đóng thư viện'),
                      onPressed: locked ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  context.tr(
                    'Thư viện chuỗi lệnh có thứ tự, không phải ghi lại phím bấm.',
                  ),
                  style: TextStyle(color: context.tp.muted),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      key: const Key('automationCreate'),
                      onPressed: locked || !library.hasValue
                          ? null
                          : () => _edit(),
                      icon: const Icon(Icons.add_rounded),
                      label: Text(context.tr('Tạo macro')),
                    ),
                    OutlinedButton.icon(
                      key: const Key('automationImport'),
                      onPressed: locked || !library.hasValue
                          ? null
                          : () => _json(importing: true),
                      icon: const Icon(Icons.input_rounded),
                      label: Text(context.tr('Nhập JSON')),
                    ),
                    OutlinedButton.icon(
                      key: const Key('automationExport'),
                      onPressed: locked || macros.isEmpty
                          ? null
                          : () => _json(importing: false),
                      icon: const Icon(Icons.output_rounded),
                      label: Text(context.tr('Xuất JSON')),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('automationSearch'),
                  decoration: InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: context.tr('Tìm macro theo tên'),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
                const SizedBox(height: 12),
                if (_error != null)
                  Text(
                    context.tr(_error!),
                    style: TextStyle(color: context.tp.red),
                  ),
                library.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => Center(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            context.tr('Không đọc được thư viện: {error}', {
                              'error': error.toString(),
                            }),
                          ),
                          const SizedBox(height: 8),
                          FilledButton(
                            onPressed: () =>
                                ref.invalidate(automationLibraryProvider),
                            child: Text(context.tr('Thử lại')),
                          ),
                        ],
                      ),
                    ),
                  ),
                  data: (_) => visible.isEmpty
                      ? Center(
                          child: Text(
                            macros.isEmpty
                                ? context.tr(
                                    'Chưa có macro. Tạo chuỗi lệnh đầu tiên.',
                                  )
                                : context.tr('Không có macro khớp tên.'),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: visible.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final macro = visible[index];
                            return Card(
                              margin: EdgeInsets.zero,
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      macro.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      context.tr(
                                        '{count} bước · {delay} ms chờ',
                                        {
                                          'count': '${macro.steps.length}',
                                          'delay':
                                              '${macro.steps.fold<int>(0, (total, step) => total + step.delayAfterMs)}',
                                        },
                                      ),
                                      style: TextStyle(color: context.tp.muted),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      macro.steps.first.command,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 4,
                                      runSpacing: 4,
                                      children: [
                                        FilledButton.tonalIcon(
                                          key: Key('automationRun_${macro.id}'),
                                          onPressed: !ready || locked
                                              ? null
                                              : () => _run(macro),
                                          icon: const Icon(
                                            Icons.play_arrow_rounded,
                                          ),
                                          label: Text(context.tr('Chạy')),
                                        ),
                                        TextButton(
                                          onPressed: locked
                                              ? null
                                              : () => _edit(macro),
                                          child: Text(context.tr('Sửa')),
                                        ),
                                        TextButton(
                                          onPressed: locked
                                              ? null
                                              : () => _action(
                                                  () => ref
                                                      .read(
                                                        automationLibraryProvider
                                                            .notifier,
                                                      )
                                                      .duplicate(macro),
                                                ),
                                          child: Text(context.tr('Nhân bản')),
                                        ),
                                        TextButton(
                                          onPressed: locked
                                              ? null
                                              : () => _delete(macro),
                                          child: Text(context.tr('Xóa')),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 10),
                Text(
                  ready
                      ? context.tr('Đích hiện tại: {name}', {
                          'name': target.broadcast
                              ? context.tr('Broadcast ({count} phiên)', {
                                  'count': '${target.sessionIds.length}',
                                })
                              : target.label,
                        })
                      : context.tr(
                          'Cần mở khóa Vault và có phiên đang kết nối để chạy.',
                        ),
                  style: TextStyle(
                    color: ready ? context.tp.accent : context.tp.amber,
                  ),
                ),
                const SizedBox(height: 6),
                if (run.running || run.macroId != null) ...[
                  LinearProgressIndicator(
                    value: run.totalSteps == 0
                        ? 0
                        : run.completedSteps / run.totalSteps,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    context.tr(run.message),
                    key: const Key('automationRunMessage'),
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (run.running)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        key: const Key('automationCancel'),
                        onPressed: run.cancelRequested
                            ? null
                            : () => _runner!.cancel(),
                        icon: const Icon(Icons.stop_rounded),
                        label: Text(context.tr('Dừng các bước tiếp')),
                      ),
                    ),
                ],
                const SizedBox(height: 6),
                Text(
                  context.tr(
                    'Lưu cục bộ dạng rõ; không lưu mật khẩu/private key. Mỗi bước qua command guard. Delay không chờ lệnh hoàn tất. Dừng chỉ ngăn bước tiếp, không hoàn tác lệnh đã gửi; khi hộp thoại xác nhận mở, chọn Hủy để dừng.',
                  ),
                  style: TextStyle(color: context.tp.muted, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepDraft {
  final TextEditingController command;
  final TextEditingController delay;
  _StepDraft([MacroStep step = const MacroStep(command: '')])
    : command = TextEditingController(text: step.command),
      delay = TextEditingController(text: '${step.delayAfterMs}');
  void dispose() {
    command.dispose();
    delay.dispose();
  }
}

class _MacroEditor extends ConsumerStatefulWidget {
  final CommandMacro? existing;
  const _MacroEditor({this.existing});
  @override
  ConsumerState<_MacroEditor> createState() => _MacroEditorState();
}

class _MacroEditorState extends ConsumerState<_MacroEditor> {
  late final TextEditingController _name;
  late final List<_StepDraft> _steps;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _steps =
        widget.existing?.steps.map(_StepDraft.new).toList() ?? [_StepDraft()];
  }

  @override
  void dispose() {
    _name.dispose();
    for (final step in _steps) {
      step.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final macro = CommandMacro(
        id: widget.existing?.id ?? CommandMacro.newId(),
        name: _name.text.trim(),
        steps: [
          for (final step in _steps)
            MacroStep(
              command: step.command.text,
              delayAfterMs: int.tryParse(step.delay.text) ?? -1,
            ),
        ],
      );
      await ref.read(automationLibraryProvider.notifier).save(macro);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(
        widget.existing == null
            ? context.tr('Tạo command macro')
            : context.tr('Sửa command macro'),
      ),
      scrollable: true,
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('macroName'),
              controller: _name,
              maxLength: 100,
              enabled: !_saving,
              autofocus: true,
              decoration: InputDecoration(labelText: context.tr('Tên macro')),
            ),
            Text(
              context.tr(
                'Chạy tuần tự trên đích hiện tại. Mỗi bước vẫn cần xác nhận khi command guard yêu cầu.',
              ),
            ),
            for (var index = 0; index < _steps.length; index++) ...[
              const SizedBox(height: 12),
              Container(
                key: ObjectKey(_steps[index]),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  border: Border.all(color: context.tp.border),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            context.tr('Bước {number}', {
                              'number': '${index + 1}',
                            }),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        IconButton(
                          tooltip: context.tr('Đưa lên'),
                          onPressed: _saving || index == 0
                              ? null
                              : () => setState(() {
                                  final step = _steps.removeAt(index);
                                  _steps.insert(index - 1, step);
                                }),
                          icon: const Icon(Icons.arrow_upward_rounded),
                        ),
                        IconButton(
                          tooltip: context.tr('Đưa xuống'),
                          onPressed: _saving || index == _steps.length - 1
                              ? null
                              : () => setState(() {
                                  final step = _steps.removeAt(index);
                                  _steps.insert(index + 1, step);
                                }),
                          icon: const Icon(Icons.arrow_downward_rounded),
                        ),
                        IconButton(
                          tooltip: context.tr('Xóa bước'),
                          onPressed: _saving || _steps.length == 1
                              ? null
                              : () => setState(() {
                                  _steps.removeAt(index).dispose();
                                }),
                          icon: const Icon(Icons.delete_outline_rounded),
                        ),
                      ],
                    ),
                    TextField(
                      key: Key('macroCommand_$index'),
                      controller: _steps[index].command,
                      enabled: !_saving,
                      minLines: 2,
                      maxLines: 5,
                      maxLength: CommandMacro.maxCommandLength,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                      decoration: InputDecoration(
                        labelText: context.tr('Lệnh shell'),
                      ),
                    ),
                    TextField(
                      key: Key('macroDelay_$index'),
                      controller: _steps[index].delay,
                      enabled: !_saving,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(6),
                      ],
                      decoration: InputDecoration(
                        labelText: context.tr('Chờ sau khi gửi (ms)'),
                        helperText: context.tr(
                          '0–600000 ms; không đợi lệnh trên shell kết thúc',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('macroAddStep'),
              onPressed: _saving || _steps.length >= CommandMacro.maxSteps
                  ? null
                  : () => setState(() => _steps.add(_StepDraft())),
              icon: const Icon(Icons.add_rounded),
              label: Text(context.tr('Thêm bước')),
            ),
            if (_error != null)
              Text(
                context.tr(_error!),
                style: TextStyle(color: context.tp.red),
              ),
            const SizedBox(height: 8),
            Text(
              context.tr(
                'Macro lưu dạng rõ ngoài Vault. Không nhập secret hoặc private key.',
              ),
              style: TextStyle(fontSize: 12, color: context.tp.amber),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(context.tr('Hủy')),
        ),
        FilledButton(
          key: const Key('macroSave'),
          onPressed: _saving ? null : _save,
          child: Text(
            _saving ? context.tr('Đang lưu…') : context.tr('Lưu macro'),
          ),
        ),
      ],
    ),
  );
}

class _MacroJsonDialog extends ConsumerStatefulWidget {
  final bool importing;
  final String initial;
  const _MacroJsonDialog({required this.importing, required this.initial});
  @override
  ConsumerState<_MacroJsonDialog> createState() => _MacroJsonDialogState();
}

class _MacroJsonDialogState extends ConsumerState<_MacroJsonDialog> {
  late final TextEditingController _text;
  bool _busy = false;
  String? _message;
  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (widget.importing) {
        await ref
            .read(automationLibraryProvider.notifier)
            .importJson(_text.text);
        if (mounted) Navigator.pop(context);
      } else {
        await Clipboard.setData(ClipboardData(text: _text.text));
        if (mounted) setState(() => _message = 'Đã sao chép JSON.');
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      scrollable: true,
      title: Text(
        widget.importing
            ? context.tr('Nhập command macros')
            : context.tr('Xuất command macros'),
      ),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.importing
                  ? context.tr(
                      'Nhập thêm bản sao; không ghi đè macro đang có. Tối đa 128 macro, 64 bước/macro, JSON 2 MiB.',
                    )
                  : context.tr(
                      'JSON dạng rõ. Kiểm tra và loại bỏ secret trước khi chia sẻ.',
                    ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('macroJson'),
              controller: _text,
              enabled: !_busy,
              readOnly: !widget.importing,
              minLines: 6,
              maxLines: 12,
              maxLength: widget.importing ? CommandMacro.maxJsonBytes : null,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(labelText: 'JSON'),
            ),
            if (_message != null) Text(context.tr(_message!)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(context.tr('Đóng')),
        ),
        FilledButton(
          key: const Key('macroJsonSubmit'),
          onPressed: _busy ? null : _submit,
          child: Text(
            widget.importing
                ? context.tr('Nhập thêm')
                : context.tr('Sao chép JSON'),
          ),
        ),
      ],
    ),
  );
}
