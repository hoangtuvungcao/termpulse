import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/features/remote_desktop/remote_desktop_session.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/hosts/connection_library.dart';
import 'package:termpulse/features/hosts/host_editor_dialog.dart';
import 'package:termpulse/features/hosts/import_dialog.dart';
import 'package:termpulse/features/hosts/quick_connect.dart';
import 'package:termpulse/features/ops/bottom_dock.dart';
import 'package:termpulse/features/settings/settings_dialog.dart';
import 'package:termpulse/features/sftp/sftp_panel.dart';
import 'package:termpulse/features/terminal/command_palette.dart';
import 'package:termpulse/features/terminal/compose_bar.dart';
import 'package:termpulse/features/terminal/guarded_command.dart';
import 'package:termpulse/features/terminal/terminal_pane.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:termpulse/ui/widgets/brand_logo.dart';
import 'package:termpulse/ui/widgets/ui_kit.dart';

class DesktopShell extends ConsumerStatefulWidget {
  final VoidCallback? onOpenTools;
  const DesktopShell({super.key, this.onOpenTools});

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  final _quickCtrl = TextEditingController();
  bool _quickConnecting = false;
  bool _sidebarOpen = true;
  bool _showCompose = true;
  bool _sftpCommanderMode = false;
  double _sidebarWidth = 244;
  double _sftpWidth = 320;
  bool _resizingSidebar = false;
  bool _resizingSftp = false;

  @override
  void dispose() {
    _quickCtrl.dispose();
    super.dispose();
  }

