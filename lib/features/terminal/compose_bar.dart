import 'package:flutter/material.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/terminal/command_guard_dialog.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';

class ComposeBar extends ConsumerStatefulWidget {
  const ComposeBar({super.key});

  @override
  ConsumerState<ComposeBar> createState() => _ComposeBarState();
}

class _ComposeBarState extends ConsumerState<ComposeBar> {
  final _ctrl = TextEditingController();
  String? _ghost;
  String? _error;
  bool _sending = false;
  bool _transmitting = false;
  int _suggestionRequest = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _onChanged(String val) async {
    final request = ++_suggestionRequest;
    if (_error != null) setState(() => _error = null);
    if (val.trim().isEmpty) {
      if (_ghost != null) setState(() => _ghost = null);
      return;
    }
    try {
      final s = await ref.read(backendProvider).suggestCommandGhost(val);
      if (mounted && request == _suggestionRequest && _ctrl.text == val) {
        setState(() => _ghost = s);
      }
    } catch (_) {}
  }

  void _acceptSuggestion() {
    if (_ghost == null) return;
    _suggestionRequest++;
    _ctrl.text += _ghost!;
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    setState(() => _ghost = null);
  }

  Future<void> _send() async {
    if (_sending) return;
    final cmd = _ctrl.text;
    if (cmd.trim().isEmpty) return;
    final ws = ref.read(sessionManagerProvider);
    final active = ws.activeTab;
    if (active == null || active.closed || active.sessionId == null) return;

    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final envToCheck = ws.broadcastMode && ws.broadcastIncludesProd
          ? 'prod'
          : active.envTag;
      final guard = ref
          .read(backendProvider)
          .checkCommandGuard(cmd, envToCheck);
      if (guard.severity != 'safe' || guard.isMultiline) {
        final label = ws.broadcastMode
            ? context.tr('Broadcast ({count} host)', {
                'count': '${ws.broadcastTargets.length}',
              })
            : active.title;
        final ok = await showCommandGuardDialog(
          context,
          command: cmd,
          result: guard,
          targetLabel: label,
        );
        if (!mounted || !ok) return;
      }

      if (ref.read(sessionManagerProvider).activeTab?.localKey !=
          active.localKey) {
        throw StateError(
          'Phiên đang hoạt động đã thay đổi. Vui lòng kiểm tra lại lệnh.',
        );
      }
      setState(() => _transmitting = true);
      final sent = await ref
          .read(sessionManagerProvider.notifier)
          .sendTextToActive(
            '$cmd\n',
            broadcastIfEnabled: true,
            expectedActiveKey: active.localKey,
            expectedBroadcastMode: ws.broadcastMode,
            expectedSessionIds: ws.broadcastMode
                ? ws.broadcastTargets.map((tab) => tab.sessionId!).toList()
                : [active.sessionId!],
          );
      if (!mounted) return;
      if (!sent) {
        final reason = ref.read(sessionManagerProvider).lastError;
        setState(
          () => _error =
              reason ??
              'Không gửi được lệnh. Vui lòng kiểm tra kết nối rồi thử lại.',
        );
        return;
      }
      _suggestionRequest++;
      if (_ctrl.text == cmd) _ctrl.clear();
      setState(() => _ghost = null);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Không gửi được lệnh: $error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _transmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ws = ref.watch(sessionManagerProvider);
    final s = ref.s;
    final tp = context.tp;
    final bcastProd = ws.broadcastMode && ws.broadcastIncludesProd;
    final canSend =
        !_sending &&
        ws.activeTab?.sessionId != null &&
        !(ws.activeTab?.closed ?? true);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _send,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send,
        if (_ghost != null && _ghost!.isNotEmpty)
          const SingleActivator(LogicalKeyboardKey.tab): _acceptSuggestion,
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
        decoration: BoxDecoration(
          color: tp.surface,
          border: Border(top: BorderSide(color: tp.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_ghost != null && _ghost!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _acceptSuggestion,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: tp.accentContainer,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: tp.accent.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Text(
                      'Tab: ${_ctrl.text}$_ghost',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: tp.accent,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
            // Warp-inspired Floating Command Block Capsule
            Container(
              padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
              decoration: BoxDecoration(
                color: tp.surface2,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: ws.broadcastMode
                      ? (bcastProd
                            ? tp.red.withValues(alpha: 0.55)
                            : tp.amber.withValues(alpha: 0.55))
                      : tp.borderStrong,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color:
                          (ws.broadcastMode
                                  ? (bcastProd ? tp.red : tp.amber)
                                  : tp.accent)
                              .withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      '>_',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                        color: ws.broadcastMode
                            ? (bcastProd ? tp.red : tp.amber)
                            : tp.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      key: const Key('composePaneField'),
                      controller: _ctrl,
                      enabled: !_sending,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.send,
                      minLines: 1,
                      maxLines: 3,
                      onChanged: _onChanged,
                      onSubmitted: (_) => _send(),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                      decoration: InputDecoration(
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 8,
                        ),
                        hintText: s.composeHint(
                          ws.broadcastTargets.length,
                          ws.broadcastMode,
                        ),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  FilledButton.icon(
                    key: const Key('composeSendButton'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 9,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      backgroundColor: ws.broadcastMode
                          ? (bcastProd ? tp.red : tp.amber)
                          : tp.accent,
                      foregroundColor: ws.broadcastMode ? tp.bg : tp.accentInk,
                    ),
                    onPressed: canSend ? _send : null,
                    icon: _transmitting
                        ? const SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded, size: 16),
                    label: Text(
                      ws.broadcastMode ? s.sendBroadcastBtn : s.sendBtn,
                    ),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Text(
                  context.tr(_error!),
                  style: TextStyle(color: tp.red, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
