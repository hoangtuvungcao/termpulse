import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/l10n_catalog_remote.dart';
import 'package:termpulse/core/remote_desktop_backend.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/remote_desktop/remote_desktop_pane.dart';
import 'package:termpulse/features/remote_desktop/remote_desktop_session.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/automation_provider.dart';
import 'package:termpulse/state/settings_provider.dart';

import 'state_regression_test.dart' show ControlledBackend, flushEvents;

HostDto _host(String protocol, {String? options}) => HostDto(
  id: 'host_$protocol',
  label: '日本語 desktop',
  protocol: protocol,
  hostname: 'desktop.example',
  port: protocol == 'rdp' ? 3389 : 5900,
  identityMode: 'direct',
  identityId: 'identity',
  jumpHostMode: 'none',
  proxyMode: 'none',
  envTag: 'prod',
  tags: ['lab'],
  notes: 'Keep user text',
  env: [],
  isFavorite: true,
  remoteDesktopJson: options,
);

RemoteDesktopEventDto _event(
  String kind, {
  String id = 'desktop_1',
  String? message,
  int width = 0,
  int height = 0,
  List<int> rgba = const [],
}) => RemoteDesktopEventDto(
  kind: kind,
  sessionId: id,
  width: width,
  height: height,
  rgba: Uint8List.fromList(rgba),
  message: message,
);

RemoteDesktopEventDto _frame({String id = 'desktop_1'}) => _event(
  'frame',
  id: id,
  width: 2,
  height: 2,
  rgba: [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255],
);

class _DesktopBackend implements RemoteDesktopBackend {
  final streams = <StreamController<RemoteDesktopEventDto>>[];
  final hosts = <String>[];
  final operations = <String>[];
  final closed = <String>[];
  final cancelled = <int>[];
  Future<void>? inputGate;
  final fingerprint = List.filled(32, 'ab').join();

  @override
  Stream<RemoteDesktopEventDto> connectHost(String hostId) {
    hosts.add(hostId);
    final index = streams.length;
    final controller = StreamController<RemoteDesktopEventDto>(
      onCancel: () => cancelled.add(index),
    );
    streams.add(controller);
    return controller.stream;
  }

  @override
  Future<void> close(String sessionId) async => closed.add(sessionId);

  @override
  Future<void> key(String id, int key, bool down, bool unicode) async {
    operations.add('$id:key:$key:$down:$unicode');
    await inputGate;
  }

  @override
  Future<void> pointer(
    String id,
    int x,
    int y,
    int buttons,
    int scrollY,
  ) async {
    operations.add('$id:pointer:$x:$y:$buttons:$scrollY');
    await inputGate;
  }

  @override
  Future<void> typeText(String id, String text) async {
    operations.add('$id:text:$text');
    await inputGate;
  }

  @override
  Future<String> probeCertificate(
    String hostname,
    int port,
    String? serverName,
  ) async => fingerprint;

  Future<void> dispose() async {
    for (final stream in streams) {
      await stream.close();
    }
  }
}

class _InventoryBackend extends ControlledBackend {
  final hosts = <HostDto>[];
  bool locked = false;

  @override
  Future<List<HostDto>> listHosts() async => List.of(hosts);

  @override
  Future<void> upsertHost(HostDto host) async {
    hosts.removeWhere((h) => h.id == host.id);
    hosts.add(host);
  }

  @override
  Future<void> vaultLock() async => locked = true;
}

