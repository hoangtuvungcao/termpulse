// Real Android smoke against the controlled native SSH fixture only.
// Before running, start qa_ssh_server, use `adb reverse tcp:22220 tcp:22220`,
// and pass its independently printed QA_SSH_SERVER_FINGERPRINT with
// --dart-define=QA_SSH_FINGERPRINT=SHA256:... . No screenshots or user vaults
// are written: the temporary vault lives below Android's actual app-data path.
// QA_ANDROID_LIFECYCLE=true additionally requires the host to background and
// reopen the real activity after TERMPULSE_ANDROID_BACKGROUND_READY is logged.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/src/rust/frb_generated.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:xterm/xterm.dart';

import 'qa_host_trust.dart';

const _checkAndroidLifecycle = bool.fromEnvironment('QA_ANDROID_LIFECYCLE');

class _AndroidLifecycleProbe extends WidgetsBindingObserver {
  final resumedAfterBackground = Completer<void>();
  final observedStates = <AppLifecycleState>[];
  bool _observedBackground = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    observedStates.add(state);
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _observedBackground = true;
    } else if (state == AppLifecycleState.resumed &&
        _observedBackground &&
        !resumedAfterBackground.isCompleted) {
      resumedAfterBackground.complete();
    }
  }
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() predicate, {
  required String reason,
  Duration timeout = const Duration(seconds: 40),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    await approveControlledQaHostPrompt(tester);
    if (predicate()) return;
  }
  fail(reason);
}

Future<void> _typeInTerminal(WidgetTester tester, String command) async {
  final terminal = find.byType(TerminalView);
  expect(terminal, findsOneWidget);
  await tester.tap(terminal);
  await tester.pump();
  expect(tester.testTextInput.hasAnyClients, isTrue);
  final prefix = tester.testTextInput.editingState?['text'] as String? ?? '';
  final value = '$prefix$command';
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    ),
  );
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
}

