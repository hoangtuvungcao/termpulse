import 'dart:async';

import 'package:flutter/material.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/remote_desktop/remote_desktop_pane.dart';
import 'package:termpulse/features/terminal/command_guard_dialog.dart';
import 'package:termpulse/features/terminal/command_palette.dart';
import 'package:termpulse/features/terminal/session_log_dialog.dart';
import 'package:termpulse/features/terminal/terminal_search.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/session_logs_provider.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:termpulse/ui/widgets/ui_kit.dart';
import 'package:xterm/xterm.dart';

class TerminalPane extends ConsumerStatefulWidget {
  final TerminalSessionTab tab;
  final bool isActive;
  final bool showBroadcastBadge;
  final VoidCallback onFocus;
  final bool hardwareKeyboardOnly;
  final bool chromeless;
  final bool showSplitFocusLine;
  final double? fontSizeOverride;
  final int searchRequest;
  final bool remoteDesktopFullscreen;
  final VoidCallback? onToggleRemoteDesktopFullscreen;

  const TerminalPane({
    super.key,
    required this.tab,
    required this.isActive,
    required this.showBroadcastBadge,
    required this.onFocus,
    this.hardwareKeyboardOnly = false,
    this.chromeless = false,
    this.showSplitFocusLine = false,
    this.fontSizeOverride,
    this.searchRequest = 0,
    this.remoteDesktopFullscreen = false,
    this.onToggleRemoteDesktopFullscreen,
  });

