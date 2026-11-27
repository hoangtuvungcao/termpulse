// Native Android mobile-host QA. Build this target, install with `adb install
// -r`, and launch its Activity directly; the integration driver uninstalls the
// app during cleanup. The test opens only a fresh temporary Vault and never
// calls production main() or loads/writes the user's preferences.
// Screenshots remain in a fresh private app-data/qa_mobile_host_shots_* folder.
// Optional SSH correction flow: start qa_ssh_server, reverse tcp:22220, and
// build with QA_MOBILE_SSH_ERRORS=true plus its QA_SSH_FINGERPRINT dart-define.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/src/rust/frb_generated.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';

import 'qa_host_trust.dart';

const _checkSshErrors = bool.fromEnvironment('QA_MOBILE_SSH_ERRORS');

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

Finder _key(String value) => find.byKey(Key(value));

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
  description: 'TextField with label "$label"',
);

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() ready, {
  required String reason,
  Duration timeout = const Duration(seconds: 45),
  bool approveQaHost = false,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (approveQaHost) await approveControlledQaHostPrompt(tester);
    if (ready()) return;
  }
  fail(reason);
}

Future<void> _tap(
  WidgetTester tester,
  Finder target, {
  bool settle = true,
}) async {
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  if (settle) {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
  } else {
    await tester.pump();
  }
}

