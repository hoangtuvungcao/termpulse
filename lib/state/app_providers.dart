import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termpulse/core/backend.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/remote_desktop_backend.dart';
import 'package:termpulse/features/remote_desktop/remote_desktop_session.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/src/rust/api/serial_api.dart';
import 'package:termpulse/state/session_logs_provider.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:xterm/xterm.dart';

final backendProvider = Provider<CoreBackend>((ref) => RustCoreBackend());

// --- Vault State ---
class VaultUiState {
  final bool initialized;
  final bool unlocked;
  final bool loading;
  final String dbPath;
  final String? error;

  const VaultUiState({
    this.initialized = false,
    this.unlocked = false,
    this.loading = false,
    this.dbPath = '',
    this.error,
  });

  VaultUiState copyWith({
    bool? initialized,
    bool? unlocked,
    bool? loading,
    String? dbPath,
    String? error,
  }) {
    return VaultUiState(
      initialized: initialized ?? this.initialized,
      unlocked: unlocked ?? this.unlocked,
      loading: loading ?? this.loading,
      dbPath: dbPath ?? this.dbPath,
      error: error,
    );
  }
}

class VaultController extends Notifier<VaultUiState> {
  @override
  VaultUiState build() => const VaultUiState();

  Future<void> initAtPath(String path) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final st = await ref.read(backendProvider).vaultInitPath(path);
      if (!ref.mounted) return;
      state = VaultUiState(
        initialized: st.initialized,
        unlocked: st.unlocked,
        dbPath: st.dbPath,
      );
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<bool> unlock(String password) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final st = await ref.read(backendProvider).vaultUnlock(password);
      if (!ref.mounted) return false;
      state = VaultUiState(
        initialized: st.initialized,
        unlocked: st.unlocked,
        dbPath: st.dbPath,
      );
      await ref.read(inventoryProvider.notifier).refreshAll();
      return true;
    } catch (e) {
      if (!ref.mounted) return false;
      state = state.copyWith(loading: false, error: e.toString());
      return false;
    }
  }

  Future<void> lock() async {
    if (state.loading) return;
    state = state.copyWith(loading: true, error: null);
    try {
      await ref.read(sessionLogsProvider.notifier).stopAll();
      await ref.read(sessionManagerProvider.notifier).closeAllSessions();
      await ref.read(backendProvider).vaultLock();
      if (!ref.mounted) return;
      ref.read(inventoryProvider.notifier).clear();
      state = state.copyWith(unlocked: false, loading: false, error: null);
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(loading: false, error: e.toString());
    }
  }
}

final vaultProvider = NotifierProvider<VaultController, VaultUiState>(
  VaultController.new,
);

// --- Inventory State (Groups, Hosts, Credentials, Identities, Proxies, Tunnels, Snippets) ---
class InventoryState {
  final List<GroupDto> groups;
  final List<HostDto> hosts;
  final List<CredentialDto> credentials;
  final List<IdentityDto> identities;
  final List<ProxyDto> proxies;
  final List<TunnelDto> tunnels;
  final List<SnippetDto> snippets;
  final String searchQuery;
  final bool loading;
  final String? error;

  const InventoryState({
    this.groups = const [],
    this.hosts = const [],
    this.credentials = const [],
    this.identities = const [],
    this.proxies = const [],
    this.tunnels = const [],
    this.snippets = const [],
    this.searchQuery = '',
    this.loading = false,
    this.error,
  });

