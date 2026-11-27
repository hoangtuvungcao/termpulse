import 'dart:async';

import 'package:flutter/material.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/security/host_trust_service.dart';
import 'package:termpulse/state/app_providers.dart';

/// Mount below MaterialApp's Navigator so prompts cover every workspace route.
class SshTrustGate extends ConsumerStatefulWidget {
  const SshTrustGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SshTrustGate> createState() => _SshTrustGateState();
}

class _SshTrustGateState extends ConsumerState<SshTrustGate> {
  Timer? _timer;
  bool _polling = false;
  DialogRoute<void>? _route;
  HostKeyPromptDto? _active;
  String? _vaultPath;
  HostTrustService? _service;
  final Set<String> _resolvedRequests = {};

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 300), (_) => _poll());
    WidgetsBinding.instance.addPostFrameCallback((_) => _poll());
  }

  void _closePrompt() {
    final route = _route;
    _route = null;
    _active = null;
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
  }

  Future<void> _poll() async {
    if (!mounted || _polling) return;
    final vault = ref.read(vaultProvider);
    final service = ref.read(hostTrustServiceProvider);
    if (!vault.unlocked || vault.loading || service == null) {
      _closePrompt();
      _vaultPath = null;
      return;
    }
    if (_vaultPath != vault.dbPath || !identical(_service, service)) {
      _closePrompt();
      _vaultPath = vault.dbPath;
      _service = service;
      _resolvedRequests.clear();
    }
    final scope = vault.dbPath;
    _polling = true;
    try {
      final response = await service.pending();
      if (!mounted) return;
      final requests = response
          .where((request) => !_resolvedRequests.contains(request.requestId))
          .toList();
      final currentVault = ref.read(vaultProvider);
      if (!currentVault.unlocked ||
          currentVault.loading ||
          currentVault.dbPath != scope ||
          !identical(ref.read(hostTrustServiceProvider), service)) {
        _closePrompt();
        return;
      }
      final active = _active;
      if (active != null) {
        if (!requests.any((request) => request.requestId == active.requestId)) {
          _closePrompt();
        }
        return;
      }
      if (requests.isEmpty) return;
      final prompt = requests.first;
      _active = prompt;
      final route = DialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => SshTrustPromptDialog(
          prompt: prompt,
          service: service,
          onResolved: () {
            _resolvedRequests.add(prompt.requestId);
            if (_resolvedRequests.length > 64) {
              _resolvedRequests.remove(_resolvedRequests.first);
            }
          },
        ),
      );
      _route = route;
      unawaited(
        Navigator.of(context, rootNavigator: true).push(route).whenComplete(() {
          if (identical(_route, route)) {
            _route = null;
            _active = null;
          }
        }),
      );
    } catch (_) {
      // A locked/switched Vault has no active trust scope. Rust cancels its
      // actual handshake; the UI must not keep a stale approval available.
      if (mounted) _closePrompt();
    } finally {
      _polling = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    final active = _active;
    final service = _service;
    if (active != null && service != null) {
      unawaited(service.decide(active, 'reject').catchError((Object _) {}));
    }
    final route = _route;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive && route.navigator?.mounted == true) {
          route.navigator?.removeRoute(route);
        }
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(vaultProvider, (previous, next) {
      if (!next.unlocked || next.loading || previous?.dbPath != next.dbPath) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _closePrompt();
        });
      }
    });
    return widget.child;
  }
}

class SshTrustPromptDialog extends StatefulWidget {
  const SshTrustPromptDialog({
    super.key,
    required this.prompt,
    required this.service,
    this.onResolved,
  });

  final HostKeyPromptDto prompt;
  final HostTrustService service;
  final VoidCallback? onResolved;

  @override
  State<SshTrustPromptDialog> createState() => _SshTrustPromptDialogState();
}