  Future<void> _quickConnect() async {
    final target = _quickCtrl.text.trim();
    if (target.isEmpty || _quickConnecting) return;
    setState(() => _quickConnecting = true);
    try {
      final dispatched = await showQuickConnect(context, ref, target);
      if (mounted && dispatched) _quickCtrl.clear();
    } finally {
      if (mounted) setState(() => _quickConnecting = false);
    }
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
    final compact = MediaQuery.sizeOf(context).width < 1180;
    final workspaceWidth = MediaQuery.sizeOf(context).width;
    final hasSftp =
        ws.showSftpPanel && activeTab != null && !activeTab.isRemoteDesktop;
    // Keep a readable terminal when opening both panels in a narrow window.
    final maxSidebarWidth = (workspaceWidth - (hasSftp ? 240.0 : 0.0) - 360.0)
        .clamp(220.0, 360.0);
    final sidebarWidth = _sidebarOpen
        ? _sidebarWidth.clamp(220.0, maxSidebarWidth)
        : 0.0;
    final maxSftpWidth = (workspaceWidth - sidebarWidth - 360.0).clamp(
      240.0,
      compact ? 280.0 : (_sftpCommanderMode ? 560.0 : 440.0),
    );
    final sftpWidth = (_sftpCommanderMode && !compact ? 560.0 : _sftpWidth)
        .clamp(240.0, maxSftpWidth);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            showCommandPaletteDialog(context, ref),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            showCommandPaletteDialog(context, ref),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const Key('desktopShell'),
          body: Column(
            children: [
              Container(
                height: 56,
                padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 10),
                decoration: BoxDecoration(
                  color: tp.surface,
                  border: Border(bottom: BorderSide(color: tp.border)),
                ),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: s.toggleSidebarTooltip,
                      icon: Icon(
                        _sidebarOpen
                            ? Icons.menu_open_rounded
                            : Icons.menu_rounded,
                        size: 19,
                      ),
                      onPressed: () =>
                          setState(() => _sidebarOpen = !_sidebarOpen),
                    ),
                    const SizedBox(width: 2),
                    if (compact)
                      const TermPulseLogo(size: 26, showGlow: false)
                    else
                      const TermPulseWordmark(iconSize: 26, fontSize: 15),
                    const SizedBox(width: 12),
                    // Quick-Connect Capsule
                    Container(
                      width: compact ? 144 : 190,
                      height: 38,
                      decoration: BoxDecoration(
                        color: tp.surface2,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: tp.border),
                      ),
                      child: TextField(
                        key: const Key('desktopQuickConnectField'),
                        controller: _quickCtrl,
                        enabled: !_quickConnecting,
                        onSubmitted: (_) => _quickConnect(),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                        decoration: InputDecoration(
                          hintText: quickConnectHint,
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          suffixIcon: IconButton(
                            key: const Key('desktopQuickConnectSubmit'),
                            tooltip: '${s.connect}\n$quickConnectSyntaxHelp',
                            padding: EdgeInsets.zero,
                            icon: Icon(
                              Icons.bolt_rounded,
                              size: 16,
                              color: tp.accent,
                            ),
                            onPressed: _quickConnecting ? null : _quickConnect,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Command Palette Raycast Pill
                    InkWell(
                      key: const Key('desktopCommandPaletteBtn'),
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => showCommandPaletteDialog(context, ref),
                      child: Container(
                        height: 38,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: tp.surface2,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: tp.border),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.search_rounded,
                              size: 14,
                              color: tp.accent,
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: tp.surface3,
                                borderRadius: BorderRadius.circular(5),
                                border: Border.all(color: tp.border),
                              ),
                              child: Text(
                                'Ctrl+K',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  fontFamily: 'monospace',
                                  color: tp.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    PopupMenuButton<String>(
                      key: const Key('desktopWorkspaceMenu'),
                      tooltip: context.tr('Workspace / Công cụ'),
                      icon: Icon(
                        Icons.apps_rounded,
                        size: 20,
                        color: tp.accent,
                      ),
                      onSelected: (action) {
                        switch (action) {
                          case 'tools':
                            widget.onOpenTools?.call();
                          case 'palette':
                            showCommandPaletteDialog(context, ref);
                          case 'local':
                            mgr.openLocalShell();
                          case 'host':
                            showHostEditorDialog(context, ref);
                          case 'import':
                            showImportExportDialog(context, ref);
                          case 'compose':
                            setState(() => _showCompose = !_showCompose);
                        }
                      },
                      itemBuilder: (_) => [
                        if (widget.onOpenTools != null)
                          PopupMenuItem(
                            value: 'tools',
                            child: Text(context.tr('Tự động hóa / Macro…')),
                          ),
                        PopupMenuItem(
                          value: 'palette',
                          child: Text(context.tr('Tìm lệnh / Command Palette')),
                        ),
                        PopupMenuItem(
                          value: 'local',
                          child: Text(s.openLocalShell),
                        ),
                        PopupMenuItem(value: 'host', child: Text(s.addHost)),
                        PopupMenuItem(
                          value: 'import',
                          child: Text(s.importExportTooltip),
                        ),
                        CheckedPopupMenuItem(
                          value: 'compose',
                          checked: _showCompose,
                          child: Text(context.tr('Thanh soạn lệnh')),
                        ),
                      ],
                    ),
                    // Recessed Split Control Track
                    if (compact)
                      PopupMenuButton<SplitMode>(
                        tooltip: context.tr('Chia terminal'),
                        initialValue: ws.splitMode,
                        onSelected: mgr.setSplitMode,
                        icon: Icon(
                          Icons.splitscreen_rounded,
                          color: tp.accent,
                          size: 20,
                        ),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: SplitMode.single,
                            child: Text(context.tr('1x1 · Một terminal')),
                          ),
                          PopupMenuItem(
                            value: SplitMode.horizontal,
                            child: Text(context.tr('1x2 · Chia ngang')),
                          ),
                          PopupMenuItem(
                            value: SplitMode.vertical,
                            child: Text(context.tr('2x1 · Chia dọc')),
                          ),
                          PopupMenuItem(
                            value: SplitMode.quad,
                            child: Text(context.tr('2x2 · Bốn terminal')),
                          ),
                        ],
                      )
                    else
                      Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: tp.bg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: tp.border),
                        ),
                        child: SegmentedButton<SplitMode>(
                          showSelectedIcon: false,
                          style: ButtonStyle(
                            side: const WidgetStatePropertyAll(BorderSide.none),
                            shape: WidgetStatePropertyAll(
                              RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(7),
                              ),
                            ),
                            backgroundColor: WidgetStateProperty.resolveWith(
                              (st) => st.contains(WidgetState.selected)
                                  ? tp.surface2
                                  : Colors.transparent,
                            ),
                            foregroundColor: WidgetStateProperty.resolveWith(
                              (st) => st.contains(WidgetState.selected)
                                  ? tp.accent
                                  : tp.muted,
                            ),
                            textStyle: const WidgetStatePropertyAll(
                              TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                                fontFamily: 'monospace',
                              ),
                            ),
                            padding: const WidgetStatePropertyAll(
                              EdgeInsets.symmetric(horizontal: 9),
                            ),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                          ),
                          segments: const [
                            ButtonSegment(
                              value: SplitMode.single,
                              label: Text('1x1'),
                            ),
                            ButtonSegment(
                              value: SplitMode.horizontal,
                              label: Text('1x2'),
                            ),
                            ButtonSegment(
                              value: SplitMode.vertical,
                              label: Text('2x1'),
                            ),
                            ButtonSegment(
                              value: SplitMode.quad,
                              label: Text('2x2'),
                            ),
                          ],
                          selected: {ws.splitMode},
                          onSelectionChanged: (sel) =>
                              mgr.setSplitMode(sel.first),
                        ),
                      ),
                    const SizedBox(width: 8),
                    FilterChip(
                      key: const Key('desktopBroadcastChip'),
                      showCheckmark: false,
                      selectedColor: ws.broadcastIncludesProd
                          ? tp.red.withValues(alpha: 0.18)
                          : tp.amber.withValues(alpha: 0.16),
                      side: BorderSide(
                        color: ws.broadcastMode
                            ? (ws.broadcastIncludesProd ? tp.red : tp.amber)
                            : tp.borderStrong,
                      ),
                      label: Text(
                        s.broadcastChip,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: ws.broadcastMode
                              ? (ws.broadcastIncludesProd ? tp.red : tp.amber)
                              : tp.ink,
                        ),
                      ),
                      avatar: Icon(
                        Icons.cast_connected_rounded,
                        size: 15,
                        color: ws.broadcastMode
                            ? (ws.broadcastIncludesProd ? tp.red : tp.amber)
                            : tp.muted,
                      ),
                      selected: ws.broadcastMode,
                      onSelected: (_) => mgr.toggleBroadcast(),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: s.overviewTooltip,
                      style: IconButton.styleFrom(
                        backgroundColor: ws.showOverview
                            ? tp.accentContainer
                            : Colors.transparent,
                      ),
                      icon: Icon(
                        Icons.grid_view_rounded,
                        size: 18,
                        color: ws.showOverview ? tp.accent : tp.muted,
                      ),
                      onPressed: mgr.toggleOverview,
                    ),
                    IconButton(
                      tooltip: s.toggleSftpTooltip,
                      style: IconButton.styleFrom(
                        backgroundColor: ws.showSftpPanel
                            ? tp.accentContainer
                            : Colors.transparent,
                      ),
                      icon: Icon(
                        Icons.folder_copy_rounded,
                        size: 18,
                        color: ws.showSftpPanel ? tp.accent : tp.muted,
                      ),
                      onPressed: mgr.toggleSftpPanel,
                    ),
                    IconButton(
                      key: const Key('quickThemeToggleBtn'),
                      tooltip: s.settingsThemeLabel,
                      icon: Icon(
                        settings.themePreset == AppThemePreset.dark
                            ? Icons.light_mode_rounded
                            : Icons.dark_mode_rounded,
                        size: 18,
                        color: tp.accent,
                      ),
                      onPressed: () =>
                          ref.read(settingsProvider.notifier).toggleTheme(),
                    ),
                    IconButton(
                      key: const Key('settingsBtn'),
                      tooltip: s.settingsTooltip,
                      icon: const Icon(Icons.tune_rounded, size: 18),
                      onPressed: () => showSettingsDialog(context, ref),
                    ),
                    IconButton(
                      tooltip: s.lockVaultTooltip,
                      icon: const Icon(Icons.lock_outline_rounded, size: 18),
                      onPressed: () => ref.read(vaultProvider.notifier).lock(),
                    ),
                  ],
                ),
              ),

              if (inv.error != null)
                InlineNotice(
                  message: inv.error!,
                  onRetry: () =>
                      ref.read(inventoryProvider.notifier).refreshAll(),
                ),
              if (ws.lastError != null)
                InlineNotice(message: ws.lastError!, onDismiss: mgr.clearError),

              // Broadcast safety banner
              if (ws.broadcastMode)
                Container(
                  key: const Key('broadcastSafetyBanner'),
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: ws.broadcastIncludesProd
                        ? tp.red.withValues(alpha: 0.14)
                        : tp.amber.withValues(alpha: 0.12),
                    border: Border(
                      bottom: BorderSide(
                        color: ws.broadcastIncludesProd
                            ? tp.red.withValues(alpha: 0.45)
                            : tp.amber.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 17,
                        color: ws.broadcastIncludesProd ? tp.red : tp.amber,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          s.broadcastBanner(
                            ws.broadcastTargets.length,
                            ws.broadcastIncludesProd,
                          ),
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: ws.broadcastIncludesProd ? tp.red : tp.amber,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: mgr.toggleBroadcast,
                        child: Text(s.turnOffFast),
                      ),
                    ],
                  ),
                ),

              // Main workspace row
              Expanded(
                child: Row(
                  children: [
                    AnimatedContainer(
                      key: const Key('desktopSidebarPanel'),
                      duration:
                          _resizingSidebar ||
                              MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      width: sidebarWidth,
                      clipBehavior: Clip.hardEdge,
                      decoration: const BoxDecoration(),
                      child: _sidebarOpen
                          ? Stack(
                              children: [
                                Positioned.fill(
                                  child: const ConnectionLibrary(),
                                ),
                                Positioned(
                                  top: 0,
                                  bottom: 0,
                                  right: 0,
                                  child: PanelResizeHandle(
                                    key: const Key('sidebarResizeHandle'),
                                    label: context.tr('Độ rộng danh sách host'),
                                    onDragStateChanged: (dragging) => setState(
                                      () => _resizingSidebar = dragging,
                                    ),
                                    onDelta: (delta) => setState(
                                      () =>
                                          _sidebarWidth = (sidebarWidth + delta)
                                              .clamp(220, maxSidebarWidth),
                                    ),
                                    onReset: () =>
                                        setState(() => _sidebarWidth = 244),
                                  ),
                                ),
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
                    Expanded(
                      child: Column(
                        key: const Key('desktopTerminalWorkspace'),
                        children: [
                          // Pill Session Tabs
                          if (ws.tabs.isNotEmpty)
                            Container(
                              height: 38,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: tp.surface,
                                border: Border(
                                  bottom: BorderSide(color: tp.border),
                                ),
                              ),
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: ws.tabs.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 5),
                                itemBuilder: (_, i) {
                                  final t = ws.tabs[i];
                                  final sel =
                                      i == ws.activeIndex && !ws.showOverview;
                                  final isProd =
                                      t.envTag.toLowerCase() == 'prod';
                                  return InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: () => mgr.setActiveTab(i),
                                    child: AnimatedContainer(
                                      duration:
                                          MediaQuery.disableAnimationsOf(
                                            context,
                                          )
                                          ? Duration.zero
                                          : const Duration(milliseconds: 140),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                      ),
                                      decoration: BoxDecoration(
                                        color: sel
                                            ? tp.surface2
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: sel
                                              ? (isProd
                                                    ? tp.red.withValues(
                                                        alpha: 0.45,
                                                      )
                                                    : tp.borderStrong)
                                              : Colors.transparent,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          StatusDot(
                                            color: t.closed
                                                ? tp.red
                                                : (isProd
                                                      ? tp.amber
                                                      : tp.green),
                                            glow: sel && !t.closed,
                                            size: 7,
                                          ),
                                          const SizedBox(width: 7),
                                          Text(
                                            t.title,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: sel
                                                  ? FontWeight.w800
                                                  : FontWeight.w500,
                                              color: sel ? tp.ink : tp.muted,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          InkWell(
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                            onTap: () =>
                                                mgr.closeTab(t.localKey),
                                            child: Padding(
                                              padding: const EdgeInsets.all(2),
                                              child: Icon(
                                                Icons.close_rounded,
                                                size: 13,
                                                color: tp.muted,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),

                          // Terminal Area / Overview / Empty welcome
                          Expanded(
                            child: ws.showOverview
                                ? _OverviewGrid(
                                    tabs: ws.tabs,
                                    onSelect: mgr.setActiveTab,
                                    s: s,
                                  )
                                : ws.tabs.isEmpty
                                ? _EmptyWorkspace(
                                    s: s,
                                    onLocalShell: () => mgr.openLocalShell(),
                                    onAddHost: () =>
                                        showHostEditorDialog(context, ref),
                                    onImport: () =>
                                        showImportExportDialog(context, ref),
                                  )
                                : _SplitTerminalArea(ws: ws, mgr: mgr),
                          ),

                          // Pinned Snippets Button Bar
                          if (activeTab != null && !activeTab.isRemoteDesktop)
                            Container(
                              height: 42,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              decoration: BoxDecoration(
                                color: tp.surface,
                                border: Border(
                                  top: BorderSide(color: tp.border),
                                ),
                              ),
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                children: [
                                  for (final sn in inv.snippets.where(
                                    (sn) => sn.pinButtonBar,
                                  ))
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        right: 6,
                                        top: 4,
                                        bottom: 4,
                                      ),
                                      child: HoverSurface(
                                        borderRadius: BorderRadius.circular(8),
                                        color: tp.surface2,
                                        hoverColor: tp.accentContainer,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 3,
                                        ),
                                        onTap:
                                            activeTab.closed ||
                                                activeTab.sessionId == null
                                            ? null
                                            : () => sendGuardedCommand(
                                                context,
                                                ref,
                                                sn.commandTpl,
                                              ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.bolt_rounded,
                                              size: 13,
                                              color: tp.accent,
                                            ),
                                            const SizedBox(width: 5),
                                            Text(
                                              sn.title,
                                              style: TextStyle(
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.w600,
                                                color: tp.ink,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  IconButton(
                                    key: const Key('toggleComposeButton'),
                                    tooltip: context.tr(
                                      _showCompose
                                          ? 'Ẩn ô soạn lệnh / Hide compose'
                                          : 'Hiện ô soạn lệnh / Show compose',
                                    ),
                                    icon: Icon(
                                      _showCompose
                                          ? Icons.edit_off_rounded
                                          : Icons.edit_note_rounded,
                                      size: 16,
                                    ),
                                    onPressed: () => setState(
                                      () => _showCompose = !_showCompose,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                          if (_showCompose &&
                              activeTab != null &&
                              !activeTab.isRemoteDesktop)
                            const ComposeBar(),
                        ],
                      ),
                    ),

                    if (hasSftp)
                      AnimatedContainer(
                        key: const Key('desktopSftpPanel'),
                        duration:
                            _resizingSftp ||
                                MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        width: sftpWidth,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: SftpPanel(
                                tab: activeTab,
                                commanderMode: _sftpCommanderMode && !compact,
                                onCommanderChanged: (v) =>
                                    setState(() => _sftpCommanderMode = v),
                              ),
                            ),
                            if (!_sftpCommanderMode || compact)
                              Positioned(
                                top: 0,
                                bottom: 0,
                                left: 0,
                                child: PanelResizeHandle(
                                  key: const Key('sftpResizeHandle'),
                                  label: context.tr('Độ rộng SFTP'),
                                  onDragStateChanged: (dragging) =>
                                      setState(() => _resizingSftp = dragging),
                                  onDelta: (delta) => setState(
                                    () => _sftpWidth = (sftpWidth - delta)
                                        .clamp(240, maxSftpWidth),
                                  ),
                                  onSizeDelta: (delta) => setState(
                                    () => _sftpWidth = (sftpWidth + delta)
                                        .clamp(240, maxSftpWidth),
                                  ),
                                  onReset: () => setState(
                                    () => _sftpWidth = compact ? 280 : 320,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),

              const BottomDock(),
            ],
          ),
        ),
      ),
    );
  }
}

class _SplitTerminalArea extends StatefulWidget {
  final WorkspaceState ws;
  final SessionManagerController mgr;
  const _SplitTerminalArea({required this.ws, required this.mgr});

  @override
  State<_SplitTerminalArea> createState() => _SplitTerminalAreaState();
}

class _SplitTerminalAreaState extends State<_SplitTerminalArea> {
  List<String> _visibleKeys = [];

  @override
  void initState() {
    super.initState();
    _reconcilePanes();
  }

  @override
  void didUpdateWidget(covariant _SplitTerminalArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reconcilePanes();
  }

  void _reconcilePanes() {
    final ws = widget.ws;
    final visibleCount = switch (ws.splitMode) {
      SplitMode.single => 1,
      SplitMode.horizontal || SplitMode.vertical => 2,
      SplitMode.quad => 4,
    };
    final available = ws.tabs.map((tab) => tab.localKey).toSet();
    final keys = _visibleKeys
        .where(available.contains)
        .take(visibleCount)
        .toList();
    final active = ws.activeTab;
    if (active != null && !keys.contains(active.localKey)) {
      if (keys.length == visibleCount) keys.removeLast();
      keys.add(active.localKey);
    }
    for (final t in ws.tabs) {
      if (keys.length >= visibleCount) break;
      if (!keys.contains(t.localKey)) keys.add(t.localKey);
    }
    _visibleKeys = keys;
  }

  @override
  Widget build(BuildContext context) {
    final ws = widget.ws;
    final tabsByKey = {for (final tab in ws.tabs) tab.localKey: tab};
    final panes = _visibleKeys.map((key) => tabsByKey[key]!).toList();

    Widget paneFor(TerminalSessionTab t, {required bool isSplit}) {
      final idx = ws.tabs.indexWhere((x) => x.localKey == t.localKey);
      void activate() {
        if (idx != widget.ws.activeIndex) widget.mgr.setActiveTab(idx);
      }

      return Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) {
          if (focused) activate();
        },
        child: TerminalPane(
          key: ValueKey(t.localKey),
          tab: t,
          isActive: idx == ws.activeIndex,
          showBroadcastBadge: ws.broadcastMode,
          showSplitFocusLine: isSplit,
          onFocus: activate,
        ),
      );
    }

    Widget expandedPane(TerminalSessionTab t) => Expanded(
      key: ValueKey('desktopSplitSlot:${t.localKey}'),
      child: paneFor(t, isSplit: true),
    );

    if (panes.isEmpty) return const SizedBox.shrink();
    if (panes.length == 1) {
      return paneFor(panes[0], isSplit: false);
    }
    if (ws.splitMode == SplitMode.horizontal) {
      return Padding(
        padding: const EdgeInsets.all(6),
        child: Row(
          children: [
            expandedPane(panes[0]),
            const SizedBox(width: 6),
            expandedPane(panes[1]),
          ],
        ),
      );
    }
    if (ws.splitMode == SplitMode.vertical) {
      return Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          children: [
            expandedPane(panes[0]),
            const SizedBox(height: 6),
            expandedPane(panes[1]),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                expandedPane(panes[0]),
                const SizedBox(width: 6),
                if (panes.length > 1)
                  expandedPane(panes[1])
                else
                  const Expanded(child: SizedBox()),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Row(
              children: [
                if (panes.length > 2)
                  expandedPane(panes[2])
                else
                  const Expanded(child: SizedBox()),
                const SizedBox(width: 6),
                if (panes.length > 3)
                  expandedPane(panes[3])
                else
                  const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OverviewGrid extends StatelessWidget {
  final List<TerminalSessionTab> tabs;
  final void Function(int) onSelect;
  final AppStrings s;
  const _OverviewGrid({
    required this.tabs,
    required this.onSelect,
    required this.s,
  });

  String _tailPreview(TerminalSessionTab tab) {
    final raw = tab.terminal.buffer
        .getText()
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (raw.isEmpty) return '—';
    final start = raw.length > 3 ? raw.length - 3 : 0;
    return raw.sublist(start).join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final tp = context.tp;
    if (tabs.isEmpty) {
      return AmbientBackdrop(
        child: Center(
          child: Text(s.overviewEmpty, style: TextStyle(color: tp.muted)),
        ),
      );
    }
    return AmbientBackdrop(
      child: GridView.builder(
        padding: const EdgeInsets.all(18),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 380,
          mainAxisExtent: 186,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
        ),
        itemCount: tabs.length,
        findChildIndexCallback: (key) {
          if (key is! ValueKey<String>) return null;
          final index = tabs.indexWhere(
            (tab) => key.value == 'desktopOverview:${tab.localKey}',
          );
          return index < 0 ? null : index;
        },
        itemBuilder: (_, i) {
          final t = tabs[i];
          return HoverSurface(
            key: ValueKey('desktopOverview:${t.localKey}'),
            padding: const EdgeInsets.all(14),
            borderRadius: BorderRadius.circular(16),
            onTap: () => onSelect(i),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    StatusDot(
                      color: t.closed ? tp.red : tp.green,
                      glow: !t.closed,
                      size: 8,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t.title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                    EnvBadge(envTag: t.envTag, compact: true),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  t.isRemoteDesktop
                      ? t.protocol.toUpperCase()
                      : 'cwd: ${t.terminalCwd}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    color: tp.cyan,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: tp.terminalTheme.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: tp.border),
                    ),
                    child: t.remoteDesktop?.frame != null
                        ? _DesktopOverviewFrame(
                            key: ValueKey('desktopOverviewFrame:${t.localKey}'),
                            session: t.remoteDesktop!,
                          )
                        : Text(
                            t.isRemoteDesktop
                                ? context.tr('Màn hình từ xa')
                                : _tailPreview(t),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 10.5,
                              height: 1.38,
                              color: tp.terminalTheme.foreground,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  t.agentAlert == null
                      ? (t.closed ? s.sessionClosed : s.sessionRunningHint)
                      : context.tr(t.agentAlert!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: t.agentAlert != null ? tp.amber : tp.muted,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DesktopOverviewFrame extends StatefulWidget {
  final RemoteDesktopSession session;
  const _DesktopOverviewFrame({super.key, required this.session});

  @override
  State<_DesktopOverviewFrame> createState() => _DesktopOverviewFrameState();
}

class _DesktopOverviewFrameState extends State<_DesktopOverviewFrame> {
  ui.Image? _image;
  Timer? _timer;
  bool _decoding = false;
  int _sequence = -1;
  int _decodeGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_schedule);
    _decode();
  }

  @override
  void didUpdateWidget(covariant _DesktopOverviewFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.session, widget.session)) return;
    oldWidget.session.removeListener(_schedule);
    _timer?.cancel();
    _timer = null;
    _decodeGeneration++;
    _decoding = false;
    _sequence = -1;
    final previous = _image;
    _image = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => previous?.dispose());
    widget.session.addListener(_schedule);
    _decode();
  }

  void _schedule() {
    _timer ??= Timer(const Duration(milliseconds: 400), () {
      _timer = null;
      _decode();
    });
  }

  void _decode() {
    final frame = widget.session.frame;
    if (_decoding || frame == null || frame.sequence == _sequence) return;
    final generation = _decodeGeneration;
    _decoding = true;
    ui.decodeImageFromPixels(
      frame.rgba,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      (image) {
        if (!mounted || generation != _decodeGeneration) {
          image.dispose();
          return;
        }
        _decoding = false;
        final previous = _image;
        setState(() {
          _image = image;
          _sequence = frame.sequence;
        });
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => previous?.dispose(),
        );
        if (widget.session.frame?.sequence != frame.sequence) _schedule();
      },
    );
  }

  @override
  Widget build(BuildContext context) =>
      RawImage(image: _image, fit: BoxFit.contain);

  @override
  void dispose() {
    _decodeGeneration++;
    widget.session.removeListener(_schedule);
    _timer?.cancel();
    _image?.dispose();
    super.dispose();
  }
}

class _EmptyWorkspace extends StatelessWidget {
  final AppStrings s;
  final VoidCallback onLocalShell;
  final VoidCallback onAddHost;
  final VoidCallback onImport;
  const _EmptyWorkspace({
    required this.s,
    required this.onLocalShell,
    required this.onAddHost,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    final tp = context.tp;
    final isDark = tp.brightness == Brightness.dark;
    return AmbientBackdrop(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: tp.surface.withValues(alpha: isDark ? 0.94 : 0.98),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: tp.borderStrong),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.08),
                    blurRadius: 36,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TermPulseLogo(size: 60, showGlow: true),
                  const SizedBox(height: 16),
                  Text(
                    s.readyTitle,
                    style: const TextStyle(
                      fontSize: 18.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    s.readyDesc,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: tp.muted,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: onLocalShell,
                        icon: const Icon(Icons.terminal_rounded, size: 17),
                        label: Text(s.openLocalShell),
                      ),
                      OutlinedButton.icon(
                        onPressed: onAddHost,
                        icon: const Icon(Icons.add_rounded, size: 17),
                        label: Text(s.addHost),
                      ),
                      OutlinedButton.icon(
                        onPressed: onImport,
                        icon: const Icon(Icons.file_upload_outlined, size: 17),
                        label: Text(s.importSshConfigBtn),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
