import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/features/automation/automation_dialog.dart';
import 'package:termpulse/features/hosts/host_editor_dialog.dart';
import 'package:termpulse/features/hosts/import_dialog.dart';
import 'package:termpulse/features/hosts/quick_connect.dart';
import 'package:termpulse/features/settings/settings_dialog.dart';
import 'package:termpulse/features/sftp/sftp_panel.dart';
import 'package:termpulse/features/terminal/session_log_dialog.dart';
import 'package:termpulse/features/terminal/compose_bar.dart';
import 'package:termpulse/features/terminal/guarded_command.dart';
import 'package:termpulse/features/terminal/serial_connect_dialog.dart';
import 'package:termpulse/features/terminal/terminal_pane.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:termpulse/ui/widgets/brand_logo.dart';
import 'package:termpulse/ui/widgets/ui_kit.dart';
import 'package:xterm/xterm.dart';

class MobileShell extends ConsumerStatefulWidget {
  const MobileShell({super.key});

  @override
  ConsumerState<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends ConsumerState<MobileShell> {
  bool _showSheet = false;
  int _terminalSearchRequest = 0;
  int _sheetTab = 0; // 0: Files (Follow CWD), 1: Snippets, 2: Health & Tunnels
  bool _showHostHome = true;
  String _envFilter = 'all';
  double _mobileFontDelta = 0.0;
  Offset _dragAccum = Offset.zero;
  final _quickCtrl = TextEditingController();
  bool _quickConnecting = false;
  final _busyHosts = <String>{};
  String? _hostActionError;
  String? _remoteDesktopFullscreenKey;

  @override
  void dispose() {
    _quickCtrl.dispose();
    super.dispose();
  }

  void _sendKey(TerminalSessionTab tab, TerminalKey key) {
    ref
        .read(sessionManagerProvider.notifier)
        .setInputModifiers(ctrl: false, alt: false);
    tab.terminal.keyInput(key, ctrl: tab.inputCtrl, alt: tab.inputAlt);
  }

  void _sendChar(TerminalSessionTab tab, String ch) {
    tab.terminal.textInput(ch);
  }

  Future<void> _editHost(HostDto host) async {
    if (!_busyHosts.add(host.id)) return;
    setState(() => _hostActionError = null);
    try {
      await showHostEditorDialog(context, ref, existing: host);
    } finally {
      if (mounted) setState(() => _busyHosts.remove(host.id));
    }
  }

  Future<void> _deleteHost(HostDto host) async {
    if (!_busyHosts.add(host.id)) return;
    setState(() => _hostActionError = null);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const Key('mobileDeleteHostDialog'),
          icon: Icon(Icons.delete_outline_rounded, color: dialogContext.tp.red),
          title: Text(dialogContext.tr('Xoá kết nối?')),
          scrollable: true,
          content: Text(
            dialogContext.tr('Xoá cấu hình đã lưu “{name}”?', {
              'name': host.label,
            }),
          ),
          actions: [
            TextButton(
              key: const Key('mobileDeleteHostCancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(ref.s.cancel),
            ),
            FilledButton.icon(
              key: const Key('mobileDeleteHostConfirm'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogContext).colorScheme.error,
                foregroundColor: Theme.of(dialogContext).colorScheme.onError,
                minimumSize: const Size(64, 48),
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: Text(ref.s.delete),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      await ref.read(inventoryProvider.notifier).removeHost(host.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('Đã xoá kết nối “{name}”.', {'name': host.label}),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _hostActionError = 'Không thể xoá kết nối: $error');
      }
    } finally {
      if (mounted) setState(() => _busyHosts.remove(host.id));
    }
  }

  Future<void> _quickConnect() async {
    final target = _quickCtrl.text.trim();
    if (target.isEmpty || _quickConnecting) return;
    setState(() => _quickConnecting = true);
    try {
      final dispatched = await showQuickConnect(context, ref, target);
      if (!mounted || !dispatched) return;
      _quickCtrl.clear();
      setState(() => _showHostHome = false);
    } finally {
      if (mounted) setState(() => _quickConnecting = false);
    }
  }

  void _cycleMobileFont() {
    setState(() {
      _mobileFontDelta = switch (_mobileFontDelta) {
        <= -1.5 => 0.0,
        < 1.5 => 1.5,
        _ => -2.0,
      };
    });
  }

  void _toggleRemoteDesktopFullscreen(String localKey) {
    setState(() {
      _remoteDesktopFullscreenKey = _remoteDesktopFullscreenKey == localKey
          ? null
          : localKey;
    });
  }

  @override
  Widget build(BuildContext context) {
    final inv = ref.watch(inventoryProvider);
    final ws = ref.watch(sessionManagerProvider);
    final mgr = ref.read(sessionManagerProvider.notifier);
    final settings = ref.watch(settingsProvider);
    final activeTab = ws.activeTab;
    final s = ref.s;
    final tp = context.tp;
    final isDark = tp.brightness == Brightness.dark;

    // Show Flagship Mobile Host Home when no active tab or user tapped Home
    if (_showHostHome || activeTab == null) {
      final activeCount = ws.tabs.where((t) => !t.closed).length;
      final visibleHosts = _envFilter == 'all'
          ? inv.filteredHosts
          : inv.filteredHosts
                .where((h) => h.envTag.toLowerCase() == _envFilter)
                .toList();

      return Scaffold(
        key: const Key('mobileShell'),
        appBar: AppBar(
          backgroundColor: tp.surface,
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: tp.border),
          ),
          title: const FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: TermPulseWordmark(iconSize: 25, fontSize: 16.5),
          ),
          actions: [
            if (ws.tabs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => setState(() => _showHostHome = false),
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 44),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: tp.accentContainer,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: tp.accent.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        StatusDot(color: tp.green, glow: true, size: 6.5),
                        const SizedBox(width: 6),
                        Text(
                          '${ws.tabs.length}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: tp.accent,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            IconButton(
              key: const Key('quickThemeToggleBtn'),
              tooltip: s.settingsThemeLabel,
              icon: Icon(
                settings.themePreset == AppThemePreset.dark
                    ? Icons.light_mode_rounded
                    : Icons.dark_mode_rounded,
                size: 20,
                color: tp.accent,
              ),
              onPressed: () =>
                  ref.read(settingsProvider.notifier).toggleTheme(),
            ),
            IconButton(
              key: const Key('settingsBtn'),
              tooltip: s.settingsTooltip,
              icon: const Icon(Icons.tune_rounded, size: 20),
              onPressed: () => showSettingsDialog(context, ref),
            ),
            PopupMenuButton<String>(
              key: const Key('mobileMoreMenu'),
              tooltip: context.tr('Thao tác khác / More actions'),
              onSelected: (action) async {
                if (action == 'import') {
                  showImportExportDialog(context, ref);
                } else if (action == 'macros') {
                  showAutomationDialog(context, ref);
                } else if (action == 'logs') {
                  showSessionLogsDialog(context, ref);
                } else if (action == 'serial') {
                  final previousKey = ref
                      .read(sessionManagerProvider)
                      .activeTab
                      ?.localKey;
                  await showSerialConnectDialog(context, ref);
                  if (!mounted) return;
                  final next = ref.read(sessionManagerProvider).activeTab;
                  if (next != null &&
                      next.localKey != previousKey &&
                      next.protocol == 'serial') {
                    setState(() => _showHostHome = false);
                  }
                } else {
                  ref.read(vaultProvider.notifier).lock();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  key: const Key('mobileMacroItem'),
                  value: 'macros',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.playlist_play_rounded),
                    title: Text(context.tr('Tự động hóa / Macro')),
                    subtitle: Text(
                      context.tr('Chuỗi lệnh có xác nhận an toàn'),
                    ),
                  ),
                ),
                PopupMenuItem(
                  key: const Key('mobileSessionLogsItem'),
                  value: 'logs',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.receipt_long_rounded),
                    title: Text(context.tr('Nhật ký phiên')),
                    subtitle: Text(context.tr('Xem, tìm kiếm và xuất log')),
                  ),
                ),
                PopupMenuItem(
                  value: 'import',
                  child: Text(s.importExportTooltip),
                ),
                PopupMenuItem(
                  key: const Key('mobileSerialConnectItem'),
                  value: 'serial',
                  enabled: ref.read(backendProvider).serialSupported(),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.cable_rounded),
                    title: Text(context.tr('Kết nối Serial')),
                    subtitle: ref.read(backendProvider).serialSupported()
                        ? Text(context.tr('Cổng thiết bị trên máy này'))
                        : Text(
                            context.tr(
                              'USB Serial không khả dụng trên thiết bị này.',
                            ),
                          ),
                  ),
                ),
                PopupMenuItem(value: 'lock', child: Text(s.lockVaultTooltip)),
              ],
            ),
          ],
        ),
        floatingActionButton: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: LinearGradient(
              colors: [tp.accent, Color.lerp(tp.accent, tp.cyan, 0.25)!],
            ),
            boxShadow: [
              BoxShadow(
                color: tp.accent.withValues(alpha: isDark ? 0.36 : 0.25),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: FloatingActionButton.extended(
            backgroundColor: Colors.transparent,
            elevation: 0,
            highlightElevation: 0,
            foregroundColor: tp.accentInk,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
            ),
            onPressed: () => showHostEditorDialog(context, ref),
            icon: const Icon(Icons.add_rounded, size: 20),
            label: Text(
              s.addHost,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
        body: AmbientBackdrop(
          child: CustomScrollView(
            key: const Key('mobileHostCardsView'),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    if (inv.error != null)
                      InlineNotice(
                        message: inv.error!,
                        onRetry: () =>
                            ref.read(inventoryProvider.notifier).refreshAll(),
                      ),
                    if (_hostActionError != null)
                      InlineNotice(
                        key: const Key('mobileHostActionError'),
                        message: _hostActionError!,
                        onDismiss: () =>
                            setState(() => _hostActionError = null),
                      ),
                    if (ws.lastError != null)
                      InlineNotice(
                        message: ws.lastError!,
                        onDismiss: mgr.clearError,
                      ),
                    // Unified Quick-Connect capsule
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                        decoration: BoxDecoration(
                          color: tp.surface,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: tp.borderStrong),
                          boxShadow: isDark
                              ? null
                              : [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.04),
                                    blurRadius: 10,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                key: const Key('mobileQuickConnectField'),
                                controller: _quickCtrl,
                                enabled: !_quickConnecting,
                                onSubmitted: (_) => _quickConnect(),
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 13,
                                ),
                                decoration: InputDecoration(
                                  hintText: quickConnectHint,
                                  filled: false,
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  prefixIcon: Tooltip(
                                    key: const Key('mobileQuickConnectHelp'),
                                    message: quickConnectSyntaxHelp,
                                    triggerMode: TooltipTriggerMode.tap,
                                    child: Icon(
                                      Icons.help_outline_rounded,
                                      color: tp.accent,
                                      size: 19,
                                    ),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 10,
                                  ),
                                ),
                              ),
                            ),
                            FilledButton(
                              key: const Key('mobileQuickConnectSubmit'),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              onPressed: _quickConnecting
                                  ? null
                                  : _quickConnect,
                              child: Text(s.connect),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Search Bar
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: TextField(
                        onChanged: ref
                            .read(inventoryProvider.notifier)
                            .setSearch,
                        decoration: InputDecoration(
                          hintText: s.searchHostsHint,
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 18,
                          ),
                        ),
                      ),
                    ),
                    // Fleet stats + Env Filter bar
                    SizedBox(
                      height: 52,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        children: [
                          _FilterPill(
                            label: context.tr('Tất cả ({count})', {
                              'count': '${inv.hosts.length}',
                            }),
                            selected: _envFilter == 'all',
                            accentColor: tp.accent,
                            onTap: () => setState(() => _envFilter = 'all'),
                          ),
                          const SizedBox(width: 6),
                          _FilterPill(
                            label: 'PROD',
                            selected: _envFilter == 'prod',
                            accentColor: tp.red,
                            onTap: () => setState(() => _envFilter = 'prod'),
                          ),
                          const SizedBox(width: 6),
                          _FilterPill(
                            label: 'STAGING',
                            selected: _envFilter == 'staging',
                            accentColor: tp.cyan,
                            onTap: () => setState(() => _envFilter = 'staging'),
                          ),
                          const SizedBox(width: 6),
                          _FilterPill(
                            label: 'DEV',
                            selected: _envFilter == 'dev',
                            accentColor: tp.green,
                            onTap: () => setState(() => _envFilter = 'dev'),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 4,
                            ),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: tp.surface.withValues(alpha: 0.8),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: tp.border),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.shield_outlined,
                                  size: 12,
                                  color: tp.cyan,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  context.tr('{count} đang kết nối', {
                                    'count': '$activeCount',
                                  }),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    fontFamily: 'monospace',
                                    color: tp.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 2),
                  ],
                ),
              ),
              if (visibleHosts.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        s.emptyHostsSidebar,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: tp.muted),
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 88),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate((ctx, i) {
                      final h = visibleHosts[i];
                      final openTab = ws.tabs
                          .where((t) => t.hostId == h.id && !t.closed)
                          .firstOrNull;
                      final isConnected = openTab != null;
                      final hostBusy = _busyHosts.contains(h.id);
                      return Container(
                        key: Key('mobileHostCard_${h.id}'),
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: tp.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isConnected
                                ? tp.accent.withValues(alpha: 0.48)
                                : tp.border,
                          ),
                          boxShadow: isDark
                              ? null
                              : [
                                  BoxShadow(
                                    color: Colors.black.withValues(
                                      alpha: 0.045,
                                    ),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: hostBusy
                                ? null
                                : () async {
                                    if (openTab != null) {
                                      final idx = ws.tabs.indexOf(openTab);
                                      mgr.setActiveTab(idx);
                                    } else {
                                      await mgr.openHostSession(h);
                                    }
                                    if (mounted) {
                                      setState(() => _showHostHome = false);
                                    }
                                  },
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      ProtocolAvatar(
                                        envTag: h.envTag,
                                        protocol: h.protocol,
                                        size: 40,
                                        active: isConnected,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    h.label,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      fontSize: 15.5,
                                                      letterSpacing: -0.2,
                                                    ),
                                                  ),
                                                ),
                                                EnvBadge(
                                                  envTag: h.envTag,
                                                  compact: true,
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              '${h.hostname}:${h.port} · ${h.protocol.toUpperCase()}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontFamily: 'monospace',
                                                fontSize: 12,
                                                color: tp.muted,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Icon(
                                        Icons.chevron_right_rounded,
                                        size: 18,
                                        color: tp.muted,
                                      ),
                                    ],
                                  ),
                                  if (openTab?.metrics != null) ...[
                                    const SizedBox(height: 10),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: tp.cyanContainer.withValues(
                                          alpha: 0.65,
                                        ),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: tp.cyan.withValues(
                                            alpha: 0.25,
                                          ),
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          StatusDot(
                                            color: tp.green,
                                            glow: true,
                                            size: 6,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            'CPU ${openTab!.metrics!.cpuPercent.toStringAsFixed(0)}% · RAM ${openTab.metrics!.memUsedMb}/${openTab.metrics!.memTotalMb} MB',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontFamily: 'monospace',
                                              fontWeight: FontWeight.w700,
                                              color: tp.cyan,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 10),
                                  Divider(height: 1, color: tp.border),
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    children: [
                                      TextButton.icon(
                                        key: Key('mobileEditHost_${h.id}'),
                                        style: TextButton.styleFrom(
                                          minimumSize: const Size(80, 48),
                                        ),
                                        onPressed: hostBusy
                                            ? null
                                            : () => _editHost(h),
                                        icon: const Icon(
                                          Icons.edit_outlined,
                                          size: 18,
                                        ),
                                        label: Text(s.edit),
                                      ),
                                      TextButton.icon(
                                        key: Key('mobileDeleteHost_${h.id}'),
                                        style: TextButton.styleFrom(
                                          foregroundColor: tp.red,
                                          minimumSize: const Size(80, 48),
                                        ),
                                        onPressed: hostBusy
                                            ? null
                                            : () => _deleteHost(h),
                                        icon: const Icon(
                                          Icons.delete_outline_rounded,
                                          size: 18,
                                        ),
                                        label: Text(s.delete),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }, childCount: visibleHosts.length),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    // Active Flagship Full-Bleed Mobile Terminal Workspace
    final effectiveFont = (settings.terminalFontSize - 0.5 + _mobileFontDelta)
        .clamp(11.0, 20.0);
    final isProd = activeTab.envTag.toLowerCase() == 'prod';
    final remoteDesktopFullscreen =
        activeTab.isRemoteDesktop &&
        _remoteDesktopFullscreenKey == activeTab.localKey;
    final terminal = TerminalPane(
      key: ValueKey(activeTab.localKey),
      tab: activeTab,
      isActive: true,
      showBroadcastBadge: false,
      chromeless: true,
      fontSizeOverride: effectiveFont,
      searchRequest: _terminalSearchRequest,
      remoteDesktopFullscreen: remoteDesktopFullscreen,
      onToggleRemoteDesktopFullscreen: activeTab.isRemoteDesktop
          ? () => _toggleRemoteDesktopFullscreen(activeTab.localKey)
          : null,
      onFocus: () {},
    );

    return Scaffold(
      key: const Key('mobileShell'),
      backgroundColor: tp.terminalTheme.background,
      appBar: remoteDesktopFullscreen
          ? null
          : AppBar(
              key: const Key('mobileWorkspaceAppBar'),
              toolbarHeight: 52,
              backgroundColor: tp.surface,
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(1),
                child: Container(height: 1, color: tp.border),
              ),
              leading: IconButton(
                tooltip: s.hostBtnLabel,
                icon: const Icon(Icons.arrow_back_rounded, size: 21),
                onPressed: () => setState(() => _showHostHome = true),
              ),
              titleSpacing: 0,
              title: Row(
                children: [
                  StatusDot(
                    color: activeTab.closed
                        ? tp.red
                        : (activeTab.sessionId == null ? tp.amber : tp.green),
                    glow: !activeTab.closed && activeTab.sessionId != null,
                    size: 8,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                activeTab.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            if (isProd) ...[
                              const SizedBox(width: 6),
                              const EnvBadge(envTag: 'prod', compact: true),
                            ],
                          ],
                        ),
                        Text(
                          activeTab.isRemoteDesktop
                              ? activeTab.protocol.toUpperCase()
                              : activeTab.terminalCwd,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: tp.cyan,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                if (!activeTab.isRemoteDesktop) ...[
                  IconButton(
                    key: const Key('mobileTerminalFindBtn'),
                    tooltip: context.tr('Tìm trong terminal / Find'),
                    icon: const Icon(Icons.search_rounded, size: 20),
                    onPressed: () => setState(() => _terminalSearchRequest++),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    tooltip: context.tr('Cỡ chữ ({size}px)', {
                      'size': effectiveFont.toStringAsFixed(0),
                    }),
                    icon: Text(
                      'A±',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: tp.muted,
                      ),
                    ),
                    onPressed: _cycleMobileFont,
                  ),
                  IconButton(
                    key: const Key('mobileBottomSheetBtn'),
                    tooltip: context.tr('Files · Snippets · Health'),
                    icon: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: _showSheet ? tp.accent : tp.accentContainer,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                          color: _showSheet
                              ? tp.accent
                              : tp.accent.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Icon(
                        _showSheet
                            ? Icons.keyboard_arrow_down_rounded
                            : Icons.layers_rounded,
                        size: 17,
                        color: _showSheet ? tp.accentInk : tp.accent,
                      ),
                    ),
                    onPressed: () => setState(() => _showSheet = !_showSheet),
                  ),
                ],
                IconButton(
                  tooltip: s.close,
                  icon: Icon(Icons.close_rounded, size: 20, color: tp.red),
                  onPressed: () async {
                    await mgr.closeTab(activeTab.localKey);
                    if (!mounted) return;
                    if (ref.read(sessionManagerProvider).tabs.isEmpty) {
                      setState(() => _showHostHome = true);
                    }
                  },
                ),
              ],
            ),
      body: PopScope(
        canPop: !remoteDesktopFullscreen,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && remoteDesktopFullscreen && mounted) {
            setState(() => _remoteDesktopFullscreenKey = null);
          }
        },
        child: SafeArea(
          top: remoteDesktopFullscreen,
          child: Column(
            children: [
              // Session switcher strip if > 1 tab
              if (ws.tabs.length > 1 && !remoteDesktopFullscreen)
                Container(
                  key: const Key('mobileSessionTabsStrip'),
                  height: 52,
                  decoration: BoxDecoration(
                    color: tp.surface,
                    border: Border(bottom: BorderSide(color: tp.border)),
                  ),
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: ws.tabs.length,
                    itemBuilder: (_, i) {
                      final t = ws.tabs[i];
                      final sel = i == ws.activeIndex;
                      return Padding(
                        padding: const EdgeInsets.only(
                          left: 6,
                          top: 2,
                          bottom: 2,
                        ),
                        child: ChoiceChip(
                          key: Key('mobileSessionTab_${t.localKey}'),
                          label: Text(
                            t.title,
                            style: const TextStyle(fontSize: 11),
                          ),
                          selected: sel,
                          onSelected: (_) => mgr.setActiveTab(i),
                        ),
                      );
                    },
                  ),
                )
              else
                const SizedBox.shrink(),

              // Keep resizing local to the split; the terminal and tool contents
              // remain stable children while the user drags the handle.
              Expanded(
                child: _MobileTerminalNotice(
                  message: ws.lastError,
                  onDismiss: mgr.clearError,
                  child: activeTab.isRemoteDesktop
                      ? terminal
                      : _MobileToolsWorkspace(
                          terminal: terminal,
                          showTools: _showSheet && !activeTab.isRemoteDesktop,
                          selectedTab: _sheetTab,
                          onTabSelected: (value) =>
                              setState(() => _sheetTab = value),
                          minimumContentHeight: switch (_sheetTab) {
                            0 =>
                              224 +
                                  (activeTab.sftpUnavailableReason != null
                                      ? 112
                                      : 0) +
                                  (activeTab.sftpError != null ? 80 : 0),
                            1 => 176,
                            _ => 96,
                          },
                          content: switch (_sheetTab) {
                            0 => SftpPanel(tab: activeTab, compact: true),
                            1 => Column(
                              children: [
                                Expanded(
                                  child: ListView.builder(
                                    key: const Key('mobileSnippetList'),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    itemCount: inv.snippets.length,
                                    itemBuilder: (_, i) {
                                      final sn = inv.snippets[i];
                                      return ListTile(
                                        dense: true,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        leading: Container(
                                          width: 30,
                                          height: 30,
                                          decoration: BoxDecoration(
                                            color: tp.accentContainer,
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: Icon(
                                            Icons.bolt_rounded,
                                            size: 16,
                                            color: tp.accent,
                                          ),
                                        ),
                                        title: Text(
                                          sn.title,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 13,
                                          ),
                                        ),
                                        subtitle: Text(
                                          sn.commandTpl,
                                          style: TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 11.5,
                                            color: tp.muted,
                                          ),
                                        ),
                                        onTap:
                                            activeTab.closed ||
                                                activeTab.sessionId == null
                                            ? null
                                            : () async {
                                                final sent =
                                                    await sendGuardedCommand(
                                                      context,
                                                      ref,
                                                      sn.commandTpl,
                                                    );
                                                if (mounted && sent) {
                                                  setState(
                                                    () => _showSheet = false,
                                                  );
                                                }
                                              },
                                      );
                                    },
                                  ),
                                ),
                                const ComposeBar(),
                              ],
                            ),
                            _ => _MobileHealthTunnels(tab: activeTab),
                          },
                        ),
                ),
              ),

              // Hardware-Grade Keycap Accessory Bar + Space-drag Arrow Trackpad
              if (!activeTab.isRemoteDesktop)
                Container(
                  key: const Key('mobileAccessoryBar'),
                  height: 48,
                  decoration: BoxDecoration(
                    color: tp.surface,
                    border: Border(top: BorderSide(color: tp.borderStrong)),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      _AccBtn(
                        label: 'Esc',
                        onTap: () => _sendKey(activeTab, TerminalKey.escape),
                      ),
                      _AccBtn(
                        label: 'Tab',
                        onTap: () => _sendKey(activeTab, TerminalKey.tab),
                      ),
                      _AccBtn(
                        key: const Key('stickyCtrlBtn'),
                        label: 'Ctrl',
                        active: activeTab.inputCtrl,
                        onTap: () => mgr.setInputModifiers(
                          ctrl: !activeTab.inputCtrl,
                          alt: activeTab.inputAlt,
                        ),
                      ),
                      _AccBtn(
                        key: const Key('stickyAltBtn'),
                        label: 'Alt',
                        active: activeTab.inputAlt,
                        onTap: () => mgr.setInputModifiers(
                          ctrl: activeTab.inputCtrl,
                          alt: !activeTab.inputAlt,
                        ),
                      ),
                      GestureDetector(
                        key: const Key('mobileSpaceTrackpad'),
                        onPanUpdate: (d) {
                          _dragAccum += d.delta;
                          if (_dragAccum.dx.abs() > 18) {
                            _sendKey(
                              activeTab,
                              _dragAccum.dx > 0
                                  ? TerminalKey.arrowRight
                                  : TerminalKey.arrowLeft,
                            );
                            _dragAccum = Offset.zero;
                          } else if (_dragAccum.dy.abs() > 18) {
                            _sendKey(
                              activeTab,
                              _dragAccum.dy > 0
                                  ? TerminalKey.arrowDown
                                  : TerminalKey.arrowUp,
                            );
                            _dragAccum = Offset.zero;
                          }
                        },
                        onTap: () => _sendChar(activeTab, ' '),
                        child: Container(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 3,
                            vertical: 6,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: tp.surface2,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: tp.accent.withValues(alpha: 0.45),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.chevron_left_rounded,
                                size: 14,
                                color: tp.cyan,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                'Space',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: tp.accent,
                                ),
                              ),
                              const SizedBox(width: 2),
                              Icon(
                                Icons.chevron_right_rounded,
                                size: 14,
                                color: tp.cyan,
                              ),
                            ],
                          ),
                        ),
                      ),
                      _AccBtn(
                        label: '↑',
                        onTap: () => _sendKey(activeTab, TerminalKey.arrowUp),
                      ),
                      _AccBtn(
                        label: '↓',
                        onTap: () => _sendKey(activeTab, TerminalKey.arrowDown),
                      ),
                      _AccBtn(
                        label: '←',
                        onTap: () => _sendKey(activeTab, TerminalKey.arrowLeft),
                      ),
                      _AccBtn(
                        label: '→',
                        onTap: () =>
                            _sendKey(activeTab, TerminalKey.arrowRight),
                      ),
                      _AccBtn(
                        label: 'Enter',
                        onTap: () => _sendKey(activeTab, TerminalKey.enter),
                      ),
                      _AccBtn(
                        label: '/',
                        onTap: () => _sendChar(activeTab, '/'),
                      ),
                      _AccBtn(
                        label: '|',
                        onTap: () => _sendChar(activeTab, '|'),
                      ),
                      _AccBtn(
                        label: '~',
                        onTap: () => _sendChar(activeTab, '~'),
                      ),
                      _AccBtn(
                        label: '-',
                        onTap: () => _sendChar(activeTab, '-'),
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

class _MobileTerminalNotice extends StatelessWidget {
  const _MobileTerminalNotice({
    required this.message,
    required this.onDismiss,
    required this.child,
  });

  final String? message;
  final VoidCallback onDismiss;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Column(
      children: [
        if (message != null)
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * .4),
            child: SingleChildScrollView(
              key: const Key('mobileTerminalNoticeScroll'),
              child: InlineNotice(message: message!, onDismiss: onDismiss),
            ),
          )
        else
          const SizedBox.shrink(),
        Expanded(child: child),
      ],
    ),
  );
}

