import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:termpulse/core/l10n.dart';

class NotificationPermissionStatus {
  final bool required;
  final bool granted;
  final bool notificationsEnabled;
  final bool channelEnabled;
  final bool canRequest;
  final bool shouldShowRationale;

  const NotificationPermissionStatus({
    required this.required,
    required this.granted,
    required this.notificationsEnabled,
    required this.channelEnabled,
    required this.canRequest,
    required this.shouldShowRationale,
  });

  factory NotificationPermissionStatus.fromMap(Map<Object?, Object?> map) =>
      NotificationPermissionStatus(
        required: map['required'] == true,
        granted: map['granted'] == true,
        notificationsEnabled: map['notificationsEnabled'] == true,
        channelEnabled: map['channelEnabled'] == true,
        canRequest: map['canRequest'] == true,
        shouldShowRationale: map['shouldShowRationale'] == true,
      );

  bool get visible => granted && notificationsEnabled && channelEnabled;
}

class BackgroundServiceStatus {
  final int activeSessions;
  final bool running;
  final String? stoppedReason;
  final String? error;

  const BackgroundServiceStatus({
    this.activeSessions = 0,
    this.running = false,
    this.stoppedReason,
    this.error,
  });
}

class ForegroundBridge {
  static const _channel = MethodChannel('com.termpulse.termpulse/foreground');
  static AppLanguage _language = AppLanguage.vi;
  static int _activeCount = 0;
  static bool _suppressed = false;
  static bool _handlerInstalled = false;
  static int _generation = 0;
  static final backgroundStatus = ValueNotifier<BackgroundServiceStatus>(
    const BackgroundServiceStatus(),
  );

  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static void _ensureHandler() {
    if (_handlerInstalled || !isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'foregroundServiceStopped') return;
      if (_activeCount <= 0) return;
      _generation++;
      final args = call.arguments;
      final reason = args is Map ? args['reason'] as String? : null;
      _suppressed = true;
      backgroundStatus.value = BackgroundServiceStatus(
        activeSessions: _activeCount,
        stoppedReason: reason ?? 'unknown',
      );
    });
    _handlerInstalled = true;
  }

  static Future<NotificationPermissionStatus> _permissionCall(
    String method,
  ) async {
    if (!isAndroid) {
      return const NotificationPermissionStatus(
        required: false,
        granted: true,
        notificationsEnabled: true,
        channelEnabled: true,
        canRequest: false,
        shouldShowRationale: false,
      );
    }
    _ensureHandler();
    final result = await _channel.invokeMethod<Object?>(method);
    if (result is! Map) {
      throw PlatformException(code: 'invalid_permission_status');
    }
    return NotificationPermissionStatus.fromMap(
      Map<Object?, Object?>.from(result),
    );
  }

  static Future<NotificationPermissionStatus>
  getNotificationPermissionStatus() =>
      _permissionCall('getNotificationPermissionStatus');

  static Future<NotificationPermissionStatus> requestNotificationPermission() =>
      _permissionCall('requestNotificationPermission');

  static Future<void> openNotificationSettings() async {
    if (!isAndroid) return;
    await _channel.invokeMethod<Object?>('openNotificationSettings');
  }

  static Future<void> resumeBackgroundSupport() async {
    _suppressed = false;
    await syncActiveCount(_activeCount);
  }

  static Future<void> pauseBackgroundSupport() async {
    if (!isAndroid) return;
    final previous = backgroundStatus.value;
    final generation = ++_generation;
    _suppressed = _activeCount > 0;
    try {
      await _channel.invokeMethod('stopService');
      if (generation != _generation) return;
      backgroundStatus.value = BackgroundServiceStatus(
        activeSessions: _activeCount,
        stoppedReason: 'user',
      );
    } catch (_) {
      if (generation != _generation) return;
      backgroundStatus.value = BackgroundServiceStatus(
        activeSessions: _activeCount,
        running: previous.running,
        error: 'foreground_stop_failed',
      );
    }
  }

  static Future<void> syncLanguage(AppLanguage language) async {
    if (_language == language) return;
    _language = language;
    if (_activeCount > 0) await syncActiveCount(_activeCount);
  }

  static Future<void> syncActiveCount(
    int count, {
    AppLanguage? language,
  }) async {
    _activeCount = count;
    if (language != null) _language = language;
    if (!isAndroid) return;
    if (count <= 0) _suppressed = false;
    if (count > 0 && _suppressed) {
      backgroundStatus.value = BackgroundServiceStatus(
        activeSessions: count,
        running: backgroundStatus.value.running,
        stoppedReason: backgroundStatus.value.stoppedReason,
        error: backgroundStatus.value.error,
      );
      return;
    }
    final generation = ++_generation;
    try {
      _ensureHandler();
      if (count > 0) {
        String tr(String source, [Map<String, String> parameters = const {}]) =>
            translateAppMessage(_language, source, parameters);
        await _channel.invokeMethod('startService', {
          'count': count,
          'strings': {
            'notification_title': tr('TermPulse đang hỗ trợ chạy nền'),
            'notification_text': tr('Hỗ trợ {count} phiên kết nối', {
              'count': '$count',
            }),
            'notification_stop': tr('Tắt dịch vụ hỗ trợ chạy nền'),
            'channel_name': tr('Phiên kết nối chạy nền'),
            'channel_description': tr(
              'Hỗ trợ phiên kết nối khi chuyển ứng dụng; Android có thể giới hạn thời gian chạy nền.',
            ),
          },
        });
        if (generation != _generation) return;
        backgroundStatus.value = BackgroundServiceStatus(
          activeSessions: count,
          running: true,
        );
      } else {
        await _channel.invokeMethod('stopService');
        if (generation != _generation) return;
        backgroundStatus.value = const BackgroundServiceStatus();
      }
    } catch (error) {
      if (generation != _generation) return;
      _suppressed = count > 0;
      backgroundStatus.value = BackgroundServiceStatus(
        activeSessions: count,
        error: error is PlatformException ? error.code : 'service_unavailable',
      );
    }
  }

  static Future<String> getAppDataDir() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        final dir = await _channel.invokeMethod<String>('getDataDir');
        if (dir != null && dir.isNotEmpty) return dir;
      } catch (_) {}
    }
    if (Platform.isWindows) {
      final appData =
          Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
      return '$appData\\TermPulse';
    }
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
      return '$home/Library/Application Support/TermPulse';
    }
    final xdg = Platform.environment['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) return '$xdg/termpulse';
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    return '$home/.local/share/termpulse';
  }
}
