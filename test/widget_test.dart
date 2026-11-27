import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/backend.dart';
import 'package:termpulse/features/terminal/command_guard_dialog.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/src/rust/api/serial_api.dart';
import 'package:termpulse/state/app_providers.dart';

class FakeCoreBackend implements CoreBackend {
  bool _initialized = false;
  bool _unlocked = false;
  final List<HostDto> hosts = [
    const HostDto(
      id: 'h_prod',
      label: 'prod-api-01',
      protocol: 'ssh',
      hostname: '10.0.1.10',
      port: 22,
      identityMode: 'inherit',
      jumpHostMode: 'inherit',
      proxyMode: 'inherit',
      envTag: 'prod',
      tags: ['api', 'eu'],
      notes: '',
      env: [],
      isFavorite: true,
    ),
    const HostDto(
      id: 'h_dev',
      label: 'dev-box',
      protocol: 'ssh',
      hostname: '192.168.1.50',
      port: 22,
      identityMode: 'inherit',
      jumpHostMode: 'inherit',
      proxyMode: 'inherit',
      envTag: 'dev',
      tags: [],
      notes: '',
      env: [],
      isFavorite: false,
    ),
  ];
  final List<SnippetDto> snippets = [
    const SnippetDto(
      id: 's1',
      scope: 'global',
      title: 'Docker PS',
      commandTpl: 'docker ps',
      pinButtonBar: true,
    ),
  ];
  final List<TunnelDto> tunnels = [
    const TunnelDto(
      id: 't1',
      name: 'Prod DB',
      hostId: 'h_prod',
      kind: 'local',
      bindAddr: '127.0.0.1',
      bindPort: 5432,
      targetHost: '127.0.0.1',
      targetPort: 5432,
      autoStart: false,
    ),
  ];

  final List<String> sentInputs = [];
  final List<List<String>> broadcastCalls = [];
  final List<ProxyDto> _proxies = [];

  @override
  Future<VaultStatusDto> vaultInitPath(String dbPath) async => VaultStatusDto(
    initialized: _initialized,
    unlocked: _unlocked,
    dbPath: dbPath,
  );

  @override
  Future<VaultStatusDto> vaultStatus() async => VaultStatusDto(
    initialized: _initialized,
    unlocked: _unlocked,
    dbPath: '/tmp/test.db',
  );

  @override
  Future<VaultStatusDto> vaultUnlock(String masterPassword) async {
    if (masterPassword == 'wrong') {
      throw Exception('Mật khẩu chính không chính xác');
    }
    _initialized = true;
    _unlocked = true;
    return const VaultStatusDto(
      initialized: true,
      unlocked: true,
      dbPath: '/tmp/test.db',
    );
  }

  @override
  Future<void> vaultLock() async => _unlocked = false;

  @override
  Future<List<HostDto>> listHosts() async => List.of(hosts);

  @override
  Future<List<SnippetDto>> listSnippets() async => List.of(snippets);

  @override
  Future<List<TunnelDto>> listTunnels() async => List.of(tunnels);

  @override
  Future<List<GroupDto>> listGroups() async => const [];
  @override
  Future<List<CredentialDto>> listCredentials() async => const [];
  @override
  Future<List<IdentityDto>> listIdentities() async => const [];
  @override
  Future<List<ProxyDto>> listProxies() async => List.of(_proxies);
  @override
  Future<void> upsertProxy(ProxyDto proxy) async {
    _proxies.removeWhere((existing) => existing.id == proxy.id);
    _proxies.add(proxy);
  }

  @override
  Future<void> deleteProxy(String id) async {
    if (hosts.any((host) => host.proxyId == id && host.proxyMode == 'direct')) {
      throw StateError('Proxy đang được Host sử dụng.');
    }
    _proxies.removeWhere((proxy) => proxy.id == id);
  }

  @override
  Stream<TerminalEventDto> connectSshHost(
    String hostId,
    int cols,
    int rows,
  ) async* {
    yield TerminalEventDto(kind: 'session_opened', text: 'sess_$hostId');
    yield TerminalEventDto(
      kind: 'output_bytes',
      bytes: Uint8List.fromList('Connected to $hostId\r\n'.codeUnits),
    );
    yield const TerminalEventDto(kind: 'cwd_changed', text: '/var/log');
    yield* StreamController<TerminalEventDto>().stream;
  }

