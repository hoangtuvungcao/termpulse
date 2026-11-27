// Controlled native RDP interaction/continuous-rendering diagnostic.
// Start rust/examples/qa_rdp_server.rs; reverse tcp:33890 and tcp:18081.
// Pass its independently printed TLS pin as QA_RDP_FINGERPRINT. Build/install
// this target with -r and launch its Activity directly. No integration driver:
// driver cleanup can uninstall the user's application. Only loopback synthetic
// credentials are permitted. main() is not called and the real Vault is never
// opened. Fixture screenshots stay in private qa_rdp_touchpad_shots_* for QA.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:termpulse/core/foreground_bridge.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/remote_desktop_backend.dart';
import 'package:termpulse/core/session_log_store.dart';
import 'package:termpulse/features/remote_desktop/remote_desktop_session.dart';
import 'package:termpulse/main.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/src/rust/frb_generated.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/automation_provider.dart';
import 'package:termpulse/state/session_logs_provider.dart';
import 'package:termpulse/state/settings_provider.dart';

const _hostId = 'qa_controlled_rdp_touchpad';
const _hostLabel = 'Controlled RDP touchpad';
const _vaultPassword = 'Temporary-RDP-Touchpad-QA-2026!';
const _fingerprint = String.fromEnvironment('QA_RDP_FINGERPRINT');

class _MemorySettings extends SettingsController {
  @override
  void setLanguage(AppLanguage language) =>
      state = state.copyWith(language: language);
}

Finder _key(String name) => find.byKey(Key(name));

Future<void> _wait(
  WidgetTester tester,
  bool Function() ready, {
  String reason = 'Controlled RDP condition did not complete.',
  Duration timeout = const Duration(seconds: 15),
}) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < timeout) {
    await tester.pump(const Duration(milliseconds: 50));
    if (ready()) return;
  }
  fail(reason);
}

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < duration) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<Map<String, dynamic>> _stats() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client
        .getUrl(Uri.parse('http://127.0.0.1:18081/stats'))
        .timeout(const Duration(seconds: 3));
    final response = await request.close().timeout(const Duration(seconds: 3));
    if (response.statusCode != 200) {
      throw StateError('QA_CONTROLLED_RDP_STATS_UNAVAILABLE');
    }
    final value = jsonDecode(await utf8.decoder.bind(response).join());
    if (value is! Map<String, dynamic> ||
        value['fixture'] != 'termpulse-controlled-rdp-v1' ||
        value['width'] != 1280 ||
        value['height'] != 720) {
      throw StateError('QA_CONTROLLED_RDP_STATS_INVALID');
    }
    return value;
  } finally {
    client.close(force: true);
  }
}

int _count(Map<String, dynamic> stats, String name) => stats[name] as int;

Future<Map<String, dynamic>> _waitStats(
  WidgetTester tester,
  bool Function(Map<String, dynamic>) ready,
) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 5)) {
    await tester.pump(const Duration(milliseconds: 50));
    final stats = await _stats();
    if (ready(stats)) return stats;
  }
  fail('QA_CONTROLLED_RDP_INPUT_NOT_ACKNOWLEDGED');
}

Future<void> _orient(WidgetTester tester, bool landscape) async {
  await SystemChrome.setPreferredOrientations([
    landscape ? DeviceOrientation.landscapeLeft : DeviceOrientation.portraitUp,
  ]);
  await _wait(
    tester,
    () {
      final size = tester.view.physicalSize;
      return landscape ? size.width > size.height : size.height > size.width;
    },
    reason: 'QA_CONTROLLED_RDP_ORIENTATION_NOT_APPLIED',
    timeout: const Duration(seconds: 10),
  );
  await _pumpFor(tester, const Duration(milliseconds: 300));
}

double _scale(WidgetTester tester) {
  final viewer = find.descendant(
    of: _key('remoteDesktopViewport'),
    matching: find.byType(InteractiveViewer),
  );
  expect(viewer, findsOneWidget);
  return tester
      .widget<InteractiveViewer>(viewer)
      .transformationController!
      .value
      .storage[0]
      .abs();
}

void _expectScaleLabel(WidgetTester tester) {
  expect(
    tester.widget<Text>(_key('remoteDesktopScale')).data,
    '${(_scale(tester) * 100).round()}%',
  );
}