String _terminalText(ProviderContainer container) => container
    .read(sessionManagerProvider)
    .activeTab!
    .terminal
    .buffer
    .getText()
    .replaceAll(RegExp(r'\s+'), '');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());

  testWidgets(
    'Android vault SSH first trust terminal keyboard and same-tab reconnect',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      tester.testTextInput.register();
      final appData = Directory(await ForegroundBridge.getAppDataDir());
      await appData.create(recursive: true);
      final directory = await appData.createTemp('qa_android_smoke_');
      final container = ProviderContainer();
      final backend = container.read(backendProvider);
      final manager = container.read(sessionManagerProvider.notifier);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        for (final tab
            in container.read(sessionManagerProvider).tabs.toList()) {
          await manager.closeTab(tab.localKey);
        }
        await backend.vaultLock();
        container.dispose();
        tester.testTextInput.unregister();
        tester.view.reset();
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      await container
          .read(vaultProvider.notifier)
          .initAtPath('${directory.path}${Platform.pathSeparator}vault.db');
      expect(container.read(vaultProvider).error, isNull);
      expect(container.read(vaultProvider).unlocked, isFalse);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TermPulseApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vaultPasswordField')), findsOneWidget);
      expect(
        find.byKey(const Key('vaultConfirmPasswordField')),
        findsOneWidget,
      );
      // Both notices must work offline before creating or unlocking a vault.
      await tester.ensureVisible(find.byKey(const Key('privacyButton')));
      await tester.tap(find.byKey(const Key('privacyButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('privacyPolicyScreen')), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'English'));
      await tester.pumpAndSettle();
      expect(find.text('2. Data stored on your device'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('permissionsButton')));
      await tester.tap(find.byKey(const Key('permissionsButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('permissionsScreen')), findsOneWidget);
      expect(
        find.byKey(const Key('notificationPermissionStatus')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('permissionsError')), findsNothing);
      final requestPermission = find.byKey(
        const Key('requestNotificationPermission'),
      );
      if (requestPermission.evaluate().isNotEmpty) {
        await tester.tap(requestPermission);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('notificationPermissionRationale')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('cancelNotificationPermission')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      debugPrint('TERMPULSE_ANDROID_PRIVACY_PERMISSIONS_PASSED');
      await tester.enterText(
        find.byKey(const Key('vaultPasswordField')),
        'Android-Smoke-QA-2026!',
      );
      await tester.enterText(
        find.byKey(const Key('vaultConfirmPasswordField')),
        'Android-Smoke-QA-2026!',
      );
      await tester.tap(find.byKey(const Key('vaultSubmitButton')));
      await _waitUntil(
        tester,
        () =>
            container.read(vaultProvider).unlocked &&
            find.byKey(const Key('mobileShell')).evaluate().isNotEmpty,
        reason: 'Android did not create and unlock its temporary native vault',
      );
      await _waitUntil(
        tester,
        () => find.byKey(const Key('vaultCreatedDialog')).evaluate().isNotEmpty,
        reason: 'First Vault creation did not show the welcome dialog',
      );
      await tester.ensureVisible(find.byKey(const Key('vaultWelcomeContinue')));
      await tester.tap(find.byKey(const Key('vaultWelcomeContinue')));
      await tester.pumpAndSettle();
      final inventory = container.read(inventoryProvider.notifier);
      await inventory.saveCredentialAndIdentity(
        cred: const CredentialDto(
          id: 'qa_android_secret',
          name: 'Controlled Android QA credential',
          kind: 'password',
          secret: 'termpulse2026',
          storageBackend: 'vault',
        ),
        identity: const IdentityDto(
          id: 'qa_android_identity',
          name: 'Controlled Android QA identity',
          username: 'ops',
          credentialId: 'qa_android_secret',
        ),
      );
      const host = HostDto(
        id: 'qa_android_host',
        label: 'Android QA loopback',
        protocol: 'ssh',
        hostname: '127.0.0.1',
        port: 22220,
        identityMode: 'by_id',
        identityId: 'qa_android_identity',
        jumpHostMode: 'none',
        proxyMode: 'none',
        envTag: 'dev',
        tags: ['controlled-fixture'],
        notes: 'Controlled fixture via adb reverse only',
        env: [],
        followTerminalSftp: false,
        isFavorite: false,
      );
      await inventory.saveHost(host);
      await tester.pumpAndSettle();
      final approvalsBeforeConnect = controlledQaHostApprovals;
      await tester.tap(find.text(host.label));
      await _waitUntil(
        tester,
        () {
          final tab = container.read(sessionManagerProvider).activeTab;
          return tab != null &&
              tab.sessionId != null &&
              tab.terminal.buffer.getText().contains('WELCOME_TERMPULSE');
        },
        reason:
            'Android SSH did not connect to controlled 127.0.0.1:22220; '
            'check adb reverse and QA_SSH_FINGERPRINT',
      );
      expect(controlledQaHostApprovals, approvalsBeforeConnect + 1);
      final initial = container.read(sessionManagerProvider).activeTab!;
      expect(find.byType(TerminalView), findsOneWidget);
      await _typeInTerminal(tester, 'qa-android-one');
      await _waitUntil(
        tester,
        () => _terminalText(container).contains('[ok]executed:qa-android-one'),
        reason: 'Direct Android terminal typing did not reach the SSH fixture',
      );

      if (_checkAndroidLifecycle) {
        final sessionIdBeforeBackground = initial.sessionId;
        final lifecycle = _AndroidLifecycleProbe();
        WidgetsBinding.instance.addObserver(lifecycle);
        try {
          final observedBackgroundAndResume = await tester.runAsync(() async {
            // The host must send HOME and reopen the real Android activity.
            // Use wall-clock time because a paused app does not produce frames.
            debugPrint('TERMPULSE_ANDROID_BACKGROUND_READY');
            try {
              await lifecycle.resumedAfterBackground.future.timeout(
                const Duration(seconds: 30),
              );
            } on TimeoutException {
              fail(
                'Android did not background and resume within 30 seconds; '
                'observed lifecycle states: ${lifecycle.observedStates}',
              );
            }
            return true;
          });
          expect(observedBackgroundAndResume, isTrue);
          await tester.pump();
          expect(
            WidgetsBinding.instance.lifecycleState,
            AppLifecycleState.resumed,
          );
          final afterResume = container.read(sessionManagerProvider).activeTab!;
          expect(afterResume.sessionId, sessionIdBeforeBackground);
          expect(afterResume.closed, isFalse);
          expect(afterResume.localKey, initial.localKey);
          expect(afterResume.terminal, same(initial.terminal));
          expect(container.read(sessionManagerProvider).tabs, hasLength(1));
          await _typeInTerminal(tester, 'qa-android-after-resume');
          await _waitUntil(
            tester,
            () => _terminalText(
              container,
            ).contains('[ok]executed:qa-android-after-resume'),
            reason:
                'Android SSH session did not accept direct typing after resume',
          );
          debugPrint('TERMPULSE_ANDROID_LIFECYCLE_PASSED');
          await ForegroundBridge.pauseBackgroundSupport();
          expect(ForegroundBridge.backgroundStatus.value.stoppedReason, 'user');
          await ForegroundBridge.syncActiveCount(1);
          expect(ForegroundBridge.backgroundStatus.value.running, isFalse);
          await _typeInTerminal(tester, 'qa-android-after-service-stop');
          await _waitUntil(
            tester,
            () => _terminalText(
              container,
            ).contains('[ok]executed:qa-android-after-service-stop'),
            reason: 'Stopping background support unexpectedly ended SSH',
          );
          await ForegroundBridge.resumeBackgroundSupport();
          expect(ForegroundBridge.backgroundStatus.value.running, isTrue);
          debugPrint('TERMPULSE_ANDROID_SERVICE_STOP_PASSED');
        } finally {
          WidgetsBinding.instance.removeObserver(lifecycle);
        }
      }

      // Close the real native SSH handle; the terminal must observe its actual
      // Closed event before the visible reconnect action becomes available.
      await backend.closeSession(initial.sessionId!);
      await _waitUntil(
        tester,
        () => container.read(sessionManagerProvider).activeTab!.closed,
        reason: 'Native SSH closure did not mark the Android terminal closed',
      );
      expect(find.byKey(const Key('terminalReconnectBtn')), findsOneWidget);
      await tester.tap(find.byKey(const Key('terminalReconnectBtn')));
      await _waitUntil(
        tester,
        () {
          final tab = container.read(sessionManagerProvider).activeTab!;
          return !tab.closed &&
              tab.sessionId != null &&
              tab.sessionId != initial.sessionId &&
              tab.terminal.buffer.getText().split('WELCOME_TERMPULSE').length ==
                  3;
        },
        reason:
            'Visible Android reconnect did not open a fresh native SSH link',
      );
      final reconnected = container.read(sessionManagerProvider).activeTab!;
      expect(reconnected.localKey, initial.localKey);
      expect(reconnected.terminal, same(initial.terminal));
      expect(container.read(sessionManagerProvider).tabs, hasLength(1));
      expect(controlledQaHostApprovals, approvalsBeforeConnect + 1);
      await _typeInTerminal(tester, 'qa-android-two');
      await _waitUntil(
        tester,
        () => _terminalText(container).contains('[ok]executed:qa-android-two'),
        reason: 'Reconnected Android terminal did not accept direct typing',
      );
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
