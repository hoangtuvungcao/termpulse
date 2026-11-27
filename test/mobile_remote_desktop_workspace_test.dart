import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termpulse/core/l10n.dart';
import 'package:termpulse/core/remote_desktop_backend.dart';
import 'package:termpulse/core/theme.dart';
import 'package:termpulse/features/remote_desktop/remote_desktop_pane.dart';
import 'package:termpulse/features/sftp/sftp_panel.dart';
import 'package:termpulse/features/terminal/compose_bar.dart';
import 'package:termpulse/features/terminal/terminal_pane.dart';
import 'package:termpulse/src/rust/api/dto.dart';
import 'package:termpulse/state/app_providers.dart';
import 'package:termpulse/state/settings_provider.dart';
import 'package:termpulse/ui/mobile_shell.dart';

import 'widget_test.dart' show FakeCoreBackend;

const _channel = MethodChannel('com.termpulse.termpulse/foreground');

class _InventoryBackend extends FakeCoreBackend {
  _InventoryBackend(String protocol) {
    hosts
      ..clear()
      ..addAll([
        for (var index = 0; index < 2; index++)
          HostDto(
            id: '${protocol}_$index',
            label: 'Desktop $index',
            protocol: protocol,
            hostname: 'desktop.example',
            port: protocol == 'rdp' ? 3389 : 5900,
            identityMode: 'none',
            jumpHostMode: 'none',
            proxyMode: 'none',
            envTag: 'dev',
            tags: const [],
            notes: '',
            env: const [],
            isFavorite: false,
          ),
      ]);
  }
}

class _DesktopBackend implements RemoteDesktopBackend {
  final connections = <String>[];
  final closed = <String>[];
  final streams = <StreamController<RemoteDesktopEventDto>>[];

  @override
  Stream<RemoteDesktopEventDto> connectHost(String hostId) {
    connections.add(hostId);
    final stream = StreamController<RemoteDesktopEventDto>();
    streams.add(stream);
    return stream.stream;
  }

  @override
  Future<void> close(String sessionId) async => closed.add(sessionId);

  @override
  Future<void> key(String id, int key, bool down, bool unicode) async {}

  @override
  Future<void> pointer(
    String id,
    int x,
    int y,
    int buttons,
    int scrollY,
  ) async {}

  @override
  Future<void> typeText(String id, String text) async {}

  @override
  Future<String> probeCertificate(
    String hostname,
    int port,
    String? serverName,
  ) async => List.filled(32, 'ab').join();

  Future<void> dispose() async {
    for (final stream in streams) {
      await stream.close();
    }
  }
}

class _MemorySettings extends SettingsController {
  @override
  AppSettingsState build() => const AppSettingsState();
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _DesktopBackend desktop, {
  required String protocol,
  required Size size,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final inventory = _InventoryBackend(protocol);
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWithValue(inventory),
      remoteDesktopBackendProvider.overrideWithValue(desktop),
      settingsProvider.overrideWith(_MemorySettings.new),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await container.read(sessionManagerProvider.notifier).closeAllSessions();
    container.dispose();
    await desktop.dispose();
  });
  await container.read(vaultProvider.notifier).unlock('test-password');
  for (final host in inventory.hosts) {
    await container.read(sessionManagerProvider.notifier).openHostSession(host);
  }
  for (var index = 0; index < desktop.streams.length; index++) {
    final id = 'desktop_$index';
    desktop.streams[index].add(
      RemoteDesktopEventDto(
        kind: 'connected',
        sessionId: id,
        width: 0,
        height: 0,
        rgba: Uint8List(0),
        message: null,
      ),
    );
    desktop.streams[index].add(
      RemoteDesktopEventDto(
        kind: 'frame',
        sessionId: id,
        width: 2,
        height: 2,
        rgba: Uint8List.fromList([
          255,
          0,
          0,
          255,
          0,
          255,
          0,
          255,
          0,
          0,
          255,
          255,
          255,
          255,
          255,
          255,
        ]),
        message: null,
      ),
    );
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTermPulseTheme(AppThemePreset.dark),
        builder: (context, child) =>
            AppLocalizationScope(language: AppLanguage.vi, child: child!),
        home: const MobileShell(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.ancestor(of: find.text('2'), matching: find.byType(InkWell)).first,
  );
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
  return container;
}

