import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/legal_config.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/settings/app_permissions_screen.dart';
import 'package:termpulse/features/settings/privacy_policy_screen.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';

import 'widget_test.dart' show FakeCoreBackend;
import 'qa_onboarding_capture.dart';

const _channel = MethodChannel('com.termpulse.termpulse/foreground');

Map<String, bool> _status({
  bool granted = false,
  bool notificationsEnabled = false,
  bool channelEnabled = true,
  bool canRequest = true,
  bool shouldShowRationale = false,
}) => {
  'required': true,
  'granted': granted,
  'notificationsEnabled': notificationsEnabled,
  'channelEnabled': channelEnabled,
  'canRequest': canRequest,
  'shouldShowRationale': shouldShowRationale,
};

class _NativePermissions {
  final calls = <MethodCall>[];
  Map<String, bool> status = _status();
  Map<String, bool>? requestResult;
  Completer<Object?>? statusPending;
  PlatformException? statusError;
  PlatformException? requestError;
  PlatformException? settingsError;

  int callsFor(String method) =>
      calls.where((call) => call.method == method).length;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'getNotificationPermissionStatus':
        if (statusError case final error?) throw error;
        if (statusPending case final pending?) return pending.future;
        return status;
      case 'requestNotificationPermission':
        if (requestError case final error?) throw error;
        status = requestResult ?? status;
        return status;
      case 'openNotificationSettings':
        if (settingsError case final error?) throw error;
        return true;
      case 'getDataDir':
        return '/tmp/termpulse-permission-test';
      default:
        return true;
    }
  }
}

Future<void> _mount(
  WidgetTester tester,
  Widget screen, {
  AppLanguage language = AppLanguage.vi,
  AppThemePreset preset = AppThemePreset.dark,
  double textScale = 1,
  bool settle = true,
  Size size = const Size(412, 915),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [backendProvider.overrideWithValue(FakeCoreBackend())],
      child: RepaintBoundary(
        key: qaOnboardingCaptureKey,
        child: MaterialApp(
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
          home: screen,
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(target, 200);
    await tester.pumpAndSettle();
  }
  if (target.hitTestable().evaluate().isEmpty) {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }
  await tester.tap(target);
  await tester.pumpAndSettle();
}

String _statusText(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const Key('notificationPermissionStatus')))
    .data!;

Future<void> _emitStopped(String reason) => TestDefaultBinaryMessengerBinding
    .instance
    .defaultBinaryMessenger
    .handlePlatformMessage(
      _channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('foregroundServiceStopped', {'reason': reason}),
      ),
      null,
    );