class _SshTrustPromptDialogState extends State<SshTrustPromptDialog> {
  final _fingerprint = TextEditingController();
  bool _verified = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _fingerprint.dispose();
    super.dispose();
  }

  Future<void> _decide(String decision) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.decide(widget.prompt, decision);
      if (mounted) {
        widget.onResolved?.call();
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Không áp dụng được quyết định: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final prompt = widget.prompt;
    final changed = prompt.changed;
    final verified = changed
        ? _fingerprint.text.trim() == prompt.fingerprint
        : _verified;
    final validUntil = int.tryParse(prompt.certificateValidUntil ?? '');
    final certificateExpiry = validUntil == null || validUntil >= 8640000000000
        ? context.tr('Không giới hạn')
        : DateTime.fromMillisecondsSinceEpoch(
            validUntil * 1000,
            isUtc: true,
          ).toLocal().toString();
    return PopScope(
      canPop: false,
      child: AlertDialog(
        key: const Key('sshTrustDialog'),
        icon: Icon(
          changed ? Icons.gpp_maybe_rounded : Icons.verified_user_outlined,
          color: changed
              ? context.tp.red
              : Theme.of(context).colorScheme.primary,
        ),
        title: Text(
          changed
              ? context.tr('Khóa máy chủ SSH đã thay đổi')
              : context.tr('Xác minh máy chủ SSH'),
        ),
        content: SizedBox(
          width: 570,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SelectableText(
                  '${prompt.hostname}:${prompt.port}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  changed
                      ? context.tr(
                          'Khóa hiện tại khác bản ghi đã lưu. Đây có thể là đổi máy chủ hợp lệ hoặc một cuộc tấn công. Hãy xác minh với quản trị viên qua kênh độc lập trước khi thay thế.',
                        )
                      : context.tr(
                          'Máy chủ này chưa được tin cậy trong Vault hiện tại. So sánh dấu vân tay với quản trị viên qua một kênh độc lập trước khi kết nối.',
                        ),
                ),
                const SizedBox(height: 16),
                Text(
                  prompt.certificateAuthority
                      ? context.tr(
                          'Dấu vân tay CA ký chứng chỉ (${prompt.algorithm})',
                        )
                      : context.tr(
                          'Dấu vân tay host key (${prompt.algorithm})',
                        ),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 6),
                SelectableText(
                  prompt.fingerprint,
                  key: const Key('sshTrustFingerprint'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
                if (prompt.certificateAuthority) ...[
                  const SizedBox(height: 12),
                  Text(
                    context.tr(
                      'Chấp thuận sẽ tin cậy CA này chỉ cho tên máy chủ và cổng ở trên. Chữ ký, thời hạn và principal được kiểm tra trên mỗi kết nối.',
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    context.tr(
                      'Khóa máy chủ: ${prompt.serverKeyFingerprint}\nPrincipal: ${prompt.certificatePrincipals.join(', ')}\nHết hạn: $certificateExpiry',
                    ),
                    style: TextStyle(fontSize: 12, color: context.tp.muted),
                  ),
                ],
                if (changed) ...[
                  const SizedBox(height: 14),
                  Text(context.tr('Dấu vân tay đã lưu')),
                  for (final previous in prompt.previousFingerprints)
                    SelectableText(
                      previous,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: context.tp.muted,
                      ),
                    ),
                  const SizedBox(height: 14),
                  TextField(
                    key: const Key('sshTrustFingerprintField'),
                    controller: _fingerprint,
                    enabled: !_busy,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: context.tr('Nhập dấu vân tay mới đã xác minh'),
                      hintText: 'SHA256:…',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ] else ...[
                  const SizedBox(height: 14),
                  CheckboxListTile(
                    key: const Key('sshTrustVerifiedCheckbox'),
                    value: _verified,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _verified = value ?? false),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      context.tr(
                        'Tôi đã đối chiếu dấu vân tay qua kênh tin cậy',
                      ),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      context.tr(_error!),
                      style: TextStyle(color: context.tp.red),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('sshTrustRejectButton'),
            onPressed: _busy ? null : () => _decide('reject'),
            child: Text(context.tr('Từ chối kết nối')),
          ),
          FilledButton.icon(
            key: Key(
              changed ? 'sshTrustReplaceButton' : 'sshTrustApproveButton',
            ),
            style: changed
                ? FilledButton.styleFrom(backgroundColor: context.tp.red)
                : null,
            onPressed: !_busy && verified
                ? () => _decide(changed ? 'replace_verified' : 'trust')
                : null,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    changed
                        ? Icons.published_with_changes_rounded
                        : Icons.check_rounded,
                    size: 18,
                  ),
            label: Text(
              changed
                  ? context.tr('Thay thế khóa đã xác minh')
                  : context.tr('Tin cậy và kết nối'),
            ),
          ),
        ],
      ),
    );
  }
}