  InventoryState copyWith({
    List<GroupDto>? groups,
    List<HostDto>? hosts,
    List<CredentialDto>? credentials,
    List<IdentityDto>? identities,
    List<ProxyDto>? proxies,
    List<TunnelDto>? tunnels,
    List<SnippetDto>? snippets,
    String? searchQuery,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return InventoryState(
      groups: groups ?? this.groups,
      hosts: hosts ?? this.hosts,
      credentials: credentials ?? this.credentials,
      identities: identities ?? this.identities,
      proxies: proxies ?? this.proxies,
      tunnels: tunnels ?? this.tunnels,
      snippets: snippets ?? this.snippets,
      searchQuery: searchQuery ?? this.searchQuery,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }

  List<HostDto> get filteredHosts {
    final q = searchQuery.trim().toLowerCase();
    if (q.isEmpty) return hosts;
    return hosts.where((h) {
      return h.label.toLowerCase().contains(q) ||
          h.hostname.toLowerCase().contains(q) ||
          h.envTag.toLowerCase().contains(q) ||
          h.tags.any((t) => t.toLowerCase().contains(q));
    }).toList();
  }
}

class InventoryController extends Notifier<InventoryState> {
  int _refreshVersion = 0;

  @override
  InventoryState build() => const InventoryState();

  CoreBackend get _be => ref.read(backendProvider);

  void clear() {
    _refreshVersion++;
    state = const InventoryState();
  }

  Future<void> refreshAll() async {
    if (!ref.mounted) return;
    final version = ++_refreshVersion;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final results = await Future.wait([
        _be.listGroups(),
        _be.listHosts(),
        _be.listCredentials(),
        _be.listIdentities(),
        _be.listProxies(),
        _be.listTunnels(),
        _be.listSnippets(),
      ]);
      if (!ref.mounted || version != _refreshVersion) return;
      state = state.copyWith(
        groups: results[0] as List<GroupDto>,
        hosts: results[1] as List<HostDto>,
        credentials: results[2] as List<CredentialDto>,
        identities: results[3] as List<IdentityDto>,
        proxies: results[4] as List<ProxyDto>,
        tunnels: results[5] as List<TunnelDto>,
        snippets: results[6] as List<SnippetDto>,
        loading: false,
        clearError: true,
      );
    } catch (e) {
      if (!ref.mounted || version != _refreshVersion) return;
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  void setSearch(String q) => state = state.copyWith(searchQuery: q);

  Future<void> saveGroup(GroupDto g) async {
    await _be.upsertGroup(g);
    await refreshAll();
  }

  Future<void> saveHost(HostDto h) async {
    await _be.upsertHost(h);
    await refreshAll();
  }

  Future<void> cloneHost(HostDto h) async {
    final copy = HostDto(
      id: 'host_${DateTime.now().microsecondsSinceEpoch}',
      groupId: h.groupId,
      label: '${h.label} (Copy)',
      protocol: h.protocol,
      hostname: h.hostname,
      port: h.port,
      identityMode: h.identityMode,
      identityId: h.identityId,
      identityNameRef: h.identityNameRef,
      jumpHostMode: h.jumpHostMode,
      jumpHostId: h.jumpHostId,
      proxyMode: h.proxyMode,
      proxyId: h.proxyId,
      colorHex: h.colorHex,
      icon: h.icon,
      envTag: h.envTag,
      tags: List.of(h.tags),
      notes: h.notes,
      startupDir: h.startupDir,
      startupCmd: h.startupCmd,
      env: List.of(h.env),
      followTerminalSftp: h.followTerminalSftp,
      wolMac: h.wolMac,
      wolBroadcast: h.wolBroadcast,
      serialBaudrate: h.serialBaudrate,
      serialDataBits: h.serialDataBits,
      serialParity: h.serialParity,
      serialStopBits: h.serialStopBits,
      serialFlowControl: h.serialFlowControl,
      remoteDesktopJson: h.remoteDesktopJson,
      isFavorite: h.isFavorite,
      lastConnectedAt: null,
    );
    await saveHost(copy);
  }

  Future<void> removeHost(String id) async {
    await _be.deleteHost(id);
    if (!ref.mounted) return;
    // The delete is committed even if reloading another collection fails.
    state = state.copyWith(
      hosts: state.hosts.where((host) => host.id != id).toList(),
    );
    await refreshAll();
  }

  Future<void> deleteProxy(String id) async {
    await _be.deleteProxy(id);
    await refreshAll();
  }

  Future<void> saveCredentialAndIdentity({
    required CredentialDto cred,
    required IdentityDto identity,
  }) async {
    await _be.upsertCredential(cred);
    await _be.upsertIdentity(identity);
    await refreshAll();
  }

  Future<void> saveTunnel(TunnelDto t) async {
    await _be.upsertTunnel(t);
    await refreshAll();
  }

  Future<void> removeTunnel(String id) async {
    await _be.deleteTunnel(id);
    await refreshAll();
  }

  Future<void> saveSnippet(SnippetDto s) async {
    await _be.upsertSnippet(s);
    await refreshAll();
  }

  Future<void> removeSnippet(String id) async {
    await _be.deleteSnippet(id);
    await refreshAll();
  }
}

final inventoryProvider = NotifierProvider<InventoryController, InventoryState>(
  InventoryController.new,
);

// --- Terminal Sessions, Split, Follow-Terminal SFTP, Broadcast, Transfers ---
enum SplitMode { single, horizontal, vertical, quad }

class TransferJobState {
  final String transferId;
  final String fileName;
  final bool isUpload;
  final int bytesDone;
  final int bytesTotal;
  final bool finished;
  final bool paused;
  final bool cancelled;
  final String? error;

  const TransferJobState({
    required this.transferId,
    required this.fileName,
    required this.isUpload,
    this.bytesDone = 0,
    this.bytesTotal = 0,
    this.finished = false,
    this.paused = false,
    this.cancelled = false,
    this.error,
  });

  TransferJobState copyWith({
    int? bytesDone,
    int? bytesTotal,
    bool? finished,
    bool? paused,
    bool? cancelled,
    String? error,
    bool clearError = false,
  }) {
    return TransferJobState(
      transferId: transferId,
      fileName: fileName,
      isUpload: isUpload,
      bytesDone: bytesDone ?? this.bytesDone,
      bytesTotal: bytesTotal ?? this.bytesTotal,
      finished: finished ?? this.finished,
      paused: paused ?? this.paused,
      cancelled: cancelled ?? this.cancelled,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class TerminalSessionTab {
  final String localKey;
  final String? sessionId;
  final String? hostId;
  final String title;
  final bool titlePinned;
  final String envTag;
  final String protocol;
  final Terminal terminal;
  final TerminalController controller;
  final String cwd;
  final String terminalCwd;
  final bool followSftpEnabled;
  final bool bidirectionalSftp;
  final bool sftpLoading;
  final List<SftpEntryDto> sftpEntries;
  final String? sftpError;
  final String? sftpUnavailableReason;
  final bool broadcastIncluded;
  final bool closed;
  final String? closeReason;
  final HostMetricsDto? metrics;
  final String? agentAlert;
  final bool inputCtrl;
  final bool inputAlt;
  final RemoteDesktopSession? remoteDesktop;

  bool get isRemoteDesktop => protocol == 'rdp' || protocol == 'vnc';

  TerminalSessionTab({
    required this.localKey,
    this.sessionId,
    this.hostId,
    required this.title,
    this.titlePinned = false,
    required this.envTag,
    required this.protocol,
    required this.terminal,
    required this.controller,
    this.cwd = '~',
    String? terminalCwd,
    this.followSftpEnabled = true,
    this.bidirectionalSftp = true,
    this.sftpLoading = false,
    this.sftpEntries = const [],
    this.sftpError,
    this.sftpUnavailableReason,
    this.broadcastIncluded = true,
    this.closed = false,
    this.closeReason,
    this.metrics,
    this.agentAlert,
    this.inputCtrl = false,
    this.inputAlt = false,
    this.remoteDesktop,
  }) : terminalCwd = terminalCwd ?? cwd;

  TerminalSessionTab copyWith({
    String? sessionId,
    bool clearSessionId = false,
    String? title,
    bool? titlePinned,
    String? protocol,
    String? envTag,
    String? cwd,
    String? terminalCwd,
    bool? followSftpEnabled,
    bool? bidirectionalSftp,
    bool? sftpLoading,
    List<SftpEntryDto>? sftpEntries,
    String? sftpError,
    bool clearSftpError = false,
    String? sftpUnavailableReason,
    bool clearSftpUnavailableReason = false,
    bool? broadcastIncluded,
    bool? closed,
    String? closeReason,
    bool clearCloseReason = false,
    HostMetricsDto? metrics,
    bool clearMetrics = false,
    String? agentAlert,
    bool clearAlert = false,
    bool? inputCtrl,
    bool? inputAlt,
  }) {
    return TerminalSessionTab(
      localKey: localKey,
      sessionId: clearSessionId ? null : (sessionId ?? this.sessionId),
      hostId: hostId,
      title: title ?? this.title,
      titlePinned: titlePinned ?? this.titlePinned,
      envTag: envTag ?? this.envTag,
      protocol: protocol ?? this.protocol,
      terminal: terminal,
      controller: controller,
      cwd: cwd ?? this.cwd,
      terminalCwd: terminalCwd ?? this.terminalCwd,
      followSftpEnabled: followSftpEnabled ?? this.followSftpEnabled,
      bidirectionalSftp: bidirectionalSftp ?? this.bidirectionalSftp,
      sftpLoading: sftpLoading ?? this.sftpLoading,
      sftpEntries: sftpEntries ?? this.sftpEntries,
      sftpError: clearSftpError ? null : (sftpError ?? this.sftpError),
      sftpUnavailableReason: clearSftpUnavailableReason
          ? null
          : (sftpUnavailableReason ?? this.sftpUnavailableReason),
      broadcastIncluded: broadcastIncluded ?? this.broadcastIncluded,
      closed: closed ?? this.closed,
      closeReason: clearCloseReason ? null : (closeReason ?? this.closeReason),
      metrics: clearMetrics ? null : (metrics ?? this.metrics),
      agentAlert: clearAlert ? null : (agentAlert ?? this.agentAlert),
      inputCtrl: inputCtrl ?? this.inputCtrl,
      inputAlt: inputAlt ?? this.inputAlt,
      remoteDesktop: remoteDesktop,
    );
  }
}

class WorkspaceState {
  final List<TerminalSessionTab> tabs;
  final int activeIndex;
  final SplitMode splitMode;
  final bool broadcastMode;
  final bool showSftpPanel;
  final bool showOverview;
  final List<TransferJobState> transfers;
  final List<TunnelStatusDto> tunnelStatuses;
  final String? lastError;

  const WorkspaceState({
    this.tabs = const [],
    this.activeIndex = 0,
    this.splitMode = SplitMode.single,
    this.broadcastMode = false,
    this.showSftpPanel = true,
    this.showOverview = false,
    this.transfers = const [],
    this.tunnelStatuses = const [],
    this.lastError,
  });

  TerminalSessionTab? get activeTab =>
      tabs.isEmpty ? null : tabs[activeIndex.clamp(0, tabs.length - 1)];

  List<TerminalSessionTab> get broadcastTargets => tabs
      .where(
        (t) =>
            !t.isRemoteDesktop &&
            !t.closed &&
            t.broadcastIncluded &&
            t.sessionId != null,
      )
      .toList();

  bool get broadcastIncludesProd =>
      broadcastTargets.any((t) => t.envTag.toLowerCase() == 'prod');

  WorkspaceState copyWith({
    List<TerminalSessionTab>? tabs,
    int? activeIndex,
    SplitMode? splitMode,
    bool? broadcastMode,
    bool? showSftpPanel,
    bool? showOverview,
    List<TransferJobState>? transfers,
    List<TunnelStatusDto>? tunnelStatuses,
    String? lastError,
    bool clearError = false,
  }) {
    return WorkspaceState(
      tabs: tabs ?? this.tabs,
      activeIndex: activeIndex ?? this.activeIndex,
      splitMode: splitMode ?? this.splitMode,
      broadcastMode: broadcastMode ?? this.broadcastMode,
      showSftpPanel: showSftpPanel ?? this.showSftpPanel,
      showOverview: showOverview ?? this.showOverview,
      transfers: transfers ?? this.transfers,
      tunnelStatuses: tunnelStatuses ?? this.tunnelStatuses,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

class _TerminalTextSink extends StringConversionSinkBase {
  final void Function(String) onText;

  _TerminalTextSink(this.onText);

  @override
  void add(String str) => onText(str);

  @override
  void addSlice(String str, int start, int end, bool isLast) {
    onText(str.substring(start, end));
    if (isLast) close();
  }

  @override
  void close() {}
}

class SessionManagerController extends Notifier<WorkspaceState> {
  final Map<String, RemoteDesktopSession> _desktopSessions = {};
  final Map<String, StreamSubscription<TerminalEventDto>> _subs = {};
  final Map<String, Stream<TerminalEventDto> Function()> _connectionFactories =
      {};
  final Map<String, String> _connectionStartDirectories = {};
  final Set<String> _reconnecting = {};
  final Map<String, Timer> _cwdDebounces = {};
  final Map<String, int> _sftpRequests = {};
  final Map<String, ByteConversionSink> _outputDecoders = {};
  final Map<String, Future<void>> _inputQueues = {};
  final Map<int, StreamSubscription<TransferProgressDto>> _transferSubs = {};
  final Map<String, Future<void>> _transferControlQueues = {};
  final Set<String> _metricsPending = {};
  final Set<String> _knownSessionIds = {};
  int _transferSequence = 0;
  int _tunnelRequest = 0;

  @override
  WorkspaceState build() {
    final backend = ref.read(backendProvider);
    final logStore = ref.read(sessionLogStoreProvider);
    ref.listen(settingsProvider.select((settings) => settings.language), (
      _,
      language,
    ) {
      unawaited(ForegroundBridge.syncLanguage(language));
    });
    ref.onDispose(() {
      for (final session in _desktopSessions.values) {
        session.dispose();
      }
      _desktopSessions.clear();
      unawaited(logStore.closeAll());
      for (final timer in _cwdDebounces.values) {
        timer.cancel();
      }
      _cwdDebounces.clear();
      for (final s in _subs.values) {
        unawaited(s.cancel().catchError((Object _) {}));
      }
      _subs.clear();
      _connectionFactories.clear();
      _connectionStartDirectories.clear();
      _reconnecting.clear();
      for (final s in _transferSubs.values) {
        unawaited(s.cancel().catchError((Object _) {}));
      }
      _transferSubs.clear();
      _transferControlQueues.clear();
      for (final decoder in _outputDecoders.values) {
        decoder.close();
      }
      _outputDecoders.clear();
      _inputQueues.clear();
      for (final id in _knownSessionIds) {
        unawaited(
          Future<void>.sync(
            () => backend.closeSession(id),
          ).catchError((Object _) {}),
        );
      }
      _knownSessionIds.clear();
      unawaited(ForegroundBridge.syncActiveCount(0));
    });
    return const WorkspaceState();
  }

  CoreBackend get _be => ref.read(backendProvider);

  void _updateTab(
    String localKey,
    TerminalSessionTab Function(TerminalSessionTab) fn,
  ) {
    if (!ref.mounted || !state.tabs.any((t) => t.localKey == localKey)) return;
    final next = state.tabs
        .map((t) => t.localKey == localKey ? fn(t) : t)
        .toList();
    state = state.copyWith(tabs: next);
  }

  void _syncForeground() {
    final activeCount = state.tabs.where((t) => !t.closed).length;
    unawaited(
      ForegroundBridge.syncActiveCount(
        activeCount,
        language: ref.read(settingsProvider).language,
      ),
    );
  }

  TerminalSessionTab? _tab(String localKey) =>
      state.tabs.where((t) => t.localKey == localKey).firstOrNull;

  void _recordError(Object error) {
    if (ref.mounted) state = state.copyWith(lastError: error.toString());
  }

  void clearError() => state = state.copyWith(clearError: true);

  void setInputModifiers({required bool ctrl, required bool alt}) {
    final tab = state.activeTab;
    if (tab == null || (tab.inputCtrl == ctrl && tab.inputAlt == alt)) return;
    _updateTab(tab.localKey, (t) => t.copyWith(inputCtrl: ctrl, inputAlt: alt));
  }

  String _consumeInputModifiers(TerminalSessionTab tab, String data) {
    if (!tab.inputCtrl && !tab.inputAlt) return data;
    _updateTab(
      tab.localKey,
      (t) => t.copyWith(inputCtrl: false, inputAlt: false),
    );
    var result = data;
    if (tab.inputCtrl && data.length == 1) {
      final code = data.codeUnitAt(0);
      if ((code >= 64 && code <= 95) || (code >= 97 && code <= 122)) {
        result = String.fromCharCode(code & 0x1f);
      } else if (data == ' ') {
        result = '\x00';
      } else if (data == '?') {
        result = '\x7f';
      }
    }
    return tab.inputAlt ? '\x1b$result' : result;
  }

  Future<bool> _queueInput(
    List<String> sessionIds,
    List<int> bytes, {
    bool broadcast = false,
    bool Function()? validateBeforeSend,
  }) => _queueInputGroups(
    [(sessionIds: sessionIds, bytes: bytes)],
    broadcast: broadcast,
    validateBeforeSend: validateBeforeSend,
  );

  Future<bool> _queueInputGroups(
    List<({List<String> sessionIds, List<int> bytes})> groups, {
    bool broadcast = false,
    bool Function()? validateBeforeSend,
  }) {
    final targets = groups.expand((group) => group.sessionIds).toSet().toList();
    if (targets.isEmpty) return Future.value(false);
    if (groups.every((group) => group.bytes.isEmpty)) return Future.value(true);
    final pending = targets
        .map((id) => _inputQueues[id] ?? Future<void>.value())
        .toList();
    final operation = Future.wait(pending)
        .then<bool>((_) async {
          if (!ref.mounted) return false;
          if (validateBeforeSend != null && !validateBeforeSend()) return false;
          final liveIds = targets
              .where(
                (id) => state.tabs.any((t) => t.sessionId == id && !t.closed),
              )
              .toList();
          if (liveIds.isEmpty) {
            _recordError('Phiên kết nối đã đóng trước khi gửi lệnh.');
            return false;
          }
          final liveTargets = liveIds.toSet();
          final results = await Future.wait(
            groups.map((group) async {
              if (group.bytes.isEmpty) return true;
              final groupTargets = group.sessionIds.toSet();
              final recipients = groupTargets
                  .where(liveTargets.contains)
                  .toList();
              if (recipients.isEmpty) {
                _recordError('Phiên kết nối đã đóng trước khi gửi lệnh.');
                return false;
              }
              if (broadcast) {
                final sent = await _be.broadcastSessionInput(
                  recipients,
                  group.bytes,
                );
                if (sent != groupTargets.length) {
                  _recordError(
                    'Chỉ gửi được tới $sent/${groupTargets.length} phiên đang phát đồng loạt.',
                  );
                  return false;
                }
              } else {
                await _be.sendSessionInput(recipients.single, group.bytes);
              }
              return true;
            }),
          );
          return results.every((sent) => sent);
        })
        .catchError((Object error) {
          _recordError(error);
          return false;
        });
    final queued = operation.then<void>((_) {});
    for (final id in targets) {
      _inputQueues[id] = queued;
    }
    unawaited(
      queued.then((_) {
        for (final id in targets) {
          if (identical(_inputQueues[id], queued)) _inputQueues.remove(id);
        }
      }),
    );
    return operation;
  }

  Future<void> _resizeSession(String localKey, int cols, int rows) async {
    final tab = _tab(localKey);
    if (tab == null ||
        tab.closed ||
        tab.sessionId == null ||
        cols <= 0 ||
        rows <= 0) {
      return;
    }
    try {
      await _be.resizeTerminal(tab.sessionId!, cols, rows);
    } catch (e) {
      _recordError(e);
    }
  }

  void _finishSession(String localKey, String reason, {bool isError = false}) {
    if (!ref.mounted) return;
    final tab = _tab(localKey);
    if (tab == null || tab.closed) return;
    unawaited(ref.read(sessionLogsProvider.notifier).stopSession(localKey));
    _cwdDebounces.remove(localKey)?.cancel();
    _sftpRequests[localKey] = (_sftpRequests[localKey] ?? 0) + 1;
    _outputDecoders.remove(localKey)?.close();
    _updateTab(
      localKey,
      (t) => t.copyWith(closed: true, closeReason: reason, sftpLoading: false),
    );
    tab.terminal.write(
      '\r\n[${isError ? translateAppMessage(ref.read(settingsProvider).language, "Lỗi kết nối") : "TermPulse"}] ${isError ? presentAppError(ref.read(settingsProvider).language, reason).summary : translateAppMessage(ref.read(settingsProvider).language, reason)}\r\n',
    );
    if (isError) _recordError(reason);
    _syncForeground();
  }

  Future<void> openHostSession(HostDto host) async {
    if (host.protocol == 'rdp' || host.protocol == 'vnc') {
      final localKey = 'desktop_${DateTime.now().microsecondsSinceEpoch}';
      late final RemoteDesktopSession desktop;
      desktop = RemoteDesktopSession(
        host: host,
        backend: ref.read(remoteDesktopBackendProvider),
        refreshHost: () async {
          final latest = (await _be.listHosts())
              .where((h) => h.id == host.id)
              .firstOrNull;
          if (latest == null) {
            throw StateError(
              'Kết nối đã bị xóa hoặc đổi giao thức. Hãy mở lại từ danh sách host.',
            );
          }
          return latest;
        },
        onStatusChanged: () {
          if (!ref.mounted) return;
          _updateTab(
            localKey,
            (tab) => tab.copyWith(
              title: tab.titlePinned ? tab.title : desktop.host.label,
              protocol: desktop.host.protocol,
              envTag: desktop.host.envTag,
              sessionId: desktop.sessionId,
              clearSessionId: desktop.sessionId == null,
              closed: desktop.closed,
              closeReason: desktop.message,
              clearCloseReason: desktop.message == null,
            ),
          );
          _syncForeground();
        },
      );
      _desktopSessions[localKey] = desktop;
      final tab = TerminalSessionTab(
        localKey: localKey,
        hostId: host.id,
        title: host.label,
        envTag: host.envTag,
        protocol: host.protocol,
        terminal: Terminal(maxLines: 1),
        controller: TerminalController(),
        followSftpEnabled: false,
        broadcastIncluded: false,
        sftpUnavailableReason: 'Màn hình từ xa không phải phiên SSH/SFTP.',
        remoteDesktop: desktop,
      );
      state = state.copyWith(
        tabs: [...state.tabs, tab],
        activeIndex: state.tabs.length,
        showOverview: false,
        clearError: true,
      );
      await desktop.connect();
      return;
    }
    if (host.protocol == 'serial') {
      await openSerial(
        SerialConfigDto(
          portName: host.hostname,
          baudRate: host.serialBaudrate ?? 115200,
          dataBits: host.serialDataBits ?? 8,
          parity: host.serialParity ?? 'none',
          stopBits: host.serialStopBits ?? 1,
          flowControl: host.serialFlowControl ?? 'none',
        ),
        label: host.label,
        hostId: host.id,
        envTag: host.envTag,
      );
      return;
    }
    if (host.protocol == 'local_shell') {
      await openLocalShell(
        startupDir: host.startupDir,
        title: host.label,
        envTag: host.envTag,
        hostId: host.id,
      );
      return;
    }
    if (host.protocol == 'telnet') {
      await openTelnet(
        host.hostname,
        host.port,
        label: host.label,
        envTag: host.envTag,
        hostId: host.id,
      );
      return;
    }
    if (host.protocol != 'ssh') {
      _recordError('Giao thức ${host.protocol} chưa được hỗ trợ.');
      return;
    }
    final localKey = 'tab_${DateTime.now().microsecondsSinceEpoch}';
    final term = Terminal(maxLines: 8000);
    final ctrl = TerminalController();
    final follow = host.followTerminalSftp ?? true;
    final tab = TerminalSessionTab(
      localKey: localKey,
      hostId: host.id,
      title: host.label,
      envTag: host.envTag,
      protocol: host.protocol,
      terminal: term,
      controller: ctrl,
      cwd: host.startupDir ?? '~',
      followSftpEnabled: follow,
    );
    _attachAndListen(
      tab: tab,
      streamFactory: () =>
          _be.connectSshHost(host.id, term.viewWidth, term.viewHeight),
    );
  }

  Future<void> openQuickSsh({
    required String target,
    String? password,
    String? privateKeyPem,
  }) async {
    final localKey = 'tab_${DateTime.now().microsecondsSinceEpoch}';
    final term = Terminal(maxLines: 8000);
    final ctrl = TerminalController();
    final tab = TerminalSessionTab(
      localKey: localKey,
      title: target,
      envTag: 'dev',
      protocol: 'ssh',
      terminal: term,
      controller: ctrl,
    );
    _attachAndListen(
      tab: tab,
      streamFactory: () => _be.connectQuickSsh(
        target: target,
        password: password,
        privateKeyPem: privateKeyPem,
        cols: term.viewWidth,
        rows: term.viewHeight,
      ),
    );
  }

  Future<void> openLocalShell({
    String? startupDir,
    String title = 'Local Shell',
    String envTag = 'dev',
    String? hostId,
  }) async {
    final localKey = 'tab_${DateTime.now().microsecondsSinceEpoch}';
    final term = Terminal(maxLines: 8000);
    final ctrl = TerminalController();
    final tab = TerminalSessionTab(
      localKey: localKey,
      hostId: hostId,
      title: title,
      envTag: envTag,
      protocol: 'local_shell',
      terminal: term,
      controller: ctrl,
      followSftpEnabled: false,
      sftpUnavailableReason: 'Phiên Local Shell không dùng SFTP',
    );
    _attachAndListen(
      tab: tab,
      streamFactory: () => _be.connectLocalShell(
        cols: term.viewWidth,
        rows: term.viewHeight,
        startupDir: startupDir,
      ),
    );
  }

  Future<void> openTelnet(
    String hostname,
    int port, {
    String? label,
    String envTag = 'dev',
    String? hostId,
  }) async {
    final localKey = 'tab_${DateTime.now().microsecondsSinceEpoch}';
    final term = Terminal(maxLines: 8000);
    final ctrl = TerminalController();
    final tab = TerminalSessionTab(
      localKey: localKey,
      hostId: hostId,
      title: label ?? 'Telnet $hostname',
      envTag: envTag,
      protocol: 'telnet',
      terminal: term,
      controller: ctrl,
      followSftpEnabled: false,
      sftpUnavailableReason: 'Telnet không hỗ trợ SFTP',
    );
    _attachAndListen(
      tab: tab,
      streamFactory: () =>
          _be.connectTelnetHost(hostname: hostname, port: port, label: label),
    );
  }

  Future<void> openSerial(
    SerialConfigDto config, {
    String? label,
    String? hostId,
    String envTag = 'dev',
  }) async {
    if (!_be.serialSupported()) {
      _recordError('USB Serial không khả dụng trên thiết bị này.');
      return;
    }
    final terminal = Terminal(maxLines: 8000);
    final tab = TerminalSessionTab(
      localKey: 'tab_${DateTime.now().microsecondsSinceEpoch}',
      hostId: hostId,
      title: label ?? 'Serial ${config.portName} · ${config.baudRate} baud',
      envTag: envTag,
      protocol: 'serial',
      terminal: terminal,
      controller: TerminalController(),
      cwd: '/',
      followSftpEnabled: false,
      sftpUnavailableReason: 'Kết nối Serial không hỗ trợ SFTP.',
    );
    _attachAndListen(
      tab: tab,
      streamFactory: () =>
          _be.connectSerial(config: config, label: label, hostId: hostId),
    );
  }

  void _attachAndListen({
    required TerminalSessionTab tab,
    required Stream<TerminalEventDto> Function() streamFactory,
  }) {
    _connectionFactories[tab.localKey] = streamFactory;
    _connectionStartDirectories.putIfAbsent(
      tab.localKey,
      () => tab.terminalCwd,
    );
    final existingIndex = state.tabs.indexWhere(
      (current) => current.localKey == tab.localKey,
    );
    final nextTabs = existingIndex < 0
        ? [...state.tabs, tab]
        : state.tabs
              .map(
                (current) => current.localKey == tab.localKey ? tab : current,
              )
              .toList();
    state = state.copyWith(
      tabs: nextTabs,
      activeIndex: existingIndex < 0 ? nextTabs.length - 1 : existingIndex,
      showOverview: false,
      clearError: true,
    );
    _syncForeground();
    _outputDecoders[tab.localKey] = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(_TerminalTextSink(tab.terminal.write));

    tab.terminal.onOutput = (data) {
      if (!ref.mounted) return;
      final current = _tab(tab.localKey);
      final sid = current?.sessionId;
      if (sid == null || current!.closed) return;
      final bytes = utf8.encode(_consumeInputModifiers(current, data));
      if (state.broadcastMode && current.broadcastIncluded) {
        final targets = state.broadcastTargets
            .map((t) => t.sessionId!)
            .toList();
        if (targets.isNotEmpty) {
          unawaited(_queueInput(targets, bytes, broadcast: true));
          return;
        }
      }
      unawaited(_queueInput([sid], bytes));
    };

    tab.terminal.onResize = (w, h, pw, ph) {
      if (ref.mounted) unawaited(_resizeSession(tab.localKey, w, h));
    };

    try {
      final sub = streamFactory().listen(
        (ev) {
          if (!ref.mounted || _tab(tab.localKey) == null) return;
          switch (ev.kind) {
            case 'session_opened':
              final sid = ev.text ?? '';
              if (sid.isEmpty) {
                _finishSession(
                  tab.localKey,
                  'Máy chủ không trả về mã phiên kết nối.',
                  isError: true,
                );
                return;
              }
              _knownSessionIds.add(sid);
              _updateTab(tab.localKey, (t) => t.copyWith(sessionId: sid));
              unawaited(
                _resizeSession(
                  tab.localKey,
                  tab.terminal.viewWidth,
                  tab.terminal.viewHeight,
                ),
              );
              if (tab.followSftpEnabled && tab.protocol == 'ssh') {
                unawaited(loadSftpDirectory(tab.localKey, tab.cwd));
              }
            case 'output_bytes':
              if (ev.bytes != null) {
                ref
                    .read(sessionLogsProvider.notifier)
                    .append(tab.localKey, ev.bytes!);
                _outputDecoders[tab.localKey]?.add(ev.bytes!);
              }
            case 'cwd_changed':
              final cwd = ev.text ?? '~';
              _updateTab(
                tab.localKey,
                (t) => t.copyWith(
                  terminalCwd: cwd,
                  cwd: t.followSftpEnabled ? cwd : null,
                ),
              );
              final cur = _tab(tab.localKey);
              if (cur != null &&
                  cur.followSftpEnabled &&
                  cur.sessionId != null) {
                _sftpRequests[tab.localKey] =
                    (_sftpRequests[tab.localKey] ?? 0) + 1;
                _cwdDebounces.remove(tab.localKey)?.cancel();
                _cwdDebounces[tab.localKey] = Timer(
                  const Duration(milliseconds: 250),
                  () {
                    _cwdDebounces.remove(tab.localKey);
                    if (ref.mounted) {
                      unawaited(loadSftpDirectory(tab.localKey, cwd));
                    }
                  },
                );
              }
            case 'title_changed':
              _updateTab(
                tab.localKey,
                (t) =>
                    t.titlePinned ? t : t.copyWith(title: ev.text ?? tab.title),
              );
            case 'agent_notification':
              _updateTab(
                tab.localKey,
                (t) => t.copyWith(
                  agentAlert: '${ev.title ?? "TermPulse"}: ${ev.text ?? ""}',
                ),
              );
            case 'zmodem':
              _updateTab(
                tab.localKey,
                (t) => t.copyWith(agentAlert: 'Phát hiện tín hiệu ZMODEM'),
              );
            case 'trzsz':
              _updateTab(
                tab.localKey,
                (t) => t.copyWith(agentAlert: 'Phát hiện tín hiệu trzsz'),
              );
            case 'sftp_unavailable':
              _updateTab(
                tab.localKey,
                (t) => t.copyWith(
                  sftpUnavailableReason:
                      ev.text ?? 'SFTP không khả dụng cho phiên này.',
                  sftpLoading: false,
                ),
              );
            case 'closed':
              _finishSession(tab.localKey, ev.text ?? 'Phiên đã kết thúc');
          }
        },
        onError: (err) {
          _finishSession(tab.localKey, err.toString(), isError: true);
        },
        onDone: () {
          _subs.remove(tab.localKey);
          _finishSession(tab.localKey, 'Luồng kết nối đã kết thúc.');
        },
        cancelOnError: true,
      );
      _subs[tab.localKey] = sub;
    } catch (e) {
      _finishSession(tab.localKey, e.toString(), isError: true);
    }
  }

  void setActiveTab(int index) {
    if (index < 0 || index >= state.tabs.length) return;
    state = state.copyWith(activeIndex: index, showOverview: false);
    final tab = state.tabs[index];
    if (!tab.closed &&
        tab.followSftpEnabled &&
        tab.sessionId != null &&
        tab.sftpEntries.isEmpty &&
        !tab.sftpLoading &&
        tab.sftpUnavailableReason == null) {
      unawaited(loadSftpDirectory(tab.localKey, tab.cwd));
    }
  }

  void renameTab(String localKey, String title) {
    final value = title.trim();
    if (value.isEmpty || value.length > 80) return;
    _updateTab(
      localKey,
      (tab) => tab.copyWith(title: value, titlePinned: true),
    );
  }

  void moveTab(String localKey, int targetIndex) {
    final source = state.tabs.indexWhere((tab) => tab.localKey == localKey);
    if (source < 0 ||
        targetIndex < 0 ||
        targetIndex >= state.tabs.length ||
        source == targetIndex) {
      return;
    }
    final activeKey = state.activeTab?.localKey;
    final tabs = [...state.tabs];
    final tab = tabs.removeAt(source);
    tabs.insert(targetIndex, tab);
    state = state.copyWith(
      tabs: tabs,
      activeIndex: tabs.indexWhere((tab) => tab.localKey == activeKey),
    );
  }

  Future<void> disconnectTab(String localKey) async {
    final tab = _tab(localKey);
    if (tab == null || tab.closed) return;
    if (tab.remoteDesktop != null) {
      await tab.remoteDesktop!.close();
      return;
    }
    final backend = _be;
    _finishSession(localKey, 'Đã ngắt kết nối theo yêu cầu.');
    try {
      await _subs.remove(localKey)?.cancel();
      if (tab.sessionId != null) {
        await backend.closeSession(tab.sessionId!);
        _knownSessionIds.remove(tab.sessionId);
      }
    } catch (error) {
      _recordError(error);
    }
  }

  Future<void> closeAllSessions() async {
    for (final key in state.tabs.map((tab) => tab.localKey).toList()) {
      await closeTab(key);
    }
    if (ref.mounted) state = const WorkspaceState();
  }

  Future<void> closeTab(String localKey) async {
    final tab = _tab(localKey);
    if (tab == null) return;
    final activeKey = state.activeTab?.localKey;
    final removedIndex = state.tabs.indexOf(tab);
    final remaining = state.tabs.where((t) => t.localKey != localKey).toList();
    final retainedIndex = remaining.indexWhere((t) => t.localKey == activeKey);
    final nextIdx = remaining.isEmpty
        ? 0
        : (retainedIndex >= 0
              ? retainedIndex
              : removedIndex.clamp(0, remaining.length - 1));
    state = state.copyWith(tabs: remaining, activeIndex: nextIdx);
    _cwdDebounces.remove(localKey)?.cancel();
    _sftpRequests.remove(localKey);
    _connectionFactories.remove(localKey);
    _connectionStartDirectories.remove(localKey);
    _outputDecoders.remove(localKey)?.close();
    tab.terminal.onOutput = null;
    tab.terminal.onResize = null;
    await ref.read(sessionLogsProvider.notifier).stopSession(localKey);
    _syncForeground();
    final desktop = _desktopSessions.remove(localKey);
    if (desktop != null) {
      await desktop.close();
      desktop.dispose();
      return;
    }
    final subscription = _subs.remove(localKey);
    try {
      if (tab.sessionId != null) {
        await _be.closeSession(tab.sessionId!);
        _knownSessionIds.remove(tab.sessionId);
      }
    } catch (e) {
      _recordError(e);
    } finally {
      try {
        await subscription?.cancel();
      } catch (e) {
        _recordError(e);
      }
    }
  }

  Future<bool> reconnectTab(String localKey) async {
    final tab = _tab(localKey);
    if (tab?.remoteDesktop != null && tab!.closed) {
      await tab.remoteDesktop!.connect();
      return true;
    }
    final connect = _connectionFactories[localKey];
    if (tab == null ||
        !tab.closed ||
        connect == null ||
        !_reconnecting.add(localKey)) {
      return false;
    }
    try {
      await _subs.remove(localKey)?.cancel();
      if (tab.sessionId != null) {
        try {
          await _be.closeSession(tab.sessionId!);
          _knownSessionIds.remove(tab.sessionId);
        } catch (error) {
          _recordError(error);
        }
      }
      if (!ref.mounted || _tab(localKey) == null) return false;
      final current = _tab(localKey)!;
      if (!current.closed) return false;
      final terminal = current.terminal;
      terminal.useMainBuffer();
      terminal.clearAltBuffer();
      terminal.setInsertMode(false);
      terminal.setLineFeedMode(false);
      terminal.setCursorKeysMode(false);
      terminal.setReverseDisplayMode(false);
      terminal.setOriginMode(false);
      terminal.setAutoWrapMode(true);
      terminal.setMouseMode(MouseMode.none);
      terminal.setMouseReportMode(MouseReportMode.normal);
      terminal.setCursorBlinkMode(false);
      terminal.setCursorVisibleMode(true);
      terminal.setAppKeypadMode(false);
      terminal.setReportFocusMode(false);
      terminal.setAltBufferMouseScrollMode(false);
      terminal.setBracketedPasteMode(false);
      terminal.resetCursorStyle();
      terminal.write(
        '\r\n[TermPulse] ${translateAppMessage(ref.read(settingsProvider).language, "Đang kết nối lại…")}\r\n',
      );
      final startupDirectory = _connectionStartDirectories[localKey] ?? '~';
      _attachAndListen(
        tab: current.copyWith(
          clearSessionId: true,
          closed: false,
          clearCloseReason: true,
          clearMetrics: true,
          clearAlert: true,
          clearSftpError: true,
          clearSftpUnavailableReason: current.protocol == 'ssh',
          terminalCwd: startupDirectory,
          cwd: current.followSftpEnabled ? startupDirectory : current.cwd,
          sftpEntries: const [],
          sftpLoading: false,
          inputCtrl: false,
          inputAlt: false,
        ),
        streamFactory: connect,
      );
      return true;
    } catch (error) {
      _recordError(error);
      return false;
    } finally {
      _reconnecting.remove(localKey);
    }
  }

  void setSplitMode(SplitMode mode) => state = state.copyWith(splitMode: mode);
  void toggleBroadcast() =>
      state = state.copyWith(broadcastMode: !state.broadcastMode);
  void toggleSftpPanel() =>
      state = state.copyWith(showSftpPanel: !state.showSftpPanel);
  void toggleOverview() =>
      state = state.copyWith(showOverview: !state.showOverview);

  void toggleTabBroadcast(String localKey) {
    _updateTab(
      localKey,
      (t) => t.isRemoteDesktop
          ? t
          : t.copyWith(broadcastIncluded: !t.broadcastIncluded),
    );
  }

  void toggleFollowSftp(String localKey) {
    if (_tab(localKey)?.protocol != 'ssh') return;
    _cwdDebounces.remove(localKey)?.cancel();
    _sftpRequests[localKey] = (_sftpRequests[localKey] ?? 0) + 1;
    _updateTab(
      localKey,
      (t) => t.copyWith(
        followSftpEnabled: !t.followSftpEnabled,
        sftpLoading: false,
      ),
    );
    final tab = _tab(localKey);
    if (tab?.followSftpEnabled ?? false) {
      unawaited(loadSftpDirectory(localKey, tab!.terminalCwd));
    }
  }

  void toggleBidirectionalSftp(String localKey) {
    _updateTab(
      localKey,
      (t) => t.copyWith(bidirectionalSftp: !t.bidirectionalSftp),
    );
  }

  void clearTabAlert(String localKey) {
    _updateTab(localKey, (t) => t.copyWith(clearAlert: true));
  }

  Future<bool> sendTextToActive(
    String text, {
    bool broadcastIfEnabled = false,
    bool bracketedPaste = false,
    String? expectedActiveKey,
    List<String>? expectedSessionIds,
    bool? expectedBroadcastMode,
    bool Function()? validateBeforeSend,
  }) async {
    final tab = state.activeTab;
    if (tab == null ||
        tab.isRemoteDesktop ||
        tab.sessionId == null ||
        tab.closed) {
      _recordError('Không có phiên kết nối đang hoạt động để gửi lệnh.');
      return false;
    }
    final broadcast = broadcastIfEnabled && state.broadcastMode;
    final targets = broadcast
        ? state.broadcastTargets.map((t) => t.sessionId!).toList()
        : [tab.sessionId!];
    final expectedTargets = expectedSessionIds?.toSet();

    bool validateSnapshot() {
      final current = state.activeTab;
      final currentTargets = broadcastIfEnabled && state.broadcastMode
          ? state.broadcastTargets.map((t) => t.sessionId!).toSet()
          : {
              if (current != null &&
                  !current.closed &&
                  current.sessionId != null)
                current.sessionId!,
            };
      if ((expectedActiveKey != null &&
              current?.localKey != expectedActiveKey) ||
          (expectedBroadcastMode != null &&
              state.broadcastMode != expectedBroadcastMode) ||
          (expectedTargets != null &&
              (expectedTargets.length != currentTargets.length ||
                  !expectedTargets.containsAll(currentTargets)))) {
        _recordError(
          'Phiên hoặc danh sách nhận lệnh đã thay đổi. Vui lòng kiểm tra và xác nhận lại lệnh.',
        );
        return false;
      }
      if (validateBeforeSend != null && !validateBeforeSend()) return false;
      return true;
    }

    if (!validateSnapshot()) return false;
    // A prior write may keep this command queued while its confirmed targets
    // change. Recheck immediately before dispatch rather than partially sending.
    final validateTargetsBeforeSend =
        expectedActiveKey != null ||
            expectedSessionIds != null ||
            expectedBroadcastMode != null ||
            validateBeforeSend != null
        ? validateSnapshot
        : null;
    if (broadcast) {
      if (targets.isEmpty) {
        _recordError('Chưa có phiên nào được chọn để phát lệnh đồng loạt.');
        return false;
      }
    }
    if (bracketedPaste) {
      final groups = <String, List<String>>{};
      for (final sessionId in targets) {
        final terminal = state.tabs
            .firstWhere((target) => target.sessionId == sessionId)
            .terminal;
        final payload = terminal.bracketedPasteMode
            ? '\x1b[200~$text\x1b[201~'
            : text;
        groups.putIfAbsent(payload, () => []).add(sessionId);
      }
      // Reserve all recipient queues as one operation so a group with a
      // different terminal paste mode cannot bypass another recipient's input.
      return _queueInputGroups(
        [
          for (final group in groups.entries)
            (sessionIds: group.value, bytes: utf8.encode(group.key)),
        ],
        broadcast: broadcast,
        validateBeforeSend: validateTargetsBeforeSend,
      );
    }
    return _queueInput(
      targets,
      utf8.encode(text),
      broadcast: broadcast,
      validateBeforeSend: validateTargetsBeforeSend,
    );
  }

  Future<void> loadSftpDirectory(
    String localKey,
    String path, {
    bool syncTerminal = false,
  }) async {
    final tab = _tab(localKey);
    if (tab == null ||
        tab.sessionId == null ||
        tab.closed ||
        tab.protocol != 'ssh' ||
        tab.sftpUnavailableReason != null) {
      return;
    }
    _cwdDebounces.remove(localKey)?.cancel();
    final request = (_sftpRequests[localKey] ?? 0) + 1;
    _sftpRequests[localKey] = request;
    _updateTab(
      localKey,
      (t) => t.copyWith(sftpLoading: true, clearSftpError: true),
    );
    try {
      final listing = await _be.sftpListDirectory(tab.sessionId!, path);
      if (!ref.mounted || _sftpRequests[localKey] != request) return;
      final current = _tab(localKey);
      if (current == null ||
          current.closed ||
          current.sftpUnavailableReason != null ||
          current.sessionId != tab.sessionId) {
        return;
      }
      _updateTab(
        localKey,
        (t) => t.copyWith(
          cwd: listing.cwd,
          sftpEntries: listing.entries,
          sftpLoading: false,
          clearSftpError: true,
        ),
      );
      if (syncTerminal && current.bidirectionalSftp) {
        final escaped = listing.cwd.replaceAll("'", "'\\''");
        await _queueInput([tab.sessionId!], utf8.encode("cd '$escaped'\n"));
      }
    } catch (e) {
      if (!ref.mounted || _sftpRequests[localKey] != request) return;
      _updateTab(
        localKey,
        (t) => t.copyWith(sftpLoading: false, sftpError: e.toString()),
      );
    }
  }

  Future<void> enqueueTransfer({
    required String localKey,
    required bool isUpload,
    required String localPath,
    required String remotePath,
    required String fileName,
  }) async {
    final tab = _tab(localKey);
    if (tab == null ||
        tab.closed ||
        tab.sessionId == null ||
        tab.protocol != 'ssh' ||
        tab.sftpUnavailableReason != null) {
      return;
    }
    final token = ++_transferSequence;
    String? transferId;
    var finished = false;

    void fail(Object error) {
      if (!ref.mounted || finished) return;
      if (state.transfers.any(
        (job) => job.transferId == transferId && job.finished,
      )) {
        finished = true;
        return;
      }
      finished = true;
      final id = transferId ?? 'failed_transfer_$token';
      final exists = state.transfers.any((job) => job.transferId == id);
      state = state.copyWith(
        lastError: error.toString(),
        transfers: exists
            ? state.transfers
                  .map(
                    (job) => job.transferId == id
                        ? job.copyWith(
                            finished: true,
                            paused: false,
                            error: error.toString(),
                          )
                        : job,
                  )
                  .toList()
            : [
                TransferJobState(
                  transferId: id,
                  fileName: fileName,
                  isUpload: isUpload,
                  finished: true,
                  error: error.toString(),
                ),
                ...state.transfers,
              ],
      );
    }

    try {
      final subscription = _be
          .sftpStartTransfer(
            sessionId: tab.sessionId!,
            isUpload: isUpload,
            localPath: localPath,
            remotePath: remotePath,
          )
          .listen(
            (p) {
              if (!ref.mounted || finished) return;
              if (state.transfers.any(
                (job) => job.transferId == p.transferId && job.finished,
              )) {
                finished = true;
                return;
              }
              transferId = p.transferId;
              finished = p.finished || p.error != null;
              final exists = state.transfers.any(
                (x) => x.transferId == p.transferId,
              );
              if (!exists) {
                state = state.copyWith(
                  transfers: [
                    TransferJobState(
                      transferId: p.transferId,
                      fileName: fileName,
                      isUpload: isUpload,
                      bytesDone: p.bytesDone.toInt(),
                      bytesTotal: p.bytesTotal.toInt(),
                      finished: finished,
                      error: p.error,
                    ),
                    ...state.transfers,
                  ],
                );
              } else {
                state = state.copyWith(
                  transfers: state.transfers
                      .map(
                        (x) => x.transferId == p.transferId
                            ? x.copyWith(
                                bytesDone: p.bytesDone.toInt(),
                                bytesTotal: p.bytesTotal.toInt(),
                                finished: finished,
                                paused: finished ? false : x.paused,
                                error: p.error,
                                clearError: p.error == null,
                              )
                            : x,
                      )
                      .toList(),
                );
              }
              if (finished && p.error == null) {
                final current = _tab(localKey);
                if (current != null) {
                  unawaited(loadSftpDirectory(localKey, current.cwd));
                }
              }
            },
            onError: (Object error) {
              fail(error);
              _transferSubs.remove(token);
            },
            onDone: () {
              fail('Luồng truyền tệp kết thúc trước khi hoàn tất.');
              _transferSubs.remove(token);
            },
            cancelOnError: true,
          );
      _transferSubs[token] = subscription;
    } catch (e) {
      fail(e);
    }
  }

  Future<void> controlTransfer(String transferId, String action) {
    if (!const {'pause', 'resume', 'cancel'}.contains(action)) {
      _recordError('Thao tác truyền file không hợp lệ.');
      return Future.value();
    }
    final pending = _transferControlQueues[transferId] ?? Future<void>.value();
    final operation = pending.then((_) async {
      if (!ref.mounted) return;
      final job = state.transfers
          .where((job) => job.transferId == transferId)
          .firstOrNull;
      if (job == null || job.finished) return;
      try {
        await _be.sftpControlTransfer(transferId, action);
        if (!ref.mounted) return;
        state = state.copyWith(
          transfers: state.transfers
              .map(
                (x) => x.transferId == transferId && !x.finished
                    ? x.copyWith(
                        paused: action == 'pause',
                        finished: action == 'cancel',
                        cancelled: action == 'cancel',
                        clearError: true,
                      )
                    : x,
              )
              .toList(),
        );
      } catch (e) {
        _recordError(e);
      }
    });
    _transferControlQueues[transferId] = operation;
    unawaited(
      operation.then((_) {
        if (identical(_transferControlQueues[transferId], operation)) {
          _transferControlQueues.remove(transferId);
        }
      }),
    );
    return operation;
  }

  Future<void> refreshMetrics(String localKey) async {
    final tab = _tab(localKey);
    if (tab == null ||
        tab.closed ||
        tab.sessionId == null ||
        tab.protocol != 'ssh' ||
        !_metricsPending.add(localKey)) {
      return;
    }
    try {
      final m = await _be.pollSessionMetrics(tab.sessionId!);
      if (!ref.mounted ||
          _tab(localKey)?.sessionId != tab.sessionId ||
          (_tab(localKey)?.closed ?? true)) {
        return;
      }
      _updateTab(localKey, (t) => t.copyWith(metrics: m));
    } catch (e) {
      _recordError(e);
    } finally {
      _metricsPending.remove(localKey);
    }
  }

  Future<void> refreshTunnelStatuses() async {
    final request = ++_tunnelRequest;
    try {
      final list = await _be.listTunnelStatuses();
      if (!ref.mounted || request != _tunnelRequest) return;
      state = state.copyWith(tunnelStatuses: list);
    } catch (e) {
      if (request == _tunnelRequest) _recordError(e);
    }
  }

  Future<void> startTunnel(String tunnelId) async {
    try {
      await _be.startTunnelById(tunnelId);
      if (ref.mounted) await refreshTunnelStatuses();
    } catch (e) {
      _recordError(e);
    }
  }

  Future<void> stopTunnel(String tunnelId) async {
    try {
      await _be.stopTunnelById(tunnelId);
      if (ref.mounted) await refreshTunnelStatuses();
    } catch (e) {
      _recordError(e);
    }
  }
}

final sessionManagerProvider =
    NotifierProvider<SessionManagerController, WorkspaceState>(
      SessionManagerController.new,
    );
