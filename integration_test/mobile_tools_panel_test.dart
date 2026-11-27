// Native Quick Connect and mobile-panel QA against the loopback SSH fixture.
// Start qa_ssh_server, reverse tcp:22220, and pass its independently printed
// fingerprint as --dart-define=QA_SSH_FINGERPRINT=SHA256:... . Build/install this
// target and launch its Activity directly; do not use the uninstalling driver.
// The native Vault is a fresh private temporary directory. Files, snippets,
// tunnels and metrics are synthetic UI fixtures; SSH transport/trust is real.
// All terminal input and tunnel starts are blocked and counted. Screenshots
// contain only this fixture and remain in qa_mobile_tools_shots_* for review.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:termpulse/core/backend.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/session_log_store.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/security/ssh_trust_gate.dart';
import 'package:termpulse/features/sftp/sftp_panel.dart';
import 'package:termpulse/features/terminal/terminal_pane.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/src/rust/frb_generated.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/automation_provider.dart';
import 'package:termpulse/state/session_logs_provider.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:termpulse/ui/mobile_shell.dart';

import 'qa_host_trust.dart';

const _vaultPassword = 'Mobile-tools-QA-2026!';
const _fixturePassword = 'termpulse2026';

class _PanelBackend extends RustCoreBackend {
  int blockedTerminalInputs = 0;
  int blockedTunnelStarts = 0;
  int quickConnectCalls = 0;
  int quickSessionOpenedEvents = 0;

  @override
  Stream<TerminalEventDto> connectQuickSsh({
    required String target,
    String? password,
    String? privateKeyPem,
    required int cols,
    required int rows,
  }) {
    if (target != 'ops@127.0.0.1:22220' ||
        password != _fixturePassword ||
        privateKeyPem != null) {
      throw StateError('Quick Connect QA only allows the controlled fixture.');
    }
    quickConnectCalls++;
    return super
        .connectQuickSsh(
          target: target,
          password: password,
          privateKeyPem: privateKeyPem,
          cols: cols,
          rows: rows,
        )
        .map((event) {
          if (event.kind == 'session_opened') quickSessionOpenedEvents++;
          return event;
        });
  }

  @override
  Future<void> sendSessionInput(String sessionId, List<int> data) async {
    blockedTerminalInputs++;
    throw StateError('Panel-only QA blocks terminal input.');
  }

  @override
  Future<int> broadcastSessionInput(
    List<String> sessionIds,
    List<int> data,
  ) async {
    blockedTerminalInputs++;
    throw StateError('Panel-only QA blocks broadcast input.');
  }

  @override
  Future<TunnelStatusDto> startTunnelById(String tunnelId) async {
    blockedTunnelStarts++;
    throw StateError('Panel-only QA blocks tunnel starts.');
  }

  @override
  Future<List<SnippetDto>> listSnippets() async => List.generate(
    25,
    (index) => SnippetDto(
      id: 'qa_panel_snippet_$index',
      scope: 'global',
      title: 'QA snippet ${index.toString().padLeft(2, '0')}',
      commandTpl: 'echo synthetic-$index',
      pinButtonBar: false,
    ),
  );

  @override
  Future<List<TunnelDto>> listTunnels() async => List.generate(
    25,
    (index) => TunnelDto(
      id: 'qa_panel_tunnel_$index',
      name: 'QA tunnel ${index.toString().padLeft(2, '0')}',
      hostId: 'qa_mobile_tools_host',
      kind: 'local',
      bindAddr: '127.0.0.1',
      bindPort: 6100 + index,
      targetHost: '127.0.0.1',
      targetPort: 22,
      autoStart: false,
    ),
  );

  @override
  Future<SftpListingDto> sftpListDirectory(
    String sessionId,
    String path,
  ) async => SftpListingDto(
    cwd: '/qa-panel',
    entries: List.generate(
      25,
      (index) => SftpEntryDto(
        name: 'qa_file_${index.toString().padLeft(2, '0')}.txt',
        path: '/qa-panel/qa_file_${index.toString().padLeft(2, '0')}.txt',
        isDir: false,
        isSymlink: false,
        size: BigInt.from(256),
        permissions: 0x1a4,
        modified: BigInt.zero,
      ),
    ),
  );

  @override
  Future<HostMetricsDto> pollSessionMetrics(String sessionId) async =>
      HostMetricsDto(
        cpuPercent: 24.5,
        memUsedMb: BigInt.from(512),
        memTotalMb: BigInt.from(2048),
        diskUsedGb: 8,
        diskTotalGb: 32,
        netRxBytes: BigInt.zero,
        netTxBytes: BigInt.zero,
        loadAvg: '0.12 0.08 0.04',
        uptimeSecs: BigInt.from(3600),
      );

