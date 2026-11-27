// Native Android welcome QA. Build this target, install the APK with -r, and
// launch its Activity directly; do not use the integration driver that removes
// the app during cleanup. Only a new temporary Vault is initialized here.
// Screenshots stay in private app-data/qa_onboarding_shots for the host to pull.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/src/rust/frb_generated.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';

// Exercise the normal notifier API without replacing the user's saved theme.
class _MemorySettings extends SettingsController {
  @override
  void setThemePreset(AppThemePreset preset) {
    state = state.copyWith(themePreset: preset);
  }
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() ready, {
  required String reason,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (ready()) return;
  }
  fail(reason);
}

Future<void> _tap(WidgetTester tester, String key, {bool settle = true}) async {
  final target = find.byKey(Key(key));
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Map<String, bool> _permissionSnapshot(NotificationPermissionStatus status) => {
  'required': status.required,
  'granted': status.granted,
  'notificationsEnabled': status.notificationsEnabled,
  'channelEnabled': status.channelEnabled,
  'canRequest': status.canRequest,
  'shouldShowRationale': status.shouldShowRationale,
};

Future<void> _capture(
  WidgetTester tester,
  GlobalKey key,
  Directory directory,
  String name,
) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
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
    'Native Android Vault welcome themes privacy permissions and ordinary unlock',
    (tester) async {
      tester.testTextInput.register();
      final appData = Directory(await ForegroundBridge.getAppDataDir());
      await appData.create(recursive: true);
      final fixture = await appData.createTemp('qa_vault_welcome_');
      final shots = Directory(
        '${appData.path}${Platform.pathSeparator}qa_onboarding_shots',
      );
      await shots.create(recursive: true);
      final container = ProviderContainer(
        overrides: [settingsProvider.overrideWith(_MemorySettings.new)],
      );
      final backend = container.read(backendProvider);
      var cleaned = false;
      Future<void> cleanup() async {
        if (cleaned) return;
        cleaned = true;
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await backend.vaultLock();
        } finally {
          container.dispose();
          tester.testTextInput.unregister();
          if (await fixture.exists()) await fixture.delete(recursive: true);
        }
      }

      addTearDown(cleanup);
      final permissionBefore = _permissionSnapshot(
        await ForegroundBridge.getNotificationPermissionStatus(),
      );
      final vault = container.read(vaultProvider.notifier);
      await vault.initAtPath(
        '${fixture.path}${Platform.pathSeparator}vault.db',
      );
      expect(container.read(vaultProvider).error, isNull);
      expect(container.read(vaultProvider).initialized, isFalse);
      expect(container.read(vaultProvider).unlocked, isFalse);

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
      expect(find.byKey(const Key('vaultCreatedDialog')), findsNothing);
      expect(
        find.byKey(const Key('vaultConfirmPasswordField')),
        findsOneWidget,
      );
      const temporaryPassword = 'VaultWelcome-QA-2026!';
      await tester.enterText(
        find.byKey(const Key('vaultPasswordField')),
        temporaryPassword,
      );
      await tester.enterText(
        find.byKey(const Key('vaultConfirmPasswordField')),
        temporaryPassword,
      );
      await _tap(tester, 'vaultSubmitButton', settle: false);
      await _waitUntil(
        tester,
        () =>
            container.read(vaultProvider).unlocked &&
            find.byKey(const Key('vaultCreatedDialog')).evaluate().isNotEmpty,
        reason: 'Native temporary Vault creation did not show its welcome UI.',
      );
      await tester.pumpAndSettle();
      expect(container.read(vaultProvider).error, isNull);
      expect(find.byKey(const Key('vaultWelcomeTitle')), findsOneWidget);
      expect(find.byKey(const Key('vaultWelcomeContinue')), findsOneWidget);
      expect(find.byKey(const Key('vaultWelcomePermissions')), findsOneWidget);
      expect(find.byKey(const Key('vaultWelcomePrivacy')), findsOneWidget);
      final welcome = find.byKey(const Key('vaultCreatedDialog'));
      expect(Theme.of(tester.element(welcome)).brightness, Brightness.dark);
      await _capture(tester, captureKey, shots, 'welcome-dark');

      final settings = container.read(settingsProvider.notifier);
      settings.setThemePreset(AppThemePreset.light);
      await tester.pumpAndSettle();
      expect(welcome, findsOneWidget);
      expect(Theme.of(tester.element(welcome)).brightness, Brightness.light);
      await _capture(tester, captureKey, shots, 'welcome-light');
      settings.setThemePreset(AppThemePreset.dark);
      await tester.pumpAndSettle();

      await _tap(tester, 'vaultWelcomePrivacy');
      expect(find.byKey(const Key('privacyPolicyScreen')), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(welcome, findsOneWidget);

      await _tap(tester, 'vaultWelcomePermissions');
      expect(welcome, findsNothing);
      expect(find.byKey(const Key('permissionsScreen')), findsOneWidget);
      await _waitUntil(
        tester,
        () => find
            .byKey(const Key('notificationPermissionStatus'))
            .evaluate()
            .isNotEmpty,
        reason: 'The real Android notification status did not load.',
      );
      expect(find.byKey(const Key('permissionsError')), findsNothing);
      final request = find.byKey(const Key('requestNotificationPermission'));
      if (request.evaluate().isNotEmpty) {
        await _tap(tester, 'requestNotificationPermission');
        expect(
          find.byKey(const Key('notificationPermissionRationale')),
          findsOneWidget,
        );
        await _capture(tester, captureKey, shots, 'permission-rationale');
        await _tap(tester, 'cancelNotificationPermission');
        expect(
          find.byKey(const Key('notificationPermissionRationale')),
          findsNothing,
        );
        (binding.reportData ??= <String, dynamic>{})['rationale'] = 'cancelled';
      } else {
        // A granted or permanently denied state may have no request action.
        // Never change system permissions or mislabel a screen as a rationale.
        (binding.reportData ??= <String, dynamic>{})['rationale'] =
            'skipped_no_request_action';
        debugPrint('TERMPULSE_VAULT_WELCOME_RATIONALE_SKIPPED');
      }
      expect(
        _permissionSnapshot(
          await ForegroundBridge.getNotificationPermissionStatus(),
        ),
        permissionBefore,
        reason:
            'Welcome navigation or cancelling rationale changed permission.',
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('permissionsScreen')), findsNothing);
      expect(welcome, findsNothing);

      await vault.lock();
      await _waitUntil(
        tester,
        () =>
            !container.read(vaultProvider).unlocked &&
            find.byKey(const Key('vaultPasswordField')).evaluate().isNotEmpty,
        reason: 'The temporary native Vault did not return to its lock screen.',
      );
      await tester.pumpAndSettle();
      expect(container.read(vaultProvider).error, isNull);
      expect(find.byKey(const Key('vaultConfirmPasswordField')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('vaultPasswordField')),
        temporaryPassword,
      );
      await _tap(tester, 'vaultSubmitButton', settle: false);
      await _waitUntil(
        tester,
        () =>
            container.read(vaultProvider).unlocked &&
            !container.read(vaultProvider).loading,
        reason: 'The temporary native Vault did not unlock again.',
      );
      await tester.pumpAndSettle();
      expect(container.read(vaultProvider).error, isNull);
      expect(
        welcome,
        findsNothing,
        reason: 'Ordinary unlock repeated onboarding.',
      );
      expect(tester.takeException(), isNull);

      await cleanup();
      (binding.reportData ??= <String, dynamic>{})['screenshotDirectory'] =
          shots.path;
      debugPrint('TERMPULSE_VAULT_WELCOME_SCREENSHOT_DIR=${shots.path}');
      debugPrint('TERMPULSE_VAULT_WELCOME_PASS');
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
