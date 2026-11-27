import 'package:flutter/material.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/security/host_trust_service.dart';
import 'package:termpulse/state/app_providers.dart';

Future<void> showSshHostKeysDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _HostKeysDialog());

class _HostKeysDialog extends ConsumerStatefulWidget {
  const _HostKeysDialog();

  @override
  ConsumerState<_HostKeysDialog> createState() => _HostKeysDialogState();
}

class _HostKeysDialogState extends ConsumerState<_HostKeysDialog> {
  List<HostKeyRecordDto> _records = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  late final String _scope;

  @override
  void initState() {
    super.initState();
    _scope = ref.read(vaultProvider).dbPath;
    _load();
  }

  HostTrustService _service() {
    final vault = ref.read(vaultProvider);
    if (!vault.unlocked || vault.dbPath != _scope) {
      throw StateError(
        'Vault đã khóa hoặc thay đổi. Hãy đóng và mở lại danh sách.',
      );
    }
    final service = ref.read(hostTrustServiceProvider);
    if (service == null) {
      throw StateError('Backend hiện tại không hỗ trợ quản lý host key.');
    }
    return service;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final records = await _service().records();
      _service();
      records.sort(
        (a, b) =>
            '${a.hostname}:${a.port}'.compareTo('${b.hostname}:${b.port}'),
      );
      if (mounted) setState(() => _records = records);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _remove(HostKeyRecordDto record) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _service();
      final fingerprint = await showDialog<String>(
        context: context,
        builder: (_) => _RemoveHostKeyDialog(record: record),
      );
      if (fingerprint == null || !mounted) return;
      await _service().remove(record, fingerprint);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _error = 'Không xóa được host key: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = _service();
      final saved = await showDialog<bool>(
        context: context,
        builder: (_) => _ImportHostKeyDialog(service: service, scope: _scope),
      );
      if (saved == true && mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(HostKeyRecordDto record) async {
    try {
      await Clipboard.setData(ClipboardData(text: record.publicKey));
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(context.tr('Đã sao chép public key'))),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Không sao chép được: $error');
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      key: const Key('sshHostKeysDialog'),
      title: Text(context.tr('Khóa máy chủ SSH')),
      content: SizedBox(
        width: 650,
        height: (MediaQuery.sizeOf(context).height * 0.56).clamp(180.0, 480.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.tr(
                'Host key và CA được lưu riêng theo Vault. Chỉ tên máy chủ và cổng chính xác được tin cậy. Xóa bản ghi sẽ yêu cầu xác minh lại ở lần kết nối tiếp theo.',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 92),
                child: SingleChildScrollView(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      context.tr(_error!),
                      style: TextStyle(color: context.tp.red),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _records.isEmpty
                  ? Center(
                      child: Text(
                        _error == null
                            ? context.tr(
                                'Chưa có máy chủ nào được tin cậy.\nKết nối SSH hoặc nhập public key đã xác minh để bắt đầu.',
                              )
                            : context.tr(
                                'Không tải được bản ghi. Hãy thử tải lại.',
                              ),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: context.tp.muted),
                      ),
                    )
                  : ListView.separated(
                      key: const Key('sshHostKeysList'),
                      itemCount: _records.length,
                      separatorBuilder: (_, index) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final record = _records[index];
                        return Card(
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      record.revoked
                                          ? Icons.gpp_bad_rounded
                                          : record.certificateAuthority
                                          ? Icons.verified_user_rounded
                                          : Icons.key_rounded,
                                      color: record.revoked
                                          ? context.tp.red
                                          : Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '${record.hostname}:${record.port}',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleSmall,
                                      ),
                                    ),
                                    IconButton(
                                      key: ValueKey(
                                        'sshHostKeyCopy:${record.recordId}',
                                      ),
                                      tooltip: context.tr(
                                        'Sao chép public key',
                                      ),
                                      onPressed: _busy
                                          ? null
                                          : () => _copy(record),
                                      icon: const Icon(
                                        Icons.copy_rounded,
                                        size: 18,
                                      ),
                                    ),
                                    IconButton(
                                      key: ValueKey(
                                        'sshHostKeyRemove:${record.recordId}',
                                      ),
                                      tooltip: record.revoked
                                          ? context.tr('Xóa bản ghi thu hồi')
                                          : context.tr('Xóa và xác minh lại'),
                                      onPressed: _busy
                                          ? null
                                          : () => _remove(record),
                                      icon: Icon(
                                        Icons.delete_outline_rounded,
                                        color: context.tp.red,
                                        size: 20,
                                      ),
                                    ),
                                  ],
                                ),
                                Text(
                                  '${record.revoked
                                      ? context.tr('Đã thu hồi')
                                      : record.certificateAuthority
                                      ? context.tr('CA chứng chỉ máy chủ')
                                      : context.tr('Host key')} · ${record.algorithm}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: context.tp.muted,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                SelectableText(
                                  record.fingerprint,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          key: const Key('sshHostKeysRefreshButton'),
          onPressed: _busy || _loading ? null : _load,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: Text(context.tr('Tải lại')),
        ),
        OutlinedButton.icon(
          key: const Key('sshHostKeysImportButton'),
          onPressed: _busy || _loading ? null : _import,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: Text(context.tr('Nhập key / CA')),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(context.tr('Đóng')),
        ),
      ],
    ),
  );
}

class _RemoveHostKeyDialog extends StatefulWidget {
  const _RemoveHostKeyDialog({required this.record});
  final HostKeyRecordDto record;

