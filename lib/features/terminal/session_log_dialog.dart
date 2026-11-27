import 'dart:io';

import 'package:flutter/material.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/session_log_store.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/workspace/file_path_dialog.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/session_logs_provider.dart';

void _message(BuildContext context, String text) {
  if (context.mounted) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(context.tr(text))));
  }
}

Future<void> toggleSessionLogging(
  BuildContext context,
  WidgetRef ref,
  TerminalSessionTab tab,
) async {
  final logs = ref.read(sessionLogsProvider.notifier);
  if (ref.read(sessionLogsProvider).activeFor(tab.localKey) != null) {
    await logs.stopSession(tab.localKey);
    return;
  }
  if (tab.closed || tab.sessionId == null) return;
  final approved = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text(context.tr('Bắt đầu ghi log phiên?')),
      content: Text(
        context.tr(
          '{name}\n\nChỉ ghi dữ liệu terminal nhận từ lúc bật, không ghi phím gõ trực tiếp. Đầu ra vẫn có thể chứa mật khẩu hoặc thông tin nhạy cảm do máy chủ in ra.\n\nLog lưu dạng văn bản rõ ngoài Vault, tối đa 20 MiB mỗi lượt. Ghi log dừng khi ngắt phiên, khóa Vault hoặc thoát ứng dụng; kết nối lại không tự bật ghi.',
          {'name': tab.title},
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(context.tr('Hủy')),
        ),
        FilledButton(
          key: const Key('confirmStartSessionLog'),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(context.tr('Bắt đầu ghi')),
        ),
      ],
    ),
  );
  if (approved != true || !context.mounted) return;
  final current = ref
      .read(sessionManagerProvider)
      .tabs
      .where((item) => item.localKey == tab.localKey)
      .firstOrNull;
  if (current == null || current.closed || current.sessionId != tab.sessionId) {
    _message(
      context,
      context.tr('Phiên đã thay đổi. Chọn lại phiên trước khi ghi log.'),
    );
    return;
  }
  final started = await logs.start(
    sessionKey: tab.localKey,
    title: current.title,
    protocol: current.protocol,
  );
  if (!context.mounted) return;
  final after = ref
      .read(sessionManagerProvider)
      .tabs
      .where((item) => item.localKey == tab.localKey)
      .firstOrNull;
  if (after == null || after.closed || after.sessionId != tab.sessionId) {
    await logs.stopSession(tab.localKey);
    return;
  }
  _message(
    context,
    started
        ? context.tr('Đang ghi đầu ra: {name}', {'name': current.title})
        : ref.read(sessionLogsProvider).error ??
              context.tr('Không ghi được log.'),
  );
}

Future<void> exportTerminalScrollback(
  BuildContext context,
  TerminalSessionTab tab,
) async {
  final content = tab.terminal.buffer.getText();
  final path = await requestOutputPath(
    context,
    title: context.tr('Xuất nội dung terminal hiện có'),
    fileName: 'terminal_${DateTime.now().millisecondsSinceEpoch}.txt',
  );
  if (path == null || !context.mounted) return;
  try {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
    if (context.mounted) {
      _message(
        context,
        context.tr('Đã xuất phần lịch sử còn trong terminal: {path}', {
          'path': path,
        }),
      );
    }
  } catch (error) {
    if (context.mounted) {
      _message(
        context,
        context.tr('Không xuất được: {error}', {'error': error.toString()}),
      );
    }
  }
}

Future<void> showSessionLogsDialog(BuildContext context, WidgetRef ref) async {
  await showDialog<void>(
    context: context,
    builder: (_) => const _SessionLogsDialog(),
  );
}