  @override
  ConsumerState<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends ConsumerState<TerminalPane> {
  final _focusNode = FocusNode(debugLabel: 'terminal input');
  final _searchFocus = FocusNode(debugLabel: 'terminal search');
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final _chromeScrollController = ScrollController();
  final _terminalViewKey = GlobalKey<TerminalViewState>();
  Timer? _searchDebounce;
  List<TerminalSearchMatch> _matches = [];
  TerminalHighlight? _highlight;
  int _matchIndex = 0;
  bool _searchOpen = false;
  bool _caseSensitive = false;
  bool _pasting = false;
  bool _reconnecting = false;
  bool _paletteOpen = false;

  @override
  void initState() {
    super.initState();
    widget.tab.terminal.addListener(_scheduleSearch);
  }

  @override
  void didUpdateWidget(covariant TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tab.terminal != widget.tab.terminal) {
      oldWidget.tab.terminal.removeListener(_scheduleSearch);
      widget.tab.terminal.addListener(_scheduleSearch);
      _clearHighlight();
      _scheduleSearch();
    }
    if (oldWidget.searchRequest != widget.searchRequest) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openSearch();
      });
    }
    if ((!oldWidget.isActive && widget.isActive) ||
        oldWidget.tab.localKey != widget.tab.localKey) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            widget.isActive &&
            (ModalRoute.of(context)?.isCurrent ?? true)) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  void _scheduleSearch() {
    if (!_searchOpen) return;
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 120), _findMatches);
  }

  void _clearHighlight() {
    final highlight = _highlight;
    _highlight = null;
    if (highlight == null) return;
    highlight.dispose();
    highlight.p1.dispose();
    highlight.p2.dispose();
  }

  void _openSearch() {
    setState(() => _searchOpen = true);
    _findMatches();
    _searchFocus.requestFocus();
  }

  void _closeSearch() {
    _searchDebounce?.cancel();
    _clearHighlight();
    setState(() => _searchOpen = false);
    _focusTerminal();
  }

  void _findMatches() {
    if (!mounted || !_searchOpen) return;
    final matches = searchTerminalBuffer(
      widget.tab.terminal.buffer,
      _searchController.text,
      caseSensitive: _caseSensitive,
    );
    setState(() {
      _matches = matches;
      _matchIndex = matches.isEmpty
          ? 0
          : _matchIndex.clamp(0, matches.length - 1);
    });
    _showMatch();
  }

  void _stepSearch(int direction) {
    if (_matches.isEmpty) return;
    setState(() => _matchIndex = (_matchIndex + direction) % _matches.length);
    _showMatch();
  }

  void _showMatch() {
    _clearHighlight();
    if (_matches.isEmpty) return;
    final match = _matches[_matchIndex];
    final buffer = widget.tab.terminal.buffer;
    if (match.end.y >= buffer.height) return;
    _highlight = widget.tab.controller.highlight(
      p1: buffer.createAnchorFromOffset(match.begin),
      p2: buffer.createAnchorFromOffset(match.end),
      color: context.tp.accent.withValues(alpha: 0.4),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_searchOpen || !_scrollController.hasClients) return;
      final lineHeight =
          _terminalViewKey.currentState?.renderTerminal.lineHeight;
      if (lineHeight == null) return;
      final position = _scrollController.position;
      final target =
          match.begin.y * lineHeight - position.viewportDimension / 2;
      _scrollController.jumpTo(target.clamp(0, position.maxScrollExtent));
    });
  }

  Future<void> _copySelection({bool all = false}) async {
    final selection = widget.tab.controller.selection;
    if (!all && selection == null) return;
    final text = widget.tab.terminal.buffer.getText(all ? null : selection);
    if (text.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(context.tr('Đã sao chép / Copied')),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (error) {
      _showError('Không sao chép được: $error');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    showAppErrorSnackBar(context, message);
  }

  Future<void> _paste() async {
    if (_pasting || widget.tab.closed || widget.tab.sessionId == null) return;
    _pasting = true;
    _focusTerminal();
    final ws = ref.read(sessionManagerProvider);
    final activeKey = widget.tab.localKey;
    final recipients = ws.broadcastMode
        ? ws.broadcastTargets.map((t) => t.sessionId!).toList()
        : [widget.tab.sessionId!];
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      // Clipboard escape sequences must never be able to break out of a
      // bracketed paste or impersonate keyboard controls.
      final text = data?.text?.replaceAll(
        RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'),
        '',
      );
      if (text == null || text.isEmpty) return;
      final guard = ref
          .read(backendProvider)
          .checkCommandGuard(
            text,
            ws.broadcastMode && ws.broadcastIncludesProd
                ? 'prod'
                : widget.tab.envTag,
          );
      if (guard.severity != 'safe' ||
          guard.isMultiline ||
          text.contains('\n') ||
          text.contains('\r')) {
        final approved = await showCommandGuardDialog(
          context,
          command: text,
          result: guard,
          targetLabel: ws.broadcastMode
              ? context.tr('Broadcast ({count} host)', {
                  'count': '${recipients.length}',
                })
              : widget.tab.title,
        );
        if (!mounted || !approved) return;
      }
      await ref
          .read(sessionManagerProvider.notifier)
          .sendTextToActive(
            text,
            broadcastIfEnabled: true,
            bracketedPaste: true,
            expectedActiveKey: activeKey,
            expectedSessionIds: recipients,
            expectedBroadcastMode: ws.broadcastMode,
          );
      if (mounted) _focusNode.requestFocus();
    } catch (error) {
      _showError('Không dán được: $error');
    } finally {
      _pasting = false;
    }
  }

  Future<void> _showContextMenu(
    TapDownDetails details,
    CellOffset offset,
  ) async {
    _focusTerminal();
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        details.globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'copy',
          enabled: widget.tab.controller.selection != null,
          child: Text(context.tr('Sao chép / Copy')),
        ),
        PopupMenuItem(
          value: 'paste',
          enabled: !widget.tab.closed && widget.tab.sessionId != null,
          child: Text(context.tr('Dán / Paste')),
        ),
        PopupMenuItem(
          value: 'find',
          child: Text(context.tr('Tìm trong terminal / Find')),
        ),
        PopupMenuItem(
          value: 'all',
          child: Text(context.tr('Sao chép toàn bộ / Copy all')),
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'copy':
        await _copySelection();
      case 'paste':
        await _paste();
      case 'find':
        _openSearch();
      case 'all':
        await _copySelection(all: true);
    }
  }

  Widget _buildSearchBar() {
    final tp = context.tp;
    final count = _searchController.text.isEmpty
        ? '0/0'
        : '${_matches.isEmpty ? 0 : _matchIndex + 1}/${_matches.length}${_matches.length == 1000 ? '+' : ''}';
    final countStyle = TextStyle(
      fontSize: 11,
      color: _matches.isEmpty && _searchController.text.isNotEmpty
          ? tp.amber
          : tp.muted,
    );
    final textScaler = MediaQuery.textScalerOf(context);
    final countPainter = TextPainter(
      text: TextSpan(
        text: count,
        style: DefaultTextStyle.of(context).style.merge(countStyle),
      ),
      textDirection: Directionality.of(context),
      textScaler: textScaler,
    )..layout();
    final actionsWidth = countPainter.width + 4 * 48;
    countPainter.dispose();
    return Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _closeSearch();
          return KeyEventResult.handled;
        }
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.enter &&
            HardwareKeyboard.instance.isShiftPressed) {
          _stepSearch(-1);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        key: const Key('terminalSearchBar'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: tp.surface2,
          border: Border(bottom: BorderSide(color: tp.border)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow =
                constraints.maxWidth <
                actionsWidth + textScaler.scale(12) * 7 + 8;
            return Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: narrow
                      ? constraints.maxWidth
                      : constraints.maxWidth - actionsWidth - 8,
                  child: TextField(
                    key: const Key('terminalSearchField'),
                    controller: _searchController,
                    focusNode: _searchFocus,
                    onChanged: (_) {
                      _matchIndex = 0;
                      _findMatches();
                    },
                    onSubmitted: (_) {
                      _stepSearch(1);
                      _searchFocus.requestFocus();
                    },
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      hintText: context.tr('Tìm / Find'),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 9,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  key: const Key('terminalSearchActions'),
                  width: narrow ? constraints.maxWidth : actionsWidth,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    primary: false,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            count,
                            key: const Key('terminalSearchCount'),
                            style: countStyle,
                          ),
                        ),
                        IconButton(
                          tooltip: context.tr(
                            'Phân biệt hoa thường / Match case',
                          ),
                          isSelected: _caseSensitive,
                          onPressed: () {
                            setState(() => _caseSensitive = !_caseSensitive);
                            _findMatches();
                          },
                          icon: const Text(
                            'Aa',
                            style: TextStyle(fontSize: 12),
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                        IconButton(
                          key: const Key('terminalSearchPrevious'),
                          tooltip: context.tr('Kết quả trước / Previous'),
                          onPressed: _matches.isEmpty
                              ? null
                              : () => _stepSearch(-1),
                          icon: const Icon(
                            Icons.keyboard_arrow_up_rounded,
                            size: 19,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                        IconButton(
                          key: const Key('terminalSearchNext'),
                          tooltip: context.tr('Kết quả tiếp / Next'),
                          onPressed: _matches.isEmpty
                              ? null
                              : () => _stepSearch(1),
                          icon: const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 19,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                        IconButton(
                          key: const Key('terminalSearchClose'),
                          tooltip: context.tr('Đóng tìm kiếm / Close search'),
                          onPressed: _closeSearch,
                          icon: const Icon(Icons.close_rounded, size: 17),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildClosedNotice() {
    final tp = context.tp;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: tp.amber.withValues(alpha: 0.08),
        border: Border(
          bottom: BorderSide(color: tp.amber.withValues(alpha: 0.2)),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.link_off_rounded, color: tp.amber, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.tr('Phiên đã đóng / Disconnected'),
              style: TextStyle(color: tp.amber, fontSize: 12),
            ),
          ),
          TextButton.icon(
            key: const Key('terminalReconnectBtn'),
            onPressed: _reconnecting
                ? null
                : () async {
                    setState(() => _reconnecting = true);
                    try {
                      await ref
                          .read(sessionManagerProvider.notifier)
                          .reconnectTab(widget.tab.localKey);
                      if (mounted) _focusTerminal();
                    } finally {
                      if (mounted) setState(() => _reconnecting = false);
                    }
                  },
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: Text(
              context.tr('Kết nối lại / Reconnect'),
              style: TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  void _focusTerminal() {
    widget.onFocus();
    _focusNode.requestFocus();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final copy =
        event.logicalKey == LogicalKeyboardKey.keyC &&
        ((keyboard.isControlPressed && keyboard.isShiftPressed) ||
            keyboard.isMetaPressed);
    final paste =
        event.logicalKey == LogicalKeyboardKey.keyV &&
        (keyboard.isControlPressed || keyboard.isMetaPressed);
    final find =
        event.logicalKey == LogicalKeyboardKey.keyF &&
        ((keyboard.isControlPressed && keyboard.isShiftPressed) ||
            keyboard.isMetaPressed);
    if (!keyboard.isAltPressed && (copy || paste || find)) {
      if (event is KeyDownEvent) {
        if (copy) unawaited(_copySelection());
        if (paste) unawaited(_paste());
        if (find) _openSearch();
      }
      return KeyEventResult.handled;
    }
    final paletteShortcut =
        event.logicalKey == LogicalKeyboardKey.keyK &&
        keyboard.isControlPressed != keyboard.isMetaPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed;
    if (!paletteShortcut) return KeyEventResult.ignored;

    if (event is KeyDownEvent && !_paletteOpen) {
      _paletteOpen = true;
      unawaited(
        showCommandPaletteDialog(context, ref).whenComplete(() {
          _paletteOpen = false;
        }),
      );
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    widget.tab.terminal.removeListener(_scheduleSearch);
    _searchDebounce?.cancel();
    _clearHighlight();
    _searchFocus.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _chromeScrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Widget _buildPaneBody({
    required List<Widget> chrome,
    required Widget terminal,
  }) => LayoutBuilder(
    builder: (context, constraints) => Column(
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: constraints.maxHeight * .6),
          child: SingleChildScrollView(
            key: const Key('terminalChromeScroll'),
            controller: _chromeScrollController,
            primary: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: chrome),
          ),
        ),
        Expanded(child: terminal),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final desktop = widget.tab.remoteDesktop;
    if (desktop != null) {
      return RemoteDesktopPane(
        key: ValueKey(widget.tab.localKey),
        session: desktop,
        onFocus: widget.onFocus,
        fullscreen: widget.remoteDesktopFullscreen,
        onToggleFullscreen: widget.onToggleRemoteDesktopFullscreen,
      );
    }
    final tab = widget.tab;
    final isActive = widget.isActive;
    final showBroadcastBadge = widget.showBroadcastBadge;
    final hardwareKeyboardOnly = widget.hardwareKeyboardOnly;
    final chromeless = widget.chromeless;
    final showSplitFocusLine = widget.showSplitFocusLine;
    final fontSizeOverride = widget.fontSizeOverride;
    final tp = context.tp;
    final baseFontSize = ref.watch(settingsProvider).terminalFontSize;
    final recording =
        ref.watch(sessionLogsProvider).activeFor(tab.localKey) != null;
    final isMobileWidth = MediaQuery.sizeOf(context).width < 600;
    final effectiveFontSize =
        (fontSizeOverride ??
                (isMobileWidth ? baseFontSize - 0.5 : baseFontSize))
            .clamp(11.0, 20.0);
    final isProd = tab.envTag.toLowerCase() == 'prod';

    final focusLineColor = showBroadcastBadge && tab.broadcastIncluded
        ? (isProd ? tp.red : tp.amber)
        : (isProd && chromeless ? tp.red : tp.accent);

    final alertBanner = tab.agentAlert == null
        ? null
        : Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: tp.accentContainer.withValues(alpha: 0.9),
              border: Border(bottom: BorderSide(color: tp.border)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.notifications_active_rounded,
                  size: 14,
                  color: tp.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.tr(tab.agentAlert!),
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: tp.ink,
                    ),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => ref
                      .read(sessionManagerProvider.notifier)
                      .clearTabAlert(tab.localKey),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.close_rounded, size: 15, color: tp.muted),
                  ),
                ),
              ],
            ),
          );

    if (chromeless) {
      return GestureDetector(
        onTap: _focusTerminal,
        child: ColoredBox(
          color: tp.terminalTheme.background,
          child: _buildPaneBody(
            chrome: [
              if (isProd)
                Container(
                  height: 2,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        tp.red.withValues(alpha: 0.25),
                        tp.red.withValues(alpha: 0.9),
                        tp.red.withValues(alpha: 0.25),
                      ],
                    ),
                  ),
                ),
              ?alertBanner,
              if (tab.closed) _buildClosedNotice(),
              if (_searchOpen) _buildSearchBar(),
            ],
            terminal: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: TerminalView(
                key: _terminalViewKey,
                tab.terminal,
                scrollController: _scrollController,
                shortcuts: const {},
                focusNode: _focusNode,
                onKeyEvent: _handleKeyEvent,
                controller: tab.controller,
                theme: tp.terminalTheme,
                textStyle: TerminalStyle(fontSize: effectiveFontSize),
                autofocus: isActive,
                deleteDetection: true,
                hardwareKeyboardOnly: hardwareKeyboardOnly,
                keyboardAppearance: tp.brightness,
                keyboardType: TextInputType.visiblePassword,
                readOnly: tab.closed,
                onTapUp: (details, offset) => _focusTerminal(),
                onSecondaryTapDown: _showContextMenu,
              ),
            ),
          ),
        ),
      );
    }

    final radius = showSplitFocusLine
        ? BorderRadius.circular(10)
        : BorderRadius.zero;
    final showTopAccent =
        (showSplitFocusLine && isActive) ||
        (showBroadcastBadge && tab.broadcastIncluded);

    return GestureDetector(
      onTap: _focusTerminal,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: radius,
          border: showSplitFocusLine
              ? Border.all(
                  color: showBroadcastBadge && tab.broadcastIncluded
                      ? focusLineColor.withValues(alpha: 0.72)
                      : (isActive ? tp.borderStrong : tp.border),
                  width: 1,
                )
              : null,
          color: tp.terminalTheme.background,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: _buildPaneBody(
            chrome: [
              if (showTopAccent)
                Container(
                  height: 2,
                  width: double.infinity,
                  color: focusLineColor,
                ),
              Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: isActive ? tp.surface : tp.bg,
                  border: Border(bottom: BorderSide(color: tp.border)),
                ),
                child: Row(
                  children: [
                    StatusDot(
                      color: tab.closed
                          ? tp.red
                          : (tab.sessionId == null ? tp.amber : tp.green),
                      glow: !tab.closed && tab.sessionId != null,
                      size: 7,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: RichText(
                        overflow: TextOverflow.ellipsis,
                        text: TextSpan(
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontFamily: 'monospace',
                          ),
                          children: [
                            TextSpan(
                              text: tab.title,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: tp.ink,
                              ),
                            ),
                            TextSpan(
                              text: '  ›  ',
                              style: TextStyle(color: tp.muted),
                            ),
                            TextSpan(
                              text: tab.terminalCwd,
                              style: TextStyle(color: tp.cyan),
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('terminalFindBtn'),
                      tooltip: context.tr(
                        'Tìm trong terminal (Ctrl+Shift+F / ⌘F)',
                      ),
                      onPressed: _openSearch,
                      icon: Icon(
                        Icons.search_rounded,
                        size: 17,
                        color: tp.muted,
                      ),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 28,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                    PopupMenuButton<String>(
                      key: const Key('terminalSessionTools'),
                      tooltip: context.tr('Nhật ký và lịch sử phiên'),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 28,
                      ),
                      iconSize: 18,
                      icon: Icon(
                        recording
                            ? Icons.fiber_manual_record_rounded
                            : Icons.receipt_long_rounded,
                        color: recording ? tp.red : tp.muted,
                      ),
                      onSelected: (action) {
                        switch (action) {
                          case 'toggle':
                            unawaited(toggleSessionLogging(context, ref, tab));
                          case 'logs':
                            unawaited(showSessionLogsDialog(context, ref));
                          case 'scrollback':
                            unawaited(exportTerminalScrollback(context, tab));
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          key: const Key('terminalSessionLogToggle'),
                          value: 'toggle',
                          enabled:
                              recording ||
                              (!tab.closed && tab.sessionId != null),
                          child: Text(
                            recording
                                ? context.tr('Dừng ghi đầu ra')
                                : context.tr('Bắt đầu ghi đầu ra'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'logs',
                          child: Text(context.tr('Xem và quản lý log…')),
                        ),
                        PopupMenuItem(
                          value: 'scrollback',
                          child: Text(context.tr('Xuất scrollback hiện có…')),
                        ),
                      ],
                    ),
                    if (isProd) ...[
                      const SizedBox(width: 6),
                      const EnvBadge(envTag: 'prod', compact: true),
                    ],
                    if (showBroadcastBadge) ...[
                      const SizedBox(width: 6),
                      InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () => ref
                            .read(sessionManagerProvider.notifier)
                            .toggleTabBroadcast(tab.localKey),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: tab.broadcastIncluded
                                ? (isProd ? tp.red : tp.amber).withValues(
                                    alpha: 0.16,
                                  )
                                : tp.surface2,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: tab.broadcastIncluded
                                  ? (isProd ? tp.red : tp.amber).withValues(
                                      alpha: 0.55,
                                    )
                                  : tp.border,
                            ),
                          ),
                          child: Text(
                            tab.broadcastIncluded
                                ? context.tr('TX ON')
                                : context.tr('TX MUTED'),
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              color: tab.broadcastIncluded
                                  ? (isProd ? tp.red : tp.amber)
                                  : tp.muted,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              ?alertBanner,
              if (tab.closed) _buildClosedNotice(),
              if (_searchOpen) _buildSearchBar(),
            ],
            terminal: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: TerminalView(
                key: _terminalViewKey,
                tab.terminal,
                scrollController: _scrollController,
                shortcuts: const {},
                focusNode: _focusNode,
                onKeyEvent: _handleKeyEvent,
                controller: tab.controller,
                theme: tp.terminalTheme,
                textStyle: TerminalStyle(fontSize: effectiveFontSize),
                autofocus: isActive,
                deleteDetection: true,
                hardwareKeyboardOnly: hardwareKeyboardOnly,
                keyboardAppearance: tp.brightness,
                keyboardType: TextInputType.visiblePassword,
                readOnly: tab.closed,
                onTapUp: (details, offset) => _focusTerminal(),
                onSecondaryTapDown: _showContextMenu,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
