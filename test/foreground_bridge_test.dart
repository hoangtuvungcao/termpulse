import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/core/l10n.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.termpulse.termpulse/foreground');
  final calls = <MethodCall>[];
  Future<Object?> Function(MethodCall)? response;

  Map<String, bool> permissionStatus({
    bool required = true,
    bool granted = false,
    bool notificationsEnabled = false,
    bool channelEnabled = true,
    bool canRequest = true,
    bool shouldShowRationale = false,
  }) => {
    'required': required,
    'granted': granted,
    'notificationsEnabled': notificationsEnabled,
    'channelEnabled': channelEnabled,
    'canRequest': canRequest,
    'shouldShowRationale': shouldShowRationale,
  };

  Future<void> emitStopped(String reason) => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('foregroundServiceStopped', {'reason': reason}),
        ),
        null,
      );

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    response = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (response case final handler?) return handler(call);
          return true;
        });
    await ForegroundBridge.syncActiveCount(0, language: AppLanguage.vi);
    calls.clear();
  });

  tearDown(() async {
    response = null;
    await ForegroundBridge.syncActiveCount(0, language: AppLanguage.vi);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'foreground notification carries app language and session count',
    () async {
      const titles = {
        AppLanguage.vi: 'TermPulse đang hỗ trợ chạy nền',
        AppLanguage.en: 'TermPulse background support',
        AppLanguage.zh: 'TermPulse 后台支持',
        AppLanguage.ja: 'TermPulse のバックグラウンドサポート',
        AppLanguage.ko: 'TermPulse 백그라운드 지원',
      };
      for (final entry in titles.entries) {
        await ForegroundBridge.syncActiveCount(3, language: entry.key);
        final call = calls.last;
        expect(call.method, 'startService');
        expect(call.arguments['count'], 3);
        final strings = call.arguments['strings'] as Map;
        expect(strings['notification_title'], entry.value);
        expect(strings['notification_text'], contains('3'));
        expect(strings.values, everyElement(isNot(contains('{count}'))));
        expect(
          strings.keys,
          unorderedEquals([
            'notification_title',
            'notification_text',
            'notification_stop',
            'channel_name',
            'channel_description',
          ]),
        );
      }
    },
  );

  test(
    'changing language refreshes the current background notification',
    () async {
      await ForegroundBridge.syncActiveCount(2, language: AppLanguage.vi);
      calls.clear();
      await ForegroundBridge.syncLanguage(AppLanguage.en);
      expect(calls, hasLength(1));
      expect(calls.single.arguments['count'], 2);
      expect(
        calls.single.arguments['strings']['notification_text'],
        'Supporting 2 connected sessions',
      );
      expect(
        calls.single.arguments['strings']['notification_stop'],
        'Turn off background support',
      );
      expect(
        calls.single.arguments['strings']['channel_name'],
        'Background connections',
      );
      expect(
        calls.single.arguments['strings']['channel_description'],
        'Supports sessions while switching apps; Android may limit background time.',
      );

      await ForegroundBridge.syncLanguage(AppLanguage.en);
      expect(calls, hasLength(1));
      await ForegroundBridge.syncActiveCount(0);
      expect(calls.last.method, 'stopService');
      calls.clear();
      await ForegroundBridge.syncLanguage(AppLanguage.ja);
      expect(calls, isEmpty);
    },
  );

  test(
    'notification status distinguishes permission and notification blocks',
    () async {
      final cases = [
        permissionStatus(),
        permissionStatus(canRequest: false),
        permissionStatus(required: false, granted: true, canRequest: false),
        permissionStatus(granted: true, canRequest: false),
        permissionStatus(
          granted: true,
          notificationsEnabled: true,
          channelEnabled: false,
          canRequest: false,
        ),
        permissionStatus(
          granted: true,
          notificationsEnabled: true,
          canRequest: false,
        ),
      ];
      for (final native in cases) {
        response = (_) async => native;
        final status = await ForegroundBridge.getNotificationPermissionStatus();
        expect(calls.last.method, 'getNotificationPermissionStatus');
        expect(status.required, native['required']);
        expect(status.granted, native['granted']);
        expect(status.notificationsEnabled, native['notificationsEnabled']);
        expect(status.channelEnabled, native['channelEnabled']);
        expect(status.canRequest, native['canRequest']);
        expect(status.shouldShowRationale, native['shouldShowRationale']);
        expect(
          status.visible,
          native['granted']! &&
              native['notificationsEnabled']! &&
              native['channelEnabled']!,
        );
      }
      expect(calls, hasLength(cases.length));
      expect(
        calls.any((call) => call.method == 'requestNotificationPermission'),
        isFalse,
      );
    },
  );

  test('permission request reports denial rationale and later grant', () async {
    response = (_) async => permissionStatus(shouldShowRationale: true);
    final denied = await ForegroundBridge.requestNotificationPermission();
    expect(calls.single.method, 'requestNotificationPermission');
    expect(denied.granted, isFalse);
    expect(denied.visible, isFalse);
    expect(denied.canRequest, isTrue);
    expect(denied.shouldShowRationale, isTrue);

    response = (_) async => permissionStatus(
      granted: true,
      notificationsEnabled: true,
      canRequest: false,
    );
    final granted = await ForegroundBridge.requestNotificationPermission();
    expect(calls, hasLength(2));
    expect(granted.visible, isTrue);
    expect(granted.canRequest, isFalse);
  });

  test('notification settings uses the native settings action only', () async {
    await ForegroundBridge.openNotificationSettings();
    expect(calls, hasLength(1));
    expect(calls.single.method, 'openNotificationSettings');
  });

  test('permission bridge rejects malformed native status', () async {
    response = (_) async => true;
    await expectLater(
      ForegroundBridge.getNotificationPermissionStatus(),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'invalid_permission_status',
        ),
      ),
    );
  });

  test(
    'permission and settings errors remain visible to their callers',
    () async {
      response = (_) async => throw PlatformException(code: 'native_failed');
      final error = throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'native_failed',
        ),
      );
      await expectLater(
        ForegroundBridge.getNotificationPermissionStatus(),
        error,
      );
      await expectLater(
        ForegroundBridge.requestNotificationPermission(),
        error,
      );
      await expectLater(ForegroundBridge.openNotificationSettings(), error);
      expect(calls.map((call) => call.method), [
        'getNotificationPermissionStatus',
        'requestNotificationPermission',
        'openNotificationSettings',
      ]);
    },
  );

  for (final reason in ['user', 'timeout', 'start_failed']) {
    test(
      'native $reason stops background support until explicit retry',
      () async {
        await ForegroundBridge.syncActiveCount(2);
        expect(ForegroundBridge.backgroundStatus.value.running, isTrue);
        calls.clear();

        await emitStopped(reason);
        var status = ForegroundBridge.backgroundStatus.value;
        expect(status.running, isFalse);
        expect(status.activeSessions, 2);
        expect(status.stoppedReason, reason);

        await ForegroundBridge.syncActiveCount(3);
        await ForegroundBridge.syncLanguage(AppLanguage.en);
        expect(calls, isEmpty);
        status = ForegroundBridge.backgroundStatus.value;
        expect(status.activeSessions, 3);
        expect(status.stoppedReason, reason);
        expect(status.running, isFalse);

        await ForegroundBridge.resumeBackgroundSupport();
        expect(calls.single.method, 'startService');
        expect(calls.single.arguments['count'], 3);
        status = ForegroundBridge.backgroundStatus.value;
        expect(status.running, isTrue);
        expect(status.stoppedReason, isNull);
        expect(status.error, isNull);
      },
    );
  }

  test('explicit pause stops native support until the user resumes', () async {
    await ForegroundBridge.syncActiveCount(1);
    calls.clear();
    await ForegroundBridge.pauseBackgroundSupport();

    expect(calls.single.method, 'stopService');
    var status = ForegroundBridge.backgroundStatus.value;
    expect(status.activeSessions, 1);
    expect(status.running, isFalse);
    expect(status.stoppedReason, 'user');
    expect(status.error, isNull);
    calls.clear();

    await ForegroundBridge.syncActiveCount(2);
    await ForegroundBridge.syncLanguage(AppLanguage.en);
    expect(calls, isEmpty);
    status = ForegroundBridge.backgroundStatus.value;
    expect(status.activeSessions, 2);
    expect(status.running, isFalse);
    expect(status.stoppedReason, 'user');

    await ForegroundBridge.resumeBackgroundSupport();
    expect(calls.single.method, 'startService');
    expect(calls.single.arguments['count'], 2);
    status = ForegroundBridge.backgroundStatus.value;
    expect(status.running, isTrue);
    expect(status.stoppedReason, isNull);
  });

  test(
    'failed explicit pause preserves running status and allows a stop retry',
    () async {
      await ForegroundBridge.syncActiveCount(1);
      response = (call) async {
        if (call.method == 'stopService') {
          throw PlatformException(code: 'native_stop_rejected');
        }
        return true;
      };
      calls.clear();
      await ForegroundBridge.pauseBackgroundSupport();

      expect(calls.single.method, 'stopService');
      var status = ForegroundBridge.backgroundStatus.value;
      expect(status.activeSessions, 1);
      expect(status.running, isTrue);
      expect(status.error, 'foreground_stop_failed');
      calls.clear();
      await ForegroundBridge.syncActiveCount(2);
      await ForegroundBridge.syncLanguage(AppLanguage.en);
      expect(calls, isEmpty);
      status = ForegroundBridge.backgroundStatus.value;
      expect(status.running, isTrue);
      expect(status.activeSessions, 2);
      expect(status.error, 'foreground_stop_failed');

      response = (_) async => true;
      await ForegroundBridge.pauseBackgroundSupport();
      expect(calls.single.method, 'stopService');
      status = ForegroundBridge.backgroundStatus.value;
      expect(status.running, isFalse);
      expect(status.activeSessions, 2);
      expect(status.stoppedReason, 'user');
      expect(status.error, isNull);
    },
  );

  test(
    'count refresh during a pending pause preserves the completed native stop',
    () async {
      await ForegroundBridge.syncActiveCount(1);
      final stopping = Completer<void>();
      final result = Completer<Object?>();
      response = (call) async {
        if (call.method != 'stopService') return true;
        stopping.complete();
        return result.future;
      };
      calls.clear();
      final pending = ForegroundBridge.pauseBackgroundSupport();
      await stopping.future;
      await ForegroundBridge.syncActiveCount(2);
      await ForegroundBridge.syncLanguage(AppLanguage.en);
      result.complete(true);
      await pending;

      expect(calls.single.method, 'stopService');
      final status = ForegroundBridge.backgroundStatus.value;
      expect(status.running, isFalse);
      expect(status.activeSessions, 2);
      expect(status.stoppedReason, 'user');
      expect(status.error, isNull);
    },
  );

  test(
    'zero sessions clears native stop suppression for the next connection',
    () async {
      await ForegroundBridge.syncActiveCount(1);
      await emitStopped('user');
      calls.clear();
      await ForegroundBridge.syncActiveCount(0);
      expect(calls.single.method, 'stopService');
      final stopped = ForegroundBridge.backgroundStatus.value;
      expect(stopped.running, isFalse);
      expect(stopped.activeSessions, 0);
      expect(stopped.stoppedReason, isNull);

      await ForegroundBridge.syncActiveCount(1);
      expect(calls.last.method, 'startService');
      expect(ForegroundBridge.backgroundStatus.value.running, isTrue);
    },
  );

  test(
    'late native stop after zero sessions cannot suppress the next connection',
    () async {
      await ForegroundBridge.syncActiveCount(1);
      await ForegroundBridge.syncActiveCount(0);
      await emitStopped('user');
      calls.clear();

      await ForegroundBridge.syncActiveCount(1);
      expect(calls.single.method, 'startService');
      expect(ForegroundBridge.backgroundStatus.value.running, isTrue);
      expect(ForegroundBridge.backgroundStatus.value.stoppedReason, isNull);
    },
  );

  test(
    'failed service start is reported and count updates do not retry it',
    () async {
      response = (call) async {
        if (call.method == 'startService') {
          throw PlatformException(code: 'foreground_start_failed');
        }
        return true;
      };
      await ForegroundBridge.syncActiveCount(2);
      var status = ForegroundBridge.backgroundStatus.value;
      expect(status.running, isFalse);
      expect(status.activeSessions, 2);
      expect(status.error, 'foreground_start_failed');
      calls.clear();

      await ForegroundBridge.syncActiveCount(3);
      await ForegroundBridge.syncLanguage(AppLanguage.en);
      expect(calls, isEmpty);
      expect(
        ForegroundBridge.backgroundStatus.value.error,
        'foreground_start_failed',
      );

      response = (_) async => true;
      await ForegroundBridge.resumeBackgroundSupport();
      expect(calls.single.method, 'startService');
      expect(calls.single.arguments['count'], 3);
      status = ForegroundBridge.backgroundStatus.value;
      expect(status.running, isTrue);
      expect(status.error, isNull);
    },
  );

  test(
    'native stop during pending start is not overwritten by stale success',
    () async {
      final started = Completer<void>();
      final result = Completer<Object?>();
      response = (call) async {
        if (call.method != 'startService') return true;
        started.complete();
        return result.future;
      };
      final pending = ForegroundBridge.syncActiveCount(2);
      await started.future;
      await emitStopped('timeout');
      result.complete(true);
      await pending;

      final status = ForegroundBridge.backgroundStatus.value;
      expect(status.running, isFalse);
      expect(status.activeSessions, 2);
      expect(status.stoppedReason, 'timeout');
      calls.clear();
      await ForegroundBridge.syncActiveCount(3);
      expect(calls, isEmpty);
    },
  );

  test(
    'stale start failure cannot suppress a newer successful service update',
    () async {
      final started = Completer<void>();
      final firstResult = Completer<Object?>();
      response = (call) async {
        if (call.method == 'startService' && call.arguments['count'] == 1) {
          started.complete();
          return firstResult.future;
        }
        return true;
      };
      final firstStart = ForegroundBridge.syncActiveCount(1);
      await started.future;
      await ForegroundBridge.syncActiveCount(2);
      firstResult.completeError(
        PlatformException(code: 'foreground_start_failed'),
      );
      await firstStart;

      var status = ForegroundBridge.backgroundStatus.value;
      expect(status.running, isTrue);
      expect(status.activeSessions, 2);
      expect(status.error, isNull);
      calls.clear();
      await ForegroundBridge.syncActiveCount(3);
      expect(calls.single.method, 'startService');
      status = ForegroundBridge.backgroundStatus.value;
      expect(status.running, isTrue);
      expect(status.activeSessions, 3);
    },
  );

  test('desktop notification controls do not invoke Android APIs', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final status = await ForegroundBridge.getNotificationPermissionStatus();
    final requested = await ForegroundBridge.requestNotificationPermission();
    await ForegroundBridge.openNotificationSettings();
    expect(status.required, isFalse);
    expect(status.visible, isTrue);
    expect(status.canRequest, isFalse);
    expect(requested.visible, isTrue);
    expect(calls, isEmpty);
  });

  test('desktop sessions do not invoke the Android service channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await ForegroundBridge.syncActiveCount(2, language: AppLanguage.ko);
    await ForegroundBridge.syncLanguage(AppLanguage.en);
    await ForegroundBridge.syncActiveCount(0);
    expect(calls, isEmpty);
  });
}