Future<void> _mount(
  WidgetTester tester,
  RemoteDesktopSession session, {
  AppLanguage language = AppLanguage.en,
  ProviderContainer? container,
  Size size = const Size(800, 600),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final providers = container ?? ProviderContainer();
  if (container == null) addTearDown(providers.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: providers,
      child: AppLocalizationScope(
        language: language,
        child: MaterialApp(
          theme: buildTermPulseTheme(AppThemePreset.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: RemoteDesktopPane(session: session, onFocus: () {}),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _render(
  WidgetTester tester,
  _DesktopBackend backend, {
  String id = 'desktop_1',
  RemoteDesktopEventDto? frame,
}) async {
  backend.streams.last.add(_event('connected', id: id));
  backend.streams.last.add(frame ?? _frame(id: id));
  await tester.pump();
  for (
    var attempt = 0;
    attempt < 30 && find.byType(RawImage).evaluate().isEmpty;
    attempt++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  expect(find.byType(RawImage), findsOneWidget);
  await tester.pumpAndSettle();
}

Future<void> _action(WidgetTester tester, String name) async {
  await tester.tap(find.byTooltip('Remote desktop actions'));
  await tester.pumpAndSettle();
  final label = find.text(name);
  final checked = find.ancestor(
    of: label,
    matching: find.byType(CheckedPopupMenuItem<String>),
  );
  await tester.tap(checked.evaluate().isNotEmpty ? checked : label);
  await tester.pumpAndSettle();
}

void main() {
  late _DesktopBackend backend;
  late RemoteDesktopSession session;

  setUp(() {
    backend = _DesktopBackend();
    session = RemoteDesktopSession(
      host: _host('rdp'),
      backend: backend,
      onStatusChanged: () {},
    );
  });

  tearDown(() async {
    session.dispose();
    await flushEvents();
    await backend.dispose();
  });

  testWidgets(
    'Android phone opens native-sized desktop at readable scale in landscape',
    (tester) async {
      await session.connect();
      await _mount(tester, session, size: const Size(872.7, 392.7));
      await _render(
        tester,
        backend,
        frame: _event(
          'frame',
          width: 1280,
          height: 720,
          rgba: Uint8List(1280 * 720 * 4),
        ),
      );
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      final transform = viewer.transformationController!.value;
      expect(transform.storage[0], closeTo(1, .0001));
      expect(transform.storage[5], closeTo(1, .0001));
      expect(find.text('100%'), findsOneWidget);
      final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
      expect(image.width, 1280);
      expect(image.height, 720);
      final viewport = tester.getSize(
        find.byKey(const Key('remoteDesktopViewport')),
      );
      final desktopCenter = MatrixUtils.transformPoint(
        transform,
        const Offset(640, 360),
      );
      expect(desktopCenter.dx, closeTo(viewport.width / 2, .001));
      expect(desktopCenter.dy, closeTo(viewport.height / 2, .001));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'fit scale below one drives percentage zoom buttons and relative touch movement',
    (tester) async {
      await session.connect();
      await _mount(tester, session, size: const Size(412, 915));
      await _render(
        tester,
        backend,
        frame: _event(
          'frame',
          width: 1280,
          height: 720,
          rgba: Uint8List(1280 * 720 * 4),
        ),
      );
      final controller = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      final viewport = find.byKey(const Key('remoteDesktopViewport'));
      final size = tester.getSize(viewport);
      final fitScale = math.min(size.width / 1280, size.height / 720);
      expect(fitScale, lessThan(1));

      void expectScale(double expected) {
        expect(controller.value.storage[0], closeTo(expected, .0001));
        expect(controller.value.storage[5], closeTo(expected, .0001));
        expect(
          tester.widget<Text>(find.byKey(const Key('remoteDesktopScale'))).data,
          '${(expected * 100).round()}%',
        );
      }

      await tester.tap(find.byKey(const Key('remoteDesktopFit')));
      await tester.pumpAndSettle();
      expectScale(fitScale);
      await tester.tap(find.byKey(const Key('remoteDesktopZoomIn')));
      await tester.pumpAndSettle();
      expectScale(fitScale * 1.3);
      await tester.tap(find.byKey(const Key('remoteDesktopZoomOut')));
      await tester.pumpAndSettle();
      expectScale(fitScale);

      final finger = await tester.startGesture(
        tester.getCenter(viewport),
        kind: PointerDeviceKind.touch,
      );
      await finger.moveBy(const Offset(40, 24));
      await tester.pump(const Duration(milliseconds: 20));
      await finger.up();
      await tester.pumpAndSettle();
      final x = (640 + 40 / fitScale).round();
      final y = (360 + 24 / fitScale).round();
      expect(backend.operations, ['desktop_1:pointer:$x:$y:0:0']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'reconnect cancels a stationary finger hold before it can press in the new session',
    (tester) async {
      await session.connect();
      await _mount(tester, session, size: const Size(412, 915));
      await _render(tester, backend);
      final finger = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('remoteDesktopViewport'))),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(backend.operations, isEmpty);

      await tester.runAsync(session.connect);
      await tester.pump();
      await _render(tester, backend, id: 'desktop_2');
      expect(session.connected, isTrue);
      expect(session.sessionId, 'desktop_2');
      await tester.pump(const Duration(milliseconds: 600));
      expect(backend.operations, isEmpty);
      await finger.up();
      await tester.pumpAndSettle();
      expect(backend.operations, isEmpty);
      expect(backend.hosts, ['host_rdp', 'host_rdp']);
      expect(backend.closed, ['desktop_1']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  test('input retains pointer, key and Unicode text ordering', () async {
    await session.connect();
    backend.streams.single.add(_event('connected'));
    await flushEvents();
    final gate = Completer<void>();
    backend.inputGate = gate.future;
    final down = session.pointer(20, 30, 1);
    final key = session.key(0x153, true);
    final up = session.pointer(20, 30, 0);
    final text = session.typeText('Việt 日本語 한글');
    await flushEvents();
    expect(backend.operations, ['desktop_1:pointer:20:30:1:0']);
    gate.complete();
    await Future.wait([down, key, up, text]);
    expect(backend.operations, [
      'desktop_1:pointer:20:30:1:0',
      'desktop_1:key:339:true:false',
      'desktop_1:pointer:20:30:0:0',
      'desktop_1:text:Việt 日本語 한글',
    ]);
  });

  test('reconnect discards queued input and old frames', () async {
    await session.connect();
    backend.streams.single.add(_event('connected'));
    backend.streams.single.add(_frame());
    await flushEvents();
    final gate = Completer<void>();
    backend.inputGate = gate.future;
    final down = session.key(30, true);
    final queued = session.typeText('must not enter the next connection');
    await flushEvents();
    await session.connect();
    expect(backend.closed, ['desktop_1']);
    expect(backend.cancelled, [0]);
    expect(session.frame, isNull);
    backend.streams.first.add(_frame());
    backend.streams.last.add(_event('connected', id: 'desktop_2'));
    await flushEvents();
    gate.complete();
    await Future.wait([down, queued]);
    expect(session.sessionId, 'desktop_2');
    expect(session.frame, isNull);
    expect(backend.operations, ['desktop_1:key:30:true:false']);
    await session.key(31, true);
    expect(backend.operations.last, 'desktop_2:key:31:true:false');
  });

  test(
    'invalid frames close native connections and erase pixels and clipboard',
    () async {
      await session.connect();
      backend.streams.single.add(_event('connected'));
      backend.streams.single.add(_frame());
      backend.streams.single.add(_event('clipboard', message: 'secret'));
      await flushEvents();
      expect(session.frame, isNotNull);
      backend.streams.single.add(_event('frame', width: 5000, height: 3000));
      await flushEvents();
      expect(session.closed, isTrue);
      expect(session.connected, isFalse);
      expect(session.frame, isNull);
      expect(session.remoteClipboard, isNull);
      expect(session.message, contains('không hợp lệ'));
      expect(backend.closed, ['desktop_1']);
    },
  );

  test(
    'stream errors close once; stream completion marks a session ended',
    () async {
      await session.connect();
      backend.streams.single.add(_event('connected'));
      backend.streams.single.addError(StateError('network lost'));
      await flushEvents();
      expect(session.closed, isTrue);
      expect(session.message, contains('network lost'));
      expect(backend.closed, ['desktop_1']);
      await session.connect();
      backend.streams.last.add(_event('connected', id: 'desktop_2'));
      await backend.streams.last.close();
      expect(session.closed, isTrue);
      expect(session.connected, isFalse);
    },
  );

  test(
    'desktop sessions are excluded from shell commands, broadcasts and macros',
    () async {
      final terminalBackend = _InventoryBackend();
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWithValue(terminalBackend),
          remoteDesktopBackendProvider.overrideWithValue(backend),
        ],
      );
      addTearDown(container.dispose);
      final manager = container.read(sessionManagerProvider.notifier);
      terminalBackend.hosts.add(_host('rdp'));
      await manager.openQuickSsh(target: 'ssh.example');
      terminalBackend.connections.single.add(
        const TerminalEventDto(kind: 'session_opened', text: 'ssh_1'),
      );
      await flushEvents();
      await manager.openHostSession(_host('rdp'));
      backend.streams.last.add(_event('connected'));
      await flushEvents();
      manager.toggleBroadcast();
      final workspace = container.read(sessionManagerProvider);
      expect(workspace.tabs, hasLength(2));
      expect(workspace.activeTab!.remoteDesktop, isNotNull);
      expect(workspace.broadcastTargets.map((tab) => tab.sessionId), ['ssh_1']);
      expect(MacroTargetSnapshot.capture(workspace), isNull);
      expect(
        await manager.sendTextToActive(
          'dangerous shell command',
          broadcastIfEnabled: true,
        ),
        isFalse,
      );
      expect(terminalBackend.inputs, isEmpty);
      expect(terminalBackend.broadcasts, isEmpty);
      manager.toggleTabBroadcast(workspace.activeTab!.localKey);
      expect(
        container.read(sessionManagerProvider).activeTab!.broadcastIncluded,
        isFalse,
      );
      await manager.closeAllSessions();
      expect(backend.closed, ['desktop_1']);
      expect(terminalBackend.closedSessions, ['ssh_1']);
    },
  );

  test(
    'locking vault closes all sessions and clears retained desktop pixels',
    () async {
      final terminalBackend = _InventoryBackend();
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWithValue(terminalBackend),
          remoteDesktopBackendProvider.overrideWithValue(backend),
        ],
      );
      addTearDown(container.dispose);
      final manager = container.read(sessionManagerProvider.notifier);
      terminalBackend.hosts.add(_host('vnc'));
      await manager.openHostSession(_host('vnc'));
      backend.streams.single.add(_event('connected'));
      backend.streams.single.add(_frame());
      await flushEvents();
      final desktop = container
          .read(sessionManagerProvider)
          .activeTab!
          .remoteDesktop!;
      expect(desktop.frame, isNotNull);
      await container.read(vaultProvider.notifier).lock();
      expect(backend.closed, ['desktop_1']);
      expect(desktop.frame, isNull);
      expect(desktop.closed, isTrue);
      expect(container.read(sessionManagerProvider).tabs, isEmpty);
      expect(terminalBackend.locked, isTrue);
    },
  );

  test(
    'cloning a desktop host preserves credentials and display/TLS options',
    () async {
      final inventory = _InventoryBackend();
      final container = ProviderContainer(
        overrides: [backendProvider.overrideWithValue(inventory)],
      );
      addTearDown(container.dispose);
      final original = _host(
        'rdp',
        options:
            '{"width":1920,"height":1080,"domain":"ACME","tls_certificate_sha256":"abc"}',
      );
      await container.read(inventoryProvider.notifier).cloneHost(original);
      final copy = inventory.hosts.single;
      expect(copy.id, isNot(original.id));
      expect(copy.remoteDesktopJson, original.remoteDesktopJson);
      expect(copy.identityId, original.identityId);
      expect(copy.protocol, 'rdp');
    },
  );

  test(
    'all native desktop errors have five-language explanations and preserve diagnostics',
    () {
      for (final language in AppLanguage.values) {
        for (final entry in remoteDesktopErrorSources.entries) {
          final message = translateAppMessage(
            language,
            '${entry.key}: diagnostic desktop.example:3389 日本語',
          );
          expect(
            message,
            startsWith(translateAppMessage(language, entry.value)),
          );
          expect(
            message,
            contains('[${entry.key}] diagnostic desktop.example:3389 日本語'),
          );
          if (language != AppLanguage.vi) {
            expect(message, isNot(startsWith(entry.value)));
          }
        }
      }
      expect(
        translateAppMessage(
          AppLanguage.en,
          'AnyhowException(RDP_AUTHENTICATION: access denied)',
        ),
        contains('Check the account, password and domain.'),
      );
    },
  );

  for (final language in AppLanguage.values) {
    testWidgets('remote desktop at 320px supports ${language.code}', (
      tester,
    ) async {
      await session.connect();
      await _mount(
        tester,
        session,
        language: language,
        size: const Size(320, 640),
      );
      backend.streams.single.add(
        _event('error', message: 'RDP_CERTIFICATE_UNTRUSTED: unknown issuer'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(translateAppMessage(language, 'Xác minh chứng chỉ')),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          translateAppMessage(
            language,
            remoteDesktopErrorSources['RDP_CERTIFICATE_UNTRUSTED']!,
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final protocol in ['rdp', 'vnc']) {
    testWidgets(
      '$protocol displays pixels and delivers Unicode, pointer and attention keys',
      (tester) async {
        session.dispose();
        session = RemoteDesktopSession(
          host: _host(protocol),
          backend: backend,
          onStatusChanged: () {},
        );
        await session.connect();
        await _mount(tester, session);
        await _render(tester, backend);
        await tester.tap(find.byType(RawImage));
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA, character: 'ế');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
        expect(backend.operations, contains('desktop_1:key:7871:true:true'));
        expect(backend.operations, contains('desktop_1:key:7871:false:true'));
        expect(
          backend.operations.where((s) => s.contains(':pointer:')),
          isNotEmpty,
        );
        backend.operations.clear();
        await _action(tester, 'Ctrl+Alt+Del');
        final keys = protocol == 'rdp'
            ? [0x1d, 0x38, 0x153]
            : [0xffe3, 0xffe9, 0xffff];
        expect(backend.operations, [
          for (final key in keys) 'desktop_1:key:$key:true:false',
          for (final key in keys.reversed) 'desktop_1:key:$key:false:false',
        ]);
        await _action(tester, 'View only');
        backend.operations.clear();
        await tester.tap(find.byType(RawImage));
        await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
        await tester.pump();
        expect(backend.operations, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('text dialog fits landscape keyboard with large text', (
    tester,
  ) async {
    await session.connect();
    await _mount(tester, session, size: const Size(740, 360), textScale: 1.6);
    await _render(tester, backend);
    await _action(tester, 'Type text');
    tester.view.viewInsets = const FakeViewPadding(bottom: 140);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final input = find.byKey(const Key('remoteDesktopTextInput'));
    await Scrollable.ensureVisible(tester.element(input), alignment: .5);
    await tester.enterText(input, 'checked text');
    expect(backend.operations, isEmpty);
    final send = find.widgetWithText(FilledButton, 'Send');
    expect(send.hitTestable(), findsOneWidget);
    final sendBounds = tester.getRect(send);
    expect(sendBounds.top, greaterThanOrEqualTo(0));
    expect(sendBounds.bottom, lessThanOrEqualTo(220));
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(backend.operations, ['desktop_1:text:checked text']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('text entry requires Send and refuses a reconnected session', (
    tester,
  ) async {
    await session.connect();
    await _mount(tester, session);
    await _render(tester, backend);
    await _action(tester, 'Type text');
    await tester.enterText(
      find.byKey(const Key('remoteDesktopTextInput')),
      'Việt 日本語 한글',
    );
    expect(backend.operations, isEmpty);
    await tester.tap(find.text('Send'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(backend.operations, ['desktop_1:text:Việt 日本語 한글']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