  @override
  State<_RemoveHostKeyDialog> createState() => _RemoveHostKeyDialogState();
}

class _RemoveHostKeyDialogState extends State<_RemoveHostKeyDialog> {
  final _fingerprint = TextEditingController();

  @override
  void dispose() {
    _fingerprint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.record.revoked
          ? context.tr('Xóa bản ghi thu hồi?')
          : context.tr('Xóa khóa máy chủ?'),
    ),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${widget.record.hostname}:${widget.record.port}'),
            const SizedBox(height: 10),
            Text(
              widget.record.revoked
                  ? context.tr(
                      'Xóa bản ghi thu hồi sẽ cho phép khóa này được xem xét tin cậy trở lại. Chỉ thực hiện khi đã xác minh nguyên nhân thu hồi.',
                    )
                  : context.tr(
                      'Lần kết nối tiếp theo sẽ yêu cầu xác minh lại. Không xóa cảnh báo thay khóa chỉ để bỏ qua kiểm tra bảo mật.',
                    ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              widget.record.fingerprint,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('sshHostKeyRemoveFingerprintField'),
              controller: _fingerprint,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: context.tr('Nhập đúng dấu vân tay để xác nhận xóa'),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(context.tr('Hủy')),
      ),
      FilledButton(
        key: const Key('sshHostKeyRemoveConfirmButton'),
        style: FilledButton.styleFrom(backgroundColor: context.tp.red),
        onPressed: _fingerprint.text.trim() == widget.record.fingerprint
            ? () => Navigator.of(context).pop(_fingerprint.text.trim())
            : null,
        child: Text(context.tr('Xóa bản ghi')),
      ),
    ],
  );
}

class _ImportHostKeyDialog extends ConsumerStatefulWidget {
  const _ImportHostKeyDialog({required this.service, required this.scope});
  final HostTrustService service;
  final String scope;

  @override
  ConsumerState<_ImportHostKeyDialog> createState() =>
      _ImportHostKeyDialogState();
}

class _ImportHostKeyDialogState extends ConsumerState<_ImportHostKeyDialog> {
  final _hostname = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _publicKey = TextEditingController();
  final _fingerprint = TextEditingController();
  bool _ca = false;
  bool _replace = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _hostname.dispose();
    _port.dispose();
    _publicKey.dispose();
    _fingerprint.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final vault = ref.read(vaultProvider);
      if (!vault.unlocked || vault.dbPath != widget.scope) {
        throw StateError('Vault đã khóa hoặc thay đổi.');
      }
      final port = int.tryParse(_port.text.trim());
      if (_hostname.text.trim().isEmpty ||
          port == null ||
          port < 1 ||
          port > 65535 ||
          _publicKey.text.trim().isEmpty ||
          !_fingerprint.text.trim().startsWith('SHA256:')) {
        throw const FormatException(
          'Nhập hostname chính xác, cổng 1–65535, public key OpenSSH và dấu vân tay SHA256 đã xác minh.',
        );
      }
      await widget.service.importKey(
        hostname: _hostname.text.trim(),
        port: port,
        publicKey: _publicKey.text.trim(),
        certificateAuthority: _ca,
        replaceExisting: _replace,
        expectedFingerprint: _fingerprint.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = 'Không nhập được host key: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      key: const Key('sshHostKeyImportDialog'),
      title: Text(context.tr('Nhập host key / CA đã xác minh')),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.tr(
                  'Lấy public key và dấu vân tay SHA256 từ quản trị viên qua kênh tin cậy. Không nhập private key. CA chỉ được áp dụng cho hostname và cổng này.',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const Key('sshHostKeyHostnameField'),
                controller: _hostname,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: context.tr('Hostname / IP chính xác'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('sshHostKeyPortField'),
                controller: _port,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: context.tr('Cổng SSH')),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('sshHostKeyPublicKeyField'),
                controller: _publicKey,
                enabled: !_busy,
                minLines: 3,
                maxLines: 5,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: context.tr('Public key OpenSSH'),
                  hintText: 'ssh-ed25519 AAAA…',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('sshHostKeyExpectedFingerprintField'),
                controller: _fingerprint,
                enabled: !_busy,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: context.tr('Dấu vân tay đã xác minh'),
                  hintText: 'SHA256:…',
                ),
              ),
              CheckboxListTile(
                key: const Key('sshHostKeyCaCheckbox'),
                contentPadding: EdgeInsets.zero,
                value: _ca,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _ca = value ?? false),
                title: Text(context.tr('Đây là CA ký chứng chỉ máy chủ')),
              ),
              CheckboxListTile(
                key: const Key('sshHostKeyReplaceCheckbox'),
                contentPadding: EdgeInsets.zero,
                value: _replace,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _replace = value ?? false),
                title: Text(
                  context.tr('Thay thế key / CA hiện có sau khi đã xác minh'),
                ),
                subtitle: Text(
                  context.tr(
                    'Bản ghi thu hồi vẫn được giữ và luôn chặn khóa đã thu hồi.',
                  ),
                ),
              ),
              if (_error != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    context.tr(_error!),
                    style: TextStyle(color: context.tp.red),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(context.tr('Hủy')),
        ),
        FilledButton(
          key: const Key('sshHostKeyImportSaveButton'),
          onPressed: _busy ? null : _save,
          child: Text(
            _busy
                ? context.tr('Đang nhập…')
                : context.tr('Lưu khóa đã xác minh'),
          ),
        ),
      ],
    ),
  );
}