  @override
  Stream<TerminalEventDto> connectQuickSsh({
    required String target,
    String? password,
    String? privateKeyPem,
    required int cols,
    required int rows,
  }) async* {
    yield const TerminalEventDto(kind: 'session_opened', text: 'sess_quick');
    yield TerminalEventDto(
      kind: 'output_bytes',
      bytes: Uint8List.fromList('Quick $target\r\n'.codeUnits),
    );
    yield* StreamController<TerminalEventDto>().stream;
  }

  @override
  Stream<TerminalEventDto> connectLocalShell({
    required int cols,
    required int rows,
    String? startupDir,
  }) async* {
    yield const TerminalEventDto(kind: 'session_opened', text: 'sess_local');
    yield TerminalEventDto(
      kind: 'output_bytes',
      bytes: Uint8List.fromList('Local Shell Ready\r\n'.codeUnits),
    );
    yield* StreamController<TerminalEventDto>().stream;
  }

  @override
  Stream<TerminalEventDto> connectTelnetHost({
    required String hostname,
    required int port,
    String? label,
  }) async* {
    yield const TerminalEventDto(kind: 'session_opened', text: 'sess_telnet');
    yield* StreamController<TerminalEventDto>().stream;
  }

  @override
  Future<void> sendSessionInput(String sessionId, List<int> data) async {
    sentInputs.add(String.fromCharCodes(data));
  }

  @override
  bool serialSupported() => false;
  @override
  Future<List<SerialPortInfoDto>> listSerialPorts() async => [];
  @override
  Stream<TerminalEventDto> connectSerial({
    required SerialConfigDto config,
    String? label,
    String? hostId,
  }) => Stream.error(
    UnsupportedError('Serial is disabled in the default test backend.'),
  );

  @override
  Future<int> broadcastSessionInput(
    List<String> sessionIds,
    List<int> data,
  ) async {
    broadcastCalls.add(sessionIds);
    return sessionIds.length;
  }

  @override
  Future<void> resizeTerminal(String sessionId, int cols, int rows) async {}

  @override
  Future<void> closeSession(String sessionId) async {}

  @override
  GuardResultDto checkCommandGuard(String input, String envTag) {
    if (input.contains('rm -rf /')) {
      return GuardResultDto(
        severity: envTag == 'prod' ? 'confirm' : 'warn',
        matchedRule: 'rm_rf_root',
        reason: 'Xoá đệ quy thư mục gốc',
        isMultiline: input.contains('\n'),
        lineCount: BigInt.from(input.split('\n').length),
      );
    }
    return GuardResultDto(
      severity: 'safe',
      isMultiline: input.contains('\n'),
      lineCount: BigInt.from(input.split('\n').length),
    );
  }

  @override
  Future<SftpListingDto> sftpListDirectory(
    String sessionId,
    String path,
  ) async {
    return SftpListingDto(
      cwd: path == '~' ? '/var/log' : path,
      entries: [
        SftpEntryDto(
          name: 'syslog',
          path: '/var/log/syslog',
          isDir: false,
          isSymlink: false,
          size: BigInt.from(2048),
          permissions: 0x1a4,
          modified: BigInt.zero,
        ),
      ],
    );
  }

  @override
  Future<String?> suggestCommandGhost(String prefix) async =>
      prefix.startsWith('sys') ? 'temctl status nginx' : null;

  @override
  Future<HostMetricsDto> pollSessionMetrics(String sessionId) async =>
      HostMetricsDto(
        cpuPercent: 24.5,
        memUsedMb: BigInt.from(1024),
        memTotalMb: BigInt.from(4096),
        diskUsedGb: 12.0,
        diskTotalGb: 50.0,
        netRxBytes: BigInt.from(1000),
        netTxBytes: BigInt.from(2000),
        loadAvg: '0.20 0.15 0.10',
        uptimeSecs: BigInt.from(3600),
      );

