import 'package:flutter/material.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/features/terminal/command_guard_dialog.dart';
import 'package:termpulse/state/app_providers.dart';

final _pendingGuards = Expando<bool>('command guard pending');

/// All one-click executable snippets use the same guard and frozen recipients.
Future<bool> sendGuardedCommand(
  BuildContext context,
  WidgetRef ref,
  String command, {
  bool Function()? canSend,
}) async {
  if (command.trim().isEmpty || (canSend != null && !canSend())) return false;
  final language = AppLocalizationScope.of(context);
  final manager = ref.read(sessionManagerProvider.notifier);
  if (_pendingGuards[manager] ?? false) return false;
  final backend = ref.read(backendProvider);
  final ws = ref.read(sessionManagerProvider);
  final active = ws.activeTab;
  if (active == null || active.closed || active.sessionId == null) return false;
  final recipients = ws.broadcastMode
      ? ws.broadcastTargets.map((tab) => tab.sessionId!).toList()
      : [active.sessionId!];
  final navigatorContext = Navigator.of(context, rootNavigator: true).context;
  final messenger = ScaffoldMessenger.maybeOf(context);
  _pendingGuards[manager] = true;
  try {
    final guard = backend.checkCommandGuard(
      command,
      ws.broadcastMode && ws.broadcastIncludesProd ? 'prod' : active.envTag,
    );
    if (guard.severity != 'safe' || guard.isMultiline) {
      final approved = await showCommandGuardDialog(
        navigatorContext,
        command: command,
        result: guard,
        targetLabel: ws.broadcastMode
            ? context.tr('Broadcast ({count} host)', {
                'count': '${recipients.length}',
              })
            : active.title,
      );
      if (!approved) return false;
    }
    // A macro may be cancelled or lose its Vault/target while the user is
    // reading this confirmation. Do not let a stale dialog dispatch it.
    if (canSend != null && !canSend()) return false;
    return await manager.sendTextToActive(
      '$command\n',
      broadcastIfEnabled: true,
      expectedActiveKey: active.localKey,
      expectedSessionIds: recipients,
      expectedBroadcastMode: ws.broadcastMode,
      validateBeforeSend: canSend,
    );
  } catch (error) {
    if (messenger?.mounted ?? false) {
      messenger!.showSnackBar(
        SnackBar(
          content: Text(
            translateAppMessage(language, 'Không gửi được lệnh: {error}', {
              'error': error.toString(),
            }),
          ),
        ),
      );
    }
    return false;
  } finally {
    _pendingGuards[manager] = false;
  }
}