void _expectFittedDesktop(WidgetTester tester) {
  final viewport = tester.getSize(_key('remoteDesktopViewport'));
  final expected = math.min(viewport.width / 1280, viewport.height / 720);
  expect(expected, lessThan(1));
  expect(_scale(tester), closeTo(expected, .0001));
  _expectScaleLabel(tester);
}

Future<void> _tapControl(WidgetTester tester, String name) async {
  expect(_key(name).hitTestable(), findsOneWidget);
  await tester.tap(_key(name));
  await _pumpFor(tester, const Duration(milliseconds: 200));
}

bool _markerMatches(DesktopFrame? frame, int inputSequence) {
  if (frame == null || frame.width != 1280 || frame.height != 720) return false;
  final at = ((720 - 132 + 30) * 1280 + 1240) * 4;
  final red = (inputSequence % 8) * 28 + 16;
  final green = ((inputSequence ~/ 8) % 8) * 28 + 16;
  return (frame.rgba[at] - red).abs() <= 8 &&
      (frame.rgba[at + 1] - green).abs() <= 8 &&
      (frame.rgba[at + 2] - 80).abs() <= 8;
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey key,
  Directory directory,
  String name,
) async {
  await tester.pump();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
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
    await File('${directory.path}/$name.png').writeAsBytes(bytes, flush: true);
  } finally {
    image.dispose();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android controlled RDP touchpad and continuous desktop',
    (tester) async {
      expect(
        RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(_fingerprint),
        isTrue,
        reason: 'Pass the independently printed controlled RDP TLS pin.',
      );
      final initialStats = await _stats();
      await RustLib.init();
      final appData = Directory(await ForegroundBridge.getAppDataDir());
      final fixture = await appData.createTemp('qa_rdp_touchpad_vault_');
      final shots = await appData.createTemp('qa_rdp_touchpad_shots_');
      final logStore = SessionLogStore(
        directory: () async => Directory('${fixture.path}/logs'),
      );
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_MemorySettings.new),
          sessionLogStoreProvider.overrideWithValue(logStore),
          automationStorageProvider.overrideWithValue(
            FileAutomationStorage(directory: () async => fixture.path),
          ),
        ],
      );
      var cleaned = false;
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
        await attempt(
          container.read(sessionManagerProvider.notifier).closeAllSessions,
        );
        await attempt(container.read(backendProvider).vaultLock);
        await attempt(logStore.closeAll);
        await attempt(() async => container.dispose());
        await attempt(() => SystemChrome.setPreferredOrientations(const []));
        await attempt(() => fixture.delete(recursive: true));
        if (failure != null) {
          Error.throwWithStackTrace(failure!, failureStack!);
        }
      }

      addTearDown(cleanup);
      final native = container.read(remoteDesktopBackendProvider);
      expect(native, isA<RustRemoteDesktopBackend>());
      final pin = await native.probeCertificate(
        '127.0.0.1',
        33890,
        'localhost',
      );
      expect(pin.toLowerCase(), _fingerprint.toLowerCase());
      final vault = container.read(vaultProvider.notifier);
      await vault.initAtPath('${fixture.path}/vault.db');
      expect(container.read(vaultProvider).error, isNull);
      expect(await vault.unlock(_vaultPassword), isTrue);
      final inventory = container.read(inventoryProvider.notifier);
      await inventory.saveCredentialAndIdentity(
        cred: CredentialDto(
          id: 'qa_rdp_touchpad_credential',
          name: 'Controlled fixture only',
          kind: 'password',
          secret: 'fixture-password',
          storageBackend: 'vault',
        ),
        identity: IdentityDto(
          id: 'qa_rdp_touchpad_identity',
          name: 'Controlled fixture only',
          username: 'fixture',
          credentialId: 'qa_rdp_touchpad_credential',
        ),
      );
      await inventory.saveHost(
        HostDto(
          id: _hostId,
          label: _hostLabel,
          protocol: 'rdp',
          hostname: '127.0.0.1',
          port: 33890,
          identityMode: 'by_id',
          identityId: 'qa_rdp_touchpad_identity',
          jumpHostMode: 'none',
          proxyMode: 'none',
          envTag: 'dev',
          tags: const ['controlled-fixture'],
          notes: 'Synthetic loopback desktop only.',
          env: const [],
          followTerminalSftp: false,
          isFavorite: false,
          remoteDesktopJson: jsonEncode({
            'width': 1280,
            'height': 720,
            'tls_server_name': 'localhost',
            'tls_certificate_sha256': _fingerprint,
          }),
        ),
      );
      expect(container.read(inventoryProvider).error, isNull);
      final capture = GlobalKey();
      await _orient(tester, false);
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: UncontrolledProviderScope(
            container: container,
            child: const TermPulseApp(),
          ),
        ),
      );
      await _pumpFor(tester, const Duration(milliseconds: 400));
      final host = find.descendant(
        of: _key('mobileHostCard_$_hostId'),
        matching: find.text(_hostLabel),
      );
      await tester.ensureVisible(host);
      await tester.tap(host);
      RemoteDesktopSession? session;
      await _wait(
        tester,
        () {
          session = container
              .read(sessionManagerProvider)
              .activeTab
              ?.remoteDesktop;
          return session?.connected == true &&
              // Native connections may announce their framebuffer before the
              // first desktop update is decoded. The marker is sent after the
              // fixture background, so it qualifies real desktop pixels before
              // the sustained-frame clock starts.
              _markerMatches(
                session?.frame,
                _count(initialStats, 'inputSequence'),
              ) &&
              _key('remoteDesktopViewport').evaluate().isNotEmpty &&
              find
                  .descendant(
                    of: _key('remoteDesktopViewport'),
                    matching: find.byType(RawImage),
                  )
                  .evaluate()
                  .any((element) => (element.widget as RawImage).image != null);
        },
        reason: 'QA_CONTROLLED_RDP_DID_NOT_RENDER',
        timeout: const Duration(seconds: 40),
      );
      final desktop = session!;
      final sessionId = desktop.sessionId;
      expect(desktop.frame!.width, 1280);
      expect(desktop.frame!.height, 720);
      final sequenceBefore = desktop.frame!.sequence;
      await _pumpFor(tester, const Duration(seconds: 3));
      final continuousFrames = desktop.frame!.sequence - sequenceBefore;
      expect(continuousFrames, greaterThanOrEqualTo(15));
      await _capture(tester, capture, shots, 'portrait-initial');

      final before = await _stats();
      final tapClock = Stopwatch()..start();
      final frameBeforeTap = desktop.frame!.sequence;
      await tester.tapAt(tester.getRect(_key('remoteDesktopViewport')).center);
      final left = await _waitStats(
        tester,
        (s) =>
            _count(s, 'leftDown') == _count(before, 'leftDown') + 1 &&
            _count(s, 'leftUp') == _count(before, 'leftUp') + 1,
      );
      await _wait(
        tester,
        () =>
            desktop.frame!.sequence > frameBeforeTap &&
            _markerMatches(desktop.frame, _count(left, 'inputSequence')),
        reason: 'QA_CONTROLLED_RDP_CLICK_FRAME_NOT_ACKNOWLEDGED',
        timeout: const Duration(seconds: 5),
      );
      tapClock.stop();
      expect(_count(left, 'rightDown'), _count(before, 'rightDown'));
      expect(_count(left, 'rightUp'), _count(before, 'rightUp'));

      final center = tester.getRect(_key('remoteDesktopViewport')).center;
      final one = await tester.startGesture(
        center - const Offset(20, 0),
        pointer: 11,
        kind: ui.PointerDeviceKind.touch,
      );
      final two = await tester.startGesture(
        center + const Offset(20, 0),
        pointer: 12,
        kind: ui.PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 70));
      await two.up();
      await one.up();
      final right = await _waitStats(
        tester,
        (s) =>
            _count(s, 'rightDown') == _count(left, 'rightDown') + 1 &&
            _count(s, 'rightUp') == _count(left, 'rightUp') + 1,
      );
      expect(_count(right, 'leftDown'), _count(left, 'leftDown'));
      expect(_count(right, 'leftUp'), _count(left, 'leftUp'));

      final swipe = await tester.startGesture(center, pointer: 13);
      for (var step = 1; step <= 6; step++) {
        await swipe.moveTo(center + Offset(step * 9, step * -4));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await swipe.up();
      final moved = await _waitStats(
        tester,
        (s) =>
            _count(s, 'pointerX') > _count(right, 'pointerX') &&
            _count(s, 'pointerY') < _count(right, 'pointerY'),
      );
      for (final name in ['leftDown', 'leftUp', 'rightDown', 'rightUp']) {
        expect(_count(moved, name), _count(right, name));
      }
      expect(_key('remoteDesktopCursor'), findsOneWidget);

      final originalScale = _scale(tester);
      await _tapControl(tester, 'remoteDesktopZoomIn');
      expect(_scale(tester), closeTo(originalScale * 1.3, .0001));
      _expectScaleLabel(tester);
      await _tapControl(tester, 'remoteDesktopZoomOut');
      expect(_scale(tester), closeTo(originalScale, .0001));
      _expectScaleLabel(tester);
      final beforePinch = _scale(tester);
      final pinchOne = await tester.startGesture(
        center - const Offset(25, 0),
        pointer: 14,
      );
      final pinchTwo = await tester.startGesture(
        center + const Offset(25, 0),
        pointer: 15,
      );
      for (var step = 1; step <= 6; step++) {
        await pinchOne.moveTo(center - Offset(25 + step * 7, 0));
        await pinchTwo.moveTo(center + Offset(25 + step * 7, 0));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await pinchTwo.up();
      await pinchOne.up();
      await _pumpFor(tester, const Duration(milliseconds: 200));
      expect(_scale(tester), greaterThan(beforePinch));
      _expectScaleLabel(tester);
      final afterPinch = await _stats();
      for (final name in ['leftDown', 'leftUp', 'rightDown', 'rightUp']) {
        expect(_count(afterPinch, name), _count(moved, name));
      }
      await _tapControl(tester, 'remoteDesktopFit');
      _expectFittedDesktop(tester);
      await _capture(tester, capture, shots, 'portrait-fit');
      final portraitFitScale = _scale(tester);
      await _tapControl(tester, 'remoteDesktopZoomIn');
      expect(_scale(tester), closeTo(portraitFitScale * 1.3, .0001));
      _expectScaleLabel(tester);
      await _tapControl(tester, 'remoteDesktopZoomOut');
      expect(_scale(tester), closeTo(portraitFitScale, .0001));
      _expectScaleLabel(tester);
      await _tapControl(tester, 'remoteDesktopFit');
      _expectFittedDesktop(tester);

      final normalViewport = tester.getRect(_key('remoteDesktopViewport'));
      await _tapControl(tester, 'remoteDesktopFullscreen');
      final fullViewport = tester.getRect(_key('remoteDesktopViewport'));
      expect(fullViewport.height, greaterThan(normalViewport.height + 30));
      _expectFittedDesktop(tester);
      await _capture(tester, capture, shots, 'portrait-fullscreen');
      await _orient(tester, true);
      expect(desktop.connected, isTrue);
      expect(desktop.sessionId, sessionId);
      final landscape = tester.getRect(_key('remoteDesktopViewport'));
      expect(landscape.width, greaterThan(landscape.height));
      await _tapControl(tester, 'remoteDesktopFit');
      _expectFittedDesktop(tester);
      await _capture(tester, capture, shots, 'landscape-fullscreen-fit');
      final landscapeFitScale = _scale(tester);
      await _tapControl(tester, 'remoteDesktopZoomIn');
      expect(_scale(tester), closeTo(landscapeFitScale * 1.3, .0001));
      _expectScaleLabel(tester);
      await _capture(tester, capture, shots, 'landscape-fullscreen-zoom');
      await _orient(tester, false);
      expect(desktop.sessionId, sessionId);
      expect(desktop.connected, isTrue);
      await _tapControl(tester, 'remoteDesktopFullscreen');
      expect(tester.takeException(), isNull);
      (binding.reportData ??= <String, dynamic>{})['rdpTouchpad'] = {
        'result': 'passed',
        'continuousFramesInThreeSeconds': continuousFrames,
        'tapToAcknowledgedFrameMs': tapClock.elapsedMilliseconds,
        'singleTapLeft': true,
        'twoFingerTapRight': true,
        'relativeSwipeWithoutClick': true,
        'pinchWithoutClick': true,
        'portraitLandscapeFullscreen': true,
        'screenshotDirectory': shots.path,
      };
      await cleanup();
      debugPrint(
        'TERMPULSE_RDP_TOUCHPAD_PASSED frames_3s=$continuousFrames '
        'tap_ack_ms=${tapClock.elapsedMilliseconds} '
        'single_left=true two_finger_right=true relative_swipe=true '
        'pinch=true fullscreen=true orientation=true cleanup=true',
      );
      debugPrint('TERMPULSE_RDP_TOUCHPAD_SCREENSHOT_DIR=${shots.path}');
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
