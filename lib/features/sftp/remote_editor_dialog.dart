import 'package:flutter/material.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/state/app_providers.dart';

Future<void> showRemoteFileEditor(
  BuildContext context,
  WidgetRef ref, {
  required String sessionId,
  required String remotePath,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) =>
        _RemoteFileEditorDialog(sessionId: sessionId, remotePath: remotePath),
  );
}

class _RemoteFileEditorDialog extends ConsumerStatefulWidget {
  final String sessionId;
  final String remotePath;
  const _RemoteFileEditorDialog({
    required this.sessionId,
    required this.remotePath,
  });

  @override
  ConsumerState<_RemoteFileEditorDialog> createState() =>
      _RemoteFileEditorDialogState();
}

class _RemoteFileEditorDialogState
    extends ConsumerState<_RemoteFileEditorDialog> {
  final _ctrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _loaded = false;
  bool _dirty = false;
  bool _allowClose = false;
  bool _closing = false;
  bool _hasError = false;
  String _savedText = '';
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _status = null;
      _hasError = false;
    });
    try {
      final text = await ref
          .read(backendProvider)
          .sftpReadText(widget.sessionId, widget.remotePath);
      if (mounted) {
        _ctrl.text = text;
        setState(() {
          _savedText = text;
          _loading = false;
          _loaded = true;
          _dirty = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loaded = false;
          _hasError = true;
          _status = 'Không đọc được file: $e';
        });
      }
    }
  }

  Future<void> _save() async {
    if (_loading || _saving || !_loaded || !_dirty) return;
    final content = _ctrl.text;
    setState(() {
      _saving = true;
      _status = null;
      _hasError = false;
    });
    try {
      final backend = ref.read(backendProvider);
      var expected = _savedText;
      // SFTP has no atomic compare-and-swap. Re-read immediately before writing
      // and require an explicit choice for every remote change we can observe.
      while (true) {
        final remote = await backend.sftpReadText(
          widget.sessionId,
          widget.remotePath,
        );
        if (!mounted) return;
        if (remote == expected) break;
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(context.tr('File trên server đã thay đổi')),
            content: Text(
              context.tr(
                'Nội dung trên server khác với bản bạn đã mở. Bạn có thể tiếp tục giữ bản đang sửa, tải bản server (bỏ nội dung đang sửa), hoặc xác nhận ghi đè.\n\nỨng dụng sẽ kiểm tra lại trước khi ghi; SFTP không khoá file trong lúc chỉnh sửa.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('keep'),
                child: Text(context.tr('Giữ bản đang sửa')),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('reload'),
                child: Text(context.tr('Tải bản server')),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop('overwrite'),
                child: Text(context.tr('Ghi đè bản server')),
              ),
            ],
          ),
        );
        if (!mounted) return;
        if (choice == 'reload') {
          final latest = await backend.sftpReadText(
            widget.sessionId,
            widget.remotePath,
          );
          if (!mounted) return;
          _ctrl.text = latest;
          setState(() {
            _savedText = latest;
            _dirty = false;
            _status = 'Đã tải bản mới nhất từ server.';
          });
          return;
        }
        if (choice != 'overwrite') {
          setState(() {
            _hasError = true;
            _status = 'Chưa lưu: bản đang sửa vẫn được giữ nguyên.';
          });
          return;
        }
        expected = remote;
      }
      await backend.sftpWriteText(widget.sessionId, widget.remotePath, content);
      if (mounted) {
        setState(() {
          _savedText = content;
          _dirty = _ctrl.text != _savedText;
          _status = 'Đã lưu lên server.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _hasError = true;
          _status = 'Không kiểm tra hoặc lưu được file: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _requestClose() async {
    if (_saving || _closing) return;
    _closing = true;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(context.tr('Bỏ thay đổi chưa lưu?')),
          content: Text(
            context.tr('Nội dung bạn vừa sửa chưa được lưu lên server.'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(context.tr('Tiếp tục sửa')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(context.tr('Bỏ thay đổi')),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (discard != true) {
        _closing = false;
        return;
      }
    }
    if (!mounted) return;
    setState(() => _allowClose = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _allowClose || (!_saving && !_dirty),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
        },
        child: AlertDialog(
          title: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: context.tp.accentContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.edit_document,
                  color: context.tp.accent,
                  size: 17,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.remotePath,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 680,
            height: (MediaQuery.sizeOf(context).height * 0.55).clamp(
              180.0,
              440.0,
            ),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_loaded) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            children: [
                              Icon(
                                _saving
                                    ? Icons.cloud_upload_outlined
                                    : _dirty
                                    ? Icons.edit_outlined
                                    : Icons.check_circle_outline_rounded,
                                size: 15,
                                color: _dirty
                                    ? context.tp.amber
                                    : context.tp.muted,
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  _saving
                                      ? context.tr(
                                          'Đang kiểm tra và lưu lên server…',
                                        )
                                      : _dirty
                                      ? context.tr('Có thay đổi chưa lưu')
                                      : context.tr('Nội dung đã đồng bộ'),
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: context.tp.muted,
                                  ),
                                ),
                              ),
                              if (MediaQuery.sizeOf(context).width >= 520)
                                Text(
                                  'Ctrl / ⌘ + S',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: context.tp.muted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _ctrl,
                            autofocus: true,
                            readOnly: _saving,
                            autocorrect: false,
                            enableSuggestions: false,
                            onChanged: (_) => setState(() {
                              _dirty = _ctrl.text != _savedText;
                              _hasError = false;
                              _status = null;
                            }),
                            maxLines: null,
                            expands: true,
                            textAlignVertical: TextAlignVertical.top,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                            ),
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                      if (!_loaded) ...[
                        const Spacer(),
                        Icon(
                          Icons.cloud_off_rounded,
                          size: 36,
                          color: context.tp.muted,
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: OutlinedButton.icon(
                            onPressed: _load,
                            icon: const Icon(Icons.refresh_rounded),
                            label: Text(context.tr('Thử tải lại')),
                          ),
                        ),
                        const Spacer(),
                      ],
                      if (_status != null) ...[
                        const SizedBox(height: 8),
                        Semantics(
                          liveRegion: true,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 80),
                            child: SingleChildScrollView(
                              child: Text(
                                context.tr(_status!),
                                style: TextStyle(
                                  color: _hasError
                                      ? context.tp.red
                                      : context.tp.green,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: _saving ? null : _requestClose,
              child: Text(context.tr('Đóng')),
            ),
            FilledButton.icon(
              onPressed: (_loading || _saving || !_loaded || !_dirty)
                  ? null
                  : _save,
              icon: const Icon(Icons.cloud_upload_outlined, size: 16),
              label: Text(
                _saving
                    ? context.tr('Đang đẩy lên...')
                    : context.tr('Lưu lên Server'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