class _MobileToolsWorkspace extends StatefulWidget {
  const _MobileToolsWorkspace({
    required this.terminal,
    required this.content,
    required this.showTools,
    required this.selectedTab,
    required this.onTabSelected,
    required this.minimumContentHeight,
  });

  final Widget terminal;
  final Widget content;
  final bool showTools;
  final int selectedTab;
  final ValueChanged<int> onTabSelected;
  final double minimumContentHeight;

  @override
  State<_MobileToolsWorkspace> createState() => _MobileToolsWorkspaceState();
}

class _MobileToolsWorkspaceState extends State<_MobileToolsWorkspace> {
  static const _handleHeight = 44.0;
  static const _tabsHeight = 48.0;
  final _contentScroll = ScrollController();
  double _preferredHeight = 344;
  double _dragHeight = 344;
  double _dragRestoreHeight = 344;
  bool _collapsed = false;
  bool _maximized = false;
  int _contentResetGeneration = 0;

  @override
  void didUpdateWidget(covariant _MobileToolsWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedTab == widget.selectedTab) return;
    final generation = ++_contentResetGeneration;
    // Changing tabs rebuilds this workspace during layout. Scroll notifications
    // must wait until that frame completes so AppBar can update safely.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _contentResetGeneration ||
          !_contentScroll.hasClients) {
        return;
      }
      final position = _contentScroll.position;
      if (position.hasContentDimensions &&
          position.pixels != position.minScrollExtent) {
        _contentScroll.jumpTo(position.minScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _contentScroll.dispose();
    super.dispose();
  }

  void _toggleCollapsed() => setState(() => _collapsed = !_collapsed);

  void _toggleMaximized() => setState(() {
    _maximized = !_maximized;
    _collapsed = false;
  });

  void _resize(double height, double maximum) => setState(() {
    _maximized = false;
    _collapsed = false;
    _preferredHeight = height.clamp(maximum.clamp(0.0, _handleHeight), maximum);
  });

  bool _forwardOverflow(OverscrollNotification notification) {
    // Files and snippets keep their own bounded lists. When those reach an
    // edge, let the cramped-screen viewport reveal the remaining controls.
    if (notification.depth == 0 ||
        notification.metrics.axis != Axis.vertical ||
        !_contentScroll.hasClients) {
      return false;
    }
    final position = _contentScroll.position;
    final next = (position.pixels + notification.overscroll).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next == position.pixels) return false;
    _contentScroll.jumpTo(next);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final tp = context.tp;
    final collapseLabel = context.tr('Thu gọn bảng công cụ');
    final expandLabel = context.tr('Mở bảng công cụ');
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxHeight;
        final terminalMinimum = (available * .18).clamp(0.0, 72.0);
        final maximum = (available - terminalMinimum).clamp(0.0, available);
        final handleHeight = maximum.clamp(0.0, _handleHeight);
        final panelHeight = _collapsed
            ? handleHeight
            : (_maximized ? maximum : _preferredHeight).clamp(
                handleHeight,
                maximum,
              );
        final bodyHeight = (panelHeight - handleHeight).clamp(0.0, maximum);
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final contentHeight = (widget.minimumContentHeight * scale.clamp(1, 2))
            .toDouble();

        return Column(
          children: [
            Expanded(child: widget.terminal),
            ExcludeFocus(
              excluding: !widget.showTools,
              child: Offstage(
                offstage: !widget.showTools,
                child: SizedBox(
                  key: const Key('mobileBottomSheet'),
                  height: panelHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: tp.surface,
                      border: Border(top: BorderSide(color: tp.borderStrong)),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(14),
                      ),
                    ),
                    child: Column(
                      children: [
                        Semantics(
                          label: context.tr('Files · Snippets · Health'),
                          value: '${panelHeight.round()} px',
                          increasedValue:
                              '${(panelHeight + 48).clamp(handleHeight, maximum).round()} px',
                          decreasedValue:
                              '${(panelHeight - 48).clamp(handleHeight, maximum).round()} px',
                          onIncrease: () => _resize(panelHeight + 48, maximum),
                          onDecrease: () {
                            if (panelHeight <= _handleHeight + 48) {
                              setState(() => _collapsed = true);
                            } else {
                              _resize(panelHeight - 48, maximum);
                            }
                          },
                          child: GestureDetector(
                            key: const Key('mobileSheetResizeHandle'),
                            behavior: HitTestBehavior.opaque,
                            onTap: _toggleCollapsed,
                            onVerticalDragStart: (_) {
                              _dragHeight = panelHeight;
                              if (!_collapsed) _dragRestoreHeight = panelHeight;
                            },
                            onVerticalDragUpdate: (details) {
                              _dragHeight = (_dragHeight - details.delta.dy)
                                  .clamp(handleHeight, maximum);
                              _resize(_dragHeight, maximum);
                            },
                            onVerticalDragEnd: (_) {
                              if (_preferredHeight < _handleHeight + 28) {
                                setState(() {
                                  _collapsed = true;
                                  _preferredHeight = _dragRestoreHeight;
                                });
                              }
                            },
                            child: SizedBox(
                              height: handleHeight,
                              child: ClipRect(
                                child: Row(
                                  children: [
                                    const SizedBox(width: 12),
                                    Icon(
                                      Icons.drag_handle_rounded,
                                      color: tp.muted,
                                      size: 24,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        context.tr('Files · Snippets · Health'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: tp.muted,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      key: const Key('mobileSheetExpandBtn'),
                                      tooltip: _maximized
                                          ? collapseLabel
                                          : expandLabel,
                                      onPressed: _toggleMaximized,
                                      icon: Icon(
                                        _maximized
                                            ? Icons.fullscreen_exit_rounded
                                            : Icons.fullscreen_rounded,
                                        size: 20,
                                      ),
                                    ),
                                    IconButton(
                                      key: const Key('mobileSheetCollapseBtn'),
                                      tooltip: _collapsed
                                          ? expandLabel
                                          : collapseLabel,
                                      onPressed: _toggleCollapsed,
                                      icon: Icon(
                                        _collapsed
                                            ? Icons.keyboard_arrow_up_rounded
                                            : Icons.keyboard_arrow_down_rounded,
                                        size: 22,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: ExcludeFocus(
                            excluding: _collapsed,
                            child: Offstage(
                              offstage: _collapsed,
                              child: SizedBox(
                                key: const Key('mobileSheetContentViewport'),
                                child: ClipRect(
                                  child: NotificationListener<OverscrollNotification>(
                                    onNotification: _forwardOverflow,
                                    child: SingleChildScrollView(
                                      key: const Key(
                                        'mobileSheetContentScroll',
                                      ),
                                      controller: _contentScroll,
                                      child: SizedBox(
                                        height: bodyHeight.clamp(
                                          _tabsHeight + contentHeight,
                                          double.infinity,
                                        ),
                                        child: Column(
                                          children: [
                                            SizedBox(
                                              height: _tabsHeight,
                                              child: Padding(
                                                padding: const EdgeInsets.all(
                                                  6,
                                                ),
                                                child: Row(
                                                  children: [
                                                    _SheetTab(
                                                      key: const Key(
                                                        'mobileSheetTabFiles',
                                                      ),
                                                      label: context.tr(
                                                        'Files (CWD)',
                                                      ),
                                                      selected:
                                                          widget.selectedTab ==
                                                          0,
                                                      onTap: () => widget
                                                          .onTabSelected(0),
                                                    ),
                                                    _SheetTab(
                                                      key: const Key(
                                                        'mobileSheetTabSnippets',
                                                      ),
                                                      label: context.tr(
                                                        'Snippets',
                                                      ),
                                                      selected:
                                                          widget.selectedTab ==
                                                          1,
                                                      onTap: () => widget
                                                          .onTabSelected(1),
                                                    ),
                                                    _SheetTab(
                                                      key: const Key(
                                                        'mobileSheetTabHealth',
                                                      ),
                                                      label: context.tr(
                                                        'Health & Tunnels',
                                                      ),
                                                      selected:
                                                          widget.selectedTab ==
                                                          2,
                                                      onTap: () => widget
                                                          .onTabSelected(2),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            Expanded(child: widget.content),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FilterPill extends StatelessWidget {
  final String label;
  final bool selected;
  final Color accentColor;
  final VoidCallback onTap;

  const _FilterPill({
    required this.label,
    required this.selected,
    required this.accentColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tp = context.tp;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? accentColor.withValues(alpha: 0.16)
              : tp.surface.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? accentColor.withValues(alpha: 0.55) : tp.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: selected ? accentColor : tp.muted,
          ),
        ),
      ),
    );
  }
}

class _AccBtn extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _AccBtn({
    super.key,
    required this.label,
    this.active = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tp = context.tp;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 11),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? tp.accent : tp.surface2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: active ? tp.accent : tp.borderStrong),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: tp.accent.withValues(alpha: 0.4),
                    blurRadius: 8,
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            fontFamily: 'monospace',
            color: active ? tp.accentInk : tp.ink,
          ),
        ),
      ),
    );
  }
}

class _SheetTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SheetTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tp = context.tp;
    return Expanded(
      child: Tooltip(
        message: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 7),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? tp.surface2 : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: selected ? Border.all(color: tp.borderStrong) : null,
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected ? tp.ink : tp.muted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileHealthTunnels extends ConsumerWidget {
  final TerminalSessionTab tab;
  const _MobileHealthTunnels({required this.tab});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inv = ref.watch(inventoryProvider);
    final ws = ref.watch(sessionManagerProvider);
    final mgr = ref.read(sessionManagerProvider.notifier);
    final m = tab.metrics;
    final canMeasure =
        tab.protocol == 'ssh' && tab.sessionId != null && !tab.closed;
    final s = ref.s;
    final tp = context.tp;

    return SingleChildScrollView(
      key: const Key('mobileHealthScroll'),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  s.healthTabTitle,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                key: const Key('mobileMeasureHealthBtn'),
                style: FilledButton.styleFrom(
                  backgroundColor: tp.accentContainer,
                  foregroundColor: tp.accent,
                ),
                onPressed: canMeasure
                    ? () => mgr.refreshMetrics(tab.localKey)
                    : null,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: Text(s.measureNowBtn),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!canMeasure)
            Text(
              context.tr(
                tab.protocol != 'ssh'
                    ? 'Giám sát /proc chỉ hỗ trợ phiên SSH Linux. Telnet và Local Shell không hỗ trợ.'
                    : tab.closed
                    ? 'Phiên SSH đã đóng. Kết nối lại SSH Linux để đo CPU, RAM và Disk.'
                    : 'Đang chờ kết nối SSH Linux để đo CPU, RAM và Disk.',
              ),
              key: const Key('mobileHealthUnavailable'),
              style: TextStyle(fontSize: 12.5, color: tp.muted),
            )
          else if (m == null)
            Text(
              context.tr('SSH /proc · CPU, RAM & Disk'),
              style: TextStyle(fontSize: 12.5, color: tp.muted),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                MetricGaugeCard(
                  label: 'CPU',
                  value: '${m.cpuPercent.toStringAsFixed(1)}%',
                  ratio: m.cpuPercent / 100.0,
                  icon: Icons.memory_rounded,
                ),
                MetricGaugeCard(
                  label: 'RAM',
                  value: '${m.memUsedMb}/${m.memTotalMb} MB',
                  ratio: m.memTotalMb > BigInt.zero
                      ? m.memUsedMb.toDouble() / m.memTotalMb.toDouble()
                      : 0,
                  icon: Icons.developer_board_rounded,
                ),
                MetricGaugeCard(
                  label: 'DISK',
                  value:
                      '${m.diskUsedGb.toStringAsFixed(1)}/${m.diskTotalGb.toStringAsFixed(1)} GB',
                  ratio: m.diskTotalGb > 0 ? m.diskUsedGb / m.diskTotalGb : 0,
                  icon: Icons.storage_rounded,
                ),
              ],
            ),
          const SizedBox(height: 14),
          Text(
            context.tr('Tunnels (-L / -R / -D)'),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          if (inv.tunnels.isEmpty)
            Text('—', style: TextStyle(fontSize: 12.5, color: tp.muted)),
          for (final t in inv.tunnels)
            Builder(
              builder: (_) {
                final running = ws.tunnelStatuses.any(
                  (st) => st.tunnelId == t.id && st.running,
                );
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: tp.surface2,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: running
                          ? tp.green.withValues(alpha: 0.45)
                          : tp.border,
                    ),
                  ),
                  child: Row(
                    children: [
                      StatusDot(
                        color: running ? tp.green : tp.muted,
                        glow: running,
                        size: 9,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              '${t.bindAddr}:${t.bindPort} (${t.kind})',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                                color: tp.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: running,
                        onChanged: (on) =>
                            on ? mgr.startTunnel(t.id) : mgr.stopTunnel(t.id),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
