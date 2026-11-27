import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/vault/vault_welcome_gate.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';

import 'widget_test.dart' show FakeCoreBackend;
import 'qa_onboarding_capture.dart';

const _channel = MethodChannel('com.termpulse.termpulse/foreground');

const _welcomeSources = [
  'Vault đã sẵn sàng',
  'Chào mừng đến với TermPulse. Thêm máy chủ đầu tiên để bắt đầu kết nối.',
  'Lưu cục bộ trên thiết bị',
  'Mật khẩu kết nối và khóa bí mật được mã hóa trong Vault. Thông tin máy chủ và lịch sử lệnh không được mã hóa.',
  'Giữ an toàn mật khẩu chính',
  'Bạn cần mật khẩu này để mở lại Vault.',
  'Bắt đầu sử dụng',
  'Quyền và thông báo',
  'Chính sách quyền riêng tư',
];

class _MemorySettings extends SettingsController {
  _MemorySettings(this.language, this.preset);
  final AppLanguage language;
  final AppThemePreset preset;

  @override
  AppSettingsState build() =>
      AppSettingsState(language: language, themePreset: preset);

  @override
  void setLanguage(AppLanguage language) {
    state = state.copyWith(language: language);
  }
}

Future<ProviderContainer> _mount(
  WidgetTester tester, {
  FakeCoreBackend? backend,
  bool existingVault = false,
  bool fullApp = false,
  Size size = const Size(412, 915),
  AppThemePreset preset = AppThemePreset.dark,
  AppLanguage language = AppLanguage.vi,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = backend ?? FakeCoreBackend();
  if (existingVault) {
    await fake.vaultUnlock('existing-test-vault');
    await fake.vaultLock();
  }
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWithValue(fake),
      settingsProvider.overrideWith(() => _MemorySettings(language, preset)),
    ],
  );
  addTearDown(container.dispose);
  if (existingVault) {
    await container
        .read(vaultProvider.notifier)
        .initAtPath('/tmp/existing-test-vault.db');
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: qaOnboardingCaptureKey,
        child: fullApp
            ? const TermPulseApp()
            : MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: qaOnboardingTheme(buildTermPulseTheme(preset)),
                builder: (context, child) => AppLocalizationScope(
                  language: language,
                  child: MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(textScale)),
                    child: child!,
                  ),
                ),
                home: const VaultWelcomeGate(
                  child: Scaffold(body: Center(child: Text('Workspace'))),
                ),
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _createVault(
  WidgetTester tester,
  ProviderContainer container,
) async {
  expect(
    await container.read(vaultProvider.notifier).unlock('test-master-password'),
    isTrue,
  );
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('vaultCreatedDialog')), findsOneWidget);
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  if (target.hitTestable().evaluate().isEmpty) {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void _androidTest(String description, WidgetTesterCallback callback) =>
    testWidgets(
      description,
      callback,
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadQaOnboardingFonts);
  final calls = <MethodCall>[];

  int callsFor(String method) =>
      calls.where((call) => call.method == method).length;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          if (call.method == 'getNotificationPermissionStatus') {
            return {
              'required': true,
              'granted': false,
              'notificationsEnabled': false,
              'channelEnabled': true,
              'canRequest': true,
              'shouldShowRationale': false,
            };
          }
          if (call.method == 'getDataDir') return '/tmp/termpulse-welcome-test';
          return true;
        });
    await ForegroundBridge.syncActiveCount(0, language: AppLanguage.vi);
    calls.clear();
  });

  tearDown(() async {
    await ForegroundBridge.syncActiveCount(0, language: AppLanguage.vi);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  _androidTest(
    'successful creation in the app shows welcome and Continue exits',
    (tester) async {
      final container = await _mount(tester, fullApp: true);
      expect(find.byKey(const Key('vaultCreatedDialog')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('vaultPasswordField')),
        'test-master-password',
      );
      await tester.enterText(
        find.byKey(const Key('vaultConfirmPasswordField')),
        'test-master-password',
      );
      await _tap(tester, 'vaultSubmitButton');
      expect(container.read(vaultProvider).initialized, isTrue);
      expect(container.read(vaultProvider).unlocked, isTrue);
      expect(find.byKey(const Key('vaultCreatedDialog')), findsOneWidget);
      expect(callsFor('requestNotificationPermission'), 0);
      expect(callsFor('getNotificationPermissionStatus'), 0);
      await _tap(tester, 'vaultWelcomeContinue');
      expect(find.byKey(const Key('vaultCreatedDialog')), findsNothing);
      expect(find.byKey(const Key('mobileShell')), findsOneWidget);
      expect(callsFor('requestNotificationPermission'), 0);
      expect(tester.takeException(), isNull);
    },
  );

  _androidTest('creation welcome is shown once and not after lock and unlock', (
    tester,
  ) async {
    final container = await _mount(tester);
    await _createVault(tester, container);
    await _tap(tester, 'vaultWelcomeContinue');
    await container.read(vaultProvider.notifier).lock();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vaultCreatedDialog')), findsNothing);
    expect(
      await container
          .read(vaultProvider.notifier)
          .unlock('test-master-password'),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vaultCreatedDialog')), findsNothing);
    container.read(settingsProvider.notifier).setLanguage(AppLanguage.en);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vaultCreatedDialog')), findsNothing);
    expect(callsFor('requestNotificationPermission'), 0);
    expect(tester.takeException(), isNull);
  });

  _androidTest(
    'normal unlock of an existing Vault never shows creation welcome',
    (tester) async {
      final container = await _mount(tester, existingVault: true);
      expect(container.read(vaultProvider).initialized, isTrue);
      expect(container.read(vaultProvider).unlocked, isFalse);
      expect(
        await container
            .read(vaultProvider.notifier)
            .unlock('existing-test-vault'),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vaultCreatedDialog')), findsNothing);
      expect(callsFor('requestNotificationPermission'), 0);
      expect(tester.takeException(), isNull);
    },
  );

  _androidTest(
    'failed creation shows no welcome and later success still does',
    (tester) async {
      final container = await _mount(tester);
      expect(
        await container.read(vaultProvider.notifier).unlock('wrong'),
        isFalse,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vaultCreatedDialog')), findsNothing);
      expect(container.read(vaultProvider).initialized, isFalse);
      await _createVault(tester, container);
      expect(callsFor('requestNotificationPermission'), 0);
      expect(tester.takeException(), isNull);
    },
  );

  _androidTest('privacy opened from welcome returns to the same dialog', (
    tester,
  ) async {
    final container = await _mount(tester);
    await _createVault(tester, container);
    await _tap(tester, 'vaultWelcomePrivacy');
    expect(find.byKey(const Key('privacyPolicyScreen')), findsOneWidget);
    expect(
      find.byKey(const Key('vaultCreatedDialog'), skipOffstage: false),
      findsOneWidget,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vaultCreatedDialog')), findsOneWidget);
    await _tap(tester, 'vaultWelcomeContinue');
    expect(find.byKey(const Key('vaultCreatedDialog')), findsNothing);
    expect(callsFor('requestNotificationPermission'), 0);
    expect(tester.takeException(), isNull);
  });

  _androidTest(
    'welcome opens permissions only on explicit action without OS ask',
    (tester) async {
      final container = await _mount(tester);
      await _createVault(tester, container);
      expect(callsFor('getNotificationPermissionStatus'), 0);
      expect(callsFor('requestNotificationPermission'), 0);
      await _tap(tester, 'vaultWelcomePermissions');
      expect(find.byKey(const Key('vaultCreatedDialog')), findsNothing);
      expect(find.byKey(const Key('permissionsScreen')), findsOneWidget);
      expect(callsFor('getNotificationPermissionStatus'), 1);
      expect(callsFor('requestNotificationPermission'), 0);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vaultCreatedDialog')), findsNothing);
      expect(callsFor('requestNotificationPermission'), 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'non-Android creation welcome omits the Android permission action',
    (tester) async {
      final container = await _mount(tester);
      await _createVault(tester, container);
      expect(find.byKey(const Key('vaultWelcomePermissions')), findsNothing);
      await _tap(tester, 'vaultWelcomeContinue');
      expect(calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  for (final preset in AppThemePreset.values) {
    _androidTest('standard phone welcome and rationale in ${preset.name}', (
      tester,
    ) async {
      final container = await _mount(tester, preset: preset);
      await _createVault(tester, container);
      await captureOnboarding(tester, 'welcome_${preset.name}_vi_412x915');
      expect(tester.takeException(), isNull);
      await _tap(tester, 'vaultWelcomePermissions');
      await _tap(tester, 'requestNotificationPermission');
      expect(
        find.byKey(const Key('notificationPermissionRationale')),
        findsOneWidget,
      );
      await captureOnboarding(tester, 'rationale_${preset.name}_vi_412x915');
      expect(callsFor('requestNotificationPermission'), 0);
      await _tap(tester, 'cancelNotificationPermission');
      expect(
        find.byKey(const Key('notificationPermissionRationale')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final preset in AppThemePreset.values) {
    for (final language in AppLanguage.values) {
      _androidTest(
        'welcome fits small phone large text in ${preset.name}/${language.code}',
        (tester) async {
          final container = await _mount(
            tester,
            size: const Size(360, 640),
            preset: preset,
            language: language,
            textScale: 1.6,
          );
          await _createVault(tester, container);
          final dialog = find.byKey(const Key('vaultCreatedDialog'));
          expect(
            Theme.of(tester.element(dialog)).brightness,
            preset == AppThemePreset.dark ? Brightness.dark : Brightness.light,
          );
          final expectedTexts = _welcomeSources.map(
            (source) => translateAppMessage(language, source),
          );
          expect(
            tester
                .widgetList<Text>(
                  find.descendant(of: dialog, matching: find.byType(Text)),
                )
                .map((text) => text.data),
            unorderedEquals(expectedTexts),
          );
          if (language != AppLanguage.vi) {
            for (final source in _welcomeSources) {
              expect(
                translateAppMessage(language, source),
                isNot(source),
                reason: 'Missing ${language.code} translation for $source',
              );
              expect(find.text(source), findsNothing);
            }
          }
          final bounds = tester.getRect(dialog);
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(360));
          expect(bounds.top, greaterThanOrEqualTo(0));
          expect(bounds.bottom, lessThanOrEqualTo(640));
          for (final key in [
            'vaultWelcomePrivacy',
            'vaultWelcomePermissions',
          ]) {
            final control = find.byKey(Key(key));
            await tester.ensureVisible(control);
            await tester.pumpAndSettle();
            expect(control.hitTestable(), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          await _tap(tester, 'vaultWelcomeContinue');
          expect(find.byKey(const Key('vaultCreatedDialog')), findsNothing);
          expect(callsFor('requestNotificationPermission'), 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