String _size(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB'
    : '${(bytes / 1024).toStringAsFixed(1)} KiB';

class _SessionLogsDialog extends ConsumerStatefulWidget {
  const _SessionLogsDialog();
  @override
  ConsumerState<_SessionLogsDialog> createState() => _SessionLogsDialogState();
}

class _SessionLogsDialogState extends ConsumerState<_SessionLogsDialog> {
  String _query = '';
  String? _busyId;
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) ref.read(sessionLogsProvider.notifier).load();
    });
  }

  Future<void> _export(SessionLogEntry entry) async {
    final store = ref.read(sessionLogStoreProvider);
    final path = await requestOutputPath(
      context,
      title: context.tr('Xuất log đầy đủ'),
      fileName: '${entry.id}.log',
    );
    if (path == null || !mounted) return;
    await File(path).parent.create(recursive: true);
    await store.export(entry.id, path);
    if (mounted) {
      _message(context, context.tr('Đã xuất log: {path}', {'path': path}));
    }
  }

  Future<void> _preview(SessionLogEntry entry) async {
    final store = ref.read(sessionLogStoreProvider);
    final text = await store.preview(entry.id);
    // Translate only the application's preview-limit footer; leave received
    // terminal output untouched even when it matches a translation key.
    const previewLimit =
        '\n\n[Chỉ xem trước 512 KiB đầu. Xuất log để đọc toàn bộ.]';
    final file = await store.fileFor(entry.id);
    final truncated =
        await file.length() > 512 * 1024 && text.endsWith(previewLimit);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 780,
          height: MediaQuery.sizeOf(ctx).height * 0.55,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(
                file.path,
                style: TextStyle(fontSize: 11, color: ctx.tp.muted),
              ),
              const Divider(),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText(
                    truncated
                        ? '${text.substring(0, text.length - previewLimit.length)}\n\n[${ctx.tr('Chỉ xem trước 512 KiB đầu. Xuất log để đọc toàn bộ.')}]'
                        : text,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) {
                _message(ctx, ctx.tr('Đã sao chép phần xem trước.'));
              }
            },
            icon: const Icon(Icons.copy_rounded, size: 17),
            label: Text(ctx.tr('Sao chép')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.tr('Đóng')),
          ),
        ],
      ),
    );
  }

  Future<void> _action(SessionLogEntry entry, String action) async {
    if (_busyId != null) return;
    setState(() => _busyId = entry.id);
    try {
      switch (action) {
        case 'preview':
          await _preview(entry);
        case 'export':
          await _export(entry);
        case 'stop':
          await ref
              .read(sessionLogsProvider.notifier)
              .stopSession(entry.sessionKey);
        case 'delete':
          final approved = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              scrollable: true,
              title: Text(context.tr('Xóa tệp log cục bộ?')),
              content: Text(
                context.tr(
                  '{name}\n{date}\n\nTệp log sẽ bị xóa khỏi máy này. Thao tác không hoàn tác.',
                  {'name': entry.title, 'date': '${entry.startedAt.toLocal()}'},
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(context.tr('Hủy')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(context.tr('Xóa log')),
                ),
              ],
            ),
          );
          if (approved == true && mounted) {
            await ref.read(sessionLogsProvider.notifier).delete(entry.id);
          }
      }
    } catch (error) {
      if (mounted) {
        _message(
          context,
          context.tr('Không thực hiện được: {error}', {
            'error': error.toString(),
          }),
        );
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(sessionLogsProvider);
    final active = ref.watch(sessionManagerProvider).activeTab;
    final query = _query.trim().toLowerCase();
    final entries = logs.entries
        .where(
          (entry) =>
              '${entry.title} ${entry.protocol} ${entry.startedAt.toLocal()}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList();
    final recording = active == null
        ? false
        : logs.activeFor(active.localKey) != null;
    return Dialog(
      key: const Key('sessionLogsDialog'),
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 850, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.receipt_long_rounded),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      context.tr('Nhật ký phiên'),
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('Đóng'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              Text(
                context.tr(
                  'Log đầu ra lưu dạng rõ ngoài Vault. Chỉ ghi khi bạn chủ động bật; không tự ghi lại sau reconnect.',
                ),
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('sessionLogSearch'),
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  hintText: context.tr(
                    'Tìm theo tên phiên, giao thức hoặc ngày',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  FilledButton.tonalIcon(
                    key: const Key('sessionLogToggle'),
                    onPressed:
                        active == null ||
                            active.closed ||
                            active.sessionId == null
                        ? null
                        : () => toggleSessionLogging(context, ref, active),
                    icon: Icon(
                      recording
                          ? Icons.stop_circle_outlined
                          : Icons.fiber_manual_record_rounded,
                      size: 17,
                    ),
                    label: Text(
                      recording
                          ? context.tr('Dừng ghi phiên hiện tại')
                          : context.tr('Ghi phiên hiện tại'),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: active == null
                        ? null
                        : () => exportTerminalScrollback(context, active),
                    icon: const Icon(Icons.save_alt_rounded, size: 17),
                    label: Text(context.tr('Xuất scrollback')),
                  ),
                ],
              ),
              if (logs.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: SelectableText(
                    context.tr(logs.error!),
                    style: TextStyle(color: context.tp.red, fontSize: 12),
                  ),
                ),
              if (logs.loading) const LinearProgressIndicator(),
              const SizedBox(height: 4),
              Expanded(
                child: entries.isEmpty
                    ? Center(
                        child: Text(
                          query.isEmpty
                              ? context.tr(
                                  'Chưa có log. Mở một phiên và chọn Ghi phiên hiện tại.',
                                )
                              : context.tr('Không có log khớp bộ lọc.'),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (ctx, index) {
                          final entry = entries[index];
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            leading: Icon(
                              entry.active
                                  ? Icons.fiber_manual_record_rounded
                                  : Icons.description_outlined,
                              color: entry.active
                                  ? context.tp.red
                                  : context.tp.muted,
                            ),
                            title: Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${entry.protocol.toUpperCase()} · ${entry.startedAt.toLocal().toString().split('.').first}\n${entry.active ? context.tr('Đang ghi') : context.tr('Đã dừng')} · ${_size(entry.bytes)}${entry.error == null ? '' : '\n${context.tr(entry.error!)}'}',
                              maxLines: 4,
                            ),
                            onTap: _busyId == null
                                ? () => _action(entry, 'preview')
                                : null,
                            trailing: PopupMenuButton<String>(
                              enabled: _busyId == null,
                              onSelected: (action) => _action(entry, action),
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: 'preview',
                                  child: Text(context.tr('Xem log')),
                                ),
                                PopupMenuItem(
                                  value: 'export',
                                  child: Text(context.tr('Xuất tệp đầy đủ')),
                                ),
                                if (entry.active)
                                  PopupMenuItem(
                                    value: 'stop',
                                    child: Text(context.tr('Dừng ghi')),
                                  ),
                                PopupMenuItem(
                                  value: 'delete',
                                  enabled: !entry.active,
                                  child: Text(context.tr('Xóa log')),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              Text(
                context.tr('{count} log · {active} đang ghi', {
                  'count': '${logs.entries.length}',
                  'active':
                      '${logs.entries.where((entry) => entry.active).length}',
                }),
                style: TextStyle(color: context.tp.muted, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