  @override
  Future<String?> suggestCommandGhost(String prefix) async => null;
}

class _MemorySettings extends SettingsController {
  @override
  void setLanguage(AppLanguage language) {
    state = state.copyWith(language: language);
  }

  @override
  void setThemePreset(AppThemePreset preset) {
    state = state.copyWith(themePreset: preset);
  }

  @override
  void setTerminalFontSize(double size) {
    state = state.copyWith(terminalFontSize: size.clamp(11.0, 20.0));
  }
}

class _PanelQaApp extends ConsumerWidget {
  const _PanelQaApp();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: Locale(settings.language.code),
      supportedLocales: [
        for (final language in AppLanguage.values) Locale(language.code),
      ],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildTermPulseTheme(settings.themePreset),
      builder: (context, child) =>
          AppLocalizationScope(language: settings.language, child: child!),
      // Keep the mobile surface in scope even on unusually wide test phones.
      home: const SshTrustGate(child: MobileShell()),
    );
  }
}

Finder _key(String value) => find.byKey(Key(value));

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() ready, {
  required String reason,
  bool approveQaHost = false,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (approveQaHost) await approveControlledQaHostPrompt(tester);
    if (ready()) return;
  }
  fail(reason);
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pump();
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 10),
  );
}

Future<void> _orient(WidgetTester tester, bool landscape) async {
  await SystemChrome.setPreferredOrientations([
    landscape ? DeviceOrientation.landscapeLeft : DeviceOrientation.portraitUp,
  ]);
  await _waitUntil(
    tester,
    () {
      final size = tester.view.physicalSize;
      return landscape ? size.width > size.height : size.height > size.width;
    },
    reason: 'The native device did not enter the requested orientation.',
    timeout: const Duration(seconds: 10),
  );
  await tester.pumpAndSettle();
}

void _expectPanel(WidgetTester tester) {
  final panel = tester.getRect(_key('mobileBottomSheet'));
  final accessory = tester.getRect(_key('mobileAccessoryBar'));
  final terminal = tester.getRect(find.byType(TerminalPane));
  expect(panel.height, greaterThanOrEqualTo(44));
  expect(panel.bottom, closeTo(accessory.top, 1));
  expect(panel.top, greaterThanOrEqualTo(terminal.top));
  expect(terminal.height, greaterThan(0));
  expect(_key('mobileSheetResizeHandle').hitTestable(), findsOneWidget);
}

void _assertSynthetic(ProviderContainer container, _PanelBackend backend) {
  final workspace = container.read(sessionManagerProvider);
  expect(workspace.tabs, hasLength(1));
  final tab = workspace.activeTab!;
  expect(tab.hostId, 'qa_mobile_tools_host');
  expect(tab.closed, isFalse);
  final text = tab.terminal.buffer.getText();
  expect(text, contains('WELCOME_TERMPULSE'));
  expect(text, isNot(contains(_vaultPassword)));
  expect(text, isNot(contains(_fixturePassword)));
  expect(backend.blockedTerminalInputs, 0);
  expect(backend.blockedTunnelStarts, 0);
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey key,
  Directory directory,
  String name,
  ProviderContainer container,
  _PanelBackend backend,
) async {
  _assertSynthetic(container, backend);
  for (final field in tester.widgetList<EditableText>(
    find.byType(EditableText),
  )) {
    expect(field.controller.text, isNot(contains(_vaultPassword)));
    expect(field.controller.text, isNot(contains(_fixturePassword)));
  }
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  expect(boundary.debugNeedsPaint, isFalse);
  final image = await boundary.toImage(
    pixelRatio: tester.view.devicePixelRatio,
  );
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(data, isNotNull);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final file = File('${directory.path}${Platform.pathSeparator}$name.png');
    await file.writeAsBytes(bytes, flush: true);
    expect(await file.length(), greaterThan(5000));
  } finally {
    image.dispose();
  }
}