void _androidTest(String description, WidgetTesterCallback callback) =>
    testWidgets(
      description,
      callback,
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadQaOnboardingFonts);
  late _NativePermissions native;

  setUp(() async {
    native = _NativePermissions();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, native.handle);
    await ForegroundBridge.syncActiveCount(0, language: AppLanguage.vi);
    native.calls.clear();
  });

  tearDown(() async {
    await ForegroundBridge.syncActiveCount(0, language: AppLanguage.vi);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  _androidTest('privacy policy is readable offline in Vietnamese and English', (
    tester,
  ) async {
    await _mount(tester, const PrivacyPolicyScreen());
    expect(find.byKey(const Key('privacyPolicyScreen')), findsOneWidget);
    expect(find.text('1. Phạm vi và lựa chọn của bạn'), findsOneWidget);
    expect(
      find.textContaining('Đây không phải mã hóa toàn bộ cơ sở dữ liệu'),
      findsOneWidget,
    );
    expect(AppLegalConfig.isConfigured, isFalse);
    expect(find.byKey(const Key('privacyConfigurationNotice')), findsOneWidget);
    expect(find.textContaining('BẢN THỬ NGHIỆM'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'English'));
    await tester.pumpAndSettle();
    expect(find.text('1. Scope and your choices'), findsOneWidget);
    expect(
      find.textContaining('This is not full-database encryption'),
      findsOneWidget,
    );
    expect(find.textContaining('TEST BUILD'), findsOneWidget);
    expect(find.text('1. Phạm vi và lựa chọn của bạn'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Tiếng Việt'));
    await tester.pumpAndSettle();
    expect(find.text('1. Phạm vi và lựa chọn của bạn'), findsOneWidget);
    expect(native.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  _androidTest('privacy policy defaults to English for an English app', (
    tester,
  ) async {
    await _mount(tester, const PrivacyPolicyScreen(), language: AppLanguage.en);
    expect(find.text('1. Scope and your choices'), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'English'))
          .selected,
      isTrue,
    );
    expect(native.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  _androidTest('locked Vault opens privacy before requesting any permission', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [backendProvider.overrideWithValue(FakeCoreBackend())],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TermPulseApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(vaultProvider).unlocked, isFalse);
    expect(native.callsFor('requestNotificationPermission'), 0);
    await _tap(tester, 'privacyButton');
    expect(find.byKey(const Key('privacyPolicyScreen')), findsOneWidget);
    expect(container.read(vaultProvider).unlocked, isFalse);
    expect(native.callsFor('requestNotificationPermission'), 0);
    expect(tester.takeException(), isNull);
  });

  _androidTest('permission screen loads status without asking on startup', (
    tester,
  ) async {
    final pending = Completer<Object?>();
    native.statusPending = pending;
    await _mount(tester, const AppPermissionsScreen(), settle: false);
    expect(find.byKey(const Key('permissionsScreen')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(native.callsFor('getNotificationPermissionStatus'), 1);
    expect(native.callsFor('requestNotificationPermission'), 0);

    pending.complete(
      _status(granted: true, notificationsEnabled: true, canRequest: false),
    );
    await tester.pumpAndSettle();
    expect(_statusText(tester), 'Thông báo đã bật');
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      find.byKey(const Key('requestNotificationPermission')),
      findsNothing,
    );
    expect(native.callsFor('requestNotificationPermission'), 0);
    expect(tester.takeException(), isNull);
  });

  _androidTest('permission rationale can be cancelled before native request', (
    tester,
  ) async {
    native.status = _status(shouldShowRationale: true);
    await _mount(tester, const AppPermissionsScreen());
    expect(_statusText(tester), 'Chưa cấp quyền thông báo');
    await _tap(tester, 'requestNotificationPermission');
    expect(
      find.byKey(const Key('notificationPermissionRationale')),
      findsOneWidget,
    );
    expect(native.callsFor('requestNotificationPermission'), 0);
    await _tap(tester, 'cancelNotificationPermission');
    expect(
      find.byKey(const Key('notificationPermissionRationale')),
      findsNothing,
    );
    expect(native.callsFor('requestNotificationPermission'), 0);
    expect(_statusText(tester), 'Chưa cấp quyền thông báo');
    expect(tester.takeException(), isNull);
  });

  for (final preset in AppThemePreset.values) {
    for (final language in [AppLanguage.vi, AppLanguage.en]) {
      _androidTest(
        'rationale fits small phone large text in ${preset.name}/${language.code}',
        (tester) async {
          await _mount(
            tester,
            const AppPermissionsScreen(),
            size: const Size(360, 640),
            preset: preset,
            language: language,
            textScale: 1.6,
          );
          await _tap(tester, 'requestNotificationPermission');
          final dialog = find.byKey(
            const Key('notificationPermissionRationale'),
          );
          expect(dialog, findsOneWidget);
          expect(
            Theme.of(tester.element(dialog)).brightness,
            preset == AppThemePreset.dark ? Brightness.dark : Brightness.light,
          );
          final bounds = tester.getRect(dialog);
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(360));
          expect(bounds.top, greaterThanOrEqualTo(0));
          expect(bounds.bottom, lessThanOrEqualTo(640));
          for (final source in [
            'Cho phép thông báo?',
            'Thông báo phiên kết nối',
            'TermPulse dùng thông báo để hiển thị số phiên và nút tắt hỗ trợ chạy nền. Bạn có thể từ chối và tiếp tục dùng ứng dụng. Android vẫn có thể giới hạn phiên chạy nền.',
            'Để sau',
            'Tiếp tục',
          ]) {
            expect(
              find.descendant(
                of: dialog,
                matching: find.text(translateAppMessage(language, source)),
              ),
              findsOneWidget,
            );
            if (language != AppLanguage.vi) {
              expect(translateAppMessage(language, source), isNot(source));
            }
          }
          expect(
            find.byKey(const Key('cancelNotificationPermission')).hitTestable(),
            findsOneWidget,
          );
          expect(
            find
                .byKey(const Key('confirmNotificationPermission'))
                .hitTestable(),
            findsOneWidget,
          );
          expect(native.callsFor('requestNotificationPermission'), 0);
          expect(tester.takeException(), isNull);
          await captureOnboarding(
            tester,
            'rationale_${preset.name}_${language.code}_360x640_text1.6',
          );
          await _tap(tester, 'cancelNotificationPermission');
          expect(dialog, findsNothing);
          expect(native.callsFor('requestNotificationPermission'), 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  _androidTest(
    'explicit rationale confirmation reports denial then later grant',
    (tester) async {
      native.requestResult = _status(shouldShowRationale: true);
      await _mount(tester, const AppPermissionsScreen());
      await _tap(tester, 'requestNotificationPermission');
      await _tap(tester, 'confirmNotificationPermission');
      expect(native.callsFor('requestNotificationPermission'), 1);
      expect(_statusText(tester), 'Chưa cấp quyền thông báo');

      native.requestResult = _status(
        granted: true,
        notificationsEnabled: true,
        canRequest: false,
      );
      await _tap(tester, 'requestNotificationPermission');
      expect(native.callsFor('requestNotificationPermission'), 1);
      await _tap(tester, 'confirmNotificationPermission');
      expect(native.callsFor('requestNotificationPermission'), 2);
      expect(_statusText(tester), 'Thông báo đã bật');
      expect(
        find.byKey(const Key('requestNotificationPermission')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  _androidTest('permanent denial routes to settings and refreshes on resume', (
    tester,
  ) async {
    native.status = _status(canRequest: false);
    await _mount(tester, const AppPermissionsScreen());
    expect(
      find.byKey(const Key('requestNotificationPermission')),
      findsNothing,
    );
    await _tap(tester, 'openNotificationSettings');
    expect(native.callsFor('openNotificationSettings'), 1);
    expect(native.callsFor('requestNotificationPermission'), 0);

    native.status = _status(
      granted: true,
      notificationsEnabled: true,
      canRequest: false,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(native.callsFor('getNotificationPermissionStatus'), 2);
    expect(_statusText(tester), 'Thông báo đã bật');
    expect(tester.takeException(), isNull);
  });

  _androidTest(
    'blocked notification channel offers settings without reasking',
    (tester) async {
      native.status = _status(
        granted: true,
        notificationsEnabled: true,
        channelEnabled: false,
        canRequest: false,
      );
      await _mount(tester, const AppPermissionsScreen());
      expect(_statusText(tester), 'Kênh thông báo phiên đang tắt');
      expect(
        find.byKey(const Key('requestNotificationPermission')),
        findsNothing,
      );
      await _tap(tester, 'openNotificationSettings');
      expect(native.callsFor('openNotificationSettings'), 1);
      expect(native.callsFor('requestNotificationPermission'), 0);
      expect(tester.takeException(), isNull);
    },
  );

  _androidTest('status read error is visible and manual refresh retries', (
    tester,
  ) async {
    native.statusError = PlatformException(code: 'unavailable');
    await _mount(tester, const AppPermissionsScreen());
    expect(find.byKey(const Key('permissionsError')), findsOneWidget);
    expect(find.text('Không đọc được trạng thái quyền.'), findsOneWidget);
    expect(
      find.byKey(const Key('requestNotificationPermission')),
      findsNothing,
    );
    native.statusError = null;
    await _tap(tester, 'refreshNotificationPermission');
    expect(native.callsFor('getNotificationPermissionStatus'), 2);
    expect(find.byKey(const Key('permissionsError')), findsNothing);
    expect(_statusText(tester), 'Chưa cấp quyền thông báo');
    expect(native.callsFor('requestNotificationPermission'), 0);
    expect(tester.takeException(), isNull);
  });

  _androidTest('native request errors remain visible and can be retried', (
    tester,
  ) async {
    native.requestError = PlatformException(code: 'request_failed');
    await _mount(tester, const AppPermissionsScreen());
    await _tap(tester, 'requestNotificationPermission');
    await _tap(tester, 'confirmNotificationPermission');
    expect(find.text('Không thể yêu cầu quyền thông báo.'), findsOneWidget);
    expect(native.callsFor('requestNotificationPermission'), 1);

    native.requestError = null;
    native.requestResult = _status(
      granted: true,
      notificationsEnabled: true,
      canRequest: false,
    );
    await _tap(tester, 'requestNotificationPermission');
    await _tap(tester, 'confirmNotificationPermission');
    expect(native.callsFor('requestNotificationPermission'), 2);
    expect(_statusText(tester), 'Thông báo đã bật');
    expect(find.byKey(const Key('permissionsError')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  _androidTest(
    'settings failure is visible and a retry opens native settings',
    (tester) async {
      native.status = _status(canRequest: false);
      native.settingsError = PlatformException(code: 'settings_failed');
      await _mount(tester, const AppPermissionsScreen());
      await _tap(tester, 'openNotificationSettings');
      expect(find.text('Không mở được cài đặt thông báo.'), findsOneWidget);
      native.settingsError = null;
      await _tap(tester, 'openNotificationSettings');
      expect(native.callsFor('openNotificationSettings'), 2);
      expect(find.byKey(const Key('permissionsError')), findsNothing);
      expect(native.callsFor('requestNotificationPermission'), 0);
      expect(tester.takeException(), isNull);
    },
  );

  _androidTest('background support resumes only after the explicit action', (
    tester,
  ) async {
    await ForegroundBridge.syncActiveCount(2);
    await _emitStopped('timeout');
    native.calls.clear();
    await _mount(tester, const AppPermissionsScreen());
    expect(native.callsFor('startService'), 0);
    expect(find.text('Android đã giới hạn thời gian chạy nền'), findsOneWidget);
    expect(find.byKey(const Key('resumeBackgroundSupport')), findsOneWidget);
    await _tap(tester, 'resumeBackgroundSupport');
    expect(native.callsFor('startService'), 1);
    final start = native.calls.singleWhere(
      (call) => call.method == 'startService',
    );
    expect(start.arguments['count'], 2);
    expect(find.byKey(const Key('resumeBackgroundSupport')), findsNothing);
    expect(native.callsFor('requestNotificationPermission'), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'non-Android permissions screen makes no native channel calls',
    (tester) async {
      await _mount(tester, const AppPermissionsScreen());
      expect(_statusText(tester), 'Không áp dụng trên nền tảng này');
      expect(
        find.byKey(const Key('requestNotificationPermission')),
        findsNothing,
      );
      expect(find.byKey(const Key('openNotificationSettings')), findsNothing);
      expect(find.byKey(const Key('resumeBackgroundSupport')), findsNothing);
      await _tap(tester, 'refreshNotificationPermission');
      expect(native.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}