void _expectDesktopOnly() {
  for (final key in [
    'mobileAccessoryBar',
    'stickyCtrlBtn',
    'stickyAltBtn',
    'mobileBottomSheetBtn',
    'mobileBottomSheet',
    'mobileTerminalFindBtn',
  ]) {
    expect(find.byKey(Key(key)), findsNothing, reason: key);
  }
  expect(find.byType(SftpPanel), findsNothing);
  expect(find.byType(ComposeBar), findsNothing);
  expect(find.text('A±'), findsNothing);
}

Future<void> _toggleFullscreen(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('remoteDesktopFullscreen')));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (_) async => true);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  for (final protocol in ['rdp', 'vnc']) {
    testWidgets(
      'mobile $protocol fullscreen preserves the live desktop and Back restores chrome',
      (tester) async {
        final backend = _DesktopBackend();
        final container = await _mount(
          tester,
          backend,
          protocol: protocol,
          size: protocol == 'rdp'
              ? const Size(412, 915)
              : const Size(872.7, 392.7),
        );
        final originalTab = container.read(sessionManagerProvider).activeTab!;
        final session = originalTab.remoteDesktop!;
        final terminalState = tester.state(find.byType(TerminalPane));
        final desktopState = tester.state(find.byType(RemoteDesktopPane));
        final controller = tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController;
        final image = tester.widget<RawImage>(find.byType(RawImage)).image;
        final originalHeight = tester
            .getSize(find.byType(RemoteDesktopPane))
            .height;

        void expectPreserved() {
          final tab = container.read(sessionManagerProvider).activeTab!;
          expect(tab.localKey, originalTab.localKey);
          expect(tab.remoteDesktop, same(session));
          expect(session.connected, isTrue);
          expect(session.sessionId, 'desktop_1');
          expect(tester.state(find.byType(TerminalPane)), same(terminalState));
          expect(
            tester.state(find.byType(RemoteDesktopPane)),
            same(desktopState),
          );
          expect(
            tester
                .widget<InteractiveViewer>(find.byType(InteractiveViewer))
                .transformationController,
            same(controller),
          );
          expect(
            tester.widget<RawImage>(find.byType(RawImage)).image,
            same(image),
          );
          expect(backend.connections, ['${protocol}_0', '${protocol}_1']);
          expect(backend.closed, isEmpty);
          _expectDesktopOnly();
          expect(tester.takeException(), isNull);
        }

        _expectDesktopOnly();
        expect(find.byKey(const Key('mobileWorkspaceAppBar')), findsOneWidget);
        expect(find.byKey(const Key('mobileSessionTabsStrip')), findsOneWidget);
        expectPreserved();

        await _toggleFullscreen(tester);
        expect(find.byKey(const Key('mobileWorkspaceAppBar')), findsNothing);
        expect(find.byKey(const Key('mobileSessionTabsStrip')), findsNothing);
        expect(
          tester
              .widget<RemoteDesktopPane>(find.byType(RemoteDesktopPane))
              .fullscreen,
          isTrue,
        );
        expect(
          tester.getSize(find.byType(RemoteDesktopPane)).height,
          greaterThan(originalHeight + 90),
        );
        expectPreserved();

        await _toggleFullscreen(tester);
        expect(find.byKey(const Key('mobileWorkspaceAppBar')), findsOneWidget);
        expect(find.byKey(const Key('mobileSessionTabsStrip')), findsOneWidget);
        expect(
          tester.getSize(find.byType(RemoteDesktopPane)).height,
          originalHeight,
        );
        expectPreserved();

        await _toggleFullscreen(tester);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('mobileWorkspaceAppBar')), findsOneWidget);
        expect(find.byKey(const Key('mobileSessionTabsStrip')), findsOneWidget);
        expect(
          tester
              .widget<RemoteDesktopPane>(find.byType(RemoteDesktopPane))
              .fullscreen,
          isFalse,
        );
        expectPreserved();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}