Future<void> _scrollPanelUntilVisible(
  WidgetTester tester,
  Finder target, {
  required Finder scrollable,
}) async {
  for (var drag = 0; drag < 45; drag++) {
    final viewport = tester.getRect(_key('mobileSheetContentViewport'));
    if (target.hitTestable().evaluate().isNotEmpty) {
      final bounds = tester.getRect(target);
      if (bounds.top >= viewport.top - 1 &&
          bounds.bottom <= viewport.bottom + 1) {
        return;
      }
    }
    final visible = tester.getRect(scrollable).intersect(viewport);
    // The nested list's center can be below the physical landscape screen.
    // Start every gesture within the clipped visible area, like a real user.
    final area = visible.height >= 24 ? visible : viewport;
    await tester.dragFrom(
      Offset(area.center.dx, area.bottom - 8),
      Offset(0, -(viewport.height * .7).clamp(80.0, 140.0)),
    );
    await tester.pumpAndSettle();
  }
  expect(
    target.hitTestable(),
    findsOneWidget,
    reason: 'The panel content must be reachable using visible drag gestures.',
  );
  final viewport = tester.getRect(_key('mobileSheetContentViewport'));
  final bounds = tester.getRect(target);
  expect(bounds.top, greaterThanOrEqualTo(viewport.top - 1));
  expect(bounds.bottom, lessThanOrEqualTo(viewport.bottom + 1));
}

