import 'dart:async';

import 'package:flutter/material.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/terminal/guarded_command.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/ui/widgets/ui_kit.dart';

Future<void> showCommandPaletteDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) => const _CommandPaletteDialog(),
  );
}

class _CommandPaletteDialog extends ConsumerStatefulWidget {
  const _CommandPaletteDialog();

  @override
  ConsumerState<_CommandPaletteDialog> createState() =>
      _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends ConsumerState<_CommandPaletteDialog> {
  final _queryCtrl = TextEditingController();
  final _scrollController = ScrollController();
  final _queryFocus = FocusNode();
  List<_PaletteAction> _visibleItems = [];
  int _selectedIndex = 0;
  bool _running = false;

  void _moveSelection(int delta) {
    if (_visibleItems.isNotEmpty) {
      setState(
        () => _selectedIndex = (_selectedIndex + delta) % _visibleItems.length,
      );
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(
          (_selectedIndex * 76.0).clamp(
            0,
            _scrollController.position.maxScrollExtent,
          ),
        );
      }
    }
  }

  Future<void> _run(_PaletteAction action) async {
    if (_running) return;
    _running = true;
    final navigator = Navigator.of(context);
    final feedbackContext = navigator.overlay?.context;
    navigator.pop();
    try {
      await action.onRun();
    } catch (error) {
      if (feedbackContext != null && feedbackContext.mounted) {
        showAppErrorSnackBar(feedbackContext, error.toString());
      }
    }
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    _queryFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inv = ref.watch(inventoryProvider);
    final ws = ref.watch(sessionManagerProvider);
    final tp = context.tp;
    final q = _queryCtrl.text.trim().toLowerCase();

    final items =
        <_PaletteAction>[
          _PaletteAction(
            icon: Icons.terminal_rounded,
            title: context.tr('Mở Local Shell mới'),
            subtitle: context.tr('Desktop PTY cục bộ'),
            badge: context.tr('ACTION'),
            onRun: () =>
                ref.read(sessionManagerProvider.notifier).openLocalShell(),
          ),
          for (var index = 0; index < ws.tabs.length; index++)
            _PaletteAction(
              icon: Icons.tab_rounded,
              title: context.tr('Chuyển phiên: {name}', {
                'name': ws.tabs[index].title,
              }),
              subtitle: ws.tabs[index].terminalCwd,
              badge: ws.tabs[index].closed
                  ? context.tr('CLOSED')
                  : context.tr('SESSION'),
              onRun: () =>
                  ref.read(sessionManagerProvider.notifier).setActiveTab(index),
            ),
          _PaletteAction(
            icon: Icons.cast_connected_rounded,
            title: ws.broadcastMode
                ? context.tr('Tắt Broadcast gõ đồng loạt')
                : context.tr('Bật Broadcast gõ đồng loạt'),
            subtitle: context.tr('Gửi phím tới nhiều terminal đang mở'),
            badge: context.tr('ACTION'),
            onRun: () =>
                ref.read(sessionManagerProvider.notifier).toggleBroadcast(),
          ),
          for (final h in inv.hosts)
            _PaletteAction(
              icon: Icons.dns_rounded,
              title: context.tr('Kết nối: {name}', {'name': h.label}),
              subtitle: '${h.hostname}:${h.port} · ${h.protocol.toUpperCase()}',
              badge: h.envTag.toUpperCase(),
              onRun: () =>
                  ref.read(sessionManagerProvider.notifier).openHostSession(h),
            ),
          for (final s in inv.snippets.where(
            (_) =>
                ws.activeTab?.sessionId != null &&
                !(ws.activeTab?.closed ?? true),
          ))
            _PaletteAction(
              icon: Icons.bolt_rounded,
              title: context.tr('Snippet: {name}', {'name': s.title}),
              subtitle: s.commandTpl,
              badge: context.tr('SNIPPET'),
              onRun: () => sendGuardedCommand(context, ref, s.commandTpl),
            ),
          for (final t in inv.tunnels)
            _PaletteAction(
              icon: Icons.alt_route_rounded,
              title: context.tr(
                ws.tunnelStatuses.any(
                      (status) => status.tunnelId == t.id && status.running,
                    )
                    ? 'Tắt Tunnel: {name}'
                    : 'Bật Tunnel: {name}',
                {'name': t.name},
              ),
              subtitle:
                  '${switch (t.kind) {
                    'local' => context.tr('Local'),
                    'remote' => context.tr('Remote'),
                    'dynamic_socks' => 'SOCKS5',
                    _ => t.kind,
                  }} ${t.bindAddr}:${t.bindPort} → ${t.kind == 'dynamic_socks' ? context.tr('SOCKS5 proxy') : '${t.targetHost ?? ""}:${t.targetPort ?? ""}'}',
              badge: context.tr('TUNNEL'),
              onRun: () =>
                  ws.tunnelStatuses.any(
                    (status) => status.tunnelId == t.id && status.running,
                  )
                  ? ref.read(sessionManagerProvider.notifier).stopTunnel(t.id)
                  : ref.read(sessionManagerProvider.notifier).startTunnel(t.id),
            ),
        ].where((it) {
          if (q.isEmpty) return true;
          return it.title.toLowerCase().contains(q) ||
              it.subtitle.toLowerCase().contains(q) ||
              it.badge.toLowerCase().contains(q);
        }).toList();
    _visibleItems = items;
    _selectedIndex = items.isEmpty
        ? 0
        : _selectedIndex.clamp(0, items.length - 1);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _moveSelection(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _moveSelection(-1),
        const SingleActivator(
          LogicalKeyboardKey.enter,
          includeRepeats: false,
        ): () {
          if (_visibleItems.isNotEmpty) _run(_visibleItems[_selectedIndex]);
        },
      },
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        backgroundColor: tp.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: tp.borderStrong),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 590, maxHeight: 490),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: tp.border)),
                ),
                child: TextField(
                  key: const Key('commandPaletteSearch'),
                  controller: _queryCtrl,
                  focusNode: _queryFocus,
                  autofocus: true,
                  onChanged: (_) => setState(() {
                    _selectedIndex = 0;
                    if (_scrollController.hasClients) {
                      _scrollController.jumpTo(0);
                    }
                  }),
                  onSubmitted: (_) {
                    if (items.isNotEmpty) _run(items[_selectedIndex]);
                  },
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: context.tr(
                      'Tìm Host, Snippet, Tunnel, Hành động (Ctrl+K)...',
                    ),
                    prefixIcon: Icon(Icons.search_rounded, color: tp.accent),
                  ),
                ),
              ),
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            context.tr(
                              'Không tìm thấy kết quả. Thử tên host, lệnh hoặc tunnel khác.',
                            ),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: tp.muted),
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        itemExtent: 76,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        itemCount: items.length,
                        itemBuilder: (ctx, i) {
                          final it = items[i];
                          return ListTile(
                            selected: i == _selectedIndex,
                            selectedTileColor: tp.accentContainer,
                            focusColor: tp.accentContainer,
                            dense: true,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(11),
                            ),
                            leading: Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: tp.accentContainer,
                                borderRadius: BorderRadius.circular(9),
                                border: Border.all(
                                  color: tp.accent.withValues(alpha: 0.25),
                                ),
                              ),
                              child: Icon(it.icon, color: tp.accent, size: 17),
                            ),
                            title: Text(
                              it.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13.5,
                              ),
                            ),
                            subtitle: Text(
                              it.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontFamily: 'monospace',
                                color: tp.muted,
                              ),
                            ),
                            trailing: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: tp.surface2,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: tp.border),
                              ),
                              child: Text(
                                it.badge,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: tp.cyan,
                                ),
                              ),
                            ),
                            onTap: () => _run(it),
                          );
                        },
                      ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: tp.border)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.tr('{count} kết quả / results', {
                          'count': '${items.length}',
                        }),
                        style: TextStyle(color: tp.muted, fontSize: 11),
                      ),
                    ),
                    Text(
                      '↑ ↓  ·  Enter  ·  Esc',
                      style: TextStyle(
                        color: tp.muted,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaletteAction {
  final IconData icon;
  final String title;
  final String subtitle;
  final String badge;
  final FutureOr<void> Function() onRun;
  _PaletteAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.onRun,
  });
}
