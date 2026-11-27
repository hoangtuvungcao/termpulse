import 'package:flutter/material.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/state/app_providers.dart';

Future<void> showImportExportDialog(BuildContext context, WidgetRef ref) async {
  await showDialog<void>(
    context: context,
    builder: (_) => const _ImportExportDialog(),
  );
}

class _ImportExportDialog extends ConsumerStatefulWidget {
  const _ImportExportDialog();

  @override
  ConsumerState<_ImportExportDialog> createState() =>
      _ImportExportDialogState();
}

class _ImportExportDialogState extends ConsumerState<_ImportExportDialog> {
  String _mode = 'ssh_config';
  final _textCtrl = TextEditingController();
  String? _resultMsg;
  List<String> _warnings = const [];
  bool _busy = false;
  bool _isError = false;

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _runImport() async {
    if (_busy) return;
    final be = ref.read(backendProvider);
    final inventory = ref.read(inventoryProvider.notifier);
    final raw = _textCtrl.text;
    if (raw.trim().isEmpty) {
      setState(() {
        _isError = true;
        _warnings = const [];
        _resultMsg = 'Dán nội dung cấu hình trước khi nhập.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _isError = false;
      _resultMsg = null;
      _warnings = const [];
    });
    try {
      String message;
      List<String> warnings = const [];
      if (_mode == 'ssh_config') {
        final r = await be.importSshConfig(raw);
        warnings = r.warnings;
        message =
            'Đã nhập ${r.hostsImported} Host, ${r.identitiesImported} Identity.';
      } else if (_mode == 'csv') {
        final r = await be.importCsv(raw);
        warnings = r.warnings;
        message = 'Đã nhập ${r.hostsImported} Host từ CSV.';
      } else if (_mode == 'putty') {
        final r = await be.importPuttyReg(raw);
        warnings = r.warnings;
        message = 'Đã nhập ${r.hostsImported} Host từ PuTTY .reg.';
      } else {
        final count = await be.vaultImportJson(raw);
        message = 'Đã nhập $count Host từ JSON.';
      }
      await inventory.refreshAll();
      if (mounted) {
        setState(() {
          _resultMsg = message;
          _warnings = warnings
              .where((warning) => warning.trim().isNotEmpty)
              .toList();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isError = true;
          _resultMsg = 'Không nhập được cấu hình: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runExport(String kind) async {
    if (_busy) return;
    final be = ref.read(backendProvider);
    setState(() {
      _busy = true;
      _isError = false;
      _resultMsg = null;
      _warnings = const [];
    });
    try {
      final data = kind == 'json'
          ? await be.vaultExportJson(includeSecrets: false)
          : await be.exportSshConfig();
      if (!mounted) return;
      _textCtrl.text = data;
      setState(
        () => _resultMsg =
            'Đã xuất $kind. Dùng nút Sao chép để lấy dữ liệu. Thông tin bí mật không được xuất.',
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isError = true;
          _resultMsg = 'Không xuất được cấu hình: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        scrollable: true,
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: context.tp.cyanContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.sync_alt_rounded,
                color: context.tp.cyan,
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                context.tr('Import / Export cấu hình đa nguồn'),
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('~/.ssh/config'),
                    selected: _mode == 'ssh_config',
                    onSelected: _busy
                        ? null
                        : (_) => setState(() => _mode = 'ssh_config'),
                  ),
                  ChoiceChip(
                    label: const Text('CSV'),
                    selected: _mode == 'csv',
                    onSelected: _busy
                        ? null
                        : (_) => setState(() => _mode = 'csv'),
                  ),
                  ChoiceChip(
                    label: const Text('PuTTY .reg'),
                    selected: _mode == 'putty',
                    onSelected: _busy
                        ? null
                        : (_) => setState(() => _mode = 'putty'),
                  ),
                  ChoiceChip(
                    label: const Text('TermPulse JSON'),
                    selected: _mode == 'json',
                    onSelected: _busy
                        ? null
                        : (_) => setState(() => _mode = 'json'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _textCtrl,
                readOnly: _busy,
                autocorrect: false,
                enableSuggestions: false,
                minLines: 4,
                maxLines: 9,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                decoration: InputDecoration(
                  hintText: _mode == 'ssh_config'
                      ? 'Host prod-api\n    HostName 10.0.1.5\n    User deploy\n    ProxyJump bastion'
                      : _mode == 'csv'
                      ? 'label,hostname,port,username,env,tags\napi-01,10.0.0.5,22,deploy,prod,web;eu'
                      : context.tr('Dán nội dung cấu hình vào đây...'),
                ),
              ),
              if (_resultMsg != null) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    context.tr(_resultMsg!),
                    style: TextStyle(
                      color: _isError
                          ? context.tp.red
                          : _warnings.isNotEmpty
                          ? context.tp.amber
                          : context.tp.green,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
              if (_warnings.isNotEmpty) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    context.tr(
                      'Cần kiểm tra ${_warnings.length} cảnh báo trước khi kết nối:',
                    ),
                    style: TextStyle(color: context.tp.amber, fontSize: 13),
                  ),
                ),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 140),
                  child: SingleChildScrollView(
                    key: const Key('importWarnings'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final warning in _warnings)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: SelectableText(
                              context.tr(warning),
                              style: TextStyle(
                                color: context.tp.amber,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => _runExport('ssh_config'),
            child: Text(context.tr('Xuất ssh_config')),
          ),
          TextButton(
            onPressed: _busy ? null : () => _runExport('json'),
            child: Text(context.tr('Xuất JSON')),
          ),
          TextButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    await Clipboard.setData(
                      ClipboardData(text: _textCtrl.text),
                    );
                    if (mounted) {
                      setState(() {
                        _isError = false;
                        _resultMsg = 'Đã sao chép nội dung.';
                      });
                    }
                  },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: Text(context.tr('Sao chép')),
          ),
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text(context.tr('Đóng')),
          ),
          FilledButton(
            onPressed: _busy ? null : _runImport,
            child: Text(
              _busy
                  ? context.tr('Đang xử lý...')
                  : context.tr('Nhập vào Vault'),
            ),
          ),
        ],
      ),
    );
  }
}