Future<void> _checkScrolling(WidgetTester tester) async {
  await _tap(tester, _key('mobileSheetTabFiles'));
  expect(tester.takeException(), isNull);
  final lastFile = _key('sftpEntry:/qa-panel/qa_file_24.txt');
  await _scrollPanelUntilVisible(
    tester,
    lastFile,
    scrollable: find
        .descendant(
          of: find.byType(SftpPanel),
          matching: find.byType(Scrollable),
        )
        .last,
  );
  await tester.pumpAndSettle();
  expect(lastFile.hitTestable(), findsOneWidget);

  await _tap(tester, _key('mobileSheetTabSnippets'));
  expect(tester.takeException(), isNull);
  await _scrollPanelUntilVisible(
    tester,
    find.text('QA snippet 24'),
    scrollable: find.descendant(
      of: _key('mobileSnippetList'),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.text('QA snippet 24').hitTestable(), findsOneWidget);
  await tester.ensureVisible(_key('composeSendButton'));
  await tester.pumpAndSettle();
  expect(_key('composeSendButton').hitTestable(), findsOneWidget);

  await _tap(tester, _key('mobileSheetTabHealth'));
  expect(tester.takeException(), isNull);
  await _scrollPanelUntilVisible(
    tester,
    find.text('QA tunnel 24'),
    scrollable: find.descendant(
      of: _key('mobileHealthScroll'),
      matching: find.byType(Scrollable),
    ),
  );
  expect(find.text('QA tunnel 24').hitTestable(), findsOneWidget);
  expect(
    tester.getRect(find.text('QA tunnel 24')).bottom,
    lessThanOrEqualTo(tester.getRect(_key('mobileAccessoryBar')).top),
  );
  _expectPanel(tester);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets('Native mobile tools drag collapse rotate and scroll', (
    tester,
  ) async {
    const fingerprint = String.fromEnvironment('QA_SSH_FINGERPRINT');
    expect(
      RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$').hasMatch(fingerprint),
      isTrue,
      reason: 'Pass the controlled SSH fixture startup fingerprint.',
    );
    final appData = Directory(await ForegroundBridge.getAppDataDir());
    await appData.create(recursive: true);
    final fixture = await appData.createTemp('qa_mobile_tools_vault_');
    final shots = await appData.createTemp('qa_mobile_tools_shots_');
    final backend = _PanelBackend();
    final logStore = SessionLogStore(
      directory: () async => Directory('${fixture.path}/logs'),
    );
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWithValue(backend),
        settingsProvider.overrideWith(_MemorySettings.new),
        sessionLogStoreProvider.overrideWithValue(logStore),
        automationStorageProvider.overrideWithValue(
          FileAutomationStorage(directory: () async => fixture.path),
        ),
      ],
    );
    final manager = container.read(sessionManagerProvider.notifier);
    var cleaned = false;
    tester.testTextInput.register();
    Future<void> cleanup() async {
      if (cleaned) return;
      cleaned = true;
      Object? failure;
      StackTrace? failureStack;
      Future<void> attempt(Future<void> Function() action) async {
        try {
          await action();
        } catch (error, stack) {
          failure ??= error;
          failureStack ??= stack;
        }
      }

      await attempt(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
      await attempt(manager.closeAllSessions);
      await attempt(backend.vaultLock);
      await attempt(logStore.closeAll);
      await attempt(() async => container.dispose());
      await attempt(() async => tester.testTextInput.unregister());
      await attempt(() => SystemChrome.setPreferredOrientations(const []));
      await attempt(() async {
        if (await fixture.exists()) await fixture.delete(recursive: true);
      });
      if (failure != null) {
        Error.throwWithStackTrace(failure!, failureStack!);
      }
    }

    addTearDown(cleanup);
    debugPrint('TERMPULSE_MOBILE_TOOLS_SCREENSHOT_DIR=${shots.path}');
    (binding.reportData ??= <String, dynamic>{})['screenshotDirectory'] =
        shots.path;
    await _orient(tester, false);
    final vault = container.read(vaultProvider.notifier);
    await vault.initAtPath('${fixture.path}${Platform.pathSeparator}vault.db');
    expect(container.read(vaultProvider).error, isNull);
    expect(container.read(vaultProvider).initialized, isFalse);
    expect(await vault.unlock(_vaultPassword), isTrue);
    await backend.upsertCredential(
      const CredentialDto(
        id: 'qa_mobile_tools_credential',
        name: 'Controlled panel QA password',
        kind: 'password',
        secret: _fixturePassword,
        storageBackend: 'vault',
      ),
    );
    await backend.upsertIdentity(
      const IdentityDto(
        id: 'qa_mobile_tools_identity',
        name: 'Controlled panel QA identity',
        username: 'ops',
        credentialId: 'qa_mobile_tools_credential',
      ),
    );
    const host = HostDto(
      id: 'qa_mobile_tools_host',
      label: 'QA mobile panel loopback',
      protocol: 'ssh',
      hostname: '127.0.0.1',
      port: 22220,
      identityMode: 'by_id',
      identityId: 'qa_mobile_tools_identity',
      jumpHostMode: 'none',
      proxyMode: 'none',
      envTag: 'dev',
      tags: ['controlled-fixture'],
      notes: 'Temporary mobile panel QA fixture only.',
      env: [],
      followTerminalSftp: false,
      isFavorite: false,
    );
    await backend.upsertHost(host);
    await container.read(inventoryProvider.notifier).refreshAll();
    final captureKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: UncontrolledProviderScope(
          container: container,
          child: const _PanelQaApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(sessionManagerProvider).tabs, isEmpty);
    final approvalsBeforeQuick = controlledQaHostApprovals;
    await tester.enterText(
      _key('mobileQuickConnectField'),
      'ssh -p 22220 ops@127.0.0.1',
    );
    await _tap(tester, _key('mobileQuickConnectSubmit'));
    expect(_key('quickConnectPasswordDialog'), findsOneWidget);
    expect(
      tester.widget<TextField>(_key('quickConnectPasswordField')).obscureText,
      isTrue,
    );
    await tester.enterText(_key('quickConnectPasswordField'), _fixturePassword);
    await tester.tap(_key('quickConnectSubmit'));
    await tester.pump();
    await _waitUntil(
      tester,
      () {
        final tab = container.read(sessionManagerProvider).activeTab;
        return backend.quickSessionOpenedEvents == 1 &&
            tab?.sessionId != null &&
            !tab!.closed &&
            tab.terminal.buffer.getText().contains('WELCOME_TERMPULSE');
      },
      reason: 'Production Quick Connect did not open the native loopback SSH.',
      approveQaHost: true,
    );
    final quickWorkspace = container.read(sessionManagerProvider);
    expect(quickWorkspace.tabs, hasLength(1));
    final quickTab = quickWorkspace.activeTab!;
    expect(quickTab.hostId, isNull);
    expect(quickTab.title, 'ops@127.0.0.1:22220');
    expect(backend.quickConnectCalls, 1);
    expect(controlledQaHostApprovals, approvalsBeforeQuick + 1);
    expect(
      quickTab.terminal.buffer.getText().contains(_fixturePassword),
      isFalse,
    );
    expect(_key('quickConnectPasswordDialog'), findsNothing);
    expect(backend.blockedTerminalInputs, 0);
    final quickConnected =
        backend.quickSessionOpenedEvents == 1 &&
        quickTab.sessionId != null &&
        !quickTab.closed;
    expect(quickConnected, isTrue);
    await manager.closeAllSessions();
    await tester.pumpAndSettle();
    expect(container.read(sessionManagerProvider).tabs, isEmpty);
    expect(
      tester
          .widget<TextField>(_key('mobileQuickConnectField'))
          .controller!
          .text,
      isEmpty,
    );
    await tester.tap(find.text(host.label));
    await _waitUntil(
      tester,
      () {
        final tab = container.read(sessionManagerProvider).activeTab;
        return tab?.sessionId != null &&
            tab!.terminal.buffer.getText().contains('WELCOME_TERMPULSE');
      },
      reason: 'Controlled loopback SSH did not connect; check fixture/reverse.',
      approveQaHost: true,
    );
    final initial = container.read(sessionManagerProvider).activeTab!;
    expect(initial.sessionId, isNot(quickTab.sessionId));
    await manager.loadSftpDirectory(initial.localKey, '/qa-panel');
    final terminalState = tester.state(find.byType(TerminalPane));
    await _tap(tester, _key('mobileBottomSheetBtn'));
    _expectPanel(tester);
    final portrait = MediaQuery.sizeOf(tester.element(_key('mobileShell')));
    final initialHeight = tester.getSize(_key('mobileBottomSheet')).height;
    await tester.dragFrom(
      tester.getTopLeft(_key('mobileSheetResizeHandle')) + const Offset(28, 22),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(_key('mobileBottomSheet')).height,
      greaterThan(initialHeight + 40),
    );
    await _capture(
      tester,
      captureKey,
      shots,
      'portrait-resized',
      container,
      backend,
    );
    await tester.dragFrom(
      tester.getTopLeft(_key('mobileSheetResizeHandle')) + const Offset(28, 22),
      const Offset(0, 1000),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(_key('mobileBottomSheet')).height, 44);
    await _capture(
      tester,
      captureKey,
      shots,
      'portrait-collapsed',
      container,
      backend,
    );
    await _tap(tester, _key('mobileSheetCollapseBtn'));
    expect(tester.getSize(_key('mobileBottomSheet')).height, greaterThan(200));
    await _tap(tester, _key('mobileSheetExpandBtn'));
    final maximized = tester.getSize(_key('mobileBottomSheet')).height;
    await _tap(tester, _key('mobileSheetExpandBtn'));
    expect(
      tester.getSize(_key('mobileBottomSheet')).height,
      lessThan(maximized),
    );
    await _tap(tester, _key('mobileSheetExpandBtn'));
    await _checkScrolling(tester);
    await _capture(
      tester,
      captureKey,
      shots,
      'portrait-health-bottom',
      container,
      backend,
    );

    await _tap(tester, _key('mobileSheetTabSnippets'));
    await tester.ensureVisible(_key('composePaneField'));
    await tester.enterText(
      _key('composePaneField'),
      'echo unsent synthetic draft',
    );
    await tester.pumpAndSettle();
    await _tap(tester, _key('mobileSheetCollapseBtn'));
    await _tap(tester, _key('mobileSheetCollapseBtn'));
    expect(
      tester.widget<TextField>(_key('composePaneField')).controller!.text,
      'echo unsent synthetic draft',
    );
    await _orient(tester, true);
    final landscape = MediaQuery.sizeOf(tester.element(_key('mobileShell')));
    expect(landscape.width, greaterThan(landscape.height));
    _expectPanel(tester);
    expect(
      tester.widget<TextField>(_key('composePaneField')).controller!.text,
      'echo unsent synthetic draft',
    );
    container
        .read(settingsProvider.notifier)
        .setThemePreset(AppThemePreset.light);
    await tester.pumpAndSettle();
    await _checkScrolling(tester);
    await _capture(
      tester,
      captureKey,
      shots,
      'landscape-health-bottom-light',
      container,
      backend,
    );
    await _tap(tester, _key('mobileSheetCollapseBtn'));
    expect(tester.getSize(_key('mobileBottomSheet')).height, 44);
    await _tap(tester, _key('mobileSheetCollapseBtn'));
    await _orient(tester, false);
    _expectPanel(tester);
    expect(tester.state(find.byType(TerminalPane)), same(terminalState));
    final after = container.read(sessionManagerProvider).activeTab!;
    expect(after.localKey, initial.localKey);
    expect(after.sessionId, initial.sessionId);
    _assertSynthetic(container, backend);
    expect(tester.takeException(), isNull);
    (binding.reportData ??= <String, dynamic>{}).addAll({
      'syntheticFixtureOnly': true,
      'quickConnected': quickConnected,
      'blockedTerminalInputs': backend.blockedTerminalInputs,
      'blockedTunnelStarts': backend.blockedTunnelStarts,
      'portraitLogicalSize': '${portrait.width}x${portrait.height}',
      'landscapeLogicalSize': '${landscape.width}x${landscape.height}',
      'devicePixelRatio': tester.view.devicePixelRatio,
      'screenshots': [
        'portrait-resized',
        'portrait-collapsed',
        'portrait-health-bottom',
        'landscape-health-bottom-light',
      ],
    });
    await cleanup();
    debugPrint('TERMPULSE_MOBILE_TOOLS_QUICK_CONNECTED=$quickConnected');
    debugPrint('TERMPULSE_MOBILE_TOOLS_PASSED');
  });
}