Future<void> _enter(WidgetTester tester, String label, String value) async {
  final target = _field(label);
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.enterText(target, value);
  await tester.pump();
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey key,
  Directory directory,
  String name,
) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 10),
  );
  final context = key.currentContext;
  if (context == null || !context.mounted) {
    throw StateError('Screenshot boundary is missing: $name');
  }
  final boundary = context.findRenderObject()! as RenderRepaintBoundary;
  expect(boundary.debugNeedsPaint, isFalse);
  final image = await boundary.toImage(
    pixelRatio: tester.view.devicePixelRatio,
  );
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(data, isNotNull, reason: 'Could not encode screenshot: $name');
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

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.isAndroid) await RustLib.init();
  });

  testWidgets(
    'Android mobile host create edit preserve credentials and delete confirmation',
    (tester) async {
      final appData = Directory(await ForegroundBridge.getAppDataDir());
      await appData.create(recursive: true);
      final fixture = await appData.createTemp('qa_mobile_host_vault_');
      final shots = await appData.createTemp('qa_mobile_host_shots_');
      debugPrint('TERMPULSE_MOBILE_HOST_SCREENSHOT_DIR=${shots.path}');
      (binding.reportData ??= <String, dynamic>{})['screenshotDirectory'] =
          shots.path;
      final container = ProviderContainer(
        overrides: [settingsProvider.overrideWith(_MemorySettings.new)],
      );
      final backend = container.read(backendProvider);
      var cleaned = false;
      tester.testTextInput.register();
      Future<void> cleanup() async {
        if (cleaned) return;
        cleaned = true;
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await container
              .read(sessionManagerProvider.notifier)
              .closeAllSessions();
          await backend.vaultLock();
        } finally {
          container.dispose();
          tester.testTextInput.unregister();
          if (await fixture.exists()) await fixture.delete(recursive: true);
        }
      }

      addTearDown(cleanup);
      final vault = container.read(vaultProvider.notifier);
      await vault.initAtPath(
        '${fixture.path}${Platform.pathSeparator}vault.db',
      );
      expect(container.read(vaultProvider).error, isNull);
      expect(container.read(vaultProvider).initialized, isFalse);
      expect(await vault.unlock('Mobile-host-QA-2026!'), isTrue);
      expect(container.read(vaultProvider).error, isNull);
      final inventory = container.read(inventoryProvider.notifier);
      const sentinel = HostDto(
        id: 'qa_mobile_untouched',
        label: 'QA untouched host',
        protocol: 'ssh',
        hostname: '192.0.2.10',
        port: 22,
        identityMode: 'inherit',
        jumpHostMode: 'none',
        proxyMode: 'none',
        envTag: 'dev',
        tags: ['controlled-fixture'],
        notes: 'Sentinel in the temporary QA Vault; never connected.',
        env: [],
        followTerminalSftp: false,
        isFavorite: false,
      );
      await inventory.saveHost(sentinel);
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: UncontrolledProviderScope(
            container: container,
            child: const TermPulseApp(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_key('mobileShell'), findsOneWidget);
      expect(_key('mobileHostCardsView'), findsOneWidget);
      expect(_key('vaultCreatedDialog'), findsNothing);

      const originalLabel = 'QA mobile host';
      const editedLabel = 'QA mobile host edited';
      const labelField = 'Tên hiển thị (vd: prod-web-01) *';
      const passwordField = 'Mật khẩu (để trống nếu giữ cũ/kế thừa)';
      await _tap(tester, find.byType(FloatingActionButton));
      expect(find.text('Thêm kết nối Host mới'), findsOneWidget);
      await _enter(tester, labelField, originalLabel);
      await _enter(tester, 'Hostname / IP *', '127.0.0.1');
      await _enter(tester, 'Port', '22220');
      await _enter(tester, 'Username', 'qa_before_edit');
      await _enter(tester, passwordField, 'deliberately-wrong-qa-password');
      FocusManager.instance.primaryFocus?.unfocus();
      await _tap(
        tester,
        find.widgetWithText(FilledButton, 'Lưu Host'),
        settle: false,
      );
      await _waitUntil(
        tester,
        () =>
            container
                .read(inventoryProvider)
                .hosts
                .any((host) => host.label == originalLabel) &&
            find.text('Thêm kết nối Host mới').evaluate().isEmpty,
        reason:
            'Creating a mobile host did not persist to the native QA Vault.',
      );
      await tester.pumpAndSettle();
      final created = (await backend.listHosts()).singleWhere(
        (host) => host.label == originalLabel,
      );
      expect(created.protocol, 'ssh');
      expect(created.hostname, '127.0.0.1');
      expect(created.port, 22220);
      expect(created.identityMode, 'by_id');
      expect(created.identityId, isNotNull);
      final originalIdentity = (await backend.listIdentities()).singleWhere(
        (identity) => identity.id == created.identityId,
      );
      expect(originalIdentity.username, 'qa_before_edit');
      expect(originalIdentity.credentialId, isNotNull);
      expect(container.read(sessionManagerProvider).tabs, isEmpty);
      expect(_key('mobileEditHost_${created.id}'), findsOneWidget);
      expect(_key('mobileDeleteHost_${created.id}'), findsOneWidget);
      await tester.ensureVisible(_key('mobileEditHost_${created.id}'));
      await _capture(tester, captureKey, shots, 'host-actions');

      await _tap(tester, _key('mobileEditHost_${created.id}'));
      expect(find.text('Chỉnh sửa Host'), findsOneWidget);
      expect(
        tester.widget<TextField>(_field(labelField)).controller!.text,
        originalLabel,
      );
      expect(
        tester.widget<TextField>(_field('Hostname / IP *')).controller!.text,
        '127.0.0.1',
      );
      expect(
        tester.widget<TextField>(_field('Port')).controller!.text,
        '22220',
      );
      expect(
        tester.widget<TextField>(_field('Username')).controller!.text,
        'qa_before_edit',
      );
      expect(
        tester.widget<TextField>(_field(passwordField)).controller!.text,
        isEmpty,
      );
      await _enter(tester, labelField, editedLabel);
      await tester.ensureVisible(_field(labelField));
      await _capture(tester, captureKey, shots, 'host-editor');
      await _tap(
        tester,
        find.widgetWithText(FilledButton, 'Lưu Host'),
        settle: false,
      );
      await _waitUntil(
        tester,
        () =>
            container
                .read(inventoryProvider)
                .hosts
                .any(
                  (host) => host.id == created.id && host.label == editedLabel,
                ) &&
            find.text('Chỉnh sửa Host').evaluate().isEmpty,
        reason: 'Editing a mobile host did not update the same native record.',
      );
      await tester.pumpAndSettle();
      final afterEdit = await backend.listHosts();
      expect(afterEdit, hasLength(2));
      final edited = afterEdit.singleWhere((host) => host.id == created.id);
      expect(edited.label, editedLabel);
      expect(edited.hostname, created.hostname);
      expect(edited.port, created.port);
      expect(edited.identityMode, created.identityMode);
      expect(edited.identityId, created.identityId);
      final preservedIdentity = (await backend.listIdentities()).singleWhere(
        (identity) => identity.id == edited.identityId,
      );
      expect(preservedIdentity.username, originalIdentity.username);
      expect(preservedIdentity.credentialId, originalIdentity.credentialId);
      expect(container.read(sessionManagerProvider).tabs, isEmpty);

      // Changing only the username must retain the stored password credential.
      await _tap(tester, _key('mobileEditHost_${created.id}'));
      await _enter(tester, 'Username', 'ops');
      expect(
        tester.widget<TextField>(_field(passwordField)).controller!.text,
        isEmpty,
      );
      await _tap(
        tester,
        find.widgetWithText(FilledButton, 'Lưu Host'),
        settle: false,
      );
      await _waitUntil(
        tester,
        () =>
            find.text('Chỉnh sửa Host').evaluate().isEmpty &&
            container
                .read(inventoryProvider)
                .hosts
                .any(
                  (host) =>
                      host.id == created.id &&
                      host.identityId != created.identityId,
                ),
        reason:
            'Changing a saved mobile username did not persist a new identity.',
      );
      final usernameEditedHost = (await backend.listHosts()).singleWhere(
        (host) => host.id == created.id,
      );
      final usernameEditedIdentity = (await backend.listIdentities())
          .singleWhere(
            (identity) => identity.id == usernameEditedHost.identityId,
          );
      expect(usernameEditedIdentity.username, 'ops');
      expect(
        usernameEditedIdentity.credentialId,
        originalIdentity.credentialId,
      );
      expect((await backend.listHosts()), hasLength(2));
      await tester.ensureVisible(_key('mobileEditHost_${created.id}'));
      await _capture(tester, captureKey, shots, 'host-main-dark');
      final settings = container.read(settingsProvider.notifier);
      settings.setThemePreset(AppThemePreset.light);
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(_key('mobileShell'))).brightness,
        Brightness.light,
      );
      await _capture(tester, captureKey, shots, 'host-main-light');
      settings.setThemePreset(AppThemePreset.dark);
      await tester.pumpAndSettle();

      if (_checkSshErrors) {
        expect(
          const String.fromEnvironment('QA_SSH_FINGERPRINT'),
          isNotEmpty,
          reason:
              'The SSH error flow requires the independently printed fixture fingerprint.',
        );
        final approvalsBefore = controlledQaHostApprovals;
        final attempt = Stopwatch()..start();
        await _tap(
          tester,
          find.descendant(
            of: _key('mobileHostCard_${created.id}'),
            matching: find.text(editedLabel),
          ),
          settle: false,
        );
        await _waitUntil(
          tester,
          () {
            final workspace = container.read(sessionManagerProvider);
            return workspace.activeTab?.closed == true &&
                workspace.lastError != null;
          },
          approveQaHost: true,
          reason:
              'The controlled SSH fixture did not reject the saved wrong password.',
        );
        attempt.stop();
        expect(controlledQaHostApprovals, approvalsBefore + 1);
        final rejected = container.read(sessionManagerProvider);
        final rejection = rejected.lastError!;
        expect(rejection, contains('SSH_AUTHENTICATION_REJECTED'));
        expect(rejection.toUpperCase(), isNot(contains('TIMEOUT')));
        expect(
          rejected.activeTab!.closeReason,
          contains('SSH_AUTHENTICATION_REJECTED'),
        );
        expect(rejected.activeTab!.sessionId, isNull);
        final visibleError = translateAppMessage(AppLanguage.vi, rejection);
        expect(visibleError, contains('Máy chủ từ chối xác thực SSH'));
        expect(find.text(visibleError), findsOneWidget);
        await _capture(
          tester,
          captureKey,
          shots,
          'ssh-authentication-rejected',
        );
        debugPrint(
          'TERMPULSE_MOBILE_SSH_REJECTION_MS=${attempt.elapsedMilliseconds}',
        );

        await _tap(tester, find.byTooltip('Host'));
        await _tap(tester, _key('mobileEditHost_${created.id}'));
        expect(
          tester.widget<TextField>(_field('Username')).controller!.text,
          'ops',
        );
        await _enter(tester, passwordField, 'termpulse2026');
        await _tap(
          tester,
          find.widgetWithText(FilledButton, 'Lưu Host'),
          settle: false,
        );
        await _waitUntil(
          tester,
          () =>
              find.text('Chỉnh sửa Host').evaluate().isEmpty &&
              container
                  .read(inventoryProvider)
                  .hosts
                  .any(
                    (host) =>
                        host.id == created.id &&
                        host.identityId != usernameEditedHost.identityId,
                  ),
          reason:
              'Editing the saved SSH password did not persist its new identity.',
        );
        final correctedHost = (await backend.listHosts()).singleWhere(
          (host) => host.id == created.id,
        );
        final correctedIdentity = (await backend.listIdentities()).singleWhere(
          (identity) => identity.id == correctedHost.identityId,
        );
        expect(correctedIdentity.username, 'ops');
        expect(
          correctedIdentity.credentialId,
          isNot(usernameEditedIdentity.credentialId),
        );
        await _tap(
          tester,
          find.descendant(
            of: _key('mobileHostCard_${created.id}'),
            matching: find.text(editedLabel),
          ),
          settle: false,
        );
        await _waitUntil(
          tester,
          () {
            final tab = container.read(sessionManagerProvider).activeTab;
            return tab?.sessionId != null &&
                tab!.closed == false &&
                tab.terminal.buffer.getText().contains('WELCOME_TERMPULSE');
          },
          approveQaHost: true,
          reason:
              'The same saved mobile host failed to connect after correcting its password.',
        );
        expect(
          controlledQaHostApprovals,
          approvalsBefore + 1,
          reason: 'The unchanged controlled host key should remain trusted.',
        );
        expect(container.read(sessionManagerProvider).lastError, isNull);
        await _capture(tester, captureKey, shots, 'ssh-after-password-edit');
        await _tap(tester, find.byTooltip('Host'));
        await container
            .read(sessionManagerProvider.notifier)
            .closeAllSessions();
        await tester.pumpAndSettle();
        (binding.reportData ??= <String, dynamic>{})['sshPasswordCorrection'] =
            'passed';
        debugPrint('TERMPULSE_MOBILE_SSH_PASSWORD_CORRECTION_PASS');
      } else {
        (binding.reportData ??= <String, dynamic>{})['sshPasswordCorrection'] =
            'skipped_no_QA_MOBILE_SSH_ERRORS';
        debugPrint('TERMPULSE_MOBILE_SSH_ERRORS_SKIPPED');
      }

      await _tap(tester, _key('mobileDeleteHost_${created.id}'));
      expect(_key('mobileDeleteHostDialog'), findsOneWidget);
      expect(
        find.descendant(
          of: _key('mobileDeleteHostDialog'),
          matching: find.textContaining(editedLabel),
        ),
        findsWidgets,
      );
      await _capture(tester, captureKey, shots, 'host-delete-confirmation');
      await _tap(tester, _key('mobileDeleteHostCancel'));
      expect(_key('mobileDeleteHostDialog'), findsNothing);
      expect(
        (await backend.listHosts()).any((host) => host.id == created.id),
        isTrue,
      );

      await _tap(tester, _key('mobileDeleteHost_${created.id}'));
      await _tap(tester, _key('mobileDeleteHostConfirm'), settle: false);
      await _waitUntil(
        tester,
        () =>
            !container
                .read(inventoryProvider)
                .hosts
                .any((host) => host.id == created.id) &&
            _key('mobileDeleteHostDialog').evaluate().isEmpty,
        reason:
            'Confirming mobile host deletion did not remove its native record.',
      );
      await inventory.refreshAll();
      await tester.pumpAndSettle();
      final remaining = await backend.listHosts();
      expect(remaining, hasLength(1));
      expect(remaining.single.id, sentinel.id);
      expect(remaining.single.label, sentinel.label);
      expect(remaining.single.hostname, sentinel.hostname);
      expect(remaining.single.notes, sentinel.notes);
      expect(_key('mobileHostCard_${created.id}'), findsNothing);
      expect(_key('mobileHostCard_${sentinel.id}'), findsOneWidget);
      expect(container.read(inventoryProvider).error, isNull);
      expect(container.read(sessionManagerProvider).tabs, isEmpty);
      await _capture(tester, captureKey, shots, 'host-deleted');
      expect(tester.takeException(), isNull);

      await cleanup();
      binding.reportData = <String, dynamic>{
        ...?binding.reportData,
        'screenshotDirectory': shots.path,
        'hostCrud': 'passed',
      };
      debugPrint('TERMPULSE_MOBILE_HOST_SCREENSHOT_DIR=${shots.path}');
      debugPrint('TERMPULSE_MOBILE_HOST_ACTIONS_PASS');
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