  @override
  Future<List<TunnelStatusDto>> listTunnelStatuses() async => const [];
  @override
  Future<TunnelStatusDto> startTunnelById(String tunnelId) async =>
      TunnelStatusDto(
        tunnelId: tunnelId,
        running: true,
        bytesIn: BigInt.zero,
        bytesOut: BigInt.zero,
        activeConns: BigInt.zero,
      );
  @override
  Future<void> stopTunnelById(String tunnelId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _dismissVaultWelcome(WidgetTester tester) async {
  expect(find.byKey(const Key('vaultCreatedDialog')), findsOneWidget);
  final continueButton = find.byKey(const Key('vaultWelcomeContinue'));
  await tester.ensureVisible(continueButton);
  await tester.tap(continueButton);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Vault unlock flow validates mismatch and unlocks cleanly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final fake = FakeCoreBackend();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [backendProvider.overrideWithValue(fake)],
        child: const TermPulseApp(),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('vaultPasswordField')),
      'secret123',
    );
    await tester.enterText(
      find.byKey(const Key('vaultConfirmPasswordField')),
      'different',
    );
    await tester.tap(find.byKey(const Key('vaultSubmitButton')));
    await tester.pump();
    expect(find.text('Mật khẩu xác nhận không khớp.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('vaultConfirmPasswordField')),
      'secret123',
    );
    await tester.tap(find.byKey(const Key('vaultSubmitButton')));
    await tester.pumpAndSettle();
    await _dismissVaultWelcome(tester);

    expect(find.byKey(const Key('desktopShell')), findsOneWidget);
  });

  testWidgets(
    'Desktop shell supports Host SSH, Follow-Terminal SFTP, Broadcast PROD banner & Ctrl+K Palette',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final fake = FakeCoreBackend();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [backendProvider.overrideWithValue(fake)],
          child: const TermPulseApp(),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('vaultPasswordField')),
        'pass',
      );
      await tester.enterText(
        find.byKey(const Key('vaultConfirmPasswordField')),
        'pass',
      );
      await tester.tap(find.byKey(const Key('vaultSubmitButton')));
      await tester.pumpAndSettle();
      await _dismissVaultWelcome(tester);

      // Host list renders prod-api-01
      expect(find.text('prod-api-01'), findsOneWidget);
      await tester.tap(find.text('prod-api-01'));
      await tester.pumpAndSettle(const Duration(milliseconds: 350));

      // SFTP Follow-Terminal panel shows /var/log & syslog
      expect(find.text('/var/log'), findsOneWidget);
      expect(find.text('syslog'), findsOneWidget);

      // Toggle Broadcast shows PROD safety banner
      await tester.tap(find.byKey(const Key('desktopBroadcastChip')));
      await tester.pump();
      expect(find.byKey(const Key('broadcastSafetyBanner')), findsOneWidget);
      expect(find.textContaining('CÓ HOST PROD'), findsOneWidget);

      // Open Command Palette
      await tester.tap(find.byKey(const Key('desktopCommandPaletteBtn')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('commandPaletteSearch')), findsOneWidget);
    },
  );

  testWidgets(
    'Mobile shell renders Status-First Host Cards, Sticky Key Bar & 3-Tab Bottom Sheet',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final fake = FakeCoreBackend();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [backendProvider.overrideWithValue(fake)],
          child: const TermPulseApp(),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('vaultPasswordField')),
        'pass',
      );
      await tester.enterText(
        find.byKey(const Key('vaultConfirmPasswordField')),
        'pass',
      );
      await tester.tap(find.byKey(const Key('vaultSubmitButton')));
      await tester.pumpAndSettle();
      await _dismissVaultWelcome(tester);

      expect(find.byKey(const Key('mobileShell')), findsOneWidget);
      expect(find.byKey(const Key('mobileHostCardsView')), findsOneWidget);

      await tester.tap(find.text('prod-api-01'));
      await tester.pumpAndSettle(const Duration(milliseconds: 350));

      // Sticky accessory bar + Space trackpad
      expect(find.byKey(const Key('mobileAccessoryBar')), findsOneWidget);
      expect(find.byKey(const Key('mobileSpaceTrackpad')), findsOneWidget);

      // Toggle Sticky Ctrl
      await tester.tap(find.byKey(const Key('stickyCtrlBtn')));
      await tester.pump();

      // Open 3-Tab Bottom Sheet -> Files (CWD)
      await tester.tap(find.byKey(const Key('mobileBottomSheetBtn')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mobileBottomSheet')), findsOneWidget);
      expect(find.text('syslog'), findsOneWidget);
    },
  );

  testWidgets(
    'Command Guard dialog blocks dangerous PROD command until confirmed',
    (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  result = await showCommandGuardDialog(
                    ctx,
                    command: 'rm -rf /',
                    targetLabel: 'prod-api-01',
                    result: GuardResultDto(
                      severity: 'confirm',
                      matchedRule: 'rm_rf_root',
                      reason: 'Xoá đệ quy thư mục gốc',
                      isMultiline: false,
                      lineCount: BigInt.one,
                    ),
                  );
                },
                child: const Text('Trigger'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Trigger'));
      await tester.pumpAndSettle();
      expect(find.text('Cảnh báo lệnh nguy hiểm (PROD)'), findsOneWidget);
      await tester.tap(find.text('Huỷ bỏ'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    },
  );
}
